[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VerifierPath,

    [Parameter(Mandatory = $true)]
    [ValidateSet(
        'zero-cim-denied',
        'get-process-denied',
        'cim-denied',
        'source-project-open',
        'other-project-open',
        'process-exit-race',
        'cim-pid-missing-live',
        'command-line-missing'
    )]
    [string]$Scenario,

    [Parameter(Mandatory = $true)]
    [string]$CimCallMarkerPath,

    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [Parameter(Mandatory = $true)]
    [string]$DoctorResultPath,

    [Parameter(Mandatory = $true)]
    [string]$UnityExecutable,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactsRoot,

    [Parameter()]
    [int]$TimeoutSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$global:SourceEditorFixtureScenario = $Scenario
$global:SourceEditorFixtureCimCallMarkerPath = $CimCallMarkerPath
$global:SourceEditorFixtureProjectRoot = $ProjectRoot
$global:SourceEditorFixtureUnityProcessId = 4102

# Creates a deterministic process object for the source-editor preflight fixture.
function New-FixtureUnityProcess {
    return [pscustomobject][ordered]@{
        Id = $global:SourceEditorFixtureUnityProcessId
        ProcessName = 'Unity'
    }
}

# Shadows Get-Process only in this test child and models initial enumeration plus PID liveness races.
function Get-Process {
    [CmdletBinding()]
    param(
        [Parameter()]
        [int[]]$Id
    )

    if ($null -eq $Id -or $Id.Count -eq 0) {
        if ($global:SourceEditorFixtureScenario -eq 'get-process-denied') {
            throw [System.UnauthorizedAccessException]::new('Fixture denied Get-Process enumeration.')
        }
        if ($global:SourceEditorFixtureScenario -eq 'zero-cim-denied') {
            return @()
        }
        return @(New-FixtureUnityProcess)
    }

    if ($global:SourceEditorFixtureScenario -eq 'process-exit-race') {
        $record = [System.Management.Automation.ErrorRecord]::new(
            ([System.InvalidOperationException]::new("Cannot find a process with process ID $($Id[0]).")),
            'NoProcessFoundForGivenId',
            [System.Management.Automation.ErrorCategory]::ObjectNotFound,
            $Id[0]
        )
        $PSCmdlet.ThrowTerminatingError($record)
    }

    return @(New-FixtureUnityProcess)
}

# Records every CIM attempt and returns or throws the selected deterministic fixture observation.
function Get-CimInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClassName,

        [Parameter()]
        [string]$Filter
    )

    if ($ClassName -ne 'Win32_Process' -or $Filter -ne "Name = 'Unity.exe'") {
        throw "Unexpected CIM query: class=$ClassName filter=$Filter"
    }

    $markerParent = Split-Path -Parent $global:SourceEditorFixtureCimCallMarkerPath
    [void][System.IO.Directory]::CreateDirectory($markerParent)
    [System.IO.File]::AppendAllText($global:SourceEditorFixtureCimCallMarkerPath, "called`n", (New-Object System.Text.UTF8Encoding($false)))

    if (@('zero-cim-denied', 'cim-denied') -contains $global:SourceEditorFixtureScenario) {
        throw [System.UnauthorizedAccessException]::new('Fixture denied CIM access.')
    }
    if (@('process-exit-race', 'cim-pid-missing-live') -contains $global:SourceEditorFixtureScenario) {
        return @()
    }

    $commandLine = switch ($global:SourceEditorFixtureScenario) {
        'source-project-open' { '"C:\Program Files\Unity\Editor\Unity.exe" -projectPath "' + $global:SourceEditorFixtureProjectRoot + '"' }
        'other-project-open' { '"C:\Program Files\Unity\Editor\Unity.exe" -projectPath "C:\Unity\DifferentProject"' }
        'command-line-missing' { $null }
        default { throw "Unsupported CIM fixture scenario: $global:SourceEditorFixtureScenario" }
    }

    return @([pscustomobject][ordered]@{
        ProcessId = $global:SourceEditorFixtureUnityProcessId
        ExecutablePath = 'C:\Program Files\Unity\Editor\Unity.exe'
        CommandLine = $commandLine
    })
}

& $VerifierPath `
    -ProjectRoot $ProjectRoot `
    -DoctorResultPath $DoctorResultPath `
    -UnityExecutable $UnityExecutable `
    -ArtifactsRoot $ArtifactsRoot `
    -TimeoutSeconds $TimeoutSeconds

exit 0
