# Contributing

Contributions should preserve the fail-closed design. Changes that touch hardware writes, state ownership, process execution, Scheduled Task behavior, or config validation need tests and a clear safety rationale.

Before opening a pull request:

- Run parser checks on all PowerShell files.
- Run only fake-only hermetic tests unless you are deliberately doing a local hardware validation.
- Do not commit `controller-config.production.json`, logs, state files, binaries, screenshots, credentials, or machine-specific data.
- Keep third-party software out of the repository.
