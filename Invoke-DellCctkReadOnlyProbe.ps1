[CmdletBinding()]
param(
    [string]$CctkPath = 'C:\Program Files (x86)\Dell\Command Configure\X86_64\cctk.exe',
    [int]$CommandTimeoutSeconds = 15,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

. (Join-Path $ScriptDirectory 'FanBackend.Contract.ps1')
. (Join-Path $ScriptDirectory 'FanBackend.DellCctk.ps1')
. (Join-Path $ScriptDirectory 'DellCctk.ProcessExecutor.ps1')

function New-ProbeResult {
    param(
        [string]$CctkPath,
        [string]$FileVersion,
        [string]$ProductVersion,
        [bool]$Availability,
        [object]$ExitCode,
        [bool]$TimedOut,
        [string]$StdErr,
        [string]$ParsedFanState,
        [bool]$Verified,
        [bool]$HardwareWritesAllowed,
        [string]$ExecutedArgument,
        [string]$Result,
        [int]$ExitCodeResult,
        [string]$Message
    )
    [pscustomobject]@{
        CctkPath = $CctkPath
        FileVersion = $FileVersion
        ProductVersion = $ProductVersion
        Availability = [bool]$Availability
        CommandExitCode = $ExitCode
        TimedOut = [bool]$TimedOut
        StdErr = $StdErr
        ParsedFanState = $ParsedFanState
        Verified = [bool]$Verified
        HardwareWritesAllowed = [bool]$HardwareWritesAllowed
        ExecutedArgument = $ExecutedArgument
        Result = $Result
        ExitCode = [int]$ExitCodeResult
        Message = $Message
    }
}

function Write-ProbeResult {
    param([object]$Result)
    Write-Host "cctk-pad: $($Result.CctkPath)"
    Write-Host "FileVersion: $($Result.FileVersion)"
    Write-Host "ProductVersion: $($Result.ProductVersion)"
    Write-Host "Availability: $($Result.Availability)"
    Write-Host "ExitCode: $($Result.CommandExitCode)"
    Write-Host "TimedOut: $($Result.TimedOut)"
    Write-Host "StdErr: $($Result.StdErr)"
    Write-Host "ParsedFanState: $($Result.ParsedFanState)"
    Write-Host "Verified: $($Result.Verified)"
    Write-Host "HardwareWritesAllowed: $($Result.HardwareWritesAllowed)"
    Write-Host "ExecutedArgument: $($Result.ExecutedArgument)"
    Write-Host "Resultaat: $($Result.Result)"
}

try {
    if ($CommandTimeoutSeconds -lt 1 -or $CommandTimeoutSeconds -gt 300) {
        $result = New-ProbeResult -CctkPath $CctkPath -FileVersion $null -ProductVersion $null -Availability $false -ExitCode $null -TimedOut $false -StdErr '' -ParsedFanState 'Unknown' -Verified $false -HardwareWritesAllowed $false -ExecutedArgument '--FanCtrlOvrd' -Result 'InvalidTimeout' -ExitCodeResult 10 -Message 'CommandTimeoutSeconds moet tussen 1 en 300 liggen.'
    } else {
        $pathCheck = Test-DellCctkPath -CctkPath $CctkPath -MinimumVersion '5.2.2.0'
        if (-not $pathCheck.Success) {
            $result = New-ProbeResult -CctkPath $CctkPath -FileVersion $pathCheck.FileVersion -ProductVersion $pathCheck.ProductVersion -Availability $false -ExitCode $null -TimedOut $false -StdErr '' -ParsedFanState 'Unknown' -Verified $false -HardwareWritesAllowed $false -ExecutedArgument '--FanCtrlOvrd' -Result 'InvalidPath' -ExitCodeResult 10 -Message ($pathCheck.Errors -join '; ')
        } else {
            $executor = New-DellCctkProcessExecutor -AllowHardwareWrites $false
            $backend = New-DellCctkFanBackend -CctkPath $CctkPath -CommandTimeoutSeconds $CommandTimeoutSeconds -AllowHardwareWrites $false -CommandExecutor $executor
            $availability = & $backend.Operations.TestAvailability $backend $CommandTimeoutSeconds
            $state = & $backend.Operations.GetState $backend
            $lastLog = @($backend.ActionLog)[@($backend.ActionLog).Count - 1]
            $executedArgument = @($lastLog.AllowlistedArguments)[0]
            if ($executedArgument -ne '--FanCtrlOvrd') { throw "Probe probeerde een niet-read-only argument: $executedArgument" }
            if (@($backend.ActionLog | Where-Object { $_.IsWriteOperation }).Count -gt 0) { throw 'Probe bevat write-operatie in actionlog.' }
            $diagnostics = $state.Diagnostics
            $exit = 0
            $resultName = 'ReadOnlyProbeSucceeded'
            if (-not $availability.Success) { $exit = 11; $resultName = 'BackendUnavailable' }
            elseif ($diagnostics.TimedOut) { $exit = 12; $resultName = 'Timeout' }
            elseif ($diagnostics.ExitCode -ne 0) { $exit = 13; $resultName = 'NonZeroExitCode' }
            elseif (-not ($state.Success -and $state.Verified)) { $exit = 14; $resultName = 'ParseOrVerificationFailed' }
            $result = New-ProbeResult -CctkPath $CctkPath -FileVersion $pathCheck.FileVersion -ProductVersion $pathCheck.ProductVersion -Availability $availability.Success -ExitCode $diagnostics.ExitCode -TimedOut $diagnostics.TimedOut -StdErr $diagnostics.StdErr -ParsedFanState $state.NewState -Verified $state.Verified -HardwareWritesAllowed $backend.AllowHardwareWrites -ExecutedArgument $executedArgument -Result $resultName -ExitCodeResult $exit -Message $state.ErrorMessage
        }
    }
    if ($Json) { $result | ConvertTo-Json -Depth 6 } else { Write-ProbeResult -Result $result }
    exit ([int]$result.ExitCode)
}
catch {
    $result = New-ProbeResult -CctkPath $CctkPath -FileVersion $null -ProductVersion $null -Availability $false -ExitCode $null -TimedOut $false -StdErr '' -ParsedFanState 'Unknown' -Verified $false -HardwareWritesAllowed $false -ExecutedArgument '--FanCtrlOvrd' -Result 'UnexpectedError' -ExitCodeResult 99 -Message $_.Exception.Message
    if ($Json) { $result | ConvertTo-Json -Depth 6 } else { Write-ProbeResult -Result $result }
    exit 99
}
