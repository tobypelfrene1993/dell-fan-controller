[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$settingsScript = Join-Path $ScriptDirectory 'DellFanController-Settings.ps1'
$testRoot = Join-Path $ScriptDirectory 'test-output'

. $settingsScript

function New-TestResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details
    )

    [pscustomobject]@{
        Name = $Name
        Passed = $Passed
        Details = $Details
    }
}

function Invoke-TestCase {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    try {
        $ok = & $Action
        New-TestResult -Name $Name -Passed ([bool]$ok) -Details 'OK'
    }
    catch {
        New-TestResult -Name $Name -Passed $false -Details $_.Exception.Message
    }
}

function New-ConfigVariant {
    param([hashtable]$Overrides)

    $config = Get-DefaultControllerConfig
    foreach ($key in $Overrides.Keys) {
        $config.$key = $Overrides[$key]
    }
    $config
}

function Write-TestJson {
    param(
        [string]$Path,
        [object]$Config
    )

    Convert-ControllerConfigToJson -Config $Config | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Test-ForbiddenCommands {
    param([string[]]$Paths)

    $blockedCommandNames = @(
        'cctk',
        'cctk.exe',
        'schtasks',
        'schtasks.exe',
        'Register-ScheduledTask',
        'New-ScheduledTask',
        'New-Service',
        'Set-Service',
        'sc.exe',
        'reg.exe',
        'powercfg',
        'Stop-VM',
        'Restart-VM'
    )
    $writeCommandNames = @(
        'Set-ItemProperty',
        'New-ItemProperty',
        'Set-CimInstance',
        'Invoke-CimMethod',
        'Set-WmiInstance'
    )

    foreach ($path in $Paths) {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) {
            throw "Parserfouten in $path"
        }

        $commands = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true)

        foreach ($command in $commands) {
            $commandName = $command.GetCommandName()
            if ([string]::IsNullOrWhiteSpace($commandName)) {
                continue
            }
            $text = $command.Extent.Text
            if ($blockedCommandNames -contains $commandName) {
                throw "Verboden uitvoerbaar commando gevonden: $commandName"
            }
            if ($text -match '(?i)(FanCtrlOvrd\s*=|--?FanCtrlOvrd|Dell Command Configure)') {
                throw 'Verboden fan- of Dell Command Configure-actie gevonden.'
            }
            if ($commandName -eq 'Stop-Process' -and $text -match '(?i)(Core Temp|CoreTemp|cTrader|trading)') {
                throw 'Verboden Stop-Process-doel gevonden.'
            }
            if (($writeCommandNames -contains $commandName) -and
                ($text -match '(?i)(CurrentVersion\\Run|\\Startup\\|Power|BIOS|DellSmbios|DCIM_BIOS)')) {
                throw 'Verboden register-, energie-, startup- of BIOS-write gevonden.'
            }
        }
    }

    $true
}

if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$results = @()
$default = Get-DefaultControllerConfig

$results += Invoke-TestCase '1. Geldige standaardconfiguratie' { (Test-ControllerConfig -Config $default).IsValid }
$results += Invoke-TestCase '2. ThresholdCelsius onder 60' { -not (Test-ControllerConfig -Config (New-ConfigVariant @{ ThresholdCelsius = 59 })).IsValid }
$results += Invoke-TestCase '3. ThresholdCelsius boven 90' { -not (Test-ControllerConfig -Config (New-ConfigVariant @{ ThresholdCelsius = 91 })).IsValid }
$results += Invoke-TestCase '4. PollIntervalSeconds onder 15' { -not (Test-ControllerConfig -Config (New-ConfigVariant @{ PollIntervalSeconds = 14 })).IsValid }
$results += Invoke-TestCase '5. PollIntervalSeconds boven 300' { -not (Test-ControllerConfig -Config (New-ConfigVariant @{ PollIntervalSeconds = 301 })).IsValid }
$results += Invoke-TestCase '6. RequiredConsecutiveHighReadings buiten grenzen' {
    (-not (Test-ControllerConfig -Config (New-ConfigVariant @{ RequiredConsecutiveHighReadings = 0 })).IsValid) -and
    (-not (Test-ControllerConfig -Config (New-ConfigVariant @{ RequiredConsecutiveHighReadings = 11 })).IsValid)
}
$results += Invoke-TestCase '7. BoostDurationSeconds buiten grenzen' {
    (-not (Test-ControllerConfig -Config (New-ConfigVariant @{ BoostDurationSeconds = 29 })).IsValid) -and
    (-not (Test-ControllerConfig -Config (New-ConfigVariant @{ BoostDurationSeconds = 901 })).IsValid)
}
$results += Invoke-TestCase '8. CooldownSeconds buiten grenzen' {
    (-not (Test-ControllerConfig -Config (New-ConfigVariant @{ CooldownSeconds = 59 })).IsValid) -and
    (-not (Test-ControllerConfig -Config (New-ConfigVariant @{ CooldownSeconds = 3601 })).IsValid)
}
$results += Invoke-TestCase '9. DryRun met verkeerd datatype' { -not (Test-ControllerConfig -Config (New-ConfigVariant @{ DryRun = 'true' })).IsValid }
$results += Invoke-TestCase '10. Verkeerde SensorProvider' { -not (Test-ControllerConfig -Config (New-ConfigVariant @{ SensorProvider = 'Other' })).IsValid }
$results += Invoke-TestCase '11. Verkeerde SchemaVersion' { -not (Test-ControllerConfig -Config (New-ConfigVariant @{ SchemaVersion = 2 })).IsValid }
$results += Invoke-TestCase '12. Ontbrekend configuratiebestand' { -not (Read-ControllerConfig -Path (Join-Path $testRoot 'missing.json')).Exists }
$results += Invoke-TestCase '13. Corrupte JSON' {
    $path = Join-Path $testRoot 'corrupt.json'
    '{bad json' | Set-Content -LiteralPath $path -Encoding UTF8
    -not (Read-ControllerConfig -Path $path).IsValid
}
$results += Invoke-TestCase '14. Ontbrekende properties' {
    $config = [pscustomobject]@{ SchemaVersion = 1 }
    -not (Test-ControllerConfig -Config $config).IsValid
}
$results += Invoke-TestCase '15. Extra onbekende properties' {
    $config = Get-DefaultControllerConfig
    $config | Add-Member -NotePropertyName ExtraProperty -NotePropertyValue 1
    -not (Test-ControllerConfig -Config $config).IsValid
}
$results += Invoke-TestCase '16. Geldig opslaan' {
    $dir = Join-Path $testRoot 'save-valid'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [void](Save-ControllerConfigSafely -Config $default -BasePath $dir)
    (Read-ControllerConfig -Path (Join-Path $dir 'controller-config.json')).IsValid
}
$results += Invoke-TestCase '17. Tijdelijk bestand valideren' {
    $dir = Join-Path $testRoot 'temp-validate'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [void](Save-ControllerConfigSafely -Config $default -BasePath $dir)
    -not (Test-Path -LiteralPath (Join-Path $dir 'controller-config.json.tmp'))
}
$results += Invoke-TestCase '18. Backup maken' {
    $dir = Join-Path $testRoot 'backup'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [void](Save-ControllerConfigSafely -Config $default -BasePath $dir)
    [void](Save-ControllerConfigSafely -Config (New-ConfigVariant @{ ThresholdCelsius = 76 }) -BasePath $dir)
    Test-Path -LiteralPath (Join-Path $dir 'controller-config.json.bak')
}
$results += Invoke-TestCase '19. Bestaande config behouden bij een schrijffout' {
    $dir = Join-Path $testRoot 'preserve'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [void](Save-ControllerConfigSafely -Config $default -BasePath $dir)
    try {
        [void](Save-ControllerConfigSafely -Config (New-ConfigVariant @{ ThresholdCelsius = 80 }) -BasePath $dir -SimulateFailureAfterTempValidation)
    } catch {}
    $loaded = Read-ControllerConfig -Path (Join-Path $dir 'controller-config.json')
    $loaded.Config.ThresholdCelsius -eq 75
}
$results += Invoke-TestCase '20. Tijdelijk bestand verwijderen bij een fout' {
    $dir = Join-Path $testRoot 'tmp-clean'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    try {
        [void](Save-ControllerConfigSafely -Config $default -BasePath $dir -SimulateFailureAfterTempValidation)
    } catch {}
    -not (Test-Path -LiteralPath (Join-Path $dir 'controller-config.json.tmp'))
}
$results += Invoke-TestCase '21. Configuratie opnieuw laden na opslaan' {
    $dir = Join-Path $testRoot 'reload'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [void](Save-ControllerConfigSafely -Config (New-ConfigVariant @{ CooldownSeconds = 700 }) -BasePath $dir)
    (Read-ControllerConfig -Path (Join-Path $dir 'controller-config.json')).Config.CooldownSeconds -eq 700
}
$results += Invoke-TestCase '22. Nederlandse statusmeldingen' {
    $source = Get-Content -LiteralPath $settingsScript -Raw
    ($source -match 'Configuratie geladen') -and
    ($source -match 'Instellingen veilig opgeslagen') -and
    ($source -match 'Wijzigingen nog niet opgeslagen')
}
$results += Invoke-TestCase '23. Set-StrictMode-compatibiliteit' {
    Set-StrictMode -Version Latest
    (Test-ControllerConfig -Config (Get-DefaultControllerConfig)).IsValid
}
$results += Invoke-TestCase '24. Windows PowerShell 5.1 parsercontrole' {
    $files = @($settingsScript, $PSCommandPath)
    foreach ($file in $files) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count -gt 0) { return $false }
    }
    $true
}
$results += Invoke-TestCase '25. AST safetytests' {
    Test-ForbiddenCommands -Paths @($settingsScript, $PSCommandPath)
}

$results | Format-Table Name, Passed, Details -AutoSize

$failed = @($results | Where-Object { -not $_.Passed })
if ($failed.Count -gt 0) {
    throw "$($failed.Count) test(s) failed."
}

'ALLE SETTINGS-APP TESTS GESLAAGD'
