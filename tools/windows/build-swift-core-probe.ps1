param([string]$Probe = 'swift-core-001')
$ErrorActionPreference = 'Stop'
if ($Probe -notmatch '^swift-core-[0-9]{3}$') { throw 'Invalid probe directory name' }
$root = Join-Path $PSScriptRoot ('results\' + $Probe)
$manifest = Get-Content (Join-Path $root 'source-manifest.json') -Raw | ConvertFrom-Json
$minimumTests = if ($manifest.host_bridge) { 88 } else { 80 }
if (-not (Test-Path (Join-Path $root 'macos\Package.resolved'))) { throw 'Prepare the isolated probe and resolve its pinned dependencies first' }
$toolchainRoot = Join-Path $env:LOCALAPPDATA 'Programs\Swift'
$swiftCandidates = @(Get-ChildItem $toolchainRoot -Filter swift.exe -Recurse | Where-Object { $_.FullName -match '\\Toolchains\\' })
if ($swiftCandidates.Count -ne 1) { throw 'Expected exactly one installed Swift toolchain; select it explicitly when testing multiple versions' }
$swift = $swiftCandidates[0].FullName
$env:PATH = (Split-Path $swift) + ';' + $env:PATH
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $installation) { throw 'MSVC x64 tools unavailable' }
$developer = Join-Path $installation 'Common7\Tools\VsDevCmd.bat'
$package = Join-Path $root 'macos'
# Keep the SSH process alive until this command finishes; detached children can be killed by sshd.
$testLog = Join-Path $root 'debug-tests.log'
$testCommand = 'call "' + $developer + '" -arch=x64 -host_arch=x64 >nul && "' + $swift + '" test --package-path "' + $package + '" --force-resolved-versions --jobs 8 > "' + $testLog + '" 2>&1'
& cmd.exe /d /c $testCommand
$testExit = $LASTEXITCODE
$validation = Join-Path $root ('debug-validation-' + [Guid]::NewGuid().ToString('N'))
python (Join-Path $PSScriptRoot 'lab.py') verify-swift-tests --test-log $testLog --test-exit-code $testExit --minimum-tests $minimumTests --output $validation
if ($LASTEXITCODE -ne 0) { throw 'Swift Debug tests failed or discovery count is insufficient' }
# Swift 6.4 swiftbuild discovers zero Release tests here; the deprecated native engine discovers the suite.
$releaseLog = Join-Path $root 'release-tests.log'
$releaseCommand = 'call "' + $developer + '" -arch=x64 -host_arch=x64 >nul && "' + $swift + '" test --package-path "' + $package + '" -c release --build-system native --force-resolved-versions --jobs 8 > "' + $releaseLog + '" 2>&1'
& cmd.exe /d /c $releaseCommand
$releaseExit = $LASTEXITCODE
$releaseValidation = Join-Path $root ('release-validation-' + [Guid]::NewGuid().ToString('N'))
python (Join-Path $PSScriptRoot 'lab.py') verify-swift-tests --test-log $releaseLog --test-exit-code $releaseExit --minimum-tests $minimumTests --output $releaseValidation
if ($LASTEXITCODE -ne 0) { throw 'Swift Release tests failed or discovery count is insufficient' }
$buildCommand = 'call "' + $developer + '" -arch=x64 -host_arch=x64 >nul && "' + $swift + '" --version && "' + $swift + '" build --package-path "' + $package + '" -c release --product LightrayCoreProbe --force-resolved-versions --jobs 8'
& cmd.exe /d /c $buildCommand
if ($LASTEXITCODE -ne 0) { throw 'Swift core build/test failed' }
$bin = & $swift build --package-path $package -c release --show-bin-path
if ($LASTEXITCODE -ne 0) { throw 'Swift product directory query failed' }
$library = Join-Path $bin 'LightrayCoreProbe.dll'
if (-not (Test-Path $library)) { throw 'Expected a release probe DLL in the Swift product directory' }
$source = Join-Path $PSScriptRoot 'src\core_abi_probe.cpp'
$executable = Join-Path $root 'core_abi_probe.exe'
$nativeCommand = 'call "' + $developer + '" -arch=x64 -host_arch=x64 >nul && cl /nologo /std:c++20 /EHsc /W4 /WX /O2 /utf-8 /I"' + $root + '" "' + $source + '" /Fe:"' + $executable + '"'
Push-Location $root
try {
    & cmd.exe /d /c $nativeCommand
    if ($LASTEXITCODE -ne 0) { throw 'MSVC C ABI caller compilation failed' }
    $process = Start-Process $executable -ArgumentList ('"' + $library + '"') -NoNewWindow -PassThru -RedirectStandardOutput abi-result.json -RedirectStandardError abi-result.log
    $processHandle = $process.Handle
    if (-not $process.WaitForExit(30000)) { $process.Kill(); $process.WaitForExit(); throw 'C ABI probe timed out after 30 seconds' }
    if ($process.ExitCode -ne 0) { throw 'C ABI probe failed' }
    Get-Content abi-result.json
    if ($manifest.host_bridge) {
        $hostSource = Join-Path $PSScriptRoot 'src\host_abi_probe.cpp'
        $hostExecutable = Join-Path $root 'host_abi_probe.exe'
        $hostCommand = 'call "' + $developer + '" -arch=x64 -host_arch=x64 >nul && cl /nologo /std:c++20 /EHsc /W4 /WX /O2 /utf-8 "' + $hostSource + '" "' + (Join-Path $PSScriptRoot 'src\nvenc_encoder.cpp') + '" /Fe:"' + $hostExecutable + '" /link d3d11.lib dxgi.lib ws2_32.lib'
        & cmd.exe /d /c $hostCommand
        if ($LASTEXITCODE -ne 0) { throw 'Host ABI caller compilation failed' }
        $corpus = Join-Path $PSScriptRoot 'results\native-nvenc-003'
        $hostProcess = Start-Process $hostExecutable -ArgumentList ('"' + $library + '" "' + $corpus + '"') -NoNewWindow -PassThru -RedirectStandardOutput host-abi-result.json -RedirectStandardError host-abi-result.log
        $hostProcessHandle = $hostProcess.Handle
        if (-not $hostProcess.WaitForExit(60000)) { $hostProcess.Kill(); $hostProcess.WaitForExit(); throw 'Host ABI probe timed out after 60 seconds' }
        if ($hostProcess.ExitCode -ne 0) { Get-Content host-abi-result.log; throw 'Host ABI probe failed' }
        Get-Content host-abi-result.json
    }
} finally { Pop-Location }
