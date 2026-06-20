[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProcessExecutorVersion = '2026-06-19-validated-v1'

function Test-DellCctkExecutorArgument {
    param([string]$Argument)
    if ([string]::IsNullOrWhiteSpace($Argument)) { return $false }
    if ($Argument -ne $Argument.Trim()) { return $false }
    if ($Argument -match '[\s''"`|&;<>]') { return $false }
    @('--FanCtrlOvrd','--FanCtrlOvrd=Enabled','--FanCtrlOvrd=Disabled') -contains $Argument
}

function Test-DellCctkExecutorCommandSpec {
    param(
        [object]$CommandSpec,
        [bool]$AllowHardwareWrites
    )

    $errors = @()
    if ($null -eq $CommandSpec) {
        return [pscustomobject]@{ Success=$false; IsWriteOperation=$false; Errors=@('CommandSpec ontbreekt.') }
    }

    $path = [string]$CommandSpec.ExecutablePath
    if ([string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathRooted($path)) { $errors += 'ExecutablePath moet absoluut zijn.' }
    if (-not [string]::IsNullOrWhiteSpace($path)) {
        if ([IO.Path]::GetFileName($path) -ne 'cctk.exe') { $errors += 'ExecutablePath moet eindigen op cctk.exe.' }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $errors += 'ExecutablePath bestaat niet.' }
    }

    $arguments = @($CommandSpec.ArgumentList)
    if ($arguments.Count -ne 1) {
        $errors += 'Er moet exact een argument zijn.'
    } elseif (-not (Test-DellCctkExecutorArgument -Argument ([string]$arguments[0]))) {
        $errors += 'Argument is niet exact allowlisted of bevat verboden tekens.'
    }

    $argument = if ($arguments.Count -eq 1) { [string]$arguments[0] } else { '' }
    $isWrite = ($argument -eq '--FanCtrlOvrd=Enabled' -or $argument -eq '--FanCtrlOvrd=Disabled')
    if ($argument -eq '--FanCtrlOvrd' -and [string]$CommandSpec.Operation -ne 'QueryFanControlState') { $errors += 'Query-argument hoort bij QueryFanControlState.' }
    if ($argument -eq '--FanCtrlOvrd=Enabled' -and [string]$CommandSpec.Operation -ne 'EnableFanBoost') { $errors += 'Enabled-argument hoort bij EnableFanBoost.' }
    if ($argument -eq '--FanCtrlOvrd=Disabled' -and [string]$CommandSpec.Operation -ne 'RestoreAutomaticFanControl') { $errors += 'Disabled-argument hoort bij RestoreAutomaticFanControl.' }
    if ($isWrite -and $AllowHardwareWrites -ne $true) { $errors += 'Write-operatie geweigerd: AllowHardwareWrites is niet exact true.' }

    $timeout = 0
    if (-not [int]::TryParse(([string]$CommandSpec.TimeoutSeconds), [ref]$timeout) -or $timeout -lt 1 -or $timeout -gt 300) {
        $errors += 'TimeoutSeconds moet tussen 1 en 300 liggen.'
    }

    [pscustomobject]@{ Success=($errors.Count -eq 0); IsWriteOperation=$isWrite; Errors=@($errors) }
}

function New-DellCctkProductionProcessInvoker {
    {
        param([string]$ExecutablePath, [string[]]$ArgumentList, [int]$TimeoutSeconds)

        $process = $null
        $started = Get-Date
        try {
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $ExecutablePath
            if ($null -ne $startInfo.GetType().GetProperty('ArgumentList')) {
                foreach ($argument in @($ArgumentList)) { [void]$startInfo.ArgumentList.Add($argument) }
            } else {
                $startInfo.Arguments = [string]@($ArgumentList)[0]
            }
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.CreateNoWindow = $true

            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $startInfo
            $startedOk = $process.Start()
            if (-not $startedOk) { throw 'Proces kon niet worden gestart.' }
            $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
            if ($timedOut) {
                try { $process.Kill() } catch {}
                try { $process.WaitForExit() } catch {}
                return [pscustomobject]@{
                    ExitCode = $null
                    StdOut = ''
                    StdErr = 'Process timeout.'
                    TimedOut = $true
                    DurationMs = [int]((Get-Date) - $started).TotalMilliseconds
                    Started = $true
                    ErrorMessage = 'Process timeout.'
                }
            }
            $process.WaitForExit()
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $exitCode = $process.ExitCode
            [pscustomobject]@{
                ExitCode = $exitCode
                StdOut = $stdout
                StdErr = $stderr
                TimedOut = $false
                DurationMs = [int]((Get-Date) - $started).TotalMilliseconds
                Started = $true
                ErrorMessage = $null
            }
        }
        catch {
            [pscustomobject]@{
                ExitCode = $null
                StdOut = ''
                StdErr = ''
                TimedOut = $false
                DurationMs = [int]((Get-Date) - $started).TotalMilliseconds
                Started = $false
                ErrorMessage = $_.Exception.Message
            }
        }
        finally {
            if ($null -ne $process) { $process.Dispose() }
        }
    }
}

function ConvertTo-DellCctkValidatedExecutorResult {
    param(
        [object[]]$RawResult,
        [int]$FallbackDurationMs
    )

    if (@($RawResult).Count -ne 1) {
        return [pscustomobject]@{
            ExitCode = $null
            StdOut = ''
            StdErr = ''
            TimedOut = $false
            DurationMs = [int]$FallbackDurationMs
            Started = $false
            ErrorMessage = "InvalidExecutorResult: ProcessInvoker retourneerde $(@($RawResult).Count) pipeline-objecten in plaats van exact een PSCustomObject."
        }
    }

    $raw = @($RawResult)[0]
    if ($null -eq $raw -or $raw -isnot [pscustomobject]) {
        return [pscustomobject]@{
            ExitCode = $null
            StdOut = ''
            StdErr = ''
            TimedOut = $false
            DurationMs = [int]$FallbackDurationMs
            Started = $false
            ErrorMessage = "InvalidExecutorResult: ProcessInvoker retourneerde geen PSCustomObject."
        }
    }

    $names = @($raw.PSObject.Properties | ForEach-Object { $_.Name })
    $required = @('Started','ExitCode','StdOut','StdErr','TimedOut','DurationMs','ErrorMessage')
    $missing = @($required | Where-Object { $names -notcontains $_ })
    if ($missing.Count -gt 0) {
        return [pscustomobject]@{
            ExitCode = $null
            StdOut = ''
            StdErr = ''
            TimedOut = $false
            DurationMs = [int]$FallbackDurationMs
            Started = $false
            ErrorMessage = "InvalidExecutorResult: verplichte properties ontbreken: $($missing -join ', ')."
        }
    }

    $started = [bool]$raw.Started
    $timedOut = [bool]$raw.TimedOut
    $errorMessage = if ($null -ne $raw.ErrorMessage) { [string]$raw.ErrorMessage } else { $null }
    $exitCode = $null
    if ($null -ne $raw.ExitCode) {
        if ($raw.ExitCode -isnot [int] -and $raw.ExitCode -isnot [long]) {
            $parsedExitCode = 0
            if (-not [int]::TryParse([string]$raw.ExitCode, [ref]$parsedExitCode)) {
                return [pscustomobject]@{
                    ExitCode = $null
                    StdOut = ''
                    StdErr = ''
                    TimedOut = $false
                    DurationMs = [int]$FallbackDurationMs
                    Started = $false
                    ErrorMessage = 'InvalidExecutorResult: ExitCode is geen integer.'
                }
            }
            $exitCode = [int]$parsedExitCode
        } else {
            $exitCode = [int]$raw.ExitCode
        }
    }

    if ($started -and -not $timedOut -and $null -eq $exitCode) {
        $errorMessage = 'InvalidExecutorResult: ExitCode ontbreekt terwijl Started=true en TimedOut=false.'
    }
    if (-not $started -and [string]::IsNullOrWhiteSpace([string]$errorMessage)) {
        $errorMessage = 'InvalidExecutorResult: Started=false zonder concrete ErrorMessage.'
    }
    if ($null -eq $errorMessage -and $exitCode -eq 0 -and $null -eq $raw.StdOut) {
        $errorMessage = 'InvalidExecutorResult: StdOut ontbreekt bij ExitCode=0.'
    }

    [pscustomobject]@{
        ExitCode = if ($null -ne $errorMessage -and $errorMessage.StartsWith('InvalidExecutorResult:')) { $null } else { $exitCode }
        StdOut = if ($null -ne $raw.StdOut) { [string]$raw.StdOut } else { '' }
        StdErr = if ($null -ne $raw.StdErr) { [string]$raw.StdErr } else { '' }
        TimedOut = $timedOut
        DurationMs = if ($null -ne $raw.DurationMs) { [int64]$raw.DurationMs } else { [int64]$FallbackDurationMs }
        Started = $started
        ErrorMessage = $errorMessage
    }
}

function New-DellCctkProcessExecutor {
    param(
        [object]$AllowHardwareWrites = $false,
        [scriptblock]$ProcessInvoker,
        [int]$DefaultTimeoutSeconds = 15
    )

    if ($DefaultTimeoutSeconds -lt 1 -or $DefaultTimeoutSeconds -gt 300) { throw 'DefaultTimeoutSeconds moet tussen 1 en 300 liggen.' }
    $writeAllowed = ($null -ne $AllowHardwareWrites -and $AllowHardwareWrites.GetType().FullName -eq 'System.Boolean' -and $AllowHardwareWrites -eq $true)
    $invoker = if ($PSBoundParameters.ContainsKey('ProcessInvoker')) { $ProcessInvoker } else { New-DellCctkProductionProcessInvoker }
    if ($null -eq $invoker -or $invoker -isnot [scriptblock]) { throw 'ProcessInvoker moet een scriptblock zijn.' }

    {
        param($CommandSpec, $CorrelationId, $Reason)

        $startedAt = Get-Date
        try {
            $validation = Test-DellCctkExecutorCommandSpec -CommandSpec $CommandSpec -AllowHardwareWrites $writeAllowed
            if (-not $validation.Success) {
                return [pscustomobject]@{
                    ExitCode = $null
                    StdOut = ''
                    StdErr = ''
                    TimedOut = $false
                    DurationMs = [int]((Get-Date) - $startedAt).TotalMilliseconds
                    Started = $false
                    ErrorMessage = ($validation.Errors -join '; ')
                }
            }
            $timeout = if ($null -ne $CommandSpec.TimeoutSeconds) { [int]$CommandSpec.TimeoutSeconds } else { $DefaultTimeoutSeconds }
            $raw = @(& $invoker ([string]$CommandSpec.ExecutablePath) ([string[]]@($CommandSpec.ArgumentList)) $timeout)
            ConvertTo-DellCctkValidatedExecutorResult -RawResult $raw -FallbackDurationMs ([int]((Get-Date) - $startedAt).TotalMilliseconds)
        }
        catch {
            [pscustomobject]@{
                ExitCode = $null
                StdOut = ''
                StdErr = ''
                TimedOut = $false
                DurationMs = [int]((Get-Date) - $startedAt).TotalMilliseconds
                Started = $false
                ErrorMessage = $_.Exception.Message
            }
        }
    }.GetNewClosure()
}
