# Architecture

Flow:

```text
Core Temp
-> snapshot
-> highest temperature
-> consecutive-high logic
-> Dell CCTK backend
-> fan override Enabled
-> verification
-> boost
-> restore Disabled/Automatic
-> verification
-> cooldown
-> logging/state
```

The production session builds one process executor and one backend instance. The executor accepts only exact CCTK command specs. The backend contract exposes availability, get-state, enable boost, restore automatic and emergency reset operations.

State ownership records controller instance, correlation id, backend and operation phase. Startup recovery uses that state to decide whether to block, verify, restore, or clean up. Unknown or corrupt state fails closed.

The controller uses a mutex to prevent multiple instances. `ValidateOnly` and `StartupOnly` are read-only modes for production checks. Normal production mode requires administrator rights, `-AllowHardwareWrites`, and `ENABLE_AUTOMATIC_DELL_FAN_CONTROLLER`.
