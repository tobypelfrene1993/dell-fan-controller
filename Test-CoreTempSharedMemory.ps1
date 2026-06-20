[CmdletBinding()]
param(
    [string]$ConfigPath,
    [int]$DurationSeconds = 0,
    [int]$IntervalSeconds = 0,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $ScriptDirectory 'coretemp-config.example.json'
}

function Write-Step {
    param([string]$Message)
    Write-Host ("[{0}] Stap: {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

function Write-PhaseError {
    param(
        [string]$Phase,
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    Write-Host "FOUTFASE: $Phase" -ForegroundColor Red
    Write-Host "Exception type: $($ErrorRecord.Exception.GetType().FullName)"
    Write-Host "Message: $($ErrorRecord.Exception.Message)"
    Write-Host "Inner exception: $($ErrorRecord.Exception.InnerException)"
    Write-Host "Script name: $($ErrorRecord.InvocationInfo.ScriptName)"
    Write-Host "Script line: $($ErrorRecord.InvocationInfo.ScriptLineNumber)"
    Write-Host "Column: $($ErrorRecord.InvocationInfo.OffsetInLine)"
    Write-Host "Function: $($ErrorRecord.InvocationInfo.MyCommand)"
    Write-Host "Script stacktrace: $($ErrorRecord.ScriptStackTrace)"
    Write-Host "Position: $($ErrorRecord.InvocationInfo.PositionMessage)"
}

function Invoke-Phase {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    try {
        Write-Step $Name
        & $Action
    }
    catch {
        Write-PhaseError -Phase $Name -ErrorRecord $_
        throw
    }
}

function Test-ScriptSafety {
    param([string[]]$Paths)

    $blockedCommandNames = @(
        'cctk',
        'cctk.exe',
        'schtasks',
        'schtasks.exe',
        'Register-ScheduledTask',
        'New-Service',
        'Set-Service',
        'Start-Service',
        'sc',
        'sc.exe',
        'Set-BiosSetting',
        'Set-DellBiosSetting'
    )
    $writeCommandNames = @(
        'Set-Content',
        'Add-Content',
        'Out-File',
        'New-Item',
        'Set-Item',
        'Remove-Item',
        'New-ItemProperty',
        'Set-ItemProperty',
        'Remove-ItemProperty',
        'Set-CimInstance',
        'Invoke-CimMethod',
        'Set-WmiInstance'
    )

    foreach ($path in $Paths) {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) {
            throw "Read-only safety guard could not parse script."
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

            $commandText = $command.Extent.Text
            if ($blockedCommandNames -contains $commandName) {
                throw "Read-only safety guard failed: blocked executable command '$commandName'."
            }

            if ($commandText -match '(?i)(--?FanCtrlOvrd|FanCtrlOvrd\s*=\s*(Enabled|Disabled))') {
                throw "Read-only safety guard failed: blocked fan override command."
            }

            if (($writeCommandNames -contains $commandName) -and
                ($commandText -match '(?i)(CurrentVersion\\Run|\\Startup\\|CoreTemp\.ini|BIOS|DellSmbios|DCIM_BIOS)')) {
                throw "Read-only safety guard failed: blocked system, BIOS, or Core Temp settings write."
            }
        }
    }
}

function Read-CoreTempConfig {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Config file not found: $Path"
    }

    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($config.ReadOnly -ne $true -or $config.DryRun -ne $true) {
        throw 'Safety stop: ReadOnly and DryRun must both be true.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$config.MappingName)) {
        throw 'MappingName is required.'
    }

    return $config
}

function Invoke-CoreTempRead {
    param(
        [string]$DiscoverScript,
        [string]$MappingName
    )

    try {
        $output = & $DiscoverScript -MappingName $MappingName -Json 2>&1
        $succeeded = $?
    }
    catch {
        throw "Unable to run Core Temp shared-memory discovery: $($_.Exception.Message)"
    }

    $text = ($output | Out-String).Trim()
    if ($text -eq 'Core Temp shared memory unavailable') {
        return [pscustomobject]@{
            Success = $false
            Unavailable = $true
            Message = $text
            DiscoverySucceeded = $succeeded
        }
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        throw 'Discovery returned no output.'
    }

    try {
        $parsedItems = @($text | ConvertFrom-Json)
    }
    catch {
        throw "Unable to parse Core Temp shared-memory discovery output: $text"
    }

    if ($parsedItems.Count -ne 1) {
        throw "Discovery returned $($parsedItems.Count) objects; expected exactly one."
    }

    $parsed = $parsedItems[0]
    $parsed | Add-Member -NotePropertyName DiscoverySucceeded -NotePropertyValue $succeeded -Force
    $parsed | Add-Member -NotePropertyName Unavailable -NotePropertyValue $false -Force
    return $parsed
}

function Convert-ToValidTemperature {
    param(
        [object]$Value,
        [int]$CpuIndex,
        [int]$CoreIndex
    )

    if ($null -eq $Value) {
        Write-Host "Ongeldige temperatuur genegeerd: CPU $CpuIndex Core $CoreIndex = null"
        return $null
    }

    $number = 0.0
    if (-not [double]::TryParse(([string]$Value), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        Write-Host "Ongeldige temperatuur genegeerd: CPU $CpuIndex Core $CoreIndex = $Value"
        return $null
    }

    if ([double]::IsNaN($number) -or $number -lt 0 -or $number -gt 115) {
        Write-Host "Ongeldige temperatuur genegeerd: CPU $CpuIndex Core $CoreIndex = $number"
        return $null
    }

    return [Math]::Round([double]$number, 2)
}

function Add-ValidatedSamples {
    param(
        [object]$Read,
        [int]$SampleNumber,
        [datetime]$Timestamp,
        [object[]]$ExistingSamples
    )

    $samples = @($ExistingSamples)
    $validThisMoment = @()

    foreach ($temperature in @($Read.Temperatures)) {
        $cpuIndex = [int]$temperature.CpuIndex
        $coreIndex = [int]$temperature.CoreIndex
        $value = Convert-ToValidTemperature -Value $temperature.TemperatureCelsius -CpuIndex $cpuIndex -CoreIndex $coreIndex

        if ($null -eq $value) {
            continue
        }

        $sample = [pscustomobject]@{
            SampleNumber = [int]$SampleNumber
            Timestamp = $Timestamp
            CpuName = [string]$Read.CpuName
            CpuCount = [int]$Read.CpuCount
            CoreCount = [int]$Read.CoreCount
            StructVersion = [int]$Read.StructVersion
            CpuIndex = $cpuIndex
            CoreIndex = $coreIndex
            TemperatureCelsius = [double]$value
            RawTemperature = if ($null -ne $temperature.RawTemperature) { [double]$temperature.RawTemperature } else { $null }
            TjMax = if ($null -ne $temperature.TjMax) { [double]$temperature.TjMax } else { $null }
            Unit = [string]$temperature.Unit
            IsFahrenheit = [bool]$Read.IsFahrenheit
            IsDistanceToTjMax = [bool]$Read.IsDistanceToTjMax
        }

        $samples += $sample
        $validThisMoment += $sample
    }

    if ($validThisMoment.Count -eq 0) {
        throw 'No valid Core Temp temperatures were available in this measurement.'
    }

    $highest = ($validThisMoment | Sort-Object TemperatureCelsius -Descending | Select-Object -First 1).TemperatureCelsius
    Write-Host ("[{0}] Meting {1}: cores={2}; hoogste={3} C; waarden={4}" -f
        $Timestamp.ToString('HH:mm:ss'),
        $SampleNumber,
        $validThisMoment.Count,
        ([Math]::Round([double]$highest, 2)),
        (($validThisMoment | ForEach-Object { "CPU$($_.CpuIndex)/Core$($_.CoreIndex)=$($_.TemperatureCelsius)" }) -join ', '))

    return [pscustomobject]@{
        Samples = @($samples)
        HighestByMoment = [pscustomobject]@{
            SampleNumber = [int]$SampleNumber
            Timestamp = $Timestamp
            HighestCoreTemperatureCelsius = [Math]::Round([double]$highest, 2)
            ValidCoreCount = [int]$validThisMoment.Count
        }
    }
}

function Get-TemperatureStats {
    param([object[]]$Samples)

    $validSamples = @($Samples | Where-Object { $null -ne $_.TemperatureCelsius })
    if ($validSamples.Count -eq 0) {
        throw 'No valid temperature samples available for statistics.'
    }

    $summary = @()
    $groups = @($validSamples | Group-Object CpuIndex, CoreIndex)
    foreach ($group in $groups) {
        $ordered = @($group.Group | Sort-Object SampleNumber)
        $latest = $ordered[$ordered.Count - 1]
        $values = @($ordered | ForEach-Object { [double]$_.TemperatureCelsius })

        if ($values.Count -eq 0) {
            continue
        }

        $sum = 0.0
        $minimum = [double]$values[0]
        $maximum = [double]$values[0]
        foreach ($value in $values) {
            $number = [double]$value
            $sum += $number
            if ($number -lt $minimum) { $minimum = $number }
            if ($number -gt $maximum) { $maximum = $number }
        }

        $summary += [pscustomobject]@{
            CpuIndex = [int]$latest.CpuIndex
            CoreIndex = [int]$latest.CoreIndex
            MinimumCelsius = [Math]::Round($minimum, 2)
            MaximumCelsius = [Math]::Round($maximum, 2)
            AverageCelsius = [Math]::Round(($sum / [double]$values.Count), 2)
            LastCelsius = [Math]::Round([double]$latest.TemperatureCelsius, 2)
            Samples = [int]$values.Count
        }
    }

    if ($summary.Count -eq 0) {
        throw 'No per-core statistics could be calculated.'
    }

    return @($summary | Sort-Object CpuIndex, CoreIndex)
}

function New-CoreTempReport {
    param(
        [object[]]$Samples,
        [object[]]$HighestByMoment,
        [int]$Duration,
        [int]$Interval,
        [string]$MappingName
    )

    $firstSample = @($Samples | Select-Object -First 1)[0]
    $coreSummary = @(Get-TemperatureStats -Samples $Samples)
    $validMoments = @($HighestByMoment | Where-Object { $null -ne $_.HighestCoreTemperatureCelsius })

    if ($validMoments.Count -eq 0) {
        throw 'No valid measurement moments available.'
    }

    $highestOverall = ($validMoments | Sort-Object HighestCoreTemperatureCelsius -Descending | Select-Object -First 1).HighestCoreTemperatureCelsius

    return [pscustomobject]@{
        Success = $true
        ReadOnly = $true
        DryRun = $true
        MappingName = $MappingName
        DurationSeconds = [int]$Duration
        IntervalSeconds = [int]$Interval
        CpuName = [string]$firstSample.CpuName
        CpuCount = [int]$firstSample.CpuCount
        CoreCount = [int]$firstSample.CoreCount
        StructVersion = [int]$firstSample.StructVersion
        CoreSummary = @($coreSummary)
        HighestByMeasurement = @($HighestByMoment)
        HighestOverallCelsius = [Math]::Round([double]$highestOverall, 2)
        ValidMeasurementMoments = [int]$validMoments.Count
        Safety = [pscustomobject]@{
            FanActionPerformed = $false
            SettingsChanged = $false
            SystemChangesPerformed = $false
        }
    }
}

$config = $null
$discoverScript = $null
$duration = 300
$interval = 30
$samples = @()
$highestByMoment = @()
$read = $null

Invoke-Phase -Name 'config laden' -Action {
    $script:config = Read-CoreTempConfig -Path $ConfigPath
    $script:duration = if ($DurationSeconds -gt 0) { [int]$DurationSeconds } else { [Math]::Max(1, [int]$script:config.DurationSeconds) }
    $script:interval = if ($IntervalSeconds -gt 0) { [int]$IntervalSeconds } else { [Math]::Max(1, [int]$script:config.IntervalSeconds) }
}

Invoke-Phase -Name 'safety guard uitvoeren' -Action {
    Test-ScriptSafety -Paths @(
        $PSCommandPath,
        (Join-Path $ScriptDirectory 'Discover-CoreTempSharedMemory.ps1')
    )
}

Invoke-Phase -Name 'discoveryscript laden' -Action {
    $script:discoverScript = Join-Path $ScriptDirectory 'Discover-CoreTempSharedMemory.ps1'
    if (-not (Test-Path -LiteralPath $script:discoverScript -PathType Leaf)) {
        throw "Discover script not found: $script:discoverScript"
    }
}

$endAt = (Get-Date).AddSeconds($duration)
$sampleNumber = 0

do {
    $sampleNumber++
    $read = $null

    Invoke-Phase -Name 'shared memory openen en meting lezen' -Action {
        $script:read = Invoke-CoreTempRead -DiscoverScript $script:discoverScript -MappingName ([string]$script:config.MappingName)
    }
    $read = $script:read

    if ($read.Unavailable) {
        Write-Host 'Core Temp shared memory unavailable'
        exit 2
    }

    $moment = Get-Date
    Invoke-Phase -Name 'sample opslaan' -Action {
        $stored = Add-ValidatedSamples -Read $read -SampleNumber $sampleNumber -Timestamp $moment -ExistingSamples $script:samples
        $script:samples = @($stored.Samples)
        $script:highestByMoment += $stored.HighestByMoment
    }

    if ((Get-Date) -lt $endAt) {
        Start-Sleep -Seconds $interval
    }
} while ((Get-Date) -lt $endAt)

$result = $null
Invoke-Phase -Name 'statistieken berekenen' -Action {
    $script:result = New-CoreTempReport -Samples $script:samples -HighestByMoment $script:highestByMoment -Duration $script:duration -Interval $script:interval -MappingName ([string]$script:config.MappingName)
}

Invoke-Phase -Name 'eindrapport maken' -Action {
    if ($Json) {
        $script:result | ConvertTo-Json -Depth 8
    } else {
        "Core Temp mapping: $($script:result.MappingName)"
        "CPU: $($script:result.CpuName)"
        "CPU count: $($script:result.CpuCount)"
        "Core count: $($script:result.CoreCount)"
        "Structure version: $($script:result.StructVersion)"
        "Duration: $($script:result.DurationSeconds) second(s)"
        "Interval: $($script:result.IntervalSeconds) second(s)"
        "Highest overall temperature: $($script:result.HighestOverallCelsius) Celsius"
        "Valid measurement moments: $($script:result.ValidMeasurementMoments)"
        ''
        'Per-core summary:'
        $script:result.CoreSummary | Format-Table CpuIndex, CoreIndex, MinimumCelsius, MaximumCelsius, AverageCelsius, LastCelsius, Samples -AutoSize
        ''
        'Highest core temperature per measurement:'
        $script:result.HighestByMeasurement | Format-Table SampleNumber, Timestamp, HighestCoreTemperatureCelsius, ValidCoreCount -AutoSize
    }
}

Write-Step 'shared memory sluiten'
