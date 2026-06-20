[CmdletBinding()]
param(
    [string]$MappingName = 'CoreTempMappingObjectEx',
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$StructSizeBytes = 4740

function Test-ScriptSafety {
    param([string]$Path)

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "Read-only safety guard could not parse script."
    }

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
        'sc.exe'
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
        'Remove-ItemProperty'
    )

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
            ($commandText -match '(?i)(CurrentVersion\\Run|\\Startup\\|CoreTemp\.ini)')) {
            throw "Read-only safety guard failed: blocked system or Core Temp settings write."
        }
    }
}

function Read-UInt32 {
    param(
        [byte[]]$Bytes,
        [int]$Offset
    )
    return [BitConverter]::ToUInt32($Bytes, $Offset)
}

function Read-Single {
    param(
        [byte[]]$Bytes,
        [int]$Offset
    )
    return [BitConverter]::ToSingle($Bytes, $Offset)
}

function Convert-ToCelsius {
    param(
        [double]$Value,
        [bool]$IsFahrenheit
    )

    if ($IsFahrenheit) {
        return [Math]::Round((($Value - 32) * 5 / 9), 2)
    }

    return [Math]::Round($Value, 2)
}

function Read-CoreTempSharedDataEx {
    param(
        [byte[]]$Bytes,
        [string]$SourceMappingName
    )

    # Official CoreTempSharedDataEx layout with 4-byte alignment.
    $offsetUiLoad = 0
    $offsetUiTjMax = $offsetUiLoad + (256 * 4)
    $offsetUiCoreCnt = $offsetUiTjMax + (128 * 4)
    $offsetUiCpuCnt = $offsetUiCoreCnt + 4
    $offsetFTemp = $offsetUiCpuCnt + 4
    $offsetFVid = $offsetFTemp + (256 * 4)
    $offsetFCpuSpeed = $offsetFVid + 4
    $offsetFFsbSpeed = $offsetFCpuSpeed + 4
    $offsetFMultiplier = $offsetFFsbSpeed + 4
    $offsetCpuName = $offsetFMultiplier + 4
    $offsetFahrenheit = $offsetCpuName + 100
    $offsetDeltaToTjMax = $offsetFahrenheit + 1
    $offsetTdpSupported = $offsetDeltaToTjMax + 1
    $offsetPowerSupported = $offsetTdpSupported + 1
    $offsetStructVersion = $offsetPowerSupported + 1
    $offsetUiTdp = $offsetStructVersion + 4
    $offsetFPower = $offsetUiTdp + (128 * 4)
    $offsetFMultipliers = $offsetFPower + (128 * 4)

    if ($Bytes.Length -lt ($offsetFMultipliers + (256 * 4))) {
        throw "Core Temp shared memory block is smaller than expected."
    }

    $coreCount = [int](Read-UInt32 -Bytes $Bytes -Offset $offsetUiCoreCnt)
    $cpuCount = [int](Read-UInt32 -Bytes $Bytes -Offset $offsetUiCpuCnt)
    $sensorCount = [Math]::Min(256, [Math]::Max(0, $coreCount * [Math]::Max(1, $cpuCount)))

    $cpuNameBytes = $Bytes[$offsetCpuName..($offsetCpuName + 99)]
    $cpuName = ([Text.Encoding]::ASCII.GetString($cpuNameBytes)).TrimEnd([char]0).Trim()
    $isFahrenheit = ($Bytes[$offsetFahrenheit] -ne 0)
    $isDistanceToTjMax = ($Bytes[$offsetDeltaToTjMax] -ne 0)
    $isTdpSupported = ($Bytes[$offsetTdpSupported] -ne 0)
    $isPowerSupported = ($Bytes[$offsetPowerSupported] -ne 0)
    $structVersion = [int](Read-UInt32 -Bytes $Bytes -Offset $offsetStructVersion)

    $temperatures = for ($i = 0; $i -lt $sensorCount; $i++) {
        $rawTemp = [double](Read-Single -Bytes $Bytes -Offset ($offsetFTemp + ($i * 4)))
        $cpuIndex = if ($coreCount -gt 0) { [int][Math]::Floor($i / $coreCount) } else { 0 }
        $coreIndex = if ($coreCount -gt 0) { [int]($i % $coreCount) } else { $i }
        $tjMax = if ($cpuIndex -lt 128) { [double](Read-UInt32 -Bytes $Bytes -Offset ($offsetUiTjMax + ($cpuIndex * 4))) } else { $null }
        $displayTemp = if ($isDistanceToTjMax -and $null -ne $tjMax) { $tjMax - $rawTemp } else { $rawTemp }

        [pscustomobject]@{
            CpuIndex = $cpuIndex
            CoreIndex = $coreIndex
            RawTemperature = [Math]::Round($rawTemp, 2)
            Temperature = [Math]::Round($displayTemp, 2)
            TemperatureCelsius = Convert-ToCelsius -Value $displayTemp -IsFahrenheit $isFahrenheit
            Unit = if ($isFahrenheit) { 'Fahrenheit' } else { 'Celsius' }
            TjMax = $tjMax
            IsDistanceToTjMax = $isDistanceToTjMax
            LoadPercent = if ($i -lt 256) { [int](Read-UInt32 -Bytes $Bytes -Offset ($offsetUiLoad + ($i * 4))) } else { $null }
        }
    }

    $highestCelsius = if (@($temperatures).Count -gt 0) {
        (@($temperatures) | Measure-Object -Property TemperatureCelsius -Maximum).Maximum
    } else {
        $null
    }

    [pscustomobject]@{
        Success = $true
        Source = 'Core Temp shared memory'
        MappingName = $SourceMappingName
        CpuName = $cpuName
        CpuCount = $cpuCount
        CoreCount = $coreCount
        StructVersion = $structVersion
        TjMax = @(for ($cpu = 0; $cpu -lt [Math]::Min(128, [Math]::Max(1, $cpuCount)); $cpu++) {
            [pscustomobject]@{
                CpuIndex = $cpu
                TjMax = [int](Read-UInt32 -Bytes $Bytes -Offset ($offsetUiTjMax + ($cpu * 4)))
            }
        })
        IsFahrenheit = $isFahrenheit
        IsDistanceToTjMax = $isDistanceToTjMax
        IsTdpSupported = $isTdpSupported
        IsPowerSupported = $isPowerSupported
        Temperatures = @($temperatures)
        HighestCoreTemperatureCelsius = if ($null -ne $highestCelsius) { [Math]::Round([double]$highestCelsius, 2) } else { $null }
        Safety = [pscustomobject]@{
            ReadOnly = $true
            DryRun = $true
            FanActionPerformed = $false
            SettingsChanged = $false
        }
    }
}

Test-ScriptSafety -Path $PSCommandPath

try {
    $mmf = [System.IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting(
        $MappingName,
        [System.IO.MemoryMappedFiles.MemoryMappedFileRights]::Read
    )
} catch {
    'Core Temp shared memory unavailable'
    exit 2
}

try {
    $accessor = $mmf.CreateViewAccessor(0, $StructSizeBytes, [System.IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
    try {
        $bytes = New-Object byte[] $StructSizeBytes
        [void]$accessor.ReadArray(0, $bytes, 0, $bytes.Length)
        $result = Read-CoreTempSharedDataEx -Bytes $bytes -SourceMappingName $MappingName

        if ($Json) {
            $result | ConvertTo-Json -Depth 8
        } else {
            "Core Temp mapping: $($result.MappingName)"
            "CPU: $($result.CpuName)"
            "CPU count: $($result.CpuCount)"
            "Core count: $($result.CoreCount)"
            "Structure version: $($result.StructVersion)"
            "Fahrenheit mode: $($result.IsFahrenheit)"
            "Distance to TjMax mode: $($result.IsDistanceToTjMax)"
            ''
            'TjMax:'
            $result.TjMax | Format-Table CpuIndex, TjMax -AutoSize
            ''
            'Core temperatures:'
            $result.Temperatures | Format-Table CpuIndex, CoreIndex, TemperatureCelsius, Temperature, Unit, TjMax, RawTemperature, LoadPercent, IsDistanceToTjMax -AutoSize
            ''
            "Highest core temperature: $($result.HighestCoreTemperatureCelsius) Celsius"
        }
    } finally {
        $accessor.Dispose()
    }
} finally {
    $mmf.Dispose()
}
