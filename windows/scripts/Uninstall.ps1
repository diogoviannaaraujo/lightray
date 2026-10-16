[CmdletBinding()]
param([switch]$RemoveUserData)
. (Join-Path $PSScriptRoot 'Common.ps1')

$bundle = Get-LightrayBundle -Directory $PSScriptRoot
$app = [string]$bundle.app
$destination = Get-LightrayInstallPath -App $app
$programs = Split-Path -Parent $destination
$null = Assert-LightrayPath -Path $destination -AllowedParent $programs
Assert-LightrayInstallation -Path $destination -App $app
Stop-LightrayInstallation -Path $destination -App $app
$shortcut = Get-LightrayShortcutPath -App $app
if (Test-Path -LiteralPath $shortcut) {
    $shell = New-Object -ComObject WScript.Shell
    if ($shell.CreateShortcut($shortcut).TargetPath -eq (Join-Path $destination "Lightray.$app.exe")) {
        Remove-Item -LiteralPath $shortcut -Force
    }
}
Remove-LightrayDirectory -Path $destination -AllowedParent $programs
if ($RemoveUserData) {
    $dataRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Lightray'
    Remove-LightrayDirectory -Path (Join-Path $dataRoot $app) -AllowedParent $dataRoot
}
Write-Host "Uninstalled Lightray $app."
if (-not $RemoveUserData) { Write-Host 'Saved computers, settings, and pairing data were retained.' }
