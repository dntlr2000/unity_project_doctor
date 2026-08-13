[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$script:RepositoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$script:ScannerPath = Join-Path $script:RepositoryRoot "skills\codex\unity-project-doctor\scripts\inspect-unity-project.ps1"
$script:InstallerPath = Join-Path $script:RepositoryRoot "scripts\install-codex-skills.ps1"
$script:FixtureRoot = Join-Path $PSScriptRoot "fixtures"
$script:TestCount = 0
$script:ScratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("unity-project-doctor-tests-" + [guid]::NewGuid().ToString("N"))

# Throws a test failure when a condition is false.
function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw "ASSERTION FAILED: $Message"
    }
    $script:TestCount++
}

# Throws a test failure when two scalar values are not exactly equal.
function Assert-Equal {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Expected,

        [Parameter()]
        [AllowNull()]
        [object]$Actual,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Expected -cne $Actual) {
        throw "ASSERTION FAILED: $Message. Expected [$Expected], actual [$Actual]."
    }
    $script:TestCount++
}

# Confirms that a JSON object exposes a required top-level property.
function Assert-JsonProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    Assert-True -Condition ($null -ne $Object.PSObject.Properties[$Name]) -Message "Required JSON property is missing: $Name"
}

# Confirms that a structured warning code is present.
function Assert-WarningCode {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result,

        [Parameter(Mandatory = $true)]
        [string]$Code
    )

    $codes = @($Result.warnings | ForEach-Object { $_.code })
    Assert-True -Condition ($codes -contains $Code) -Message "Expected warning code was not found: $Code"
}

# Produces a deterministic directory and file hash snapshot without writing to the target.
function Get-TreeSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $normalizedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd("\", "/")
    $records = New-Object System.Collections.ArrayList
    $entries = @(Get-ChildItem -LiteralPath $normalizedRoot -Force -Recurse -ErrorAction Stop | Sort-Object -Property FullName)
    foreach ($entry in $entries) {
        $relativePath = $entry.FullName.Substring($normalizedRoot.Length + 1).Replace("\", "/")
        if ($entry.PSIsContainer) {
            [void]$records.Add("D|$relativePath")
        } else {
            $hash = (Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256).Hash
            [void]$records.Add("F|$relativePath|$($entry.Length)|$hash")
        }
    }
    return @($records.ToArray()) -join [Environment]::NewLine
}

# Copies one source fixture into an isolated system-temporary project directory.
function Copy-FixtureToScratch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $source = Join-Path $script:FixtureRoot $Name
    $destination = Join-Path $script:ScratchRoot $Name
    Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
    return $destination
}

# Runs one Git command used only to prepare an isolated fixture repository.
function Invoke-FixtureGit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & git -C $Root @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Fixture Git setup failed: git $($Arguments -join ' ') $([Environment]::NewLine)$($output -join [Environment]::NewLine)"
    }
}

# Initializes and commits a clean local Git repository inside a scratch fixture.
function Initialize-FixtureGitRepository {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    Invoke-FixtureGit -Root $Root -Arguments @("-c", "init.defaultBranch=main", "init", "-q")
    Invoke-FixtureGit -Root $Root -Arguments @("-c", "core.autocrlf=false", "add", "--all")
    Invoke-FixtureGit -Root $Root -Arguments @(
        "-c", "user.name=Unity Project Doctor Tests",
        "-c", "user.email=unity-project-doctor@example.invalid",
        "-c", "commit.gpgsign=false",
        "commit", "--no-verify", "-q", "-m", "fixture"
    )
}

# Executes the scanner in a child Windows PowerShell process and parses its sole stdout JSON document.
function Invoke-ScannerProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,

        [Parameter()]
        [switch]$Pretty,

        [Parameter()]
        [switch]$UseDefaultProjectRoot
    )

    if ($script:ScannerPath.Contains('"') -or $ProjectRoot.Contains('"')) {
        throw "Test paths containing a quote are unsupported."
    }

    $powershellCommand = Get-Command powershell.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $script:ScannerPath
    if (-not $UseDefaultProjectRoot) {
        $arguments += ' -ProjectRoot "{0}"' -f $ProjectRoot
    }
    if ($Pretty) {
        $arguments += " -Pretty"
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershellCommand.Source
    $startInfo.Arguments = $arguments
    $startInfo.WorkingDirectory = $ProjectRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.Result.Trim()
        $stderr = $stderrTask.Result.Trim()
        Assert-Equal -Expected 0 -Actual $process.ExitCode -Message "Scanner process exit code"
        Assert-Equal -Expected "" -Actual $stderr -Message "Scanner stderr must be empty for a normal audit"
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($stdout)) -Message "Scanner stdout must contain one JSON document"

        try {
            $parsed = ConvertFrom-Json -InputObject $stdout -ErrorAction Stop
        } catch {
            throw "Scanner stdout was not exactly one valid JSON document: $($_.Exception.Message)"
        }

        return [pscustomobject][ordered]@{
            json = $stdout
            result = $parsed
        }
    } finally {
        $process.Dispose()
    }
}

# Verifies that all dynamic checks remain explicitly unverified.
function Assert-DynamicChecksNotVerified {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result
    )

    foreach ($name in @("compilation", "tests", "build", "runtime")) {
        Assert-Equal -Expected "NOT_VERIFIED" -Actual $Result.dynamicVerification.$name.status -Message "Dynamic verification status for $name"
    }
}

# Runs the installer in-process so WhatIf, idempotency, and conflict exceptions are observable.
function Invoke-Installer {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot,

        [Parameter()]
        [switch]$WhatIf
    )

    if ($WhatIf) {
        & $script:InstallerPath -DestinationRoot $DestinationRoot -WhatIf
    } else {
        & $script:InstallerPath -DestinationRoot $DestinationRoot
    }
}

# Resolves one link target to a normalized absolute string for idempotency checks.
function Get-NormalizedLinkTarget {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileSystemInfo]$Link
    )

    $target = [string](@($Link.Target)[0])
    if (-not [System.IO.Path]::IsPathRooted($target)) {
        $target = Join-Path $Link.Parent.FullName $target
    }
    return [System.IO.Path]::GetFullPath($target).TrimEnd("\", "/")
}

Write-Host "Unity Project Doctor v0.2 static tests"
Write-Host "Scratch root: $script:ScratchRoot"

Assert-True -Condition (Test-Path -LiteralPath $script:ScannerPath -PathType Leaf) -Message "Scanner script must exist"
Assert-True -Condition (Test-Path -LiteralPath $script:InstallerPath -PathType Leaf) -Message "Installer script must exist"
$version = (Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot "VERSION")).Trim()
Assert-Equal -Expected "0.2.0" -Actual $version -Message "Repository VERSION"
$skillContent = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot "skills\codex\unity-project-doctor\SKILL.md")
Assert-True -Condition ($skillContent -match "^---\r?\nname: unity-project-doctor\r?\ndescription:") -Message "Skill frontmatter and name"
$agentContent = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot "skills\codex\unity-project-doctor\agents\openai.yaml")
Assert-True -Condition ($agentContent -match "(?m)^\s*allow_implicit_invocation:\s*false\s*$") -Message "Implicit invocation must remain disabled"
$repositoryBefore = Get-TreeSnapshot -Root $script:RepositoryRoot
$fixtureSourceBefore = Get-TreeSnapshot -Root $script:FixtureRoot
New-Item -ItemType Directory -Path $script:ScratchRoot -Force | Out-Null

$notUnity = Invoke-ScannerProcess -ProjectRoot (Join-Path $script:FixtureRoot "not-unity")
Assert-Equal -Expected "NOT_A_UNITY_PROJECT" -Actual $notUnity.result.finalStatus -Message "Non-Unity fixture status"
Assert-Equal -Expected $false -Actual $notUnity.result.projectDetection.isUnityProject -Message "Non-Unity project detection"
Assert-DynamicChecksNotVerified -Result $notUnity.result

$cleanRoot = Copy-FixtureToScratch -Name "unity-minimal-clean"
Initialize-FixtureGitRepository -Root $cleanRoot
$cleanBefore = Get-TreeSnapshot -Root $cleanRoot
$cleanFirst = Invoke-ScannerProcess -ProjectRoot $cleanRoot
$cleanSecond = Invoke-ScannerProcess -ProjectRoot $cleanRoot
$cleanPretty = Invoke-ScannerProcess -ProjectRoot $cleanRoot -Pretty
$cleanDefaultRoot = Invoke-ScannerProcess -ProjectRoot $cleanRoot -UseDefaultProjectRoot
$cleanAfter = Get-TreeSnapshot -Root $cleanRoot
Assert-Equal -Expected "STATIC_AUDIT_COMPLETE" -Actual $cleanFirst.result.finalStatus -Message "Minimal clean project status"
Assert-Equal -Expected 0 -Actual $cleanFirst.result.warnings.Count -Message "Minimal clean project warning count"
Assert-Equal -Expected "CLEAN" -Actual $cleanFirst.result.git.dirtyState -Message "Minimal clean Git state"
Assert-Equal -Expected "6000.0.69f1" -Actual $cleanFirst.result.unityEditorVersion.editorVersion -Message "Unity editor version"
Assert-Equal -Expected 1 -Actual $cleanFirst.result.packages.directDependencies.Count -Message "Direct dependency count"
Assert-Equal -Expected 1 -Actual $cleanFirst.result.packages.resolvedDependencies.Count -Message "Resolved dependency count"
Assert-Equal -Expected 1 -Actual $cleanFirst.result.assemblies.confirmedTestAssemblies.Count -Message "Confirmed test assembly count"
Assert-Equal -Expected 1 -Actual $cleanFirst.result.buildSettings.enabledScenes.Count -Message "Enabled Build Settings Scene count"
Assert-Equal -Expected 1 -Actual $cleanFirst.result.buildSettings.disabledScenes.Count -Message "Disabled Build Settings Scene count"
Assert-Equal -Expected 0 -Actual $cleanFirst.result.buildSettings.missingScenes.Count -Message "Clean Build Settings missing Scene count"
Assert-True -Condition ($cleanFirst.result.evidence.Count -gt 0) -Message "Clean audit must contain evidence"
Assert-Equal -Expected $cleanFirst.json -Actual $cleanSecond.json -Message "Scanner JSON must be deterministic"
Assert-Equal -Expected $cleanFirst.result.finalStatus -Actual $cleanPretty.result.finalStatus -Message "Pretty output semantics"
Assert-Equal -Expected $cleanFirst.result.projectRoot -Actual $cleanDefaultRoot.result.projectRoot -Message "Default ProjectRoot must use the current working directory"
Assert-Equal -Expected "STATIC_AUDIT_COMPLETE" -Actual $cleanDefaultRoot.result.finalStatus -Message "Default ProjectRoot audit status"
Assert-Equal -Expected $cleanBefore -Actual $cleanAfter -Message "Minimal clean fixture must remain byte-for-byte unchanged"
Assert-DynamicChecksNotVerified -Result $cleanFirst.result

foreach ($requiredProperty in @(
    "schemaVersion", "scannerVersion", "projectRoot", "projectDetection",
    "unityEditorVersion", "git", "packages", "assemblies", "buildSettings",
    "agentsFiles", "projectSkills", "trackedGeneratedFolderPaths", "warnings",
    "blockedChecks", "dynamicVerification", "finalStatus", "evidence"
)) {
    Assert-JsonProperty -Object $cleanFirst.result -Name $requiredProperty
}
Assert-Equal -Expected "1.0.0" -Actual $cleanFirst.result.schemaVersion -Message "Schema version"
Assert-Equal -Expected "0.2.0" -Actual $cleanFirst.result.scannerVersion -Message "Scanner version"

$previousGitDirectory = [Environment]::GetEnvironmentVariable("GIT_DIR", "Process")
try {
    [Environment]::SetEnvironmentVariable("GIT_DIR", (Join-Path $script:ScratchRoot "outside-git-metadata"), "Process")
    $sanitizedEnvironmentResult = Invoke-ScannerProcess -ProjectRoot $cleanRoot
} finally {
    [Environment]::SetEnvironmentVariable("GIT_DIR", $previousGitDirectory, "Process")
}
Assert-Equal -Expected "SAFE" -Actual $sanitizedEnvironmentResult.result.git.metadataStatus -Message "Inherited GIT_DIR must not redirect scanner Git operations"
Assert-Equal -Expected "STATIC_AUDIT_COMPLETE" -Actual $sanitizedEnvironmentResult.result.finalStatus -Message "Sanitized Git environment audit status"

$unicodeDirectoryName = -join @(
    [char]0xC720,
    [char]0xB2C8,
    [char]0xD2F0,
    [char]0x002D,
    [char]0xD504,
    [char]0xB85C,
    [char]0xC81D,
    [char]0xD2B8
)
$unicodeRoot = Join-Path $script:ScratchRoot $unicodeDirectoryName
Copy-Item -LiteralPath (Join-Path $script:FixtureRoot "unity-minimal-clean") -Destination $unicodeRoot -Recurse -Force
Initialize-FixtureGitRepository -Root $unicodeRoot
$unicodeResult = Invoke-ScannerProcess -ProjectRoot $unicodeRoot
Assert-Equal -Expected ([System.IO.Path]::GetFullPath($unicodeRoot).TrimEnd("\", "/")) -Actual $unicodeResult.result.projectRoot -Message "Unicode project root must round-trip through JSON"
Assert-Equal -Expected "STATIC_AUDIT_COMPLETE" -Actual $unicodeResult.result.finalStatus -Message "Unicode project path status"

$warningRoot = Copy-FixtureToScratch -Name "unity-with-warnings"
Initialize-FixtureGitRepository -Root $warningRoot
[System.IO.File]::WriteAllText(
    (Join-Path $warningRoot "Assets\UntrackedProbe.txt"),
    "untracked fixture state",
    (New-Object System.Text.UTF8Encoding($false))
)
$warningBefore = Get-TreeSnapshot -Root $warningRoot
$warningResult = Invoke-ScannerProcess -ProjectRoot $warningRoot
$warningAfter = Get-TreeSnapshot -Root $warningRoot
Assert-Equal -Expected "STATIC_AUDIT_COMPLETE_WITH_WARNINGS" -Actual $warningResult.result.finalStatus -Message "Warning project status"
Assert-WarningCode -Result $warningResult.result -Code "NON_REGISTRY_DEPENDENCY_REFERENCE"
Assert-WarningCode -Result $warningResult.result -Code "DIRECT_DEPENDENCIES_MISSING_FROM_LOCK"
Assert-WarningCode -Result $warningResult.result -Code "NO_DECLARED_TEST_ASSEMBLY_DETECTED"
Assert-WarningCode -Result $warningResult.result -Code "TRACKED_GENERATED_FOLDER"
Assert-Equal -Expected "DIRTY" -Actual $warningResult.result.git.dirtyState -Message "Warning fixture dirty state"
Assert-True -Condition (@($warningResult.result.git.changedPaths | ForEach-Object path) -contains "Assets/UntrackedProbe.txt") -Message "Warning fixture changed path inventory"
Assert-Equal -Expected 1 -Actual $warningResult.result.assemblies.candidateOnlyTestAssemblies.Count -Message "Candidate-only test assembly count"
Assert-Equal -Expected 2 -Actual $warningResult.result.agentsFiles.Count -Message "AGENTS.md inventory count"
Assert-Equal -Expected 1 -Actual $warningResult.result.projectSkills.Count -Message "Project-local Skill inventory count"
Assert-Equal -Expected $warningBefore -Actual $warningAfter -Message "Warning fixture must remain byte-for-byte unchanged"
Assert-DynamicChecksNotVerified -Result $warningResult.result

$malformedRoot = Copy-FixtureToScratch -Name "malformed-manifest"
Initialize-FixtureGitRepository -Root $malformedRoot
$malformedBefore = Get-TreeSnapshot -Root $malformedRoot
$malformedResult = Invoke-ScannerProcess -ProjectRoot $malformedRoot
$malformedAfter = Get-TreeSnapshot -Root $malformedRoot
Assert-Equal -Expected "STATIC_AUDIT_COMPLETE_WITH_WARNINGS" -Actual $malformedResult.result.finalStatus -Message "Malformed manifest project status"
Assert-Equal -Expected "INVALID_JSON" -Actual $malformedResult.result.packages.manifest.parseStatus -Message "Malformed manifest parse state"
Assert-WarningCode -Result $malformedResult.result -Code "MANIFEST_JSON_INVALID"
Assert-Equal -Expected $malformedBefore -Actual $malformedAfter -Message "Malformed manifest fixture must remain byte-for-byte unchanged"

$missingSceneRoot = Copy-FixtureToScratch -Name "missing-build-scene"
Initialize-FixtureGitRepository -Root $missingSceneRoot
$missingSceneBefore = Get-TreeSnapshot -Root $missingSceneRoot
$missingSceneResult = Invoke-ScannerProcess -ProjectRoot $missingSceneRoot
$missingSceneAfter = Get-TreeSnapshot -Root $missingSceneRoot
Assert-Equal -Expected "STATIC_AUDIT_COMPLETE_WITH_WARNINGS" -Actual $missingSceneResult.result.finalStatus -Message "Missing Build Scene project status"
Assert-WarningCode -Result $missingSceneResult.result -Code "BUILD_SCENE_MISSING"
Assert-Equal -Expected 1 -Actual $missingSceneResult.result.buildSettings.missingScenes.Count -Message "Missing Build Scene count"
Assert-Equal -Expected $missingSceneBefore -Actual $missingSceneAfter -Message "Missing Build Scene fixture must remain byte-for-byte unchanged"

$junctionRoot = Join-Path $script:ScratchRoot "junction-boundary"
Copy-Item -LiteralPath (Join-Path $script:FixtureRoot "unity-minimal-clean") -Destination $junctionRoot -Recurse -Force
Initialize-FixtureGitRepository -Root $junctionRoot
$outsideRoot = Join-Path $script:ScratchRoot "junction-outside"
New-Item -ItemType Directory -Path $outsideRoot -Force | Out-Null
$outsideAsmdef = Join-Path $outsideRoot "OutsideBoundary.Tests.asmdef"
[System.IO.File]::WriteAllText(
    $outsideAsmdef,
    '{"name":"OutsideBoundary.Tests","optionalUnityReferences":["TestAssemblies"]}',
    (New-Object System.Text.UTF8Encoding($false))
)
New-Item -ItemType Junction -Path (Join-Path $junctionRoot "Assets\ExternalLink") -Target $outsideRoot | Out-Null
$outsideHashBefore = (Get-FileHash -LiteralPath $outsideAsmdef -Algorithm SHA256).Hash
$junctionResult = Invoke-ScannerProcess -ProjectRoot $junctionRoot
$outsideHashAfter = (Get-FileHash -LiteralPath $outsideAsmdef -Algorithm SHA256).Hash
Assert-Equal -Expected "UNSAFE_WORKTREE_LAYOUT" -Actual $junctionResult.result.git.metadataStatus -Message "Junction must disable Git worktree inspection"
Assert-WarningCode -Result $junctionResult.result -Code "GIT_WORKTREE_REPARSE_POINT"
Assert-WarningCode -Result $junctionResult.result -Code "REPARSE_POINT_SKIPPED"
Assert-Equal -Expected 0 -Actual $junctionResult.result.git.changedPaths.Count -Message "Git must not disclose a path behind a junction"
Assert-True -Condition (-not $junctionResult.json.Contains("OutsideBoundary.Tests.asmdef")) -Message "Scanner JSON must not contain a filename behind a junction"
Assert-Equal -Expected $outsideHashBefore -Actual $outsideHashAfter -Message "File behind a junction must remain unchanged"

$blockedTargetRoot = Join-Path $script:ScratchRoot "blocked-root-target"
Copy-Item -LiteralPath (Join-Path $script:FixtureRoot "unity-minimal-clean") -Destination $blockedTargetRoot -Recurse -Force
$blockedJunctionRoot = Join-Path $script:ScratchRoot "blocked-project-root"
New-Item -ItemType Junction -Path $blockedJunctionRoot -Target $blockedTargetRoot | Out-Null
$blockedRootResult = Invoke-ScannerProcess -ProjectRoot $blockedJunctionRoot
$blockedRootCodes = @($blockedRootResult.result.blockedChecks | ForEach-Object { $_.code })
Assert-Equal -Expected "AUDIT_BLOCKED" -Actual $blockedRootResult.result.finalStatus -Message "Reparse-point project root status"
Assert-True -Condition ($blockedRootCodes -contains "PROJECT_ROOT_REPARSE_POINT") -Message "Reparse-point project root blocker"

$localExecutableRoot = Join-Path $script:ScratchRoot "project-local-git"
Copy-Item -LiteralPath (Join-Path $script:FixtureRoot "unity-minimal-clean") -Destination $localExecutableRoot -Recurse -Force
Initialize-FixtureGitRepository -Root $localExecutableRoot
$localGitExecutable = Join-Path $localExecutableRoot "git.exe"
[System.IO.File]::WriteAllText($localGitExecutable, "This fixture executable must never run.", (New-Object System.Text.UTF8Encoding($false)))
$localGitHashBefore = (Get-FileHash -LiteralPath $localGitExecutable -Algorithm SHA256).Hash
$previousPath = [Environment]::GetEnvironmentVariable("PATH", "Process")
try {
    [Environment]::SetEnvironmentVariable("PATH", ($localExecutableRoot + [System.IO.Path]::PathSeparator + $previousPath), "Process")
    $localExecutableResult = Invoke-ScannerProcess -ProjectRoot $localExecutableRoot
} finally {
    [Environment]::SetEnvironmentVariable("PATH", $previousPath, "Process")
}
$localGitHashAfter = (Get-FileHash -LiteralPath $localGitExecutable -Algorithm SHA256).Hash
Assert-Equal -Expected "PROJECT_LOCAL_EXECUTABLE_REFUSED" -Actual $localExecutableResult.result.git.metadataStatus -Message "Project-local Git executable must be refused"
Assert-WarningCode -Result $localExecutableResult.result -Code "GIT_EXECUTABLE_INSIDE_PROJECT"
Assert-Equal -Expected 0 -Actual $localExecutableResult.result.git.changedPaths.Count -Message "Project-local Git executable refusal must not produce changed paths"
Assert-Equal -Expected $localGitHashBefore -Actual $localGitHashAfter -Message "Project-local Git executable must remain untouched"

$whatIfDestination = Join-Path $script:ScratchRoot "installer-whatif"
Invoke-Installer -DestinationRoot $whatIfDestination -WhatIf
Assert-True -Condition (-not (Test-Path -LiteralPath $whatIfDestination)) -Message "Installer WhatIf must not create its destination"

$idempotencyDestination = Join-Path $script:ScratchRoot "installer-idempotency"
$idempotencyLink = Join-Path $idempotencyDestination "unity-project-doctor"
$usedExistingGlobalLink = $false
try {
    Invoke-Installer -DestinationRoot $idempotencyDestination
} catch {
    $defaultDestination = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) ".agents\skills"
    $defaultLink = Join-Path $defaultDestination "unity-project-doctor"
    $existingLink = Get-Item -LiteralPath $defaultLink -Force -ErrorAction SilentlyContinue
    $expectedSource = Join-Path $script:RepositoryRoot "skills\codex\unity-project-doctor"
    if ($null -eq $existingLink -or $existingLink.LinkType -ne "SymbolicLink" -or (Get-NormalizedLinkTarget -Link $existingLink) -cne ([System.IO.Path]::GetFullPath($expectedSource).TrimEnd("\", "/"))) {
        throw "Symbolic link creation is unavailable and no matching installed global link can be used for the idempotency test. Original error: $($_.Exception.Message)"
    }
    $usedExistingGlobalLink = $true
    $idempotencyDestination = $defaultDestination
    $idempotencyLink = $defaultLink
}

$linkBefore = Get-Item -LiteralPath $idempotencyLink -Force
$targetBefore = Get-NormalizedLinkTarget -Link $linkBefore
$creationTimeBefore = $linkBefore.CreationTimeUtc
Invoke-Installer -DestinationRoot $idempotencyDestination
$linkAfter = Get-Item -LiteralPath $idempotencyLink -Force
Assert-Equal -Expected "SymbolicLink" -Actual $linkAfter.LinkType -Message "Installer link type"
Assert-Equal -Expected $targetBefore -Actual (Get-NormalizedLinkTarget -Link $linkAfter) -Message "Installer link target after repeated run"
Assert-Equal -Expected $creationTimeBefore -Actual $linkAfter.CreationTimeUtc -Message "Installer must preserve an existing matching link"
if ($usedExistingGlobalLink) {
    Write-Host "Idempotency test reused the already installed global link because this process cannot create symbolic links."
}

$conflictDestination = Join-Path $script:ScratchRoot "installer-conflict"
$conflictPath = Join-Path $conflictDestination "unity-project-doctor"
New-Item -ItemType Directory -Path $conflictPath -Force | Out-Null
$sentinelPath = Join-Path $conflictPath "sentinel.txt"
[System.IO.File]::WriteAllText($sentinelPath, "preserve", (New-Object System.Text.UTF8Encoding($false)))
$conflictRejected = $false
try {
    Invoke-Installer -DestinationRoot $conflictDestination
} catch {
    $conflictRejected = $true
}
Assert-True -Condition $conflictRejected -Message "Installer must reject a conflicting existing path"
Assert-True -Condition (Test-Path -LiteralPath $sentinelPath -PathType Leaf) -Message "Installer must preserve conflict content"
$conflictEntry = Get-Item -LiteralPath $conflictPath -Force
Assert-True -Condition ($null -eq $conflictEntry.LinkType) -Message "Installer must not replace a conflicting directory with a link"

$fixtureSourceAfter = Get-TreeSnapshot -Root $script:FixtureRoot
Assert-Equal -Expected $fixtureSourceBefore -Actual $fixtureSourceAfter -Message "Source fixture list and hashes must remain unchanged"
$repositoryAfter = Get-TreeSnapshot -Root $script:RepositoryRoot
Assert-Equal -Expected $repositoryBefore -Actual $repositoryAfter -Message "Repository file list and hashes must remain unchanged during tests"

Write-Host "All tests passed. Assertions: $script:TestCount"
Write-Host "Scratch artifacts were left outside the repository at: $script:ScratchRoot"
