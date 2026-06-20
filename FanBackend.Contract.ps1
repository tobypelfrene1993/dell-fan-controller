[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$stateModulePath = Join-Path $scriptDirectory 'DellFanController-State.ps1'
. $stateModulePath

function New-FanBackendResult {
    param(
        [bool]$Success,
        [string]$Action,
        [string]$PreviousState,
        [string]$NewState,
        [bool]$Verified,
        [bool]$RequiresCleanup,
        [string]$ErrorCode,
        [string]$ErrorMessage,
        [object]$Diagnostics
    )

    [pscustomobject]@{
        Success = [bool]$Success
        Action = [string]$Action
        PreviousState = $PreviousState
        NewState = $NewState
        Verified = [bool]$Verified
        RequiresCleanup = [bool]$RequiresCleanup
        ErrorCode = $ErrorCode
        ErrorMessage = $ErrorMessage
        Diagnostics = $Diagnostics
    }
}

function Test-FanBackendContract {
    param([object]$Backend)

    $errors = @()
    $requiredProperties = @('BackendName', 'BackendType', 'Version', 'RequiresAdmin', 'Operations', 'RuntimeState', 'ActionLog')
    $requiredOperations = @('TestAvailability', 'GetState', 'EnableBoost', 'RestoreAutomatic', 'EmergencyReset')
    $supportedOperations = @()

    if ($null -eq $Backend) {
        return [pscustomobject]@{ IsValid = $false; Errors = @('Backend ontbreekt.'); BackendName = $null; BackendType = $null; SupportedOperations = @() }
    }

    $propertyNames = @($Backend.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($property in $requiredProperties) {
        if ($propertyNames -notcontains $property) { $errors += "Verplichte backend-property ontbreekt: $property." }
    }

    if ($propertyNames -contains 'BackendName' -and [string]::IsNullOrWhiteSpace([string]$Backend.BackendName)) {
        $errors += 'BackendName mag niet leeg zijn.'
    }
    if ($propertyNames -contains 'BackendType' -and @('Mock', 'DellCctk') -notcontains [string]$Backend.BackendType) {
        $errors += "BackendType is ongeldig: $($Backend.BackendType)."
    }

    if ($propertyNames -contains 'Operations') {
        if ($null -eq $Backend.Operations) {
            $errors += 'Operations ontbreekt.'
        } else {
            $operationNames = @($Backend.Operations.PSObject.Properties | ForEach-Object { $_.Name })
            foreach ($operation in $requiredOperations) {
                if ($operationNames -notcontains $operation) {
                    $errors += "Verplichte backend-operation ontbreekt: $operation."
                } elseif ($Backend.Operations.$operation -isnot [scriptblock]) {
                    $errors += "Backend-operation is geen ScriptBlock: $operation."
                } else {
                    $supportedOperations += $operation
                }
            }
        }
    }

    [pscustomobject]@{
        IsValid = ($errors.Count -eq 0)
        Errors = @($errors)
        BackendName = if ($propertyNames -contains 'BackendName') { $Backend.BackendName } else { $null }
        BackendType = if ($propertyNames -contains 'BackendType') { $Backend.BackendType } else { $null }
        SupportedOperations = @($supportedOperations)
    }
}

function Assert-FanBackendContract {
    param([object]$Backend)
    $validation = Test-FanBackendContract -Backend $Backend
    if (-not $validation.IsValid) {
        throw "Backendcontract ongeldig: $(@($validation.Errors) -join '; ')"
    }
}

function Invoke-FanBackendAvailabilityCheck {
    param(
        [object]$Backend,
        [int]$TimeoutSeconds = 10
    )

    try {
        Assert-FanBackendContract -Backend $Backend
        $result = & $Backend.Operations.TestAvailability $Backend $TimeoutSeconds
        if ($result.Success -ne $true) { return $result }
        return $result
    }
    catch {
        New-FanBackendResult -Success $false -Action 'TestAvailability' -PreviousState $null -NewState $null -Verified $false -RequiresCleanup $false -ErrorCode 'AvailabilityException' -ErrorMessage $_.Exception.Message -Diagnostics $null
    }
}

function Get-FanBackendControlState {
    param([object]$Backend)

    try {
        Assert-FanBackendContract -Backend $Backend
        $result = & $Backend.Operations.GetState $Backend
        if ($result.Success -ne $true) { return $result }
        if (@('Automatic', 'BoostEnabled', 'Unknown') -notcontains [string]$result.NewState) {
            return New-FanBackendResult -Success $false -Action 'GetState' -PreviousState $result.PreviousState -NewState $result.NewState -Verified $false -RequiresCleanup $false -ErrorCode 'InvalidState' -ErrorMessage "Backend retourneerde een onbekende fanstatus: $($result.NewState)." -Diagnostics $result
        }
        $result.Verified = ([string]$result.NewState -ne 'Unknown')
        return $result
    }
    catch {
        New-FanBackendResult -Success $false -Action 'GetState' -PreviousState $null -NewState $null -Verified $false -RequiresCleanup $false -ErrorCode 'GetStateException' -ErrorMessage $_.Exception.Message -Diagnostics $null
    }
}

function Write-BackendCleanupState {
    param(
        [string]$StatePath,
        [object]$BaseState,
        [string]$ErrorMessage
    )

    $cleanupState = Mark-ControllerEmergencyReset -State $BaseState -ErrorMessage $ErrorMessage
    [void](Write-ControllerStateAtomic -Path $StatePath -State $cleanupState)
    $cleanupState
}

function Enable-FanBackendBoost {
    param(
        [object]$Backend,
        [string]$StatePath,
        [string]$ControllerInstanceId,
        [string]$CorrelationId,
        [string]$Reason
    )

    $pendingState = $null
    try {
        Assert-FanBackendContract -Backend $Backend
        $read = Read-ControllerState -Path $StatePath
        if (-not $read.Success) {
            return New-FanBackendResult -Success $false -Action 'EnableBoost' -PreviousState $null -NewState $null -Verified $false -RequiresCleanup $false -ErrorCode 'StateReadFailed' -ErrorMessage ($read.Errors -join '; ') -Diagnostics $read
        }
        $decision = Get-ControllerRecoveryDecision -State $read.State
        if (-not $decision.AllowNewEnable) {
            return New-FanBackendResult -Success $false -Action 'EnableBoost' -PreviousState $read.State.CurrentRequestedState -NewState $read.State.CurrentRequestedState -Verified $false -RequiresCleanup $decision.CleanupRequired -ErrorCode 'EnableBlocked' -ErrorMessage $decision.Reason -Diagnostics $decision
        }

        $pendingState = Set-ControllerStatePhase -State $read.State -OperationPhase 'EnablePending'
        $pendingState.ControllerInstanceId = $ControllerInstanceId
        $pendingState.CorrelationId = $CorrelationId
        $pendingWrite = Write-ControllerStateAtomic -Path $StatePath -State $pendingState
        if (-not $pendingWrite.Success) { throw "EnablePending kon niet worden geschreven: $($pendingWrite.Error)" }

        $enableResult = & $Backend.Operations.EnableBoost $Backend $CorrelationId $Reason
        if ($enableResult.Success -ne $true) { throw $enableResult.ErrorMessage }

        $stateResult = Get-FanBackendControlState -Backend $Backend
        if (-not ($stateResult.Success -and $stateResult.Verified -and [string]$stateResult.NewState -eq 'BoostEnabled')) {
            throw "Enable-verificatie faalde: $($stateResult.ErrorMessage)"
        }

        $activeState = Set-ControllerStatePhase -State $pendingState -OperationPhase 'ActiveVerified'
        [void](Write-ControllerStateAtomic -Path $StatePath -State $activeState)
        New-FanBackendResult -Success $true -Action 'EnableBoost' -PreviousState $enableResult.PreviousState -NewState 'BoostEnabled' -Verified $true -RequiresCleanup $false -ErrorCode $null -ErrorMessage $null -Diagnostics $stateResult
    }
    catch {
        if ($null -ne $pendingState) { [void](Write-BackendCleanupState -StatePath $StatePath -BaseState $pendingState -ErrorMessage $_.Exception.Message) }
        New-FanBackendResult -Success $false -Action 'EnableBoost' -PreviousState $(if ($null -ne $pendingState) { $pendingState.PreviousFanState } else { $null }) -NewState $null -Verified $false -RequiresCleanup $true -ErrorCode 'EnableFailed' -ErrorMessage $_.Exception.Message -Diagnostics $null
    }
}

function Restore-FanBackendAutomaticControl {
    param(
        [object]$Backend,
        [string]$StatePath,
        [string]$CorrelationId,
        [string]$Reason
    )

    $disableState = $null
    try {
        Assert-FanBackendContract -Backend $Backend
        $read = Read-ControllerState -Path $StatePath
        if (-not $read.Success) {
            return New-FanBackendResult -Success $false -Action 'RestoreAutomatic' -PreviousState $null -NewState $null -Verified $false -RequiresCleanup $false -ErrorCode 'StateReadFailed' -ErrorMessage ($read.Errors -join '; ') -Diagnostics $read
        }
        if ([string]$read.State.OperationPhase -eq 'Restored' -and [string]$read.State.CurrentRequestedState -eq 'Automatic') {
            return New-FanBackendResult -Success $true -Action 'RestoreAutomatic' -PreviousState 'Automatic' -NewState 'Automatic' -Verified $true -RequiresCleanup $false -ErrorCode $null -ErrorMessage $null -Diagnostics 'Already restored.'
        }
        $decision = Get-ControllerRecoveryDecision -State $read.State
        if (-not $decision.OwnershipProven) {
            return New-FanBackendResult -Success $false -Action 'RestoreAutomatic' -PreviousState $read.State.CurrentRequestedState -NewState $read.State.CurrentRequestedState -Verified $false -RequiresCleanup $decision.CleanupRequired -ErrorCode 'OwnershipNotProven' -ErrorMessage $decision.Reason -Diagnostics $decision
        }

        $disableState = Set-ControllerStatePhase -State $read.State -OperationPhase 'DisablePending'
        $disableState.CorrelationId = $CorrelationId
        [void](Write-ControllerStateAtomic -Path $StatePath -State $disableState)

        $restoreResult = & $Backend.Operations.RestoreAutomatic $Backend $CorrelationId $Reason
        if ($restoreResult.Success -ne $true) { throw $restoreResult.ErrorMessage }

        $stateResult = Get-FanBackendControlState -Backend $Backend
        if (-not ($stateResult.Success -and $stateResult.Verified -and [string]$stateResult.NewState -eq 'Automatic')) {
            throw "Restore-verificatie faalde: $($stateResult.ErrorMessage)"
        }

        $restoredState = Set-ControllerStatePhase -State $disableState -OperationPhase 'Restored'
        [void](Write-ControllerStateAtomic -Path $StatePath -State $restoredState)
        New-FanBackendResult -Success $true -Action 'RestoreAutomatic' -PreviousState $restoreResult.PreviousState -NewState 'Automatic' -Verified $true -RequiresCleanup $false -ErrorCode $null -ErrorMessage $null -Diagnostics $stateResult
    }
    catch {
        if ($null -ne $disableState) { [void](Write-BackendCleanupState -StatePath $StatePath -BaseState $disableState -ErrorMessage $_.Exception.Message) }
        New-FanBackendResult -Success $false -Action 'RestoreAutomatic' -PreviousState $(if ($null -ne $disableState) { $disableState.PreviousFanState } else { $null }) -NewState $null -Verified $false -RequiresCleanup $true -ErrorCode 'RestoreFailed' -ErrorMessage $_.Exception.Message -Diagnostics $null
    }
}

function Invoke-FanBackendEmergencyReset {
    param(
        [object]$Backend,
        [string]$StatePath,
        [string]$CorrelationId,
        [string]$Reason,
        [switch]$ForceIfOwned
    )

    $baseState = $null
    try {
        Assert-FanBackendContract -Backend $Backend
        $read = Read-ControllerState -Path $StatePath
        if (-not $read.Success) {
            return New-FanBackendResult -Success $false -Action 'EmergencyReset' -PreviousState $null -NewState $null -Verified $false -RequiresCleanup $false -ErrorCode 'StateReadFailed' -ErrorMessage ($read.Errors -join '; ') -Diagnostics $read
        }
        $baseState = $read.State
        if ([string]$baseState.OperationPhase -eq 'Restored') {
            return New-FanBackendResult -Success $true -Action 'EmergencyReset' -PreviousState 'Automatic' -NewState 'Automatic' -Verified $true -RequiresCleanup $false -ErrorCode $null -ErrorMessage $null -Diagnostics 'Already restored.'
        }
        $decision = Get-ControllerRecoveryDecision -State $baseState
        if (-not ($decision.OwnershipProven -and $ForceIfOwned)) {
            return New-FanBackendResult -Success $false -Action 'EmergencyReset' -PreviousState $baseState.CurrentRequestedState -NewState $baseState.CurrentRequestedState -Verified $false -RequiresCleanup $decision.CleanupRequired -ErrorCode 'OwnershipNotProven' -ErrorMessage 'Emergency reset geweigerd: ownership niet bewezen of ForceIfOwned ontbreekt.' -Diagnostics $decision
        }

        $resetResult = & $Backend.Operations.EmergencyReset $Backend $CorrelationId $Reason
        if ($resetResult.Success -ne $true) { throw $resetResult.ErrorMessage }
        $stateResult = Get-FanBackendControlState -Backend $Backend
        if (-not ($stateResult.Success -and $stateResult.Verified -and [string]$stateResult.NewState -eq 'Automatic')) {
            throw "Emergency reset-verificatie faalde: $($stateResult.ErrorMessage)"
        }

        $restoredState = Set-ControllerStatePhase -State $baseState -OperationPhase 'Restored'
        $restoredState.CorrelationId = $CorrelationId
        [void](Write-ControllerStateAtomic -Path $StatePath -State $restoredState)
        New-FanBackendResult -Success $true -Action 'EmergencyReset' -PreviousState $resetResult.PreviousState -NewState 'Automatic' -Verified $true -RequiresCleanup $false -ErrorCode $null -ErrorMessage $null -Diagnostics $stateResult
    }
    catch {
        if ($null -ne $baseState) { [void](Write-BackendCleanupState -StatePath $StatePath -BaseState $baseState -ErrorMessage $_.Exception.Message) }
        New-FanBackendResult -Success $false -Action 'EmergencyReset' -PreviousState $(if ($null -ne $baseState) { $baseState.CurrentRequestedState } else { $null }) -NewState $null -Verified $false -RequiresCleanup $true -ErrorCode 'EmergencyResetFailed' -ErrorMessage $_.Exception.Message -Diagnostics $null
    }
}
