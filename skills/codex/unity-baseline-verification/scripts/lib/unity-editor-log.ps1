Set-StrictMode -Version Latest

$script:UnityEditorLogUtf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Normalizes one log-observed project path without resolving link targets.
function Get-UnityEditorLogNormalizedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals($fullPath, $root)) {
        return $fullPath
    }
    return $fullPath.TrimEnd('\', '/')
}

# Calculates a lowercase SHA-256 digest for one Editor.log file.
function Get-UnityEditorLogSha256 {
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
        $digest = $algorithm.ComputeHash($stream)
        return -join @($digest | ForEach-Object { $_.ToString('x2') })
    } finally {
        if ($null -ne $algorithm) {
            $algorithm.Dispose()
        }
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

# Reads one Editor.log with BOM detection and no adjacent writes.
function Read-UnityEditorLogText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $reader = $null
    try {
        $reader = New-Object System.IO.StreamReader($Path, $script:UnityEditorLogUtf8NoBom, $true)
        return $reader.ReadToEnd()
    } finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
    }
}

# Extracts concrete version, isolated-path, import, compilation, and exit evidence from Editor.log.
function Get-UnityEditorLogAnalysis {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedProjectPath,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedUnityVersion
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
        classification = 'NOT_ANALYZED'
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]$analysis
    }

    $analysis.exists = $true
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $analysis.byteLength = [long]$item.Length
    $analysis.sha256 = Get-UnityEditorLogSha256 -Path $Path
    $text = Read-UnityEditorLogText -Path $Path
    $lines = @([regex]::Split($text, '\r?\n'))

    $versionMatch = [regex]::Match($text, "(?m)^Built from .+? Version is '(?<version>\d+\.\d+\.\d+[abfp]\d+)")
    if (-not $versionMatch.Success) {
        $versionMatch = [regex]::Match($text, '(?m)^Initialize engine version:\s*(?<version>\d+\.\d+\.\d+[abfp]\d+)')
    }
    if ($versionMatch.Success) {
        $analysis.detectedUnityVersion = $versionMatch.Groups['version'].Value
        $analysis.versionMatched = $analysis.detectedUnityVersion -eq $ExpectedUnityVersion
    }

    $analysis.batchModeObserved = [regex]::IsMatch($text, '(?m)^BatchMode:\s*1\b')
    $projectPathMatch = [regex]::Match($text, '(?m)^Successfully changed project path to:\s*(?<path>.+?)\s*$')
    if ($projectPathMatch.Success) {
        try {
            $observedProjectPath = Get-UnityEditorLogNormalizedPath -Path $projectPathMatch.Groups['path'].Value
            $expectedNormalizedPath = Get-UnityEditorLogNormalizedPath -Path $ExpectedProjectPath
            $comparison = if ($env:OS -eq 'Windows_NT') {
                [System.StringComparison]::OrdinalIgnoreCase
            } else {
                [System.StringComparison]::Ordinal
            }
            $analysis.isolatedProjectPathObserved = $observedProjectPath.Equals($expectedNormalizedPath, $comparison)
        } catch {
            $analysis.isolatedProjectPathObserved = $false
        }
    }

    $analysis.importCompleted = [regex]::IsMatch($text, '(?m)^Application\.AssetDatabase Initial Refresh End\s*$')
    $analysis.compilePhaseObserved = [regex]::IsMatch($text, '(?m)^\s*CompileScripts:\s*\d')
    $analysis.domainReloadCompleted = [regex]::IsMatch($text, '(?m)^Domain Reload Profiling:\s*\d')
    $analysis.successfulQuitObserved = (
        [regex]::IsMatch($text, '(?m)^Batchmode quit successfully invoked - shutting down!\s*$') -and
        [regex]::IsMatch($text, '(?m)^Exiting batchmode successfully now!\s*$')
    )
    $analysis.zeroReturnCodeObserved = [regex]::IsMatch($text, '(?m)^Exiting without the bug reporter\. Application will terminate with return code 0\s*$')

    $compilerErrors = New-Object System.Collections.ArrayList
    foreach ($line in $lines) {
        if ([regex]::IsMatch($line, '\berror\s+CS\d{4}\s*:', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
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
        [pscustomobject]@{ code = 'COMPILER_ERROR'; pattern = '\berror\s+CS\d{4}\s*:' },
        [pscustomobject]@{ code = 'SCRIPTS_HAVE_COMPILER_ERRORS'; pattern = 'Scripts have compiler errors' },
        [pscustomobject]@{ code = 'COMPILATION_FAILED'; pattern = '(?:Compilation failed|Failed to compile)' },
        [pscustomobject]@{ code = 'BATCHMODE_ABORTED'; pattern = 'Aborting batchmode due to failure' },
        [pscustomobject]@{ code = 'FATAL_ERROR'; pattern = 'Fatal Error!' },
        [pscustomobject]@{ code = 'CRASH'; pattern = '^Crash!!!\s*$' },
        [pscustomobject]@{ code = 'NONZERO_RETURN_CODE_IN_LOG'; pattern = 'Application will terminate with return code [1-9]\d*' },
        [pscustomobject]@{ code = 'PACKAGE_RESOLUTION_FAILED'; pattern = '(?:An error occurred while resolving packages|Package resolution failed)' }
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
            code = 'UNITY_LOG_VERSION_MISMATCH'
            line = "Editor.log identifies Unity $($analysis.detectedUnityVersion)."
        })
    }
    $analysis.failureMarkers = @($failureMarkers)

    $missingMarkers = New-Object System.Collections.ArrayList
    foreach ($requirement in @(
        [pscustomobject]@{ name = 'unityVersion'; met = $analysis.versionMatched },
        [pscustomobject]@{ name = 'batchMode'; met = $analysis.batchModeObserved },
        [pscustomobject]@{ name = 'isolatedProjectPath'; met = $analysis.isolatedProjectPathObserved },
        [pscustomobject]@{ name = 'initialAssetDatabaseRefresh'; met = $analysis.importCompleted },
        [pscustomobject]@{ name = 'compileScriptsPhase'; met = $analysis.compilePhaseObserved },
        [pscustomobject]@{ name = 'domainReload'; met = $analysis.domainReloadCompleted },
        [pscustomobject]@{ name = 'successfulBatchmodeQuit'; met = $analysis.successfulQuitObserved },
        [pscustomobject]@{ name = 'loggedReturnCodeZero'; met = $analysis.zeroReturnCodeObserved }
    )) {
        if (-not $requirement.met) {
            [void]$missingMarkers.Add($requirement.name)
        }
    }
    $analysis.missingSuccessMarkers = @($missingMarkers)

    if ($analysis.failureMarkers.Count -gt 0) {
        $analysis.classification = 'FAILURE'
    } elseif ($analysis.missingSuccessMarkers.Count -eq 0) {
        $analysis.classification = 'SUCCESS'
    } else {
        $analysis.classification = 'INCONCLUSIVE'
    }
    return [pscustomobject]$analysis
}
