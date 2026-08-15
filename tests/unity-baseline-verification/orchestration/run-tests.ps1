[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:RepositoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))).TrimEnd("\", "/")
$script:OrchestratorPath = Join-Path $script:RepositoryRoot "skills\codex\unity-baseline-verification\scripts\invoke-unity-baseline-verification.ps1"
$script:OrchestrationLibraryPath = Join-Path $script:RepositoryRoot "skills\codex\unity-baseline-verification\scripts\lib\unity-baseline-orchestration.ps1"
$script:VerifierPath = Join-Path $script:RepositoryRoot "skills\codex\unity-baseline-verification\scripts\verify-unity-baseline.ps1"
$script:ScannerPath = Join-Path $script:RepositoryRoot "skills\codex\unity-project-doctor\scripts\inspect-unity-project.ps1"
$script:ScratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ubo-tests-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$script:Assertions = 0
$script:TestsPassed = $false
$script:ExternalSessionRoots = New-Object System.Collections.ArrayList

# Throws when a test condition is false.
function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $script:Assertions++
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

# Throws when two scalar or canonical string values differ.
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

    $script:Assertions++
    if ($Expected -ne $Actual) {
        throw "Assertion failed: $Message. Expected <$Expected>; actual <$Actual>."
    }
}

# Throws when an enumerable lacks one expected scalar value.
function Assert-Contains {
    param(
        [Parameter()]
        [AllowNull()]
        [object[]]$Collection,

        [Parameter()]
        [AllowNull()]
        [object]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $script:Assertions++
    if (@($Collection) -notcontains $Expected) {
        throw "Assertion failed: $Message. Missing <$Expected>."
    }
}

# Writes one UTF-8 without BOM test file after creating its parent directory.
function Write-TestText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [void][System.IO.Directory]::CreateDirectory($parent)
    }
    [void][System.IO.File]::WriteAllText($Path, $Content, $script:Utf8NoBom)
}

# Captures a deterministic directory/file/length/SHA-256 tree snapshot.
function Get-TestTreeSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $normalizedRoot = Get-OrchestrationNormalizedPath -Path $Root
    $records = New-Object System.Collections.ArrayList
    foreach ($directory in @(Get-ChildItem -LiteralPath $normalizedRoot -Directory -Force -Recurse | Sort-Object FullName)) {
        $relative = $directory.FullName.Substring($normalizedRoot.Length + 1).Replace("\", "/")
        [void]$records.Add("D|$relative")
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $normalizedRoot -File -Force -Recurse | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($normalizedRoot.Length + 1).Replace("\", "/")
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
        [void]$records.Add("F|$relative|$($file.Length)|$hash")
    }
    return [string]::Join([char]10, [string[]]@($records))
}

# Creates a minimal Unity project whose missing test assembly produces preserved Doctor warnings.
function New-TestUnityProject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $projectRoot = Join-Path $script:ScratchRoot ("projects\" + $Name)
    [void][System.IO.Directory]::CreateDirectory($projectRoot)
    Write-TestText -Path (Join-Path $projectRoot "Assets\Scripts\Probe.cs") -Content "public sealed class Probe { public int Value = 1; }"
    Write-TestText -Path (Join-Path $projectRoot "Packages\manifest.json") -Content '{"dependencies":{"com.unity.modules.jsonserialize":"1.0.0"}}'
    Write-TestText -Path (Join-Path $projectRoot "Packages\packages-lock.json") -Content '{"dependencies":{"com.unity.modules.jsonserialize":{"version":"1.0.0","depth":0,"source":"builtin","dependencies":{}}}}'
    $versionText = "m_EditorVersion: 6000.0.69f1`r`nm_EditorVersionWithRevision: 6000.0.69f1 (5f8607f5118b)`r`n"
    Write-TestText -Path (Join-Path $projectRoot "ProjectSettings\ProjectVersion.txt") -Content $versionText
    return Get-OrchestrationNormalizedPath -Path $projectRoot
}

# Initializes a real scratch-only Git worktree for read-only orchestration checks.
function Initialize-TestGitMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot
    )

    $gitCommand = Get-Command "git.exe" -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $gitOutput = @(& $gitCommand.Source init --quiet $ProjectRoot 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Scratch Git initialization failed: $([string]::Join([Environment]::NewLine, [string[]]$gitOutput))"
    }
}

# Compiles an unsigned Unity-shaped executable that writes a marker only if started.
function New-UnsignedUnityExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $OutputPath))
    $source = @"
using System;
using System.IO;
using System.Reflection;
using System.Text;

[assembly: AssemblyTitle("Unity")]
[assembly: AssemblyProduct("Unity")]
[assembly: AssemblyCompany("Fixture")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("6000.0.69.1")]
[assembly: AssemblyInformationalVersion("6000.0.69f1_fixture")]

internal static class Program
{
    // Writes a marker only when this unsigned fixture is actually executed.
    private static int Main(string[] args)
    {
        string marker = Environment.GetEnvironmentVariable("ORCHESTRATION_FAKE_EXECUTED");
        if (!String.IsNullOrWhiteSpace(marker))
        {
            string parent = Path.GetDirectoryName(marker);
            if (!String.IsNullOrWhiteSpace(parent))
            {
                Directory.CreateDirectory(parent);
            }
            File.WriteAllText(marker, String.Join(Environment.NewLine, args), new UTF8Encoding(false));
        }
        return 0;
    }
}
"@
    Add-Type -TypeDefinition $source -Language CSharp -OutputAssembly $OutputPath -OutputType ConsoleApplication
    return Get-OrchestrationNormalizedPath -Path $OutputPath
}

# Runs the production or scratch-copy orchestrator and parses its sole JSON stdout document.
function Invoke-OrchestratorCase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CaseName,

        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,

        [Parameter()]
        [AllowNull()]
        [string]$ProjectRoot,

        [Parameter()]
        [switch]$OmitProjectRoot,

        [Parameter()]
        [AllowNull()]
        [string]$ArtifactsRoot,

        [Parameter()]
        [switch]$OmitArtifactsRoot,

        [Parameter()]
        [AllowNull()]
        [string]$UnityExecutable,

        [Parameter()]
        [switch]$Pretty,

        [Parameter()]
        [hashtable]$Environment = @{}
    )

    $arguments = New-Object System.Collections.ArrayList
    if (-not $OmitProjectRoot) {
        [void]$arguments.Add("-ProjectRoot")
        [void]$arguments.Add($ProjectRoot)
    }
    if (-not $OmitArtifactsRoot) {
        [void]$arguments.Add("-ArtifactsRoot")
        [void]$arguments.Add($ArtifactsRoot)
    }
    if (-not [string]::IsNullOrWhiteSpace($UnityExecutable)) {
        [void]$arguments.Add("-UnityExecutable")
        [void]$arguments.Add($UnityExecutable)
    }
    [void]$arguments.Add("-TimeoutSeconds")
    [void]$arguments.Add("60")
    if ($Pretty) {
        [void]$arguments.Add("-Pretty")
    }

    $previousValues = @{}
    foreach ($name in @($Environment.Keys)) {
        $previousValues[$name] = [Environment]::GetEnvironmentVariable([string]$name, "Process")
    }
    try {
        foreach ($name in @($Environment.Keys)) {
            [Environment]::SetEnvironmentVariable([string]$name, [string]$Environment[$name], "Process")
        }
        $process = Invoke-OrchestrationPowerShellScript -ScriptPath $ScriptPath -Arguments ([string[]]@($arguments)) -WorkingDirectory $WorkingDirectory
    } finally {
        foreach ($name in @($Environment.Keys)) {
            [Environment]::SetEnvironmentVariable([string]$name, $previousValues[$name], "Process")
        }
    }

    Assert-Equal -Expected 0 -Actual $process.exitCode -Message "$CaseName process exit code"
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$process.stdout)) -Message "$CaseName stdout contains JSON"
    try {
        $result = ConvertFrom-Json -InputObject ([string]$process.stdout) -ErrorAction Stop
    } catch {
        throw "$CaseName stdout was not exactly one JSON document: $($_.Exception.Message)"
    }
    return [pscustomobject][ordered]@{
        raw = [string]$process.stdout
        stderr = [string]$process.stderr
        result = $result
    }
}

# Records only verified system-temporary session roots for end-of-suite cleanup.
function Register-OrchestrationArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [object]$CaseResult
    )

    $paths = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace([string]$CaseResult.result.doctor.sourcePath)) {
        $doctorDirectory = Split-Path -Parent ([string]$CaseResult.result.doctor.sourcePath)
        [void]$paths.Add((Split-Path -Parent $doctorDirectory))
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$CaseResult.result.isolation.sessionRoot)) {
        [void]$paths.Add([string]$CaseResult.result.isolation.sessionRoot)
    }

    foreach ($path in @($paths)) {
        $normalizedPath = Get-OrchestrationNormalizedPath -Path $path
        if (-not (Test-OrchestrationPathWithinRoot -Path $normalizedPath -Root ([System.IO.Path]::GetTempPath()))) {
            throw "Refusing to register non-temporary test artifact: $normalizedPath"
        }
        if (-not (Test-OrchestrationPathWithinRoot -Path $normalizedPath -Root $script:ScratchRoot)) {
            [void]$script:ExternalSessionRoots.Add($normalizedPath)
        }
    }
}

# Copies the installed-layout components needed to replace only the scanner with a fixture stub.
function New-OrchestrationHarness {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ScannerStub
    )

    $harnessRoot = Join-Path $script:ScratchRoot ("harnesses\" + $Name)
    [void][System.IO.Directory]::CreateDirectory((Join-Path $harnessRoot "skills\codex"))
    Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot "skills\codex\unity-baseline-verification") -Destination (Join-Path $harnessRoot "skills\codex\unity-baseline-verification") -Recurse
    Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot "skills\codex\unity-project-doctor") -Destination (Join-Path $harnessRoot "skills\codex\unity-project-doctor") -Recurse
    Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot "schemas") -Destination (Join-Path $harnessRoot "schemas") -Recurse
    Write-TestText -Path (Join-Path $harnessRoot "skills\codex\unity-project-doctor\scripts\inspect-unity-project.ps1") -Content $ScannerStub
    return Join-Path $harnessRoot "skills\codex\unity-baseline-verification\scripts\invoke-unity-baseline-verification.ps1"
}

# Removes only verified temporary roots created by this orchestration test run.
function Remove-OrchestrationTestArtifacts {
    $normalizedScratch = Get-OrchestrationNormalizedPath -Path $script:ScratchRoot
    $temporaryRoot = Get-OrchestrationNormalizedPath -Path ([System.IO.Path]::GetTempPath())
    if (
        -not (Test-OrchestrationPathWithinRoot -Path $normalizedScratch -Root $temporaryRoot) -or
        -not ([System.IO.Path]::GetFileName($normalizedScratch)).StartsWith("ubo-tests-", [System.StringComparison]::Ordinal)
    ) {
        throw "Refusing to remove unverified scratch root: $normalizedScratch"
    }

    $cleanupCandidates = @($script:ExternalSessionRoots | Sort-Object -Unique) + @($normalizedScratch)
    foreach ($candidate in $cleanupCandidates) {
        if (-not (Test-Path -LiteralPath $candidate)) {
            continue
        }
        $leaf = [System.IO.Path]::GetFileName($candidate)
        $allowed = $candidate -eq $normalizedScratch -or
            $leaf.StartsWith("unity-baseline-orchestration-", [System.StringComparison]::Ordinal) -or
            $leaf.StartsWith("unity-baseline-verification-", [System.StringComparison]::Ordinal)
        if (-not $allowed -or -not (Test-OrchestrationPathWithinRoot -Path $candidate -Root $temporaryRoot)) {
            throw "Refusing to remove unverified session root: $candidate"
        }
        Remove-Item -LiteralPath $candidate -Recurse -Force
    }
}

Write-Host "Unity Baseline Verification v0.2.0 orchestration tests"
Write-Host "Scratch root: $script:ScratchRoot"

[void][System.IO.Directory]::CreateDirectory($script:ScratchRoot)
. $script:OrchestrationLibraryPath
$fixtureRoot = Join-Path $script:RepositoryRoot "tests\fixtures"
$fixturesBefore = Get-TestTreeSnapshot -Root $fixtureRoot

try {
    foreach ($requiredPath in @($script:OrchestratorPath, $script:OrchestrationLibraryPath, $script:VerifierPath, $script:ScannerPath)) {
        Assert-True -Condition (Test-Path -LiteralPath $requiredPath -PathType Leaf) -Message "Required orchestration file: $requiredPath"
    }
    Assert-Equal -Expected "0.3.0" -Actual ((Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot "VERSION")).Trim()) -Message "Repository VERSION remains sealed"
    Assert-Equal -Expected "0.2.0" -Actual ((Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot "skills\codex\unity-baseline-verification\VERSION")).Trim()) -Message "Baseline component VERSION"
    Assert-Equal -Expected "0.2.1" -Actual ((Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot "skills\codex\unity-project-doctor\VERSION")).Trim()) -Message "Doctor component VERSION remains unchanged"

    $agentYaml = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot "skills\codex\unity-baseline-verification\agents\openai.yaml")
    Assert-True -Condition ($agentYaml -match '(?m)^\s*allow_implicit_invocation:\s*false\s*$') -Message "Implicit invocation remains disabled"
    $orchestratorContent = Get-Content -Raw -LiteralPath $script:OrchestratorPath
    $libraryContent = Get-Content -Raw -LiteralPath $script:OrchestrationLibraryPath
    $verifierContent = Get-Content -Raw -LiteralPath $script:VerifierPath
    Assert-True -Condition ($orchestratorContent.Contains('$script:OrchestratorVersion = "0.1.0"')) -Message "Orchestrator metadata version"
    Assert-True -Condition ($orchestratorContent.Contains('$script:BaselineComponentVersion = "0.2.0"')) -Message "Component metadata version"
    Assert-True -Condition ($verifierContent.Contains('$script:VerifierVersion = "0.1.2"')) -Message "Low-level verifier metadata remains 0.1.2"
    Assert-True -Condition ($verifierContent.Contains('$script:SchemaVersion = "1.1.0"')) -Message "Baseline result schema remains 1.1.0"
    foreach ($status in @("BASELINE_VERIFIED", "BASELINE_FAILED", "VERIFICATION_BLOCKED", "ORIGINAL_PROJECT_CHANGED")) {
        Assert-True -Condition ($verifierContent.Contains($status)) -Message "Low-level final status remains defined: $status"
        Assert-True -Condition (-not $orchestratorContent.Contains($status)) -Message "Orchestrator does not synthesize final status: $status"
    }
    Assert-True -Condition ($orchestratorContent -notmatch '(?i)SkipSignatureCheck|TestMode|AllowUnsigned') -Message "Orchestrator exposes no trust bypass"
    Assert-True -Condition ($verifierContent -notmatch '(?i)SkipSignatureCheck|TestMode|AllowUnsigned') -Message "Verifier exposes no trust bypass"
    Assert-True -Condition ($orchestratorContent -notmatch '(?i)Start-Process|Process\.Start|UnityHub\.exe') -Message "Orchestrator starts neither Unity nor Unity Hub directly"
    Assert-True -Condition ($libraryContent -notmatch '(?i)Get-ChildItem[^\r\n]*-Recurse|Registry::|UnityHub\.exe') -Message "Resolver performs no recursive or registry discovery"

    $fakeUnity = New-UnsignedUnityExecutable -OutputPath (Join-Path $script:ScratchRoot "fake-unity\Unity.exe")
    Assert-Equal -Expected "NotSigned" -Actual ([string](Get-AuthenticodeSignature -LiteralPath $fakeUnity).Status) -Message "Production fake remains unsigned"
    Assert-True -Condition ((Get-Item -LiteralPath $fakeUnity).VersionInfo.ProductVersion.StartsWith("6000.0.69f1", [System.StringComparison]::Ordinal)) -Message "Fake exposes exact product version"

    $resolverRoot = Join-Path $script:ScratchRoot "resolver"
    $explicitPath = Join-Path $resolverRoot "explicit\Unity.exe"
    $editorPath = Join-Path $resolverRoot "editor-env\Unity.exe"
    $hubRoot = Join-Path $resolverRoot "hub-root"
    $hubPath = Join-Path $hubRoot "6000.0.69f1\Editor\Unity.exe"
    $programFilesRoot = Join-Path $resolverRoot "program-files"
    $programFilesPath = Join-Path $programFilesRoot "Unity\Hub\Editor\6000.0.69f1\Editor\Unity.exe"
    $programFilesX86Root = Join-Path $resolverRoot "program-files-x86"
    $programFilesX86Path = Join-Path $programFilesX86Root "Unity\Hub\Editor\6000.0.69f1\Editor\Unity.exe"
    foreach ($candidatePath in @($explicitPath, $editorPath, $hubPath, $programFilesPath, $programFilesX86Path)) {
        [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $candidatePath))
        Copy-Item -LiteralPath $fakeUnity -Destination $candidatePath
    }

    $allResolution = Resolve-OrchestrationUnityExecutable -RequiredVersion "6000.0.69f1" -UnityExecutableOverride $explicitPath -UnityEditorPath $editorPath -UnityHubEditorRoot $hubRoot -ProgramFilesRoot $programFilesRoot -ProgramFilesX86Root $programFilesX86Root
    Assert-Equal -Expected "UnityExecutable" -Actual $allResolution.selectedSource -Message "Explicit Unity override has highest priority"
    Assert-Equal -Expected (Get-OrchestrationNormalizedPath $explicitPath) -Actual $allResolution.selectedPath -Message "Explicit Unity override exact path"
    Assert-Equal -Expected 1 -Actual $allResolution.candidates.Count -Message "Explicit override is authoritative and stops fallback"

    $editorResolution = Resolve-OrchestrationUnityExecutable -RequiredVersion "6000.0.69f1" -UnityExecutableOverride $null -UnityEditorPath $editorPath -UnityHubEditorRoot $hubRoot -ProgramFilesRoot $programFilesRoot -ProgramFilesX86Root $programFilesX86Root
    Assert-Equal -Expected "UNITY_EDITOR_PATH" -Actual $editorResolution.selectedSource -Message "UNITY_EDITOR_PATH precedence"
    $hubResolution = Resolve-OrchestrationUnityExecutable -RequiredVersion "6000.0.69f1" -UnityExecutableOverride $null -UnityEditorPath $null -UnityHubEditorRoot $hubRoot -ProgramFilesRoot $programFilesRoot -ProgramFilesX86Root $programFilesX86Root
    Assert-Equal -Expected "UNITY_HUB_EDITOR_ROOT" -Actual $hubResolution.selectedSource -Message "UNITY_HUB_EDITOR_ROOT precedence"
    $programFilesResolution = Resolve-OrchestrationUnityExecutable -RequiredVersion "6000.0.69f1" -UnityExecutableOverride $null -UnityEditorPath $null -UnityHubEditorRoot $null -ProgramFilesRoot $programFilesRoot -ProgramFilesX86Root $programFilesX86Root
    Assert-Equal -Expected "ProgramFiles" -Actual $programFilesResolution.selectedSource -Message "Program Files precedence"
    $programFilesX86Resolution = Resolve-OrchestrationUnityExecutable -RequiredVersion "6000.0.69f1" -UnityExecutableOverride $null -UnityEditorPath $null -UnityHubEditorRoot $null -ProgramFilesRoot $null -ProgramFilesX86Root $programFilesX86Root
    Assert-Equal -Expected "ProgramFiles(x86)" -Actual $programFilesX86Resolution.selectedSource -Message "Program Files x86 precedence"
    Assert-Equal -Expected "UNITY_EDITOR_PATH|UNITY_HUB_EDITOR_ROOT|ProgramFiles|ProgramFiles(x86)" -Actual ([string]::Join("|", [string[]]@($editorResolution.candidates | ForEach-Object source))) -Message "Resolver candidate order is deterministic"

    $nearVersionRoot = Join-Path $resolverRoot "near-version-only"
    $nearVersionPath = Join-Path $nearVersionRoot "Unity\Hub\Editor\6000.0.70f1\Editor\Unity.exe"
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $nearVersionPath))
    Copy-Item -LiteralPath $fakeUnity -Destination $nearVersionPath
    $nearResolution = Resolve-OrchestrationUnityExecutable -RequiredVersion "6000.0.69f1" -UnityExecutableOverride $null -UnityEditorPath $null -UnityHubEditorRoot $null -ProgramFilesRoot $nearVersionRoot -ProgramFilesX86Root $null
    Assert-Equal -Expected "NOT_FOUND" -Actual $nearResolution.status -Message "Near Unity version is not selected"
    Assert-True -Condition ($nearResolution.candidates[0].path.Contains("6000.0.69f1")) -Message "Resolver checks exact required version directory"
    Assert-True -Condition (-not $nearResolution.candidates[0].path.Contains("6000.0.70f1")) -Message "Resolver never substitutes a nearby version"

    $missingOverride = Join-Path $resolverRoot "missing-override\Unity.exe"
    $missingOverrideResolution = Resolve-OrchestrationUnityExecutable -RequiredVersion "6000.0.69f1" -UnityExecutableOverride $missingOverride -UnityEditorPath $editorPath -UnityHubEditorRoot $hubRoot -ProgramFilesRoot $programFilesRoot -ProgramFilesX86Root $programFilesX86Root
    Assert-Equal -Expected "EXPLICIT_OVERRIDE" -Actual $missingOverrideResolution.status -Message "Missing explicit override does not silently fall back"
    Assert-Equal -Expected (Get-OrchestrationNormalizedPath $missingOverride) -Actual $missingOverrideResolution.selectedPath -Message "Missing override is preserved for verifier blocker evidence"

    $projectRoot = New-TestUnityProject -Name "default-current-directory"
    Initialize-TestGitMetadata -ProjectRoot $projectRoot
    $projectLocalPowerShell = Join-Path $projectRoot "powershell.exe"
    Copy-Item -LiteralPath $fakeUnity -Destination $projectLocalPowerShell
    $projectLocalUnity = Join-Path $projectRoot "Tools\Unity.exe"
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $projectLocalUnity))
    Copy-Item -LiteralPath $fakeUnity -Destination $projectLocalUnity
    $fakeExecutionMarker = Join-Path $script:ScratchRoot "markers\fake-executed.txt"
    $sourceBefore = Get-TestTreeSnapshot -Root $projectRoot
    $defaultResult = Invoke-OrchestratorCase `
        -CaseName "default-current-directory" `
        -ScriptPath $script:OrchestratorPath `
        -WorkingDirectory $projectRoot `
        -OmitProjectRoot `
        -OmitArtifactsRoot `
        -UnityExecutable $fakeUnity `
        -Environment @{
            PATH = $projectRoot + [System.IO.Path]::PathSeparator + [Environment]::GetEnvironmentVariable("PATH", "Process")
            ORCHESTRATION_FAKE_EXECUTED = $fakeExecutionMarker
        }
    Register-OrchestrationArtifacts -CaseResult $defaultResult
    $sourceAfter = Get-TestTreeSnapshot -Root $projectRoot
    Assert-Equal -Expected $sourceBefore -Actual $sourceAfter -Message "Default orchestration leaves source and .git byte-for-byte unchanged"
    Assert-Equal -Expected (Get-OrchestrationNormalizedPath $projectRoot) -Actual $defaultResult.result.projectRoot -Message "Omitted ProjectRoot uses exact current working directory"
    Assert-Equal -Expected "VERIFICATION_BLOCKED" -Actual $defaultResult.result.finalStatus -Message "Unsigned production fake remains blocked"
    Assert-Equal -Expected "1.1.0" -Actual $defaultResult.result.schemaVersion -Message "Forwarded Baseline schema version"
    Assert-Equal -Expected "0.1.2" -Actual $defaultResult.result.verifierVersion -Message "Forwarded low-level verifier version"
    Assert-Equal -Expected $true -Actual $defaultResult.result.doctor.accepted -Message "Automatically generated Doctor result accepted"
    Assert-Equal -Expected "0.2.1" -Actual $defaultResult.result.doctor.scannerVersion -Message "Bundled sibling Doctor scanner discovered automatically"
    Assert-Equal -Expected $false -Actual $defaultResult.result.unity.processStarted -Message "Unsigned fake never starts through production verifier"
    Assert-Contains -Collection @($defaultResult.result.blockers | ForEach-Object code) -Expected "UNITY_EXECUTABLE_SIGNATURE_INVALID" -Message "Production signature blocker preserved"
    Assert-True -Condition (-not (Test-Path -LiteralPath $fakeExecutionMarker)) -Message "Neither project-local PowerShell nor fake Unity executable ran"
    Assert-Equal -Expected 1 -Actual @(($defaultResult.raw.Trim()) -split '\r?\n').Count -Message "Compact stdout contains one JSON line"
    Assert-True -Condition ($defaultResult.raw.TrimStart().StartsWith("{", [System.StringComparison]::Ordinal)) -Message "Stdout begins directly with JSON"
    Assert-Equal -Expected "" -Actual $defaultResult.stderr.Trim() -Message "Normal blocked run emits no human stdout or unexpected stderr"
    foreach ($scopeName in @("tests", "playerBuild", "playMode", "runtime")) {
        Assert-Equal -Expected "NOT_VERIFIED" -Actual $defaultResult.result.verification.$scopeName.status -Message "$scopeName remains NOT_VERIFIED"
    }

    $savedDoctorPath = [string]$defaultResult.result.doctor.sourcePath
    $savedDoctorRaw = [System.IO.File]::ReadAllText($savedDoctorPath, $script:Utf8NoBom)
    $savedDoctorBytes = [System.IO.File]::ReadAllBytes($savedDoctorPath)
    $savedDoctor = $savedDoctorRaw | ConvertFrom-Json -ErrorAction Stop
    Assert-Equal -Expected "1.1.0" -Actual $savedDoctor.schemaVersion -Message "External raw Doctor schema"
    Assert-Equal -Expected "0.2.1" -Actual $savedDoctor.scannerVersion -Message "External raw Doctor scanner"
    Assert-True -Condition (-not (Test-OrchestrationPathWithinRoot -Path $savedDoctorPath -Root $projectRoot)) -Message "Doctor JSON is outside source project"
    Assert-True -Condition (-not ($savedDoctorBytes.Length -ge 3 -and $savedDoctorBytes[0] -eq 0xEF -and $savedDoctorBytes[1] -eq 0xBB -and $savedDoctorBytes[2] -eq 0xBF)) -Message "Doctor JSON is UTF-8 without BOM"
    Assert-True -Condition ($savedDoctorPath -match 'unity-baseline-orchestration-[0-9a-f]{32}\\doctor\\unity-project-doctor\.json$') -Message "Doctor artifact uses fixed session layout"
    $orchestrationSession = Split-Path -Parent (Split-Path -Parent $savedDoctorPath)
    Assert-Equal -Expected (Get-OrchestrationNormalizedPath (Join-Path $orchestrationSession "baseline")) -Actual (Get-OrchestrationNormalizedPath $defaultResult.result.isolation.artifactsRoot) -Message "Verifier artifacts are nested below orchestration baseline"
    Assert-True -Condition (Test-OrchestrationPathWithinRoot -Path $orchestrationSession -Root ([System.IO.Path]::GetTempPath())) -Message "Default artifacts use system temporary storage"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $savedDoctorPath) "doctor-stderr.log") -PathType Leaf) -Message "Doctor stderr log is external and present"

    $directDoctorProcess = Invoke-OrchestrationPowerShellScript -ScriptPath $script:ScannerPath -Arguments @("-ProjectRoot", $projectRoot) -WorkingDirectory $projectRoot
    Assert-Equal -Expected 0 -Actual $directDoctorProcess.exitCode -Message "Direct Doctor comparison exit code"
    Assert-Equal -Expected $directDoctorProcess.stdout -Actual $savedDoctorRaw -Message "Doctor stdout is preserved without reserialization"
    Assert-True -Condition ($savedDoctor.warnings.Count -gt 0) -Message "Doctor fixture contains warning evidence"
    Assert-Equal -Expected $savedDoctor.warnings.Count -Actual $defaultResult.result.doctor.warningCount -Message "Doctor warning count is preserved"
    Assert-Equal -Expected ([string]::Join("|", [string[]]@($savedDoctor.warnings | ForEach-Object code))) -Actual ([string]::Join("|", [string[]]@($defaultResult.result.doctor.warnings | ForEach-Object code))) -Message "Doctor warning codes are preserved"

    $prettyArtifacts = Join-Path $script:ScratchRoot "cases\pretty\artifacts"
    $prettyResult = Invoke-OrchestratorCase `
        -CaseName "pretty-auto-editor-path" `
        -ScriptPath $script:OrchestratorPath `
        -WorkingDirectory $projectRoot `
        -ProjectRoot $projectRoot `
        -ArtifactsRoot $prettyArtifacts `
        -Pretty `
        -Environment @{
            UNITY_EDITOR_PATH = $projectLocalUnity
            UNITY_HUB_EDITOR_ROOT = (Join-Path $script:ScratchRoot "must-not-win-hub")
            ORCHESTRATION_FAKE_EXECUTED = $fakeExecutionMarker
        }
    Register-OrchestrationArtifacts -CaseResult $prettyResult
    Assert-True -Condition (@(($prettyResult.raw.Trim()) -split '\r?\n').Count -gt 1) -Message "Pretty stdout contains formatted JSON"
    Assert-Equal -Expected $defaultResult.result.finalStatus -Actual $prettyResult.result.finalStatus -Message "Pretty preserves final-status meaning"
    Assert-Equal -Expected $defaultResult.result.schemaVersion -Actual $prettyResult.result.schemaVersion -Message "Pretty preserves schema meaning"
    Assert-Equal -Expected $defaultResult.result.doctor.warningCount -Actual $prettyResult.result.doctor.warningCount -Message "Pretty preserves Doctor warnings"
    Assert-Equal -Expected (Get-OrchestrationNormalizedPath $projectLocalUnity) -Actual (Get-OrchestrationNormalizedPath $prettyResult.result.unity.executablePath) -Message "UNITY_EDITOR_PATH auto-resolution reaches verifier"
    Assert-Contains -Collection @($prettyResult.result.blockers | ForEach-Object code) -Expected "UNITY_EXECUTABLE_INVALID" -Message "Project-local auto-resolved Unity is blocked before execution"
    Assert-True -Condition ((@($prettyResult.result.blockers | Where-Object code -eq "UNITY_EXECUTABLE_INVALID" | ForEach-Object message) -join " ").Contains("inside the original project")) -Message "Project-local Unity blocker preserves exact safety reason"
    Assert-Equal -Expected $prettyResult.raw.TrimEnd("`r", "`n") -Actual ([System.IO.File]::ReadAllText($prettyResult.result.artifacts.resultPath, $script:Utf8NoBom)).TrimEnd("`r", "`n") -Message "Final stdout is the low-level verifier result artifact"
    Assert-True -Condition (-not (Test-Path -LiteralPath $fakeExecutionMarker)) -Message "Pretty auto-resolution still cannot run unsigned fake"

    $containerRoot = Join-Path $script:ScratchRoot "exact-root-container"
    [void][System.IO.Directory]::CreateDirectory($containerRoot)
    $nestedProject = New-TestUnityProject -Name "nested-unity-project"
    Copy-Item -LiteralPath $nestedProject -Destination (Join-Path $containerRoot "NestedUnity") -Recurse
    $nestedProject = Join-Path $containerRoot "NestedUnity"
    $containerResult = Invoke-OrchestratorCase -CaseName "no-child-search" -ScriptPath $script:OrchestratorPath -WorkingDirectory $containerRoot -ProjectRoot $containerRoot -ArtifactsRoot (Join-Path $script:ScratchRoot "cases\no-child-search") -UnityExecutable $fakeUnity
    Register-OrchestrationArtifacts -CaseResult $containerResult
    $containerDoctor = [System.IO.File]::ReadAllText((Join-Path (Split-Path -Parent $containerResult.result.doctor.sourcePath) "unity-project-doctor.json"), $script:Utf8NoBom) | ConvertFrom-Json
    Assert-Equal -Expected "NOT_A_UNITY_PROJECT" -Actual $containerDoctor.finalStatus -Message "Orchestrator does not search a child Unity project"
    Assert-Equal -Expected (Get-OrchestrationNormalizedPath $containerRoot) -Actual $containerResult.result.projectRoot -Message "Container remains the exact ProjectRoot"
    Assert-Equal -Expected $false -Actual $containerResult.result.unity.processStarted -Message "Non-Unity exact root prevents Unity"

    $assetsDoctorProcess = Invoke-OrchestrationPowerShellScript -ScriptPath $script:ScannerPath -Arguments @("-ProjectRoot", (Join-Path $projectRoot "Assets")) -WorkingDirectory (Join-Path $projectRoot "Assets")
    $assetsDoctor = $assetsDoctorProcess.stdout | ConvertFrom-Json
    Assert-Equal -Expected "NOT_A_UNITY_PROJECT" -Actual $assetsDoctor.finalStatus -Message "Bundled scanner does not search a parent Unity project"

    $insideArtifacts = Join-Path $projectRoot "forbidden-artifacts"
    $insideBefore = Get-TestTreeSnapshot -Root $projectRoot
    $insideResult = Invoke-OrchestratorCase -CaseName "artifact-inside-project" -ScriptPath $script:OrchestratorPath -WorkingDirectory $projectRoot -ProjectRoot $projectRoot -ArtifactsRoot ".\forbidden-artifacts" -UnityExecutable $fakeUnity
    Register-OrchestrationArtifacts -CaseResult $insideResult
    Assert-Contains -Collection @($insideResult.result.blockers | ForEach-Object code) -Expected "ARTIFACT_ROOT_UNSAFE" -Message "In-project artifact root returns structured blocker"
    Assert-True -Condition (-not (Test-Path -LiteralPath $insideArtifacts)) -Message "In-project artifact root is never created"
    Assert-Equal -Expected $insideBefore -Actual (Get-TestTreeSnapshot -Root $projectRoot) -Message "Unsafe artifact request leaves source unchanged"
    Assert-Equal -Expected $false -Actual $insideResult.result.unity.processStarted -Message "Unsafe artifact root prevents Unity"

    $reparseTarget = Join-Path $script:ScratchRoot "reparse-artifact-target"
    $reparseLink = Join-Path $script:ScratchRoot "reparse-artifact-link"
    [void][System.IO.Directory]::CreateDirectory($reparseTarget)
    New-Item -ItemType Junction -Path $reparseLink -Target $reparseTarget -ErrorAction Stop | Out-Null
    $reparseArtifactChild = Join-Path $reparseLink "nested-artifacts"
    $reparseResult = Invoke-OrchestratorCase -CaseName "artifact-reparse" -ScriptPath $script:OrchestratorPath -WorkingDirectory $projectRoot -ProjectRoot $projectRoot -ArtifactsRoot $reparseArtifactChild -UnityExecutable $fakeUnity
    Register-OrchestrationArtifacts -CaseResult $reparseResult
    Assert-Contains -Collection @($reparseResult.result.blockers | ForEach-Object code) -Expected "ARTIFACT_ROOT_UNSAFE" -Message "Reparse artifact root returns structured blocker"
    Assert-Equal -Expected 0 -Actual @(Get-ChildItem -LiteralPath $reparseTarget -Force).Count -Message "No artifact is written through reparse root"
    Assert-Equal -Expected $false -Actual $reparseResult.result.unity.processStarted -Message "Reparse artifact root prevents Unity"

    $projectReparseLink = Join-Path $script:ScratchRoot "project-root-link"
    New-Item -ItemType Junction -Path $projectReparseLink -Target $projectRoot -ErrorAction Stop | Out-Null
    $projectReparseBefore = Get-TestTreeSnapshot -Root $projectRoot
    $projectReparseResult = Invoke-OrchestratorCase -CaseName "project-root-reparse" -ScriptPath $script:OrchestratorPath -WorkingDirectory $script:ScratchRoot -ProjectRoot $projectReparseLink -ArtifactsRoot (Join-Path $script:ScratchRoot "cases\project-root-reparse") -UnityExecutable $fakeUnity
    Register-OrchestrationArtifacts -CaseResult $projectReparseResult
    Assert-Contains -Collection @($projectReparseResult.result.blockers | ForEach-Object code) -Expected "PROJECT_ROOT_INVALID" -Message "Reparse ProjectRoot returns structured blocker"
    Assert-Equal -Expected $false -Actual $projectReparseResult.result.unity.processStarted -Message "Reparse ProjectRoot prevents Unity"
    Assert-Equal -Expected $projectReparseBefore -Actual (Get-TestTreeSnapshot -Root $projectRoot) -Message "Reparse ProjectRoot leaves target project unchanged"
    $projectReparseDoctorDirectory = Split-Path -Parent $projectReparseResult.result.doctor.sourcePath
    Assert-Equal -Expected 0 -Actual (Get-Item -LiteralPath (Join-Path $projectReparseDoctorDirectory "unity-project-doctor.json")).Length -Message "Reparse ProjectRoot never starts Doctor scanner"

    $nonzeroStub = @'
[CmdletBinding()]
param([string]$ProjectRoot)
$encoding = New-Object System.Text.UTF8Encoding($false)
$text = [System.IO.File]::ReadAllText($env:ORCHESTRATION_TEST_DOCTOR_PATH, $encoding)
[Console]::OutputEncoding = $encoding
[Console]::Out.Write($text)
[Console]::Error.WriteLine("fixture scanner exited nonzero")
exit 9
'@
    $nonzeroHarness = New-OrchestrationHarness -Name "scanner-nonzero" -ScannerStub $nonzeroStub
    $nonzeroResult = Invoke-OrchestratorCase -CaseName "scanner-nonzero" -ScriptPath $nonzeroHarness -WorkingDirectory $projectRoot -ProjectRoot $projectRoot -ArtifactsRoot (Join-Path $script:ScratchRoot "cases\scanner-nonzero") -UnityExecutable $fakeUnity -Environment @{
        ORCHESTRATION_TEST_DOCTOR_PATH = $savedDoctorPath
        ORCHESTRATION_FAKE_EXECUTED = $fakeExecutionMarker
    }
    Register-OrchestrationArtifacts -CaseResult $nonzeroResult
    Assert-Equal -Expected "VERIFICATION_BLOCKED" -Actual $nonzeroResult.result.finalStatus -Message "Nonzero scanner becomes Baseline blocker"
    Assert-Equal -Expected $false -Actual $nonzeroResult.result.unity.processStarted -Message "Nonzero scanner prevents Unity"
    Assert-Contains -Collection @($nonzeroResult.result.doctor.validationErrors | ForEach-Object code) -Expected "DOCTOR_RESULT_NOT_FOUND" -Message "Nonzero scanner uses an unusable Doctor handoff"
    $nonzeroDoctorDirectory = Split-Path -Parent $nonzeroResult.result.doctor.sourcePath
    Assert-Equal -Expected $savedDoctorRaw -Actual ([System.IO.File]::ReadAllText((Join-Path $nonzeroDoctorDirectory "unity-project-doctor.json"), $script:Utf8NoBom)) -Message "Nonzero scanner raw stdout is still preserved"
    Assert-True -Condition (([System.IO.File]::ReadAllText((Join-Path $nonzeroDoctorDirectory "doctor-stderr.log"), $script:Utf8NoBom)).Contains("fixture scanner exited nonzero")) -Message "Nonzero scanner stderr is preserved separately"
    Assert-True -Condition (-not (Test-Path -LiteralPath $fakeExecutionMarker)) -Message "Nonzero scanner never permits fake execution"

    $malformedStub = @'
[CmdletBinding()]
param([string]$ProjectRoot)
$encoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $encoding
[Console]::Out.Write("not-json with progress text")
exit 0
'@
    $malformedHarness = New-OrchestrationHarness -Name "scanner-malformed" -ScannerStub $malformedStub
    $malformedResult = Invoke-OrchestratorCase -CaseName "scanner-malformed" -ScriptPath $malformedHarness -WorkingDirectory $projectRoot -ProjectRoot $projectRoot -ArtifactsRoot (Join-Path $script:ScratchRoot "cases\scanner-malformed") -UnityExecutable $fakeUnity -Environment @{
        ORCHESTRATION_FAKE_EXECUTED = $fakeExecutionMarker
    }
    Register-OrchestrationArtifacts -CaseResult $malformedResult
    Assert-Equal -Expected "VERIFICATION_BLOCKED" -Actual $malformedResult.result.finalStatus -Message "Malformed scanner stdout becomes Baseline blocker"
    Assert-Equal -Expected $false -Actual $malformedResult.result.unity.processStarted -Message "Malformed scanner stdout prevents Unity"
    Assert-Contains -Collection @($malformedResult.result.doctor.validationErrors | ForEach-Object code) -Expected "DOCTOR_RESULT_NOT_FOUND" -Message "Malformed scanner uses an unusable Doctor handoff"
    $malformedDoctorDirectory = Split-Path -Parent $malformedResult.result.doctor.sourcePath
    Assert-Equal -Expected "not-json with progress text" -Actual ([System.IO.File]::ReadAllText((Join-Path $malformedDoctorDirectory "unity-project-doctor.json"), $script:Utf8NoBom)) -Message "Malformed scanner stdout is preserved verbatim"
    Assert-True -Condition (-not (Test-Path -LiteralPath $fakeExecutionMarker)) -Message "Malformed scanner never permits fake execution"

    $emptyStub = @'
[CmdletBinding()]
param([string]$ProjectRoot)
[Console]::Error.WriteLine("fixture scanner returned empty stdout")
exit 0
'@
    $emptyHarness = New-OrchestrationHarness -Name "scanner-empty" -ScannerStub $emptyStub
    $emptyResult = Invoke-OrchestratorCase -CaseName "scanner-empty" -ScriptPath $emptyHarness -WorkingDirectory $projectRoot -ProjectRoot $projectRoot -ArtifactsRoot (Join-Path $script:ScratchRoot "cases\scanner-empty") -UnityExecutable $fakeUnity -Environment @{
        ORCHESTRATION_FAKE_EXECUTED = $fakeExecutionMarker
    }
    Register-OrchestrationArtifacts -CaseResult $emptyResult
    Assert-Equal -Expected "VERIFICATION_BLOCKED" -Actual $emptyResult.result.finalStatus -Message "Empty scanner stdout becomes Baseline blocker"
    Assert-Equal -Expected $false -Actual $emptyResult.result.unity.processStarted -Message "Empty scanner stdout prevents Unity"
    Assert-Contains -Collection @($emptyResult.result.doctor.validationErrors | ForEach-Object code) -Expected "DOCTOR_RESULT_NOT_FOUND" -Message "Empty scanner uses an unusable Doctor handoff"
    $emptyDoctorDirectory = Split-Path -Parent $emptyResult.result.doctor.sourcePath
    Assert-Equal -Expected 0 -Actual (Get-Item -LiteralPath (Join-Path $emptyDoctorDirectory "unity-project-doctor.json")).Length -Message "Empty scanner stdout is preserved as an empty raw artifact"
    Assert-True -Condition (([System.IO.File]::ReadAllText((Join-Path $emptyDoctorDirectory "doctor-stderr.log"), $script:Utf8NoBom)).Contains("fixture scanner returned empty stdout")) -Message "Empty scanner stderr is preserved separately"
    Assert-True -Condition (-not (Test-Path -LiteralPath $fakeExecutionMarker)) -Message "Empty scanner never permits fake execution"

    Assert-Equal -Expected $fixturesBefore -Actual (Get-TestTreeSnapshot -Root $fixtureRoot) -Message "Orchestration tests leave source fixtures unchanged"
    Assert-Equal -Expected $sourceBefore -Actual (Get-TestTreeSnapshot -Root $projectRoot) -Message "All orchestration cases leave source project and .git unchanged"

    $script:TestsPassed = $true
    Write-Host "All orchestration tests passed. Assertions: $($script:Assertions)"
} finally {
    if ($script:TestsPassed) {
        Remove-OrchestrationTestArtifacts
    } else {
        Write-Host "Orchestration test scratch retained for diagnosis: $script:ScratchRoot"
    }
}
