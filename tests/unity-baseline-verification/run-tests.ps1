[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:RepositoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $PSScriptRoot))).TrimEnd("\", "/")
$script:VerifierPath = Join-Path -Path $script:RepositoryRoot -ChildPath "skills\codex\unity-baseline-verification\scripts\verify-unity-baseline.ps1"
$script:ScannerPath = Join-Path -Path $script:RepositoryRoot -ChildPath "skills\codex\unity-project-doctor\scripts\inspect-unity-project.ps1"
$script:SchemaPath = Join-Path -Path $script:RepositoryRoot -ChildPath "schemas\unity-project-audit-1.1.0.schema.json"
$script:SchemaValidatorPath = Join-Path -Path $script:RepositoryRoot -ChildPath "skills\codex\unity-baseline-verification\scripts\lib\json-schema-validator.ps1"
$script:ProcessLibraryPath = Join-Path -Path $script:RepositoryRoot -ChildPath "skills\codex\unity-baseline-verification\scripts\lib\unity-process-job.ps1"
$script:EditorLogLibraryPath = Join-Path -Path $script:RepositoryRoot -ChildPath "skills\codex\unity-baseline-verification\scripts\lib\unity-editor-log.ps1"
$script:GitIntegrityLibraryPath = Join-Path -Path $script:RepositoryRoot -ChildPath "skills\codex\unity-baseline-verification\scripts\lib\git-metadata-integrity.ps1"
$script:IsolationPathBudgetLibraryPath = Join-Path -Path $script:RepositoryRoot -ChildPath "skills\codex\unity-baseline-verification\scripts\lib\unity-isolation-path-budget.ps1"
$script:FingerprintLibraryPath = Join-Path -Path $script:RepositoryRoot -ChildPath "skills\codex\unity-project-doctor\scripts\lib\unity-project-fingerprint.ps1"
$script:OrchestratorPath = Join-Path -Path $script:RepositoryRoot -ChildPath "skills\codex\unity-baseline-verification\scripts\invoke-unity-baseline-verification.ps1"
$script:OrchestrationLibraryPath = Join-Path -Path $script:RepositoryRoot -ChildPath "skills\codex\unity-baseline-verification\scripts\lib\unity-baseline-orchestration.ps1"
$script:OrchestrationTestsPath = Join-Path -Path $script:RepositoryRoot -ChildPath "tests\unity-baseline-verification\orchestration\run-tests.ps1"
$script:SourceEditorFixtureHarnessPath = Join-Path -Path $script:RepositoryRoot -ChildPath "tests\unity-baseline-verification\helpers\invoke-verifier-with-source-editor-fixture.ps1"
$script:InstallerPath = Join-Path -Path $script:RepositoryRoot -ChildPath "scripts\install-codex-skills.ps1"
$script:ScratchRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("unity-baseline-verification-tests-" + [guid]::NewGuid().ToString("N"))
$script:Assertions = 0
$script:TestsPassed = $false

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

# Throws when two scalar values are not equal.
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

# Throws when an enumerable does not contain the expected scalar value.
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

# Returns a stable absolute path with trailing separators removed.
function Get-NormalizedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals($fullPath, $root)) {
        return $fullPath
    }
    return $fullPath.TrimEnd("\", "/")
}

# Tests whether one path is equal to or below another path.
function Test-PathWithinRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $normalizedPath = Get-NormalizedPath -Path $Path
    $normalizedRoot = Get-NormalizedPath -Path $Root
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals($normalizedPath, $normalizedRoot)) {
        return $true
    }
    return $normalizedPath.StartsWith(
        $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

# Builds one relative test path whose normalized destination has an exact length.
function New-TestRelativePathForDestinationLength {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot,

        [Parameter(Mandatory = $true)]
        [int]$TargetLength,

        [Parameter()]
        [switch]$File
    )

    $normalizedRoot = Get-NormalizedPath -Path $DestinationRoot
    $relativeLength = $TargetLength - $normalizedRoot.Length - 1
    $suffix = if ($File) { ".cs" } else { "" }
    if ($relativeLength -le $suffix.Length) {
        throw "Target length $TargetLength is too short for destination root $normalizedRoot."
    }

    return ("p" * ($relativeLength - $suffix.Length)) + $suffix
}

# Captures a compact file-list and SHA-256 snapshot with an optional top-level .git exclusion.
function Get-TestTreeSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter()]
        [switch]$ExcludeGitMetadata
    )

    $normalizedRoot = Get-NormalizedPath -Path $Root
    $lines = New-Object System.Collections.ArrayList
    $directories = @(
        Get-ChildItem -LiteralPath $normalizedRoot -Directory -Force -Recurse |
            Sort-Object -Property FullName
    )
    foreach ($directory in $directories) {
        $relative = $directory.FullName.Substring($normalizedRoot.Length + 1).Replace("\", "/")
        if ($ExcludeGitMetadata -and ($relative -eq '.git' -or $relative.StartsWith('.git/', [System.StringComparison]::OrdinalIgnoreCase))) {
            continue
        }
        [void]$lines.Add("D|$relative")
    }
    $files = @(
        Get-ChildItem -LiteralPath $normalizedRoot -File -Force -Recurse |
            Sort-Object -Property FullName
    )
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($normalizedRoot.Length + 1).Replace("\", "/")
        if ($ExcludeGitMetadata -and ($relative -eq '.git' -or $relative.StartsWith('.git/', [System.StringComparison]::OrdinalIgnoreCase))) {
            continue
        }
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
        [void]$lines.Add("F|$relative|$($file.Length)|$hash")
    }
    return [string]::Join([char]10, [string[]]@($lines))
}

# Writes one UTF-8 text file after creating its parent directory.
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

# Creates a minimal source Unity project plus generated trees that must be excluded.
function New-TestUnityProject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter()]
        [AllowNull()]
        [string]$ManifestContent
    )

    $projectRoot = Join-Path -Path $script:ScratchRoot -ChildPath ("projects\" + $Name)
    [void][System.IO.Directory]::CreateDirectory($projectRoot)
    Write-TestText -Path (Join-Path $projectRoot "Assets\Scripts\Probe.cs") -Content "public sealed class Probe { public int Value = 1; }"
    if ([string]::IsNullOrWhiteSpace($ManifestContent)) {
        $ManifestContent = '{"dependencies":{"com.unity.modules.jsonserialize":"1.0.0"}}'
    }
    Write-TestText -Path (Join-Path $projectRoot "Packages\manifest.json") -Content $ManifestContent
    Write-TestText -Path (Join-Path $projectRoot "Packages\packages-lock.json") -Content '{"dependencies":{"com.unity.modules.jsonserialize":{"version":"1.0.0","depth":0,"source":"builtin","dependencies":{}}}}'
    $versionLines = @(
        "m_EditorVersion: 6000.0.69f1",
        "m_EditorVersionWithRevision: 6000.0.69f1 (5f8607f5118b)"
    )
    Write-TestText -Path (Join-Path $projectRoot "ProjectSettings\ProjectVersion.txt") -Content ([string]::Join([Environment]::NewLine, $versionLines) + [Environment]::NewLine)
    Write-TestText -Path (Join-Path $projectRoot "Library\Generated.cache") -Content "generated-library"
    Write-TestText -Path (Join-Path $projectRoot "Temp\Generated.tmp") -Content "generated-temp"
    Write-TestText -Path (Join-Path $projectRoot "Logs\Editor.log") -Content "historical-log"
    Write-TestText -Path (Join-Path $projectRoot "UserSettings\EditorUserSettings.asset") -Content "user-settings"
    $fixtureSkillLines = @("---", "name: fixture", "description: fixture", "---")
    Write-TestText -Path (Join-Path $projectRoot ".agents\skills\fixture\SKILL.md") -Content ([string]::Join([Environment]::NewLine, $fixtureSkillLines))
    return Get-NormalizedPath -Path $projectRoot
}

# Creates minimal in-project Git metadata for deterministic integrity classification tests.
function Initialize-TestGitMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot
    )

    Write-TestText -Path (Join-Path $ProjectRoot '.git\HEAD') -Content "ref: refs/heads/main`n"
    Write-TestText -Path (Join-Path $ProjectRoot '.git\config') -Content "[core]`nrepositoryformatversion = 0`n"
    Write-TestText -Path (Join-Path $ProjectRoot '.git\index') -Content 'fixture-index'
}

# Runs Doctor 0.2.1 and writes its complete schema 1.1.0 stdout document outside the project.
function Write-DoctorResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = "powershell.exe"
    $startInfo.Arguments = [string]::Join(" ", [string[]]@(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", ('"' + $script:ScannerPath + '"'),
        "-ProjectRoot", ('"' + (Get-NormalizedPath -Path $ProjectRoot) + '"')
    ))
    $startInfo.WorkingDirectory = $script:RepositoryRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill()
            throw "Doctor fixture process timed out."
        }
        $process.WaitForExit()
        $stdout = $stdoutTask.Result.Trim()
        $stderr = $stderrTask.Result.Trim()
        if ($process.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($stdout)) {
            throw "Doctor fixture process failed with exit $($process.ExitCode): $stderr"
        }
        [void](ConvertFrom-Json -InputObject $stdout -ErrorAction Stop)
        Write-TestText -Path $Path -Content $stdout
    } finally {
        $process.Dispose()
    }
}

# Applies one in-memory mutation to a Doctor JSON fixture and writes it deterministically.
function Update-DoctorResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Mutation
    )

    $doctor = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -ErrorAction Stop
    & $Mutation $doctor
    $json = ConvertTo-Json -InputObject $doctor -Depth 30 -Compress
    Write-TestText -Path $Path -Content $json
}

# Compiles a fake Unity.exe with controlled version metadata and log behavior.
function New-FakeUnityExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $true)]
        [string]$ProductVersion
    )

    $parent = Split-Path -Parent $OutputPath
    [void][System.IO.Directory]::CreateDirectory($parent)
    $safeProductVersion = $ProductVersion.Replace('"', "")
    $source = @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;

[assembly: AssemblyTitle("Unity")]
[assembly: AssemblyProduct("Unity")]
[assembly: AssemblyDescription("Fake Unity executable for static CI tests")]
[assembly: AssemblyCompany("Fixture")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("6000.0.69.1")]
[assembly: AssemblyInformationalVersion("$safeProductVersion")]

internal static class Program
{
    // Returns the value following one command-line option.
    private static string GetOptionValue(string[] args, string option)
    {
        for (int index = 0; index + 1 < args.Length; index++)
        {
            if (String.Equals(args[index], option, StringComparison.OrdinalIgnoreCase))
            {
                return args[index + 1];
            }
        }
        return null;
    }

    // Creates the containing directory before writing one UTF-8 file.
    private static void WriteFile(string path, string content)
    {
        if (String.IsNullOrWhiteSpace(path))
        {
            return;
        }
        string parent = Path.GetDirectoryName(path);
        if (!String.IsNullOrWhiteSpace(parent))
        {
            Directory.CreateDirectory(parent);
        }
        File.WriteAllText(path, content, new UTF8Encoding(false));
    }

    // Emits controlled Unity-like arguments, logs, mutations, and exit codes.
    private static int Main(string[] args)
    {
        if (args.Length > 0 && String.Equals(args[0], "--child", StringComparison.Ordinal))
        {
            Thread.Sleep(2500);
            WriteFile(Environment.GetEnvironmentVariable("FAKE_UNITY_DELAYED_SENTINEL"), "child survived timeout");
            return 0;
        }

        string argumentsPath = Environment.GetEnvironmentVariable("FAKE_UNITY_ARGUMENTS_PATH");
        WriteFile(argumentsPath, String.Join(Environment.NewLine, args));

        string projectPath = GetOptionValue(args, "-projectPath");
        string editorLogPath = GetOptionValue(args, "-logFile");
        string upmLogPath = GetOptionValue(args, "-upmLogFile");
        string scenario = Environment.GetEnvironmentVariable("FAKE_UNITY_SCENARIO") ?? "success";
        if (String.Equals(scenario, "parent-child-timeout", StringComparison.OrdinalIgnoreCase))
        {
            Thread.Sleep(500);
            var childStart = new ProcessStartInfo();
            childStart.FileName = Assembly.GetExecutingAssembly().Location;
            childStart.Arguments = "--child";
            childStart.UseShellExecute = false;
            Process.Start(childStart);
            Thread.Sleep(Timeout.Infinite);
        }
        string mutationPath = Environment.GetEnvironmentVariable("FAKE_UNITY_MUTATE_PATH");
        if (!String.IsNullOrWhiteSpace(mutationPath))
        {
            WriteFile(mutationPath, "mutated by fake Unity");
        }
        WriteFile(upmLogPath, "Fake UPM log");

        if (!String.Equals(scenario, "no-log", StringComparison.OrdinalIgnoreCase))
        {
            var lines = new List<string>();
            lines.Add("[Licensing::Module] Fake licensing context");
            lines.Add("Built from '6000.0/staging' branch; Version is '6000.0.69f1 (5f8607f5118b) revision 6260231'; Using compiler version 'fake'; Build Type 'Release'");
            lines.Add("BatchMode: 1, IsHumanControllingUs: 0, StartBugReporterOnCrash: 0, Is64bit: 1");
            lines.Add("COMMAND LINE ARGUMENTS:");
            foreach (string argument in args)
            {
                lines.Add(argument);
            }
            lines.Add("Successfully changed project path to: " + projectPath);

            if (!String.Equals(scenario, "inconclusive", StringComparison.OrdinalIgnoreCase))
            {
                lines.Add("Domain Reload Profiling: 10ms");
                lines.Add("Asset Pipeline Refresh (id=fake): Total: 0.100 seconds - Initiated by InitialRefreshV2(ForceSynchronousImport)");
                lines.Add("    CompileScripts: 1.000ms");
                lines.Add("Application.AssetDatabase Initial Refresh End");
            }
            if (String.Equals(scenario, "compiler-error", StringComparison.OrdinalIgnoreCase))
            {
                lines.Add("Assets/Scripts/Broken.cs(1,1): error CS0103: The name 'Missing' does not exist in the current context");
                lines.Add("Scripts have compiler errors.");
            }
            if (!String.Equals(scenario, "inconclusive", StringComparison.OrdinalIgnoreCase))
            {
                lines.Add("Batchmode quit successfully invoked - shutting down!");
                lines.Add("Exiting batchmode successfully now!");
                lines.Add("Exiting without the bug reporter. Application will terminate with return code 0");
            }
            WriteFile(editorLogPath, String.Join(Environment.NewLine, lines) + Environment.NewLine);
        }

        int exitCode;
        if (!Int32.TryParse(Environment.GetEnvironmentVariable("FAKE_UNITY_EXIT_CODE"), out exitCode))
        {
            exitCode = 0;
        }
        return exitCode;
    }
}
"@

    Add-Type -TypeDefinition $source -Language CSharp -OutputAssembly $OutputPath -OutputType ConsoleApplication
    return Get-NormalizedPath -Path $OutputPath
}

# Starts the verifier in a clean child PowerShell process and parses its one JSON stdout document.
function Invoke-Verifier {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CaseName,

        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,

        [Parameter(Mandatory = $true)]
        [string]$DoctorPath,

        [Parameter(Mandatory = $true)]
        [string]$UnityPath,

        [Parameter()]
        [string]$Scenario = "success",

        [Parameter()]
        [int]$FakeExitCode = 0,

        [Parameter()]
        [AllowNull()]
        [string]$MutationPath,

        [Parameter()]
        [AllowNull()]
        [string]$SourceEditorFixtureScenario
    )

    $caseRoot = Join-Path -Path $script:ScratchRoot -ChildPath ("cases\" + $CaseName)
    $artifactsRoot = Join-Path -Path $caseRoot -ChildPath "artifacts"
    $argumentsPath = Join-Path -Path $caseRoot -ChildPath "fake-unity-arguments.txt"
    [void][System.IO.Directory]::CreateDirectory($caseRoot)

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = "powershell.exe"
    $cimCallMarkerPath = Join-Path -Path $caseRoot -ChildPath 'cim-calls.log'
    if ([string]::IsNullOrWhiteSpace($SourceEditorFixtureScenario)) {
        $argumentValues = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $script:VerifierPath,
            "-ProjectRoot", $ProjectRoot,
            "-DoctorResultPath", $DoctorPath,
            "-UnityExecutable", $UnityPath,
            "-ArtifactsRoot", $artifactsRoot,
            "-TimeoutSeconds", "60"
        )
    } else {
        $argumentValues = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $script:SourceEditorFixtureHarnessPath,
            "-VerifierPath", $script:VerifierPath,
            "-Scenario", $SourceEditorFixtureScenario,
            "-CimCallMarkerPath", $cimCallMarkerPath,
            "-ProjectRoot", $ProjectRoot,
            "-DoctorResultPath", $DoctorPath,
            "-UnityExecutable", $UnityPath,
            "-ArtifactsRoot", $artifactsRoot,
            "-TimeoutSeconds", "60"
        )
    }
    $quotedArguments = foreach ($argument in $argumentValues) {
        if ([string]$argument -match "[\s]") {
            '"' + ([string]$argument) + '"'
        } else {
            [string]$argument
        }
    }
    $startInfo.Arguments = [string]::Join(" ", [string[]]@($quotedArguments))
    $startInfo.WorkingDirectory = $script:RepositoryRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $script:Utf8NoBom
    $startInfo.StandardErrorEncoding = $script:Utf8NoBom
    $startInfo.EnvironmentVariables["FAKE_UNITY_ARGUMENTS_PATH"] = $argumentsPath
    $startInfo.EnvironmentVariables["FAKE_UNITY_SCENARIO"] = $Scenario
    $startInfo.EnvironmentVariables["FAKE_UNITY_EXIT_CODE"] = [string]$FakeExitCode
    if (-not [string]::IsNullOrWhiteSpace($MutationPath)) {
        $startInfo.EnvironmentVariables["FAKE_UNITY_MUTATE_PATH"] = $MutationPath
    } else {
        [void]$startInfo.EnvironmentVariables.Remove("FAKE_UNITY_MUTATE_PATH")
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.Result.Trim()
        $stderr = $stderrTask.Result.Trim()
        Assert-Equal -Expected 0 -Actual $process.ExitCode -Message "$CaseName verifier process exit code"
        Assert-Equal -Expected "" -Actual $stderr -Message "$CaseName verifier stderr"
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($stdout)) -Message "$CaseName verifier stdout must contain JSON"
        try {
            $result = ConvertFrom-Json -InputObject $stdout -ErrorAction Stop
        } catch {
            throw "$CaseName stdout was not exactly one valid JSON document: $($_.Exception.Message)"
        }
        return [pscustomobject][ordered]@{
            json = $stdout
            result = $result
            argumentsPath = $argumentsPath
            cimCallMarkerPath = $cimCallMarkerPath
        }
    } finally {
        $process.Dispose()
    }
}

# Detects whether the current Windows token can create symbolic links.
function Test-SymbolicLinkCapability {
    $probeRoot = Join-Path -Path $script:ScratchRoot -ChildPath "symbolic-link-probe"
    $probeSource = Join-Path -Path $probeRoot -ChildPath "source"
    $probeLink = Join-Path -Path $probeRoot -ChildPath "link"
    [void][System.IO.Directory]::CreateDirectory($probeSource)
    try {
        New-Item -ItemType SymbolicLink -Path $probeLink -Target $probeSource -ErrorAction Stop | Out-Null
        Remove-Item -LiteralPath $probeLink -Force
        return $true
    } catch {
        return $false
    }
}

# Removes only this test run's verified system-temporary scratch directory.
function Remove-TestScratch {
    $normalizedScratch = Get-NormalizedPath -Path $script:ScratchRoot
    $normalizedTemp = Get-NormalizedPath -Path ([System.IO.Path]::GetTempPath())
    $leafName = [System.IO.Path]::GetFileName($normalizedScratch)
    if (
        -not (Test-PathWithinRoot -Path $normalizedScratch -Root $normalizedTemp) -or
        -not $leafName.StartsWith("unity-baseline-verification-tests-", [System.StringComparison]::Ordinal)
    ) {
        throw "Refusing to remove unverified scratch path: $normalizedScratch"
    }
    if (Test-Path -LiteralPath $normalizedScratch) {
        Remove-Item -LiteralPath $normalizedScratch -Recurse -Force
    }
}

# Runs the unsigned fake only through the internal Job Object and shared log-analysis layers.
function Invoke-InternalFakeUnity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CaseName,

        [Parameter(Mandatory = $true)]
        [string]$FakeUnityPath,

        [Parameter(Mandatory = $true)]
        [string]$IsolatedProjectPath,

        [Parameter()]
        [string]$Scenario = 'success',

        [Parameter()]
        [int]$ExitCode = 0,

        [Parameter()]
        [int]$TimeoutSeconds = 10,

        [Parameter()]
        [AllowNull()]
        [string]$DelayedSentinelPath
    )

    $caseRoot = Join-Path $script:ScratchRoot ("internal\" + $CaseName)
    [void][System.IO.Directory]::CreateDirectory($caseRoot)
    $argumentsPath = Join-Path $caseRoot 'arguments.txt'
    $editorLogPath = Join-Path $caseRoot 'Editor.log'
    $upmLogPath = Join-Path $caseRoot 'upm.log'
    $stdoutPath = Join-Path $caseRoot 'stdout.log'
    $stderrPath = Join-Path $caseRoot 'stderr.log'
    $arguments = [string[]]@(
        '-batchmode', '-nographics', '-quit',
        '-projectPath', $IsolatedProjectPath,
        '-logFile', $editorLogPath,
        '-upmLogFile', $upmLogPath
    )

    $environmentNames = @('FAKE_UNITY_ARGUMENTS_PATH', 'FAKE_UNITY_SCENARIO', 'FAKE_UNITY_EXIT_CODE', 'FAKE_UNITY_DELAYED_SENTINEL')
    $previousValues = @{}
    foreach ($environmentName in $environmentNames) {
        $previousValues[$environmentName] = [Environment]::GetEnvironmentVariable($environmentName, 'Process')
    }
    try {
        [Environment]::SetEnvironmentVariable('FAKE_UNITY_ARGUMENTS_PATH', $argumentsPath, 'Process')
        [Environment]::SetEnvironmentVariable('FAKE_UNITY_SCENARIO', $Scenario, 'Process')
        [Environment]::SetEnvironmentVariable('FAKE_UNITY_EXIT_CODE', [string]$ExitCode, 'Process')
        [Environment]::SetEnvironmentVariable('FAKE_UNITY_DELAYED_SENTINEL', $DelayedSentinelPath, 'Process')
        $processResult = Invoke-UnityProcessInJob -ExecutablePath $FakeUnityPath -Arguments $arguments -WorkingDirectory $caseRoot -StandardOutputPath $stdoutPath -StandardErrorPath $stderrPath -TimeoutSeconds $TimeoutSeconds
        $logAnalysis = Get-UnityEditorLogAnalysis -Path $editorLogPath -ExpectedProjectPath $IsolatedProjectPath -ExpectedUnityVersion '6000.0.69f1'
    } finally {
        foreach ($environmentName in $environmentNames) {
            [Environment]::SetEnvironmentVariable($environmentName, $previousValues[$environmentName], 'Process')
        }
    }

    return [pscustomobject][ordered]@{
        process = $processResult
        log = $logAnalysis
        argumentsPath = $argumentsPath
        editorLogPath = $editorLogPath
        stdoutPath = $stdoutPath
        stderrPath = $stderrPath
    }
}

Write-Host "Unity Baseline Verification v0.2.0 regression tests"
Write-Host "Scratch root: $script:ScratchRoot"

. $script:GitIntegrityLibraryPath
$repositoryBefore = Get-TestTreeSnapshot -Root $script:RepositoryRoot -ExcludeGitMetadata
$repositoryGitBefore = Get-BaselineGitMetadataSnapshot -ProjectRoot $script:RepositoryRoot
$fixtureRoot = Join-Path $script:RepositoryRoot 'tests\fixtures'
$fixturesBefore = Get-TestTreeSnapshot -Root $fixtureRoot
[void][System.IO.Directory]::CreateDirectory($script:ScratchRoot)

try {
    foreach ($requiredRelativePath in @(
        'schemas\unity-project-audit.schema.json',
        'schemas\unity-project-audit-1.1.0.schema.json',
        'docs\skills\unity-baseline-verification.md',
        'docs\skills\unity-project-doctor.md',
        'docs\releases\v0.3.0.md',
        'docs\releases\v0.4.0.md',
        'docs\releases\v0.5.0.md',
        'docs\validation\v0.1.1-unity-baseline-real-unity-acceptance.md',
        'docs\validation\v0.1.2-original-integrity-acceptance.md',
        'docs\validation\v0.1.2-real-unity-acceptance-result.md',
        'docs\validation\v0.2.0-baseline-orchestration-acceptance.md',
        'VERSION',
        'CHANGELOG.md',
        'skills\codex\unity-baseline-verification\VERSION',
        'skills\codex\unity-baseline-verification\SKILL.md',
        'skills\codex\unity-baseline-verification\agents\openai.yaml',
        'skills\codex\unity-baseline-verification\scripts\invoke-unity-baseline-verification.ps1',
        'skills\codex\unity-baseline-verification\scripts\verify-unity-baseline.ps1',
        'skills\codex\unity-baseline-verification\scripts\lib\unity-baseline-orchestration.ps1',
        'skills\codex\unity-baseline-verification\scripts\lib\json-schema-validator.ps1',
        'skills\codex\unity-baseline-verification\scripts\lib\unity-process-job.ps1',
        'skills\codex\unity-baseline-verification\scripts\lib\unity-editor-log.ps1',
        'skills\codex\unity-baseline-verification\scripts\lib\git-metadata-integrity.ps1',
        'skills\codex\unity-baseline-verification\scripts\lib\unity-isolation-path-budget.ps1',
        'skills\codex\unity-project-doctor\scripts\lib\unity-project-fingerprint.ps1',
        'scripts\install-codex-skills.ps1',
        'tests\unity-baseline-verification\run-tests.ps1',
        'tests\unity-baseline-verification\helpers\invoke-verifier-with-source-editor-fixture.ps1',
        'tests\unity-baseline-verification\orchestration\run-tests.ps1',
        '.github\workflows\baseline-static-tests.yml'
    )) {
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $requiredRelativePath) -PathType Leaf) -Message "Required file $requiredRelativePath"
    }

    Assert-Equal -Expected '0.5.0' -Actual ((Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'VERSION')).Trim()) -Message 'Repository VERSION'
    Assert-Equal -Expected '0.2.0' -Actual ((Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'skills\codex\unity-baseline-verification\VERSION')).Trim()) -Message 'Baseline Skill VERSION'
    Assert-Equal -Expected '0.2.1' -Actual ((Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'skills\codex\unity-project-doctor\VERSION')).Trim()) -Message 'Doctor Skill VERSION'
    $acceptanceResultContent = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'docs\validation\v0.1.2-real-unity-acceptance-result.md')
    Assert-True -Condition ($acceptanceResultContent.Contains('APPROVED')) -Message 'Real-Unity acceptance approval marker'
    Assert-True -Condition ($acceptanceResultContent.Contains('BASELINE_VERIFIED')) -Message 'Real-Unity acceptance final status'
    Assert-True -Condition ($acceptanceResultContent.Contains('fd13e495d7e993f17812ce87fc68f9589e7f6d3498ca8f01399fc75309ca1203')) -Message 'Real-Unity acceptance raw evidence hash'
    Assert-True -Condition (-not $acceptanceResultContent.Contains('C:\Users\')) -Message 'Public acceptance result excludes user-profile paths'
    Assert-True -Condition (-not $acceptanceResultContent.Contains('E:\Unity\')) -Message 'Public acceptance result excludes source-project paths'
    Assert-True -Condition (-not $acceptanceResultContent.Contains('Woosik')) -Message 'Public acceptance result excludes local user name'
    $releaseNotesContent = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'docs\releases\v0.3.0.md')
    Assert-True -Condition ($releaseNotesContent.Contains('Release contract status: **FINAL**')) -Message 'Release notes final contract state'
    Assert-True -Condition ($releaseNotesContent.Contains('This file records invariant release requirements')) -Message 'Release notes durable publication semantics'
    Assert-True -Condition ($releaseNotesContent.Contains('`$unity-project-doctor` | `0.2.1`')) -Message 'Release notes Doctor component version'
    Assert-True -Condition ($releaseNotesContent.Contains('`$unity-baseline-verification` | `0.1.2`')) -Message 'Release notes Baseline component version'
    $previousReleaseNotesContent = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'docs\releases\v0.4.0.md')
    Assert-True -Condition ($previousReleaseNotesContent.Contains('Release contract status: **FINAL**')) -Message 'Previous release notes final contract state'
    Assert-True -Condition ($previousReleaseNotesContent.Contains('This file records invariant release requirements')) -Message 'Previous release notes durable publication semantics'
    Assert-True -Condition ($previousReleaseNotesContent.Contains('`$unity-project-doctor` | `0.2.1`')) -Message 'Previous release notes Doctor component version'
    Assert-True -Condition ($previousReleaseNotesContent.Contains('`$unity-baseline-verification` | `0.2.0`')) -Message 'Previous release notes Baseline component version'
    $currentReleaseNotesContent = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'docs\releases\v0.5.0.md')
    Assert-True -Condition ($currentReleaseNotesContent.Contains('Release contract status: **FINAL**')) -Message 'Current release notes final contract state'
    Assert-True -Condition ($currentReleaseNotesContent.Contains('This file records invariant release requirements')) -Message 'Current release notes durable publication semantics'
    Assert-True -Condition ($currentReleaseNotesContent.Contains('`$unity-project-doctor` | `0.2.1`')) -Message 'Current release notes Doctor component version'
    Assert-True -Condition ($currentReleaseNotesContent.Contains('`$unity-baseline-verification` | `0.2.0`')) -Message 'Current release notes Baseline component version'
    Assert-True -Condition ($currentReleaseNotesContent.Contains('`$unity-editmode-verification` | `0.1.0`')) -Message 'Current release notes EditMode component version'
    Assert-True -Condition ($currentReleaseNotesContent.Contains('`$unity-test-scaffold` | `0.1.0`')) -Message 'Current release notes Test Scaffold component version'
    Assert-True -Condition ($currentReleaseNotesContent.Contains('Low-level Baseline verifier | `0.1.3`')) -Message 'Current release notes verifier version'
    Assert-True -Condition ($currentReleaseNotesContent.Contains('APPROVED')) -Message 'Current release notes approval marker'
    Assert-True -Condition ($currentReleaseNotesContent.Contains('SCRIPT COMPILATION + SELECTED EDITMODE TESTS ONLY')) -Message 'Current release notes approval scope'
    Assert-True -Condition ($currentReleaseNotesContent.Contains('4 / 4 / 4')) -Message 'Current release notes selected EditMode result'
    Assert-True -Condition ($currentReleaseNotesContent.Contains('PlayMode, Player Build, runtime')) -Message 'Current release notes unverified scope'
    Assert-True -Condition (-not $currentReleaseNotesContent.Contains('C:\Users\')) -Message 'Current release notes exclude user-profile paths'
    Assert-True -Condition (-not $currentReleaseNotesContent.Contains('E:\Unity\')) -Message 'Current release notes exclude source-project paths'
    Assert-True -Condition (-not $currentReleaseNotesContent.Contains('Woosik')) -Message 'Current release notes exclude local user name'
    $skillContent = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'skills\codex\unity-baseline-verification\SKILL.md')
    Assert-True -Condition ($skillContent -match '^---\r?\nname: unity-baseline-verification\r?\ndescription:') -Message 'Skill frontmatter'
    $frontmatterMatch = [regex]::Match($skillContent, '^---\r?\n(?<body>.*?)\r?\n---', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    Assert-True -Condition $frontmatterMatch.Success -Message 'Skill frontmatter delimiters'
    $frontmatterKeys = @([regex]::Matches($frontmatterMatch.Groups['body'].Value, '(?m)^(?<key>[a-z][a-z0-9-]*):') | ForEach-Object { $_.Groups['key'].Value })
    Assert-Equal -Expected 'name|description' -Actual ([string]::Join('|', [string[]]$frontmatterKeys)) -Message 'Skill frontmatter contains only name and description'
    Assert-True -Condition ($skillContent -match '\$unity-baseline-verification') -Message 'Skill explicit invocation text'
    $agentContent = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'skills\codex\unity-baseline-verification\agents\openai.yaml')
    Assert-True -Condition ($agentContent -match '(?m)^\s*allow_implicit_invocation:\s*false\s*$') -Message 'Implicit invocation policy'
    foreach ($interfaceField in @('display_name', 'short_description', 'default_prompt')) {
        Assert-True -Condition ($agentContent -match ('(?m)^\s*{0}:\s*"[^"]+"\s*$' -f [regex]::Escape($interfaceField))) -Message "Quoted openai.yaml interface field: $interfaceField"
    }
    $verifierContent = Get-Content -Raw -LiteralPath $script:VerifierPath
    Assert-True -Condition ($verifierContent -notmatch '(?i)SkipSignatureCheck|TestMode') -Message 'Production verifier exposes no trust bypass flag'
    Assert-True -Condition ($verifierContent -notmatch '(?i)SourceEditorFixture|PREFLIGHT_SCENARIO') -Message 'Production verifier exposes no source-editor fixture hook'
    Assert-True -Condition ($verifierContent.Contains('$script:VerifierVersion = "0.1.3"')) -Message 'Low-level verifier source-editor compatibility metadata version 0.1.3'
    $orchestratorContent = Get-Content -Raw -LiteralPath $script:OrchestratorPath
    Assert-True -Condition ($orchestratorContent.Contains('$script:BaselineComponentVersion = "0.2.0"')) -Message 'Orchestration component metadata version'
    foreach ($finalStatus in @('BASELINE_VERIFIED', 'BASELINE_FAILED', 'VERIFICATION_BLOCKED', 'ORIGINAL_PROJECT_CHANGED')) {
        Assert-True -Condition ($verifierContent.Contains($finalStatus)) -Message "Final status remains defined: $finalStatus"
    }

    $parseErrors = New-Object System.Collections.ArrayList
    foreach ($scriptFile in @(Get-ChildItem -LiteralPath $script:RepositoryRoot -Filter '*.ps1' -File -Recurse)) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        foreach ($error in @($errors)) {
            [void]$parseErrors.Add("$($scriptFile.FullName):$($error.Extent.StartLineNumber): $($error.Message)")
        }
    }
    Assert-Equal -Expected 0 -Actual $parseErrors.Count -Message 'PowerShell parse error count'

    . $script:SchemaValidatorPath
    . $script:ProcessLibraryPath
    . $script:EditorLogLibraryPath
    . $script:GitIntegrityLibraryPath
    . $script:IsolationPathBudgetLibraryPath
    . $script:FingerprintLibraryPath

    $shortProjectDestination = Join-Path ([System.IO.Path]::GetTempPath()) "ubv\b\unity-baseline-verification-00000000000000000000000000000000\project"
    $colorGateRushPrefix = "Assets/Scripts/Generated/"
    $colorGateRushRelativePath = $colorGateRushPrefix + ("c" * (125 - $colorGateRushPrefix.Length - 3)) + ".cs"
    Assert-Equal -Expected 125 -Actual $colorGateRushRelativePath.Length -Message 'ColorGateRush longest relative file path regression length'
    $colorGateRushSnapshot = [pscustomobject]@{
        directories = @("Assets", "Assets/Scripts", "Assets/Scripts/Generated")
        files = @([pscustomobject]@{ path = $colorGateRushRelativePath })
    }
    $colorGateRushBudget = Get-UnityIsolationPathBudgetAssessment -Snapshot $colorGateRushSnapshot -Destination $shortProjectDestination
    Assert-Equal -Expected $true -Actual $colorGateRushBudget.accepted -Message 'Short ubv layout accepts the 125-character ColorGateRush relative path'
    Assert-Equal -Expected ((Get-NormalizedPath $shortProjectDestination).Length + 126) -Actual $colorGateRushBudget.maximumFilePathLength -Message 'ColorGateRush destination length calculation'
    Assert-Equal -Expected 0 -Actual $colorGateRushBudget.violations.Count -Message 'ColorGateRush path has no budget violation'

    $boundaryDestination = Join-Path ([System.IO.Path]::GetTempPath()) "ubv\budget"
    $directory247 = New-TestRelativePathForDestinationLength -DestinationRoot $boundaryDestination -TargetLength 247
    $directory248 = New-TestRelativePathForDestinationLength -DestinationRoot $boundaryDestination -TargetLength 248
    $directory247Budget = Get-UnityIsolationPathBudgetAssessment -Snapshot ([pscustomobject]@{ directories = @($directory247); files = @() }) -Destination $boundaryDestination
    $directory248Budget = Get-UnityIsolationPathBudgetAssessment -Snapshot ([pscustomobject]@{ directories = @($directory248); files = @() }) -Destination $boundaryDestination
    Assert-Equal -Expected $true -Actual $directory247Budget.accepted -Message '247-character directory destination remains within budget'
    Assert-Equal -Expected 247 -Actual $directory247Budget.maximumDirectoryPathLength -Message '247-character directory boundary calculation'
    Assert-Equal -Expected $false -Actual $directory248Budget.accepted -Message '248-character directory destination is blocked before copy'
    Assert-Equal -Expected 1 -Actual $directory248Budget.violations.Count -Message '248-character directory yields one structured violation'
    Assert-Equal -Expected 'ISOLATION_DIRECTORY_PATH_BUDGET_EXCEEDED' -Actual $directory248Budget.violations[0].code -Message '248-character directory blocker code'
    Assert-Equal -Expected 248 -Actual $directory248Budget.violations[0].characterCount -Message '248-character directory evidence length'
    Assert-Equal -Expected 248 -Actual $directory248Budget.violations[0].boundary -Message 'Directory boundary evidence'
    Assert-Equal -Expected (Get-UnityIsolationDestinationPath -DestinationRoot $boundaryDestination -RelativePath $directory248) -Actual $directory248Budget.violations[0].destinationPath -Message 'Directory violation reports exact destination path'

    $file259 = New-TestRelativePathForDestinationLength -DestinationRoot $boundaryDestination -TargetLength 259 -File
    $file260 = New-TestRelativePathForDestinationLength -DestinationRoot $boundaryDestination -TargetLength 260 -File
    $file259Budget = Get-UnityIsolationPathBudgetAssessment -Snapshot ([pscustomobject]@{ directories = @(); files = @([pscustomobject]@{ path = $file259 }) }) -Destination $boundaryDestination
    $file260Budget = Get-UnityIsolationPathBudgetAssessment -Snapshot ([pscustomobject]@{ directories = @(); files = @([pscustomobject]@{ path = $file260 }) }) -Destination $boundaryDestination
    Assert-Equal -Expected $true -Actual $file259Budget.accepted -Message '259-character file destination remains within budget'
    Assert-Equal -Expected 259 -Actual $file259Budget.maximumFilePathLength -Message '259-character file boundary calculation'
    Assert-Equal -Expected $false -Actual $file260Budget.accepted -Message '260-character file destination is blocked before copy'
    Assert-Equal -Expected 1 -Actual $file260Budget.violations.Count -Message '260-character file yields one structured violation'
    Assert-Equal -Expected 'ISOLATION_FILE_PATH_BUDGET_EXCEEDED' -Actual $file260Budget.violations[0].code -Message '260-character file blocker code'
    Assert-Equal -Expected 260 -Actual $file260Budget.violations[0].characterCount -Message '260-character file evidence length'
    Assert-Equal -Expected 260 -Actual $file260Budget.violations[0].boundary -Message 'File boundary evidence'
    Assert-Equal -Expected (Get-UnityIsolationDestinationPath -DestinationRoot $boundaryDestination -RelativePath $file260) -Actual $file260Budget.violations[0].path -Message 'File violation blocker path is the exact destination'

    $verifierTokens = $null
    $verifierParseErrors = $null
    $verifierAst = [System.Management.Automation.Language.Parser]::ParseFile($script:VerifierPath, [ref]$verifierTokens, [ref]$verifierParseErrors)
    Assert-Equal -Expected 0 -Actual @($verifierParseErrors).Count -Message 'Verifier functions are extractable for isolated path-budget integration'
    foreach ($functionName in @('Add-Evidence', 'Add-Blocker', 'Test-IsolationDestinationPathBudget')) {
        $functionDefinitions = @($verifierAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
        }, $true))
        Assert-Equal -Expected 1 -Actual $functionDefinitions.Count -Message "One production function definition exists for $functionName"
        . ([scriptblock]::Create($functionDefinitions[0].Extent.Text))
    }

    $wrapperDestination = Join-Path $script:ScratchRoot 'path-budget-wrapper-project'
    $wrapperFile260 = New-TestRelativePathForDestinationLength -DestinationRoot $wrapperDestination -TargetLength 260 -File
    $wrapperSnapshot = [pscustomobject]@{
        directories = @()
        files = @([pscustomobject]@{ path = $wrapperFile260 })
    }
    Assert-True -Condition (-not (Test-Path -LiteralPath $wrapperDestination)) -Message 'Production path-budget wrapper destination starts absent'
    $script:Blockers = New-Object System.Collections.ArrayList
    $script:Evidence = New-Object System.Collections.ArrayList
    $script:EvidenceSequence = 0
    Test-IsolationDestinationPathBudget -Snapshot $wrapperSnapshot -Destination $wrapperDestination
    Assert-Equal -Expected 1 -Actual $script:Blockers.Count -Message 'Production wrapper emits one structured blocker for an exact 260-character file'
    Assert-Equal -Expected 'ISOLATION_FILE_PATH_BUDGET_EXCEEDED' -Actual $script:Blockers[0].code -Message 'Production wrapper preserves path-budget blocker code'
    Assert-Equal -Expected 'isolationPathBudget' -Actual $script:Blockers[0].check -Message 'Production wrapper preserves path-budget check name'
    Assert-Equal -Expected 260 -Actual ([string]$script:Blockers[0].path).Length -Message 'Production wrapper reports the exact 260-character destination path'
    Assert-True -Condition ([string]$script:Blockers[0].message -match [regex]::Escape($wrapperFile260)) -Message 'Production wrapper reports the relative source path'
    Assert-Contains -Collection @($script:Evidence | ForEach-Object status) -Expected 'BLOCKED' -Message 'Production wrapper emits matching blocked evidence'
    Assert-True -Condition (-not (Test-Path -LiteralPath $wrapperDestination)) -Message 'Production path-budget wrapper creates no destination before blocking'

    $ambientProject = New-TestUnityProject -Name 'git-ambient-checkpoint'
    Initialize-TestGitMetadata -ProjectRoot $ambientProject
    $ambientContentBefore = Get-UnityCopySetSnapshot -ProjectRoot $ambientProject
    $ambientGitBefore = Get-BaselineGitMetadataSnapshot -ProjectRoot $ambientProject
    $ambientCheckpointPath = Join-Path $ambientProject '.git\refs\codex\turn-diffs\checkpoints\fixture\turn\checkpoint'
    Write-TestText -Path $ambientCheckpointPath -Content 'checkpoint'
    $ambientContentAfter = Get-UnityCopySetSnapshot -ProjectRoot $ambientProject
    $ambientGitAfter = Get-BaselineGitMetadataSnapshot -ProjectRoot $ambientProject
    $ambientAssessment = Get-BaselineGitMetadataAssessment -Before $ambientGitBefore -After $ambientGitAfter
    Assert-Equal -Expected $ambientContentBefore.treeSha256 -Actual $ambientContentAfter.treeSha256 -Message 'Codex checkpoint leaves Baseline copy-set fingerprint unchanged'
    Assert-Equal -Expected 'AMBIENT_CODEX_CHECKPOINTS_ONLY' -Actual $ambientAssessment.status -Message 'Codex checkpoint-only Git delta classification'
    Assert-Equal -Expected $true -Actual $ambientAssessment.ambientChangesAllowed -Message 'Codex checkpoint additions are explicitly ambient'
    Assert-Equal -Expected 0 -Actual $ambientAssessment.disallowedAddedFiles.Count -Message 'Checkpoint namespace has no disallowed added files'
    Assert-Contains -Collection $ambientAssessment.addedFiles -Expected '.git/refs/codex/turn-diffs/checkpoints/fixture/turn/checkpoint' -Message 'Checkpoint evidence retains the exact added path'

    $sensitiveGitCases = @(
        [pscustomobject]@{
            name = 'head-change'
            expectedPath = '.git/HEAD'
            mutate = { param($root) Write-TestText -Path (Join-Path $root '.git\HEAD') -Content "ref: refs/heads/release`n" }
        },
        [pscustomobject]@{
            name = 'index-change'
            expectedPath = '.git/index'
            mutate = { param($root) Write-TestText -Path (Join-Path $root '.git\index') -Content 'changed-index' }
        },
        [pscustomobject]@{
            name = 'config-change'
            expectedPath = '.git/config'
            mutate = { param($root) Write-TestText -Path (Join-Path $root '.git\config') -Content "[core]`nrepositoryformatversion = 1`n" }
        },
        [pscustomobject]@{
            name = 'hook-addition'
            expectedPath = '.git/hooks/pre-commit'
            mutate = { param($root) Write-TestText -Path (Join-Path $root '.git\hooks\pre-commit') -Content 'blocked-hook' }
        },
        [pscustomobject]@{
            name = 'ordinary-ref-addition'
            expectedPath = '.git/refs/heads/new-branch'
            mutate = { param($root) Write-TestText -Path (Join-Path $root '.git\refs\heads\new-branch') -Content '0123456789abcdef' }
        },
        [pscustomobject]@{
            name = 'object-addition'
            expectedPath = '.git/objects/01/23456789abcdef'
            mutate = { param($root) Write-TestText -Path (Join-Path $root '.git\objects\01\23456789abcdef') -Content 'git-object' }
        },
        [pscustomobject]@{
            name = 'checkpoint-prefix-lookalike'
            expectedPath = '.git/refs/codex/turn-diffs/checkpoints-unsafe/file'
            mutate = { param($root) Write-TestText -Path (Join-Path $root '.git\refs\codex\turn-diffs\checkpoints-unsafe\file') -Content 'not-a-checkpoint' }
        }
    )
    foreach ($sensitiveCase in $sensitiveGitCases) {
        $sensitiveProject = New-TestUnityProject -Name ("git-" + $sensitiveCase.name)
        Initialize-TestGitMetadata -ProjectRoot $sensitiveProject
        $sensitiveBefore = Get-BaselineGitMetadataSnapshot -ProjectRoot $sensitiveProject
        & $sensitiveCase.mutate $sensitiveProject
        $sensitiveAfter = Get-BaselineGitMetadataSnapshot -ProjectRoot $sensitiveProject
        $sensitiveAssessment = Get-BaselineGitMetadataAssessment -Before $sensitiveBefore -After $sensitiveAfter
        Assert-Equal -Expected 'CHANGED' -Actual $sensitiveAssessment.status -Message "$($sensitiveCase.name) remains blocking"
        $reportedPaths = @($sensitiveAssessment.changedFiles | ForEach-Object pathAfter) + @($sensitiveAssessment.disallowedAddedFiles)
        Assert-Contains -Collection $reportedPaths -Expected $sensitiveCase.expectedPath -Message "$($sensitiveCase.name) exact evidence path"
    }

    $checkpointChangeProject = New-TestUnityProject -Name 'git-existing-checkpoint-change'
    Initialize-TestGitMetadata -ProjectRoot $checkpointChangeProject
    $existingCheckpointPath = Join-Path $checkpointChangeProject '.git\refs\codex\turn-diffs\checkpoints\existing\checkpoint'
    Write-TestText -Path $existingCheckpointPath -Content 'before'
    $checkpointChangeBefore = Get-BaselineGitMetadataSnapshot -ProjectRoot $checkpointChangeProject
    Write-TestText -Path $existingCheckpointPath -Content 'after'
    $checkpointChangeAfter = Get-BaselineGitMetadataSnapshot -ProjectRoot $checkpointChangeProject
    $checkpointChangeAssessment = Get-BaselineGitMetadataAssessment -Before $checkpointChangeBefore -After $checkpointChangeAfter
    Assert-Equal -Expected 'CHANGED' -Actual $checkpointChangeAssessment.status -Message 'Existing checkpoint modification remains blocking'
    Assert-Contains -Collection @($checkpointChangeAssessment.changedFiles | ForEach-Object pathAfter) -Expected '.git/refs/codex/turn-diffs/checkpoints/existing/checkpoint' -Message 'Existing checkpoint modification exact path'

    $checkpointRemovalProject = New-TestUnityProject -Name 'git-existing-checkpoint-removal'
    Initialize-TestGitMetadata -ProjectRoot $checkpointRemovalProject
    $removedCheckpointPath = Join-Path $checkpointRemovalProject '.git\refs\codex\turn-diffs\checkpoints\existing\checkpoint'
    Write-TestText -Path $removedCheckpointPath -Content 'before'
    $checkpointRemovalBefore = Get-BaselineGitMetadataSnapshot -ProjectRoot $checkpointRemovalProject
    Remove-Item -LiteralPath $removedCheckpointPath -Force
    $checkpointRemovalAfter = Get-BaselineGitMetadataSnapshot -ProjectRoot $checkpointRemovalProject
    $checkpointRemovalAssessment = Get-BaselineGitMetadataAssessment -Before $checkpointRemovalBefore -After $checkpointRemovalAfter
    Assert-Equal -Expected 'CHANGED' -Actual $checkpointRemovalAssessment.status -Message 'Existing checkpoint removal remains blocking'
    Assert-Contains -Collection $checkpointRemovalAssessment.removedFiles -Expected '.git/refs/codex/turn-diffs/checkpoints/existing/checkpoint' -Message 'Existing checkpoint removal exact path'

    $noGitProject = New-TestUnityProject -Name 'git-not-present'
    $noGitBefore = Get-BaselineGitMetadataSnapshot -ProjectRoot $noGitProject
    $noGitAfter = Get-BaselineGitMetadataSnapshot -ProjectRoot $noGitProject
    $noGitAssessment = Get-BaselineGitMetadataAssessment -Before $noGitBefore -After $noGitAfter
    Assert-Equal -Expected 'NOT_PRESENT' -Actual $noGitAssessment.status -Message 'Absent in-project Git metadata is explicitly classified'

    $gitReparseProject = New-TestUnityProject -Name 'git-reparse-blocked'
    $gitReparseTarget = Join-Path $script:ScratchRoot 'outside-git-reparse-target'
    [void][System.IO.Directory]::CreateDirectory($gitReparseTarget)
    Write-TestText -Path (Join-Path $gitReparseTarget 'HEAD') -Content "ref: refs/heads/main`n"
    New-Item -ItemType Junction -Path (Join-Path $gitReparseProject '.git') -Target $gitReparseTarget -ErrorAction Stop | Out-Null
    $gitReparseBlocked = $false
    try {
        [void](Get-BaselineGitMetadataSnapshot -ProjectRoot $gitReparseProject)
    } catch {
        $gitReparseBlocked = $_.Exception.Message -match 'reparse point'
    }
    Assert-Equal -Expected $true -Actual $gitReparseBlocked -Message 'In-project .git reparse point is blocked without traversal'

    $contentMutationProject = New-TestUnityProject -Name 'copy-set-content-change'
    Initialize-TestGitMetadata -ProjectRoot $contentMutationProject
    $contentMutationBefore = Get-UnityCopySetSnapshot -ProjectRoot $contentMutationProject
    $contentMutationGitBefore = Get-BaselineGitMetadataSnapshot -ProjectRoot $contentMutationProject
    Write-TestText -Path (Join-Path $contentMutationProject 'Assets\Scripts\Probe.cs') -Content 'public sealed class Probe { public int Value = 2; }'
    $contentMutationAfter = Get-UnityCopySetSnapshot -ProjectRoot $contentMutationProject
    $contentMutationGitAfter = Get-BaselineGitMetadataSnapshot -ProjectRoot $contentMutationProject
    $contentMutationGitAssessment = Get-BaselineGitMetadataAssessment -Before $contentMutationGitBefore -After $contentMutationGitAfter
    Assert-True -Condition ($contentMutationBefore.treeSha256 -ne $contentMutationAfter.treeSha256) -Message 'Copy-included source mutation changes content fingerprint'
    Assert-Equal -Expected 'UNCHANGED' -Actual $contentMutationGitAssessment.status -Message 'Content mutation does not fabricate a Git metadata delta'

    $generatedMutationProject = New-TestUnityProject -Name 'excluded-generated-change'
    $generatedMutationBefore = Get-UnityCopySetSnapshot -ProjectRoot $generatedMutationProject
    Write-TestText -Path (Join-Path $generatedMutationProject 'Library\Generated.cache') -Content 'changed-generated-library'
    $generatedMutationAfter = Get-UnityCopySetSnapshot -ProjectRoot $generatedMutationProject
    Assert-Equal -Expected $generatedMutationBefore.treeSha256 -Actual $generatedMutationAfter.treeSha256 -Message 'Excluded generated-tree mutation leaves content fingerprint unchanged'

    $fakeUnity = New-FakeUnityExecutable -OutputPath (Join-Path $script:ScratchRoot 'fake-unity\6000.0.69f1\Editor\Unity.exe') -ProductVersion '6000.0.69f1_5f8607f5118b'
    $fakeVersionInfo = (Get-Item -LiteralPath $fakeUnity).VersionInfo
    Assert-True -Condition ($fakeVersionInfo.ProductVersion.StartsWith('6000.0.69f1', [System.StringComparison]::Ordinal)) -Message 'Fake Unity ProductVersion'
    Assert-Equal -Expected 'NotSigned' -Actual ([string](Get-AuthenticodeSignature -LiteralPath $fakeUnity).Status) -Message 'Fake Unity must remain unsigned'

    $validProject = New-TestUnityProject -Name 'valid-doctor'
    $validDoctor = Join-Path $script:ScratchRoot 'doctor\valid.json'
    Write-DoctorResult -Path $validDoctor -ProjectRoot $validProject
    $validDoctorObject = Get-Content -Raw -LiteralPath $validDoctor | ConvertFrom-Json
    $validSchemaErrors = @(Invoke-JsonSchemaValidation -Instance $validDoctorObject -SchemaPath $script:SchemaPath)
    Assert-Equal -Expected 0 -Actual $validSchemaErrors.Count -Message 'Valid full Doctor output schema errors'
    Assert-Equal -Expected 'COMPUTED' -Actual $validDoctorObject.projectFingerprint.status -Message 'Doctor fingerprint status'

    $zeroUnityPreflight = Invoke-Verifier -CaseName 'preflight-zero-unity-cim-denied' -ProjectRoot $validProject -DoctorPath $validDoctor -UnityPath $fakeUnity -SourceEditorFixtureScenario 'zero-cim-denied'
    Assert-Equal -Expected $true -Actual $zeroUnityPreflight.result.preflight.sourceEditorCheckCompleted -Message 'Zero Unity process preflight completed'
    Assert-Equal -Expected $false -Actual $zeroUnityPreflight.result.preflight.sourceEditorDetected -Message 'Zero Unity process source editor not detected'
    Assert-Equal -Expected 0 -Actual @($zeroUnityPreflight.result.preflight.sourceEditorProcessIds).Count -Message 'Zero Unity process IDs'
    Assert-True -Condition (-not (Test-Path -LiteralPath $zeroUnityPreflight.cimCallMarkerPath)) -Message 'Zero Unity process skips CIM entirely'
    Assert-Contains -Collection @($zeroUnityPreflight.result.evidence | Where-Object check -eq 'sourceEditorPreflight' | ForEach-Object status) -Expected 'PASSED' -Message 'Zero Unity process preflight evidence passed'
    Assert-True -Condition (@($zeroUnityPreflight.result.blockers | ForEach-Object code) -notcontains 'SOURCE_EDITOR_PREFLIGHT_UNAVAILABLE') -Message 'Zero Unity process has no unavailable blocker'
    Assert-Equal -Expected $false -Actual $zeroUnityPreflight.result.unity.processStarted -Message 'Zero Unity fixture never starts Unity'
    Assert-True -Condition (-not (Test-Path -LiteralPath $zeroUnityPreflight.argumentsPath)) -Message 'Zero Unity fixture has no executable invocation marker'

    $getProcessDeniedPreflight = Invoke-Verifier -CaseName 'preflight-get-process-denied' -ProjectRoot $validProject -DoctorPath $validDoctor -UnityPath $fakeUnity -SourceEditorFixtureScenario 'get-process-denied'
    Assert-Equal -Expected $false -Actual $getProcessDeniedPreflight.result.preflight.sourceEditorCheckCompleted -Message 'Get-Process denial leaves preflight incomplete'
    Assert-True -Condition ($null -eq $getProcessDeniedPreflight.result.preflight.sourceEditorDetected) -Message 'Get-Process denial leaves editor detection unknown'
    Assert-Contains -Collection @($getProcessDeniedPreflight.result.blockers | ForEach-Object code) -Expected 'SOURCE_EDITOR_PREFLIGHT_UNAVAILABLE' -Message 'Get-Process denial blocker'
    Assert-True -Condition (-not (Test-Path -LiteralPath $getProcessDeniedPreflight.cimCallMarkerPath)) -Message 'Get-Process denial does not proceed to CIM'
    Assert-Equal -Expected $false -Actual $getProcessDeniedPreflight.result.unity.processStarted -Message 'Get-Process denial prevents Unity'
    Assert-True -Condition (-not (Test-Path -LiteralPath $getProcessDeniedPreflight.argumentsPath)) -Message 'Get-Process denial has no executable invocation marker'

    $cimDeniedPreflight = Invoke-Verifier -CaseName 'preflight-unity-cim-denied' -ProjectRoot $validProject -DoctorPath $validDoctor -UnityPath $fakeUnity -SourceEditorFixtureScenario 'cim-denied'
    Assert-Equal -Expected $false -Actual $cimDeniedPreflight.result.preflight.sourceEditorCheckCompleted -Message 'Unity process plus CIM denial leaves preflight incomplete'
    Assert-True -Condition ($null -eq $cimDeniedPreflight.result.preflight.sourceEditorDetected) -Message 'Unity process plus CIM denial leaves editor detection unknown'
    Assert-Contains -Collection @($cimDeniedPreflight.result.blockers | ForEach-Object code) -Expected 'SOURCE_EDITOR_PREFLIGHT_UNAVAILABLE' -Message 'Unity process plus CIM denial blocker'
    Assert-True -Condition (Test-Path -LiteralPath $cimDeniedPreflight.cimCallMarkerPath -PathType Leaf) -Message 'Unity process requires one CIM attempt'
    Assert-Equal -Expected 1 -Actual @(Get-Content -LiteralPath $cimDeniedPreflight.cimCallMarkerPath).Count -Message 'Unity process performs exactly one CIM query'
    Assert-Equal -Expected $false -Actual $cimDeniedPreflight.result.unity.processStarted -Message 'CIM denial prevents Unity'
    Assert-True -Condition (-not (Test-Path -LiteralPath $cimDeniedPreflight.argumentsPath)) -Message 'CIM denial has no executable invocation marker'

    $sourceOpenPreflight = Invoke-Verifier -CaseName 'preflight-source-project-open' -ProjectRoot $validProject -DoctorPath $validDoctor -UnityPath $fakeUnity -SourceEditorFixtureScenario 'source-project-open'
    Assert-Equal -Expected $true -Actual $sourceOpenPreflight.result.preflight.sourceEditorCheckCompleted -Message 'Source project open preflight completed'
    Assert-Equal -Expected $true -Actual $sourceOpenPreflight.result.preflight.sourceEditorDetected -Message 'Source project open detected'
    Assert-Equal -Expected '4102' -Actual ([string]::Join(',', [string[]]@($sourceOpenPreflight.result.preflight.sourceEditorProcessIds))) -Message 'Source project exact PID result evidence'
    Assert-Contains -Collection @($sourceOpenPreflight.result.blockers | ForEach-Object code) -Expected 'SOURCE_PROJECT_OPEN_IN_UNITY' -Message 'Source project open blocker'
    $sourceOpenEvidence = @($sourceOpenPreflight.result.evidence | Where-Object check -eq 'preflight' | Where-Object status -eq 'BLOCKED')
    Assert-True -Condition (@($sourceOpenEvidence | Where-Object { $_.detail -like '*4102*' }).Count -gt 0) -Message 'Source project exact PID ledger evidence'
    Assert-True -Condition (@($sourceOpenPreflight.result.blockers | ForEach-Object code) -notcontains 'SOURCE_EDITOR_PREFLIGHT_UNAVAILABLE') -Message 'Source project open is conclusive, not unavailable'
    Assert-Equal -Expected $false -Actual $sourceOpenPreflight.result.unity.processStarted -Message 'Source project open prevents Unity'
    Assert-True -Condition (-not (Test-Path -LiteralPath $sourceOpenPreflight.argumentsPath)) -Message 'Source project open has no executable invocation marker'

    $otherOpenPreflight = Invoke-Verifier -CaseName 'preflight-other-project-open' -ProjectRoot $validProject -DoctorPath $validDoctor -UnityPath $fakeUnity -SourceEditorFixtureScenario 'other-project-open'
    Assert-Equal -Expected $true -Actual $otherOpenPreflight.result.preflight.sourceEditorCheckCompleted -Message 'Other project preflight completed'
    Assert-Equal -Expected $false -Actual $otherOpenPreflight.result.preflight.sourceEditorDetected -Message 'Other project not misclassified as source'
    Assert-Equal -Expected 0 -Actual @($otherOpenPreflight.result.preflight.sourceEditorProcessIds).Count -Message 'Other project has no source PID evidence'
    Assert-True -Condition (@($otherOpenPreflight.result.blockers | ForEach-Object code) -notcontains 'SOURCE_PROJECT_OPEN_IN_UNITY') -Message 'Other project has no source-open blocker'
    Assert-True -Condition (@($otherOpenPreflight.result.blockers | ForEach-Object code) -notcontains 'SOURCE_EDITOR_PREFLIGHT_UNAVAILABLE') -Message 'Other project is safely inspectable'
    Assert-Contains -Collection @($otherOpenPreflight.result.evidence | Where-Object check -eq 'sourceEditorPreflight' | ForEach-Object status) -Expected 'PASSED' -Message 'Other project preflight evidence passed'
    Assert-Equal -Expected $false -Actual $otherOpenPreflight.result.unity.processStarted -Message 'Other project fixture never starts unsigned Unity'
    Assert-True -Condition (-not (Test-Path -LiteralPath $otherOpenPreflight.argumentsPath)) -Message 'Other project fixture has no executable invocation marker'

    $exitRacePreflight = Invoke-Verifier -CaseName 'preflight-process-exit-race' -ProjectRoot $validProject -DoctorPath $validDoctor -UnityPath $fakeUnity -SourceEditorFixtureScenario 'process-exit-race'
    Assert-Equal -Expected $true -Actual $exitRacePreflight.result.preflight.sourceEditorCheckCompleted -Message 'Exited Unity PID race completes preflight'
    Assert-Equal -Expected $false -Actual $exitRacePreflight.result.preflight.sourceEditorDetected -Message 'Exited Unity PID is not a source editor'
    Assert-True -Condition (@($exitRacePreflight.result.blockers | ForEach-Object code) -notcontains 'SOURCE_EDITOR_PREFLIGHT_UNAVAILABLE') -Message 'Confirmed process exit race does not block'
    Assert-Contains -Collection @($exitRacePreflight.result.evidence | Where-Object check -eq 'sourceEditorPreflight' | ForEach-Object status) -Expected 'PASSED' -Message 'Confirmed process exit race evidence passed'
    Assert-Equal -Expected $false -Actual $exitRacePreflight.result.unity.processStarted -Message 'Process exit race fixture never starts unsigned Unity'
    Assert-True -Condition (-not (Test-Path -LiteralPath $exitRacePreflight.argumentsPath)) -Message 'Process exit race fixture has no executable invocation marker'

    $missingLivePidPreflight = Invoke-Verifier -CaseName 'preflight-cim-pid-missing-live' -ProjectRoot $validProject -DoctorPath $validDoctor -UnityPath $fakeUnity -SourceEditorFixtureScenario 'cim-pid-missing-live'
    Assert-Equal -Expected $false -Actual $missingLivePidPreflight.result.preflight.sourceEditorCheckCompleted -Message 'Live PID missing from CIM leaves preflight incomplete'
    Assert-True -Condition ($null -eq $missingLivePidPreflight.result.preflight.sourceEditorDetected) -Message 'Live PID missing from CIM leaves detection unknown'
    Assert-Contains -Collection @($missingLivePidPreflight.result.blockers | ForEach-Object code) -Expected 'SOURCE_EDITOR_PREFLIGHT_UNAVAILABLE' -Message 'Live PID missing from CIM blocker'
    Assert-Equal -Expected $false -Actual $missingLivePidPreflight.result.unity.processStarted -Message 'Live PID missing from CIM prevents Unity'
    Assert-True -Condition (-not (Test-Path -LiteralPath $missingLivePidPreflight.argumentsPath)) -Message 'Live PID missing from CIM has no executable invocation marker'

    $missingCommandLinePreflight = Invoke-Verifier -CaseName 'preflight-command-line-missing' -ProjectRoot $validProject -DoctorPath $validDoctor -UnityPath $fakeUnity -SourceEditorFixtureScenario 'command-line-missing'
    Assert-Equal -Expected $false -Actual $missingCommandLinePreflight.result.preflight.sourceEditorCheckCompleted -Message 'Missing CommandLine leaves preflight incomplete'
    Assert-True -Condition ($null -eq $missingCommandLinePreflight.result.preflight.sourceEditorDetected) -Message 'Missing CommandLine leaves detection unknown'
    Assert-Contains -Collection @($missingCommandLinePreflight.result.blockers | ForEach-Object code) -Expected 'SOURCE_EDITOR_PREFLIGHT_UNAVAILABLE' -Message 'Missing CommandLine blocker'
    Assert-Equal -Expected $false -Actual $missingCommandLinePreflight.result.unity.processStarted -Message 'Missing CommandLine prevents Unity'
    Assert-True -Condition (-not (Test-Path -LiteralPath $missingCommandLinePreflight.argumentsPath)) -Message 'Missing CommandLine has no executable invocation marker'

    $secondDoctor = Join-Path $script:ScratchRoot 'doctor\valid-second.json'
    Write-DoctorResult -Path $secondDoctor -ProjectRoot $validProject
    $secondDoctorObject = Get-Content -Raw -LiteralPath $secondDoctor | ConvertFrom-Json
    Assert-Equal -Expected $validDoctorObject.projectFingerprint.treeSha256 -Actual $secondDoctorObject.projectFingerprint.treeSha256 -Message 'Fingerprint determinism'
    Assert-Equal -Expected $validDoctorObject.projectFingerprint.fileCount -Actual $secondDoctorObject.projectFingerprint.fileCount -Message 'Fingerprint file-count determinism'

    $schemaMutationCases = @(
        [pscustomobject]@{ name = 'invalid-git-metadata'; path = '$.git.metadataStatus'; mutate = { param($doctor) $doctor.git.metadataStatus = 'INVALID_ENUM' } },
        [pscustomobject]@{ name = 'invalid-build-parse'; path = '$.buildSettings.parseStatus'; mutate = { param($doctor) $doctor.buildSettings.parseStatus = 'INVALID_ENUM' } },
        [pscustomobject]@{ name = 'nested-required-missing'; path = '$.projectDetection.rootStatus'; mutate = { param($doctor) $doctor.projectDetection.PSObject.Properties.Remove('rootStatus') } },
        [pscustomobject]@{ name = 'wrong-nested-type'; path = '$.projectDetection.isUnityProject'; mutate = { param($doctor) $doctor.projectDetection.isUnityProject = 'true' } },
        [pscustomobject]@{ name = 'nested-extra-property'; path = '$.buildSettings.unexpected'; mutate = { param($doctor) $doctor.buildSettings | Add-Member -NotePropertyName unexpected -NotePropertyValue $true } }
    )
    foreach ($schemaCase in $schemaMutationCases) {
        $caseDoctor = Join-Path $script:ScratchRoot ("doctor\$($schemaCase.name).json")
        Copy-Item -LiteralPath $validDoctor -Destination $caseDoctor -Force
        Update-DoctorResult -Path $caseDoctor -Mutation $schemaCase.mutate
        $caseObject = Get-Content -Raw -LiteralPath $caseDoctor | ConvertFrom-Json
        $directErrors = @(Invoke-JsonSchemaValidation -Instance $caseObject -SchemaPath $script:SchemaPath)
        Assert-True -Condition (@($directErrors | ForEach-Object path) -contains $schemaCase.path) -Message "$($schemaCase.name) exact validator path"
        $caseResult = Invoke-Verifier -CaseName $schemaCase.name -ProjectRoot $validProject -DoctorPath $caseDoctor -UnityPath $fakeUnity
        Assert-Equal -Expected $false -Actual $caseResult.result.doctor.schemaValidated -Message "$($schemaCase.name) full schema rejected"
        Assert-Equal -Expected $false -Actual $caseResult.result.unity.processStarted -Message "$($schemaCase.name) processStarted false"
        Assert-True -Condition (@($caseResult.result.doctor.validationErrors | ForEach-Object path) -contains $schemaCase.path) -Message "$($schemaCase.name) result exact JSON path"
        Assert-True -Condition (-not (Test-Path -LiteralPath $caseResult.argumentsPath)) -Message "$($schemaCase.name) fake executable not invoked"
    }

    $legacyDoctor = Join-Path $script:ScratchRoot 'doctor\legacy-1.0.0.json'
    Copy-Item -LiteralPath $validDoctor -Destination $legacyDoctor -Force
    Update-DoctorResult -Path $legacyDoctor -Mutation {
        param($doctor)
        $doctor.schemaVersion = '1.0.0'
        $doctor.scannerVersion = '0.2.0'
        $doctor.PSObject.Properties.Remove('projectFingerprint')
    }
    $legacyResult = Invoke-Verifier -CaseName 'legacy-doctor' -ProjectRoot $validProject -DoctorPath $legacyDoctor -UnityPath $fakeUnity
    Assert-Equal -Expected $true -Actual $legacyResult.result.doctor.schemaValidated -Message 'Legacy Doctor remains valid static-audit JSON'
    Assert-Contains -Collection @($legacyResult.result.blockers | ForEach-Object code) -Expected 'DOCTOR_FINGERPRINT_CONTRACT_REQUIRED' -Message 'Legacy Doctor fingerprint migration blocker'
    Assert-Equal -Expected $false -Actual $legacyResult.result.unity.processStarted -Message 'Legacy Doctor prevents Unity'

    $validBefore = Get-TestTreeSnapshot -Root $validProject
    $unsignedProduction = Invoke-Verifier -CaseName 'unsigned-production' -ProjectRoot $validProject -DoctorPath $validDoctor -UnityPath $fakeUnity
    $validAfter = Get-TestTreeSnapshot -Root $validProject
    Assert-Equal -Expected 'VERIFICATION_BLOCKED' -Actual $unsignedProduction.result.finalStatus -Message 'Unsigned production final status'
    Assert-Equal -Expected '1.1.0' -Actual $unsignedProduction.result.schemaVersion -Message 'Baseline result schema version'
    Assert-Equal -Expected '0.1.3' -Actual $unsignedProduction.result.verifierVersion -Message 'Baseline verifier version'
    Assert-Equal -Expected $true -Actual $unsignedProduction.result.doctor.accepted -Message 'Valid full Doctor accepted'
    Assert-Equal -Expected $true -Actual $unsignedProduction.result.doctor.fingerprintMatched -Message 'Doctor/current fingerprint matched'
    Assert-Equal -Expected $false -Actual $unsignedProduction.result.unity.processStarted -Message 'Unsigned fake blocked before process start'
    Assert-Equal -Expected 'NotSigned' -Actual $unsignedProduction.result.unity.signatureStatus -Message 'Unsigned signature evidence'
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$unsignedProduction.result.unity.fileVersion)) -Message 'FileVersion evidence recorded'
    Assert-True -Condition ([string]$unsignedProduction.result.unity.productVersion -like '6000.0.69f1*') -Message 'ProductVersion evidence recorded'
    Assert-Equal -Expected 'Fixture' -Actual $unsignedProduction.result.unity.companyName -Message 'CompanyName evidence recorded'
    Assert-Equal -Expected 64 -Actual ([string]$unsignedProduction.result.unity.executableSha256).Length -Message 'Executable SHA-256 evidence recorded'
    Assert-True -Condition ($null -eq $unsignedProduction.result.unity.signerSubject) -Message 'Unsigned fake has no signer subject'
    Assert-True -Condition ($null -eq $unsignedProduction.result.unity.certificateThumbprint) -Message 'Unsigned fake has no certificate thumbprint'
    Assert-Contains -Collection @($unsignedProduction.result.blockers | ForEach-Object code) -Expected 'UNITY_EXECUTABLE_SIGNATURE_INVALID' -Message 'Unsigned fake production blocker'
    Assert-Equal -Expected $validBefore -Actual $validAfter -Message 'Production rejection leaves source project unchanged'
    Assert-True -Condition (-not (Test-Path -LiteralPath $unsignedProduction.argumentsPath)) -Message 'Unsigned production fake has no invocation arguments'
    Assert-True -Condition $unsignedProduction.result.artifacts.resultWritten -Message 'Blocked result artifact written externally'
    Assert-Equal -Expected $unsignedProduction.json -Actual ([System.IO.File]::ReadAllText($unsignedProduction.result.artifacts.resultPath, $script:Utf8NoBom)) -Message 'stdout is the exact one result artifact JSON'
    Assert-Equal -Expected 'BASELINE_COPY_SET' -Actual $unsignedProduction.result.originalProjectIntegrity.scope -Message 'Original content integrity scope'
    Assert-Equal -Expected '.git' -Actual $unsignedProduction.result.gitMetadataIntegrity.scope -Message 'Separate Git metadata integrity scope'
    Assert-Equal -Expected '.git/refs/codex/turn-diffs/checkpoints/' -Actual $unsignedProduction.result.gitMetadataIntegrity.allowedAdditionPrefix -Message 'Exact ambient checkpoint prefix'
    foreach ($scopeName in @('tests', 'playerBuild', 'playMode', 'runtime')) {
        Assert-Equal -Expected 'NOT_VERIFIED' -Actual $unsignedProduction.result.verification.$scopeName.status -Message "$scopeName remains NOT_VERIFIED"
    }

    $mismatchProject = New-TestUnityProject -Name 'fingerprint-mismatch'
    $mismatchDoctor = Join-Path $script:ScratchRoot 'doctor\fingerprint-mismatch.json'
    Write-DoctorResult -Path $mismatchDoctor -ProjectRoot $mismatchProject
    Write-TestText -Path (Join-Path $mismatchProject 'Assets\Scripts\AfterDoctor.cs') -Content 'public sealed class AfterDoctor {}'
    $mismatchResult = Invoke-Verifier -CaseName 'fingerprint-mismatch' -ProjectRoot $mismatchProject -DoctorPath $mismatchDoctor -UnityPath $fakeUnity
    Assert-Equal -Expected $false -Actual $mismatchResult.result.doctor.fingerprintMatched -Message 'Changed source fingerprint mismatch'
    Assert-Contains -Collection @($mismatchResult.result.blockers | ForEach-Object code) -Expected 'DOCTOR_PROJECT_FINGERPRINT_MISMATCH' -Message 'Fingerprint mismatch blocker'
    Assert-Equal -Expected $false -Actual $mismatchResult.result.unity.processStarted -Message 'Fingerprint mismatch prevents Unity'

    $packageCases = New-Object System.Collections.ArrayList

    $absoluteProject = New-TestUnityProject -Name 'package-absolute'
    Write-TestText -Path (Join-Path $absoluteProject 'LocalPackages\Safe\package.json') -Content '{"name":"com.example.safe","version":"1.0.0"}'
    $absoluteReference = 'file:' + (Join-Path $absoluteProject 'LocalPackages\Safe')
    Write-TestText -Path (Join-Path $absoluteProject 'Packages\manifest.json') -Content (([ordered]@{ dependencies = [ordered]@{ 'com.example.safe' = $absoluteReference } } | ConvertTo-Json -Compress))
    [void]$packageCases.Add([pscustomobject]@{ name = 'package-absolute'; project = $absoluteProject; code = 'LOCAL_PACKAGE_ABSOLUTE_PATH_FORBIDDEN' })

    $outsideProject = New-TestUnityProject -Name 'package-outside-relative' -ManifestContent '{"dependencies":{"com.example.outside":"file:../../outside-package"}}'
    [void]$packageCases.Add([pscustomobject]@{ name = 'package-outside-relative'; project = $outsideProject; code = 'LOCAL_PACKAGE_OUTSIDE_PROJECT' })

    $uncProject = New-TestUnityProject -Name 'package-unc' -ManifestContent '{"dependencies":{"com.example.unc":"file://server/share/package"}}'
    [void]$packageCases.Add([pscustomobject]@{ name = 'package-unc'; project = $uncProject; code = 'LOCAL_PACKAGE_AUTHORITY_OR_DEVICE_PATH' })

    $encodedProject = New-TestUnityProject -Name 'package-encoded' -ManifestContent '{"dependencies":{"com.example.encoded":"file:%252e%252e%252f%252e%252e%252foutside"}}'
    [void]$packageCases.Add([pscustomobject]@{ name = 'package-encoded'; project = $encodedProject; code = 'LOCAL_PACKAGE_OUTSIDE_PROJECT' })

    $excludedProject = New-TestUnityProject -Name 'package-excluded' -ManifestContent '{"dependencies":{"com.example.excluded":"file:../Library/LocalPackage"}}'
    Write-TestText -Path (Join-Path $excludedProject 'Library\LocalPackage\package.json') -Content '{"name":"com.example.excluded","version":"1.0.0"}'
    [void]$packageCases.Add([pscustomobject]@{ name = 'package-excluded'; project = $excludedProject; code = 'LOCAL_PACKAGE_EXCLUDED_FROM_COPY' })

    foreach ($packageCase in @($packageCases)) {
        $doctorPath = Join-Path $script:ScratchRoot ("doctor\$($packageCase.name).json")
        Write-DoctorResult -Path $doctorPath -ProjectRoot $packageCase.project
        $packageResult = Invoke-Verifier -CaseName $packageCase.name -ProjectRoot $packageCase.project -DoctorPath $doctorPath -UnityPath $fakeUnity
        Assert-Contains -Collection @($packageResult.result.blockers | ForEach-Object code) -Expected $packageCase.code -Message "$($packageCase.name) blocker"
        Assert-Equal -Expected $false -Actual $packageResult.result.unity.processStarted -Message "$($packageCase.name) prevents Unity"
    }

    $safePackageProject = New-TestUnityProject -Name 'package-safe-relative' -ManifestContent '{"dependencies":{"com.example.safe":"file:../LocalPackages/Safe"}}'
    Write-TestText -Path (Join-Path $safePackageProject 'LocalPackages\Safe\package.json') -Content '{"name":"com.example.safe","version":"1.0.0"}'
    $safePackageDoctor = Join-Path $script:ScratchRoot 'doctor\package-safe-relative.json'
    Write-DoctorResult -Path $safePackageDoctor -ProjectRoot $safePackageProject
    $safePackageResult = Invoke-Verifier -CaseName 'package-safe-relative' -ProjectRoot $safePackageProject -DoctorPath $safePackageDoctor -UnityPath $fakeUnity
    $safePackageBlockers = @($safePackageResult.result.blockers | ForEach-Object code | Where-Object { $_ -like 'LOCAL_PACKAGE_*' })
    Assert-Equal -Expected 0 -Actual $safePackageBlockers.Count -Message 'Safe relative package has no package blocker'
    Assert-Equal -Expected 1 -Actual $safePackageResult.result.isolation.localPackageReferences.Count -Message 'Safe relative package normalization record'
    Assert-Equal -Expected 'LocalPackages/Safe' -Actual $safePackageResult.result.isolation.localPackageReferences[0].projectRelativePath -Message 'Safe relative project path'

    $reparseProject = New-TestUnityProject -Name 'package-reparse' -ManifestContent '{"dependencies":{"com.example.linked":"file:../LocalPackages/Linked"}}'
    $reparseTarget = Join-Path $script:ScratchRoot 'outside-reparse-package'
    [void][System.IO.Directory]::CreateDirectory($reparseTarget)
    Write-TestText -Path (Join-Path $reparseTarget 'package.json') -Content '{"name":"com.example.linked","version":"1.0.0"}'
    [void][System.IO.Directory]::CreateDirectory((Join-Path $reparseProject 'LocalPackages'))
    $reparseCreated = $false
    try {
        New-Item -ItemType Junction -Path (Join-Path $reparseProject 'LocalPackages\Linked') -Target $reparseTarget -ErrorAction Stop | Out-Null
        $reparseCreated = $true
    } catch {
        throw "Local-package reparse fixture could not be created: $($_.Exception.Message)"
    }
    if ($reparseCreated) {
        $reparseDoctor = Join-Path $script:ScratchRoot 'doctor\package-reparse.json'
        Write-DoctorResult -Path $reparseDoctor -ProjectRoot $reparseProject
        $reparseResult = Invoke-Verifier -CaseName 'package-reparse' -ProjectRoot $reparseProject -DoctorPath $reparseDoctor -UnityPath $fakeUnity
        Assert-Contains -Collection @($reparseResult.result.blockers | ForEach-Object code) -Expected 'LOCAL_PACKAGE_REPARSE_POINT' -Message 'Reparse package blocker'
        Assert-Equal -Expected $false -Actual $reparseResult.result.unity.processStarted -Message 'Reparse package prevents Unity'
    }

    $internalProject = New-TestUnityProject -Name 'internal-process-project'
    $internalSuccess = Invoke-InternalFakeUnity -CaseName 'success' -FakeUnityPath $fakeUnity -IsolatedProjectPath $internalProject
    Assert-Equal -Expected $true -Actual $internalSuccess.process.processStarted -Message 'Internal fake process started'
    Assert-Equal -Expected 0 -Actual $internalSuccess.process.exitCode -Message 'Internal fake exit code'
    Assert-Equal -Expected $true -Actual $internalSuccess.process.processTreeExitVerified -Message 'Internal process tree exit verified'
    Assert-Equal -Expected 'SUCCESS' -Actual $internalSuccess.log.classification -Message 'Shared Editor.log success classification'
    $internalArguments = @([System.IO.File]::ReadAllLines($internalSuccess.argumentsPath, $script:Utf8NoBom))
    Assert-Equal -Expected 9 -Actual $internalArguments.Count -Message 'Internal fixed Unity argument count'
    Assert-Equal -Expected '-batchmode' -Actual $internalArguments[0] -Message 'Internal batchmode argument'
    Assert-Equal -Expected '-projectPath' -Actual $internalArguments[3] -Message 'Internal projectPath argument key'
    Assert-Equal -Expected (Get-NormalizedPath -Path $internalProject) -Actual (Get-NormalizedPath -Path $internalArguments[4]) -Message 'Internal projectPath argument value'
    foreach ($forbiddenArgument in @('-runTests', '-executeMethod', '-accept-apiupdate', '-ignorecompilererrors')) {
        Assert-True -Condition ($internalArguments -notcontains $forbiddenArgument) -Message "Internal forbidden argument absent: $forbiddenArgument"
    }

    $internalCompiler = Invoke-InternalFakeUnity -CaseName 'compiler-error' -FakeUnityPath $fakeUnity -IsolatedProjectPath $internalProject -Scenario 'compiler-error'
    Assert-Equal -Expected 'FAILURE' -Actual $internalCompiler.log.classification -Message 'Shared Editor.log compiler failure classification'
    Assert-True -Condition ($internalCompiler.log.compilerErrorCount -gt 0) -Message 'Compiler error captured'

    $internalExit = Invoke-InternalFakeUnity -CaseName 'nonzero-exit' -FakeUnityPath $fakeUnity -IsolatedProjectPath $internalProject -ExitCode 17
    Assert-Equal -Expected 17 -Actual $internalExit.process.exitCode -Message 'Internal nonzero exit preserved'

    $delayedSentinel = Join-Path $script:ScratchRoot 'internal\timeout\delayed-sentinel.txt'
    $internalTimeout = Invoke-InternalFakeUnity -CaseName 'timeout' -FakeUnityPath $fakeUnity -IsolatedProjectPath $internalProject -Scenario 'parent-child-timeout' -TimeoutSeconds 1 -DelayedSentinelPath $delayedSentinel
    Assert-Equal -Expected $true -Actual $internalTimeout.process.timedOut -Message 'Internal parent/child timeout observed'
    Assert-Equal -Expected $true -Actual $internalTimeout.process.terminationRequested -Message 'Timeout requested Job Object termination'
    Assert-Equal -Expected $true -Actual $internalTimeout.process.terminationApiSucceeded -Message 'Job Object termination API succeeded'
    Assert-Equal -Expected $true -Actual $internalTimeout.process.processTreeExitVerified -Message 'Parent and child process tree exited'
    Assert-Equal -Expected 0 -Actual $internalTimeout.process.activeProcessCountAfterWait -Message 'Job Object active process count after timeout'
    Start-Sleep -Milliseconds 3000
    Assert-True -Condition (-not (Test-Path -LiteralPath $delayedSentinel)) -Message 'Killed child cannot create delayed sentinel'
    foreach ($artifactPath in @($internalTimeout.editorLogPath, $internalTimeout.stdoutPath, $internalTimeout.stderrPath)) {
        Assert-True -Condition (Test-PathWithinRoot -Path $artifactPath -Root ([System.IO.Path]::GetTempPath())) -Message 'Internal process artifact stays in system temp'
        Assert-True -Condition (-not (Test-PathWithinRoot -Path $artifactPath -Root $script:RepositoryRoot)) -Message 'Internal process artifact stays outside repository'
    }

    $whatIfDestination = Join-Path $script:ScratchRoot 'installer-whatif\skills'
    & $script:InstallerPath -DestinationRoot $whatIfDestination -WhatIf | Out-Null
    Assert-True -Condition (-not (Test-Path -LiteralPath $whatIfDestination)) -Message 'Installer WhatIf makes no destination'

    if (Test-SymbolicLinkCapability) {
        $installDestination = Join-Path $script:ScratchRoot 'installer\skills'
        & $script:InstallerPath -DestinationRoot $installDestination | Out-Null
        $installedLink = Join-Path $installDestination 'unity-baseline-verification'
        Assert-True -Condition (Test-Path -LiteralPath $installedLink -PathType Container) -Message 'Installer creates Skill link'
        $linkEntry = Get-Item -LiteralPath $installedLink -Force
        Assert-Equal -Expected 'SymbolicLink' -Actual $linkEntry.LinkType -Message 'Installer link type'
        & $script:InstallerPath -DestinationRoot $installDestination | Out-Null
        $linkEntryAgain = Get-Item -LiteralPath $installedLink -Force
        Assert-Equal -Expected 'SymbolicLink' -Actual $linkEntryAgain.LinkType -Message 'Installer idempotency'
    } else {
        Write-Host 'Symbolic-link creation tests skipped because this token lacks the required Windows privilege.'
    }

    $conflictDestination = Join-Path $script:ScratchRoot 'installer-conflict\skills'
    $conflictPath = Join-Path $conflictDestination 'unity-baseline-verification'
    Write-TestText -Path (Join-Path $conflictPath 'marker.txt') -Content 'preserve'
    $conflictThrown = $false
    try {
        & $script:InstallerPath -DestinationRoot $conflictDestination -WarningAction SilentlyContinue | Out-Null
    } catch {
        $conflictThrown = $true
    }
    Assert-True -Condition $conflictThrown -Message 'Installer rejects conflict'
    Assert-Equal -Expected 'preserve' -Actual ([System.IO.File]::ReadAllText((Join-Path $conflictPath 'marker.txt'), $script:Utf8NoBom)) -Message 'Installer preserves conflict'

    $orchestrationOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:OrchestrationTestsPath 2>&1)
    $orchestrationExitCode = $LASTEXITCODE
    $orchestrationOutput | ForEach-Object { Write-Host ([string]$_) }
    Assert-Equal -Expected 0 -Actual $orchestrationExitCode -Message 'Orchestration child test exit code'
    Assert-True -Condition ([string]::Join([Environment]::NewLine, [string[]]$orchestrationOutput).Contains('All orchestration tests passed. Assertions:')) -Message 'Orchestration child test completion marker'

    $fixturesAfter = Get-TestTreeSnapshot -Root $fixtureRoot
    Assert-Equal -Expected $fixturesBefore -Actual $fixturesAfter -Message 'Fixture file list and hashes remain unchanged'
    $repositoryAfter = Get-TestTreeSnapshot -Root $script:RepositoryRoot -ExcludeGitMetadata
    Assert-Equal -Expected $repositoryBefore -Actual $repositoryAfter -Message 'Test suite leaves repository content byte-for-byte unchanged'
    $repositoryGitAfter = Get-BaselineGitMetadataSnapshot -ProjectRoot $script:RepositoryRoot
    $repositoryGitAssessment = Get-BaselineGitMetadataAssessment -Before $repositoryGitBefore -After $repositoryGitAfter
    Assert-True -Condition (@('UNCHANGED', 'AMBIENT_CODEX_CHECKPOINTS_ONLY') -contains $repositoryGitAssessment.status) -Message 'Test suite changes no Git metadata outside ambient Codex checkpoints'

    $script:TestsPassed = $true
    Write-Host "All tests passed. Assertions: $($script:Assertions)"
} finally {
    if ($script:TestsPassed) {
        Remove-TestScratch
    } else {
        Write-Host "Test scratch retained for diagnosis: $script:ScratchRoot"
    }
}
