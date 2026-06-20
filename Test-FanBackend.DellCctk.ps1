[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$dellPath = Join-Path $ScriptDirectory 'FanBackend.DellCctk.ps1'
$configPath = Join-Path $ScriptDirectory 'controller-config.json'
$dryRunPath = Join-Path $ScriptDirectory 'DellFanController-DryRun.ps1'
$resetPath = Join-Path $ScriptDirectory 'Reset-DellFanController.ps1'
$statePath = Join-Path $ScriptDirectory 'DellFanController-State.ps1'
$contractPath = Join-Path $ScriptDirectory 'FanBackend.Contract.ps1'
$mockPath = Join-Path $ScriptDirectory 'FanBackend.Mock.ps1'
$testRoot = Join-Path $ScriptDirectory ("test-output\dellcctk-backend-{0}" -f ([guid]::NewGuid().ToString('N')))
$realCctkPath = 'C:\Program Files (x86)\Dell\Command Configure\X86_64\cctk.exe'

$configBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath))
$dryRunBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($dryRunPath))
$resetBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($resetPath))
$stateBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($statePath))
$contractBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($contractPath))
$mockBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($mockPath))

. $dellPath

function New-TestResult { param([string]$Name,[bool]$Passed,[string]$Details) [pscustomobject]@{Name=$Name;Passed=$Passed;Details=$Details} }
function Invoke-TestCase {
    param([string]$Name,[scriptblock]$Action)
    try { New-TestResult -Name $Name -Passed ([bool](& $Action)) -Details 'OK' }
    catch { New-TestResult -Name $Name -Passed $false -Details $_.Exception.Message }
}
function New-FakeDellExecutor {
    param([string]$Mode='Normal',[string]$InitialState='Disabled')
    $state = [pscustomobject]@{ Mode=$Mode; FanValue=$InitialState; Calls=@(); RealProcessCount=0 }
    $executor = {
        param($CommandSpec,$CorrelationId,$Reason)
        $call = [pscustomobject]@{ Operation=$CommandSpec.Operation; Argument=@($CommandSpec.ArgumentList)[0]; CorrelationId=$CorrelationId; Reason=$Reason }
        $state.Calls = @($state.Calls) + $call
        if ($state.Mode -eq 'Exception') { throw 'fake executor exception' }
        if ($state.Mode -eq 'Timeout') { return [pscustomobject]@{ ExitCode=$null; StdOut=''; StdErr=''; TimedOut=$true; DurationMs=15000 } }
        if ($state.Mode -eq 'Slow') { $duration = 9999 } else { $duration = 1 }
        if ($state.Mode -eq 'NonZero') { return [pscustomobject]@{ ExitCode=1; StdOut=''; StdErr='error'; TimedOut=$false; DurationMs=$duration } }
        if ($state.Mode -eq 'StdErr') { return [pscustomobject]@{ ExitCode=0; StdOut='FanCtrlOvrd=Disabled'; StdErr='unexpected stderr'; TimedOut=$false; DurationMs=$duration } }
        if ($state.Mode -eq 'EmptyStdOut') { return [pscustomobject]@{ ExitCode=0; StdOut=''; StdErr=''; TimedOut=$false; DurationMs=$duration } }
        if ($state.Mode -eq 'Malformed') { return [pscustomobject]@{ ExitCode=0; StdOut='FanCtrlOvrd maybe Disabled'; StdErr=''; TimedOut=$false; DurationMs=$duration } }
        if ($state.Mode -eq 'Conflicting') { return [pscustomobject]@{ ExitCode=0; StdOut=\"FanCtrlOvrd=Disabled`nFanCtrlOvrd=Enabled\"; StdErr=''; TimedOut=$false; DurationMs=$duration } }
        if ($state.Mode -eq 'Unknown') { return [pscustomobject]@{ ExitCode=0; StdOut='FanCtrlOvrd=Maybe'; StdErr=''; TimedOut=$false; DurationMs=$duration } }
        if ($state.Mode -eq 'ExactRegression') { return [pscustomobject]@{ Started=$true; ExitCode=0; StdOut='FanCtrlOvrd=Disabled'; StdErr=''; TimedOut=$false; DurationMs=35; ErrorMessage=$null } }
        if ($state.Mode -eq 'InvalidExecutorResult') { return [pscustomobject]@{ Started=$true; ExitCode=$null; StdOut='FanCtrlOvrd=Disabled'; StdErr=''; TimedOut=$false; DurationMs=35; ErrorMessage='InvalidExecutorResult: ExitCode ontbreekt terwijl Started=true en TimedOut=false.' } }
        if ($CommandSpec.Operation -eq 'EnableFanBoost') {
            if ($state.Mode -ne 'EnableReadBackDisabled') { $state.FanValue='Enabled' }
            return [pscustomobject]@{ ExitCode=0; StdOut='FanCtrlOvrd=Enabled'; StdErr=''; TimedOut=$false; DurationMs=$duration }
        }
        if ($CommandSpec.Operation -eq 'RestoreAutomaticFanControl') {
            if ($state.Mode -ne 'RestoreReadBackEnabled') { $state.FanValue='Disabled' }
            return [pscustomobject]@{ ExitCode=0; StdOut='FanCtrlOvrd=Disabled'; StdErr=''; TimedOut=$false; DurationMs=$duration }
        }
        [pscustomobject]@{ ExitCode=0; StdOut=("FanCtrlOvrd={0}" -f $state.FanValue); StdErr=''; TimedOut=$false; DurationMs=$duration }
    }.GetNewClosure()
    [pscustomobject]@{ State=$state; ScriptBlock=$executor }
}
function New-TestBackend {
    param([string]$Mode='Normal',[string]$InitialState='Disabled',[object]$AllowWrites=$false,[string]$Path=$realCctkPath,[int]$Timeout=15)
    $fake = New-FakeDellExecutor -Mode $Mode -InitialState $InitialState
    $backend = New-DellCctkFanBackend -CctkPath $Path -AllowHardwareWrites $AllowWrites -CommandTimeoutSeconds $Timeout -CommandExecutor $fake.ScriptBlock
    [pscustomobject]@{ Backend=$backend; Fake=$fake }
}
function Test-NoForbiddenAst {
    param([string[]]$Paths)
    $blocked=@('Start-Process','Invoke-Expression','Invoke-WebRequest','curl','wget','Register-ScheduledTask','New-Service','Set-Service','Install-Module','Set-ItemProperty','New-ItemProperty','Set-CimInstance','Invoke-CimMethod','Set-WmiInstance')
    foreach($path in $Paths){
        $tokens=$null;$errors=$null;$ast=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
        if($errors.Count -gt 0){throw "Parserfout in $path"}
        $types=$ast.FindAll({param($node)$node -is [System.Management.Automation.Language.TypeExpressionAst]},$true)
        foreach($type in $types){if($type.TypeName.FullName -eq 'System.Diagnostics.Process'){throw 'Verboden System.Diagnostics.Process typegebruik gevonden.'}}
        $commands=$ast.FindAll({param($node)$node -is [System.Management.Automation.Language.CommandAst]},$true)
        foreach($command in $commands){$name=$command.GetCommandName(); if($blocked -contains $name){throw "Verboden commando gevonden: $name"}}
    }
    $true
}

if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$results=@()

try {
    $results += Invoke-TestCase '1. Geldige Dell-backend voldoet aan contract' { (Test-FanBackendContract (New-TestBackend).Backend).IsValid }
    $results += Invoke-TestCase '2. BackendName is DellCctk' { (New-TestBackend).Backend.BackendName -eq 'DellCctk' }
    $results += Invoke-TestCase '3. BackendType is DellCctk' { (New-TestBackend).Backend.BackendType -eq 'DellCctk' }
    $results += Invoke-TestCase '4. RequiresAdmin is correct vastgelegd' { (New-TestBackend).Backend.RequiresAdmin -eq $true }
    $results += Invoke-TestCase '5. AllowHardwareWrites default false' { (New-TestBackend).Backend.AllowHardwareWrites -eq $false }
    $results += Invoke-TestCase '6. Ongeldig leeg pad wordt geweigerd' { -not (Test-DellCctkPath -CctkPath '').Success }
    $results += Invoke-TestCase '7. Relatief pad wordt geweigerd' { -not (Test-DellCctkPath -CctkPath 'cctk.exe').Success }
    $results += Invoke-TestCase '8. Verkeerde bestandsnaam wordt geweigerd' { -not (Test-DellCctkPath -CctkPath 'C:\Windows\System32\not-cctk.exe').Success }
    $results += Invoke-TestCase '9. Verkeerde extensie wordt geweigerd' { -not (Test-DellCctkPath -CctkPath 'C:\Windows\System32\cctk.txt').Success }
    $results += Invoke-TestCase '10. Pad onder tijdelijke testmap wordt voor productieconfig geweigerd' { $p=Join-Path $testRoot 'cctk.exe'; Set-Content -LiteralPath $p -Value 'x'; -not (Test-DellCctkPath -CctkPath $p).Success }
    $results += Invoke-TestCase '11. Ontbrekend bestand wordt geweigerd' { -not (Test-DellCctkPath -CctkPath 'C:\Program Files\Dell\Missing\cctk.exe').Success }
    $results += Invoke-TestCase '12. Te lage versie wordt geweigerd' { -not (Test-DellCctkPath -CctkPath $realCctkPath -MinimumVersion '99.0.0.0').Success }
    $results += Invoke-TestCase '13. Geldige versie wordt geaccepteerd' { (Test-DellCctkPath -CctkPath $realCctkPath -MinimumVersion '5.2.2.0').Success }
    $results += Invoke-TestCase '14. Timeout kleiner dan veilige minimumwaarde wordt geweigerd' { try{[void](New-DellCctkFanBackend -CommandTimeoutSeconds 1);$false}catch{$true} }
    $results += Invoke-TestCase '15. Onbekende backendproperty veroorzaakt geen vrije uitvoering' { $t=New-TestBackend; $t.Backend | Add-Member ExtraProperty 'ignored'; (Invoke-FanBackendAvailabilityCheck $t.Backend).Success }

    $query=New-DellCctkCommandSpec -Operation QueryFanControlState
    $enable=New-DellCctkCommandSpec -Operation EnableFanBoost
    $restore=New-DellCctkCommandSpec -Operation RestoreAutomaticFanControl
    $results += Invoke-TestCase '16. Query-command heeft exact --FanCtrlOvrd' { @($query.ArgumentList)[0] -eq '--FanCtrlOvrd' }
    $results += Invoke-TestCase '17. Enable-command heeft exact --FanCtrlOvrd=Enabled' { @($enable.ArgumentList)[0] -eq '--FanCtrlOvrd=Enabled' }
    $results += Invoke-TestCase '18. Restore-command heeft exact --FanCtrlOvrd=Disabled' { @($restore.ArgumentList)[0] -eq '--FanCtrlOvrd=Disabled' }
    $results += Invoke-TestCase '19. Query is geen write' { -not $query.IsWriteOperation }
    $results += Invoke-TestCase '20. Enable is write' { $enable.IsWriteOperation }
    $results += Invoke-TestCase '21. Restore is write' { $restore.IsWriteOperation }
    $results += Invoke-TestCase '22. Onbekende operation wordt geweigerd' { try{[void](New-DellCctkCommandSpec -Operation Other);$false}catch{$true} }
    $results += Invoke-TestCase '23. Geen vrije argumenten toegestaan' { @($query.ArgumentList + $enable.ArgumentList + $restore.ArgumentList | Where-Object { @('--FanCtrlOvrd','--FanCtrlOvrd=Enabled','--FanCtrlOvrd=Disabled') -notcontains $_ }).Count -eq 0 }
    $results += Invoke-TestCase '24. Argumentlijst bevat exact een element' { @($query.ArgumentList).Count -eq 1 -and @($enable.ArgumentList).Count -eq 1 -and @($restore.ArgumentList).Count -eq 1 }
    $results += Invoke-TestCase '25. CommandSpec kan na creatie niet stil worden gemanipuleerd zonder hernieuwde validatie' { $t=New-TestBackend; $s=New-DellCctkCommandSpec -Operation QueryFanControlState -Backend $t.Backend; $s.ArgumentList=@('--bad'); -not (Invoke-DellCctkCommand -Backend $t.Backend -CommandSpec $s).Success }

    $results += Invoke-TestCase '26. Disabled parseert naar Automatic' { (ConvertFrom-DellCctkFanStateOutput 'FanCtrlOvrd=Disabled').State -eq 'Automatic' }
    $results += Invoke-TestCase '27. Enabled parseert naar BoostEnabled' { (ConvertFrom-DellCctkFanStateOutput 'FanCtrlOvrd=Enabled').State -eq 'BoostEnabled' }
    $results += Invoke-TestCase '28. Veilige whitespace wordt verwerkt' { (ConvertFrom-DellCctkFanStateOutput '  FanCtrlOvrd = Disabled  ').Success }
    $results += Invoke-TestCase '29. Lege output faalt' { -not (ConvertFrom-DellCctkFanStateOutput '').Success }
    $results += Invoke-TestCase '30. Onbekende waarde faalt' { -not (ConvertFrom-DellCctkFanStateOutput 'FanCtrlOvrd=Maybe').Success }
    $results += Invoke-TestCase '31. Conflicterende output faalt' { -not (ConvertFrom-DellCctkFanStateOutput "FanCtrlOvrd=Disabled`nFanCtrlOvrd=Enabled").Success }
    $results += Invoke-TestCase '32. Dubbele identieke statusregel wordt volgens expliciete regel afgehandeld' { (ConvertFrom-DellCctkFanStateOutput "FanCtrlOvrd=Disabled`nFanCtrlOvrd=Disabled").State -eq 'Automatic' }
    $results += Invoke-TestCase '33. Foutmelding parseert niet als status' { -not (ConvertFrom-DellCctkFanStateOutput 'Error: FanCtrlOvrd failed').Success }
    $results += Invoke-TestCase '34. Gedeeltelijke tekstmatch wordt geweigerd' { -not (ConvertFrom-DellCctkFanStateOutput 'xFanCtrlOvrd=Disabled').Success }
    $results += Invoke-TestCase '35. Extra onverwachte waarde wordt geweigerd' { -not (ConvertFrom-DellCctkFanStateOutput "FanCtrlOvrd=Disabled`nOther=1").Success }

    $results += Invoke-TestCase '36. Geldige fake backend is beschikbaar' { (Invoke-FanBackendAvailabilityCheck (New-TestBackend).Backend).Success }
    $results += Invoke-TestCase '37. Ontbrekende executor faalt gesloten' { -not (Invoke-FanBackendAvailabilityCheck (New-DellCctkFanBackend -CctkPath $realCctkPath)).Success }
    $results += Invoke-TestCase '38. Executor-exception wordt afgevangen' { -not (Invoke-FanBackendAvailabilityCheck (New-TestBackend -Mode Exception).Backend).Success }
    $results += Invoke-TestCase '39. Availability wijzigt geen fanstate' { $t=New-TestBackend -InitialState Enabled; [void](Invoke-FanBackendAvailabilityCheck $t.Backend); $t.Fake.State.FanValue -eq 'Enabled' }
    $results += Invoke-TestCase '40. Availability voert geen write uit' { $t=New-TestBackend; [void](Invoke-FanBackendAvailabilityCheck $t.Backend); @($t.Fake.State.Calls|Where-Object {$_.Argument -like '*=*'}).Count -eq 0 }

    $results += Invoke-TestCase '41. Query Disabled geeft Automatic' { (Get-FanBackendControlState (New-TestBackend -InitialState Disabled).Backend).NewState -eq 'Automatic' }
    $results += Invoke-TestCase '42. Query Enabled geeft BoostEnabled' { (Get-FanBackendControlState (New-TestBackend -InitialState Enabled).Backend).NewState -eq 'BoostEnabled' }
    $results += Invoke-TestCase '43. Non-zero exitcode faalt' { -not (Get-FanBackendControlState (New-TestBackend -Mode NonZero).Backend).Success }
    $results += Invoke-TestCase '44. Timeout faalt' { -not (Get-FanBackendControlState (New-TestBackend -Mode Timeout).Backend).Success }
    $results += Invoke-TestCase '45. Lege stdout faalt' { -not (Get-FanBackendControlState (New-TestBackend -Mode EmptyStdOut).Backend).Success }
    $results += Invoke-TestCase '46. Malformed stdout faalt' { -not (Get-FanBackendControlState (New-TestBackend -Mode Malformed).Backend).Success }
    $results += Invoke-TestCase '47. Conflicterende stdout faalt' { -not (Get-FanBackendControlState (New-TestBackend -Mode Conflicting).Backend).Success }
    $results += Invoke-TestCase '48. Onverwachte stderr faalt' { -not (Get-FanBackendControlState (New-TestBackend -Mode StdErr).Backend).Success }
    $results += Invoke-TestCase '49. Unknown state is niet verified' { $r=Get-FanBackendControlState (New-TestBackend -Mode Unknown).Backend; -not $r.Verified }
    $results += Invoke-TestCase '50. Query gebruikt exact allowlisted argument' { $t=New-TestBackend; [void](Get-FanBackendControlState $t.Backend); @($t.Fake.State.Calls)[0].Argument -eq '--FanCtrlOvrd' }
    $results += Invoke-TestCase '50a. Resultmapping behoudt alle executorproperties' { $t=New-TestBackend -Mode ExactRegression; $spec=New-DellCctkCommandSpec -Operation QueryFanControlState -Backend $t.Backend; $r=Invoke-DellCctkCommand -Backend $t.Backend -CommandSpec $spec; $r.Started -eq $true -and $r.ExitCode -eq 0 -and $r.StdOut -eq 'FanCtrlOvrd=Disabled' -and $r.StdErr -eq '' -and $r.TimedOut -eq $false -and $r.DurationMs -eq 35 -and $null -eq $r.ErrorMessage }
    $results += Invoke-TestCase '50b. GetState parseert exact regressieobject naar Automatic' { (Get-FanBackendControlState (New-TestBackend -Mode ExactRegression).Backend).NewState -eq 'Automatic' }
    $results += Invoke-TestCase '50c. Exact regressieobject wordt verified' { (Get-FanBackendControlState (New-TestBackend -Mode ExactRegression).Backend).Verified -eq $true }
    $results += Invoke-TestCase '50d. InvalidExecutorResult blijft expliciet' { $r=Get-FanBackendControlState (New-TestBackend -Mode InvalidExecutorResult).Backend; $r.Success -eq $false -and $r.ErrorCode -eq 'InvalidExecutorResult' -and $r.ErrorMessage -match '^InvalidExecutorResult:' }

    $results += Invoke-TestCase '51. Enable met AllowHardwareWrites=false wordt geweigerd' { -not (& (New-TestBackend).Backend.Operations.EnableBoost (New-TestBackend).Backend 'c' 'r').Success }
    $results += Invoke-TestCase '52. Enable met writes false roept executor niet aan' { $t=New-TestBackend; [void](& $t.Backend.Operations.EnableBoost $t.Backend 'c' 'r'); @($t.Fake.State.Calls).Count -eq 0 }
    $results += Invoke-TestCase '53. Restore met writes false wordt geweigerd' { $t=New-TestBackend; -not (& $t.Backend.Operations.RestoreAutomatic $t.Backend 'c' 'r').Success }
    $results += Invoke-TestCase '54. Restore met writes false roept executor niet aan' { $t=New-TestBackend; [void](& $t.Backend.Operations.RestoreAutomatic $t.Backend 'c' 'r'); @($t.Fake.State.Calls).Count -eq 0 }
    $results += Invoke-TestCase '55. EmergencyReset met writes false roept executor niet aan' { $t=New-TestBackend; [void](& $t.Backend.Operations.EmergencyReset $t.Backend 'c' 'r'); @($t.Fake.State.Calls).Count -eq 0 }
    $results += Invoke-TestCase '56. Boolean-achtige string true geldt niet als toestemming' { (New-TestBackend -AllowWrites 'true').Backend.AllowHardwareWrites -eq $false }
    $results += Invoke-TestCase '57. Ontbrekende writepermission faalt gesloten' { $t=New-TestBackend; (& $t.Backend.Operations.EnableBoost $t.Backend 'c' 'r').RequiresCleanup -eq $false }

    $results += Invoke-TestCase '58. Enable met writes true gebruikt exact Enabled-argument' { $t=New-TestBackend -AllowWrites $true; [void](& $t.Backend.Operations.EnableBoost $t.Backend 'c' 'r'); @($t.Fake.State.Calls)[0].Argument -eq '--FanCtrlOvrd=Enabled' }
    $results += Invoke-TestCase '59. Enable exitcode 0 plus read-back Enabled is succes' { $t=New-TestBackend -AllowWrites $true; (& $t.Backend.Operations.EnableBoost $t.Backend 'c' 'r').Success }
    $results += Invoke-TestCase '60. Enable vereist read-back' { $t=New-TestBackend -AllowWrites $true; [void](& $t.Backend.Operations.EnableBoost $t.Backend 'c' 'r'); @($t.Fake.State.Calls).Count -eq 2 }
    $results += Invoke-TestCase '61. Enable read-back Disabled is failure' { $t=New-TestBackend -AllowWrites $true -Mode EnableReadBackDisabled; -not (& $t.Backend.Operations.EnableBoost $t.Backend 'c' 'r').Success }
    $results += Invoke-TestCase '62. Enable read-back Unknown is failure' { $t=New-TestBackend -AllowWrites $true -Mode Unknown; -not (& $t.Backend.Operations.EnableBoost $t.Backend 'c' 'r').Success }
    $results += Invoke-TestCase '63. Enable timeout is failure' { $t=New-TestBackend -AllowWrites $true -Mode Timeout; -not (& $t.Backend.Operations.EnableBoost $t.Backend 'c' 'r').Success }
    $results += Invoke-TestCase '64. Enable non-zero exitcode is failure' { $t=New-TestBackend -AllowWrites $true -Mode NonZero; -not (& $t.Backend.Operations.EnableBoost $t.Backend 'c' 'r').Success }
    $results += Invoke-TestCase '65. Enable exception wordt afgevangen' { $t=New-TestBackend -AllowWrites $true -Mode Exception; -not (& $t.Backend.Operations.EnableBoost $t.Backend 'c' 'r').Success }
    $results += Invoke-TestCase '66. Enable verification failure zet RequiresCleanup' { $t=New-TestBackend -AllowWrites $true -Mode EnableReadBackDisabled; (& $t.Backend.Operations.EnableBoost $t.Backend 'c' 'r').RequiresCleanup }

    $results += Invoke-TestCase '67. Restore gebruikt exact Disabled-argument' { $t=New-TestBackend -AllowWrites $true -InitialState Enabled; [void](& $t.Backend.Operations.RestoreAutomatic $t.Backend 'c' 'r'); @($t.Fake.State.Calls)[0].Argument -eq '--FanCtrlOvrd=Disabled' }
    $results += Invoke-TestCase '68. Restore exitcode 0 plus read-back Disabled is succes' { $t=New-TestBackend -AllowWrites $true -InitialState Enabled; (& $t.Backend.Operations.RestoreAutomatic $t.Backend 'c' 'r').Success }
    $results += Invoke-TestCase '69. Restore vereist read-back' { $t=New-TestBackend -AllowWrites $true -InitialState Enabled; [void](& $t.Backend.Operations.RestoreAutomatic $t.Backend 'c' 'r'); @($t.Fake.State.Calls).Count -eq 2 }
    $results += Invoke-TestCase '70. Restore read-back Enabled is failure' { $t=New-TestBackend -AllowWrites $true -Mode RestoreReadBackEnabled -InitialState Enabled; -not (& $t.Backend.Operations.RestoreAutomatic $t.Backend 'c' 'r').Success }
    $results += Invoke-TestCase '71. Restore read-back Unknown is failure' { $t=New-TestBackend -AllowWrites $true -Mode Unknown; -not (& $t.Backend.Operations.RestoreAutomatic $t.Backend 'c' 'r').Success }
    $results += Invoke-TestCase '72. Restore timeout is failure' { $t=New-TestBackend -AllowWrites $true -Mode Timeout; -not (& $t.Backend.Operations.RestoreAutomatic $t.Backend 'c' 'r').Success }
    $results += Invoke-TestCase '73. Restore non-zero exitcode is failure' { $t=New-TestBackend -AllowWrites $true -Mode NonZero; -not (& $t.Backend.Operations.RestoreAutomatic $t.Backend 'c' 'r').Success }
    $results += Invoke-TestCase '74. Restore exception wordt afgevangen' { $t=New-TestBackend -AllowWrites $true -Mode Exception; -not (& $t.Backend.Operations.RestoreAutomatic $t.Backend 'c' 'r').Success }
    $results += Invoke-TestCase '75. Restore verification failure zet RequiresCleanup' { $t=New-TestBackend -AllowWrites $true -Mode RestoreReadBackEnabled -InitialState Enabled; (& $t.Backend.Operations.RestoreAutomatic $t.Backend 'c' 'r').RequiresCleanup }
    $results += Invoke-TestCase '76. Reeds Automatic is idempotent success na query' { $t=New-TestBackend -AllowWrites $true -InitialState Disabled; (& $t.Backend.Operations.RestoreAutomatic $t.Backend 'c' 'r').Success }

    $results += Invoke-TestCase '77. EmergencyReset gebruikt nooit Enabled' { $t=New-TestBackend -AllowWrites $true -InitialState Enabled; [void](& $t.Backend.Operations.EmergencyReset $t.Backend 'c' 'r'); @($t.Fake.State.Calls|Where-Object {$_.Argument -eq '--FanCtrlOvrd=Enabled'}).Count -eq 0 }
    $results += Invoke-TestCase '78. EmergencyReset gebruikt alleen Disabled' { $t=New-TestBackend -AllowWrites $true -InitialState Enabled; [void](& $t.Backend.Operations.EmergencyReset $t.Backend 'c' 'r'); @($t.Fake.State.Calls)[0].Argument -eq '--FanCtrlOvrd=Disabled' }
    $results += Invoke-TestCase '79. EmergencyReset vereist read-back Automatic' { $t=New-TestBackend -AllowWrites $true -InitialState Enabled; @($(& $t.Backend.Operations.EmergencyReset $t.Backend 'c' 'r')).Success -and @($t.Fake.State.Calls).Count -eq 2 }
    $results += Invoke-TestCase '80. EmergencyReset failure behoudt RequiresCleanup' { $t=New-TestBackend -AllowWrites $true -Mode RestoreReadBackEnabled -InitialState Enabled; (& $t.Backend.Operations.EmergencyReset $t.Backend 'c' 'r').RequiresCleanup }

    $results += Invoke-TestCase '81. Iedere actie krijgt UTC-timestamp' { $t=New-TestBackend; [void](Get-FanBackendControlState $t.Backend); @($t.Backend.ActionLog|Where-Object{ -not $_.TimestampUtc.EndsWith('Z') }).Count -eq 0 }
    $results += Invoke-TestCase '82. CorrelationId wordt gelogd' { $t=New-TestBackend -AllowWrites $true; [void](& $t.Backend.Operations.EnableBoost $t.Backend 'cid-x' 'r'); @($t.Backend.ActionLog|Where-Object CorrelationId -eq 'cid-x').Count -gt 0 }
    $results += Invoke-TestCase '83. Reason wordt gelogd' { $t=New-TestBackend -AllowWrites $true; [void](& $t.Backend.Operations.EnableBoost $t.Backend 'c' 'reason-x'); @($t.Backend.ActionLog|Where-Object Reason -eq 'reason-x').Count -gt 0 }
    $results += Invoke-TestCase '84. Exacte allowlisted argumenten worden gelogd' { $t=New-TestBackend; [void](Get-FanBackendControlState $t.Backend); @($t.Backend.ActionLog[0].AllowlistedArguments)[0] -eq '--FanCtrlOvrd' }
    $results += Invoke-TestCase '85. Timeout wordt gelogd' { $t=New-TestBackend -Mode Timeout; [void](Get-FanBackendControlState $t.Backend); $t.Backend.ActionLog[0].TimedOut }
    $results += Invoke-TestCase '86. Exitcode wordt gelogd' { $t=New-TestBackend -Mode NonZero; [void](Get-FanBackendControlState $t.Backend); $t.Backend.ActionLog[0].ExitCode -eq 1 }
    $results += Invoke-TestCase '87. ParsedState wordt gelogd' { $t=New-TestBackend; [void](Get-FanBackendControlState $t.Backend); $t.Backend.ActionLog[0].ParsedState -eq 'Automatic' }
    $results += Invoke-TestCase '88. ActionLog-copy kan intern log niet wijzigen' { $t=New-TestBackend; [void](Get-FanBackendControlState $t.Backend); $copy=Get-DellCctkActionLog $t.Backend; $copy[0].Operation='Changed'; $t.Backend.ActionLog[0].Operation -ne 'Changed' }

    $results += Invoke-TestCase '89. Geen echte cctk-uitvoering' { $t=New-TestBackend; [void](Get-FanBackendControlState $t.Backend); $t.Fake.State.RealProcessCount -eq 0 -and @($t.Fake.State.Calls).Count -eq 1 }
    $results += Invoke-TestCase '90. Geen echte externe processen' { $t=New-TestBackend -AllowWrites $true; [void](& $t.Backend.Operations.EnableBoost $t.Backend 'c' 'r'); $t.Fake.State.RealProcessCount -eq 0 }
    $results += Invoke-TestCase '91. Geen BIOS-wijzigingen' { (Get-Content -Raw $dellPath) -notmatch '(?i)BIOS.*write|Dell Command Configure.*write' }
    $results += Invoke-TestCase '92. Geen hardwarecommando''s' { (Get-Content -Raw $dellPath) -notmatch '(?i)Start-Process|Invoke-Expression' }
    $results += Invoke-TestCase '93. controller-config.json blijft byte-for-byte ongewijzigd' { [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -eq $configBefore }
    $results += Invoke-TestCase '94. DellFanController-DryRun.ps1 blijft byte-for-byte ongewijzigd' { [Convert]::ToBase64String([IO.File]::ReadAllBytes($dryRunPath)) -eq $dryRunBefore }
    $results += Invoke-TestCase '95. Reset-DellFanController.ps1 blijft byte-for-byte ongewijzigd' { [Convert]::ToBase64String([IO.File]::ReadAllBytes($resetPath)) -eq $resetBefore }
    $results += Invoke-TestCase '96. DellFanController-State.ps1 blijft byte-for-byte ongewijzigd' { [Convert]::ToBase64String([IO.File]::ReadAllBytes($statePath)) -eq $stateBefore }
    $results += Invoke-TestCase '97. FanBackend.Contract.ps1 blijft byte-for-byte ongewijzigd' { [Convert]::ToBase64String([IO.File]::ReadAllBytes($contractPath)) -eq $contractBefore }
    $results += Invoke-TestCase '98. FanBackend.Mock.ps1 blijft byte-for-byte ongewijzigd' { [Convert]::ToBase64String([IO.File]::ReadAllBytes($mockPath)) -eq $mockBefore }
    $results += Invoke-TestCase '99. DryRun blijft true' { (Get-Content -Raw $configPath | ConvertFrom-Json).DryRun -eq $true }
    $results += Invoke-TestCase '100. Geen tijdelijke bestanden blijven achter' { @((Get-ChildItem -LiteralPath $testRoot -Recurse -File -Filter '*.tmp')).Count -eq 0 }
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

$results += Invoke-TestCase '101. Testdirectory wordt verwijderd' { -not (Test-Path -LiteralPath $testRoot) }
$results += Invoke-TestCase '102. ParserErrors=0 voor nieuwe module' { $tokens=$null;$errors=$null;[System.Management.Automation.Language.Parser]::ParseFile($dellPath,[ref]$tokens,[ref]$errors)|Out-Null;$errors.Count -eq 0 }
$results += Invoke-TestCase '103. ParserErrors=0 voor testscript' { $tokens=$null;$errors=$null;[System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors)|Out-Null;$errors.Count -eq 0 }
$results += Invoke-TestCase '104. Geen Invoke-Expression' { Test-NoForbiddenAst @($dellPath,$PSCommandPath) }
$results += Invoke-TestCase '105. Geen vrije shellcommandconstructie' { (Get-Content -Raw $dellPath) -notmatch '(?i)cmd /c|powershell.exe|ArgumentList\\s*=\\s*\\$' }
$results += Invoke-TestCase '106. Geen netwerkcode' { Test-NoForbiddenAst @($dellPath,$PSCommandPath) }
$results += Invoke-TestCase '107. Geen registrywrite' { Test-NoForbiddenAst @($dellPath,$PSCommandPath) }
$results += Invoke-TestCase '108. Geen service- of Scheduled Task-code' { Test-NoForbiddenAst @($dellPath,$PSCommandPath) }

$results | Format-Table Name, Passed, Details -AutoSize
$failed=@($results|Where-Object{ -not $_.Passed })
if($failed.Count -gt 0){ throw "$($failed.Count) test(s) failed." }
'ALLE DELL CCTK BACKEND TESTS GESLAAGD'
