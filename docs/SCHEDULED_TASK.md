# Scheduled Task

The included helper creates a logon task that runs with highest privileges, waits 60 seconds, uses `powershell.exe -File`, passes `-AllowHardwareWrites` and the exact hardware-write confirmation, uses a hidden window, restarts on failure, ignores duplicate instances and has unlimited runtime.

Install manually:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-ScheduledTask.ps1
```

Uninstall manually:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Uninstall-ScheduledTask.ps1
```

Uninstalling removes only the task. It does not remove project files, logs or state.
