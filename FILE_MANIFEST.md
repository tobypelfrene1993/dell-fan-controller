# File Manifest

Public release files are grouped as:

- Core controller: `DellFanController.ps1`, `DellFanController-ProductionSupport.ps1`, `DellFanController-State.ps1`.
- Backends and execution: `FanBackend.Contract.ps1`, `FanBackend.DellCctk.ps1`, `FanBackend.Mock.ps1`, `DellCctk.ProcessExecutor.ps1`.
- Discovery and recovery: `Discover-CoreTempSharedMemory.ps1`, `Discover-CoreTempSensors.ps1`, `Discover-TemperatureSensors.ps1`, `Invoke-DellCctkReadOnlyProbe.ps1`, `Invoke-DellFanControllerProductionPreflight.ps1`, `Reset-DellFanController.ps1`.
- Legacy safe tools: `DellFanController-DryRun.ps1`, `DellFanController-Settings.ps1`.
- Tests: `Test-*.ps1`.
- Config examples: `controller-config.example.json`, `controller-config.production.example.json`, `controller-config.json`, `coretemp-config.example.json`.
- Helper scripts: `scripts\*.ps1`.
- Documentation: `README.md`, `docs\*.md`, `SECURITY.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `LICENSE-OPTIONS.md`, `PUBLISH_CHECKLIST.md`, `SANITIZATION_REPORT.md`.
- GitHub metadata: `.github\ISSUE_TEMPLATE\*.yml`, `.github\pull_request_template.md`, `.github\workflows\powershell-tests.yml`.

Excluded:

- `.git`
- logs and CSV files
- runtime state files
- backups and temporary files
- `test-output`
- third-party binaries and archives
- private production config
