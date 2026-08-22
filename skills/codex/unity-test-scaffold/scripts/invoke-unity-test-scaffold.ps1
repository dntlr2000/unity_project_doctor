[CmdletBinding()]
param(
    [Parameter()]
    [string]$ProjectRoot = (Get-Location).Path,

    [Parameter()]
    [string]$RuntimeSourceRoot,

    [Parameter()]
    [string]$RuntimeAssemblyName,

    [Parameter()]
    [string]$TestRoot,

    [Parameter()]
    [string]$TestAssemblyName,

    [Parameter()]
    [switch]$Apply,

    [Parameter()]
    [string]$ExpectedPlanSha256,

    [Parameter()]
    [switch]$Pretty
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:UtsSchemaVersion = '1.0.0'
$script:UtsScaffoldVersion = '0.1.0'
$script:UtsScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:UtsSkillRoot = Split-Path -Parent $script:UtsScriptRoot
$script:UtsRepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $script:UtsScriptRoot '..\..\..\..'))
$script:UtsSchemaPath = Join-Path $script:UtsRepositoryRoot 'schemas\unity-test-scaffold-result-1.0.0.schema.json'
$script:UtsCorePath = Join-Path $script:UtsScriptRoot 'lib\unity-test-scaffold-core.ps1'
$script:UtsFingerprintPath = Join-Path $script:UtsScriptRoot '..\..\unity-project-doctor\scripts\lib\unity-project-fingerprint.ps1'
$script:UtsSchemaValidatorPath = Join-Path $script:UtsScriptRoot '..\..\unity-baseline-verification\scripts\lib\json-schema-validator.ps1'

. $script:UtsCorePath
. $script:UtsFingerprintPath
. $script:UtsSchemaValidatorPath

# Creates one stable structured finding for warnings and blockers.
function New-UtsFinding {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Check,
        [Parameter()][AllowNull()][object]$Path,
        [Parameter(Mandatory = $true)][string]$Message
    )

    return [pscustomobject][ordered]@{
        code = $Code
        check = $Check
        path = $Path
        message = $Message
    }
}

# Creates one stable evidence record without claiming unperformed Unity validation.
function New-UtsEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Check,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter()][AllowNull()][object]$Path,
        [Parameter(Mandatory = $true)][string]$Message
    )

    return [pscustomobject][ordered]@{
        check = $Check
        status = $Status
        path = $Path
        message = $Message
    }
}

# Creates the complete default result shape used by both success and blocked paths.
function New-UtsResult {
    param(
        [Parameter()][AllowNull()][object]$NormalizedProjectRoot,
        [Parameter(Mandatory = $true)][bool]$ApplyRequested
    )

    return [pscustomobject][ordered]@{
        schemaVersion = $script:UtsSchemaVersion
        scaffoldVersion = $script:UtsScaffoldVersion
        projectRoot = $NormalizedProjectRoot
        mode = if ($ApplyRequested) { 'APPLY' } else { 'PLAN' }
        projectDetection = [pscustomobject][ordered]@{
            isUnityProject = $false
            assetsDirectoryExists = $false
            manifestExists = $false
            projectVersionExists = $false
        }
        testFramework = [pscustomobject][ordered]@{
            manifestParseStatus = 'NOT_CHECKED'
            directDependencyPresent = $false
            declaredVersion = $null
        }
        runtime = [pscustomobject][ordered]@{
            resolution = 'NOT_RESOLVED'
            candidates = @()
            sourceRoot = $null
            assemblyName = $null
            asmdefPath = $null
            asmdefSource = 'NONE'
        }
        tests = [pscustomobject][ordered]@{
            root = $null
            assemblyName = $null
            asmdefPath = $null
            asmdefSource = 'NONE'
            testFileCreated = $false
        }
        preconditionFingerprint = [pscustomobject][ordered]@{
            status = 'NOT_COMPUTED'
            algorithm = 'SHA-256'
            directoryCount = 0
            fileCount = 0
            treeSha256 = $null
        }
        plan = [pscustomobject][ordered]@{
            status = 'NOT_READY'
            contractVersion = '1.0.0'
            planSha256 = $null
            requiresConfirmation = $false
            directories = @()
            files = @()
        }
        apply = [pscustomobject][ordered]@{
            requested = $ApplyRequested
            expectedPlanSha256 = $null
            confirmationMatched = $false
            attempted = $false
            succeeded = $false
            createdDirectories = @()
            createdFiles = @()
            postconditionVerified = $false
            postconditionFingerprint = $null
            delta = $null
            rollback = [pscustomobject][ordered]@{
                attempted = $false
                completed = $false
                removedFiles = @()
                removedDirectories = @()
                errors = @()
            }
        }
        verification = [pscustomobject][ordered]@{
            scriptCompilation = [pscustomobject][ordered]@{ status = 'NOT_VERIFIED'; reason = 'This scaffold does not run Unity compilation.' }
            editModeTests = [pscustomobject][ordered]@{ status = 'NOT_VERIFIED'; reason = 'This scaffold does not create or run test methods.' }
            playMode = [pscustomobject][ordered]@{ status = 'NOT_VERIFIED'; reason = 'PlayMode is outside the scaffold scope.' }
            playerBuild = [pscustomobject][ordered]@{ status = 'NOT_VERIFIED'; reason = 'Player Build is outside the scaffold scope.' }
            runtime = [pscustomobject][ordered]@{ status = 'NOT_VERIFIED'; reason = 'Runtime behavior is outside the scaffold scope.' }
        }
        warnings = @()
        blockers = @()
        finalStatus = 'SCAFFOLD_BLOCKED'
        evidence = @()
    }
}

# Copies mutable finding and evidence lists into JSON-array-compatible properties.
function Complete-UtsResultCollections {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.ArrayList]$Warnings,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.ArrayList]$Blockers,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.ArrayList]$Evidence
    )

    $Result.warnings = [object[]]@($Warnings.ToArray())
    $Result.blockers = [object[]]@($Blockers.ToArray())
    $Result.evidence = [object[]]@($Evidence.ToArray())
    return $Result
}

# Tests whether one copy-set snapshot contains a C# source below a selected directory.
function Test-UtsSnapshotContainsCsSource {
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][string]$RelativeDirectory
    )

    $prefix = $RelativeDirectory.TrimEnd('/') + '/'
    return @($Snapshot.files | Where-Object {
        ([string]$_.path).StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -and
        ([string]$_.path).EndsWith('.cs', [System.StringComparison]::OrdinalIgnoreCase)
    }).Count -gt 0
}

# Derives a conventional Tests/EditMode path near the selected Runtime source directory.
function Get-UtsDefaultTestRoot {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRelativeRoot
    )

    $segments = @($RuntimeRelativeRoot.Replace('\', '/').Split('/'))
    if ($segments.Count -lt 2) {
        return 'Assets/Tests/EditMode'
    }
    $parentSegments = @($segments[0..($segments.Count - 2)])
    if ($parentSegments.Count -gt 1 -and $parentSegments[-1] -ieq 'Scripts') {
        $parentSegments = @($parentSegments[0..($parentSegments.Count - 2)])
    }
    return [string]::Join('/', [string[]](@($parentSegments) + @('Tests', 'EditMode')))
}

# Adds one planned file after proving that it does not already exist.
function Add-UtsPlannedFile {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.ArrayList]$Files,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $fullPath = Resolve-UtsProjectPath -Path $Path -ProjectRoot $ProjectRoot
    if (Test-Path -LiteralPath $fullPath) {
        throw "A planned scaffold path already exists and will not be overwritten: $Path"
    }
    [void]$Files.Add([pscustomobject][ordered]@{
        path = $Path.Replace('\', '/')
        kind = $Kind
        sha256 = Get-UtsTextSha256 -Text $Content
        content = $Content
    })
}

# Builds the hash-bound deterministic plan identity without embedding mutable timestamps.
function Get-UtsPlanIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$PreconditionTreeSha256,
        [Parameter(Mandatory = $true)][object]$Runtime,
        [Parameter(Mandatory = $true)][object]$Tests,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Directories,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Files
    )

    return [ordered]@{
        contractVersion = '1.0.0'
        scaffoldVersion = $script:UtsScaffoldVersion
        projectRoot = $ProjectRoot
        preconditionTreeSha256 = $PreconditionTreeSha256
        runtime = [ordered]@{
            sourceRoot = $Runtime.sourceRoot
            assemblyName = $Runtime.assemblyName
            asmdefPath = $Runtime.asmdefPath
            asmdefSource = $Runtime.asmdefSource
        }
        tests = [ordered]@{
            root = $Tests.root
            assemblyName = $Tests.assemblyName
            asmdefPath = $Tests.asmdefPath
            asmdefSource = $Tests.asmdefSource
        }
        directories = [string[]]@($Directories | Sort-Object)
        files = [object[]]@($Files | Sort-Object path | ForEach-Object {
            [ordered]@{ path = $_.path; kind = $_.kind; sha256 = $_.sha256 }
        })
    }
}

# Produces the deterministic scaffold plan or applies exactly one confirmed plan.
function Invoke-UtsScaffold {
    param(
        [Parameter(Mandatory = $true)][string]$RequestedProjectRoot,
        [Parameter()][AllowNull()][string]$RequestedRuntimeSourceRoot,
        [Parameter()][AllowNull()][string]$RequestedRuntimeAssemblyName,
        [Parameter()][AllowNull()][string]$RequestedTestRoot,
        [Parameter()][AllowNull()][string]$RequestedTestAssemblyName,
        [Parameter(Mandatory = $true)][bool]$ApplyRequested,
        [Parameter()][AllowNull()][string]$ExpectedHash
    )

    $warnings = New-Object System.Collections.ArrayList
    $blockers = New-Object System.Collections.ArrayList
    $evidence = New-Object System.Collections.ArrayList
    $normalizedRoot = $null
    $transaction = $null
    try {
        $normalizedRoot = Get-UtsNormalizedPath -Path $RequestedProjectRoot
    } catch {
        $result = New-UtsResult -NormalizedProjectRoot $null -ApplyRequested $ApplyRequested
        [void]$blockers.Add((New-UtsFinding -Code 'PROJECT_ROOT_INVALID' -Check 'project-root' -Path $RequestedProjectRoot -Message $_.Exception.Message))
        return Complete-UtsResultCollections -Result $result -Warnings $warnings -Blockers $blockers -Evidence $evidence
    }

    $result = New-UtsResult -NormalizedProjectRoot $normalizedRoot -ApplyRequested $ApplyRequested
    $result.apply.expectedPlanSha256 = if ([string]::IsNullOrWhiteSpace($ExpectedHash)) { $null } else { $ExpectedHash.ToLowerInvariant() }
    try {
        $rootItem = Get-Item -LiteralPath $normalizedRoot -Force -ErrorAction Stop
        if (-not $rootItem.PSIsContainer) {
            throw 'ProjectRoot is not a directory.'
        }
        if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'ProjectRoot is a reparse point.'
        }
    } catch {
        [void]$blockers.Add((New-UtsFinding -Code 'PROJECT_ROOT_UNAVAILABLE' -Check 'project-root' -Path $normalizedRoot -Message $_.Exception.Message))
        return Complete-UtsResultCollections -Result $result -Warnings $warnings -Blockers $blockers -Evidence $evidence
    }

    $assetsPath = Join-Path $normalizedRoot 'Assets'
    $manifestPath = Join-Path $normalizedRoot 'Packages\manifest.json'
    $projectVersionPath = Join-Path $normalizedRoot 'ProjectSettings\ProjectVersion.txt'
    $result.projectDetection.assetsDirectoryExists = Test-Path -LiteralPath $assetsPath -PathType Container
    $result.projectDetection.manifestExists = Test-Path -LiteralPath $manifestPath -PathType Leaf
    $result.projectDetection.projectVersionExists = Test-Path -LiteralPath $projectVersionPath -PathType Leaf
    $result.projectDetection.isUnityProject = (
        $result.projectDetection.assetsDirectoryExists -and
        $result.projectDetection.manifestExists -and
        $result.projectDetection.projectVersionExists
    )
    if (-not $result.projectDetection.isUnityProject) {
        [void]$blockers.Add((New-UtsFinding -Code 'NOT_A_UNITY_PROJECT' -Check 'project-detection' -Path $normalizedRoot -Message 'Assets, Packages/manifest.json, and ProjectSettings/ProjectVersion.txt must all exist at the exact ProjectRoot.'))
        return Complete-UtsResultCollections -Result $result -Warnings $warnings -Blockers $blockers -Evidence $evidence
    }
    [void]$evidence.Add((New-UtsEvidence -Check 'project-detection' -Status 'PASSED' -Path $normalizedRoot -Message 'The exact root contains all required Unity project markers.'))

    try {
        $manifest = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        $result.testFramework.manifestParseStatus = 'PARSED'
        $dependencies = Get-UtsProperty -InputObject $manifest -Name 'dependencies'
        $testFrameworkVersion = Get-UtsProperty -InputObject $dependencies -Name 'com.unity.test-framework'
        if ($null -ne $testFrameworkVersion -and -not [string]::IsNullOrWhiteSpace([string]$testFrameworkVersion)) {
            $result.testFramework.directDependencyPresent = $true
            $result.testFramework.declaredVersion = [string]$testFrameworkVersion
            [void]$evidence.Add((New-UtsEvidence -Check 'test-framework' -Status 'PASSED' -Path 'Packages/manifest.json' -Message "Direct com.unity.test-framework dependency declared as $testFrameworkVersion."))
        } else {
            [void]$blockers.Add((New-UtsFinding -Code 'TEST_FRAMEWORK_NOT_DECLARED' -Check 'test-framework' -Path 'Packages/manifest.json' -Message 'The scaffold does not install packages; declare com.unity.test-framework before applying test assembly configuration.'))
        }
    } catch {
        $result.testFramework.manifestParseStatus = 'MALFORMED'
        [void]$blockers.Add((New-UtsFinding -Code 'MANIFEST_PARSE_FAILED' -Check 'test-framework' -Path 'Packages/manifest.json' -Message $_.Exception.Message))
    }
    if ($blockers.Count -gt 0) {
        return Complete-UtsResultCollections -Result $result -Warnings $warnings -Blockers $blockers -Evidence $evidence
    }

    $fingerprint = $null
    try {
        $fingerprint = Get-StableUnityCopySetFingerprint -ProjectRoot $normalizedRoot
        $result.preconditionFingerprint = [pscustomobject][ordered]@{
            status = $fingerprint.status
            algorithm = $fingerprint.algorithm
            directoryCount = $fingerprint.directoryCount
            fileCount = $fingerprint.fileCount
            treeSha256 = $fingerprint.treeSha256
        }
        [void]$evidence.Add((New-UtsEvidence -Check 'precondition-fingerprint' -Status 'COMPUTED' -Path $normalizedRoot -Message "Stable copy-set SHA-256: $($fingerprint.treeSha256)"))
    } catch {
        [void]$blockers.Add((New-UtsFinding -Code 'PROJECT_FINGERPRINT_UNAVAILABLE' -Check 'precondition-fingerprint' -Path $normalizedRoot -Message $_.Exception.Message))
        return Complete-UtsResultCollections -Result $result -Warnings $warnings -Blockers $blockers -Evidence $evidence
    }

    $runtimeCandidates = [string[]](Get-UtsRuntimeCandidates -Snapshot $fingerprint.snapshot)
    $result.runtime.candidates = $runtimeCandidates
    $runtimeFullPath = $null
    $runtimeRelativePath = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace($RequestedRuntimeSourceRoot)) {
            $runtimeFullPath = Resolve-UtsProjectPath -Path $RequestedRuntimeSourceRoot -ProjectRoot $normalizedRoot
            $result.runtime.resolution = 'EXPLICIT'
        } elseif ($runtimeCandidates.Count -eq 1) {
            $runtimeFullPath = Resolve-UtsProjectPath -Path $runtimeCandidates[0] -ProjectRoot $normalizedRoot
            $result.runtime.resolution = 'INFERRED_UNIQUE_RUNTIME_DIRECTORY'
        } elseif ($runtimeCandidates.Count -eq 0) {
            [void]$blockers.Add((New-UtsFinding -Code 'RUNTIME_SOURCE_ROOT_NOT_FOUND' -Check 'runtime-source' -Path 'Assets' -Message 'No unique Runtime directory containing C# source was found; rerun with -RuntimeSourceRoot.'))
        } else {
            [void]$blockers.Add((New-UtsFinding -Code 'RUNTIME_SOURCE_ROOT_AMBIGUOUS' -Check 'runtime-source' -Path 'Assets' -Message 'Multiple Runtime directories contain C# source; rerun with one explicit -RuntimeSourceRoot.'))
        }
        if ($blockers.Count -eq 0) {
            $runtimeRelativePath = ConvertTo-UtsRelativePath -Path $runtimeFullPath -ProjectRoot $normalizedRoot
            if (-not ($runtimeRelativePath -ieq 'Assets' -or $runtimeRelativePath.StartsWith('Assets/', [System.StringComparison]::OrdinalIgnoreCase))) {
                throw 'RuntimeSourceRoot must be inside Assets.'
            }
            if (-not (Test-Path -LiteralPath $runtimeFullPath -PathType Container)) {
                throw 'RuntimeSourceRoot must be an existing directory.'
            }
            if ($null -ne (Get-UtsReparsePointOnPath -Path $runtimeFullPath)) {
                throw 'RuntimeSourceRoot traverses a reparse point.'
            }
            if (-not (Test-UtsSnapshotContainsCsSource -Snapshot $fingerprint.snapshot -RelativeDirectory $runtimeRelativePath)) {
                throw 'RuntimeSourceRoot contains no included C# source.'
            }
            $result.runtime.sourceRoot = $runtimeRelativePath
            [void]$evidence.Add((New-UtsEvidence -Check 'runtime-source' -Status 'RESOLVED' -Path $runtimeRelativePath -Message "Runtime source root resolved by $($result.runtime.resolution)."))
        }
    } catch {
        [void]$blockers.Add((New-UtsFinding -Code 'RUNTIME_SOURCE_ROOT_UNSAFE' -Check 'runtime-source' -Path $RequestedRuntimeSourceRoot -Message $_.Exception.Message))
    }
    if ($blockers.Count -gt 0) {
        return Complete-UtsResultCollections -Result $result -Warnings $warnings -Blockers $blockers -Evidence $evidence
    }

    $projectPrefix = $null
    try {
        $projectPrefix = ConvertTo-UtsAssemblyPrefix -Value (Split-Path -Leaf $normalizedRoot)
        $owningAsmdef = Get-UtsOwningAsmdef -RuntimeRoot $runtimeFullPath -ProjectRoot $normalizedRoot
        if ($null -ne $owningAsmdef) {
            if (-not [string]::IsNullOrWhiteSpace($RequestedRuntimeAssemblyName) -and $RequestedRuntimeAssemblyName -cne $owningAsmdef.name) {
                throw "The existing owning asmdef name '$($owningAsmdef.name)' does not match -RuntimeAssemblyName '$RequestedRuntimeAssemblyName'."
            }
            $result.runtime.assemblyName = $owningAsmdef.name
            $result.runtime.asmdefPath = $owningAsmdef.path
            $result.runtime.asmdefSource = 'EXISTING'
        } else {
            $selectedRuntimeName = if ([string]::IsNullOrWhiteSpace($RequestedRuntimeAssemblyName)) { "$projectPrefix.Runtime" } else { $RequestedRuntimeAssemblyName }
            if (-not (Test-UtsAssemblyName -Name $selectedRuntimeName)) {
                throw "Unsafe RuntimeAssemblyName: $selectedRuntimeName"
            }
            $result.runtime.assemblyName = $selectedRuntimeName
            $result.runtime.asmdefPath = "$runtimeRelativePath/$selectedRuntimeName.asmdef"
            $result.runtime.asmdefSource = 'PLANNED'
            [void]$warnings.Add((New-UtsFinding -Code 'RUNTIME_ASSEMBLY_BOUNDARY_CHANGE' -Check 'runtime-asmdef' -Path $result.runtime.asmdefPath -Message 'Adding the runtime asmdef changes Unity assembly boundaries and can expose missing assembly references; review the plan and run Baseline afterward.'))
        }
    } catch {
        [void]$blockers.Add((New-UtsFinding -Code 'RUNTIME_ASMDEF_UNAVAILABLE' -Check 'runtime-asmdef' -Path $runtimeRelativePath -Message $_.Exception.Message))
        return Complete-UtsResultCollections -Result $result -Warnings $warnings -Blockers $blockers -Evidence $evidence
    }

    $testFullPath = $null
    $testRelativePath = $null
    try {
        if ([string]::IsNullOrWhiteSpace($RequestedTestRoot)) {
            $testRelativePath = Get-UtsDefaultTestRoot -RuntimeRelativeRoot $runtimeRelativePath
            $testFullPath = Resolve-UtsProjectPath -Path $testRelativePath -ProjectRoot $normalizedRoot
        } else {
            $testFullPath = Resolve-UtsProjectPath -Path $RequestedTestRoot -ProjectRoot $normalizedRoot
            $testRelativePath = ConvertTo-UtsRelativePath -Path $testFullPath -ProjectRoot $normalizedRoot
        }
        if (-not $testRelativePath.StartsWith('Assets/', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'TestRoot must be below Assets.'
        }
        if (Test-UtsPathWithinRoot -Path $testFullPath -Root $runtimeFullPath) {
            throw 'TestRoot must not be inside RuntimeSourceRoot.'
        }
        if ((Test-Path -LiteralPath $testFullPath) -and -not (Test-Path -LiteralPath $testFullPath -PathType Container)) {
            throw 'TestRoot exists but is not a directory.'
        }
        $existingTestRootAncestor = $testFullPath
        while (-not (Test-Path -LiteralPath $existingTestRootAncestor)) {
            $parent = [System.IO.Directory]::GetParent($existingTestRootAncestor)
            if ($null -eq $parent) { throw 'TestRoot has no safe existing ancestor.' }
            $existingTestRootAncestor = $parent.FullName
        }
        if ($null -ne (Get-UtsReparsePointOnPath -Path $existingTestRootAncestor)) {
            throw 'TestRoot traverses a reparse point.'
        }
        $result.tests.root = $testRelativePath
        $selectedTestName = if ([string]::IsNullOrWhiteSpace($RequestedTestAssemblyName)) { "$projectPrefix.EditModeTests" } else { $RequestedTestAssemblyName }
        if (-not (Test-UtsAssemblyName -Name $selectedTestName)) {
            throw "Unsafe TestAssemblyName: $selectedTestName"
        }

        $existingTestAsmdefs = @(if (Test-Path -LiteralPath $testFullPath -PathType Container) {
            Get-ChildItem -LiteralPath $testFullPath -Filter '*.asmdef' -File -Force -ErrorAction Stop | Sort-Object Name
        })
        if ($existingTestAsmdefs.Count -gt 1) {
            throw 'TestRoot contains multiple asmdef files and is ambiguous.'
        }
        if ($existingTestAsmdefs.Count -eq 1) {
            $existingTest = Test-UtsExistingTestAsmdef -Path $existingTestAsmdefs[0].FullName -RuntimeAssemblyName $result.runtime.assemblyName
            if (-not $existingTest.accepted) {
                $reason = if ([string]::IsNullOrWhiteSpace([string]$existingTest.error)) { 'Existing asmdef is not an Editor-only test assembly referencing the selected runtime assembly.' } else { $existingTest.error }
                throw $reason
            }
            if (-not [string]::IsNullOrWhiteSpace($RequestedTestAssemblyName) -and $RequestedTestAssemblyName -cne $existingTest.name) {
                throw "Existing test asmdef name '$($existingTest.name)' does not match -TestAssemblyName '$RequestedTestAssemblyName'."
            }
            $result.tests.assemblyName = $existingTest.name
            $result.tests.asmdefPath = ConvertTo-UtsRelativePath -Path $existingTestAsmdefs[0].FullName -ProjectRoot $normalizedRoot
            $result.tests.asmdefSource = 'EXISTING'
        } else {
            $result.tests.assemblyName = $selectedTestName
            $result.tests.asmdefPath = "$testRelativePath/$selectedTestName.asmdef"
            $result.tests.asmdefSource = 'PLANNED'
        }
    } catch {
        [void]$blockers.Add((New-UtsFinding -Code 'TEST_ASMDEF_UNAVAILABLE' -Check 'test-asmdef' -Path $RequestedTestRoot -Message $_.Exception.Message))
        return Complete-UtsResultCollections -Result $result -Warnings $warnings -Blockers $blockers -Evidence $evidence
    }

    try {
        $asmdefInventory = @(Get-UtsAsmdefInventory -Snapshot $fingerprint.snapshot -ProjectRoot $normalizedRoot)
        $malformedAsmdefs = @($asmdefInventory | Where-Object { $_.parseStatus -ne 'PARSED' })
        if ($malformedAsmdefs.Count -gt 0) {
            throw "An existing Assembly Definition cannot be safely parsed: $($malformedAsmdefs[0].path)"
        }
        $duplicateGroup = @($asmdefInventory | Group-Object -Property { ([string]$_.name).ToUpperInvariant() } | Where-Object { $_.Count -gt 1 } | Sort-Object Name | Select-Object -First 1)
        if ($duplicateGroup.Count -gt 0) {
            throw "Existing Assembly Definition names are duplicated: $($duplicateGroup[0].Group[0].name)"
        }
        if ($result.runtime.assemblyName -ieq $result.tests.assemblyName) {
            throw 'Runtime and EditMode test assembly names must be distinct.'
        }
        foreach ($selection in @(
            [pscustomobject]@{ role = 'Runtime'; name = $result.runtime.assemblyName; path = $result.runtime.asmdefPath; source = $result.runtime.asmdefSource },
            [pscustomobject]@{ role = 'EditMode test'; name = $result.tests.assemblyName; path = $result.tests.asmdefPath; source = $result.tests.asmdefSource }
        )) {
            $matches = @($asmdefInventory | Where-Object { $_.name -ieq $selection.name })
            if ($selection.source -eq 'PLANNED' -and $matches.Count -gt 0) {
                throw "$($selection.role) assembly name '$($selection.name)' already exists at $($matches[0].path)."
            }
            if ($selection.source -eq 'EXISTING' -and @($matches | Where-Object { $_.path -ine $selection.path }).Count -gt 0) {
                throw "$($selection.role) assembly name '$($selection.name)' is also declared by another asmdef."
            }
        }
    } catch {
        [void]$blockers.Add((New-UtsFinding -Code 'ASSEMBLY_INVENTORY_UNSAFE' -Check 'assembly-inventory' -Path 'Assets' -Message $_.Exception.Message))
        return Complete-UtsResultCollections -Result $result -Warnings $warnings -Blockers $blockers -Evidence $evidence
    }

    $plannedFiles = New-Object System.Collections.ArrayList
    try {
        if ($result.runtime.asmdefSource -eq 'PLANNED') {
            $runtimeContent = New-UtsRuntimeAsmdefContent -AssemblyName $result.runtime.assemblyName -RootNamespace $projectPrefix
            Add-UtsPlannedFile -Files $plannedFiles -ProjectRoot $normalizedRoot -Path $result.runtime.asmdefPath -Kind 'RUNTIME_ASMDEF' -Content $runtimeContent
        }
        if ($result.tests.asmdefSource -eq 'PLANNED') {
            $testContent = New-UtsEditModeAsmdefContent -AssemblyName $result.tests.assemblyName -RootNamespace "$projectPrefix.Tests.EditMode" -RuntimeAssemblyName $result.runtime.assemblyName
            Add-UtsPlannedFile -Files $plannedFiles -ProjectRoot $normalizedRoot -Path $result.tests.asmdefPath -Kind 'EDITMODE_TEST_ASMDEF' -Content $testContent
        }

        $assetFilePaths = [string[]]@($plannedFiles | ForEach-Object { [string]$_.path })
        $plannedDirectories = [string[]](Get-UtsMissingDirectories -ProjectRoot $normalizedRoot -FilePaths $assetFilePaths)
        $existingGuids = Get-UtsExistingMetaGuids -Snapshot $fingerprint.snapshot -ProjectRoot $normalizedRoot
        $reservedGuids = @{}
        foreach ($directory in $plannedDirectories) {
            $metaPath = "$directory.meta"
            $guid = Get-UtsDeterministicGuid -Seed "folder|$projectPrefix|$metaPath" -ExistingGuids $existingGuids -ReservedGuids $reservedGuids
            $metaContent = New-UtsMetaContent -Guid $guid -Kind 'Folder'
            Add-UtsPlannedFile -Files $plannedFiles -ProjectRoot $normalizedRoot -Path $metaPath -Kind 'FOLDER_META' -Content $metaContent
        }
        foreach ($asmdefFile in @($plannedFiles | Where-Object { $_.kind -in @('RUNTIME_ASMDEF', 'EDITMODE_TEST_ASMDEF') })) {
            $metaPath = "$($asmdefFile.path).meta"
            $guid = Get-UtsDeterministicGuid -Seed "asmdef|$projectPrefix|$metaPath" -ExistingGuids $existingGuids -ReservedGuids $reservedGuids
            $metaContent = New-UtsMetaContent -Guid $guid -Kind 'AssemblyDefinition'
            Add-UtsPlannedFile -Files $plannedFiles -ProjectRoot $normalizedRoot -Path $metaPath -Kind 'ASMDEF_META' -Content $metaContent
        }

        $sortedFiles = [object[]]@($plannedFiles | Sort-Object path)
        $sortedDirectories = [string[]]@($plannedDirectories | Sort-Object @{ Expression = { @($_.Split('/')).Count } }, @{ Expression = { $_ } })
        $planIdentity = Get-UtsPlanIdentity -ProjectRoot $normalizedRoot -PreconditionTreeSha256 $fingerprint.treeSha256 -Runtime $result.runtime -Tests $result.tests -Directories $sortedDirectories -Files $sortedFiles
        $planHash = Get-UtsTextSha256 -Text (ConvertTo-UtsJsonFileText -InputObject $planIdentity)
        $result.plan = [pscustomobject][ordered]@{
            status = if ($sortedFiles.Count -eq 0) { 'ALREADY_CONFIGURED' } else { 'READY' }
            contractVersion = '1.0.0'
            planSha256 = $planHash
            requiresConfirmation = $sortedFiles.Count -gt 0
            directories = $sortedDirectories
            files = $sortedFiles
        }
        [void]$warnings.Add((New-UtsFinding -Code 'TEST_IMPLEMENTATION_REQUIRED' -Check 'test-implementation' -Path $testRelativePath -Message 'The scaffold deliberately creates no passing test; add meaningful EditMode test code before requesting EditMode verification.'))
        [void]$evidence.Add((New-UtsEvidence -Check 'scaffold-plan' -Status $result.plan.status -Path $normalizedRoot -Message "Deterministic plan SHA-256: $planHash"))
    } catch {
        [void]$blockers.Add((New-UtsFinding -Code 'SCAFFOLD_PLAN_FAILED' -Check 'scaffold-plan' -Path $normalizedRoot -Message $_.Exception.Message))
        return Complete-UtsResultCollections -Result $result -Warnings $warnings -Blockers $blockers -Evidence $evidence
    }

    if ($result.plan.status -eq 'ALREADY_CONFIGURED') {
        $result.finalStatus = 'SCAFFOLD_ALREADY_CONFIGURED'
        return Complete-UtsResultCollections -Result $result -Warnings $warnings -Blockers $blockers -Evidence $evidence
    }
    if (-not $ApplyRequested) {
        $result.finalStatus = 'SCAFFOLD_PLAN_READY'
        return Complete-UtsResultCollections -Result $result -Warnings $warnings -Blockers $blockers -Evidence $evidence
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedHash)) {
        [void]$blockers.Add((New-UtsFinding -Code 'PLAN_CONFIRMATION_REQUIRED' -Check 'plan-confirmation' -Path $null -Message 'Apply requires -ExpectedPlanSha256 from a reviewed PLAN result.'))
        return Complete-UtsResultCollections -Result $result -Warnings $warnings -Blockers $blockers -Evidence $evidence
    }
    if ($ExpectedHash -cnotmatch '^[0-9a-fA-F]{64}$' -or $ExpectedHash.ToLowerInvariant() -cne $result.plan.planSha256) {
        [void]$blockers.Add((New-UtsFinding -Code 'PLAN_HASH_MISMATCH' -Check 'plan-confirmation' -Path $null -Message 'ExpectedPlanSha256 does not match the current project state and deterministic plan.'))
        return Complete-UtsResultCollections -Result $result -Warnings $warnings -Blockers $blockers -Evidence $evidence
    }
    $result.apply.confirmationMatched = $true

    try {
        $immediateFingerprint = Get-StableUnityCopySetFingerprint -ProjectRoot $normalizedRoot
        if ($immediateFingerprint.treeSha256 -cne $fingerprint.treeSha256) {
            [void]$blockers.Add((New-UtsFinding -Code 'PROJECT_CHANGED_BEFORE_APPLY' -Check 'apply-precondition' -Path $normalizedRoot -Message 'The copy-set fingerprint changed after plan construction; no files were written.'))
            return Complete-UtsResultCollections -Result $result -Warnings $warnings -Blockers $blockers -Evidence $evidence
        }

        $result.apply.attempted = $true
        $transaction = Invoke-UtsTransactionalWrites -ProjectRoot $normalizedRoot -Files $result.plan.files -Directories $result.plan.directories
        $result.apply.createdDirectories = [string[]]@($transaction.createdDirectories)
        $result.apply.createdFiles = [string[]]@($transaction.createdFiles)
        $result.apply.rollback = $transaction.rollback
        if (-not $transaction.succeeded) {
            [void]$blockers.Add((New-UtsFinding -Code 'SCAFFOLD_WRITE_FAILED' -Check 'apply-transaction' -Path $normalizedRoot -Message $transaction.error))
            if ($transaction.rollback.attempted -and -not $transaction.rollback.completed) {
                $result.finalStatus = 'PROJECT_CHANGED_DURING_APPLY'
            }
            return Complete-UtsResultCollections -Result $result -Warnings $warnings -Blockers $blockers -Evidence $evidence
        }

        $afterFingerprint = Get-StableUnityCopySetFingerprint -ProjectRoot $normalizedRoot
        $delta = Get-UtsSnapshotDelta -Before $fingerprint.snapshot -After $afterFingerprint.snapshot
        $deltaCheck = Test-UtsExpectedDelta -Delta $delta -After $afterFingerprint.snapshot -ExpectedFiles $result.plan.files -ExpectedDirectories $result.plan.directories
        $result.apply.delta = $delta
        $result.apply.postconditionFingerprint = [pscustomobject][ordered]@{
            status = $afterFingerprint.status
            algorithm = $afterFingerprint.algorithm
            directoryCount = $afterFingerprint.directoryCount
            fileCount = $afterFingerprint.fileCount
            treeSha256 = $afterFingerprint.treeSha256
        }
        if (-not $deltaCheck.accepted) {
            $result.apply.rollback = Undo-UtsCreatedEntries -ProjectRoot $normalizedRoot -CreatedFiles $result.apply.createdFiles -CreatedDirectories $result.apply.createdDirectories
            [void]$blockers.Add((New-UtsFinding -Code 'UNEXPECTED_PROJECT_DELTA' -Check 'apply-postcondition' -Path $normalizedRoot -Message 'The post-apply project delta did not exactly match planned paths and content; created entries were rolled back.'))
            $result.finalStatus = 'PROJECT_CHANGED_DURING_APPLY'
            return Complete-UtsResultCollections -Result $result -Warnings $warnings -Blockers $blockers -Evidence $evidence
        }
        $result.apply.succeeded = $true
        $result.apply.postconditionVerified = $true
        $result.finalStatus = 'SCAFFOLD_APPLIED'
        [void]$evidence.Add((New-UtsEvidence -Check 'apply-postcondition' -Status 'PASSED' -Path $normalizedRoot -Message 'Only the reviewed planned directories and exact file contents were added.'))
        return Complete-UtsResultCollections -Result $result -Warnings $warnings -Blockers $blockers -Evidence $evidence
    } catch {
        if ($null -ne $transaction -and $transaction.succeeded -and -not $result.apply.postconditionVerified) {
            $result.apply.rollback = Undo-UtsCreatedEntries -ProjectRoot $normalizedRoot -CreatedFiles $result.apply.createdFiles -CreatedDirectories $result.apply.createdDirectories
            $result.finalStatus = 'PROJECT_CHANGED_DURING_APPLY'
        }
        [void]$blockers.Add((New-UtsFinding -Code 'SCAFFOLD_APPLY_FAILED' -Check 'apply-transaction' -Path $normalizedRoot -Message $_.Exception.Message))
        return Complete-UtsResultCollections -Result $result -Warnings $warnings -Blockers $blockers -Evidence $evidence
    }
}

# Serializes exactly one result document and validates it against the bundled schema.
function Write-UtsResult {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][bool]$Indented
    )

    $schemaErrors = @(Invoke-JsonSchemaValidation -Instance $Result -SchemaPath $script:UtsSchemaPath)
    $json = if ($Indented) {
        ConvertTo-UtsJsonFileText -InputObject $Result
    } else {
        (ConvertTo-Json -InputObject $Result -Depth 30 -Compress) + "`n"
    }
    [Console]::Out.Write($json)
    if ($schemaErrors.Count -gt 0) {
        foreach ($schemaError in $schemaErrors) {
            [Console]::Error.WriteLine("Schema validation failed at $($schemaError.path): $($schemaError.message)")
        }
        return 2
    }
    return 0
}

$resultDocument = $null
$internalFailure = $false
try {
    $resultDocument = Invoke-UtsScaffold `
        -RequestedProjectRoot $ProjectRoot `
        -RequestedRuntimeSourceRoot $RuntimeSourceRoot `
        -RequestedRuntimeAssemblyName $RuntimeAssemblyName `
        -RequestedTestRoot $TestRoot `
        -RequestedTestAssemblyName $TestAssemblyName `
        -ApplyRequested ([bool]$Apply) `
        -ExpectedHash $ExpectedPlanSha256
} catch {
    $internalFailure = $true
    [Console]::Error.WriteLine("Unity Test Scaffold internal failure: $($_.Exception.Message)")
    $resultDocument = New-UtsResult -NormalizedProjectRoot $null -ApplyRequested ([bool]$Apply)
    $resultDocument.blockers = [object[]]@((New-UtsFinding -Code 'INTERNAL_FAILURE' -Check 'scaffold' -Path $null -Message $_.Exception.Message))
}

$outputExitCode = Write-UtsResult -Result $resultDocument -Indented ([bool]$Pretty)
if ($internalFailure -or $outputExitCode -ne 0) {
    exit 2
}
exit 0
