#Requires -Version 5.1
<#
pckit-diff | снимок настроек Windows «до/после» и читаемый список отличий.
ТОЛЬКО ЧТЕНИЕ: скрипт ничего не меняет в системе, пишет только файл снимка / отчёта.

Использование:
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\pckit-diff.ps1 -Snapshot до.json
  ... запустите оптимизатор, перезагрузитесь, если он просит ...
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\pckit-diff.ps1 -Snapshot после.json
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\pckit-diff.ps1 -Before до.json -After после.json [-Report отчёт.md]

Запускать лучше от администратора (иначе bcdedit и часть задач планировщика не прочитаются).
Совет: сделайте два снимка подряд без изменений — разница между ними покажет «шум» (его можно не учитывать).
#>
[CmdletBinding(DefaultParameterSetName = 'Snapshot')]
param(
    [Parameter(ParameterSetName = 'Snapshot', Mandatory)][string]$Snapshot,
    [Parameter(ParameterSetName = 'Compare', Mandatory)][string]$Before,
    [Parameter(ParameterSetName = 'Compare', Mandatory)][string]$After,
    [string]$Report,
    [switch]$NoFilter
)
$ErrorActionPreference = 'Stop'

# ---- ветки реестра для снимка: путь, глубина вложенности ----
$script:RegistryTargets = @(
    ,@('HKCU', 'System\GameConfigStore', 2)
    ,@('HKCU', 'Software\Microsoft\GameBar', 2)
    ,@('HKCU', 'Software\Microsoft\Windows\CurrentVersion\GameDVR', 2)
    ,@('HKCU', 'Software\Microsoft\Windows\CurrentVersion\AppCompat', 1)
    ,@('HKCU', 'Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers', 1)
    ,@('HKLM', 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers', 1)
    ,@('HKCU', 'Control Panel\Mouse', 1)
    ,@('HKCU', 'Control Panel\Keyboard', 1)
    ,@('HKCU', 'Control Panel\Desktop', 2)
    ,@('HKCU', 'Control Panel\Accessibility', 3)
    ,@('HKCU', 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 1)
    ,@('HKCU', 'Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects', 2)
    ,@('HKCU', 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize', 1)
    ,@('HKCU', 'Software\Microsoft\Windows\CurrentVersion\Search', 2)
    ,@('HKCU', 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 1)
    ,@('HKCU', 'Software\Microsoft\Windows\CurrentVersion\Policies', 3)
    ,@('HKCU', 'Software\Policies', 4)
    ,@('HKCU', 'Software\Microsoft\Windows\DWM', 1)
    ,@('HKCU', 'Software\Microsoft\Windows\CurrentVersion\Run', 1)
    ,@('HKCU', 'Software\Microsoft\Windows\CurrentVersion\RunOnce', 1)
    ,@('HKCU', 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved', 2)
    ,@('HKCU', 'Environment', 1)
    ,@('HKLM', 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile', 3)
    ,@('HKLM', 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options', 3)
    ,@('HKLM', 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies', 3)
    ,@('HKLM', 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 1)
    ,@('HKLM', 'SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', 1)
    ,@('HKLM', 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 1)
    ,@('HKLM', 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved', 2)
    ,@('HKLM', 'SOFTWARE\Microsoft\Windows\DWM', 1)
    ,@('HKLM', 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 2)
    ,@('HKLM', 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 2)
    ,@('HKCU', 'Software\Microsoft\Windows\CurrentVersion\Uninstall', 2)
    ,@('HKLM', 'SOFTWARE\Policies', 5)
    ,@('HKLM', 'SOFTWARE\Microsoft\Windows Defender', 3)
    ,@('HKLM', 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer', 1)
    ,@('HKLM', 'SYSTEM\GameConfigStore', 2)
    ,@('HKLM', 'SYSTEM\CurrentControlSet\Control\GraphicsDrivers', 3)
    ,@('HKLM', 'SYSTEM\CurrentControlSet\Control\Power', 4)
    ,@('HKLM', 'SYSTEM\CurrentControlSet\Control\PriorityControl', 1)
    ,@('HKLM', 'SYSTEM\CurrentControlSet\Control\Session Manager', 3)
    ,@('HKLM', 'SYSTEM\CurrentControlSet\Control\DeviceGuard', 3)
    ,@('HKLM', 'SYSTEM\CurrentControlSet\Control\CI', 2)
    ,@('HKLM', 'SYSTEM\CurrentControlSet\Control\FileSystem', 1)
    ,@('HKLM', 'SYSTEM\CurrentControlSet\Control\CrashControl', 1)
    ,@('HKLM', 'SYSTEM\CurrentControlSet\Control\Lsa', 1)
    ,@('HKLM', 'SYSTEM\CurrentControlSet\Control\Terminal Server', 1)
    ,@('HKLM', 'SYSTEM\CurrentControlSet\Control\StorageDevicePolicies', 1)
    ,@('HKLM', 'SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}', 2)
    ,@('HKLM', 'SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}', 2)
    ,@('HKLM', 'SYSTEM\CurrentControlSet\Services\Tcpip\Parameters', 2)
    ,@('HKLM', 'SYSTEM\CurrentControlSet\Services\AFD\Parameters', 1)
    ,@('HKLM', 'SYSTEM\CurrentControlSet\Services\Dnscache\Parameters', 1)
    ,@('HKLM', 'SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters', 1)
    ,@('HKLM', 'SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters', 1)
    ,@('HKLM', 'SYSTEM\CurrentControlSet\Services\NDIS\Parameters', 1)
    ,@('HKLM', 'SYSTEM\CurrentControlSet\Services\mouclass\Parameters', 1)
    ,@('HKLM', 'SYSTEM\CurrentControlSet\Services\kbdclass\Parameters', 1)
    ,@('HKLM', 'SYSTEM\CurrentControlSet\Services\stornvme\Parameters', 3)
    ,@('HKLM', 'SYSTEM\CurrentControlSet\Services\nvlddmkm', 3)
    ,@('HKLM', 'SYSTEM\CurrentControlSet\Services\USBHUB3\Parameters', 1)
    ,@('HKLM', 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment', 1)
    ,@('HKLM', 'SOFTWARE\NVIDIA Corporation', 3)
)

# значения в разделах Enum\PCI\...\Interrupt Management (MSI и привязка к ядрам)
$script:PciInterruptRoot = 'SYSTEM\CurrentControlSet\Enum\PCI'

function Open-HiveKey([string]$Hive, [string]$Sub) {
    $base = if ($Hive -eq 'HKCU') { [Microsoft.Win32.Registry]::CurrentUser } else { [Microsoft.Win32.Registry]::LocalMachine }
    try { return $base.OpenSubKey($Sub, $false) } catch { return $null }
}

function Format-RegValue($Value, $Kind) {
    if ($null -eq $Value) { return '' }
    if ($Value -is [byte[]]) {
        $n = [Math]::Min($Value.Length, 128)
        $hex = ($Value[0..([Math]::Max($n - 1, 0))] | ForEach-Object { '{0:x2}' -f $_ }) -join ''
        if ($Value.Length -gt 128) { $hex += ('…(+{0} байт)' -f ($Value.Length - 128)) }
        return $hex
    }
    if ($Value -is [string[]]) { return ($Value -join ' | ') }
    return [string]$Value
}

function Read-RegistryTree([string]$Hive, [string]$Sub, [int]$Depth, [hashtable]$Out) {
    $key = Open-HiveKey $Hive $Sub
    if (-not $key) { return }
    try {
        $names = @($key.GetValueNames())
        if (-not $names.Count) { $Out[('{0}\{1}|(ключ существует)' -f $Hive, $Sub)] = '' }
        foreach ($vn in $names) {
            try {
                $kind = $key.GetValueKind($vn)
                $val = $key.GetValue($vn, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $label = if ($vn -eq '') { '(по умолчанию)' } else { $vn }
                $Out[('{0}\{1}|{2}' -f $Hive, $Sub, $label)] = ('{0}:{1}' -f $kind, (Format-RegValue $val $kind))
            } catch { }
        }
        if ($Depth -gt 0) {
            foreach ($sk in @($key.GetSubKeyNames())) {
                Read-RegistryTree $Hive ($Sub + '\' + $sk) ($Depth - 1) $Out
            }
        }
    } catch { } finally { $key.Close() }
}

function Read-PciInterruptSettings([hashtable]$Out) {
    $root = Open-HiveKey 'HKLM' $script:PciInterruptRoot
    if (-not $root) { return }
    try {
        foreach ($dev in @($root.GetSubKeyNames())) {
            $devKey = $root.OpenSubKey($dev)
            if (-not $devKey) { continue }
            try {
                foreach ($inst in @($devKey.GetSubKeyNames())) {
                    $sub = '{0}\{1}\{2}\Device Parameters\Interrupt Management' -f $script:PciInterruptRoot, $dev, $inst
                    Read-RegistryTree 'HKLM' $sub 3 $Out
                }
            } finally { $devKey.Close() }
        }
    } finally { $root.Close() }
}

function Get-ServicesState {
    $o = [ordered]@{}
    foreach ($s in Get-CimInstance Win32_Service) {
        $mode = $s.StartMode
        if ($s.PSObject.Properties['DelayedAutoStart'] -and $s.DelayedAutoStart) { $mode += ' (отложенный)' }
        $o[$s.Name] = ('{0}; {1}' -f $mode, $s.PathName)
    }
    return $o
}

function Get-DriversState {
    $o = [ordered]@{}
    foreach ($d in Get-CimInstance Win32_SystemDriver) { $o[$d.Name] = ('{0}; {1}' -f $d.StartMode, $d.PathName) }
    return $o
}

function Get-TasksState {
    $o = [ordered]@{}
    try {
        foreach ($t in Get-ScheduledTask) {
            $o[($t.TaskPath + $t.TaskName)] = $(if ($t.Settings.Enabled) { 'включена' } else { 'выключена' })
        }
    } catch { $o['(ошибка чтения задач)'] = $_.Exception.Message }
    return $o
}

function Get-PowerState {
    $o = [ordered]@{}
    $active = (& powercfg /getactivescheme) -join ' '
    $o['активная схема'] = $active
    $o['список схем'] = ((& powercfg /list) -join ' | ')
    $guidRe = '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'
    $sub = ''; $setting = ''; $hex = New-Object System.Collections.ArrayList
    $flush = {
        if ($setting -and $hex.Count -ge 2) {
            $o[('{0} / {1}' -f $sub, $setting)] = ('от сети={0}; от батареи={1}' -f $hex[$hex.Count - 2], $hex[$hex.Count - 1])
        }
    }
    foreach ($line in @(& powercfg /qh)) {
        if ($line -match 'GUID' -and $line -match $guidRe) {
            $isSub = $line -match '(?i)subgroup|подгрупп'
            & $flush
            $hex.Clear()
            $name = ($line.Trim() -replace '\s+', ' ')
            if ($isSub) { $sub = $name; $setting = '' } else { $setting = $name }
        } elseif ($line -match '(0x[0-9a-fA-F]{8})\s*$') { [void]$hex.Add($Matches[1]) }
    }
    & $flush
    return $o
}

function Get-EnvState {
    $o = [ordered]@{}
    foreach ($scope in 'Machine', 'User') {
        $vars = [Environment]::GetEnvironmentVariables($scope)
        foreach ($k in ($vars.Keys | Sort-Object)) { $o[('{0}:{1}' -f $scope, $k)] = [string]$vars[$k] }
    }
    return $o
}

function Get-StartupFolders {
    $o = [ordered]@{}
    foreach ($p in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            foreach ($f in Get-ChildItem -LiteralPath $p -File -ErrorAction SilentlyContinue) { $o[$f.FullName] = [string]$f.Length }
        }
    }
    return $o
}

function Get-NvidiaState {
    $o = [ordered]@{}
    $drs = Join-Path $env:ProgramData 'NVIDIA Corporation\Drs'
    if (Test-Path -LiteralPath $drs) {
        foreach ($f in Get-ChildItem -LiteralPath $drs -File -ErrorAction SilentlyContinue) {
            try { $o[$f.Name] = ('{0} байт; sha256={1}' -f $f.Length, (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.Substring(0, 16)) } catch { }
        }
    } else { $o['(папка Drs не найдена)'] = 'видеокарта не NVIDIA или драйвер не установлен' }
    $o['профиль cs2.exe'] = 'побайтно не разбирается: если sha256 файлов выше изменился, профили NVIDIA менялись; детали — через экспорт в NVIDIA Profile Inspector (File → Export user-defined profiles) до и после'
    return $o
}

function Get-NetworkState {
    $o = [ordered]@{}
    try { $o['netsh tcp global'] = ((& netsh int tcp show global) -join ' | ') } catch { }
    try {
        foreach ($p in Get-NetAdapterAdvancedProperty -ErrorAction Stop) {
            $o[('адаптер {0} / {1}' -f $p.Name, $p.DisplayName)] = [string]$p.DisplayValue
        }
    } catch { }
    try { foreach ($q in Get-NetQosPolicy -ErrorAction Stop) { $o[('QoS ' + $q.Name)] = ('DSCP={0}; приложение={1}' -f $q.DSCPAction, $q.AppPathNameMatchCondition) } } catch { }
    return $o
}

function Get-OtherState {
    $o = [ordered]@{}
    try { $o['bcdedit {current}'] = ((& bcdedit /enum '{current}' 2>&1) -join ' | ') } catch { $o['bcdedit {current}'] = 'не прочитан (нужны права администратора)' }
    try {
        $mp = Get-MpPreference -ErrorAction Stop
        foreach ($n in 'DisableRealtimeMonitoring', 'DisableBehaviorMonitoring', 'DisableIOAVProtection', 'DisableScriptScanning', 'MAPSReporting', 'SubmitSamplesConsent', 'EnableControlledFolderAccess', 'PUAProtection') {
            $o[('Defender ' + $n)] = [string]$mp.$n
        }
    } catch { $o['Defender'] = 'не прочитан' }
    try { $o['hosts sha256'] = (Get-FileHash -LiteralPath (Join-Path $env:windir 'System32\drivers\etc\hosts') -Algorithm SHA256).Hash.Substring(0, 16) } catch { }
    return $o
}

function New-Snapshot {
    $reg = @{}
    foreach ($t in $script:RegistryTargets) { Read-RegistryTree $t[0] $t[1] $t[2] $reg }
    Read-PciInterruptSettings $reg
    $regSorted = [ordered]@{}
    foreach ($k in ($reg.Keys | Sort-Object)) { $regSorted[$k] = $reg[$k] }
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    return [ordered]@{
        meta = [ordered]@{ time = (Get-Date).ToString('s'); computer = $env:COMPUTERNAME; admin = $isAdmin; tool = 'pckit-diff'; schema = 1 }
        'Реестр' = $regSorted
        'Службы' = Get-ServicesState
        'Драйверы' = Get-DriversState
        'Задачи планировщика' = Get-TasksState
        'Электропитание' = Get-PowerState
        'Переменные среды' = Get-EnvState
        'Папки автозагрузки' = Get-StartupFolders
        'NVIDIA' = Get-NvidiaState
        'Сеть' = Get-NetworkState
        'Прочее' = Get-OtherState
    }
}

# ---- сравнение ----
$script:NoiseRe = 'UserAssist|RecentDocs|\\MRU|ComDlg32|Signature Updates|Defender\\Health|LastUpdate|BootId|\\Volatile|\\Notifications\\|TaskCache\\Tree|Uninstall\\[^|]+\|(EstimatedSize|InstallDate)|\|(LastBootUpTime|LastWrite|LastSuccess|LastRun)'

function Compare-Section($Before, $After, [bool]$Filter) {
    $res = New-Object System.Collections.ArrayList
    $names = New-Object System.Collections.Generic.HashSet[string]
    foreach ($o in @($Before, $After)) { if ($o) { foreach ($p in $o.PSObject.Properties) { [void]$names.Add($p.Name) } } }
    foreach ($n in ($names | Sort-Object)) {
        if ($Filter -and $n -match $script:NoiseRe) { continue }
        $b = if ($Before -and $Before.PSObject.Properties[$n]) { [string]$Before.$n } else { $null }
        $a = if ($After -and $After.PSObject.Properties[$n]) { [string]$After.$n } else { $null }
        if ($null -eq $b -and $null -ne $a) { [void]$res.Add(@('+', $n, '', $a)) }
        elseif ($null -ne $b -and $null -eq $a) { [void]$res.Add(@('-', $n, $b, '')) }
        elseif ($b -ne $a) { [void]$res.Add(@('~', $n, $b, $a)) }
    }
    return , $res
}

function Invoke-Compare([string]$BeforePath, [string]$AfterPath, [string]$ReportPath, [bool]$Filter) {
    $before = Get-Content -LiteralPath $BeforePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $after = Get-Content -LiteralPath $AfterPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('# Что изменилось между снимками')
    [void]$lines.Add(('до: {0} ({1}); после: {2} ({3})' -f $before.meta.time, (Split-Path $BeforePath -Leaf), $after.meta.time, (Split-Path $AfterPath -Leaf)))
    [void]$lines.Add('Обозначения: `+` добавлено, `-` удалено, `~` изменено.')
    if (-not $before.meta.admin -or -not $after.meta.admin) { [void]$lines.Add('**Внимание:** один из снимков сделан без прав администратора — часть данных (bcdedit, задачи) могла не прочитаться.') }
    $total = 0
    foreach ($section in ($before.PSObject.Properties.Name | Where-Object { $_ -ne 'meta' })) {
        $diff = Compare-Section $before.$section $after.$section $Filter
        if (-not $diff.Count) { continue }
        $total += $diff.Count
        [void]$lines.Add('')
        [void]$lines.Add(('## {0} ({1})' -f $section, $diff.Count))
        foreach ($d in $diff) {
            switch ($d[0]) {
                '+' { [void]$lines.Add(('- `+` {0} = {1}' -f $d[1], $d[3])) }
                '-' { [void]$lines.Add(('- `-` {0} (было {1})' -f $d[1], $d[2])) }
                '~' { [void]$lines.Add(('- `~` {0}: {1} → {2}' -f $d[1], $d[2], $d[3])) }
            }
        }
    }
    if (-not $total) { [void]$lines.Add(''); [void]$lines.Add('Отличий не найдено.') }
    $text = $lines -join "`r`n"
    if ($ReportPath) { [IO.File]::WriteAllText($ReportPath, $text, (New-Object System.Text.UTF8Encoding($true))); Write-Host ('отчёт: {0}' -f $ReportPath) -ForegroundColor Green }
    Write-Output $text
}

if ($PSCmdlet.ParameterSetName -eq 'Compare') {
    Invoke-Compare $Before $After $Report (-not $NoFilter)
    return
}
$snap = New-Snapshot
$json = $snap | ConvertTo-Json -Depth 6 -Compress
[IO.File]::WriteAllText($Snapshot, $json, (New-Object System.Text.UTF8Encoding($true)))
Write-Host ('снимок записан: {0} ({1} значений реестра, {2} служб, {3} задач, админ: {4})' -f $Snapshot, $snap.'Реестр'.Count, $snap.'Службы'.Count, $snap.'Задачи планировщика'.Count, $snap.meta.admin) -ForegroundColor Green
