Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LightrayBundle {
    param([string]$Directory)
    $manifest = Get-Content -LiteralPath (Join-Path $Directory 'bundle.json') -Raw | ConvertFrom-Json
    if ($manifest.app -notin @('Host', 'Client')) { throw 'Invalid Lightray bundle manifest.' }
    return $manifest
}

function Get-LightrayInstallPath {
    param([ValidateSet('Host', 'Client')][string]$App)
    return [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "Programs\Lightray$App"))
}

function Assert-LightrayPath {
    param([string]$Path, [string]$AllowedParent)
    $absolute = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetFullPath($AllowedParent).TrimEnd('\')
    if (-not $absolute.StartsWith($parent + '\', [StringComparison]::OrdinalIgnoreCase) -or $absolute -eq $parent) {
        throw "Refusing to modify a path outside $parent"
    }
    $cursor = $absolute
    while ($cursor.Length -ge $parent.Length) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing to modify a linked directory: $cursor" }
        }
        if ($cursor -eq $parent) { break }
        $cursor = Split-Path -Parent $cursor
    }
    return $absolute
}

function Assert-LightrayInstallation {
    param([string]$Path, [ValidateSet('Host', 'Client')][string]$App)
    if (Test-Path -LiteralPath $Path) {
        $marker = Join-Path $Path '.lightray-install.json'
        if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw "The destination is not a managed Lightray installation: $Path" }
        $installed = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
        if ($installed.app -ne $App) { throw "The destination contains a different application: $Path" }
    }
}

function Stop-LightrayInstallation {
    param([string]$Path, [ValidateSet('Host', 'Client')][string]$App)
    if ($App -eq 'Host') {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $taskName = "Lightray Host $sid"
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($null -ne $task) {
            $actions = @($task.Actions)
            $expected = [IO.Path]::GetFullPath((Join-Path $Path 'lightray-host-agent.exe'))
            if ($actions.Count -ne 1 -or [IO.Path]::GetFullPath($actions[0].Execute) -ne $expected) {
                throw 'The login task belongs to another Lightray location. Stop Sharing in that installation before installing or removing this one.'
            }
            Unregister-ScheduledTask -InputObject $task -Confirm:$false
        }
        $check = Join-Path $Path 'lightray-check.exe'
        $expectedAgent = [IO.Path]::GetFullPath((Join-Path $Path 'lightray-host-agent.exe'))
        $matchingAgent = $false
        foreach ($process in @(Get-Process -Name 'lightray-host-agent' -ErrorAction SilentlyContinue)) {
            try { $actual = $process.Path } catch { continue }
            if ($actual -and [IO.Path]::GetFullPath($actual) -eq $expectedAgent) { $matchingAgent = $true }
        }
        if ($matchingAgent -and (Test-Path -LiteralPath $check -PathType Leaf)) {
            & $check --stop-host
            if ($LASTEXITCODE -ne 0) { throw 'Unable to request a graceful host shutdown.' }
        }
    }
    $names = if ($App -eq 'Host') { @('Lightray.Host', 'lightray-host-agent') } else { @('Lightray.Client') }
    foreach ($name in $names) {
        $expected = [IO.Path]::GetFullPath((Join-Path $Path ($name + '.exe')))
        foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            try { $actual = $process.Path } catch { continue }
            if ($actual -and [IO.Path]::GetFullPath($actual) -eq $expected) {
                if ($name -eq 'lightray-host-agent' -and $process.WaitForExit(3000)) { continue }
                if ($name -ne 'lightray-host-agent' -and $process.CloseMainWindow() -and $process.WaitForExit(5000)) { continue }
                Stop-Process -Id $process.Id -Force
                if (-not $process.WaitForExit(10000)) { throw "Unable to stop $expected" }
            }
        }
    }
}

function Remove-LightrayDirectory {
    param([string]$Path, [string]$AllowedParent)
    $absolute = Assert-LightrayPath -Path $Path -AllowedParent $AllowedParent
    if (Test-Path -LiteralPath $absolute) {
        foreach ($item in Get-ChildItem -LiteralPath $absolute -Recurse -Force) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing to recursively remove a linked item: $($item.FullName)" }
        }
        Remove-Item -LiteralPath $absolute -Recurse -Force
    }
}

function Get-LightrayShortcutPath {
    param([ValidateSet('Host', 'Client')][string]$App)
    return Join-Path ([Environment]::GetFolderPath('Programs')) "Lightray $App.lnk"
}
