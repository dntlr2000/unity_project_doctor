[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [AllowEmptyString()]
    [string]$ProjectRoot = (Get-Location).Path,

    [Parameter()]
    [AllowNull()]
    [string]$DoctorResultPath,

    [Parameter()]
    [AllowNull()]
    [string]$UnityExecutable = "C:\Program Files\Unity\Hub\Editor\6000.0.69f1\Editor\Unity.exe",

    [Parameter()]
    [AllowNull()]
    [string]$ArtifactsRoot = (Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "unity-baseline-verification"),

    [Parameter()]
    [int]$TimeoutSeconds = 1800,

    [Parameter()]
    [switch]$Pretty
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:SchemaVersion = "1.1.0"
$script:VerifierVersion = "0.1.2"
$script:ExpectedDoctorSchemaVersion = "1.1.0"
$script:ExpectedDoctorScannerVersion = "0.2.1"
$script:LegacyDoctorSchemaVersion = "1.0.0"
$script:ExpectedUnityVersion = "6000.0.69f1"
$script:ValidatorLibraryPath = Join-Path -Path $PSScriptRoot -ChildPath "lib\json-schema-validator.ps1"
$script:ProcessLibraryPath = Join-Path -Path $PSScriptRoot -ChildPath "lib\unity-process-job.ps1"
$script:EditorLogLibraryPath = Join-Path -Path $PSScriptRoot -ChildPath "lib\unity-editor-log.ps1"
$script:GitIntegrityLibraryPath = Join-Path -Path $PSScriptRoot -ChildPath "lib\git-metadata-integrity.ps1"
$script:CodexSkillsRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:FingerprintLibraryPath = Join-Path -Path $script:CodexSkillsRoot -ChildPath "unity-project-doctor\scripts\lib\unity-project-fingerprint.ps1"
$script:IsWindowsPlatform = $env:OS -eq "Windows_NT"
$script:PathComparison = if ($script:IsWindowsPlatform) {
    [System.StringComparison]::OrdinalIgnoreCase
} else {
    [System.StringComparison]::Ordinal
}
$script:PathComparer = if ($script:IsWindowsPlatform) {
    [System.StringComparer]::OrdinalIgnoreCase
} else {
    [System.StringComparer]::Ordinal
}
$script:ExcludedTopLevelNames = @(
    ".agents", ".codex", ".git", ".hg", ".idea", ".svn", ".vs",
    "Build", "Builds", "Library", "Logs", "Obj", "Temp", "UserSettings"
)
$script:ExcludedTopLevelLookup = @{}
foreach ($excludedName in $script:ExcludedTopLevelNames) {
    $script:ExcludedTopLevelLookup[$excludedName.ToUpperInvariant()] = $true
}
$script:Blockers = New-Object System.Collections.ArrayList
$script:Evidence = New-Object System.Collections.ArrayList
$script:EvidenceSequence = 0
$script:DoctorValidationErrors = New-Object System.Collections.ArrayList
$script:NormalizedProjectRoot = $null
$script:SessionRoot = $null
$script:OriginalSnapshotBefore = $null
$script:OriginalSnapshotAfter = $null
$script:GitMetadataSnapshotBefore = $null
$script:GitMetadataSnapshotAfter = $null

[Console]::OutputEncoding = $script:Utf8NoBom

# Creates the stable v0.1 JSON result shape before validation begins.
function New-VerificationResult {
    return [ordered]@{
        schemaVersion = $script:SchemaVersion
        verifierVersion = $script:VerifierVersion
        projectRoot = $null
        expectedUnityVersion = $script:ExpectedUnityVersion
        doctor = [ordered]@{
            sourcePath = $null
            sha256 = $null
            schemaPath = $null
            schemaVersion = $null
            scannerVersion = $null
            projectRoot = $null
            finalStatus = $null
            warningCount = 0
            warnings = @()
            validationErrors = @()
            schemaValidated = $false
            fingerprintMatched = $false
            projectFingerprint = $null
            currentProjectFingerprint = $null
            accepted = $false
        }
        unity = [ordered]@{
            executablePath = $null
            executableSha256 = $null
            fileVersion = $null
            productVersion = $null
            companyName = $null
            detectedExecutableVersion = $null
            executableVersionMatched = $false
            signatureStatus = $null
            signerSubject = $null
            certificateThumbprint = $null
            publisherMatched = $false
            projectVersion = $null
            arguments = @()
            commandLineContainsOriginalProject = $null
            processStarted = $false
            timedOut = $false
            exitCode = $null
            standardOutputPath = $null
            standardErrorPath = $null
            hubInvoked = $false
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
        preflight = [ordered]@{
            sourceEditorCheckCompleted = $false
            sourceEditorProcessIds = @()
            sourceEditorDetected = $null
            sourceSnapshotStable = $false
            gitMetadataSnapshotAccepted = $false
            artifactRootOutsideProject = $false
            trustedPathsWithoutReparse = $false
        }
        isolation = [ordered]@{
            artifactsRoot = $null
            sessionRoot = $null
            projectCopyPath = $null
            copyStatus = "NOT_STARTED"
            copiedDirectoryCount = 0
            copiedFileCount = 0
            excludedTopLevelPaths = @($script:ExcludedTopLevelNames)
            localPackageReferences = @()
            copyFingerprint = $null
            originalProjectPassedToUnity = $null
        }
        artifacts = [ordered]@{
            editorLogPath = $null
            upmLogPath = $null
            resultPath = $null
            resultWritten = $false
        }
        editorLog = [ordered]@{
            exists = $false
            byteLength = $null
            sha256 = $null
            detectedUnityVersion = $null
            versionMatched = $false
            batchModeObserved = $false
            isolatedProjectPathObserved = $false
            importCompleted = $false
            compilePhaseObserved = $false
            domainReloadCompleted = $false
            successfulQuitObserved = $false
            zeroReturnCodeObserved = $false
            compilerErrors = @()
            compilerErrorCount = 0
            compilerErrorsTruncated = $false
            failureMarkers = @()
            missingSuccessMarkers = @()
            classification = "NOT_ANALYZED"
        }
        originalProjectIntegrity = [ordered]@{
            scope = "BASELINE_COPY_SET"
            excludedTopLevelPaths = @($script:ExcludedTopLevelNames)
            status = "NOT_VERIFIED"
            beforeDirectoryCount = $null
            afterDirectoryCount = $null
            beforeFileCount = $null
            afterFileCount = $null
            beforeTreeSha256 = $null
            afterTreeSha256 = $null
            unchanged = $null
            addedDirectories = @()
            removedDirectories = @()
            addedFiles = @()
            removedFiles = @()
            changedFiles = @()
        }
        gitMetadataIntegrity = [ordered]@{
            scope = ".git"
            status = "NOT_VERIFIED"
            presentBefore = $null
            presentAfter = $null
            entryTypeBefore = $null
            entryTypeAfter = $null
            beforeDirectoryCount = $null
            afterDirectoryCount = $null
            beforeFileCount = $null
            afterFileCount = $null
            beforeTreeSha256 = $null
            afterTreeSha256 = $null
            unchanged = $null
            ambientChangesAllowed = $false
            allowedAdditionPrefix = ".git/refs/codex/turn-diffs/checkpoints/"
            rootStateChanged = $false
            addedDirectories = @()
            removedDirectories = @()
            addedFiles = @()
            removedFiles = @()
            changedFiles = @()
            disallowedAddedDirectories = @()
            disallowedAddedFiles = @()
        }
        verification = [ordered]@{
            scriptCompilation = [ordered]@{
                status = "NOT_VERIFIED"
                reason = "Unity has not produced sufficient compilation evidence."
            }
            tests = [ordered]@{
                status = "NOT_VERIFIED"
                reason = "No Unity tests or external tests were run."
            }
            playerBuild = [ordered]@{
                status = "NOT_VERIFIED"
                reason = "No Player Build was run."
            }
            playMode = [ordered]@{
                status = "NOT_VERIFIED"
                reason = "PlayMode was not entered and no PlayMode tests were run."
            }
            runtime = [ordered]@{
                status = "NOT_VERIFIED"
                reason = "No scene, player, or runtime behavior was launched."
            }
        }
        blockers = @()
        finalStatus = "VERIFICATION_BLOCKED"
        evidence = @()
    }
}

$script:Result = New-VerificationResult

# Normalizes an absolute path without resolving a link target.
function Get-NormalizedAbsolutePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Path must not be empty."
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
    if ($script:PathComparer.Equals($fullPath, $pathRoot)) {
        return $fullPath
    }

    $trimCharacters = [char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    return $fullPath.TrimEnd($trimCharacters)
}

# Resolves one canonical repository schema from source or an installed Skill symlink target.
function Resolve-DoctorSchemaPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SchemaVersion
    )

    $fileName = switch ($SchemaVersion) {
        "1.0.0" { "unity-project-audit.schema.json" }
        "1.1.0" { "unity-project-audit-1.1.0.schema.json" }
        default { throw "No Doctor schema is registered for schemaVersion $SchemaVersion." }
    }

    $searchStarts = New-Object System.Collections.ArrayList
    [void]$searchStarts.Add($PSScriptRoot)
    $skillRoot = Split-Path -Parent $PSScriptRoot
    try {
        $skillEntry = Get-Item -LiteralPath $skillRoot -Force -ErrorAction Stop
        foreach ($target in @($skillEntry.Target)) {
            if ([string]::IsNullOrWhiteSpace([string]$target)) {
                continue
            }
            $targetPath = [string]$target
            if (-not [System.IO.Path]::IsPathRooted($targetPath)) {
                $targetPath = Join-Path -Path $skillEntry.Parent.FullName -ChildPath $targetPath
            }
            [void]$searchStarts.Add((Get-NormalizedAbsolutePath -Path $targetPath))
        }
    } catch {
    }

    foreach ($searchStart in @($searchStarts)) {
        $current = Get-NormalizedAbsolutePath -Path ([string]$searchStart)
        for ($depth = 0; $depth -le 8; $depth++) {
            $candidate = Join-Path -Path $current -ChildPath ("schemas\" + $fileName)
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return Get-NormalizedAbsolutePath -Path $candidate
            }
            $parent = [System.IO.Directory]::GetParent($current)
            if ($null -eq $parent -or $parent.FullName.Equals($current, $script:PathComparison)) {
                break
            }
            $current = $parent.FullName
        }
    }
    throw "Canonical Doctor schema was not found: $fileName"
}

# Tests whether one normalized path is equal to or below another path.
function Test-PathWithinRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $normalizedPath = Get-NormalizedAbsolutePath -Path $Path
    $normalizedRoot = Get-NormalizedAbsolutePath -Path $Root
    if ($normalizedPath.Equals($normalizedRoot, $script:PathComparison)) {
        return $true
    }

    $rootPrefix = $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar
    return $normalizedPath.StartsWith($rootPrefix, $script:PathComparison)
}

# Converts an in-project absolute path to a forward-slash relative path.
function ConvertTo-ProjectRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $normalizedPath = Get-NormalizedAbsolutePath -Path $Path
    if (-not (Test-PathWithinRoot -Path $normalizedPath -Root $script:NormalizedProjectRoot)) {
        throw "Path is outside the original project: $normalizedPath"
    }

    if ($normalizedPath.Equals($script:NormalizedProjectRoot, $script:PathComparison)) {
        return "."
    }

    return $normalizedPath.Substring($script:NormalizedProjectRoot.Length + 1).Replace("\", "/")
}

# Returns a case-stable dictionary key for a project-relative path.
function Get-PathKey {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($script:IsWindowsPlatform) {
        return $Path.ToUpperInvariant()
    }

    return $Path
}

# Parses a Windows command line into argument tokens for exact project-path comparison.
function ConvertFrom-WindowsProcessCommandLine {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$CommandLine
    )

    $arguments = New-Object 'System.Collections.Generic.List[string]'
    $length = $CommandLine.Length
    $index = 0
    while ($index -lt $length) {
        while ($index -lt $length -and [char]::IsWhiteSpace($CommandLine[$index])) {
            $index++
        }
        if ($index -ge $length) {
            break
        }

        $builder = New-Object System.Text.StringBuilder
        $insideQuotes = $false
        while ($index -lt $length) {
            $backslashCount = 0
            while ($index -lt $length -and $CommandLine[$index] -eq '\') {
                $backslashCount++
                $index++
            }
            if ($index -lt $length -and $CommandLine[$index] -eq '"') {
                [void]$builder.Append(('\' * [int]($backslashCount / 2)))
                if (($backslashCount % 2) -eq 0) {
                    $insideQuotes = -not $insideQuotes
                } else {
                    [void]$builder.Append('"')
                }
                $index++
                continue
            }
            if ($backslashCount -gt 0) {
                [void]$builder.Append(('\' * $backslashCount))
            }
            if ($index -ge $length -or (-not $insideQuotes -and [char]::IsWhiteSpace($CommandLine[$index]))) {
                break
            }
            [void]$builder.Append($CommandLine[$index])
            $index++
        }
        $arguments.Add($builder.ToString())
    }
    return [string[]]$arguments.ToArray()
}

# Finds only running Unity Editor processes whose -projectPath equals the source project.
function Get-SourceProjectUnityProcesses {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceProjectRoot
    )

    if (-not $script:IsWindowsPlatform) {
        throw 'Unity process preflight requires Windows.'
    }

    $matches = New-Object System.Collections.ArrayList
    $unityProcesses = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'Unity.exe'" -ErrorAction Stop)
    foreach ($unityProcess in $unityProcesses) {
        if ([string]::IsNullOrWhiteSpace([string]$unityProcess.CommandLine)) {
            continue
        }
        $arguments = @(ConvertFrom-WindowsProcessCommandLine -CommandLine ([string]$unityProcess.CommandLine))
        for ($argumentIndex = 0; $argumentIndex + 1 -lt $arguments.Count; $argumentIndex++) {
            if (-not [string]::Equals($arguments[$argumentIndex], '-projectPath', [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            try {
                $observedProjectPath = Get-NormalizedAbsolutePath -Path $arguments[$argumentIndex + 1]
                if ($observedProjectPath.Equals($SourceProjectRoot, $script:PathComparison)) {
                    [void]$matches.Add([pscustomobject][ordered]@{
                        processId = [int]$unityProcess.ProcessId
                        executablePath = $unityProcess.ExecutablePath
                        projectPath = $observedProjectPath
                    })
                }
            } catch {
            }
            break
        }
    }
    return @($matches)
}

# Blocks only when a running Unity Editor is associated with the exact source project path.
function Test-SourceProjectEditorPreflight {
    try {
        $matches = @(Get-SourceProjectUnityProcesses -SourceProjectRoot $script:NormalizedProjectRoot)
        $script:Result.preflight.sourceEditorCheckCompleted = $true
        $script:Result.preflight.sourceEditorProcessIds = @($matches | ForEach-Object { $_.processId })
        $script:Result.preflight.sourceEditorDetected = $matches.Count -gt 0
        if ($matches.Count -gt 0) {
            Add-Blocker -Code "SOURCE_PROJECT_OPEN_IN_UNITY" -Check "preflight" -Path $script:NormalizedProjectRoot -Message "The exact source project is already associated with running Unity process ID(s): $([string]::Join(', ', [string[]]@($script:Result.preflight.sourceEditorProcessIds)))."
        } else {
            Add-Evidence -Check "sourceEditorPreflight" -Status "PASSED" -Source $script:NormalizedProjectRoot -Detail "No running Unity.exe -projectPath argument matched the exact source project; unrelated Unity projects were not blocked."
        }
    } catch {
        $script:Result.preflight.sourceEditorCheckCompleted = $false
        $script:Result.preflight.sourceEditorDetected = $null
        Add-Blocker -Code "SOURCE_EDITOR_PREFLIGHT_UNAVAILABLE" -Check "preflight" -Path $script:NormalizedProjectRoot -Message "Running Unity process association could not be inspected safely: $($_.Exception.Message)"
    }
}

# Finds the first existing reparse point on a path or its existing ancestors.
function Get-ReparsePointOnPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $currentPath = Get-NormalizedAbsolutePath -Path $Path
    while (-not [string]::IsNullOrWhiteSpace($currentPath)) {
        if (Test-Path -LiteralPath $currentPath) {
            $entry = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                return $entry.FullName
            }
        }

        $parent = [System.IO.Directory]::GetParent($currentPath)
        if ($null -eq $parent) {
            break
        }

        $parentPath = $parent.FullName
        if ($parentPath.Equals($currentPath, $script:PathComparison)) {
            break
        }

        $currentPath = $parentPath
    }

    return $null
}

# Reads a named property without allowing StrictMode to throw for missing JSON fields.
function Get-JsonPropertyValue {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

# Tests whether a parsed JSON object contains a named property.
function Test-JsonProperty {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $false
    }

    return $null -ne $InputObject.PSObject.Properties[$Name]
}

# Adds one ordered evidence record to the result ledger.
function Add-Evidence {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Check,

        [Parameter(Mandatory = $true)]
        [ValidateSet("OBSERVED", "PASSED", "FAILED", "NOT_VERIFIED", "BLOCKED")]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Detail
    )

    $script:EvidenceSequence++
    [void]$script:Evidence.Add([ordered]@{
        id = "E{0:D3}" -f $script:EvidenceSequence
        check = $Check
        status = $Status
        source = $Source
        detail = $Detail
    })
}

# Adds a concrete blocker and matching evidence without changing any project file.
function Add-Blocker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Code,

        [Parameter(Mandatory = $true)]
        [string]$Check,

        [Parameter()]
        [AllowNull()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    foreach ($existing in @($script:Blockers)) {
        if ($existing.code -eq $Code -and $existing.path -eq $Path -and $existing.message -eq $Message) {
            return
        }
    }

    [void]$script:Blockers.Add([ordered]@{
        code = $Code
        check = $Check
        path = $Path
        message = $Message
    })
    $source = if ([string]::IsNullOrWhiteSpace($Path)) { $Check } else { $Path }
    Add-Evidence -Check $Check -Status "BLOCKED" -Source $source -Detail $Message
}

# Adds one Doctor contract error and blocks Unity startup.
function Add-DoctorValidationError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Code,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter()]
        [AllowNull()]
        [string]$JsonPath,

        [Parameter()]
        [AllowNull()]
        [string]$Keyword
    )

    [void]$script:DoctorValidationErrors.Add([ordered]@{
        code = $Code
        path = $JsonPath
        keyword = $Keyword
        message = $Message
    })
    $blockerPath = if ([string]::IsNullOrWhiteSpace($JsonPath)) {
        $script:Result.doctor.sourcePath
    } else {
        $JsonPath
    }
    Add-Blocker -Code $Code -Check "doctor" -Path $blockerPath -Message $Message
}

# Calculates a lowercase SHA-256 digest for a file with read-only sharing.
function Get-FileSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $stream = $null
    $algorithm = $null
    try {
        $stream = New-Object System.IO.FileStream(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        $algorithm = [System.Security.Cryptography.SHA256]::Create()
        $hash = $algorithm.ComputeHash($stream)
        return -join @($hash | ForEach-Object { $_.ToString("x2") })
    } finally {
        if ($null -ne $algorithm) {
            $algorithm.Dispose()
        }
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

# Calculates a lowercase SHA-256 digest for one UTF-8 string.
function Get-StringSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $script:Utf8NoBom.GetBytes($Text)
        $hash = $algorithm.ComputeHash($bytes)
        return -join @($hash | ForEach-Object { $_.ToString("x2") })
    } finally {
        $algorithm.Dispose()
    }
}

# Reads a UTF-8 or BOM-marked text file without writing beside it.
function Read-TextFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $reader = $null
    try {
        $reader = New-Object System.IO.StreamReader($Path, $script:Utf8NoBom, $true)
        return $reader.ReadToEnd()
    } finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
    }
}

# Parses exactly one JSON document from a file.
function Read-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $text = Read-TextFile -Path $Path
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "JSON file is empty."
    }

    return ConvertFrom-Json -InputObject $text -ErrorAction Stop
}

# Builds the exact Doctor/Baseline copy-set snapshot while excluding generated, tooling, agent, and VCS trees.
function Get-ProjectTreeSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    return Get-UnityCopySetSnapshot -ProjectRoot $Root
}

# Compares two project snapshots and returns every structural or content difference.
function Compare-ProjectTreeSnapshots {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Before,

        [Parameter(Mandatory = $true)]
        [object]$After
    )

    $beforeDirectories = @{}
    $afterDirectories = @{}
    foreach ($path in @($Before.directories)) {
        $beforeDirectories[(Get-PathKey -Path $path)] = $path
    }
    foreach ($path in @($After.directories)) {
        $afterDirectories[(Get-PathKey -Path $path)] = $path
    }

    $addedDirectories = New-Object System.Collections.ArrayList
    $removedDirectories = New-Object System.Collections.ArrayList
    foreach ($key in $afterDirectories.Keys) {
        if (-not $beforeDirectories.ContainsKey($key)) {
            [void]$addedDirectories.Add($afterDirectories[$key])
        } elseif ([string]$beforeDirectories[$key] -cne [string]$afterDirectories[$key]) {
            [void]$removedDirectories.Add($beforeDirectories[$key])
            [void]$addedDirectories.Add($afterDirectories[$key])
        }
    }
    foreach ($key in $beforeDirectories.Keys) {
        if (-not $afterDirectories.ContainsKey($key)) {
            [void]$removedDirectories.Add($beforeDirectories[$key])
        }
    }

    $beforeFiles = @{}
    $afterFiles = @{}
    foreach ($entry in @($Before.files)) {
        $beforeFiles[(Get-PathKey -Path $entry.path)] = $entry
    }
    foreach ($entry in @($After.files)) {
        $afterFiles[(Get-PathKey -Path $entry.path)] = $entry
    }

    $addedFiles = New-Object System.Collections.ArrayList
    $removedFiles = New-Object System.Collections.ArrayList
    $changedFiles = New-Object System.Collections.ArrayList
    foreach ($key in $afterFiles.Keys) {
        $afterEntry = $afterFiles[$key]
        if (-not $beforeFiles.ContainsKey($key)) {
            [void]$addedFiles.Add($afterEntry.path)
            continue
        }

        $beforeEntry = $beforeFiles[$key]
        if (
            [string]$beforeEntry.path -cne [string]$afterEntry.path -or
            [long]$beforeEntry.length -ne [long]$afterEntry.length -or
            [string]$beforeEntry.sha256 -ne [string]$afterEntry.sha256
        ) {
            [void]$changedFiles.Add([ordered]@{
                pathBefore = $beforeEntry.path
                pathAfter = $afterEntry.path
                lengthBefore = [long]$beforeEntry.length
                lengthAfter = [long]$afterEntry.length
                sha256Before = $beforeEntry.sha256
                sha256After = $afterEntry.sha256
            })
        }
    }
    foreach ($key in $beforeFiles.Keys) {
        if (-not $afterFiles.ContainsKey($key)) {
            [void]$removedFiles.Add($beforeFiles[$key].path)
        }
    }

    $addedDirectoryArray = @($addedDirectories | Sort-Object)
    $removedDirectoryArray = @($removedDirectories | Sort-Object)
    $addedFileArray = @($addedFiles | Sort-Object)
    $removedFileArray = @($removedFiles | Sort-Object)
    $changedFileArray = @($changedFiles | Sort-Object -Property pathBefore)
    $unchanged = (
        $addedDirectoryArray.Count -eq 0 -and
        $removedDirectoryArray.Count -eq 0 -and
        $addedFileArray.Count -eq 0 -and
        $removedFileArray.Count -eq 0 -and
        $changedFileArray.Count -eq 0 -and
        $Before.treeSha256 -eq $After.treeSha256
    )

    return [pscustomobject][ordered]@{
        unchanged = $unchanged
        addedDirectories = $addedDirectoryArray
        removedDirectories = $removedDirectoryArray
        addedFiles = $addedFileArray
        removedFiles = $removedFileArray
        changedFiles = $changedFileArray
    }
}

# Tests whether a relative project path belongs to an excluded generated or tooling tree.
function Test-ExcludedProjectPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $firstSegment = @($RelativePath.Replace("\", "/").Split("/"))[0]
    return $script:ExcludedTopLevelLookup.ContainsKey($firstSegment.ToUpperInvariant())
}

# Copies only project source and configuration files into the isolated project.
function Copy-ProjectToIsolation {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Snapshot,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    [void][System.IO.Directory]::CreateDirectory($Destination)
    $copiedDirectoryCount = 0
    $copiedFileCount = 0

    foreach ($relativeDirectory in @($Snapshot.directories)) {
        if (Test-ExcludedProjectPath -RelativePath $relativeDirectory) {
            continue
        }

        $destinationDirectory = Join-Path -Path $Destination -ChildPath $relativeDirectory.Replace("/", "\")
        [void][System.IO.Directory]::CreateDirectory($destinationDirectory)
        $copiedDirectoryCount++
    }

    foreach ($file in @($Snapshot.files)) {
        if (Test-ExcludedProjectPath -RelativePath $file.path) {
            continue
        }

        $sourcePath = Join-Path -Path $script:NormalizedProjectRoot -ChildPath $file.path.Replace("/", "\")
        $destinationPath = Join-Path -Path $Destination -ChildPath $file.path.Replace("/", "\")
        $destinationParent = Split-Path -Parent $destinationPath
        [void][System.IO.Directory]::CreateDirectory($destinationParent)
        [System.IO.File]::Copy($sourcePath, $destinationPath, $false)
        $copiedItem = Get-Item -LiteralPath $destinationPath -Force -ErrorAction Stop
        $copiedHash = Get-FileSha256 -Path $destinationPath
        if ([long]$copiedItem.Length -ne [long]$file.length -or $copiedHash -ne [string]$file.sha256) {
            throw "Copied file does not match the pre-run source snapshot: $($file.path)"
        }
        $copiedFileCount++
    }

    foreach ($requiredPath in @(
        "Assets",
        "Packages",
        "ProjectSettings",
        "ProjectSettings\ProjectVersion.txt"
    )) {
        $candidate = Join-Path -Path $Destination -ChildPath $requiredPath
        if (-not (Test-Path -LiteralPath $candidate)) {
            throw "Isolated copy is missing required Unity path: $requiredPath"
        }
    }

    return [pscustomobject][ordered]@{
        copiedDirectoryCount = $copiedDirectoryCount
        copiedFileCount = $copiedFileCount
    }
}

# Decodes a file-package path repeatedly so percent-encoded escape syntax cannot bypass checks.
function ConvertFrom-LocalPackagePathEncoding {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$RawPath
    )

    $decoded = $RawPath
    for ($pass = 0; $pass -lt 4; $pass++) {
        $next = [System.Uri]::UnescapeDataString($decoded)
        if ($next -eq $decoded) {
            return $decoded
        }
        $decoded = $next
    }
    if ($decoded -match '%[0-9A-Fa-f]{2}') {
        throw "Local package path remains percent-encoded after the decode safety limit."
    }
    return $decoded
}

# Tests syntax that denotes an absolute, authority, UNC, or Windows device path.
function Get-ForbiddenLocalPackagePathKind {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Path
    )

    $windowsPath = $Path.Replace('/', '\')
    if (
        $windowsPath.StartsWith('\\?\', [System.StringComparison]::Ordinal) -or
        $windowsPath.StartsWith('\\.\', [System.StringComparison]::Ordinal) -or
        $windowsPath.StartsWith('\??\', [System.StringComparison]::Ordinal)
    ) {
        return 'DEVICE'
    }
    if ($Path.StartsWith('//', [System.StringComparison]::Ordinal) -or $windowsPath.StartsWith('\\', [System.StringComparison]::Ordinal)) {
        return 'AUTHORITY_OR_UNC'
    }
    if (
        $Path.StartsWith('/', [System.StringComparison]::Ordinal) -or
        $windowsPath.StartsWith('\', [System.StringComparison]::Ordinal) -or
        [System.IO.Path]::IsPathRooted($windowsPath) -or
        $windowsPath -match '^[A-Za-z]:'
    ) {
        return 'ABSOLUTE'
    }
    if ($windowsPath -match '^[^\\]+:') {
        return 'URI_SCHEME'
    }
    return $null
}

# Validates local file package references in the source and, after copying, in isolation.
function Test-LocalPackageDependencySafety {
    param(
        [Parameter()]
        [switch]$ValidateIsolatedCopy
    )

    $projectForManifest = if ($ValidateIsolatedCopy) {
        $script:Result.isolation.projectCopyPath
    } else {
        $script:NormalizedProjectRoot
    }
    $manifestPath = Join-Path -Path $projectForManifest -ChildPath "Packages\manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Add-Blocker -Code "PACKAGE_MANIFEST_MISSING" -Check "isolation" -Path "Packages/manifest.json" -Message "Packages/manifest.json is required before an isolated Unity import."
        return
    }

    try {
        $manifest = Read-JsonFile -Path $manifestPath
    } catch {
        Add-Blocker -Code "PACKAGE_MANIFEST_INVALID" -Check "isolation" -Path "Packages/manifest.json" -Message "Packages/manifest.json could not be parsed for safe local dependency resolution: $($_.Exception.Message)"
        return
    }

    $dependencies = Get-JsonPropertyValue -InputObject $manifest -Name "dependencies"
    if ($null -eq $dependencies) {
        if (-not $ValidateIsolatedCopy) {
            $script:Result.isolation.localPackageReferences = @()
        }
        return
    }

    if ($dependencies -isnot [pscustomobject] -and $dependencies -isnot [System.Collections.IDictionary]) {
        Add-Blocker -Code "PACKAGE_DEPENDENCIES_INVALID" -Check "isolation" -Path "Packages/manifest.json" -Message "manifest dependencies must be a JSON object before local references can be checked."
        return
    }

    $manifestDirectory = Split-Path -Parent $manifestPath
    $validatedReferences = New-Object System.Collections.ArrayList
    foreach ($property in @($dependencies.PSObject.Properties)) {
        $reference = [string]$property.Value
        if (-not $reference.StartsWith("file:", [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $rawPath = $reference.Substring(5)
        try {
            if ([string]::IsNullOrWhiteSpace($rawPath) -or $rawPath.IndexOf([char]0) -ge 0) {
                throw "Local package path is empty or contains a null character."
            }
            $decodedPath = ConvertFrom-LocalPackagePathEncoding -RawPath $rawPath
        } catch {
            Add-Blocker -Code "LOCAL_PACKAGE_PATH_INVALID" -Check "isolation" -Path "Packages/manifest.json" -Message "Local package $($property.Name) has an invalid file reference: $reference"
            continue
        }

        $forbiddenKind = Get-ForbiddenLocalPackagePathKind -Path $decodedPath
        if ($null -ne $forbiddenKind) {
            $code = if ($forbiddenKind -in @('DEVICE', 'AUTHORITY_OR_UNC', 'URI_SCHEME')) {
                'LOCAL_PACKAGE_AUTHORITY_OR_DEVICE_PATH'
            } else {
                'LOCAL_PACKAGE_ABSOLUTE_PATH_FORBIDDEN'
            }
            Add-Blocker -Code $code -Check "isolation" -Path "Packages/manifest.json" -Message "Local package $($property.Name) must use a relative path without URI authority, UNC, device, or absolute syntax: $reference"
            continue
        }

        try {
            $decodedWindowsPath = $decodedPath.Replace('/', '\')
            $resolvedPath = Get-NormalizedAbsolutePath -Path (Join-Path -Path $manifestDirectory -ChildPath $decodedWindowsPath)
        } catch {
            Add-Blocker -Code "LOCAL_PACKAGE_PATH_INVALID" -Check "isolation" -Path "Packages/manifest.json" -Message "Local package $($property.Name) could not be normalized safely: $reference"
            continue
        }

        if (-not (Test-PathWithinRoot -Path $resolvedPath -Root $projectForManifest)) {
            Add-Blocker -Code "LOCAL_PACKAGE_OUTSIDE_PROJECT" -Check "isolation" -Path "Packages/manifest.json" -Message "Local package $($property.Name) resolves outside the original and isolated project boundary: $reference"
            continue
        }

        $relativePath = if ($ValidateIsolatedCopy) {
            $resolvedPath.Substring($script:Result.isolation.projectCopyPath.Length + 1).Replace('\', '/')
        } else {
            ConvertTo-ProjectRelativePath -Path $resolvedPath
        }
        if (Test-ExcludedProjectPath -RelativePath $relativePath) {
            Add-Blocker -Code "LOCAL_PACKAGE_EXCLUDED_FROM_COPY" -Check "isolation" -Path "Packages/manifest.json" -Message "Local package $($property.Name) resolves into excluded path $relativePath."
            continue
        }

        $reparsePoint = Get-ReparsePointOnPath -Path $resolvedPath
        if ($null -ne $reparsePoint) {
            Add-Blocker -Code "LOCAL_PACKAGE_REPARSE_POINT" -Check "isolation" -Path "Packages/manifest.json" -Message "Local package $($property.Name) traverses reparse point $reparsePoint."
            continue
        }
        if (-not (Test-Path -LiteralPath $resolvedPath)) {
            Add-Blocker -Code "LOCAL_PACKAGE_NOT_FOUND" -Check "isolation" -Path "Packages/manifest.json" -Message "Local package $($property.Name) does not exist at normalized project path $relativePath."
            continue
        }

        if ($ValidateIsolatedCopy) {
            $sourceRecord = @($script:Result.isolation.localPackageReferences | Where-Object { $_.name -ceq $property.Name }) | Select-Object -First 1
            if ($null -eq $sourceRecord) {
                Add-Blocker -Code "LOCAL_PACKAGE_COPY_RECORD_MISSING" -Check "isolation" -Path "Packages/manifest.json" -Message "Isolated local package $($property.Name) has no validated source record."
                continue
            }
            if (-not [string]::Equals([string]$sourceRecord.projectRelativePath, $relativePath, [System.StringComparison]::Ordinal)) {
                Add-Blocker -Code "LOCAL_PACKAGE_COPY_PATH_MISMATCH" -Check "isolation" -Path "Packages/manifest.json" -Message "Local package $($property.Name) resolves to a different relative path after isolation."
                continue
            }
            if ([string]$sourceRecord.sourceResolvedPath -eq [string]$resolvedPath) {
                Add-Blocker -Code "LOCAL_PACKAGE_SOURCE_REUSED" -Check "isolation" -Path "Packages/manifest.json" -Message "Local package $($property.Name) still resolves to the source path after isolation."
                continue
            }
            $isolatedEntry = Get-Item -LiteralPath $resolvedPath -Force -ErrorAction Stop
            $isolatedEntryType = if ($isolatedEntry.PSIsContainer) { 'Directory' } else { 'File' }
            if (-not [string]::Equals([string]$sourceRecord.sourceEntryType, $isolatedEntryType, [System.StringComparison]::Ordinal)) {
                Add-Blocker -Code "LOCAL_PACKAGE_COPY_TYPE_MISMATCH" -Check "isolation" -Path "Packages/manifest.json" -Message "Local package $($property.Name) changed filesystem type in the isolated copy."
                continue
            }
            $sourceRecord.isolatedResolvedPath = $resolvedPath
            $sourceRecord.isolatedPresent = $true
            $sourceRecord.copied = $true
        } else {
            $isolatedResolvedPath = Get-NormalizedAbsolutePath -Path (Join-Path -Path $script:Result.isolation.projectCopyPath -ChildPath $relativePath.Replace('/', '\'))
            if (-not (Test-PathWithinRoot -Path $isolatedResolvedPath -Root $script:Result.isolation.projectCopyPath)) {
                Add-Blocker -Code "LOCAL_PACKAGE_ISOLATED_PATH_INVALID" -Check "isolation" -Path "Packages/manifest.json" -Message "Local package $($property.Name) cannot resolve inside the isolated project."
                continue
            }
            if ($resolvedPath.Equals($isolatedResolvedPath, $script:PathComparison)) {
                Add-Blocker -Code "LOCAL_PACKAGE_SOURCE_REUSED" -Check "isolation" -Path "Packages/manifest.json" -Message "Local package $($property.Name) source and isolated paths are unexpectedly identical."
                continue
            }
            $entry = Get-Item -LiteralPath $resolvedPath -Force -ErrorAction Stop
            [void]$validatedReferences.Add([pscustomobject][ordered]@{
                name = $property.Name
                reference = $reference
                decodedRelativePath = $decodedPath.Replace('\', '/')
                projectRelativePath = $relativePath
                sourceResolvedPath = $resolvedPath
                isolatedResolvedPath = $isolatedResolvedPath
                sourceEntryType = if ($entry.PSIsContainer) { 'Directory' } else { 'File' }
                isolatedPresent = $false
                copied = $false
            })
        }
    }

    if (-not $ValidateIsolatedCopy) {
        $script:Result.isolation.localPackageReferences = @($validatedReferences)
    }
}

# Initializes one unique artifact session outside the original project.
function Initialize-ArtifactSession {
    param(
        [Parameter()]
        [AllowNull()]
        [string]$RequestedRoot
    )

    $requestedRootInvalid = $false
    try {
        $artifactParent = Get-NormalizedAbsolutePath -Path $RequestedRoot
        if (Test-PathWithinRoot -Path $artifactParent -Root $script:NormalizedProjectRoot) {
            throw "The artifact root is inside the original project."
        }
        $reparsePoint = Get-ReparsePointOnPath -Path $artifactParent
        if ($null -ne $reparsePoint) {
            throw "The artifact root traverses reparse point $reparsePoint."
        }
        if (Test-Path -LiteralPath $artifactParent -PathType Leaf) {
            throw "The artifact root is an existing file."
        }
        [void][System.IO.Directory]::CreateDirectory($artifactParent)
    } catch {
        $requestedRootInvalid = $true
        Add-Blocker -Code "ARTIFACT_ROOT_UNSAFE" -Check "artifacts" -Path $RequestedRoot -Message "The requested artifact root is unsafe or unavailable: $($_.Exception.Message)"
        $artifactParent = Get-NormalizedAbsolutePath -Path ([System.IO.Path]::GetTempPath())
    }

    $sessionName = "unity-baseline-verification-" + [guid]::NewGuid().ToString("N")
    $sessionRoot = Join-Path -Path $artifactParent -ChildPath $sessionName
    if (Test-PathWithinRoot -Path $sessionRoot -Root $script:NormalizedProjectRoot) {
        throw "No artifact session can be created outside the original project."
    }

    [void][System.IO.Directory]::CreateDirectory($sessionRoot)
    $logsRoot = Join-Path -Path $sessionRoot -ChildPath "logs"
    $resultsRoot = Join-Path -Path $sessionRoot -ChildPath "results"
    $projectCopyPath = Join-Path -Path $sessionRoot -ChildPath "project"
    [void][System.IO.Directory]::CreateDirectory($logsRoot)
    [void][System.IO.Directory]::CreateDirectory($resultsRoot)

    $sessionReparsePoint = Get-ReparsePointOnPath -Path $sessionRoot
    if ($null -ne $sessionReparsePoint) {
        throw "The artifact session traverses reparse point $sessionReparsePoint."
    }

    $script:SessionRoot = Get-NormalizedAbsolutePath -Path $sessionRoot
    $script:Result.isolation.artifactsRoot = $artifactParent
    $script:Result.isolation.sessionRoot = $script:SessionRoot
    $script:Result.isolation.projectCopyPath = Get-NormalizedAbsolutePath -Path $projectCopyPath
    $script:Result.artifacts.editorLogPath = Join-Path -Path $logsRoot -ChildPath "Editor.log"
    $script:Result.artifacts.upmLogPath = Join-Path -Path $logsRoot -ChildPath "upm.log"
    $script:Result.artifacts.resultPath = Join-Path -Path $resultsRoot -ChildPath "unity-baseline-verification.json"
    $script:Result.unity.standardOutputPath = Join-Path -Path $logsRoot -ChildPath "unity-stdout.log"
    $script:Result.unity.standardErrorPath = Join-Path -Path $logsRoot -ChildPath "unity-stderr.log"

    if (-not $requestedRootInvalid) {
        $script:Result.preflight.artifactRootOutsideProject = $true
        Add-Evidence -Check "artifacts" -Status "PASSED" -Source $script:SessionRoot -Detail "All logs, results, and the isolated project are located outside the original project."
    }
}

# Tests whether two string arrays have identical ordinal values and ordering.
function Test-ExactStringArray {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Left,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Right
    )

    if ($Left.Count -ne $Right.Count) {
        return $false
    }
    for ($index = 0; $index -lt $Left.Count; $index++) {
        if (-not [string]::Equals([string]$Left[$index], [string]$Right[$index], [System.StringComparison]::Ordinal)) {
            return $false
        }
    }
    return $true
}

# Validates the complete Doctor schema and its current-project fingerprint binding.
function Test-DoctorResult {
    param(
        [Parameter()]
        [AllowNull()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Add-DoctorValidationError -Code "DOCTOR_RESULT_PATH_REQUIRED" -Message "An existing unity-project-doctor v0.2 JSON path is required."
        return
    }

    try {
        $normalizedPath = Get-NormalizedAbsolutePath -Path $Path
        $script:Result.doctor.sourcePath = $normalizedPath
        if (Test-PathWithinRoot -Path $normalizedPath -Root $script:NormalizedProjectRoot) {
            Add-DoctorValidationError -Code "DOCTOR_RESULT_INSIDE_PROJECT" -Message "Doctor JSON must be stored outside the original Unity project."
            return
        }
        if (-not (Test-Path -LiteralPath $normalizedPath -PathType Leaf)) {
            Add-DoctorValidationError -Code "DOCTOR_RESULT_NOT_FOUND" -Message "Doctor JSON was not found at the supplied path."
            return
        }
        $reparsePoint = Get-ReparsePointOnPath -Path $normalizedPath
        if ($null -ne $reparsePoint) {
            Add-DoctorValidationError -Code "DOCTOR_RESULT_REPARSE_POINT" -Message "Doctor JSON path traverses reparse point $reparsePoint."
            return
        }

        $script:Result.doctor.sha256 = Get-FileSha256 -Path $normalizedPath
        $doctorResult = Read-JsonFile -Path $normalizedPath
    } catch {
        Add-DoctorValidationError -Code "DOCTOR_RESULT_INVALID_JSON" -Message "Doctor JSON could not be read as exactly one JSON document: $($_.Exception.Message)"
        return
    }

    $schemaVersion = Get-JsonPropertyValue -InputObject $doctorResult -Name "schemaVersion"
    $script:Result.doctor.schemaVersion = $schemaVersion
    if (@($script:LegacyDoctorSchemaVersion, $script:ExpectedDoctorSchemaVersion) -notcontains [string]$schemaVersion) {
        Add-DoctorValidationError -Code "DOCTOR_SCHEMA_VERSION_UNSUPPORTED" -Message "Doctor schemaVersion must be $($script:ExpectedDoctorSchemaVersion); schema 1.0.0 is recognized only as a legacy static-audit contract." -JsonPath '$.schemaVersion' -Keyword 'const'
        return
    }

    try {
        $schemaPath = Resolve-DoctorSchemaPath -SchemaVersion ([string]$schemaVersion)
        $script:Result.doctor.schemaPath = $schemaPath
        $schemaReparsePoint = Get-ReparsePointOnPath -Path $schemaPath
        if ($null -ne $schemaReparsePoint) {
            throw "Doctor schema path traverses reparse point $schemaReparsePoint."
        }
        $schemaErrors = @(Invoke-JsonSchemaValidation -Instance $doctorResult -SchemaPath $schemaPath)
    } catch {
        Add-DoctorValidationError -Code "DOCTOR_SCHEMA_VALIDATION_UNAVAILABLE" -Message "Doctor JSON Schema validation could not be completed: $($_.Exception.Message)" -JsonPath '$' -Keyword '$ref'
        return
    }

    foreach ($schemaError in $schemaErrors) {
        $keywordCode = ([string]$schemaError.keyword).ToUpperInvariant().Replace('$', 'REF_')
        Add-DoctorValidationError -Code ("DOCTOR_SCHEMA_" + $keywordCode) -Message $schemaError.message -JsonPath $schemaError.path -Keyword $schemaError.keyword
    }
    if ($schemaErrors.Count -gt 0) {
        return
    }
    $script:Result.doctor.schemaValidated = $true

    $scannerVersion = Get-JsonPropertyValue -InputObject $doctorResult -Name "scannerVersion"
    $doctorProjectRoot = Get-JsonPropertyValue -InputObject $doctorResult -Name "projectRoot"
    $finalStatus = Get-JsonPropertyValue -InputObject $doctorResult -Name "finalStatus"
    $projectDetection = Get-JsonPropertyValue -InputObject $doctorResult -Name "projectDetection"
    $unityEditorVersion = Get-JsonPropertyValue -InputObject $doctorResult -Name "unityEditorVersion"
    $blockedChecks = @(Get-JsonPropertyValue -InputObject $doctorResult -Name "blockedChecks")
    $warnings = @(Get-JsonPropertyValue -InputObject $doctorResult -Name "warnings")
    $dynamicVerification = Get-JsonPropertyValue -InputObject $doctorResult -Name "dynamicVerification"
    $evidence = @(Get-JsonPropertyValue -InputObject $doctorResult -Name "evidence")
    $doctorFingerprint = Get-JsonPropertyValue -InputObject $doctorResult -Name "projectFingerprint"

    $script:Result.doctor.scannerVersion = $scannerVersion
    $script:Result.doctor.projectRoot = $doctorProjectRoot
    $script:Result.doctor.finalStatus = $finalStatus
    $script:Result.doctor.warnings = $warnings
    $script:Result.doctor.warningCount = $warnings.Count
    $script:Result.doctor.projectFingerprint = $doctorFingerprint

    if ([string]$schemaVersion -eq $script:LegacyDoctorSchemaVersion) {
        Add-DoctorValidationError -Code "DOCTOR_FINGERPRINT_CONTRACT_REQUIRED" -Message "Doctor schema 1.0.0 remains valid for static audit, but Baseline v0.1.2 requires schema 1.1.0 copy-set fingerprint evidence." -JsonPath '$.schemaVersion' -Keyword 'const'
        return
    }
    if ([string]$scannerVersion -ne $script:ExpectedDoctorScannerVersion) {
        Add-DoctorValidationError -Code "DOCTOR_SCANNER_VERSION_MISMATCH" -Message "Doctor scannerVersion must be $($script:ExpectedDoctorScannerVersion)." -JsonPath '$.scannerVersion' -Keyword 'const'
    }
    try {
        $normalizedDoctorRoot = Get-NormalizedAbsolutePath -Path ([string]$doctorProjectRoot)
        if (-not $normalizedDoctorRoot.Equals($script:NormalizedProjectRoot, $script:PathComparison)) {
            Add-DoctorValidationError -Code "DOCTOR_PROJECT_ROOT_MISMATCH" -Message "Doctor projectRoot does not match the exact current project root." -JsonPath '$.projectRoot'
        }
    } catch {
        Add-DoctorValidationError -Code "DOCTOR_PROJECT_ROOT_INVALID" -Message "Doctor projectRoot is absent or invalid." -JsonPath '$.projectRoot'
    }

    $isUnityProject = Get-JsonPropertyValue -InputObject $projectDetection -Name "isUnityProject"
    $rootStatus = Get-JsonPropertyValue -InputObject $projectDetection -Name "rootStatus"
    if ($isUnityProject -isnot [bool] -or -not [bool]$isUnityProject -or [string]$rootStatus -ne "UNITY_PROJECT") {
        Add-DoctorValidationError -Code "DOCTOR_PROJECT_DETECTION_REJECTED" -Message "Doctor must identify the exact root as UNITY_PROJECT." -JsonPath '$.projectDetection'
    }

    $parseStatus = Get-JsonPropertyValue -InputObject $unityEditorVersion -Name "parseStatus"
    $doctorEditorVersion = Get-JsonPropertyValue -InputObject $unityEditorVersion -Name "editorVersion"
    if ([string]$parseStatus -ne "PARSED" -or [string]$doctorEditorVersion -ne $script:ExpectedUnityVersion) {
        Add-DoctorValidationError -Code "DOCTOR_UNITY_VERSION_MISMATCH" -Message "Doctor must parse Unity editorVersion $($script:ExpectedUnityVersion)." -JsonPath '$.unityEditorVersion'
    }

    if (@("STATIC_AUDIT_COMPLETE", "STATIC_AUDIT_COMPLETE_WITH_WARNINGS") -notcontains [string]$finalStatus) {
        Add-DoctorValidationError -Code "DOCTOR_FINAL_STATUS_REJECTED" -Message "Doctor finalStatus must be STATIC_AUDIT_COMPLETE or STATIC_AUDIT_COMPLETE_WITH_WARNINGS." -JsonPath '$.finalStatus'
    }
    if ($blockedChecks.Count -gt 0 -and $null -ne $blockedChecks[0]) {
        Add-DoctorValidationError -Code "DOCTOR_BLOCKED_CHECKS_PRESENT" -Message "Doctor blockedChecks must be empty." -JsonPath '$.blockedChecks'
    }
    if ($evidence.Count -eq 0 -or $null -eq $evidence[0]) {
        Add-DoctorValidationError -Code "DOCTOR_EVIDENCE_MISSING" -Message "Doctor evidence must contain the v0.2.1 static audit ledger." -JsonPath '$.evidence'
    }

    foreach ($name in @("compilation", "tests", "build", "runtime")) {
        $dynamicItem = Get-JsonPropertyValue -InputObject $dynamicVerification -Name $name
        $dynamicStatus = Get-JsonPropertyValue -InputObject $dynamicItem -Name "status"
        if ([string]$dynamicStatus -ne "NOT_VERIFIED") {
            Add-DoctorValidationError -Code ("DOCTOR_DYNAMIC_STATUS_INVALID_" + $name.ToUpperInvariant()) -Message "Doctor dynamicVerification.$name.status must remain NOT_VERIFIED." -JsonPath "$.dynamicVerification.$name.status"
        }
    }

    $expectedExcludedPaths = [object[]]@($script:ExcludedTopLevelNames)
    $doctorExcludedPaths = [object[]]@((Get-JsonPropertyValue -InputObject $doctorFingerprint -Name "excludedTopLevelPaths"))
    if (
        [string](Get-JsonPropertyValue -InputObject $doctorFingerprint -Name "status") -ne "COMPUTED" -or
        [string](Get-JsonPropertyValue -InputObject $doctorFingerprint -Name "contractVersion") -ne "1.0.0" -or
        [string](Get-JsonPropertyValue -InputObject $doctorFingerprint -Name "algorithm") -ne "SHA-256" -or
        [string](Get-JsonPropertyValue -InputObject $doctorFingerprint -Name "canonicalization") -ne "unity-copy-set-relative-path-length-sha256-lf-v1" -or
        [int](Get-JsonPropertyValue -InputObject $doctorFingerprint -Name "stabilityPasses") -ne 2 -or
        -not (Test-ExactStringArray -Left $doctorExcludedPaths -Right $expectedExcludedPaths)
    ) {
        Add-DoctorValidationError -Code "DOCTOR_FINGERPRINT_POLICY_MISMATCH" -Message "Doctor projectFingerprint does not use the exact stable Baseline copy-set contract." -JsonPath '$.projectFingerprint'
    } else {
        try {
            $currentFingerprint = Get-StableUnityCopySetFingerprint -ProjectRoot $script:NormalizedProjectRoot
            $script:Result.doctor.currentProjectFingerprint = [ordered]@{
                contractVersion = $currentFingerprint.contractVersion
                status = $currentFingerprint.status
                algorithm = $currentFingerprint.algorithm
                canonicalization = $currentFingerprint.canonicalization
                excludedTopLevelPaths = @($currentFingerprint.excludedTopLevelPaths)
                directoryCount = $currentFingerprint.directoryCount
                fileCount = $currentFingerprint.fileCount
                treeSha256 = $currentFingerprint.treeSha256
                stabilityPasses = $currentFingerprint.stabilityPasses
                error = $null
            }
            $script:Result.doctor.fingerprintMatched = (
                [int](Get-JsonPropertyValue -InputObject $doctorFingerprint -Name "directoryCount") -eq [int]$currentFingerprint.directoryCount -and
                [int](Get-JsonPropertyValue -InputObject $doctorFingerprint -Name "fileCount") -eq [int]$currentFingerprint.fileCount -and
                [string]::Equals(
                    [string](Get-JsonPropertyValue -InputObject $doctorFingerprint -Name "treeSha256"),
                    [string]$currentFingerprint.treeSha256,
                    [System.StringComparison]::Ordinal
                )
            )
            if (-not $script:Result.doctor.fingerprintMatched) {
                Add-DoctorValidationError -Code "DOCTOR_PROJECT_FINGERPRINT_MISMATCH" -Message "Current copy-included project content does not match the Doctor fingerprint." -JsonPath '$.projectFingerprint.treeSha256'
            }
        } catch {
            Add-DoctorValidationError -Code "CURRENT_PROJECT_FINGERPRINT_BLOCKED" -Message "Current project fingerprint could not be recomputed safely: $($_.Exception.Message)" -JsonPath '$.projectFingerprint'
        }
    }

    $script:Result.doctor.validationErrors = @($script:DoctorValidationErrors)
    $script:Result.doctor.accepted = $script:DoctorValidationErrors.Count -eq 0
    if ($script:Result.doctor.accepted) {
        Add-Evidence -Check "doctor" -Status "PASSED" -Source $script:Result.doctor.sourcePath -Detail "The complete Doctor schema 1.1.0 document, scanner 0.2.1 semantics, and exact current copy-set fingerprint were accepted."
    }
}

# Reads the current original ProjectVersion.txt and requires the expected editor version.
function Test-CurrentProjectVersion {
    $versionPath = Join-Path -Path $script:NormalizedProjectRoot -ChildPath "ProjectSettings\ProjectVersion.txt"
    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
        Add-Blocker -Code "PROJECT_VERSION_FILE_MISSING" -Check "unityVersion" -Path "ProjectSettings/ProjectVersion.txt" -Message "The original project version file is missing."
        return
    }

    try {
        $content = Read-TextFile -Path $versionPath
        $match = [regex]::Match($content, "(?m)^m_EditorVersion:\s*(?<version>\S+)\s*$")
        if (-not $match.Success) {
            throw "m_EditorVersion was not found."
        }
        $script:Result.unity.projectVersion = $match.Groups["version"].Value
    } catch {
        Add-Blocker -Code "PROJECT_VERSION_PARSE_FAILED" -Check "unityVersion" -Path "ProjectSettings/ProjectVersion.txt" -Message "The original project Unity version could not be parsed: $($_.Exception.Message)"
        return
    }

    if ($script:Result.unity.projectVersion -ne $script:ExpectedUnityVersion) {
        Add-Blocker -Code "PROJECT_UNITY_VERSION_MISMATCH" -Check "unityVersion" -Path "ProjectSettings/ProjectVersion.txt" -Message "The current project requires $($script:Result.unity.projectVersion), not $($script:ExpectedUnityVersion)."
        return
    }

    Add-Evidence -Check "unityVersion" -Status "PASSED" -Source "ProjectSettings/ProjectVersion.txt" -Detail "The current project requires Unity $($script:ExpectedUnityVersion)."
}

# Validates that the supplied file is the exact expected Unity.exe version outside the project.
function Test-UnityExecutable {
    param(
        [Parameter()]
        [AllowNull()]
        [string]$Path
    )

    if (-not $script:IsWindowsPlatform) {
        Add-Blocker -Code "WINDOWS_REQUIRED" -Check "unityExecutable" -Path $Path -Message "v0.1 requires Windows and a Windows Unity.exe."
        return
    }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Add-Blocker -Code "UNITY_EXECUTABLE_REQUIRED" -Check "unityExecutable" -Path $null -Message "An explicit Unity.exe path is required."
        return
    }

    try {
        $normalizedPath = Get-NormalizedAbsolutePath -Path $Path
        $script:Result.unity.executablePath = $normalizedPath
        if (Test-PathWithinRoot -Path $normalizedPath -Root $script:NormalizedProjectRoot) {
            throw "Unity executable is inside the original project."
        }
        if (-not (Test-Path -LiteralPath $normalizedPath -PathType Leaf)) {
            throw "Unity executable was not found."
        }
        if ([System.IO.Path]::GetFileName($normalizedPath) -ine "Unity.exe") {
            throw "The supplied executable filename is not Unity.exe."
        }
        $reparsePoint = Get-ReparsePointOnPath -Path $normalizedPath
        if ($null -ne $reparsePoint) {
            throw "Unity executable path traverses reparse point $reparsePoint."
        }

        $item = Get-Item -LiteralPath $normalizedPath -Force -ErrorAction Stop
        $script:Result.unity.fileVersion = $item.VersionInfo.FileVersion
        $script:Result.unity.productVersion = $item.VersionInfo.ProductVersion
        $script:Result.unity.companyName = $item.VersionInfo.CompanyName
        $script:Result.unity.executableSha256 = Get-FileSha256 -Path $normalizedPath
        $signature = Get-AuthenticodeSignature -LiteralPath $normalizedPath -ErrorAction Stop
        $script:Result.unity.signatureStatus = [string]$signature.Status
        if ($null -ne $signature.SignerCertificate) {
            $script:Result.unity.signerSubject = $signature.SignerCertificate.Subject
            $script:Result.unity.certificateThumbprint = $signature.SignerCertificate.Thumbprint
        }
        $script:Result.unity.publisherMatched = (
            $script:Result.unity.signatureStatus -eq "Valid" -and
            -not [string]::IsNullOrWhiteSpace([string]$script:Result.unity.signerSubject) -and
            [regex]::IsMatch([string]$script:Result.unity.signerSubject, "(?i)\bUnity Technologies\b")
        )
        $versionMatch = [regex]::Match(
            [string]$item.VersionInfo.ProductVersion,
            "^(?<version>\d+\.\d+\.\d+[abfp]\d+)(?:_|$|\s)"
        )
        if ($versionMatch.Success) {
            $script:Result.unity.detectedExecutableVersion = $versionMatch.Groups["version"].Value
        }
        $script:Result.unity.executableVersionMatched = (
            $versionMatch.Success -and
            $script:Result.unity.detectedExecutableVersion -eq $script:ExpectedUnityVersion
        )
    } catch {
        Add-Blocker -Code "UNITY_EXECUTABLE_INVALID" -Check "unityExecutable" -Path $Path -Message "The supplied Unity.exe is unsafe or unavailable: $($_.Exception.Message)"
        return
    }

    if (-not $script:Result.unity.executableVersionMatched) {
        Add-Blocker -Code "UNITY_EXECUTABLE_VERSION_MISMATCH" -Check "unityExecutable" -Path $script:Result.unity.executablePath -Message "Unity.exe ProductVersion must identify exactly $($script:ExpectedUnityVersion)."
        return
    }
    if ($script:Result.unity.signatureStatus -ne "Valid") {
        Add-Blocker -Code "UNITY_EXECUTABLE_SIGNATURE_INVALID" -Check "unityExecutable" -Path $script:Result.unity.executablePath -Message "Unity.exe must have a currently valid Authenticode signature; observed status $($script:Result.unity.signatureStatus)."
        return
    }
    if (-not $script:Result.unity.publisherMatched) {
        Add-Blocker -Code "UNITY_EXECUTABLE_PUBLISHER_MISMATCH" -Check "unityExecutable" -Path $script:Result.unity.executablePath -Message "Unity.exe signer subject must identify Unity Technologies."
        return
    }

    Add-Evidence -Check "unityExecutable" -Status "PASSED" -Source $script:Result.unity.executablePath -Detail "ProductVersion identifies $($script:ExpectedUnityVersion), Authenticode is valid, and the signer subject identifies Unity Technologies; certificate thumbprints are evidence, not a permanent pin."
}

# Quotes one Windows process argument without invoking a shell.
function ConvertTo-ProcessArgument {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Argument
    )

    if ($Argument.Contains('"')) {
        throw "Process arguments containing quote characters are unsupported."
    }
    if ($Argument.Length -eq 0 -or $Argument.IndexOfAny([char[]]@(" ", [char]9)) -ge 0) {
        return '"' + $Argument + '"'
    }

    return $Argument
}

# Starts only the specified Unity.exe with the fixed isolated-import argument set.
function Invoke-IsolatedUnity {
    $arguments = @(
        "-batchmode",
        "-nographics",
        "-quit",
        "-projectPath",
        $script:Result.isolation.projectCopyPath,
        "-logFile",
        $script:Result.artifacts.editorLogPath,
        "-upmLogFile",
        $script:Result.artifacts.upmLogPath
    )
    $script:Result.unity.arguments = $arguments
    $containsOriginal = $false
    foreach ($argument in $arguments) {
        if ([string]$argument -eq [string]$script:NormalizedProjectRoot) {
            $containsOriginal = $true
        }
    }
    $script:Result.unity.commandLineContainsOriginalProject = $containsOriginal
    $script:Result.isolation.originalProjectPassedToUnity = $containsOriginal
    if ($containsOriginal) {
        throw "Safety invariant failed: the Unity argument list contains the original project root."
    }

    foreach ($forbiddenArgument in @("-runTests", "-executeMethod", "-accept-apiupdate", "-ignorecompilererrors")) {
        if (@($arguments) -contains $forbiddenArgument) {
            throw "Safety invariant failed: forbidden Unity argument $forbiddenArgument is present."
        }
    }

    $processResult = Invoke-UnityProcessInJob `
        -ExecutablePath $script:Result.unity.executablePath `
        -Arguments ([string[]]$arguments) `
        -WorkingDirectory $script:SessionRoot `
        -StandardOutputPath $script:Result.unity.standardOutputPath `
        -StandardErrorPath $script:Result.unity.standardErrorPath `
        -TimeoutSeconds $TimeoutSeconds

    $script:Result.unity.processStarted = $processResult.processStarted
    $script:Result.unity.timedOut = $processResult.timedOut
    $script:Result.unity.exitCode = $processResult.exitCode
    foreach ($propertyName in @(
        "rootProcessId",
        "jobObjectCreated",
        "killOnJobCloseConfigured",
        "processAssignedToJob",
        "terminationRequested",
        "terminationReason",
        "terminationApiSucceeded",
        "rootProcessExited",
        "processTreeExitVerified",
        "activeProcessCountAfterWait",
        "treeExitWaitMilliseconds",
        "controlError"
    )) {
        $script:Result.processControl[$propertyName] = $processResult.$propertyName
    }

    if ($processResult.processStarted) {
        Add-Evidence -Check "unityProcess" -Status "OBSERVED" -Source $script:Result.unity.executablePath -Detail "Only the specified signed Unity.exe was started in a kill-on-close Job Object; Unity Hub was not invoked."
    }
    if (
        -not $processResult.jobObjectCreated -or
        -not $processResult.killOnJobCloseConfigured -or
        ($processResult.processStarted -and -not $processResult.processAssignedToJob) -or
        -not [string]::IsNullOrWhiteSpace([string]$processResult.controlError)
    ) {
        Add-Blocker -Code "UNITY_JOB_OBJECT_CONTROL_FAILED" -Check "unityProcess" -Path $script:Result.unity.executablePath -Message "Unity process-tree control was not established cleanly: $($processResult.controlError)"
    }
    if ($processResult.processStarted -and -not $processResult.processTreeExitVerified) {
        Add-Blocker -Code "UNITY_PROCESS_TREE_EXIT_UNPROVEN" -Check "unityProcess" -Path $script:Result.unity.executablePath -Message "The verifier could not prove that Unity and every assigned descendant exited within the bounded wait."
    } elseif ($processResult.processStarted) {
        Add-Evidence -Check "unityProcessTree" -Status "PASSED" -Source $script:Result.unity.executablePath -Detail "Job Object accounting reported zero active processes after bounded completion or termination."
    }
}

# Extracts concrete Unity compilation, import, version, path, and termination evidence.
function Get-EditorLogAnalysis {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedProjectPath
    )

    $analysis = [ordered]@{
        exists = $false
        byteLength = $null
        sha256 = $null
        detectedUnityVersion = $null
        versionMatched = $false
        batchModeObserved = $false
        isolatedProjectPathObserved = $false
        importCompleted = $false
        compilePhaseObserved = $false
        domainReloadCompleted = $false
        successfulQuitObserved = $false
        zeroReturnCodeObserved = $false
        compilerErrors = @()
        compilerErrorCount = 0
        compilerErrorsTruncated = $false
        failureMarkers = @()
        missingSuccessMarkers = @()
        classification = "NOT_ANALYZED"
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]$analysis
    }

    $analysis.exists = $true
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $analysis.byteLength = [long]$item.Length
    $analysis.sha256 = Get-FileSha256 -Path $Path
    $text = Read-TextFile -Path $Path
    $lines = @([regex]::Split($text, "\r?\n"))

    $versionMatch = [regex]::Match($text, "(?m)^Built from .+? Version is '(?<version>\d+\.\d+\.\d+[abfp]\d+)")
    if (-not $versionMatch.Success) {
        $versionMatch = [regex]::Match($text, "(?m)^Initialize engine version:\s*(?<version>\d+\.\d+\.\d+[abfp]\d+)")
    }
    if ($versionMatch.Success) {
        $analysis.detectedUnityVersion = $versionMatch.Groups["version"].Value
        $analysis.versionMatched = $analysis.detectedUnityVersion -eq $script:ExpectedUnityVersion
    }

    $analysis.batchModeObserved = [regex]::IsMatch($text, "(?m)^BatchMode:\s*1\b")
    $projectPathMatch = [regex]::Match($text, "(?m)^Successfully changed project path to:\s*(?<path>.+?)\s*$")
    if ($projectPathMatch.Success) {
        try {
            $observedProjectPath = Get-NormalizedAbsolutePath -Path $projectPathMatch.Groups["path"].Value
            $expectedNormalizedPath = Get-NormalizedAbsolutePath -Path $ExpectedProjectPath
            $analysis.isolatedProjectPathObserved = $observedProjectPath.Equals($expectedNormalizedPath, $script:PathComparison)
        } catch {
            $analysis.isolatedProjectPathObserved = $false
        }
    }

    $analysis.importCompleted = [regex]::IsMatch($text, "(?m)^Application\.AssetDatabase Initial Refresh End\s*$")
    $analysis.compilePhaseObserved = [regex]::IsMatch($text, "(?m)^\s*CompileScripts:\s*\d")
    $analysis.domainReloadCompleted = [regex]::IsMatch($text, "(?m)^Domain Reload Profiling:\s*\d")
    $analysis.successfulQuitObserved = (
        [regex]::IsMatch($text, "(?m)^Batchmode quit successfully invoked - shutting down!\s*$") -and
        [regex]::IsMatch($text, "(?m)^Exiting batchmode successfully now!\s*$")
    )
    $analysis.zeroReturnCodeObserved = [regex]::IsMatch($text, "(?m)^Exiting without the bug reporter\. Application will terminate with return code 0\s*$")

    $compilerErrors = New-Object System.Collections.ArrayList
    foreach ($line in $lines) {
        if ([regex]::IsMatch($line, "\berror\s+CS\d{4}\s*:", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            if ($compilerErrors.Count -lt 200) {
                [void]$compilerErrors.Add($line.Trim())
            } else {
                $analysis.compilerErrorsTruncated = $true
            }
            $analysis.compilerErrorCount++
        }
    }
    $analysis.compilerErrors = @($compilerErrors)

    $failureDefinitions = @(
        [pscustomobject]@{ code = "COMPILER_ERROR"; pattern = "\berror\s+CS\d{4}\s*:" },
        [pscustomobject]@{ code = "SCRIPTS_HAVE_COMPILER_ERRORS"; pattern = "Scripts have compiler errors" },
        [pscustomobject]@{ code = "COMPILATION_FAILED"; pattern = "(?:Compilation failed|Failed to compile)" },
        [pscustomobject]@{ code = "BATCHMODE_ABORTED"; pattern = "Aborting batchmode due to failure" },
        [pscustomobject]@{ code = "FATAL_ERROR"; pattern = "Fatal Error!" },
        [pscustomobject]@{ code = "CRASH"; pattern = "^Crash!!!\s*$" },
        [pscustomobject]@{ code = "NONZERO_RETURN_CODE_IN_LOG"; pattern = "Application will terminate with return code [1-9]\d*" },
        [pscustomobject]@{ code = "PACKAGE_RESOLUTION_FAILED"; pattern = "(?:An error occurred while resolving packages|Package resolution failed)" }
    )
    $failureMarkers = New-Object System.Collections.ArrayList
    foreach ($definition in $failureDefinitions) {
        $matchingLine = $null
        foreach ($line in $lines) {
            if ([regex]::IsMatch($line, $definition.pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                $matchingLine = $line.Trim()
                break
            }
        }
        if ($null -ne $matchingLine) {
            [void]$failureMarkers.Add([ordered]@{
                code = $definition.code
                line = $matchingLine
            })
        }
    }
    if ($null -ne $analysis.detectedUnityVersion -and -not $analysis.versionMatched) {
        [void]$failureMarkers.Add([ordered]@{
            code = "UNITY_LOG_VERSION_MISMATCH"
            line = "Editor.log identifies Unity $($analysis.detectedUnityVersion)."
        })
    }
    $analysis.failureMarkers = @($failureMarkers)

    $missingMarkers = New-Object System.Collections.ArrayList
    foreach ($requirement in @(
        [pscustomobject]@{ name = "unityVersion"; met = $analysis.versionMatched },
        [pscustomobject]@{ name = "batchMode"; met = $analysis.batchModeObserved },
        [pscustomobject]@{ name = "isolatedProjectPath"; met = $analysis.isolatedProjectPathObserved },
        [pscustomobject]@{ name = "initialAssetDatabaseRefresh"; met = $analysis.importCompleted },
        [pscustomobject]@{ name = "compileScriptsPhase"; met = $analysis.compilePhaseObserved },
        [pscustomobject]@{ name = "domainReload"; met = $analysis.domainReloadCompleted },
        [pscustomobject]@{ name = "successfulBatchmodeQuit"; met = $analysis.successfulQuitObserved },
        [pscustomobject]@{ name = "loggedReturnCodeZero"; met = $analysis.zeroReturnCodeObserved }
    )) {
        if (-not $requirement.met) {
            [void]$missingMarkers.Add($requirement.name)
        }
    }
    $analysis.missingSuccessMarkers = @($missingMarkers)

    if ($analysis.failureMarkers.Count -gt 0) {
        $analysis.classification = "FAILURE"
    } elseif ($analysis.missingSuccessMarkers.Count -eq 0) {
        $analysis.classification = "SUCCESS"
    } else {
        $analysis.classification = "INCONCLUSIVE"
    }

    return [pscustomobject]$analysis
}

# Maps process and Editor.log evidence to the script-compilation verification state.
function Set-CompilationVerification {
    if (-not $script:Result.unity.processStarted) {
        $script:Result.verification.scriptCompilation.status = "NOT_VERIFIED"
        $script:Result.verification.scriptCompilation.reason = "Unity.exe did not start."
        return
    }
    if ($script:Result.unity.timedOut) {
        $script:Result.verification.scriptCompilation.status = "NOT_VERIFIED"
        $script:Result.verification.scriptCompilation.reason = "Unity exceeded the configured timeout and was terminated."
        Add-Blocker -Code "UNITY_PROCESS_TIMEOUT" -Check "scriptCompilation" -Path $script:Result.unity.executablePath -Message "Unity did not complete within $TimeoutSeconds seconds."
        return
    }
    if (-not $script:Result.editorLog.exists) {
        $script:Result.verification.scriptCompilation.status = "NOT_VERIFIED"
        $script:Result.verification.scriptCompilation.reason = "Editor.log was not created."
        Add-Blocker -Code "EDITOR_LOG_MISSING" -Check "scriptCompilation" -Path $script:Result.artifacts.editorLogPath -Message "Unity did not create the required Editor.log evidence."
        return
    }

    if ($null -ne $script:Result.unity.exitCode -and [int]$script:Result.unity.exitCode -ne 0) {
        $script:Result.verification.scriptCompilation.status = "VERIFIED_FAILURE"
        $script:Result.verification.scriptCompilation.reason = "Unity exited with concrete nonzero exit code $($script:Result.unity.exitCode)."
        Add-Evidence -Check "scriptCompilation" -Status "FAILED" -Source $script:Result.artifacts.editorLogPath -Detail $script:Result.verification.scriptCompilation.reason
        return
    }
    if ($script:Result.editorLog.classification -eq "FAILURE") {
        $script:Result.verification.scriptCompilation.status = "VERIFIED_FAILURE"
        $script:Result.verification.scriptCompilation.reason = "Editor.log contains explicit compiler, fatal, crash, package-resolution, or nonzero-return evidence."
        Add-Evidence -Check "scriptCompilation" -Status "FAILED" -Source $script:Result.artifacts.editorLogPath -Detail $script:Result.verification.scriptCompilation.reason
        return
    }
    if ($script:Result.editorLog.classification -eq "SUCCESS" -and [int]$script:Result.unity.exitCode -eq 0) {
        $script:Result.verification.scriptCompilation.status = "VERIFIED_SUCCESS"
        $script:Result.verification.scriptCompilation.reason = "Unity exit code 0 and Editor.log explicitly confirm the expected version, isolated project, import refresh, CompileScripts phase, domain reload, and successful batch-mode exit."
        Add-Evidence -Check "scriptCompilation" -Status "PASSED" -Source $script:Result.artifacts.editorLogPath -Detail $script:Result.verification.scriptCompilation.reason
        return
    }

    $script:Result.verification.scriptCompilation.status = "NOT_VERIFIED"
    $script:Result.verification.scriptCompilation.reason = "Editor.log lacks one or more required positive markers; success was not inferred."
    Add-Blocker -Code "EDITOR_LOG_INCONCLUSIVE" -Check "scriptCompilation" -Path $script:Result.artifacts.editorLogPath -Message "Editor.log is inconclusive. Missing markers: $([string]::Join(', ', [string[]]@($script:Result.editorLog.missingSuccessMarkers)))"
}

# Stores concise before/after copy-set snapshot summaries in the public result.
function Set-IntegritySnapshotSummaries {
    if ($null -ne $script:OriginalSnapshotBefore) {
        $script:Result.originalProjectIntegrity.beforeDirectoryCount = $script:OriginalSnapshotBefore.directoryCount
        $script:Result.originalProjectIntegrity.beforeFileCount = $script:OriginalSnapshotBefore.fileCount
        $script:Result.originalProjectIntegrity.beforeTreeSha256 = $script:OriginalSnapshotBefore.treeSha256
    }
    if ($null -ne $script:OriginalSnapshotAfter) {
        $script:Result.originalProjectIntegrity.afterDirectoryCount = $script:OriginalSnapshotAfter.directoryCount
        $script:Result.originalProjectIntegrity.afterFileCount = $script:OriginalSnapshotAfter.fileCount
        $script:Result.originalProjectIntegrity.afterTreeSha256 = $script:OriginalSnapshotAfter.treeSha256
    }
}

# Stores concise before/after .git metadata snapshot summaries in the public result.
function Set-GitMetadataSnapshotSummaries {
    if ($null -ne $script:GitMetadataSnapshotBefore) {
        $script:Result.gitMetadataIntegrity.presentBefore = [bool]$script:GitMetadataSnapshotBefore.present
        $script:Result.gitMetadataIntegrity.entryTypeBefore = [string]$script:GitMetadataSnapshotBefore.entryType
        $script:Result.gitMetadataIntegrity.beforeDirectoryCount = [int]$script:GitMetadataSnapshotBefore.directoryCount
        $script:Result.gitMetadataIntegrity.beforeFileCount = [int]$script:GitMetadataSnapshotBefore.fileCount
        $script:Result.gitMetadataIntegrity.beforeTreeSha256 = [string]$script:GitMetadataSnapshotBefore.treeSha256
    }
    if ($null -ne $script:GitMetadataSnapshotAfter) {
        $script:Result.gitMetadataIntegrity.presentAfter = [bool]$script:GitMetadataSnapshotAfter.present
        $script:Result.gitMetadataIntegrity.entryTypeAfter = [string]$script:GitMetadataSnapshotAfter.entryType
        $script:Result.gitMetadataIntegrity.afterDirectoryCount = [int]$script:GitMetadataSnapshotAfter.directoryCount
        $script:Result.gitMetadataIntegrity.afterFileCount = [int]$script:GitMetadataSnapshotAfter.fileCount
        $script:Result.gitMetadataIntegrity.afterTreeSha256 = [string]$script:GitMetadataSnapshotAfter.treeSha256
    }
}

# Copies one Git metadata assessment into the stable JSON result shape.
function Set-GitMetadataAssessmentResult {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Assessment
    )

    $script:Result.gitMetadataIntegrity.status = [string]$Assessment.status
    $script:Result.gitMetadataIntegrity.unchanged = [bool]$Assessment.unchanged
    $script:Result.gitMetadataIntegrity.ambientChangesAllowed = [bool]$Assessment.ambientChangesAllowed
    $script:Result.gitMetadataIntegrity.allowedAdditionPrefix = [string]$Assessment.allowedAdditionPrefix
    $script:Result.gitMetadataIntegrity.rootStateChanged = [bool]$Assessment.rootStateChanged
    $script:Result.gitMetadataIntegrity.addedDirectories = @($Assessment.addedDirectories)
    $script:Result.gitMetadataIntegrity.removedDirectories = @($Assessment.removedDirectories)
    $script:Result.gitMetadataIntegrity.addedFiles = @($Assessment.addedFiles)
    $script:Result.gitMetadataIntegrity.removedFiles = @($Assessment.removedFiles)
    $script:Result.gitMetadataIntegrity.changedFiles = @($Assessment.changedFiles)
    $script:Result.gitMetadataIntegrity.disallowedAddedDirectories = @($Assessment.disallowedAddedDirectories)
    $script:Result.gitMetadataIntegrity.disallowedAddedFiles = @($Assessment.disallowedAddedFiles)
}

# Returns true only for Git metadata states that preserve the v0.1.2 integrity contract.
function Test-GitMetadataIntegrityAccepted {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status
    )

    return @("NOT_PRESENT", "UNCHANGED", "AMBIENT_CODEX_CHECKPOINTS_ONLY") -contains $Status
}

# Captures two pre-run Git metadata snapshots and permits only checkpoint-namespace additions between them.
function Initialize-GitMetadataIntegrity {
    try {
        $script:GitMetadataSnapshotBefore = Get-BaselineGitMetadataSnapshot -ProjectRoot $script:NormalizedProjectRoot
        Set-GitMetadataSnapshotSummaries
        $stabilitySnapshot = Get-BaselineGitMetadataSnapshot -ProjectRoot $script:NormalizedProjectRoot
        $assessment = Get-BaselineGitMetadataAssessment -Before $script:GitMetadataSnapshotBefore -After $stabilitySnapshot
        if (-not (Test-GitMetadataIntegrityAccepted -Status $assessment.status)) {
            $script:Result.gitMetadataIntegrity.status = "BLOCKED"
            Add-Blocker -Code "GIT_METADATA_SNAPSHOT_UNSTABLE" -Check "gitMetadataIntegrity" -Path (Join-Path $script:NormalizedProjectRoot ".git") -Message "Git metadata changed outside the allowed Codex checkpoint-addition namespace during preflight."
            return
        }

        $script:Result.preflight.gitMetadataSnapshotAccepted = $true
        $detail = if ($assessment.status -eq "AMBIENT_CODEX_CHECKPOINTS_ONLY") {
            "Preflight observed only added paths under the Codex checkpoint namespace; no existing Git metadata changed or disappeared."
        } else {
            "Two preflight Git metadata snapshots were identical or .git was absent."
        }
        Add-Evidence -Check "gitMetadataBefore" -Status "OBSERVED" -Source (Join-Path $script:NormalizedProjectRoot ".git") -Detail $detail
    } catch {
        $script:Result.gitMetadataIntegrity.status = "BLOCKED"
        Add-Blocker -Code "GIT_METADATA_PRE_SNAPSHOT_FAILED" -Check "gitMetadataIntegrity" -Path (Join-Path $script:NormalizedProjectRoot ".git") -Message "The in-project Git metadata could not be hashed safely: $($_.Exception.Message)"
    }
}

# Finalizes blockers, evidence, untouched scope rows, and exactly one final status.
function Complete-VerificationResult {
    $script:Result.doctor.validationErrors = @($script:DoctorValidationErrors)
    $script:Result.blockers = @($script:Blockers)
    $script:Result.evidence = @($script:Evidence)

    if (
        $script:Result.originalProjectIntegrity.status -eq "CHANGED" -or
        $script:Result.gitMetadataIntegrity.status -eq "CHANGED"
    ) {
        $script:Result.finalStatus = "ORIGINAL_PROJECT_CHANGED"
    } elseif (
        $script:Result.originalProjectIntegrity.status -eq "BLOCKED" -or
        $script:Result.gitMetadataIntegrity.status -eq "BLOCKED"
    ) {
        $script:Result.finalStatus = "VERIFICATION_BLOCKED"
    } elseif ($script:Result.verification.scriptCompilation.status -eq "VERIFIED_FAILURE") {
        $script:Result.finalStatus = "BASELINE_FAILED"
    } elseif ($script:Blockers.Count -gt 0) {
        $script:Result.finalStatus = "VERIFICATION_BLOCKED"
    } elseif (
        $script:Result.verification.scriptCompilation.status -eq "VERIFIED_SUCCESS" -and
        $script:Result.originalProjectIntegrity.status -eq "UNCHANGED" -and
        (Test-GitMetadataIntegrityAccepted -Status $script:Result.gitMetadataIntegrity.status)
    ) {
        $script:Result.finalStatus = "BASELINE_VERIFIED"
    } else {
        $script:Result.finalStatus = "VERIFICATION_BLOCKED"
    }
}

# Writes the finalized JSON artifact outside the project and returns the exact stdout JSON.
function ConvertTo-FinalJson {
    Complete-VerificationResult
    $json = if ($Pretty) {
        ConvertTo-Json -InputObject $script:Result -Depth 30
    } else {
        ConvertTo-Json -InputObject $script:Result -Depth 30 -Compress
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$script:Result.artifacts.resultPath)) {
        try {
            [void][System.IO.File]::WriteAllText($script:Result.artifacts.resultPath, $json, $script:Utf8NoBom)
            $script:Result.artifacts.resultWritten = $true
            Complete-VerificationResult
            $json = if ($Pretty) {
                ConvertTo-Json -InputObject $script:Result -Depth 30
            } else {
                ConvertTo-Json -InputObject $script:Result -Depth 30 -Compress
            }
            [void][System.IO.File]::WriteAllText($script:Result.artifacts.resultPath, $json, $script:Utf8NoBom)
        } catch {
            $script:Result.artifacts.resultWritten = $false
            Add-Blocker -Code "RESULT_ARTIFACT_WRITE_FAILED" -Check "artifacts" -Path $script:Result.artifacts.resultPath -Message "The JSON result artifact could not be written: $($_.Exception.Message)"
            Complete-VerificationResult
            $json = if ($Pretty) {
                ConvertTo-Json -InputObject $script:Result -Depth 30
            } else {
                ConvertTo-Json -InputObject $script:Result -Depth 30 -Compress
            }
        }
    }

    return $json
}

try {
    try {
        foreach ($libraryPath in @(
            $script:ValidatorLibraryPath,
            $script:ProcessLibraryPath,
            $script:EditorLogLibraryPath,
            $script:GitIntegrityLibraryPath,
            $script:FingerprintLibraryPath
        )) {
            if (-not (Test-Path -LiteralPath $libraryPath -PathType Leaf)) {
                throw "Required verifier library was not found: $libraryPath"
            }
            . $libraryPath
        }
    } catch {
        Add-Blocker -Code "VERIFIER_LIBRARY_LOAD_FAILED" -Check "verifier" -Path $null -Message "A trusted verifier library could not be loaded: $($_.Exception.Message)"
    }

    try {
        $script:NormalizedProjectRoot = Get-NormalizedAbsolutePath -Path $ProjectRoot
        $script:Result.projectRoot = $script:NormalizedProjectRoot
        if (-not (Test-Path -LiteralPath $script:NormalizedProjectRoot -PathType Container)) {
            throw "ProjectRoot is not an existing directory."
        }
        $rootReparsePoint = Get-ReparsePointOnPath -Path $script:NormalizedProjectRoot
        if ($null -ne $rootReparsePoint) {
            throw "ProjectRoot traverses reparse point $rootReparsePoint."
        }
    } catch {
        Add-Blocker -Code "PROJECT_ROOT_INVALID" -Check "projectRoot" -Path $ProjectRoot -Message "The original project root is unsafe or unavailable: $($_.Exception.Message)"
    }

    if ($null -ne $script:NormalizedProjectRoot -and (Test-Path -LiteralPath $script:NormalizedProjectRoot -PathType Container)) {
        try {
            Initialize-ArtifactSession -RequestedRoot $ArtifactsRoot
        } catch {
            Add-Blocker -Code "ARTIFACT_SESSION_CREATION_FAILED" -Check "artifacts" -Path $ArtifactsRoot -Message "An external artifact session could not be created: $($_.Exception.Message)"
        }

        if ($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 86400) {
            Add-Blocker -Code "TIMEOUT_RANGE_INVALID" -Check "unityProcess" -Path $null -Message "TimeoutSeconds must be between 1 and 86400."
        }

        Test-SourceProjectEditorPreflight
        Test-DoctorResult -Path $DoctorResultPath
        Test-CurrentProjectVersion
        Test-UnityExecutable -Path $UnityExecutable
        if ($script:Blockers.Count -eq 0) {
            $script:Result.preflight.trustedPathsWithoutReparse = $true
        }
        Test-LocalPackageDependencySafety
    }

    if ($script:Blockers.Count -eq 0) {
        Initialize-GitMetadataIntegrity
    }

    if ($script:Blockers.Count -eq 0) {
        try {
            $script:OriginalSnapshotBefore = Get-ProjectTreeSnapshot -Root $script:NormalizedProjectRoot
            Set-IntegritySnapshotSummaries
            $stabilitySnapshot = Get-ProjectTreeSnapshot -Root $script:NormalizedProjectRoot
            $stabilityComparison = Compare-ProjectTreeSnapshots -Before $script:OriginalSnapshotBefore -After $stabilitySnapshot
            if (-not $stabilityComparison.unchanged) {
                Add-Blocker -Code "SOURCE_SNAPSHOT_UNSTABLE" -Check "preflight" -Path $script:NormalizedProjectRoot -Message "Two consecutive Baseline copy-set snapshots differed before isolation."
            } else {
                $script:Result.preflight.sourceSnapshotStable = $true
                Add-Evidence -Check "originalIntegrityBefore" -Status "OBSERVED" -Source $script:NormalizedProjectRoot -Detail "Captured two identical Doctor/Baseline copy-set directory/file/length/SHA-256 snapshots before copying."
            }
        } catch {
            Add-Blocker -Code "ORIGINAL_PRE_SNAPSHOT_FAILED" -Check "originalIntegrity" -Path $script:NormalizedProjectRoot -Message "The original pre-run Baseline copy set could not be hashed safely: $($_.Exception.Message)"
            $script:Result.originalProjectIntegrity.status = "BLOCKED"
        }
    }

    if ($null -ne $script:OriginalSnapshotBefore) {
        try {
            if ($script:Blockers.Count -eq 0) {
                $copyResult = Copy-ProjectToIsolation -Snapshot $script:OriginalSnapshotBefore -Destination $script:Result.isolation.projectCopyPath
                $script:Result.isolation.copyStatus = "COPIED"
                $script:Result.isolation.copiedDirectoryCount = $copyResult.copiedDirectoryCount
                $script:Result.isolation.copiedFileCount = $copyResult.copiedFileCount
                Add-Evidence -Check "isolation" -Status "PASSED" -Source $script:Result.isolation.projectCopyPath -Detail "Project source and configuration were copied without generated or tooling trees."

                Test-LocalPackageDependencySafety -ValidateIsolatedCopy
                if ($script:Blockers.Count -eq 0) {
                    $isolatedFingerprint = Get-StableUnityCopySetFingerprint -ProjectRoot $script:Result.isolation.projectCopyPath
                    $script:Result.isolation.copyFingerprint = [ordered]@{
                        contractVersion = $isolatedFingerprint.contractVersion
                        status = $isolatedFingerprint.status
                        algorithm = $isolatedFingerprint.algorithm
                        canonicalization = $isolatedFingerprint.canonicalization
                        excludedTopLevelPaths = @($isolatedFingerprint.excludedTopLevelPaths)
                        directoryCount = $isolatedFingerprint.directoryCount
                        fileCount = $isolatedFingerprint.fileCount
                        treeSha256 = $isolatedFingerprint.treeSha256
                        stabilityPasses = $isolatedFingerprint.stabilityPasses
                        error = $null
                    }
                    if (
                        -not [string]::Equals([string]$isolatedFingerprint.treeSha256, [string]$script:Result.doctor.currentProjectFingerprint.treeSha256, [System.StringComparison]::Ordinal) -or
                        [int]$isolatedFingerprint.directoryCount -ne [int]$script:Result.doctor.currentProjectFingerprint.directoryCount -or
                        [int]$isolatedFingerprint.fileCount -ne [int]$script:Result.doctor.currentProjectFingerprint.fileCount
                    ) {
                        Add-Blocker -Code "ISOLATED_COPY_FINGERPRINT_MISMATCH" -Check "isolation" -Path $script:Result.isolation.projectCopyPath -Message "The isolated copy does not match the accepted current-project fingerprint."
                    } else {
                        Add-Evidence -Check "isolationFingerprint" -Status "PASSED" -Source $script:Result.isolation.projectCopyPath -Detail "The isolated copy has the same canonical file-set SHA-256 fingerprint as the accepted Doctor-bound source content."
                    }
                }

                if ($script:Blockers.Count -eq 0) {
                    $preLaunchSnapshot = Get-ProjectTreeSnapshot -Root $script:NormalizedProjectRoot
                    $preLaunchComparison = Compare-ProjectTreeSnapshots -Before $script:OriginalSnapshotBefore -After $preLaunchSnapshot
                    if (-not $preLaunchComparison.unchanged) {
                        $script:Result.preflight.sourceSnapshotStable = $false
                        Add-Blocker -Code "SOURCE_CHANGED_DURING_ISOLATION" -Check "preflight" -Path $script:NormalizedProjectRoot -Message "The source project changed while the isolated copy was being prepared; Unity was not started."
                    }
                }

                if ($script:Blockers.Count -eq 0 -and $null -ne $script:GitMetadataSnapshotBefore) {
                    $preLaunchGitSnapshot = Get-BaselineGitMetadataSnapshot -ProjectRoot $script:NormalizedProjectRoot
                    $preLaunchGitAssessment = Get-BaselineGitMetadataAssessment -Before $script:GitMetadataSnapshotBefore -After $preLaunchGitSnapshot
                    if (-not (Test-GitMetadataIntegrityAccepted -Status $preLaunchGitAssessment.status)) {
                        $script:Result.preflight.gitMetadataSnapshotAccepted = $false
                        Add-Blocker -Code "GIT_METADATA_CHANGED_DURING_ISOLATION" -Check "preflight" -Path (Join-Path $script:NormalizedProjectRoot ".git") -Message "Git metadata changed outside the allowed Codex checkpoint-addition namespace while the isolated copy was being prepared; Unity was not started."
                    }
                }

                if ($script:Blockers.Count -eq 0) {
                    Invoke-IsolatedUnity
                    $script:Result.editorLog = Get-UnityEditorLogAnalysis -Path $script:Result.artifacts.editorLogPath -ExpectedProjectPath $script:Result.isolation.projectCopyPath -ExpectedUnityVersion $script:ExpectedUnityVersion
                    Set-CompilationVerification
                }
            }
        } catch {
            if ($script:Result.isolation.copyStatus -eq "NOT_STARTED") {
                $script:Result.isolation.copyStatus = "FAILED"
            }
            Add-Blocker -Code "ISOLATED_VERIFICATION_ERROR" -Check "isolation" -Path $script:Result.isolation.projectCopyPath -Message "The isolated copy or Unity process failed: $($_.Exception.Message)"
        } finally {
            try {
                $script:OriginalSnapshotAfter = Get-ProjectTreeSnapshot -Root $script:NormalizedProjectRoot
                Set-IntegritySnapshotSummaries
                $comparison = Compare-ProjectTreeSnapshots -Before $script:OriginalSnapshotBefore -After $script:OriginalSnapshotAfter
                $script:Result.originalProjectIntegrity.unchanged = $comparison.unchanged
                $script:Result.originalProjectIntegrity.addedDirectories = $comparison.addedDirectories
                $script:Result.originalProjectIntegrity.removedDirectories = $comparison.removedDirectories
                $script:Result.originalProjectIntegrity.addedFiles = $comparison.addedFiles
                $script:Result.originalProjectIntegrity.removedFiles = $comparison.removedFiles
                $script:Result.originalProjectIntegrity.changedFiles = $comparison.changedFiles
                if ($comparison.unchanged) {
                    $script:Result.originalProjectIntegrity.status = "UNCHANGED"
                    Add-Evidence -Check "originalIntegrityAfter" -Status "PASSED" -Source $script:NormalizedProjectRoot -Detail "The original Doctor/Baseline copy-set directory list, file list, lengths, per-file SHA-256 values, and tree SHA-256 are identical."
                } else {
                    $script:Result.originalProjectIntegrity.status = "CHANGED"
                    Add-Evidence -Check "originalIntegrityAfter" -Status "FAILED" -Source $script:NormalizedProjectRoot -Detail "The original Baseline copy set differs from its pre-run snapshot. No automatic rollback was attempted."
                }
            } catch {
                $script:Result.originalProjectIntegrity.status = "BLOCKED"
                Add-Blocker -Code "ORIGINAL_POST_SNAPSHOT_FAILED" -Check "originalIntegrity" -Path $script:NormalizedProjectRoot -Message "The original post-run Baseline copy set could not be hashed safely: $($_.Exception.Message)"
            }

            if ($null -ne $script:GitMetadataSnapshotBefore) {
                try {
                    $script:GitMetadataSnapshotAfter = Get-BaselineGitMetadataSnapshot -ProjectRoot $script:NormalizedProjectRoot
                    Set-GitMetadataSnapshotSummaries
                    $gitAssessment = Get-BaselineGitMetadataAssessment -Before $script:GitMetadataSnapshotBefore -After $script:GitMetadataSnapshotAfter
                    Set-GitMetadataAssessmentResult -Assessment $gitAssessment
                    if ($gitAssessment.status -eq "CHANGED") {
                        Add-Evidence -Check "gitMetadataAfter" -Status "FAILED" -Source (Join-Path $script:NormalizedProjectRoot ".git") -Detail "Git metadata changed outside the allowed Codex checkpoint-addition namespace. No automatic rollback was attempted."
                    } elseif ($gitAssessment.status -eq "AMBIENT_CODEX_CHECKPOINTS_ONLY") {
                        Add-Evidence -Check "gitMetadataAfter" -Status "OBSERVED" -Source (Join-Path $script:NormalizedProjectRoot ".git") -Detail "Only new paths under .git/refs/codex/turn-diffs/checkpoints/ were observed; existing Git metadata was unchanged and the additions were classified as ambient."
                    } elseif ($gitAssessment.status -eq "NOT_PRESENT") {
                        Add-Evidence -Check "gitMetadataAfter" -Status "OBSERVED" -Source (Join-Path $script:NormalizedProjectRoot ".git") -Detail "The source project had no in-project .git metadata before or after verification."
                    } else {
                        Add-Evidence -Check "gitMetadataAfter" -Status "PASSED" -Source (Join-Path $script:NormalizedProjectRoot ".git") -Detail "The in-project .git directory/file list, lengths, and SHA-256 values were unchanged."
                    }
                } catch {
                    $script:Result.gitMetadataIntegrity.status = "BLOCKED"
                    Add-Blocker -Code "GIT_METADATA_POST_SNAPSHOT_FAILED" -Check "gitMetadataIntegrity" -Path (Join-Path $script:NormalizedProjectRoot ".git") -Message "The post-run Git metadata could not be hashed safely: $($_.Exception.Message)"
                }
            }
        }
    }
} catch {
    Add-Blocker -Code "VERIFIER_UNEXPECTED_ERROR" -Check "verifier" -Path $null -Message "The verifier encountered an unexpected internal error: $($_.Exception.Message)"
}

foreach ($scopeName in @("tests", "playerBuild", "playMode", "runtime")) {
    Add-Evidence -Check $scopeName -Status "NOT_VERIFIED" -Source "v0.1.2 scope" -Detail $script:Result.verification.$scopeName.reason
}

$finalJson = ConvertTo-FinalJson
[Console]::Out.WriteLine($finalJson)
