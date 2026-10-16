[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'Common.ps1')

$bundle = Get-LightrayBundle -Directory $PSScriptRoot
$app = [string]$bundle.app
$destination = Get-LightrayInstallPath -App $app
$programs = Split-Path -Parent $destination
$null = Assert-LightrayPath -Path $destination -AllowedParent $programs
Assert-LightrayInstallation -Path $destination -App $app
if ([IO.Path]::GetFullPath($PSScriptRoot) -eq $destination) { throw 'Extract a new bundle to another folder before running its installer.' }
if (($programs + '\').StartsWith([IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Extract the bundle outside the Programs directory before installing it.'
}
foreach ($name in @("Lightray.$app.exe", 'lightray_runtime.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)) { throw "Bundle file is missing: $name" }
}

$null = New-Item -ItemType Directory -Path $programs -Force
$stage = Assert-LightrayPath -Path (Join-Path $programs ('.Lightray' + $app + '.install.' + [Guid]::NewGuid().ToString('N'))) -AllowedParent $programs
$backup = Assert-LightrayPath -Path (Join-Path $programs ('.Lightray' + $app + '.backup.' + [Guid]::NewGuid().ToString('N'))) -AllowedParent $programs
$null = New-Item -ItemType Directory -Path $stage
$backedUp = $false
try {
    foreach ($item in Get-ChildItem -LiteralPath $PSScriptRoot -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $stage -Recurse -Force
    }
    @{ app = $app; version = $bundle.version } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage '.lightray-install.json') -Encoding UTF8
    Stop-LightrayInstallation -Path $destination -App $app
    if (Test-Path -LiteralPath $destination) {
        $null = Assert-LightrayPath -Path $destination -AllowedParent $programs
        $null = Assert-LightrayPath -Path $backup -AllowedParent $programs
        Move-Item -LiteralPath $destination -Destination $backup
        $backedUp = $true
    }
    try { Move-Item -LiteralPath $stage -Destination $destination }
    catch {
        if ($backedUp -and -not (Test-Path -LiteralPath $destination)) { Move-Item -LiteralPath $backup -Destination $destination; $backedUp = $false }
        throw
    }
    $shell = New-Object -ComObject WScript.Shell
    $shortcutPath = Get-LightrayShortcutPath -App $app
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $shortcutPath) -Force
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = Join-Path $destination "Lightray.$app.exe"
    $shortcut.WorkingDirectory = $destination
    $shortcut.Save()
    if ($backedUp) { Remove-LightrayDirectory -Path $backup -AllowedParent $programs }
    Write-Host "Installed Lightray $app in $destination."
    Write-Host 'Your saved computers and pairing data were preserved. Sharing is not started by this installer.'
} finally {
    Remove-LightrayDirectory -Path $stage -AllowedParent $programs
}
