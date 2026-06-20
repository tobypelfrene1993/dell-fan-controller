# Usage

Use `ValidateOnly` first. It checks config, admin status, Core Temp availability, CCTK path and current fan state without enabling or disabling fan override.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\DellFanController.ps1 -ConfigPath .\controller-config.production.json -EnableProductionMode -ValidateOnly
```

Use `StartupOnly` to verify startup recovery and write a startup log entry without running the monitoring loop or issuing write commands.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\DellFanController.ps1 -ConfigPath .\controller-config.production.json -EnableProductionMode -StartupOnly
```

Run a short production test:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\DellFanController.ps1 -ConfigPath .\controller-config.production.json -EnableProductionMode -AllowHardwareWrites -HardwareWriteConfirmation 'ENABLE_AUTOMATIC_DELL_FAN_CONTROLLER' -RunMinutes 10
```

Run continuously only after short-run logs prove boost, restore and cooldown behavior.
