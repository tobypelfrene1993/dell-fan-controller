param(
    [switch]$ConfirmRestore,
    [string]$ProjectPath = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$ConfigPath = (Join-Path $ProjectPath 'controller-config.production.json')
)

if (-not $ConfirmRestore.IsPresent) {
    throw 'This performs a Dell CCTK hardware write. Re-run with -ConfirmRestore only after reading docs/SAFETY.md.'
}
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Config not found: $ConfigPath" }

$cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$statePath = if ([IO.Path]::IsPathRooted([string]$cfg.StatePath)) { [string]$cfg.StatePath } else { Join-Path $ProjectPath ([string]$cfg.StatePath) }
$reset = Join-Path $ProjectPath 'Reset-DellFanController.ps1'

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $reset -UseDellCctkBackend -StatePath $statePath -CctkPath ([string]$cfg.CctkPath) -CommandTimeoutSeconds ([int]$cfg.CommandTimeoutSeconds) -AllowHardwareWrites $true -HardwareWriteConfirmation 'RESTORE_DELL_AUTOMATIC_FAN_CONTROL' -ForceIfOwned -Reason 'ManualEmergencyRestore'
