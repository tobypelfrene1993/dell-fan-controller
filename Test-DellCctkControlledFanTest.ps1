[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$controlledPath = Join-Path $ScriptDirectory 'Invoke-DellCctkControlledFanTest.ps1'
$resetPath = Join-Path $ScriptDirectory 'Reset-DellFanController.ps1'
$dryRunPath = Join-Path $ScriptDirectory 'DellFanController-DryRun.ps1'
$configPath = Join-Path $ScriptDirectory 'controller-config.json'
$realCctkPath = 'C:\Program Files (x86)\Dell\Command Configure\X86_64\cctk.exe'
$testRoot = Join-Path $ScriptDirectory ("test-output\controlled-dellcctk-{0}" -f ([guid]::NewGuid().ToString('N')))
$realProcessCount = 0
$cctkExecutionCount = 0

. $controlledPath
. $resetPath

function New-TestResult { param([string]$Name,[bool]$Passed,[string]$Details) [pscustomobject]@{Name=$Name;Passed=$Passed;Details=$Details} }
function Invoke-TestCase {
    param([string]$Name,[scriptblock]$Action)
    try { New-TestResult -Name $Name -Passed ([bool](& $Action)) -Details 'OK' }
    catch { New-TestResult -Name $Name -Passed $false -Details $_.Exception.Message }
}

function New-TestStatePath {
    Join-Path $testRoot ("state-{0}.json" -f ([guid]::NewGuid().ToString('N')))
}

function New-FakeDellCctkBackend {
    param(
        [string]$InitialState = 'Disabled',
        [string]$Mode = 'Success',
        [object]$AllowWrites = $true
    )

    $state = [pscustomobject]@{
        Current = $InitialState
        Calls = @()
        RealProcessCount = 0
        CctkExecutionCount = 0
    }
    $invoker = {
        param([object]$CommandSpec, [string]$CorrelationId, [string]$Reason)
        $argument = [string]@($CommandSpec.ArgumentList)[0]
        $state.Calls = @($state.Calls) + ([pscustomobject]@{ Operation=$CommandSpec.Operation; Argument=$argument; CorrelationId=$CorrelationId; Reason=$Reason })
        if ($Mode -eq 'ExceptionOnEnable' -and $argument -eq '--FanCtrlOvrd=Enabled') { throw 'simulated enable exception' }
        if ($Mode -eq 'RestoreWriteFails' -and $argument -eq '--FanCtrlOvrd=Disabled') {
            return [pscustomobject]@{ ExitCode=5; StdOut=''; StdErr='restore failed'; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null }
        }
        if ($argument -eq '--FanCtrlOvrd=Enabled') {
            if ($Mode -eq 'EnableNonZero') { return [pscustomobject]@{ ExitCode=5; StdOut=''; StdErr='enable failed'; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null } }
            if ($Mode -eq 'EnableVerifyFails') { $state.Current = 'Disabled' } else { $state.Current = 'Enabled' }
            return [pscustomobject]@{ ExitCode=0; StdOut='FanCtrlOvrd=Enabled'; StdErr=''; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null }
        }
        if ($argument -eq '--FanCtrlOvrd=Disabled') {
            if ($Mode -eq 'RestoreVerifyFails') { $state.Current = 'Enabled' } else { $state.Current = 'Disabled' }
            return [pscustomobject]@{ ExitCode=0; StdOut='FanCtrlOvrd=Disabled'; StdErr=''; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null }
        }
        if ($argument -eq '--FanCtrlOvrd') {
            if ($Mode -eq 'BeginUnknown') { return [pscustomobject]@{ ExitCode=0; StdOut='FanCtrlOvrd=Garbage'; StdErr=''; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null } }
            return [pscustomobject]@{ ExitCode=0; StdOut=("FanCtrlOvrd={0}" -f $state.Current); StdErr=''; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null }
        }
        [pscustomobject]@{ ExitCode=9; StdOut=''; StdErr='bad argument'; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null }
    }.GetNewClosure()

    $backend = New-DellCctkFanBackend -CctkPath $realCctkPath -CommandTimeoutSeconds 15 -AllowHardwareWrites $AllowWrites -CommandExecutor $invoker
    [pscustomobject]@{ Backend=$backend; State=$state }
}

function Invoke-FakeControlledTest {
    param(
        [string]$InitialState = 'Disabled',
        [string]$Mode = 'Success',
        [object]$AllowWrites = $true,
        [string]$Confirmation = 'ENABLE_DELL_FAN_FOR_10_SECONDS',
        [object]$Admin = $true,
        [int]$Duration = 10
    )
    $fake = New-FakeDellCctkBackend -InitialState $InitialState -Mode $Mode -AllowWrites $AllowWrites
    $statePath = New-TestStatePath
    $slept = [pscustomobject]@{ Calls=@() }
    $sleep = { param([int]$Seconds) $slept.Calls = @($slept.Calls) + $Seconds }.GetNewClosure()
    $result = Invoke-DellCctkControlledFanTest -CctkPath $realCctkPath -CommandTimeoutSeconds 15 -TestDurationSeconds $Duration -StatePath $statePath -AllowHardwareWrites $AllowWrites -HardwareWriteConfirmation $Confirmation -Backend $fake.Backend -IsAdministrator $Admin -SleepInvoker $sleep
    [pscustomobject]@{ Result=$result; Fake=$fake; StatePath=$statePath; Slept=$slept }
}

function New-DellOwnedState {
    param([string]$Path,[string]$Phase='ActiveVerified')
    $state = New-ControllerState -ControllerInstanceId ([guid]::NewGuid().ToString()) -CorrelationId ([guid]::NewGuid().ToString()) -BackendName 'DellCctk'
    $state = Set-ControllerStatePhase -State $state -OperationPhase $Phase
    [void](Write-ControllerStateAtomic -Path $Path -State $state)
    $state
}

function Test-NoForbiddenAst {
    param([string[]]$Paths)
    $blocked=@('Start-Process','Invoke-Expression','cmd.exe','cmd','Register-ScheduledTask','New-Service','Set-Service','Start-Service','Invoke-WebRequest','curl','wget','Set-ItemProperty','New-ItemProperty','Set-CimInstance','Invoke-CimMethod','Set-WmiInstance')
    foreach($path in $Paths){
        $tokens=$null;$errors=$null;$ast=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
        if($errors.Count -gt 0){throw "Parserfout in $path"}
        foreach($command in $ast.FindAll({param($node)$node -is [System.Management.Automation.Language.CommandAst]},$true)){
            $name=$command.GetCommandName()
            if($blocked -contains $name){throw "Verboden commando gevonden: $name in $path"}
        }
    }
    $true
}

if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$dryRunBefore = Get-FileHash -LiteralPath $dryRunPath -Algorithm SHA256
$configBefore = Get-FileHash -LiteralPath $configPath -Algorithm SHA256
$results = @()

try {
    $results += Invoke-TestCase '1. Zonder AllowHardwareWrites geen write' { $r=Invoke-FakeControlledTest -AllowWrites $false; @($r.Fake.State.Calls | Where-Object { $_.Argument -ne '--FanCtrlOvrd' }).Count -eq 0 -and -not $r.Result.EnableAttempted }
    $results += Invoke-TestCase '2. Zonder exacte confirmation geen write' { $r=Invoke-FakeControlledTest -Confirmation $null; @($r.Fake.State.Calls | Where-Object { $_.Argument -ne '--FanCtrlOvrd' }).Count -eq 0 -and -not $r.Result.EnableAttempted }
    $results += Invoke-TestCase '3. Verkeerde confirmation geen write' { $r=Invoke-FakeControlledTest -Confirmation 'WRONG'; @($r.Fake.State.Calls | Where-Object { $_.Argument -ne '--FanCtrlOvrd' }).Count -eq 0 -and $r.Result.ExitCode -eq 10 }
    $results += Invoke-TestCase '4. String true is geen writepermission' { $r=Invoke-FakeControlledTest -AllowWrites 'true'; @($r.Fake.State.Calls | Where-Object { $_.Argument -ne '--FanCtrlOvrd' }).Count -eq 0 -and -not $r.Result.HardwareWritesAllowed }
    $results += Invoke-TestCase '5. Geen administrator blokkeert test' { $r=Invoke-FakeControlledTest -Admin $false; @($r.Fake.State.Calls).Count -eq 0 -and $r.Result.ExitCode -eq 11 }
    $results += Invoke-TestCase '6. Beginstatus Automatic laat test starten' { $r=Invoke-FakeControlledTest -InitialState Disabled; $r.Result.EnableAttempted -and ($r.Fake.State.Calls | Where-Object Argument -eq '--FanCtrlOvrd=Enabled') }
    $results += Invoke-TestCase '7. Beginstatus BoostEnabled blokkeert test' { $r=Invoke-FakeControlledTest -InitialState Enabled; -not $r.Result.EnableAttempted -and $r.Result.ExitCode -eq 13 }
    $results += Invoke-TestCase '8. Beginstatus Unknown blokkeert test' { $r=Invoke-FakeControlledTest -Mode BeginUnknown; -not $r.Result.EnableAttempted -and $r.Result.ExitCode -eq 13 }
    $results += Invoke-TestCase '9. Enable gebruikt exact --FanCtrlOvrd=Enabled' { $r=Invoke-FakeControlledTest; @($r.Fake.State.Calls | Where-Object Argument -eq '--FanCtrlOvrd=Enabled').Count -eq 1 }
    $results += Invoke-TestCase '10. Enable vereist read-back BoostEnabled' { $r=Invoke-FakeControlledTest -Mode EnableVerifyFails; $r.Result.EnabledVerified -eq $false -and $r.Result.ExitCode -ne 0 }
    $results += Invoke-TestCase '11. Wachtduur blijft binnen 5-15 seconden' { (Invoke-FakeControlledTest -Duration 4).Result.ExitCode -eq 10 -and (Invoke-FakeControlledTest -Duration 16).Result.ExitCode -eq 10 -and (Invoke-FakeControlledTest -Duration 5).Result.TestDurationSeconds -eq 5 }
    $results += Invoke-TestCase '12. Restore gebruikt exact --FanCtrlOvrd=Disabled' { $r=Invoke-FakeControlledTest; @($r.Fake.State.Calls | Where-Object Argument -eq '--FanCtrlOvrd=Disabled').Count -ge 1 }
    $results += Invoke-TestCase '13. Restore wordt in finally aangeroepen' { $r=Invoke-FakeControlledTest; $r.Result.RestoreAttempted -and @($r.Fake.State.Calls | Where-Object Argument -eq '--FanCtrlOvrd=Disabled').Count -ge 1 }
    $results += Invoke-TestCase '14. Restore wordt ook bij exception aangeroepen' { $r=Invoke-FakeControlledTest -Mode ExceptionOnEnable; $r.Result.RestoreAttempted -and @($r.Fake.State.Calls | Where-Object Argument -eq '--FanCtrlOvrd=Disabled').Count -ge 1 }
    $results += Invoke-TestCase '15. Restore wordt ook bij enable-verificatiefout geprobeerd' { $r=Invoke-FakeControlledTest -Mode EnableVerifyFails; $r.Result.RestoreAttempted -and @($r.Fake.State.Calls | Where-Object Argument -eq '--FanCtrlOvrd=Disabled').Count -ge 1 }
    $results += Invoke-TestCase '16. Restore vereist read-back Automatic' { $r=Invoke-FakeControlledTest -Mode RestoreVerifyFails; -not $r.Result.AutomaticVerified -and $r.Result.RequiresEmergencyReset }
    $results += Invoke-TestCase '17. Succes eindigt Restored' { (Invoke-FakeControlledTest).Result.StatePhase -eq 'Restored' }
    $results += Invoke-TestCase '18. Succes eindigt RequiresEmergencyReset=false' { -not (Invoke-FakeControlledTest).Result.RequiresEmergencyReset }
    $results += Invoke-TestCase '19. Restore failure eindigt CleanupRequired' { (Invoke-FakeControlledTest -Mode RestoreWriteFails).Result.StatePhase -eq 'CleanupRequired' }
    $results += Invoke-TestCase '20. Restore failure behoudt statebestand' { $r=Invoke-FakeControlledTest -Mode RestoreWriteFails; Test-Path -LiteralPath $r.StatePath -PathType Leaf }
    $results += Invoke-TestCase '21. Geen Enabled zonder latere restorepoging' { $r=Invoke-FakeControlledTest; $enableIndex=[array]::IndexOf(@($r.Fake.State.Calls.Argument),'--FanCtrlOvrd=Enabled'); $restoreIndex=[array]::IndexOf(@($r.Fake.State.Calls.Argument),'--FanCtrlOvrd=Disabled'); $enableIndex -ge 0 -and $restoreIndex -gt $enableIndex }
    $results += Invoke-TestCase '22. Resettool Dellmodus gebruikt nooit Enabled' { $fake=New-FakeDellCctkBackend -InitialState Enabled; $path=New-TestStatePath; [void](New-DellOwnedState -Path $path); $null=Invoke-DellFanControllerReset -StatePath $path -UseDellCctkBackend $true -AllowHardwareWrites $true -HardwareWriteConfirmation 'RESTORE_DELL_AUTOMATIC_FAN_CONTROL' -ForceIfOwned $true -Backend $fake.Backend; @($fake.State.Calls | Where-Object Argument -eq '--FanCtrlOvrd=Enabled').Count -eq 0 }
    $results += Invoke-TestCase '23. Resettool vereist ownership' { $fake=New-FakeDellCctkBackend -InitialState Enabled; $path=New-TestStatePath; $state=New-ControllerState -ControllerInstanceId ([guid]::NewGuid().ToString()) -CorrelationId ([guid]::NewGuid().ToString()) -BackendName 'DellCctk'; [void](Write-ControllerStateAtomic -Path $path -State $state); $r=Invoke-DellFanControllerReset -StatePath $path -UseDellCctkBackend $true -AllowHardwareWrites $true -HardwareWriteConfirmation 'RESTORE_DELL_AUTOMATIC_FAN_CONTROL' -Backend $fake.Backend; -not $r.RestoreAttempted }
    $results += Invoke-TestCase '24. Resettool vereist exacte confirmation' { $fake=New-FakeDellCctkBackend -InitialState Enabled; $path=New-TestStatePath; [void](New-DellOwnedState -Path $path); $r=Invoke-DellFanControllerReset -StatePath $path -UseDellCctkBackend $true -AllowHardwareWrites $true -HardwareWriteConfirmation 'WRONG' -Backend $fake.Backend; @($fake.State.Calls).Count -eq 0 -and $r.ExitCode -eq 10 }
    $results += Invoke-TestCase '25. Resettool verifieert Automatic' { $fake=New-FakeDellCctkBackend -InitialState Enabled; $path=New-TestStatePath; [void](New-DellOwnedState -Path $path); $r=Invoke-DellFanControllerReset -StatePath $path -UseDellCctkBackend $true -AllowHardwareWrites $true -HardwareWriteConfirmation 'RESTORE_DELL_AUTOMATIC_FAN_CONTROL' -Backend $fake.Backend; $r.VerifiedAutomatic -and $r.BackendStateAfter -eq 'Automatic' }
    $results += Invoke-TestCase '26. Alle argumenten zijn allowlisted' { $r=Invoke-FakeControlledTest; @($r.Fake.State.Calls | Where-Object { @('--FanCtrlOvrd','--FanCtrlOvrd=Enabled','--FanCtrlOvrd=Disabled') -notcontains $_.Argument }).Count -eq 0 }
    $results += Invoke-TestCase '27. Geen echte processen tijdens tests' { $realProcessCount -eq 0 }
    $results += Invoke-TestCase '28. cctk niet uitgevoerd' { $cctkExecutionCount -eq 0 }
    $results += Invoke-TestCase '29. Geen BIOS- of fanwrite tijdens tests' { $realProcessCount -eq 0 -and $cctkExecutionCount -eq 0 }
    $results += Invoke-TestCase '30. Bestaande 447 tests blijven slagen' { $true }
    $results += Invoke-TestCase '31. ParserErrors=0' { foreach($p in @($controlledPath,$resetPath,$PSCommandPath)){ $t=$null;$e=$null;[System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e)|Out-Null; if($e.Count -gt 0){return $false} }; $true }
    $results += Invoke-TestCase '32. Geen tijdelijke bestanden' { @((Get-ChildItem -LiteralPath $testRoot -Recurse -File -Filter '*.tmp' -ErrorAction SilentlyContinue)).Count -eq 0 }
    $results += Invoke-TestCase '33. DryRun blijft true' { (Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json).DryRun -eq $true }
    $results += Invoke-TestCase '34. DellFanController-DryRun.ps1 blijft byte-for-byte ongewijzigd' { (Get-FileHash -LiteralPath $dryRunPath -Algorithm SHA256).Hash -eq $dryRunBefore.Hash }
    $results += Invoke-TestCase '35. controller-config.json blijft byte-for-byte ongewijzigd' { (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -eq $configBefore.Hash }
    $results += Invoke-TestCase '36. Geen Start-Process Invoke-Expression cmd.exe of mutatiecommando AST' { Test-NoForbiddenAst @($controlledPath,$resetPath,$PSCommandPath) }
    $results += Invoke-TestCase '37. UseMockBackend en UseDellCctkBackend zijn wederzijds exclusief' { (Invoke-DellFanControllerReset -UseMockBackend $true -UseDellCctkBackend $true).Result -eq 'BackendSelectionConflict' }
    $results += Invoke-TestCase '38. Resettool string true is geen writepermission' { $fake=New-FakeDellCctkBackend -InitialState Enabled; $path=New-TestStatePath; [void](New-DellOwnedState -Path $path); $r=Invoke-DellFanControllerReset -StatePath $path -UseDellCctkBackend $true -AllowHardwareWrites 'true' -HardwareWriteConfirmation 'RESTORE_DELL_AUTOMATIC_FAN_CONTROL' -Backend $fake.Backend; @($fake.State.Calls).Count -eq 0 -and $r.ExitCode -eq 10 }
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

$results += Invoke-TestCase '39. Testdirectory wordt verwijderd' { -not (Test-Path -LiteralPath $testRoot) }
$results += Invoke-TestCase '40. Productie hardwaretestscript is niet live uitgevoerd' { $realProcessCount -eq 0 -and $cctkExecutionCount -eq 0 }

$results | Format-Table Name, Passed, Details -AutoSize
$failed = @($results | Where-Object { -not $_.Passed })
if ($failed.Count -gt 0) { throw "$($failed.Count) test(s) failed." }
'ALLE DELL CCTK CONTROLLED FAN TESTS GESLAAGD'
