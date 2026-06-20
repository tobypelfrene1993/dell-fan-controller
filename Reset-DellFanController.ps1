[CmdletBinding()]
param(
    [string]$StatePath,
    [switch]$UseMockBackend,
    [switch]$UseDellCctkBackend,
    [string]$MockFailureMode = 'None',
    [string]$CctkPath = 'C:\Program Files (x86)\Dell\Command Configure\X86_64\cctk.exe',
    [int]$CommandTimeoutSeconds = 15,
    [object]$AllowHardwareWrites = $false,
    [string]$HardwareWriteConfirmation,
    [switch]$ForceIfOwned,
    [switch]$ClearStateAfterVerifiedRestore,
    [string]$Reason = 'ManualRecovery',
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

. (Join-Path $ScriptDirectory 'DellFanController-State.ps1')
. (Join-Path $ScriptDirectory 'FanBackend.Contract.ps1')
. (Join-Path $ScriptDirectory 'FanBackend.Mock.ps1')
. (Join-Path $ScriptDirectory 'FanBackend.DellCctk.ps1')
. (Join-Path $ScriptDirectory 'DellCctk.ProcessExecutor.ps1')

function Get-ResetDefaultStatePath {
    Join-Path (Join-Path $ScriptDirectory 'logs') 'dell-fan-controller-state.mock.json'
}

function Get-ResetDefaultDellCctkStatePath {
    Join-Path (Join-Path $ScriptDirectory 'logs') 'dell-fan-controller-state.dellcctk.json'
}

function Test-ResetMockFailureMode {
    param([string]$Value)
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
    ) -contains $Value
}

function New-ResetResult {
    param(
        [string]$StatePath,
        [bool]$StateFound,
        [string]$StateSource,
        [string]$RecoveryAction,
        [bool]$OwnershipProven,
        [string]$BackendName,
        [string]$BackendStateBefore,
        [bool]$RestoreAttempted,
        [bool]$EmergencyResetAttempted,
        [string]$BackendStateAfter,
        [bool]$VerifiedAutomatic,
        [string]$OperationPhaseBefore,
        [string]$OperationPhaseAfter,
        [bool]$RequiresEmergencyReset,
        [bool]$StateCleared,
        [string]$Result,
        [int]$ExitCode,
        [string]$Message
    )

    [pscustomobject]@{
        StatePath = $StatePath
        StateFound = [bool]$StateFound
        StateSource = $StateSource
        RecoveryAction = $RecoveryAction
        OwnershipProven = [bool]$OwnershipProven
        BackendName = $BackendName
        BackendStateBefore = $BackendStateBefore
        RestoreAttempted = [bool]$RestoreAttempted
        EmergencyResetAttempted = [bool]$EmergencyResetAttempted
        BackendStateAfter = $BackendStateAfter
        VerifiedAutomatic = [bool]$VerifiedAutomatic
        OperationPhaseBefore = $OperationPhaseBefore
        OperationPhaseAfter = $OperationPhaseAfter
        RequiresEmergencyReset = [bool]$RequiresEmergencyReset
        StateCleared = [bool]$StateCleared
        Result = $Result
        ExitCode = [int]$ExitCode
        Message = $Message
    }
}

function Test-ResetOwnership {
    param(
        [object]$State,
        [string]$BackendName
    )

    if ($null -eq $State) { return $false }
    if ($State.FanOverrideActivatedByThisApp -ne $true) { return $false }
    if ([string]$State.BackendName -ne $BackendName) { return $false }
    if (@('ActiveVerified','DisablePending','CleanupRequired') -notcontains [string]$State.OperationPhase) { return $false }
    if (-not (Test-GuidString -Value $State.ControllerInstanceId)) { return $false }
    if (-not (Test-GuidString -Value $State.CorrelationId)) { return $false }
    $true
}

function Set-ResetCleanupRequired {
    param(
        [string]$Path,
        [object]$State,
        [string]$Message
    )

    if ($null -eq $State) { return }
    $cleanup = Mark-ControllerEmergencyReset -State $State -ErrorMessage $Message
    [void](Write-ControllerStateAtomic -Path $Path -State $cleanup)
}

function Write-ResetConsoleResult {
    param([object]$Result)
    Write-Host "StatePath: $($Result.StatePath)"
    Write-Host "State gevonden: $(if ($Result.StateFound) { 'ja' } else { 'nee' })"
    Write-Host "Statebron: $($Result.StateSource)"
    Write-Host "RecoveryAction: $($Result.RecoveryAction)"
    Write-Host "OwnershipProven: $($Result.OwnershipProven)"
    Write-Host "BackendName: $($Result.BackendName)"
    Write-Host "Backendstatus voor reset: $($Result.BackendStateBefore)"
    Write-Host "Restore geprobeerd: $(if ($Result.RestoreAttempted) { 'ja' } else { 'nee' })"
    Write-Host "Emergency reset geprobeerd: $(if ($Result.EmergencyResetAttempted) { 'ja' } else { 'nee' })"
    Write-Host "Backendstatus na reset: $($Result.BackendStateAfter)"
    Write-Host "VerifiedAutomatic: $($Result.VerifiedAutomatic)"
    Write-Host "OperationPhase voor: $($Result.OperationPhaseBefore)"
    Write-Host "OperationPhase na: $($Result.OperationPhaseAfter)"
    Write-Host "RequiresEmergencyReset: $($Result.RequiresEmergencyReset)"
    Write-Host "State gewist: $(if ($Result.StateCleared) { 'ja' } else { 'nee' })"
    Write-Host "Resultaat: $($Result.Result)"
    Write-Host "Exitcode: $($Result.ExitCode)"
}

function Invoke-DellFanControllerReset {
    param(
        [string]$StatePath,
        [bool]$UseMockBackend,
        [bool]$UseDellCctkBackend,
        [string]$MockFailureMode = 'None',
        [string]$CctkPath = 'C:\Program Files (x86)\Dell\Command Configure\X86_64\cctk.exe',
        [int]$CommandTimeoutSeconds = 15,
        [object]$AllowHardwareWrites = $false,
        [string]$HardwareWriteConfirmation,
        [bool]$ForceIfOwned,
        [bool]$ClearStateAfterVerifiedRestore,
        [string]$Reason = 'ManualRecovery',
        [object]$Backend
    )

    if ($UseMockBackend -and $UseDellCctkBackend) {
        $pathForError = if ([string]::IsNullOrWhiteSpace($StatePath)) { Get-ResetDefaultStatePath } else { $StatePath }
        return New-ResetResult -StatePath $pathForError -StateFound $false -StateSource 'None' -RecoveryAction 'InvalidParameters' -OwnershipProven $false -BackendName 'Unknown' -BackendStateBefore $null -RestoreAttempted $false -EmergencyResetAttempted $false -BackendStateAfter $null -VerifiedAutomatic $false -OperationPhaseBefore $null -OperationPhaseAfter $null -RequiresEmergencyReset $false -StateCleared $false -Result 'BackendSelectionConflict' -ExitCode 10 -Message 'Gebruik exact een backend: UseMockBackend of UseDellCctkBackend.'
    }

    $backendNameForError = if ($UseDellCctkBackend) { 'DellCctk' } else { 'MockFanBackend' }
    $resolvedStatePath = if ([string]::IsNullOrWhiteSpace($StatePath)) {
        if ($UseDellCctkBackend) { Get-ResetDefaultDellCctkStatePath } else { Get-ResetDefaultStatePath }
    } else { $StatePath }

    if (-not ($UseMockBackend -or $UseDellCctkBackend)) {
        return New-ResetResult -StatePath $resolvedStatePath -StateFound $false -StateSource 'None' -RecoveryAction 'RejectUnsupportedBackend' -OwnershipProven $false -BackendName 'MockFanBackend' -BackendStateBefore $null -RestoreAttempted $false -EmergencyResetAttempted $false -BackendStateAfter $null -VerifiedAutomatic $false -OperationPhaseBefore $null -OperationPhaseAfter $null -RequiresEmergencyReset $false -StateCleared $false -Result 'OnlyMockBackendSupported' -ExitCode 10 -Message 'Alleen MockFanBackend wordt ondersteund; gebruik -UseMockBackend.'
    }

    if ($UseMockBackend -and -not (Test-ResetMockFailureMode -Value $MockFailureMode)) {
        return New-ResetResult -StatePath $resolvedStatePath -StateFound $false -StateSource 'None' -RecoveryAction 'InvalidParameters' -OwnershipProven $false -BackendName 'MockFanBackend' -BackendStateBefore $null -RestoreAttempted $false -EmergencyResetAttempted $false -BackendStateAfter $null -VerifiedAutomatic $false -OperationPhaseBefore $null -OperationPhaseAfter $null -RequiresEmergencyReset $false -StateCleared $false -Result 'InvalidMockFailureMode' -ExitCode 10 -Message "Ongeldige MockFailureMode: $MockFailureMode"
    }

    if ($UseDellCctkBackend) {
        $writeAllowed = ($AllowHardwareWrites -is [bool] -and $AllowHardwareWrites -eq $true)
        $confirmationValid = ([string]$HardwareWriteConfirmation -eq 'RESTORE_DELL_AUTOMATIC_FAN_CONTROL')
        if (-not ($writeAllowed -and $confirmationValid)) {
            return New-ResetResult -StatePath $resolvedStatePath -StateFound (Test-Path -LiteralPath $resolvedStatePath -PathType Leaf) -StateSource 'Unknown' -RecoveryAction 'RejectUnconfirmedDellWrite' -OwnershipProven $false -BackendName $backendNameForError -BackendStateBefore $null -RestoreAttempted $false -EmergencyResetAttempted $false -BackendStateAfter $null -VerifiedAutomatic $false -OperationPhaseBefore $null -OperationPhaseAfter $null -RequiresEmergencyReset $false -StateCleared $false -Result 'HardwareWriteConfirmationRequired' -ExitCode 10 -Message 'DellCctk reset vereist AllowHardwareWrites als boolean true en exacte HardwareWriteConfirmation.'
        }
    }

    if ($null -eq $Backend) {
        if ($UseDellCctkBackend) {
            $executor = New-DellCctkProcessExecutor -AllowHardwareWrites $AllowHardwareWrites
            $Backend = New-DellCctkFanBackend -CctkPath $CctkPath -CommandTimeoutSeconds $CommandTimeoutSeconds -AllowHardwareWrites $AllowHardwareWrites -CommandExecutor $executor
        } else {
            $Backend = New-MockFanBackend -FailureMode $MockFailureMode
        }
    }
    $availability = Invoke-FanBackendAvailabilityCheck -Backend $Backend
    if (-not $availability.Success) {
        return New-ResetResult -StatePath $resolvedStatePath -StateFound (Test-Path -LiteralPath $resolvedStatePath -PathType Leaf) -StateSource 'Unknown' -RecoveryAction 'AvailabilityCheck' -OwnershipProven $false -BackendName $Backend.BackendName -BackendStateBefore $null -RestoreAttempted $false -EmergencyResetAttempted $false -BackendStateAfter $null -VerifiedAutomatic $false -OperationPhaseBefore $null -OperationPhaseAfter $null -RequiresEmergencyReset $false -StateCleared $false -Result 'BackendUnavailable' -ExitCode 12 -Message $availability.ErrorMessage
    }

    $read = Read-ControllerState -Path $resolvedStatePath
    if (-not $read.Success -and -not $read.Found) {
        return New-ResetResult -StatePath $resolvedStatePath -StateFound $false -StateSource 'None' -RecoveryAction 'NoAction' -OwnershipProven $false -BackendName $Backend.BackendName -BackendStateBefore $Backend.RuntimeState.CurrentFanState -RestoreAttempted $false -EmergencyResetAttempted $false -BackendStateAfter $Backend.RuntimeState.CurrentFanState -VerifiedAutomatic ([string]$Backend.RuntimeState.CurrentFanState -eq 'Automatic') -OperationPhaseBefore $null -OperationPhaseAfter $null -RequiresEmergencyReset $false -StateCleared $false -Result 'NoStateFound' -ExitCode 0 -Message 'Geen state of backup gevonden.'
    }
    if (-not $read.Success) {
        return New-ResetResult -StatePath $resolvedStatePath -StateFound $true -StateSource 'None' -RecoveryAction 'FailClosed' -OwnershipProven $false -BackendName $Backend.BackendName -BackendStateBefore $Backend.RuntimeState.CurrentFanState -RestoreAttempted $false -EmergencyResetAttempted $false -BackendStateAfter $Backend.RuntimeState.CurrentFanState -VerifiedAutomatic $false -OperationPhaseBefore $null -OperationPhaseAfter $null -RequiresEmergencyReset $false -StateCleared $false -Result 'CorruptStateAndBackup' -ExitCode 11 -Message ($read.Errors -join '; ')
    }

    $state = $read.State
    $phaseBefore = [string]$state.OperationPhase
    $stateSource = [string]$read.Source
    $ownership = Test-ResetOwnership -State $state -BackendName $Backend.BackendName
    $backendStateBeforeResult = Get-FanBackendControlState -Backend $Backend
    $backendStateBefore = $backendStateBeforeResult.NewState
    $restoreAttempted = $false
    $emergencyAttempted = $false
    $verified = $false
    $stateCleared = $false
    $resultName = ''
    $exitCode = 0
    $message = ''

    switch ($phaseBefore) {
        'Idle' {
            $resultName = 'NoActionRequired'
            $verified = ([string]$backendStateBefore -eq 'Automatic')
        }
        'Restored' {
            $resultName = 'AlreadyRestored'
            $verified = ([string]$backendStateBefore -eq 'Automatic')
        }
        'EnablePending' {
            if (-not $backendStateBeforeResult.Success -or [string]$backendStateBefore -eq 'Unknown') {
                Set-ResetCleanupRequired -Path $resolvedStatePath -State $state -Message 'EnablePending backendstatus kon niet veilig worden geverifieerd.'
                $resultName = 'BackendStateUnknown'
                $exitCode = 21
            } elseif ([string]$backendStateBefore -eq 'Automatic') {
                $restored = Set-ControllerStatePhase -State $state -OperationPhase 'Restored'
                [void](Write-ControllerStateAtomic -Path $resolvedStatePath -State $restored)
                $resultName = 'RestoredFromAutomatic'
                $verified = $true
            } elseif ([string]$backendStateBefore -eq 'BoostEnabled') {
                $active = Set-ControllerStatePhase -State $state -OperationPhase 'ActiveVerified'
                [void](Write-ControllerStateAtomic -Path $resolvedStatePath -State $active)
                $restoreAttempted = $true
                $restore = Restore-FanBackendAutomaticControl -Backend $Backend -StatePath $resolvedStatePath -CorrelationId ([guid]::NewGuid().ToString()) -Reason $Reason
                if ($restore.Success -and $restore.Verified -and [string]$restore.NewState -eq 'Automatic') {
                    $resultName = 'Restored'
                    $verified = $true
                } else {
                    $resultName = 'RestoreFailed'
                    $exitCode = 30
                }
            }
        }
        'ActiveVerified' {
            if (-not $ownership) {
                $resultName = 'OwnershipNotProven'
                $exitCode = 20
            } else {
                $restoreAttempted = $true
                $restore = Restore-FanBackendAutomaticControl -Backend $Backend -StatePath $resolvedStatePath -CorrelationId ([guid]::NewGuid().ToString()) -Reason $Reason
                if ($restore.Success -and $restore.Verified -and [string]$restore.NewState -eq 'Automatic') {
                    $resultName = 'Restored'
                    $verified = $true
                } else {
                    $resultName = 'RestoreFailed'
                    $exitCode = 30
                }
            }
        }
        'DisablePending' {
            if (-not $ownership) {
                $resultName = 'OwnershipNotProven'
                $exitCode = 20
            } else {
                $restoreAttempted = $true
                $restore = Restore-FanBackendAutomaticControl -Backend $Backend -StatePath $resolvedStatePath -CorrelationId ([guid]::NewGuid().ToString()) -Reason $Reason
                if ($restore.Success -and $restore.Verified -and [string]$restore.NewState -eq 'Automatic') {
                    $resultName = 'Restored'
                    $verified = $true
                } else {
                    $resultName = 'RestoreFailed'
                    $exitCode = 30
                }
            }
        }
        'CleanupRequired' {
            if (-not ($ownership -and $ForceIfOwned)) {
                $resultName = 'OwnershipNotProven'
                $exitCode = 20
            } else {
                $emergencyAttempted = $true
                $reset = Invoke-FanBackendEmergencyReset -Backend $Backend -StatePath $resolvedStatePath -CorrelationId ([guid]::NewGuid().ToString()) -Reason $Reason -ForceIfOwned
                if ($reset.Success -and $reset.Verified -and [string]$reset.NewState -eq 'Automatic') {
                    $resultName = 'EmergencyResetSucceeded'
                    $verified = $true
                } else {
                    $resultName = 'EmergencyResetFailed'
                    $exitCode = 32
                }
            }
        }
        default {
            $resultName = 'InvalidState'
            $exitCode = 11
        }
    }

    $afterRead = Read-ControllerState -Path $resolvedStatePath
    $phaseAfter = if ($afterRead.Success) { [string]$afterRead.State.OperationPhase } else { $null }
    $requiresReset = if ($afterRead.Success) { [bool]$afterRead.State.RequiresEmergencyReset } else { $false }
    $backendAfter = Get-FanBackendControlState -Backend $Backend
    $backendStateAfter = $backendAfter.NewState
    if ($backendAfter.Success -and $backendAfter.Verified -and [string]$backendAfter.NewState -eq 'Automatic') { $verified = $true }

    if ($ClearStateAfterVerifiedRestore -and $exitCode -eq 0) {
        $clear = Clear-ControllerState -Path $resolvedStatePath
        if ($clear.Success) {
            $stateCleared = $true
            $phaseAfter = $null
            $requiresReset = $false
        } else {
            $exitCode = 40
            $resultName = 'ClearStateFailed'
            $message = $clear.Error
        }
    }

    New-ResetResult -StatePath $resolvedStatePath -StateFound $true -StateSource $stateSource -RecoveryAction $resultName -OwnershipProven $ownership -BackendName $Backend.BackendName -BackendStateBefore $backendStateBefore -RestoreAttempted $restoreAttempted -EmergencyResetAttempted $emergencyAttempted -BackendStateAfter $backendStateAfter -VerifiedAutomatic $verified -OperationPhaseBefore $phaseBefore -OperationPhaseAfter $phaseAfter -RequiresEmergencyReset $requiresReset -StateCleared $stateCleared -Result $resultName -ExitCode $exitCode -Message $message
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $result = Invoke-DellFanControllerReset -StatePath $StatePath -UseMockBackend ([bool]$UseMockBackend) -UseDellCctkBackend ([bool]$UseDellCctkBackend) -MockFailureMode $MockFailureMode -CctkPath $CctkPath -CommandTimeoutSeconds $CommandTimeoutSeconds -AllowHardwareWrites $AllowHardwareWrites -HardwareWriteConfirmation $HardwareWriteConfirmation -ForceIfOwned ([bool]$ForceIfOwned) -ClearStateAfterVerifiedRestore ([bool]$ClearStateAfterVerifiedRestore) -Reason $Reason
        if ($Json) {
            $result | ConvertTo-Json -Depth 6
        } else {
            Write-ResetConsoleResult -Result $result
        }
        exit ([int]$result.ExitCode)
    }
    catch {
        $fallbackPath = if ([string]::IsNullOrWhiteSpace($StatePath)) { Get-ResetDefaultStatePath } else { $StatePath }
        $result = New-ResetResult -StatePath $fallbackPath -StateFound $false -StateSource 'Unknown' -RecoveryAction 'UnexpectedError' -OwnershipProven $false -BackendName 'MockFanBackend' -BackendStateBefore $null -RestoreAttempted $false -EmergencyResetAttempted $false -BackendStateAfter $null -VerifiedAutomatic $false -OperationPhaseBefore $null -OperationPhaseAfter $null -RequiresEmergencyReset $false -StateCleared $false -Result 'UnexpectedError' -ExitCode 99 -Message $_.Exception.Message
        if ($Json) { $result | ConvertTo-Json -Depth 6 } else { Write-ResetConsoleResult -Result $result }
        exit 99
    }
}
