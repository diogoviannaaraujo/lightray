param([switch]$Decoder, [switch]$Presentation)
$ErrorActionPreference = 'Stop'
if ($Decoder -and $Presentation) { throw 'Select only one probe' }
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $installation) { throw 'MSVC x64 tools unavailable' }
$name = if ($Decoder) { 'mf_decode_probe' } elseif ($Presentation) { 'present_probe' } else { 'platform_probe' }
$source = Join-Path $PSScriptRoot ('src\' + $name + '.cpp')
$build = Join-Path $PSScriptRoot 'results\platform-build'
New-Item -ItemType Directory -Force -Path $build | Out-Null
$developer = Join-Path $installation 'Common7\Tools\VsDevCmd.bat'
$command = 'call "' + $developer + '" -arch=x64 -host_arch=x64 >nul && cl /nologo /std:c++20 /EHsc /W4 /WX /O2 /utf-8 "' + $source + '" /Fe:' + $name + '.exe /link d3d11.lib dxgi.lib dxguid.lib mfplat.lib mfreadwrite.lib mfuuid.lib ole32.lib bcrypt.lib user32.lib'
Push-Location $build
try {
    & cmd.exe /d /c $command
    if ($LASTEXITCODE -ne 0) { throw 'Platform probe compilation failed' }
    if ($Decoder) { return }
    if ($Presentation) {
        & '.\present_probe.exe' --self-test
        if ($LASTEXITCODE -ne 0) { throw 'Presentation probe self-test failed' }
        return
    }
    & '.\platform_probe.exe' | Set-Content -Encoding UTF8 platform.json
    if ($LASTEXITCODE -ne 0) { throw 'Platform probe execution failed' }
    Get-Content platform.json
} finally { Pop-Location }
