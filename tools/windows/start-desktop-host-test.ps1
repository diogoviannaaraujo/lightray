param(
    [switch]$DesktopApproved,
    [string]$Run = 'desktop-001',
    [ValidatePattern('^swift-core-[0-9]{3}$')][string]$CoreProbe = 'swift-core-002',
    [Parameter(Mandatory=$true)][string]$BindIPv4,
    [Parameter(Mandatory=$true)][string]$PeerIPv4,
    [Parameter(Mandatory=$true)][string]$PairFile,
    [ValidateRange(10,540)][int]$Seconds = 480,
    [ValidateSet(1920,2560,3840)][int]$Width = 1920,
    [ValidateRange(30,120)][int]$FPS = 30,
    [ValidateRange(5,200)][int]$BitrateMbps = 20,
    [switch]$Motion,
    [ValidateSet('dxgi','wgc')][string]$CaptureBackend = 'dxgi',
    [ValidateSet(0,120,144,160)][int]$RefreshHz = 0
)
$ErrorActionPreference = 'Stop'
if (-not $DesktopApproved) { throw 'Coordinate desktop use before passing -DesktopApproved' }
if ($Run -notmatch '^desktop-[0-9]{3}$') { throw 'Invalid run name' }
foreach ($address in @($BindIPv4, $PeerIPv4)) {
    $parsed = [System.Net.IPAddress]::Parse($address)
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or $address -eq '0.0.0.0') { throw 'Explicit IPv4 addresses required' }
}
if (-not (Test-Path -LiteralPath $PairFile -PathType Leaf)) { throw 'Pairing file missing' }
$PairFile = (Resolve-Path -LiteralPath $PairFile).Path
$output = Join-Path $PSScriptRoot ('results\' + $Run)
if (Test-Path $output) { throw 'Output already exists' }
$build = Join-Path $PSScriptRoot 'results\desktop-build'
$hostExe = Join-Path $build 'windows_host.exe'
$testExe = Join-Path $build 'desktop_test_window.exe'
$swiftCandidates = @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs\Swift') -Filter swift.exe -Recurse | Where-Object { $_.FullName -match '\\Toolchains\\' })
if ($swiftCandidates.Count -ne 1) { throw 'Exactly one Swift toolchain required' }
$swift = $swiftCandidates[0].FullName
$package = Join-Path $PSScriptRoot ('results\' + $CoreProbe + '\macos')
$bin = & $swift build --package-path $package -c release --show-bin-path
if ($LASTEXITCODE -ne 0) { throw 'Core path query failed' }
$library = Join-Path $bin 'LightrayCoreProbe.dll'
foreach ($file in @($hostExe, $testExe, $library)) { if (-not (Test-Path $file)) { throw ('Missing binary: ' + $file) } }
New-Item -ItemType Directory $output | Out-Null
$worker = Join-Path $output 'worker.ps1'
function Quote([string]$value) { return "'" + $value.Replace("'", "''") + "'" }
$hostArguments = '"' + $library + '" ' + $BindIPv4 + ' ' + $PeerIPv4 + ' "' + $PairFile + '" ' + $Seconds + ' "' + (Join-Path $output 'host') + '"'
$hostArguments += ' ' + $Width + ' ' + $FPS + ' ' + $BitrateMbps
$hostArguments += ' ' + $CaptureBackend
$testArguments = '"' + (Join-Path $output 'test-window.json') + '"'
if ($Motion) { $testArguments += ' --motion' }
$source = @(
    '$ErrorActionPreference = ''Stop''',
    ('$env:PATH = ' + (Quote ((Split-Path $swift) + ';')) + ' + $env:PATH'),
    '$testProcess = $null; $hostProcess = $null; $restoreRequired = $false',
    'try {',
    ('  & ' + (Quote (Join-Path $build 'display_modes_probe.exe')) + ' > ' + (Quote (Join-Path $output 'display-modes.log'))),
    '  if ($LASTEXITCODE -ne 0) { throw ''Display mode inventory failed'' }',
    ('  if (' + $RefreshHz + ' -gt 0) { & ' + (Quote (Join-Path $build 'display_modes_probe.exe')) + ' --set-refresh ' + $RefreshHz + ' 60 > ' + (Quote (Join-Path $output 'refresh-change.log')) + '; if ($LASTEXITCODE -ne 0) { throw ''Refresh change failed'' }; $restoreRequired = $true }'),
    ('  $testProcess = Start-Process ' + (Quote $testExe) + ' -ArgumentList ' + (Quote $testArguments) + ' -PassThru -WindowStyle Hidden'),
    '  Start-Sleep -Seconds 2',
    ('  $hostProcess = Start-Process ' + (Quote $hostExe) + ' -ArgumentList ' + (Quote $hostArguments) + ' -PassThru -WindowStyle Hidden -RedirectStandardOutput ' + (Quote (Join-Path $output 'stdout.log')) + ' -RedirectStandardError ' + (Quote (Join-Path $output 'stderr.log'))),
    '  $processHandle = $hostProcess.Handle',
    ('  if (-not $hostProcess.WaitForExit(' + (($Seconds + 15) * 1000) + ')) { throw ''Host deadline exceeded'' }'),
    ('  $hostProcess.ExitCode | Set-Content ' + (Quote (Join-Path $output 'host.exit'))),
    '  if ($hostProcess.ExitCode -ne 0) { throw ''Host failed; inspect stderr.log'' }',
    '} catch {',
    ('  $_.Exception.Message | Set-Content ' + (Quote (Join-Path $output 'worker-error.log'))),
    '  exit 1',
    '} finally {',
    '  if ($hostProcess -and -not $hostProcess.HasExited) { $hostProcess.Kill(); $hostProcess.WaitForExit() }',
    '  if ($testProcess -and -not $testProcess.HasExited) { [void]$testProcess.CloseMainWindow(); if (-not $testProcess.WaitForExit(3000)) { $testProcess.Kill() } }',
    ('  if ($restoreRequired) { & ' + (Quote (Join-Path $build 'display_modes_probe.exe')) + ' --set-refresh 60 ' + $RefreshHz + ' > ' + (Quote (Join-Path $output 'refresh-restore.log')) + '; if ($LASTEXITCODE -ne 0) { throw ''Refresh restoration failed; check display mode'' } }'),
    '}'
)
$source | Set-Content -Encoding UTF8 $worker
$taskName = 'LightrayLab-' + [Guid]::NewGuid().ToString('N')
$action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument ('-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File "' + $worker + '"') -WorkingDirectory $output
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds ($Seconds + 30)) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Description 'Bounded Lightray desktop capture and input validation' | Out-Null
@{task=$taskName;run=$Run;seconds=$Seconds;width=$Width;fps=$FPS;bitrate_mbps=$BitrateMbps;capture_backend=$CaptureBackend;motion=[bool]$Motion;temporary_refresh_hz=$RefreshHz;bind=$BindIPv4;peer=$PeerIPv4;port=37373;core_sha256=(Get-FileHash $library -Algorithm SHA256).Hash.ToLower();executable_sha256=(Get-FileHash $hostExe -Algorithm SHA256).Hash.ToLower()} | ConvertTo-Json | Set-Content (Join-Path $output 'launch.json')
Start-ScheduledTask -TaskName $taskName
Write-Output ('Started bounded desktop test: ' + $Run)
Write-Output ('Stop gracefully by creating: ' + (Join-Path $output 'host\stop'))
Write-Output ('Unregister after completion: ' + $taskName)
