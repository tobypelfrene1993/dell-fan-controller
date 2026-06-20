# Installation

Install to a neutral path such as `C:\DellFanController`.

1. Open Windows PowerShell 5.1 as Administrator.
2. Install Core Temp from the official Core Temp source.
3. Start Core Temp and confirm its shared memory is available.
4. Install Dell Command | Configure from Dell.
5. Find `cctk.exe`, commonly `C:\Program Files (x86)\Dell\Command Configure\X86_64\cctk.exe`.
6. Download or clone this repository into `C:\DellFanController`.
7. Copy `controller-config.example.json` to `controller-config.production.json`.
8. Review `CctkPath`, `StatePath`, `LogPath`, thresholds and durations.
9. Run `scripts\Test-Prerequisites.ps1`.
10. Run `ValidateOnly` manually.
11. Run `StartupOnly` manually.
12. Run a limited production session with `-RunMinutes 10`.
13. For a boost test, use a separate local test config and review logs immediately.
14. Install the Scheduled Task with `scripts\Install-ScheduledTask.ps1`.
15. Reboot once and confirm the task, log and restore behavior.

Do not run production mode until `ValidateOnly` proves Core Temp, CCTK, administrator rights and automatic fan state.
