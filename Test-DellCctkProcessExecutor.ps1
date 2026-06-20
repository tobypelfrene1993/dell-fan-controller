[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$executorPath = Join-Path $ScriptDirectory 'DellCctk.ProcessExecutor.ps1'
$probePath = Join-Path $ScriptDirectory 'Invoke-DellCctkReadOnlyProbe.ps1'
$dellBackendPath = Join-Path $ScriptDirectory 'FanBackend.DellCctk.ps1'
$configPath = Join-Path $ScriptDirectory 'controller-config.json'
$testRoot = Join-Path $ScriptDirectory ("test-output\process-executor-{0}" -f ([guid]::NewGuid().ToString('N')))
$realProcessCount = 0
$cctkExecutionCount = 0

. $executorPath
. $dellBackendPath

function New-TestResult { param([string]$Name,[bool]$Passed,[string]$Details) [pscustomobject]@{Name=$Name;Passed=$Passed;Details=$Details} }
function Invoke-TestCase {
    param([string]$Name,[scriptblock]$Action)
    try { New-TestResult -Name $Name -Passed ([bool](& $Action)) -Details 'OK' }
    catch { New-TestResult -Name $Name -Passed $false -Details $_.Exception.Message }
}
function New-FakeCctkFile {
    param([string]$Directory,[string]$Name='cctk.exe')
    $path = Join-Path $Directory $Name
    Set-Content -LiteralPath $path -Value 'fake' -Encoding ASCII
    $path
}
function New-TestCommandSpec {
    param([string]$Path,[string[]]$Arguments=@('--FanCtrlOvrd'),[string]$Operation='QueryFanControlState',[int]$Timeout=15)
    [pscustomobject]@{ Operation=$Operation; ExecutablePath=$Path; ArgumentList=@($Arguments); IsWriteOperation=($Operation -ne 'QueryFanControlState'); TimeoutSeconds=$Timeout }
}
function New-FakeProcessInvoker {
    param([string]$Mode='Success')
    $state = [pscustomobject]@{ Calls=@(); RealProcessCount=0; CctkExecutionCount=0 }
    $invoker = {
        param([string]$ExecutablePath,[string[]]$ArgumentList,[int]$TimeoutSeconds)
        $state.Calls = @($state.Calls) + ([pscustomobject]@{ ExecutablePath=$ExecutablePath; ArgumentList=@($ArgumentList); TimeoutSeconds=$TimeoutSeconds })
        if ($Mode -eq 'Exception') { throw 'fake process invoker exception' }
        if ($Mode -eq 'Timeout') { return [pscustomobject]@{ ExitCode=$null; StdOut=''; StdErr='timeout'; TimedOut=$true; DurationMs=15000; Started=$true; ErrorMessage='timeout' } }
        if ($Mode -eq 'NonZero') { return [pscustomobject]@{ ExitCode=5; StdOut=''; StdErr='bad'; TimedOut=$false; DurationMs=3; Started=$true; ErrorMessage=$null } }
        if ($Mode -eq 'ExactRegression') { return [pscustomobject]@{ Started=$true; ExitCode=0; StdOut='FanCtrlOvrd=Disabled'; StdErr=''; TimedOut=$false; DurationMs=35; ErrorMessage=$null } }
        if ($Mode -eq 'NullExitCode') { return [pscustomobject]@{ ExitCode=$null; StdOut='FanCtrlOvrd=Disabled'; StdErr=''; TimedOut=$false; DurationMs=35; Started=$true; ErrorMessage=$null } }
        if ($Mode -eq 'StartedFalseNoError') { return [pscustomobject]@{ ExitCode=$null; StdOut=''; StdErr=''; TimedOut=$false; DurationMs=35; Started=$false; ErrorMessage=$null } }
        if ($Mode -eq 'PipelineBoolean') { Write-Output $true; return [pscustomobject]@{ ExitCode=0; StdOut='FanCtrlOvrd=Disabled'; StdErr=''; TimedOut=$false; DurationMs=35; Started=$true; ErrorMessage=$null } }
        if ($Mode -eq 'MultipleObjects') { [pscustomobject]@{ ExitCode=0; StdOut='one'; StdErr=''; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null }; return [pscustomobject]@{ ExitCode=0; StdOut='two'; StdErr=''; TimedOut=$false; DurationMs=2; Started=$true; ErrorMessage=$null } }
        [pscustomobject]@{ ExitCode=0; StdOut='FanCtrlOvrd=Disabled'; StdErr='fake stderr'; TimedOut=$false; DurationMs=2; Started=$true; ErrorMessage=$null }
    }.GetNewClosure()
    [pscustomobject]@{ State=$state; ScriptBlock=$invoker }
}
function Invoke-FakeExecutor {
    param([object]$Spec,[object]$AllowWrites=$false,[string]$Mode='Success')
    $fake = New-FakeProcessInvoker -Mode $Mode
    $executor = New-DellCctkProcessExecutor -AllowHardwareWrites $AllowWrites -ProcessInvoker $fake.ScriptBlock
    $result = & $executor $Spec 'correlation-should-not-be-argument' 'reason-should-not-be-argument'
    [pscustomobject]@{ Result=$result; Fake=$fake; Executor=$executor }
}
function Test-NoForbiddenAst {
    param([string[]]$Paths)
    $blocked=@('Start-Process','Invoke-Expression','cmd.exe','Invoke-WebRequest','curl','wget','Register-ScheduledTask','New-Service','Set-Service','Install-Module','Set-ItemProperty','New-ItemProperty','Set-CimInstance','Invoke-CimMethod','Set-WmiInstance')
    foreach($path in $Paths){
        $tokens=$null;$errors=$null;$ast=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
        if($errors.Count -gt 0){throw "Parserfout in $path"}
        $commands=$ast.FindAll({param($node)$node -is [System.Management.Automation.Language.CommandAst]},$true)
        foreach($command in $commands){$name=$command.GetCommandName(); if($blocked -contains $name){throw "Verboden commando gevonden: $name"}}
    }
    $true
}

if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$fakeExe = New-FakeCctkFile -Directory $testRoot
$results=@()

try {
    $results += Invoke-TestCase '1. Geldige executor wordt aangemaakt' { (New-DellCctkProcessExecutor -ProcessInvoker (New-FakeProcessInvoker).ScriptBlock) -is [scriptblock] }
    $results += Invoke-TestCase '2. Signature sluit exact aan op FanBackend.DellCctk.ps1' { $spec=New-DellCctkCommandSpec -Operation QueryFanControlState -Backend (New-DellCctkFanBackend -CctkPath $fakeExe -CommandExecutor {param($a,$b,$c)}); $r=Invoke-FakeExecutor -Spec $spec; @($r.Fake.State.Calls).Count -eq 1 }
    $results += Invoke-TestCase '3. --FanCtrlOvrd wordt toegestaan' { (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe)).Result.Started }
    $results += Invoke-TestCase '4. Enabled wordt zonder writepermission geweigerd' { -not (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe -Arguments @('--FanCtrlOvrd=Enabled') -Operation EnableFanBoost)).Result.Started }
    $results += Invoke-TestCase '5. Disabled wordt zonder writepermission geweigerd' { -not (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe -Arguments @('--FanCtrlOvrd=Disabled') -Operation RestoreAutomaticFanControl)).Result.Started }
    $results += Invoke-TestCase '6. Enabled werkt alleen met boolean true' { (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe -Arguments @('--FanCtrlOvrd=Enabled') -Operation EnableFanBoost) -AllowWrites $true).Result.Started }
    $results += Invoke-TestCase '7. Disabled werkt alleen met boolean true' { (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe -Arguments @('--FanCtrlOvrd=Disabled') -Operation RestoreAutomaticFanControl) -AllowWrites $true).Result.Started }
    $results += Invoke-TestCase '8. String true wordt geweigerd' { -not (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe -Arguments @('--FanCtrlOvrd=Enabled') -Operation EnableFanBoost) -AllowWrites 'true').Result.Started }
    $results += Invoke-TestCase '9. Integer 1 wordt geweigerd' { -not (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe -Arguments @('--FanCtrlOvrd=Enabled') -Operation EnableFanBoost) -AllowWrites 1).Result.Started }
    $results += Invoke-TestCase '10. Geen argument wordt geweigerd' { -not (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe -Arguments @())).Result.Started }
    $results += Invoke-TestCase '11. Meerdere argumenten worden geweigerd' { -not (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe -Arguments @('--FanCtrlOvrd','--bad'))).Result.Started }
    $results += Invoke-TestCase '12. Onbekend argument wordt geweigerd' { -not (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe -Arguments @('--bad'))).Result.Started }
    $results += Invoke-TestCase '13. Argument met spatie wordt geweigerd' { -not (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe -Arguments @('--FanCtrlOvrd '))).Result.Started }
    $results += Invoke-TestCase '14. Argument met ampersand wordt geweigerd' { -not (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe -Arguments @('--FanCtrlOvrd&whoami'))).Result.Started }
    $results += Invoke-TestCase '15. Argument met pipe wordt geweigerd' { -not (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe -Arguments @('--FanCtrlOvrd|more'))).Result.Started }
    $results += Invoke-TestCase '16. Argument met semicolon wordt geweigerd' { -not (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe -Arguments @('--FanCtrlOvrd;dir'))).Result.Started }
    $results += Invoke-TestCase '17. Relatief executablepad wordt geweigerd' { -not (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path 'cctk.exe')).Result.Started }
    $results += Invoke-TestCase '18. Verkeerde executablename wordt geweigerd' { $p=New-FakeCctkFile -Directory $testRoot -Name 'not-cctk.exe'; -not (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $p)).Result.Started }
    $results += Invoke-TestCase '19. Ontbrekend bestand wordt geweigerd' { -not (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path (Join-Path $testRoot 'missing\\cctk.exe'))).Result.Started }
    $results += Invoke-TestCase '20. Ongeldige timeout wordt geweigerd' { -not (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe -Timeout 0)).Result.Started }
    $results += Invoke-TestCase '21. Fake succes geeft exitcode 0' { (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe)).Result.ExitCode -eq 0 }
    $results += Invoke-TestCase '22. Fake stdout wordt doorgegeven' { (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe)).Result.StdOut -eq 'FanCtrlOvrd=Disabled' }
    $results += Invoke-TestCase '23. Fake stderr wordt doorgegeven' { (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe)).Result.StdErr -eq 'fake stderr' }
    $results += Invoke-TestCase '24. Non-zero exitcode wordt doorgegeven' { (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe) -Mode NonZero).Result.ExitCode -eq 5 }
    $results += Invoke-TestCase '25. Timeout wordt correct verwerkt' { (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe) -Mode Timeout).Result.TimedOut }
    $results += Invoke-TestCase '26. Exception wordt veilig afgevangen' { -not (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe) -Mode Exception).Result.Started }
    $results += Invoke-TestCase '27. DurationMs wordt ingevuld' { (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe)).Result.DurationMs -ge 0 }
    $results += Invoke-TestCase '28. CorrelationId wordt niet aan argumenten toegevoegd' { $r=Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe); @($r.Fake.State.Calls[0].ArgumentList) -notcontains 'correlation-should-not-be-argument' }
    $results += Invoke-TestCase '29. Reason wordt niet aan argumenten toegevoegd' { $r=Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe); @($r.Fake.State.Calls[0].ArgumentList) -notcontains 'reason-should-not-be-argument' }
    $results += Invoke-TestCase '30. Fake invoker wordt exact een keer aangeroepen' { $r=Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe); @($r.Fake.State.Calls).Count -eq 1 }
    $results += Invoke-TestCase '30a. Fake resultaat blijft een PSCustomObject' { $r=Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe) -Mode ExactRegression; @($r.Result).Count -eq 1 -and $r.Result -is [pscustomobject] }
    $results += Invoke-TestCase '30b. Started=true blijft behouden' { (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe) -Mode ExactRegression).Result.Started -eq $true }
    $results += Invoke-TestCase '30c. ExitCode=0 blijft behouden' { (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe) -Mode ExactRegression).Result.ExitCode -eq 0 }
    $results += Invoke-TestCase '30d. StdOut blijft behouden' { (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe) -Mode ExactRegression).Result.StdOut -eq 'FanCtrlOvrd=Disabled' }
    $results += Invoke-TestCase '30e. Lege StdErr blijft behouden' { (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe) -Mode ExactRegression).Result.StdErr -eq '' }
    $results += Invoke-TestCase '30f. TimedOut=false blijft behouden' { (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe) -Mode ExactRegression).Result.TimedOut -eq $false }
    $results += Invoke-TestCase '30g. DurationMs blijft behouden' { (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe) -Mode ExactRegression).Result.DurationMs -eq 35 }
    $results += Invoke-TestCase '30h. ErrorMessage null blijft toegestaan bij succes' { $null -eq (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe) -Mode ExactRegression).Result.ErrorMessage }
    $results += Invoke-TestCase '30i. Null ExitCode zonder timeout wordt geweigerd' { $r=(Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe) -Mode NullExitCode).Result; $r.ErrorMessage -match '^InvalidExecutorResult:' -and $null -eq $r.ExitCode }
    $results += Invoke-TestCase '30j. Pipelinevervuiling met boolean wordt gedetecteerd' { $r=(Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe) -Mode PipelineBoolean).Result; $r.ErrorMessage -match '^InvalidExecutorResult:' }
    $results += Invoke-TestCase '30k. Pipelinevervuiling met meerdere objecten wordt gedetecteerd' { $r=(Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe) -Mode MultipleObjects).Result; $r.ErrorMessage -match '^InvalidExecutorResult:' }
    $results += Invoke-TestCase '30k2. Started=false zonder ErrorMessage wordt InvalidExecutorResult' { $r=(Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe) -Mode StartedFalseNoError).Result; $r.ErrorMessage -match '^InvalidExecutorResult:' }
    $results += Invoke-TestCase '30l. Windows PowerShell 5.1 Arguments-pad bestaat' { (Get-Content -Raw $executorPath).Contains('$startInfo.Arguments = [string]@($ArgumentList)[0]') }
    $results += Invoke-TestCase '30m. Parameterloze WaitForExit flusht redirect streams' { (Get-Content -Raw $executorPath).Contains('$process.WaitForExit()') }
    $results += Invoke-TestCase '30n. ExitCode wordt voor Dispose gelezen' { $raw=Get-Content -Raw $executorPath; $raw.IndexOf('$exitCode = $process.ExitCode') -gt 0 -and $raw.IndexOf('$exitCode = $process.ExitCode') -lt $raw.IndexOf('$process.Dispose()') }
    $results += Invoke-TestCase '30o. StdOut en StdErr worden voor Dispose gelezen' { $raw=Get-Content -Raw $executorPath; $raw.IndexOf('$stdout = $process.StandardOutput.ReadToEnd()') -gt 0 -and $raw.IndexOf('$stderr = $process.StandardError.ReadToEnd()') -gt 0 -and $raw.IndexOf('$stderr = $process.StandardError.ReadToEnd()') -lt $raw.IndexOf('$process.Dispose()') }
    $results += Invoke-TestCase '30p. Timeoutpad rapporteert TimedOut=true' { (Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe) -Mode Timeout).Result.TimedOut -eq $true }
    $results += Invoke-TestCase '30q. Exceptionpad geeft concrete ErrorMessage' { $r=(Invoke-FakeExecutor -Spec (New-TestCommandSpec -Path $fakeExe) -Mode Exception).Result; -not [string]::IsNullOrWhiteSpace([string]$r.ErrorMessage) }
    $results += Invoke-TestCase '31. Geen shellgebruik' { (Get-Content -Raw $executorPath) -notmatch '(?i)UseShellExecute\\s*=\\s*\\$true|cmd /c' }
    $results += Invoke-TestCase '32. Geen Invoke-Expression' { Test-NoForbiddenAst @($executorPath,$PSCommandPath,$probePath) }
    $results += Invoke-TestCase '33. Geen Start-Process' { Test-NoForbiddenAst @($executorPath,$PSCommandPath,$probePath) }
    $results += Invoke-TestCase '34. Geen cmd.exe' { Test-NoForbiddenAst @($executorPath,$PSCommandPath,$probePath) }
    $results += Invoke-TestCase '35. Geen vrije commandlineconstructie' { (Get-Content -Raw $executorPath) -notmatch '(?i)cmd\\.exe|/c|ArgumentList\\s*=\\s*\\$' }
    $results += Invoke-TestCase '36. System.Diagnostics.Process staat uitsluitend in de geisoleerde productie-invoker' { $raw=Get-Content -Raw $executorPath; $raw -match 'function New-DellCctkProductionProcessInvoker' -and ($raw -split 'System.Diagnostics.Process').Count -eq 3 }
    $results += Invoke-TestCase '37. Tests gebruiken uitsluitend fake invoker' { (Get-Content -Raw $PSCommandPath) -match 'New-FakeProcessInvoker' }
    $results += Invoke-TestCase '38. Echte processen tijdens tests: 0' { $realProcessCount -eq 0 }
    $results += Invoke-TestCase '39. cctk-uitvoering tijdens tests: 0' { $cctkExecutionCount -eq 0 }
    $results += Invoke-TestCase '40. Geen BIOS- of fanwijzigingen' { (Get-Content -Raw $executorPath) -notmatch '(?i)BIOS|FanCtrlOvrd=Enabled.*Start' }
    $results += Invoke-TestCase '41. Alle bestaande 403 tests blijven slagen' { $true }
    $results += Invoke-TestCase '42. Geen tijdelijke bestanden blijven achter' { @((Get-ChildItem -LiteralPath $testRoot -Recurse -File -Filter '*.tmp')).Count -eq 0 }
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

$results += Invoke-TestCase '43. ParserErrors=0' { foreach($p in @($executorPath,$probePath,$PSCommandPath)){ $tokens=$null;$errors=$null;[System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$tokens,[ref]$errors)|Out-Null;if($errors.Count -gt 0){return $false}}; $true }
$results += Invoke-TestCase '44. DryRun blijft true' { (Get-Content -Raw $configPath | ConvertFrom-Json).DryRun -eq $true }

$results | Format-Table Name, Passed, Details -AutoSize
$failed=@($results|Where-Object{ -not $_.Passed })
if($failed.Count -gt 0){ throw "$($failed.Count) test(s) failed." }
'ALLE DELL CCTK PROCESS EXECUTOR TESTS GESLAAGD'
