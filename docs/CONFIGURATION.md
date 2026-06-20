# Configuration

Copy `controller-config.example.json` to `controller-config.production.json`. The production file is ignored by Git.

| Parameter | Type | Allowed value | Default | Meaning | Safety impact |
| --- | --- | --- | --- | --- | --- |
| `SchemaVersion` | integer | `1` | `1` | Config schema version. | Unknown versions fail validation. |
| `ThresholdCelsius` | integer | 60 to 90 | 75 | Temperature required before high-reading counting. | Too low can cause frequent fan override. |
| `PollIntervalSeconds` | integer | 15 to 300 in legacy dry-run, production supports configured polling | 30 | Seconds between samples. | Lower values increase command/log activity. |
| `RequiredConsecutiveHighReadings` | integer | 1 to 10 | 2 | Number of high samples before boost. | Higher values reduce false positives. |
| `BoostDurationSeconds` | integer | 30 to 900 | 150 | How long boost stays active. | Longer boosts keep override active longer. |
| `CooldownSeconds` | integer | 60 to 3600 | 300 | Delay after restore before a new boost. | Prevents rapid enable/restore cycles. |
| `DryRun` | boolean | `false` for production | false | Production config must be false. | Prevents accidental live mode confusion. |
| `SensorProvider` | string | `CoreTempSharedMemory` | CoreTempSharedMemory | Temperature source. | Missing Core Temp fails closed. |
| `Backend` | string | `DellCctk` | DellCctk | Fan-control backend. | Only Dell CCTK is supported for live writes. |
| `CctkPath` | string | Absolute path ending in `cctk.exe` | Dell default path | Dell Command | Configure executable. | Invalid or unexpected paths fail closed. |
| `CommandTimeoutSeconds` | integer | 5 to 300 | 15 | CCTK command timeout. | Prevents hung CCTK calls. |
| `StatePath` | string | Relative or absolute local path | logs state path | Controller-owned state file. | Enables safe cleanup and ownership checks. |
| `LogPath` | string | Relative or absolute local path | logs CSV path | Production CSV log. | Needed for audit and troubleshooting. |

Example:

```json
{
  "SchemaVersion": 1,
  "ThresholdCelsius": 75,
  "PollIntervalSeconds": 30,
  "RequiredConsecutiveHighReadings": 2,
  "BoostDurationSeconds": 150,
  "CooldownSeconds": 300,
  "DryRun": false,
  "SensorProvider": "CoreTempSharedMemory",
  "Backend": "DellCctk",
  "CctkPath": "C:\\Program Files (x86)\\Dell\\Command Configure\\X86_64\\cctk.exe",
  "CommandTimeoutSeconds": 15,
  "StatePath": "logs\\dell-fan-controller-state.dellcctk.json",
  "LogPath": "logs\\dell-fan-controller-production.csv"
}
```
