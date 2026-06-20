# Security Policy

Report security issues privately to the repository owner. Do not open a public issue for secrets, unsafe hardware-write behavior, or a bypass of confirmation checks.

This project intentionally controls hardware through Dell Command | Configure when production mode is enabled. The safe default posture is read-only validation first, then a short manual run, then a Scheduled Task only after logs confirm restore behavior.

Never attach production logs, state files, screenshots with personal data, CCTK binaries, Core Temp binaries, or machine-specific paths to public issues.
