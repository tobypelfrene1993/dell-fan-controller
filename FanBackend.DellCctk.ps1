[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $scriptDirectory 'FanBackend.Contract.ps1')

$script:DellCctkDefaultPath = 'C:\Program Files (x86)\Dell\Command Configure\X86_64\cctk.exe'

function New-DellCctkActionLogEntry {
    param(
        [object]$Backend,
        [string]$Operation,
        [object]$CommandSpec,
        [string]$CorrelationId,
        [string]$Reason,
        [object]$CommandResult,
        [string]$ParsedState,
        [bool]$Verified,
        [bool]$Success,
        [string]$ErrorMessage
    )

    $entry = [pscustomobject]@{
        TimestampUtc = ([DateTime]::UtcNow).ToString('o')
        BackendName = $Backend.BackendName
        Operation = $Operation
        ExecutablePath = if ($null -ne $CommandSpec) { $CommandSpec.ExecutablePath } else { $Backend.CctkPath }
        AllowlistedArguments = if ($null -ne $CommandSpec) { @($CommandSpec.ArgumentList) } else { @() }
        IsWriteOperation = if ($null -ne $CommandSpec) { [bool]$CommandSpec.IsWriteOperation } else { $false }
        WriteAllowed = [bool]$Backend.AllowHardwareWrites
        CorrelationId = $CorrelationId
        Reason = $Reason
        ExitCode = if ($null -ne $CommandResult) { $CommandResult.ExitCode } else { $null }
        TimedOut = if ($null -ne $CommandResult) { [bool]$CommandResult.TimedOut } else { $false }
        ParsedState = $ParsedState
        Verified = [bool]$Verified
        Success = [bool]$Success
        ErrorMessage = $ErrorMessage
        DurationMs = if ($null -ne $CommandResult) { $CommandResult.DurationMs } else { $null }
    }
    $Backend.ActionLog = @($Backend.ActionLog) + $entry
    $entry
}

function Test-DellCctkPath {
    param(
        [string]$CctkPath = $script:DellCctkDefaultPath,
        [string]$MinimumVersion = '5.2.2.0'
    )

    $errors = @()
    $resolved = $null
    $fileVersion = $null
    $productVersion = $null

    if ([string]::IsNullOrWhiteSpace($CctkPath)) {
        $errors += 'CctkPath ontbreekt.'
    } elseif (-not [IO.Path]::IsPathRooted($CctkPath)) {
        $errors += 'CctkPath moet absoluut zijn.'
    } else {
        try {
            $full = [IO.Path]::GetFullPath($CctkPath)
            if ($full -ne $CctkPath) { $errors += 'Resolved path wijkt af van geconfigureerd pad.' }
            $resolved = $full
            if ([IO.Path]::GetFileName($full) -ne 'cctk.exe') { $errors += 'Bestandsnaam moet exact cctk.exe zijn.' }
            if ([IO.Path]::GetExtension($full) -ne '.exe') { $errors += 'Bestandsextensie moet .exe zijn.' }
            $lower = $full.ToLowerInvariant()
            $temp = [IO.Path]::GetTempPath().TrimEnd('\').ToLowerInvariant()
            $downloads = (Join-Path $env:USERPROFILE 'Downloads').ToLowerInvariant()
            if ($lower.StartsWith($temp) -or $lower.StartsWith($downloads) -or $lower -match '\\test-output\\') {
                $errors += 'CctkPath mag niet onder Temp, Downloads of testdirectory staan.'
            }
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
                $errors += 'CctkPath bestaat niet als bestand.'
            } else {
                $item = Get-Item -LiteralPath $full
                if ($item.Attributes -band [IO.FileAttributes]::Directory) { $errors += 'CctkPath mag geen directory zijn.' }
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $errors += 'CctkPath mag geen reparse-point zijn.' }
                $fileVersion = $item.VersionInfo.FileVersion
                $productVersion = $item.VersionInfo.ProductVersion
                if ([string]::IsNullOrWhiteSpace($fileVersion)) {
                    $errors += 'FileVersion is niet leesbaar.'
                } else {
                    try {
                        if ([version]$fileVersion -lt [version]$MinimumVersion) { $errors += "FileVersion is lager dan minimumversie $MinimumVersion." }
                    } catch {
                        $errors += 'FileVersion of MinimumVersion kan niet als versie worden gelezen.'
                    }
                }
            }
        } catch {
            $errors += $_.Exception.Message
        }
    }

    [pscustomobject]@{
        Success = ($errors.Count -eq 0)
        ResolvedPath = $resolved
        FileVersion = $fileVersion
        ProductVersion = $productVersion
        Errors = @($errors)
    }
}

function New-DellCctkCommandSpec {
    param(
        [string]$Operation,
        [object]$Backend
    )

    $executable = if ($null -ne $Backend) { [string]$Backend.CctkPath } else { $script:DellCctkDefaultPath }
    $timeout = if ($null -ne $Backend) { [int]$Backend.CommandTimeoutSeconds } else { 15 }
    switch ($Operation) {
        'QueryFanControlState' {
            [pscustomobject]@{ Operation = $Operation; ExecutablePath = $executable; ArgumentList = @('--FanCtrlOvrd'); IsWriteOperation = $false; ExpectedOutputPattern = '^FanCtrlOvrd=(Disabled|Enabled)$'; TimeoutSeconds = $timeout }
        }
        'EnableFanBoost' {
            [pscustomobject]@{ Operation = $Operation; ExecutablePath = $executable; ArgumentList = @('--FanCtrlOvrd=Enabled'); IsWriteOperation = $true; ExpectedOutputPattern = '^FanCtrlOvrd=Enabled$'; TimeoutSeconds = $timeout }
        }
        'RestoreAutomaticFanControl' {
            [pscustomobject]@{ Operation = $Operation; ExecutablePath = $executable; ArgumentList = @('--FanCtrlOvrd=Disabled'); IsWriteOperation = $true; ExpectedOutputPattern = '^FanCtrlOvrd=Disabled$'; TimeoutSeconds = $timeout }
        }
        default {
            throw "Onbekende DellCctk-operation: $Operation"
        }
    }
}

function Test-DellCctkCommandSpec {
    param([object]$CommandSpec)
    if ($null -eq $CommandSpec) { return $false }
    $args = @($CommandSpec.ArgumentList)
    if ($args.Count -ne 1) { return $false }
    switch ([string]$CommandSpec.Operation) {
        'QueryFanControlState' { return ($args[0] -eq '--FanCtrlOvrd' -and $CommandSpec.IsWriteOperation -eq $false) }
        'EnableFanBoost' { return ($args[0] -eq '--FanCtrlOvrd=Enabled' -and $CommandSpec.IsWriteOperation -eq $true) }
        'RestoreAutomaticFanControl' { return ($args[0] -eq '--FanCtrlOvrd=Disabled' -and $CommandSpec.IsWriteOperation -eq $true) }
        default { return $false }
    }
}

function ConvertFrom-DellCctkFanStateOutput {
    param([string]$Output)

    $errors = @()
    if ([string]::IsNullOrWhiteSpace($Output)) {
        return [pscustomobject]@{ Success = $false; State = 'Unknown'; RawValue = $null; Errors = @('Output is leeg.') }
    }
    $values = @()
    foreach ($line in (($Output -split "`r?`n") | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        if ($line -match '^(?i)FanCtrlOvrd\s*=\s*(Disabled|Enabled)\s*$') {
            $values += $Matches[1].ToLowerInvariant()
        } elseif ($line -match '(?i)FanCtrlOvrd') {
            $errors += "Onbekende FanCtrlOvrd-regel: $line"
        } else {
            $errors += "Onverwachte outputregel: $line"
        }
    }
    $unique = @($values | Select-Object -Unique)
    if ($errors.Count -gt 0) {
        return [pscustomobject]@{ Success = $false; State = 'Unknown'; RawValue = ($values -join ','); Errors = @($errors) }
    }
    if ($unique.Count -eq 0) {
        return [pscustomobject]@{ Success = $false; State = 'Unknown'; RawValue = $null; Errors = @('Geen statusregel gevonden.') }
    }
    if ($unique.Count -gt 1) {
        return [pscustomobject]@{ Success = $false; State = 'Unknown'; RawValue = ($unique -join ','); Errors = @('Conflicterende statuswaarden gevonden.') }
    }
    switch ($unique[0]) {
        'disabled' { [pscustomobject]@{ Success = $true; State = 'Automatic'; RawValue = 'Disabled'; Errors = @() } }
        'enabled' { [pscustomobject]@{ Success = $true; State = 'BoostEnabled'; RawValue = 'Enabled'; Errors = @() } }
        default { [pscustomobject]@{ Success = $false; State = 'Unknown'; RawValue = $unique[0]; Errors = @('Onbekende statuswaarde.') } }
    }
}

function Invoke-DellCctkCommand {
    param(
        [object]$Backend,
        [object]$CommandSpec,
        [string]$CorrelationId,
        [string]$Reason
    )

    $started = Get-Date
    try {
        Assert-FanBackendContract -Backend $Backend
        if (-not (Test-DellCctkCommandSpec -CommandSpec $CommandSpec)) { throw 'CommandSpec is niet exact allowlisted.' }
        $pathCheck = Test-DellCctkPath -CctkPath $Backend.CctkPath -MinimumVersion $Backend.MinimumVersion
        if (-not $pathCheck.Success) { throw "CctkPath ongeldig: $(@($pathCheck.Errors) -join '; ')" }
        if ($CommandSpec.IsWriteOperation -and $Backend.AllowHardwareWrites -ne $true) { throw 'Hardwarewrites zijn niet toegestaan.' }
        if ($null -eq $Backend.CommandExecutor -or $Backend.CommandExecutor -isnot [scriptblock]) { throw 'CommandExecutor ontbreekt; fail closed.' }
        $raw = & $Backend.CommandExecutor $CommandSpec $CorrelationId $Reason
        $duration = [int]((Get-Date) - $started).TotalMilliseconds
        $rawNames = @($raw.PSObject.Properties | ForEach-Object { $_.Name })
        $rawErrorMessage = if ($rawNames -contains 'ErrorMessage') { $raw.ErrorMessage } else { $null }
        $invalidExecutorResult = ($rawErrorMessage -is [string] -and ([string]$rawErrorMessage).StartsWith('InvalidExecutorResult:'))
        $result = [pscustomobject]@{
            Success = ($raw.ExitCode -eq 0 -and -not [bool]$raw.TimedOut -and -not $invalidExecutorResult)
            ExitCode = $raw.ExitCode
            StdOut = $raw.StdOut
            StdErr = $raw.StdErr
            TimedOut = [bool]$raw.TimedOut
            DurationMs = if ($null -ne $raw.DurationMs) { [int]$raw.DurationMs } else { $duration }
            Started = if ($rawNames -contains 'Started') { [bool]$raw.Started } else { $false }
            ErrorMessage = if ($invalidExecutorResult) { [string]$rawErrorMessage } else { $null }
            ErrorCode = if ($invalidExecutorResult) { 'InvalidExecutorResult' } else { $null }
        }
        [void](New-DellCctkActionLogEntry -Backend $Backend -Operation $CommandSpec.Operation -CommandSpec $CommandSpec -CorrelationId $CorrelationId -Reason $Reason -CommandResult $result -ParsedState $null -Verified $false -Success $result.Success -ErrorMessage $result.ErrorMessage)
        $result
    } catch {
        $duration = [int]((Get-Date) - $started).TotalMilliseconds
        $result = [pscustomobject]@{ Success = $false; ExitCode = $null; StdOut = ''; StdErr = ''; TimedOut = $false; DurationMs = $duration; Started = $false; ErrorMessage = $_.Exception.Message; ErrorCode = 'CommandException' }
        [void](New-DellCctkActionLogEntry -Backend $Backend -Operation $(if ($null -ne $CommandSpec) { $CommandSpec.Operation } else { 'Unknown' }) -CommandSpec $CommandSpec -CorrelationId $CorrelationId -Reason $Reason -CommandResult $result -ParsedState $null -Verified $false -Success $false -ErrorMessage $_.Exception.Message)
        $result
    }
}

function Get-DellCctkFanState {
    param([object]$Backend, [string]$CorrelationId, [string]$Reason)
    $spec = New-DellCctkCommandSpec -Operation 'QueryFanControlState' -Backend $Backend
    $command = Invoke-DellCctkCommand -Backend $Backend -CommandSpec $spec -CorrelationId $CorrelationId -Reason $Reason
    if (-not $command.Success) {
        return New-FanBackendResult -Success $false -Action 'GetState' -PreviousState $null -NewState 'Unknown' -Verified $false -RequiresCleanup $false -ErrorCode $(if ($command.ErrorCode) { $command.ErrorCode } else { 'CommandFailed' }) -ErrorMessage $(if ($command.ErrorMessage) { $command.ErrorMessage } else { 'Query command failed.' }) -Diagnostics $command
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$command.StdErr)) {
        return New-FanBackendResult -Success $false -Action 'GetState' -PreviousState $null -NewState 'Unknown' -Verified $false -RequiresCleanup $false -ErrorCode 'StdErrNotAllowed' -ErrorMessage $command.StdErr -Diagnostics $command
    }
    $parsed = ConvertFrom-DellCctkFanStateOutput -Output $command.StdOut
    $verified = ($parsed.Success -and @('Automatic','BoostEnabled') -contains [string]$parsed.State)
    $last = @($Backend.ActionLog)[@($Backend.ActionLog).Count - 1]
    $last.ParsedState = $parsed.State
    $last.Verified = $verified
    $last.Success = $verified
    if (-not $verified) { $last.ErrorMessage = ($parsed.Errors -join '; ') }
    New-FanBackendResult -Success $verified -Action 'GetState' -PreviousState $null -NewState $parsed.State -Verified $verified -RequiresCleanup $false -ErrorCode $(if ($verified) { $null } else { 'ParseFailed' }) -ErrorMessage $(if ($verified) { $null } else { ($parsed.Errors -join '; ') }) -Diagnostics $command
}

function New-DellCctkFanBackend {
    param(
        [string]$CctkPath = $script:DellCctkDefaultPath,
        [string]$MinimumVersion = '5.2.2.0',
        [int]$CommandTimeoutSeconds = 15,
        [object]$AllowHardwareWrites = $false,
        [scriptblock]$CommandExecutor
    )

    if ($CommandTimeoutSeconds -lt 5 -or $CommandTimeoutSeconds -gt 300) { throw 'CommandTimeoutSeconds moet tussen 5 en 300 liggen.' }
    $writeAllowed = ($null -ne $AllowHardwareWrites -and $AllowHardwareWrites.GetType().FullName -eq 'System.Boolean' -and $AllowHardwareWrites -eq $true)
    $backend = [pscustomobject]@{
        BackendName = 'DellCctk'
        BackendType = 'DellCctk'
        Version = '1.0'
        RequiresAdmin = $true
        Operations = $null
        RuntimeState = [pscustomobject]@{
            CurrentFanState = 'Unknown'
            AvailabilityCallCount = 0
            GetStateCallCount = 0
            EnableCallCount = 0
            RestoreCallCount = 0
            EmergencyResetCallCount = 0
        }
        ActionLog = @()
        CctkPath = $CctkPath
        ExpectedFileName = 'cctk.exe'
        MinimumVersion = $MinimumVersion
        CommandTimeoutSeconds = [int]$CommandTimeoutSeconds
        AllowHardwareWrites = [bool]$writeAllowed
        CommandExecutor = $CommandExecutor
    }
    $backend.Operations = [pscustomobject]@{
        TestAvailability = {
            param([object]$Backend, [int]$TimeoutSeconds)
            $Backend.RuntimeState.AvailabilityCallCount++
            $path = Test-DellCctkPath -CctkPath $Backend.CctkPath -MinimumVersion $Backend.MinimumVersion
            if (-not $path.Success) { return New-FanBackendResult -Success $false -Action 'TestAvailability' -PreviousState $null -NewState 'Unknown' -Verified $false -RequiresCleanup $false -ErrorCode 'InvalidPath' -ErrorMessage ($path.Errors -join '; ') -Diagnostics $path }
            $state = Get-DellCctkFanState -Backend $Backend -CorrelationId $null -Reason "Availability TimeoutSeconds=$TimeoutSeconds"
            New-FanBackendResult -Success $state.Success -Action 'TestAvailability' -PreviousState $null -NewState $state.NewState -Verified $state.Verified -RequiresCleanup $false -ErrorCode $state.ErrorCode -ErrorMessage $state.ErrorMessage -Diagnostics $state.Diagnostics
        }
        GetState = {
            param([object]$Backend)
            $Backend.RuntimeState.GetStateCallCount++
            $state = Get-DellCctkFanState -Backend $Backend -CorrelationId $null -Reason 'GetState'
            if ($state.Success -and $state.Verified) { $Backend.RuntimeState.CurrentFanState = $state.NewState }
            $state
        }
        EnableBoost = {
            param([object]$Backend, [string]$CorrelationId, [string]$Reason)
            $Backend.RuntimeState.EnableCallCount++
            if ($Backend.AllowHardwareWrites -ne $true) { return New-FanBackendResult -Success $false -Action 'EnableBoost' -PreviousState $Backend.RuntimeState.CurrentFanState -NewState $Backend.RuntimeState.CurrentFanState -Verified $false -RequiresCleanup $false -ErrorCode 'WritesDisabled' -ErrorMessage 'Hardwarewrites zijn uitgeschakeld.' -Diagnostics $null }
            $spec = New-DellCctkCommandSpec -Operation 'EnableFanBoost' -Backend $Backend
            $command = Invoke-DellCctkCommand -Backend $Backend -CommandSpec $spec -CorrelationId $CorrelationId -Reason $Reason
            if (-not $command.Success) { return New-FanBackendResult -Success $false -Action 'EnableBoost' -PreviousState $Backend.RuntimeState.CurrentFanState -NewState 'Unknown' -Verified $false -RequiresCleanup $true -ErrorCode 'CommandFailed' -ErrorMessage $(if ($command.ErrorMessage) { $command.ErrorMessage } else { 'Enable command failed.' }) -Diagnostics $command }
            $state = Get-DellCctkFanState -Backend $Backend -CorrelationId $CorrelationId -Reason 'EnableReadBack'
            $ok = ($state.Success -and $state.Verified -and [string]$state.NewState -eq 'BoostEnabled')
            if ($ok) { $Backend.RuntimeState.CurrentFanState = 'BoostEnabled' }
            New-FanBackendResult -Success $ok -Action 'EnableBoost' -PreviousState $null -NewState $state.NewState -Verified $ok -RequiresCleanup (-not $ok) -ErrorCode $(if ($ok) { $null } else { 'VerificationFailed' }) -ErrorMessage $(if ($ok) { $null } else { 'Enable read-back was not BoostEnabled.' }) -Diagnostics $state
        }
        RestoreAutomatic = {
            param([object]$Backend, [string]$CorrelationId, [string]$Reason)
            $Backend.RuntimeState.RestoreCallCount++
            if ($Backend.AllowHardwareWrites -ne $true) { return New-FanBackendResult -Success $false -Action 'RestoreAutomatic' -PreviousState $Backend.RuntimeState.CurrentFanState -NewState $Backend.RuntimeState.CurrentFanState -Verified $false -RequiresCleanup $false -ErrorCode 'WritesDisabled' -ErrorMessage 'Hardwarewrites zijn uitgeschakeld.' -Diagnostics $null }
            $spec = New-DellCctkCommandSpec -Operation 'RestoreAutomaticFanControl' -Backend $Backend
            $command = Invoke-DellCctkCommand -Backend $Backend -CommandSpec $spec -CorrelationId $CorrelationId -Reason $Reason
            if (-not $command.Success) { return New-FanBackendResult -Success $false -Action 'RestoreAutomatic' -PreviousState $Backend.RuntimeState.CurrentFanState -NewState 'Unknown' -Verified $false -RequiresCleanup $true -ErrorCode 'CommandFailed' -ErrorMessage $(if ($command.ErrorMessage) { $command.ErrorMessage } else { 'Restore command failed.' }) -Diagnostics $command }
            $state = Get-DellCctkFanState -Backend $Backend -CorrelationId $CorrelationId -Reason 'RestoreReadBack'
            $ok = ($state.Success -and $state.Verified -and [string]$state.NewState -eq 'Automatic')
            if ($ok) { $Backend.RuntimeState.CurrentFanState = 'Automatic' }
            New-FanBackendResult -Success $ok -Action 'RestoreAutomatic' -PreviousState $null -NewState $state.NewState -Verified $ok -RequiresCleanup (-not $ok) -ErrorCode $(if ($ok) { $null } else { 'VerificationFailed' }) -ErrorMessage $(if ($ok) { $null } else { 'Restore read-back was not Automatic.' }) -Diagnostics $state
        }
        EmergencyReset = {
            param([object]$Backend, [string]$CorrelationId, [string]$Reason)
            $Backend.RuntimeState.EmergencyResetCallCount++
            & $Backend.Operations.RestoreAutomatic $Backend $CorrelationId $Reason
        }
    }
    $backend
}

function Get-DellCctkActionLog {
    param([object]$Backend)
    @($Backend.ActionLog | ForEach-Object { $_ | ConvertTo-Json -Depth 6 | ConvertFrom-Json })
}
