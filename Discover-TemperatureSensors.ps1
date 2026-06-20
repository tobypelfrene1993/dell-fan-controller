[CmdletBinding()]
param(
    [string]$LibreHardwareMonitorPath,
    [int]$SampleSeconds = 300,
    [int]$SampleIntervalSeconds = 30,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$diagnostics = [ordered]@{
    PowerShellExecutable = [string](Get-Process -Id $PID).Path
    PowerShellProcessId = $PID
    PowerShellIs64Bit = [Environment]::Is64BitProcess
    OperatingSystemIs64Bit = [Environment]::Is64BitOperatingSystem
    AssemblyPath = $null
    AssemblyVersion = $null
    AssemblyProcessorArchitecture = $null
    AssemblyDirectory = $null
    LoadedDependencyDlls = @()
    DependencyLoadFailures = @()
    ComputerOpenSucceeded = $false
    ComputerCloseSucceeded = $false
    SuccessfulUpdatePasses = 0
    Exceptions = @()
}

function Add-DiagnosticException {
    param(
        [string]$Operation,
        [object]$Target,
        [System.Exception]$Exception
    )

    $diagnostics.Exceptions += [pscustomobject]@{
        Operation = $Operation
        Target = [string]$Target
        ExceptionType = $Exception.GetType().FullName
        Message = $Exception.Message
        HResult = ('0x{0:X8}' -f $Exception.HResult)
        StackTrace = $Exception.StackTrace
        FullException = $Exception.ToString()
    }
}

function Find-LibreHardwareMonitorLibrary {
    param([string]$ExplicitPath)

    if ($ExplicitPath) {
        if (Test-Path -LiteralPath $ExplicitPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $ExplicitPath).Path
        }
        throw "LibreHardwareMonitorLib.dll not found at explicit path: $ExplicitPath"
    }

    $roots = @(
        $PSScriptRoot,
        (Join-Path $PSScriptRoot 'lib'),
        'C:\ProgramData\DellFanController\App',
        'C:\ProgramData\DellFanController\App\lib',
        'C:\Program Files\LibreHardwareMonitor',
        'C:\Program Files (x86)\LibreHardwareMonitor'
    )

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        $found = Get-ChildItem -LiteralPath $root -Filter 'LibreHardwareMonitorLib.dll' -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) {
            return $found.FullName
        }
    }

    return $null
}

function Import-LibreHardwareMonitorAssemblies {
    param([string]$LibraryPath)

    $libraryItem = Get-Item -LiteralPath $LibraryPath
    $libraryDirectory = $libraryItem.Directory.FullName
    $diagnostics.AssemblyDirectory = $libraryDirectory

    try {
        $assemblyName = [Reflection.AssemblyName]::GetAssemblyName($LibraryPath)
        $diagnostics.AssemblyPath = $LibraryPath
        $diagnostics.AssemblyVersion = [string]$assemblyName.Version
        $diagnostics.AssemblyProcessorArchitecture = [string]$assemblyName.ProcessorArchitecture
    }
    catch {
        Add-DiagnosticException -Operation 'AssemblyName.GetAssemblyName' -Target $LibraryPath -Exception $_.Exception
        throw
    }

    $dependencyDlls = Get-ChildItem -LiteralPath $libraryDirectory -Filter '*.dll' -File |
        Where-Object { $_.FullName -ne $LibraryPath } |
        Sort-Object Name

    foreach ($dll in $dependencyDlls) {
        try {
            [void][Reflection.Assembly]::LoadFrom($dll.FullName)
            $diagnostics.LoadedDependencyDlls += $dll.FullName
        }
        catch {
            $diagnostics.DependencyLoadFailures += [pscustomobject]@{
                Path = $dll.FullName
                ExceptionType = $_.Exception.GetType().FullName
                Message = $_.Exception.Message
                FullException = $_.Exception.ToString()
            }
        }
    }

    try {
        Add-Type -Path $LibraryPath
    }
    catch {
        Add-DiagnosticException -Operation 'Add-Type LibreHardwareMonitorLib.dll' -Target $LibraryPath -Exception $_.Exception
        throw
    }
}

function Add-UpdateVisitorType {
    param([string]$LibraryPath)

    $source = @'
using System;
using System.Collections.Generic;
using LibreHardwareMonitor.Hardware;

public sealed class DiagnosticUpdateVisitor : IVisitor
{
    public readonly List<string> Exceptions = new List<string>();
    public int SuccessfulUpdates { get; private set; }

    public void VisitComputer(IComputer computer)
    {
        computer.Traverse(this);
    }

    public void VisitHardware(IHardware hardware)
    {
        try
        {
            hardware.Update();
            SuccessfulUpdates++;
        }
        catch (Exception ex)
        {
            Exceptions.Add("Update failed for hardware '" + hardware.Name + "' [" + hardware.Identifier + "]: " + ex.ToString());
        }

        foreach (IHardware subHardware in hardware.SubHardware)
            subHardware.Accept(this);
    }

    public void VisitSensor(ISensor sensor) { }

    public void VisitParameter(IParameter parameter) { }
}
'@

    try {
        Add-Type -TypeDefinition $source -ReferencedAssemblies $LibraryPath -Language CSharp
    }
    catch {
        Add-DiagnosticException -Operation 'Add-Type DiagnosticUpdateVisitor' -Target 'DiagnosticUpdateVisitor' -Exception $_.Exception
        throw
    }
}

function Invoke-ComputerUpdate {
    param([object]$Computer)

    $visitor = [DiagnosticUpdateVisitor]::new()
    try {
        $Computer.Accept($visitor)
    }
    catch {
        Add-DiagnosticException -Operation 'Computer.Accept(UpdateVisitor)' -Target 'Computer' -Exception $_.Exception
    }

    $diagnostics.SuccessfulUpdatePasses += $visitor.SuccessfulUpdates
    foreach ($updateException in $visitor.Exceptions) {
        $diagnostics.Exceptions += [pscustomobject]@{
            Operation = 'Hardware.Update'
            Target = $null
            ExceptionType = $null
            Message = $updateException
            HResult = $null
            StackTrace = $null
            FullException = $updateException
        }
    }

    return ($visitor.Exceptions.Count -eq 0)
}

function Get-AllHardware {
    param([object]$Hardware)

    $items = New-Object System.Collections.Generic.List[object]
    $items.Add($Hardware)
    foreach ($child in $Hardware.SubHardware) {
        foreach ($item in (Get-AllHardware -Hardware $child)) {
            $items.Add($item)
        }
    }
    return $items
}

function Read-SensorValue {
    param(
        [object]$Sensor,
        [string]$PropertyName
    )

    try {
        return $Sensor.$PropertyName
    }
    catch {
        Add-DiagnosticException -Operation "Sensor.$PropertyName" -Target ([string]$Sensor.Identifier) -Exception $_.Exception
        return $null
    }
}

function Get-CpuTemperatureSensors {
    param(
        [object]$Computer,
        [int]$SampleNumber
    )

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($hardware in $Computer.Hardware) {
        foreach ($node in (Get-AllHardware -Hardware $hardware)) {
            $hardwareName = [string]$node.Name
            $hardwareIdentifier = [string]$node.Identifier
            $hardwareType = [string]$node.HardwareType

            if ($hardwareType -ne 'Cpu') {
                continue
            }

            foreach ($sensor in $node.Sensors) {
                if ([string]$sensor.SensorType -ne 'Temperature') {
                    continue
                }

                $value = Read-SensorValue -Sensor $sensor -PropertyName 'Value'
                $minimum = Read-SensorValue -Sensor $sensor -PropertyName 'Min'
                $maximum = Read-SensorValue -Sensor $sensor -PropertyName 'Max'

                $results.Add([pscustomobject]@{
                    SampleNumber = $SampleNumber
                    Timestamp = Get-Date
                    SensorName = [string]$sensor.Name
                    Identifier = [string]$sensor.Identifier
                    HardwareName = $hardwareName
                    HardwareIdentifier = $hardwareIdentifier
                    HardwareType = $hardwareType
                    SensorType = [string]$sensor.SensorType
                    ValueIsNull = ($null -eq $value)
                    CurrentCelsius = if ($null -ne $value) { [double]$value } else { $null }
                    MinimumCelsius = if ($null -ne $minimum) { [double]$minimum } else { $null }
                    MaximumCelsius = if ($null -ne $maximum) { [double]$maximum } else { $null }
                })
            }
        }
    }
    return $results
}

function Get-Recommendation {
    param([object[]]$Sensors)

    $valid = @($Sensors | Where-Object {
        $null -ne $_.AverageCelsius -and
        $_.AverageCelsius -ge 0 -and
        $_.AverageCelsius -le 115
    })

    if ($valid.Count -eq 0) {
        return 'No valid CPU temperature sensor found.'
    }

    $package = @($valid | Where-Object { $_.SensorName -match '(?i)package' })
    if ($package.Count -eq 1) {
        return "Recommended candidate: $($package[0].SensorName) [$($package[0].Identifier)]"
    }
    if ($package.Count -gt 1) {
        return 'Multiple CPU package-like sensors found. Manual approval required.'
    }

    $coreMax = @($valid | Where-Object { $_.SensorName -match '(?i)(core max|max)' })
    if ($coreMax.Count -eq 1) {
        return "Recommended fallback candidate: $($coreMax[0].SensorName) [$($coreMax[0].Identifier)]"
    }

    return 'Multiple or non-package CPU temperature sensors found. Manual approval required.'
}

$libraryPath = Find-LibreHardwareMonitorLibrary -ExplicitPath $LibreHardwareMonitorPath
if (-not $libraryPath) {
    $result = [pscustomobject]@{
        Success = $false
        Dependency = 'LibreHardwareMonitorLib.dll'
        Message = 'LibreHardwareMonitorLib.dll was not found locally. No download or install was attempted.'
        Diagnostics = $diagnostics
        SearchedLocations = @(
            $PSScriptRoot,
            (Join-Path $PSScriptRoot 'lib'),
            'C:\ProgramData\DellFanController\App',
            'C:\ProgramData\DellFanController\App\lib',
            'C:\Program Files\LibreHardwareMonitor',
            'C:\Program Files (x86)\LibreHardwareMonitor'
        )
        Sensors = @()
        Recommendation = 'Install or provide LibreHardwareMonitorLib.dll locally before selecting a final sensor.'
    }

    if ($Json) { $result | ConvertTo-Json -Depth 8 } else { $result | Format-List }
    exit 2
}

Import-LibreHardwareMonitorAssemblies -LibraryPath $libraryPath
Add-UpdateVisitorType -LibraryPath $libraryPath

$computer = [LibreHardwareMonitor.Hardware.Computer]::new()
$computer.IsCpuEnabled = $true
$computer.IsMotherboardEnabled = $false
$computer.IsMemoryEnabled = $false
$computer.IsGpuEnabled = $false
$computer.IsStorageEnabled = $false
$computer.IsNetworkEnabled = $false
$computer.IsControllerEnabled = $false
if ($computer.PSObject.Properties.Name -contains 'IsPowerMonitorEnabled') {
    $computer.IsPowerMonitorEnabled = $false
}

$allSamples = New-Object System.Collections.Generic.List[object]

try {
    try {
        $computer.Open()
        $diagnostics.ComputerOpenSucceeded = $true
    }
    catch {
        Add-DiagnosticException -Operation 'Computer.Open' -Target 'Computer' -Exception $_.Exception
        throw
    }

    $endAt = (Get-Date).AddSeconds([Math]::Max(1, $SampleSeconds))
    $sampleNumber = 0
    do {
        $sampleNumber++
        [void](Invoke-ComputerUpdate -Computer $computer)

        foreach ($sensor in (Get-CpuTemperatureSensors -Computer $computer -SampleNumber $sampleNumber)) {
            $allSamples.Add($sensor)
        }

        if ((Get-Date) -lt $endAt) {
            Start-Sleep -Seconds ([Math]::Max(1, $SampleIntervalSeconds))
        }
    } while ((Get-Date) -lt $endAt)

    $grouped = @($allSamples | Group-Object Identifier | ForEach-Object {
        $latest = $_.Group | Select-Object -Last 1
        $values = @($_.Group | Where-Object { $null -ne $_.CurrentCelsius } | ForEach-Object { $_.CurrentCelsius })
        [pscustomobject]@{
            SensorName = $latest.SensorName
            Identifier = $latest.Identifier
            HardwareName = $latest.HardwareName
            HardwareIdentifier = $latest.HardwareIdentifier
            HardwareType = $latest.HardwareType
            CurrentCelsius = $latest.CurrentCelsius
            ValueIsNull = $latest.ValueIsNull
            MinimumCelsius = if ($values.Count -gt 0) { [Math]::Round(($values | Measure-Object -Minimum).Minimum, 2) } else { $null }
            MaximumCelsius = if ($values.Count -gt 0) { [Math]::Round(($values | Measure-Object -Maximum).Maximum, 2) } else { $null }
            AverageCelsius = if ($values.Count -gt 0) { [Math]::Round(($values | Measure-Object -Average).Average, 2) } else { $null }
            ValidSamples = $values.Count
            ObservedSamples = $_.Group.Count
        }
    } | Sort-Object Identifier)

    $result = [pscustomobject]@{
        Success = $true
        LibraryPath = $libraryPath
        SampleSeconds = $SampleSeconds
        SampleIntervalSeconds = $SampleIntervalSeconds
        Diagnostics = $diagnostics
        Sensors = $grouped
        Recommendation = Get-Recommendation -Sensors $grouped
    }

    if ($Json) {
        $result | ConvertTo-Json -Depth 8
    } else {
        "LibreHardwareMonitor library: $libraryPath"
        "LibreHardwareMonitor version: $($diagnostics.AssemblyVersion)"
        "PowerShell 64-bit: $($diagnostics.PowerShellIs64Bit)"
        "Sample period: $SampleSeconds second(s)"
        "Sample interval: $SampleIntervalSeconds second(s)"
        "Successful hardware updates: $($diagnostics.SuccessfulUpdatePasses)"
        "Exceptions captured: $($diagnostics.Exceptions.Count)"
        ''
        if ($grouped.Count -eq 0) {
            'No CPU temperature sensors found.'
        } else {
            $grouped | Format-Table SensorName, Identifier, HardwareName, HardwareIdentifier, ValueIsNull, MinimumCelsius, MaximumCelsius, AverageCelsius, ValidSamples, ObservedSamples -AutoSize
        }
        ''
        $result.Recommendation
        if ($diagnostics.Exceptions.Count -gt 0) {
            ''
            'Exceptions:'
            $diagnostics.Exceptions | Format-List
        }
    }
}
finally {
    if ($computer) {
        try {
            $computer.Close()
            $diagnostics.ComputerCloseSucceeded = $true
        }
        catch {
            Add-DiagnosticException -Operation 'Computer.Close' -Target 'Computer' -Exception $_.Exception
        }
    }
}
