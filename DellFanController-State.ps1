[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-UtcTimestamp {
    ([DateTime]::UtcNow).ToString('o')
}

function Test-GuidString {
    param([object]$Value)
    if ($null -eq $Value) { return $false }
    $parsed = [guid]::Empty
    [guid]::TryParse([string]$Value, [ref]$parsed)
}

function Test-UtcTimestamp {
    param(
        [object]$Value,
        [bool]$AllowNull
    )
    if ($null -eq $Value) { return $AllowNull }
    if ($Value -isnot [string]) { return $false }
    if (-not ([string]$Value).EndsWith('Z')) { return $false }
    $parsed = [datetime]::MinValue
    [datetime]::TryParse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed
    ) -and $parsed.Kind -eq [DateTimeKind]::Utc
}

function Get-DefaultControllerStateBackupPath {
    param([string]$Path)
    "$Path.bak"
}

function Copy-ControllerStateObject {
    param([object]$State)
    if ($null -eq $State) { return $null }
    $State | ConvertTo-Json -Depth 6 | ConvertFrom-Json
}

function Convert-ControllerStateToJson {
    param([object]$State)
    $ordered = [ordered]@{
        SchemaVersion = [int]$State.SchemaVersion
        ControllerInstanceId = [string]$State.ControllerInstanceId
        CorrelationId = [string]$State.CorrelationId
        BackendName = [string]$State.BackendName
        OperationPhase = [string]$State.OperationPhase
        FanOverrideActivatedByThisApp = [bool]$State.FanOverrideActivatedByThisApp
        PreviousFanState = [string]$State.PreviousFanState
        CurrentRequestedState = [string]$State.CurrentRequestedState
        ActivatedAtUtc = $State.ActivatedAtUtc
        LastSuccessfulVerificationUtc = $State.LastSuccessfulVerificationUtc
        RequiresEmergencyReset = [bool]$State.RequiresEmergencyReset
        LastError = $State.LastError
        UpdatedAtUtc = [string]$State.UpdatedAtUtc
    }
    ([pscustomobject]$ordered) | ConvertTo-Json -Depth 6
}

function New-ControllerState {
    param(
        [string]$ControllerInstanceId,
        [string]$CorrelationId,
        [string]$BackendName
    )

    if ([string]::IsNullOrWhiteSpace($ControllerInstanceId)) { $ControllerInstanceId = ([guid]::NewGuid()).ToString() }
    if ([string]::IsNullOrWhiteSpace($CorrelationId)) { $CorrelationId = ([guid]::NewGuid()).ToString() }
    if ([string]::IsNullOrWhiteSpace($BackendName)) { $BackendName = 'MockFanBackend' }

    [pscustomobject]@{
        SchemaVersion = 1
        ControllerInstanceId = $ControllerInstanceId
        CorrelationId = $CorrelationId
        BackendName = $BackendName
        OperationPhase = 'Idle'
        FanOverrideActivatedByThisApp = $false
        PreviousFanState = 'Automatic'
        CurrentRequestedState = 'Automatic'
        ActivatedAtUtc = $null
        LastSuccessfulVerificationUtc = $null
        RequiresEmergencyReset = $false
        LastError = $null
        UpdatedAtUtc = New-UtcTimestamp
    }
}

function Test-ControllerState {
    param([object]$State)

    $errors = @()
    $required = @(
        'SchemaVersion',
        'ControllerInstanceId',
        'CorrelationId',
        'BackendName',
        'OperationPhase',
        'FanOverrideActivatedByThisApp',
        'PreviousFanState',
        'CurrentRequestedState',
        'ActivatedAtUtc',
        'LastSuccessfulVerificationUtc',
        'RequiresEmergencyReset',
        'LastError',
        'UpdatedAtUtc'
    )
    $allowedPhases = @('Idle', 'EnablePending', 'ActiveVerified', 'DisablePending', 'CleanupRequired', 'Restored')
    $allowedFanStates = @('Automatic', 'BoostEnabled', 'Unknown')

    if ($null -eq $State) {
        return [pscustomobject]@{ IsValid = $false; Errors = @('State ontbreekt.'); SchemaVersion = $null; OperationPhase = $null }
    }

    $names = @($State.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($name in $required) {
        if ($names -notcontains $name) { $errors += "Verplichte property ontbreekt: $name." }
    }
    foreach ($name in $names) {
        if ($required -notcontains $name) { $errors += "Onbekende property is niet toegestaan: $name." }
    }

    if ($errors.Count -eq 0) {
        if ($State.SchemaVersion -ne 1) { $errors += 'SchemaVersion moet exact 1 zijn.' }
        if (-not (Test-GuidString -Value $State.ControllerInstanceId)) { $errors += 'ControllerInstanceId moet een geldige GUID zijn.' }
        if (-not (Test-GuidString -Value $State.CorrelationId)) { $errors += 'CorrelationId moet een geldige GUID zijn.' }
        if ([string]::IsNullOrWhiteSpace([string]$State.BackendName)) { $errors += 'BackendName mag niet leeg zijn.' }
        if ($allowedPhases -notcontains [string]$State.OperationPhase) { $errors += "OperationPhase is ongeldig: $($State.OperationPhase)." }
        if ($State.FanOverrideActivatedByThisApp -isnot [bool]) { $errors += 'FanOverrideActivatedByThisApp moet boolean zijn.' }
        if ($allowedFanStates -notcontains [string]$State.PreviousFanState) { $errors += "PreviousFanState is ongeldig: $($State.PreviousFanState)." }
        if ($allowedFanStates -notcontains [string]$State.CurrentRequestedState) { $errors += "CurrentRequestedState is ongeldig: $($State.CurrentRequestedState)." }
        if ($State.RequiresEmergencyReset -isnot [bool]) { $errors += 'RequiresEmergencyReset moet boolean zijn.' }
        if (-not (Test-UtcTimestamp -Value $State.ActivatedAtUtc -AllowNull $true)) { $errors += 'ActivatedAtUtc moet null of een UTC ISO-8601 timestamp zijn.' }
        if (-not (Test-UtcTimestamp -Value $State.LastSuccessfulVerificationUtc -AllowNull $true)) { $errors += 'LastSuccessfulVerificationUtc moet null of een UTC ISO-8601 timestamp zijn.' }
        if (-not (Test-UtcTimestamp -Value $State.UpdatedAtUtc -AllowNull $false)) { $errors += 'UpdatedAtUtc moet een UTC ISO-8601 timestamp zijn.' }
    }

    if ($errors.Count -eq 0) {
        switch ([string]$State.OperationPhase) {
            'Idle' {
                if ($State.FanOverrideActivatedByThisApp -ne $false) { $errors += 'Idle vereist FanOverrideActivatedByThisApp=false.' }
                if ($State.RequiresEmergencyReset -ne $false) { $errors += 'Idle vereist RequiresEmergencyReset=false.' }
                if ([string]$State.CurrentRequestedState -ne 'Automatic') { $errors += 'Idle vereist CurrentRequestedState=Automatic.' }
            }
            'EnablePending' {
                if ($State.FanOverrideActivatedByThisApp -ne $false) { $errors += 'EnablePending vereist FanOverrideActivatedByThisApp=false.' }
                if ([string]$State.CurrentRequestedState -ne 'BoostEnabled') { $errors += 'EnablePending vereist CurrentRequestedState=BoostEnabled.' }
            }
            'ActiveVerified' {
                if ($State.FanOverrideActivatedByThisApp -ne $true) { $errors += 'ActiveVerified vereist FanOverrideActivatedByThisApp=true.' }
                if ([string]$State.CurrentRequestedState -ne 'BoostEnabled') { $errors += 'ActiveVerified vereist CurrentRequestedState=BoostEnabled.' }
                if ($null -eq $State.ActivatedAtUtc) { $errors += 'ActiveVerified vereist ActivatedAtUtc.' }
                if ($null -eq $State.LastSuccessfulVerificationUtc) { $errors += 'ActiveVerified vereist LastSuccessfulVerificationUtc.' }
            }
            'DisablePending' {
                if ($State.FanOverrideActivatedByThisApp -ne $true) { $errors += 'DisablePending vereist FanOverrideActivatedByThisApp=true.' }
                if ([string]$State.CurrentRequestedState -ne 'Automatic') { $errors += 'DisablePending vereist CurrentRequestedState=Automatic.' }
            }
            'CleanupRequired' {
                if ($State.RequiresEmergencyReset -ne $true) { $errors += 'CleanupRequired vereist RequiresEmergencyReset=true.' }
                if ([string]::IsNullOrWhiteSpace([string]$State.LastError)) { $errors += 'CleanupRequired vereist LastError.' }
            }
            'Restored' {
                if ($State.FanOverrideActivatedByThisApp -ne $false) { $errors += 'Restored vereist FanOverrideActivatedByThisApp=false.' }
                if ([string]$State.CurrentRequestedState -ne 'Automatic') { $errors += 'Restored vereist CurrentRequestedState=Automatic.' }
                if ($State.RequiresEmergencyReset -ne $false) { $errors += 'Restored vereist RequiresEmergencyReset=false.' }
                if ($null -eq $State.LastSuccessfulVerificationUtc) { $errors += 'Restored vereist LastSuccessfulVerificationUtc.' }
            }
        }
    }

    [pscustomobject]@{
        IsValid = ($errors.Count -eq 0)
        Errors = @($errors)
        SchemaVersion = if ($names -contains 'SchemaVersion') { $State.SchemaVersion } else { $null }
        OperationPhase = if ($names -contains 'OperationPhase') { $State.OperationPhase } else { $null }
    }
}

function Read-StateFile {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return [pscustomobject]@{ Found = $false; IsValid = $false; State = $null; Errors = @('Bestand ontbreekt.') }
        }
        $parsed = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $validation = Test-ControllerState -State $parsed
        [pscustomobject]@{ Found = $true; IsValid = [bool]$validation.IsValid; State = $parsed; Errors = @($validation.Errors) }
    }
    catch {
        [pscustomobject]@{ Found = $true; IsValid = $false; State = $null; Errors = @($_.Exception.Message) }
    }
}

function Read-ControllerState {
    param(
        [string]$Path,
        [string]$BackupPath
    )

    if ([string]::IsNullOrWhiteSpace($BackupPath)) { $BackupPath = Get-DefaultControllerStateBackupPath -Path $Path }
    $active = Read-StateFile -Path $Path
    if ($active.Found -and $active.IsValid) {
        return [pscustomobject]@{ Success = $true; Found = $true; State = $active.State; Source = 'Active'; RecoveredFromBackup = $false; Errors = @() }
    }

    $backup = Read-StateFile -Path $BackupPath
    if ($backup.Found -and $backup.IsValid) {
        return [pscustomobject]@{ Success = $true; Found = $true; State = $backup.State; Source = 'Backup'; RecoveredFromBackup = $true; Errors = @($active.Errors) }
    }

    if (-not $active.Found -and -not $backup.Found) {
        return [pscustomobject]@{ Success = $false; Found = $false; State = $null; Source = 'None'; RecoveredFromBackup = $false; Errors = @('Geen actief statebestand of backup gevonden.') }
    }

    [pscustomobject]@{ Success = $false; Found = $true; State = $null; Source = 'None'; RecoveredFromBackup = $false; Errors = @($active.Errors + $backup.Errors) }
}

function Write-ControllerStateAtomic {
    param(
        [string]$Path,
        [object]$State,
        [string]$BackupPath
    )

    if ([string]::IsNullOrWhiteSpace($BackupPath)) { $BackupPath = Get-DefaultControllerStateBackupPath -Path $Path }
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw "Directory bestaat niet: $directory" }

    $validation = Test-ControllerState -State $State
    if (-not $validation.IsValid) {
        return [pscustomobject]@{ Success = $false; Path = $Path; BackupCreated = $false; Verified = $false; Error = "State ongeldig: $(@($validation.Errors) -join '; ')" }
    }

    $activeExists = Test-Path -LiteralPath $Path -PathType Leaf
    $backupCreated = $false
    $tempPath = Join-Path $directory ("{0}.{1}.tmp" -f ([IO.Path]::GetFileName($Path)), ([guid]::NewGuid().ToString('N')))

    try {
        if ($activeExists) {
            $active = Read-StateFile -Path $Path
            if (-not $active.IsValid) {
                return [pscustomobject]@{ Success = $false; Path = $Path; BackupCreated = $false; Verified = $false; Error = "Actief statebestand is corrupt of ongeldig; overschrijven geweigerd." }
            }
        }

        $json = Convert-ControllerStateToJson -State $State
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $stream = [System.IO.File]::Open($tempPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $writer = New-Object System.IO.StreamWriter($stream, $utf8)
            try {
                $writer.Write($json)
                $writer.Flush()
                $stream.Flush($true)
            }
            finally {
                $writer.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }

        $tempRead = Read-StateFile -Path $tempPath
        if (-not $tempRead.IsValid) {
            return [pscustomobject]@{ Success = $false; Path = $Path; BackupCreated = $false; Verified = $false; Error = "Tijdelijk statebestand valideert niet: $(@($tempRead.Errors) -join '; ')" }
        }

        if ($activeExists) {
            [System.IO.File]::Replace($tempPath, $Path, $BackupPath, $true)
            $backupCreated = $true
        } else {
            [System.IO.File]::Move($tempPath, $Path)
        }

        $verified = Read-StateFile -Path $Path
        if (-not $verified.IsValid) {
            return [pscustomobject]@{ Success = $false; Path = $Path; BackupCreated = $backupCreated; Verified = $false; Error = "Geschreven statebestand kon niet worden geverifieerd." }
        }

        [pscustomobject]@{ Success = $true; Path = $Path; BackupCreated = $backupCreated; Verified = $true; Error = $null }
    }
    catch {
        [pscustomobject]@{ Success = $false; Path = $Path; BackupCreated = $backupCreated; Verified = $false; Error = $_.Exception.Message }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}

function Set-ControllerStatePhase {
    param(
        [object]$State,
        [string]$OperationPhase,
        [string]$LastError,
        [string]$VerificationTimeUtc
    )

    $copy = Copy-ControllerStateObject -State $State
    $now = New-UtcTimestamp
    $copy.OperationPhase = $OperationPhase
    $copy.UpdatedAtUtc = $now

    switch ($OperationPhase) {
        'Idle' {
            $copy.FanOverrideActivatedByThisApp = $false
            $copy.CurrentRequestedState = 'Automatic'
            $copy.RequiresEmergencyReset = $false
            $copy.LastError = $null
        }
        'EnablePending' {
            $copy.FanOverrideActivatedByThisApp = $false
            $copy.CurrentRequestedState = 'BoostEnabled'
        }
        'ActiveVerified' {
            $copy.FanOverrideActivatedByThisApp = $true
            $copy.CurrentRequestedState = 'BoostEnabled'
            if ($null -eq $copy.ActivatedAtUtc) { $copy.ActivatedAtUtc = $now }
            $copy.LastSuccessfulVerificationUtc = if ([string]::IsNullOrWhiteSpace($VerificationTimeUtc)) { $now } else { $VerificationTimeUtc }
            $copy.RequiresEmergencyReset = $false
        }
        'DisablePending' {
            $copy.FanOverrideActivatedByThisApp = $true
            $copy.CurrentRequestedState = 'Automatic'
        }
        'CleanupRequired' {
            $copy.RequiresEmergencyReset = $true
            $copy.LastError = $LastError
        }
        'Restored' {
            $copy.FanOverrideActivatedByThisApp = $false
            $copy.CurrentRequestedState = 'Automatic'
            $copy.RequiresEmergencyReset = $false
            $copy.LastSuccessfulVerificationUtc = if ([string]::IsNullOrWhiteSpace($VerificationTimeUtc)) { $now } else { $VerificationTimeUtc }
            $copy.LastError = $null
        }
    }

    $validation = Test-ControllerState -State $copy
    if (-not $validation.IsValid) {
        throw "Nieuwe fase is ongeldig: $(@($validation.Errors) -join '; ')"
    }
    $copy
}

function Mark-ControllerEmergencyReset {
    param(
        [object]$State,
        [string]$ErrorMessage
    )

    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { throw 'ErrorMessage is verplicht.' }
    Set-ControllerStatePhase -State $State -OperationPhase 'CleanupRequired' -LastError $ErrorMessage
}

function Clear-ControllerState {
    param(
        [string]$Path,
        [string]$BackupPath
    )

    if ([string]::IsNullOrWhiteSpace($BackupPath)) { $BackupPath = Get-DefaultControllerStateBackupPath -Path $Path }
    $read = Read-ControllerState -Path $Path -BackupPath $BackupPath
    if (-not $read.Success) {
        return [pscustomobject]@{ Success = $false; Cleared = $false; Path = $Path; BackupPath = $BackupPath; Error = "State kan niet veilig worden gelezen." }
    }

    $state = $read.State
    $canClear = (
        [string]$state.OperationPhase -eq 'Restored' -and
        $state.FanOverrideActivatedByThisApp -eq $false -and
        [string]$state.CurrentRequestedState -eq 'Automatic' -and
        $state.RequiresEmergencyReset -eq $false -and
        (Test-UtcTimestamp -Value $state.LastSuccessfulVerificationUtc -AllowNull $false)
    )
    if (-not $canClear) {
        return [pscustomobject]@{ Success = $false; Cleared = $false; Path = $Path; BackupPath = $BackupPath; Error = 'State mag alleen worden verwijderd wanneer Restored veilig is geverifieerd.' }
    }

    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { Remove-Item -LiteralPath $Path -Force }
        [pscustomobject]@{ Success = $true; Cleared = $true; Path = $Path; BackupPath = $BackupPath; Error = $null }
    }
    catch {
        [pscustomobject]@{ Success = $false; Cleared = $false; Path = $Path; BackupPath = $BackupPath; Error = $_.Exception.Message }
    }
}

function Get-ControllerRecoveryDecision {
    param([object]$State)

    $validation = Test-ControllerState -State $State
    if (-not $validation.IsValid) {
        return [pscustomobject]@{ Action = 'BlockNewEnable'; AllowNewEnable = $false; CleanupRequired = $false; OwnershipProven = $false; Reason = "State ongeldig: $(@($validation.Errors) -join '; ')" }
    }

    switch ([string]$State.OperationPhase) {
        'Idle' {
            [pscustomobject]@{ Action = 'NoAction'; AllowNewEnable = $true; CleanupRequired = $false; OwnershipProven = $false; Reason = 'Idle state.' }
        }
        'Restored' {
            [pscustomobject]@{ Action = 'NoAction'; AllowNewEnable = $true; CleanupRequired = $false; OwnershipProven = $false; Reason = 'Restored state.' }
        }
        'EnablePending' {
            [pscustomobject]@{ Action = 'VerifyBackendState'; AllowNewEnable = $false; CleanupRequired = $false; OwnershipProven = $false; Reason = 'Enable was pending; backend state must be verified.' }
        }
        'ActiveVerified' {
            [pscustomobject]@{ Action = 'RestoreAutomatic'; AllowNewEnable = $false; CleanupRequired = $true; OwnershipProven = $true; Reason = 'This application verified active fan override.' }
        }
        'DisablePending' {
            [pscustomobject]@{ Action = 'RestoreAutomatic'; AllowNewEnable = $false; CleanupRequired = $true; OwnershipProven = $true; Reason = 'Disable is pending and must be completed.' }
        }
        'CleanupRequired' {
            [pscustomobject]@{ Action = 'EmergencyResetRequired'; AllowNewEnable = $false; CleanupRequired = $true; OwnershipProven = [bool]$State.FanOverrideActivatedByThisApp; Reason = 'Emergency reset is required.' }
        }
        default {
            [pscustomobject]@{ Action = 'BlockNewEnable'; AllowNewEnable = $false; CleanupRequired = $false; OwnershipProven = $false; Reason = 'Unknown state.' }
        }
    }
}
