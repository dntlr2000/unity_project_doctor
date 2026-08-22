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
    [ValidateRange(1, 86400)]
    [int]$TimeoutSeconds = 1800,

    [Parameter()]
    [switch]$Pretty
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:SchemaVersion = '1.0.0'
$script:VerifierVersion = '0.1.0'
$script:ExpectedUnityVersion = '6000.0.69f1'
$script:ExpectedBaselineSchemaVersion = '1.1.0'
$script:ExpectedBaselineVerifierVersion = '0.1.3'
$script:ExpectedDoctorSchemaVersion = '1.1.0'
$script:ExpectedDoctorScannerVersion = '0.2.1'
$script:SkillRoot = Split-Path -Parent $PSScriptRoot
$script:CodexSkillsRoot = Split-Path -Parent $script:SkillRoot
$script:RepositoryRoot = Split-Path -Parent (Split-Path -Parent $script:CodexSkillsRoot)
$script:BaselineScriptsRoot = Join-Path $script:CodexSkillsRoot 'unity-baseline-verification\scripts'
$script:BaselineEntrypoint = Join-Path $script:BaselineScriptsRoot 'invoke-unity-baseline-verification.ps1'
$script:ProcessLibraryPath = Join-Path $script:BaselineScriptsRoot 'lib\unity-process-job.ps1'
$script:OrchestrationLibraryPath = Join-Path $script:BaselineScriptsRoot 'lib\unity-baseline-orchestration.ps1'
$script:GitIntegrityLibraryPath = Join-Path $script:BaselineScriptsRoot 'lib\git-metadata-integrity.ps1'
$script:ValidatorLibraryPath = Join-Path $script:BaselineScriptsRoot 'lib\json-schema-validator.ps1'
$script:FingerprintLibraryPath = Join-Path $script:CodexSkillsRoot 'unity-project-doctor\scripts\lib\unity-project-fingerprint.ps1'
$script:CoreLibraryPath = Join-Path $PSScriptRoot 'lib\unity-editmode-verification-core.ps1'
$script:BaselineHandoffSchemaPath = Join-Path $script:RepositoryRoot 'schemas\unity-baseline-editmode-handoff-1.0.0.schema.json'
$script:DoctorSchemaPath = Join-Path $script:RepositoryRoot 'schemas\unity-project-audit-1.1.0.schema.json'
$script:ResultSchemaPath = Join-Path $script:RepositoryRoot 'schemas\unity-editmode-verification-result-1.0.0.schema.json'
$script:Warnings = New-Object System.Collections.ArrayList
$script:Failures = New-Object System.Collections.ArrayList
$script:Blockers = New-Object System.Collections.ArrayList
$script:Evidence = New-Object System.Collections.ArrayList
$script:EvidenceSequence = 0
$script:NormalizedProjectRoot = $null
$script:SessionRoot = $null
$script:OriginalFingerprintBefore = $null
$script:OriginalFingerprintAfter = $null
$script:GitSnapshotBefore = $null
$script:GitSnapshotAfter = $null
$script:BaselineObject = $null
$script:DoctorObject = $null
$script:NoConfirmedAssembly = $false

[Console]::OutputEncoding = $script:Utf8NoBom

foreach ($libraryPath in @(
    $script:ProcessLibraryPath,
    $script:OrchestrationLibraryPath,
    $script:GitIntegrityLibraryPath,
    $script:ValidatorLibraryPath,
    $script:FingerprintLibraryPath,
    $script:CoreLibraryPath
)) {
    if (-not (Test-Path -LiteralPath $libraryPath -PathType Leaf)) {
        throw "Required EditMode verification library was not found: $libraryPath"
    }
    . $libraryPath
}

# Creates the stable EditMode result shape before validation begins.
function New-UevResult {
    return [ordered]@{
        schemaVersion = $script:SchemaVersion
        verifierVersion = $script:VerifierVersion
        projectRoot = $null
        baseline = [ordered]@{
            rawResultPath = $null
            rawResultSha256 = $null
            stderrPath = $null
            schemaVersion = $null
            verifierVersion = $null
            finalStatus = $null
            accepted = $false
            validationErrors = @()
            diagnostics = $null
        }
        doctor = [ordered]@{
            sourcePath = $null
            sha256 = $null
            schemaVersion = $null
            scannerVersion = $null
            finalStatus = $null
            warningCount = 0
            warnings = @()
            confirmedTestAssemblies = @()
            candidateOnlyTestAssemblyCount = 0
            projectFingerprint = $null
            accepted = $false
            validationErrors = @()
        }
        unity = [ordered]@{
            executablePath = $null
            executableSha256 = $null
            fileVersion = $null
            productVersion = $null
            detectedExecutableVersion = $null
            signatureStatus = $null
            signerSubject = $null
            certificateThumbprint = $null
            publisherMatched = $false
            arguments = @()
            commandLineContainsOriginalProject = $null
            processStarted = $false
            timedOut = $false
            exitCode = $null
        }
        preflight = [ordered]@{
            artifactRootOutsideProject = $false
            trustedPathsWithoutReparse = $false
            baselineHandoffAccepted = $false
            doctorEvidenceAccepted = $false
            originalFingerprintMatched = $false
            isolatedFingerprintMatched = $false
            isolatedSourceProjectionMatched = $false
            selectedAssemblyBinariesPresent = $false
            unityTrustRevalidated = $false
            sourceEditorCheckCompleted = $false
            sourceEditorDetected = $null
            sourceEditorProcessIds = @()
        }
        processControl = [ordered]@{
            rootProcessId = $null
            jobObjectCreated = $false
            killOnJobCloseConfigured = $false
            processAssignedToJob = $false
            terminationRequested = $false
            terminationReason = $null
            terminationApiSucceeded = $null
            rootProcessExited = $false
            processTreeExitVerified = $false
            activeProcessCountAfterWait = $null
            treeExitWaitMilliseconds = 0
            controlError = $null
        }
        isolation = [ordered]@{
            baselineSessionRoot = $null
            projectCopyPath = $null
            baselineCopyFingerprint = $null
            currentCopyFingerprint = $null
            fingerprintBindingClassification = 'NOT_EVALUATED'
            fingerprintDelta = $null
            reusedBaselineCopy = $false
        }
        artifacts = [ordered]@{
            root = $null
            sessionRoot = $null
            baselineResultPath = $null
            baselineStderrPath = $null
            editorLogPath = $null
            upmLogPath = $null
            testResultsPath = $null
            standardOutputPath = $null
            standardErrorPath = $null
            resultPath = $null
            resultWritten = $false
        }
        testSelection = [ordered]@{
            source = 'DOCTOR_CONFIRMED_TEST_ASSEMBLIES'
            confirmedAssemblies = @()
            assemblyNames = @()
            assemblyNamesArgument = $null
            candidateOnlyExcludedCount = 0
            binaryPreflight = [ordered]@{
                completed = $false
                accepted = $false
                scriptAssembliesRoot = $null
                records = @()
                missingAssemblyNames = @()
            }
        }
        nunit = [ordered]@{
            exists = $false
            byteLength = $null
            sha256 = $null
            format = $null
            rootResult = $null
            total = 0
            executed = 0
            passed = 0
            failed = 0
            errors = 0
            skipped = 0
            inconclusive = 0
            assertions = 0
            durationSeconds = $null
            problemDetails = @()
            problemDetailsTruncated = $false
            classification = 'NOT_ANALYZED'
            error = $null
        }
        editorLog = [ordered]@{
            exists = $false
            byteLength = $null
            sha256 = $null
            detectedUnityVersion = $null
            versionMatched = $false
            batchModeObserved = $false
            isolatedProjectPathObserved = $false
            testRunnerObserved = $false
            compilerErrors = @()
            compilerErrorCount = 0
            compilerErrorsTruncated = $false
            failureMarkers = @()
            missingRequiredMarkers = @()
            classification = 'NOT_ANALYZED'
        }
        originalProjectIntegrity = [ordered]@{
            scope = 'BASELINE_COPY_SET'
            status = 'NOT_VERIFIED'
            beforeDirectoryCount = $null
            afterDirectoryCount = $null
            beforeFileCount = $null
            afterFileCount = $null
            beforeTreeSha256 = $null
            afterTreeSha256 = $null
            unchanged = $null
        }
        gitMetadataIntegrity = [ordered]@{
            scope = '.git'
            status = 'NOT_VERIFIED'
            presentBefore = $null
            presentAfter = $null
            beforeTreeSha256 = $null
            afterTreeSha256 = $null
            unchanged = $null
            ambientChangesAllowed = $false
            allowedAdditionPrefix = '.git/refs/codex/turn-diffs/checkpoints/'
            addedDirectories = @()
            removedDirectories = @()
            addedFiles = @()
            removedFiles = @()
            changedFiles = @()
        }
        verification = [ordered]@{
            scriptCompilation = [ordered]@{
                status = 'NOT_VERIFIED'
                reason = 'A Baseline result has not been accepted.'
            }
            editModeTests = [ordered]@{
                status = 'NOT_VERIFIED'
                reason = 'Unity EditMode tests have not produced complete evidence.'
            }
            playMode = [ordered]@{
                status = 'NOT_VERIFIED'
                reason = 'PlayMode was not entered and no PlayMode tests were run.'
            }
            playerBuild = [ordered]@{
                status = 'NOT_VERIFIED'
                reason = 'No Player Build was run.'
            }
            runtime = [ordered]@{
                status = 'NOT_VERIFIED'
                reason = 'No player, scene runtime, or gameplay behavior was verified.'
            }
        }
        warnings = @()
        failures = @()
        blockers = @()
        finalStatus = 'EDITMODE_BLOCKED'
        evidence = @()
    }
}

$script:Result = New-UevResult

# Adds one ordered evidence record to the public result.
function Add-UevEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Check,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter()][AllowNull()][string]$Source,
        [Parameter(Mandatory = $true)][string]$Detail
    )

    $script:EvidenceSequence++
    [void]$script:Evidence.Add([ordered]@{
        sequence = $script:EvidenceSequence
        check = $Check
        status = $Status
        source = $Source
        detail = $Detail
    })
}

# Adds one non-blocking warning without promoting verification status.
function Add-UevWarning {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Check,
        [Parameter()][AllowNull()][string]$Path,
        [Parameter(Mandatory = $true)][string]$Message
    )

    [void]$script:Warnings.Add([ordered]@{ code = $Code; check = $Check; path = $Path; message = $Message })
}

# Adds one concrete test or compilation failure.
function Add-UevFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Check,
        [Parameter()][AllowNull()][string]$Path,
        [Parameter(Mandatory = $true)][string]$Message
    )

    [void]$script:Failures.Add([ordered]@{ code = $Code; check = $Check; path = $Path; message = $Message })
}

# Adds one fail-closed prerequisite or evidence blocker.
function Add-UevBlocker {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Check,
        [Parameter()][AllowNull()][string]$Path,
        [Parameter(Mandatory = $true)][string]$Message
    )

    [void]$script:Blockers.Add([ordered]@{ code = $Code; check = $Check; path = $Path; message = $Message })
}

# Writes one external UTF-8 artifact without a byte-order mark.
function Write-UevText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $reparsePoint = Get-UevReparsePointOnPath -Path $Path
    if ($null -ne $reparsePoint) {
        throw "Refusing to write through reparse point $reparsePoint."
    }
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [void][System.IO.Directory]::CreateDirectory($parent)
    }
    [void][System.IO.File]::WriteAllText($Path, $Content, $script:Utf8NoBom)
}

# Creates a short external artifact session after checking its boundary.
function Initialize-UevArtifactSession {
    param(
        [Parameter(Mandatory = $true)][string]$RequestedRoot
    )

    $root = Get-UevNormalizedPath -Path $RequestedRoot
    if ($null -ne $script:NormalizedProjectRoot -and (Test-UevPathWithinRoot -Path $root -Root $script:NormalizedProjectRoot)) {
        throw 'ArtifactsRoot must be outside the original Unity project.'
    }
    $reparsePoint = Get-UevReparsePointOnPath -Path $root
    if ($null -ne $reparsePoint) {
        throw "ArtifactsRoot traverses reparse point $reparsePoint."
    }
    if (Test-Path -LiteralPath $root -PathType Leaf) {
        throw 'ArtifactsRoot is an existing file.'
    }
    [void][System.IO.Directory]::CreateDirectory($root)
    $session = Join-Path $root ('s-' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($session)
    if ($null -ne (Get-UevReparsePointOnPath -Path $session)) {
        throw 'Created EditMode artifact session traverses a reparse point.'
    }

    $script:SessionRoot = Get-UevNormalizedPath -Path $session
    $script:Result.preflight.artifactRootOutsideProject = $true
    $script:Result.preflight.trustedPathsWithoutReparse = $true
    $script:Result.artifacts.root = $root
    $script:Result.artifacts.sessionRoot = $script:SessionRoot
    $script:Result.artifacts.baselineResultPath = Join-Path $script:SessionRoot 'baseline-result.json'
    $script:Result.artifacts.baselineStderrPath = Join-Path $script:SessionRoot 'baseline-stderr.log'
    $script:Result.artifacts.editorLogPath = Join-Path $script:SessionRoot 'EditMode-Editor.log'
    $script:Result.artifacts.upmLogPath = Join-Path $script:SessionRoot 'EditMode-upm.log'
    $script:Result.artifacts.testResultsPath = Join-Path $script:SessionRoot 'editmode-results.xml'
    $script:Result.artifacts.standardOutputPath = Join-Path $script:SessionRoot 'unity-stdout.log'
    $script:Result.artifacts.standardErrorPath = Join-Path $script:SessionRoot 'unity-stderr.log'
    $script:Result.artifacts.resultPath = Join-Path $script:SessionRoot 'unity-editmode-verification.json'
    $script:Result.baseline.rawResultPath = $script:Result.artifacts.baselineResultPath
    $script:Result.baseline.stderrPath = $script:Result.artifacts.baselineStderrPath
    Add-UevEvidence -Check 'artifactBoundary' -Status 'PASSED' -Source $script:SessionRoot -Detail 'Every EditMode artifact path is external to the source project and traverses no reparse point.'
}

# Captures source-content and Git metadata state before Baseline orchestration starts.
function Initialize-UevOriginalIntegrity {
    try {
        $script:OriginalFingerprintBefore = Get-StableUnityCopySetFingerprint -ProjectRoot $script:NormalizedProjectRoot
        $script:Result.originalProjectIntegrity.beforeDirectoryCount = $script:OriginalFingerprintBefore.directoryCount
        $script:Result.originalProjectIntegrity.beforeFileCount = $script:OriginalFingerprintBefore.fileCount
        $script:Result.originalProjectIntegrity.beforeTreeSha256 = $script:OriginalFingerprintBefore.treeSha256
        Add-UevEvidence -Check 'originalFingerprintBefore' -Status 'OBSERVED' -Source $script:NormalizedProjectRoot -Detail "Captured stable source fingerprint $($script:OriginalFingerprintBefore.treeSha256) before Baseline."
    } catch {
        Add-UevBlocker -Code 'ORIGINAL_FINGERPRINT_PRECHECK_FAILED' -Check 'originalProjectIntegrity' -Path $script:NormalizedProjectRoot -Message $_.Exception.Message
    }
    try {
        $script:GitSnapshotBefore = Get-BaselineGitMetadataSnapshot -ProjectRoot $script:NormalizedProjectRoot
        $script:Result.gitMetadataIntegrity.presentBefore = [bool]$script:GitSnapshotBefore.present
        $script:Result.gitMetadataIntegrity.beforeTreeSha256 = [string]$script:GitSnapshotBefore.treeSha256
    } catch {
        Add-UevBlocker -Code 'GIT_METADATA_PRECHECK_FAILED' -Check 'gitMetadataIntegrity' -Path (Join-Path $script:NormalizedProjectRoot '.git') -Message $_.Exception.Message
    }
}

# Runs the trusted sibling Baseline one-command entrypoint and preserves raw output.
function Invoke-UevBaseline {
    $arguments = New-Object 'System.Collections.Generic.List[string]'
    $arguments.Add('-ProjectRoot')
    $arguments.Add($script:NormalizedProjectRoot)
    $arguments.Add('-TimeoutSeconds')
    $arguments.Add($TimeoutSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture))
    if (-not [string]::IsNullOrWhiteSpace($UnityExecutable)) {
        $arguments.Add('-UnityExecutable')
        $arguments.Add($UnityExecutable)
    }

    try {
        $process = Invoke-OrchestrationPowerShellScript `
            -ScriptPath $script:BaselineEntrypoint `
            -Arguments $arguments.ToArray() `
            -WorkingDirectory $script:RepositoryRoot
        Write-UevText -Path $script:Result.artifacts.baselineStderrPath -Content ([string]$process.stderr)
        Write-UevText -Path $script:Result.artifacts.baselineResultPath -Content ([string]$process.stdout)
        if ($process.exitCode -ne 0) {
            throw "Baseline orchestration exited with code $($process.exitCode)."
        }
        if ([string]::IsNullOrWhiteSpace([string]$process.stdout)) {
            throw 'Baseline orchestration produced empty stdout.'
        }
        $script:BaselineObject = ConvertFrom-Json -InputObject ([string]$process.stdout) -ErrorAction Stop
        $script:Result.baseline.rawResultSha256 = Get-UevFileSha256 -Path $script:Result.artifacts.baselineResultPath
        Add-UevEvidence -Check 'baselineInvocation' -Status 'OBSERVED' -Source $script:Result.artifacts.baselineResultPath -Detail 'Bundled Baseline orchestration returned one JSON document whose original bytes were preserved externally.'
    } catch {
        Add-UevBlocker -Code 'BASELINE_INVOCATION_FAILED' -Check 'baseline' -Path $script:BaselineEntrypoint -Message $_.Exception.Message
    }
}

# Validates the narrow Baseline handoff schema and semantic project binding.
function Test-UevBaselineHandoff {
    if ($null -eq $script:BaselineObject) {
        return
    }
    $baseline = $script:BaselineObject
    $script:Result.baseline.schemaVersion = [string](Get-UevJsonProperty $baseline 'schemaVersion')
    $script:Result.baseline.verifierVersion = [string](Get-UevJsonProperty $baseline 'verifierVersion')
    $script:Result.baseline.finalStatus = [string](Get-UevJsonProperty $baseline 'finalStatus')
    $script:Result.baseline.diagnostics = Get-UevBaselineDiagnosticSummary -Baseline $baseline
    try {
        $schemaErrors = @(Invoke-JsonSchemaValidation -Instance $baseline -SchemaPath $script:BaselineHandoffSchemaPath)
        $semanticErrors = New-Object System.Collections.ArrayList
        $baselineRoot = [string](Get-UevJsonProperty $baseline 'projectRoot')
        if ([string]::IsNullOrWhiteSpace($baselineRoot) -or -not (Get-UevNormalizedPath $baselineRoot).Equals($script:NormalizedProjectRoot, $script:UevPathComparison)) {
            [void]$semanticErrors.Add('Baseline projectRoot does not exactly match the requested source root.')
        }
        if (@((Get-UevJsonProperty $baseline 'blockers')).Count -ne 0) {
            [void]$semanticErrors.Add('Baseline contains one or more blockers.')
        }
        foreach ($errorRecord in @($schemaErrors)) {
            [void]$semanticErrors.Add("$($errorRecord.path): $($errorRecord.message)")
        }
        $script:Result.baseline.validationErrors = @($semanticErrors)
        if ($semanticErrors.Count -gt 0) {
            $message = [string]::Join(' ', [string[]]@($semanticErrors))
            $primaryCause = Get-UevJsonProperty -InputObject $script:Result.baseline.diagnostics -Name 'primaryCause'
            if ($null -ne $primaryCause) {
                $message += " Primary cause: $([string](Get-UevJsonProperty $primaryCause 'code')) - $([string](Get-UevJsonProperty $primaryCause 'message'))"
            }
            Add-UevBlocker -Code 'BASELINE_HANDOFF_REJECTED' -Check 'baseline' -Path $script:Result.artifacts.baselineResultPath -Message $message
            return
        }
        $script:Result.baseline.accepted = $true
        $script:Result.preflight.baselineHandoffAccepted = $true
        $script:Result.verification.scriptCompilation.status = 'VERIFIED_SUCCESS'
        $script:Result.verification.scriptCompilation.reason = 'The bundled Baseline verifier supplied accepted Script Compilation evidence.'
        Add-UevEvidence -Check 'baselineHandoff' -Status 'PASSED' -Source $script:Result.artifacts.baselineResultPath -Detail 'Baseline schema 1.1.0/verifier 0.1.3 is BASELINE_VERIFIED and preserves every required safety invariant.'
    } catch {
        Add-UevBlocker -Code 'BASELINE_HANDOFF_VALIDATION_FAILED' -Check 'baseline' -Path $script:Result.artifacts.baselineResultPath -Message $_.Exception.Message
    }
}

# Loads and validates the exact Doctor artifact referenced and hashed by Baseline.
function Test-UevDoctorEvidence {
    if (-not $script:Result.baseline.accepted) {
        return
    }
    try {
        $baselineDoctor = Get-UevJsonProperty $script:BaselineObject 'doctor'
        $doctorPath = Get-UevNormalizedPath -Path ([string](Get-UevJsonProperty $baselineDoctor 'sourcePath'))
        $script:Result.doctor.sourcePath = $doctorPath
        if (Test-UevPathWithinRoot -Path $doctorPath -Root $script:NormalizedProjectRoot) {
            throw 'Doctor artifact is inside the original project.'
        }
        $reparsePoint = Get-UevReparsePointOnPath -Path $doctorPath
        if ($null -ne $reparsePoint) {
            throw "Doctor artifact traverses reparse point $reparsePoint."
        }
        if (-not (Test-Path -LiteralPath $doctorPath -PathType Leaf)) {
            throw 'Doctor artifact does not exist.'
        }
        $doctorHash = Get-UevFileSha256 -Path $doctorPath
        $script:Result.doctor.sha256 = $doctorHash
        if ($doctorHash -ne [string](Get-UevJsonProperty $baselineDoctor 'sha256')) {
            throw 'Doctor artifact SHA-256 does not match the Baseline receipt.'
        }
        $script:DoctorObject = [System.IO.File]::ReadAllText($doctorPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        $schemaErrors = @(Invoke-JsonSchemaValidation -Instance $script:DoctorObject -SchemaPath $script:DoctorSchemaPath)
        $semanticErrors = New-Object System.Collections.ArrayList
        foreach ($errorRecord in $schemaErrors) {
            [void]$semanticErrors.Add("$($errorRecord.path): $($errorRecord.message)")
        }
        $script:Result.doctor.schemaVersion = [string](Get-UevJsonProperty $script:DoctorObject 'schemaVersion')
        $script:Result.doctor.scannerVersion = [string](Get-UevJsonProperty $script:DoctorObject 'scannerVersion')
        $script:Result.doctor.finalStatus = [string](Get-UevJsonProperty $script:DoctorObject 'finalStatus')
        if ($script:Result.doctor.schemaVersion -ne $script:ExpectedDoctorSchemaVersion) { [void]$semanticErrors.Add('Doctor schemaVersion is not 1.1.0.') }
        if ($script:Result.doctor.scannerVersion -ne $script:ExpectedDoctorScannerVersion) { [void]$semanticErrors.Add('Doctor scannerVersion is not 0.2.1.') }
        if (@((Get-UevJsonProperty $script:DoctorObject 'blockedChecks')).Count -ne 0) { [void]$semanticErrors.Add('Doctor contains blocked checks.') }
        $doctorRoot = Get-UevNormalizedPath -Path ([string](Get-UevJsonProperty $script:DoctorObject 'projectRoot'))
        if (-not $doctorRoot.Equals($script:NormalizedProjectRoot, $script:UevPathComparison)) { [void]$semanticErrors.Add('Doctor projectRoot does not match the source root.') }
        $script:Result.doctor.validationErrors = @($semanticErrors)
        if ($semanticErrors.Count -gt 0) {
            throw [string]::Join(' ', [string[]]@($semanticErrors))
        }

        $assemblies = Get-UevJsonProperty $script:DoctorObject 'assemblies'
        $confirmed = @((Get-UevJsonProperty $assemblies 'confirmedTestAssemblies'))
        $candidates = @((Get-UevJsonProperty $assemblies 'candidateOnlyTestAssemblies'))
        $selection = Get-UevAssemblySelection -ConfirmedAssemblies $confirmed
        if (-not $selection.accepted) {
            throw [string]::Join(' ', [string[]]$selection.errors)
        }
        $script:Result.doctor.confirmedTestAssemblies = @($selection.records)
        $script:Result.doctor.candidateOnlyTestAssemblyCount = $candidates.Count
        $script:Result.doctor.projectFingerprint = Get-UevJsonProperty $script:DoctorObject 'projectFingerprint'
        $script:Result.testSelection.confirmedAssemblies = @($selection.records)
        $script:Result.testSelection.assemblyNames = @($selection.names)
        $script:Result.testSelection.assemblyNamesArgument = $selection.argument
        $script:Result.testSelection.candidateOnlyExcludedCount = $candidates.Count
        $doctorWarnings = @((Get-UevJsonProperty $script:DoctorObject 'warnings'))
        $script:Result.doctor.warnings = @($doctorWarnings)
        $script:Result.doctor.warningCount = $doctorWarnings.Count
        foreach ($warning in $doctorWarnings) {
            Add-UevWarning `
                -Code ([string](Get-UevJsonProperty $warning 'code')) `
                -Check 'doctor' `
                -Path ([string](Get-UevJsonProperty $warning 'path')) `
                -Message ([string](Get-UevJsonProperty $warning 'message'))
        }
        $script:Result.doctor.accepted = $true
        $script:Result.preflight.doctorEvidenceAccepted = $true
        if ($selection.names.Count -eq 0) {
            $script:NoConfirmedAssembly = $true
            $script:Result.verification.editModeTests.reason = 'Doctor found no asmdef with direct Unity test assembly evidence; no EditMode test process was started.'
            Add-UevEvidence -Check 'testSelection' -Status 'NOT_AVAILABLE' -Source $doctorPath -Detail 'No confirmed test assembly exists; candidate-only assemblies were not executed.'
        } else {
            Add-UevEvidence -Check 'testSelection' -Status 'PASSED' -Source $doctorPath -Detail "Selected only $($selection.names.Count) Doctor-confirmed test assembly name(s); $($candidates.Count) candidate-only record(s) were excluded."
        }
    } catch {
        Add-UevBlocker -Code 'DOCTOR_EVIDENCE_REJECTED' -Check 'doctor' -Path $script:Result.doctor.sourcePath -Message $_.Exception.Message
    }
}

# Recomputes exact source evidence and the narrow reusable-isolation source projection before EditMode starts.
function Test-UevFingerprintBindings {
    if (-not $script:Result.doctor.accepted) {
        return
    }
    try {
        $doctorFingerprint = Get-UevJsonProperty $script:DoctorObject 'projectFingerprint'
        $doctorTree = [string](Get-UevJsonProperty $doctorFingerprint 'treeSha256')
        $currentSource = Get-StableUnityCopySetFingerprint -ProjectRoot $script:NormalizedProjectRoot
        if ($currentSource.treeSha256 -ne $doctorTree) {
            throw 'Current source fingerprint no longer matches Doctor/Baseline evidence.'
        }
        if ($null -ne $script:OriginalFingerprintBefore -and $currentSource.treeSha256 -ne $script:OriginalFingerprintBefore.treeSha256) {
            throw 'Source fingerprint changed after the initial EditMode preflight snapshot.'
        }
        $script:Result.preflight.originalFingerprintMatched = $true

        $baselineIsolation = Get-UevJsonProperty $script:BaselineObject 'isolation'
        $sessionRoot = Get-UevNormalizedPath -Path ([string](Get-UevJsonProperty $baselineIsolation 'sessionRoot'))
        $copyPath = Get-UevNormalizedPath -Path ([string](Get-UevJsonProperty $baselineIsolation 'projectCopyPath'))
        $script:Result.isolation.baselineSessionRoot = $sessionRoot
        $script:Result.isolation.projectCopyPath = $copyPath
        if ((Test-UevPathWithinRoot -Path $sessionRoot -Root $script:NormalizedProjectRoot) -or -not (Test-UevPathWithinRoot -Path $copyPath -Root $sessionRoot)) {
            throw 'Baseline isolation paths do not preserve the external session boundary.'
        }
        foreach ($trustedPath in @($sessionRoot, $copyPath)) {
            if (-not (Test-Path -LiteralPath $trustedPath -PathType Container)) {
                throw "Baseline isolation directory is missing: $trustedPath"
            }
            $reparsePoint = Get-UevReparsePointOnPath -Path $trustedPath
            if ($null -ne $reparsePoint) {
                throw "Baseline isolation path traverses reparse point $reparsePoint."
            }
        }
        $baselineCopy = Get-UevJsonProperty $baselineIsolation 'copyFingerprint'
        $baselineCopyTree = [string](Get-UevJsonProperty $baselineCopy 'treeSha256')
        if ($baselineCopyTree -ne $doctorTree) {
            throw 'Doctor and Baseline receipts disagree about the accepted pre-Unity isolation fingerprint.'
        }
        $currentCopy = Get-StableUnityCopySetFingerprint -ProjectRoot $copyPath
        $script:Result.isolation.baselineCopyFingerprint = $baselineCopyTree
        $script:Result.isolation.currentCopyFingerprint = $currentCopy.treeSha256
        $assessment = Get-UevIsolationFingerprintAssessment `
            -SourceSnapshot $currentSource.snapshot `
            -IsolationSnapshot $currentCopy.snapshot
        $script:Result.isolation.fingerprintBindingClassification = $assessment.classification
        $script:Result.isolation.fingerprintDelta = $assessment
        $script:Result.preflight.isolatedFingerprintMatched = [bool]$assessment.exactMatch
        $script:Result.preflight.isolatedSourceProjectionMatched = [bool]$assessment.accepted
        if (-not $assessment.accepted) {
            throw "The reusable Baseline isolation copy contains a disallowed post-Unity delta: $($assessment.disallowedDeltaCount) file or directory change(s)."
        }
        $script:Result.isolation.reusedBaselineCopy = $true
        if ($assessment.exactMatch) {
            Add-UevEvidence -Check 'fingerprintBinding' -Status 'PASSED' -Source $copyPath -Detail 'Current source, Doctor receipt, Baseline receipt, and reusable isolated copy have the same copy-set SHA-256.'
        } else {
            $allowedPaths = @(
                @($assessment.allowedAddedFiles) +
                @($assessment.allowedRemovedFiles) +
                @($assessment.allowedChangedFiles) |
                    ForEach-Object { [string]$_.path } |
                    Sort-Object -Unique
            )
            Add-UevEvidence `
                -Check 'fingerprintBinding' `
                -Status 'PASSED' `
                -Source $copyPath `
                -Detail "Current source still matches Doctor and Baseline receipts; only project-root IDE files regenerated by Baseline Unity differ in the reusable isolation: $([string]::Join(', ', [string[]]$allowedPaths))."
        }
    } catch {
        Add-UevBlocker -Code 'FINGERPRINT_BINDING_FAILED' -Check 'preflight' -Path $script:Result.isolation.projectCopyPath -Message $_.Exception.Message
    }
}

# Requires every Doctor-selected test assembly DLL to exist in the accepted Baseline isolation.
function Test-UevSelectedAssemblyBinaries {
    if (-not $script:Result.isolation.reusedBaselineCopy) {
        return
    }
    try {
        $assessment = Get-UevSelectedAssemblyBinaryAssessment `
            -ProjectCopyPath $script:Result.isolation.projectCopyPath `
            -AssemblyNames ([string[]]@($script:Result.testSelection.assemblyNames))
        foreach ($propertyName in @('completed', 'accepted', 'scriptAssembliesRoot', 'records', 'missingAssemblyNames')) {
            $script:Result.testSelection.binaryPreflight[$propertyName] = Get-UevJsonProperty -InputObject $assessment -Name $propertyName
        }
        if (-not $assessment.accepted) {
            $missing = [string]::Join(', ', [string[]]@($assessment.missingAssemblyNames))
            Add-UevBlocker `
                -Code 'TEST_ASSEMBLY_NOT_BUILT' `
                -Check 'testAssemblyBinary' `
                -Path $assessment.scriptAssembliesRoot `
                -Message "Baseline completed, but selected test assembly DLL(s) were not built: $missing. Likely causes include asmdef/.meta import failure, platform or define constraints, or an assembly compilation failure."
            return
        }
        $script:Result.preflight.selectedAssemblyBinariesPresent = $true
        Add-UevEvidence `
            -Check 'testAssemblyBinary' `
            -Status 'PASSED' `
            -Source $assessment.scriptAssembliesRoot `
            -Detail "Every selected test assembly produced a non-empty DLL in the accepted Baseline isolation: $([string]::Join(', ', [string[]]@($script:Result.testSelection.assemblyNames)))."
    } catch {
        Add-UevBlocker `
            -Code 'TEST_ASSEMBLY_BINARY_PREFLIGHT_UNAVAILABLE' `
            -Check 'testAssemblyBinary' `
            -Path $script:Result.isolation.projectCopyPath `
            -Message $_.Exception.Message
    }
}

# Observes the current Unity executable trust state without starting it.
function Get-UevCurrentUnityObservation {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $normalizedPath = Get-UevNormalizedPath -Path $Path
    if (Test-UevPathWithinRoot -Path $normalizedPath -Root $script:NormalizedProjectRoot) {
        throw 'Unity executable is inside the original project.'
    }
    if (-not (Test-Path -LiteralPath $normalizedPath -PathType Leaf)) {
        throw 'Unity executable no longer exists.'
    }
    if ([System.IO.Path]::GetFileName($normalizedPath) -ine 'Unity.exe') {
        throw 'Trusted executable filename is not Unity.exe.'
    }
    $reparsePoint = Get-UevReparsePointOnPath -Path $normalizedPath
    if ($null -ne $reparsePoint) {
        throw "Unity executable traverses reparse point $reparsePoint."
    }
    $item = Get-Item -LiteralPath $normalizedPath -Force -ErrorAction Stop
    $signature = Get-AuthenticodeSignature -LiteralPath $normalizedPath -ErrorAction Stop
    $detectedVersion = $null
    $versionMatch = [regex]::Match([string]$item.VersionInfo.ProductVersion, '^(?<version>\d+\.\d+\.\d+[abfp]\d+)(?:_|$|\s)')
    if ($versionMatch.Success) {
        $detectedVersion = $versionMatch.Groups['version'].Value
    }
    $signerSubject = if ($null -ne $signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { $null }
    return [pscustomobject][ordered]@{
        executablePath = $normalizedPath
        executableSha256 = Get-UevFileSha256 -Path $normalizedPath
        fileVersion = [string]$item.VersionInfo.FileVersion
        productVersion = [string]$item.VersionInfo.ProductVersion
        detectedExecutableVersion = $detectedVersion
        signatureStatus = [string]$signature.Status
        signerSubject = $signerSubject
        certificateThumbprint = if ($null -ne $signature.SignerCertificate) { [string]$signature.SignerCertificate.Thumbprint } else { $null }
        publisherMatched = (
            [string]$signature.Status -eq 'Valid' -and
            -not [string]::IsNullOrWhiteSpace($signerSubject) -and
            [regex]::IsMatch($signerSubject, '(?i)\bUnity Technologies\b')
        )
    }
}

# Revalidates the exact signed Unity bytes accepted by Baseline.
function Test-UevUnityTrust {
    if (-not $script:Result.preflight.baselineHandoffAccepted) {
        return
    }
    try {
        $baselineUnity = Get-UevJsonProperty $script:BaselineObject 'unity'
        $observation = Get-UevCurrentUnityObservation -Path ([string](Get-UevJsonProperty $baselineUnity 'executablePath'))
        foreach ($propertyName in @(
            'executablePath', 'executableSha256', 'fileVersion', 'productVersion', 'detectedExecutableVersion',
            'signatureStatus', 'signerSubject', 'certificateThumbprint', 'publisherMatched'
        )) {
            $script:Result.unity[$propertyName] = Get-UevJsonProperty $observation $propertyName
        }
        $assessment = Get-UevUnityTrustAssessment -BaselineUnity $baselineUnity -CurrentUnity $observation -ExpectedUnityVersion $script:ExpectedUnityVersion
        if (-not $assessment.accepted) {
            throw [string]::Join(' ', [string[]]$assessment.errors)
        }
        $script:Result.preflight.unityTrustRevalidated = $true
        Add-UevEvidence -Check 'unityTrust' -Status 'PASSED' -Source $observation.executablePath -Detail 'Unity version, executable SHA-256, Authenticode status, signer, and certificate thumbprint still match the accepted Baseline evidence.'
    } catch {
        Add-UevBlocker -Code 'UNITY_TRUST_REVALIDATION_FAILED' -Check 'unityExecutable' -Path $script:Result.unity.executablePath -Message $_.Exception.Message
    }
}

# Observes running Unity processes and performs fail-closed source-project association.
function Test-UevSourceEditorPreflight {
    try {
        $running = @(
            Get-Process -ErrorAction Stop |
                Where-Object { $_.ProcessName -ieq 'Unity' } |
                ForEach-Object { [pscustomobject]@{ processId = [int]$_.Id } }
        )
        if ($running.Count -eq 0) {
            $assessment = Get-UevSourceEditorAssessment -ProjectRoot $script:NormalizedProjectRoot -RunningProcesses @()
        } else {
            try {
                $cimRows = @(
                    Get-CimInstance -ClassName Win32_Process -Filter "Name = 'Unity.exe'" -ErrorAction Stop |
                        ForEach-Object { [pscustomobject]@{ processId = [int]$_.ProcessId; commandLine = [string]$_.CommandLine } }
                )
            } catch {
                throw "CIM command-line inspection failed while Unity processes exist: $($_.Exception.Message)"
            }
            $candidateIds = New-Object 'System.Collections.Generic.HashSet[int]'
            foreach ($process in $running) { [void]$candidateIds.Add([int]$process.processId) }
            foreach ($process in $cimRows) { [void]$candidateIds.Add([int]$process.processId) }
            $stillRunning = New-Object System.Collections.ArrayList
            foreach ($processId in @($candidateIds | Sort-Object)) {
                try {
                    $process = Get-Process -Id $processId -ErrorAction Stop
                    if ($process.ProcessName -ieq 'Unity') {
                        [void]$stillRunning.Add([int]$processId)
                    }
                } catch {
                    if ($_.CategoryInfo.Category -ne [System.Management.Automation.ErrorCategory]::ObjectNotFound) {
                        throw
                    }
                }
            }
            $assessment = Get-UevSourceEditorAssessment `
                -ProjectRoot $script:NormalizedProjectRoot `
                -RunningProcesses $running `
                -CimProcesses $cimRows `
                -StillRunningProcessIds ([int[]]$stillRunning.ToArray([int]))
        }
        $script:Result.preflight.sourceEditorCheckCompleted = [bool]$assessment.completed
        $script:Result.preflight.sourceEditorDetected = $assessment.detected
        $script:Result.preflight.sourceEditorProcessIds = @($assessment.processIds)
        if ($null -ne $assessment.blockerCode) {
            Add-UevBlocker -Code $assessment.blockerCode -Check 'sourceEditorPreflight' -Path $script:NormalizedProjectRoot -Message $assessment.detail
            return
        }
        Add-UevEvidence -Check 'sourceEditorPreflight' -Status 'PASSED' -Source $script:NormalizedProjectRoot -Detail $assessment.detail
    } catch {
        $script:Result.preflight.sourceEditorCheckCompleted = $false
        $script:Result.preflight.sourceEditorDetected = $null
        $script:Result.preflight.sourceEditorProcessIds = @()
        Add-UevBlocker -Code 'SOURCE_EDITOR_PREFLIGHT_UNAVAILABLE' -Check 'sourceEditorPreflight' -Path $script:NormalizedProjectRoot -Message $_.Exception.Message
    }
}

# Starts Unity only with the closed EditMode argument set and shared Job Object control.
function Invoke-UevEditModeTests {
    $arguments = New-UevUnityArguments `
        -ProjectPath $script:Result.isolation.projectCopyPath `
        -AssemblyNames $script:Result.testSelection.assemblyNamesArgument `
        -TestResultsPath $script:Result.artifacts.testResultsPath `
        -EditorLogPath $script:Result.artifacts.editorLogPath `
        -UpmLogPath $script:Result.artifacts.upmLogPath
    $script:Result.unity.arguments = @($arguments)
    $containsOriginal = @($arguments | Where-Object {
        try { (Get-UevNormalizedPath -Path ([string]$_)).Equals($script:NormalizedProjectRoot, $script:UevPathComparison) } catch { $false }
    }).Count -gt 0
    $script:Result.unity.commandLineContainsOriginalProject = $containsOriginal
    if ($containsOriginal) {
        throw 'Closed Unity argument set contains the original project root.'
    }
    foreach ($forbidden in @('-quit', '-runSynchronously', '-executeMethod', '-accept-apiupdate', '-ignorecompilererrors')) {
        if (@($arguments) -contains $forbidden) {
            throw "Closed Unity argument set contains forbidden option $forbidden."
        }
    }

    $process = Invoke-UnityProcessInJob `
        -ExecutablePath $script:Result.unity.executablePath `
        -Arguments $arguments `
        -WorkingDirectory $script:SessionRoot `
        -StandardOutputPath $script:Result.artifacts.standardOutputPath `
        -StandardErrorPath $script:Result.artifacts.standardErrorPath `
        -TimeoutSeconds $TimeoutSeconds
    $script:Result.unity.processStarted = [bool]$process.processStarted
    $script:Result.unity.timedOut = [bool]$process.timedOut
    $script:Result.unity.exitCode = $process.exitCode
    foreach ($propertyName in @(
        'rootProcessId', 'jobObjectCreated', 'killOnJobCloseConfigured', 'processAssignedToJob',
        'terminationRequested', 'terminationReason', 'terminationApiSucceeded', 'rootProcessExited',
        'processTreeExitVerified', 'activeProcessCountAfterWait', 'treeExitWaitMilliseconds', 'controlError'
    )) {
        $script:Result.processControl[$propertyName] = Get-UevJsonProperty $process $propertyName
    }
}

# Classifies NUnit XML, Editor.log, process exit, timeout, and tree-exit evidence together.
function Set-UevDynamicVerification {
    $nunit = Get-UevNUnitAnalysis -Path $script:Result.artifacts.testResultsPath
    $editorLog = Get-UevEditorLogAnalysis `
        -Path $script:Result.artifacts.editorLogPath `
        -ExpectedUnityVersion $script:ExpectedUnityVersion `
        -ExpectedProjectPath $script:Result.isolation.projectCopyPath
    foreach ($property in $nunit.PSObject.Properties) { $script:Result.nunit[$property.Name] = $property.Value }
    foreach ($property in $editorLog.PSObject.Properties) { $script:Result.editorLog[$property.Name] = $property.Value }

    if (-not $script:Result.unity.processStarted) {
        Add-UevBlocker -Code 'UNITY_PROCESS_NOT_STARTED' -Check 'editModeTests' -Path $script:Result.unity.executablePath -Message 'Unity did not start.'
        return
    }
    if ($script:Result.unity.timedOut) {
        Add-UevBlocker -Code 'UNITY_PROCESS_TIMEOUT' -Check 'editModeTests' -Path $script:Result.unity.executablePath -Message "Unity exceeded the $TimeoutSeconds second timeout."
        return
    }
    if (-not $script:Result.processControl.processTreeExitVerified -or $script:Result.processControl.activeProcessCountAfterWait -ne 0) {
        Add-UevBlocker -Code 'UNITY_PROCESS_TREE_EXIT_UNPROVEN' -Check 'processControl' -Path $script:Result.unity.executablePath -Message 'Job Object accounting did not prove zero active Unity processes.'
        return
    }
    if ($editorLog.classification -eq 'FAILURE') {
        $script:Result.verification.editModeTests.status = 'VERIFIED_FAILURE'
        $script:Result.verification.editModeTests.reason = 'Editor.log contains concrete compiler, package, fatal, crash, or nonzero-return evidence.'
        Add-UevFailure -Code 'EDITMODE_LOG_FAILURE' -Check 'editModeTests' -Path $script:Result.artifacts.editorLogPath -Message $script:Result.verification.editModeTests.reason
        return
    }
    if ($nunit.classification -eq 'FAILED') {
        $script:Result.verification.editModeTests.status = 'VERIFIED_FAILURE'
        $script:Result.verification.editModeTests.reason = 'NUnit XML contains one or more failed or error tests.'
        Add-UevFailure -Code 'EDITMODE_TEST_FAILURE' -Check 'editModeTests' -Path $script:Result.artifacts.testResultsPath -Message $script:Result.verification.editModeTests.reason
        return
    }
    if ($null -eq $script:Result.unity.exitCode -or [int]$script:Result.unity.exitCode -ne 0) {
        Add-UevBlocker -Code 'UNITY_EXIT_EVIDENCE_INCOMPLETE' -Check 'editModeTests' -Path $script:Result.unity.executablePath -Message "Unity exit code must be exactly 0; observed $($script:Result.unity.exitCode)."
        return
    }
    if ($editorLog.classification -ne 'SAFE') {
        Add-UevBlocker -Code 'EDITOR_LOG_INCONCLUSIVE' -Check 'editModeTests' -Path $script:Result.artifacts.editorLogPath -Message "Editor.log classification is $($editorLog.classification)."
        return
    }
    $nunitDecision = Get-UevNUnitEvidenceDecision -NUnitAnalysis $nunit
    if (-not $nunitDecision.accepted) {
        Add-UevBlocker -Code $nunitDecision.blockerCode -Check 'editModeTests' -Path $script:Result.artifacts.testResultsPath -Message $nunitDecision.message
        return
    }
    if ($nunit.passed -le 0 -or $nunit.failed -ne 0 -or $nunit.errors -ne 0 -or $nunit.inconclusive -ne 0) {
        Add-UevBlocker -Code 'NUNIT_SUCCESS_INVARIANT_FAILED' -Check 'editModeTests' -Path $script:Result.artifacts.testResultsPath -Message 'Success requires at least one passed test and zero failed, error, or inconclusive tests.'
        return
    }
    if ($nunit.skipped -gt 0) {
        Add-UevWarning -Code 'EDITMODE_TESTS_SKIPPED' -Check 'editModeTests' -Path $script:Result.artifacts.testResultsPath -Message "$($nunit.skipped) selected EditMode test(s) were skipped; the count is preserved without being promoted to failure."
    }
    $script:Result.verification.editModeTests.status = 'VERIFIED_SUCCESS'
    $script:Result.verification.editModeTests.reason = "NUnit XML records $($nunit.passed) passed, $($nunit.skipped) skipped, and zero failed/error/inconclusive tests; Unity exited 0 with safe log and process-tree evidence."
    Add-UevEvidence -Check 'editModeTests' -Status 'PASSED' -Source $script:Result.artifacts.testResultsPath -Detail $script:Result.verification.editModeTests.reason
}

# Captures final source and Git state and classifies permitted ambient metadata.
function Complete-UevOriginalIntegrity {
    try {
        $script:OriginalFingerprintAfter = Get-StableUnityCopySetFingerprint -ProjectRoot $script:NormalizedProjectRoot
        $script:Result.originalProjectIntegrity.afterDirectoryCount = $script:OriginalFingerprintAfter.directoryCount
        $script:Result.originalProjectIntegrity.afterFileCount = $script:OriginalFingerprintAfter.fileCount
        $script:Result.originalProjectIntegrity.afterTreeSha256 = $script:OriginalFingerprintAfter.treeSha256
        if ($null -eq $script:OriginalFingerprintBefore) {
            $script:Result.originalProjectIntegrity.status = 'BLOCKED'
            Add-UevBlocker -Code 'ORIGINAL_INTEGRITY_BASELINE_MISSING' -Check 'originalProjectIntegrity' -Path $script:NormalizedProjectRoot -Message 'The before snapshot was unavailable.'
        } else {
            $unchanged = $script:OriginalFingerprintBefore.treeSha256 -eq $script:OriginalFingerprintAfter.treeSha256
            $script:Result.originalProjectIntegrity.unchanged = $unchanged
            $script:Result.originalProjectIntegrity.status = if ($unchanged) { 'UNCHANGED' } else { 'CHANGED' }
        }
    } catch {
        $script:Result.originalProjectIntegrity.status = 'BLOCKED'
        Add-UevBlocker -Code 'ORIGINAL_INTEGRITY_POSTCHECK_FAILED' -Check 'originalProjectIntegrity' -Path $script:NormalizedProjectRoot -Message $_.Exception.Message
    }

    try {
        $script:GitSnapshotAfter = Get-BaselineGitMetadataSnapshot -ProjectRoot $script:NormalizedProjectRoot
        $script:Result.gitMetadataIntegrity.presentAfter = [bool]$script:GitSnapshotAfter.present
        $script:Result.gitMetadataIntegrity.afterTreeSha256 = [string]$script:GitSnapshotAfter.treeSha256
        if ($null -eq $script:GitSnapshotBefore) {
            throw 'The before Git metadata snapshot was unavailable.'
        }
        $assessment = Get-BaselineGitMetadataAssessment -Before $script:GitSnapshotBefore -After $script:GitSnapshotAfter
        foreach ($propertyName in @(
            'status', 'unchanged', 'ambientChangesAllowed', 'allowedAdditionPrefix',
            'addedDirectories', 'removedDirectories', 'addedFiles', 'removedFiles', 'changedFiles'
        )) {
            $script:Result.gitMetadataIntegrity[$propertyName] = Get-UevJsonProperty $assessment $propertyName
        }
    } catch {
        $script:Result.gitMetadataIntegrity.status = 'BLOCKED'
        Add-UevBlocker -Code 'GIT_METADATA_POSTCHECK_FAILED' -Check 'gitMetadataIntegrity' -Path (Join-Path $script:NormalizedProjectRoot '.git') -Message $_.Exception.Message
    }
}

# Finalizes finding arrays and exactly one public final status.
function Complete-UevResult {
    $script:Result.warnings = @($script:Warnings)
    $script:Result.failures = @($script:Failures)
    $script:Result.blockers = @($script:Blockers)
    $script:Result.evidence = @($script:Evidence)
    $script:Result.finalStatus = Get-UevFinalStatus `
        -OriginalIntegrityStatus $script:Result.originalProjectIntegrity.status `
        -GitIntegrityStatus $script:Result.gitMetadataIntegrity.status `
        -FailureCount $script:Failures.Count `
        -BlockerCount $script:Blockers.Count `
        -NoConfirmedAssembly $script:NoConfirmedAssembly `
        -ScriptCompilationStatus $script:Result.verification.scriptCompilation.status `
        -EditModeStatus $script:Result.verification.editModeTests.status
}

# Serializes, schema-checks, and preserves the final JSON outside the project.
function ConvertTo-UevFinalJson {
    Complete-UevResult
    try {
        $schemaErrors = @(Invoke-JsonSchemaValidation -Instance ([pscustomobject]$script:Result) -SchemaPath $script:ResultSchemaPath)
        if ($schemaErrors.Count -gt 0) {
            Add-UevBlocker -Code 'RESULT_SCHEMA_VALIDATION_FAILED' -Check 'result' -Path $script:ResultSchemaPath -Message ([string]::Join(' ', [string[]]@($schemaErrors | ForEach-Object { "$($_.path): $($_.message)" })))
            Complete-UevResult
        }
    } catch {
        Add-UevBlocker -Code 'RESULT_SCHEMA_VALIDATION_UNAVAILABLE' -Check 'result' -Path $script:ResultSchemaPath -Message $_.Exception.Message
        Complete-UevResult
    }
    $json = if ($Pretty) {
        ConvertTo-Json -InputObject $script:Result -Depth 30
    } else {
        ConvertTo-Json -InputObject $script:Result -Depth 30 -Compress
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:Result.artifacts.resultPath)) {
        try {
            Write-UevText -Path $script:Result.artifacts.resultPath -Content $json
            $script:Result.artifacts.resultWritten = $true
            Complete-UevResult
            $json = if ($Pretty) { ConvertTo-Json $script:Result -Depth 30 } else { ConvertTo-Json $script:Result -Depth 30 -Compress }
            Write-UevText -Path $script:Result.artifacts.resultPath -Content $json
        } catch {
            $script:Result.artifacts.resultWritten = $false
            Add-UevBlocker -Code 'RESULT_ARTIFACT_WRITE_FAILED' -Check 'result' -Path $script:Result.artifacts.resultPath -Message $_.Exception.Message
            Complete-UevResult
            $json = if ($Pretty) { ConvertTo-Json $script:Result -Depth 30 } else { ConvertTo-Json $script:Result -Depth 30 -Compress }
        }
    }
    return $json
}

try {
    try {
        $script:NormalizedProjectRoot = Get-UevNormalizedPath -Path $ProjectRoot
        $script:Result.projectRoot = $script:NormalizedProjectRoot
        if (-not (Test-Path -LiteralPath $script:NormalizedProjectRoot -PathType Container)) {
            throw 'ProjectRoot is not an existing directory.'
        }
        $projectReparsePoint = Get-UevReparsePointOnPath -Path $script:NormalizedProjectRoot
        if ($null -ne $projectReparsePoint) {
            throw "ProjectRoot traverses reparse point $projectReparsePoint."
        }
    } catch {
        Add-UevBlocker -Code 'PROJECT_ROOT_INVALID' -Check 'projectRoot' -Path $ProjectRoot -Message $_.Exception.Message
    }

    $requestedArtifactsRoot = if ([string]::IsNullOrWhiteSpace($ArtifactsRoot)) {
        Join-Path ([System.IO.Path]::GetTempPath()) 'uev'
    } else {
        $ArtifactsRoot
    }
    try {
        Initialize-UevArtifactSession -RequestedRoot $requestedArtifactsRoot
    } catch {
        Add-UevBlocker -Code 'ARTIFACT_ROOT_UNSAFE' -Check 'artifacts' -Path $requestedArtifactsRoot -Message $_.Exception.Message
        $fallbackRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'uev'
        if (-not ([string]$requestedArtifactsRoot).Equals($fallbackRoot, $script:UevPathComparison)) {
            try {
                Initialize-UevArtifactSession -RequestedRoot $fallbackRoot
            } catch {
                [Console]::Error.WriteLine("[unity-editmode-verification] No safe artifact session is available: $($_.Exception.Message)")
            }
        }
    }

    if ($null -ne $script:NormalizedProjectRoot -and (Test-Path -LiteralPath $script:NormalizedProjectRoot -PathType Container)) {
        Initialize-UevOriginalIntegrity
    }
    if ($null -ne $script:SessionRoot -and $script:Blockers.Count -eq 0) {
        Invoke-UevBaseline
        Test-UevBaselineHandoff
        Test-UevDoctorEvidence
        if ($script:Result.doctor.accepted -and -not $script:NoConfirmedAssembly) {
            Test-UevFingerprintBindings
            Test-UevSelectedAssemblyBinaries
            Test-UevUnityTrust
            Test-UevSourceEditorPreflight
            if ($script:Blockers.Count -eq 0) {
                try {
                    Invoke-UevEditModeTests
                    Set-UevDynamicVerification
                } catch {
                    Add-UevBlocker -Code 'EDITMODE_PROCESS_EXECUTION_FAILED' -Check 'editModeTests' -Path $script:Result.unity.executablePath -Message $_.Exception.Message
                }
            }
        }
    }
} catch {
    Add-UevBlocker -Code 'UNEXPECTED_VERIFIER_ERROR' -Check 'verifier' -Path $null -Message $_.Exception.Message
} finally {
    if ($null -ne $script:NormalizedProjectRoot -and (Test-Path -LiteralPath $script:NormalizedProjectRoot -PathType Container)) {
        Complete-UevOriginalIntegrity
    }
    [Console]::Out.Write((ConvertTo-UevFinalJson))
}
