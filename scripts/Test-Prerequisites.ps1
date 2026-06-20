param(
    [string]$ProjectPath = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$ConfigPath = (Join-Path $ProjectPath 'controller-config.production.json')
)

$result = [ordered]@{
    ProjectPath = $ProjectPath
    ConfigPath = $ConfigPath
    IsAdministrator = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    ConfigExists = Test-Path -LiteralPath $ConfigPath -PathType Leaf
    CoreTempReaderExists = Test-Path -LiteralPath (Join-Path $ProjectPath 'Discover-CoreTempSharedMemory.ps1') -PathType Leaf
    ControllerExists = Test-Path -LiteralPath (Join-Path $ProjectPath 'DellFanController.ps1') -PathType Leaf
    CctkPath = $null
    CctkExists = $false
    Notes = @()
}

if ($result.ConfigExists) {
    try {
        $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        $result.CctkPath = [string]$cfg.CctkPath
        $result.CctkExists = -not [string]::IsNullOrWhiteSpace($result.CctkPath) -and (Test-Path -LiteralPath $result.CctkPath -PathType Leaf)
    } catch {
        $result.Notes += "Config JSON could not be parsed: $($_.Exception.Message)"
    }
} else {
    $result.Notes += 'Copy controller-config.example.json to controller-config.production.json first.'
}

[pscustomobject]$result | Format-List *
