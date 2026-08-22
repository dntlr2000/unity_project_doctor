Set-StrictMode -Version Latest

$script:UtsUtf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:UtsPathComparison = if ($env:OS -eq 'Windows_NT') {
    [System.StringComparison]::OrdinalIgnoreCase
} else {
    [System.StringComparison]::Ordinal
}

# Returns a normalized absolute path without resolving symbolic links or junctions.
function Get-UtsNormalizedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Path must not be empty.'
    }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Equals($root, $script:UtsPathComparison)) {
        return $fullPath
    }
    return $fullPath.TrimEnd('\', '/')
}

# Tests whether a path is equal to or below a trusted root boundary.
function Test-UtsPathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $normalizedPath = Get-UtsNormalizedPath -Path $Path
    $normalizedRoot = Get-UtsNormalizedPath -Path $Root
    if ($normalizedPath.Equals($normalizedRoot, $script:UtsPathComparison)) {
        return $true
    }
    return $normalizedPath.StartsWith(
        $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar,
        $script:UtsPathComparison
    )
}

# Returns the first existing reparse point on a path or one of its ancestors.
function Get-UtsReparsePointOnPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $current = Get-UtsNormalizedPath -Path $Path
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        try {
            $entry = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                return $entry.FullName
            }
        } catch [System.Management.Automation.ItemNotFoundException] {
        } catch [System.IO.FileNotFoundException] {
        } catch [System.IO.DirectoryNotFoundException] {
        }

        $parent = [System.IO.Directory]::GetParent($current)
        if ($null -eq $parent -or $parent.FullName.Equals($current, $script:UtsPathComparison)) {
            break
        }
        $current = $parent.FullName
    }
    return $null
}

# Converts one trusted in-project absolute path to a forward-slash relative path.
function ConvertTo-UtsRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    $normalizedPath = Get-UtsNormalizedPath -Path $Path
    $normalizedRoot = Get-UtsNormalizedPath -Path $ProjectRoot
    if (-not (Test-UtsPathWithinRoot -Path $normalizedPath -Root $normalizedRoot)) {
        throw "Path escapes the project root: $normalizedPath"
    }
    if ($normalizedPath.Equals($normalizedRoot, $script:UtsPathComparison)) {
        return '.'
    }
    return $normalizedPath.Substring($normalizedRoot.Length + 1).Replace('\', '/')
}

# Resolves a relative or absolute project path and enforces the project boundary.
function Resolve-UtsProjectPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) {
        $Path
    } else {
        Join-Path $ProjectRoot $Path
    }
    $normalized = Get-UtsNormalizedPath -Path $candidate
    if (-not (Test-UtsPathWithinRoot -Path $normalized -Root $ProjectRoot)) {
        throw "Project-relative path escapes the project root: $Path"
    }
    return $normalized
}

# Calculates a lowercase SHA-256 digest over UTF-8 text.
function Get-UtsTextSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $script:UtsUtf8NoBom.GetBytes($Text)
        $digest = $algorithm.ComputeHash($bytes)
        return -join @($digest | ForEach-Object { $_.ToString('x2') })
    } finally {
        $algorithm.Dispose()
    }
}

# Returns a named object property or null when the property is absent.
function Get-UtsProperty {
    param(
        [Parameter()][AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
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

# Converts a project folder name into a conservative C# assembly-name prefix.
function ConvertTo-UtsAssemblyPrefix {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $segments = @([regex]::Matches($Value, '[A-Za-z0-9]+') | ForEach-Object { $_.Value })
    $prefix = [string]::Join('', [string[]]$segments)
    if ([string]::IsNullOrWhiteSpace($prefix)) {
        throw "Project name '$Value' cannot produce a safe assembly prefix."
    }
    if ($prefix[0] -match '[0-9]') {
        $prefix = 'Project' + $prefix
    }
    return $prefix
}

# Validates an assembly name accepted by the scaffold's closed file-name contract.
function Test-UtsAssemblyName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return $Name -match '^[A-Za-z_][A-Za-z0-9_.-]{0,199}$'
}

# Serializes an ordered object as stable indented JSON with LF and one terminal newline.
function ConvertTo-UtsJsonFileText {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject
    )

    $json = ConvertTo-Json -InputObject $InputObject -Depth 20
    return ([regex]::Replace($json, '\r?\n', "`n")).TrimEnd() + "`n"
}

# Builds a complete runtime Assembly Definition without introducing package or test references.
function New-UtsRuntimeAsmdefContent {
    param(
        [Parameter(Mandatory = $true)][string]$AssemblyName,
        [Parameter(Mandatory = $true)][string]$RootNamespace
    )

    return ConvertTo-UtsJsonFileText -InputObject ([ordered]@{
        name = $AssemblyName
        rootNamespace = $RootNamespace
        references = @()
        includePlatforms = @()
        excludePlatforms = @()
        allowUnsafeCode = $false
        overrideReferences = $false
        precompiledReferences = @()
        autoReferenced = $true
        defineConstraints = @()
        versionDefines = @()
        noEngineReferences = $false
    })
}

# Builds an Editor-only Unity test Assembly Definition referencing one runtime assembly.
function New-UtsEditModeAsmdefContent {
    param(
        [Parameter(Mandatory = $true)][string]$AssemblyName,
        [Parameter(Mandatory = $true)][string]$RootNamespace,
        [Parameter(Mandatory = $true)][string]$RuntimeAssemblyName
    )

    return ConvertTo-UtsJsonFileText -InputObject ([ordered]@{
        name = $AssemblyName
        rootNamespace = $RootNamespace
        references = @($RuntimeAssemblyName)
        includePlatforms = @('Editor')
        excludePlatforms = @()
        allowUnsafeCode = $false
        overrideReferences = $false
        precompiledReferences = @()
        autoReferenced = $false
        defineConstraints = @()
        versionDefines = @()
        noEngineReferences = $false
        optionalUnityReferences = @('TestAssemblies')
    })
}

# Builds deterministic Unity metadata for either a folder or an Assembly Definition asset.
function New-UtsMetaContent {
    param(
        [Parameter(Mandatory = $true)][string]$Guid,
        [Parameter(Mandatory = $true)][ValidateSet('Folder', 'AssemblyDefinition')][string]$Kind
    )

    $content = if ($Kind -eq 'Folder') {
        @"
fileFormatVersion: 2
guid: $Guid
folderAsset: yes
DefaultImporter:
  externalObjects: {}
  userData:
  assetBundleName:
  assetBundleVariant:
"@
    } else {
        @"
fileFormatVersion: 2
guid: $Guid
AssemblyDefinitionImporter:
  externalObjects: {}
  userData:
  assetBundleName:
  assetBundleVariant:
"@
    }
    return $content.Replace("`r`n", "`n").TrimStart("`n").TrimEnd("`r", "`n") + "`n"
}

# Collects Unity GUIDs already declared by included project metadata files.
function Get-UtsExistingMetaGuids {
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    $lookup = @{}
    foreach ($file in @($Snapshot.files | Where-Object { [string]$_.path -match '(?i)\.meta$' })) {
        $fullPath = Resolve-UtsProjectPath -Path ([string]$file.path) -ProjectRoot $ProjectRoot
        $text = [System.IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8)
        $match = [regex]::Match($text, '(?m)^guid:\s*(?<guid>[0-9a-fA-F]{32})\s*$')
        if ($match.Success) {
            $lookup[$match.Groups['guid'].Value.ToLowerInvariant()] = [string]$file.path
        }
    }
    return $lookup
}

# Parses every included Assembly Definition so new assembly names cannot collide globally.
function Get-UtsAsmdefInventory {
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    $inventory = New-Object System.Collections.ArrayList
    foreach ($file in @($Snapshot.files | Where-Object { [string]$_.path -match '(?i)\.asmdef$' } | Sort-Object path)) {
        $path = [string]$file.path
        try {
            $fullPath = Resolve-UtsProjectPath -Path $path -ProjectRoot $ProjectRoot
            $data = [System.IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
            $name = [string](Get-UtsProperty -InputObject $data -Name 'name')
            if (-not (Test-UtsAssemblyName -Name $name)) {
                throw 'Assembly Definition has an unsafe or missing name.'
            }
            [void]$inventory.Add([pscustomobject][ordered]@{
                path = $path
                name = $name
                parseStatus = 'PARSED'
                error = $null
            })
        } catch {
            [void]$inventory.Add([pscustomobject][ordered]@{
                path = $path
                name = $null
                parseStatus = 'MALFORMED'
                error = $_.Exception.Message
            })
        }
    }
    return [object[]]@($inventory.ToArray())
}

# Derives a stable collision-free Unity GUID from a project-local identity.
function Get-UtsDeterministicGuid {
    param(
        [Parameter(Mandatory = $true)][string]$Seed,
        [Parameter(Mandatory = $true)][hashtable]$ExistingGuids,
        [Parameter(Mandatory = $true)][hashtable]$ReservedGuids
    )

    for ($counter = 0; $counter -lt 1024; $counter++) {
        $candidate = (Get-UtsTextSha256 -Text ("unity-test-scaffold-v1|$Seed|$counter")).Substring(0, 32)
        if (-not $ExistingGuids.ContainsKey($candidate) -and -not $ReservedGuids.ContainsKey($candidate)) {
            $ReservedGuids[$candidate] = $Seed
            return $candidate
        }
    }
    throw "Unable to derive a collision-free Unity GUID for $Seed."
}

# Finds unique Runtime directory candidates from the stable project copy-set snapshot.
function Get-UtsRuntimeCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Snapshot
    )

    $lookup = @{}
    foreach ($file in @($Snapshot.files | Where-Object { [string]$_.path -match '(?i)\.cs$' })) {
        $segments = @(([string]$file.path).Replace('\', '/').Split('/'))
        for ($index = 1; $index -lt ($segments.Count - 1); $index++) {
            if ($segments[$index] -ine 'Runtime') {
                continue
            }
            $prefixSegments = @($segments[0..($index - 1)])
            if (@($prefixSegments | Where-Object { $_ -imatch '^(Tests?|Editor)$' }).Count -gt 0) {
                continue
            }
            $candidate = [string]::Join('/', [string[]]$segments[0..$index])
            $lookup[$candidate.ToUpperInvariant()] = $candidate
            break
        }
    }
    return [string[]]@($lookup.Values | Sort-Object)
}

# Resolves the nearest ancestor Assembly Definition that owns a runtime source root.
function Get-UtsOwningAsmdef {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    $assetsRoot = Get-UtsNormalizedPath -Path (Join-Path $ProjectRoot 'Assets')
    $current = Get-UtsNormalizedPath -Path $RuntimeRoot
    while (Test-UtsPathWithinRoot -Path $current -Root $assetsRoot) {
        $asmdefs = @(Get-ChildItem -LiteralPath $current -Filter '*.asmdef' -File -Force -ErrorAction Stop | Sort-Object Name)
        if ($asmdefs.Count -gt 1) {
            throw "Assembly ownership is ambiguous because $current contains multiple asmdef files."
        }
        if ($asmdefs.Count -eq 1) {
            $text = [System.IO.File]::ReadAllText($asmdefs[0].FullName, [System.Text.Encoding]::UTF8)
            $data = ConvertFrom-Json -InputObject $text -ErrorAction Stop
            $name = [string](Get-UtsProperty -InputObject $data -Name 'name')
            if (-not (Test-UtsAssemblyName -Name $name)) {
                throw "Owning asmdef has an unsafe or missing name: $($asmdefs[0].FullName)"
            }
            return [pscustomobject][ordered]@{
                path = ConvertTo-UtsRelativePath -Path $asmdefs[0].FullName -ProjectRoot $ProjectRoot
                name = $name
                source = 'EXISTING'
            }
        }
        if ($current.Equals($assetsRoot, $script:UtsPathComparison)) {
            break
        }
        $parent = [System.IO.Directory]::GetParent($current)
        if ($null -eq $parent) {
            break
        }
        $current = $parent.FullName
    }
    return $null
}

# Confirms whether an existing asmdef is an Editor-only test assembly for the selected runtime assembly.
function Test-UtsExistingTestAsmdef {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RuntimeAssemblyName
    )

    try {
        $data = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        $name = [string](Get-UtsProperty -InputObject $data -Name 'name')
        $references = @((Get-UtsProperty -InputObject $data -Name 'references') | ForEach-Object { [string]$_ })
        $platforms = @((Get-UtsProperty -InputObject $data -Name 'includePlatforms') | ForEach-Object { [string]$_ })
        $optional = @((Get-UtsProperty -InputObject $data -Name 'optionalUnityReferences') | ForEach-Object { [string]$_ })
        $hasTestRunnerReference = @($references | Where-Object { $_ -in @('UnityEngine.TestRunner', 'UnityEditor.TestRunner') }).Count -gt 0
        return [pscustomobject][ordered]@{
            accepted = (
                (Test-UtsAssemblyName -Name $name) -and
                ($references -contains $RuntimeAssemblyName) -and
                ($platforms.Count -eq 1) -and
                ($platforms[0] -ieq 'Editor') -and
                (($optional -contains 'TestAssemblies') -or $hasTestRunnerReference)
            )
            name = $name
            error = $null
        }
    } catch {
        return [pscustomobject][ordered]@{ accepted = $false; name = $null; error = $_.Exception.Message }
    }
}

# Returns every currently missing directory required by planned file parents.
function Get-UtsMissingDirectories {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$FilePaths
    )

    $missing = @{}
    foreach ($relativeFile in $FilePaths) {
        $parent = Split-Path -Parent (Resolve-UtsProjectPath -Path $relativeFile -ProjectRoot $ProjectRoot)
        while (-not [string]::IsNullOrWhiteSpace($parent) -and (Test-UtsPathWithinRoot -Path $parent -Root $ProjectRoot)) {
            if (Test-Path -LiteralPath $parent) {
                if (Test-Path -LiteralPath $parent -PathType Container) {
                    break
                }
                throw "Required scaffold parent exists but is not a directory: $parent"
            }
            $relativeParent = ConvertTo-UtsRelativePath -Path $parent -ProjectRoot $ProjectRoot
            $missing[$relativeParent.ToUpperInvariant()] = $relativeParent
            $next = [System.IO.Directory]::GetParent($parent)
            if ($null -eq $next) {
                break
            }
            $parent = $next.FullName
        }
    }
    return [string[]]@($missing.Values | Sort-Object @{ Expression = { @($_.Split('/')).Count } }, @{ Expression = { $_ } })
}

# Produces a deterministic file and directory delta between two copy-set snapshots.
function Get-UtsSnapshotDelta {
    param(
        [Parameter(Mandatory = $true)][object]$Before,
        [Parameter(Mandatory = $true)][object]$After
    )

    $beforeFiles = @{}
    $afterFiles = @{}
    foreach ($file in @($Before.files)) { $beforeFiles[[string]$file.path] = $file }
    foreach ($file in @($After.files)) { $afterFiles[[string]$file.path] = $file }
    $addedFiles = New-Object System.Collections.ArrayList
    $removedFiles = New-Object System.Collections.ArrayList
    $changedFiles = New-Object System.Collections.ArrayList
    foreach ($path in @($afterFiles.Keys | Sort-Object)) {
        if (-not $beforeFiles.ContainsKey($path)) {
            [void]$addedFiles.Add($path)
        } elseif ($beforeFiles[$path].sha256 -ne $afterFiles[$path].sha256 -or $beforeFiles[$path].length -ne $afterFiles[$path].length) {
            [void]$changedFiles.Add($path)
        }
    }
    foreach ($path in @($beforeFiles.Keys | Sort-Object)) {
        if (-not $afterFiles.ContainsKey($path)) {
            [void]$removedFiles.Add($path)
        }
    }

    $beforeDirectories = @{}
    $afterDirectories = @{}
    foreach ($path in @($Before.directories)) { $beforeDirectories[[string]$path] = $true }
    foreach ($path in @($After.directories)) { $afterDirectories[[string]$path] = $true }
    $addedDirectories = @($afterDirectories.Keys | Where-Object { -not $beforeDirectories.ContainsKey($_) } | Sort-Object)
    $removedDirectories = @($beforeDirectories.Keys | Where-Object { -not $afterDirectories.ContainsKey($_) } | Sort-Object)
    return [pscustomobject][ordered]@{
        addedFiles = @($addedFiles)
        removedFiles = @($removedFiles)
        changedFiles = @($changedFiles)
        addedDirectories = @($addedDirectories)
        removedDirectories = @($removedDirectories)
    }
}

# Confirms that a snapshot delta contains only the declared scaffold additions.
function Test-UtsExpectedDelta {
    param(
        [Parameter(Mandatory = $true)][object]$Delta,
        [Parameter(Mandatory = $true)][object]$After,
        [Parameter(Mandatory = $true)][object[]]$ExpectedFiles,
        [Parameter(Mandatory = $true)][string[]]$ExpectedDirectories
    )

    $actualFiles = [string[]]@($Delta.addedFiles | Sort-Object)
    $plannedFiles = [string[]]@($ExpectedFiles | ForEach-Object { [string]$_.path } | Sort-Object)
    $actualDirectories = [string[]]@($Delta.addedDirectories | Sort-Object)
    $plannedDirectories = [string[]]@($ExpectedDirectories | Sort-Object)
    $filesMatch = [string]::Join("`n", $actualFiles) -ceq [string]::Join("`n", $plannedFiles)
    $directoriesMatch = [string]::Join("`n", $actualDirectories) -ceq [string]::Join("`n", $plannedDirectories)
    $afterFiles = @{}
    foreach ($file in @($After.files)) {
        $afterFiles[[string]$file.path] = $file
    }
    $contentMatch = $true
    foreach ($expectedFile in $ExpectedFiles) {
        $path = [string]$expectedFile.path
        if (-not $afterFiles.ContainsKey($path) -or [string]$afterFiles[$path].sha256 -cne [string]$expectedFile.sha256) {
            $contentMatch = $false
            break
        }
    }
    return [pscustomobject][ordered]@{
        accepted = (
            $filesMatch -and
            $directoriesMatch -and
            $contentMatch -and
            @($Delta.removedFiles).Count -eq 0 -and
            @($Delta.changedFiles).Count -eq 0 -and
            @($Delta.removedDirectories).Count -eq 0
        )
        filesMatch = $filesMatch
        directoriesMatch = $directoriesMatch
        contentMatch = $contentMatch
    }
}

# Writes one new UTF-8 file atomically with create-new semantics.
function Write-UtsNewFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $bytes = $script:UtsUtf8NoBom.GetBytes($Content)
    $stream = $null
    $created = $false
    try {
        $stream = New-Object System.IO.FileStream(
            $Path,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $created = $true
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } catch {
        if ($null -ne $stream) {
            $stream.Dispose()
            $stream = $null
        }
        if ($created -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        }
        throw
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

# Removes only exact files and empty directories created by the current transaction.
function Undo-UtsCreatedEntries {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter()][AllowEmptyCollection()][string[]]$CreatedFiles = @(),
        [Parameter()][AllowEmptyCollection()][string[]]$CreatedDirectories = @()
    )

    $removedFiles = New-Object System.Collections.ArrayList
    $removedDirectories = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    foreach ($relativePath in @($CreatedFiles | Sort-Object -Descending)) {
        try {
            $fullPath = Resolve-UtsProjectPath -Path $relativePath -ProjectRoot $ProjectRoot
            if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
                Remove-Item -LiteralPath $fullPath -Force -ErrorAction Stop
                [void]$removedFiles.Add($relativePath)
            }
        } catch {
            [void]$errors.Add("${relativePath}: $($_.Exception.Message)")
        }
    }
    foreach ($relativePath in @($CreatedDirectories | Sort-Object @{ Expression = { @($_.Split('/')).Count }; Descending = $true }, @{ Expression = { $_ }; Descending = $true })) {
        try {
            $fullPath = Resolve-UtsProjectPath -Path $relativePath -ProjectRoot $ProjectRoot
            if ((Test-Path -LiteralPath $fullPath -PathType Container) -and @(Get-ChildItem -LiteralPath $fullPath -Force).Count -eq 0) {
                Remove-Item -LiteralPath $fullPath -Force -ErrorAction Stop
                [void]$removedDirectories.Add($relativePath)
            }
        } catch {
            [void]$errors.Add("${relativePath}: $($_.Exception.Message)")
        }
    }
    return [pscustomobject][ordered]@{
        attempted = $true
        completed = $errors.Count -eq 0
        removedFiles = @($removedFiles)
        removedDirectories = @($removedDirectories)
        errors = @($errors)
    }
}

# Creates planned directories and files transactionally without overwriting existing entries.
function Invoke-UtsTransactionalWrites {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][object[]]$Files,
        [Parameter()][AllowEmptyCollection()][string[]]$Directories = @(),
        [Parameter()][AllowNull()][scriptblock]$FileWriter
    )

    $createdFiles = New-Object System.Collections.ArrayList
    $createdDirectories = New-Object System.Collections.ArrayList
    if ($null -eq $FileWriter) {
        $FileWriter = { param($Path, $Content) Write-UtsNewFile -Path $Path -Content $Content }
    }
    try {
        foreach ($relativeDirectory in $Directories) {
            $fullDirectory = Resolve-UtsProjectPath -Path $relativeDirectory -ProjectRoot $ProjectRoot
            if (Test-Path -LiteralPath $fullDirectory) {
                throw "Planned directory unexpectedly exists: $relativeDirectory"
            }
            $parent = Split-Path -Parent $fullDirectory
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                throw "Planned directory parent is missing: $relativeDirectory"
            }
            if ($null -ne (Get-UtsReparsePointOnPath -Path $parent)) {
                throw "Planned directory parent traverses a reparse point: $relativeDirectory"
            }
            [void][System.IO.Directory]::CreateDirectory($fullDirectory)
            [void]$createdDirectories.Add($relativeDirectory)
        }
        foreach ($file in @($Files | Sort-Object path)) {
            $relativePath = [string]$file.path
            $fullPath = Resolve-UtsProjectPath -Path $relativePath -ProjectRoot $ProjectRoot
            if (Test-Path -LiteralPath $fullPath) {
                throw "Planned file unexpectedly exists: $relativePath"
            }
            $parent = Split-Path -Parent $fullPath
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                throw "Planned file parent is missing: $relativePath"
            }
            if ($null -ne (Get-UtsReparsePointOnPath -Path $parent)) {
                throw "Planned file parent traverses a reparse point: $relativePath"
            }
            & $FileWriter $fullPath ([string]$file.content)
            [void]$createdFiles.Add($relativePath)
        }
        return [pscustomobject][ordered]@{
            succeeded = $true
            error = $null
            createdFiles = @($createdFiles)
            createdDirectories = @($createdDirectories)
            rollback = [pscustomobject][ordered]@{
                attempted = $false
                completed = $false
                removedFiles = @()
                removedDirectories = @()
                errors = @()
            }
        }
    } catch {
        $rollback = Undo-UtsCreatedEntries -ProjectRoot $ProjectRoot -CreatedFiles @($createdFiles) -CreatedDirectories @($createdDirectories)
        return [pscustomobject][ordered]@{
            succeeded = $false
            error = $_.Exception.Message
            createdFiles = @($createdFiles)
            createdDirectories = @($createdDirectories)
            rollback = $rollback
        }
    }
}
