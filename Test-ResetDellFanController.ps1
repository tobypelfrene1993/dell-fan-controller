[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$resetScript = Join-Path $ScriptDirectory 'Reset-DellFanController.ps1'
$configPath = Join-Path $ScriptDirectory 'controller-config.json'
$dryRunPath = Join-Path $ScriptDirectory 'DellFanController-DryRun.ps1'
$stateModulePath = Join-Path $ScriptDirectory 'DellFanController-State.ps1'
$contractPath = Join-Path $ScriptDirectory 'FanBackend.Contract.ps1'
$mockPath = Join-Path $ScriptDirectory 'FanBackend.Mock.ps1'
$runtimeLogPath = Join-Path (Join-Path $ScriptDirectory 'logs') 'dell-fan-dryrun.csv'
$testRoot = Join-Path $ScriptDirectory ("test-output\reset-tool-{0}" -f ([guid]::NewGuid().ToString('N')))

$configBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath))
$dryRunBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($dryRunPath))
$stateModuleBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($stateModulePath))
$contractBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($contractPath))
$mockBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($mockPath))
$runtimeLogBefore = if (Test-Path -LiteralPath $runtimeLogPath -PathType Leaf) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($runtimeLogPath)) } else { $null }

. $resetScript

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
function New-TestStatePath { param([string]$Directory) Join-Path $Directory 'state.json' }
function New-TestBackendState {
    param([string]$Phase='Idle',[bool]$Owned=$false,[string]$BackendName='MockFanBackend',[string]$ControllerInstanceId,[string]$CorrelationId)
    if ([string]::IsNullOrWhiteSpace($ControllerInstanceId)) { $ControllerInstanceId = ([guid]::NewGuid()).ToString() }
    if ([string]::IsNullOrWhiteSpace($CorrelationId)) { $CorrelationId = ([guid]::NewGuid()).ToString() }
    $state = [pscustomobject]@{
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
    $state
}
function Write-TestState {
    param([string]$Path,[object]$State)
    [void](Write-ControllerStateAtomic -Path $Path -State $State)
    $Path
}
function Invoke-TestReset {
    param(
        [string]$Phase,
        [bool]$Owned=$false,
        [object]$Backend,
        [string]$FailureMode='None',
        [switch]$NoMock,
        [switch]$ForceIfOwned,
        [switch]$Clear,
        [string]$BackendName='MockFanBackend',
        [string]$ControllerInstanceId,
        [string]$CorrelationId,
        [switch]$NoState
    )
    $dir = New-TestDirectory
    $path = New-TestStatePath -Directory $dir
    if (-not $NoState) {
        $state = New-TestBackendState -Phase $Phase -Owned $Owned -BackendName $BackendName -ControllerInstanceId $ControllerInstanceId -CorrelationId $CorrelationId
        [void](Write-TestState -Path $path -State $state)
    }
    if ($null -eq $Backend) { $Backend = New-MockFanBackend -FailureMode $FailureMode }
    $result = Invoke-DellFanControllerReset -StatePath $path -UseMockBackend (-not [bool]$NoMock) -MockFailureMode $FailureMode -ForceIfOwned ([bool]$ForceIfOwned) -ClearStateAfterVerifiedRestore ([bool]$Clear) -Reason 'TestRecovery' -Backend $Backend
    [pscustomobject]@{ Directory=$dir; StatePath=$path; Backend=$Backend; Result=$result; StateRead=$(if(Test-Path -LiteralPath $path){Read-ControllerState -Path $path}else{$null}) }
}
function Test-NoForbiddenAst {
    param([string[]]$Paths)
    $blockedCommands=@('Start-Process','Invoke-Expression','cctk','cctk.exe','Set-CimInstance','Invoke-CimMethod','Set-WmiInstance','Register-ScheduledTask','New-Service','Set-Service','Install-Module')
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
$results=@()

try {
    $results += Invoke-TestCase '1. Zonder UseMockBackend wordt uitvoering geweigerd' { (Invoke-TestReset -NoState -NoMock).Result.ExitCode -eq 10 }
    $results += Invoke-TestCase '2. Zonder state en backup geeft NoStateFound' { (Invoke-TestReset -NoState).Result.Result -eq 'NoStateFound' }
    $results += Invoke-TestCase '3. NoStateFound eindigt exitcode 0' { (Invoke-TestReset -NoState).Result.ExitCode -eq 0 }
    $results += Invoke-TestCase '4. Idle geeft NoActionRequired' { (Invoke-TestReset -Phase Idle).Result.Result -eq 'NoActionRequired' }
    $results += Invoke-TestCase '5. Idle voert geen restore uit' { $r=Invoke-TestReset -Phase Idle; $r.Backend.RuntimeState.RestoreCallCount -eq 0 }
    $results += Invoke-TestCase '6. Restored geeft AlreadyRestored' { (Invoke-TestReset -Phase Restored).Result.Result -eq 'AlreadyRestored' }
    $results += Invoke-TestCase '7. Restored voert geen onnodige restore uit' { $r=Invoke-TestReset -Phase Restored; $r.Backend.RuntimeState.RestoreCallCount -eq 0 }
    $results += Invoke-TestCase '8. ActiveVerified veroorzaakt restore' { $r=Invoke-TestReset -Phase ActiveVerified; $r.Result.RestoreAttempted -and $r.Backend.RuntimeState.RestoreCallCount -eq 1 }
    $results += Invoke-TestCase '9. ActiveVerified eindigt Restored' { (Invoke-TestReset -Phase ActiveVerified).StateRead.State.OperationPhase -eq 'Restored' }
    $results += Invoke-TestCase '10. ActiveVerified eindigt backend Automatic' { (Invoke-TestReset -Phase ActiveVerified).Backend.RuntimeState.CurrentFanState -eq 'Automatic' }
    $results += Invoke-TestCase '11. Restore gebruikt bewezen ownership' { (Invoke-TestReset -Phase ActiveVerified).Result.OwnershipProven }
    $results += Invoke-TestCase '12. DisablePending voltooit restore' { (Invoke-TestReset -Phase DisablePending).StateRead.State.OperationPhase -eq 'Restored' }
    $results += Invoke-TestCase '13. CleanupRequired met ownership gebruikt emergency reset' { $r=Invoke-TestReset -Phase CleanupRequired -Owned $true -ForceIfOwned; $r.Result.EmergencyResetAttempted }
    $results += Invoke-TestCase '14. CleanupRequired zonder ownership wordt geweigerd' { (Invoke-TestReset -Phase CleanupRequired).Result.ExitCode -eq 20 }
    $results += Invoke-TestCase '15. ForceIfOwned verzint geen ownership' { (Invoke-TestReset -Phase CleanupRequired -ForceIfOwned).Result.ExitCode -eq 20 }
    $results += Invoke-TestCase '16. EnablePending plus BoostEnabled veroorzaakt restore' { $b=New-MockFanBackend -InitialState BoostEnabled; $r=Invoke-TestReset -Phase EnablePending -Backend $b; $r.Result.RestoreAttempted }
    $results += Invoke-TestCase '17. EnablePending plus Automatic wordt Restored' { (Invoke-TestReset -Phase EnablePending).StateRead.State.OperationPhase -eq 'Restored' }
    $results += Invoke-TestCase '18. EnablePending plus Unknown faalt gesloten' { $b=New-MockFanBackend -InitialState Unknown; (Invoke-TestReset -Phase EnablePending -Backend $b).Result.ExitCode -eq 21 }
    $results += Invoke-TestCase '19. Corrupt actief plus geldige backup gebruikt backup' { $d=New-TestDirectory;$p=New-TestStatePath $d;$s=New-TestBackendState -Phase Restored;[void](Write-TestState $p $s);Copy-Item -LiteralPath $p -Destination "$p.bak" -Force;Set-Content -LiteralPath $p -Value '{bad' -Encoding UTF8;$r=Invoke-DellFanControllerReset -StatePath $p -UseMockBackend $true -Backend (New-MockFanBackend);$r.StateSource -eq 'Backup' }
    $results += Invoke-TestCase '20. Corrupt actief plus corrupte backup faalt gesloten' { $d=New-TestDirectory;$p=New-TestStatePath $d;Set-Content -LiteralPath $p -Value '{bad' -Encoding UTF8;Set-Content -LiteralPath "$p.bak" -Value '{bad' -Encoding UTF8;(Invoke-DellFanControllerReset -StatePath $p -UseMockBackend $true -Backend (New-MockFanBackend)).ExitCode -eq 11 }
    $results += Invoke-TestCase '21. Corrupt state wordt niet overschreven' { $d=New-TestDirectory;$p=New-TestStatePath $d;Set-Content -LiteralPath $p -Value '{bad' -Encoding UTF8;[void](Invoke-DellFanControllerReset -StatePath $p -UseMockBackend $true -Backend (New-MockFanBackend));(Get-Content -Raw $p) -eq "{bad`r`n" -or (Get-Content -Raw $p) -eq "{bad`n" }
    $results += Invoke-TestCase '22. Ontbrekende verplichte property faalt gesloten' { $d=New-TestDirectory;$p=New-TestStatePath $d;$s=New-TestBackendState -Phase Idle;$s.PSObject.Properties.Remove('BackendName');Set-Content -LiteralPath $p -Value ($s|ConvertTo-Json -Depth 6) -Encoding UTF8;(Invoke-DellFanControllerReset -StatePath $p -UseMockBackend $true -Backend (New-MockFanBackend)).ExitCode -eq 11 }
    $results += Invoke-TestCase '23. Verkeerde BackendName blokkeert ownership' { (Invoke-TestReset -Phase ActiveVerified -BackendName OtherBackend).Result.ExitCode -eq 20 }
    $results += Invoke-TestCase '24. Ongeldige ControllerInstanceId blokkeert ownership' { $d=New-TestDirectory;$p=New-TestStatePath $d;$s=New-TestBackendState -Phase ActiveVerified;$s.ControllerInstanceId='bad-guid';Set-Content -LiteralPath $p -Value ($s|ConvertTo-Json -Depth 6) -Encoding UTF8;(Invoke-DellFanControllerReset -StatePath $p -UseMockBackend $true -Backend (New-MockFanBackend)).ExitCode -eq 11 }
    $results += Invoke-TestCase '25. Ongeldige CorrelationId blokkeert ownership' { $d=New-TestDirectory;$p=New-TestStatePath $d;$s=New-TestBackendState -Phase ActiveVerified;$s.CorrelationId='bad-guid';Set-Content -LiteralPath $p -Value ($s|ConvertTo-Json -Depth 6) -Encoding UTF8;(Invoke-DellFanControllerReset -StatePath $p -UseMockBackend $true -Backend (New-MockFanBackend)).ExitCode -eq 11 }
    $results += Invoke-TestCase '26. ThrowOnRestore geeft non-zero resultaat' { (Invoke-TestReset -Phase ActiveVerified -FailureMode ThrowOnRestore).Result.ExitCode -ne 0 }
    $results += Invoke-TestCase '27. ThrowOnRestore behoudt CleanupRequired' { (Invoke-TestReset -Phase ActiveVerified -FailureMode ThrowOnRestore).StateRead.State.OperationPhase -eq 'CleanupRequired' }
    $results += Invoke-TestCase '28. RestoreVerificationFails behoudt emergency flag' { (Invoke-TestReset -Phase ActiveVerified -FailureMode RestoreVerificationFails).StateRead.State.RequiresEmergencyReset }
    $results += Invoke-TestCase '29. ReturnUnknownAfterRestore faalt verificatie' { (Invoke-TestReset -Phase ActiveVerified -FailureMode ReturnUnknownAfterRestore).Result.ExitCode -ne 0 }
    $results += Invoke-TestCase '30. Backend Unavailable faalt veilig' { (Invoke-TestReset -Phase ActiveVerified -FailureMode Unavailable).Result.ExitCode -eq 12 }
    $results += Invoke-TestCase '31. ThrowOnAvailability wordt afgevangen' { (Invoke-TestReset -Phase ActiveVerified -FailureMode ThrowOnAvailability).Result.ExitCode -eq 12 }
    $results += Invoke-TestCase '32. ThrowOnGetState wordt afgevangen' { (Invoke-TestReset -Phase ActiveVerified -FailureMode ThrowOnGetState).Result.ExitCode -ne 0 }
    $results += Invoke-TestCase '33. Herhaalde reset na succes is idempotent' { $r=Invoke-TestReset -Phase ActiveVerified; (Invoke-DellFanControllerReset -StatePath $r.StatePath -UseMockBackend $true -Backend $r.Backend).Result -eq 'AlreadyRestored' }
    $results += Invoke-TestCase '34. Tweede reset voert geen extra effectieve restore uit' { $r=Invoke-TestReset -Phase ActiveVerified; $before=$r.Backend.RuntimeState.RestoreCallCount; [void](Invoke-DellFanControllerReset -StatePath $r.StatePath -UseMockBackend $true -Backend $r.Backend); $r.Backend.RuntimeState.RestoreCallCount -eq $before }
    $results += Invoke-TestCase '35. Clear zonder Restored wordt geweigerd' { (Invoke-TestReset -Phase Idle -Clear).Result.ExitCode -eq 40 }
    $results += Invoke-TestCase '36. Clear na verified Restored werkt' { $r=Invoke-TestReset -Phase Restored -Clear; $r.Result.StateCleared -and -not (Test-Path -LiteralPath $r.StatePath) }
    $results += Invoke-TestCase '37. Clear verwijdert geen onveilige state' { $r=Invoke-TestReset -Phase CleanupRequired -Clear; Test-Path -LiteralPath $r.StatePath }
    $results += Invoke-TestCase '38. Zonder ClearStateAfterVerifiedRestore blijft Restored state bestaan' { $r=Invoke-TestReset -Phase ActiveVerified; Test-Path -LiteralPath $r.StatePath }
    $results += Invoke-TestCase '39. JSON-output is parseerbaar' { $json=(Invoke-TestReset -Phase Idle).Result | ConvertTo-Json -Depth 6; $null -ne ($json | ConvertFrom-Json) }
    $results += Invoke-TestCase '40. JSON-output bevat alle verplichte velden' { $o=((Invoke-TestReset -Phase Idle).Result | ConvertTo-Json -Depth 6 | ConvertFrom-Json); @('StatePath','StateFound','StateSource','RecoveryAction','OwnershipProven','BackendName','BackendStateBefore','RestoreAttempted','EmergencyResetAttempted','BackendStateAfter','VerifiedAutomatic','OperationPhaseBefore','OperationPhaseAfter','RequiresEmergencyReset','StateCleared','Result','ExitCode') | ForEach-Object { if($o.PSObject.Properties.Name -notcontains $_){ throw $_ } }; $true }
    $results += Invoke-TestCase '41. Normale console-output bevat status en resultaat' { $text=(& { Write-ResetConsoleResult -Result (Invoke-TestReset -Phase Idle).Result } 6>&1 | Out-String); $text -match 'StatePath' -and $text -match 'Resultaat' }
    $results += Invoke-TestCase '42. Exitcode 0 bij succesvol herstel' { (Invoke-TestReset -Phase ActiveVerified).Result.ExitCode -eq 0 }
    $results += Invoke-TestCase '43. Exitcode non-zero bij restore failure' { (Invoke-TestReset -Phase ActiveVerified -FailureMode ThrowOnRestore).Result.ExitCode -ne 0 }
    $results += Invoke-TestCase '44. Backup blijft geldig na stateovergangen' { $r=Invoke-TestReset -Phase ActiveVerified; (Read-ControllerState -Path ($r.StatePath+'.missing') -BackupPath ($r.StatePath+'.bak')).Success }
    $results += Invoke-TestCase '45. Geen gedeeltelijk JSON-bestand ontstaat' { $r=Invoke-TestReset -Phase ActiveVerified; @((Get-ChildItem -LiteralPath $r.Directory -File -Filter '*.tmp')).Count -eq 0 }
    $results += Invoke-TestCase '46. Geen tijdelijke statebestanden blijven achter' { @((Get-ChildItem -LiteralPath $testRoot -Recurse -File -Filter '*.tmp')).Count -eq 0 }
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

$results += Invoke-TestCase '47. Testdirectory wordt verwijderd' { -not (Test-Path -LiteralPath $testRoot) }
$results += Invoke-TestCase '48. Geen bestanden in projectroot aangemaakt' { @((Get-ChildItem -LiteralPath $ScriptDirectory -File -Filter 'state.json')).Count -eq 0 }
$results += Invoke-TestCase '49. logs\dell-fan-dryrun.csv blijft byte-for-byte ongewijzigd' { if($null -eq $runtimeLogBefore){ -not (Test-Path -LiteralPath $runtimeLogPath) } else { [Convert]::ToBase64String([IO.File]::ReadAllBytes($runtimeLogPath)) -eq $runtimeLogBefore } }
$results += Invoke-TestCase '50. controller-config.json blijft byte-for-byte ongewijzigd' { [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -eq $configBefore }
$results += Invoke-TestCase '51. DellFanController-DryRun.ps1 blijft byte-for-byte ongewijzigd' { [Convert]::ToBase64String([IO.File]::ReadAllBytes($dryRunPath)) -eq $dryRunBefore }
$results += Invoke-TestCase '52. DellFanController-State.ps1 blijft byte-for-byte ongewijzigd' { [Convert]::ToBase64String([IO.File]::ReadAllBytes($stateModulePath)) -eq $stateModuleBefore }
$results += Invoke-TestCase '53. FanBackend.Contract.ps1 blijft byte-for-byte ongewijzigd' { [Convert]::ToBase64String([IO.File]::ReadAllBytes($contractPath)) -eq $contractBefore }
$results += Invoke-TestCase '54. FanBackend.Mock.ps1 blijft byte-for-byte ongewijzigd' { [Convert]::ToBase64String([IO.File]::ReadAllBytes($mockPath)) -eq $mockBefore }
$results += Invoke-TestCase '55. DryRun blijft boolean true' { (Get-Content -Raw $configPath | ConvertFrom-Json).DryRun -eq $true }
$results += Invoke-TestCase '56. Resettool heeft geen parserfouten' { $tokens=$null;$errors=$null;[System.Management.Automation.Language.Parser]::ParseFile($resetScript,[ref]$tokens,[ref]$errors)|Out-Null;$errors.Count -eq 0 }
$results += Invoke-TestCase '57. Testscript heeft geen parserfouten' { $tokens=$null;$errors=$null;[System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors)|Out-Null;$errors.Count -eq 0 }
$results += Invoke-TestCase '58. Geen Start-Process' { Test-NoForbiddenAst @($resetScript,$PSCommandPath) }
$results += Invoke-TestCase '59. Geen System.Diagnostics.Process' { Test-NoForbiddenAst @($resetScript,$PSCommandPath) }
$results += Invoke-TestCase '60. Geen Invoke-Expression' { Test-NoForbiddenAst @($resetScript,$PSCommandPath) }
$results += Invoke-TestCase '61. Geen cctk-referentie in uitvoerbare code' { Test-NoForbiddenAst @($resetScript,$PSCommandPath) }
$results += Invoke-TestCase '62. Geen Dell- of BIOS-writecommando''s' { Test-NoForbiddenAst @($resetScript,$PSCommandPath) }
$results += Invoke-TestCase '63. Geen WMI/CIM-hardwarewrites' { Test-NoForbiddenAst @($resetScript,$PSCommandPath) }
$results += Invoke-TestCase '64. Geen externe executable invocation' { Test-NoForbiddenAst @($resetScript,$PSCommandPath) }
$results += Invoke-TestCase '65. Geen software-installatiecode' { Test-NoForbiddenAst @($resetScript,$PSCommandPath) }
$results += Invoke-TestCase '66. Geen Scheduled Task- of servicecode' { Test-NoForbiddenAst @($resetScript,$PSCommandPath) }

$results | Format-Table Name, Passed, Details -AutoSize
$failed=@($results|Where-Object{ -not $_.Passed })
if($failed.Count -gt 0){ throw "$($failed.Count) test(s) failed." }
'ALLE RESET DELL FAN CONTROLLER TESTS GESLAAGD'
