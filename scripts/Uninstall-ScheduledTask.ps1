param(
    [string]$TaskName = 'Dell Fan Controller'
)

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -eq $task) {
    Write-Host "Scheduled Task not found: $TaskName"
    return
}

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$true
