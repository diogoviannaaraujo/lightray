$ErrorActionPreference = 'Stop'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $installation) { throw 'MSVC x64 tools unavailable' }
$build = Join-Path $PSScriptRoot 'results\desktop-build'
New-Item -ItemType Directory -Force $build | Out-Null
$developer = Join-Path $installation 'Common7\Tools\VsDevCmd.bat'
Push-Location $build
try {
    foreach ($name in @('windows_host', 'desktop_test_window', 'windows_input_tests', 'capture_recovery_tests', 'windows_display_tests', 'capture_probe', 'wgc_capture_probe', 'display_modes_probe')) {
        $source = Join-Path $PSScriptRoot ('src\' + $name + '.cpp')
        $component = if ($name -eq 'windows_host') { ' "' + (Join-Path $PSScriptRoot 'src\nvenc_encoder.cpp') + '"' } else { '' }
        $command = 'call "' + $developer + '" -arch=x64 -host_arch=x64 >nul && cl /nologo /std:c++20 /EHsc /W4 /WX /O2 /utf-8 "' + $source + '"' + $component + ' /Fe:' + $name + '.exe /link d3d11.lib dxgi.lib ws2_32.lib bcrypt.lib user32.lib gdi32.lib dwmapi.lib wtsapi32.lib windowsapp.lib'
        & cmd.exe /d /c $command
        if ($LASTEXITCODE -ne 0) { throw ('Desktop host compilation failed: ' + $name) }
    }
    & '.\capture_recovery_tests.exe'
    if ($LASTEXITCODE -ne 0) { throw 'Capture recovery tests failed' }
    & '.\windows_input_tests.exe'
    if ($LASTEXITCODE -ne 0) { throw 'Windows input tests failed' }
    & '.\windows_display_tests.exe'
    if ($LASTEXITCODE -ne 0) { throw 'Display metadata tests failed' }
} finally { Pop-Location }
