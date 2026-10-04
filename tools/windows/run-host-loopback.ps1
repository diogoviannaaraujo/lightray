param([string]$CoreProbe = 'swift-core-002', [string]$Run = 'host-loopback-001')
$ErrorActionPreference = 'Stop'
if ($CoreProbe -notmatch '^swift-core-[0-9]{3}$' -or $Run -notmatch '^host-loopback-[0-9]{3}$') { throw 'Invalid run name' }
$root = Join-Path $PSScriptRoot ('results\' + $Run)
if (Test-Path $root) { throw 'Output already exists' }
$swiftCandidates = @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs\Swift') -Filter swift.exe -Recurse | Where-Object { $_.FullName -match '\\Toolchains\\' })
if ($swiftCandidates.Count -ne 1) { throw 'Select exactly one Swift toolchain' }
$swift = $swiftCandidates[0].FullName
$env:PATH = (Split-Path $swift) + ';' + $env:PATH
$package = Join-Path $PSScriptRoot ('results\' + $CoreProbe + '\macos')
$bin = & $swift build --package-path $package -c release --show-bin-path
if ($LASTEXITCODE -ne 0) { throw 'Core binary path query failed' }
$library = Join-Path $bin 'LightrayCoreProbe.dll'
if (-not (Test-Path $library)) { throw 'Build and validate the host bridge DLL first' }
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $installation) { throw 'MSVC unavailable' }
$developer = Join-Path $installation 'Common7\Tools\VsDevCmd.bat'
New-Item -ItemType Directory -Path $root | Out-Null
Push-Location $root
try {
    foreach ($name in @('udp_loopback_tests', 'host_abi_probe')) {
        $source = Join-Path $PSScriptRoot ('src\' + $name + '.cpp')
        $component = if ($name -eq 'host_abi_probe') { ' "' + (Join-Path $PSScriptRoot 'src\nvenc_encoder.cpp') + '"' } else { '' }
        $command = 'call "' + $developer + '" -arch=x64 -host_arch=x64 >nul && cl /nologo /std:c++20 /EHsc /W4 /WX /O2 /utf-8 "' + $source + '"' + $component + ' /Fe:' + $name + '.exe /link d3d11.lib dxgi.lib ws2_32.lib'
        & cmd.exe /d /c $command
        if ($LASTEXITCODE -ne 0) { throw ('Compilation failed: ' + $name) }
    }
    & '.\udp_loopback_tests.exe' > socket-tests.json
    if ($LASTEXITCODE -ne 0) { throw 'Socket tests failed' }
    $corpus = Join-Path $PSScriptRoot 'results\native-nvenc-004'
    foreach ($mode in @('memory', 'live')) {
        $arguments = '"' + $library + '" "' + $corpus + '"'
        if ($mode -eq 'live') { $arguments += ' --live-loopback' }
        $process = Start-Process '.\host_abi_probe.exe' -ArgumentList $arguments -NoNewWindow -PassThru -RedirectStandardOutput ($mode + '.json') -RedirectStandardError ($mode + '.log')
        $processHandle = $process.Handle
        if (-not $process.WaitForExit(60000)) { $process.Kill(); $process.WaitForExit(); throw ('Timed out: ' + $mode) }
        if ($process.ExitCode -ne 0 -or (Get-Item ($mode + '.log')).Length -ne 0) { Get-Content ($mode + '.log'); throw ('Probe failed: ' + $mode) }
        $result = Get-Content ($mode + '.json') -Raw | ConvertFrom-Json
        if ($result.status -ne 'passed' -or $result.nvenc_frames_delivered -ne 360) { throw 'Incomplete frame delivery' }
        if ($mode -eq 'live' -and (-not $result.live_nvenc -or -not $result.udp_sockets -or $result.datagrams_sent -le 0 -or $result.datagrams_sent -ne $result.datagrams_received)) { throw 'Incomplete live UDP delivery' }
        Get-Content ($mode + '.json')
    }
    $inputs = @{}
    foreach ($name in @('src\host_abi_probe.cpp','src\udp_loopback.hpp','src\udp_loopback_tests.cpp','src\nvenc_encoder.hpp','src\nvenc_encoder.cpp','src\hevc_annexb.hpp','vendor\nv-codec-headers\nvEncodeAPI.h','run-host-loopback.ps1')) { $inputs[$name] = (Get-FileHash (Join-Path $PSScriptRoot $name) -Algorithm SHA256).Hash.ToLower() }
    @{status='passed';core_probe=$CoreProbe;core_dll_sha256=(Get-FileHash $library -Algorithm SHA256).Hash.ToLower();executable_sha256=(Get-FileHash '.\host_abi_probe.exe' -Algorithm SHA256).Hash.ToLower();inputs=$inputs;listener='127.0.0.1:7373 during probe only';clock='simulated';desktop_captured=$false} | ConvertTo-Json -Depth 5 | Set-Content provenance.json -Encoding UTF8
} finally { Pop-Location }
