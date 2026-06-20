[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$modulePath = Join-Path $ScriptDirectory 'DellFanController-State.ps1'
$configPath = Join-Path $ScriptDirectory 'controller-config.json'
$dryRunPath = Join-Path $ScriptDirectory 'DellFanController-DryRun.ps1'
$configBefore = if (Test-Path -LiteralPath $configPath -PathType Leaf) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) } else { $null }
$dryRunBefore = if (Test-Path -LiteralPath $dryRunPath -PathType Leaf) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($dryRunPath)) } else { $null }
$testRoot = Join-Path $ScriptDirectory ("test-output\controller-state-{0}" -f ([guid]::NewGuid().ToString('N')))

. $modulePath

function New-TestResult {
    param([string]$Name, [bool]$Passed, [string]$Details)
    [pscustomobject]@{ Name = $Name; Passed = $Passed; Details = $Details }
}

function Invoke-TestCase {
    param([string]$Name, [scriptblock]$Action)
    try {
        New-TestResult -Name $Name -Passed ([bool](& $Action)) -Details 'OK'
    }
    catch {
        New-TestResult -Name $Name -Passed $false -Details $_.Exception.Message
    }
}

function New-TestState {
    New-ControllerState -ControllerInstanceId ([guid]::NewGuid().ToString()) -CorrelationId ([guid]::NewGuid().ToString()) -BackendName 'MockFanBackend'
}

function Save-RawJson {
    param([string]$Path, [string]$Json)
    Set-Content -LiteralPath $Path -Value $Json -Encoding UTF8
}

function Test-NoForbiddenAst {
    param([string[]]$Paths)
    $blockedCommands = @(
        'Start-Process',
        'Invoke-Expression',
        'cctk',
        'cctk.exe',
        'Set-CimInstance',
        'Invoke-CimMethod',
        'Set-WmiInstance',
        'Register-ScheduledTask',
        'New-Service',
        'Set-Service'
    )
    $writeCommands = @(
        'Set-CimInstance',
        'Invoke-CimMethod',
        'Set-WmiInstance',
        'Set-ItemProperty',
        'New-ItemProperty'
    )
    foreach ($path in $Paths) {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "Parserfout in $path" }

        $types = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.TypeExpressionAst] }, $true)
        foreach ($type in $types) {
            if ($type.TypeName.FullName -eq 'System.Diagnostics.Process') {
                throw 'Verboden System.Diagnostics.Process typegebruik gevonden.'
            }
        }

        $commands = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($command in $commands) {
            $name = $command.GetCommandName()
            $text = $command.Extent.Text
            if ($blockedCommands -contains $name) { throw "Verboden commando gevonden: $name" }
            if (($writeCommands -contains $name) -and $text -match '(?i)(FanCtrlOvrd\s*=|--?FanCtrlOvrd|Dell Command Configure|BIOS.*write)') {
                throw 'Verboden uitvoerbare code gevonden.'
            }
        }
    }
    $true
}

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$results = @()

try {
    $results += Invoke-TestCase '1. Nieuw stateobject is geldig' { (Test-ControllerState -State (New-TestState)).IsValid }
    $results += Invoke-TestCase '2. SchemaVersion ongeldig wordt geweigerd' { $s=New-TestState; $s.SchemaVersion=2; -not (Test-ControllerState $s).IsValid }
    $results += Invoke-TestCase '3. Ontbrekende property wordt geweigerd' { $s=New-TestState; $s.PSObject.Properties.Remove('BackendName'); -not (Test-ControllerState $s).IsValid }
    $results += Invoke-TestCase '4. Extra property wordt geweigerd' { $s=New-TestState; $s | Add-Member -NotePropertyName Extra -NotePropertyValue 1; -not (Test-ControllerState $s).IsValid }
    $results += Invoke-TestCase '5. Ongeldige ControllerInstanceId wordt geweigerd' { $s=New-TestState; $s.ControllerInstanceId='bad'; -not (Test-ControllerState $s).IsValid }
    $results += Invoke-TestCase '6. Ongeldige CorrelationId wordt geweigerd' { $s=New-TestState; $s.CorrelationId='bad'; -not (Test-ControllerState $s).IsValid }
    $results += Invoke-TestCase '7. Ongeldige OperationPhase wordt geweigerd' { $s=New-TestState; $s.OperationPhase='Bad'; -not (Test-ControllerState $s).IsValid }
    $results += Invoke-TestCase '8. Ongeldige PreviousFanState wordt geweigerd' { $s=New-TestState; $s.PreviousFanState='Manual'; -not (Test-ControllerState $s).IsValid }
    $results += Invoke-TestCase '9. Ongeldige CurrentRequestedState wordt geweigerd' { $s=New-TestState; $s.CurrentRequestedState='Manual'; -not (Test-ControllerState $s).IsValid }
    $results += Invoke-TestCase '10. Ongeldige UTC-timestamp wordt geweigerd' { $s=New-TestState; $s.UpdatedAtUtc='2026-01-01 10:00'; -not (Test-ControllerState $s).IsValid }
    $results += Invoke-TestCase '11. Idle-consistentieregels worden afgedwongen' { $s=New-TestState; $s.CurrentRequestedState='BoostEnabled'; -not (Test-ControllerState $s).IsValid }
    $results += Invoke-TestCase '12. EnablePending-consistentieregels worden afgedwongen' { $s=New-TestState; $s.OperationPhase='EnablePending'; $s.CurrentRequestedState='Automatic'; -not (Test-ControllerState $s).IsValid }
    $results += Invoke-TestCase '13. ActiveVerified vereist ownership true' { $s=Set-ControllerStatePhase (New-TestState) 'ActiveVerified'; $s.FanOverrideActivatedByThisApp=$false; -not (Test-ControllerState $s).IsValid }
    $results += Invoke-TestCase '14. ActiveVerified vereist ActivatedAtUtc' { $s=Set-ControllerStatePhase (New-TestState) 'ActiveVerified'; $s.ActivatedAtUtc=$null; -not (Test-ControllerState $s).IsValid }
    $results += Invoke-TestCase '15. ActiveVerified vereist verification timestamp' { $s=Set-ControllerStatePhase (New-TestState) 'ActiveVerified'; $s.LastSuccessfulVerificationUtc=$null; -not (Test-ControllerState $s).IsValid }
    $results += Invoke-TestCase '16. DisablePending-consistentieregels worden afgedwongen' { $s=Set-ControllerStatePhase (New-TestState) 'DisablePending'; $s.FanOverrideActivatedByThisApp=$false; -not (Test-ControllerState $s).IsValid }
    $results += Invoke-TestCase '17. CleanupRequired vereist emergency flag' { $s=Mark-ControllerEmergencyReset (New-TestState) 'error'; $s.RequiresEmergencyReset=$false; -not (Test-ControllerState $s).IsValid }
    $results += Invoke-TestCase '18. CleanupRequired vereist LastError' { $s=Mark-ControllerEmergencyReset (New-TestState) 'error'; $s.LastError=$null; -not (Test-ControllerState $s).IsValid }
    $results += Invoke-TestCase '19. Restored-consistentieregels worden afgedwongen' { $s=Set-ControllerStatePhase (New-TestState) 'Restored'; $s.RequiresEmergencyReset=$true; -not (Test-ControllerState $s).IsValid }
    $results += Invoke-TestCase '20. Eerste atomic write maakt geldig actief bestand' { $p=Join-Path $testRoot 'state20.json'; $r=Write-ControllerStateAtomic $p (New-TestState); $r.Success -and (Read-ControllerState $p).Success }
    $results += Invoke-TestCase '21. Eerste write maakt geen onnodige backup' { $p=Join-Path $testRoot 'state21.json'; $r=Write-ControllerStateAtomic $p (New-TestState); $r.Success -and -not (Test-Path "$p.bak") }
    $results += Invoke-TestCase '22. Tweede atomic write bewaart vorige geldige state in backup' { $p=Join-Path $testRoot 'state22.json'; [void](Write-ControllerStateAtomic $p (New-TestState)); $s=Set-ControllerStatePhase (New-TestState) 'EnablePending'; $r=Write-ControllerStateAtomic $p $s; $r.Success -and $r.BackupCreated -and (Test-Path "$p.bak") }
    $results += Invoke-TestCase '23. Roundtrip write/read behoudt alle waarden' { $p=Join-Path $testRoot 'state23.json'; $s=Set-ControllerStatePhase (New-TestState) 'EnablePending'; [void](Write-ControllerStateAtomic $p $s); $read=Read-ControllerState $p; $read.State.OperationPhase -eq 'EnablePending' -and $read.State.ControllerInstanceId -eq $s.ControllerInstanceId }
    $results += Invoke-TestCase '24. Corrupt actief bestand plus geldige backup leest backup' { $p=Join-Path $testRoot 'state24.json'; $b="$p.bak"; $s=New-TestState; Save-RawJson $b (Convert-ControllerStateToJson $s); Save-RawJson $p '{bad'; $r=Read-ControllerState $p $b; $r.Success -and $r.Source -eq 'Backup' -and $r.RecoveredFromBackup }
    $results += Invoke-TestCase '25. Corrupt actief bestand zonder geldige backup faalt gesloten' { $p=Join-Path $testRoot 'state25.json'; Save-RawJson $p '{bad'; $r=Read-ControllerState $p; -not $r.Success -and $r.Found }
    $results += Invoke-TestCase '26. Corrupt actief bestand wordt niet overschreven' { $p=Join-Path $testRoot 'state26.json'; Save-RawJson $p '{bad'; $before=Get-Content $p -Raw; $r=Write-ControllerStateAtomic $p (New-TestState); (-not $r.Success) -and ((Get-Content $p -Raw) -eq $before) }
    $results += Invoke-TestCase '27. Geldig actief bestand heeft voorkeur boven backup' { $p=Join-Path $testRoot 'state27.json'; $b="$p.bak"; $active=Set-ControllerStatePhase (New-TestState) 'EnablePending'; $backup=New-TestState; Save-RawJson $p (Convert-ControllerStateToJson $active); Save-RawJson $b (Convert-ControllerStateToJson $backup); (Read-ControllerState $p $b).Source -eq 'Active' }
    $results += Invoke-TestCase '28. Tijdelijke bestanden worden verwijderd na succesvolle write' { $p=Join-Path $testRoot 'state28.json'; [void](Write-ControllerStateAtomic $p (New-TestState)); @((Get-ChildItem $testRoot -Filter '*.tmp' -File)).Count -eq 0 }
    $results += Invoke-TestCase '29. Tijdelijke bestanden worden verwijderd na geforceerde fout' { $p=Join-Path $testRoot 'state29.json'; [void](Write-ControllerStateAtomic $p (New-TestState)); $badBackup=Join-Path $testRoot 'missing-dir\state29.bak'; [void](Write-ControllerStateAtomic $p (Set-ControllerStatePhase (New-TestState) 'EnablePending') $badBackup); @((Get-ChildItem $testRoot -Filter '*.tmp' -File)).Count -eq 0 }
    $results += Invoke-TestCase '30. Clear werkt bij volledig Restored state' { $p=Join-Path $testRoot 'state30.json'; [void](Write-ControllerStateAtomic $p (Set-ControllerStatePhase (New-TestState) 'Restored')); $r=Clear-ControllerState $p; $r.Success -and -not (Test-Path $p) }
    $results += Invoke-TestCase '31. Clear wordt geweigerd bij ActiveVerified' { $p=Join-Path $testRoot 'state31.json'; [void](Write-ControllerStateAtomic $p (Set-ControllerStatePhase (New-TestState) 'ActiveVerified')); -not (Clear-ControllerState $p).Success }
    $results += Invoke-TestCase '32. Clear wordt geweigerd bij CleanupRequired' { $p=Join-Path $testRoot 'state32.json'; [void](Write-ControllerStateAtomic $p (Mark-ControllerEmergencyReset (New-TestState) 'error')); -not (Clear-ControllerState $p).Success }
    $results += Invoke-TestCase '33. Emergency markering zet correcte velden' { $s=Mark-ControllerEmergencyReset (New-TestState) 'boom'; $s.OperationPhase -eq 'CleanupRequired' -and $s.RequiresEmergencyReset -and $s.LastError -eq 'boom' }
    $results += Invoke-TestCase '34. RecoveryDecision voor Idle is NoAction' { (Get-ControllerRecoveryDecision (New-TestState)).Action -eq 'NoAction' }
    $results += Invoke-TestCase '35. RecoveryDecision voor EnablePending blokkeert nieuwe enable' { $d=Get-ControllerRecoveryDecision (Set-ControllerStatePhase (New-TestState) 'EnablePending'); $d.Action -eq 'VerifyBackendState' -and -not $d.AllowNewEnable }
    $results += Invoke-TestCase '36. RecoveryDecision voor ActiveVerified vereist restore' { (Get-ControllerRecoveryDecision (Set-ControllerStatePhase (New-TestState) 'ActiveVerified')).Action -eq 'RestoreAutomatic' }
    $results += Invoke-TestCase '37. RecoveryDecision voor CleanupRequired vereist emergency reset' { (Get-ControllerRecoveryDecision (Mark-ControllerEmergencyReset (New-TestState) 'error')).Action -eq 'EmergencyResetRequired' }
    $results += Invoke-TestCase '38. Inputobject blijft ongewijzigd wanneer phase transition faalt' { $s=New-TestState; $before=$s.OperationPhase; try { [void](Set-ControllerStatePhase $s 'CleanupRequired') } catch {}; $s.OperationPhase -eq $before }
    $results += Invoke-TestCase '39. Module en testscript hebben geen PowerShell-parserfouten' { foreach($p in @($modulePath,$PSCommandPath)){ $tokens=$null;$errors=$null;[System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$tokens,[ref]$errors)|Out-Null; if($errors.Count -ne 0){return $false}}; $true }
    $results += Invoke-TestCase '40. AST-safetytest: geen Start-Process' { Test-NoForbiddenAst @($modulePath,$PSCommandPath) }
    $results += Invoke-TestCase '41. AST-safetytest: geen System.Diagnostics.Process' { Test-NoForbiddenAst @($modulePath,$PSCommandPath) }
    $results += Invoke-TestCase '42. AST-safetytest: geen Invoke-Expression' { Test-NoForbiddenAst @($modulePath,$PSCommandPath) }
    $results += Invoke-TestCase '43. AST-safetytest: geen cctk-aanroep' { Test-NoForbiddenAst @($modulePath,$PSCommandPath) }
    $results += Invoke-TestCase '44. AST-safetytest: geen Dell-, BIOS- of fan-writecommando''s' { Test-NoForbiddenAst @($modulePath,$PSCommandPath) }
    $results += Invoke-TestCase '45. controller-config.json is na de tests byte-for-byte ongewijzigd' { [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -eq $configBefore }
    $results += Invoke-TestCase '46. DellFanController-DryRun.ps1 is na de tests byte-for-byte ongewijzigd' { [Convert]::ToBase64String([IO.File]::ReadAllBytes($dryRunPath)) -eq $dryRunBefore }
    $results += Invoke-TestCase '47. Geen tijdelijk statebestand blijft achter in de projectroot' { @((Get-ChildItem -LiteralPath $ScriptDirectory -Filter '*.tmp' -File)).Count -eq 0 }
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

$results += Invoke-TestCase '48. Testdirectory wordt na afloop opgeruimd' { -not (Test-Path -LiteralPath $testRoot) }

$results | Format-Table Name, Passed, Details -AutoSize
$failed = @($results | Where-Object { -not $_.Passed })
if ($failed.Count -gt 0) { throw "$($failed.Count) test(s) failed." }
'ALLE CONTROLLER STATE TESTS GESLAAGD'
