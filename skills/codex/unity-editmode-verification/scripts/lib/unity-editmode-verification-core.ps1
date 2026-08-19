Set-StrictMode -Version Latest

$script:UevUtf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:UevPathComparison = if ($env:OS -eq 'Windows_NT') {
    [System.StringComparison]::OrdinalIgnoreCase
} else {
    [System.StringComparison]::Ordinal
}

# Returns a normalized absolute path without resolving a link target.
function Get-UevNormalizedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Path must not be empty.'
    }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Equals($root, $script:UevPathComparison)) {
        return $fullPath
    }
    return $fullPath.TrimEnd('\', '/')
}

# Tests whether one normalized path is equal to or below a trusted root.
function Test-UevPathWithinRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $normalizedPath = Get-UevNormalizedPath -Path $Path
    $normalizedRoot = Get-UevNormalizedPath -Path $Root
    if ($normalizedPath.Equals($normalizedRoot, $script:UevPathComparison)) {
        return $true
    }
    return $normalizedPath.StartsWith(
        $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar,
        $script:UevPathComparison
    )
}

# Returns the first existing reparse point on a path or existing ancestor.
function Get-UevReparsePointOnPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $current = Get-UevNormalizedPath -Path $Path
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
        if ($null -eq $parent -or $parent.FullName.Equals($current, $script:UevPathComparison)) {
            break
        }
        $current = $parent.FullName
    }
    return $null
}

# Calculates a lowercase SHA-256 digest for one file.
function Get-UevFileSha256 {
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

# Returns a named JSON property value or null when it is absent.
function Get-UevJsonProperty {
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

# Validates and deterministically orders Doctor-confirmed assembly names.
function Get-UevAssemblySelection {
    param(
        [Parameter()]
        [AllowNull()]
        [object[]]$ConfirmedAssemblies
    )

    $errors = New-Object System.Collections.ArrayList
    $records = New-Object System.Collections.ArrayList
    $names = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($assembly in @($ConfirmedAssemblies)) {
        $name = [string](Get-UevJsonProperty -InputObject $assembly -Name 'name')
        $path = [string](Get-UevJsonProperty -InputObject $assembly -Name 'path')
        $evidence = @((Get-UevJsonProperty -InputObject $assembly -Name 'evidence'))
        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_.-]{0,199}$') {
            [void]$errors.Add("Confirmed test assembly '$name' has an unsafe or unsupported name.")
            continue
        }
        if ([string]::IsNullOrWhiteSpace($path) -or $evidence.Count -eq 0) {
            [void]$errors.Add("Confirmed test assembly '$name' lacks its Doctor path or direct evidence.")
            continue
        }
        if (-not $seen.Add($name)) {
            [void]$errors.Add("Confirmed test assembly name '$name' is duplicated case-insensitively.")
            continue
        }
        [void]$records.Add([ordered]@{ name = $name; path = $path; evidence = @($evidence) })
        [void]$names.Add($name)
    }

    $orderedRecords = @($records | Sort-Object -Property @{ Expression = { [string]$_.name }; Ascending = $true })
    $orderedNames = @($orderedRecords | ForEach-Object { [string]$_.name })
    return [pscustomobject][ordered]@{
        accepted = $errors.Count -eq 0
        records = $orderedRecords
        names = $orderedNames
        argument = if ($orderedNames.Count -gt 0) { [string]::Join(';', [string[]]$orderedNames) } else { $null }
        errors = @($errors)
    }
}

# Builds the closed Unity Test Framework argument set for EditMode only.
function New-UevUnityArguments {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$AssemblyNames,
        [Parameter(Mandatory = $true)][string]$TestResultsPath,
        [Parameter(Mandatory = $true)][string]$EditorLogPath,
        [Parameter(Mandatory = $true)][string]$UpmLogPath
    )

    if ([string]::IsNullOrWhiteSpace($AssemblyNames)) {
        throw 'At least one confirmed test assembly name is required.'
    }
    return [string[]]@(
        '-batchmode',
        '-nographics',
        '-runTests',
        '-projectPath', $ProjectPath,
        '-testPlatform', 'EditMode',
        '-assemblyNames', $AssemblyNames,
        '-testResults', $TestResultsPath,
        '-logFile', $EditorLogPath,
        '-upmLogFile', $UpmLogPath
    )
}

# Reads the first invariant integer XML attribute from a declared name list.
function Get-UevXmlIntegerAttribute {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlElement]$Element,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter()][int]$DefaultValue = 0
    )

    foreach ($name in $Names) {
        if ($Element.HasAttribute($name)) {
            $parsed = 0
            if ([int]::TryParse(
                $Element.GetAttribute($name),
                [System.Globalization.NumberStyles]::Integer,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$parsed
            )) {
                return $parsed
            }
            throw "XML attribute '$name' is not an invariant integer."
        }
    }
    return $DefaultValue
}

# Reads the first invariant floating-point XML attribute from a declared name list.
function Get-UevXmlDoubleAttribute {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlElement]$Element,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    foreach ($name in $Names) {
        if ($Element.HasAttribute($name)) {
            $parsed = 0.0
            if ([double]::TryParse(
                $Element.GetAttribute($name),
                [System.Globalization.NumberStyles]::Float,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$parsed
            )) {
                return $parsed
            }
            throw "XML attribute '$name' is not an invariant number."
        }
    }
    return $null
}

# Converts one XML node value to a bounded single-line diagnostic string.
function ConvertTo-UevBoundedDiagnostic {
    param(
        [Parameter()]
        [AllowNull()]
        [string]$Value,

        [Parameter()][int]$MaximumLength = 2048
    )

    if ($null -eq $Value) {
        return $null
    }
    $singleLine = ([regex]::Replace($Value, '\s+', ' ')).Trim()
    if ($singleLine.Length -le $MaximumLength) {
        return $singleLine
    }
    return $singleLine.Substring(0, $MaximumLength)
}

# Parses NUnit 3 or legacy NUnit 2 XML into a strict EditMode summary.
function Get-UevNUnitAnalysis {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $analysis = [ordered]@{
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
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $analysis.error = 'NUnit result XML was not created.'
        return [pscustomobject]$analysis
    }

    try {
        $analysis.exists = $true
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $analysis.byteLength = [long]$item.Length
        $analysis.sha256 = Get-UevFileSha256 -Path $Path
        $reader = $null
        try {
            $readerSettings = New-Object System.Xml.XmlReaderSettings
            $readerSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
            $readerSettings.XmlResolver = $null
            $readerSettings.MaxCharactersInDocument = 67108864
            $readerSettings.MaxCharactersFromEntities = 0
            $reader = [System.Xml.XmlReader]::Create($Path, $readerSettings)
            $document = New-Object System.Xml.XmlDocument
            $document.XmlResolver = $null
            $document.Load($reader)
        } finally {
            if ($null -ne $reader) {
                $reader.Dispose()
            }
        }
        $root = $document.DocumentElement
        if ($null -eq $root) {
            throw 'NUnit result XML has no document element.'
        }

        $nunit3HasExplicitErrors = $false
        if ($root.LocalName -eq 'test-run') {
            $analysis.format = 'NUNIT3'
            $analysis.rootResult = $root.GetAttribute('result')
            $analysis.total = Get-UevXmlIntegerAttribute -Element $root -Names @('total', 'testcasecount')
            $analysis.passed = Get-UevXmlIntegerAttribute -Element $root -Names @('passed')
            $analysis.failed = Get-UevXmlIntegerAttribute -Element $root -Names @('failed')
            $nunit3HasExplicitErrors = $root.HasAttribute('errors')
            if ($nunit3HasExplicitErrors) {
                $analysis.errors = Get-UevXmlIntegerAttribute -Element $root -Names @('errors')
            }
            $analysis.skipped = Get-UevXmlIntegerAttribute -Element $root -Names @('skipped')
            $analysis.inconclusive = Get-UevXmlIntegerAttribute -Element $root -Names @('inconclusive')
            $analysis.assertions = Get-UevXmlIntegerAttribute -Element $root -Names @('asserts')
            $analysis.durationSeconds = Get-UevXmlDoubleAttribute -Element $root -Names @('duration')
        } elseif ($root.LocalName -eq 'test-results') {
            $analysis.format = 'NUNIT2'
            $legacyFailures = Get-UevXmlIntegerAttribute -Element $root -Names @('failures')
            $legacyErrors = Get-UevXmlIntegerAttribute -Element $root -Names @('errors')
            $analysis.rootResult = if (($legacyFailures + $legacyErrors) -gt 0) { 'Failed' } else { 'Passed' }
            $analysis.total = Get-UevXmlIntegerAttribute -Element $root -Names @('total')
            $analysis.failed = $legacyFailures
            $analysis.errors = $legacyErrors
            $analysis.inconclusive = Get-UevXmlIntegerAttribute -Element $root -Names @('inconclusive')
            $analysis.skipped = (
                (Get-UevXmlIntegerAttribute -Element $root -Names @('not-run')) +
                (Get-UevXmlIntegerAttribute -Element $root -Names @('ignored')) +
                (Get-UevXmlIntegerAttribute -Element $root -Names @('skipped')) +
                (Get-UevXmlIntegerAttribute -Element $root -Names @('invalid'))
            )
            $analysis.passed = [Math]::Max(
                0,
                $analysis.total - $analysis.failed - $analysis.errors - $analysis.skipped - $analysis.inconclusive
            )
            $analysis.durationSeconds = Get-UevXmlDoubleAttribute -Element $root -Names @('time')
        } else {
            throw "Unsupported NUnit XML root element '$($root.LocalName)'."
        }

        $problemNodes = @($document.SelectNodes(
            "//*[local-name()='test-case' and (@result='Failed' or @result='Error' or @result='Inconclusive' or @label='Error')]"
        ))
        $detectedErrorCount = @($problemNodes | Where-Object {
            $_.GetAttribute('result') -eq 'Error' -or $_.GetAttribute('label') -eq 'Error'
        }).Count
        if ($analysis.format -eq 'NUNIT3' -and $nunit3HasExplicitErrors) {
            if ($detectedErrorCount -gt $analysis.errors) {
                throw "NUnit XML contains $detectedErrorCount Error test cases but reports only $($analysis.errors) errors."
            }
        } elseif ($analysis.format -eq 'NUNIT3') {
            if ($detectedErrorCount -gt $analysis.failed) {
                throw "NUnit XML contains $detectedErrorCount Error test cases but reports only $($analysis.failed) failed tests."
            }
            $analysis.failed -= $detectedErrorCount
            $analysis.errors = $detectedErrorCount
        } else {
            if ($detectedErrorCount -gt $analysis.errors) {
                throw "Legacy NUnit XML contains $detectedErrorCount Error test cases but reports only $($analysis.errors) errors."
            }
        }
        foreach ($countName in @('total', 'passed', 'failed', 'errors', 'skipped', 'inconclusive', 'assertions')) {
            if ([int]$analysis[$countName] -lt 0) {
                throw "NUnit count '$countName' is negative."
            }
        }
        $sum = $analysis.passed + $analysis.failed + $analysis.errors + $analysis.skipped + $analysis.inconclusive
        if ($sum -ne $analysis.total) {
            throw "NUnit counts are inconsistent: total=$($analysis.total), classified=$sum."
        }
        $analysis.executed = $analysis.passed + $analysis.failed + $analysis.errors + $analysis.inconclusive
        $details = New-Object System.Collections.ArrayList
        foreach ($node in @($problemNodes | Sort-Object -Property @{ Expression = { [string]$_.GetAttribute('fullname') } }) | Select-Object -First 100) {
            $failure = $node.SelectSingleNode("./*[local-name()='failure']")
            $message = if ($null -ne $failure) { $failure.SelectSingleNode("./*[local-name()='message']") } else { $null }
            $stack = if ($null -ne $failure) { $failure.SelectSingleNode("./*[local-name()='stack-trace']") } else { $null }
            [void]$details.Add([ordered]@{
                name = [string]$node.GetAttribute('fullname')
                result = [string]$node.GetAttribute('result')
                label = [string]$node.GetAttribute('label')
                message = ConvertTo-UevBoundedDiagnostic -Value $(if ($null -ne $message) { [string]$message.InnerText } else { $null })
                stackTrace = ConvertTo-UevBoundedDiagnostic -Value $(if ($null -ne $stack) { [string]$stack.InnerText } else { $null })
            })
        }
        $analysis.problemDetails = @($details)
        $analysis.problemDetailsTruncated = $problemNodes.Count -gt 100

        if ($analysis.total -eq 0) {
            $analysis.classification = 'ZERO_TESTS'
        } elseif ($analysis.failed -gt 0 -or $analysis.errors -gt 0 -or $analysis.rootResult -match '^(Failed|Error)$') {
            $analysis.classification = 'FAILED'
        } elseif ($analysis.inconclusive -gt 0) {
            $analysis.classification = 'INCONCLUSIVE'
        } elseif ($analysis.passed -le 0) {
            $analysis.classification = 'NO_EXECUTED_TESTS'
        } elseif ($analysis.rootResult -notmatch '^(Passed|Success)$') {
            $analysis.classification = 'INCONCLUSIVE'
        } elseif ($analysis.skipped -gt 0) {
            $analysis.classification = 'PASSED_WITH_SKIPS'
        } else {
            $analysis.classification = 'PASSED'
        }
    } catch {
        $analysis.classification = 'INVALID'
        $analysis.error = $_.Exception.Message
    }
    return [pscustomobject]$analysis
}

# Extracts required safety and failure evidence from an EditMode Editor.log.
function Get-UevEditorLogAnalysis {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedUnityVersion,
        [Parameter(Mandatory = $true)][string]$ExpectedProjectPath
    )

    $analysis = [ordered]@{
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
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]$analysis
    }

    $analysis.exists = $true
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $analysis.byteLength = [long]$item.Length
    $analysis.sha256 = Get-UevFileSha256 -Path $Path
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $lines = @([regex]::Split($text, '\r?\n'))
    $versionMatch = [regex]::Match($text, "(?m)^Built from .+? Version is '(?<version>\d+\.\d+\.\d+[abfp]\d+)")
    if (-not $versionMatch.Success) {
        $versionMatch = [regex]::Match($text, '(?m)^Initialize engine version:\s*(?<version>\d+\.\d+\.\d+[abfp]\d+)')
    }
    if ($versionMatch.Success) {
        $analysis.detectedUnityVersion = $versionMatch.Groups['version'].Value
        $analysis.versionMatched = $analysis.detectedUnityVersion -ceq $ExpectedUnityVersion
    }
    $analysis.batchModeObserved = [regex]::IsMatch($text, '(?m)^BatchMode:\s*1\b')
    $analysis.testRunnerObserved = [regex]::IsMatch($text, '(?im)(runTests|test run|TestRunner|Test Framework)')
    foreach ($pathMatch in [regex]::Matches($text, '(?m)^Successfully changed project path to:\s*(?<path>.+?)\s*$')) {
        try {
            if ((Get-UevNormalizedPath -Path $pathMatch.Groups['path'].Value).Equals(
                (Get-UevNormalizedPath -Path $ExpectedProjectPath),
                $script:UevPathComparison
            )) {
                $analysis.isolatedProjectPathObserved = $true
                break
            }
        } catch {
        }
    }

    $compilerErrors = New-Object System.Collections.ArrayList
    foreach ($line in $lines) {
        if ([regex]::IsMatch($line, '\berror\s+CS\d{4}\s*:', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            $analysis.compilerErrorCount++
            if ($compilerErrors.Count -lt 100) {
                [void]$compilerErrors.Add((ConvertTo-UevBoundedDiagnostic -Value $line))
            }
        }
    }
    $analysis.compilerErrors = @($compilerErrors)
    $analysis.compilerErrorsTruncated = $analysis.compilerErrorCount -gt 100

    $definitions = @(
        [pscustomobject]@{ code = 'COMPILER_ERROR'; pattern = '\berror\s+CS\d{4}\s*:' },
        [pscustomobject]@{ code = 'SCRIPTS_HAVE_COMPILER_ERRORS'; pattern = 'Scripts have compiler errors' },
        [pscustomobject]@{ code = 'COMPILATION_FAILED'; pattern = '(?:Compilation failed|Failed to compile)' },
        [pscustomobject]@{ code = 'BATCHMODE_ABORTED'; pattern = 'Aborting batchmode due to failure' },
        [pscustomobject]@{ code = 'FATAL_ERROR'; pattern = 'Fatal Error!' },
        [pscustomobject]@{ code = 'CRASH'; pattern = '^Crash!!!\s*$' },
        [pscustomobject]@{ code = 'NONZERO_RETURN_CODE'; pattern = 'Application will terminate with return code [1-9]\d*' },
        [pscustomobject]@{ code = 'PACKAGE_RESOLUTION_FAILED'; pattern = '(?:An error occurred while resolving packages|Package resolution failed)' }
    )
    $failures = New-Object System.Collections.ArrayList
    foreach ($definition in $definitions) {
        foreach ($line in $lines) {
            if ([regex]::IsMatch($line, $definition.pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                [void]$failures.Add([ordered]@{ code = $definition.code; line = ConvertTo-UevBoundedDiagnostic -Value $line })
                break
            }
        }
    }
    if ($null -ne $analysis.detectedUnityVersion -and -not $analysis.versionMatched) {
        [void]$failures.Add([ordered]@{
            code = 'UNITY_LOG_VERSION_MISMATCH'
            line = "Editor.log identifies Unity $($analysis.detectedUnityVersion)."
        })
    }
    $analysis.failureMarkers = @($failures)

    $missing = New-Object System.Collections.ArrayList
    if (-not $analysis.versionMatched) { [void]$missing.Add('unityVersion') }
    if (-not $analysis.batchModeObserved) { [void]$missing.Add('batchMode') }
    if (-not $analysis.isolatedProjectPathObserved) { [void]$missing.Add('isolatedProjectPath') }
    if (-not $analysis.testRunnerObserved) { [void]$missing.Add('testRunner') }
    $analysis.missingRequiredMarkers = @($missing)
    if ($analysis.failureMarkers.Count -gt 0) {
        $analysis.classification = 'FAILURE'
    } elseif ($analysis.missingRequiredMarkers.Count -gt 0) {
        $analysis.classification = 'INCONCLUSIVE'
    } else {
        $analysis.classification = 'SAFE'
    }
    return [pscustomobject]$analysis
}

# Splits a Windows process command line without invoking a command shell.
function ConvertFrom-UevWindowsCommandLine {
    param(
        [Parameter(Mandatory = $true)]
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

# Classifies deterministic process and CIM observations for the source-editor preflight.
function Get-UevSourceEditorAssessment {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter()][AllowEmptyCollection()][object[]]$RunningProcesses = @(),
        [Parameter()][AllowEmptyCollection()][object[]]$CimProcesses = @(),
        [Parameter()][AllowEmptyCollection()][int[]]$StillRunningProcessIds = @()
    )

    $normalizedProjectRoot = Get-UevNormalizedPath -Path $ProjectRoot
    $running = @($RunningProcesses | Sort-Object -Property processId)
    if ($running.Count -eq 0) {
        return [pscustomobject][ordered]@{
            completed = $true
            detected = $false
            processIds = @()
            blockerCode = $null
            detail = 'Get-Process independently reported zero running Unity processes; CIM was unnecessary.'
        }
    }

    $candidateIds = New-Object 'System.Collections.Generic.List[int]'
    foreach ($process in $running) {
        $candidateIds.Add([int](Get-UevJsonProperty -InputObject $process -Name 'processId'))
    }
    foreach ($process in @($CimProcesses)) {
        $candidateIds.Add([int](Get-UevJsonProperty -InputObject $process -Name 'processId'))
    }
    $sourceIds = New-Object System.Collections.ArrayList
    foreach ($processId in @($candidateIds | Sort-Object -Unique)) {
        $matches = @($CimProcesses | Where-Object { [int](Get-UevJsonProperty -InputObject $_ -Name 'processId') -eq $processId })
        if ($matches.Count -ne 1) {
            if ($StillRunningProcessIds -contains $processId) {
                return [pscustomobject][ordered]@{
                    completed = $false; detected = $null; processIds = @(); blockerCode = 'SOURCE_EDITOR_PREFLIGHT_UNAVAILABLE'
                    detail = "Live Unity process $processId could not be matched to exactly one CIM row."
                }
            }
            continue
        }
        if ($StillRunningProcessIds -notcontains $processId) {
            continue
        }
        $commandLine = [string](Get-UevJsonProperty -InputObject $matches[0] -Name 'commandLine')
        if ([string]::IsNullOrWhiteSpace($commandLine)) {
            return [pscustomobject][ordered]@{
                completed = $false; detected = $null; processIds = @(); blockerCode = 'SOURCE_EDITOR_PREFLIGHT_UNAVAILABLE'
                detail = "Unity process $processId had no readable CommandLine."
            }
        }
        try {
            $tokens = ConvertFrom-UevWindowsCommandLine -CommandLine $commandLine
            $projectPaths = New-Object System.Collections.ArrayList
            for ($index = 0; $index -lt $tokens.Count; $index++) {
                if ($tokens[$index] -ieq '-projectPath') {
                    if (($index + 1) -ge $tokens.Count) {
                        throw '-projectPath has no value.'
                    }
                    [void]$projectPaths.Add((Get-UevNormalizedPath -Path $tokens[$index + 1]))
                    $index++
                }
            }
            if ($projectPaths.Count -ne 1) {
                throw "Expected one -projectPath, observed $($projectPaths.Count)."
            }
            if ([string]$projectPaths[0] -eq $normalizedProjectRoot) {
                [void]$sourceIds.Add($processId)
            }
        } catch {
            return [pscustomobject][ordered]@{
                completed = $false; detected = $null; processIds = @(); blockerCode = 'SOURCE_EDITOR_PREFLIGHT_UNAVAILABLE'
                detail = "Unity process $processId could not be associated safely: $($_.Exception.Message)"
            }
        }
    }

    $orderedIds = @($sourceIds | Sort-Object -Unique)
    return [pscustomobject][ordered]@{
        completed = $true
        detected = $orderedIds.Count -gt 0
        processIds = $orderedIds
        blockerCode = if ($orderedIds.Count -gt 0) { 'SOURCE_PROJECT_OPEN_IN_UNITY' } else { $null }
        detail = if ($orderedIds.Count -gt 0) {
            "The source project is open in Unity process ID(s): $([string]::Join(', ', [string[]]$orderedIds))."
        } else {
            'Every still-running Unity process was safely associated with a different project; exited PIDs were ignored as a normal race.'
        }
    }
}

# Compares a fresh Unity executable observation to an accepted Baseline record.
function Get-UevUnityTrustAssessment {
    param(
        [Parameter(Mandatory = $true)][object]$BaselineUnity,
        [Parameter(Mandatory = $true)][object]$CurrentUnity,
        [Parameter(Mandatory = $true)][string]$ExpectedUnityVersion
    )

    $errors = New-Object System.Collections.ArrayList
    foreach ($comparison in @(
        [pscustomobject]@{ name = 'executablePath'; expected = [string](Get-UevJsonProperty $BaselineUnity 'executablePath'); actual = [string](Get-UevJsonProperty $CurrentUnity 'executablePath') },
        [pscustomobject]@{ name = 'executableSha256'; expected = [string](Get-UevJsonProperty $BaselineUnity 'executableSha256'); actual = [string](Get-UevJsonProperty $CurrentUnity 'executableSha256') },
        [pscustomobject]@{ name = 'detectedExecutableVersion'; expected = [string](Get-UevJsonProperty $BaselineUnity 'detectedExecutableVersion'); actual = [string](Get-UevJsonProperty $CurrentUnity 'detectedExecutableVersion') },
        [pscustomobject]@{ name = 'signatureStatus'; expected = [string](Get-UevJsonProperty $BaselineUnity 'signatureStatus'); actual = [string](Get-UevJsonProperty $CurrentUnity 'signatureStatus') },
        [pscustomobject]@{ name = 'signerSubject'; expected = [string](Get-UevJsonProperty $BaselineUnity 'signerSubject'); actual = [string](Get-UevJsonProperty $CurrentUnity 'signerSubject') },
        [pscustomobject]@{ name = 'certificateThumbprint'; expected = [string](Get-UevJsonProperty $BaselineUnity 'certificateThumbprint'); actual = [string](Get-UevJsonProperty $CurrentUnity 'certificateThumbprint') }
    )) {
        if (-not ([string]$comparison.expected).Equals([string]$comparison.actual, [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$errors.Add("Unity $($comparison.name) changed after Baseline verification.")
        }
    }
    if ([string](Get-UevJsonProperty $CurrentUnity 'detectedExecutableVersion') -ne $ExpectedUnityVersion) {
        [void]$errors.Add("Unity executable is not exact version $ExpectedUnityVersion.")
    }
    if ([string](Get-UevJsonProperty $CurrentUnity 'signatureStatus') -ne 'Valid') {
        [void]$errors.Add('Unity Authenticode signature is not currently valid.')
    }
    if (-not [bool](Get-UevJsonProperty $CurrentUnity 'publisherMatched')) {
        [void]$errors.Add('Unity signer does not identify Unity Technologies.')
    }
    return [pscustomobject][ordered]@{ accepted = $errors.Count -eq 0; errors = @($errors) }
}

# Selects the public final status from already classified evidence with fixed precedence.
function Get-UevFinalStatus {
    param(
        [Parameter(Mandatory = $true)][string]$OriginalIntegrityStatus,
        [Parameter(Mandatory = $true)][string]$GitIntegrityStatus,
        [Parameter(Mandatory = $true)][int]$FailureCount,
        [Parameter(Mandatory = $true)][int]$BlockerCount,
        [Parameter(Mandatory = $true)][bool]$NoConfirmedAssembly,
        [Parameter(Mandatory = $true)][string]$ScriptCompilationStatus,
        [Parameter(Mandatory = $true)][string]$EditModeStatus
    )

    if ($OriginalIntegrityStatus -eq 'CHANGED' -or $GitIntegrityStatus -eq 'CHANGED') {
        return 'ORIGINAL_PROJECT_CHANGED'
    }
    if ($FailureCount -gt 0) {
        return 'EDITMODE_FAILED'
    }
    if ($NoConfirmedAssembly -and $BlockerCount -eq 0) {
        return 'NO_CONFIRMED_TEST_ASSEMBLY'
    }
    if ($BlockerCount -gt 0 -or $OriginalIntegrityStatus -eq 'BLOCKED' -or $GitIntegrityStatus -eq 'BLOCKED') {
        return 'EDITMODE_BLOCKED'
    }
    if (
        $ScriptCompilationStatus -eq 'VERIFIED_SUCCESS' -and
        $EditModeStatus -eq 'VERIFIED_SUCCESS' -and
        $OriginalIntegrityStatus -eq 'UNCHANGED' -and
        @('NOT_PRESENT', 'UNCHANGED', 'AMBIENT_CODEX_CHECKPOINTS_ONLY') -contains $GitIntegrityStatus
    ) {
        return 'EDITMODE_VERIFIED'
    }
    return 'EDITMODE_BLOCKED'
}
