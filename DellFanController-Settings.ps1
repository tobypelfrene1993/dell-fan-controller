[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Get-DefaultControllerConfig {
    [pscustomobject]@{
        SchemaVersion = 1
        ThresholdCelsius = 75
        PollIntervalSeconds = 60
        RequiredConsecutiveHighReadings = 2
        BoostDurationSeconds = 300
        CooldownSeconds = 600
        DryRun = $true
        SensorProvider = 'CoreTempSharedMemory'
    }
}

function Get-ControllerConfigPath {
    param([string]$BasePath)

    $root = if ([string]::IsNullOrWhiteSpace($BasePath)) {
        if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    } else {
        $BasePath
    }

    [pscustomobject]@{
        Root = $root
        Active = Join-Path $root 'controller-config.json'
        Backup = Join-Path $root 'controller-config.json.bak'
        Temp = Join-Path $root 'controller-config.json.tmp'
        Example = Join-Path $root 'controller-config.example.json'
    }
}

function New-ValidationResult {
    param(
        [bool]$IsValid,
        [string[]]$Errors,
        [object]$Config
    )

    [pscustomobject]@{
        IsValid = $IsValid
        Errors = @($Errors)
        Config = $Config
    }
}

function Test-IntegerField {
    param(
        [object]$Value,
        [string]$Name,
        [int]$Minimum,
        [int]$Maximum,
        [ref]$Errors
    )

    if ($null -eq $Value -or $Value -is [bool]) {
        $Errors.Value += "$Name moet een geheel getal zijn."
        return $null
    }

    $number = 0
    if (-not [int]::TryParse(([string]$Value), [ref]$number)) {
        $Errors.Value += "$Name moet een geheel getal zijn."
        return $null
    }

    if ($number -lt $Minimum -or $number -gt $Maximum) {
        $Errors.Value += "$Name moet tussen $Minimum en $Maximum liggen."
        return $null
    }

    return [int]$number
}

function Test-ControllerConfig {
    param([object]$Config)

    $errors = @()
    if ($null -eq $Config) {
        return New-ValidationResult -IsValid $false -Errors @('Configuratie ontbreekt.') -Config $null
    }

    $required = @(
        'SchemaVersion',
        'ThresholdCelsius',
        'PollIntervalSeconds',
        'RequiredConsecutiveHighReadings',
        'BoostDurationSeconds',
        'CooldownSeconds',
        'DryRun',
        'SensorProvider'
    )
    $names = @($Config.PSObject.Properties | ForEach-Object { $_.Name })

    foreach ($name in $required) {
        if ($names -notcontains $name) {
            $errors += "Verplicht veld ontbreekt: $name."
        }
    }
    foreach ($name in $names) {
        if ($required -notcontains $name) {
            $errors += "Onbekend veld is niet toegestaan: $name."
        }
    }

    if ($errors.Count -gt 0) {
        return New-ValidationResult -IsValid $false -Errors $errors -Config $null
    }

    $schemaVersion = Test-IntegerField -Value $Config.SchemaVersion -Name 'SchemaVersion' -Minimum 1 -Maximum 1 -Errors ([ref]$errors)
    $threshold = Test-IntegerField -Value $Config.ThresholdCelsius -Name 'ThresholdCelsius' -Minimum 60 -Maximum 90 -Errors ([ref]$errors)
    $poll = Test-IntegerField -Value $Config.PollIntervalSeconds -Name 'PollIntervalSeconds' -Minimum 15 -Maximum 300 -Errors ([ref]$errors)
    $high = Test-IntegerField -Value $Config.RequiredConsecutiveHighReadings -Name 'RequiredConsecutiveHighReadings' -Minimum 1 -Maximum 10 -Errors ([ref]$errors)
    $boost = Test-IntegerField -Value $Config.BoostDurationSeconds -Name 'BoostDurationSeconds' -Minimum 30 -Maximum 900 -Errors ([ref]$errors)
    $cooldown = Test-IntegerField -Value $Config.CooldownSeconds -Name 'CooldownSeconds' -Minimum 60 -Maximum 3600 -Errors ([ref]$errors)

    if ($Config.DryRun -isnot [bool]) {
        $errors += 'DryRun moet true of false zijn.'
    }

    if ([string]$Config.SensorProvider -ne 'CoreTempSharedMemory') {
        $errors += 'SensorProvider moet CoreTempSharedMemory zijn.'
    }

    if ($errors.Count -gt 0) {
        return New-ValidationResult -IsValid $false -Errors $errors -Config $null
    }

    $validated = [pscustomobject]@{
        SchemaVersion = [int]$schemaVersion
        ThresholdCelsius = [int]$threshold
        PollIntervalSeconds = [int]$poll
        RequiredConsecutiveHighReadings = [int]$high
        BoostDurationSeconds = [int]$boost
        CooldownSeconds = [int]$cooldown
        DryRun = [bool]$Config.DryRun
        SensorProvider = 'CoreTempSharedMemory'
    }

    New-ValidationResult -IsValid $true -Errors @() -Config $validated
}

function Read-ControllerConfig {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Exists = $false
            IsValid = $false
            Config = $null
            Errors = @('Configuratiebestand ontbreekt.')
        }
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw
        $parsed = $raw | ConvertFrom-Json
        $validation = Test-ControllerConfig -Config $parsed
        [pscustomobject]@{
            Exists = $true
            IsValid = [bool]$validation.IsValid
            Config = $validation.Config
            Errors = @($validation.Errors)
        }
    }
    catch {
        [pscustomobject]@{
            Exists = $true
            IsValid = $false
            Config = $null
            Errors = @("Fout bij laden: $($_.Exception.Message)")
        }
    }
}

function Convert-GuiToControllerConfig {
    param([hashtable]$Controls)

    [pscustomobject]@{
        SchemaVersion = 1
        ThresholdCelsius = [int]$Controls.Threshold.Value
        PollIntervalSeconds = [int]$Controls.PollInterval.Value
        RequiredConsecutiveHighReadings = [int]$Controls.HighReadings.Value
        BoostDurationSeconds = [int]$Controls.BoostDuration.Value
        CooldownSeconds = [int]$Controls.Cooldown.Value
        DryRun = [bool]$Controls.DryRun.Checked
        SensorProvider = 'CoreTempSharedMemory'
    }
}

function Set-GuiFromControllerConfig {
    param(
        [hashtable]$Controls,
        [object]$Config
    )

    $Controls.Threshold.Value = [decimal]$Config.ThresholdCelsius
    $Controls.PollInterval.Value = [decimal]$Config.PollIntervalSeconds
    $Controls.HighReadings.Value = [decimal]$Config.RequiredConsecutiveHighReadings
    $Controls.BoostDuration.Value = [decimal]$Config.BoostDurationSeconds
    $Controls.Cooldown.Value = [decimal]$Config.CooldownSeconds
    $Controls.DryRun.Checked = [bool]$Config.DryRun
    $Controls.SensorProvider.Text = [string]$Config.SensorProvider
}

function Convert-ControllerConfigToJson {
    param([object]$Config)

    $ordered = [ordered]@{
        SchemaVersion = [int]$Config.SchemaVersion
        ThresholdCelsius = [int]$Config.ThresholdCelsius
        PollIntervalSeconds = [int]$Config.PollIntervalSeconds
        RequiredConsecutiveHighReadings = [int]$Config.RequiredConsecutiveHighReadings
        BoostDurationSeconds = [int]$Config.BoostDurationSeconds
        CooldownSeconds = [int]$Config.CooldownSeconds
        DryRun = [bool]$Config.DryRun
        SensorProvider = [string]$Config.SensorProvider
    }

    ([pscustomobject]$ordered) | ConvertTo-Json -Depth 4
}

function Save-ControllerConfigSafely {
    param(
        [object]$Config,
        [string]$BasePath,
        [switch]$SimulateFailureAfterTempValidation
    )

    $paths = Get-ControllerConfigPath -BasePath $BasePath
    if (-not (Test-Path -LiteralPath $paths.Root -PathType Container)) {
        throw "Projectmap bestaat niet: $($paths.Root)"
    }

    $validation = Test-ControllerConfig -Config $Config
    if (-not $validation.IsValid) {
        throw "Configuratie ongeldig: $(@($validation.Errors) -join '; ')"
    }

    $json = Convert-ControllerConfigToJson -Config $validation.Config
    try {
        Set-Content -LiteralPath $paths.Temp -Value $json -Encoding UTF8

        $tempRead = Read-ControllerConfig -Path $paths.Temp
        if (-not $tempRead.IsValid) {
            throw "Tijdelijk JSON-bestand is ongeldig: $(@($tempRead.Errors) -join '; ')"
        }

        if ($SimulateFailureAfterTempValidation) {
            throw 'Gesimuleerde schrijffout na tijdelijke validatie.'
        }

        $activeRead = Read-ControllerConfig -Path $paths.Active
        if ($activeRead.Exists -and $activeRead.IsValid) {
            [System.IO.File]::Replace($paths.Temp, $paths.Active, $paths.Backup, $true)
        } else {
            Move-Item -LiteralPath $paths.Temp -Destination $paths.Active -Force
        }

        [pscustomobject]@{
            Success = $true
            ActivePath = $paths.Active
            BackupPath = $paths.Backup
            TempPath = $paths.Temp
        }
    }
    catch {
        if (Test-Path -LiteralPath $paths.Temp -PathType Leaf) {
            Remove-Item -LiteralPath $paths.Temp -Force
        }
        throw
    }
}

function Set-StatusMessage {
    param(
        [System.Windows.Forms.Label]$Label,
        [string]$Message,
        [System.Drawing.Color]$Color
    )

    $Label.Text = $Message
    $Label.ForeColor = $Color
}

function Show-DryRunWarning {
    $message = "Dry-run uitschakelen betekent dat een toekomstige controller echte fancommando's zou kunnen uitvoeren. Dit instellingenprogramma voert zelf geen fancommando's uit. Weet je zeker dat je Dry-run wilt uitschakelen?"
    $result = [System.Windows.Forms.MessageBox]::Show(
        $message,
        'Dry-run uitschakelen',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2
    )
    return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
}

function New-NumberInput {
    param(
        [int]$Minimum,
        [int]$Maximum,
        [int]$Value
    )

    $input = New-Object System.Windows.Forms.NumericUpDown
    $input.Minimum = [decimal]$Minimum
    $input.Maximum = [decimal]$Maximum
    $input.Value = [decimal]$Value
    $input.Width = 110
    $input.TextAlign = 'Right'
    $input
}

function Show-SettingsApp {
    $paths = Get-ControllerConfigPath
    $defaultConfig = Get-DefaultControllerConfig

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Dell Fan Controller - Instellingen'
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $true
    $form.ClientSize = New-Object System.Drawing.Size(560, 430)

    $warning = New-Object System.Windows.Forms.Label
    $warning.Text = 'Deze applicatie past alleen configuratie aan. De ventilator wordt vanuit dit venster niet bediend.'
    $warning.Location = New-Object System.Drawing.Point(16, 14)
    $warning.Size = New-Object System.Drawing.Size(528, 36)
    $warning.ForeColor = [System.Drawing.Color]::DarkRed
    $warning.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($warning)

    $dryRunWarning = New-Object System.Windows.Forms.Label
    $dryRunWarning.Text = ''
    $dryRunWarning.Location = New-Object System.Drawing.Point(16, 302)
    $dryRunWarning.Size = New-Object System.Drawing.Size(528, 24)
    $dryRunWarning.ForeColor = [System.Drawing.Color]::DarkOrange
    $form.Controls.Add($dryRunWarning)

    $controls = @{}
    $labels = @(
        @{ Text = 'Temperatuurdrempel (C)'; Key = 'Threshold'; Min = 60; Max = 90; Value = 75 },
        @{ Text = 'Controle-interval (seconden)'; Key = 'PollInterval'; Min = 15; Max = 300; Value = 60 },
        @{ Text = 'Opeenvolgende hoge metingen'; Key = 'HighReadings'; Min = 1; Max = 10; Value = 2 },
        @{ Text = 'Duur fanboost (seconden)'; Key = 'BoostDuration'; Min = 30; Max = 900; Value = 300 },
        @{ Text = 'Cooldown (seconden)'; Key = 'Cooldown'; Min = 60; Max = 3600; Value = 600 }
    )

    $top = 62
    foreach ($row in $labels) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $row.Text
        $label.Location = New-Object System.Drawing.Point(28, $top)
        $label.Size = New-Object System.Drawing.Size(260, 24)
        $form.Controls.Add($label)

        $input = New-NumberInput -Minimum $row.Min -Maximum $row.Max -Value $row.Value
        $input.Location = New-Object System.Drawing.Point(322, ($top - 2))
        $form.Controls.Add($input)
        $controls[$row.Key] = $input
        $top += 38
    }

    $dryRun = New-Object System.Windows.Forms.CheckBox
    $dryRun.Text = 'Dry-run'
    $dryRun.Checked = $true
    $dryRun.Location = New-Object System.Drawing.Point(28, $top)
    $dryRun.Size = New-Object System.Drawing.Size(180, 24)
    $form.Controls.Add($dryRun)
    $controls.DryRun = $dryRun

    $sensorLabel = New-Object System.Windows.Forms.Label
    $sensorLabel.Text = 'Sensorbron'
    $sensorLabel.Location = New-Object System.Drawing.Point(28, ($top + 38))
    $sensorLabel.Size = New-Object System.Drawing.Size(260, 24)
    $form.Controls.Add($sensorLabel)

    $sensor = New-Object System.Windows.Forms.TextBox
    $sensor.ReadOnly = $true
    $sensor.Text = 'CoreTempSharedMemory'
    $sensor.Location = New-Object System.Drawing.Point(322, ($top + 36))
    $sensor.Size = New-Object System.Drawing.Size(190, 24)
    $form.Controls.Add($sensor)
    $controls.SensorProvider = $sensor

    $status = New-Object System.Windows.Forms.Label
    $status.Text = ''
    $status.BorderStyle = 'Fixed3D'
    $status.Location = New-Object System.Drawing.Point(0, 402)
    $status.Size = New-Object System.Drawing.Size(560, 28)
    $status.TextAlign = 'MiddleLeft'
    $form.Controls.Add($status)

    $buttonCheck = New-Object System.Windows.Forms.Button
    $buttonCheck.Text = 'Configuratie controleren'
    $buttonCheck.Location = New-Object System.Drawing.Point(16, 340)
    $buttonCheck.Size = New-Object System.Drawing.Size(150, 32)
    $form.Controls.Add($buttonCheck)

    $buttonSave = New-Object System.Windows.Forms.Button
    $buttonSave.Text = 'Instellingen opslaan'
    $buttonSave.Location = New-Object System.Drawing.Point(176, 340)
    $buttonSave.Size = New-Object System.Drawing.Size(130, 32)
    $form.Controls.Add($buttonSave)

    $buttonDefaults = New-Object System.Windows.Forms.Button
    $buttonDefaults.Text = 'Standaardwaarden herstellen'
    $buttonDefaults.Location = New-Object System.Drawing.Point(316, 340)
    $buttonDefaults.Size = New-Object System.Drawing.Size(160, 32)
    $form.Controls.Add($buttonDefaults)

    $buttonCancel = New-Object System.Windows.Forms.Button
    $buttonCancel.Text = 'Annuleren'
    $buttonCancel.Location = New-Object System.Drawing.Point(484, 340)
    $buttonCancel.Size = New-Object System.Drawing.Size(64, 32)
    $form.Controls.Add($buttonCancel)

    $markDirty = {
        Set-StatusMessage -Label $status -Message 'Wijzigingen nog niet opgeslagen' -Color ([System.Drawing.Color]::DarkOrange)
    }
    foreach ($key in @('Threshold', 'PollInterval', 'HighReadings', 'BoostDuration', 'Cooldown')) {
        $controls[$key].Add_ValueChanged($markDirty)
    }

    $dryRun.Add_CheckedChanged({
        if (-not $dryRun.Checked) {
            if (-not (Show-DryRunWarning)) {
                $dryRun.Checked = $true
                return
            }
            $dryRunWarning.Text = 'Waarschuwing: Dry-run is uitgeschakeld voor toekomstige controllerlogica.'
            $dryRunWarning.ForeColor = [System.Drawing.Color]::DarkRed
        } else {
            $dryRunWarning.Text = ''
        }
        & $markDirty
    })

    $buttonCheck.Add_Click({
        $config = Convert-GuiToControllerConfig -Controls $controls
        $validation = Test-ControllerConfig -Config $config
        if ($validation.IsValid) {
            Set-StatusMessage -Label $status -Message 'Configuratie geldig' -Color ([System.Drawing.Color]::DarkGreen)
        } else {
            Set-StatusMessage -Label $status -Message ("Fout bij laden: $(@($validation.Errors) -join '; ')") -Color ([System.Drawing.Color]::DarkRed)
        }
    })

    $buttonSave.Add_Click({
        try {
            $config = Convert-GuiToControllerConfig -Controls $controls
            [void](Save-ControllerConfigSafely -Config $config -BasePath $paths.Root)
            Set-StatusMessage -Label $status -Message 'Instellingen veilig opgeslagen' -Color ([System.Drawing.Color]::DarkGreen)
            [System.Windows.Forms.MessageBox]::Show('Instellingen veilig opgeslagen.', 'Opgeslagen', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
        catch {
            Set-StatusMessage -Label $status -Message 'Fout bij opslaan' -Color ([System.Drawing.Color]::DarkRed)
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Fout bij opslaan', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    })

    $buttonDefaults.Add_Click({
        $answer = [System.Windows.Forms.MessageBox]::Show('Standaardwaarden herstellen? Er wordt nog niets opgeslagen.', 'Bevestigen', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            Set-GuiFromControllerConfig -Controls $controls -Config $defaultConfig
            Set-StatusMessage -Label $status -Message 'Standaardwaarden geladen' -Color ([System.Drawing.Color]::DarkBlue)
        }
    })

    $buttonCancel.Add_Click({
        $form.Close()
    })

    $load = Read-ControllerConfig -Path $paths.Active
    if ($load.Exists -and $load.IsValid) {
        Set-GuiFromControllerConfig -Controls $controls -Config $load.Config
        Set-StatusMessage -Label $status -Message 'Configuratie geladen' -Color ([System.Drawing.Color]::DarkGreen)
    } elseif (-not $load.Exists) {
        Set-GuiFromControllerConfig -Controls $controls -Config $defaultConfig
        Set-StatusMessage -Label $status -Message 'Geen configuratie gevonden. Standaardwaarden geladen.' -Color ([System.Drawing.Color]::DarkBlue)
    } else {
        $backup = Read-ControllerConfig -Path $paths.Backup
        if ($backup.Exists -and $backup.IsValid) {
            $answer = [System.Windows.Forms.MessageBox]::Show("Fout bij laden. Geldige backup gevonden. Backup laden?", 'Fout bij laden', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
                Set-GuiFromControllerConfig -Controls $controls -Config $backup.Config
                Set-StatusMessage -Label $status -Message 'Configuratie geladen' -Color ([System.Drawing.Color]::DarkGreen)
            } else {
                Set-GuiFromControllerConfig -Controls $controls -Config $defaultConfig
                Set-StatusMessage -Label $status -Message 'Fout bij laden' -Color ([System.Drawing.Color]::DarkRed)
            }
        } else {
            Set-GuiFromControllerConfig -Controls $controls -Config $defaultConfig
            Set-StatusMessage -Label $status -Message 'Fout bij laden' -Color ([System.Drawing.Color]::DarkRed)
            [System.Windows.Forms.MessageBox]::Show(($load.Errors -join "`r`n"), 'Fout bij laden', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    }

    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::Run($form)
}

if ($MyInvocation.InvocationName -ne '.') {
    Show-SettingsApp
}
