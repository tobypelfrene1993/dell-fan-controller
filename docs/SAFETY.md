# Safety

Use this project at your own risk and only on supported Dell hardware. Start with read-only validation and do not blindly lower thresholds.

Core Temp must be available. Dell Command | Configure must be installed separately. The controller never bundles CCTK or Core Temp.

Hardware writes are gated by:

- Administrator requirement.
- Explicit `-AllowHardwareWrites` switch.
- Exact confirmation string.
- Allowlisted CCTK arguments.
- Backend verification after writes.
- State ownership and cleanup.

If the fan remains at full speed, stop the controller, run the emergency restore helper, then confirm `FanCtrlOvrd=Disabled` or equivalent Automatic state with Dell CCTK. Do not delete state before restore is verified.
