[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$contractPath = Join-Path $scriptDirectory 'FanBackend.Contract.ps1'
. $contractPath

function Test-MockFanState {
    param([string]$State)
    @('Automatic', 'BoostEnabled', 'Unknown') -contains $State
}

function Test-MockFailureMode {
    param([string]$FailureMode)
    @(
        'None',
        'Unavailable',
        'ThrowOnAvailability',
        'ThrowOnGetState',
        'ThrowOnEnable',
        'ThrowOnRestore',
        'EnableVerificationFails',
        'RestoreVerificationFails',
        'ReturnUnknownAfterEnable',
        'ReturnUnknownAfterRestore'
    ) -contains $FailureMode
}

function Add-MockFanBackendAction {
    param(
        [object]$Backend,
        [string]$Action,
        [string]$PreviousState,
        [string]$RequestedState,
        [string]$ResultState,
        [bool]$Success,
        [string]$ErrorMessage,
        [string]$CorrelationId,
        [string]$Reason,
        [bool]$EffectiveStateChanged
    )

    $entry = [pscustomobject]@{
        TimestampUtc = ([DateTime]::UtcNow).ToString('o')
        Action = $Action
        PreviousState = $PreviousState
        RequestedState = $RequestedState
        ResultState = $ResultState
        Success = [bool]$Success
        ErrorMessage = $ErrorMessage
        CorrelationId = $CorrelationId
        Reason = $Reason
        EffectiveStateChanged = [bool]$EffectiveStateChanged
    }
    $Backend.ActionLog = @($Backend.ActionLog) + $entry
    $entry
}

function New-MockFanBackend {
    param(
        [string]$InitialState = 'Automatic',
        [string]$FailureMode = 'None',
        [string]$BackendName = 'MockFanBackend'
    )

    if (-not (Test-MockFanState -State $InitialState)) { throw "Ongeldige InitialState: $InitialState" }
    if (-not (Test-MockFailureMode -FailureMode $FailureMode)) { throw "Ongeldige FailureMode: $FailureMode" }
    if ([string]::IsNullOrWhiteSpace($BackendName)) { throw 'BackendName mag niet leeg zijn.' }

    $backend = [pscustomobject]@{
        BackendName = $BackendName
        BackendType = 'Mock'
        Version = '1.0'
        RequiresAdmin = $false
        Operations = $null
        RuntimeState = [pscustomobject]@{
            CurrentFanState = $InitialState
            FailureMode = $FailureMode
            EnableCallCount = 0
            RestoreCallCount = 0
            GetStateCallCount = 0
            AvailabilityCallCount = 0
            EffectiveEnableCount = 0
            EffectiveRestoreCount = 0
        }
        ActionLog = @()
    }

    $backend.Operations = [pscustomobject]@{
        TestAvailability = {
            param([object]$Backend, [int]$TimeoutSeconds)
            $Backend.RuntimeState.AvailabilityCallCount++
            if ($Backend.RuntimeState.FailureMode -eq 'ThrowOnAvailability') { throw 'Mock availability exception.' }
            $available = ($Backend.RuntimeState.FailureMode -ne 'Unavailable')
            [void](Add-MockFanBackendAction -Backend $Backend -Action 'TestAvailability' -PreviousState $Backend.RuntimeState.CurrentFanState -RequestedState $Backend.RuntimeState.CurrentFanState -ResultState $Backend.RuntimeState.CurrentFanState -Success $available -ErrorMessage $(if ($available) { $null } else { 'Mock backend unavailable.' }) -CorrelationId $null -Reason "TimeoutSeconds=$TimeoutSeconds" -EffectiveStateChanged $false)
            New-FanBackendResult -Success $available -Action 'TestAvailability' -PreviousState $Backend.RuntimeState.CurrentFanState -NewState $Backend.RuntimeState.CurrentFanState -Verified $available -RequiresCleanup $false -ErrorCode $(if ($available) { $null } else { 'Unavailable' }) -ErrorMessage $(if ($available) { $null } else { 'Mock backend unavailable.' }) -Diagnostics $Backend.RuntimeState
        }
        GetState = {
            param([object]$Backend)
            $Backend.RuntimeState.GetStateCallCount++
            if ($Backend.RuntimeState.FailureMode -eq 'ThrowOnGetState') { throw 'Mock get-state exception.' }
            $state = [string]$Backend.RuntimeState.CurrentFanState
            if ($Backend.RuntimeState.FailureMode -eq 'EnableVerificationFails' -or $Backend.RuntimeState.FailureMode -eq 'RestoreVerificationFails') { $state = 'Unknown' }
            if ($Backend.RuntimeState.FailureMode -eq 'ReturnUnknownAfterEnable' -and $Backend.RuntimeState.EnableCallCount -gt 0) { $state = 'Unknown' }
            if ($Backend.RuntimeState.FailureMode -eq 'ReturnUnknownAfterRestore' -and $Backend.RuntimeState.RestoreCallCount -gt 0) { $state = 'Unknown' }
            [void](Add-MockFanBackendAction -Backend $Backend -Action 'GetState' -PreviousState $Backend.RuntimeState.CurrentFanState -RequestedState $null -ResultState $state -Success $true -ErrorMessage $null -CorrelationId $null -Reason $null -EffectiveStateChanged $false)
            New-FanBackendResult -Success $true -Action 'GetState' -PreviousState $Backend.RuntimeState.CurrentFanState -NewState $state -Verified ($state -ne 'Unknown') -RequiresCleanup $false -ErrorCode $null -ErrorMessage $null -Diagnostics $Backend.RuntimeState
        }
        EnableBoost = {
            param([object]$Backend, [string]$CorrelationId, [string]$Reason)
            $Backend.RuntimeState.EnableCallCount++
            $previous = [string]$Backend.RuntimeState.CurrentFanState
            if ($Backend.RuntimeState.FailureMode -eq 'ThrowOnEnable') {
                [void](Add-MockFanBackendAction -Backend $Backend -Action 'EnableBoost' -PreviousState $previous -RequestedState 'BoostEnabled' -ResultState $previous -Success $false -ErrorMessage 'Mock enable exception.' -CorrelationId $CorrelationId -Reason $Reason -EffectiveStateChanged $false)
                throw 'Mock enable exception.'
            }
            $changed = ($previous -ne 'BoostEnabled')
            $Backend.RuntimeState.CurrentFanState = 'BoostEnabled'
            if ($changed) { $Backend.RuntimeState.EffectiveEnableCount++ }
            [void](Add-MockFanBackendAction -Backend $Backend -Action 'EnableBoost' -PreviousState $previous -RequestedState 'BoostEnabled' -ResultState $Backend.RuntimeState.CurrentFanState -Success $true -ErrorMessage $null -CorrelationId $CorrelationId -Reason $Reason -EffectiveStateChanged $changed)
            New-FanBackendResult -Success $true -Action 'EnableBoost' -PreviousState $previous -NewState $Backend.RuntimeState.CurrentFanState -Verified $true -RequiresCleanup $false -ErrorCode $null -ErrorMessage $null -Diagnostics $Backend.RuntimeState
        }
        RestoreAutomatic = {
            param([object]$Backend, [string]$CorrelationId, [string]$Reason)
            $Backend.RuntimeState.RestoreCallCount++
            $previous = [string]$Backend.RuntimeState.CurrentFanState
            if ($Backend.RuntimeState.FailureMode -eq 'ThrowOnRestore') {
                [void](Add-MockFanBackendAction -Backend $Backend -Action 'RestoreAutomatic' -PreviousState $previous -RequestedState 'Automatic' -ResultState $previous -Success $false -ErrorMessage 'Mock restore exception.' -CorrelationId $CorrelationId -Reason $Reason -EffectiveStateChanged $false)
                throw 'Mock restore exception.'
            }
            $changed = ($previous -ne 'Automatic')
            $Backend.RuntimeState.CurrentFanState = 'Automatic'
            if ($changed) { $Backend.RuntimeState.EffectiveRestoreCount++ }
            [void](Add-MockFanBackendAction -Backend $Backend -Action 'RestoreAutomatic' -PreviousState $previous -RequestedState 'Automatic' -ResultState $Backend.RuntimeState.CurrentFanState -Success $true -ErrorMessage $null -CorrelationId $CorrelationId -Reason $Reason -EffectiveStateChanged $changed)
            New-FanBackendResult -Success $true -Action 'RestoreAutomatic' -PreviousState $previous -NewState $Backend.RuntimeState.CurrentFanState -Verified $true -RequiresCleanup $false -ErrorCode $null -ErrorMessage $null -Diagnostics $Backend.RuntimeState
        }
        EmergencyReset = {
            param([object]$Backend, [string]$CorrelationId, [string]$Reason)
            & $Backend.Operations.RestoreAutomatic $Backend $CorrelationId $Reason
        }
    }

    $backend
}

function Set-MockFanBackendFailureMode {
    param(
        [object]$Backend,
        [string]$FailureMode
    )

    if (-not (Test-MockFailureMode -FailureMode $FailureMode)) { throw "Ongeldige FailureMode: $FailureMode" }
    $Backend.RuntimeState.FailureMode = $FailureMode
    $Backend
}

function Get-MockFanBackendActionLog {
    param([object]$Backend)
    @($Backend.ActionLog | ForEach-Object { $_ | ConvertTo-Json -Depth 5 | ConvertFrom-Json })
}
