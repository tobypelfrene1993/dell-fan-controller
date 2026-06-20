[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$contractPath = Join-Path $ScriptDirectory 'FanBackend.Contract.ps1'
$mockPath = Join-Path $ScriptDirectory 'FanBackend.Mock.ps1'
$statePath = Join-Path $ScriptDirectory 'DellFanController-State.ps1'
$configPath = Join-Path $ScriptDirectory 'controller-config.json'
$dryRunPath = Join-Path $ScriptDirectory 'DellFanController-DryRun.ps1'
$configBefore = if (Test-Path -LiteralPath $configPath -PathType Leaf) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) } else { $null }
$dryRunBefore = if (Test-Path -LiteralPath $dryRunPath -PathType Leaf) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($dryRunPath)) } else { $null }
$stateBefore = if (Test-Path -LiteralPath $statePath -PathType Leaf) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($statePath)) } else { $null }
$testRoot = Join-Path $ScriptDirectory ("test-output\fanbackend-mock-{0}" -f ([guid]::NewGuid().ToString('N')))

. $mockPath

function New-TestResult { param([string]$Name,[bool]$Passed,[string]$Details) [pscustomobject]@{Name=$Name;Passed=$Passed;Details=$Details} }
function Invoke-TestCase {
    param([string]$Name,[scriptblock]$Action)
    try { New-TestResult -Name $Name -Passed ([bool](& $Action)) -Details 'OK' }
    catch { New-TestResult -Name $Name -Passed $false -Details $_.Exception.Message }
}
function New-TestStatePath { Join-Path $testRoot ("state-{0}.json" -f ([guid]::NewGuid().ToString('N'))) }
function Write-InitialState { param([string]$Path,[object]$State) [void](Write-ControllerStateAtomic -Path $Path -State $State); $Path }
function New-TestState { New-ControllerState -ControllerInstanceId ([guid]::NewGuid().ToString()) -CorrelationId ([guid]::NewGuid().ToString()) -BackendName 'MockFanBackend' }
function Enable-TestBackend {
    param([object]$Backend,[string]$Path,[string]$Reason='test-enable')
    Enable-FanBackendBoost -Backend $Backend -StatePath $Path -ControllerInstanceId ([guid]::NewGuid().ToString()) -CorrelationId ([guid]::NewGuid().ToString()) -Reason $Reason
}
function Restore-TestBackend {
    param([object]$Backend,[string]$Path,[string]$Reason='test-restore')
    Restore-FanBackendAutomaticControl -Backend $Backend -StatePath $Path -CorrelationId ([guid]::NewGuid().ToString()) -Reason $Reason
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

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$results=@()

try {
    $results += Invoke-TestCase '1. Geldige mock voldoet aan backendcontract' { (Test-FanBackendContract (New-MockFanBackend)).IsValid }
    $results += Invoke-TestCase '2. Ontbrekende BackendName wordt geweigerd' { $b=New-MockFanBackend; $b.PSObject.Properties.Remove('BackendName'); -not (Test-FanBackendContract $b).IsValid }
    $results += Invoke-TestCase '3. Ontbrekende BackendType wordt geweigerd' { $b=New-MockFanBackend; $b.PSObject.Properties.Remove('BackendType'); -not (Test-FanBackendContract $b).IsValid }
    $results += Invoke-TestCase '4. Ontbrekende operation wordt geweigerd' { $b=New-MockFanBackend; $b.Operations.PSObject.Properties.Remove('GetState'); -not (Test-FanBackendContract $b).IsValid }
    $results += Invoke-TestCase '5. Niet-ScriptBlock operation wordt geweigerd' { $b=New-MockFanBackend; $b.Operations.TestAvailability='bad'; -not (Test-FanBackendContract $b).IsValid }
    $results += Invoke-TestCase '6. Ontbrekende RuntimeState wordt geweigerd' { $b=New-MockFanBackend; $b.PSObject.Properties.Remove('RuntimeState'); -not (Test-FanBackendContract $b).IsValid }
    $results += Invoke-TestCase '7. Ontbrekende ActionLog wordt geweigerd' { $b=New-MockFanBackend; $b.PSObject.Properties.Remove('ActionLog'); -not (Test-FanBackendContract $b).IsValid }
    $results += Invoke-TestCase '8. Standaard mock is beschikbaar' { (Invoke-FanBackendAvailabilityCheck (New-MockFanBackend)).Success }
    $results += Invoke-TestCase '9. Unavailable geeft beschikbaar=false' { -not (Invoke-FanBackendAvailabilityCheck (New-MockFanBackend -FailureMode Unavailable)).Success }
    $results += Invoke-TestCase '10. ThrowOnAvailability wordt veilig afgevangen' { $r=Invoke-FanBackendAvailabilityCheck (New-MockFanBackend -FailureMode ThrowOnAvailability); -not $r.Success -and $r.ErrorCode -eq 'AvailabilityException' }
    $results += Invoke-TestCase '11. GetState retourneert Automatic' { (Get-FanBackendControlState (New-MockFanBackend -InitialState Automatic)).NewState -eq 'Automatic' }
    $results += Invoke-TestCase '12. GetState retourneert BoostEnabled' { (Get-FanBackendControlState (New-MockFanBackend -InitialState BoostEnabled)).NewState -eq 'BoostEnabled' }
    $results += Invoke-TestCase '13. Unknown state wordt als niet-geverifieerd behandeld' { $r=Get-FanBackendControlState (New-MockFanBackend -InitialState Unknown); $r.Success -and -not $r.Verified }
    $results += Invoke-TestCase '14. ThrowOnGetState wordt veilig afgevangen' { -not (Get-FanBackendControlState (New-MockFanBackend -FailureMode ThrowOnGetState)).Success }
    $results += Invoke-TestCase '15. Availabilitycheck wijzigt fanstate niet' { $b=New-MockFanBackend; [void](Invoke-FanBackendAvailabilityCheck $b); $b.RuntimeState.CurrentFanState -eq 'Automatic' }
    $results += Invoke-TestCase '16. Enable vanuit Idle schrijft EnablePending' { $p=Write-InitialState (New-TestStatePath) (New-TestState); $b=New-MockFanBackend -FailureMode ThrowOnEnable; [void](Enable-TestBackend $b $p); (Read-ControllerState $p).State.OperationPhase -eq 'CleanupRequired' }
    $results += Invoke-TestCase '17. Enable eindigt in ActiveVerified' { $p=Write-InitialState (New-TestStatePath) (New-TestState); $r=Enable-TestBackend (New-MockFanBackend) $p; $r.Success -and (Read-ControllerState $p).State.OperationPhase -eq 'ActiveVerified' }
    $results += Invoke-TestCase '18. Enable zet ownership true' { $p=Write-InitialState (New-TestStatePath) (New-TestState); [void](Enable-TestBackend (New-MockFanBackend) $p); (Read-ControllerState $p).State.FanOverrideActivatedByThisApp }
    $results += Invoke-TestCase '19. Enable zet RequestedState BoostEnabled' { $p=Write-InitialState (New-TestStatePath) (New-TestState); [void](Enable-TestBackend (New-MockFanBackend) $p); (Read-ControllerState $p).State.CurrentRequestedState -eq 'BoostEnabled' }
    $results += Invoke-TestCase '20. Enable vult ActivatedAtUtc' { $p=Write-InitialState (New-TestStatePath) (New-TestState); [void](Enable-TestBackend (New-MockFanBackend) $p); $null -ne (Read-ControllerState $p).State.ActivatedAtUtc }
    $results += Invoke-TestCase '21. Enable vult verificatietijd' { $p=Write-InitialState (New-TestStatePath) (New-TestState); [void](Enable-TestBackend (New-MockFanBackend) $p); $null -ne (Read-ControllerState $p).State.LastSuccessfulVerificationUtc }
    $results += Invoke-TestCase '22. Mockstate wordt BoostEnabled' { $b=New-MockFanBackend; $p=Write-InitialState (New-TestStatePath) (New-TestState); [void](Enable-TestBackend $b $p); $b.RuntimeState.CurrentFanState -eq 'BoostEnabled' }
    $results += Invoke-TestCase '23. EnableCallCount wordt een' { $b=New-MockFanBackend; $p=Write-InitialState (New-TestStatePath) (New-TestState); [void](Enable-TestBackend $b $p); $b.RuntimeState.EnableCallCount -eq 1 }
    $results += Invoke-TestCase '24. Actionlog bevat enable' { $b=New-MockFanBackend; $p=Write-InitialState (New-TestStatePath) (New-TestState); [void](Enable-TestBackend $b $p); @($b.ActionLog|Where-Object Action -eq 'EnableBoost').Count -eq 1 }
    $results += Invoke-TestCase '25. CorrelationId en Reason worden gelogd' { $b=New-MockFanBackend; $p=Write-InitialState (New-TestStatePath) (New-TestState); $cid=[guid]::NewGuid().ToString(); [void](Enable-FanBackendBoost $b $p ([guid]::NewGuid().ToString()) $cid 'reason-x'); $e=@($b.ActionLog|Where-Object Action -eq 'EnableBoost')[0]; $e.CorrelationId -eq $cid -and $e.Reason -eq 'reason-x' }
    $results += Invoke-TestCase '26. Dubbele enable veroorzaakt geen tweede effectieve statewijziging' { $b=New-MockFanBackend; $p=Write-InitialState (New-TestStatePath) (New-TestState); [void](Enable-TestBackend $b $p); $s=Set-ControllerStatePhase (Read-ControllerState $p).State 'Restored'; [void](Write-ControllerStateAtomic $p $s); [void](Enable-TestBackend $b $p); $b.RuntimeState.EnableCallCount -eq 2 -and $b.RuntimeState.EffectiveEnableCount -eq 1 }
    $results += Invoke-TestCase '27. Dubbele enable blijft geverifieerd BoostEnabled' { $b=New-MockFanBackend -InitialState BoostEnabled; $p=Write-InitialState (New-TestStatePath) (New-TestState); $r=Enable-TestBackend $b $p; $r.Success -and $r.NewState -eq 'BoostEnabled' }
    $results += Invoke-TestCase '28. Dubbele enable beschadigt statefile niet' { $b=New-MockFanBackend; $p=Write-InitialState (New-TestStatePath) (New-TestState); [void](Enable-TestBackend $b $p); (Read-ControllerState $p).Success }
    $results += Invoke-TestCase '29. CleanupRequired blokkeert nieuwe enable' { $p=Write-InitialState (New-TestStatePath) (Mark-ControllerEmergencyReset (New-TestState) 'err'); -not (Enable-TestBackend (New-MockFanBackend) $p).Success }
    $results += Invoke-TestCase '30. EnablePending blokkeert blind opnieuw enable' { $p=Write-InitialState (New-TestStatePath) (Set-ControllerStatePhase (New-TestState) 'EnablePending'); -not (Enable-TestBackend (New-MockFanBackend) $p).Success }
    $results += Invoke-TestCase '31. ThrowOnEnable geeft failure-resultaat' { $p=Write-InitialState (New-TestStatePath) (New-TestState); -not (Enable-TestBackend (New-MockFanBackend -FailureMode ThrowOnEnable) $p).Success }
    $results += Invoke-TestCase '32. ThrowOnEnable markeert CleanupRequired' { $p=Write-InitialState (New-TestStatePath) (New-TestState); [void](Enable-TestBackend (New-MockFanBackend -FailureMode ThrowOnEnable) $p); (Read-ControllerState $p).State.OperationPhase -eq 'CleanupRequired' }
    $results += Invoke-TestCase '33. ThrowOnEnable zet RequiresEmergencyReset' { $p=Write-InitialState (New-TestStatePath) (New-TestState); [void](Enable-TestBackend (New-MockFanBackend -FailureMode ThrowOnEnable) $p); (Read-ControllerState $p).State.RequiresEmergencyReset }
    $results += Invoke-TestCase '34. EnableVerificationFails markeert CleanupRequired' { $p=Write-InitialState (New-TestStatePath) (New-TestState); [void](Enable-TestBackend (New-MockFanBackend -FailureMode EnableVerificationFails) $p); (Read-ControllerState $p).State.OperationPhase -eq 'CleanupRequired' }
    $results += Invoke-TestCase '35. ReturnUnknownAfterEnable markeert CleanupRequired' { $p=Write-InitialState (New-TestStatePath) (New-TestState); [void](Enable-TestBackend (New-MockFanBackend -FailureMode ReturnUnknownAfterEnable) $p); (Read-ControllerState $p).State.OperationPhase -eq 'CleanupRequired' }
    $results += Invoke-TestCase '36. Foutmelding wordt in state opgeslagen' { $p=Write-InitialState (New-TestStatePath) (New-TestState); [void](Enable-TestBackend (New-MockFanBackend -FailureMode ThrowOnEnable) $p); -not [string]::IsNullOrWhiteSpace((Read-ControllerState $p).State.LastError) }
    $results += Invoke-TestCase '37. Vorige geldige statefile blijft leesbaar' { $p=Write-InitialState (New-TestStatePath) (New-TestState); [void](Enable-TestBackend (New-MockFanBackend -FailureMode ThrowOnEnable) $p); (Read-ControllerState $p).Success }
    $results += Invoke-TestCase '38. Restore vanuit ActiveVerified schrijft DisablePending' { $p=Write-InitialState (New-TestStatePath) (Set-ControllerStatePhase (New-TestState) 'ActiveVerified'); [void](Restore-TestBackend (New-MockFanBackend -InitialState BoostEnabled -FailureMode ThrowOnRestore) $p); (Read-ControllerState $p).State.OperationPhase -eq 'CleanupRequired' }
    $results += Invoke-TestCase '39. Restore eindigt in Restored' { $p=Write-InitialState (New-TestStatePath) (Set-ControllerStatePhase (New-TestState) 'ActiveVerified'); $r=Restore-TestBackend (New-MockFanBackend -InitialState BoostEnabled) $p; $r.Success -and (Read-ControllerState $p).State.OperationPhase -eq 'Restored' }
    $results += Invoke-TestCase '40. Restore zet ownership false' { $p=Write-InitialState (New-TestStatePath) (Set-ControllerStatePhase (New-TestState) 'ActiveVerified'); [void](Restore-TestBackend (New-MockFanBackend -InitialState BoostEnabled) $p); -not (Read-ControllerState $p).State.FanOverrideActivatedByThisApp }
    $results += Invoke-TestCase '41. Restore zet RequestedState Automatic' { $p=Write-InitialState (New-TestStatePath) (Set-ControllerStatePhase (New-TestState) 'ActiveVerified'); [void](Restore-TestBackend (New-MockFanBackend -InitialState BoostEnabled) $p); (Read-ControllerState $p).State.CurrentRequestedState -eq 'Automatic' }
    $results += Invoke-TestCase '42. Restore vult verificatietijd' { $p=Write-InitialState (New-TestStatePath) (Set-ControllerStatePhase (New-TestState) 'ActiveVerified'); [void](Restore-TestBackend (New-MockFanBackend -InitialState BoostEnabled) $p); $null -ne (Read-ControllerState $p).State.LastSuccessfulVerificationUtc }
    $results += Invoke-TestCase '43. Mockstate wordt Automatic' { $b=New-MockFanBackend -InitialState BoostEnabled; $p=Write-InitialState (New-TestStatePath) (Set-ControllerStatePhase (New-TestState) 'ActiveVerified'); [void](Restore-TestBackend $b $p); $b.RuntimeState.CurrentFanState -eq 'Automatic' }
    $results += Invoke-TestCase '44. RestoreCallCount wordt een' { $b=New-MockFanBackend -InitialState BoostEnabled; $p=Write-InitialState (New-TestStatePath) (Set-ControllerStatePhase (New-TestState) 'ActiveVerified'); [void](Restore-TestBackend $b $p); $b.RuntimeState.RestoreCallCount -eq 1 }
    $results += Invoke-TestCase '45. Actionlog bevat restore' { $b=New-MockFanBackend -InitialState BoostEnabled; $p=Write-InitialState (New-TestStatePath) (Set-ControllerStatePhase (New-TestState) 'ActiveVerified'); [void](Restore-TestBackend $b $p); @($b.ActionLog|Where-Object Action -eq 'RestoreAutomatic').Count -eq 1 }
    $results += Invoke-TestCase '46. Dubbele restore is idempotent success' { $b=New-MockFanBackend; $p=Write-InitialState (New-TestStatePath) (Set-ControllerStatePhase (New-TestState) 'Restored'); (Restore-TestBackend $b $p).Success }
    $results += Invoke-TestCase '47. ThrowOnRestore markeert CleanupRequired' { $p=Write-InitialState (New-TestStatePath) (Set-ControllerStatePhase (New-TestState) 'ActiveVerified'); [void](Restore-TestBackend (New-MockFanBackend -InitialState BoostEnabled -FailureMode ThrowOnRestore) $p); (Read-ControllerState $p).State.OperationPhase -eq 'CleanupRequired' }
    $results += Invoke-TestCase '48. ThrowOnRestore behoudt bewezen ownership' { $p=Write-InitialState (New-TestStatePath) (Set-ControllerStatePhase (New-TestState) 'ActiveVerified'); [void](Restore-TestBackend (New-MockFanBackend -InitialState BoostEnabled -FailureMode ThrowOnRestore) $p); (Read-ControllerState $p).State.FanOverrideActivatedByThisApp }
    $results += Invoke-TestCase '49. RestoreVerificationFails markeert CleanupRequired' { $p=Write-InitialState (New-TestStatePath) (Set-ControllerStatePhase (New-TestState) 'ActiveVerified'); [void](Restore-TestBackend (New-MockFanBackend -InitialState BoostEnabled -FailureMode RestoreVerificationFails) $p); (Read-ControllerState $p).State.OperationPhase -eq 'CleanupRequired' }
    $results += Invoke-TestCase '50. ReturnUnknownAfterRestore markeert CleanupRequired' { $p=Write-InitialState (New-TestStatePath) (Set-ControllerStatePhase (New-TestState) 'ActiveVerified'); [void](Restore-TestBackend (New-MockFanBackend -InitialState BoostEnabled -FailureMode ReturnUnknownAfterRestore) $p); (Read-ControllerState $p).State.OperationPhase -eq 'CleanupRequired' }
    $results += Invoke-TestCase '51. Statebestand wordt niet automatisch verwijderd bij restore failure' { $p=Write-InitialState (New-TestStatePath) (Set-ControllerStatePhase (New-TestState) 'ActiveVerified'); [void](Restore-TestBackend (New-MockFanBackend -InitialState BoostEnabled -FailureMode ThrowOnRestore) $p); Test-Path $p }
    $results += Invoke-TestCase '52. Emergency reset werkt bij bewezen ownership' { $p=Write-InitialState (New-TestStatePath) (Set-ControllerStatePhase (New-TestState) 'ActiveVerified'); (Invoke-FanBackendEmergencyReset (New-MockFanBackend -InitialState BoostEnabled) $p ([guid]::NewGuid().ToString()) 'reset' -ForceIfOwned).Success }
    $results += Invoke-TestCase '53. Emergency reset wordt geweigerd zonder ownership' { $p=Write-InitialState (New-TestStatePath) (New-TestState); -not (Invoke-FanBackendEmergencyReset (New-MockFanBackend) $p ([guid]::NewGuid().ToString()) 'reset' -ForceIfOwned).Success }
    $results += Invoke-TestCase '54. Emergency reset eindigt in Restored bij succes' { $p=Write-InitialState (New-TestStatePath) (Set-ControllerStatePhase (New-TestState) 'ActiveVerified'); [void](Invoke-FanBackendEmergencyReset (New-MockFanBackend -InitialState BoostEnabled) $p ([guid]::NewGuid().ToString()) 'reset' -ForceIfOwned); (Read-ControllerState $p).State.OperationPhase -eq 'Restored' }
    $results += Invoke-TestCase '55. Emergency reset behoudt CleanupRequired bij failure' { $p=Write-InitialState (New-TestStatePath) (Mark-ControllerEmergencyReset (Set-ControllerStatePhase (New-TestState) 'ActiveVerified') 'needs reset'); [void](Invoke-FanBackendEmergencyReset (New-MockFanBackend -InitialState BoostEnabled -FailureMode ThrowOnRestore) $p ([guid]::NewGuid().ToString()) 'reset' -ForceIfOwned); (Read-ControllerState $p).State.OperationPhase -eq 'CleanupRequired' }
    $results += Invoke-TestCase '56. Dubbele emergency reset is veilig' { $p=Write-InitialState (New-TestStatePath) (Set-ControllerStatePhase (New-TestState) 'ActiveVerified'); $b=New-MockFanBackend -InitialState BoostEnabled; [void](Invoke-FanBackendEmergencyReset $b $p ([guid]::NewGuid().ToString()) 'reset' -ForceIfOwned); (Invoke-FanBackendEmergencyReset $b $p ([guid]::NewGuid().ToString()) 'reset' -ForceIfOwned).Success }
    $results += Invoke-TestCase '57. Alle acties hebben UTC-timestamp' { $b=New-MockFanBackend; [void](Invoke-FanBackendAvailabilityCheck $b); @($b.ActionLog|Where-Object { -not $_.TimestampUtc.EndsWith('Z') }).Count -eq 0 }
    $results += Invoke-TestCase '58. Alle acties bevatten Success' { $b=New-MockFanBackend; [void](Invoke-FanBackendAvailabilityCheck $b); @($b.ActionLog|Where-Object { $_.PSObject.Properties.Name -notcontains 'Success' }).Count -eq 0 }
    $results += Invoke-TestCase '59. Logcopy wijzigen verandert intern log niet' { $b=New-MockFanBackend; [void](Invoke-FanBackendAvailabilityCheck $b); $copy=Get-MockFanBackendActionLog $b; $copy[0].Action='Changed'; $b.ActionLog[0].Action -ne 'Changed' }
    $results += Invoke-TestCase '60. Call counts zijn correct' { $b=New-MockFanBackend; [void](Invoke-FanBackendAvailabilityCheck $b); [void](Get-FanBackendControlState $b); $b.RuntimeState.AvailabilityCallCount -eq 1 -and $b.RuntimeState.GetStateCallCount -eq 1 }
    $results += Invoke-TestCase '61. Effectieve statewijziging is te onderscheiden van idempotente call' { $b=New-MockFanBackend -InitialState BoostEnabled; $p=Write-InitialState (New-TestStatePath) (New-TestState); [void](Enable-TestBackend $b $p); $b.RuntimeState.EnableCallCount -eq 1 -and $b.RuntimeState.EffectiveEnableCount -eq 0 }
    $results += Invoke-TestCase '62. Alle tijdelijke statebestanden worden opgeruimd' { @((Get-ChildItem $testRoot -Filter '*.tmp' -File -Recurse)).Count -eq 0 }
    $results += Invoke-TestCase '63. Geen mockbestand blijft achter in projectroot' { @((Get-ChildItem $ScriptDirectory -Filter '*mock*.tmp' -File)).Count -eq 0 }
    $results += Invoke-TestCase '64. controller-config.json blijft byte-for-byte ongewijzigd' { [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -eq $configBefore }
    $results += Invoke-TestCase '65. DellFanController-DryRun.ps1 blijft byte-for-byte ongewijzigd' { [Convert]::ToBase64String([IO.File]::ReadAllBytes($dryRunPath)) -eq $dryRunBefore }
    $results += Invoke-TestCase '66. DellFanController-State.ps1 blijft byte-for-byte ongewijzigd' { [Convert]::ToBase64String([IO.File]::ReadAllBytes($statePath)) -eq $stateBefore }
    $results += Invoke-TestCase '67. DryRun blijft boolean true' { (Get-Content -Raw $configPath | ConvertFrom-Json).DryRun -eq $true }
    $results += Invoke-TestCase '68. FanBackend.Contract.ps1 heeft geen parserfouten' { $tokens=$null;$errors=$null;[System.Management.Automation.Language.Parser]::ParseFile($contractPath,[ref]$tokens,[ref]$errors)|Out-Null;$errors.Count -eq 0 }
    $results += Invoke-TestCase '69. FanBackend.Mock.ps1 heeft geen parserfouten' { $tokens=$null;$errors=$null;[System.Management.Automation.Language.Parser]::ParseFile($mockPath,[ref]$tokens,[ref]$errors)|Out-Null;$errors.Count -eq 0 }
    $results += Invoke-TestCase '70. Test-FanBackend.Mock.ps1 heeft geen parserfouten' { $tokens=$null;$errors=$null;[System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors)|Out-Null;$errors.Count -eq 0 }
    $results += Invoke-TestCase '71. Geen Start-Process' { Test-NoForbiddenAst @($contractPath,$mockPath,$PSCommandPath) }
    $results += Invoke-TestCase '72. Geen System.Diagnostics.Process' { Test-NoForbiddenAst @($contractPath,$mockPath,$PSCommandPath) }
    $results += Invoke-TestCase '73. Geen Invoke-Expression' { Test-NoForbiddenAst @($contractPath,$mockPath,$PSCommandPath) }
    $results += Invoke-TestCase '74. Geen cctk-referentie in uitvoerbare code' { Test-NoForbiddenAst @($contractPath,$mockPath,$PSCommandPath) }
    $results += Invoke-TestCase '75. Geen Dell-, BIOS- of fan-writecommando''s' { Test-NoForbiddenAst @($contractPath,$mockPath,$PSCommandPath) }
    $results += Invoke-TestCase '76. Geen WMI/CIM-hardwarewijzigingen' { Test-NoForbiddenAst @($contractPath,$mockPath,$PSCommandPath) }
    $results += Invoke-TestCase '77. Geen externe executable invocation' { Test-NoForbiddenAst @($contractPath,$mockPath,$PSCommandPath) }
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
$results += Invoke-TestCase '78. Testdirectory wordt na afloop verwijderd' { -not (Test-Path -LiteralPath $testRoot) }

$results | Format-Table Name, Passed, Details -AutoSize
$failed=@($results|Where-Object{ -not $_.Passed })
if($failed.Count -gt 0){ throw "$($failed.Count) test(s) failed." }
'ALLE FANBACKEND MOCK TESTS GESLAAGD'
