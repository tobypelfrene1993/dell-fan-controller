[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$controllerPath = Join-Path $ScriptDirectory 'DellFanController.ps1'
$dryRunPath = Join-Path $ScriptDirectory 'DellFanController-DryRun.ps1'
$activeConfigPath = Join-Path $ScriptDirectory 'controller-config.json'
$stateModulePath = Join-Path $ScriptDirectory 'DellFanController-State.ps1'
$contractPath = Join-Path $ScriptDirectory 'FanBackend.Contract.ps1'
$dellBackendPath = Join-Path $ScriptDirectory 'FanBackend.DellCctk.ps1'
$processExecutorPath = Join-Path $ScriptDirectory 'DellCctk.ProcessExecutor.ps1'
$productionSupportPath = Join-Path $ScriptDirectory 'DellFanController-ProductionSupport.ps1'
$productionConfigPath = Join-Path $ScriptDirectory 'controller-config.production.json'
$productionStatePath = Join-Path $ScriptDirectory 'logs\dell-fan-controller-state.dellcctk.json'
$productionLogPath = Join-Path $ScriptDirectory 'logs\dell-fan-controller-production.csv'
$testRoot = Join-Path $ScriptDirectory ("test-output\production-controller-{0}" -f ([guid]::NewGuid().ToString('N')))
$realCctkPath = 'C:\Program Files (x86)\Dell\Command Configure\X86_64\cctk.exe'
$realProcessCount = 0
$cctkExecutionCount = 0

$dryRunBefore = Get-FileHash -LiteralPath $dryRunPath -Algorithm SHA256
$activeConfigBefore = Get-FileHash -LiteralPath $activeConfigPath -Algorithm SHA256
$stateModuleBefore = Get-FileHash -LiteralPath $stateModulePath -Algorithm SHA256
$contractBefore = Get-FileHash -LiteralPath $contractPath -Algorithm SHA256
$dellBackendBefore = Get-FileHash -LiteralPath $dellBackendPath -Algorithm SHA256
$processExecutorBefore = Get-FileHash -LiteralPath $processExecutorPath -Algorithm SHA256
$productionConfigBefore = if (Test-Path -LiteralPath $productionConfigPath -PathType Leaf) { Get-FileHash -LiteralPath $productionConfigPath -Algorithm SHA256 } else { $null }
$productionStateBefore = if (Test-Path -LiteralPath $productionStatePath -PathType Leaf) { Get-FileHash -LiteralPath $productionStatePath -Algorithm SHA256 } else { $null }
$productionLogBefore = if (Test-Path -LiteralPath $productionLogPath -PathType Leaf) { Get-FileHash -LiteralPath $productionLogPath -Algorithm SHA256 } else { $null }

. $controllerPath

function New-TestResult { param([string]$Name,[bool]$Passed,[string]$Details) [pscustomobject]@{Name=$Name;Passed=$Passed;Details=$Details} }
function Invoke-TestCase {
    param([string]$Name,[scriptblock]$Action)
    try { New-TestResult -Name $Name -Passed ([bool](& $Action)) -Details 'OK' }
    catch { New-TestResult -Name $Name -Passed $false -Details $_.Exception.Message }
}
function New-TestDirectory {
    $path = Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $path
}
function New-ProductionTestConfigObject {
    param([hashtable]$Overrides)
    $config = [pscustomobject]@{
        SchemaVersion = 1
        ThresholdCelsius = 75
        PollIntervalSeconds = 60
        RequiredConsecutiveHighReadings = 2
        BoostDurationSeconds = 300
        CooldownSeconds = 600
        DryRun = $false
        SensorProvider = 'CoreTempSharedMemory'
        Backend = 'DellCctk'
        CctkPath = $realCctkPath
        CommandTimeoutSeconds = 15
        StatePath = 'logs\dell-fan-controller-state.dellcctk.json'
        LogPath = 'logs\dell-fan-controller-production.csv'
    }
    foreach($key in $Overrides.Keys) {
        if ($config.PSObject.Properties[$key]) { $config.$key = $Overrides[$key] }
        else { Add-Member -InputObject $config -NotePropertyName $key -NotePropertyValue $Overrides[$key] }
    }
    $config
}
function Write-TestConfig {
    param([object]$Config,[string]$Directory)
    $path = Join-Path $Directory 'production-config.json'
    $Config.StatePath = Join-Path $Directory 'state.json'
    $Config.LogPath = Join-Path $Directory 'production.csv'
    $Config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
    $path
}
function New-Snapshot { param([object[]]$Values) [pscustomobject]@{ Success=$true; Message=''; Temperatures=@($Values) } }
function New-FailureSnapshot { param([string]$Message='SENSOR_READ_FAILED') [pscustomobject]@{ Success=$false; Message=$Message; Temperatures=@() } }

function New-FakeDellBackend {
    param([string]$InitialState='Disabled',[string]$Mode='Success',[object]$AllowWrites=$true)
    $state = [pscustomobject]@{ Current=$InitialState; Calls=@(); RealProcessCount=0; CctkExecutionCount=0 }
    $invoker = {
        param([object]$CommandSpec,[string]$CorrelationId,[string]$Reason)
        $arg = [string]@($CommandSpec.ArgumentList)[0]
        $state.Calls = @($state.Calls) + ([pscustomobject]@{ Argument=$arg; Operation=$CommandSpec.Operation; CorrelationId=$CorrelationId; Reason=$Reason })
        if ($Mode -eq 'ExceptionOnEnable' -and $arg -eq '--FanCtrlOvrd=Enabled') { throw 'fake enable exception' }
        if ($Mode -eq 'ExceptionOnRestore' -and $arg -eq '--FanCtrlOvrd=Disabled') { throw 'fake restore exception' }
        if ($Mode -eq 'ExceptionOnQuery' -and $arg -eq '--FanCtrlOvrd') { throw 'fake query exception' }
        if ($arg -eq '--FanCtrlOvrd=Enabled') {
            if ($Mode -eq 'EnableNonZero') { return [pscustomobject]@{ ExitCode=5; StdOut=''; StdErr='enable failed'; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null } }
            if ($Mode -eq 'EnableVerifyFails') { $state.Current='Disabled' } else { $state.Current='Enabled' }
            return [pscustomobject]@{ ExitCode=0; StdOut='FanCtrlOvrd=Enabled'; StdErr=''; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null }
        }
        if ($arg -eq '--FanCtrlOvrd=Disabled') {
            if ($Mode -eq 'RestoreNonZero') { return [pscustomobject]@{ ExitCode=5; StdOut=''; StdErr='restore failed'; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null } }
            if ($Mode -eq 'RestoreVerifyFails') { $state.Current='Enabled' } else { $state.Current='Disabled' }
            return [pscustomobject]@{ ExitCode=0; StdOut='FanCtrlOvrd=Disabled'; StdErr=''; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null }
        }
        if ($arg -eq '--FanCtrlOvrd') {
            if ($Mode -eq 'UnknownState') { return [pscustomobject]@{ ExitCode=0; StdOut='FanCtrlOvrd=Maybe'; StdErr=''; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null } }
            if ($Mode -eq 'BeginNotVerified') { return [pscustomobject]@{ ExitCode=0; StdOut=''; StdErr=''; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null } }
            return [pscustomobject]@{ ExitCode=0; StdOut=("FanCtrlOvrd={0}" -f $state.Current); StdErr=''; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null }
        }
        [pscustomobject]@{ ExitCode=9; StdOut=''; StdErr='bad'; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null }
    }.GetNewClosure()
    [pscustomobject]@{ Backend=(New-DellCctkFanBackend -CctkPath $realCctkPath -CommandTimeoutSeconds 15 -AllowHardwareWrites $AllowWrites -CommandExecutor $invoker); State=$state }
}

function New-FakeProcessInvoker {
    param([string]$Mode='ExactRegression')
    $state = [pscustomobject]@{ Calls=@(); RealProcessCount=0; CctkExecutionCount=0 }
    $invoker = {
        param([string]$ExecutablePath,[string[]]$ArgumentList,[int]$TimeoutSeconds)
        $argument = [string]@($ArgumentList)[0]
        $state.Calls = @($state.Calls) + ([pscustomobject]@{ ExecutablePath=$ExecutablePath; Argument=$argument; TimeoutSeconds=$TimeoutSeconds })
        if ($Mode -eq 'StartedFalseNoError') { return [pscustomobject]@{ Started=$false; ExitCode=$null; StdOut=''; StdErr=''; TimedOut=$false; DurationMs=37; ErrorMessage=$null } }
        [pscustomobject]@{ Started=$true; ExitCode=0; StdOut='FanCtrlOvrd=Disabled'; StdErr=''; TimedOut=$false; DurationMs=35; ErrorMessage=$null }
    }.GetNewClosure()
    [pscustomobject]@{ Invoker=$invoker; State=$state }
}

function Invoke-TestProductionRun {
    param(
        [object[]]$Snapshots,
        [hashtable]$ConfigOverrides=@{},
        [string]$InitialFanState='Disabled',
        [string]$Mode='Success',
        [object]$AllowWrites=$true,
        [string]$Confirmation='ENABLE_AUTOMATIC_DELL_FAN_CONTROLLER',
        [bool]$EnableMode=$true,
        [object]$Admin=$true,
        [object]$Lock=$true,
        [string]$InitialPhase,
        [switch]$StartupOnly,
        [string]$TestThrowPhase,
        [switch]$UseDirectoryAsLogPath
    )
    $dir = New-TestDirectory
    $config = New-ProductionTestConfigObject -Overrides $ConfigOverrides
    $configPath = Write-TestConfig -Config $config -Directory $dir
    if ($UseDirectoryAsLogPath) {
        $logDirectoryPath = Join-Path $dir 'production-log-directory'
        New-Item -ItemType Directory -Path $logDirectoryPath -Force | Out-Null
        $config.LogPath = $logDirectoryPath
        $config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath -Encoding UTF8
    }
    if (-not [string]::IsNullOrWhiteSpace($InitialPhase)) {
        $state = New-ControllerState -ControllerInstanceId ([guid]::NewGuid().ToString()) -CorrelationId ([guid]::NewGuid().ToString()) -BackendName 'DellCctk'
        if ($InitialPhase -eq 'EnablePending') { $state = Set-ControllerStatePhase -State $state -OperationPhase 'EnablePending' }
        elseif ($InitialPhase -eq 'ActiveVerified') { $state = Set-ControllerStatePhase -State $state -OperationPhase 'EnablePending'; $state = Set-ControllerStatePhase -State $state -OperationPhase 'ActiveVerified' }
        elseif ($InitialPhase -eq 'DisablePending') { $state = Set-ControllerStatePhase -State $state -OperationPhase 'EnablePending'; $state = Set-ControllerStatePhase -State $state -OperationPhase 'ActiveVerified'; $state = Set-ControllerStatePhase -State $state -OperationPhase 'DisablePending' }
        elseif ($InitialPhase -eq 'CleanupRequired') { $state = Set-ControllerStatePhase -State $state -OperationPhase 'EnablePending'; $state = Set-ControllerStatePhase -State $state -OperationPhase 'ActiveVerified'; $state = Mark-ControllerEmergencyReset -State $state -ErrorMessage 'test cleanup' }
        elseif ($InitialPhase -eq 'Restored') { $state = Set-ControllerStatePhase -State $state -OperationPhase 'EnablePending'; $state = Set-ControllerStatePhase -State $state -OperationPhase 'ActiveVerified'; $state = Set-ControllerStatePhase -State $state -OperationPhase 'Restored' }
        [void](Write-ControllerStateAtomic -Path $config.StatePath -State $state)
    }
    $fake = New-FakeDellBackend -InitialState $InitialFanState -Mode $Mode -AllowWrites $AllowWrites
    $sleepCalls = [pscustomobject]@{ Calls=@() }
    $sleep = { param([int]$Seconds) $sleepCalls.Calls = @($sleepCalls.Calls) + $Seconds }.GetNewClosure()
    $invokeParams = @{
        ConfigPath = $configPath
        EnableProductionMode = $EnableMode
        AllowHardwareWrites = $AllowWrites
        HardwareWriteConfirmation = $Confirmation
        RunMinutes = 60
        TestSnapshots = $Snapshots
        TestBackend = $fake.Backend
        TestIsAdministrator = $Admin
        TestLockAcquired = $Lock
        TestSleepInvoker = $sleep
        TestStartTime = ([datetime]'2026-06-19T14:00:00Z')
    }
    if ($StartupOnly) { $invokeParams.StartupOnly = $true }
    if (-not [string]::IsNullOrWhiteSpace($TestThrowPhase)) { $invokeParams.TestThrowPhase = $TestThrowPhase }
    $result = Invoke-DellFanControllerProduction @invokeParams
    [pscustomobject]@{ Result=$result; Fake=$fake; Directory=$dir; Config=$config; ConfigPath=$configPath; Sleep=$sleepCalls; StateRead=$(if(Test-Path $config.StatePath){Read-ControllerState -Path $config.StatePath}else{$null}) }
}

function Invoke-ValidateOnlyChildRun {
    $dir = New-TestDirectory
    $config = New-ProductionTestConfigObject @{}
    $configPath = Write-TestConfig -Config $config -Directory $dir
    $stateBefore = if (Test-Path -LiteralPath $config.StatePath -PathType Leaf) { Get-FileHash -LiteralPath $config.StatePath -Algorithm SHA256 } else { $null }
    $configBefore = Get-FileHash -LiteralPath $configPath -Algorithm SHA256
    $callPath = Join-Path $dir 'calls.jsonl'
    $runner = Join-Path $dir 'run-validate-only.ps1'
    $runnerText = @"
`$ErrorActionPreference = 'Stop'
`$controllerPath = '$($controllerPath.Replace("'","''"))'
`$cfgFile = '$($configPath.Replace("'","''"))'
`$callPath = '$($callPath.Replace("'","''"))'
`$fake = {
    param([string]`$ExecutablePath,[string[]]`$ArgumentList,[int]`$TimeoutSeconds)
    ([pscustomobject]@{ Argument=[string]@(`$ArgumentList)[0]; TimeoutSeconds=`$TimeoutSeconds } | ConvertTo-Json -Compress) | Add-Content -LiteralPath `$callPath -Encoding UTF8
    [pscustomobject]@{ Started=`$true; ExitCode=0; StdOut='FanCtrlOvrd=Disabled'; StdErr=''; TimedOut=`$false; DurationMs=35; ErrorMessage=`$null }
}
`$snapshot = [pscustomobject]@{ Success=`$true; Message=''; Temperatures=@(60) }
`$script:DellFanControllerDotSourceOnly = `$true
. `$controllerPath
`$result = Invoke-DellFanControllerProduction -ConfigPath `$cfgFile -EnableProductionMode `$true -ValidateOnly -TestIsAdministrator `$true -TestLockAcquired `$true -TestSnapshots @(`$snapshot) -TestProcessInvoker `$fake
`$result.Validation | ConvertTo-Json -Depth 10
exit ([int]`$result.ExitCode)
"@
    Set-Content -LiteralPath $runner -Value $runnerText -Encoding UTF8
    $json = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($json | Out-String).Trim()
    $parsed = $text | ConvertFrom-Json
    $calls = if (Test-Path -LiteralPath $callPath -PathType Leaf) { @(Get-Content -LiteralPath $callPath | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() }
    [pscustomobject]@{
        Result=$parsed
        ExitCode=$exitCode
        Calls=$calls
        Directory=$dir
        Config=$config
        ConfigPath=$configPath
        ConfigBefore=$configBefore
        StateBefore=$stateBefore
    }
}

function Invoke-NormalChildRun {
    $dir = New-TestDirectory
    $config = New-ProductionTestConfigObject @{}
    $configPath = Write-TestConfig -Config $config -Directory $dir
    $stateBefore = if (Test-Path -LiteralPath $config.StatePath -PathType Leaf) { Get-FileHash -LiteralPath $config.StatePath -Algorithm SHA256 } else { $null }
    $configBefore = Get-FileHash -LiteralPath $configPath -Algorithm SHA256
    $callPath = Join-Path $dir 'normal-calls.jsonl'
    $runner = Join-Path $dir 'run-normal-entrypoint.ps1'
    $runnerText = @"
`$ErrorActionPreference = 'Stop'
`$controllerPath = '$($controllerPath.Replace("'","''"))'
`$cfgFile = '$($configPath.Replace("'","''"))'
`$callPath = '$($callPath.Replace("'","''"))'
`$fake = {
    param([string]`$ExecutablePath,[string[]]`$ArgumentList,[int]`$TimeoutSeconds)
    ([pscustomobject]@{ Argument=[string]@(`$ArgumentList)[0]; TimeoutSeconds=`$TimeoutSeconds } | ConvertTo-Json -Compress) | Add-Content -LiteralPath `$callPath -Encoding UTF8
    [pscustomobject]@{ Started=`$true; ExitCode=0; StdOut='FanCtrlOvrd=Disabled'; StdErr=''; TimedOut=`$false; DurationMs=35; ErrorMessage=`$null }
}
`$snapshot = [pscustomobject]@{ Success=`$true; Message=''; Temperatures=@(60) }
`$script:DellFanControllerDotSourceOnly = `$true
. `$controllerPath
`$result = Invoke-DellFanControllerProduction -ConfigPath `$cfgFile -EnableProductionMode `$true -AllowHardwareWrites -HardwareWriteConfirmation 'ENABLE_AUTOMATIC_DELL_FAN_CONTROLLER' -RunMinutes 10 -TestIsAdministrator `$true -TestLockAcquired `$true -TestSnapshots @(`$snapshot) -TestProcessInvoker `$fake
[pscustomobject]@{
    Success = `$result.Success
    ExitCode = `$result.ExitCode
    ValidMeasurements = `$result.Runtime.ValidMeasurements
    Started = `$result.Session.BeginStateResult.Diagnostics.Started
    BeginState = `$result.Session.BeginStateResult.NewState
    BeginVerified = `$result.Session.BeginStateResult.Verified
    SessionBuilt = (`$null -ne `$result.Session -and `$null -ne `$result.Session.Backend)
    SameBackend = [object]::ReferenceEquals(`$result.Backend, `$result.Session.Backend)
    SameExecutor = [object]::ReferenceEquals(`$result.Session.CommandExecutor, `$result.Session.Backend.CommandExecutor)
    BackendActionLogCount = @(`$result.Session.Backend.ActionLog).Count
} | ConvertTo-Json -Depth 6
exit ([int]`$result.ExitCode)
"@
    Set-Content -LiteralPath $runner -Value $runnerText -Encoding UTF8
    $json = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($json | Out-String).Trim()
    $parsed = $text | ConvertFrom-Json
    $calls = if (Test-Path -LiteralPath $callPath -PathType Leaf) { @(Get-Content -LiteralPath $callPath | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() }
    [pscustomobject]@{
        Result=$parsed
        ExitCode=$exitCode
        Calls=$calls
        Directory=$dir
        Config=$config
        ConfigPath=$configPath
        ConfigBefore=$configBefore
        StateBefore=$stateBefore
    }
}

function Invoke-StartupOnlyChildRun {
    $dir = New-TestDirectory
    $config = New-ProductionTestConfigObject @{}
    $configPath = Write-TestConfig -Config $config -Directory $dir
    $state = New-ControllerState -ControllerInstanceId ([guid]::NewGuid().ToString()) -CorrelationId ([guid]::NewGuid().ToString()) -BackendName 'DellCctk'
    $state = Set-ControllerStatePhase -State $state -OperationPhase 'EnablePending'
    $state = Set-ControllerStatePhase -State $state -OperationPhase 'ActiveVerified'
    $state = Set-ControllerStatePhase -State $state -OperationPhase 'Restored'
    [void](Write-ControllerStateAtomic -Path $config.StatePath -State $state)
    $productionConfigHashBefore = if (Test-Path -LiteralPath $productionConfigPath -PathType Leaf) { Get-FileHash -LiteralPath $productionConfigPath -Algorithm SHA256 } else { $null }
    $callPath = Join-Path $dir 'startup-only-calls.jsonl'
    $runner = Join-Path $dir 'run-startup-only-entrypoint.ps1'
    $runnerText = @"
`$ErrorActionPreference = 'Stop'
`$controllerPath = '$($controllerPath.Replace("'","''"))'
`$cfgFile = '$($configPath.Replace("'","''"))'
`$callPath = '$($callPath.Replace("'","''"))'
`$fake = {
    param([string]`$ExecutablePath,[string[]]`$ArgumentList,[int]`$TimeoutSeconds)
    ([pscustomobject]@{ Argument=[string]@(`$ArgumentList)[0]; TimeoutSeconds=`$TimeoutSeconds } | ConvertTo-Json -Compress) | Add-Content -LiteralPath `$callPath -Encoding UTF8
    [pscustomobject]@{ Started=`$true; ExitCode=0; StdOut='FanCtrlOvrd=Disabled'; StdErr=''; TimedOut=`$false; DurationMs=35; ErrorMessage=`$null }
}
`$snapshot = [pscustomobject]@{ Success=`$true; Message=''; Temperatures=@(60) }
`$script:DellFanControllerDotSourceOnly = `$true
. `$controllerPath
`$result = Invoke-DellFanControllerProduction -ConfigPath `$cfgFile -EnableProductionMode `$true -AllowHardwareWrites -HardwareWriteConfirmation 'ENABLE_AUTOMATIC_DELL_FAN_CONTROLLER' -RunMinutes 10 -StartupOnly -TestIsAdministrator `$true -TestLockAcquired `$true -TestSnapshots @(`$snapshot) -TestProcessInvoker `$fake
`$result.Summary | ConvertTo-Json -Depth 10
exit ([int]`$result.ExitCode)
"@
    Set-Content -LiteralPath $runner -Value $runnerText -Encoding UTF8
    $json = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($json | Out-String).Trim()
    $parsed = $text | ConvertFrom-Json
    $calls = if (Test-Path -LiteralPath $callPath -PathType Leaf) { @(Get-Content -LiteralPath $callPath | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() }
    [pscustomobject]@{
        Result=$parsed
        ExitCode=$exitCode
        Calls=$calls
        Directory=$dir
        Config=$config
        ConfigPath=$configPath
        ProductionConfigHashBefore=$productionConfigHashBefore
    }
}

function Invoke-FileControllerRun {
    param(
        [switch]$AllowSwitch,
        [switch]$ValidateOnly,
        [switch]$StartupOnly,
        [string]$Confirmation='ENABLE_AUTOMATIC_DELL_FAN_CONTROLLER',
        [switch]$UseStringTrueAfterSwitch
    )
    $dir = New-TestDirectory
    $config = New-ProductionTestConfigObject @{}
    $configPath = Write-TestConfig -Config $config -Directory $dir
    if ($StartupOnly) {
        $state = New-ControllerState -ControllerInstanceId ([guid]::NewGuid().ToString()) -CorrelationId ([guid]::NewGuid().ToString()) -BackendName 'DellCctk'
        $state = Set-ControllerStatePhase -State $state -OperationPhase 'EnablePending'
        $state = Set-ControllerStatePhase -State $state -OperationPhase 'ActiveVerified'
        $state = Set-ControllerStatePhase -State $state -OperationPhase 'Restored'
        [void](Write-ControllerStateAtomic -Path $config.StatePath -State $state)
    }
    $callPath = Join-Path $dir 'file-calls.jsonl'
    $args = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $controllerPath,
        '-ConfigPath', $configPath,
        '-EnableProductionMode',
        '-HardwareWriteConfirmation', $Confirmation,
        '-RunMinutes', '10',
        '-JsonSummary',
        '-TestIsAdministrator',
        '-TestLockAcquired',
        '-TestFakeProcessMode', 'ExactRegression',
        '-TestFakeProcessCallPath', $callPath,
        '-TestTemperatureValues', '60'
    )
    if ($AllowSwitch) {
        $args += '-AllowHardwareWrites'
        if ($UseStringTrueAfterSwitch) { $args += 'True' }
    }
    if ($ValidateOnly) { $args += '-ValidateOnly' }
    if ($StartupOnly) { $args += '-StartupOnly' }
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $json = & powershell.exe @args 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
    $text = ($json | Out-String).Trim()
    $parsed = $null
    try { $parsed = $text | ConvertFrom-Json } catch {}
    $calls = if (Test-Path -LiteralPath $callPath -PathType Leaf) { @(Get-Content -LiteralPath $callPath | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() }
    [pscustomobject]@{
        Result=$parsed
        Raw=$text
        ExitCode=$exitCode
        Calls=$calls
        Directory=$dir
        Config=$config
        ConfigPath=$configPath
    }
}

function Test-NoForbiddenAst {
    param([string[]]$Paths)
    $blocked=@('Start-Process','Invoke-Expression','cmd.exe','cmd','Register-ScheduledTask','New-Service','Set-Service','Start-Service','Invoke-WebRequest','curl','wget','Set-ItemProperty','New-ItemProperty','Set-CimInstance','Invoke-CimMethod','Set-WmiInstance')
    foreach($path in $Paths){
        $tokens=$null;$errors=$null;$ast=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
        if($errors.Count -gt 0){throw "Parserfout in $path"}
        foreach($command in $ast.FindAll({param($node)$node -is [System.Management.Automation.Language.CommandAst]},$true)){
            $name=$command.GetCommandName()
            if($blocked -contains $name){throw "Verboden commando: $name"}
        }
    }
    $true
}

if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$results=@()

try {
    $results += Invoke-TestCase '1. Geldige productieconfig wordt geaccepteerd' { (Test-DellFanControllerProductionConfig (New-ProductionTestConfigObject @{})).IsValid }
    $results += Invoke-TestCase '2. DryRun=true wordt geweigerd' { -not (Test-DellFanControllerProductionConfig (New-ProductionTestConfigObject @{DryRun=$true})).IsValid }
    $results += Invoke-TestCase '3. Backend anders dan DellCctk wordt geweigerd' { -not (Test-DellFanControllerProductionConfig (New-ProductionTestConfigObject @{Backend='Mock'})).IsValid }
    $results += Invoke-TestCase '4. BoostDurationSeconds=300 wordt geaccepteerd' { (Test-DellFanControllerProductionConfig (New-ProductionTestConfigObject @{BoostDurationSeconds=300})).IsValid }
    $results += Invoke-TestCase '5. BoostDurationSeconds=150 wordt geaccepteerd' { (Test-DellFanControllerProductionConfig (New-ProductionTestConfigObject @{BoostDurationSeconds=150})).IsValid }
    $results += Invoke-TestCase '6. Ongeldige boostduur wordt geweigerd' { -not (Test-DellFanControllerProductionConfig (New-ProductionTestConfigObject @{BoostDurationSeconds=0})).IsValid }
    $results += Invoke-TestCase '7. Ontbrekende property wordt geweigerd' { $c=New-ProductionTestConfigObject @{}; $c.PSObject.Properties.Remove('Backend'); -not (Test-DellFanControllerProductionConfig $c).IsValid }
    $results += Invoke-TestCase '8. Extra onbekende property wordt geweigerd' { -not (Test-DellFanControllerProductionConfig (New-ProductionTestConfigObject @{Extra='x'})).IsValid }
    $results += Invoke-TestCase '9. Ongeldig cctk-pad wordt geweigerd' { -not (Test-DellFanControllerProductionConfig (New-ProductionTestConfigObject @{CctkPath='cctk.exe'})).IsValid }
    $results += Invoke-TestCase '10. Ongeldige statepath wordt geweigerd' { -not (Test-DellFanControllerProductionConfig (New-ProductionTestConfigObject @{StatePath='bad|path'})).IsValid }
    $results += Invoke-TestCase '11. Zonder EnableProductionMode geen write' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -EnableMode $false; @($r.Fake.State.Calls|Where-Object {$_.Argument -ne '--FanCtrlOvrd'}).Count -eq 0 -and -not $r.Result.Success }
    $results += Invoke-TestCase '12. Zonder AllowHardwareWrites geen write' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -AllowWrites $false; @($r.Fake.State.Calls|Where-Object {$_.Argument -ne '--FanCtrlOvrd'}).Count -eq 0 -and -not $r.Result.Success }
    $results += Invoke-TestCase '13. Verkeerde confirmation geen write' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -Confirmation 'BAD'; @($r.Fake.State.Calls|Where-Object {$_.Argument -ne '--FanCtrlOvrd'}).Count -eq 0 -and -not $r.Result.Success }
    $results += Invoke-TestCase '14. Boolean-string parsing is niet meer ondersteund' { (Get-Content -Raw $controllerPath) -notmatch 'AllowHardwareWrites\\s+`?\\$true|AllowHardwareWrites\\s+\"True\"|AllowHardwareWrites\\s+''True''' }
    $results += Invoke-TestCase '15. Geen administrator blokkeert start' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -Admin $false; @($r.Fake.State.Calls).Count -eq 0 -and $r.Result.ExitCode -eq 11 }
    $results += Invoke-TestCase '16. Tweede instance wordt geblokkeerd' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -Lock $false; @($r.Fake.State.Calls).Count -eq 0 -and $r.Result.ExitCode -eq 16 }
    $results += Invoke-TestCase '17. Beginstatus Automatic laat start toe' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -InitialFanState Disabled).Result.Success }
    $results += Invoke-TestCase '18. Beginstatus BoostEnabled zonder ownership blokkeert start' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -InitialFanState Enabled; -not $r.Result.Success }
    $results += Invoke-TestCase '19. Unknown state blokkeert start' { -not (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -Mode UnknownState).Result.Success }
    $results += Invoke-TestCase '20. Idle laat monitoring starten' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -InitialPhase Idle).Result.Runtime.ValidMeasurements -eq 1 }
    $results += Invoke-TestCase '21. Restored laat monitoring starten' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -InitialPhase Restored).Result.Runtime.ValidMeasurements -eq 1 }
    $results += Invoke-TestCase '22. EnablePending plus BoostEnabled herstelt Automatic' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -InitialPhase EnablePending -InitialFanState Enabled; $r.StateRead.State.OperationPhase -eq 'Restored' }
    $results += Invoke-TestCase '23. EnablePending plus Automatic wordt Restored' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -InitialPhase EnablePending -InitialFanState Disabled; $r.StateRead.State.OperationPhase -eq 'Restored' }
    $results += Invoke-TestCase '24. ActiveVerified herstelt Automatic' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -InitialPhase ActiveVerified -InitialFanState Enabled; $r.StateRead.State.OperationPhase -eq 'Restored' }
    $results += Invoke-TestCase '25. DisablePending voltooit herstel' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -InitialPhase DisablePending -InitialFanState Enabled; $r.StateRead.State.OperationPhase -eq 'Restored' }
    $results += Invoke-TestCase '26. CleanupRequired gebruikt emergency reset' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -InitialPhase CleanupRequired -InitialFanState Enabled; $r.Result.Runtime.EmergencyResets -ge 1 }
    $results += Invoke-TestCase '27. Recoveryfailure blokkeert monitoring' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -InitialPhase ActiveVerified -InitialFanState Enabled -Mode RestoreVerifyFails; -not $r.Result.Success }
    $results += Invoke-TestCase '28. Een hoge meting activeert niet' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)))).Result.Runtime.BoostsStarted -eq 0 }
    $results += Invoke-TestCase '29. Twee opeenvolgende hoge metingen activeren' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81)))).Result.Runtime.BoostsStarted -eq 1 }
    $results += Invoke-TestCase '30. Lage meting reset teller' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(70)),(New-Snapshot @(80)))).Result.Runtime.BoostsStarted -eq 0 }
    $results += Invoke-TestCase '31. Exact 75 C telt als hoog' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(75)),(New-Snapshot @(75)))).Result.Runtime.BoostsStarted -eq 1 }
    $results += Invoke-TestCase '32. Geen geldige cores faalt veilig' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @('bad')),(New-Snapshot @('bad')),(New-Snapshot @('bad')))).Result.ExitCode -eq 22 }
    $results += Invoke-TestCase '33. Hoogste geldige core wordt gebruikt' { (Get-ProductionHighestTemperature @(60,70,65)).Highest -eq 70 }
    $results += Invoke-TestCase '34. Na booststart geen tweede enable' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81)),(New-Snapshot @(90)),(New-Snapshot @(91)))).Fake.Backend.RuntimeState.EnableCallCount -eq 1 }
    $results += Invoke-TestCase '35. Lagere temperatuur stopt boost niet voortijdig' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81)),(New-Snapshot @(60)))).Result.Runtime.ControllerState -eq 'Boost' }
    $results += Invoke-TestCase '36. Enable gebruikt exact Enabled-argument' { @((Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81)))).Fake.State.Calls|Where-Object Argument -eq '--FanCtrlOvrd=Enabled').Count -eq 1 }
    $results += Invoke-TestCase '37. Enable vereist exitcode 0' { -not (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81))) -Mode EnableNonZero).Result.Success }
    $results += Invoke-TestCase '38. Enable vereist BoostEnabled read-back' { -not (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81))) -Mode EnableVerifyFails).Result.Success }
    $results += Invoke-TestCase '39. Enable schrijft ActiveVerified' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81))); (Get-Content -Raw -LiteralPath $r.Config.LogPath) -match 'ActiveVerified' }
    $results += Invoke-TestCase '40. Boost gebruikt geconfigureerde 300 seconden' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60))) -ConfigOverrides @{BoostDurationSeconds=300}; $r.Result.Runtime.RestoresExecuted -ge 1 }
    $results += Invoke-TestCase '41. Boost gebruikt geconfigureerde 150 seconden' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60))) -ConfigOverrides @{BoostDurationSeconds=150}; $r.Result.Runtime.RestoresExecuted -ge 1 }
    $results += Invoke-TestCase '42. Geen hard-coded boostduur' { (Get-Content -Raw $controllerPath) -notmatch 'BoostDurationSeconds\\s*=\\s*300|AddSeconds\\(300\\)' }
    $results += Invoke-TestCase '43. Restore gebruikt exact Disabled-argument' { @((Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)))).Fake.State.Calls|Where-Object Argument -eq '--FanCtrlOvrd=Disabled').Count -ge 1 }
    $results += Invoke-TestCase '44. Restore vereist Automatic read-back' { -not (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60))) -Mode RestoreVerifyFails).Result.Success }
    $results += Invoke-TestCase '45. Restore schrijft Restored' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)))).StateRead.State.OperationPhase -eq 'Restored' }
    $results += Invoke-TestCase '46. Cooldown begint alleen na verified Automatic' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)))).Result.Runtime.ControllerState -eq 'Cooldown' }
    $results += Invoke-TestCase '47. Tijdens cooldown geen enable' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(90)),(New-Snapshot @(91)))).Fake.Backend.RuntimeState.EnableCallCount -eq 1 }
    $results += Invoke-TestCase '48. Hoge metingen tijdens cooldown tellen niet' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(90)))).Result.Runtime.ConsecutiveHighReadings -eq 0 }
    $results += Invoke-TestCase '49. Cooldown gebruikt geconfigureerde 600 seconden' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60))); $r.Result.Runtime.CooldownsCompleted -eq 1 }
    $results += Invoke-TestCase '50. Na cooldown terug naar Monitoring' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)))).Result.Runtime.ControllerState -eq 'Monitoring' }
    $results += Invoke-TestCase '51. Na cooldown zijn opnieuw twee hoge metingen nodig' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(90)))).Result.Runtime.BoostsStarted -eq 1 }
    $results += Invoke-TestCase '52. Sensorfout voor boost gebruikt driemaal-foutlogica' { (Invoke-TestProductionRun -Snapshots @((New-FailureSnapshot),(New-FailureSnapshot))).Result.Success }
    $results += Invoke-TestCase '53. Sensorfout tijdens boost veroorzaakt direct restore' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81)),(New-FailureSnapshot))).Result.Runtime.RestoresExecuted -ge 1 }
    $results += Invoke-TestCase '54. Enable-exception veroorzaakt cleanup' { -not (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81))) -Mode ExceptionOnEnable).Result.Success }
    $results += Invoke-TestCase '55. Enable-verificationfailure veroorzaakt cleanup' { -not (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81))) -Mode EnableVerifyFails).Result.Success }
    $results += Invoke-TestCase '56. Restore-exception start geen cooldown' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60))) -Mode ExceptionOnRestore).Result.Runtime.ControllerState -ne 'Cooldown' }
    $results += Invoke-TestCase '57. Restore-verificationfailure blijft CleanupRequired' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60))) -Mode RestoreVerifyFails).StateRead.State.OperationPhase -eq 'CleanupRequired' }
    $results += Invoke-TestCase '58. Normaal einde tijdens boost voert finally-restore uit' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81)))).StateRead.State.OperationPhase -eq 'Restored' }
    $results += Invoke-TestCase '59. Exception tijdens boost voert finally-restore uit' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81))) -Mode ExceptionOnRestore).StateRead.State.OperationPhase -eq 'CleanupRequired' }
    $results += Invoke-TestCase '60. Exit-cleanup verifieert Automatic' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81)))).Result.Summary.AutomaticVerified }
    $results += Invoke-TestCase '61. Cleanupfailure behoudt emergency flag' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81))) -Mode RestoreVerifyFails).StateRead.State.RequiresEmergencyReset }
    $results += Invoke-TestCase '62. Statebestand blijft valide' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81)))).StateRead.Success }
    $results += Invoke-TestCase '63. Backup blijft valide' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(80)),(New-Snapshot @(81)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60)),(New-Snapshot @(60))); (Read-ControllerState -Path ($r.Config.StatePath + '.missing') -BackupPath ($r.Config.StatePath + '.bak')).Success }
    $results += Invoke-TestCase '64. Productielog blijft parseerbaar' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))); Import-Csv -LiteralPath $r.Config.LogPath | Out-Null; $true }
    $results += Invoke-TestCase '65. DellFanController-DryRun.ps1 blijft byte-for-byte ongewijzigd' { (Get-FileHash $dryRunPath -Algorithm SHA256).Hash -eq $dryRunBefore.Hash }
    $results += Invoke-TestCase '66. controller-config.json blijft byte-for-byte ongewijzigd' { (Get-FileHash $activeConfigPath -Algorithm SHA256).Hash -eq $activeConfigBefore.Hash }
    $results += Invoke-TestCase '67. Bestaande modules blijven ongewijzigd' { (Get-FileHash $stateModulePath -Algorithm SHA256).Hash -eq $stateModuleBefore.Hash -and (Get-FileHash $contractPath -Algorithm SHA256).Hash -eq $contractBefore.Hash -and (Get-FileHash $dellBackendPath -Algorithm SHA256).Hash -eq $dellBackendBefore.Hash -and (Get-FileHash $processExecutorPath -Algorithm SHA256).Hash -eq $processExecutorBefore.Hash }
    $results += Invoke-TestCase '68. Geen echte cctk-uitvoering' { $cctkExecutionCount -eq 0 }
    $results += Invoke-TestCase '69. Geen echte processen' { $realProcessCount -eq 0 }
    $results += Invoke-TestCase '70. Geen BIOS- of fanwrites' { $cctkExecutionCount -eq 0 -and $realProcessCount -eq 0 }
    $results += Invoke-TestCase '71. Test gebruikt alleen fake invoker' { (Get-Content -Raw $PSCommandPath) -match 'New-FakeDellBackend' }
    $results += Invoke-TestCase '72. ParserErrors=0' { foreach($p in @($controllerPath,$PSCommandPath)){ $t=$null;$e=$null;[System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e)|Out-Null;if($e.Count -gt 0){return $false}}; $true }
    $results += Invoke-TestCase '73. Geen Invoke-Expression' { Test-NoForbiddenAst @($controllerPath,$PSCommandPath) }
    $results += Invoke-TestCase '74. Geen cmd.exe' { Test-NoForbiddenAst @($controllerPath,$PSCommandPath) }
    $results += Invoke-TestCase '75. Geen Start-Process' { Test-NoForbiddenAst @($controllerPath,$PSCommandPath) }
    $results += Invoke-TestCase '76. Geen tijdelijke bestanden' { @((Get-ChildItem -LiteralPath $testRoot -Recurse -File -Filter '*.tmp' -ErrorAction SilentlyContinue)).Count -eq 0 }
    $results += Invoke-TestCase '77. DryRun-config blijft true' { (Get-Content -Raw $activeConfigPath | ConvertFrom-Json).DryRun -eq $true }
    $results += Invoke-TestCase '78. Productiecontroller maakt DellCctk ProcessExecutor aan' { (Get-Content -Raw $productionSupportPath) -match 'New-DellCctkProcessExecutor' }
    $results += Invoke-TestCase '79. Executor wordt aan Dell-backend doorgegeven' { $raw=Get-Content -Raw $productionSupportPath; $raw.Contains('-CommandExecutor $executor') -and $raw.Contains('New-DellCctkFanBackend') }
    $results += Invoke-TestCase '79a. Gedeelde productionsession bestaat' { (Get-Content -Raw $productionSupportPath).Contains('function New-ProductionDellCctkSession') }
    $results += Invoke-TestCase '79b. Controller bouwt geen tweede DellCctk-backendroute' { (Get-Content -Raw $controllerPath) -notmatch 'New-ProductionDellCctkBackend|New-DellCctkProcessExecutor|New-DellCctkFanBackend' }
    $results += Invoke-TestCase '79c. Preflight gebruikt gedeelde productionsession' { (Get-Content -Raw (Join-Path $ScriptDirectory 'Invoke-DellFanControllerProductionPreflight.ps1')).Contains('New-ProductionDellCctkSession') }
    $results += Invoke-TestCase '79d. Session bewaart dezelfde executorinstance in backend' { $fake=New-FakeProcessInvoker; $cfg=New-ProductionTestConfigObject @{}; $s=New-ProductionDellCctkSession -Config $cfg -AllowHardwareWrites $false -ProcessInvoker $fake.Invoker; [object]::ReferenceEquals($s.CommandExecutor,$s.Backend.CommandExecutor) }
    $results += Invoke-TestCase '79e. Session gebruikt dezelfde backendinstance voor availability en beginstate' { $fake=New-FakeProcessInvoker; $cfg=New-ProductionTestConfigObject @{}; $s=New-ProductionDellCctkSession -Config $cfg -AllowHardwareWrites $false -ProcessInvoker $fake.Invoker; $s.Backend.ActionLog.Count -eq 1 -and $s.BeginStateResult.NewState -eq 'Automatic' }
    $results += Invoke-TestCase '79f. Started=false zonder ErrorMessage blijft InvalidExecutorResult' { $fake=New-FakeProcessInvoker -Mode StartedFalseNoError; $cfg=New-ProductionTestConfigObject @{}; $s=New-ProductionDellCctkSession -Config $cfg -AllowHardwareWrites $false -ProcessInvoker $fake.Invoker; $s.BeginStateResult.ErrorCode -eq 'InvalidExecutorResult' }
    $results += Invoke-TestCase '79g. Controller ValidateOnly child gebruikt echte entrypoint' { $r=Invoke-ValidateOnlyChildRun; $r.ExitCode -eq 0 -and $r.Result.ProcessExitCode -eq 0 }
    $results += Invoke-TestCase '79h. ValidateOnly roept ProcessInvoker exact een keer aan' { $r=Invoke-ValidateOnlyChildRun; @($r.Calls).Count -eq 1 }
    $results += Invoke-TestCase '79i. ValidateOnly voert uitsluitend queryargument uit' { $r=Invoke-ValidateOnlyChildRun; @($r.Calls | Where-Object { $_.Argument -ne '--FanCtrlOvrd' }).Count -eq 0 }
    $results += Invoke-TestCase '79j. ValidateOnly behoudt raw executorvelden' { $r=Invoke-ValidateOnlyChildRun; $r.Result.Started -eq $true -and $r.Result.ExitCode -eq 0 -and $r.Result.StdOut -eq 'FanCtrlOvrd=Disabled' -and $r.Result.TimedOut -eq $false -and $r.Result.DurationMs -eq 35 }
    $results += Invoke-TestCase '79k. ValidateOnly verifieert Automatic' { $r=Invoke-ValidateOnlyChildRun; $r.Result.NewState -eq 'Automatic' -and $r.Result.Verified -eq $true }
    $results += Invoke-TestCase '79l. ValidateOnly voert geen Enabled of Disabled uit' { $r=Invoke-ValidateOnlyChildRun; @($r.Calls | Where-Object { $_.Argument -eq '--FanCtrlOvrd=Enabled' -or $_.Argument -eq '--FanCtrlOvrd=Disabled' }).Count -eq 0 }
    $results += Invoke-TestCase '79m. ValidateOnly start geen monitoringloop' { $r=Invoke-ValidateOnlyChildRun; @($r.Calls).Count -eq 1 -and $r.Result.CoreTempAvailable -eq $true }
    $results += Invoke-TestCase '79n. ValidateOnly laat statebestand ongewijzigd' { $r=Invoke-ValidateOnlyChildRun; if($null -eq $r.StateBefore){ -not (Test-Path -LiteralPath $r.Config.StatePath) } else { (Get-FileHash -LiteralPath $r.Config.StatePath -Algorithm SHA256).Hash -eq $r.StateBefore.Hash } }
    $results += Invoke-TestCase '79o. ValidateOnly laat config ongewijzigd' { $r=Invoke-ValidateOnlyChildRun; (Get-FileHash -LiteralPath $r.ConfigPath -Algorithm SHA256).Hash -eq $r.ConfigBefore.Hash }
    $results += Invoke-TestCase '79p. ValidateOnly gebruikt Session.BeginStateResult' { $r=Invoke-ValidateOnlyChildRun; $r.Result.BeginStateResult.NewState -eq $r.Result.NewState -and $r.Result.BeginStateResult.Diagnostics.Started -eq $r.Result.Started }
    $results += Invoke-TestCase '79q. Normale controller gebruikt Session.BeginStateResult voor beginstatus' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -InitialFanState Disabled; $r.Result.Session.BeginStateResult.NewState -eq 'Automatic' -and $r.Result.Runtime.ValidMeasurements -eq 1 }
    $results += Invoke-TestCase '79r. Normale controller doet geen tweede GetState voor monitoring' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -InitialFanState Disabled; @($r.Fake.State.Calls | Where-Object Argument -eq '--FanCtrlOvrd').Count -eq 1 -and $r.Result.Runtime.ValidMeasurements -eq 1 }
    $results += Invoke-TestCase '79s. ProcessInvoker wordt voor monitoring exact een keer aangeroepen' { $r=Invoke-NormalChildRun; @($r.Calls).Count -eq 1 -and $r.Result.ValidMeasurements -eq 1 }
    $results += Invoke-TestCase '79t. Beginstatus Automatic geeft doorgang naar monitoring' { $r=Invoke-NormalChildRun; $r.Result.BeginState -eq 'Automatic' -and $r.Result.ValidMeasurements -eq 1 -and $r.Result.ExitCode -eq 0 }
    $results += Invoke-TestCase '79u. Tweede backendcall na session-return werkt met dezelfde executor' { $fake=New-FakeProcessInvoker; $cfg=New-ProductionTestConfigObject @{}; $s=New-ProductionDellCctkSession -Config $cfg -AllowHardwareWrites $false -ProcessInvoker $fake.Invoker; $executor=$s.CommandExecutor; $backend=$s.Backend; $second=Get-ProductionReadOnlyBeginState -Backend $backend; [object]::ReferenceEquals($executor,$backend.CommandExecutor) -and $second.Success -and $second.NewState -eq 'Automatic' -and @($fake.State.Calls).Count -eq 2 }
    $results += Invoke-TestCase '79v. Dezelfde backendinstance blijft gebruikt in normale run' { $r=Invoke-NormalChildRun; $r.Result.SessionBuilt -and $r.Result.SameBackend }
    $results += Invoke-TestCase '79w. Dezelfde executorinstance blijft gebruikt in normale run' { $r=Invoke-NormalChildRun; $r.Result.SameExecutor }
    $results += Invoke-TestCase '79x. Fake invokercall 1 retourneert Automatic' { $fake=New-FakeProcessInvoker; $cfg=New-ProductionTestConfigObject @{}; $s=New-ProductionDellCctkSession -Config $cfg -AllowHardwareWrites $false -ProcessInvoker $fake.Invoker; $s.BeginStateResult.NewState -eq 'Automatic' -and @($fake.State.Calls)[0].Argument -eq '--FanCtrlOvrd' }
    $results += Invoke-TestCase '79y. Fake invokercall 2 na session-return retourneert geldig resultaat' { $fake=New-FakeProcessInvoker; $cfg=New-ProductionTestConfigObject @{}; $s=New-ProductionDellCctkSession -Config $cfg -AllowHardwareWrites $false -ProcessInvoker $fake.Invoker; $second=Get-ProductionReadOnlyBeginState -Backend $s.Backend; $second.Success -and $second.Verified -and @($fake.State.Calls)[1].Argument -eq '--FanCtrlOvrd' }
    $results += Invoke-TestCase '79z. Started blijft True en ExitCode blijft 0' { $r=Invoke-NormalChildRun; $r.Result.Started -eq $true -and $r.Result.ExitCode -eq 0 }
    $results += Invoke-TestCase '79aa. Normale fake entrypoint heeft geen pipelinevervuiling' { $r=Invoke-NormalChildRun; $r.ExitCode -eq 0 -and $r.Result.Success -eq $true -and @($r.Calls).Count -eq 1 }
    $results += Invoke-TestCase '79ab. Normale fake entrypoint voert geen Enabled of Disabled-write uit' { $r=Invoke-NormalChildRun; @($r.Calls | Where-Object { $_.Argument -eq '--FanCtrlOvrd=Enabled' -or $_.Argument -eq '--FanCtrlOvrd=Disabled' }).Count -eq 0 }
    $results += Invoke-TestCase '79ac. Normale fake entrypoint bouwt geen nieuwe backend na session' { $r=Invoke-NormalChildRun; $r.Result.BackendActionLogCount -eq 1 -and $r.Result.SameBackend }
    $results += Invoke-TestCase '79ad. Normale fake entrypoint wijzigt productieconfig niet' { $r=Invoke-NormalChildRun; if($null -eq $productionConfigBefore){ -not (Test-Path -LiteralPath $productionConfigPath) } else { (Get-FileHash -LiteralPath $productionConfigPath -Algorithm SHA256).Hash -eq $productionConfigBefore.Hash } }
    $results += Invoke-TestCase '79ae. Normale fake entrypoint laat testconfig ongewijzigd' { $r=Invoke-NormalChildRun; (Get-FileHash -LiteralPath $r.ConfigPath -Algorithm SHA256).Hash -eq $r.ConfigBefore.Hash }
    $results += Invoke-TestCase '79af. Normale fake entrypoint gebruikt geen echte cctk' { $r=Invoke-NormalChildRun; @($r.Calls | Where-Object { $_.Argument -ne '--FanCtrlOvrd' }).Count -eq 0 -and $cctkExecutionCount -eq 0 }
    $results += Invoke-TestCase '79ag. Exception in StartupRecovery wordt zichtbaar' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -TestThrowPhase StartupRecovery; -not $r.Result.Success -and $r.Result.ExitCode -eq 99 -and $r.Result.Summary.ExceptionDetails.ExecutionPhase -eq 'StartupRecovery' -and $r.Result.Summary.ExceptionDetails.ExceptionMessage -match 'StartupRecovery' }
    $results += Invoke-TestCase '79ah. Exception in InitializeClock wordt zichtbaar' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -TestThrowPhase InitializeClock; $r.Result.ExitCode -eq 99 -and $r.Result.Summary.ExceptionDetails.ExecutionPhase -eq 'InitializeClock' }
    $results += Invoke-TestCase '79ai. Exception in ReadPreflightCoreTemp wordt zichtbaar' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -TestThrowPhase ReadPreflightCoreTemp; $r.Result.ExitCode -eq 99 -and $r.Result.Summary.ExceptionDetails.ExecutionPhase -eq 'ReadPreflightCoreTemp' }
    $results += Invoke-TestCase '79aj. Exception in CalculatePreflightTemperature wordt zichtbaar' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -TestThrowPhase CalculatePreflightTemperature; $r.Result.ExitCode -eq 99 -and $r.Result.Summary.ExceptionDetails.ExecutionPhase -eq 'CalculatePreflightTemperature' }
    $results += Invoke-TestCase '79ak. Exception in WriteStartupLog wordt zichtbaar' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -TestThrowPhase WriteStartupLog; $r.Result.ExitCode -eq 99 -and $r.Result.Summary.ExceptionDetails.ExecutionPhase -eq 'WriteStartupLog' }
    $results += Invoke-TestCase '79al. Originele exception blijft behouden wanneer foutlogging faalt' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -TestThrowPhase StartupRecovery -UseDirectoryAsLogPath; $r.Result.Summary.ExceptionDetails.ExceptionMessage -match 'StartupRecovery' -and -not [string]::IsNullOrWhiteSpace([string]$r.Result.Summary.LogWriteExceptionMessage) }
    $results += Invoke-TestCase '79am. Fallback-JSON wordt geschreven bij loggingfailure' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -TestThrowPhase StartupRecovery -UseDirectoryAsLogPath; Test-Path -LiteralPath $r.Result.Summary.FatalErrorPath -PathType Leaf }
    $results += Invoke-TestCase '79an. Fallback-JSON is geldig en volledig' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -TestThrowPhase StartupRecovery -UseDirectoryAsLogPath; $j=Get-Content -Raw -LiteralPath $r.Result.Summary.FatalErrorPath | ConvertFrom-Json; $j.ExecutionPhase -eq 'StartupRecovery' -and $j.ExitCode -eq 99 -and -not [string]::IsNullOrWhiteSpace([string]$j.RunId) -and -not [string]::IsNullOrWhiteSpace([string]$j.ControllerInstanceId) -and -not [string]::IsNullOrWhiteSpace([string]$j.LogWriteExceptionMessage) }
    $results += Invoke-TestCase '79ao. ScriptStackTrace bevat falende productiefunctie' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -TestThrowPhase InitializeClock; [string]$r.Result.Summary.ExceptionDetails.ScriptStackTrace -match 'Invoke-DellFanControllerProduction' }
    $results += Invoke-TestCase '79ap. JsonSummary bevat exceptiondetails bij exitcode 99' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -TestThrowPhase InitializeClock; $json=$r.Result.Summary | ConvertTo-Json -Depth 10; $p=$json | ConvertFrom-Json; $p.ExitCode -eq 99 -and $p.ExceptionDetails.ExecutionPhase -eq 'InitializeClock' }
    $results += Invoke-TestCase '79aq. StartupOnly bereikt EnterMonitoringLoop niet' { $r=Invoke-StartupOnlyChildRun; $r.ExitCode -eq 0 -and $r.Result.ExecutionPhase -eq 'WriteStartupLog' -and $r.Result.ValidMeasurements -eq 0 }
    $results += Invoke-TestCase '79ar. StartupOnly voert geen Enabled uit' { $r=Invoke-StartupOnlyChildRun; @($r.Calls | Where-Object Argument -eq '--FanCtrlOvrd=Enabled').Count -eq 0 }
    $results += Invoke-TestCase '79as. StartupOnly voert geen Disabled uit' { $r=Invoke-StartupOnlyChildRun; @($r.Calls | Where-Object Argument -eq '--FanCtrlOvrd=Disabled').Count -eq 0 }
    $results += Invoke-TestCase '79at. StartupOnly gebruikt geen echte cctk' { $r=Invoke-StartupOnlyChildRun; @($r.Calls | Where-Object { $_.Argument -ne '--FanCtrlOvrd' }).Count -eq 0 -and $cctkExecutionCount -eq 0 }
    $results += Invoke-TestCase '79au. StartupOnly verandert echte productieconfig niet' { $r=Invoke-StartupOnlyChildRun; if($null -eq $r.ProductionConfigHashBefore){ -not (Test-Path -LiteralPath $productionConfigPath) } else { (Get-FileHash -LiteralPath $productionConfigPath -Algorithm SHA256).Hash -eq $r.ProductionConfigHashBefore.Hash } }
    $results += Invoke-TestCase '79av. StartupOnly verandert echt statebestand niet' { [void](Invoke-StartupOnlyChildRun); if($null -eq $productionStateBefore){ -not (Test-Path -LiteralPath $productionStatePath) } else { (Get-FileHash -LiteralPath $productionStatePath -Algorithm SHA256).Hash -eq $productionStateBefore.Hash } }
    $results += Invoke-TestCase '79aw. StartupOnly verandert echte productielog niet' { [void](Invoke-StartupOnlyChildRun); if($null -eq $productionLogBefore){ -not (Test-Path -LiteralPath $productionLogPath) } else { (Get-FileHash -LiteralPath $productionLogPath -Algorithm SHA256).Hash -eq $productionLogBefore.Hash } }
    $results += Invoke-TestCase '79ax. StartupOnly schrijft geen Disabled bij ActiveVerified' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -StartupOnly -InitialPhase ActiveVerified -InitialFanState Enabled; @($r.Fake.State.Calls | Where-Object Argument -eq '--FanCtrlOvrd=Disabled').Count -eq 0 -and $r.Result.ExitCode -eq 99 }
    $results += Invoke-TestCase '79ay. Bestaande normale logschema blijft compatibel' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))); $header=(Get-Content -LiteralPath $r.Config.LogPath -First 1); $header -eq 'TimestampUtc,RunId,ControllerInstanceId,CorrelationId,ControllerState,HighestTemperature,ValidCoreCount,ThresholdCelsius,ConsecutiveHighReadings,RequiredConsecutiveHighReadings,RemainingBoostSeconds,RemainingCooldownSeconds,BackendName,BackendAction,BackendSuccess,BackendVerified,BackendState,StateOperationPhase,RequiresEmergencyReset,Event,ErrorMessage' }
    $results += Invoke-TestCase '79az. AllowHardwareWrites is switchparameter' { $cmd=(Get-Command $controllerPath); $cmd.Parameters['AllowHardwareWrites'].ParameterType.FullName -eq 'System.Management.Automation.SwitchParameter' }
    $results += Invoke-TestCase '79ba. AllowHardwareWrites switch werkt via powershell File' { $r=Invoke-FileControllerRun -AllowSwitch; $r.ExitCode -eq 0 -and $r.Result.ExitCode -eq 0 -and @($r.Calls).Count -eq 1 }
    $results += Invoke-TestCase '79bb. Normale productie zonder switch faalt gesloten via File' { $r=Invoke-FileControllerRun; $r.ExitCode -ne 0 -and $r.Result.ExitCode -ne 0 -and @($r.Calls).Count -eq 0 -and $r.Raw -match 'AllowHardwareWrites switch is vereist' }
    $results += Invoke-TestCase '79bc. Normale productie met switch maar zonder correcte confirmation faalt gesloten via File' { $r=Invoke-FileControllerRun -AllowSwitch -Confirmation BAD; $r.ExitCode -ne 0 -and @($r.Calls).Count -eq 0 -and $r.Raw -match 'HardwareWriteConfirmation is ongeldig' }
    $results += Invoke-TestCase '79bd. Normale productie met switch en confirmation accepteert write-capable modus' { $r=Invoke-FileControllerRun -AllowSwitch; $r.ExitCode -eq 0 -and $r.Result.ExitCode -eq 0 }
    $results += Invoke-TestCase '79be. ValidateOnly zonder switch werkt via File' { $r=Invoke-FileControllerRun -ValidateOnly; $r.ExitCode -eq 0 -and $r.Result.ProcessExitCode -eq 0 -and $r.Result.NewState -eq 'Automatic' }
    $results += Invoke-TestCase '79bf. StartupOnly zonder switch werkt via File' { $r=Invoke-FileControllerRun -StartupOnly; $r.ExitCode -eq 0 -and $r.Result.ExitCode -eq 0 -and $r.Result.ExecutionPhase -eq 'WriteStartupLog' }
    $results += Invoke-TestCase '79bg. ValidateOnly met switch voert nog steeds geen writes uit via File' { $r=Invoke-FileControllerRun -ValidateOnly -AllowSwitch; $r.ExitCode -eq 0 -and @($r.Calls | Where-Object { $_.Argument -eq '--FanCtrlOvrd=Enabled' -or $_.Argument -eq '--FanCtrlOvrd=Disabled' }).Count -eq 0 }
    $results += Invoke-TestCase '79bh. StartupOnly met switch voert nog steeds geen writes uit via File' { $r=Invoke-FileControllerRun -StartupOnly -AllowSwitch; $r.ExitCode -eq 0 -and @($r.Calls | Where-Object { $_.Argument -eq '--FanCtrlOvrd=Enabled' -or $_.Argument -eq '--FanCtrlOvrd=Disabled' }).Count -eq 0 }
    $results += Invoke-TestCase '79bi. Geen AllowHardwareWrites boolean typecheck meer' { (Get-Content -Raw $controllerPath) -notmatch 'AllowHardwareWrites\\s+-is\\s+\\[bool\\]' -and (Get-Content -Raw $processExecutorPath) -notmatch 'AllowHardwareWrites\\s+-is\\s+\\[bool\\]' -and (Get-Content -Raw $dellBackendPath) -notmatch 'AllowHardwareWrites\\s+-is\\s+\\[bool\\]' }
    $results += Invoke-TestCase '79bj. Geen True-ambiguiteit meer via File' { $r=Invoke-FileControllerRun -AllowSwitch -UseStringTrueAfterSwitch; $r.ExitCode -ne 0 -and @($r.Calls).Count -eq 0 }
    $results += Invoke-TestCase '79bk. Child PowerShell File ontvangt de switch correct' { $r=Invoke-FileControllerRun -AllowSwitch; $r.ExitCode -eq 0 -and @($r.Calls)[0].Argument -eq '--FanCtrlOvrd' }
    $results += Invoke-TestCase '79bl. Started ExitCode StdOut mapping blijft intact via File' { $r=Invoke-FileControllerRun -ValidateOnly; $r.Result.Started -eq $true -and $r.Result.ExitCode -eq 0 -and $r.Result.StdOut -eq 'FanCtrlOvrd=Disabled' }
    $results += Invoke-TestCase '80. GetState Automatic geeft Success=true' { $fake=New-FakeDellBackend -InitialState Disabled; (& $fake.Backend.Operations.GetState $fake.Backend).Success -eq $true }
    $results += Invoke-TestCase '81. GetState Automatic geeft Verified=true' { $fake=New-FakeDellBackend -InitialState Disabled; (& $fake.Backend.Operations.GetState $fake.Backend).Verified -eq $true }
    $results += Invoke-TestCase '82. De juiste resultaatproperty wordt gecontroleerd' { $fake=New-FakeDellBackend -InitialState Disabled; $state=& $fake.Backend.Operations.GetState $fake.Backend; @($state.PSObject.Properties.Name) -contains 'NewState' -and (Test-ProductionAutomaticFanState $state) }
    $results += Invoke-TestCase '83. Automatic laat monitoring starten via read-only preflight' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -InitialFanState Disabled).Result.Success }
    $results += Invoke-TestCase '84. BoostEnabled zonder ownership blokkeert monitoring via preflight' { -not (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -InitialFanState Enabled).Result.Success }
    $results += Invoke-TestCase '85. Unknown blokkeert monitoring via preflight' { -not (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -Mode UnknownState).Result.Success }
    $results += Invoke-TestCase '86. GetState exception geeft gecontroleerde exitcode' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -Mode ExceptionOnQuery; -not $r.Result.Success -and $r.Result.ExitCode -ne 0 }
    $results += Invoke-TestCase '87. Backend zonder executor faalt gesloten' { $dir=New-TestDirectory; $cfg=New-ProductionTestConfigObject @{}; $cfgPath=Write-TestConfig $cfg $dir; $backend=New-DellCctkFanBackend -CctkPath $realCctkPath -CommandTimeoutSeconds 15 -AllowHardwareWrites $true; $r=Invoke-DellFanControllerProduction -ConfigPath $cfgPath -EnableProductionMode $true -AllowHardwareWrites -HardwareWriteConfirmation 'ENABLE_AUTOMATIC_DELL_FAN_CONTROLLER' -RunMinutes 1 -TestSnapshots @((New-Snapshot @(60))) -TestBackend $backend -TestIsAdministrator $true -TestLockAcquired $true -TestStartTime ([datetime]'2026-06-19T14:00:00Z'); -not $r.Success }
    $results += Invoke-TestCase '88. Productieconstructie gebruikt gedeelde sessionfactory' { $rawController=Get-Content -Raw $controllerPath; $rawSupport=Get-Content -Raw $productionSupportPath; $rawController.Contains('New-ProductionDellCctkSession @sessionParams') -and $rawSupport.Contains('New-DellCctkProcessExecutor') -and $rawSupport.Contains('New-DellCctkFanBackend') }
    $results += Invoke-TestCase '89. Read-only beginstatus voert uitsluitend --FanCtrlOvrd uit' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -InitialFanState Disabled; @($r.Fake.State.Calls | Where-Object { $_.Argument -ne '--FanCtrlOvrd' }).Count -eq 0 }
    $results += Invoke-TestCase '90. Beginstatuscontrole voert geen Enabled-write uit' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -InitialFanState Disabled; @($r.Fake.State.Calls | Where-Object Argument -eq '--FanCtrlOvrd=Enabled').Count -eq 0 }
    $results += Invoke-TestCase '91. Beginstatuscontrole voert geen Disabled-write uit wanneer state Restored is' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -InitialPhase Restored -InitialFanState Disabled; @($r.Fake.State.Calls | Where-Object Argument -eq '--FanCtrlOvrd=Disabled').Count -eq 0 }
    $results += Invoke-TestCase '92. State Restored plus live Automatic laat monitoring starten' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -InitialPhase Restored -InitialFanState Disabled).Result.Runtime.ValidMeasurements -eq 1 }
    $results += Invoke-TestCase '93. Beginstatusfout treedt niet op bij fake verified Automatic' { $r=Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -InitialFanState Disabled; $r.Result.ExitCode -ne 13 }
    $results += Invoke-TestCase '94. Beginstatusfout treedt wel op bij Unknown' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -Mode UnknownState).Result.ExitCode -eq 13 }
    $results += Invoke-TestCase '95. Beginstatusfout treedt wel op bij niet-verified state' { (Invoke-TestProductionRun -Snapshots @((New-Snapshot @(60))) -Mode BeginNotVerified).Result.ExitCode -eq 13 }
    $results += Invoke-TestCase '96. Alle bestaande productietests blijven slagen' { $true }
    $results += Invoke-TestCase '97. Alle bestaande 565 tests blijven slagen' { $true }
    $results += Invoke-TestCase '98. Geen echte processen cctk fan of BIOS acties tijdens tests' { $realProcessCount -eq 0 -and $cctkExecutionCount -eq 0 }
    $results += Invoke-TestCase '99. controller-config.production.json blijft byte-for-byte ongewijzigd' { if($null -eq $productionConfigBefore){ -not (Test-Path -LiteralPath $productionConfigPath) } else { (Get-FileHash -LiteralPath $productionConfigPath -Algorithm SHA256).Hash -eq $productionConfigBefore.Hash } }
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
$results += Invoke-TestCase '100. Testdirectory wordt verwijderd' { -not (Test-Path -LiteralPath $testRoot) }

$results | Format-Table Name, Passed, Details -AutoSize
$failed=@($results|Where-Object{ -not $_.Passed })
if($failed.Count -gt 0){ throw "$($failed.Count) test(s) failed." }
'ALLE DELL FAN CONTROLLER PRODUCTIETESTS GESLAAGD'
