#Requires -Version 5.1
# pckit engine | hardware: портрет ПК для «умного» подбора настроек и советов (только чтение)

$script:PckitDisplaySource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Pckit
{
    public class DisplayInfo
    {
        public string Device;
        public bool Primary;
        public int Width;
        public int Height;
        public int Hz;
        public int MaxHz;        // максимум при текущем разрешении
    }

    public static class Displays
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct DISPLAY_DEVICE
        {
            public int cb;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
            public int StateFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct DEVMODE
        {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
            public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
            public int dmFields;
            public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
            public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
            public short dmLogPixels;
            public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
            public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool EnumDisplayDevices(string dev, int i, ref DISPLAY_DEVICE dd, int flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);

        public static DisplayInfo[] List()
        {
            var result = new List<DisplayInfo>();
            for (int i = 0; ; i++)
            {
                var dd = new DISPLAY_DEVICE();
                dd.cb = Marshal.SizeOf(dd);
                if (!EnumDisplayDevices(null, i, ref dd, 0)) break;
                if ((dd.StateFlags & 1) == 0) continue;   // не подключён к рабочему столу
                var cur = new DEVMODE();
                cur.dmSize = (short)Marshal.SizeOf(cur);
                if (!EnumDisplaySettings(dd.DeviceName, -1, ref cur)) continue;
                var info = new DisplayInfo
                {
                    Device = dd.DeviceName, Primary = (dd.StateFlags & 4) != 0,
                    Width = cur.dmPelsWidth, Height = cur.dmPelsHeight, Hz = cur.dmDisplayFrequency, MaxHz = cur.dmDisplayFrequency
                };
                for (int m = 0; ; m++)
                {
                    var dm = new DEVMODE();
                    dm.dmSize = (short)Marshal.SizeOf(dm);
                    if (!EnumDisplaySettings(dd.DeviceName, m, ref dm)) break;
                    if (dm.dmPelsWidth == cur.dmPelsWidth && dm.dmPelsHeight == cur.dmPelsHeight && dm.dmDisplayFrequency > info.MaxHz)
                        info.MaxHz = dm.dmDisplayFrequency;
                }
                result.Add(info);
            }
            return result.ToArray();
        }
    }
}
'@

function Find-PckitCs2 {
    $candidates = New-Object System.Collections.ArrayList

    try {
        $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
        if ($steam) { [void]$candidates.Add(($steam -replace '/', '\')) }
    } catch { }

    if (-not $candidates.Count) {
        [void]$candidates.Add('C:\Program Files (x86)\Steam')
        [void]$candidates.Add('D:\Steam')
    }
    $libFile = Join-Path ([string]$candidates[0] -replace '\\$', '') 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $libFile) {
        try {
            foreach ($m in [regex]::Matches((Get-Content -LiteralPath $libFile -Raw), '"path"\s+"([^"]+)"')) {
                [void]$candidates.Add(($m.Groups[1].Value -replace '\\\\', '\'))
            }
        } catch { }
    }
    foreach ($root in $candidates) {
        $path = Join-Path $root 'steamapps\common\Counter-Strike Global Offensive'
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return $null
}

$script:PckitHardwareCache = $null

function Get-PckitDisplays {
    try {
        if (-not ('Pckit.Displays' -as [type])) { Add-Type -TypeDefinition $script:PckitDisplaySource -Language CSharp -ErrorAction Stop }
        return @([Pckit.Displays]::List())
    } catch { return @() }
}

function Get-PckitGpuVendor {
    param([string]$Name, [string]$Compat)
    $t = ('{0} {1}' -f $Name, $Compat)
    if ($t -match 'NVIDIA') { return 'nvidia' }
    if ($t -match 'AMD|Radeon|Advanced Micro') { return 'amd' }
    if ($t -match 'Intel') { return 'intel' }
    return 'other'
}

# интегрированная графика: Intel UHD/Iris (не Arc), Radeon Graphics/Vega в составе процессора
function Test-PckitIntegratedGpu {
    param([string]$Name)
    if ($Name -match 'Intel' -and $Name -notmatch '\bArc\b') { return $true }
    if ($Name -match '^AMD Radeon\(TM\) Graphics$|Radeon\(TM\) Vega|Radeon Vega \d+ Graphics|AMD Radeon Graphics$|Radeon \d{3}M\b') { return $true }
    return $false
}

function Get-PckitSteamPath {
    try {
        $p = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath
        if ($p) { return ($p -replace '/', '\') }
    } catch { }
    return $null
}

# последний вошедший пользователь Steam (папка userdata\<id>)
function Get-PckitSteamUserDir {
    $steam = Get-PckitSteamPath
    if (-not $steam) { return $null }
    $root = Join-Path $steam 'userdata'
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    $active = $null
    try { $active = [string](Get-ItemProperty 'HKCU:\Software\Valve\Steam\ActiveProcess' -ErrorAction Stop).ActiveUser } catch { }
    if ($active -and $active -ne '0') {
        $dir = Join-Path $root $active
        if (Test-Path -LiteralPath $dir) { return $dir }
    }
    $dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne '0' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'config\localconfig.vdf')) } |
            Sort-Object { (Get-Item -LiteralPath (Join-Path $_.FullName 'config\localconfig.vdf')).LastWriteTime } -Descending)
    if ($dirs.Count) { return $dirs[0].FullName }
    return $null
}

# видеонастройки CS2 из cs2_video.txt: { Fullscreen, VSync, LowLatency, RefreshHz, Width, Height }
function Get-PckitCs2VideoSettings {
    $user = Get-PckitSteamUserDir
    if (-not $user) { return $null }
    $file = Join-Path $user '730\local\cfg\cs2_video.txt'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $kv = @{}
    foreach ($m in [regex]::Matches((Get-Content -LiteralPath $file -Raw -ErrorAction SilentlyContinue), '"([^"]+)"\s+"([^"]*)"')) {
        $kv[$m.Groups[1].Value] = $m.Groups[2].Value
    }
    $num = { param($k) if ($kv.ContainsKey($k)) { try { return [double]$kv[$k] } catch { } }; return $null }
    $hz = $null
    $n = & $num 'setting.refreshrate_numerator'; $d = & $num 'setting.refreshrate_denominator'
    if ($n -and $d) { $hz = [math]::Round($n / $d) }
    return [pscustomobject]@{
        File       = $file
        Fullscreen = (& $num 'setting.fullscreen')
        VSync      = (& $num 'setting.mat_vsync')
        LowLatency = (& $num 'setting.r_low_latency')
        RefreshHz  = $hz
        Width      = (& $num 'setting.defaultres')
        Height     = (& $num 'setting.defaultresheight')
    }
}

function Get-PckitHardwareProfile {
    param([switch]$Refresh)
    if ($script:PckitHardwareCache -and -not $Refresh) { return $script:PckitHardwareCache }
    # фоновые задачи окна стартуют с пустой памятью — берём свежий (до 10 минут) портрет с диска, а не сканируем ПК заново
    $cacheFile = Join-Path $env:LOCALAPPDATA 'pckit\hw-cache.json'
    if (-not $Refresh -and (Test-Path -LiteralPath $cacheFile)) {
        try {
            if (((Get-Date) - (Get-Item -LiteralPath $cacheFile).LastWriteTime).TotalMinutes -lt 10) {
                $cached = Get-Content -LiteralPath $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($cached -and $cached.Build -eq [Environment]::OSVersion.Version.Build) {
                    $cached.Displays = @($cached.Displays); $cached.GpuList = @($cached.GpuList)
                    $script:PckitHardwareCache = $cached
                    return $cached
                }
            }
        } catch { }
    }

    $hw = [ordered]@{
        GpuVendor = 'other'; GpuName = ''; GpuDriverVersion = ''; GpuDriverDate = $null
        HybridGpu = $false; IntegratedOnly = $false; GpuList = @()
        Laptop = $false; OnBattery = $false
        CpuName = ''; CpuCores = 0; CpuThreads = 0; CpuVendor = ''
        RamGb = 0; RamModules = 0; RamType = ''; RamMhz = 0; RamRatedMhz = 0
        SystemSsd = $null; SystemDiskName = ''
        Displays = @(); PrimaryHz = 0; PrimaryMaxHz = 0
        Build = [Environment]::OSVersion.Version.Build
        Hags = $null
        WiredNetwork = $null; WifiOnly = $false
        Cs2Path = $null; Cs2Exe = $null; Cs2Video = $null
        SteamRunning = $false
    }

    # ---- видеокарты
    try {
        $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { $_.Name -and $_.Name -notmatch 'Basic Display|Remote|Virtual|Parsec|Meta' })
        $list = foreach ($g in $gpus) {
            [pscustomobject]@{
                Name = [string]$g.Name; Vendor = (Get-PckitGpuVendor -Name $g.Name -Compat $g.AdapterCompatibility)
                Integrated = (Test-PckitIntegratedGpu -Name $g.Name); Driver = [string]$g.DriverVersion; DriverDate = $g.DriverDate
            }
        }
        $list = @($list)
        $hw.GpuList = $list
        $discrete = @($list | Where-Object { -not $_.Integrated })
        $main = if ($discrete.Count) { $discrete[0] } elseif ($list.Count) { $list[0] } else { $null }
        if ($main) {
            $hw.GpuVendor = $main.Vendor; $hw.GpuName = $main.Name; $hw.GpuDriverVersion = $main.Driver; $hw.GpuDriverDate = $main.DriverDate
        }
        $hw.HybridGpu = ($discrete.Count -ge 1 -and @($list | Where-Object { $_.Integrated }).Count -ge 1)
        $hw.IntegratedOnly = ($list.Count -ge 1 -and $discrete.Count -eq 0)
    } catch { }

    # ---- ноутбук / батарея
    try {
        $chassis = @((Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop).ChassisTypes)
        $laptopTypes = 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32
        $hw.Laptop = [bool](@($chassis | Where-Object { $laptopTypes -contains [int]$_ }).Count)
    } catch { }
    try {
        $bat = @(Get-CimInstance Win32_Battery -ErrorAction Stop)
        if ($bat.Count) {
            $hw.Laptop = $true
            # 1 = разряжается (работает от батареи)
            $hw.OnBattery = [bool](@($bat | Where-Object { [int]$_.BatteryStatus -eq 1 }).Count)
        }
    } catch { }

    # ---- процессор
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $hw.CpuName = ([string]$cpu.Name).Trim(); $hw.CpuCores = [int]$cpu.NumberOfCores; $hw.CpuThreads = [int]$cpu.NumberOfLogicalProcessors
        $hw.CpuVendor = if ($cpu.Manufacturer -match 'AMD') { 'amd' } elseif ($cpu.Manufacturer -match 'Intel') { 'intel' } else { 'other' }
    } catch { }

    # ---- память: тип и частота (Speed = паспорт планки, ConfiguredClockSpeed = как работает сейчас)
    try {
        $mods = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
        $hw.RamModules = $mods.Count
        $hw.RamGb = [math]::Round((($mods | Measure-Object -Property Capacity -Sum).Sum / 1GB))
        $t = [int]($mods | Select-Object -First 1).SMBIOSMemoryType
        $hw.RamType = switch ($t) { 24 { 'DDR3' } 26 { 'DDR4' } 34 { 'DDR5' } default { '' } }
        $cfg = @($mods | ForEach-Object { [int]$_.ConfiguredClockSpeed } | Where-Object { $_ -gt 0 } | Sort-Object)
        $rated = @($mods | ForEach-Object { [int]$_.Speed } | Where-Object { $_ -gt 0 } | Sort-Object)
        if ($cfg.Count) { $hw.RamMhz = $cfg[0] }
        if ($rated.Count) { $hw.RamRatedMhz = $rated[0] }
    } catch { }

    # ---- системный диск: SSD или HDD
    try {
        $letter = $env:SystemDrive.Substring(0, 1)
        $disk = Get-Partition -DriveLetter $letter -ErrorAction Stop | Get-Disk -ErrorAction Stop
        $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.DeviceId -eq [string]$disk.Number } | Select-Object -First 1
        if ($pd) {
            $hw.SystemDiskName = [string]$pd.FriendlyName
            if ([string]$pd.MediaType -eq 'SSD' -or [string]$pd.BusType -eq 'NVMe') { $hw.SystemSsd = $true }
            elseif ([string]$pd.MediaType -eq 'HDD') { $hw.SystemSsd = $false }
        }
    } catch { }

    # ---- мониторы
    $hw.Displays = @(Get-PckitDisplays)
    $prim = @($hw.Displays | Where-Object { $_.Primary }) | Select-Object -First 1
    if (-not $prim) { $prim = @($hw.Displays) | Select-Object -First 1 }
    if ($prim) { $hw.PrimaryHz = [int]$prim.Hz; $hw.PrimaryMaxHz = [int]$prim.MaxHz }

    # ---- HAGS: 2 = включено, 1 = выключено, нет значения = по умолчанию
    try {
        $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -ErrorAction Stop).HwSchMode
        $hw.Hags = ([int]$v -eq 2)
    } catch { }

    # ---- сеть: кабель или только Wi-Fi
    try {
        $up = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
        $wired = @($up | Where-Object { $_.PhysicalMediaType -match '802\.3' -or ($_.InterfaceDescription -notmatch 'Wi-?Fi|Wireless|802\.11|WLAN' -and $_.NdisPhysicalMedium -eq 14) })
        $wifi = @($up | Where-Object { $_.PhysicalMediaType -match '802\.11|Native 802.11' -or $_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN' })
        $hw.WiredNetwork = [bool]$wired.Count
        $hw.WifiOnly = ($wifi.Count -gt 0 -and $wired.Count -eq 0)
    } catch { }

    # ---- CS2 и Steam
    try {
        $hw.Cs2Path = Find-PckitCs2
        if ($hw.Cs2Path) {
            $exe = Join-Path $hw.Cs2Path 'game\bin\win64\cs2.exe'
            if (Test-Path -LiteralPath $exe) { $hw.Cs2Exe = $exe }
        }
        $hw.Cs2Video = Get-PckitCs2VideoSettings
        $hw.SteamRunning = [bool](@(Get-Process -Name 'steam' -ErrorAction SilentlyContinue).Count)
    } catch { }

    $script:PckitHardwareCache = [pscustomobject]$hw
    try {
        $dir = Split-Path -Parent $cacheFile
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [IO.File]::WriteAllText($cacheFile, ($script:PckitHardwareCache | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
    return $script:PckitHardwareCache
}

# короткое описание для шапки: «RTX 3070 · Ryzen 5 5600X · 32 ГБ DDR4-3200 · SSD · 280 Гц»
function Format-PckitHardwareLine {
    param($Hw)
    $parts = New-Object System.Collections.ArrayList
    if ($Hw.GpuName) { [void]$parts.Add(($Hw.GpuName -replace 'NVIDIA GeForce |AMD Radeon |\(TM\)|\(R\)', '').Trim()) }
    if ($Hw.CpuName) { [void]$parts.Add(($Hw.CpuName -replace '\s+\d+-Core Processor|\s+Processor|\(TM\)|\(R\)|CPU @.*$', '' -replace 'AMD |Intel |Core ', '').Trim()) }
    if ($Hw.RamGb) {
        $r = '{0} ГБ' -f $Hw.RamGb
        if ($Hw.RamType -and $Hw.RamMhz) { $r += (' {0}-{1}' -f $Hw.RamType, $Hw.RamMhz) }
        [void]$parts.Add($r)
    }
    if ($null -ne $Hw.SystemSsd) { [void]$parts.Add($(if ($Hw.SystemSsd) { 'SSD' } else { 'HDD' })) }
    if ($Hw.PrimaryHz) { [void]$parts.Add(('{0} Гц' -f $Hw.PrimaryHz)) }
    if ($Hw.Laptop) { [void]$parts.Add('ноутбук') }
    return ($parts -join ' · ')
}
