param(
    [string]$ProjectPath = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$ConfigPath = (Join-Path $ProjectPath 'controller-config.production.json'),
    [int]$Tail = 50
)

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Config not found: $ConfigPath" }
$cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$logPath = if ([IO.Path]::IsPathRooted([string]$cfg.LogPath)) { [string]$cfg.LogPath } else { Join-Path $ProjectPath ([string]$cfg.LogPath) }
if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) { throw "Log not found: $logPath" }
Get-Content -LiteralPath $logPath -Tail $Tail
