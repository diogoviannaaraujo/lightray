param([string]$Probe = 'swift-core-001', [string]$Run = 'portable-001')
$ErrorActionPreference = 'Stop'
if ($Probe -notmatch '^swift-core-[0-9]{3}$' -or $Run -notmatch '^portable-[0-9]{3}$') { throw 'Invalid lab directory name' }
$root = Join-Path $PSScriptRoot ('results\' + $Probe)
$output = Join-Path $root $Run
if (Test-Path $output) { throw 'Portable experiment output already exists' }
$runtime = Join-Path $env:LOCALAPPDATA 'Programs\Swift\Runtimes\6.4.0\usr\bin'
$swift = Join-Path $env:LOCALAPPDATA 'Programs\Swift\Toolchains\6.4.0+Asserts\usr\bin\swift.exe'
$bin = & $swift build --package-path (Join-Path $root 'macos') -c release --show-bin-path
if ($LASTEXITCODE -ne 0) { throw 'Swift product directory query failed' }
$library = Join-Path $bin 'LightrayCoreProbe.dll'
if (-not (Test-Path $library)) { throw 'Build the release probe DLL first' }
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $installation) { throw 'MSVC unavailable' }
$msvc = Get-ChildItem (Join-Path $installation 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1
$dumpbin = Join-Path $msvc.FullName 'bin\Hostx64\x64\dumpbin.exe'
New-Item -ItemType Directory $output | Out-Null
Copy-Item $library (Join-Path $output 'LightrayCoreProbe.dll')
Copy-Item (Join-Path $root 'core_abi_probe.exe') $output
$pending = [System.Collections.Generic.Queue[string]]::new()
$pending.Enqueue('LightrayCoreProbe.dll')
$pending.Enqueue('core_abi_probe.exe')
$visited = @{}
$system = @{}
while ($pending.Count -gt 0) {
    $name = $pending.Dequeue()
    if ($visited.ContainsKey($name)) { continue }
    if ($visited.Count -ge 64) { throw 'Dependency traversal exceeded the 64-module lab limit' }
    $visited[$name] = $true
    $lines = & $dumpbin /nologo /dependents (Join-Path $output $name)
    if ($LASTEXITCODE -ne 0) { throw ('Dependency inspection failed: ' + $name) }
    foreach ($line in $lines) {
        if ($line -notmatch '^\s+([A-Za-z0-9_.-]+\.dll)\s*$') { continue }
        $dependency = $Matches[1]
        $local = Join-Path $output $dependency
        $provided = Join-Path $runtime $dependency
        if (Test-Path $local) {
            $pending.Enqueue($dependency)
        } elseif (Test-Path $provided) {
            Copy-Item $provided $local
            $pending.Enqueue($dependency)
        } elseif ($dependency -match '^(api|ext)-ms-win-' -or (Test-Path (Join-Path $env:SystemRoot ('System32\' + $dependency)))) {
            $system[$dependency] = $true
        } else {
            throw ('Unresolved dependency: ' + $dependency)
        }
    }
}
$manifest = @(Get-ChildItem $output -File | Sort-Object Name | ForEach-Object {
    [ordered]@{ name = $_.Name; bytes = $_.Length; sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
})
$savedPath = $env:PATH
Push-Location $output
try {
    $env:PATH = $output + ';' + (Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot
    $process = Start-Process (Join-Path $output 'core_abi_probe.exe') -ArgumentList ('"' + (Join-Path $output 'LightrayCoreProbe.dll') + '"') -NoNewWindow -PassThru -RedirectStandardOutput abi-result.json -RedirectStandardError abi-result.log
    $processHandle = $process.Handle
    if (-not $process.WaitForExit(30000)) { $process.Kill(); $process.WaitForExit(); throw 'App-local runtime probe timed out after 30 seconds' }
    if ($process.ExitCode -ne 0) { throw 'App-local runtime probe failed with toolchain removed from PATH' }
} finally {
    $env:PATH = $savedPath
    Pop-Location
}
[ordered]@{
    status = 'passed'; swift = '6.4.0'; files = $manifest; system_dependencies = @($system.Keys | Sort-Object)
    limits = @('App-local runtime load on the development machine; not a clean Windows installation', 'Licensing, signing, installer and minimum OS validation remain pending')
} | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $output 'manifest.json')
Get-Content (Join-Path $output 'abi-result.json')
