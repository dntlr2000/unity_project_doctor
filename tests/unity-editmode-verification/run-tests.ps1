[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:SkillRoot = Join-Path $script:RepositoryRoot 'skills\codex\unity-editmode-verification'
$script:RunnerPath = Join-Path $script:SkillRoot 'scripts\invoke-unity-editmode-verification.ps1'
$script:CorePath = Join-Path $script:SkillRoot 'scripts\lib\unity-editmode-verification-core.ps1'
$script:ProcessLibraryPath = Join-Path $script:RepositoryRoot 'skills\codex\unity-baseline-verification\scripts\lib\unity-process-job.ps1'
$script:ValidatorPath = Join-Path $script:RepositoryRoot 'skills\codex\unity-baseline-verification\scripts\lib\json-schema-validator.ps1'
$script:HandoffSchemaPath = Join-Path $script:RepositoryRoot 'schemas\unity-baseline-editmode-handoff-1.0.0.schema.json'
$script:ResultSchemaPath = Join-Path $script:RepositoryRoot 'schemas\unity-editmode-verification-result-1.0.0.schema.json'
$script:InstallerPath = Join-Path $script:RepositoryRoot 'scripts\install-codex-skills.ps1'
$script:ScratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('uev-tests-' + [guid]::NewGuid().ToString('N'))
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Assertions = 0

. $script:CorePath
. $script:ProcessLibraryPath
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

# Writes a UTF-8-no-BOM test artifact under the system temporary directory.
function Write-TestText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [void][System.IO.Directory]::CreateDirectory($parent)
    }
    [void][System.IO.File]::WriteAllText($Path, $Content, $script:Utf8NoBom)
}

# Returns a deterministic file-list and hash snapshot outside Git metadata.
function Get-TestTreeSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Root
    )

    $records = New-Object System.Collections.ArrayList
    foreach ($file in Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Where-Object {
        $_.FullName -notmatch '[\\/]\.git(?:[\\/]|$)'
    } | Sort-Object -Property FullName) {
        $relative = $file.FullName.Substring((Get-UevNormalizedPath $Root).Length).TrimStart('\', '/').Replace('\', '/')
        [void]$records.Add("$relative|$($file.Length)|$(Get-UevFileSha256 $file.FullName)")
    }
    return [string]::Join("`n", [string[]]$records)
}

# Creates one deterministic copy-set file record for fingerprint assessment tests.
function New-TestFingerprintFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]$')][string]$DigestCharacter,
        [Parameter()][long]$Length = 1
    )

    return [pscustomobject][ordered]@{
        path = $Path
        length = $Length
        sha256 = $DigestCharacter * 64
    }
}

# Creates one deterministic in-memory copy-set snapshot without touching a Unity project.
function New-TestFingerprintSnapshot {
    param(
        [Parameter()][string[]]$Directories = @(),
        [Parameter()][object[]]$Files = @(),
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]$')][string]$TreeDigestCharacter
    )

    return [pscustomobject][ordered]@{
        directories = @($Directories)
        files = @($Files)
        directoryCount = @($Directories).Count
        fileCount = @($Files).Count
        treeSha256 = $TreeDigestCharacter * 64
    }
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

# Compiles one unsigned Unity-shaped process fixture for internal process tests only.
function New-FakeEditModeUnity {
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $OutputPath))
    $source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;

internal static class Program
{
    // Returns the value following one case-insensitive command-line option.
    private static string GetValue(string[] args, string option)
    {
        for (int index = 0; index + 1 < args.Length; index++)
        {
            if (String.Equals(args[index], option, StringComparison.OrdinalIgnoreCase)) return args[index + 1];
        }
        return null;
    }

    // Writes one UTF-8-no-BOM artifact after creating its parent.
    private static void WriteFile(string path, string content)
    {
        if (String.IsNullOrWhiteSpace(path)) return;
        string parent = Path.GetDirectoryName(path);
        if (!String.IsNullOrWhiteSpace(parent)) Directory.CreateDirectory(parent);
        File.WriteAllText(path, content, new UTF8Encoding(false));
    }

    // Emits controlled EditMode XML and log evidence without running Unity.
    private static int Main(string[] args)
    {
        string scenario = Environment.GetEnvironmentVariable("UEV_FAKE_SCENARIO") ?? "success";
        if (String.Equals(scenario, "timeout", StringComparison.OrdinalIgnoreCase)) Thread.Sleep(Timeout.Infinite);
        WriteFile(Environment.GetEnvironmentVariable("UEV_FAKE_ARGUMENTS"), String.Join(Environment.NewLine, args));
        string project = GetValue(args, "-projectPath");
        string results = GetValue(args, "-testResults");
        string log = GetValue(args, "-logFile");
        string upm = GetValue(args, "-upmLogFile");
        string xml = "<test-run result=\"Passed\" total=\"2\" passed=\"2\" failed=\"0\" inconclusive=\"0\" skipped=\"0\" asserts=\"2\" duration=\"0.1\" />";
        if (scenario == "skipped") xml = "<test-run result=\"Passed\" total=\"2\" passed=\"1\" failed=\"0\" inconclusive=\"0\" skipped=\"1\" asserts=\"1\" duration=\"0.1\" />";
        if (scenario == "failed") xml = "<test-run result=\"Failed\" total=\"2\" passed=\"1\" failed=\"1\" inconclusive=\"0\" skipped=\"0\" asserts=\"2\" duration=\"0.1\"><test-case fullname=\"Example.Fail\" result=\"Failed\"><failure><message>expected true</message><stack-trace>line 1</stack-trace></failure></test-case></test-run>";
        if (scenario == "inconclusive") xml = "<test-run result=\"Inconclusive\" total=\"1\" passed=\"0\" failed=\"0\" inconclusive=\"1\" skipped=\"0\" asserts=\"0\" duration=\"0.1\" />";
        if (scenario == "zero") xml = "<test-run result=\"Passed\" total=\"0\" passed=\"0\" failed=\"0\" inconclusive=\"0\" skipped=\"0\" asserts=\"0\" duration=\"0\" />";
        if (scenario == "malformed") xml = "<test-run>";
        if (scenario != "missing") WriteFile(results, xml);
        var lines = new List<string>();
        lines.Add("Built from '6000.0/staging' branch; Version is '6000.0.69f1 (fixture) revision fixture'");
        lines.Add("BatchMode: 1, IsHumanControllingUs: 0");
        lines.Add("Successfully changed project path to: " + project);
        lines.Add("runTests started through Unity Test Framework");
        if (scenario == "compiler") lines.Add("Assets/Broken.cs(1,1): error CS1002: ; expected");
        WriteFile(log, String.Join(Environment.NewLine, lines));
        WriteFile(upm, "fixture");
        int exitCode;
        if (!Int32.TryParse(Environment.GetEnvironmentVariable("UEV_FAKE_EXIT"), out exitCode)) exitCode = 0;
        return exitCode;
    }
}
'@
    Add-Type -TypeDefinition $source -Language CSharp -OutputAssembly $OutputPath -OutputType ConsoleApplication
    return Get-UevNormalizedPath $OutputPath
}

# Runs the internal fake process through production Job Object control.
function Invoke-FakeEditModeCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$FakeUnity,
        [Parameter(Mandatory = $true)][string]$Scenario,
        [Parameter()][int]$TimeoutSeconds = 10
    )

    $caseRoot = Join-Path $script:ScratchRoot $Name
    $project = Join-Path $caseRoot 'project'
    [void][System.IO.Directory]::CreateDirectory($project)
    $results = Join-Path $caseRoot 'result.xml'
    $log = Join-Path $caseRoot 'Editor.log'
    $upm = Join-Path $caseRoot 'upm.log'
    $stdout = Join-Path $caseRoot 'stdout.log'
    $stderr = Join-Path $caseRoot 'stderr.log'
    $argumentsPath = Join-Path $caseRoot 'arguments.txt'
    $arguments = New-UevUnityArguments -ProjectPath $project -AssemblyNames 'Example.Tests' -TestResultsPath $results -EditorLogPath $log -UpmLogPath $upm
    $oldScenario = $env:UEV_FAKE_SCENARIO
    $oldArguments = $env:UEV_FAKE_ARGUMENTS
    $oldExit = $env:UEV_FAKE_EXIT
    try {
        $env:UEV_FAKE_SCENARIO = $Scenario
        $env:UEV_FAKE_ARGUMENTS = $argumentsPath
        $env:UEV_FAKE_EXIT = '0'
        $process = Invoke-UnityProcessInJob -ExecutablePath $FakeUnity -Arguments $arguments -WorkingDirectory $caseRoot -StandardOutputPath $stdout -StandardErrorPath $stderr -TimeoutSeconds $TimeoutSeconds
    } finally {
        $env:UEV_FAKE_SCENARIO = $oldScenario
        $env:UEV_FAKE_ARGUMENTS = $oldArguments
        $env:UEV_FAKE_EXIT = $oldExit
    }
    return [pscustomobject]@{
        process = $process
        arguments = $arguments
        argumentsPath = $argumentsPath
        nunit = Get-UevNUnitAnalysis -Path $results
        editorLog = Get-UevEditorLogAnalysis -Path $log -ExpectedUnityVersion '6000.0.69f1' -ExpectedProjectPath $project
    }
}

# Creates the minimal accepted Baseline handoff used by schema tests.
function New-TestBaselineHandoff {
    return [pscustomobject][ordered]@{
        schemaVersion = '1.1.0'; verifierVersion = '0.1.3'; projectRoot = 'C:\fixture'; expectedUnityVersion = '6000.0.69f1'
        doctor = [pscustomobject][ordered]@{
            sourcePath = 'C:\temp\doctor.json'; sha256 = ('a' * 64); schemaVersion = '1.1.0'; scannerVersion = '0.2.1'
            projectRoot = 'C:\fixture'; finalStatus = 'STATIC_AUDIT_COMPLETE'; schemaValidated = $true; fingerprintMatched = $true
            projectFingerprint = [pscustomobject]@{}; currentProjectFingerprint = [pscustomobject]@{}; accepted = $true
        }
        unity = [pscustomobject][ordered]@{
            executablePath = 'C:\Unity\Unity.exe'; executableSha256 = ('b' * 64); detectedExecutableVersion = '6000.0.69f1'
            executableVersionMatched = $true; signatureStatus = 'Valid'; signerSubject = 'CN=Unity Technologies SF'
            certificateThumbprint = 'ABC'; publisherMatched = $true; processStarted = $true; timedOut = $false; exitCode = 0
        }
        processControl = [pscustomobject]@{ jobObjectCreated = $true; killOnJobCloseConfigured = $true; processAssignedToJob = $true; rootProcessExited = $true; processTreeExitVerified = $true; activeProcessCountAfterWait = 0 }
        preflight = [pscustomobject]@{ sourceEditorCheckCompleted = $true; sourceEditorDetected = $false; sourceSnapshotStable = $true; gitMetadataSnapshotAccepted = $true; artifactRootOutsideProject = $true; trustedPathsWithoutReparse = $true }
        isolation = [pscustomobject]@{ sessionRoot = 'C:\temp\b'; projectCopyPath = 'C:\temp\b\project'; copyStatus = 'COPIED'; copyFingerprint = [pscustomobject]@{}; originalProjectPassedToUnity = $false }
        artifacts = [pscustomobject]@{ resultPath = 'C:\temp\result.json'; resultWritten = $true }
        originalProjectIntegrity = [pscustomobject]@{ status = 'UNCHANGED'; unchanged = $true; beforeTreeSha256 = ('c' * 64); afterTreeSha256 = ('c' * 64) }
        gitMetadataIntegrity = [pscustomobject]@{ status = 'UNCHANGED' }
        verification = [pscustomobject]@{
            scriptCompilation = [pscustomobject]@{ status = 'VERIFIED_SUCCESS' }
            tests = [pscustomobject]@{ status = 'NOT_VERIFIED' }
            playerBuild = [pscustomobject]@{ status = 'NOT_VERIFIED' }
            playMode = [pscustomobject]@{ status = 'NOT_VERIFIED' }
            runtime = [pscustomobject]@{ status = 'NOT_VERIFIED' }
        }
        blockers = @(); finalStatus = 'BASELINE_VERIFIED'
    }
}

# Creates a minimal result object for the public result-schema regression.
function New-TestEditModeResult {
    return [pscustomobject][ordered]@{
        schemaVersion = '1.0.0'; verifierVersion = '0.1.0'; projectRoot = 'C:\fixture'
        baseline = [pscustomobject]@{}; doctor = [pscustomobject]@{}; unity = [pscustomobject]@{}; preflight = [pscustomobject]@{}
        processControl = [pscustomobject]@{}; isolation = [pscustomobject]@{}; artifacts = [pscustomobject]@{}
        testSelection = [pscustomobject]@{}; nunit = [pscustomobject]@{}; editorLog = [pscustomobject]@{}
        originalProjectIntegrity = [pscustomobject]@{}; gitMetadataIntegrity = [pscustomobject]@{}
        verification = [pscustomobject][ordered]@{
            scriptCompilation = [pscustomobject]@{ status = 'VERIFIED_SUCCESS'; reason = 'accepted Baseline' }
            editModeTests = [pscustomobject]@{ status = 'VERIFIED_SUCCESS'; reason = 'complete XML evidence' }
            playMode = [pscustomobject]@{ status = 'NOT_VERIFIED'; reason = 'not run' }
            playerBuild = [pscustomobject]@{ status = 'NOT_VERIFIED'; reason = 'not run' }
            runtime = [pscustomobject]@{ status = 'NOT_VERIFIED'; reason = 'not run' }
        }
        warnings = @(); failures = @(); blockers = @(); finalStatus = 'EDITMODE_VERIFIED'; evidence = @()
    }
}

$repositoryBefore = Get-TestTreeSnapshot -Root $script:RepositoryRoot
[void][System.IO.Directory]::CreateDirectory($script:ScratchRoot)
try {
    foreach ($required in @($script:RunnerPath, $script:CorePath, $script:HandoffSchemaPath, $script:ResultSchemaPath, $script:InstallerPath)) {
        Assert-True -Condition (Test-Path -LiteralPath $required -PathType Leaf) -Message "Required path exists: $required"
    }
    foreach ($schemaPath in @($script:HandoffSchemaPath, $script:ResultSchemaPath)) {
        Assert-True -Condition ($null -ne (Get-Content -Raw -LiteralPath $schemaPath | ConvertFrom-Json -ErrorAction Stop)) -Message "Schema parses: $schemaPath"
    }

    $runnerContent = Get-Content -Raw -LiteralPath $script:RunnerPath
    $fingerprintCallIndex = $runnerContent.LastIndexOf('Test-UevFingerprintBindings')
    $binaryPreflightCallIndex = $runnerContent.LastIndexOf('Test-UevSelectedAssemblyBinaries')
    $editModeCallIndex = $runnerContent.LastIndexOf('Invoke-UevEditModeTests')
    Assert-True -Condition ($fingerprintCallIndex -ge 0 -and $binaryPreflightCallIndex -gt $fingerprintCallIndex) -Message 'Production runner invokes selected-DLL proof after fingerprint binding'
    Assert-True -Condition ($editModeCallIndex -gt $binaryPreflightCallIndex) -Message 'Production runner invokes selected-DLL proof before the EditMode Unity process'
    Assert-True -Condition $runnerContent.Contains('selectedAssemblyBinariesPresent = $false') -Message 'Production result initializes selected-DLL preflight evidence fail-closed'
    Assert-True -Condition $runnerContent.Contains("-Code 'TEST_ASSEMBLY_NOT_BUILT'") -Message 'Production runner preserves a missing selected-DLL blocker'
    Assert-True -Condition $runnerContent.Contains('$script:Result.baseline.diagnostics = Get-UevBaselineDiagnosticSummary') -Message 'Production runner preserves Baseline diagnostics before handoff rejection'

    $selection = Get-UevAssemblySelection -ConfirmedAssemblies @(
        [pscustomobject]@{ name = 'Zeta.Tests'; path = 'Assets/Zeta.Tests.asmdef'; evidence = @('optionalUnityReferences:TestAssemblies') },
        [pscustomobject]@{ name = 'Alpha.Tests'; path = 'Assets/Alpha.Tests.asmdef'; evidence = @('reference:UnityEditor.TestRunner') }
    )
    Assert-True -Condition $selection.accepted -Message 'Safe confirmed assembly names are accepted'
    Assert-Equal -Expected 'Alpha.Tests;Zeta.Tests' -Actual $selection.argument -Message 'Assembly names are sorted and joined deterministically'
    Assert-Equal -Expected 2 -Actual $selection.records.Count -Message 'Every confirmed record is preserved'
    Assert-True -Condition (-not (Get-UevAssemblySelection -ConfirmedAssemblies @([pscustomobject]@{ name = 'Bad;Name'; path = 'Assets/Bad.asmdef'; evidence = @('direct') })).accepted) -Message 'Semicolon assembly name is rejected'
    Assert-True -Condition (-not (Get-UevAssemblySelection -ConfirmedAssemblies @(
        [pscustomobject]@{ name = 'Same.Tests'; path = 'Assets/A.asmdef'; evidence = @('direct') },
        [pscustomobject]@{ name = 'same.tests'; path = 'Assets/B.asmdef'; evidence = @('direct') }
    )).accepted) -Message 'Case-insensitive duplicate assembly is rejected'
    $emptySelection = Get-UevAssemblySelection -ConfirmedAssemblies @()
    Assert-True -Condition $emptySelection.accepted -Message 'Empty confirmed selection is a valid no-evidence state'
    Assert-Equal -Expected 0 -Actual $emptySelection.names.Count -Message 'Empty selection has no names'

    Assert-True -Condition (Test-UevRootIdeGeneratedFilePath -RelativePath 'project.sln') -Message 'Root solution is a narrow generated-IDE path'
    Assert-True -Condition (Test-UevRootIdeGeneratedFilePath -RelativePath 'Assembly-CSharp.csproj') -Message 'Root C# project is a narrow generated-IDE path'
    Assert-True -Condition (Test-UevRootIdeGeneratedFilePath -RelativePath 'Assembly-CSharp.csproj.user') -Message 'Root C# project user file is a narrow generated-IDE path'
    Assert-True -Condition (-not (Test-UevRootIdeGeneratedFilePath -RelativePath 'Assets/Assembly-CSharp.csproj')) -Message 'Nested C# project is not allowlisted'
    Assert-True -Condition (-not (Test-UevRootIdeGeneratedFilePath -RelativePath 'project.sln.DotSettings')) -Message 'Unlisted root IDE suffix is not allowlisted'

    $sourceFingerprintSnapshot = New-TestFingerprintSnapshot `
        -TreeDigestCharacter 'a' `
        -Directories @('Assets', 'ProjectSettings', 'Tools') `
        -Files @(
            (New-TestFingerprintFile -Path 'Assets/Game.cs' -DigestCharacter '1' -Length 10),
            (New-TestFingerprintFile -Path 'ProjectSettings/ProjectVersion.txt' -DigestCharacter '2' -Length 20),
            (New-TestFingerprintFile -Path 'Assembly-CSharp.csproj' -DigestCharacter '3' -Length 30),
            (New-TestFingerprintFile -Path 'Legacy.sln' -DigestCharacter '4' -Length 40)
        )
    $exactFingerprintSnapshot = New-TestFingerprintSnapshot `
        -TreeDigestCharacter 'a' `
        -Directories @('Assets', 'ProjectSettings', 'Tools') `
        -Files @(
            (New-TestFingerprintFile -Path 'Assets/Game.cs' -DigestCharacter '1' -Length 10),
            (New-TestFingerprintFile -Path 'ProjectSettings/ProjectVersion.txt' -DigestCharacter '2' -Length 20),
            (New-TestFingerprintFile -Path 'Assembly-CSharp.csproj' -DigestCharacter '3' -Length 30),
            (New-TestFingerprintFile -Path 'Legacy.sln' -DigestCharacter '4' -Length 40)
        )
    $exactFingerprintAssessment = Get-UevIsolationFingerprintAssessment -SourceSnapshot $sourceFingerprintSnapshot -IsolationSnapshot $exactFingerprintSnapshot
    Assert-True -Condition $exactFingerprintAssessment.accepted -Message 'Exact reusable isolation fingerprint is accepted'
    Assert-True -Condition $exactFingerprintAssessment.exactMatch -Message 'Exact reusable isolation is classified as an exact match'
    Assert-Equal -Expected 'EXACT_MATCH' -Actual $exactFingerprintAssessment.classification -Message 'Exact fingerprint classification is stable'

    $generatedIdeDeltaSnapshot = New-TestFingerprintSnapshot `
        -TreeDigestCharacter 'b' `
        -Directories @('Assets', 'ProjectSettings', 'Tools') `
        -Files @(
            (New-TestFingerprintFile -Path 'Assets/Game.cs' -DigestCharacter '1' -Length 10),
            (New-TestFingerprintFile -Path 'ProjectSettings/ProjectVersion.txt' -DigestCharacter '2' -Length 20),
            (New-TestFingerprintFile -Path 'Assembly-CSharp.csproj' -DigestCharacter '5' -Length 35),
            (New-TestFingerprintFile -Path 'project.sln' -DigestCharacter '6' -Length 60)
        )
    $generatedIdeAssessment = Get-UevIsolationFingerprintAssessment -SourceSnapshot $sourceFingerprintSnapshot -IsolationSnapshot $generatedIdeDeltaSnapshot
    Assert-True -Condition $generatedIdeAssessment.accepted -Message 'Only root IDE-generated file delta is accepted'
    Assert-True -Condition (-not $generatedIdeAssessment.exactMatch) -Message 'Allowed generated-file delta is not reported as raw fingerprint equality'
    Assert-Equal -Expected 'ROOT_IDE_GENERATED_FILES_ONLY' -Actual $generatedIdeAssessment.classification -Message 'Generated-file-only classification is explicit'
    Assert-Equal -Expected 3 -Actual $generatedIdeAssessment.allowedDeltaCount -Message 'Added, removed, and changed root IDE files are all recorded'
    Assert-Equal -Expected 'project.sln' -Actual $generatedIdeAssessment.allowedAddedFiles[0].path -Message 'Added root solution path is recorded'
    Assert-Equal -Expected 'Legacy.sln' -Actual $generatedIdeAssessment.allowedRemovedFiles[0].path -Message 'Removed root solution path is recorded'
    Assert-Equal -Expected 'Assembly-CSharp.csproj' -Actual $generatedIdeAssessment.allowedChangedFiles[0].path -Message 'Changed root C# project hashes are recorded'
    Assert-Equal -Expected ('3' * 64) -Actual $generatedIdeAssessment.allowedChangedFiles[0].sourceSha256 -Message 'Changed root C# project source hash is preserved'
    Assert-Equal -Expected ('5' * 64) -Actual $generatedIdeAssessment.allowedChangedFiles[0].isolationSha256 -Message 'Changed root C# project isolation hash is preserved'
    $generatedIdeAssessmentRepeat = Get-UevIsolationFingerprintAssessment -SourceSnapshot $sourceFingerprintSnapshot -IsolationSnapshot $generatedIdeDeltaSnapshot
    Assert-Equal -Expected ($generatedIdeAssessment | ConvertTo-Json -Depth 20 -Compress) -Actual ($generatedIdeAssessmentRepeat | ConvertTo-Json -Depth 20 -Compress) -Message 'Generated IDE delta evidence is deterministic'

    $assetMutationSnapshot = New-TestFingerprintSnapshot `
        -TreeDigestCharacter 'c' `
        -Directories @('Assets', 'ProjectSettings', 'Tools') `
        -Files @(
            (New-TestFingerprintFile -Path 'Assets/Game.cs' -DigestCharacter '9' -Length 10),
            (New-TestFingerprintFile -Path 'ProjectSettings/ProjectVersion.txt' -DigestCharacter '2' -Length 20),
            (New-TestFingerprintFile -Path 'Assembly-CSharp.csproj' -DigestCharacter '3' -Length 30),
            (New-TestFingerprintFile -Path 'Legacy.sln' -DigestCharacter '4' -Length 40)
        )
    $assetMutationAssessment = Get-UevIsolationFingerprintAssessment -SourceSnapshot $sourceFingerprintSnapshot -IsolationSnapshot $assetMutationSnapshot
    Assert-True -Condition (-not $assetMutationAssessment.accepted) -Message 'Assets mutation remains fail-closed'
    Assert-Equal -Expected 'Assets/Game.cs' -Actual $assetMutationAssessment.disallowedChangedFiles[0].path -Message 'Changed source path is structured in evidence'

    $rootMutationSnapshot = New-TestFingerprintSnapshot `
        -TreeDigestCharacter 'd' `
        -Directories @('Assets', 'ProjectSettings', 'Tools') `
        -Files @(
            (New-TestFingerprintFile -Path 'Assets/Game.cs' -DigestCharacter '1' -Length 10),
            (New-TestFingerprintFile -Path 'ProjectSettings/ProjectVersion.txt' -DigestCharacter '2' -Length 20),
            (New-TestFingerprintFile -Path 'Assembly-CSharp.csproj' -DigestCharacter '3' -Length 30),
            (New-TestFingerprintFile -Path 'Legacy.sln' -DigestCharacter '4' -Length 40),
            (New-TestFingerprintFile -Path 'README.md' -DigestCharacter '7' -Length 70)
        )
    $rootMutationAssessment = Get-UevIsolationFingerprintAssessment -SourceSnapshot $sourceFingerprintSnapshot -IsolationSnapshot $rootMutationSnapshot
    Assert-True -Condition (-not $rootMutationAssessment.accepted) -Message 'Arbitrary project-root file addition remains fail-closed'
    Assert-Equal -Expected 'README.md' -Actual $rootMutationAssessment.disallowedAddedFiles[0].path -Message 'Arbitrary root delta is structured in evidence'

    $nestedIdeSnapshot = New-TestFingerprintSnapshot `
        -TreeDigestCharacter 'e' `
        -Directories @('Assets', 'ProjectSettings', 'Tools') `
        -Files @(
            (New-TestFingerprintFile -Path 'Assets/Game.cs' -DigestCharacter '1' -Length 10),
            (New-TestFingerprintFile -Path 'ProjectSettings/ProjectVersion.txt' -DigestCharacter '2' -Length 20),
            (New-TestFingerprintFile -Path 'Assembly-CSharp.csproj' -DigestCharacter '3' -Length 30),
            (New-TestFingerprintFile -Path 'Legacy.sln' -DigestCharacter '4' -Length 40),
            (New-TestFingerprintFile -Path 'Tools/Generated.csproj' -DigestCharacter '8' -Length 80)
        )
    $nestedIdeAssessment = Get-UevIsolationFingerprintAssessment -SourceSnapshot $sourceFingerprintSnapshot -IsolationSnapshot $nestedIdeSnapshot
    Assert-True -Condition (-not $nestedIdeAssessment.accepted) -Message 'Nested C# project addition is not treated as root IDE output'
    Assert-Equal -Expected 'Tools/Generated.csproj' -Actual $nestedIdeAssessment.disallowedAddedFiles[0].path -Message 'Nested IDE-like path is structured as disallowed'

    $directoryDeltaSnapshot = New-TestFingerprintSnapshot `
        -TreeDigestCharacter 'f' `
        -Directories @('Assets', 'Generated', 'ProjectSettings', 'Tools') `
        -Files @($sourceFingerprintSnapshot.files)
    $directoryDeltaAssessment = Get-UevIsolationFingerprintAssessment -SourceSnapshot $sourceFingerprintSnapshot -IsolationSnapshot $directoryDeltaSnapshot
    Assert-True -Condition (-not $directoryDeltaAssessment.accepted) -Message 'Any directory delta remains fail-closed'
    Assert-Equal -Expected 'Generated' -Actual $directoryDeltaAssessment.addedDirectories[0] -Message 'Directory delta is structured in evidence'

    $contradictoryHashSnapshot = New-TestFingerprintSnapshot `
        -TreeDigestCharacter '9' `
        -Directories @($sourceFingerprintSnapshot.directories) `
        -Files @($sourceFingerprintSnapshot.files)
    $contradictoryHashAssessment = Get-UevIsolationFingerprintAssessment -SourceSnapshot $sourceFingerprintSnapshot -IsolationSnapshot $contradictoryHashSnapshot
    Assert-True -Condition (-not $contradictoryHashAssessment.accepted) -Message 'Equal entries with contradictory tree hashes remain fail-closed'
    Assert-True -Condition $contradictoryHashAssessment.snapshotHashContradiction -Message 'Contradictory tree hash evidence is explicit'

    $binaryProject = Join-Path $script:ScratchRoot 'binary-preflight\project'
    $scriptAssembliesRoot = Join-Path $binaryProject 'Library\ScriptAssemblies'
    Write-TestText -Path (Join-Path $scriptAssembliesRoot 'Alpha.Tests.dll') -Content 'deterministic fake assembly bytes'
    $binaryPresent = Get-UevSelectedAssemblyBinaryAssessment -ProjectCopyPath $binaryProject -AssemblyNames @('Alpha.Tests')
    Assert-True -Condition $binaryPresent.accepted -Message 'A non-empty selected test assembly DLL is accepted'
    Assert-Equal -Expected 1 -Actual $binaryPresent.records.Count -Message 'Selected DLL evidence has one deterministic record'
    Assert-True -Condition ([string]$binaryPresent.records[0].sha256 -match '^[0-9a-f]{64}$') -Message 'Selected DLL SHA-256 is preserved'
    $binaryMissing = Get-UevSelectedAssemblyBinaryAssessment -ProjectCopyPath $binaryProject -AssemblyNames @('Alpha.Tests', 'Missing.Tests')
    Assert-True -Condition (-not $binaryMissing.accepted) -Message 'A missing selected test assembly DLL blocks preflight'
    Assert-Equal -Expected 'Missing.Tests' -Actual $binaryMissing.missingAssemblyNames[0] -Message 'Missing selected DLL name is exact'
    Assert-True -Condition (-not (Get-UevSelectedAssemblyBinaryAssessment -ProjectCopyPath $binaryProject -AssemblyNames @()).accepted) -Message 'An empty selected binary set is never accepted'

    $argumentRoot = Join-Path $script:ScratchRoot 'paths with spaces'
    $arguments = New-UevUnityArguments -ProjectPath (Join-Path $argumentRoot 'project') -AssemblyNames 'Alpha.Tests;Zeta.Tests' -TestResultsPath (Join-Path $argumentRoot 'result.xml') -EditorLogPath (Join-Path $argumentRoot 'Editor.log') -UpmLogPath (Join-Path $argumentRoot 'upm.log')
    foreach ($requiredArgument in @('-batchmode', '-nographics', '-runTests', '-projectPath', '-testPlatform', 'EditMode', '-assemblyNames', '-testResults', '-logFile', '-upmLogFile')) {
        Assert-True -Condition ($arguments -contains $requiredArgument) -Message "Fixed argument exists: $requiredArgument"
    }
    foreach ($forbiddenArgument in @('-quit', '-runSynchronously', '-executeMethod', '-accept-apiupdate', '-ignorecompilererrors')) {
        Assert-True -Condition ($arguments -notcontains $forbiddenArgument) -Message "Forbidden argument absent: $forbiddenArgument"
    }
    Assert-Equal -Expected 1 -Actual @($arguments | Where-Object { $_ -ceq 'Alpha.Tests;Zeta.Tests' }).Count -Message 'Assembly selector remains one opaque argument'

    $nunitRoot = Join-Path $script:ScratchRoot 'nunit'
    $xmlCases = @(
        [pscustomobject]@{ name = 'passed'; xml = '<test-run result="Passed" total="2" passed="2" failed="0" inconclusive="0" skipped="0" asserts="2" duration="0.1" />'; expected = 'PASSED' },
        [pscustomobject]@{ name = 'skipped'; xml = '<test-run result="Passed" total="2" passed="1" failed="0" inconclusive="0" skipped="1" asserts="1" duration="0.1" />'; expected = 'PASSED_WITH_SKIPS' },
        [pscustomobject]@{ name = 'failed'; xml = '<test-run result="Failed" total="2" passed="1" failed="1" inconclusive="0" skipped="0" asserts="2"><test-case fullname="Example.Fail" result="Failed"><failure><message>no</message></failure></test-case></test-run>'; expected = 'FAILED' },
        [pscustomobject]@{ name = 'error'; xml = '<test-run result="Failed" total="1" passed="0" failed="1" inconclusive="0" skipped="0" asserts="1"><test-case fullname="Example.Error" result="Failed" label="Error"><failure><message>boom</message></failure></test-case></test-run>'; expected = 'FAILED' },
        [pscustomobject]@{ name = 'inconclusive'; xml = '<test-run result="Inconclusive" total="1" passed="0" failed="0" inconclusive="1" skipped="0" asserts="0" />'; expected = 'INCONCLUSIVE' },
        [pscustomobject]@{ name = 'zero'; xml = '<test-run result="Passed" total="0" passed="0" failed="0" inconclusive="0" skipped="0" asserts="0" />'; expected = 'ZERO_TESTS' },
        [pscustomobject]@{ name = 'all-skipped'; xml = '<test-run result="Passed" total="1" passed="0" failed="0" inconclusive="0" skipped="1" asserts="0" />'; expected = 'NO_EXECUTED_TESTS' },
        [pscustomobject]@{ name = 'inconsistent'; xml = '<test-run result="Passed" total="2" passed="1" failed="0" inconclusive="0" skipped="0" asserts="1" />'; expected = 'INVALID' },
        [pscustomobject]@{ name = 'dtd'; xml = '<!DOCTYPE test-run [<!ENTITY xxe SYSTEM "file:///C:/Windows/win.ini">]><test-run result="Passed" total="1" passed="1" failed="0" inconclusive="0" skipped="0" asserts="1"><test-suite>&xxe;</test-suite></test-run>'; expected = 'INVALID' },
        [pscustomobject]@{ name = 'malformed'; xml = '<test-run>'; expected = 'INVALID' }
    )
    foreach ($case in $xmlCases) {
        $path = Join-Path $nunitRoot ($case.name + '.xml')
        Write-TestText -Path $path -Content $case.xml
        Assert-Equal -Expected $case.expected -Actual (Get-UevNUnitAnalysis -Path $path).classification -Message "NUnit $($case.name) classification"
    }
    Assert-Equal -Expected 'NOT_ANALYZED' -Actual (Get-UevNUnitAnalysis -Path (Join-Path $nunitRoot 'missing.xml')).classification -Message 'Missing XML remains not analyzed'
    Assert-Equal -Expected 'Example.Fail' -Actual (Get-UevNUnitAnalysis -Path (Join-Path $nunitRoot 'failed.xml')).problemDetails[0].name -Message 'Failed test name is preserved'
    $errorAnalysis = Get-UevNUnitAnalysis -Path (Join-Path $nunitRoot 'error.xml')
    Assert-Equal -Expected 1 -Actual $errorAnalysis.errors -Message 'Error test evidence is counted'
    Assert-Equal -Expected 0 -Actual $errorAnalysis.failed -Message 'NUnit3 Error cases are not double-counted as failures'
    $zeroDecision = Get-UevNUnitEvidenceDecision -NUnitAnalysis (Get-UevNUnitAnalysis -Path (Join-Path $nunitRoot 'zero.xml'))
    Assert-Equal -Expected 'NO_DISCOVERED_TEST_CASES' -Actual $zeroDecision.blockerCode -Message 'Zero tests after DLL preflight has a precise blocker'
    Assert-True -Condition (-not $zeroDecision.message.EndsWith(':', [System.StringComparison]::Ordinal)) -Message 'Zero-test message has no dangling colon'
    Assert-True -Condition (Get-UevNUnitEvidenceDecision -NUnitAnalysis (Get-UevNUnitAnalysis -Path (Join-Path $nunitRoot 'passed.xml'))).accepted -Message 'Passed NUnit evidence is accepted'
    $invalidNunitDecision = Get-UevNUnitEvidenceDecision -NUnitAnalysis (Get-UevNUnitAnalysis -Path (Join-Path $nunitRoot 'malformed.xml'))
    Assert-Equal -Expected 'NUNIT_EVIDENCE_INCONCLUSIVE' -Actual $invalidNunitDecision.blockerCode -Message 'Malformed NUnit evidence remains inconclusive'
    Assert-True -Condition (-not $invalidNunitDecision.message.EndsWith(':', [System.StringComparison]::Ordinal)) -Message 'Malformed NUnit message has no dangling colon'

    $logProject = Join-Path $script:ScratchRoot 'editor-log-project'
    [void][System.IO.Directory]::CreateDirectory($logProject)
    $safeLogLines = @(
        "Built from '6000.0/staging' branch; Version is '6000.0.69f1 (fixture) revision fixture'",
        'BatchMode: 1, IsHumanControllingUs: 0',
        "Successfully changed project path to: $logProject",
        'runTests started through Unity Test Framework'
    )
    $safeDiagnosticLog = Join-Path $script:ScratchRoot 'safe-diagnostic.log'
    Write-TestText -Path $safeDiagnosticLog -Content ([string]::Join("`n", @($safeLogLines + 'Licensing access-token error did not affect the test run.')))
    Assert-Equal -Expected 'SAFE' -Actual (Get-UevEditorLogAnalysis -Path $safeDiagnosticLog -ExpectedUnityVersion '6000.0.69f1' -ExpectedProjectPath $logProject).classification -Message 'Unrelated licensing text is not an asset-import failure'
    foreach ($logCase in @(
        [pscustomobject]@{ name = 'meta-yaml'; line = 'YAML Parsing error at Assets/Tests.meta'; code = 'ASSET_META_YAML_PARSE_ERROR' },
        [pscustomobject]@{ name = 'meta-guid'; line = 'Assets/Tests.meta does not have a valid GUID'; code = 'ASSET_META_GUID_INVALID' },
        [pscustomobject]@{ name = 'asmdef-import'; line = 'Assembly Definition Assets/Tests/Example.Tests.asmdef failed to import'; code = 'ASMDEF_IMPORT_FAILED' }
    )) {
        $path = Join-Path $script:ScratchRoot ($logCase.name + '.log')
        Write-TestText -Path $path -Content ([string]::Join("`n", @($safeLogLines + $logCase.line)))
        $analysis = Get-UevEditorLogAnalysis -Path $path -ExpectedUnityVersion '6000.0.69f1' -ExpectedProjectPath $logProject
        Assert-Equal -Expected 'FAILURE' -Actual $analysis.classification -Message "$($logCase.name) is a concrete EditMode log failure"
        Assert-True -Condition (@($analysis.failureMarkers | Where-Object { $_.code -eq $logCase.code }).Count -eq 1) -Message "$($logCase.name) preserves its precise failure code"
    }

    $sourceRoot = 'C:\Source\Project'
    $zero = Get-UevSourceEditorAssessment -ProjectRoot $sourceRoot -RunningProcesses @()
    Assert-True -Condition $zero.completed -Message 'Zero processes completes preflight'
    Assert-Equal -Expected $false -Actual $zero.detected -Message 'Zero processes detects no source editor'
    $cimDeniedEquivalent = Get-UevSourceEditorAssessment -ProjectRoot $sourceRoot -RunningProcesses @([pscustomobject]@{ processId = 10 }) -CimProcesses @() -StillRunningProcessIds @(10)
    Assert-Equal -Expected 'SOURCE_EDITOR_PREFLIGHT_UNAVAILABLE' -Actual $cimDeniedEquivalent.blockerCode -Message 'Live PID missing from CIM blocks'
    $sourceOpen = Get-UevSourceEditorAssessment -ProjectRoot $sourceRoot -RunningProcesses @([pscustomobject]@{ processId = 11 }) -CimProcesses @([pscustomobject]@{ processId = 11; commandLine = '"C:\Unity\Unity.exe" -projectPath "C:\Source\Project"' }) -StillRunningProcessIds @(11)
    Assert-Equal -Expected 'SOURCE_PROJECT_OPEN_IN_UNITY' -Actual $sourceOpen.blockerCode -Message 'Exact source project process blocks'
    Assert-Equal -Expected 11 -Actual $sourceOpen.processIds[0] -Message 'Exact source PID is preserved'
    $otherOpen = Get-UevSourceEditorAssessment -ProjectRoot $sourceRoot -RunningProcesses @([pscustomobject]@{ processId = 12 }) -CimProcesses @([pscustomobject]@{ processId = 12; commandLine = '"C:\Unity\Unity.exe" -projectPath "C:\Other\Project"' }) -StillRunningProcessIds @(12)
    Assert-True -Condition $otherOpen.completed -Message 'Other project can complete preflight'
    Assert-Equal -Expected $false -Actual $otherOpen.detected -Message 'Other project is not misclassified'
    $exitRace = Get-UevSourceEditorAssessment -ProjectRoot $sourceRoot -RunningProcesses @([pscustomobject]@{ processId = 13 }) -CimProcesses @() -StillRunningProcessIds @()
    Assert-True -Condition $exitRace.completed -Message 'Exited PID is accepted as a normal race'
    $newCimSource = Get-UevSourceEditorAssessment -ProjectRoot $sourceRoot -RunningProcesses @([pscustomobject]@{ processId = 16 }) -CimProcesses @(
        [pscustomobject]@{ processId = 16; commandLine = '"C:\Unity\Unity.exe" -projectPath "C:\Other\Project"' },
        [pscustomobject]@{ processId = 17; commandLine = '"C:\Unity\Unity.exe" -projectPath "C:\Source\Project"' }
    ) -StillRunningProcessIds @(16, 17)
    Assert-Equal -Expected 'SOURCE_PROJECT_OPEN_IN_UNITY' -Actual $newCimSource.blockerCode -Message 'Unity PID appearing during CIM is also inspected'
    Assert-Equal -Expected 17 -Actual $newCimSource.processIds[0] -Message 'New CIM source-project PID is preserved'
    $missingCommand = Get-UevSourceEditorAssessment -ProjectRoot $sourceRoot -RunningProcesses @([pscustomobject]@{ processId = 14 }) -CimProcesses @([pscustomobject]@{ processId = 14; commandLine = $null }) -StillRunningProcessIds @(14)
    Assert-Equal -Expected 'SOURCE_EDITOR_PREFLIGHT_UNAVAILABLE' -Actual $missingCommand.blockerCode -Message 'Missing live CommandLine blocks'
    $missingProjectPath = Get-UevSourceEditorAssessment -ProjectRoot $sourceRoot -RunningProcesses @([pscustomobject]@{ processId = 15 }) -CimProcesses @([pscustomobject]@{ processId = 15; commandLine = '"C:\Unity\Unity.exe" -batchmode' }) -StillRunningProcessIds @(15)
    Assert-Equal -Expected 'SOURCE_EDITOR_PREFLIGHT_UNAVAILABLE' -Actual $missingProjectPath.blockerCode -Message 'Missing projectPath blocks'

    $baselineUnity = [pscustomobject]@{ executablePath = 'C:\Unity\Unity.exe'; executableSha256 = ('a' * 64); detectedExecutableVersion = '6000.0.69f1'; signatureStatus = 'Valid'; signerSubject = 'CN=Unity Technologies SF'; certificateThumbprint = 'ABC' }
    $currentUnity = [pscustomobject]@{ executablePath = 'C:\Unity\Unity.exe'; executableSha256 = ('a' * 64); detectedExecutableVersion = '6000.0.69f1'; signatureStatus = 'Valid'; signerSubject = 'CN=Unity Technologies SF'; certificateThumbprint = 'ABC'; publisherMatched = $true }
    Assert-True -Condition (Get-UevUnityTrustAssessment -BaselineUnity $baselineUnity -CurrentUnity $currentUnity -ExpectedUnityVersion '6000.0.69f1').accepted -Message 'Unchanged Unity trust observation is accepted'
    $changedUnity = $currentUnity.PSObject.Copy()
    $changedUnity.executableSha256 = ('b' * 64)
    Assert-True -Condition (-not (Get-UevUnityTrustAssessment -BaselineUnity $baselineUnity -CurrentUnity $changedUnity -ExpectedUnityVersion '6000.0.69f1').accepted) -Message 'Changed Unity SHA blocks'

    $failedBaselineDiagnostics = Get-UevBaselineDiagnosticSummary -Baseline ([pscustomobject]@{
        finalStatus = 'BASELINE_FAILED'
        editorLog = [pscustomobject]@{
            compilerErrorCount = 9
            compilerErrors = @('Assets/GameManager.cs(1,1): error CS0234: InputSystem missing', 'Assets/RuntimeUi.cs(1,1): error CS0234: InputSystem missing')
            failureMarkers = @([pscustomobject]@{ code = 'COMPILER_ERROR'; line = 'first compiler error' })
        }
        processControl = [pscustomobject]@{
            terminationRequested = $true
            terminationReason = 'DESCENDANTS_REMAINED_AFTER_ROOT_EXIT'
            terminationApiSucceeded = $true
            processTreeExitVerified = $true
            activeProcessCountAfterWait = 0
        }
        failures = @([pscustomobject]@{ code = 'SCRIPT_COMPILATION_FAILED'; message = 'Compilation failed.' })
        blockers = @()
    })
    Assert-Equal -Expected 'BASELINE_SCRIPT_COMPILATION_FAILED' -Actual $failedBaselineDiagnostics.primaryCause.code -Message 'Baseline compiler failure is the preserved primary cause'
    Assert-Equal -Expected 9 -Actual $failedBaselineDiagnostics.compilerErrorCount -Message 'Baseline compiler occurrence count is preserved'
    Assert-Equal -Expected 2 -Actual $failedBaselineDiagnostics.compilerErrors.Count -Message 'Available concrete Baseline compiler lines are preserved'
    Assert-Equal -Expected 'DESCENDANTS_REMAINED_AFTER_ROOT_EXIT' -Actual $failedBaselineDiagnostics.processCleanup.terminationReason -Message 'Baseline cleanup remains a separate diagnostic axis'
    Assert-Equal -Expected 0 -Actual $failedBaselineDiagnostics.processCleanup.activeProcessCountAfterWait -Message 'Successful Baseline cleanup is preserved'
    Assert-Equal -Expected $null -Actual (Get-UevBaselineDiagnosticSummary -Baseline (New-TestBaselineHandoff)).primaryCause -Message 'Accepted Baseline has no synthetic primary failure'

    $validHandoff = New-TestBaselineHandoff
    Assert-Equal -Expected 0 -Actual @(Invoke-JsonSchemaValidation -Instance $validHandoff -SchemaPath $script:HandoffSchemaPath).Count -Message 'Valid narrow handoff schema'
    $invalidHandoff = New-TestBaselineHandoff
    $invalidHandoff.finalStatus = 'BASELINE_FAILED'
    Assert-True -Condition (@(Invoke-JsonSchemaValidation -Instance $invalidHandoff -SchemaPath $script:HandoffSchemaPath).Count -gt 0) -Message 'Wrong Baseline final status fails schema'
    $invalidDynamic = New-TestBaselineHandoff
    $invalidDynamic.verification.tests.status = 'VERIFIED_SUCCESS'
    Assert-True -Condition (@(Invoke-JsonSchemaValidation -Instance $invalidDynamic -SchemaPath $script:HandoffSchemaPath).Count -gt 0) -Message 'Previously verified tests fail handoff schema'
    Assert-Equal -Expected 0 -Actual @(Invoke-JsonSchemaValidation -Instance (New-TestEditModeResult) -SchemaPath $script:ResultSchemaPath).Count -Message 'Valid EditMode result schema'

    Assert-Equal -Expected 'NO_CONFIRMED_TEST_ASSEMBLY' -Actual (Get-UevFinalStatus -OriginalIntegrityStatus 'UNCHANGED' -GitIntegrityStatus 'UNCHANGED' -FailureCount 0 -BlockerCount 0 -NoConfirmedAssembly $true -ScriptCompilationStatus 'VERIFIED_SUCCESS' -EditModeStatus 'NOT_VERIFIED') -Message 'No confirmed assembly has dedicated final status'
    Assert-Equal -Expected 'ORIGINAL_PROJECT_CHANGED' -Actual (Get-UevFinalStatus -OriginalIntegrityStatus 'CHANGED' -GitIntegrityStatus 'UNCHANGED' -FailureCount 1 -BlockerCount 1 -NoConfirmedAssembly $false -ScriptCompilationStatus 'VERIFIED_SUCCESS' -EditModeStatus 'VERIFIED_FAILURE') -Message 'Original change has highest precedence'
    Assert-Equal -Expected 'EDITMODE_FAILED' -Actual (Get-UevFinalStatus -OriginalIntegrityStatus 'UNCHANGED' -GitIntegrityStatus 'UNCHANGED' -FailureCount 1 -BlockerCount 1 -NoConfirmedAssembly $false -ScriptCompilationStatus 'VERIFIED_SUCCESS' -EditModeStatus 'VERIFIED_FAILURE') -Message 'Concrete failure precedes incomplete evidence'
    Assert-Equal -Expected 'EDITMODE_VERIFIED' -Actual (Get-UevFinalStatus -OriginalIntegrityStatus 'UNCHANGED' -GitIntegrityStatus 'AMBIENT_CODEX_CHECKPOINTS_ONLY' -FailureCount 0 -BlockerCount 0 -NoConfirmedAssembly $false -ScriptCompilationStatus 'VERIFIED_SUCCESS' -EditModeStatus 'VERIFIED_SUCCESS') -Message 'Complete evidence verifies EditMode'

    $fakeUnity = New-FakeEditModeUnity -OutputPath (Join-Path $script:ScratchRoot 'fake\Unity.exe')
    Assert-Equal -Expected 'NotSigned' -Actual ([string](Get-AuthenticodeSignature -LiteralPath $fakeUnity).Status) -Message 'Internal fake remains unsigned'
    foreach ($case in @(
        [pscustomobject]@{ name = 'fake-success'; scenario = 'success'; classification = 'PASSED' },
        [pscustomobject]@{ name = 'fake-skipped'; scenario = 'skipped'; classification = 'PASSED_WITH_SKIPS' },
        [pscustomobject]@{ name = 'fake-failed'; scenario = 'failed'; classification = 'FAILED' },
        [pscustomobject]@{ name = 'fake-inconclusive'; scenario = 'inconclusive'; classification = 'INCONCLUSIVE' },
        [pscustomobject]@{ name = 'fake-zero'; scenario = 'zero'; classification = 'ZERO_TESTS' },
        [pscustomobject]@{ name = 'fake-malformed'; scenario = 'malformed'; classification = 'INVALID' },
        [pscustomobject]@{ name = 'fake-missing'; scenario = 'missing'; classification = 'NOT_ANALYZED' }
    )) {
        $result = Invoke-FakeEditModeCase -Name $case.name -FakeUnity $fakeUnity -Scenario $case.scenario
        Assert-True -Condition $result.process.processTreeExitVerified -Message "$($case.name) process tree exits"
        Assert-Equal -Expected 0 -Actual $result.process.activeProcessCountAfterWait -Message "$($case.name) has zero active processes"
        Assert-Equal -Expected $case.classification -Actual $result.nunit.classification -Message "$($case.name) XML classification"
        Assert-Equal -Expected 'SAFE' -Actual $result.editorLog.classification -Message "$($case.name) log classification"
    }
    $fakeSuccess = Invoke-FakeEditModeCase -Name 'fake-arguments' -FakeUnity $fakeUnity -Scenario 'success'
    $observedArguments = @([System.IO.File]::ReadAllLines($fakeSuccess.argumentsPath, $script:Utf8NoBom))
    foreach ($forbidden in @('-quit', '-runSynchronously', '-executeMethod', '-accept-apiupdate', '-ignorecompilererrors')) {
        Assert-True -Condition ($observedArguments -notcontains $forbidden) -Message "Fake child did not receive forbidden argument $forbidden"
    }
    $timeout = Invoke-FakeEditModeCase -Name 'fake-timeout' -FakeUnity $fakeUnity -Scenario 'timeout' -TimeoutSeconds 1
    Assert-True -Condition $timeout.process.timedOut -Message 'Fake timeout is observed'
    Assert-True -Condition $timeout.process.terminationRequested -Message 'Fake timeout requests Job Object termination'
    Assert-True -Condition $timeout.process.processTreeExitVerified -Message 'Fake timeout process tree exits'
    Assert-Equal -Expected 0 -Actual $timeout.process.activeProcessCountAfterWait -Message 'Fake timeout leaves zero active processes'

    $skillText = Get-Content -Raw -LiteralPath (Join-Path $script:SkillRoot 'SKILL.md')
    $metadataText = Get-Content -Raw -LiteralPath (Join-Path $script:SkillRoot 'agents\openai.yaml')
    Assert-True -Condition ($skillText -match '^---\s*\r?\nname:\s+unity-editmode-verification') -Message 'Skill frontmatter name is valid'
    Assert-True -Condition $skillText.Contains('$unity-editmode-verification') -Message 'Skill requires literal invocation'
    Assert-True -Condition ($metadataText -match 'allow_implicit_invocation:\s*false') -Message 'Skill remains explicit-only'
    Assert-Equal -Expected '0.1.0' -Actual (Get-Content -Raw -LiteralPath (Join-Path $script:SkillRoot 'VERSION')).Trim() -Message 'Component version is 0.1.0'

    $whatIfDestination = Join-Path $script:ScratchRoot 'installer-whatif\skills'
    & $script:InstallerPath -DestinationRoot $whatIfDestination -WhatIf | Out-Null
    Assert-True -Condition (-not (Test-Path -LiteralPath $whatIfDestination)) -Message 'Installer WhatIf creates no destination'
    if (Test-SymbolicLinkCapability) {
        $installDestination = Join-Path $script:ScratchRoot 'installer\skills'
        & $script:InstallerPath -DestinationRoot $installDestination | Out-Null
        $editModeLink = Join-Path $installDestination 'unity-editmode-verification'
        Assert-True -Condition (Test-Path -LiteralPath $editModeLink -PathType Container) -Message 'Installer links the EditMode Skill'
        Assert-Equal -Expected 'SymbolicLink' -Actual (Get-Item -LiteralPath $editModeLink -Force).LinkType -Message 'EditMode installation is a symbolic link'
        & $script:InstallerPath -DestinationRoot $installDestination | Out-Null
        Assert-Equal -Expected 'SymbolicLink' -Actual (Get-Item -LiteralPath $editModeLink -Force).LinkType -Message 'EditMode installer rerun is idempotent'
    } else {
        Write-Host 'Symbolic-link creation tests skipped because this token lacks the required Windows privilege.'
    }
    $conflictDestination = Join-Path $script:ScratchRoot 'installer-conflict\skills'
    $conflictPath = Join-Path $conflictDestination 'unity-editmode-verification'
    Write-TestText -Path (Join-Path $conflictPath 'marker.txt') -Content 'preserve'
    $conflictThrown = $false
    try {
        & $script:InstallerPath -DestinationRoot $conflictDestination -WarningAction SilentlyContinue | Out-Null
    } catch {
        $conflictThrown = $true
    }
    Assert-True -Condition $conflictThrown -Message 'Installer refuses an existing EditMode conflict'
    Assert-Equal -Expected 'preserve' -Actual ([System.IO.File]::ReadAllText((Join-Path $conflictPath 'marker.txt'), $script:Utf8NoBom)) -Message 'Installer preserves the conflicting path'

    foreach ($powerShellFile in Get-ChildItem -LiteralPath $script:SkillRoot -Filter '*.ps1' -File -Recurse) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($powerShellFile.FullName, [ref]$tokens, [ref]$parseErrors)
        Assert-Equal -Expected 0 -Actual $parseErrors.Count -Message "PowerShell parses: $($powerShellFile.FullName)"
    }

    $repositoryAfter = Get-TestTreeSnapshot -Root $script:RepositoryRoot
    Assert-Equal -Expected $repositoryBefore -Actual $repositoryAfter -Message 'EditMode tests leave repository and fixtures byte-for-byte unchanged'
    Write-Host "Unity EditMode Verification tests passed. Assertions: $script:Assertions"
} finally {
    if (Test-Path -LiteralPath $script:ScratchRoot -PathType Container) {
        Remove-Item -LiteralPath $script:ScratchRoot -Recurse -Force
    }
}
