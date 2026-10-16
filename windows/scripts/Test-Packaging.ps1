Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('lightray-package-test.' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
function Assert-Throws {
    param([scriptblock]$Action)
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    if (-not $threw) { throw 'Expected the unsafe path or unmanaged directory to be rejected.' }
}
try {
    Assert-Throws { Assert-LightrayPath -Path $testRoot -AllowedParent $testRoot }
    Assert-Throws { Assert-LightrayPath -Path (Join-Path $testRoot '..\outside') -AllowedParent $testRoot }
    Assert-Throws { Assert-LightrayPath -Path ($testRoot + '-sibling\child') -AllowedParent $testRoot }
    $directory = Join-Path $testRoot 'Host'
    $null = New-Item -ItemType Directory -Path $directory
    Assert-Throws { Assert-LightrayInstallation -Path $directory -App Host }
    @{app = 'Host'; version = 'test'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory '.lightray-install.json')
    Assert-LightrayInstallation -Path $directory -App Host
    Assert-Throws { Assert-LightrayInstallation -Path $directory -App Client }
    'keep me' | Set-Content -LiteralPath (Join-Path $testRoot 'retained.txt')
    Remove-LightrayDirectory -Path $directory -AllowedParent $testRoot
    if (Test-Path -LiteralPath $directory) { throw 'Managed directory was not removed.' }
    if ((Get-Content -LiteralPath (Join-Path $testRoot 'retained.txt') -Raw).Trim() -ne 'keep me') { throw 'A sibling file was modified.' }
    $target = Join-Path $testRoot 'junction-target'
    $link = Join-Path $testRoot 'junction'
    $null = New-Item -ItemType Directory -Path $target
    'target preserved' | Set-Content -LiteralPath (Join-Path $target 'proof.txt')
    $null = New-Item -ItemType Junction -Path $link -Target $target
    try {
        Assert-Throws { Assert-LightrayPath -Path $link -AllowedParent $testRoot }
        Assert-Throws { Assert-LightrayPath -Path (Join-Path $link 'child') -AllowedParent $testRoot }
        Assert-Throws { Remove-LightrayDirectory -Path $testRoot -AllowedParent ([IO.Path]::GetTempPath()) }
    } finally { [IO.Directory]::Delete($link) }
    if ((Get-Content -LiteralPath (Join-Path $target 'proof.txt') -Raw).Trim() -ne 'target preserved') { throw 'A linked target was modified.' }
    @{app = 'Unrecognized'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $testRoot 'bundle.json')
    Assert-Throws { Get-LightrayBundle -Directory $testRoot }
    Write-Host 'Packaging path guards, installation markers, and retained-file checks passed.'
} finally {
    Remove-LightrayDirectory -Path $testRoot -AllowedParent ([IO.Path]::GetTempPath())
}
