param(
    [string]$TaskName = 'Dell Fan Controller',
    [string]$ProjectPath = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$ConfigPath = (Join-Path $ProjectPath 'controller-config.production.json')
)

$controller = Join-Path $ProjectPath 'DellFanController.ps1'
if (-not (Test-Path -LiteralPath $controller -PathType Leaf)) { throw "Controller not found: $controller" }
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Config not found: $ConfigPath" }

$args = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-WindowStyle', 'Hidden',
    '-File', "`"$controller`"",
    '-ConfigPath', "`"$ConfigPath`"",
    '-EnableProductionMode',
    '-AllowHardwareWrites',
    '-HardwareWriteConfirmation', "'ENABLE_AUTOMATIC_DELL_FAN_CONTROLLER'"
) -join ' '

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $args -WorkingDirectory $ProjectPath
$trigger = New-ScheduledTaskTrigger -AtLogOn
$trigger.Delay = 'PT60S'
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Runs Dell Fan Controller at user logon.' -Force
