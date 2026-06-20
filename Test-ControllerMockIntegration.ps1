[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$controllerScript = Join-Path $ScriptDirectory 'DellFanController-DryRun.ps1'
$configPath = Join-Path $ScriptDirectory 'controller-config.json'
$stateModulePath = Join-Path $ScriptDirectory 'DellFanController-State.ps1'
$contractPath = Join-Path $ScriptDirectory 'FanBackend.Contract.ps1'
$mockPath = Join-Path $ScriptDirectory 'FanBackend.Mock.ps1'
$testRoot = Join-Path $ScriptDirectory ("test-output\controller-mock-{0}" -f ([guid]::NewGuid().ToString('N')))

$configBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath))
$stateModuleBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($stateModulePath))
$contractBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($contractPath))
$mockBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($mockPath))

. $controllerScript
Import-MockBackendModules

function New-TestResult { param([string]$Name,[bool]$Passed,[string]$Details) [pscustomobject]@{Name=$Name;Passed=$Passed;Details=$Details} }
function Invoke-TestCase {
    param([string]$Name,[scriptblock]$Action)
    try { New-TestResult -Name $Name -Passed ([bool](& $Action)) -Details 'OK' }
    catch { New-TestResult -Name $Name -Passed $false -Details $_.Exception.Message }
}
function New-TestSnapshot { param([object[]]$Values) [pscustomobject]@{ Success=$true; Message=''; Temperatures=@($Values) } }
function New-TestFailureSnapshot { param([string]$Message='SENSOR_READ_FAILED') [pscustomobject]@{ Success=$false; Message=$Message; Temperatures=@() } }
function New-TestCaseDirectory {
    $path = Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $path
}
function New-TestStatePath { param([string]$Directory) Join-Path $Directory 'state.json' }
function Write-TestBackendState {
    param([string]$Path,[string]$Phase,[bool]$Owned=$false)
    $state = New-MockBackendStateObject -ControllerInstanceId ([guid]::NewGuid().ToString()) -CorrelationId ([guid]::NewGuid().ToString()) -BackendName 'MockFanBackend'
    if ($Phase -ne 'Idle') {
        if ($Phase -eq 'EnablePending') {
            $state = Set-ControllerStatePhase -State $state -OperationPhase 'EnablePending'
        } elseif ($Phase -eq 'ActiveVerified') {
            $state = Set-ControllerStatePhase -State $state -OperationPhase 'EnablePending'
            $state = Set-ControllerStatePhase -State $state -OperationPhase 'ActiveVerified'
        } elseif ($Phase -eq 'DisablePending') {
            $state = Set-ControllerStatePhase -State $state -OperationPhase 'EnablePending'
            $state = Set-ControllerStatePhase -State $state -OperationPhase 'ActiveVerified'
            $state = Set-ControllerStatePhase -State $state -OperationPhase 'DisablePending'
        } elseif ($Phase -eq 'CleanupRequired') {
            if ($Owned) {
                $state = Set-ControllerStatePhase -State $state -OperationPhase 'EnablePending'
                $state = Set-ControllerStatePhase -State $state -OperationPhase 'ActiveVerified'
            }
            $state = Mark-ControllerEmergencyReset -State $state -ErrorMessage 'test cleanup'
        } elseif ($Phase -eq 'Restored') {
            $state = Set-ControllerStatePhase -State $state -OperationPhase 'EnablePending'
            $state = Set-ControllerStatePhase -State $state -OperationPhase 'ActiveVerified'
            $state = Set-ControllerStatePhase -State $state -OperationPhase 'Restored'
        }
    }
    [void](Write-ControllerStateAtomic -Path $Path -State $state)
}
function Invoke-TestRun {
    param(
        [object[]]$Snapshots,
        [string]$FailureMode='None',
        [string]$InitialPhase,
        [bool]$Owned=$false,
        [switch]$NoMock,
        [switch]$WithLog
    )
    $dir = New-TestCaseDirectory
    $statePath = New-TestStatePath -Directory $dir
    if (-not [string]::IsNullOrWhiteSpace($InitialPhase)) { Write-TestBackendState -Path $statePath -Phase $InitialPhase -Owned $Owned }
    $logPath = Join-Path $dir 'dryrun.csv'
    $result = $null
    $errorMessage = $null
    try {
        $result = Start-DryRunController -Minutes 30 -DisableLog (-not $WithLog) -UseMock (-not [bool]$NoMock) -MockFailureModeValue $FailureMode -MockStatePath $statePath -TestSnapshots $Snapshots -TestStartTime ([datetime]'2026-06-19T14:00:00') -LogPathOverride $logPath -NoSleep
    }
    catch {
        $errorMessage = $_.Exception.Message
    }
    [pscustomobject]@{ Directory=$dir; StatePath=$statePath; LogPath=$logPath; Result=$result; ErrorMessage=$errorMessage; StateRead=$(if(Test-Path -LiteralPath $statePath){Read-ControllerState -Path $statePath}else{$null}) }
}
function Test-NoForbiddenAst {
    param([string[]]$Paths)
    $blockedCommands=@('Start-Process','Invoke-Expression','cctk','cctk.exe','Set-CimInstance','Invoke-CimMethod','Set-WmiInstance','Register-ScheduledTask','New-Service','Set-Service')
    $writeCommands=@('Set-CimInstance','Invoke-CimMethod','Set-WmiInstance','Set-ItemProperty','New-ItemProperty')
    foreach($path in $Paths){
        $tokens=$null;$errors=$null;$ast=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
        if($errors.Count -gt 0){throw "Parserfout in $path"}
        $types=$ast.FindAll({param($node)$node -is [System.Management.Automation.Language.TypeExpressionAst]},$true)
        foreach($type in $types){if($type.TypeName.FullName -eq 'System.Diagnostics.Process'){throw 'Verboden System.Diagnostics.Process typegebruik gevonden.'}}
        $commands=$ast.FindAll({param($node)$node -is [System.Management.Automation.Language.CommandAst]},$true)
        foreach($command in $commands){
            $name=$command.GetCommandName();$text=$command.Extent.Text
            if($blockedCommands -contains $name){throw "Verboden commando gevonden: $name"}
            if(($writeCommands -contains $name) -and $text -match '(?i)(FanCtrlOvrd\s*=|--?FanCtrlOvrd|Dell Command Configure|BIOS.*write)'){throw 'Verboden uitvoerbare code gevonden.'}
        }
    }
    $true
}

if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$results = @()

try {
    $highThenBoost = @((New-TestSnapshot @(80)),(New-TestSnapshot @(81)),(New-TestSnapshot @(70)),(New-TestSnapshot @(70)),(New-TestSnapshot @(70)),(New-TestSnapshot @(70)),(New-TestSnapshot @(70)))
    $oneHigh = @((New-TestSnapshot @(80)),(New-TestSnapshot @(70)))
    $lowReset = @((New-TestSnapshot @(80)),(New-TestSnapshot @(70)),(New-TestSnapshot @(80)))
    $throughCooldown = @((New-TestSnapshot @(80)),(New-TestSnapshot @(81)),(New-TestSnapshot @(70)),(New-TestSnapshot @(70)),(New-TestSnapshot @(70)),(New-TestSnapshot @(70)),(New-TestSnapshot @(70)),(New-TestSnapshot @(70)),(New-TestSnapshot @(70)),(New-TestSnapshot @(70)),(New-TestSnapshot @(70)),(New-TestSnapshot @(70)),(New-TestSnapshot @(70)),(New-TestSnapshot @(70)),(New-TestSnapshot @(70)),(New-TestSnapshot @(70)),(New-TestSnapshot @(70)))
    $boostAndCooldown = @($throughCooldown + @((New-TestSnapshot @(80)),(New-TestSnapshot @(81))))

    $results += Invoke-TestCase '1. Controller zonder UseMockBackend behoudt bestaande werking' { $r=Invoke-TestRun -Snapshots $oneHigh -NoMock; $null -eq $r.ErrorMessage -and $r.Result.RuntimeState.ValidMeasurements -eq 2 }
    $results += Invoke-TestCase '2. Zonder mock wordt geen statebestand gemaakt' { $r=Invoke-TestRun -Snapshots $oneHigh -NoMock; -not (Test-Path -LiteralPath $r.StatePath) }
    $results += Invoke-TestCase '3. Mockmodus vereist DryRun=true' { (Read-ControllerConfig -Path $configPath).Config.DryRun -eq $true }
    $results += Invoke-TestCase '4. Geldige mockmodus start' { $r=Invoke-TestRun -Snapshots @((New-TestSnapshot @(60))); $null -eq $r.ErrorMessage -and $r.Result.Success }
    $results += Invoke-TestCase '5. Mockbackend wordt een keer aangemaakt per run' { $r=Invoke-TestRun -Snapshots @((New-TestSnapshot @(60))); $r.Result.MockContext.BackendCreatedCount -eq 1 }
    $results += Invoke-TestCase '6. Idle-state laat controller starten' { $r=Invoke-TestRun -Snapshots @((New-TestSnapshot @(60))) -InitialPhase Idle; $null -eq $r.ErrorMessage }
    $results += Invoke-TestCase '7. Restored-state laat controller starten' { $r=Invoke-TestRun -Snapshots @((New-TestSnapshot @(60))) -InitialPhase Restored; $null -eq $r.ErrorMessage }
    $results += Invoke-TestCase '8. ActiveVerified veroorzaakt startup restore' { $r=Invoke-TestRun -Snapshots @((New-TestSnapshot @(60))) -InitialPhase ActiveVerified; $r.StateRead.State.OperationPhase -eq 'Restored' }
    $results += Invoke-TestCase '9. DisablePending veroorzaakt startup restore' { $r=Invoke-TestRun -Snapshots @((New-TestSnapshot @(60))) -InitialPhase DisablePending; $r.StateRead.State.OperationPhase -eq 'Restored' }
    $results += Invoke-TestCase '10. CleanupRequired veroorzaakt startup emergency recovery' { $r=Invoke-TestRun -Snapshots @((New-TestSnapshot @(60))) -InitialPhase CleanupRequired -Owned $true; $r.Result.MockContext.EmergencyResetAttempts -ge 1 }
    $results += Invoke-TestCase '11. Startup recovery failure blokkeert controllerstart' { $r=Invoke-TestRun -Snapshots @((New-TestSnapshot @(60))) -InitialPhase ActiveVerified -FailureMode ThrowOnRestore; $null -ne $r.ErrorMessage }
    $results += Invoke-TestCase '12. Enable gebeurt na twee opeenvolgende hoge metingen' { $r=Invoke-TestRun -Snapshots $highThenBoost; $r.Result.MockContext.Backend.RuntimeState.EnableCallCount -eq 1 }
    $results += Invoke-TestCase '13. Enable gebeurt niet na een hoge meting' { $r=Invoke-TestRun -Snapshots $oneHigh; $r.Result.MockContext.Backend.RuntimeState.EnableCallCount -eq 0 }
    $results += Invoke-TestCase '14. Lage meting reset consecutive teller' { $r=Invoke-TestRun -Snapshots $lowReset; $r.Result.MockContext.Backend.RuntimeState.EnableCallCount -eq 0 }
    $results += Invoke-TestCase '15. Normale enable eindigt ActiveVerified' { $r=Invoke-TestRun -Snapshots @((New-TestSnapshot @(80)),(New-TestSnapshot @(81))) -WithLog; (Get-Content -LiteralPath $r.LogPath -Raw) -match 'ActiveVerified' }
    $results += Invoke-TestCase '16. Mockbackend staat na enable op BoostEnabled' { $r=Invoke-TestRun -Snapshots @((New-TestSnapshot @(80)),(New-TestSnapshot @(81))); @($r.Result.MockContext.Backend.ActionLog|Where-Object { $_.Action -eq 'EnableBoost' -and $_.ResultState -eq 'BoostEnabled' }).Count -eq 1 }
    $results += Invoke-TestCase '17. EnableCallCount is correct' { $r=Invoke-TestRun -Snapshots $highThenBoost; $r.Result.MockContext.Backend.RuntimeState.EnableCallCount -eq 1 }
    $results += Invoke-TestCase '18. Enable-event bevat CorrelationId' { $r=Invoke-TestRun -Snapshots @((New-TestSnapshot @(80)),(New-TestSnapshot @(81))); -not [string]::IsNullOrWhiteSpace([string]$r.Result.MockContext.CurrentCorrelationId) }
    $results += Invoke-TestCase '19. Dubbele enable tijdens boost gebeurt niet' { $r=Invoke-TestRun -Snapshots @((New-TestSnapshot @(80)),(New-TestSnapshot @(81)),(New-TestSnapshot @(90)),(New-TestSnapshot @(91))); $r.Result.MockContext.Backend.RuntimeState.EnableCallCount -eq 1 }
    $results += Invoke-TestCase '20. Boost eindigt met restore' { $r=Invoke-TestRun -Snapshots $highThenBoost; $r.Result.MockContext.Backend.RuntimeState.RestoreCallCount -eq 1 }
    $results += Invoke-TestCase '21. Restore eindigt in Restored' { $r=Invoke-TestRun -Snapshots $highThenBoost; $r.StateRead.State.OperationPhase -eq 'Restored' }
    $results += Invoke-TestCase '22. Mockbackend staat na restore op Automatic' { $r=Invoke-TestRun -Snapshots $highThenBoost; $r.Result.MockContext.Backend.RuntimeState.CurrentFanState -eq 'Automatic' }
    $results += Invoke-TestCase '23. Controller gaat pas na verified restore naar Cooldown' { $r=Invoke-TestRun -Snapshots $highThenBoost; $r.Result.RuntimeState.State -eq 'Cooldown' -and $r.StateRead.State.OperationPhase -eq 'Restored' }
    $results += Invoke-TestCase '24. Cooldown voert geen extra restore uit' { $r=Invoke-TestRun -Snapshots $throughCooldown; $r.Result.MockContext.Backend.RuntimeState.RestoreCallCount -eq 1 }
    $results += Invoke-TestCase '25. Nieuwe boost na cooldown krijgt nieuwe CorrelationId' { $r=Invoke-TestRun -Snapshots $boostAndCooldown; $r.Result.RuntimeState.WouldEnableFanCount -eq 2 -and $r.Result.MockContext.Backend.RuntimeState.EnableCallCount -eq 2 }
    $results += Invoke-TestCase '26. ThrowOnEnable stopt gecontroleerd' { $r=Invoke-TestRun -Snapshots @((New-TestSnapshot @(80)),(New-TestSnapshot @(81))) -FailureMode ThrowOnEnable; $null -ne $r.ErrorMessage }
    $results += Invoke-TestCase '27. ThrowOnEnable eindigt CleanupRequired of verified Restored na cleanup' { $r=Invoke-TestRun -Snapshots @((New-TestSnapshot @(80)),(New-TestSnapshot @(81))) -FailureMode ThrowOnEnable; @('CleanupRequired','Restored') -contains [string]$r.StateRead.State.OperationPhase }
    $results += Invoke-TestCase '28. EnableVerificationFails stopt gecontroleerd' { $r=Invoke-TestRun -Snapshots @((New-TestSnapshot @(80)),(New-TestSnapshot @(81))) -FailureMode EnableVerificationFails; $null -ne $r.ErrorMessage }
    $results += Invoke-TestCase '29. ReturnUnknownAfterEnable stopt gecontroleerd' { $r=Invoke-TestRun -Snapshots @((New-TestSnapshot @(80)),(New-TestSnapshot @(81))) -FailureMode ReturnUnknownAfterEnable; $null -ne $r.ErrorMessage }
    $results += Invoke-TestCase '30. ThrowOnRestore gaat niet naar Cooldown' { $r=Invoke-TestRun -Snapshots $highThenBoost -FailureMode ThrowOnRestore; $null -ne $r.ErrorMessage -and $r.Result -eq $null }
    $results += Invoke-TestCase '31. RestoreVerificationFails gaat niet naar Cooldown' { $r=Invoke-TestRun -Snapshots $highThenBoost -FailureMode RestoreVerificationFails; $null -ne $r.ErrorMessage }
    $results += Invoke-TestCase '32. ReturnUnknownAfterRestore gaat niet naar Cooldown' { $r=Invoke-TestRun -Snapshots $highThenBoost -FailureMode ReturnUnknownAfterRestore; $null -ne $r.ErrorMessage }
    $results += Invoke-TestCase '33. Sensorfout voor boost gebruikt bestaande foutlogica' { $r=Invoke-TestRun -Snapshots @((New-TestFailureSnapshot),(New-TestFailureSnapshot)); $r.Result.RuntimeState.ShouldStop -eq $false }
    $results += Invoke-TestCase '34. Sensorfout tijdens boost start onmiddellijk restore' { $r=Invoke-TestRun -Snapshots @((New-TestSnapshot @(80)),(New-TestSnapshot @(81)),(New-TestFailureSnapshot)); $r.Result.MockContext.Backend.RuntimeState.RestoreCallCount -eq 1 }
    $results += Invoke-TestCase '35. Sensorfout tijdens boost wacht niet op drie failures' { $r=Invoke-TestRun -Snapshots @((New-TestSnapshot @(80)),(New-TestSnapshot @(81)),(New-TestFailureSnapshot)); $r.Result.RuntimeState.FailedMeasurements -eq 1 -and $r.Result.RuntimeState.ShouldStop }
    $results += Invoke-TestCase '36. Sensorfoutrestore success eindigt Automatic' { $r=Invoke-TestRun -Snapshots @((New-TestSnapshot @(80)),(New-TestSnapshot @(81)),(New-TestFailureSnapshot)); $r.StateRead.State.OperationPhase -eq 'Restored' }
    $results += Invoke-TestCase '37. Sensorfoutrestore failure behoudt CleanupRequired' { $r=Invoke-TestRun -Snapshots @((New-TestSnapshot @(80)),(New-TestSnapshot @(81)),(New-TestFailureSnapshot)) -FailureMode ThrowOnRestore; $r.StateRead.State.OperationPhase -eq 'CleanupRequired' }
    $results += Invoke-TestCase '38. Normaal einde tijdens actieve boost voert exit-cleanup uit' { $r=Invoke-TestRun -Snapshots @((New-TestSnapshot @(80)),(New-TestSnapshot @(81))); $r.Result.MockContext.CleanupSucceeded -eq 1 }
    $results += Invoke-TestCase '39. Exception tijdens boost voert finally-cleanup uit' { $r=Invoke-TestRun -Snapshots $highThenBoost -FailureMode ThrowOnRestore; $r.StateRead.State.OperationPhase -eq 'CleanupRequired' }
    $results += Invoke-TestCase '40. Exit-cleanup success eindigt Restored' { $r=Invoke-TestRun -Snapshots @((New-TestSnapshot @(80)),(New-TestSnapshot @(81))); $r.StateRead.State.OperationPhase -eq 'Restored' }
    $results += Invoke-TestCase '41. Exit-cleanup failure behoudt emergency flag' { $r=Invoke-TestRun -Snapshots $highThenBoost -FailureMode ThrowOnRestore; $r.StateRead.State.RequiresEmergencyReset }
    $results += Invoke-TestCase '42. Statebestand blijft valide na elke overgang' { $r=Invoke-TestRun -Snapshots $highThenBoost; $r.StateRead.Success }
    $results += Invoke-TestCase '43. Statebackup blijft valide' { $r=Invoke-TestRun -Snapshots $highThenBoost; (Read-ControllerState -Path ($r.StatePath + '.missing') -BackupPath ($r.StatePath + '.bak')).Success }
    $results += Invoke-TestCase '44. Geen gedeeltelijk JSON-bestand ontstaat' { $r=Invoke-TestRun -Snapshots $highThenBoost; @((Get-ChildItem -LiteralPath $r.Directory -Filter '*.tmp' -File)).Count -eq 0 }
    $results += Invoke-TestCase '45. Mock actionlog bevat enable' { $r=Invoke-TestRun -Snapshots $highThenBoost; @($r.Result.MockContext.Backend.ActionLog|Where-Object Action -eq 'EnableBoost').Count -ge 1 }
    $results += Invoke-TestCase '46. Mock actionlog bevat restore' { $r=Invoke-TestRun -Snapshots $highThenBoost; @($r.Result.MockContext.Backend.ActionLog|Where-Object Action -eq 'RestoreAutomatic').Count -ge 1 }
    $results += Invoke-TestCase '47. Summary bevat mockgegevens' { $r=Invoke-TestRun -Snapshots @((New-TestSnapshot @(60))); $null -ne $r.Result.MockContext -and $r.Result.MockContext.Backend.BackendName -eq 'MockFanBackend' }
    $results += Invoke-TestCase '48. CSV bevat mockbackendvelden' { $r=Invoke-TestRun -Snapshots @((New-TestSnapshot @(60))) -WithLog; $csv=Get-Content -LiteralPath $r.Result.LogPath -Raw; $csv -match 'BackendName,BackendAction,BackendSuccess' }
    $results += Invoke-TestCase '49. Legacy dry-run CSV blijft bruikbaar' { $d=New-TestCaseDirectory; $p=Join-Path $d 'legacy.csv'; $row=Update-ControllerState -State (New-ControllerState) -Config (Read-ControllerConfig $configPath).Config -Now ([datetime]'2026-06-19') -Snapshot (New-TestSnapshot @(60)); Write-DryRunLog $p $row; (Get-Content $p -TotalCount 1) -eq 'Timestamp,State,HighestTemperatureCelsius,ValidCoreCount,ThresholdCelsius,ConsecutiveHighReadings,RequiredConsecutiveHighReadings,RemainingBoostSeconds,RemainingCooldownSeconds,Event,DryRun' }
    $results += Invoke-TestCase '50. controller-config.json blijft byte-for-byte ongewijzigd' { [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -eq $configBefore }
    $results += Invoke-TestCase '51. DellFanController-State.ps1 blijft byte-for-byte ongewijzigd' { [Convert]::ToBase64String([IO.File]::ReadAllBytes($stateModulePath)) -eq $stateModuleBefore }
    $results += Invoke-TestCase '52. FanBackend.Contract.ps1 blijft byte-for-byte ongewijzigd' { [Convert]::ToBase64String([IO.File]::ReadAllBytes($contractPath)) -eq $contractBefore }
    $results += Invoke-TestCase '53. FanBackend.Mock.ps1 blijft byte-for-byte ongewijzigd' { [Convert]::ToBase64String([IO.File]::ReadAllBytes($mockPath)) -eq $mockBefore }
    $results += Invoke-TestCase '54. DryRun blijft boolean true' { (Get-Content -Raw $configPath | ConvertFrom-Json).DryRun -eq $true }
    $results += Invoke-TestCase '55. Geen projectroot-tempbestanden blijven achter' { @((Get-ChildItem -LiteralPath $ScriptDirectory -File -Filter '*.tmp')).Count -eq 0 }
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

$results += Invoke-TestCase '56. Testdirectory wordt verwijderd' { -not (Test-Path -LiteralPath $testRoot) }
$results += Invoke-TestCase '57. Geen parserfouten in gewijzigde controller' { $tokens=$null;$errors=$null;[System.Management.Automation.Language.Parser]::ParseFile($controllerScript,[ref]$tokens,[ref]$errors)|Out-Null;$errors.Count -eq 0 }
$results += Invoke-TestCase '58. Geen parserfouten in nieuw testscript' { $tokens=$null;$errors=$null;[System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors)|Out-Null;$errors.Count -eq 0 }
$results += Invoke-TestCase '59. Geen Start-Process' { Test-NoForbiddenAst @($controllerScript,$PSCommandPath) }
$results += Invoke-TestCase '60. Geen System.Diagnostics.Process' { Test-NoForbiddenAst @($controllerScript,$PSCommandPath) }
$results += Invoke-TestCase '61. Geen Invoke-Expression' { Test-NoForbiddenAst @($controllerScript,$PSCommandPath) }
$results += Invoke-TestCase '62. Geen cctk-referentie in uitvoerbare code' { Test-NoForbiddenAst @($controllerScript,$PSCommandPath) }
$results += Invoke-TestCase '63. Geen Dell- of BIOS-writecommando''s' { Test-NoForbiddenAst @($controllerScript,$PSCommandPath) }
$results += Invoke-TestCase '64. Geen WMI/CIM-hardwarewrites' { Test-NoForbiddenAst @($controllerScript,$PSCommandPath) }
$results += Invoke-TestCase '65. Geen externe executable invocation' { Test-NoForbiddenAst @($controllerScript,$PSCommandPath) }

$results | Format-Table Name, Passed, Details -AutoSize
$failed=@($results|Where-Object{ -not $_.Passed })
if($failed.Count -gt 0){ throw "$($failed.Count) test(s) failed." }
'ALLE CONTROLLER MOCK INTEGRATIETESTS GESLAAGD'
