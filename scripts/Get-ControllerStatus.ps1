param(
    [string]$ProjectPath = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$TaskName = 'Dell Fan Controller',
    [string]$ConfigPath = (Join-Path $ProjectPath 'controller-config.production.json')
)

$logPath = $null
$statePath = $null
if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $logPath = if ([IO.Path]::IsPathRooted([string]$cfg.LogPath)) { [string]$cfg.LogPath } else { Join-Path $ProjectPath ([string]$cfg.LogPath) }
    $statePath = if ([IO.Path]::IsPathRooted([string]$cfg.StatePath)) { [string]$cfg.StatePath } else { Join-Path $ProjectPath ([string]$cfg.StatePath) }
}

[pscustomobject]@{
    Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    ConfigExists = Test-Path -LiteralPath $ConfigPath -PathType Leaf
    LogPath = $logPath
    LogExists = -not [string]::IsNullOrWhiteSpace($logPath) -and (Test-Path -LiteralPath $logPath -PathType Leaf)
    StatePath = $statePath
    StateExists = -not [string]::IsNullOrWhiteSpace($statePath) -and (Test-Path -LiteralPath $statePath -PathType Leaf)
} | Format-List *
