[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:RepositoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $PSScriptRoot))).TrimEnd("\", "/")
$script:VerifierPath = Join-Path -Path $script:RepositoryRoot -ChildPath "skills\codex\unity-baseline-verification\scripts\verify-unity-baseline.ps1"
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

# Captures a compact repository file-list and SHA-256 snapshot.
function Get-TestTreeSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $normalizedRoot = Get-NormalizedPath -Path $Root
    $lines = New-Object System.Collections.ArrayList
    $directories = @(
        Get-ChildItem -LiteralPath $normalizedRoot -Directory -Force -Recurse |
            Sort-Object -Property FullName
    )
    foreach ($directory in $directories) {
        $relative = $directory.FullName.Substring($normalizedRoot.Length + 1).Replace("\", "/")
        [void]$lines.Add("D|$relative")
    }
    $files = @(
        Get-ChildItem -LiteralPath $normalizedRoot -File -Force -Recurse |
            Sort-Object -Property FullName
    )
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($normalizedRoot.Length + 1).Replace("\", "/")
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
    Write-TestText -Path (Join-Path $projectRoot ".git\config") -Content "[core]"
    $fixtureSkillLines = @("---", "name: fixture", "description: fixture", "---")
    Write-TestText -Path (Join-Path $projectRoot ".agents\skills\fixture\SKILL.md") -Content ([string]::Join([Environment]::NewLine, $fixtureSkillLines))
    return Get-NormalizedPath -Path $projectRoot
}

# Writes a full Doctor schema 1.0.0 document with selected contract overrides.
function Write-DoctorResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,

        [Parameter()]
        [string]$ScannerVersion = "0.2.0",

        [Parameter()]
        [string]$FinalStatus = "STATIC_AUDIT_COMPLETE",

        [Parameter()]
        [string]$EditorVersion = "6000.0.69f1",

        [Parameter()]
        [object[]]$Warnings = @(),

        [Parameter()]
        [object[]]$BlockedChecks = @()
    )

    $doctor = [ordered]@{
        schemaVersion = "1.0.0"
        scannerVersion = $ScannerVersion
        projectRoot = Get-NormalizedPath -Path $ProjectRoot
        projectDetection = [ordered]@{
            isUnityProject = $true
            rootStatus = "UNITY_PROJECT"
            markers = @(
                [ordered]@{ path = "Assets"; expectedType = "Directory"; status = "PRESENT" },
                [ordered]@{ path = "Packages"; expectedType = "Directory"; status = "PRESENT" },
                [ordered]@{ path = "ProjectSettings"; expectedType = "Directory"; status = "PRESENT" },
                [ordered]@{ path = "ProjectSettings/ProjectVersion.txt"; expectedType = "File"; status = "PRESENT" }
            )
        }
        unityEditorVersion = [ordered]@{
            source = "ProjectSettings/ProjectVersion.txt"
            parseStatus = "PARSED"
            editorVersion = $EditorVersion
            editorVersionWithRevision = "$EditorVersion (5f8607f5118b)"
        }
        git = [ordered]@{
            gitAvailable = $false
            metadataStatus = "NOT_AVAILABLE"
            worktree = $false
            topLevel = $null
            branch = $null
            detachedHead = $null
            headCommit = $null
            dirtyState = "NOT_AVAILABLE"
            dirty = $null
            changedPaths = @()
        }
        packages = [ordered]@{
            manifest = [ordered]@{ path = "Packages/manifest.json"; exists = $true; parseStatus = "PARSED"; error = $null }
            packagesLock = [ordered]@{ path = "Packages/packages-lock.json"; exists = $true; parseStatus = "PARSED"; error = $null }
            directDependencies = @()
            resolvedDependencies = @()
            directDependenciesMissingFromLock = @()
        }
        assemblies = [ordered]@{
            asmdefs = @()
            confirmedTestAssemblies = @()
            candidateOnlyTestAssemblies = @()
        }
        buildSettings = [ordered]@{
            path = "ProjectSettings/EditorBuildSettings.asset"
            exists = $false
            parseStatus = "MISSING"
            enabledScenes = @()
            disabledScenes = @()
            missingScenes = @()
        }
        agentsFiles = @()
        projectSkills = @()
        trackedGeneratedFolderPaths = @()
        warnings = @($Warnings)
        blockedChecks = @($BlockedChecks)
        dynamicVerification = [ordered]@{
            compilation = [ordered]@{ status = "NOT_VERIFIED"; reason = "Unity was not run." }
            tests = [ordered]@{ status = "NOT_VERIFIED"; reason = "Tests were not run." }
            build = [ordered]@{ status = "NOT_VERIFIED"; reason = "Build was not run." }
            runtime = [ordered]@{ status = "NOT_VERIFIED"; reason = "Runtime was not run." }
        }
        finalStatus = $FinalStatus
        evidence = @(
            [ordered]@{ id = "E001"; check = "projectDetection"; status = "OBSERVED"; source = "fixture"; detail = "Fixture Doctor evidence." }
        )
    }
    $json = ConvertTo-Json -InputObject $doctor -Depth 20 -Compress
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
using System.IO;
using System.Reflection;
using System.Text;

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
        string argumentsPath = Environment.GetEnvironmentVariable("FAKE_UNITY_ARGUMENTS_PATH");
        WriteFile(argumentsPath, String.Join(Environment.NewLine, args));

        string projectPath = GetOptionValue(args, "-projectPath");
        string editorLogPath = GetOptionValue(args, "-logFile");
        string upmLogPath = GetOptionValue(args, "-upmLogFile");
        string scenario = Environment.GetEnvironmentVariable("FAKE_UNITY_SCENARIO") ?? "success";
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
        [string]$MutationPath
    )

    $caseRoot = Join-Path -Path $script:ScratchRoot -ChildPath ("cases\" + $CaseName)
    $artifactsRoot = Join-Path -Path $caseRoot -ChildPath "artifacts"
    $argumentsPath = Join-Path -Path $caseRoot -ChildPath "fake-unity-arguments.txt"
    [void][System.IO.Directory]::CreateDirectory($caseRoot)

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = "powershell.exe"
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

Write-Host "Unity Baseline Verification v0.1 tests"
Write-Host "Scratch root: $script:ScratchRoot"

$repositoryBefore = Get-TestTreeSnapshot -Root $script:RepositoryRoot
[void][System.IO.Directory]::CreateDirectory($script:ScratchRoot)

try {
    foreach ($requiredRelativePath in @(
        "docs\skills\unity-baseline-verification.md",
        "CHANGELOG.md",
        "skills\codex\unity-baseline-verification\VERSION",
        "skills\codex\unity-baseline-verification\SKILL.md",
        "skills\codex\unity-baseline-verification\agents\openai.yaml",
        "skills\codex\unity-baseline-verification\scripts\verify-unity-baseline.ps1",
        "scripts\install-codex-skills.ps1",
        "tests\unity-baseline-verification\run-tests.ps1",
        ".github\workflows\baseline-static-tests.yml"
    )) {
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $requiredRelativePath) -PathType Leaf) -Message "Required file $requiredRelativePath"
    }

    Assert-Equal -Expected "0.1.0" -Actual ((Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot "skills\codex\unity-baseline-verification\VERSION")).Trim()) -Message "Baseline Skill VERSION"
    $skillContent = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot "skills\codex\unity-baseline-verification\SKILL.md")
    Assert-True -Condition ($skillContent -match "^---\r?\nname: unity-baseline-verification\r?\ndescription:") -Message "Skill frontmatter"
    Assert-True -Condition ($skillContent -match '\$unity-baseline-verification') -Message "Skill explicit invocation text"
    $agentContent = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot "skills\codex\unity-baseline-verification\agents\openai.yaml")
    Assert-True -Condition ($agentContent -match "(?m)^\s*allow_implicit_invocation:\s*false\s*$") -Message "Implicit invocation policy"

    $parseErrors = New-Object System.Collections.ArrayList
    foreach ($scriptFile in @(Get-ChildItem -LiteralPath $script:RepositoryRoot -Filter "*.ps1" -File -Recurse)) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        foreach ($error in @($errors)) {
            [void]$parseErrors.Add("$($scriptFile.FullName):$($error.Extent.StartLineNumber): $($error.Message)")
        }
    }
    Assert-Equal -Expected 0 -Actual $parseErrors.Count -Message "PowerShell parse error count"

    $fakeUnity = New-FakeUnityExecutable -OutputPath (Join-Path $script:ScratchRoot "fake-unity\6000.0.69f1\Editor\Unity.exe") -ProductVersion "6000.0.69f1_5f8607f5118b"
    $fakeVersionInfo = (Get-Item -LiteralPath $fakeUnity).VersionInfo
    Assert-True -Condition ($fakeVersionInfo.ProductVersion.StartsWith("6000.0.69f1", [System.StringComparison]::Ordinal)) -Message "Fake Unity ProductVersion"

    $successProject = New-TestUnityProject -Name "success"
    $successDoctor = Join-Path $script:ScratchRoot "doctor\success.json"
    $doctorWarning = [ordered]@{ code = "GIT_NOT_WORKTREE"; check = "git"; path = ".git"; message = "Fixture warning." }
    Write-DoctorResult -Path $successDoctor -ProjectRoot $successProject -FinalStatus "STATIC_AUDIT_COMPLETE_WITH_WARNINGS" -Warnings @($doctorWarning)
    $successBefore = Get-TestTreeSnapshot -Root $successProject
    $success = Invoke-Verifier -CaseName "success" -ProjectRoot $successProject -DoctorPath $successDoctor -UnityPath $fakeUnity
    $successAfter = Get-TestTreeSnapshot -Root $successProject

    Assert-Equal -Expected "BASELINE_VERIFIED" -Actual $success.result.finalStatus -Message "Success final status"
    Assert-Equal -Expected "VERIFIED_SUCCESS" -Actual $success.result.verification.scriptCompilation.status -Message "Success compilation status"
    Assert-Equal -Expected "UNCHANGED" -Actual $success.result.originalProjectIntegrity.status -Message "Success original integrity"
    Assert-Equal -Expected $successBefore -Actual $successAfter -Message "Success source tree unchanged"
    Assert-Equal -Expected $success.result.originalProjectIntegrity.beforeTreeSha256 -Actual $success.result.originalProjectIntegrity.afterTreeSha256 -Message "Success before and after tree SHA-256"
    Assert-Equal -Expected $true -Actual $success.result.doctor.accepted -Message "Success Doctor acceptance"
    Assert-Equal -Expected 1 -Actual $success.result.doctor.warningCount -Message "Doctor warning preservation"
    Assert-Equal -Expected "6000.0.69f1" -Actual $success.result.unity.detectedExecutableVersion -Message "Executable version"
    Assert-Equal -Expected "6000.0.69f1" -Actual $success.result.editorLog.detectedUnityVersion -Message "Editor.log version"
    Assert-Equal -Expected 0 -Actual $success.result.unity.exitCode -Message "Unity exit code"
    Assert-Equal -Expected $false -Actual $success.result.unity.hubInvoked -Message "Unity Hub not invoked"
    Assert-Equal -Expected $false -Actual $success.result.unity.commandLineContainsOriginalProject -Message "Original root absent from Unity arguments"
    Assert-Equal -Expected "NOT_VERIFIED" -Actual $success.result.verification.tests.status -Message "Tests not verified"
    Assert-Equal -Expected "NOT_VERIFIED" -Actual $success.result.verification.playerBuild.status -Message "Player Build not verified"
    Assert-Equal -Expected "NOT_VERIFIED" -Actual $success.result.verification.playMode.status -Message "PlayMode not verified"
    Assert-Equal -Expected "NOT_VERIFIED" -Actual $success.result.verification.runtime.status -Message "Runtime not verified"
    Assert-True -Condition $success.result.artifacts.resultWritten -Message "Result artifact written"
    $resultArtifactJson = [System.IO.File]::ReadAllText($success.result.artifacts.resultPath, $script:Utf8NoBom)
    Assert-Equal -Expected $success.json -Actual $resultArtifactJson -Message "stdout JSON and result artifact match"

    $fakeArguments = @([System.IO.File]::ReadAllLines($success.argumentsPath, $script:Utf8NoBom))
    Assert-Equal -Expected 9 -Actual $fakeArguments.Count -Message "Fixed Unity argument count"
    Assert-Equal -Expected "-batchmode" -Actual $fakeArguments[0] -Message "batchmode argument"
    Assert-Equal -Expected "-nographics" -Actual $fakeArguments[1] -Message "nographics argument"
    Assert-Equal -Expected "-quit" -Actual $fakeArguments[2] -Message "quit argument"
    Assert-Equal -Expected "-projectPath" -Actual $fakeArguments[3] -Message "projectPath argument key"
    Assert-Equal -Expected (Get-NormalizedPath -Path $success.result.isolation.projectCopyPath) -Actual (Get-NormalizedPath -Path $fakeArguments[4]) -Message "isolated project argument value"
    Assert-Equal -Expected "-logFile" -Actual $fakeArguments[5] -Message "logFile argument key"
    Assert-Equal -Expected "-upmLogFile" -Actual $fakeArguments[7] -Message "upmLogFile argument key"
    Assert-True -Condition (-not (Test-PathWithinRoot -Path $fakeArguments[4] -Root $successProject)) -Message "Isolated project is outside original"
    Assert-True -Condition (-not (Test-PathWithinRoot -Path $fakeArguments[6] -Root $successProject)) -Message "Editor.log is outside original"
    foreach ($forbiddenArgument in @("-runTests", "-executeMethod", "-accept-apiupdate", "-ignorecompilererrors")) {
        Assert-True -Condition ($fakeArguments -notcontains $forbiddenArgument) -Message "Forbidden argument absent: $forbiddenArgument"
    }

    $copyRoot = $success.result.isolation.projectCopyPath
    foreach ($excludedPath in @("Library", "Temp", "Logs", "UserSettings", ".git", ".agents")) {
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $copyRoot $excludedPath))) -Message "Excluded copy path $excludedPath"
    }
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $copyRoot "Assets\Scripts\Probe.cs") -PathType Leaf) -Message "Assets copied"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $copyRoot "Packages\manifest.json") -PathType Leaf) -Message "Packages copied"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $copyRoot "ProjectSettings\ProjectVersion.txt") -PathType Leaf) -Message "ProjectSettings copied"

    $compilerProject = New-TestUnityProject -Name "compiler-error"
    $compilerDoctor = Join-Path $script:ScratchRoot "doctor\compiler-error.json"
    Write-DoctorResult -Path $compilerDoctor -ProjectRoot $compilerProject
    $compiler = Invoke-Verifier -CaseName "compiler-error" -ProjectRoot $compilerProject -DoctorPath $compilerDoctor -UnityPath $fakeUnity -Scenario "compiler-error"
    Assert-Equal -Expected "BASELINE_FAILED" -Actual $compiler.result.finalStatus -Message "Compiler error final status"
    Assert-Equal -Expected "VERIFIED_FAILURE" -Actual $compiler.result.verification.scriptCompilation.status -Message "Compiler error verification status"
    Assert-True -Condition ($compiler.result.editorLog.compilerErrorCount -gt 0) -Message "Compiler error captured"
    Assert-Equal -Expected "UNCHANGED" -Actual $compiler.result.originalProjectIntegrity.status -Message "Compiler error original integrity"

    $exitProject = New-TestUnityProject -Name "nonzero-exit"
    $exitDoctor = Join-Path $script:ScratchRoot "doctor\nonzero-exit.json"
    Write-DoctorResult -Path $exitDoctor -ProjectRoot $exitProject
    $exitFailure = Invoke-Verifier -CaseName "nonzero-exit" -ProjectRoot $exitProject -DoctorPath $exitDoctor -UnityPath $fakeUnity -FakeExitCode 17
    Assert-Equal -Expected "BASELINE_FAILED" -Actual $exitFailure.result.finalStatus -Message "Nonzero exit final status"
    Assert-Equal -Expected 17 -Actual $exitFailure.result.unity.exitCode -Message "Nonzero exit preserved"
    Assert-Equal -Expected "VERIFIED_FAILURE" -Actual $exitFailure.result.verification.scriptCompilation.status -Message "Nonzero exit verification status"

    $inconclusiveProject = New-TestUnityProject -Name "inconclusive"
    $inconclusiveDoctor = Join-Path $script:ScratchRoot "doctor\inconclusive.json"
    Write-DoctorResult -Path $inconclusiveDoctor -ProjectRoot $inconclusiveProject
    $inconclusive = Invoke-Verifier -CaseName "inconclusive" -ProjectRoot $inconclusiveProject -DoctorPath $inconclusiveDoctor -UnityPath $fakeUnity -Scenario "inconclusive"
    Assert-Equal -Expected "VERIFICATION_BLOCKED" -Actual $inconclusive.result.finalStatus -Message "Inconclusive final status"
    Assert-Equal -Expected "NOT_VERIFIED" -Actual $inconclusive.result.verification.scriptCompilation.status -Message "Inconclusive compilation status"
    Assert-Contains -Collection @($inconclusive.result.blockers | ForEach-Object code) -Expected "EDITOR_LOG_INCONCLUSIVE" -Message "Inconclusive blocker"

    $missingLogProject = New-TestUnityProject -Name "missing-log"
    $missingLogDoctor = Join-Path $script:ScratchRoot "doctor\missing-log.json"
    Write-DoctorResult -Path $missingLogDoctor -ProjectRoot $missingLogProject
    $missingLog = Invoke-Verifier -CaseName "missing-log" -ProjectRoot $missingLogProject -DoctorPath $missingLogDoctor -UnityPath $fakeUnity -Scenario "no-log"
    Assert-Equal -Expected "VERIFICATION_BLOCKED" -Actual $missingLog.result.finalStatus -Message "Missing log final status"
    Assert-Equal -Expected $false -Actual $missingLog.result.editorLog.exists -Message "Missing Editor.log evidence"
    Assert-Contains -Collection @($missingLog.result.blockers | ForEach-Object code) -Expected "EDITOR_LOG_MISSING" -Message "Missing log blocker"

    $doctorRejectedProject = New-TestUnityProject -Name "doctor-rejected"
    $doctorRejectedPath = Join-Path $script:ScratchRoot "doctor\rejected.json"
    Write-DoctorResult -Path $doctorRejectedPath -ProjectRoot $doctorRejectedProject -ScannerVersion "0.3.0"
    $doctorRejected = Invoke-Verifier -CaseName "doctor-rejected" -ProjectRoot $doctorRejectedProject -DoctorPath $doctorRejectedPath -UnityPath $fakeUnity
    Assert-Equal -Expected "VERIFICATION_BLOCKED" -Actual $doctorRejected.result.finalStatus -Message "Rejected Doctor final status"
    Assert-Equal -Expected $false -Actual $doctorRejected.result.doctor.accepted -Message "Rejected Doctor acceptance"
    Assert-Equal -Expected $false -Actual $doctorRejected.result.unity.processStarted -Message "Rejected Doctor prevents Unity"
    Assert-True -Condition (-not (Test-Path -LiteralPath $doctorRejected.argumentsPath)) -Message "Rejected Doctor has no fake Unity invocation"
    Assert-Contains -Collection @($doctorRejected.result.blockers | ForEach-Object code) -Expected "DOCTOR_SCANNER_VERSION_MISMATCH" -Message "Doctor scanner version blocker"

    $blockedDoctorProject = New-TestUnityProject -Name "doctor-blocked"
    $blockedDoctorPath = Join-Path $script:ScratchRoot "doctor\blocked.json"
    $blockedCheck = [ordered]@{ code = "FIXTURE_BLOCK"; check = "fixture"; path = $null; message = "Fixture blocker." }
    Write-DoctorResult -Path $blockedDoctorPath -ProjectRoot $blockedDoctorProject -FinalStatus "AUDIT_BLOCKED" -BlockedChecks @($blockedCheck)
    $blockedDoctor = Invoke-Verifier -CaseName "doctor-blocked" -ProjectRoot $blockedDoctorProject -DoctorPath $blockedDoctorPath -UnityPath $fakeUnity
    Assert-Equal -Expected "VERIFICATION_BLOCKED" -Actual $blockedDoctor.result.finalStatus -Message "Blocked Doctor final status"
    Assert-Equal -Expected $false -Actual $blockedDoctor.result.unity.processStarted -Message "Blocked Doctor prevents Unity"
    Assert-Contains -Collection @($blockedDoctor.result.blockers | ForEach-Object code) -Expected "DOCTOR_FINAL_STATUS_REJECTED" -Message "Doctor final status blocker"
    Assert-Contains -Collection @($blockedDoctor.result.blockers | ForEach-Object code) -Expected "DOCTOR_BLOCKED_CHECKS_PRESENT" -Message "Doctor blocked-check blocker"

    $wrongUnity = New-FakeUnityExecutable -OutputPath (Join-Path $script:ScratchRoot "fake-unity\6000.0.68f1\Editor\Unity.exe") -ProductVersion "6000.0.68f1_wrong"
    $wrongVersionProject = New-TestUnityProject -Name "wrong-unity"
    $wrongVersionDoctor = Join-Path $script:ScratchRoot "doctor\wrong-unity.json"
    Write-DoctorResult -Path $wrongVersionDoctor -ProjectRoot $wrongVersionProject
    $wrongVersion = Invoke-Verifier -CaseName "wrong-unity" -ProjectRoot $wrongVersionProject -DoctorPath $wrongVersionDoctor -UnityPath $wrongUnity
    Assert-Equal -Expected "VERIFICATION_BLOCKED" -Actual $wrongVersion.result.finalStatus -Message "Wrong Unity final status"
    Assert-Equal -Expected $false -Actual $wrongVersion.result.unity.processStarted -Message "Wrong Unity prevents process"
    Assert-Contains -Collection @($wrongVersion.result.blockers | ForEach-Object code) -Expected "UNITY_EXECUTABLE_VERSION_MISMATCH" -Message "Wrong Unity version blocker"

    $externalPackageProject = New-TestUnityProject -Name "external-package" -ManifestContent '{"dependencies":{"com.example.local":"file:../../outside-package"}}'
    $externalPackageDoctor = Join-Path $script:ScratchRoot "doctor\external-package.json"
    Write-DoctorResult -Path $externalPackageDoctor -ProjectRoot $externalPackageProject
    $externalPackage = Invoke-Verifier -CaseName "external-package" -ProjectRoot $externalPackageProject -DoctorPath $externalPackageDoctor -UnityPath $fakeUnity
    Assert-Equal -Expected "VERIFICATION_BLOCKED" -Actual $externalPackage.result.finalStatus -Message "External local package final status"
    Assert-Equal -Expected $false -Actual $externalPackage.result.unity.processStarted -Message "External local package prevents Unity"
    Assert-Contains -Collection @($externalPackage.result.blockers | ForEach-Object code) -Expected "LOCAL_PACKAGE_OUTSIDE_PROJECT" -Message "External local package blocker"
    Assert-Equal -Expected "UNCHANGED" -Actual $externalPackage.result.originalProjectIntegrity.status -Message "External package project unchanged"

    $mutationProject = New-TestUnityProject -Name "original-mutation"
    $mutationDoctor = Join-Path $script:ScratchRoot "doctor\original-mutation.json"
    Write-DoctorResult -Path $mutationDoctor -ProjectRoot $mutationProject
    $mutationPath = Join-Path -Path $mutationProject -ChildPath "Assets\MutatedByFakeUnity.txt"
    $mutation = Invoke-Verifier -CaseName "original-mutation" -ProjectRoot $mutationProject -DoctorPath $mutationDoctor -UnityPath $fakeUnity -MutationPath $mutationPath
    Assert-Equal -Expected "ORIGINAL_PROJECT_CHANGED" -Actual $mutation.result.finalStatus -Message "Original mutation final status"
    Assert-Equal -Expected "CHANGED" -Actual $mutation.result.originalProjectIntegrity.status -Message "Original mutation integrity status"
    Assert-Contains -Collection @($mutation.result.originalProjectIntegrity.addedFiles) -Expected "Assets/MutatedByFakeUnity.txt" -Message "Original added file reported"
    Assert-True -Condition (Test-Path -LiteralPath $mutationPath -PathType Leaf) -Message "Verifier did not automatically roll back mutation"

    $whatIfDestination = Join-Path $script:ScratchRoot "installer-whatif\skills"
    & $script:InstallerPath -DestinationRoot $whatIfDestination -WhatIf | Out-Null
    Assert-True -Condition (-not (Test-Path -LiteralPath $whatIfDestination)) -Message "Installer WhatIf makes no destination"

    if (Test-SymbolicLinkCapability) {
        $installDestination = Join-Path $script:ScratchRoot "installer\skills"
        & $script:InstallerPath -DestinationRoot $installDestination | Out-Null
        $installedLink = Join-Path $installDestination "unity-baseline-verification"
        Assert-True -Condition (Test-Path -LiteralPath $installedLink -PathType Container) -Message "Installer creates Skill link"
        $linkEntry = Get-Item -LiteralPath $installedLink -Force
        Assert-Equal -Expected "SymbolicLink" -Actual $linkEntry.LinkType -Message "Installer link type"
        & $script:InstallerPath -DestinationRoot $installDestination | Out-Null
        $linkEntryAgain = Get-Item -LiteralPath $installedLink -Force
        Assert-Equal -Expected "SymbolicLink" -Actual $linkEntryAgain.LinkType -Message "Installer idempotency"
    } else {
        Write-Host "Symbolic-link creation tests skipped because this token lacks the required Windows privilege."
    }

    $conflictDestination = Join-Path $script:ScratchRoot "installer-conflict\skills"
    $conflictPath = Join-Path $conflictDestination "unity-baseline-verification"
    Write-TestText -Path (Join-Path $conflictPath "marker.txt") -Content "preserve"
    $conflictThrown = $false
    try {
        & $script:InstallerPath -DestinationRoot $conflictDestination -WarningAction SilentlyContinue | Out-Null
    } catch {
        $conflictThrown = $true
    }
    Assert-True -Condition $conflictThrown -Message "Installer rejects conflict"
    Assert-Equal -Expected "preserve" -Actual ([System.IO.File]::ReadAllText((Join-Path $conflictPath "marker.txt"), $script:Utf8NoBom)) -Message "Installer preserves conflict"

    $repositoryAfter = Get-TestTreeSnapshot -Root $script:RepositoryRoot
    Assert-Equal -Expected $repositoryBefore -Actual $repositoryAfter -Message "Test suite leaves repository byte-for-byte unchanged"

    $script:TestsPassed = $true
    Write-Host "All tests passed. Assertions: $($script:Assertions)"
} finally {
    if ($script:TestsPassed) {
        Remove-TestScratch
    } else {
        Write-Host "Test scratch retained for diagnosis: $script:ScratchRoot"
    }
}
