$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$warnings = New-Object 'System.Collections.Generic.List[string]'
function Read-Section($Name, [scriptblock]$Read) {
    try { & $Read } catch { $warnings.Add($Name + ': unavailable'); return $null }
}
$inventory = [ordered]@{
    schema_version = 1
    platform = 'windows'
    powershell = $PSVersionTable.PSVersion.ToString()
    interactive = [Environment]::UserInteractive
    process_session_id = (Get-Process -Id $PID).SessionId
    os = Read-Section 'os' { Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture }
    cpu = @(Read-Section 'cpu' { Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors })
    ram_bytes = Read-Section 'ram' { (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory }
    gpu = @(Read-Section 'gpu' { Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, VideoProcessor, CurrentHorizontalResolution, CurrentVerticalResolution, CurrentRefreshRate })
    network = @(Read-Section 'network' { Get-NetAdapter | Select-Object InterfaceDescription, Status, LinkSpeed })
    mtu = @(Read-Section 'mtu' { Get-NetIPInterface | Select-Object AddressFamily, NlMtu, ConnectionState })
    sdk_versions = @(Read-Section 'sdk' { Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' | Where-Object { $_.PSChildName -match '^10\.' } | Select-Object -ExpandProperty PSChildName })
    tools = @()
    visual_studio = @()
    nvidia = @()
    displays = @()
}
foreach ($name in @('git', 'cmake', 'ninja', 'cl', 'swift', 'ffmpeg', 'ffprobe', 'nvidia-smi')) {
    $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $inventory.tools += [ordered]@{ name = $name; available_on_path = ($null -ne $command); file_version = $(if ($command) { $command.FileVersionInfo.FileVersion } else { $null }) }
}
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path $vswhere) {
    $inventory.visual_studio = @(Read-Section 'visual_studio' {
        $raw = & $vswhere -all -products '*' -format json
        if ($LASTEXITCODE -ne 0) { throw 'vswhere failed' }
        $instances = ConvertFrom-Json -InputObject ($raw -join "`n")
        $instances | ForEach-Object { $_ | Select-Object installationVersion, isComplete, isLaunchable }
    })
}
$nvidia = Get-Command nvidia-smi -CommandType Application -ErrorAction SilentlyContinue
if ($nvidia) {
    $inventory.nvidia = @(Read-Section 'nvidia' {
        $raw = & $nvidia.Source '--query-gpu=name,memory.total,driver_version' '--format=csv,noheader,nounits'
        if ($LASTEXITCODE -ne 0) { throw 'nvidia-smi failed' }
        $raw | ConvertFrom-Csv -Header model, vram_mib, driver_version
    })
}
$inventory.displays = @(Read-Section 'displays' {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
        [ordered]@{ width = $_.Bounds.Width; height = $_.Bounds.Height; primary = $_.Primary; bits_per_pixel = $_.BitsPerPixel }
    }
})
$inventory['unmeasured'] = @('physical console topology', 'HDR', 'VRR', 'DPI', 'active power plan', 'direct versus DERP path', 'UDP path MTU', 'GPU decode availability', 'SDK and compiler build smoke')
$inventory['warnings'] = @($warnings.ToArray())
$inventory | ConvertTo-Json -Depth 8 -Compress
