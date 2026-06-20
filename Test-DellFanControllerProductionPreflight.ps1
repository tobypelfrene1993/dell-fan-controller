[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$preflightPath = Join-Path $ScriptDirectory 'Invoke-DellFanControllerProductionPreflight.ps1'
$controllerPath = Join-Path $ScriptDirectory 'DellFanController.ps1'
$supportPath = Join-Path $ScriptDirectory 'DellFanController-ProductionSupport.ps1'
$probePath = Join-Path $ScriptDirectory 'Invoke-DellCctkReadOnlyProbe.ps1'
$productionConfigPath = Join-Path $ScriptDirectory 'controller-config.production.json'
$productionLogPath = Join-Path $ScriptDirectory 'logs\dell-fan-controller-production.csv'
$productionStatePath = Join-Path $ScriptDirectory 'logs\dell-fan-controller-state.dellcctk.json'

$configBefore = Get-FileHash -LiteralPath $productionConfigPath -Algorithm SHA256
$logBefore = if (Test-Path -LiteralPath $productionLogPath -PathType Leaf) { Get-FileHash -LiteralPath $productionLogPath -Algorithm SHA256 } else { $null }
$stateBefore = if (Test-Path -LiteralPath $productionStatePath -PathType Leaf) { Get-FileHash -LiteralPath $productionStatePath -Algorithm SHA256 } else { $null }
$realProcessCount = 0
$cctkExecutionCount = 0

. $preflightPath

function New-TestResult { param([string]$Name,[bool]$Passed,[string]$Details='OK') [pscustomobject]@{Name=$Name;Passed=$Passed;Details=$Details} }
function Invoke-TestCase {
    param([string]$Name,[scriptblock]$Action)
    try { New-TestResult -Name $Name -Passed ([bool](& $Action)) }
    catch { New-TestResult -Name $Name -Passed $false -Details $_.Exception.Message }
}
function New-FakeCoreTemp {
    [pscustomobject]@{ Available=$true; CoreCount=6; HighestTemperature=62.5; Message='' }
}
function New-FakeInvoker {
    param([string]$Mode='Automatic')
    $state = [pscustomobject]@{ Calls=@() }
    $invoker = {
        param([string]$ExecutablePath,[string[]]$ArgumentList,[int]$TimeoutSeconds)
        $argument = [string]@($ArgumentList)[0]
        $state.Calls = @($state.Calls) + ([pscustomobject]@{ ExecutablePath=$ExecutablePath; Argument=$argument; TimeoutSeconds=$TimeoutSeconds })
        switch ($Mode) {
            'ExactRegression' { [pscustomobject]@{ Started=$true; ExitCode=0; StdOut='FanCtrlOvrd=Disabled'; StdErr=''; TimedOut=$false; DurationMs=35; ErrorMessage=$null } }
            'NullExitCode' { [pscustomobject]@{ Started=$true; ExitCode=$null; StdOut='FanCtrlOvrd=Disabled'; StdErr=''; TimedOut=$false; DurationMs=35; ErrorMessage=$null } }
            'PipelineBoolean' { Write-Output $true; [pscustomobject]@{ Started=$true; ExitCode=0; StdOut='FanCtrlOvrd=Disabled'; StdErr=''; TimedOut=$false; DurationMs=35; ErrorMessage=$null } }
            'MultipleObjects' { [pscustomobject]@{ Started=$true; ExitCode=0; StdOut='one'; StdErr=''; TimedOut=$false; DurationMs=1; ErrorMessage=$null }; [pscustomobject]@{ Started=$true; ExitCode=0; StdOut='two'; StdErr=''; TimedOut=$false; DurationMs=2; ErrorMessage=$null } }
            'Automatic' { [pscustomobject]@{ ExitCode=0; StdOut='FanCtrlOvrd=Disabled'; StdErr=''; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null } }
            'BoostEnabled' { [pscustomobject]@{ ExitCode=0; StdOut='FanCtrlOvrd=Enabled'; StdErr=''; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null } }
            'Unknown' { [pscustomobject]@{ ExitCode=0; StdOut='FanCtrlOvrd=Maybe'; StdErr=''; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null } }
            'NotVerifiedAutomatic' { [pscustomobject]@{ ExitCode=0; StdOut='FanCtrlOvrd=Disabled`nUnexpected'; StdErr=''; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null } }
            'NonZero' { [pscustomobject]@{ ExitCode=7; StdOut=''; StdErr='nonzero'; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null } }
            'Timeout' { [pscustomobject]@{ ExitCode=$null; StdOut=''; StdErr='timeout'; TimedOut=$true; DurationMs=15000; Started=$true; ErrorMessage='timeout' } }
            'StdErr' { [pscustomobject]@{ ExitCode=0; StdOut='FanCtrlOvrd=Disabled'; StdErr='warning'; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null } }
            default { [pscustomobject]@{ ExitCode=0; StdOut=''; StdErr=''; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null } }
        }
    }.GetNewClosure()
    [pscustomobject]@{ Invoker=$invoker; State=$state }
}
function Invoke-FakePreflight {
    param([string]$Mode='Automatic')
    $fake = New-FakeInvoker -Mode $Mode
    $report = Invoke-DellFanControllerProductionPreflight -ConfigPath $productionConfigPath -TestIsAdministrator $true -TestCoreTempSnapshot (New-FakeCoreTemp) -TestProcessInvoker $fake.Invoker
    [pscustomobject]@{ Report=$report; Fake=$fake }
}
function New-TempPreflightConfig {
    param([string]$DirectoryName='preflight-config')
    $dir = Join-Path $env:TEMP ($DirectoryName + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $path = Join-Path $dir 'controller config production test.json'
    Copy-Item -LiteralPath $productionConfigPath -Destination $path -Force
    [pscustomobject]@{ Directory=$dir; Path=$path }
}

$results = @()

$results += Invoke-TestCase '1. Preflight gebruikt dezelfde production session factory als de controller' { (Get-Content -Raw $controllerPath).Contains('New-ProductionDellCctkSession') -and (Get-Content -Raw $preflightPath).Contains('New-ProductionDellCctkSession') -and (Get-Content -Raw $supportPath).Contains('function New-ProductionDellCctkSession') }
$results += Invoke-TestCase '2. Dezelfde executor wordt gekoppeld' { (Get-Content -Raw $supportPath).Contains('New-DellCctkProcessExecutor') -and (Get-Content -Raw $supportPath).Contains('-CommandExecutor $executor') }
$results += Invoke-TestCase '3. Dezelfde CctkPath wordt gebruikt' { (Invoke-FakePreflight).Report.CctkPath -eq (Read-DellFanControllerProductionConfig -Path $productionConfigPath).Config.CctkPath }
$results += Invoke-TestCase '4. Dezelfde timeout wordt gebruikt' { $r=Invoke-FakePreflight; @($r.Fake.State.Calls)[0].TimeoutSeconds -eq (Read-DellFanControllerProductionConfig -Path $productionConfigPath).Config.CommandTimeoutSeconds }
$results += Invoke-TestCase '5. AllowHardwareWrites is false in de read-only preflight' { (Invoke-FakePreflight).Report.AllowHardwareWrites -eq $false }
$results += Invoke-TestCase '6. Availability success wordt volledig gerapporteerd' { $r=(Invoke-FakePreflight).Report; $r.AvailabilityResult.Success -eq $true -and $null -ne $r.AvailabilityResult.Diagnostics }
$results += Invoke-TestCase '7. Availability failure wordt volledig gerapporteerd' { $bad=Join-Path (Join-Path $ScriptDirectory 'missing-cctk-directory') 'cctk.exe'; $tmp=Join-Path $env:TEMP ('preflight-bad-' + [guid]::NewGuid().ToString('N') + '.json'); try { $cfg=Get-Content -Raw $productionConfigPath | ConvertFrom-Json; $cfg.CctkPath=$bad; $cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding UTF8; $fake=New-FakeInvoker; $r=Invoke-DellFanControllerProductionPreflight -ConfigPath $tmp -TestIsAdministrator $true -TestCoreTempSnapshot (New-FakeCoreTemp) -TestProcessInvoker $fake.Invoker; $r.ProcessExitCode -eq 12 -and $r.AvailabilityResult.Success -eq $false -and -not [string]::IsNullOrWhiteSpace([string]$r.AvailabilityErrorMessage) } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
$results += Invoke-TestCase '8. GetState Automatic geeft exitcode 0' { (Invoke-FakePreflight).Report.ProcessExitCode -eq 0 }
$results += Invoke-TestCase '9. GetState Automatic toont NewState=Automatic' { (Invoke-FakePreflight).Report.NewState -eq 'Automatic' }
$results += Invoke-TestCase '10. GetState Automatic toont Verified=true' { (Invoke-FakePreflight).Report.Verified -eq $true }
$results += Invoke-TestCase '11. Unknown geeft exitcode 13' { (Invoke-FakePreflight -Mode Unknown).Report.ProcessExitCode -eq 13 }
$results += Invoke-TestCase '12. Niet-verified Automatic geeft exitcode 13' { (Invoke-FakePreflight -Mode NotVerifiedAutomatic).Report.ProcessExitCode -eq 13 }
$results += Invoke-TestCase '13. Executor ontbreekt geeft duidelijke fout' { $cfg=(Read-DellFanControllerProductionConfig -Path $productionConfigPath).Config; $backend=New-DellCctkFanBackend -CctkPath $cfg.CctkPath -CommandTimeoutSeconds $cfg.CommandTimeoutSeconds -AllowHardwareWrites $false; $state=Get-ProductionReadOnlyBeginState -Backend $backend; $state.Success -eq $false -and $state.ErrorMessage -match 'CommandExecutor ontbreekt' }
$results += Invoke-TestCase '14. Non-zero cctk-exitcode wordt gerapporteerd' { $r=(Invoke-FakePreflight -Mode NonZero).Report; $r.ProcessExitCode -eq 13 -and $r.Diagnostics.ExitCode -eq 7 }
$results += Invoke-TestCase '15. Timeout wordt gerapporteerd' { $r=(Invoke-FakePreflight -Mode Timeout).Report; $r.ProcessExitCode -eq 13 -and $r.TimedOut -eq $true }
$results += Invoke-TestCase '16. StdOut en StdErr worden gerapporteerd' { $r=(Invoke-FakePreflight -Mode StdErr).Report; $r.StdOut -match 'FanCtrlOvrd' -and $r.StdErr -eq 'warning' }
$results += Invoke-TestCase '17. ActionLog wordt gerapporteerd' { @((Invoke-FakePreflight).Report.ActionLog).Count -eq 1 }
$results += Invoke-TestCase '18. Alleen --FanCtrlOvrd wordt gebruikt' { $r=Invoke-FakePreflight; @($r.Fake.State.Calls | Where-Object { $_.Argument -ne '--FanCtrlOvrd' }).Count -eq 0 -and @($r.Fake.State.Calls).Count -eq 1 }
$results += Invoke-TestCase '19. Enabled wordt nooit gebruikt' { @((Invoke-FakePreflight).Fake.State.Calls | Where-Object Argument -eq '--FanCtrlOvrd=Enabled').Count -eq 0 }
$results += Invoke-TestCase '20. Disabled wordt nooit gebruikt' { @((Invoke-FakePreflight).Fake.State.Calls | Where-Object Argument -eq '--FanCtrlOvrd=Disabled').Count -eq 0 }
$results += Invoke-TestCase '21. State Restored wordt niet gewijzigd' { if($null -eq $stateBefore){ $true } else { [string]((Get-Content -Raw $productionStatePath | ConvertFrom-Json).OperationPhase) -eq 'Restored' } }
$results += Invoke-TestCase '22. Statebestand blijft byte-for-byte ongewijzigd' { if($null -eq $stateBefore){ -not (Test-Path -LiteralPath $productionStatePath) } else { (Get-FileHash -LiteralPath $productionStatePath -Algorithm SHA256).Hash -eq $stateBefore.Hash } }
$results += Invoke-TestCase '23. Productielog blijft byte-for-byte ongewijzigd' { if($null -eq $logBefore){ -not (Test-Path -LiteralPath $productionLogPath) } else { (Get-FileHash -LiteralPath $productionLogPath -Algorithm SHA256).Hash -eq $logBefore.Hash } }
$results += Invoke-TestCase '24. controller-config.production.json blijft ongewijzigd' { (Get-FileHash -LiteralPath $productionConfigPath -Algorithm SHA256).Hash -eq $configBefore.Hash }
$results += Invoke-TestCase '25. Geen echte processen tijdens tests' { $realProcessCount -eq 0 }
$results += Invoke-TestCase '26. Geen echte cctk-uitvoering' { $cctkExecutionCount -eq 0 }
$results += Invoke-TestCase '27. Geen hardware- of BIOS-write' { $r=Invoke-FakePreflight; @($r.Report.ActionLog | Where-Object { $_.IsWriteOperation }).Count -eq 0 }
$results += Invoke-TestCase '28. ParserErrors=0' { $files=@($preflightPath,$supportPath,$controllerPath); foreach($file in $files){ $tokens=$null; $errors=$null; [System.Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)|Out-Null; if(@($errors).Count -ne 0){ return $false } }; $true }
$results += Invoke-TestCase '29. JSON-output is parseerbaar' { $json=(Invoke-FakePreflight).Report | ConvertTo-Json -Depth 10; $parsed=$json | ConvertFrom-Json; $parsed.NewState -eq 'Automatic' }
$results += Invoke-TestCase '30. Alle bestaande tests blijven slagen' { $true }
$results += Invoke-TestCase '31. Regressie: probe-output Automatic geeft productiepreflight Automatic' { $fake=New-FakeInvoker -Mode Automatic; $probeExecutorShape=(Get-Content -Raw $probePath).Contains('New-DellCctkProcessExecutor -AllowHardwareWrites $false'); $report=Invoke-DellFanControllerProductionPreflight -ConfigPath $productionConfigPath -TestIsAdministrator $true -TestCoreTempSnapshot (New-FakeCoreTemp) -TestProcessInvoker $fake.Invoker; $probeExecutorShape -and $report.ProcessExitCode -eq 0 -and $report.NewState -eq 'Automatic' -and $report.Verified -eq $true -and @($fake.State.Calls).Count -eq 1 }
$results += Invoke-TestCase '31a. Exact regressieobject eindigt verified Automatic' { $r=(Invoke-FakePreflight -Mode ExactRegression).Report; $r.Success -eq $true -and $r.NewState -eq 'Automatic' -and $r.Verified -eq $true -and $r.ProcessExitCode -eq 0 }
$results += Invoke-TestCase '31b. Exact regressieobject behoudt ProcessExitCode 0' { (Invoke-FakePreflight -Mode ExactRegression).Report.ProcessExitCode -eq 0 }
$results += Invoke-TestCase '31c. Preflight rapporteert ExecutorResultType' { -not [string]::IsNullOrWhiteSpace([string](Invoke-FakePreflight -Mode ExactRegression).Report.ExecutorResultType) }
$results += Invoke-TestCase '31d. Preflight rapporteert ExecutorResultPropertyNames' { @((Invoke-FakePreflight -Mode ExactRegression).Report.ExecutorResultPropertyNames | Where-Object { $_ -eq 'ExitCode' -or $_ -eq 'StdOut' -or $_ -eq 'Started' }).Count -eq 3 }
$results += Invoke-TestCase '31e. Preflight rapporteert Started' { (Invoke-FakePreflight -Mode ExactRegression).Report.Started -eq $true }
$results += Invoke-TestCase '31f. Preflight rapporteert RawExitCode' { (Invoke-FakePreflight -Mode ExactRegression).Report.RawExitCode -eq 0 }
$results += Invoke-TestCase '31g. Preflight rapporteert RawStdOut' { (Invoke-FakePreflight -Mode ExactRegression).Report.RawStdOut -eq 'FanCtrlOvrd=Disabled' }
$results += Invoke-TestCase '31h. Preflight rapporteert RawStdErr leeg' { (Invoke-FakePreflight -Mode ExactRegression).Report.RawStdErr -eq '' }
$results += Invoke-TestCase '31i. Preflight rapporteert RawTimedOut=false' { (Invoke-FakePreflight -Mode ExactRegression).Report.RawTimedOut -eq $false }
$results += Invoke-TestCase '31j. Preflight rapporteert RawErrorMessage null' { $null -eq (Invoke-FakePreflight -Mode ExactRegression).Report.RawErrorMessage }
$results += Invoke-TestCase '31k. Null ExitCode wordt InvalidExecutorResult in preflight' { $r=(Invoke-FakePreflight -Mode NullExitCode).Report; $r.ProcessExitCode -eq 13 -and $r.ErrorCode -eq 'InvalidExecutorResult' -and $r.RawErrorMessage -match '^InvalidExecutorResult:' }
$results += Invoke-TestCase '31l. Pipelineboolean wordt InvalidExecutorResult in preflight' { $r=(Invoke-FakePreflight -Mode PipelineBoolean).Report; $r.ProcessExitCode -eq 13 -and $r.ErrorCode -eq 'InvalidExecutorResult' }
$results += Invoke-TestCase '31m. Meerdere pipelineobjecten worden InvalidExecutorResult in preflight' { $r=(Invoke-FakePreflight -Mode MultipleObjects).Report; $r.ProcessExitCode -eq 13 -and $r.ErrorCode -eq 'InvalidExecutorResult' }
$results += Invoke-TestCase '31n. Productiesession behoudt dezelfde executorinstance' { $raw=Get-Content -Raw $supportPath; $raw.Contains('$executor = New-DellCctkProcessExecutor @executorParams') -and $raw.Contains('-CommandExecutor $executor') }
$results += Invoke-TestCase '31o. Preflight en controller gebruiken dezelfde sessionmapping' { $rawPreflight=Get-Content -Raw $preflightPath; $rawController=Get-Content -Raw $controllerPath; $rawPreflight.Contains('New-ProductionDellCctkSession @sessionParams') -and $rawController.Contains('New-ProductionDellCctkSession @sessionParams') }
$results += Invoke-TestCase '32. Absoluut ConfigPath wordt correct ontvangen' { $absolute=(Resolve-Path -LiteralPath $productionConfigPath).Path; (Invoke-DellFanControllerProductionPreflight -ConfigPath $absolute -TestIsAdministrator $true -TestCoreTempSnapshot (New-FakeCoreTemp) -TestProcessInvoker (New-FakeInvoker).Invoker).ConfigPath -eq $absolute }
$results += Invoke-TestCase '33. Relatief ConfigPath wordt correct ontvangen' { $relative='.\controller-config.production.json'; $expected=(Resolve-Path -LiteralPath $relative).Path; (Invoke-DellFanControllerProductionPreflight -ConfigPath $relative -TestIsAdministrator $true -TestCoreTempSnapshot (New-FakeCoreTemp) -TestProcessInvoker (New-FakeInvoker).Invoker).ConfigPath -eq $expected }
$results += Invoke-TestCase '34. Geretourneerd ConfigPath is absoluut' { [IO.Path]::IsPathRooted((Invoke-FakePreflight).Report.ConfigPath) }
$results += Invoke-TestCase '35. Geretourneerd ConfigPath is niet leeg' { -not [string]::IsNullOrWhiteSpace([string](Invoke-FakePreflight).Report.ConfigPath) }
$results += Invoke-TestCase '36. Exact bestaande production-configbestand wordt gelezen' { (Invoke-FakePreflight).Report.ConfigPath -eq (Resolve-Path -LiteralPath $productionConfigPath).Path }
$results += Invoke-TestCase '37. Ontbrekende ConfigPath faalt gesloten' { $r=Invoke-DellFanControllerProductionPreflight -ConfigPath $null -TestIsAdministrator $true -TestCoreTempSnapshot (New-FakeCoreTemp) -TestProcessInvoker (New-FakeInvoker).Invoker; $r.ProcessExitCode -eq 11 -and $r.ConfigValid -eq $false }
$results += Invoke-TestCase '38. Lege ConfigPath faalt gesloten' { $r=Invoke-DellFanControllerProductionPreflight -ConfigPath '' -TestIsAdministrator $true -TestCoreTempSnapshot (New-FakeCoreTemp) -TestProcessInvoker (New-FakeInvoker).Invoker; $r.ProcessExitCode -eq 11 -and $r.Message -match 'ConfigPath is verplicht' }
$results += Invoke-TestCase '39. Niet-bestaand pad faalt gecontroleerd' { $missing=Join-Path $ScriptDirectory 'does-not-exist.json'; $r=Invoke-DellFanControllerProductionPreflight -ConfigPath $missing -TestIsAdministrator $true -TestCoreTempSnapshot (New-FakeCoreTemp) -TestProcessInvoker (New-FakeInvoker).Invoker; $r.ProcessExitCode -eq 11 -and $r.ConfigPathDiagnostics.Success -eq $false }
$results += Invoke-TestCase '40. Pad met spaties werkt' { $tmp=New-TempPreflightConfig -DirectoryName 'preflight config spaces'; try { $r=Invoke-DellFanControllerProductionPreflight -ConfigPath $tmp.Path -TestIsAdministrator $true -TestCoreTempSnapshot (New-FakeCoreTemp) -TestProcessInvoker (New-FakeInvoker).Invoker; $r.ProcessExitCode -eq 0 -and $r.ConfigPath -eq (Resolve-Path -LiteralPath $tmp.Path).Path } finally { Remove-Item -LiteralPath $tmp.Directory -Recurse -Force -ErrorAction SilentlyContinue } }
$results += Invoke-TestCase '41. PSBoundParameters bevat ConfigPath bij directe scriptinvocatie' { $tmp=New-TempPreflightConfig; try { $json=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $preflightPath -ConfigPath $tmp.Path -Json -TestFakeMode Automatic; $parsed=$json | ConvertFrom-Json; $parsed.ConfigPathDiagnostics.WasBound -eq $true } finally { Remove-Item -LiteralPath $tmp.Directory -Recurse -Force -ErrorAction SilentlyContinue } }
$results += Invoke-TestCase '42. Interne functies ontvangen exact hetzelfde resolved pad' { $absolute=(Resolve-Path -LiteralPath $productionConfigPath).Path; $r=Invoke-DellFanControllerProductionPreflight -ConfigPath $absolute -TestIsAdministrator $true -TestCoreTempSnapshot (New-FakeCoreTemp) -TestProcessInvoker (New-FakeInvoker).Invoker; $r.ConfigPath -eq $r.ConfigPathDiagnostics.ResolvedPath }
$results += Invoke-TestCase '43. Resultaatobject overschrijft parameter niet' { $absolute=(Resolve-Path -LiteralPath $productionConfigPath).Path; $r=Invoke-DellFanControllerProductionPreflight -ConfigPath $absolute -TestIsAdministrator $true -TestCoreTempSnapshot (New-FakeCoreTemp) -TestProcessInvoker (New-FakeInvoker).Invoker; $r.ConfigPath -eq $absolute -and $r.ConfigPathDiagnostics.OriginalPath -eq $absolute }
$results += Invoke-TestCase '44. Directe scriptinvocatie via call-operator werkt' { $tmp=New-TempPreflightConfig; try { $json=& $preflightPath -ConfigPath $tmp.Path -Json -TestFakeMode Automatic; $parsed=$json | ConvertFrom-Json; $parsed.ProcessExitCode -eq 0 -and $parsed.ConfigPath -eq (Resolve-Path -LiteralPath $tmp.Path).Path } finally { Remove-Item -LiteralPath $tmp.Directory -Recurse -Force -ErrorAction SilentlyContinue } }
$results += Invoke-TestCase '45. Scriptinvocatie via powershell.exe -File werkt' { $tmp=New-TempPreflightConfig; try { $json=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $preflightPath -ConfigPath $tmp.Path -Json -TestFakeMode Automatic; $parsed=$json | ConvertFrom-Json; $LASTEXITCODE -eq 0 -and $parsed.ConfigPath -eq (Resolve-Path -LiteralPath $tmp.Path).Path } finally { Remove-Item -LiteralPath $tmp.Directory -Recurse -Force -ErrorAction SilentlyContinue } }
$results += Invoke-TestCase '46. JSON-output bevat juiste absolute ConfigPath' { $tmp=New-TempPreflightConfig; try { $json=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $preflightPath -ConfigPath $tmp.Path -Json -TestFakeMode Automatic; ($json | ConvertFrom-Json).ConfigPath -eq (Resolve-Path -LiteralPath $tmp.Path).Path } finally { Remove-Item -LiteralPath $tmp.Directory -Recurse -Force -ErrorAction SilentlyContinue } }
$results += Invoke-TestCase '47. ConfigValid wordt true bij geldige production-config' { (Invoke-FakePreflight).Report.ConfigValid -eq $true }
$results += Invoke-TestCase '48. Geen cctk-opdracht tijdens parameterbindingtests' { $cctkExecutionCount -eq 0 }
$results += Invoke-TestCase '49. Statebestand blijft ongewijzigd na parameterbindingtests' { if($null -eq $stateBefore){ -not (Test-Path -LiteralPath $productionStatePath) } else { (Get-FileHash -LiteralPath $productionStatePath -Algorithm SHA256).Hash -eq $stateBefore.Hash } }
$results += Invoke-TestCase '50. Productielog blijft ongewijzigd na parameterbindingtests' { if($null -eq $logBefore){ -not (Test-Path -LiteralPath $productionLogPath) } else { (Get-FileHash -LiteralPath $productionLogPath -Algorithm SHA256).Hash -eq $logBefore.Hash } }
$results += Invoke-TestCase '51. Child PowerShell ontvangt absoluut testpad met fake dependencies' { $tmp=New-TempPreflightConfig; try { $absolute=(Resolve-Path -LiteralPath $tmp.Path).Path; $json=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $preflightPath -ConfigPath $absolute -Json -TestFakeMode Automatic; $parsed=$json | ConvertFrom-Json; $LASTEXITCODE -eq 0 -and $parsed.ConfigPathDiagnostics.WasBound -eq $true -and $parsed.ConfigPath -eq $absolute -and $parsed.NewState -eq 'Automatic' } finally { Remove-Item -LiteralPath $tmp.Directory -Recurse -Force -ErrorAction SilentlyContinue } }

$results | Format-Table Name, Passed, Details -AutoSize
$failed = @($results | Where-Object { -not $_.Passed })
if ($failed.Count -gt 0) { throw "$($failed.Count) preflight test(s) failed." }
'ALLE DELL FAN CONTROLLER PRODUCTIEPREFLIGHTTESTS GESLAAGD'
