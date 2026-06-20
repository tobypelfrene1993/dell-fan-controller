# Troubleshooting

## Core Temp shared memory unavailable

Start Core Temp and confirm it exposes shared memory. Re-run `ValidateOnly`.

## cctk.exe not found

Install Dell Command | Configure from Dell and update `CctkPath`.

## Administrator rights missing

Run Windows PowerShell as Administrator or use the Scheduled Task with highest privileges.

## ExecutionPolicy

Use `-ExecutionPolicy Bypass` for this script invocation, or set a local policy you understand.

## Started=False or ExitCode=null

CCTK did not start cleanly or returned an invalid executor result. Check path, permissions and timeout.

## fan status Unknown

The CCTK output did not parse as `FanCtrlOvrd=Disabled` or `FanCtrlOvrd=Enabled`. Do not continue until this is understood.

## Scheduled Task Ready but not Running

Check trigger, logon state, highest-privileges setting and task history.

## Multiple instances

The mutex blocks duplicate controllers. Stop the existing instance before starting another.

## No new log lines

Check `LogPath`, permissions, task account and whether the controller exited early.

## Config not loaded

Pass an explicit `-ConfigPath` and validate JSON.

## Fan boost does not start

Review threshold, consecutive readings, Core Temp values and cooldown state.

## Restore failed

Run the emergency restore helper and verify Automatic state before restarting.
