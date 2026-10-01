$ErrorActionPreference = 'Stop'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $installation) { throw 'MSVC x64 tools unavailable' }
$build = Join-Path $PSScriptRoot 'results\nvenc-build'
New-Item -ItemType Directory -Force -Path $build | Out-Null
$developer = Join-Path $installation 'Common7\Tools\VsDevCmd.bat'
Push-Location $build
try {
    foreach ($name in @('hevc_annexb_tests', 'nvenc_encode_probe', 'nvenc_lifecycle_probe')) {
        $source = Join-Path $PSScriptRoot ('src\' + $name + '.cpp')
        $component = if ($name -eq 'hevc_annexb_tests') { '' } else { ' "' + (Join-Path $PSScriptRoot 'src\nvenc_encoder.cpp') + '"' }
        $command = 'call "' + $developer + '" -arch=x64 -host_arch=x64 >nul && cl /nologo /std:c++20 /EHsc /W4 /WX /O2 /utf-8 "' + $source + '"' + $component + ' /Fe:' + $name + '.exe /link d3d11.lib dxgi.lib psapi.lib'
        & cmd.exe /d /c $command
        if ($LASTEXITCODE -ne 0) { throw ('NVENC probe compilation failed: ' + $name) }
    }
    & '.\hevc_annexb_tests.exe'
    if ($LASTEXITCODE -ne 0) { throw 'HEVC framing tests failed' }
} finally { Pop-Location }
