Set-StrictMode -Version Latest

$script:ProductionSupportVersion = '2026-06-19-session-v1'

function New-ProductionDellCctkBackend {
    param(
        [object]$Config,
        [object]$AllowHardwareWrites = $false,
        [scriptblock]$ProcessInvoker
    )

    $executorParams = @{
        AllowHardwareWrites = $AllowHardwareWrites
        DefaultTimeoutSeconds = [int]$Config.CommandTimeoutSeconds
    }
    if ($PSBoundParameters.ContainsKey('ProcessInvoker')) {
        $executorParams.ProcessInvoker = $ProcessInvoker
    }

    $executor = New-DellCctkProcessExecutor @executorParams
    New-DellCctkFanBackend -CctkPath $Config.CctkPath -CommandTimeoutSeconds $Config.CommandTimeoutSeconds -AllowHardwareWrites $AllowHardwareWrites -CommandExecutor $executor
}

function New-ProductionDellCctkSession {
    param(
        [object]$Config,
        [object]$AllowHardwareWrites = $false,
        [scriptblock]$ProcessInvoker
    )

    $executorParams = @{
        AllowHardwareWrites = $AllowHardwareWrites
        DefaultTimeoutSeconds = [int]$Config.CommandTimeoutSeconds
    }
    $processInvokerUsed = $null
    if ($PSBoundParameters.ContainsKey('ProcessInvoker')) {
        $executorParams.ProcessInvoker = $ProcessInvoker
        $processInvokerUsed = $ProcessInvoker
    }

    $executor = New-DellCctkProcessExecutor @executorParams
    $backend = New-DellCctkFanBackend -CctkPath $Config.CctkPath -CommandTimeoutSeconds $Config.CommandTimeoutSeconds -AllowHardwareWrites $AllowHardwareWrites -CommandExecutor $executor
    $availability = Invoke-ProductionReadOnlyBackendAvailability -Backend $backend -CommandTimeoutSeconds $Config.CommandTimeoutSeconds
    $beginState = if ($availability.Success) { Get-ProductionReadOnlyBeginState -Backend $backend } else { $null }

    [pscustomobject]@{
        Backend = $backend
        CommandExecutor = $executor
        ProcessInvoker = $processInvokerUsed
        AvailabilityResult = $availability
        BeginStateResult = $beginState
        AutomaticVerified = (Test-ProductionAutomaticFanState -StateResult $beginState)
        Diagnostics = [pscustomobject]@{
            ProductionSupportVersion = $script:ProductionSupportVersion
            ProcessExecutorVersion = $script:ProcessExecutorVersion
            BackendObjectType = if ($null -ne $backend) { $backend.GetType().FullName } else { $null }
            ExecutorObjectType = if ($null -ne $executor) { $executor.GetType().FullName } else { $null }
            Started = if ($null -ne $beginState -and $null -ne $beginState.Diagnostics) { $beginState.Diagnostics.Started } else { $null }
            ExitCode = if ($null -ne $beginState -and $null -ne $beginState.Diagnostics) { $beginState.Diagnostics.ExitCode } else { $null }
            ErrorCode = if ($null -ne $beginState) { $beginState.ErrorCode } else { $null }
        }
    }
}

function Test-ProductionAutomaticFanState {
    param([object]$StateResult)

    if ($null -eq $StateResult) { return $false }
    $names = @($StateResult.PSObject.Properties | ForEach-Object { $_.Name })
    if ($names -notcontains 'Success' -or $names -notcontains 'Verified' -or $names -notcontains 'NewState') { return $false }
    ($StateResult.Success -eq $true -and $StateResult.Verified -eq $true -and [string]$StateResult.NewState -eq 'Automatic')
}

function Invoke-ProductionReadOnlyBackendAvailability {
    param(
        [object]$Backend,
        [int]$CommandTimeoutSeconds
    )

    try {
        Assert-FanBackendContract -Backend $Backend
        $path = Test-DellCctkPath -CctkPath $Backend.CctkPath -MinimumVersion $Backend.MinimumVersion
        if (-not $path.Success) {
            return New-FanBackendResult -Success $false -Action 'TestAvailability' -PreviousState $null -NewState 'Unknown' -Verified $false -RequiresCleanup $false -ErrorCode 'InvalidPath' -ErrorMessage ($path.Errors -join '; ') -Diagnostics $path
        }
        New-FanBackendResult -Success $true -Action 'TestAvailability' -PreviousState $null -NewState 'Unknown' -Verified $false -RequiresCleanup $false -ErrorCode $null -ErrorMessage $null -Diagnostics $path
    }
    catch {
        New-FanBackendResult -Success $false -Action 'TestAvailability' -PreviousState $null -NewState 'Unknown' -Verified $false -RequiresCleanup $false -ErrorCode 'AvailabilityException' -ErrorMessage $_.Exception.Message -Diagnostics $null
    }
}

function Get-ProductionReadOnlyBeginState {
    param([object]$Backend)

    try {
        Assert-FanBackendContract -Backend $Backend
        & $Backend.Operations.GetState $Backend
    }
    catch {
        New-FanBackendResult -Success $false -Action 'GetState' -PreviousState $null -NewState 'Unknown' -Verified $false -RequiresCleanup $false -ErrorCode 'GetStateException' -ErrorMessage $_.Exception.Message -Diagnostics $null
    }
}

function Get-ProductionSafeActionLogEntry {
    param([object]$Backend)

    if ($null -eq $Backend) { return $null }
    $log = @($Backend.ActionLog)
    if ($log.Count -eq 0) { return $null }
    $last = $log[$log.Count - 1]
    [pscustomobject]@{
        Operation = $last.Operation
        IsWriteOperation = [bool]$last.IsWriteOperation
        ParsedState = $last.ParsedState
        Verified = [bool]$last.Verified
        Success = [bool]$last.Success
        ExitCode = $last.ExitCode
        TimedOut = [bool]$last.TimedOut
        ErrorMessage = $last.ErrorMessage
        ExecutedArgument = if (@($last.AllowlistedArguments).Count -gt 0) { [string]@($last.AllowlistedArguments)[0] } else { $null }
    }
}

function Convert-ProductionBackendResultForJson {
    param([object]$Result)

    if ($null -eq $Result) { return $null }
    [pscustomobject]@{
        Success = $Result.Success
        Action = $Result.Action
        PreviousState = $Result.PreviousState
        NewState = $Result.NewState
        Verified = $Result.Verified
        RequiresCleanup = $Result.RequiresCleanup
        ErrorCode = $Result.ErrorCode
        ErrorMessage = $Result.ErrorMessage
        Diagnostics = $Result.Diagnostics
    }
}

function Format-ProductionBeginStateFailureMessage {
    param(
        [object]$BeginState,
        [object]$Backend
    )

    $last = Get-ProductionSafeActionLogEntry -Backend $Backend
    $parts = @('Beginstatus is niet geverifieerd Automatic.')
    if ($null -ne $BeginState) {
        $parts += "ProductionSupportVersion=$script:ProductionSupportVersion"
        $parts += "ProcessExecutorVersion=$script:ProcessExecutorVersion"
        if ($null -ne $Backend) {
            $parts += "BackendObjectType=$($Backend.GetType().FullName)"
            $parts += "ExecutorObjectType=$(if ($null -ne $Backend.CommandExecutor) { $Backend.CommandExecutor.GetType().FullName } else { $null })"
        }
        $parts += "Success=$($BeginState.Success)"
        $parts += "NewState=$($BeginState.NewState)"
        $parts += "Verified=$($BeginState.Verified)"
        $parts += "ErrorCode=$($BeginState.ErrorCode)"
        $parts += "ErrorMessage=$($BeginState.ErrorMessage)"
        if ($null -ne $BeginState.Diagnostics) {
            $parts += "Started=$($BeginState.Diagnostics.Started)"
            $parts += "ExitCode=$($BeginState.Diagnostics.ExitCode)"
            $parts += "Diagnostics=$($BeginState.Diagnostics | ConvertTo-Json -Depth 5 -Compress)"
        }
    } else {
        $parts += 'BeginState=<null>'
    }
    if ($null -ne $last) {
        $parts += "LastAction=$($last | ConvertTo-Json -Depth 5 -Compress)"
    }
    $parts -join ' '
}
