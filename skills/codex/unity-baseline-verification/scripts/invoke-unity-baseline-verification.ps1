[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [AllowEmptyString()]
    [string]$ProjectRoot = (Get-Location).Path,

    [Parameter()]
    [AllowNull()]
    [string]$UnityExecutable,

    [Parameter()]
    [AllowNull()]
    [string]$ArtifactsRoot,

    [Parameter()]
    [int]$TimeoutSeconds = 1800,

    [Parameter()]
    [switch]$Pretty
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:OrchestratorVersion = "0.1.0"
$script:BaselineComponentVersion = "0.2.0"
$script:SupportedUnityVersion = "6000.0.69f1"
$script:LibraryPath = Join-Path -Path $PSScriptRoot -ChildPath "lib\unity-baseline-orchestration.ps1"
$script:VerifierPath = Join-Path -Path $PSScriptRoot -ChildPath "verify-unity-baseline.ps1"
$script:BaselineSkillRoot = Split-Path -Parent $PSScriptRoot
$script:CodexSkillsRoot = Split-Path -Parent $script:BaselineSkillRoot
$script:DoctorScannerPath = Join-Path -Path $script:CodexSkillsRoot -ChildPath "unity-project-doctor\scripts\inspect-unity-project.ps1"

[Console]::OutputEncoding = $script:Utf8NoBom

if (-not (Test-Path -LiteralPath $script:LibraryPath -PathType Leaf)) {
    [Console]::Error.WriteLine("Orchestration library was not found: $script:LibraryPath")
    exit 1
}
. $script:LibraryPath

# Writes one diagnostic line to stderr without contaminating the JSON stdout contract.
function Write-OrchestrationDiagnostic {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    [Console]::Error.WriteLine("[unity-baseline-orchestration] $Message")
}

# Writes exact text using UTF-8 without a byte-order mark.
function Write-OrchestrationText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $reparsePoint = Get-OrchestrationReparsePointOnPath -Path $Path
    if ($null -ne $reparsePoint) {
        throw "Refusing to write an orchestration artifact through reparse point $reparsePoint."
    }
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [void][System.IO.Directory]::CreateDirectory($parent)
    }
    [void][System.IO.File]::WriteAllText($Path, $Content, $script:Utf8NoBom)
}

# Validates an artifact root without creating it or traversing a reparse point.
function Test-OrchestrationArtifactRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter()]
        [AllowNull()]
        [string]$NormalizedProjectRoot
    )

    $normalizedPath = $null
    try {
        $normalizedPath = Get-OrchestrationNormalizedPath -Path $Path
        if (
            -not [string]::IsNullOrWhiteSpace($NormalizedProjectRoot) -and
            (Test-OrchestrationPathWithinRoot -Path $normalizedPath -Root $NormalizedProjectRoot)
        ) {
            throw "The artifact root is inside the original project."
        }
        $reparsePoint = Get-OrchestrationReparsePointOnPath -Path $normalizedPath
        if ($null -ne $reparsePoint) {
            throw "The artifact root traverses reparse point $reparsePoint."
        }
        if (Test-Path -LiteralPath $normalizedPath -PathType Leaf) {
            throw "The artifact root is an existing file."
        }
        return [pscustomobject][ordered]@{
            safe = $true
            normalizedPath = $normalizedPath
            error = $null
        }
    } catch {
        return [pscustomobject][ordered]@{
            safe = $false
            normalizedPath = $normalizedPath
            error = $_.Exception.Message
        }
    }
}

# Creates one unique external orchestration session and its fixed subdirectories.
function New-OrchestrationArtifactSession {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $normalizedRoot = Get-OrchestrationNormalizedPath -Path $Root
    $rootReparsePoint = Get-OrchestrationReparsePointOnPath -Path $normalizedRoot
    if ($null -ne $rootReparsePoint) {
        throw "The orchestration root traverses reparse point $rootReparsePoint."
    }
    [void][System.IO.Directory]::CreateDirectory($normalizedRoot)
    $rootReparsePoint = Get-OrchestrationReparsePointOnPath -Path $normalizedRoot
    if ($null -ne $rootReparsePoint) {
        throw "The created orchestration root traverses reparse point $rootReparsePoint."
    }
    $sessionRoot = Join-Path -Path $normalizedRoot -ChildPath (
        "unity-baseline-orchestration-" + [guid]::NewGuid().ToString("N")
    )
    $doctorRoot = Join-Path -Path $sessionRoot -ChildPath "doctor"
    $baselineRoot = Join-Path -Path $sessionRoot -ChildPath "baseline"
    [void][System.IO.Directory]::CreateDirectory($doctorRoot)
    [void][System.IO.Directory]::CreateDirectory($baselineRoot)
    $sessionReparsePoint = Get-OrchestrationReparsePointOnPath -Path $sessionRoot
    if ($null -ne $sessionReparsePoint) {
        throw "The orchestration session traverses reparse point $sessionReparsePoint."
    }

    return [pscustomobject][ordered]@{
        sessionRoot = Get-OrchestrationNormalizedPath -Path $sessionRoot
        doctorRoot = Get-OrchestrationNormalizedPath -Path $doctorRoot
        baselineRoot = Get-OrchestrationNormalizedPath -Path $baselineRoot
        doctorResultPath = Join-Path -Path $doctorRoot -ChildPath "unity-project-doctor.json"
        doctorStderrPath = Join-Path -Path $doctorRoot -ChildPath "doctor-stderr.log"
    }
}

# Reads only the Doctor editor-version field needed for deterministic executable resolution.
function Get-OrchestrationDoctorUnityVersion {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Doctor
    )

    $versionContainer = $Doctor.PSObject.Properties["unityEditorVersion"]
    if ($null -eq $versionContainer -or $null -eq $versionContainer.Value) {
        return $null
    }
    $versionProperty = $versionContainer.Value.PSObject.Properties["editorVersion"]
    if ($null -eq $versionProperty) {
        return $null
    }
    return [string]$versionProperty.Value
}

$normalizedProjectRoot = $null
$projectRootSafe = $false
try {
    $normalizedProjectRoot = Get-OrchestrationNormalizedPath -Path $ProjectRoot
    if (-not (Test-Path -LiteralPath $normalizedProjectRoot -PathType Container)) {
        throw "ProjectRoot is not an existing directory."
    }
    $projectReparsePoint = Get-OrchestrationReparsePointOnPath -Path $normalizedProjectRoot
    if ($null -ne $projectReparsePoint) {
        throw "ProjectRoot traverses reparse point $projectReparsePoint."
    }
    $projectRootSafe = $true
} catch {
    Write-OrchestrationDiagnostic -Message "ProjectRoot preflight failed; the low-level verifier will return the structured blocker: $($_.Exception.Message)"
}

$defaultArtifactsRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "unity-baseline-verification"
$requestedArtifactsRoot = if ([string]::IsNullOrWhiteSpace($ArtifactsRoot)) {
    $defaultArtifactsRoot
} else {
    $ArtifactsRoot
}
$artifactAssessment = Test-OrchestrationArtifactRoot -Path $requestedArtifactsRoot -NormalizedProjectRoot $normalizedProjectRoot
$verifierArtifactsRoot = $null
$session = $null
if ($artifactAssessment.safe) {
    try {
        $session = New-OrchestrationArtifactSession -Root $artifactAssessment.normalizedPath
        $verifierArtifactsRoot = $session.baselineRoot
    } catch {
        Write-OrchestrationDiagnostic -Message "Requested ArtifactsRoot could not host an orchestration session; no project artifact was created: $($_.Exception.Message)"
    }
}
if ($null -eq $session) {
    if (-not $artifactAssessment.safe) {
        Write-OrchestrationDiagnostic -Message "Requested ArtifactsRoot is unsafe; no artifact will be created there: $($artifactAssessment.error)"
    }
    $fallbackAssessment = Test-OrchestrationArtifactRoot -Path $defaultArtifactsRoot -NormalizedProjectRoot $normalizedProjectRoot
    if (-not $fallbackAssessment.safe) {
        Write-OrchestrationDiagnostic -Message "No safe system-temporary orchestration root is available: $($fallbackAssessment.error)"
        exit 1
    }
    try {
        $session = New-OrchestrationArtifactSession -Root $fallbackAssessment.normalizedPath
    } catch {
        Write-OrchestrationDiagnostic -Message "No system-temporary orchestration session could be created: $($_.Exception.Message)"
        exit 1
    }
    $verifierArtifactsRoot = if ($null -ne $artifactAssessment.normalizedPath) {
        $artifactAssessment.normalizedPath
    } else {
        $requestedArtifactsRoot
    }
}

$doctorStdout = ""
$doctorStderr = ""
$doctorUsable = $false
$doctorObject = $null
$requiredUnityVersion = $null
if ($projectRootSafe) {
    try {
        $doctorProcess = Invoke-OrchestrationPowerShellScript `
            -ScriptPath $script:DoctorScannerPath `
            -Arguments @("-ProjectRoot", $normalizedProjectRoot) `
            -WorkingDirectory $normalizedProjectRoot
        $doctorStdout = [string]$doctorProcess.stdout
        $doctorStderr = [string]$doctorProcess.stderr
        if ($doctorProcess.exitCode -ne 0) {
            throw "Doctor scanner exited with code $($doctorProcess.exitCode)."
        }
        if ([string]::IsNullOrWhiteSpace($doctorStdout)) {
            throw "Doctor scanner produced empty stdout."
        }
        $doctorObject = ConvertFrom-Json -InputObject $doctorStdout -ErrorAction Stop
        $requiredUnityVersion = Get-OrchestrationDoctorUnityVersion -Doctor $doctorObject
        $doctorUsable = $true
    } catch {
        if ([string]::IsNullOrWhiteSpace($doctorStderr)) {
            $doctorStderr = $_.Exception.Message + [Environment]::NewLine
        }
        Write-OrchestrationDiagnostic -Message "Doctor handoff failed; Unity will not start: $($_.Exception.Message)"
    }
} else {
    $doctorStderr = "Doctor scanner was not started because ProjectRoot preflight failed." + [Environment]::NewLine
}
try {
    Write-OrchestrationText -Path $session.doctorResultPath -Content $doctorStdout
    Write-OrchestrationText -Path $session.doctorStderrPath -Content $doctorStderr
} catch {
    $doctorUsable = $false
    Write-OrchestrationDiagnostic -Message "Doctor artifacts could not be preserved safely; Unity will not start: $($_.Exception.Message)"
}

$doctorInputPath = if ($doctorUsable) {
    $session.doctorResultPath
} else {
    Join-Path -Path $session.doctorRoot -ChildPath "unusable-doctor-result.json"
}

$resolvedUnityPath = $null
if ($doctorUsable -and $requiredUnityVersion -eq $script:SupportedUnityVersion) {
    $unityResolution = Resolve-OrchestrationUnityExecutable `
        -RequiredVersion $requiredUnityVersion `
        -UnityExecutableOverride $UnityExecutable `
        -UnityEditorPath ([Environment]::GetEnvironmentVariable("UNITY_EDITOR_PATH", "Process")) `
        -UnityHubEditorRoot ([Environment]::GetEnvironmentVariable("UNITY_HUB_EDITOR_ROOT", "Process")) `
        -ProgramFilesRoot ([Environment]::GetEnvironmentVariable("ProgramFiles", "Process")) `
        -ProgramFilesX86Root ([Environment]::GetEnvironmentVariable("ProgramFiles(x86)", "Process"))
    $resolvedUnityPath = $unityResolution.selectedPath
    if ([string]::IsNullOrWhiteSpace($resolvedUnityPath)) {
        Write-OrchestrationDiagnostic -Message "Exact Unity $requiredUnityVersion executable was not found in the approved candidate locations. Use -UnityExecutable for an explicit override."
    }
} elseif ($doctorUsable) {
    Write-OrchestrationDiagnostic -Message "Doctor requires unsupported Unity version '$requiredUnityVersion'; only $($script:SupportedUnityVersion) is approved."
}
if ([string]::IsNullOrWhiteSpace($resolvedUnityPath)) {
    $resolvedUnityPath = Join-Path -Path $session.sessionRoot -ChildPath "missing-unity\Unity.exe"
}

$verifierArguments = @(
    "-ProjectRoot", $(if ($null -ne $normalizedProjectRoot) { $normalizedProjectRoot } else { $ProjectRoot }),
    "-DoctorResultPath", $doctorInputPath,
    "-UnityExecutable", $resolvedUnityPath,
    "-ArtifactsRoot", $verifierArtifactsRoot,
    "-TimeoutSeconds", [string]$TimeoutSeconds
)
if ($Pretty) {
    $verifierArguments += "-Pretty"
}

try {
    $verifierProcess = Invoke-OrchestrationPowerShellScript `
        -ScriptPath $script:VerifierPath `
        -Arguments ([string[]]$verifierArguments) `
        -WorkingDirectory $session.sessionRoot
    if (-not [string]::IsNullOrWhiteSpace([string]$verifierProcess.stderr)) {
        [Console]::Error.Write([string]$verifierProcess.stderr)
    }
    if ($verifierProcess.exitCode -ne 0) {
        throw "Low-level verifier exited with code $($verifierProcess.exitCode)."
    }
    if ([string]::IsNullOrWhiteSpace([string]$verifierProcess.stdout)) {
        throw "Low-level verifier produced empty stdout."
    }
    [void](ConvertFrom-Json -InputObject ([string]$verifierProcess.stdout) -ErrorAction Stop)
    [Console]::Out.Write([string]$verifierProcess.stdout)
} catch {
    Write-OrchestrationDiagnostic -Message "The low-level verifier did not return one valid JSON document: $($_.Exception.Message)"
    exit 1
}
