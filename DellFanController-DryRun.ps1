[CmdletBinding()]
param(
    [int]$RunMinutes,
    [switch]$NoLogFile,
    [switch]$UseMockBackend,
    [string]$MockFailureMode = 'None',
    [string]$StatePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

function Get-ProjectPath {
    param([string]$Name)
    Join-Path $ScriptDirectory $Name
}

function Test-IntegerField {
    param([object]$Value, [string]$Name, [int]$Minimum, [int]$Maximum, [ref]$Errors)
    if ($null -eq $Value -or $Value -is [bool]) {
        $Errors.Value += "$Name moet een geheel getal zijn."
        return $null
    }
    $number = 0
    if (-not [int]::TryParse(([string]$Value), [ref]$number)) {
        $Errors.Value += "$Name moet een geheel getal zijn."
        return $null
    }
    if ($number -lt $Minimum -or $number -gt $Maximum) {
        $Errors.Value += "$Name moet tussen $Minimum en $Maximum liggen."
        return $null
    }
    [int]$number
}

function Test-ControllerConfig {
    param([object]$Config)

    $errors = @()
    if ($null -eq $Config) {
        return [pscustomobject]@{ IsValid = $false; DryRunBlocked = $true; Errors = @('Configuratie ontbreekt.'); Config = $null }
    }

    $required = @('SchemaVersion','ThresholdCelsius','PollIntervalSeconds','RequiredConsecutiveHighReadings','BoostDurationSeconds','CooldownSeconds','DryRun','SensorProvider')
    $names = @($Config.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($name in $required) {
        if ($names -notcontains $name) { $errors += "Verplicht veld ontbreekt: $name." }
    }
    foreach ($name in $names) {
        if ($required -notcontains $name) { $errors += "Onbekend veld is niet toegestaan: $name." }
    }

    if ($names -notcontains 'DryRun' -or $Config.DryRun -isnot [bool] -or $Config.DryRun -ne $true) {
        return [pscustomobject]@{ IsValid = $false; DryRunBlocked = $true; Errors = @('DryRun moet exact true zijn.'); Config = $null }
    }
    if ($errors.Count -gt 0) {
        return [pscustomobject]@{ IsValid = $false; DryRunBlocked = $false; Errors = @($errors); Config = $null }
    }

    $schema = Test-IntegerField -Value $Config.SchemaVersion -Name 'SchemaVersion' -Minimum 1 -Maximum 1 -Errors ([ref]$errors)
    $threshold = Test-IntegerField -Value $Config.ThresholdCelsius -Name 'ThresholdCelsius' -Minimum 60 -Maximum 90 -Errors ([ref]$errors)
    $poll = Test-IntegerField -Value $Config.PollIntervalSeconds -Name 'PollIntervalSeconds' -Minimum 15 -Maximum 300 -Errors ([ref]$errors)
    $requiredHigh = Test-IntegerField -Value $Config.RequiredConsecutiveHighReadings -Name 'RequiredConsecutiveHighReadings' -Minimum 1 -Maximum 10 -Errors ([ref]$errors)
    $boost = Test-IntegerField -Value $Config.BoostDurationSeconds -Name 'BoostDurationSeconds' -Minimum 30 -Maximum 900 -Errors ([ref]$errors)
    $cooldown = Test-IntegerField -Value $Config.CooldownSeconds -Name 'CooldownSeconds' -Minimum 60 -Maximum 3600 -Errors ([ref]$errors)
    if ([string]$Config.SensorProvider -ne 'CoreTempSharedMemory') { $errors += 'SensorProvider moet exact CoreTempSharedMemory zijn.' }

    if ($errors.Count -gt 0) {
        return [pscustomobject]@{ IsValid = $false; DryRunBlocked = $false; Errors = @($errors); Config = $null }
    }

    $validated = [pscustomobject]@{
        SchemaVersion = [int]$schema
        ThresholdCelsius = [int]$threshold
        PollIntervalSeconds = [int]$poll
        RequiredConsecutiveHighReadings = [int]$requiredHigh
        BoostDurationSeconds = [int]$boost
        CooldownSeconds = [int]$cooldown
        DryRun = $true
        SensorProvider = 'CoreTempSharedMemory'
    }
    [pscustomobject]@{ IsValid = $true; DryRunBlocked = $false; Errors = @(); Config = $validated }
}

function Read-ControllerConfig {
    param([string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw
    $parsed = $raw | ConvertFrom-Json
    $validation = Test-ControllerConfig -Config $parsed
    if ($validation.DryRunBlocked) {
        Write-Host 'DRY-RUN VEREIST - CONTROLLER NIET GESTART'
        return $validation
    }
    if (-not $validation.IsValid) {
        throw "Configuratie ongeldig: $(@($validation.Errors) -join '; ')"
    }
    $validation
}

function Convert-ToValidTemperature {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    $number = 0.0
    if (-not [double]::TryParse(([string]$Value), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $null }
    if ([double]::IsNaN($number) -or $number -lt 0 -or $number -gt 115) { return $null }
    [Math]::Round([double]$number, 2)
}

function Test-ObjectProperty {
    param(
        [object]$InputObject,
        [string]$Name
    )
    if ($null -eq $InputObject) { return $false }
    foreach ($property in @($InputObject.PSObject.Properties)) {
        if ($property.Name -eq $Name) { return $true }
    }
    $false
}

function Get-HighestValidTemperature {
    param([object[]]$Temperatures)
    $valid = @()
    foreach ($item in @($Temperatures)) {
        $value = if (Test-ObjectProperty -InputObject $item -Name 'TemperatureCelsius') { $item.TemperatureCelsius } else { $item }
        $converted = Convert-ToValidTemperature -Value $value
        if ($null -ne $converted) { $valid += [double]$converted }
    }
    if ($valid.Count -eq 0) {
        return [pscustomobject]@{ Success = $false; Highest = $null; ValidCoreCount = 0; Values = @() }
    }
    [pscustomobject]@{
        Success = $true
        Highest = [Math]::Round([double](($valid | Sort-Object -Descending | Select-Object -First 1)), 2)
        ValidCoreCount = [int]$valid.Count
        Values = @($valid)
    }
}

function Read-CoreTempSnapshot {
    param([string]$DiscoverScript)
    $output = & $DiscoverScript -Json 2>&1
    $text = ($output | Out-String).Trim()
    if ($text -eq 'Core Temp shared memory unavailable') {
        return [pscustomobject]@{ Success = $false; Unavailable = $true; Message = 'Core Temp shared memory unavailable'; Temperatures = @() }
    }
    $parsed = $text | ConvertFrom-Json
    [pscustomobject]@{ Success = $true; Unavailable = $false; Message = ''; Temperatures = @($parsed.Temperatures) }
}

function Get-MockStatePath {
    param([string]$ExplicitPath)
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) { return $ExplicitPath }
    Join-Path (Get-ProjectPath 'logs') 'dell-fan-controller-state.mock.json'
}

function Test-MockBackendFailureModeValue {
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

function Import-MockBackendModules {
    $stateModulePath = Get-ProjectPath 'DellFanController-State.ps1'
    $contractPath = Get-ProjectPath 'FanBackend.Contract.ps1'
    $mockPath = Get-ProjectPath 'FanBackend.Mock.ps1'
    . $stateModulePath
    . $contractPath
    . $mockPath
    $functionNames = @(
        'New-UtcTimestamp',
        'Test-GuidString',
        'Test-UtcTimestamp',
        'Get-DefaultControllerStateBackupPath',
        'Copy-ControllerStateObject',
        'Convert-ControllerStateToJson',
        'Test-ControllerState',
        'Read-StateFile',
        'Read-ControllerState',
        'Write-ControllerStateAtomic',
        'Set-ControllerStatePhase',
        'Mark-ControllerEmergencyReset',
        'Get-ControllerRecoveryDecision',
        'New-FanBackendResult',
        'Test-FanBackendContract',
        'Assert-FanBackendContract',
        'Invoke-FanBackendAvailabilityCheck',
        'Get-FanBackendControlState',
        'Write-BackendCleanupState',
        'Enable-FanBackendBoost',
        'Restore-FanBackendAutomaticControl',
        'Invoke-FanBackendEmergencyReset',
        'Test-MockFanState',
        'Test-MockFailureMode',
        'Add-MockFanBackendAction',
        'New-MockFanBackend',
        'Set-MockFanBackendFailureMode',
        'Get-MockFanBackendActionLog'
    )
    foreach ($name in $functionNames) {
        $command = Get-Command -Name $name -CommandType Function -ErrorAction Stop
        Set-Item -Path ("Function:\script:{0}" -f $name) -Value $command.ScriptBlock
    }
}

function New-MockBackendStateObject {
    param(
        [string]$ControllerInstanceId,
        [string]$CorrelationId,
        [string]$BackendName
    )
    [pscustomobject]@{
        SchemaVersion = 1
        ControllerInstanceId = $ControllerInstanceId
        CorrelationId = $CorrelationId
        BackendName = $BackendName
        OperationPhase = 'Idle'
        FanOverrideActivatedByThisApp = $false
        PreviousFanState = 'Automatic'
        CurrentRequestedState = 'Automatic'
        ActivatedAtUtc = $null
        LastSuccessfulVerificationUtc = $null
        RequiresEmergencyReset = $false
        LastError = $null
        UpdatedAtUtc = ([DateTime]::UtcNow).ToString('o')
    }
}

function Add-MockFieldsToLogRow {
    param(
        [object]$Row,
        [object]$MockContext,
        [string]$BackendAction,
        [object]$BackendResult
    )

    if ($null -eq $MockContext) { return $Row }
    $phase = $null
    $requiresReset = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$MockContext.StatePath) -and (Test-Path -LiteralPath $MockContext.StatePath -PathType Leaf)) {
        $read = Read-ControllerState -Path $MockContext.StatePath
        if ($read.Success) {
            $phase = $read.State.OperationPhase
            $requiresReset = $read.State.RequiresEmergencyReset
        }
    }
    $Row | Add-Member -NotePropertyName BackendName -NotePropertyValue $MockContext.Backend.BackendName -Force
    $Row | Add-Member -NotePropertyName BackendAction -NotePropertyValue $BackendAction -Force
    $Row | Add-Member -NotePropertyName BackendSuccess -NotePropertyValue $(if ($null -ne $BackendResult) { $BackendResult.Success } else { $null }) -Force
    $Row | Add-Member -NotePropertyName BackendVerified -NotePropertyValue $(if ($null -ne $BackendResult) { $BackendResult.Verified } else { $null }) -Force
    $Row | Add-Member -NotePropertyName BackendState -NotePropertyValue $(if ($null -ne $BackendResult) { $BackendResult.NewState } else { $MockContext.Backend.RuntimeState.CurrentFanState }) -Force
    $Row | Add-Member -NotePropertyName CorrelationId -NotePropertyValue $MockContext.CurrentCorrelationId -Force
    $Row | Add-Member -NotePropertyName StateOperationPhase -NotePropertyValue $phase -Force
    $Row | Add-Member -NotePropertyName RequiresEmergencyReset -NotePropertyValue $requiresReset -Force
    $Row
}

function New-ControllerState {
    [pscustomobject]@{
        State = 'Monitoring'
        ConsecutiveHighReadings = 0
        SimulatedBoostEndTime = $null
        CooldownEndTime = $null
        ShouldStop = $false
        ConsecutiveSensorFailures = 0
        ValidMeasurements = 0
        FailedMeasurements = 0
        HighestMeasuredTemperature = $null
        WouldEnableFanCount = 0
        WouldDisableFanCount = 0
        CompletedCooldownCount = 0
        StartedAt = Get-Date
    }
}

function Get-RemainingSeconds {
    param([datetime]$Now, [object]$EndTime)
    if ($null -eq $EndTime) { return $null }
    $remaining = [int][Math]::Ceiling((([datetime]$EndTime) - $Now).TotalSeconds)
    if ($remaining -lt 0) { return 0 }
    $remaining
}

function Update-ControllerState {
    param(
        [object]$State,
        [object]$Config,
        [datetime]$Now,
        [object]$Snapshot
    )

    $event = ''
    $highest = $null
    $validCoreCount = 0

    if (-not $Snapshot.Success) {
        $State.FailedMeasurements++
        $State.ConsecutiveSensorFailures++
        $State.ConsecutiveHighReadings = 0
        $event = if ($Snapshot.Message -eq 'Core Temp shared memory unavailable') { 'Core Temp shared memory unavailable' } else { 'SENSOR_READ_FAILED' }
        if ($State.ConsecutiveSensorFailures -ge 3) {
            $event = 'CONTROLLER_STOPPED_AFTER_SENSOR_FAILURES'
            $State.ShouldStop = $true
        }
    } else {
        $reading = Get-HighestValidTemperature -Temperatures @($Snapshot.Temperatures)
        if (-not $reading.Success) {
            $State.FailedMeasurements++
            $State.ConsecutiveSensorFailures++
            $State.ConsecutiveHighReadings = 0
            $event = 'SENSOR_READ_FAILED'
            if ($State.ConsecutiveSensorFailures -ge 3) {
                $event = 'CONTROLLER_STOPPED_AFTER_SENSOR_FAILURES'
                $State.ShouldStop = $true
            }
        } else {
            $State.ConsecutiveSensorFailures = 0
            $State.ValidMeasurements++
            $highest = [double]$reading.Highest
            $validCoreCount = [int]$reading.ValidCoreCount
            if ($null -eq $State.HighestMeasuredTemperature -or $highest -gt [double]$State.HighestMeasuredTemperature) {
                $State.HighestMeasuredTemperature = $highest
            }

            if ($State.State -eq 'Monitoring') {
                if ($highest -ge [double]$Config.ThresholdCelsius) {
                    $State.ConsecutiveHighReadings++
                } else {
                    $State.ConsecutiveHighReadings = 0
                }
                if ($State.ConsecutiveHighReadings -ge [int]$Config.RequiredConsecutiveHighReadings) {
                    $event = 'WOULD_ENABLE_FAN'
                    $State.State = 'SimulatedBoost'
                    $State.SimulatedBoostEndTime = $Now.AddSeconds([int]$Config.BoostDurationSeconds)
                    $State.CooldownEndTime = $null
                    $State.ConsecutiveHighReadings = 0
                    $State.WouldEnableFanCount++
                }
            } elseif ($State.State -eq 'SimulatedBoost') {
                $State.ConsecutiveHighReadings = 0
                if ($null -ne $State.SimulatedBoostEndTime -and $Now -ge [datetime]$State.SimulatedBoostEndTime) {
                    $event = 'WOULD_DISABLE_FAN'
                    $State.State = 'Cooldown'
                    $State.CooldownEndTime = $Now.AddSeconds([int]$Config.CooldownSeconds)
                    $State.SimulatedBoostEndTime = $null
                    $State.WouldDisableFanCount++
                }
            } elseif ($State.State -eq 'Cooldown') {
                $State.ConsecutiveHighReadings = 0
                if ($null -ne $State.CooldownEndTime -and $Now -ge [datetime]$State.CooldownEndTime) {
                    $event = 'COOLDOWN_ENDED'
                    $State.State = 'Monitoring'
                    $State.CooldownEndTime = $null
                    $State.CompletedCooldownCount++
                }
            }
        }
    }

    [pscustomobject]@{
        Timestamp = $Now
        State = $State.State
        HighestTemperatureCelsius = $highest
        ValidCoreCount = $validCoreCount
        ThresholdCelsius = [int]$Config.ThresholdCelsius
        ConsecutiveHighReadings = [int]$State.ConsecutiveHighReadings
        RequiredConsecutiveHighReadings = [int]$Config.RequiredConsecutiveHighReadings
        RemainingBoostSeconds = Get-RemainingSeconds -Now $Now -EndTime $State.SimulatedBoostEndTime
        RemainingCooldownSeconds = Get-RemainingSeconds -Now $Now -EndTime $State.CooldownEndTime
        Event = $event
        DryRun = $true
    }
}

function Convert-LogRowToCsvLine {
    param([object]$Row)
    $values = @(
        $Row.Timestamp.ToString('s'),
        $Row.State,
        $(if ($null -ne $Row.HighestTemperatureCelsius) { ([double]$Row.HighestTemperatureCelsius).ToString([Globalization.CultureInfo]::InvariantCulture) } else { '' }),
        $Row.ValidCoreCount,
        $Row.ThresholdCelsius,
        $Row.ConsecutiveHighReadings,
        $Row.RequiredConsecutiveHighReadings,
        $(if ($null -ne $Row.RemainingBoostSeconds) { $Row.RemainingBoostSeconds } else { '' }),
        $(if ($null -ne $Row.RemainingCooldownSeconds) { $Row.RemainingCooldownSeconds } else { '' }),
        $Row.Event,
        $Row.DryRun
    )
    if (Test-ObjectProperty -InputObject $Row -Name 'BackendName') {
        $values += @(
            $Row.BackendName,
            $Row.BackendAction,
            $Row.BackendSuccess,
            $Row.BackendVerified,
            $Row.BackendState,
            $Row.CorrelationId,
            $Row.StateOperationPhase,
            $Row.RequiresEmergencyReset
        )
    }
    ($values | ForEach-Object { '"' + ([string]$_).Replace('"','""') + '"' }) -join ','
}

function Write-DryRunLog {
    param([string]$Path, [object]$Row)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $header = 'Timestamp,State,HighestTemperatureCelsius,ValidCoreCount,ThresholdCelsius,ConsecutiveHighReadings,RequiredConsecutiveHighReadings,RemainingBoostSeconds,RemainingCooldownSeconds,Event,DryRun'
    if (Test-ObjectProperty -InputObject $Row -Name 'BackendName') {
        $header = "$header,BackendName,BackendAction,BackendSuccess,BackendVerified,BackendState,CorrelationId,StateOperationPhase,RequiresEmergencyReset"
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Set-Content -LiteralPath $Path -Value $header -Encoding UTF8
    }
    Add-Content -LiteralPath $Path -Value (Convert-LogRowToCsvLine -Row $Row) -Encoding UTF8
}

function Write-ControllerConsoleStatus {
    param([object]$Row)
    $parts = @(
        ("[{0}]" -f $Row.Timestamp.ToString('HH:mm:ss')),
        "State=$($Row.State)",
        "Highest=$(if ($null -ne $Row.HighestTemperatureCelsius) { "$($Row.HighestTemperatureCelsius) C" } else { 'n/a' })",
        "Cores=$($Row.ValidCoreCount)",
        "Threshold=$($Row.ThresholdCelsius)",
        "HighReadings=$($Row.ConsecutiveHighReadings)/$($Row.RequiredConsecutiveHighReadings)"
    )
    if ($null -ne $Row.RemainingBoostSeconds) { $parts += "RemainingBoost=$($Row.RemainingBoostSeconds)" }
    if ($null -ne $Row.RemainingCooldownSeconds) { $parts += "RemainingCooldown=$($Row.RemainingCooldownSeconds)" }
    if (-not [string]::IsNullOrWhiteSpace($Row.Event)) { $parts += "Event=$($Row.Event)" }
    if (Test-ObjectProperty -InputObject $Row -Name 'BackendName') {
        $parts += "Backend=$($Row.BackendName)"
        if (-not [string]::IsNullOrWhiteSpace([string]$Row.BackendAction)) { $parts += "BackendAction=$($Row.BackendAction)" }
        if ($null -ne $Row.BackendState) { $parts += "BackendState=$($Row.BackendState)" }
    }
    Write-Host ($parts -join '; ')
}

function Show-ControllerSummary {
    param([object]$State, [datetime]$EndedAt, [string]$LogPath, [object]$MockContext)
    $runtime = [Math]::Round(($EndedAt - [datetime]$State.StartedAt).TotalMinutes, 2)
    Write-Host ''
    Write-Host 'Dry-run samenvatting'
    Write-Host "Totale looptijd (min): $runtime"
    Write-Host "Geldige metingen: $($State.ValidMeasurements)"
    Write-Host "Mislukte metingen: $($State.FailedMeasurements)"
    Write-Host "Hoogste gemeten temperatuur: $(if ($null -ne $State.HighestMeasuredTemperature) { "$($State.HighestMeasuredTemperature) C" } else { 'n/a' })"
    Write-Host "WOULD_ENABLE_FAN gebeurtenissen: $($State.WouldEnableFanCount)"
    Write-Host "WOULD_DISABLE_FAN gebeurtenissen: $($State.WouldDisableFanCount)"
    Write-Host "Voltooide cooldowns: $($State.CompletedCooldownCount)"
    Write-Host "Eindtoestand: $($State.State)"
    Write-Host "Mock backend gebruikt: $(if ($null -ne $MockContext) { 'ja' } else { 'nee' })"
    if ($null -ne $MockContext) {
        $finalPhase = 'n/a'
        $requiresReset = 'n/a'
        if (Test-Path -LiteralPath $MockContext.StatePath -PathType Leaf) {
            $read = Read-ControllerState -Path $MockContext.StatePath
            if ($read.Success) {
                $finalPhase = $read.State.OperationPhase
                $requiresReset = $read.State.RequiresEmergencyReset
            }
        }
        Write-Host "Mock enable pogingen: $($MockContext.Backend.RuntimeState.EnableCallCount)"
        Write-Host "Mock restore pogingen: $($MockContext.Backend.RuntimeState.RestoreCallCount)"
        Write-Host "Mock emergency reset pogingen: $($MockContext.EmergencyResetAttempts)"
        Write-Host "Mock cleanup geslaagd: $($MockContext.CleanupSucceeded)"
        Write-Host "Mock cleanup mislukt: $($MockContext.CleanupFailed)"
        Write-Host "Eindstatus mockbackend: $($MockContext.Backend.RuntimeState.CurrentFanState)"
        Write-Host "Eindfase statebestand: $finalPhase"
        Write-Host "Emergency reset vereist: $requiresReset"
    }
    Write-Host "Logbestand: $LogPath"
}

function New-MockBackendContext {
    param(
        [string]$FailureMode,
        [string]$RequestedStatePath
    )

    if (-not (Test-MockBackendFailureModeValue -FailureMode $FailureMode)) { throw "Ongeldige MockFailureMode: $FailureMode" }
    $resolvedStatePath = Get-MockStatePath -ExplicitPath $RequestedStatePath
    $stateDirectory = Split-Path -Parent $resolvedStatePath
    if (-not (Test-Path -LiteralPath $stateDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }
    $backend = New-MockFanBackend -FailureMode $FailureMode
    [pscustomobject]@{
        Backend = $backend
        StatePath = $resolvedStatePath
        ControllerInstanceId = ([guid]::NewGuid()).ToString()
        CurrentCorrelationId = $null
        EnableAttempts = 0
        RestoreAttempts = 0
        EmergencyResetAttempts = 0
        CleanupSucceeded = 0
        CleanupFailed = 0
        BackendCreatedCount = 1
    }
}

function Initialize-MockControllerState {
    param([object]$MockContext)
    if (-not (Test-Path -LiteralPath $MockContext.StatePath -PathType Leaf)) {
        $initial = New-MockBackendStateObject -ControllerInstanceId $MockContext.ControllerInstanceId -CorrelationId ([guid]::NewGuid()).ToString() -BackendName $MockContext.Backend.BackendName
        [void](Write-ControllerStateAtomic -Path $MockContext.StatePath -State $initial)
        return
    }

    $read = Read-ControllerState -Path $MockContext.StatePath
    if (-not $read.Success) { throw "Startup recovery geweigerd: bestaand statebestand is ongeldig: $(@($read.Errors) -join '; ')" }
    $decision = Get-ControllerRecoveryDecision -State $read.State
    switch ([string]$read.State.OperationPhase) {
        'Idle' { return }
        'Restored' { return }
        'EnablePending' {
            $stateResult = Get-FanBackendControlState -Backend $MockContext.Backend
            if ($stateResult.Success -and $stateResult.Verified -and [string]$stateResult.NewState -eq 'Automatic') {
                $restored = Set-ControllerStatePhase -State $read.State -OperationPhase 'Restored'
                [void](Write-ControllerStateAtomic -Path $MockContext.StatePath -State $restored)
                return
            }
            if ($stateResult.Success -and $stateResult.Verified -and [string]$stateResult.NewState -eq 'BoostEnabled') {
                $active = Set-ControllerStatePhase -State $read.State -OperationPhase 'ActiveVerified'
                [void](Write-ControllerStateAtomic -Path $MockContext.StatePath -State $active)
                $restore = Restore-FanBackendAutomaticControl -Backend $MockContext.Backend -StatePath $MockContext.StatePath -CorrelationId ([guid]::NewGuid()).ToString() -Reason 'StartupRecoveryEnablePending'
                if ($restore.Success -and $restore.Verified -and [string]$restore.NewState -eq 'Automatic') { return }
                throw "Startup recovery faalde voor EnablePending: $($restore.ErrorMessage)"
            }
            throw 'Startup recovery faalde voor EnablePending: backendstatus kon niet veilig worden geverifieerd.'
        }
        'ActiveVerified' {
            $restore = Restore-FanBackendAutomaticControl -Backend $MockContext.Backend -StatePath $MockContext.StatePath -CorrelationId ([guid]::NewGuid()).ToString() -Reason 'StartupRecoveryActiveVerified'
            if ($restore.Success -and $restore.Verified -and [string]$restore.NewState -eq 'Automatic') { return }
            throw "Startup recovery faalde voor ActiveVerified: $($restore.ErrorMessage)"
        }
        'DisablePending' {
            $restore = Restore-FanBackendAutomaticControl -Backend $MockContext.Backend -StatePath $MockContext.StatePath -CorrelationId ([guid]::NewGuid()).ToString() -Reason 'StartupRecoveryDisablePending'
            if ($restore.Success -and $restore.Verified -and [string]$restore.NewState -eq 'Automatic') { return }
            throw "Startup recovery faalde voor DisablePending: $($restore.ErrorMessage)"
        }
        'CleanupRequired' {
            $MockContext.EmergencyResetAttempts++
            $reset = Invoke-FanBackendEmergencyReset -Backend $MockContext.Backend -StatePath $MockContext.StatePath -CorrelationId ([guid]::NewGuid()).ToString() -Reason 'StartupEmergencyRecovery' -ForceIfOwned
            if ($reset.Success -and $reset.Verified -and [string]$reset.NewState -eq 'Automatic') { return }
            throw "Startup emergency recovery faalde: $($reset.ErrorMessage)"
        }
        default {
            throw "Startup recovery geweigerd: $($decision.Reason)"
        }
    }
}

function Invoke-MockExitCleanup {
    param([object]$MockContext)
    if ($null -eq $MockContext -or -not (Test-Path -LiteralPath $MockContext.StatePath -PathType Leaf)) {
        return [pscustomobject]@{ Attempted = $false; Success = $true; Event = '' }
    }
    $read = Read-ControllerState -Path $MockContext.StatePath
    if (-not $read.Success) {
        $MockContext.CleanupFailed++
        return [pscustomobject]@{ Attempted = $true; Success = $false; Event = 'MOCK_EXIT_CLEANUP_FAILED' }
    }
    if (@('EnablePending','ActiveVerified','DisablePending','CleanupRequired') -notcontains [string]$read.State.OperationPhase) {
        return [pscustomobject]@{ Attempted = $false; Success = $true; Event = '' }
    }

    $result = $null
    if ([string]$read.State.OperationPhase -eq 'CleanupRequired') {
        $MockContext.EmergencyResetAttempts++
        $result = Invoke-FanBackendEmergencyReset -Backend $MockContext.Backend -StatePath $MockContext.StatePath -CorrelationId ([guid]::NewGuid()).ToString() -Reason 'ExitCleanupEmergencyReset' -ForceIfOwned
    } else {
        $result = Restore-FanBackendAutomaticControl -Backend $MockContext.Backend -StatePath $MockContext.StatePath -CorrelationId ([guid]::NewGuid()).ToString() -Reason 'ExitCleanupRestore'
    }
    if ($result.Success -and $result.Verified -and [string]$result.NewState -eq 'Automatic') {
        $MockContext.CleanupSucceeded++
        return [pscustomobject]@{ Attempted = $true; Success = $true; Event = 'MOCK_EXIT_CLEANUP_SUCCEEDED' }
    }
    $MockContext.CleanupFailed++
    [pscustomobject]@{ Attempted = $true; Success = $false; Event = 'MOCK_EXIT_CLEANUP_FAILED' }
}

function Start-DryRunController {
    param(
        [int]$Minutes,
        [bool]$DisableLog,
        [bool]$UseMock,
        [string]$MockFailureModeValue = 'None',
        [string]$MockStatePath,
        [object[]]$TestSnapshots,
        [datetime]$TestStartTime,
        [string]$LogPathOverride,
        [switch]$NoSleep
    )
    if ($Minutes -lt 1 -or $Minutes -gt 1440) { throw '-RunMinutes moet tussen 1 en 1440 liggen.' }
    $configResult = Read-ControllerConfig -Path (Get-ProjectPath 'controller-config.json')
    if (-not $configResult.IsValid) { return }
    $config = $configResult.Config
    if ($UseMock -and $config.DryRun -ne $true) { throw 'Mockmodus vereist DryRun=true.' }
    $state = New-ControllerState
    $mockContext = $null
    if ($UseMock) {
        Import-MockBackendModules
        $mockContext = New-MockBackendContext -FailureMode $MockFailureModeValue -RequestedStatePath $MockStatePath
        Initialize-MockControllerState -MockContext $mockContext
    }
    $discoverScript = Get-ProjectPath 'Discover-CoreTempSharedMemory.ps1'
    $logPath = if ($DisableLog) { '<geen logbestand>' } elseif (-not [string]::IsNullOrWhiteSpace($LogPathOverride)) { $LogPathOverride } else { Get-ProjectPath 'logs\dell-fan-dryrun.csv' }
    $clock = if ($PSBoundParameters.ContainsKey('TestStartTime')) { $TestStartTime } else { Get-Date }
    $endAt = $clock.AddMinutes($Minutes)
    $sampleIndex = 0
    $exitCode = 0
    try {
        while ($clock -lt $endAt -and -not $state.ShouldStop) {
            $now = $clock
            if ($null -ne $TestSnapshots -and $sampleIndex -ge @($TestSnapshots).Count) {
                break
            }
            if ($null -ne $TestSnapshots -and $sampleIndex -lt @($TestSnapshots).Count) {
                $snapshot = @($TestSnapshots)[$sampleIndex]
            } else {
                $snapshot = Read-CoreTempSnapshot -DiscoverScript $discoverScript
            }
            $sampleIndex++
            $previousControllerState = [string]$state.State
            $row = Update-ControllerState -State $state -Config $config -Now $now -Snapshot $snapshot
            $backendAction = ''
            $backendResult = $null

            if ($UseMock -and [string]$row.Event -eq 'WOULD_ENABLE_FAN') {
                $mockContext.CurrentCorrelationId = ([guid]::NewGuid()).ToString()
                $mockContext.EnableAttempts++
                $backendResult = Enable-FanBackendBoost -Backend $mockContext.Backend -StatePath $mockContext.StatePath -ControllerInstanceId $mockContext.ControllerInstanceId -CorrelationId $mockContext.CurrentCorrelationId -Reason 'ThresholdExceededAfterConsecutiveReadings'
                if ($backendResult.Success -and $backendResult.Verified -and [string]$backendResult.NewState -eq 'BoostEnabled') {
                    $row.Event = 'MOCK_ENABLE_SUCCEEDED'
                    $backendAction = 'EnableBoost'
                } else {
                    $row.Event = 'MOCK_ENABLE_FAILED'
                    $state.State = 'Monitoring'
                    $state.ShouldStop = $true
                    $exitCode = 10
                    $backendAction = 'EnableBoost'
                }
            } elseif ($UseMock -and $previousControllerState -eq 'SimulatedBoost' -and -not $snapshot.Success) {
                $mockContext.CurrentCorrelationId = ([guid]::NewGuid()).ToString()
                $mockContext.RestoreAttempts++
                $backendResult = Restore-FanBackendAutomaticControl -Backend $mockContext.Backend -StatePath $mockContext.StatePath -CorrelationId $mockContext.CurrentCorrelationId -Reason 'SensorFailureDuringBoost'
                $backendAction = 'RestoreAutomatic'
                if ($backendResult.Success -and $backendResult.Verified -and [string]$backendResult.NewState -eq 'Automatic') {
                    $row.Event = 'MOCK_SENSOR_FAILURE_RESTORE_SUCCEEDED'
                    $state.State = 'Monitoring'
                    $state.SimulatedBoostEndTime = $null
                    $state.ShouldStop = $true
                } else {
                    $row.Event = 'MOCK_SENSOR_FAILURE_RESTORE_FAILED'
                    $state.ShouldStop = $true
                    $exitCode = 12
                }
            } elseif ($UseMock -and [string]$row.Event -eq 'WOULD_DISABLE_FAN') {
                $mockContext.CurrentCorrelationId = ([guid]::NewGuid()).ToString()
                $mockContext.RestoreAttempts++
                $backendResult = Restore-FanBackendAutomaticControl -Backend $mockContext.Backend -StatePath $mockContext.StatePath -CorrelationId $mockContext.CurrentCorrelationId -Reason 'BoostDurationElapsed'
                $backendAction = 'RestoreAutomatic'
                if ($backendResult.Success -and $backendResult.Verified -and [string]$backendResult.NewState -eq 'Automatic') {
                    $row.Event = 'MOCK_RESTORE_SUCCEEDED'
                } else {
                    $row.Event = 'MOCK_RESTORE_FAILED'
                    $state.State = 'SimulatedBoost'
                    $state.ShouldStop = $true
                    $exitCode = 11
                }
            }

            if ($UseMock) { $row = Add-MockFieldsToLogRow -Row $row -MockContext $mockContext -BackendAction $backendAction -BackendResult $backendResult }
            Write-ControllerConsoleStatus -Row $row
            if (-not $DisableLog) { Write-DryRunLog -Path $logPath -Row $row }
            if ($state.ShouldStop) { break }
            if (-not $NoSleep) { Start-Sleep -Seconds ([int]$config.PollIntervalSeconds) }
            $clock = $clock.AddSeconds([int]$config.PollIntervalSeconds)
        }
        $finalEvent = if ($state.ShouldStop) { 'CONTROLLER_STOPPED' } else { 'CONTROLLER_RUN_COMPLETED' }
        $finalRow = [pscustomobject]@{
            Timestamp = $clock
            State = $state.State
            HighestTemperatureCelsius = $null
            ValidCoreCount = 0
            ThresholdCelsius = [int]$config.ThresholdCelsius
            ConsecutiveHighReadings = [int]$state.ConsecutiveHighReadings
            RequiredConsecutiveHighReadings = [int]$config.RequiredConsecutiveHighReadings
            RemainingBoostSeconds = $null
            RemainingCooldownSeconds = $null
            Event = $finalEvent
            DryRun = $true
        }
        if ($UseMock) {
            $cleanup = Invoke-MockExitCleanup -MockContext $mockContext
            if ($cleanup.Attempted) {
                $finalRow.Event = $cleanup.Event
                if (-not $cleanup.Success) { $exitCode = 20 }
            }
            $finalRow = Add-MockFieldsToLogRow -Row $finalRow -MockContext $mockContext -BackendAction 'ExitCleanup' -BackendResult $null
        }
        if (-not $DisableLog) { Write-DryRunLog -Path $logPath -Row $finalRow }
        if ($exitCode -ne 0) { throw "Mockcontroller gestopt met foutcode $exitCode." }
    }
    catch {
        Write-Host "Controller veilig gestopt: $($_.Exception.Message)"
        if (-not $DisableLog) {
            try {
                if ($UseMock -and $null -ne $mockContext) { [void](Invoke-MockExitCleanup -MockContext $mockContext) }
                $stopRow = [pscustomobject]@{
                    Timestamp = $clock
                    State = $state.State
                    HighestTemperatureCelsius = $null
                    ValidCoreCount = 0
                    ThresholdCelsius = [int]$config.ThresholdCelsius
                    ConsecutiveHighReadings = [int]$state.ConsecutiveHighReadings
                    RequiredConsecutiveHighReadings = [int]$config.RequiredConsecutiveHighReadings
                    RemainingBoostSeconds = $null
                    RemainingCooldownSeconds = $null
                    Event = 'CONTROLLER_STOPPED'
                    DryRun = $true
                }
                if ($UseMock -and $null -ne $mockContext) { $stopRow = Add-MockFieldsToLogRow -Row $stopRow -MockContext $mockContext -BackendAction 'ExceptionCleanup' -BackendResult $null }
                Write-DryRunLog -Path $logPath -Row $stopRow
            } catch {}
        }
        throw
    }
    finally {
        Show-ControllerSummary -State $state -EndedAt (Get-Date) -LogPath $logPath -MockContext $mockContext
    }

    [pscustomobject]@{
        Success = ($exitCode -eq 0)
        ExitCode = $exitCode
        RuntimeState = $state
        MockContext = $mockContext
        LogPath = $logPath
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $PSBoundParameters.ContainsKey('RunMinutes')) {
        Write-Host "Gebruik: powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\DellFanController-DryRun.ps1' -RunMinutes 20"
        exit 2
    }
    Start-DryRunController -Minutes $RunMinutes -DisableLog ([bool]$NoLogFile) -UseMock ([bool]$UseMockBackend) -MockFailureModeValue $MockFailureMode -MockStatePath $StatePath
}
