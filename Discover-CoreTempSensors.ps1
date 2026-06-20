[CmdletBinding()]
param(
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$mappingName = 'CoreTempMappingObjectEx'

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

function Read-CoreTempSharedDataEx {
    param([byte[]]$Bytes)

    # Official CoreTempSharedDataEx layout, 4-byte alignment.
    $offsetUiLoad = 0
    $offsetUiTjMax = $offsetUiLoad + (256 * 4)
    $offsetUiCoreCnt = $offsetUiTjMax + (128 * 4)
    $offsetUiCpuCnt = $offsetUiCoreCnt + 4
    $offsetFTemp = $offsetUiCpuCnt + 4
    $offsetCpuName = $offsetFTemp + (256 * 4) + (4 * 4)
    $offsetFahrenheit = $offsetCpuName + 100
    $offsetDeltaToTjMax = $offsetFahrenheit + 1
    $offsetTdpSupported = $offsetDeltaToTjMax + 1
    $offsetPowerSupported = $offsetTdpSupported + 1
    $offsetStructVersion = $offsetPowerSupported + 1

    $coreCount = [int](Read-UInt32 -Bytes $Bytes -Offset $offsetUiCoreCnt)
    $cpuCount = [int](Read-UInt32 -Bytes $Bytes -Offset $offsetUiCpuCnt)
    $sensorCount = [Math]::Min(256, [Math]::Max(0, $coreCount * [Math]::Max(1, $cpuCount)))

    $cpuNameBytes = $Bytes[$offsetCpuName..($offsetCpuName + 99)]
    $cpuName = ([Text.Encoding]::ASCII.GetString($cpuNameBytes)).TrimEnd([char]0).Trim()
    $fahrenheit = ($Bytes[$offsetFahrenheit] -ne 0)
    $deltaToTjMax = ($Bytes[$offsetDeltaToTjMax] -ne 0)
    $structVersion = [int](Read-UInt32 -Bytes $Bytes -Offset $offsetStructVersion)

    $temps = for ($i = 0; $i -lt $sensorCount; $i++) {
        $rawTemp = Read-Single -Bytes $Bytes -Offset ($offsetFTemp + ($i * 4))
        $cpuIndex = if ($coreCount -gt 0) { [Math]::Floor($i / $coreCount) } else { 0 }
        $coreIndex = if ($coreCount -gt 0) { $i % $coreCount } else { $i }
        $tjMax = if ($cpuIndex -lt 128) { [int](Read-UInt32 -Bytes $Bytes -Offset ($offsetUiTjMax + ($cpuIndex * 4))) } else { $null }
        $actualTemp = if ($deltaToTjMax -and $null -ne $tjMax) { [double]$tjMax - [double]$rawTemp } else { [double]$rawTemp }

        [pscustomobject]@{
            CpuIndex = $cpuIndex
            CoreIndex = $coreIndex
            Temperature = [Math]::Round($actualTemp, 2)
            RawTemperature = [Math]::Round([double]$rawTemp, 2)
            TjMax = $tjMax
            IsDistanceToTjMax = $deltaToTjMax
            Unit = if ($fahrenheit) { 'Fahrenheit' } else { 'Celsius' }
        }
    }

    [pscustomobject]@{
        Success = $true
        Source = 'Core Temp shared memory'
        MappingName = $mappingName
        CpuName = $cpuName
        CpuCount = $cpuCount
        CoreCount = $coreCount
        StructVersion = $structVersion
        IsFahrenheit = $fahrenheit
        IsDistanceToTjMax = $deltaToTjMax
        Temperatures = @($temps)
        HighestCoreTemperature = if ($temps.Count -gt 0) { ($temps | Measure-Object -Property Temperature -Maximum).Maximum } else { $null }
        Safety = [pscustomobject]@{
            ReadOnly = $true
            FanActionPerformed = $false
            SettingsChanged = $false
        }
    }
}

try {
    $mmf = [System.IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting(
        $mappingName,
        [System.IO.MemoryMappedFiles.MemoryMappedFileRights]::Read
    )
} catch {
    $result = [pscustomobject]@{
        Success = $false
        Source = 'Core Temp shared memory'
        MappingName = $mappingName
        Error = $_.Exception.Message
        Recommendation = 'Start Core Temp and ensure its shared memory interface is available, then retry read-only discovery.'
        Safety = [pscustomobject]@{
            ReadOnly = $true
            FanActionPerformed = $false
            SettingsChanged = $false
        }
    }

    if ($Json) { $result | ConvertTo-Json -Depth 6 } else { $result | Format-List }
    exit 2
}

try {
    $accessor = $mmf.CreateViewAccessor(0, 0, [System.IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
    try {
        $bytes = New-Object byte[] 4740
        $accessor.ReadArray(0, $bytes, 0, $bytes.Length) | Out-Null
        $result = Read-CoreTempSharedDataEx -Bytes $bytes

        if ($Json) {
            $result | ConvertTo-Json -Depth 6
        } else {
            "Core Temp mapping: $($result.MappingName)"
            "CPU: $($result.CpuName)"
            "CPU count: $($result.CpuCount)"
            "Core count: $($result.CoreCount)"
            "Structure version: $($result.StructVersion)"
            "Temperature unit: $(if ($result.IsFahrenheit) { 'Fahrenheit' } else { 'Celsius' })"
            "Distance to TjMax mode: $($result.IsDistanceToTjMax)"
            ''
            $result.Temperatures | Format-Table CpuIndex, CoreIndex, Temperature, Unit, TjMax, RawTemperature, IsDistanceToTjMax -AutoSize
            ''
            "Highest core temperature: $($result.HighestCoreTemperature)"
        }
    } finally {
        $accessor.Dispose()
    }
} finally {
    $mmf.Dispose()
}
