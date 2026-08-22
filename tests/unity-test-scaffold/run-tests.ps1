[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:SkillRoot = Join-Path $script:RepositoryRoot 'skills\codex\unity-test-scaffold'
$script:RunnerPath = Join-Path $script:SkillRoot 'scripts\invoke-unity-test-scaffold.ps1'
$script:CorePath = Join-Path $script:SkillRoot 'scripts\lib\unity-test-scaffold-core.ps1'
$script:FingerprintPath = Join-Path $script:RepositoryRoot 'skills\codex\unity-project-doctor\scripts\lib\unity-project-fingerprint.ps1'
$script:DoctorPath = Join-Path $script:RepositoryRoot 'skills\codex\unity-project-doctor\scripts\inspect-unity-project.ps1'
$script:ValidatorPath = Join-Path $script:RepositoryRoot 'skills\codex\unity-baseline-verification\scripts\lib\json-schema-validator.ps1'
$script:SchemaPath = Join-Path $script:RepositoryRoot 'schemas\unity-test-scaffold-result-1.0.0.schema.json'
$script:InstallerPath = Join-Path $script:RepositoryRoot 'scripts\install-codex-skills.ps1'
$script:FixtureRoot = Join-Path $script:RepositoryRoot 'tests\fixtures\test-scaffold-minimal'
$script:ScratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('uts-tests-' + [guid]::NewGuid().ToString('N'))
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Assertions = 0
$script:CaseCounter = 0

. $script:CorePath
. $script:FingerprintPath
. $script:ValidatorPath

# Throws when one boolean test condition is false.
function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $script:Assertions++
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

# Throws when two scalar values are not equal.
function Assert-Equal {
    param(
        [Parameter()][AllowNull()]$Expected,
        [Parameter()][AllowNull()]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $script:Assertions++
    if ($Expected -ne $Actual) {
        throw "Assertion failed: $Message. Expected '$Expected', actual '$Actual'."
    }
}

# Writes one UTF-8-no-BOM test artifact only below the unique scratch root.
function Write-TestText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $normalizedPath = [System.IO.Path]::GetFullPath($Path)
    $normalizedScratch = [System.IO.Path]::GetFullPath($script:ScratchRoot).TrimEnd('\') + '\'
    if (-not $normalizedPath.StartsWith($normalizedScratch, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Test write escaped scratch root: $normalizedPath"
    }
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $normalizedPath))
    [System.IO.File]::WriteAllText($normalizedPath, $Content, $script:Utf8NoBom)
}

# Returns a deterministic file-list and hash snapshot while excluding Git metadata.
function Get-TestTreeSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Root
    )

    $normalizedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $records = New-Object System.Collections.ArrayList
    foreach ($file in @(Get-ChildItem -LiteralPath $normalizedRoot -File -Recurse -Force | Where-Object {
        $_.FullName -notmatch '[\\/]\.git(?:[\\/]|$)'
    } | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($normalizedRoot.Length + 1).Replace('\', '/')
        [void]$records.Add("$relative|$($file.Length)|$(Get-UnityFingerprintFileSha256 -Path $file.FullName)")
    }
    return [string]::Join("`n", [string[]]$records)
}

# Copies the immutable committed fixture into one isolated scratch project.
function New-TestProjectCopy {
    param(
        [Parameter(Mandatory = $true)][string]$Name
    )

    $destination = Join-Path $script:ScratchRoot $Name
    if (Test-Path -LiteralPath $destination) {
        throw "Scratch test project already exists: $destination"
    }
    Copy-Item -LiteralPath $script:FixtureRoot -Destination $destination -Recurse -ErrorAction Stop
    return [System.IO.Path]::GetFullPath($destination)
}

# Runs the production scaffold in a child PowerShell and parses its single JSON stdout document.
function Invoke-ScaffoldCase {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter()][AllowEmptyCollection()][string[]]$AdditionalArguments = @()
    )

    $script:CaseCounter++
    $stderrPath = Join-Path $script:ScratchRoot ("stderr-$($script:CaseCounter).txt")
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $script:RunnerPath,
        '-ProjectRoot', $ProjectRoot
    ) + @($AdditionalArguments)
    $stdoutLines = @(& powershell.exe @arguments 2> $stderrPath)
    $exitCode = $LASTEXITCODE
    $stdout = [string]::Join("`n", [string[]]$stdoutLines)
    $stderr = if (Test-Path -LiteralPath $stderrPath) { [System.IO.File]::ReadAllText($stderrPath) } else { '' }
    $document = $null
    try {
        $document = ConvertFrom-Json -InputObject $stdout -ErrorAction Stop
    } catch {
        throw "Scaffold stdout was not one JSON document. Exit=$exitCode stderr=$stderr stdout=$stdout"
    }
    return [pscustomobject][ordered]@{
        exitCode = $exitCode
        stdout = $stdout
        stderr = $stderr
        result = $document
    }
}

# Runs Doctor against a scratch project and returns its parsed read-only result.
function Invoke-DoctorCase {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    $stderrPath = Join-Path $script:ScratchRoot 'doctor-stderr.txt'
    $stdoutLines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:DoctorPath -ProjectRoot $ProjectRoot 2> $stderrPath)
    if ($LASTEXITCODE -ne 0) {
        $diagnostic = if (Test-Path -LiteralPath $stderrPath) { [System.IO.File]::ReadAllText($stderrPath) } else { '' }
        throw "Doctor fixture execution failed: $diagnostic"
    }
    return ([string]::Join("`n", [string[]]$stdoutLines) | ConvertFrom-Json)
}

# Reports whether this Windows token can create a temporary directory symbolic link.
function Test-SymbolicLinkCapability {
    $target = Join-Path $script:ScratchRoot 'symlink-capability-target'
    $link = Join-Path $script:ScratchRoot 'symlink-capability-link'
    [void][System.IO.Directory]::CreateDirectory($target)
    try {
        New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    } finally {
        if (Test-Path -LiteralPath $link) {
            Remove-Item -LiteralPath $link -Force
        }
    }
}

[void][System.IO.Directory]::CreateDirectory($script:ScratchRoot)
$repositoryBefore = Get-TestTreeSnapshot -Root $script:RepositoryRoot
$fixtureBefore = Get-TestTreeSnapshot -Root $script:FixtureRoot
try {
    foreach ($metaKind in @('Folder', 'AssemblyDefinition')) {
        $metaContent = New-UtsMetaContent -Guid ('a' * 32) -Kind $metaKind
        $metaBytes = $script:Utf8NoBom.GetBytes($metaContent)
        Assert-True -Condition $metaContent.EndsWith("`n", [System.StringComparison]::Ordinal) -Message "$metaKind metadata has a terminal LF"
        Assert-True -Condition (-not $metaContent.EndsWith("`n`n", [System.StringComparison]::Ordinal)) -Message "$metaKind metadata has exactly one terminal LF"
        Assert-True -Condition (-not $metaContent.Contains("`r")) -Message "$metaKind metadata uses LF-only line endings"
        Assert-Equal -Expected 10 -Actual ([int]$metaBytes[$metaBytes.Length - 1]) -Message "$metaKind metadata serializes with LF as its final byte"
    }

    $notUnityRoot = Join-Path $script:ScratchRoot 'not-unity'
    Write-TestText -Path (Join-Path $notUnityRoot 'README.txt') -Content 'not unity'
    $notUnity = Invoke-ScaffoldCase -ProjectRoot $notUnityRoot
    Assert-Equal -Expected 0 -Actual $notUnity.exitCode -Message 'Not-Unity result is a structured semantic block'
    Assert-Equal -Expected 'SCAFFOLD_BLOCKED' -Actual $notUnity.result.finalStatus -Message 'Not-Unity status is blocked'
    Assert-True -Condition (@($notUnity.result.blockers | Where-Object { $_.code -eq 'NOT_A_UNITY_PROJECT' }).Count -eq 1) -Message 'Not-Unity blocker is exact'

    $planProject = New-TestProjectCopy -Name 'plan-project'
    $planBefore = Get-TestTreeSnapshot -Root $planProject
    $planOne = Invoke-ScaffoldCase -ProjectRoot $planProject
    $planTwo = Invoke-ScaffoldCase -ProjectRoot $planProject
    Assert-Equal -Expected 0 -Actual $planOne.exitCode -Message 'Plan exits successfully'
    Assert-Equal -Expected '' -Actual $planOne.stderr.Trim() -Message 'Normal plan emits no stderr diagnostics'
    Assert-Equal -Expected 'SCAFFOLD_PLAN_READY' -Actual $planOne.result.finalStatus -Message 'Minimal project produces a ready plan'
    Assert-Equal -Expected 'INFERRED_UNIQUE_RUNTIME_DIRECTORY' -Actual $planOne.result.runtime.resolution -Message 'Unique Runtime directory is inferred'
    Assert-Equal -Expected 'Assets/_Project/Scripts/Runtime' -Actual $planOne.result.runtime.sourceRoot -Message 'Runtime path is exact'
    Assert-Equal -Expected 'Assets/_Project/Tests/EditMode' -Actual $planOne.result.tests.root -Message 'Conventional test root is derived'
    Assert-Equal -Expected 2 -Actual @($planOne.result.plan.directories).Count -Message 'Plan contains two new directories'
    Assert-Equal -Expected 6 -Actual @($planOne.result.plan.files).Count -Message 'Plan contains two asmdefs and four metadata files'
    Assert-True -Condition ([bool]$planOne.result.plan.requiresConfirmation) -Message 'Plan requires explicit confirmation'
    Assert-True -Condition ([string]$planOne.result.plan.planSha256 -match '^[0-9a-f]{64}$') -Message 'Plan exposes a SHA-256 confirmation token'
    Assert-Equal -Expected $planOne.stdout -Actual $planTwo.stdout -Message 'Compact plan JSON is byte-for-byte deterministic'
    Assert-Equal -Expected $planBefore -Actual (Get-TestTreeSnapshot -Root $planProject) -Message 'Planning leaves project files unchanged'
    Assert-True -Condition (@($planOne.result.plan.files | Where-Object { $_.kind -eq 'RUNTIME_ASMDEF' }).Count -eq 1) -Message 'One Runtime asmdef is planned'
    Assert-True -Condition (@($planOne.result.plan.files | Where-Object { $_.kind -eq 'EDITMODE_TEST_ASMDEF' }).Count -eq 1) -Message 'One EditMode test asmdef is planned'
    Assert-True -Condition (@($planOne.result.plan.files | Where-Object { $_.content -match 'TestAssemblies' }).Count -eq 1) -Message 'Test asmdef contains direct test evidence'
    foreach ($plannedMeta in @($planOne.result.plan.files | Where-Object { $_.kind -in @('FOLDER_META', 'ASMDEF_META') })) {
        Assert-True -Condition ([string]$plannedMeta.content).EndsWith("`n", [System.StringComparison]::Ordinal) -Message "Planned metadata ends with LF: $($plannedMeta.path)"
        Assert-True -Condition (-not ([string]$plannedMeta.content).EndsWith("`n`n", [System.StringComparison]::Ordinal)) -Message "Planned metadata has one terminal LF: $($plannedMeta.path)"
    }
    Assert-Equal -Expected 0 -Actual @(Invoke-JsonSchemaValidation -Instance $planOne.result -SchemaPath $script:SchemaPath).Count -Message 'Plan result satisfies schema'
    foreach ($verificationProperty in $planOne.result.verification.PSObject.Properties) {
        Assert-Equal -Expected 'NOT_VERIFIED' -Actual $verificationProperty.Value.status -Message "$($verificationProperty.Name) remains NOT_VERIFIED"
    }

    $missingHash = Invoke-ScaffoldCase -ProjectRoot $planProject -AdditionalArguments @('-Apply')
    Assert-Equal -Expected 'SCAFFOLD_BLOCKED' -Actual $missingHash.result.finalStatus -Message 'Apply without hash is blocked'
    Assert-True -Condition (@($missingHash.result.blockers | Where-Object { $_.code -eq 'PLAN_CONFIRMATION_REQUIRED' }).Count -eq 1) -Message 'Missing hash blocker is exact'
    Assert-Equal -Expected $planBefore -Actual (Get-TestTreeSnapshot -Root $planProject) -Message 'Missing hash writes nothing'

    $wrongHash = Invoke-ScaffoldCase -ProjectRoot $planProject -AdditionalArguments @('-Apply', '-ExpectedPlanSha256', ('0' * 64))
    Assert-Equal -Expected 'SCAFFOLD_BLOCKED' -Actual $wrongHash.result.finalStatus -Message 'Wrong hash is blocked'
    Assert-True -Condition (@($wrongHash.result.blockers | Where-Object { $_.code -eq 'PLAN_HASH_MISMATCH' }).Count -eq 1) -Message 'Wrong hash blocker is exact'
    Assert-Equal -Expected $planBefore -Actual (Get-TestTreeSnapshot -Root $planProject) -Message 'Wrong hash writes nothing'

    $beforeApplySnapshot = Get-UnityCopySetSnapshot -ProjectRoot $planProject
    $applied = Invoke-ScaffoldCase -ProjectRoot $planProject -AdditionalArguments @('-Apply', '-ExpectedPlanSha256', [string]$planOne.result.plan.planSha256)
    Assert-Equal -Expected 0 -Actual $applied.exitCode -Message 'Confirmed apply exits successfully'
    Assert-Equal -Expected 'SCAFFOLD_APPLIED' -Actual $applied.result.finalStatus -Message 'Confirmed apply succeeds'
    Assert-True -Condition ([bool]$applied.result.apply.confirmationMatched) -Message 'Apply records the hash match'
    Assert-True -Condition ([bool]$applied.result.apply.postconditionVerified) -Message 'Apply verifies exact postcondition'
    Assert-Equal -Expected 6 -Actual @($applied.result.apply.createdFiles).Count -Message 'Apply creates exactly planned files'
    Assert-Equal -Expected 2 -Actual @($applied.result.apply.createdDirectories).Count -Message 'Apply creates exactly planned directories'
    $afterApplySnapshot = Get-UnityCopySetSnapshot -ProjectRoot $planProject
    $independentDelta = Get-UtsSnapshotDelta -Before $beforeApplySnapshot -After $afterApplySnapshot
    $independentDeltaCheck = Test-UtsExpectedDelta -Delta $independentDelta -After $afterApplySnapshot -ExpectedFiles $planOne.result.plan.files -ExpectedDirectories $planOne.result.plan.directories
    Assert-True -Condition ([bool]$independentDeltaCheck.accepted) -Message 'Independent snapshot proves only planned content was added'
    Assert-Equal -Expected 0 -Actual @(Invoke-JsonSchemaValidation -Instance $applied.result -SchemaPath $script:SchemaPath).Count -Message 'Apply result satisfies schema'
    foreach ($createdMetaPath in @($applied.result.apply.createdFiles | Where-Object { $_ -match '(?i)\.meta$' })) {
        $createdMetaBytes = [System.IO.File]::ReadAllBytes((Join-Path $planProject ([string]$createdMetaPath).Replace('/', '\')))
        Assert-Equal -Expected 10 -Actual ([int]$createdMetaBytes[$createdMetaBytes.Length - 1]) -Message "Applied metadata ends with LF: $createdMetaPath"
    }

    $doctor = Invoke-DoctorCase -ProjectRoot $planProject
    Assert-True -Condition (@($doctor.assemblies.confirmedTestAssemblies).Count -eq 1) -Message 'Doctor confirms the generated test asmdef'
    Assert-Equal -Expected $applied.result.tests.assemblyName -Actual $doctor.assemblies.confirmedTestAssemblies[0].name -Message 'Doctor confirms the exact generated test assembly name'
    $already = Invoke-ScaffoldCase -ProjectRoot $planProject
    Assert-Equal -Expected 'SCAFFOLD_ALREADY_CONFIGURED' -Actual $already.result.finalStatus -Message 'Rerun detects compatible existing configuration'
    Assert-Equal -Expected 0 -Actual @($already.result.plan.files).Count -Message 'Configured rerun plans no files'

    $missingPackageProject = New-TestProjectCopy -Name 'missing-package'
    Write-TestText -Path (Join-Path $missingPackageProject 'Packages\manifest.json') -Content "{`n  `"dependencies`": {}`n}`n"
    $missingPackageBefore = Get-TestTreeSnapshot -Root $missingPackageProject
    $missingPackage = Invoke-ScaffoldCase -ProjectRoot $missingPackageProject
    Assert-Equal -Expected 'SCAFFOLD_BLOCKED' -Actual $missingPackage.result.finalStatus -Message 'Missing Test Framework blocks'
    Assert-True -Condition (@($missingPackage.result.blockers | Where-Object { $_.code -eq 'TEST_FRAMEWORK_NOT_DECLARED' }).Count -eq 1) -Message 'Missing package blocker is exact'
    Assert-Equal -Expected $missingPackageBefore -Actual (Get-TestTreeSnapshot -Root $missingPackageProject) -Message 'Missing package block writes nothing'

    $ambiguousProject = New-TestProjectCopy -Name 'ambiguous-runtime'
    Write-TestText -Path (Join-Path $ambiguousProject 'Assets\Other\Runtime\Other.cs') -Content "public sealed class Other { }`n"
    $ambiguous = Invoke-ScaffoldCase -ProjectRoot $ambiguousProject
    Assert-Equal -Expected 'SCAFFOLD_BLOCKED' -Actual $ambiguous.result.finalStatus -Message 'Ambiguous Runtime roots block inference'
    Assert-True -Condition (@($ambiguous.result.blockers | Where-Object { $_.code -eq 'RUNTIME_SOURCE_ROOT_AMBIGUOUS' }).Count -eq 1) -Message 'Ambiguous Runtime blocker is exact'
    $explicit = Invoke-ScaffoldCase -ProjectRoot $ambiguousProject -AdditionalArguments @('-RuntimeSourceRoot', 'Assets/_Project/Scripts/Runtime')
    Assert-Equal -Expected 'SCAFFOLD_PLAN_READY' -Actual $explicit.result.finalStatus -Message 'Explicit Runtime root resolves ambiguity'
    Assert-Equal -Expected 'EXPLICIT' -Actual $explicit.result.runtime.resolution -Message 'Explicit resolution is recorded'

    $escapeProject = New-TestProjectCopy -Name 'path-escape'
    $escapeBefore = Get-TestTreeSnapshot -Root $escapeProject
    $escaped = Invoke-ScaffoldCase -ProjectRoot $escapeProject -AdditionalArguments @('-TestRoot', '..\outside-tests')
    Assert-Equal -Expected 'SCAFFOLD_BLOCKED' -Actual $escaped.result.finalStatus -Message 'Out-of-project TestRoot is blocked'
    Assert-Equal -Expected $escapeBefore -Actual (Get-TestTreeSnapshot -Root $escapeProject) -Message 'Path escape writes nothing'

    $collisionProject = New-TestProjectCopy -Name 'collision-project'
    $collisionName = 'collisionproject.Runtime.asmdef'
    Write-TestText -Path (Join-Path $collisionProject "Assets\_Project\Scripts\Runtime\$collisionName") -Content "{ malformed`n"
    $collisionBefore = Get-TestTreeSnapshot -Root $collisionProject
    $collision = Invoke-ScaffoldCase -ProjectRoot $collisionProject
    Assert-Equal -Expected 'SCAFFOLD_BLOCKED' -Actual $collision.result.finalStatus -Message 'Existing malformed asmdef blocks'
    Assert-Equal -Expected $collisionBefore -Actual (Get-TestTreeSnapshot -Root $collisionProject) -Message 'Collision path is never overwritten'

    $nameCollisionProject = New-TestProjectCopy -Name 'name-collision'
    Write-TestText -Path (Join-Path $nameCollisionProject 'Assets\Other\Existing.asmdef') -Content "{`n  `"name`": `"namecollision.Runtime`"`n}`n"
    $nameCollisionBefore = Get-TestTreeSnapshot -Root $nameCollisionProject
    $nameCollision = Invoke-ScaffoldCase -ProjectRoot $nameCollisionProject
    Assert-Equal -Expected 'SCAFFOLD_BLOCKED' -Actual $nameCollision.result.finalStatus -Message 'Global assembly-name collision blocks the plan'
    Assert-True -Condition (@($nameCollision.result.blockers | Where-Object { $_.code -eq 'ASSEMBLY_INVENTORY_UNSAFE' }).Count -eq 1) -Message 'Assembly-name collision blocker is exact'
    Assert-Equal -Expected $nameCollisionBefore -Actual (Get-TestTreeSnapshot -Root $nameCollisionProject) -Message 'Assembly-name collision writes nothing'

    $rollbackRoot = Join-Path $script:ScratchRoot 'rollback-transaction'
    [void][System.IO.Directory]::CreateDirectory($rollbackRoot)
    $rollbackFiles = @(
        [pscustomobject]@{ path = 'a.txt'; content = 'a' },
        [pscustomobject]@{ path = 'b.txt'; content = 'b' }
    )
    $rollbackWriter = {
        param($Path, $Content)
        if ([System.IO.Path]::GetFileName($Path) -eq 'b.txt') { throw 'injected write failure' }
        Write-UtsNewFile -Path $Path -Content $Content
    }
    $rollback = Invoke-UtsTransactionalWrites -ProjectRoot $rollbackRoot -Files $rollbackFiles -FileWriter $rollbackWriter
    Assert-Equal -Expected $false -Actual $rollback.succeeded -Message 'Injected transaction fails'
    Assert-True -Condition ([bool]$rollback.rollback.completed) -Message 'Injected transaction rolls back created files'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $rollbackRoot 'a.txt'))) -Message 'Rollback removes only the first created file'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $rollbackRoot 'b.txt'))) -Message 'Rollback leaves no failed target'

    $skillText = Get-Content -Raw -LiteralPath (Join-Path $script:SkillRoot 'SKILL.md')
    $metadataText = Get-Content -Raw -LiteralPath (Join-Path $script:SkillRoot 'agents\openai.yaml')
    Assert-True -Condition ($skillText -match '^---\s*\r?\nname:\s+unity-test-scaffold') -Message 'Skill frontmatter name is valid'
    Assert-True -Condition $skillText.Contains('$unity-test-scaffold') -Message 'Skill requires literal invocation'
    Assert-True -Condition ($metadataText -match 'allow_implicit_invocation:\s*false') -Message 'Skill remains explicit-only'
    Assert-Equal -Expected '0.1.0' -Actual (Get-Content -Raw -LiteralPath (Join-Path $script:SkillRoot 'VERSION')).Trim() -Message 'Component version is 0.1.0'

    $whatIfDestination = Join-Path $script:ScratchRoot 'installer-whatif\skills'
    & $script:InstallerPath -DestinationRoot $whatIfDestination -WhatIf | Out-Null
    Assert-True -Condition (-not (Test-Path -LiteralPath $whatIfDestination)) -Message 'Installer WhatIf creates no destination'
    if (Test-SymbolicLinkCapability) {
        $installDestination = Join-Path $script:ScratchRoot 'installer\skills'
        & $script:InstallerPath -DestinationRoot $installDestination | Out-Null
        $scaffoldLink = Join-Path $installDestination 'unity-test-scaffold'
        Assert-True -Condition (Test-Path -LiteralPath $scaffoldLink -PathType Container) -Message 'Installer discovers and links Test Scaffold'
        Assert-Equal -Expected 'SymbolicLink' -Actual (Get-Item -LiteralPath $scaffoldLink -Force).LinkType -Message 'Test Scaffold installation is a symbolic link'
        & $script:InstallerPath -DestinationRoot $installDestination | Out-Null
        Assert-Equal -Expected 'SymbolicLink' -Actual (Get-Item -LiteralPath $scaffoldLink -Force).LinkType -Message 'Test Scaffold installer rerun is idempotent'
    } else {
        Write-Host 'Symbolic-link creation tests skipped because this token lacks the required Windows privilege.'
    }
    $conflictDestination = Join-Path $script:ScratchRoot 'installer-conflict\skills'
    $conflictPath = Join-Path $conflictDestination 'unity-test-scaffold'
    Write-TestText -Path (Join-Path $conflictPath 'marker.txt') -Content 'preserve'
    $conflictThrown = $false
    try {
        & $script:InstallerPath -DestinationRoot $conflictDestination -WarningAction SilentlyContinue | Out-Null
    } catch {
        $conflictThrown = $true
    }
    Assert-True -Condition $conflictThrown -Message 'Installer refuses an existing Test Scaffold conflict'
    Assert-Equal -Expected 'preserve' -Actual ([System.IO.File]::ReadAllText((Join-Path $conflictPath 'marker.txt'), $script:Utf8NoBom)) -Message 'Installer preserves the conflicting path'

    foreach ($powerShellFile in @(Get-ChildItem -LiteralPath $script:SkillRoot -Filter '*.ps1' -File -Recurse)) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($powerShellFile.FullName, [ref]$tokens, [ref]$parseErrors)
        Assert-Equal -Expected 0 -Actual $parseErrors.Count -Message "PowerShell parses: $($powerShellFile.FullName)"
    }

    Assert-Equal -Expected $fixtureBefore -Actual (Get-TestTreeSnapshot -Root $script:FixtureRoot) -Message 'Committed fixture remains byte-for-byte unchanged'
    Assert-Equal -Expected $repositoryBefore -Actual (Get-TestTreeSnapshot -Root $script:RepositoryRoot) -Message 'Tests leave the repository byte-for-byte unchanged'
    Write-Host "Unity Test Scaffold tests passed. Assertions: $script:Assertions"
} finally {
    $normalizedScratch = [System.IO.Path]::GetFullPath($script:ScratchRoot)
    $normalizedTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($normalizedScratch.StartsWith($normalizedTemp, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $normalizedScratch -PathType Container)) {
        Remove-Item -LiteralPath $normalizedScratch -Recurse -Force
    }
}
