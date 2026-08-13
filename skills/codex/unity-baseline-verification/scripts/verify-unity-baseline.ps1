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
$script:SchemaVersion = "1.0.0"
$script:VerifierVersion = "0.1.0"
$script:ExpectedDoctorSchemaVersion = "1.0.0"
$script:ExpectedDoctorScannerVersion = "0.2.0"
$script:ExpectedUnityVersion = "6000.0.69f1"
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
    ".agents",
    ".codex",
    ".git",
    ".hg",
    ".idea",
    ".svn",
    ".vs",
    "Build",
    "Builds",
    "Library",
    "Logs",
    "Obj",
    "Temp",
    "UserSettings"
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
            schemaVersion = $null
            scannerVersion = $null
            projectRoot = $null
            finalStatus = $null
            warningCount = 0
            warnings = @()
            validationErrors = @()
            accepted = $false
        }
        unity = [ordered]@{
            executablePath = $null
            executableSha256 = $null
            fileVersion = $null
            productVersion = $null
            detectedExecutableVersion = $null
            executableVersionMatched = $false
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
        isolation = [ordered]@{
            artifactsRoot = $null
            sessionRoot = $null
            projectCopyPath = $null
            copyStatus = "NOT_STARTED"
            copiedDirectoryCount = 0
            copiedFileCount = 0
            excludedTopLevelPaths = @($script:ExcludedTopLevelNames)
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
        [string]$Message
    )

    [void]$script:DoctorValidationErrors.Add([ordered]@{
        code = $Code
        message = $Message
    })
    Add-Blocker -Code $Code -Check "doctor" -Path $script:Result.doctor.sourcePath -Message $Message
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

# Builds a complete directory and file SHA-256 snapshot without following links.
function Get-ProjectTreeSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $normalizedRoot = Get-NormalizedAbsolutePath -Path $Root
    $rootEntry = Get-Item -LiteralPath $normalizedRoot -Force -ErrorAction Stop
    if (-not $rootEntry.PSIsContainer) {
        throw "Snapshot root is not a directory: $normalizedRoot"
    }
    if (($rootEntry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Snapshot root is a reparse point: $normalizedRoot"
    }

    $directories = New-Object System.Collections.ArrayList
    $files = New-Object System.Collections.ArrayList
    $queue = New-Object "System.Collections.Generic.Queue[string]"
    $queue.Enqueue($normalizedRoot)

    while ($queue.Count -gt 0) {
        $currentDirectory = $queue.Dequeue()
        $entries = @(
            Get-ChildItem -LiteralPath $currentDirectory -Force -ErrorAction Stop |
                Sort-Object -Property FullName
        )
        foreach ($entry in $entries) {
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                $relativeReparsePath = ConvertTo-ProjectRelativePath -Path $entry.FullName
                throw "Project tree contains a reparse point: $relativeReparsePath"
            }

            $relativePath = ConvertTo-ProjectRelativePath -Path $entry.FullName
            if ($entry.PSIsContainer) {
                [void]$directories.Add($relativePath)
                $queue.Enqueue($entry.FullName)
                continue
            }

            if (-not (Test-Path -LiteralPath $entry.FullName -PathType Leaf)) {
                throw "Project tree contains an unsupported filesystem entry: $relativePath"
            }

            [void]$files.Add([pscustomobject][ordered]@{
                path = $relativePath
                length = [long]$entry.Length
                sha256 = Get-FileSha256 -Path $entry.FullName
            })
        }
    }

    $sortedDirectories = @($directories | Sort-Object)
    $sortedFiles = @($files | Sort-Object -Property path)
    $canonicalLines = New-Object System.Collections.ArrayList
    foreach ($directory in $sortedDirectories) {
        [void]$canonicalLines.Add("D|$directory")
    }
    foreach ($file in $sortedFiles) {
        [void]$canonicalLines.Add("F|$($file.path)|$($file.length)|$($file.sha256)")
    }
    $canonicalText = [string]::Join([char]10, [string[]]@($canonicalLines))

    return [pscustomobject][ordered]@{
        directories = $sortedDirectories
        files = $sortedFiles
        directoryCount = $sortedDirectories.Count
        fileCount = $sortedFiles.Count
        treeSha256 = Get-StringSha256 -Text $canonicalText
    }
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

# Validates local file package references so Unity cannot escape the isolated project.
function Test-LocalPackageDependencySafety {
    $manifestPath = Join-Path -Path $script:NormalizedProjectRoot -ChildPath "Packages\manifest.json"
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
        return
    }

    $manifestDirectory = Split-Path -Parent $manifestPath
    foreach ($property in @($dependencies.PSObject.Properties)) {
        $reference = [string]$property.Value
        if (-not $reference.StartsWith("file:", [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $rawPath = $reference.Substring(5)
        try {
            $decodedPath = [System.Uri]::UnescapeDataString($rawPath).Replace("/", "\")
            $resolvedPath = if ([System.IO.Path]::IsPathRooted($decodedPath)) {
                Get-NormalizedAbsolutePath -Path $decodedPath
            } else {
                Get-NormalizedAbsolutePath -Path (Join-Path -Path $manifestDirectory -ChildPath $decodedPath)
            }
        } catch {
            Add-Blocker -Code "LOCAL_PACKAGE_PATH_INVALID" -Check "isolation" -Path "Packages/manifest.json" -Message "Local package $($property.Name) has an invalid file reference: $reference"
            continue
        }

        if (-not (Test-PathWithinRoot -Path $resolvedPath -Root $script:NormalizedProjectRoot)) {
            Add-Blocker -Code "LOCAL_PACKAGE_OUTSIDE_PROJECT" -Check "isolation" -Path "Packages/manifest.json" -Message "Local package $($property.Name) resolves outside the original and isolated project boundary: $reference"
            continue
        }

        $relativePath = ConvertTo-ProjectRelativePath -Path $resolvedPath
        if (Test-ExcludedProjectPath -RelativePath $relativePath) {
            Add-Blocker -Code "LOCAL_PACKAGE_EXCLUDED_FROM_COPY" -Check "isolation" -Path "Packages/manifest.json" -Message "Local package $($property.Name) resolves into excluded path $relativePath."
        }
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
        Add-Evidence -Check "artifacts" -Status "PASSED" -Source $script:SessionRoot -Detail "All logs, results, and the isolated project are located outside the original project."
    }
}

# Validates the unity-project-doctor v0.2 JSON consumer contract.
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

    foreach ($requiredProperty in @(
        "schemaVersion",
        "scannerVersion",
        "projectRoot",
        "projectDetection",
        "unityEditorVersion",
        "git",
        "packages",
        "assemblies",
        "buildSettings",
        "agentsFiles",
        "projectSkills",
        "trackedGeneratedFolderPaths",
        "warnings",
        "blockedChecks",
        "dynamicVerification",
        "finalStatus",
        "evidence"
    )) {
        if (-not (Test-JsonProperty -InputObject $doctorResult -Name $requiredProperty)) {
            Add-DoctorValidationError -Code ("DOCTOR_REQUIRED_FIELD_MISSING_" + $requiredProperty.ToUpperInvariant()) -Message "Doctor JSON is missing required top-level field $requiredProperty."
        }
    }

    $schemaVersion = Get-JsonPropertyValue -InputObject $doctorResult -Name "schemaVersion"
    $scannerVersion = Get-JsonPropertyValue -InputObject $doctorResult -Name "scannerVersion"
    $doctorProjectRoot = Get-JsonPropertyValue -InputObject $doctorResult -Name "projectRoot"
    $finalStatus = Get-JsonPropertyValue -InputObject $doctorResult -Name "finalStatus"
    $projectDetection = Get-JsonPropertyValue -InputObject $doctorResult -Name "projectDetection"
    $unityEditorVersion = Get-JsonPropertyValue -InputObject $doctorResult -Name "unityEditorVersion"
    $blockedChecks = @(Get-JsonPropertyValue -InputObject $doctorResult -Name "blockedChecks")
    $warnings = @(Get-JsonPropertyValue -InputObject $doctorResult -Name "warnings")
    $dynamicVerification = Get-JsonPropertyValue -InputObject $doctorResult -Name "dynamicVerification"
    $evidence = @(Get-JsonPropertyValue -InputObject $doctorResult -Name "evidence")

    $script:Result.doctor.schemaVersion = $schemaVersion
    $script:Result.doctor.scannerVersion = $scannerVersion
    $script:Result.doctor.projectRoot = $doctorProjectRoot
    $script:Result.doctor.finalStatus = $finalStatus
    $script:Result.doctor.warnings = $warnings
    $script:Result.doctor.warningCount = $warnings.Count

    if ([string]$schemaVersion -ne $script:ExpectedDoctorSchemaVersion) {
        Add-DoctorValidationError -Code "DOCTOR_SCHEMA_VERSION_MISMATCH" -Message "Doctor schemaVersion must be $($script:ExpectedDoctorSchemaVersion)."
    }
    if ([string]$scannerVersion -ne $script:ExpectedDoctorScannerVersion) {
        Add-DoctorValidationError -Code "DOCTOR_SCANNER_VERSION_MISMATCH" -Message "Doctor scannerVersion must be $($script:ExpectedDoctorScannerVersion)."
    }
    try {
        $normalizedDoctorRoot = Get-NormalizedAbsolutePath -Path ([string]$doctorProjectRoot)
        if (-not $normalizedDoctorRoot.Equals($script:NormalizedProjectRoot, $script:PathComparison)) {
            Add-DoctorValidationError -Code "DOCTOR_PROJECT_ROOT_MISMATCH" -Message "Doctor projectRoot does not match the exact current project root."
        }
    } catch {
        Add-DoctorValidationError -Code "DOCTOR_PROJECT_ROOT_INVALID" -Message "Doctor projectRoot is absent or invalid."
    }

    $isUnityProject = Get-JsonPropertyValue -InputObject $projectDetection -Name "isUnityProject"
    $rootStatus = Get-JsonPropertyValue -InputObject $projectDetection -Name "rootStatus"
    if ($isUnityProject -isnot [bool] -or -not [bool]$isUnityProject -or [string]$rootStatus -ne "UNITY_PROJECT") {
        Add-DoctorValidationError -Code "DOCTOR_PROJECT_DETECTION_REJECTED" -Message "Doctor must identify the exact root as UNITY_PROJECT."
    }

    $parseStatus = Get-JsonPropertyValue -InputObject $unityEditorVersion -Name "parseStatus"
    $doctorEditorVersion = Get-JsonPropertyValue -InputObject $unityEditorVersion -Name "editorVersion"
    if ([string]$parseStatus -ne "PARSED" -or [string]$doctorEditorVersion -ne $script:ExpectedUnityVersion) {
        Add-DoctorValidationError -Code "DOCTOR_UNITY_VERSION_MISMATCH" -Message "Doctor must parse Unity editorVersion $($script:ExpectedUnityVersion)."
    }

    if (@("STATIC_AUDIT_COMPLETE", "STATIC_AUDIT_COMPLETE_WITH_WARNINGS") -notcontains [string]$finalStatus) {
        Add-DoctorValidationError -Code "DOCTOR_FINAL_STATUS_REJECTED" -Message "Doctor finalStatus must be STATIC_AUDIT_COMPLETE or STATIC_AUDIT_COMPLETE_WITH_WARNINGS."
    }
    if ($blockedChecks.Count -gt 0 -and $null -ne $blockedChecks[0]) {
        Add-DoctorValidationError -Code "DOCTOR_BLOCKED_CHECKS_PRESENT" -Message "Doctor blockedChecks must be empty."
    }
    if ($evidence.Count -eq 0 -or $null -eq $evidence[0]) {
        Add-DoctorValidationError -Code "DOCTOR_EVIDENCE_MISSING" -Message "Doctor evidence must contain the v0.2 static audit ledger."
    }

    foreach ($name in @("compilation", "tests", "build", "runtime")) {
        $dynamicItem = Get-JsonPropertyValue -InputObject $dynamicVerification -Name $name
        $dynamicStatus = Get-JsonPropertyValue -InputObject $dynamicItem -Name "status"
        if ([string]$dynamicStatus -ne "NOT_VERIFIED") {
            Add-DoctorValidationError -Code ("DOCTOR_DYNAMIC_STATUS_INVALID_" + $name.ToUpperInvariant()) -Message "Doctor dynamicVerification.$name.status must remain NOT_VERIFIED."
        }
    }

    $script:Result.doctor.validationErrors = @($script:DoctorValidationErrors)
    $script:Result.doctor.accepted = $script:DoctorValidationErrors.Count -eq 0
    if ($script:Result.doctor.accepted) {
        Add-Evidence -Check "doctor" -Status "PASSED" -Source $script:Result.doctor.sourcePath -Detail "unity-project-doctor schema 1.0.0 and scanner 0.2.0 evidence was accepted for the exact project root."
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
        $script:Result.unity.executableSha256 = Get-FileSha256 -Path $normalizedPath
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

    Add-Evidence -Check "unityExecutable" -Status "PASSED" -Source $script:Result.unity.executablePath -Detail "The specified Unity.exe ProductVersion identifies $($script:ExpectedUnityVersion)."
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

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:Result.unity.executablePath
    $startInfo.Arguments = [string]::Join(" ", [string[]]@($arguments | ForEach-Object { ConvertTo-ProcessArgument -Argument ([string]$_) }))
    $startInfo.WorkingDirectory = $script:SessionRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $script:Utf8NoBom
    $startInfo.StandardErrorEncoding = $script:Utf8NoBom

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $script:Result.unity.processStarted = $true
        Add-Evidence -Check "unityProcess" -Status "OBSERVED" -Source $script:Result.unity.executablePath -Detail "Only the specified Unity.exe was started; Unity Hub was not invoked by the verifier."

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timeoutMilliseconds = [int]([math]::Min([int64]::MaxValue, ([int64]$TimeoutSeconds * 1000)))
        $completed = $process.WaitForExit($timeoutMilliseconds)
        if (-not $completed) {
            $script:Result.unity.timedOut = $true
            try {
                $process.Kill()
                $process.WaitForExit()
            } catch {
            }
        } else {
            $process.WaitForExit()
        }

        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        if (-not $script:Result.unity.timedOut) {
            $script:Result.unity.exitCode = $process.ExitCode
        }
        [void][System.IO.File]::WriteAllText($script:Result.unity.standardOutputPath, $stdout, $script:Utf8NoBom)
        [void][System.IO.File]::WriteAllText($script:Result.unity.standardErrorPath, $stderr, $script:Utf8NoBom)
    } finally {
        $process.Dispose()
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

# Stores concise before/after snapshot summaries in the public result.
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

# Finalizes blockers, evidence, untouched scope rows, and exactly one final status.
function Complete-VerificationResult {
    $script:Result.doctor.validationErrors = @($script:DoctorValidationErrors)
    $script:Result.blockers = @($script:Blockers)
    $script:Result.evidence = @($script:Evidence)

    if ($script:Result.originalProjectIntegrity.status -eq "CHANGED") {
        $script:Result.finalStatus = "ORIGINAL_PROJECT_CHANGED"
    } elseif ($script:Result.originalProjectIntegrity.status -eq "BLOCKED") {
        $script:Result.finalStatus = "VERIFICATION_BLOCKED"
    } elseif ($script:Result.verification.scriptCompilation.status -eq "VERIFIED_FAILURE") {
        $script:Result.finalStatus = "BASELINE_FAILED"
    } elseif ($script:Blockers.Count -gt 0) {
        $script:Result.finalStatus = "VERIFICATION_BLOCKED"
    } elseif (
        $script:Result.verification.scriptCompilation.status -eq "VERIFIED_SUCCESS" -and
        $script:Result.originalProjectIntegrity.status -eq "UNCHANGED"
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

        Test-DoctorResult -Path $DoctorResultPath
        Test-CurrentProjectVersion
        Test-UnityExecutable -Path $UnityExecutable
    }

    if ($script:Blockers.Count -eq 0) {
        try {
            $script:OriginalSnapshotBefore = Get-ProjectTreeSnapshot -Root $script:NormalizedProjectRoot
            Set-IntegritySnapshotSummaries
            Add-Evidence -Check "originalIntegrityBefore" -Status "OBSERVED" -Source $script:NormalizedProjectRoot -Detail "Captured the complete original directory list, file list, lengths, and SHA-256 hashes before Unity startup."
        } catch {
            Add-Blocker -Code "ORIGINAL_PRE_SNAPSHOT_FAILED" -Check "originalIntegrity" -Path $script:NormalizedProjectRoot -Message "The original pre-run tree could not be hashed safely: $($_.Exception.Message)"
            $script:Result.originalProjectIntegrity.status = "BLOCKED"
        }
    }

    if ($null -ne $script:OriginalSnapshotBefore) {
        try {
            Test-LocalPackageDependencySafety
            if ($script:Blockers.Count -eq 0) {
                $copyResult = Copy-ProjectToIsolation -Snapshot $script:OriginalSnapshotBefore -Destination $script:Result.isolation.projectCopyPath
                $script:Result.isolation.copyStatus = "COPIED"
                $script:Result.isolation.copiedDirectoryCount = $copyResult.copiedDirectoryCount
                $script:Result.isolation.copiedFileCount = $copyResult.copiedFileCount
                Add-Evidence -Check "isolation" -Status "PASSED" -Source $script:Result.isolation.projectCopyPath -Detail "Project source and configuration were copied without generated or tooling trees."

                Invoke-IsolatedUnity
                $script:Result.editorLog = Get-EditorLogAnalysis -Path $script:Result.artifacts.editorLogPath -ExpectedProjectPath $script:Result.isolation.projectCopyPath
                Set-CompilationVerification
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
                    Add-Evidence -Check "originalIntegrityAfter" -Status "PASSED" -Source $script:NormalizedProjectRoot -Detail "The original pre/post directory list, file list, lengths, per-file SHA-256 values, and tree SHA-256 are identical."
                } else {
                    $script:Result.originalProjectIntegrity.status = "CHANGED"
                    Add-Evidence -Check "originalIntegrityAfter" -Status "FAILED" -Source $script:NormalizedProjectRoot -Detail "The original project tree differs from its pre-run snapshot. No automatic rollback was attempted."
                }
            } catch {
                $script:Result.originalProjectIntegrity.status = "BLOCKED"
                Add-Blocker -Code "ORIGINAL_POST_SNAPSHOT_FAILED" -Check "originalIntegrity" -Path $script:NormalizedProjectRoot -Message "The original post-run tree could not be hashed safely: $($_.Exception.Message)"
            }
        }
    }
} catch {
    Add-Blocker -Code "VERIFIER_UNEXPECTED_ERROR" -Check "verifier" -Path $null -Message "The verifier encountered an unexpected internal error: $($_.Exception.Message)"
}

foreach ($scopeName in @("tests", "playerBuild", "playMode", "runtime")) {
    Add-Evidence -Check $scopeName -Status "NOT_VERIFIED" -Source "v0.1 scope" -Detail $script:Result.verification.$scopeName.reason
}

$finalJson = ConvertTo-FinalJson
[Console]::Out.WriteLine($finalJson)
