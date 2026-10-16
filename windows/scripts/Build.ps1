[CmdletBinding()]
param(
    [string]$OutputDirectory = '',
    [string]$Version = '0.1.0',
    [switch]$SkipValidation,
    [switch]$SmokeTest
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$windowsRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $windowsRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $windowsRoot 'artifacts' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
if ($Version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { throw 'Version must use MAJOR.MINOR.PATCH, optionally with a prerelease suffix.' }

function Invoke-Checked {
    param([string]$File, [string[]]$Arguments)
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$File failed with exit code $LASTEXITCODE" }
}

$null = New-Item -ItemType Directory -Path $output -Force
$stage = Assert-LightrayPath -Path (Join-Path $output ('staging.' + [Guid]::NewGuid().ToString('N'))) -AllowedParent $output
$null = New-Item -ItemType Directory -Path $stage
Push-Location $windowsRoot
try {
    if (-not $SkipValidation) {
        & (Join-Path $PSScriptRoot 'Test-Packaging.ps1')
        Invoke-Checked -File 'cargo' -Arguments @('fmt', '--all', '--', '--check')
        Invoke-Checked -File 'cargo' -Arguments @('clippy', '--workspace', '--all-targets', '--locked', '--', '-D', 'warnings')
        Invoke-Checked -File 'cargo' -Arguments @('test', '--workspace', '--locked')
    }
    Invoke-Checked -File 'cargo' -Arguments @('build', '--workspace', '--release', '--locked')
    $native = Join-Path $windowsRoot 'target\release'
    Invoke-Checked -File (Join-Path $native 'lightray-check.exe') -Arguments @('--abi-smoke')
    $commit = (& git -C $repoRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Unable to determine the source commit.' }
    $dirty = [bool](& git -C $repoRoot status --porcelain -- windows .cargo .github/workflows/windows.yml)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to determine whether the source tree is dirty.' }
    $sourcePaths = & git -C $repoRoot ls-files --cached --others --exclude-standard -- windows .cargo .github/workflows/windows.yml
    if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate source files.' }
    $sourceFiles = @($sourcePaths | Sort-Object -Unique | ForEach-Object {
        [ordered]@{ path = $_; sha256 = (Get-FileHash -LiteralPath (Join-Path $repoRoot $_) -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    $provenance = [ordered]@{ base_commit = $commit; source_tree_dirty = $dirty; files = $sourceFiles } | ConvertTo-Json -Depth 5 -Compress
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $sourceHash = ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($provenance)))).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
    foreach ($app in @('Host', 'Client')) {
        $project = Join-Path $windowsRoot "ui\$app\Lightray.$app.csproj"
        $bundle = Join-Path $stage $app
        Invoke-Checked -File 'dotnet' -Arguments @('restore', $project, '--locked-mode', '-r', 'win-x64', '--nologo')
        Invoke-Checked -File 'dotnet' -Arguments @('publish', $project, '-c', 'Release', '-r', 'win-x64', '--self-contained', 'true', '--no-restore', '-p:PublishSingleFile=false', '-p:PublishTrimmed=false', '-o', $bundle, '--nologo')
        foreach ($required in @("Lightray.$app.exe", "Lightray.$app.pri", 'App.xbf', 'Microsoft.UI.Xaml.dll', 'coreclr.dll')) {
            if (-not (Test-Path -LiteralPath (Join-Path $bundle $required) -PathType Leaf)) { throw "Self-contained publish is incomplete: $required" }
        }
        foreach ($name in @('lightray_runtime.dll', 'lightray-check.exe')) {
            Copy-Item -LiteralPath (Join-Path $native $name) -Destination $bundle
        }
        if ($app -eq 'Host') { Copy-Item -LiteralPath (Join-Path $native 'lightray-host-agent.exe') -Destination $bundle }
        foreach ($script in @('Install.ps1', 'Uninstall.ps1', 'Common.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $script) -Destination $bundle }
        @{ app = $app; version = $Version; architecture = 'x64'; base_commit = $commit; source_tree_dirty = $dirty; source_sha256 = $sourceHash; abi_version = 1 } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $bundle 'bundle.json') -Encoding UTF8
        [IO.File]::WriteAllText((Join-Path $bundle 'source-manifest.json'), $provenance, [Text.UTF8Encoding]::new($false))
        if ($SmokeTest) {
            $previousData = [Environment]::GetEnvironmentVariable('LIGHTRAY_DATA_DIR', 'Process')
            try {
                $env:LIGHTRAY_DATA_DIR = Join-Path $stage "smoke-$app"
                $process = Start-Process -FilePath (Join-Path $bundle "Lightray.$app.exe") -ArgumentList '--smoke-test' -WindowStyle Hidden -PassThru
                if (-not $process.WaitForExit(20000)) { Stop-Process -Id $process.Id -Force; throw "$app UI smoke test timed out." }
                if ($process.ExitCode -ne 0) {
                    $log = Join-Path $env:LIGHTRAY_DATA_DIR 'Logs\ui.log'
                    if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Tail 30 | Write-Host }
                    throw "$app UI smoke test failed with exit code $($process.ExitCode)."
                }
            } finally {
                [Environment]::SetEnvironmentVariable('LIGHTRAY_DATA_DIR', $previousData, 'Process')
            }
        }
        $archive = Join-Path $output "Lightray-$app-win-x64.zip"
        Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $archive -Force
        $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $([IO.Path]::GetFileName($archive))" | Set-Content -LiteralPath ($archive + '.sha256') -Encoding ASCII
        Write-Host "Created $archive"
    }
} finally {
    Pop-Location
    Remove-LightrayDirectory -Path $stage -AllowedParent $output
}
