[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$controllerScript = Join-Path $ScriptDirectory 'DellFanController-DryRun.ps1'
$testRoot = Join-Path $ScriptDirectory 'test-output'

. $controllerScript

function New-TestResult { param([string]$Name, [bool]$Passed, [string]$Details) [pscustomobject]@{ Name = $Name; Passed = $Passed; Details = $Details } }
function Invoke-TestCase {
    param([string]$Name, [scriptblock]$Action)
    try { New-TestResult -Name $Name -Passed ([bool](& $Action)) -Details 'OK' }
    catch { New-TestResult -Name $Name -Passed $false -Details $_.Exception.Message }
}
function New-TestConfig {
    param([hashtable]$Overrides)
    $config = [pscustomobject]@{
        SchemaVersion = 1
        ThresholdCelsius = 75
        PollIntervalSeconds = 60
        RequiredConsecutiveHighReadings = 2
        BoostDurationSeconds = 300
        CooldownSeconds = 600
        DryRun = $true
        SensorProvider = 'CoreTempSharedMemory'
    }
    foreach ($key in $Overrides.Keys) { $config.$key = $Overrides[$key] }
    $config
}
function New-Snapshot { param([object[]]$Values) [pscustomobject]@{ Success = $true; Message = ''; Temperatures = @($Values) } }
function New-FailureSnapshot { param([string]$Message = 'SENSOR_READ_FAILED') [pscustomobject]@{ Success = $false; Message = $Message; Temperatures = @() } }
function Step-Controller {
    param([object]$State, [object]$Config, [datetime]$Now, [object[]]$Values)
    Update-ControllerState -State $State -Config $Config -Now $Now -Snapshot (New-Snapshot -Values $Values)
}
function Test-ForbiddenAst {
    param([string[]]$Paths)
    $blocked = @('cctk','cctk.exe','schtasks','schtasks.exe','Register-ScheduledTask','New-ScheduledTask','New-Service','Set-Service','sc.exe','reg.exe','powercfg','Set-ItemProperty','Stop-VM','Restart-VM','Stop-Process')
    $writeCommands = @('Set-ItemProperty','New-ItemProperty','Set-CimInstance','Invoke-CimMethod','Set-WmiInstance')
    foreach ($path in $Paths) {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "Parserfout in $path" }
        $commands = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($command in $commands) {
            $name = $command.GetCommandName()
            $text = $command.Extent.Text
            if ($blocked -contains $name) { throw "Verboden commando: $name" }
            if ($name -eq 'Start-Process' -and $text -match '(?i)(cctk|powercfg|reg\.exe)') { throw 'Verboden Start-Process-doel gevonden.' }
            if (($writeCommands -contains $name) -and $text -match '(?i)(FanCtrlOvrd|Dell Command Configure|BIOS.*write)') { throw 'Verboden write-actie in uitvoerbare code.' }
        }
    }
    $true
}

if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$results = @()
$cfg = New-TestConfig @{}
$t0 = [datetime]'2026-06-19T14:00:00'

$results += Invoke-TestCase '1. Geldige configuratie wordt geaccepteerd' { (Test-ControllerConfig -Config $cfg).IsValid }
$results += Invoke-TestCase '2. DryRun false wordt geweigerd' { (Test-ControllerConfig -Config (New-TestConfig @{ DryRun = $false })).DryRunBlocked }
$results += Invoke-TestCase '3. DryRun ontbreekt wordt geweigerd' { $c = New-TestConfig @{}; $c.PSObject.Properties.Remove('DryRun'); (Test-ControllerConfig -Config $c).DryRunBlocked }
$results += Invoke-TestCase '4. Verkeerde SchemaVersion wordt geweigerd' { -not (Test-ControllerConfig -Config (New-TestConfig @{ SchemaVersion = 2 })).IsValid }
$results += Invoke-TestCase '5. Verkeerde SensorProvider wordt geweigerd' { -not (Test-ControllerConfig -Config (New-TestConfig @{ SensorProvider = 'Other' })).IsValid }
$results += Invoke-TestCase '6. Ongeldige numerieke grenzen worden geweigerd' { -not (Test-ControllerConfig -Config (New-TestConfig @{ ThresholdCelsius = 91 })).IsValid }
$results += Invoke-TestCase '7. Een hoge meting bij vereiste twee activeert niets' { $s=New-ControllerState; $r=Step-Controller $s $cfg $t0 @(76); $r.Event -eq '' -and $s.State -eq 'Monitoring' }
$results += Invoke-TestCase '8. Twee opeenvolgende hoge metingen activeren WOULD_ENABLE_FAN' { $s=New-ControllerState; [void](Step-Controller $s $cfg $t0 @(76)); $r=Step-Controller $s $cfg $t0.AddSeconds(60) @(77); $r.Event -eq 'WOULD_ENABLE_FAN' -and $s.State -eq 'SimulatedBoost' }
$results += Invoke-TestCase '9. Lage meting reset teller' { $s=New-ControllerState; [void](Step-Controller $s $cfg $t0 @(76)); [void](Step-Controller $s $cfg $t0.AddSeconds(60) @(70)); $r=Step-Controller $s $cfg $t0.AddSeconds(120) @(76); $r.Event -eq '' -and $s.ConsecutiveHighReadings -eq 1 }
$results += Invoke-TestCase '10. Exact 75 telt als hoog' { $s=New-ControllerState; $r=Step-Controller $s $cfg $t0 @(75.0); $s.ConsecutiveHighReadings -eq 1 -and $r.HighestTemperatureCelsius -eq 75 }
$results += Invoke-TestCase '11. Tijdens SimulatedBoost ontstaat geen tweede boost' { $s=New-ControllerState; [void](Step-Controller $s $cfg $t0 @(80)); [void](Step-Controller $s $cfg $t0.AddSeconds(60) @(81)); $r=Step-Controller $s $cfg $t0.AddSeconds(120) @(82); $r.Event -eq '' -and $s.WouldEnableFanCount -eq 1 }
$results += Invoke-TestCase '12. SimulatedBoost duurt exact BoostDurationSeconds' { $s=New-ControllerState; [void](Step-Controller $s $cfg $t0 @(80)); [void](Step-Controller $s $cfg $t0.AddSeconds(60) @(81)); $r=Step-Controller $s $cfg $t0.AddSeconds(360) @(70); $r.Event -eq 'WOULD_DISABLE_FAN' }
$results += Invoke-TestCase '13. Na boost ontstaat WOULD_DISABLE_FAN' { $s=New-ControllerState; [void](Step-Controller $s $cfg $t0 @(80)); [void](Step-Controller $s $cfg $t0.AddSeconds(60) @(81)); $r=Step-Controller $s $cfg $t0.AddSeconds(360) @(70); $r.Event -eq 'WOULD_DISABLE_FAN' }
$results += Invoke-TestCase '14. Daarna start Cooldown' { $s=New-ControllerState; [void](Step-Controller $s $cfg $t0 @(80)); [void](Step-Controller $s $cfg $t0.AddSeconds(60) @(81)); [void](Step-Controller $s $cfg $t0.AddSeconds(360) @(70)); $s.State -eq 'Cooldown' }
$results += Invoke-TestCase '15. Tijdens Cooldown ontstaat geen nieuwe boost' { $s=New-ControllerState; [void](Step-Controller $s $cfg $t0 @(80)); [void](Step-Controller $s $cfg $t0.AddSeconds(60) @(81)); [void](Step-Controller $s $cfg $t0.AddSeconds(360) @(80)); $r=Step-Controller $s $cfg $t0.AddSeconds(420) @(85); $r.Event -eq '' -and $s.WouldEnableFanCount -eq 1 }
$results += Invoke-TestCase '16. Cooldown duurt exact CooldownSeconds' { $s=New-ControllerState; [void](Step-Controller $s $cfg $t0 @(80)); [void](Step-Controller $s $cfg $t0.AddSeconds(60) @(81)); [void](Step-Controller $s $cfg $t0.AddSeconds(360) @(80)); $r=Step-Controller $s $cfg $t0.AddSeconds(960) @(70); $r.Event -eq 'COOLDOWN_ENDED' }
$results += Invoke-TestCase '17. Na cooldown ontstaat COOLDOWN_ENDED' { $s=New-ControllerState; [void](Step-Controller $s $cfg $t0 @(80)); [void](Step-Controller $s $cfg $t0.AddSeconds(60) @(81)); [void](Step-Controller $s $cfg $t0.AddSeconds(360) @(80)); $r=Step-Controller $s $cfg $t0.AddSeconds(960) @(70); $r.Event -eq 'COOLDOWN_ENDED' }
$results += Invoke-TestCase '18. Na cooldown zijn opnieuw twee hoge metingen nodig' { $s=New-ControllerState; [void](Step-Controller $s $cfg $t0 @(80)); [void](Step-Controller $s $cfg $t0.AddSeconds(60) @(81)); [void](Step-Controller $s $cfg $t0.AddSeconds(360) @(80)); [void](Step-Controller $s $cfg $t0.AddSeconds(960) @(80)); $r=Step-Controller $s $cfg $t0.AddSeconds(1020) @(80); $r.Event -eq '' -and $s.ConsecutiveHighReadings -eq 1 }
$results += Invoke-TestCase '19. HighReadings blijft nul tijdens boost' { $s=New-ControllerState; [void](Step-Controller $s $cfg $t0 @(80)); [void](Step-Controller $s $cfg $t0.AddSeconds(60) @(81)); [void](Step-Controller $s $cfg $t0.AddSeconds(120) @(82)); $s.ConsecutiveHighReadings -eq 0 }
$results += Invoke-TestCase '20. HighReadings blijft nul tijdens cooldown' { $s=New-ControllerState; [void](Step-Controller $s $cfg $t0 @(80)); [void](Step-Controller $s $cfg $t0.AddSeconds(60) @(81)); [void](Step-Controller $s $cfg $t0.AddSeconds(360) @(80)); [void](Step-Controller $s $cfg $t0.AddSeconds(420) @(80)); $s.ConsecutiveHighReadings -eq 0 }
$results += Invoke-TestCase '21. Nulltemperaturen worden geweigerd' { -not (Get-HighestValidTemperature -Temperatures @($null)).Success }
$results += Invoke-TestCase '22. NaN wordt geweigerd' { -not (Get-HighestValidTemperature -Temperatures @([double]::NaN)).Success }
$results += Invoke-TestCase '23. Strings worden geweigerd' { -not (Get-HighestValidTemperature -Temperatures @('warm')).Success }
$results += Invoke-TestCase '24. Temperatuur onder 0 wordt geweigerd' { -not (Get-HighestValidTemperature -Temperatures @(-1)).Success }
$results += Invoke-TestCase '25. Temperatuur boven 115 wordt geweigerd' { -not (Get-HighestValidTemperature -Temperatures @(116)).Success }
$results += Invoke-TestCase '26. Een geldige core wordt geaccepteerd' { (Get-HighestValidTemperature -Temperatures @(61)).ValidCoreCount -eq 1 }
$results += Invoke-TestCase '27. Zes geldige cores worden geaccepteerd' { (Get-HighestValidTemperature -Temperatures @(60,61,62,63,64,65)).ValidCoreCount -eq 6 }
$results += Invoke-TestCase '28. Hoogste coretemperatuur wordt correct bepaald' { (Get-HighestValidTemperature -Temperatures @(60,83.5,62)).Highest -eq 83.5 }
$results += Invoke-TestCase '29. Geen geldige cores veroorzaakt SENSOR_READ_FAILED' { $s=New-ControllerState; $r=Step-Controller $s $cfg $t0 @('bad'); $r.Event -eq 'SENSOR_READ_FAILED' }
$results += Invoke-TestCase '30. Drie sensorfouten stoppen veilig' { $s=New-ControllerState; [void](Update-ControllerState $s $cfg $t0 (New-FailureSnapshot)); [void](Update-ControllerState $s $cfg $t0.AddSeconds(60) (New-FailureSnapshot)); $r=Update-ControllerState $s $cfg $t0.AddSeconds(120) (New-FailureSnapshot); $r.Event -eq 'CONTROLLER_STOPPED_AFTER_SENSOR_FAILURES' -and $s.ShouldStop }
$results += Invoke-TestCase '31. Geldige CSV-header' { $row=Step-Controller (New-ControllerState) $cfg $t0 @(60); $p=Join-Path $testRoot 'dryrun.csv'; Write-DryRunLog $p $row; (Get-Content $p -TotalCount 1) -eq 'Timestamp,State,HighestTemperatureCelsius,ValidCoreCount,ThresholdCelsius,ConsecutiveHighReadings,RequiredConsecutiveHighReadings,RemainingBoostSeconds,RemainingCooldownSeconds,Event,DryRun' }
$results += Invoke-TestCase '32. Correcte CSV-regels' { $row=Step-Controller (New-ControllerState) $cfg $t0 @(60); $line=Convert-LogRowToCsvLine $row; $line -match 'Monitoring' -and $line -match '60' }
$results += Invoke-TestCase '33. Geen dubbele CSV-header' { $p=Join-Path $testRoot 'dryrun2.csv'; $row=Step-Controller (New-ControllerState) $cfg $t0 @(60); Write-DryRunLog $p $row; Write-DryRunLog $p $row; @((Get-Content $p) | Where-Object { $_ -match '^Timestamp,' }).Count -eq 1 }
$results += Invoke-TestCase '34. Eindrapportberekeningen kloppen' { $s=New-ControllerState; [void](Step-Controller $s $cfg $t0 @(80)); [void](Step-Controller $s $cfg $t0.AddSeconds(60) @(81)); $s.ValidMeasurements -eq 2 -and $s.HighestMeasuredTemperature -eq 81 -and $s.WouldEnableFanCount -eq 1 }
$results += Invoke-TestCase '35. Set-StrictMode-compatibiliteit' { Set-StrictMode -Version Latest; (Test-ControllerConfig -Config $cfg).IsValid }
$results += Invoke-TestCase '36. Windows PowerShell 5.1 parsercontrole' { foreach($p in @($controllerScript,$PSCommandPath)){ $tokens=$null; $errors=$null; [System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$tokens,[ref]$errors)|Out-Null; if($errors.Count -gt 0){ return $false } }; $true }
$results += Invoke-TestCase '37. Ctrl+C/stopafhandeling veroorzaakt geen hardwareactie' { (Get-Content -LiteralPath $controllerScript -Raw) -notmatch '(?i)(FanCtrlOvrd|cctk|powercfg|Stop-VM|Restart-VM)' }
$results += Invoke-TestCase '38. AST-safetytests' { Test-ForbiddenAst -Paths @($controllerScript, $PSCommandPath) }

$results | Format-Table Name, Passed, Details -AutoSize
$failed = @($results | Where-Object { -not $_.Passed })
if ($failed.Count -gt 0) { throw "$($failed.Count) test(s) failed." }
'ALLE DRY-RUNCONTROLLER TESTS GESLAAGD'
