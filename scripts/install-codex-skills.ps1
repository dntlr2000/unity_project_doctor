[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationRoot = (Join-Path -Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) -ChildPath ".agents\skills")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Returns a stable absolute path for safe source and link-target comparisons.
function Get-NormalizedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals($fullPath, $pathRoot)) {
        return $fullPath
    }

    $trimCharacters = [char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    return $fullPath.TrimEnd($trimCharacters)
}

# Finds an existing filesystem entry, including a dangling symbolic link.
function Get-PathEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath
    )

    $parentPath = Split-Path -Parent $LiteralPath
    $leafName = Split-Path -Leaf $LiteralPath
    if (-not (Test-Path -LiteralPath $parentPath -PathType Container)) {
        return $null
    }

    return Get-ChildItem -LiteralPath $parentPath -Force |
        Where-Object { $_.Name -ieq $leafName } |
        Select-Object -First 1
}

# Confirms that an existing symbolic link already targets the expected Skill source.
function Test-LinkMatchesSource {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileSystemInfo]$Link,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedSource
    )

    if ($Link.LinkType -ne "SymbolicLink") {
        return $false
    }

    $rawTargets = @($Link.Target)
    if ($rawTargets.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$rawTargets[0])) {
        return $false
    }

    $rawTarget = [string]$rawTargets[0]
    if (-not [System.IO.Path]::IsPathRooted($rawTarget)) {
        $rawTarget = Join-Path -Path $Link.Parent.FullName -ChildPath $rawTarget
    }

    $actualTarget = Get-NormalizedPath -Path $rawTarget
    $expectedTarget = Get-NormalizedPath -Path $ExpectedSource
    return [System.StringComparer]::OrdinalIgnoreCase.Equals($actualTarget, $expectedTarget)
}

$repositoryRoot = Get-NormalizedPath -Path (Split-Path -Parent $PSScriptRoot)
$sourceRoot = Join-Path -Path $repositoryRoot -ChildPath "skills\codex"
$destinationRootPath = Get-NormalizedPath -Path $DestinationRoot

if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
    throw "Codex Skill source directory was not found: $sourceRoot"
}

$skillDirectories = @(
    Get-ChildItem -LiteralPath $sourceRoot -Directory |
        Sort-Object -Property Name
)
if ($skillDirectories.Count -eq 0) {
    throw "No Codex Skill directories were found under: $sourceRoot"
}

$destinationRootEntry = Get-PathEntry -LiteralPath $destinationRootPath
if ($null -ne $destinationRootEntry -and -not $destinationRootEntry.PSIsContainer) {
    throw "The installation root exists but is not a directory: $destinationRootPath"
}

$installPlan = foreach ($skillDirectory in $skillDirectories) {
    $skillManifest = Join-Path -Path $skillDirectory.FullName -ChildPath "SKILL.md"
    if (-not (Test-Path -LiteralPath $skillManifest -PathType Leaf)) {
        throw "Skill source is missing SKILL.md: $($skillDirectory.FullName)"
    }

    $sourcePath = Get-NormalizedPath -Path $skillDirectory.FullName
    $targetPath = Join-Path -Path $destinationRootPath -ChildPath $skillDirectory.Name
    $existingEntry = Get-PathEntry -LiteralPath $targetPath

    if ($null -eq $existingEntry) {
        [pscustomobject]@{
            Action = "Create"
            Name = $skillDirectory.Name
            Source = $sourcePath
            Target = $targetPath
            ExistingType = $null
        }
        continue
    }

    if (Test-LinkMatchesSource -Link $existingEntry -ExpectedSource $sourcePath) {
        [pscustomobject]@{
            Action = "Unchanged"
            Name = $skillDirectory.Name
            Source = $sourcePath
            Target = $targetPath
            ExistingType = $existingEntry.LinkType
        }
        continue
    }

    [pscustomobject]@{
        Action = "Conflict"
        Name = $skillDirectory.Name
        Source = $sourcePath
        Target = $targetPath
        ExistingType = if ($null -ne $existingEntry.LinkType) {
            $existingEntry.LinkType
        } elseif ($existingEntry.PSIsContainer) {
            "Directory"
        } else {
            "File"
        }
    }
}

$conflicts = @($installPlan | Where-Object { $_.Action -eq "Conflict" })
if ($conflicts.Count -gt 0) {
    foreach ($conflict in $conflicts) {
        Write-Warning (
            "Refusing to replace existing {0} at {1}; expected a symbolic link to {2}." -f
            $conflict.ExistingType,
            $conflict.Target,
            $conflict.Source
        )
    }

    throw "Installation stopped before creating links because existing entries conflict."
}

if ($null -eq $destinationRootEntry) {
    if ($PSCmdlet.ShouldProcess($destinationRootPath, "Create Codex Skill installation directory")) {
        New-Item -ItemType Directory -Path $destinationRootPath -Force | Out-Null
    }
}

$createdCount = 0
$unchangedCount = 0
foreach ($item in $installPlan) {
    if ($item.Action -eq "Unchanged") {
        Write-Host "[unchanged] $($item.Name) -> $($item.Source)"
        $unchangedCount++
        continue
    }

    if ($PSCmdlet.ShouldProcess($item.Target, "Create symbolic link to $($item.Source)")) {
        New-Item -ItemType SymbolicLink -Path $item.Target -Target $item.Source | Out-Null
        Write-Host "[linked] $($item.Name) -> $($item.Source)"
        $createdCount++
    }
}

Write-Host "Install plan processed. Created: $createdCount; unchanged: $unchangedCount."
