[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Json,
    [object]$TestIsAdministrator,
    [object]$TestCoreTempSnapshot,
    [scriptblock]$TestProcessInvoker,
    [string]$TestFakeMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$entryConfigPathWasBound = $PSBoundParameters.ContainsKey('ConfigPath')
$entryOriginalConfigPath = $ConfigPath
$entryTestIsAdministratorWasBound = $PSBoundParameters.ContainsKey('TestIsAdministrator')
$entryOriginalTestIsAdministrator = $TestIsAdministrator
$entryTestCoreTempSnapshotWasBound = $PSBoundParameters.ContainsKey('TestCoreTempSnapshot')
$entryOriginalTestCoreTempSnapshot = $TestCoreTempSnapshot
$entryTestProcessInvokerWasBound = $PSBoundParameters.ContainsKey('TestProcessInvoker')
$entryOriginalTestProcessInvoker = $TestProcessInvoker
$entryTestFakeModeWasBound = $PSBoundParameters.ContainsKey('TestFakeMode')
$entryOriginalTestFakeMode = $TestFakeMode

function Resolve-ProductionPreflightConfigPath {
    param(
        [string]$InputPath,
        [bool]$WasBound
    )

    if (-not $WasBound -or [string]::IsNullOrWhiteSpace($InputPath)) {
        return [pscustomobject]@{
            WasBound = [bool]$WasBound
            OriginalPath = $InputPath
            ResolvedPath = ''
            Success = $false
            ErrorMessage = 'ConfigPath is verplicht.'
        }
    }

    try {
        $resolved = (Resolve-Path -LiteralPath $InputPath -ErrorAction Stop).Path
        return [pscustomobject]@{
            WasBound = [bool]$WasBound
            OriginalPath = $InputPath
            ResolvedPath = $resolved
            Success = $true
            ErrorMessage = ''
        }
    }
    catch {
        $absolute = try {
            if ([IO.Path]::IsPathRooted($InputPath)) { [IO.Path]::GetFullPath($InputPath) }
            else { [IO.Path]::GetFullPath((Join-Path (Get-Location) $InputPath)) }
        } catch { [string]$InputPath }
        return [pscustomobject]@{
            WasBound = [bool]$WasBound
            OriginalPath = $InputPath
            ResolvedPath = $absolute
            Success = $false
            ErrorMessage = "ConfigPath kan niet worden resolved met Resolve-Path -LiteralPath: $($_.Exception.Message)"
        }
    }
}

$entryConfigPathDiagnostics = Resolve-ProductionPreflightConfigPath -InputPath $entryOriginalConfigPath -WasBound $entryConfigPathWasBound
. (Join-Path $ScriptDirectory 'DellFanController.ps1')

function Read-ProductionPreflightCoreTemp {
    param([object]$TestSnapshot)

    if ($null -ne $TestSnapshot) { return $TestSnapshot }
    $discover = Join-Path $ScriptDirectory 'Discover-CoreTempSharedMemory.ps1'
    $output = & $discover -Json 2>&1
    $text = ($output | Out-String).Trim()
    if ($text -eq 'Core Temp shared memory unavailable') {
        return [pscustomobject]@{ Available=$false; CoreCount=0; HighestTemperature=$null; Message=$text }
    }
    $parsed = $text | ConvertFrom-Json
    [pscustomobject]@{
        Available = $true
        CoreCount = [int]$parsed.CoreCount
        HighestTemperature = $parsed.HighestCoreTemperatureCelsius
        Message = ''
    }
}

function Get-ProductionPreflightRecoveryAction {
    param([object]$StateRead)

    if ($null -eq $StateRead -or -not $StateRead.Success) { return 'StateUnavailableNoWrite' }
    switch ([string]$StateRead.State.OperationPhase) {
        'Idle' { 'NoRecoveryWriteRequiredIdle' }
        'Restored' { 'NoRecoveryWriteRequiredRestored' }
        'EnablePending' { 'WouldInspectBackendNoWrite' }
        'ActiveVerified' { 'WouldRestoreAutomaticNoWrite' }
        'DisablePending' { 'WouldRestoreAutomaticNoWrite' }
        default { 'UnknownStateNoWrite' }
    }
}

function New-ProductionPreflightFakeProcessInvoker {
    param([string]$Mode)

    {
        param([string]$ExecutablePath, [string[]]$ArgumentList, [int]$TimeoutSeconds)
        switch ($Mode) {
            'ExactRegression' { [pscustomobject]@{ Started=$true; ExitCode=0; StdOut='FanCtrlOvrd=Disabled'; StdErr=''; TimedOut=$false; DurationMs=35; ErrorMessage=$null } }
            'NullExitCode' { [pscustomobject]@{ Started=$true; ExitCode=$null; StdOut='FanCtrlOvrd=Disabled'; StdErr=''; TimedOut=$false; DurationMs=35; ErrorMessage=$null } }
            'PipelineBoolean' { Write-Output $true; [pscustomobject]@{ Started=$true; ExitCode=0; StdOut='FanCtrlOvrd=Disabled'; StdErr=''; TimedOut=$false; DurationMs=35; ErrorMessage=$null } }
            'MultipleObjects' { [pscustomobject]@{ Started=$true; ExitCode=0; StdOut='one'; StdErr=''; TimedOut=$false; DurationMs=1; ErrorMessage=$null }; [pscustomobject]@{ Started=$true; ExitCode=0; StdOut='two'; StdErr=''; TimedOut=$false; DurationMs=2; ErrorMessage=$null } }
            'Automatic' { [pscustomobject]@{ ExitCode=0; StdOut='FanCtrlOvrd=Disabled'; StdErr=''; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null } }
            'Unknown' { [pscustomobject]@{ ExitCode=0; StdOut='FanCtrlOvrd=Maybe'; StdErr=''; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null } }
            'NonZero' { [pscustomobject]@{ ExitCode=7; StdOut=''; StdErr='nonzero'; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null } }
            'Timeout' { [pscustomobject]@{ ExitCode=$null; StdOut=''; StdErr='timeout'; TimedOut=$true; DurationMs=15000; Started=$true; ErrorMessage='timeout' } }
            default { [pscustomobject]@{ ExitCode=0; StdOut='FanCtrlOvrd=Disabled'; StdErr=''; TimedOut=$false; DurationMs=1; Started=$true; ErrorMessage=$null } }
        }
    }.GetNewClosure()
}

function New-ProductionPreflightReport {
    param(
        [string]$InputConfigPath,
        [object]$ConfigValidation,
        [object]$Admin,
        [object]$CoreTemp,
        [object]$PathCheck,
        [object]$StateRead,
        [string]$RecoveryAction,
        [object]$Backend,
        [object]$AvailabilityResult,
        [object]$GetStateResult,
        [int]$ExitCode,
        [string]$ResultName,
        [string]$Message,
        [object]$ConfigPathDiagnostics
    )

    $lastAction = Get-ProductionSafeActionLogEntry -Backend $Backend
    $diagnostics = if ($null -ne $GetStateResult) { $GetStateResult.Diagnostics } else { $null }
    $diagnosticPropertyNames = if ($null -ne $diagnostics) { @($diagnostics.PSObject.Properties | ForEach-Object { $_.Name }) } else { @() }
    [pscustomobject]@{
        ProductionSupportVersion = $script:ProductionSupportVersion
        ProcessExecutorVersion = $script:ProcessExecutorVersion
        ConfigPath = $InputConfigPath
        ConfigPathDiagnostics = $ConfigPathDiagnostics
        ConfigValid = [bool]$ConfigValidation.IsValid
        Administrator = [bool]$Admin
        CoreTempAvailable = [bool]$CoreTemp.Available
        CoreTempCoreCount = $CoreTemp.CoreCount
        CoreTempHighestTemperature = $CoreTemp.HighestTemperature
        StateFound = ($null -ne $StateRead -and $StateRead.Success)
        StateSource = if ($null -ne $StateRead -and $StateRead.Success) { 'StateFile' } else { 'None' }
        StateOperationPhase = if ($null -ne $StateRead -and $StateRead.Success) { $StateRead.State.OperationPhase } else { $null }
        RecoveryAction = $RecoveryAction
        CctkPath = if ($null -ne $ConfigValidation.Config) { $ConfigValidation.Config.CctkPath } else { $null }
        FileVersion = $PathCheck.FileVersion
        ProductVersion = $PathCheck.ProductVersion
        BackendName = if ($null -ne $Backend) { $Backend.BackendName } else { $null }
        BackendType = if ($null -ne $Backend) { $Backend.BackendType } else { $null }
        CommandExecutorPresent = ($null -ne $Backend -and $Backend.CommandExecutor -is [scriptblock])
        AllowHardwareWrites = if ($null -ne $Backend) { [bool]$Backend.AllowHardwareWrites } else { $false }
        AvailabilityResult = Convert-ProductionBackendResultForJson -Result $AvailabilityResult
        AvailabilityErrorCode = if ($null -ne $AvailabilityResult) { $AvailabilityResult.ErrorCode } else { $null }
        AvailabilityErrorMessage = if ($null -ne $AvailabilityResult) { $AvailabilityResult.ErrorMessage } else { $null }
        GetStateResult = Convert-ProductionBackendResultForJson -Result $GetStateResult
        Success = if ($null -ne $GetStateResult) { $GetStateResult.Success } else { $false }
        Action = if ($null -ne $GetStateResult) { $GetStateResult.Action } else { $null }
        PreviousState = if ($null -ne $GetStateResult) { $GetStateResult.PreviousState } else { $null }
        NewState = if ($null -ne $GetStateResult) { $GetStateResult.NewState } else { 'Unknown' }
        Verified = if ($null -ne $GetStateResult) { $GetStateResult.Verified } else { $false }
        RequiresCleanup = if ($null -ne $GetStateResult) { $GetStateResult.RequiresCleanup } else { $false }
        ErrorCode = if ($null -ne $GetStateResult) { $GetStateResult.ErrorCode } else { $null }
        ErrorMessage = if ($null -ne $GetStateResult) { $GetStateResult.ErrorMessage } else { $Message }
        Diagnostics = $diagnostics
        ActionLog = if ($null -ne $Backend) { @($Backend.ActionLog) } else { @() }
        ExecutedArgument = if ($null -ne $lastAction) { $lastAction.ExecutedArgument } else { $null }
        ExitCode = if ($null -ne $diagnostics) { $diagnostics.ExitCode } elseif ($null -ne $lastAction) { $lastAction.ExitCode } else { $null }
        StdOut = if ($null -ne $diagnostics) { $diagnostics.StdOut } else { $null }
        StdErr = if ($null -ne $diagnostics) { $diagnostics.StdErr } else { $null }
        TimedOut = if ($null -ne $diagnostics) { $diagnostics.TimedOut } elseif ($null -ne $lastAction) { $lastAction.TimedOut } else { $false }
        ExecutorResultType = if ($null -ne $diagnostics) { $diagnostics.GetType().FullName } else { $null }
        ExecutorResultPropertyNames = $diagnosticPropertyNames
        Started = if ($diagnosticPropertyNames -contains 'Started') { $diagnostics.Started } else { $null }
        RawExitCode = if ($diagnosticPropertyNames -contains 'ExitCode') { $diagnostics.ExitCode } else { $null }
        RawStdOut = if ($diagnosticPropertyNames -contains 'StdOut') { $diagnostics.StdOut } else { $null }
        RawStdErr = if ($diagnosticPropertyNames -contains 'StdErr') { $diagnostics.StdErr } else { $null }
        RawTimedOut = if ($diagnosticPropertyNames -contains 'TimedOut') { $diagnostics.TimedOut } else { $null }
        RawErrorMessage = if ($diagnosticPropertyNames -contains 'ErrorMessage') { $diagnostics.ErrorMessage } else { $null }
        Resultaat = $ResultName
        ProcessExitCode = [int]$ExitCode
        Message = $Message
    }
}

function Invoke-DellFanControllerProductionPreflight {
    param(
        [string]$ConfigPath,
        [object]$TestIsAdministrator,
        [object]$TestCoreTempSnapshot,
        [scriptblock]$TestProcessInvoker,
        [string]$TestFakeMode,
        [object]$ConfigPathDiagnostics
    )

    $exitCode = 99
    $resultName = 'UnexpectedError'
    $message = ''
    $configValidation = [pscustomobject]@{ IsValid=$false; Config=$null; Errors=@() }
    $config = $null
    $backend = $null
    $session = $null
    $pathCheck = [pscustomobject]@{ Success=$false; FileVersion=$null; ProductVersion=$null; Errors=@() }
    $stateRead = $null
    $availability = $null
    $state = $null
    $coreTemp = [pscustomobject]@{ Available=$false; CoreCount=0; HighestTemperature=$null; Message='' }
    $admin = $false
    $recoveryAction = 'NotEvaluated'
    $configPathResolution = if ($null -ne $ConfigPathDiagnostics) { $ConfigPathDiagnostics } else { Resolve-ProductionPreflightConfigPath -InputPath $ConfigPath -WasBound $true }

    try {
        if (-not $configPathResolution.Success) {
            $exitCode = 11
            $resultName = 'InvalidConfigPath'
            $message = $configPathResolution.ErrorMessage
            return New-ProductionPreflightReport -InputConfigPath $configPathResolution.ResolvedPath -ConfigValidation $configValidation -Admin $admin -CoreTemp $coreTemp -PathCheck $pathCheck -StateRead $stateRead -RecoveryAction $recoveryAction -Backend $backend -AvailabilityResult $availability -GetStateResult $state -ExitCode $exitCode -ResultName $resultName -Message $message -ConfigPathDiagnostics $configPathResolution
        }

        $configValidation = Read-DellFanControllerProductionConfig -Path $configPathResolution.ResolvedPath
        $config = $configValidation.Config
        $admin = if ($null -ne $TestIsAdministrator) { [bool]$TestIsAdministrator } else { Test-ProductionAdministrator }
        if (-not [string]::IsNullOrWhiteSpace($TestFakeMode) -and $null -eq $TestCoreTempSnapshot) {
            $TestCoreTempSnapshot = [pscustomobject]@{ Available=$true; CoreCount=6; HighestTemperature=60.0; Message='' }
        }
        if (-not [string]::IsNullOrWhiteSpace($TestFakeMode) -and $null -eq $TestProcessInvoker) {
            $TestProcessInvoker = New-ProductionPreflightFakeProcessInvoker -Mode $TestFakeMode
        }
        $coreTemp = Read-ProductionPreflightCoreTemp -TestSnapshot $TestCoreTempSnapshot
        $pathCheck = Test-DellCctkPath -CctkPath $config.CctkPath -MinimumVersion '5.2.2.0'
        $stateRead = if (Test-Path -LiteralPath $config.StatePath -PathType Leaf) { Read-ControllerState -Path $config.StatePath } else { [pscustomobject]@{ Success=$false; State=$null; Errors=@('Statebestand ontbreekt.') } }
        $recoveryAction = Get-ProductionPreflightRecoveryAction -StateRead $stateRead

        if (-not $pathCheck.Success) {
            $availability = New-FanBackendResult -Success $false -Action 'TestAvailability' -PreviousState $null -NewState 'Unknown' -Verified $false -RequiresCleanup $false -ErrorCode 'InvalidPath' -ErrorMessage ($pathCheck.Errors -join '; ') -Diagnostics $pathCheck
            $exitCode = 12
            $resultName = 'BackendAvailabilityFailed'
            $message = $availability.ErrorMessage
        } else {
            $sessionParams = @{ Config = $config; AllowHardwareWrites = $false }
            if ($null -ne $TestProcessInvoker) { $sessionParams.ProcessInvoker = $TestProcessInvoker }
            $session = New-ProductionDellCctkSession @sessionParams
            $backend = $session.Backend
            $availability = $session.AvailabilityResult
            if (-not $availability.Success) {
                $exitCode = 12
                $resultName = 'BackendAvailabilityFailed'
                $message = $availability.ErrorMessage
            } else {
                $state = $session.BeginStateResult
                if (Test-ProductionAutomaticFanState -StateResult $state) {
                    $exitCode = 0
                    $resultName = 'VerifiedAutomatic'
                } else {
                    $exitCode = 13
                    $resultName = 'StatusNotVerifiedAutomatic'
                    $message = if ($state.ErrorMessage) { $state.ErrorMessage } else { 'Status is niet verified Automatic.' }
                }
            }
        }
    }
    catch {
        $exitCode = if ($exitCode -eq 99) { 99 } else { $exitCode }
        $message = $_.Exception.Message
        if ($exitCode -eq 99) { $resultName = 'UnexpectedError' }
        if ($null -eq $configValidation) { $configValidation = [pscustomobject]@{ IsValid=$false; Config=$null; Errors=@($message) } }
    }

    New-ProductionPreflightReport -InputConfigPath $configPathResolution.ResolvedPath -ConfigValidation $configValidation -Admin $admin -CoreTemp $coreTemp -PathCheck $pathCheck -StateRead $stateRead -RecoveryAction $recoveryAction -Backend $backend -AvailabilityResult $availability -GetStateResult $state -ExitCode $exitCode -ResultName $resultName -Message $message -ConfigPathDiagnostics $configPathResolution
}

if ($MyInvocation.InvocationName -ne '.') {
    $invokeParams = @{
        ConfigPath = $entryOriginalConfigPath
        ConfigPathDiagnostics = $entryConfigPathDiagnostics
    }
    if ($entryTestIsAdministratorWasBound) {
        $invokeParams.TestIsAdministrator = $entryOriginalTestIsAdministrator
    }
    if ($entryTestCoreTempSnapshotWasBound) {
        $invokeParams.TestCoreTempSnapshot = $entryOriginalTestCoreTempSnapshot
    }
    if ($entryTestProcessInvokerWasBound) {
        $invokeParams.TestProcessInvoker = $entryOriginalTestProcessInvoker
    }
    if ($entryTestFakeModeWasBound) {
        $invokeParams.TestFakeMode = $entryOriginalTestFakeMode
    }
    $report = Invoke-DellFanControllerProductionPreflight @invokeParams
    if ($Json) {
        $report | ConvertTo-Json -Depth 10
    } else {
        $report | Format-List *
    }
    exit ([int]$report.ProcessExitCode)
}
