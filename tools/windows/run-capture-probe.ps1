param([switch]$DesktopApproved, [ValidatePattern('^capture-[0-9]{3}$')][string]$Run = 'capture-001', [switch]$Motion, [ValidateSet('dxgi','wgc')][string]$Backend = 'dxgi')
$ErrorActionPreference = 'Stop'
if (-not $DesktopApproved) { throw 'Coordinate desktop capture before passing -DesktopApproved' }
$output = Join-Path $PSScriptRoot ('results\' + $Run)
if (Test-Path $output) { throw 'Output already exists' }
$exeName = if ($Backend -eq 'wgc') { 'wgc_capture_probe.exe' } else { 'capture_probe.exe' }
$exe = Join-Path $PSScriptRoot ('results\desktop-build\' + $exeName)
if (-not (Test-Path $exe)) { throw 'Build capture_probe first' }
$testExe = Join-Path $PSScriptRoot 'results\desktop-build\desktop_test_window.exe'
if ($Motion -and -not (Test-Path $testExe)) { throw 'Build desktop_test_window first' }
New-Item -ItemType Directory $output | Out-Null
function Quote([string]$value) { return "'" + $value.Replace("'", "''") + "'" }
$worker = Join-Path $output 'worker.ps1'
@(
    '$ErrorActionPreference = ''Stop''',
    '$process = $null; $testProcess = $null',
    'try {',
    ('  if (' + ([int][bool]$Motion) + ') { $testProcess = Start-Process ' + (Quote $testExe) + ' -ArgumentList ' + (Quote ('"' + (Join-Path $output 'test-window.json') + '" --motion')) + ' -PassThru -WindowStyle Hidden; Start-Sleep -Milliseconds 500 }'),
    ('  $process = Start-Process ' + (Quote $exe) + ' -PassThru -WindowStyle Hidden -RedirectStandardOutput ' + (Quote (Join-Path $output 'probe.log')) + ' -RedirectStandardError ' + (Quote (Join-Path $output 'stderr.log'))),
    '  $processHandle = $process.Handle',
    '  if (-not $process.WaitForExit(20000)) { throw ''Capture probe deadline exceeded'' }',
    ('  $process.ExitCode | Set-Content ' + (Quote (Join-Path $output 'probe.exit'))),
    '} finally {',
    '  if ($process -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() }',
    '  if ($testProcess -and -not $testProcess.HasExited) { [void]$testProcess.CloseMainWindow(); if (-not $testProcess.WaitForExit(3000)) { $testProcess.Kill(); $testProcess.WaitForExit() } }',
    '}'
) | Set-Content -Encoding UTF8 $worker
$taskName = 'LightrayCapture-' + [Guid]::NewGuid().ToString('N')
$action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument ('-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File "' + $worker + '"') -WorkingDirectory $output
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds 30) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Description 'Five-second raw DXGI capture diagnostic without saving pixels or injecting input' | Out-Null
try {
    Start-ScheduledTask -TaskName $taskName
    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    do {
        if (Test-Path (Join-Path $output 'probe.exit')) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not (Test-Path (Join-Path $output 'probe.exit'))) { throw 'Capture probe did not finish' }
    Get-Content (Join-Path $output 'probe.log')
    $probeExit = [int](Get-Content (Join-Path $output 'probe.exit'))
    [pscustomobject]@{ run=$Run; backend=$Backend; exit_code=$probeExit; motion=[bool]$Motion; captured_pixels_saved=$false; input_injected=$false; executable_sha256=(Get-FileHash $exe -Algorithm SHA256).Hash.ToLower() } | ConvertTo-Json | Set-Content (Join-Path $output 'result.json')
} finally {
    if ((Get-ScheduledTask -TaskName $taskName).State -in @('Running','Queued')) { Stop-ScheduledTask -TaskName $taskName }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}
