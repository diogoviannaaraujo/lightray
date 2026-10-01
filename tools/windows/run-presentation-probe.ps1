param([switch]$DesktopApproved, [ValidateSet(1, 2)][int]$Latency = 1, [string]$Run = 'presentation-001')
$ErrorActionPreference = 'Stop'
if (-not $DesktopApproved) { throw 'Coordinate desktop use with the user before passing -DesktopApproved' }
if ($Run -notmatch '^presentation-[0-9]{3}$') { throw 'Invalid presentation run name' }
$output = Join-Path $PSScriptRoot ('results\' + $Run)
if (Test-Path $output) { throw 'Presentation output already exists' }
$executable = Join-Path $PSScriptRoot 'results\platform-build\present_probe.exe'
if (-not (Test-Path $executable)) { throw 'Compile the presentation probe first' }
New-Item -ItemType Directory $output | Out-Null
$taskName = 'LightrayLab-' + [Guid]::NewGuid().ToString('N')
$resultFile = Join-Path $output 'result.json'
$worker = Join-Path $output 'desktop-worker.ps1'
$diagnostic = Join-Path $output 'process.log'
# The hidden PowerShell console hosts the console-subsystem probe; only its explicit Win32 window is shown.
$workerSource = "& '" + $executable.Replace("'", "''") + "' --present " + $Latency + " 1920 1080 600 '" + $resultFile.Replace("'", "''") + "' *> '" + $diagnostic.Replace("'", "''") + "'`nexit `$LASTEXITCODE`n"
$workerSource | Set-Content -Encoding UTF8 $worker
$arguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File "' + $worker + '"'
$action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument $arguments -WorkingDirectory $output
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds 30) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$registered = $false
try {
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Description 'Temporary bounded Lightray presentation experiment' | Out-Null
    $registered = $true
    Start-ScheduledTask -TaskName $taskName
    $deadline = [DateTime]::UtcNow.AddSeconds(40)
    $completed = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $task = Get-ScheduledTask -TaskName $taskName
        $info = Get-ScheduledTaskInfo -TaskName $taskName
        if ($info.LastRunTime.Year -gt 2000 -and $task.State -ne 'Running' -and $task.State -ne 'Queued') {
            if ($info.LastTaskResult -ne 0) { throw ('Presentation process failed: ' + $info.LastTaskResult) }
            $completed = $true
            break
        }
    }
    if (-not $completed) { throw 'Interactive presentation task did not complete within 40 seconds' }
    if (-not (Test-Path $resultFile)) { throw 'Interactive presentation produced no result' }
    $result = Get-Content $resultFile -Raw | ConvertFrom-Json
    if ($result.status -ne 'passed' -or $result.frames_submitted -ne 600 -or $result.maximum_frame_latency -ne $Latency) { throw 'Presentation result failed validation' }
    Get-Content $resultFile
} finally {
    if ($registered) {
        try {
            $state = (Get-ScheduledTask -TaskName $taskName).State
            if ($state -eq 'Running' -or $state -eq 'Queued') { Stop-ScheduledTask -TaskName $taskName }
        } finally { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }
    }
}
