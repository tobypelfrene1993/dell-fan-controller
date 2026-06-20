# Testing

Safe CI tests are parser checks and fake-only tests. They do not require CCTK, Core Temp, administrator rights or real hardware.

CI-safe examples:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-ControllerState.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-DellCctkProcessExecutor.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-FanBackend.Mock.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-FanBackend.DellCctk.ps1
```

Manual only:

- `ValidateOnly`
- `StartupOnly`
- normal production mode
- Core Temp shared-memory live sampling
- Dell CCTK live probes
- controlled fan boost tests
- emergency restore against real CCTK

Never run manual hardware tests from GitHub Actions.
