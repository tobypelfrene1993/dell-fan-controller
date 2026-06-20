[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$EnableProductionMode,
    [switch]$AllowHardwareWrites,
    [string]$HardwareWriteConfirmation,
    [int]$RunMinutes,
    [switch]$JsonSummary,
    [switch]$ValidateOnly,
    [switch]$StartupOnly,
    [scriptblock]$TestProcessInvoker,
    [string]$TestFakeProcessMode,
    [string]$TestFakeProcessCallPath,
    [double[]]$TestTemperatureValues,
    [object[]]$TestSnapshots,
    [switch]$TestIsAdministrator,
    [switch]$TestLockAcquired
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

. (Join-Path $ScriptDirectory 'DellFanController-State.ps1')
. (Join-Path $ScriptDirectory 'FanBackend.Contract.ps1')
. (Join-Path $ScriptDirectory 'FanBackend.DellCctk.ps1')
. (Join-Path $ScriptDirectory 'DellCctk.ProcessExecutor.ps1')
. (Join-Path $ScriptDirectory 'DellFanController-ProductionSupport.ps1')

function Test-ProductionAdministrator {
    ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Test-ProductionIntegerField {
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

function Resolve-ProductionProjectPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if ([IO.Path]::IsPathRooted($Path)) { return $Path }
    Join-Path $ScriptDirectory $Path
}

function Test-DellFanControllerProductionConfig {
    param([object]$Config)

    $errors = @()
    if ($null -eq $Config) {
        return [pscustomobject]@{ IsValid=$false; Errors=@('Configuratie ontbreekt.'); Config=$null }
    }
    $required = @('SchemaVersion','ThresholdCelsius','PollIntervalSeconds','RequiredConsecutiveHighReadings','BoostDurationSeconds','CooldownSeconds','DryRun','SensorProvider','Backend','CctkPath','CommandTimeoutSeconds','StatePath','LogPath')
    $names = @($Config.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($name in $required) { if ($names -notcontains $name) { $errors += "Verplicht veld ontbreekt: $name." } }
    foreach ($name in $names) { if ($required -notcontains $name) { $errors += "Onbekend veld is niet toegestaan: $name." } }

    if ($names -contains 'DryRun' -and ($Config.DryRun -isnot [bool] -or $Config.DryRun -ne $false)) { $errors += 'DryRun moet exact false zijn.' }
    if ($names -contains 'SensorProvider' -and [string]$Config.SensorProvider -ne 'CoreTempSharedMemory') { $errors += 'SensorProvider moet exact CoreTempSharedMemory zijn.' }
    if ($names -contains 'Backend' -and [string]$Config.Backend -ne 'DellCctk') { $errors += 'Backend moet exact DellCctk zijn.' }
    if ($names -contains 'CctkPath') {
        if ([string]::IsNullOrWhiteSpace([string]$Config.CctkPath) -or -not [IO.Path]::IsPathRooted([string]$Config.CctkPath) -or [IO.Path]::GetFileName([string]$Config.CctkPath) -ne 'cctk.exe') {
            $errors += 'CctkPath moet een absoluut pad naar cctk.exe zijn.'
        }
    }
    if ($names -contains 'StatePath') {
        if ([string]::IsNullOrWhiteSpace([string]$Config.StatePath) -or [string]$Config.StatePath -match '[<>|?*]') { $errors += 'StatePath is ongeldig.' }
    }
    if ($names -contains 'LogPath') {
        if ([string]::IsNullOrWhiteSpace([string]$Config.LogPath) -or [string]$Config.LogPath -match '[<>|?*]') { $errors += 'LogPath is ongeldig.' }
    }
    if ($errors.Count -gt 0) {
        return [pscustomobject]@{ IsValid=$false; Errors=@($errors); Config=$null }
    }

    $schema = Test-ProductionIntegerField -Value $Config.SchemaVersion -Name 'SchemaVersion' -Minimum 1 -Maximum 1 -Errors ([ref]$errors)
    $threshold = Test-ProductionIntegerField -Value $Config.ThresholdCelsius -Name 'ThresholdCelsius' -Minimum 60 -Maximum 90 -Errors ([ref]$errors)
    $poll = Test-ProductionIntegerField -Value $Config.PollIntervalSeconds -Name 'PollIntervalSeconds' -Minimum 5 -Maximum 300 -Errors ([ref]$errors)
    $requiredHigh = Test-ProductionIntegerField -Value $Config.RequiredConsecutiveHighReadings -Name 'RequiredConsecutiveHighReadings' -Minimum 1 -Maximum 10 -Errors ([ref]$errors)
    $boost = Test-ProductionIntegerField -Value $Config.BoostDurationSeconds -Name 'BoostDurationSeconds' -Minimum 30 -Maximum 900 -Errors ([ref]$errors)
    $cooldown = Test-ProductionIntegerField -Value $Config.CooldownSeconds -Name 'CooldownSeconds' -Minimum 60 -Maximum 3600 -Errors ([ref]$errors)
    $timeout = Test-ProductionIntegerField -Value $Config.CommandTimeoutSeconds -Name 'CommandTimeoutSeconds' -Minimum 5 -Maximum 300 -Errors ([ref]$errors)
    if ($errors.Count -gt 0) {
        return [pscustomobject]@{ IsValid=$false; Errors=@($errors); Config=$null }
    }

    [pscustomobject]@{
        IsValid = $true
        Errors = @()
        Config = [pscustomobject]@{
            SchemaVersion = [int]$schema
            ThresholdCelsius = [int]$threshold
            PollIntervalSeconds = [int]$poll
            RequiredConsecutiveHighReadings = [int]$requiredHigh
            BoostDurationSeconds = [int]$boost
            CooldownSeconds = [int]$cooldown
            DryRun = $false
            SensorProvider = 'CoreTempSharedMemory'
            Backend = 'DellCctk'
            CctkPath = [string]$Config.CctkPath
            CommandTimeoutSeconds = [int]$timeout
            StatePath = Resolve-ProductionProjectPath -Path ([string]$Config.StatePath)
            LogPath = Resolve-ProductionProjectPath -Path ([string]$Config.LogPath)
        }
    }
}

function Read-DellFanControllerProductionConfig {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'ConfigPath is verplicht.' }
    $parsed = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $validation = Test-DellFanControllerProductionConfig -Config $parsed
    if (-not $validation.IsValid) { throw "Productieconfig ongeldig: $(@($validation.Errors) -join '; ')" }
    $validation
}

function Convert-ToProductionTemperature {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    $number = 0.0
    if (-not [double]::TryParse(([string]$Value), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $null }
    if ([double]::IsNaN($number) -or $number -lt 0 -or $number -gt 115) { return $null }
    [Math]::Round([double]$number, 2)
}

function Test-ProductionObjectProperty {
    param([object]$InputObject, [string]$Name)
    if ($null -eq $InputObject) { return $false }
    foreach ($property in @($InputObject.PSObject.Properties)) { if ($property.Name -eq $Name) { return $true } }
    $false
}

function Get-ProductionHighestTemperature {
    param([object[]]$Temperatures)
    $valid = @()
    foreach ($item in @($Temperatures)) {
        $value = if (Test-ProductionObjectProperty -InputObject $item -Name 'TemperatureCelsius') { $item.TemperatureCelsius } else { $item }
        $converted = Convert-ToProductionTemperature -Value $value
        if ($null -ne $converted) { $valid += [double]$converted }
    }
    if ($valid.Count -eq 0) { return [pscustomobject]@{ Success=$false; Highest=$null; ValidCoreCount=0; Values=@() } }
    [pscustomobject]@{ Success=$true; Highest=[double](($valid | Sort-Object -Descending | Select-Object -First 1)); ValidCoreCount=[int]$valid.Count; Values=@($valid) }
}

function Read-ProductionCoreTempSnapshot {
    param([string]$DiscoverScript)
    $output = & $DiscoverScript -Json 2>&1
    $text = ($output | Out-String).Trim()
    if ($text -eq 'Core Temp shared memory unavailable') {
        return [pscustomobject]@{ Success=$false; Unavailable=$true; Message='Core Temp shared memory unavailable'; Temperatures=@() }
    }
    $parsed = $text | ConvertFrom-Json
    [pscustomobject]@{ Success=$true; Unavailable=$false; Message=''; Temperatures=@($parsed.Temperatures) }
}

function New-ProductionLock {
    param([string]$Name='Global\DellFanControllerProduction')
    $created = $false
    $mutex = New-Object System.Threading.Mutex($false, $Name, [ref]$created)
    $acquired = $mutex.WaitOne(0)
    [pscustomobject]@{ Acquired=[bool]$acquired; Mutex=$mutex; Name=$Name }
}

function Release-ProductionLock {
    param([object]$Lock)
    if ($null -eq $Lock) { return }
    try { if ($Lock.Acquired) { $Lock.Mutex.ReleaseMutex() } } catch {}
    try { $Lock.Mutex.Dispose() } catch {}
}

function New-ProductionRuntimeState {
    param([string]$RunId)
    [pscustomobject]@{
        ControllerState='Monitoring'
        RunId=$RunId
        ControllerInstanceId=([guid]::NewGuid()).ToString()
        CurrentCorrelationId=$null
        ConsecutiveHighReadings=0
        ConsecutiveSensorFailures=0
        ValidMeasurements=0
        FailedMeasurements=0
        HighestMeasuredTemperature=$null
        BoostsStarted=0
        RestoresExecuted=0
        CooldownsCompleted=0
        EnableFailures=0
        RestoreFailures=0
        EmergencyResets=0
        BoostEndTime=$null
        CooldownEndTime=$null
        ShouldStop=$false
        ExitCode=0
        StartedAtUtc=[DateTime]::UtcNow
        AutomaticVerified=$false
        ExecutionPhase=$null
        ExceptionDetails=$null
        LogWriteExceptionMessage=$null
        CleanupExceptionMessage=$null
        FatalErrorPath=$null
    }
}

function Set-ProductionExecutionPhase {
    param([object]$Runtime, [string]$Phase)
    if ($null -ne $Runtime) { $Runtime.ExecutionPhase = $Phase }
}

function New-ProductionExceptionDetails {
    param([object]$ErrorRecord, [object]$Runtime, [int]$ExitCodeBeforeCatch)

    $invocation = if ($null -ne $ErrorRecord) { $ErrorRecord.InvocationInfo } else { $null }
    [pscustomobject]@{
        ExceptionMessage = if ($null -ne $ErrorRecord -and $null -ne $ErrorRecord.Exception) { $ErrorRecord.Exception.Message } else { $null }
        ExceptionType = if ($null -ne $ErrorRecord -and $null -ne $ErrorRecord.Exception) { $ErrorRecord.Exception.GetType().FullName } else { $null }
        FullyQualifiedErrorId = if ($null -ne $ErrorRecord) { $ErrorRecord.FullyQualifiedErrorId } else { $null }
        CategoryInfo = if ($null -ne $ErrorRecord) { [string]$ErrorRecord.CategoryInfo } else { $null }
        ScriptStackTrace = if ($null -ne $ErrorRecord) { $ErrorRecord.ScriptStackTrace } else { $null }
        PositionMessage = if ($null -ne $invocation) { $invocation.PositionMessage } else { $null }
        InvocationLine = if ($null -ne $invocation) { $invocation.Line } else { $null }
        ExecutionPhase = if ($null -ne $Runtime) { $Runtime.ExecutionPhase } else { $null }
        ExitCodeBeforeCatch = [int]$ExitCodeBeforeCatch
        TimestampUtc = ([DateTime]::UtcNow).ToString('o')
    }
}

function Write-ProductionFatalErrorFile {
    param([object]$Config, [object]$Runtime, [int]$ExitCode)

    if ($null -eq $Config -or $null -eq $Runtime -or [string]::IsNullOrWhiteSpace([string]$Config.LogPath)) { return $null }
    $directory = Split-Path -Parent $Config.LogPath
    if ([string]::IsNullOrWhiteSpace($directory)) { return $null }
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    $path = Join-Path $directory 'dell-fan-controller-fatal-error.json'
    $tempPath = Join-Path $directory ("dell-fan-controller-fatal-error.{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
    $details = $Runtime.ExceptionDetails
    $payload = [pscustomobject]@{
        TimestampUtc = if ($null -ne $details) { $details.TimestampUtc } else { ([DateTime]::UtcNow).ToString('o') }
        RunId = $Runtime.RunId
        ControllerInstanceId = $Runtime.ControllerInstanceId
        ExecutionPhase = if ($null -ne $details) { $details.ExecutionPhase } else { $Runtime.ExecutionPhase }
        ExceptionMessage = if ($null -ne $details) { $details.ExceptionMessage } else { $null }
        ExceptionType = if ($null -ne $details) { $details.ExceptionType } else { $null }
        FullyQualifiedErrorId = if ($null -ne $details) { $details.FullyQualifiedErrorId } else { $null }
        ScriptStackTrace = if ($null -ne $details) { $details.ScriptStackTrace } else { $null }
        PositionMessage = if ($null -ne $details) { $details.PositionMessage } else { $null }
        ExitCode = [int]$ExitCode
        LogWriteExceptionMessage = $Runtime.LogWriteExceptionMessage
        CleanupExceptionMessage = $Runtime.CleanupExceptionMessage
    }
    $json = $payload | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.Encoding]::UTF8)
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        [System.IO.File]::Replace($tempPath, $path, $null)
    } else {
        [System.IO.File]::Move($tempPath, $path)
    }
    $Runtime.FatalErrorPath = $path
    $path
}

function New-ProductionValidationResult {
    param(
        [object]$Config,
        [object]$Admin,
        [object]$CoreTemp,
        [object]$StateRead,
        [object]$Session,
        [int]$ExitCode,
        [string]$Message
    )

    $beginState = if ($null -ne $Session) { $Session.BeginStateResult } else { $null }
    $diagnostics = if ($null -ne $beginState) { $beginState.Diagnostics } else { $null }
    [pscustomobject]@{
        ProductionSupportVersion = $script:ProductionSupportVersion
        ProcessExecutorVersion = $script:ProcessExecutorVersion
        ConfigValid = ($null -ne $Config)
        Administrator = [bool]$Admin
        CoreTempAvailable = if ($null -ne $CoreTemp) { [bool]$CoreTemp.Success } else { $false }
        StateFound = if ($null -ne $StateRead) { [bool]$StateRead.Success } else { $false }
        BackendName = if ($null -ne $Session -and $null -ne $Session.Backend) { $Session.Backend.BackendName } else { $null }
        BackendObjectType = if ($null -ne $Session -and $null -ne $Session.Backend) { $Session.Backend.GetType().FullName } else { $null }
        ExecutorObjectType = if ($null -ne $Session -and $null -ne $Session.CommandExecutor) { $Session.CommandExecutor.GetType().FullName } else { $null }
        AvailabilityResult = if ($null -ne $Session) { Convert-ProductionBackendResultForJson -Result $Session.AvailabilityResult } else { $null }
        BeginStateResult = Convert-ProductionBackendResultForJson -Result $beginState
        Success = if ($null -ne $beginState) { $beginState.Success } else { $false }
        NewState = if ($null -ne $beginState) { $beginState.NewState } else { 'Unknown' }
        Verified = if ($null -ne $beginState) { $beginState.Verified } else { $false }
        ErrorCode = if ($null -ne $beginState) { $beginState.ErrorCode } else { $null }
        ErrorMessage = if ($null -ne $beginState) { $beginState.ErrorMessage } else { $Message }
        Started = if ($null -ne $diagnostics) { $diagnostics.Started } else { $null }
        ExitCode = if ($null -ne $diagnostics) { $diagnostics.ExitCode } else { $null }
        StdOut = if ($null -ne $diagnostics) { $diagnostics.StdOut } else { $null }
        StdErr = if ($null -ne $diagnostics) { $diagnostics.StdErr } else { $null }
        TimedOut = if ($null -ne $diagnostics) { $diagnostics.TimedOut } else { $null }
        DurationMs = if ($null -ne $diagnostics) { $diagnostics.DurationMs } else { $null }
        ProcessExitCode = [int]$ExitCode
        Message = $Message
    }
}

function Convert-ProductionLogRowToCsv {
    param([object]$Row)
    $columns = @(
        'TimestampUtc','RunId','ControllerInstanceId','CorrelationId','ControllerState','HighestTemperature','ValidCoreCount','ThresholdCelsius','ConsecutiveHighReadings','RequiredConsecutiveHighReadings','RemainingBoostSeconds','RemainingCooldownSeconds','BackendName','BackendAction','BackendSuccess','BackendVerified','BackendState','StateOperationPhase','RequiresEmergencyReset','Event','ErrorMessage'
    )
    (($columns | ForEach-Object { '"' + ([string]$Row.$_).Replace('"','""') + '"' }) -join ',')
}

function Write-ProductionLog {
    param([string]$Path, [object]$Row)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $header = 'TimestampUtc,RunId,ControllerInstanceId,CorrelationId,ControllerState,HighestTemperature,ValidCoreCount,ThresholdCelsius,ConsecutiveHighReadings,RequiredConsecutiveHighReadings,RemainingBoostSeconds,RemainingCooldownSeconds,BackendName,BackendAction,BackendSuccess,BackendVerified,BackendState,StateOperationPhase,RequiresEmergencyReset,Event,ErrorMessage'
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Set-Content -LiteralPath $Path -Value $header -Encoding UTF8 }
    Add-Content -LiteralPath $Path -Value (Convert-ProductionLogRowToCsv -Row $Row) -Encoding UTF8
}

function Get-ProductionRemainingSeconds {
    param([datetime]$Now, [object]$EndTime)
    if ($null -eq $EndTime) { return $null }
    $remaining = [int][Math]::Ceiling((([datetime]$EndTime) - $Now).TotalSeconds)
    if ($remaining -lt 0) { return 0 }
    $remaining
}

function Get-ProductionStatePhase {
    param([string]$StatePath)
    if ([string]::IsNullOrWhiteSpace($StatePath) -or -not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        return [pscustomobject]@{ Phase=$null; RequiresEmergencyReset=$false }
    }
    $read = Read-ControllerState -Path $StatePath
    if ($read.Success) { return [pscustomobject]@{ Phase=$read.State.OperationPhase; RequiresEmergencyReset=[bool]$read.State.RequiresEmergencyReset } }
    [pscustomobject]@{ Phase='Invalid'; RequiresEmergencyReset=$true }
}

function New-ProductionLogRow {
    param(
        [object]$Runtime,
        [object]$Config,
        [datetime]$Now,
        [object]$Reading,
        [object]$Backend,
        [string]$BackendAction,
        [object]$BackendResult,
        [string]$Event,
        [string]$ErrorMessage
    )
    $phase = Get-ProductionStatePhase -StatePath $Config.StatePath
    [pscustomobject]@{
        TimestampUtc = $Now.ToUniversalTime().ToString('o')
        RunId = $Runtime.RunId
        ControllerInstanceId = $Runtime.ControllerInstanceId
        CorrelationId = $Runtime.CurrentCorrelationId
        ControllerState = $Runtime.ControllerState
        HighestTemperature = if ($null -ne $Reading) { $Reading.Highest } else { $null }
        ValidCoreCount = if ($null -ne $Reading) { $Reading.ValidCoreCount } else { 0 }
        ThresholdCelsius = $Config.ThresholdCelsius
        ConsecutiveHighReadings = $Runtime.ConsecutiveHighReadings
        RequiredConsecutiveHighReadings = $Config.RequiredConsecutiveHighReadings
        RemainingBoostSeconds = Get-ProductionRemainingSeconds -Now $Now -EndTime $Runtime.BoostEndTime
        RemainingCooldownSeconds = Get-ProductionRemainingSeconds -Now $Now -EndTime $Runtime.CooldownEndTime
        BackendName = if ($null -ne $Backend) { $Backend.BackendName } else { 'DellCctk' }
        BackendAction = $BackendAction
        BackendSuccess = if ($null -ne $BackendResult) { $BackendResult.Success } else { $null }
        BackendVerified = if ($null -ne $BackendResult) { $BackendResult.Verified } else { $null }
        BackendState = if ($null -ne $BackendResult) { $BackendResult.NewState } elseif ($null -ne $Backend) { $Backend.RuntimeState.CurrentFanState } else { $null }
        StateOperationPhase = $phase.Phase
        RequiresEmergencyReset = $phase.RequiresEmergencyReset
        Event = $Event
        ErrorMessage = $ErrorMessage
    }
}

function Initialize-ProductionStateFile {
    param([string]$StatePath, [string]$ControllerInstanceId, [string]$CorrelationId)
    $directory = Split-Path -Parent $StatePath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        $state = New-ControllerState -ControllerInstanceId $ControllerInstanceId -CorrelationId $CorrelationId -BackendName 'DellCctk'
        [void](Write-ControllerStateAtomic -Path $StatePath -State $state)
    }
}

function Invoke-ProductionStartupRecovery {
    param([object]$Backend, [object]$Config, [object]$Runtime)
    Initialize-ProductionStateFile -StatePath $Config.StatePath -ControllerInstanceId $Runtime.ControllerInstanceId -CorrelationId ([guid]::NewGuid().ToString())
    $read = Read-ControllerState -Path $Config.StatePath
    if (-not $read.Success) { throw "Startup recovery geweigerd: state ongeldig: $(@($read.Errors) -join '; ')" }
    $phase = [string]$read.State.OperationPhase
    switch ($phase) {
        'Idle' { return 'StartupIdle' }
        'Restored' { return 'StartupRestored' }
        'EnablePending' {
            $stateResult = Get-FanBackendControlState -Backend $Backend
            if ($stateResult.Success -and $stateResult.Verified -and [string]$stateResult.NewState -eq 'Automatic') {
                $restored = Set-ControllerStatePhase -State $read.State -OperationPhase 'Restored'
                [void](Write-ControllerStateAtomic -Path $Config.StatePath -State $restored)
                return 'StartupEnablePendingAlreadyAutomatic'
            }
            if ($stateResult.Success -and $stateResult.Verified -and [string]$stateResult.NewState -eq 'BoostEnabled') {
                $active = Set-ControllerStatePhase -State $read.State -OperationPhase 'ActiveVerified'
                [void](Write-ControllerStateAtomic -Path $Config.StatePath -State $active)
                $restore = Restore-FanBackendAutomaticControl -Backend $Backend -StatePath $Config.StatePath -CorrelationId ([guid]::NewGuid().ToString()) -Reason 'ProductionStartupRecoveryEnablePending'
                $Runtime.RestoresExecuted++
                if ($restore.Success -and $restore.Verified -and [string]$restore.NewState -eq 'Automatic') { return 'StartupRecoveredEnablePending' }
                throw "Startup recovery EnablePending faalde: $($restore.ErrorMessage)"
            }
            throw 'Startup recovery EnablePending faalde: backendstatus onbekend.'
        }
        'ActiveVerified' {
            $restore = Restore-FanBackendAutomaticControl -Backend $Backend -StatePath $Config.StatePath -CorrelationId ([guid]::NewGuid().ToString()) -Reason 'ProductionStartupRecoveryActiveVerified'
            $Runtime.RestoresExecuted++
            if ($restore.Success -and $restore.Verified -and [string]$restore.NewState -eq 'Automatic') { return 'StartupRecoveredActiveVerified' }
            throw "Startup recovery ActiveVerified faalde: $($restore.ErrorMessage)"
        }
        'DisablePending' {
            $restore = Restore-FanBackendAutomaticControl -Backend $Backend -StatePath $Config.StatePath -CorrelationId ([guid]::NewGuid().ToString()) -Reason 'ProductionStartupRecoveryDisablePending'
            $Runtime.RestoresExecuted++
            if ($restore.Success -and $restore.Verified -and [string]$restore.NewState -eq 'Automatic') { return 'StartupRecoveredDisablePending' }
            throw "Startup recovery DisablePending faalde: $($restore.ErrorMessage)"
        }
        'CleanupRequired' {
            $reset = Invoke-FanBackendEmergencyReset -Backend $Backend -StatePath $Config.StatePath -CorrelationId ([guid]::NewGuid().ToString()) -Reason 'ProductionStartupEmergencyRecovery' -ForceIfOwned
            $Runtime.EmergencyResets++
            if ($reset.Success -and $reset.Verified -and [string]$reset.NewState -eq 'Automatic') { return 'StartupEmergencyRecovered' }
            throw "Startup emergency recovery faalde: $($reset.ErrorMessage)"
        }
        default { throw "Startup recovery geweigerd voor fase: $phase" }
    }
}

function Invoke-ProductionStartupRecoveryReadOnly {
    param([object]$Backend, [object]$Config)

    if (-not (Test-Path -LiteralPath $Config.StatePath -PathType Leaf)) { throw 'StartupOnly startup recovery geweigerd: statebestand ontbreekt.' }
    $read = Read-ControllerState -Path $Config.StatePath
    if (-not $read.Success) { throw "StartupOnly startup recovery geweigerd: state ongeldig: $(@($read.Errors) -join '; ')" }
    $phase = [string]$read.State.OperationPhase
    switch ($phase) {
        'Idle' { return 'StartupIdle' }
        'Restored' { return 'StartupRestored' }
        'EnablePending' {
            $stateResult = Get-FanBackendControlState -Backend $Backend
            if ($stateResult.Success -and $stateResult.Verified -and [string]$stateResult.NewState -eq 'Automatic') { return 'StartupEnablePendingAlreadyAutomaticReadOnly' }
            throw 'StartupOnly startup recovery geweigerd: EnablePending vereist herstelactie of onbekende backendstatus.'
        }
        default { throw "StartupOnly startup recovery geweigerd: fase vereist write-cleanup: $phase" }
    }
}

function Invoke-ProductionRestore {
    param([object]$Backend, [object]$Config, [object]$Runtime, [string]$Reason)
    $Runtime.CurrentCorrelationId = if ([string]::IsNullOrWhiteSpace($Runtime.CurrentCorrelationId)) { ([guid]::NewGuid()).ToString() } else { $Runtime.CurrentCorrelationId }
    $restore = Restore-FanBackendAutomaticControl -Backend $Backend -StatePath $Config.StatePath -CorrelationId $Runtime.CurrentCorrelationId -Reason $Reason
    $Runtime.RestoresExecuted++
    if ($restore.Success -and $restore.Verified -and [string]$restore.NewState -eq 'Automatic') {
        $Runtime.AutomaticVerified = $true
        return $restore
    }
    $Runtime.RestoreFailures++
    $Runtime.ExitCode = 30
    $reset = Invoke-FanBackendEmergencyReset -Backend $Backend -StatePath $Config.StatePath -CorrelationId ([guid]::NewGuid().ToString()) -Reason 'ProductionRestoreFailureEmergencyReset' -ForceIfOwned
    $Runtime.EmergencyResets++
    if (-not ($reset.Success -and $reset.Verified -and [string]$reset.NewState -eq 'Automatic')) { $Runtime.ExitCode = 32 }
    $restore
}

function Invoke-ProductionExitCleanup {
    param([object]$Backend, [object]$Config, [object]$Runtime)
    if (-not (Test-Path -LiteralPath $Config.StatePath -PathType Leaf)) { return [pscustomobject]@{ Attempted=$false; Success=$true; Result=$null } }
    $read = Read-ControllerState -Path $Config.StatePath
    if (-not $read.Success) { return [pscustomobject]@{ Attempted=$false; Success=$false; Result=$null } }
    if (@('EnablePending','ActiveVerified','DisablePending','CleanupRequired') -notcontains [string]$read.State.OperationPhase) {
        return [pscustomobject]@{ Attempted=$false; Success=$true; Result=$null }
    }
    $result = if ([string]$read.State.OperationPhase -eq 'CleanupRequired') {
        $Runtime.EmergencyResets++
        Invoke-FanBackendEmergencyReset -Backend $Backend -StatePath $Config.StatePath -CorrelationId ([guid]::NewGuid().ToString()) -Reason 'ProductionExitEmergencyReset' -ForceIfOwned
    } else {
        Invoke-ProductionRestore -Backend $Backend -Config $Config -Runtime $Runtime -Reason 'ProductionExitRestore'
    }
    [pscustomobject]@{ Attempted=$true; Success=($result.Success -and $result.Verified -and [string]$result.NewState -eq 'Automatic'); Result=$result }
}

function New-ProductionSummary {
    param([object]$Runtime, [object]$Backend, [object]$Config, [int]$ExitCode)
    $phase = Get-ProductionStatePhase -StatePath $Config.StatePath
    [pscustomobject]@{
        TotalRuntimeMinutes = [Math]::Round((([DateTime]::UtcNow) - [datetime]$Runtime.StartedAtUtc).TotalMinutes, 2)
        ValidMeasurements = $Runtime.ValidMeasurements
        FailedMeasurements = $Runtime.FailedMeasurements
        HighestTemperature = $Runtime.HighestMeasuredTemperature
        BoostsStarted = $Runtime.BoostsStarted
        RestoresExecuted = $Runtime.RestoresExecuted
        CooldownsCompleted = $Runtime.CooldownsCompleted
        EnableFailures = $Runtime.EnableFailures
        RestoreFailures = $Runtime.RestoreFailures
        EmergencyResets = $Runtime.EmergencyResets
        FinalBackendState = if ($null -ne $Backend) { $Backend.RuntimeState.CurrentFanState } else { 'Unknown' }
        FinalStatePhase = $phase.Phase
        AutomaticVerified = $Runtime.AutomaticVerified
        RequiresEmergencyReset = $phase.RequiresEmergencyReset
        ProductionLogPath = $Config.LogPath
        ExitCode = [int]$ExitCode
        ExecutionPhase = $Runtime.ExecutionPhase
        ExceptionDetails = $Runtime.ExceptionDetails
        LogWriteExceptionMessage = $Runtime.LogWriteExceptionMessage
        CleanupExceptionMessage = $Runtime.CleanupExceptionMessage
        FatalErrorPath = $Runtime.FatalErrorPath
    }
}

function Write-ProductionSummary {
    param([object]$Summary)
    Write-Host "Totale looptijd (min): $($Summary.TotalRuntimeMinutes)"
    Write-Host "Geldige metingen: $($Summary.ValidMeasurements)"
    Write-Host "Mislukte metingen: $($Summary.FailedMeasurements)"
    Write-Host "Hoogste temperatuur: $($Summary.HighestTemperature)"
    Write-Host "Boosts gestart: $($Summary.BoostsStarted)"
    Write-Host "Restores uitgevoerd: $($Summary.RestoresExecuted)"
    Write-Host "Cooldowns voltooid: $($Summary.CooldownsCompleted)"
    Write-Host "Enable failures: $($Summary.EnableFailures)"
    Write-Host "Restore failures: $($Summary.RestoreFailures)"
    Write-Host "Emergency resets: $($Summary.EmergencyResets)"
    Write-Host "Eindstatus backend: $($Summary.FinalBackendState)"
    Write-Host "Eindfase statebestand: $($Summary.FinalStatePhase)"
    Write-Host "Automatic verified: $($Summary.AutomaticVerified)"
    Write-Host "Emergency reset vereist: $($Summary.RequiresEmergencyReset)"
    Write-Host "Productielogpad: $($Summary.ProductionLogPath)"
    Write-Host "Exitcode: $($Summary.ExitCode)"
}

function Invoke-DellFanControllerProduction {
    param(
        [string]$ConfigPath,
        [bool]$EnableProductionMode,
        [switch]$AllowHardwareWrites,
        [string]$HardwareWriteConfirmation,
        [int]$RunMinutes,
        [object[]]$TestSnapshots,
        [object]$TestBackend,
        [object]$TestIsAdministrator,
        [object]$TestLockAcquired,
        [scriptblock]$TestSleepInvoker,
        [object]$TestStartTime,
        [switch]$ValidateOnly,
        [switch]$StartupOnly,
        [scriptblock]$TestProcessInvoker,
        [string]$TestFakeProcessMode,
        [string]$TestFakeProcessCallPath,
        [string]$TestThrowPhase
    )

    $configResult = Read-DellFanControllerProductionConfig -Path $ConfigPath
    $config = $configResult.Config
    $runtime = New-ProductionRuntimeState -RunId ([guid]::NewGuid().ToString())
    $backend = $null
    $session = $null
    $lock = $null
    $exitCode = 0
    $summary = $null
    $validationResult = $null
    $coreTempValidation = $null
    $stateRead = $null

    try {
        if ($null -eq $TestProcessInvoker -and -not [string]::IsNullOrWhiteSpace($TestFakeProcessMode)) {
            $fakeMode = [string]$TestFakeProcessMode
            $fakeCallPath = [string]$TestFakeProcessCallPath
            $TestProcessInvoker = {
                param([string]$ExecutablePath, [string[]]$ArgumentList, [int]$TimeoutSeconds)
                if (-not [string]::IsNullOrWhiteSpace($fakeCallPath)) {
                    ([pscustomobject]@{ Argument=[string]@($ArgumentList)[0]; TimeoutSeconds=$TimeoutSeconds } | ConvertTo-Json -Compress) | Add-Content -LiteralPath $fakeCallPath -Encoding UTF8
                }
                if ($fakeMode -eq 'StartedFalseNoError') { return [pscustomobject]@{ Started=$false; ExitCode=$null; StdOut=''; StdErr=''; TimedOut=$false; DurationMs=37; ErrorMessage=$null } }
                [pscustomobject]@{ Started=$true; ExitCode=0; StdOut='FanCtrlOvrd=Disabled'; StdErr=''; TimedOut=$false; DurationMs=35; ErrorMessage=$null }
            }.GetNewClosure()
        }

        if (-not $EnableProductionMode) { throw 'EnableProductionMode ontbreekt.' }
        if (-not $ValidateOnly -and -not $StartupOnly) {
            if (-not $AllowHardwareWrites.IsPresent) { throw 'AllowHardwareWrites switch is vereist voor normale productie.' }
            if ([string]$HardwareWriteConfirmation -ne 'ENABLE_AUTOMATIC_DELL_FAN_CONTROLLER') { throw 'HardwareWriteConfirmation is ongeldig.' }
        }
        if ($config.DryRun -ne $false -or $config.Backend -ne 'DellCctk') { throw 'Productieconfig vereist DryRun=false en Backend=DellCctk.' }
        $admin = if ($null -ne $TestIsAdministrator) { ($TestIsAdministrator -is [bool] -and $TestIsAdministrator -eq $true) } else { Test-ProductionAdministrator }
        if (-not $admin) { $exitCode = 11; throw 'Administratorrechten zijn vereist.' }

        if ($null -ne $TestLockAcquired) {
            if (-not ($TestLockAcquired -is [bool] -and $TestLockAcquired -eq $true)) { $exitCode = 16; throw 'Er draait al een controllerinstance.' }
            $lock = [pscustomobject]@{ Acquired=$true; Mutex=$null }
        } else {
            $lock = New-ProductionLock
            if (-not $lock.Acquired) { $exitCode = 16; throw 'Er draait al een controllerinstance.' }
        }

        $pathCheck = Test-DellCctkPath -CctkPath $config.CctkPath -MinimumVersion '5.2.2.0'
        if (-not $pathCheck.Success) { $exitCode = 12; throw "cctk-pad ongeldig: $(@($pathCheck.Errors) -join '; ')" }

        $sessionParams = @{
            Config = $config
            AllowHardwareWrites = if ($ValidateOnly -or $StartupOnly) { $false } else { $AllowHardwareWrites.IsPresent }
        }
        if ($null -ne $TestProcessInvoker) { $sessionParams.ProcessInvoker = $TestProcessInvoker }
        if ($null -eq $TestBackend) {
            $session = New-ProductionDellCctkSession @sessionParams
            $backend = $session.Backend
        } else {
            $backend = $TestBackend
            $beginAvailability = Invoke-ProductionReadOnlyBackendAvailability -Backend $backend -CommandTimeoutSeconds $config.CommandTimeoutSeconds
            $beginStateForTestBackend = if ($beginAvailability.Success) { Get-ProductionReadOnlyBeginState -Backend $backend } else { $null }
            $session = [pscustomobject]@{
                Backend = $backend
                CommandExecutor = $backend.CommandExecutor
                ProcessInvoker = $null
                AvailabilityResult = $beginAvailability
                BeginStateResult = $beginStateForTestBackend
                AutomaticVerified = (Test-ProductionAutomaticFanState -StateResult $beginStateForTestBackend)
                Diagnostics = [pscustomobject]@{ ProductionSupportVersion=$script:ProductionSupportVersion; ProcessExecutorVersion=$script:ProcessExecutorVersion }
            }
        }

        if ($ValidateOnly) {
            if ($null -ne $TestSnapshots -and @($TestSnapshots).Count -gt 0) {
                $coreTempValidation = @($TestSnapshots)[0]
            } else {
                $coreTempValidation = Read-ProductionCoreTempSnapshot -DiscoverScript (Join-Path $ScriptDirectory 'Discover-CoreTempSharedMemory.ps1')
            }
            if (-not $coreTempValidation.Success) { $exitCode = 12; throw $coreTempValidation.Message }
            $stateRead = if (Test-Path -LiteralPath $config.StatePath -PathType Leaf) { Read-ControllerState -Path $config.StatePath } else { [pscustomobject]@{ Success=$false; State=$null; Errors=@('Statebestand ontbreekt.') } }
            if (-not $session.AvailabilityResult.Success) { $exitCode = 12; throw (Format-ProductionBeginStateFailureMessage -BeginState $session.AvailabilityResult -Backend $backend) }
            if (-not $session.AutomaticVerified) { $exitCode = 13; throw (Format-ProductionBeginStateFailureMessage -BeginState $session.BeginStateResult -Backend $backend) }
            $runtime.AutomaticVerified = $true
            $validationResult = New-ProductionValidationResult -Config $config -Admin $admin -CoreTemp $coreTempValidation -StateRead $stateRead -Session $session -ExitCode 0 -Message ''
            return [pscustomobject]@{ Success=$true; ExitCode=0; Summary=$null; Validation=$validationResult; Runtime=$runtime; Backend=$backend; Config=$config; Session=$session }
        }

        Set-ProductionExecutionPhase -Runtime $runtime -Phase 'StartupRecovery'
        if ([string]$TestThrowPhase -eq 'StartupRecovery') { throw 'TEST_THROW StartupRecovery' }
        $startupEvent = if ($StartupOnly) {
            Invoke-ProductionStartupRecoveryReadOnly -Backend $backend -Config $config
        } else {
            Invoke-ProductionStartupRecovery -Backend $backend -Config $config -Runtime $runtime
        }
        Set-ProductionExecutionPhase -Runtime $runtime -Phase 'ValidateAvailability'
        if ([string]$TestThrowPhase -eq 'ValidateAvailability') { throw 'TEST_THROW ValidateAvailability' }
        if (-not $session.AvailabilityResult.Success) { $exitCode = 12; throw (Format-ProductionBeginStateFailureMessage -BeginState $session.AvailabilityResult -Backend $backend) }
        Set-ProductionExecutionPhase -Runtime $runtime -Phase 'ValidateBeginState'
        if ([string]$TestThrowPhase -eq 'ValidateBeginState') { throw 'TEST_THROW ValidateBeginState' }
        $beginState = $session.BeginStateResult
        if (-not (Test-ProductionAutomaticFanState -StateResult $beginState)) { $exitCode = 13; throw (Format-ProductionBeginStateFailureMessage -BeginState $beginState -Backend $backend) }
        $runtime.AutomaticVerified = $true

        Set-ProductionExecutionPhase -Runtime $runtime -Phase 'InitializeClock'
        if ([string]$TestThrowPhase -eq 'InitializeClock') { throw 'TEST_THROW InitializeClock' }
        $clock = if ($PSBoundParameters.ContainsKey('TestStartTime')) { [datetime]$TestStartTime } else { Get-Date }
        $endAt = if ($RunMinutes -gt 0) { $clock.AddMinutes($RunMinutes) } else { $null }
        $sampleIndex = 0
        $discoverScript = Join-Path $ScriptDirectory 'Discover-CoreTempSharedMemory.ps1'
        $preflightSnapshot = $null
        if ($null -eq $TestSnapshots) {
            Set-ProductionExecutionPhase -Runtime $runtime -Phase 'ReadPreflightCoreTemp'
            if ([string]$TestThrowPhase -eq 'ReadPreflightCoreTemp') { throw 'TEST_THROW ReadPreflightCoreTemp' }
            $preflightSnapshot = Read-ProductionCoreTempSnapshot -DiscoverScript $discoverScript
            if (-not $preflightSnapshot.Success) { $exitCode = 12; throw $preflightSnapshot.Message }
            Set-ProductionExecutionPhase -Runtime $runtime -Phase 'CalculatePreflightTemperature'
            if ([string]$TestThrowPhase -eq 'CalculatePreflightTemperature') { throw 'TEST_THROW CalculatePreflightTemperature' }
            $preflightReading = Get-ProductionHighestTemperature -Temperatures @($preflightSnapshot.Temperatures)
            if (-not $preflightReading.Success) { $exitCode = 12; throw 'Core Temp shared memory bevat geen geldige temperaturen.' }
        } else {
            Set-ProductionExecutionPhase -Runtime $runtime -Phase 'ReadPreflightCoreTemp'
            if ([string]$TestThrowPhase -eq 'ReadPreflightCoreTemp') { throw 'TEST_THROW ReadPreflightCoreTemp' }
            Set-ProductionExecutionPhase -Runtime $runtime -Phase 'CalculatePreflightTemperature'
            if ([string]$TestThrowPhase -eq 'CalculatePreflightTemperature') { throw 'TEST_THROW CalculatePreflightTemperature' }
            if ($StartupOnly -and @($TestSnapshots).Count -gt 0) {
                $preflightReadingForTest = Get-ProductionHighestTemperature -Temperatures @(@($TestSnapshots)[0].Temperatures)
                if (-not $preflightReadingForTest.Success) { $exitCode = 12; throw 'Core Temp shared memory bevat geen geldige temperaturen.' }
            }
        }
        Set-ProductionExecutionPhase -Runtime $runtime -Phase 'WriteStartupLog'
        if ([string]$TestThrowPhase -eq 'WriteStartupLog') { throw 'TEST_THROW WriteStartupLog' }
        Write-ProductionLog -Path $config.LogPath -Row (New-ProductionLogRow -Runtime $runtime -Config $config -Now $clock -Reading $null -Backend $backend -BackendAction 'StartupRecovery' -BackendResult $beginState -Event $startupEvent -ErrorMessage '')
        if ($StartupOnly) {
            $exitCode = 0
            return [pscustomobject]@{ Success=$true; ExitCode=0; Summary=(New-ProductionSummary -Runtime $runtime -Backend $backend -Config $config -ExitCode 0); Runtime=$runtime; Backend=$backend; Config=$config; Session=$session }
        }

        Set-ProductionExecutionPhase -Runtime $runtime -Phase 'EnterMonitoringLoop'
        if ([string]$TestThrowPhase -eq 'EnterMonitoringLoop') { throw 'TEST_THROW EnterMonitoringLoop' }
        while (-not $runtime.ShouldStop) {
            if ($null -ne $endAt -and $clock -ge $endAt) { break }
            if ($null -ne $preflightSnapshot) {
                $snapshot = $preflightSnapshot
                $preflightSnapshot = $null
            } elseif ($null -ne $TestSnapshots) {
                if ($sampleIndex -ge @($TestSnapshots).Count) { break }
                $snapshot = @($TestSnapshots)[$sampleIndex]
                $sampleIndex++
            } else {
                $snapshot = Read-ProductionCoreTempSnapshot -DiscoverScript $discoverScript
            }
            $event = ''
            $backendAction = ''
            $backendResult = $null
            $errorMessage = ''
            $reading = $null

            if (-not $snapshot.Success) {
                $runtime.FailedMeasurements++
                if ($runtime.ControllerState -eq 'Boost') {
                    $backendAction = 'RestoreAutomatic'
                    $backendResult = Invoke-ProductionRestore -Backend $backend -Config $config -Runtime $runtime -Reason 'ProductionSensorFailureDuringBoost'
                    $runtime.ShouldStop = $true
                    $event = if ($backendResult.Success -and $backendResult.Verified) { 'DELL_SENSOR_FAILURE_RESTORE_SUCCEEDED' } else { 'DELL_SENSOR_FAILURE_RESTORE_FAILED' }
                    if (-not ($backendResult.Success -and $backendResult.Verified)) { $exitCode = 31 }
                } else {
                    $runtime.ConsecutiveHighReadings = 0
                    $runtime.ConsecutiveSensorFailures++
                    $event = 'SENSOR_READ_FAILED'
                    if ($runtime.ConsecutiveSensorFailures -ge 3) { $runtime.ShouldStop = $true; $exitCode = 22; $event = 'CONTROLLER_STOPPED_AFTER_SENSOR_FAILURES' }
                }
            } else {
                $reading = Get-ProductionHighestTemperature -Temperatures @($snapshot.Temperatures)
                if (-not $reading.Success) {
                    $runtime.FailedMeasurements++
                    if ($runtime.ControllerState -eq 'Boost') {
                        $backendAction = 'RestoreAutomatic'
                        $backendResult = Invoke-ProductionRestore -Backend $backend -Config $config -Runtime $runtime -Reason 'ProductionInvalidSensorDuringBoost'
                        $runtime.ShouldStop = $true
                        $event = if ($backendResult.Success -and $backendResult.Verified) { 'DELL_SENSOR_FAILURE_RESTORE_SUCCEEDED' } else { 'DELL_SENSOR_FAILURE_RESTORE_FAILED' }
                        if (-not ($backendResult.Success -and $backendResult.Verified)) { $exitCode = 31 }
                    } else {
                        $runtime.ConsecutiveHighReadings = 0
                        $runtime.ConsecutiveSensorFailures++
                        $event = 'SENSOR_READ_FAILED'
                        if ($runtime.ConsecutiveSensorFailures -ge 3) { $runtime.ShouldStop = $true; $exitCode = 22; $event = 'CONTROLLER_STOPPED_AFTER_SENSOR_FAILURES' }
                    }
                } else {
                    $runtime.ValidMeasurements++
                    $runtime.ConsecutiveSensorFailures = 0
                    if ($null -eq $runtime.HighestMeasuredTemperature -or [double]$reading.Highest -gt [double]$runtime.HighestMeasuredTemperature) { $runtime.HighestMeasuredTemperature = [double]$reading.Highest }
                    if ($runtime.ControllerState -eq 'Monitoring') {
                        if ([double]$reading.Highest -ge [double]$config.ThresholdCelsius) { $runtime.ConsecutiveHighReadings++ } else { $runtime.ConsecutiveHighReadings = 0 }
                        if ($runtime.ConsecutiveHighReadings -ge [int]$config.RequiredConsecutiveHighReadings) {
                            $runtime.CurrentCorrelationId = ([guid]::NewGuid()).ToString()
                            $backendAction = 'EnableBoost'
                            $backendResult = Enable-FanBackendBoost -Backend $backend -StatePath $config.StatePath -ControllerInstanceId $runtime.ControllerInstanceId -CorrelationId $runtime.CurrentCorrelationId -Reason 'ProductionThresholdExceeded'
                            if ($backendResult.Success -and $backendResult.Verified -and [string]$backendResult.NewState -eq 'BoostEnabled') {
                                $runtime.ControllerState = 'Boost'
                                $runtime.BoostsStarted++
                                $runtime.BoostEndTime = $clock.AddSeconds([int]$config.BoostDurationSeconds)
                                $runtime.ConsecutiveHighReadings = 0
                                $runtime.AutomaticVerified = $false
                                $event = 'DELL_ENABLE_SUCCEEDED'
                            } else {
                                $runtime.EnableFailures++
                                $event = 'DELL_ENABLE_FAILED'
                                $errorMessage = $backendResult.ErrorMessage
                                [void](Invoke-ProductionRestore -Backend $backend -Config $config -Runtime $runtime -Reason 'ProductionEnableFailureCleanup')
                                $runtime.ShouldStop = $true
                                $exitCode = 20
                            }
                        }
                    } elseif ($runtime.ControllerState -eq 'Boost') {
                        $runtime.ConsecutiveHighReadings = 0
                        if ($clock -ge [datetime]$runtime.BoostEndTime) {
                            $backendAction = 'RestoreAutomatic'
                            $backendResult = Invoke-ProductionRestore -Backend $backend -Config $config -Runtime $runtime -Reason 'ProductionBoostDurationElapsed'
                            if ($backendResult.Success -and $backendResult.Verified -and [string]$backendResult.NewState -eq 'Automatic') {
                                $runtime.ControllerState = 'Cooldown'
                                $runtime.BoostEndTime = $null
                                $runtime.CooldownEndTime = $clock.AddSeconds([int]$config.CooldownSeconds)
                                $event = 'DELL_RESTORE_SUCCEEDED'
                            } else {
                                $runtime.ShouldStop = $true
                                $event = 'DELL_RESTORE_FAILED'
                                $errorMessage = $backendResult.ErrorMessage
                                $exitCode = 30
                            }
                        }
                    } elseif ($runtime.ControllerState -eq 'Cooldown') {
                        $runtime.ConsecutiveHighReadings = 0
                        if ($clock -ge [datetime]$runtime.CooldownEndTime) {
                            $runtime.ControllerState = 'Monitoring'
                            $runtime.CooldownEndTime = $null
                            $runtime.CooldownsCompleted++
                            $event = 'COOLDOWN_ENDED'
                        }
                    }
                }
            }

            Set-ProductionExecutionPhase -Runtime $runtime -Phase 'WriteMeasurementLog'
            Write-ProductionLog -Path $config.LogPath -Row (New-ProductionLogRow -Runtime $runtime -Config $config -Now $clock -Reading $reading -Backend $backend -BackendAction $backendAction -BackendResult $backendResult -Event $event -ErrorMessage $errorMessage)
            if ($runtime.ShouldStop) { break }
            if ($null -ne $TestSleepInvoker) { & $TestSleepInvoker ([int]$config.PollIntervalSeconds) } elseif ($null -eq $TestSnapshots) { Start-Sleep -Seconds ([int]$config.PollIntervalSeconds) }
            $clock = $clock.AddSeconds([int]$config.PollIntervalSeconds)
        }
    }
    catch {
        $originalError = $_
        $exitCodeBeforeCatch = $exitCode
        if ($null -ne $runtime -and $null -eq $runtime.ExceptionDetails) {
            $runtime.ExceptionDetails = New-ProductionExceptionDetails -ErrorRecord $originalError -Runtime $runtime -ExitCodeBeforeCatch $exitCodeBeforeCatch
        }
        if ($exitCode -eq 0) { $exitCode = 99 }
        if ($ValidateOnly) {
            $validationResult = New-ProductionValidationResult -Config $config -Admin $admin -CoreTemp $coreTempValidation -StateRead $stateRead -Session $session -ExitCode $exitCode -Message $originalError.Exception.Message
            return [pscustomobject]@{ Success=$false; ExitCode=$exitCode; Summary=$null; Validation=$validationResult; Runtime=$runtime; Backend=$backend; Config=$config; Session=$session }
        }
        try {
            if ($null -ne $backend -and $null -ne $config) {
                Write-ProductionLog -Path $config.LogPath -Row (New-ProductionLogRow -Runtime $runtime -Config $config -Now (Get-Date) -Reading $null -Backend $backend -BackendAction 'Exception' -BackendResult $null -Event 'CONTROLLER_EXCEPTION' -ErrorMessage $originalError.Exception.Message)
            }
        } catch {
            if ($null -ne $runtime) { $runtime.LogWriteExceptionMessage = $_.Exception.Message }
            try { [void](Write-ProductionFatalErrorFile -Config $config -Runtime $runtime -ExitCode $exitCode) } catch {}
        }
    }
    finally {
        if (-not $ValidateOnly -and -not $StartupOnly -and $null -ne $backend -and $null -ne $config) {
            Set-ProductionExecutionPhase -Runtime $runtime -Phase 'ExitCleanup'
            try {
                $cleanup = Invoke-ProductionExitCleanup -Backend $backend -Config $config -Runtime $runtime
                if ($cleanup.Attempted -and -not $cleanup.Success -and $exitCode -eq 0) { $exitCode = 32 }
            } catch {
                if ($null -ne $runtime) { $runtime.CleanupExceptionMessage = $_.Exception.Message }
                if ($exitCode -eq 0) { $exitCode = 99 }
                if ($null -ne $runtime -and $null -eq $runtime.ExceptionDetails) {
                    $runtime.ExceptionDetails = New-ProductionExceptionDetails -ErrorRecord $_ -Runtime $runtime -ExitCodeBeforeCatch 0
                }
                try { [void](Write-ProductionFatalErrorFile -Config $config -Runtime $runtime -ExitCode $exitCode) } catch {}
            }
        }
        Release-ProductionLock -Lock $lock
        if ($null -ne $config) { $summary = New-ProductionSummary -Runtime $runtime -Backend $backend -Config $config -ExitCode $exitCode }
    }
    [pscustomobject]@{ Success=($exitCode -eq 0); ExitCode=$exitCode; Summary=$summary; Runtime=$runtime; Backend=$backend; Config=$config; Session=$session }
}

$dotSourceOnlyVariable = Get-Variable -Name DellFanControllerDotSourceOnly -Scope Script -ErrorAction SilentlyContinue
$dotSourceOnly = ($null -ne $dotSourceOnlyVariable -and $dotSourceOnlyVariable.Value -eq $true)
if ($MyInvocation.InvocationName -ne '.' -and -not $dotSourceOnly) {
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        Write-Host "Gebruik: powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\DellFanController.ps1' -ConfigPath '.\controller-config.production.json' -EnableProductionMode -AllowHardwareWrites -HardwareWriteConfirmation 'ENABLE_AUTOMATIC_DELL_FAN_CONTROLLER'"
        exit 2
    }
    $invokeParams = @{
        ConfigPath = $ConfigPath
        EnableProductionMode = ([bool]$EnableProductionMode)
        AllowHardwareWrites = $AllowHardwareWrites.IsPresent
        HardwareWriteConfirmation = $HardwareWriteConfirmation
        RunMinutes = $RunMinutes
    }
    if ($ValidateOnly) { $invokeParams.ValidateOnly = $true }
    if ($StartupOnly) { $invokeParams.StartupOnly = $true }
    if ($null -ne $TestProcessInvoker) { $invokeParams.TestProcessInvoker = $TestProcessInvoker }
    if (-not [string]::IsNullOrWhiteSpace($TestFakeProcessMode)) { $invokeParams.TestFakeProcessMode = $TestFakeProcessMode }
    if (-not [string]::IsNullOrWhiteSpace($TestFakeProcessCallPath)) { $invokeParams.TestFakeProcessCallPath = $TestFakeProcessCallPath }
    if ($PSBoundParameters.ContainsKey('TestTemperatureValues')) {
        $invokeParams.TestSnapshots = @([pscustomobject]@{ Success=$true; Message=''; Temperatures=@($TestTemperatureValues) })
    }
    if ($PSBoundParameters.ContainsKey('TestSnapshots')) { $invokeParams.TestSnapshots = $TestSnapshots }
    if ($PSBoundParameters.ContainsKey('TestIsAdministrator')) { $invokeParams.TestIsAdministrator = $TestIsAdministrator.IsPresent }
    if ($PSBoundParameters.ContainsKey('TestLockAcquired')) { $invokeParams.TestLockAcquired = $TestLockAcquired.IsPresent }
    $result = Invoke-DellFanControllerProduction @invokeParams
    if ($JsonSummary) {
        if ($ValidateOnly) { $result.Validation | ConvertTo-Json -Depth 10 } else { $result.Summary | ConvertTo-Json -Depth 8 }
    } else {
        if ($ValidateOnly) { $result.Validation | Format-List * } else { Write-ProductionSummary -Summary $result.Summary }
    }
    exit ([int]$result.ExitCode)
}
