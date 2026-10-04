param([string]$Run, [switch]$RemoveTestFirewall)
$ErrorActionPreference = 'Stop'
if ($Run -notmatch '^desktop-[0-9]{3}$') { throw 'Invalid run name' }
$output = Join-Path $PSScriptRoot ('results\' + $Run)
$launch = Get-Content (Join-Path $output 'launch.json') -Raw | ConvertFrom-Json
if ($launch.task -notmatch '^LightrayLab-[a-f0-9]{32}$') { throw 'Invalid task identity' }
$hostOutput = Join-Path $output 'host'
if (Test-Path $hostOutput) { New-Item -ItemType File (Join-Path $hostOutput 'stop') -Force | Out-Null }
$deadline = [DateTime]::UtcNow.AddSeconds(15)
$forced = $false
try {
    do {
        $task = Get-ScheduledTask -TaskName $launch.task -ErrorAction SilentlyContinue
        if (-not $task -or $task.State -notin @('Running', 'Queued')) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($task -and $task.State -in @('Running', 'Queued')) {
        $forced = $true
        Stop-ScheduledTask -TaskName $launch.task
    }
} finally {
    if (Get-ScheduledTask -TaskName $launch.task -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $launch.task -Confirm:$false }
    if ($RemoveTestFirewall -and (Get-NetFirewallRule -Name 'LightrayLab-DesktopTest-37373' -ErrorAction SilentlyContinue)) { Remove-NetFirewallRule -Name 'LightrayLab-DesktopTest-37373' }
}
if ($forced) { throw 'Forced task stop: graceful input release not verified' }
if (-not (Test-Path (Join-Path $hostOutput 'result.json'))) { throw 'Host result missing; inspect worker logs' }
$result = Get-Content (Join-Path $hostOutput 'result.json') -Raw | ConvertFrom-Json
if ($result.status -ne 'completed' -or $result.held_at_exit -ne 0 -or $result.input_failures -ne 0) { throw 'Host cleanup validation failed' }
Write-Output 'Host stopped gracefully and scheduled task removed.'
