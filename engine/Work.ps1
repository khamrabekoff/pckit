#Requires -Version 5.1
# pckit engine | work: режим «Для работы» — офис, Photoshop, AutoCAD, Revit и т. п.
# Находит установленные рабочие программы (data\work-apps.json), чистит их безопасные кэши,
# а крупное и спорное (журналы Revit, кэш OneDrive, Загрузки, установщики) только ПОКАЗЫВАЕТ с размером.

function Get-PckitWorkCatalog {
    $file = Join-Path (Split-Path -Parent $script:PckitEngineDir) 'data\work-apps.json'
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    $data = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    return @($data)
}

function Get-PckitWorkProfileIds {
    $file = Join-Path (Split-Path -Parent $script:PckitEngineDir) 'data\work-profile.json'
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    $data = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    return @($data.ids | ForEach-Object { [string]$_ })
}

# установленные программы: { Name, Location }
$script:PckitInstalledCache = $null

function Get-PckitInstalledPrograms {
    if ($script:PckitInstalledCache) { return $script:PckitInstalledCache }
    $list = New-Object System.Collections.ArrayList
    foreach ($root in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p -or -not $p.DisplayName) { continue }
            [void]$list.Add([pscustomobject]@{ Name = [string]$p.DisplayName; Location = [string]$p.InstallLocation })
        }
    }
    $script:PckitInstalledCache = $list.ToArray()
    return $script:PckitInstalledCache
}

# полный путь к exe: сначала «App Paths» (так его находит и сама Windows), потом папка установки
function Find-PckitAppExe {
    param([string]$Exe, [string[]]$Locations)
    foreach ($hive in 'HKLM:', 'HKCU:') {
        $k = '{0}\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\{1}' -f $hive, $Exe
        try {
            $v = (Get-Item -LiteralPath $k -ErrorAction Stop).GetValue('')
            if ($v) {
                $path = ([string]$v).Trim('"')
                if (Test-Path -LiteralPath $path) { return $path }
            }
        } catch { }
    }
    foreach ($loc in @($Locations | Where-Object { $_ } | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $loc)) { continue }
        $f = Get-ChildItem -LiteralPath $loc -Filter $Exe -File -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { return $f.FullName }
    }
    return $null
}

function Get-PckitDirSizeMb {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return 0 }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if (-not $sum) { return 0 }
    return [math]::Round($sum / 1MB, 1)
}

# какие рабочие программы есть: [{ Id, Title, Programs, Exes (полные пути), Caches, Reports, Note }]
function Get-PckitWorkApps {
    # -NoExe: для чистки пути к exe не нужны — не ищем их по папкам установки (это самое медленное)
    param($Installed, [switch]$NoExe)
    if (-not $Installed) { $Installed = @(Get-PckitInstalledPrograms) }
    $result = New-Object System.Collections.ArrayList
    foreach ($c in @(Get-PckitWorkCatalog)) {
        $hits = @($Installed | Where-Object { $_.Name -match [string]$c.match })
        # кэши мессенджеров и т. п. ищем и без записи в «Программах» (портативные версии)
        $caches = @(@($c.caches) | Where-Object { $_ -and (Test-Path -LiteralPath (Resolve-PckitPath ([string]$_.path))) })
        if (-not $hits.Count -and -not $caches.Count) { continue }
        $exes = New-Object System.Collections.ArrayList
        foreach ($e in @($(if ($NoExe) { @() } else { $c.exes }))) {
            $p = Find-PckitAppExe -Exe ([string]$e) -Locations @($hits | ForEach-Object { $_.Location })
            if ($p -and -not $exes.Contains($p)) { [void]$exes.Add($p) }
        }
        [void]$result.Add([pscustomobject]@{
                Id       = [string]$c.id
                Title    = [string]$c.title
                Programs = @($hits | ForEach-Object { $_.Name } | Sort-Object -Unique)
                Exes     = $exes.ToArray()
                Caches   = $caches
                Reports  = @($c.reports)
                Note     = [string]$c.note
            })
    }
    return $result.ToArray()
}

# цели для «Чистки»: безопасные кэши найденных рабочих программ
function Get-PckitWorkCleanTargets {
    param($Apps)
    if (-not $Apps) { $Apps = @(Get-PckitWorkApps -NoExe) }
    $targets = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($a in @($Apps)) {
        foreach ($c in @($a.Caches)) {
            $i++
            [void]$targets.Add([pscustomobject]@{
                    Id = ('work.{0}.{1}' -f $a.Id, $i); Group = 'Рабочие программы'; Title = [string]$c.title
                    What = ('Кэш, который программа соберёт заново. {0}' -f $a.Note).Trim()
                    Paths = @([string]$c.path); Risk = 'low'; Admin = $false; Kind = 'dir'; Note = $a.Note; Patterns = @(); Link = ''
                })
        }
    }
    return $targets.ToArray()
}

# крупное и спорное — только показать: [{ Title, Path, SizeMb, What }]
function Get-PckitWorkReports {
    param($Apps, [int]$MinMb = 200)
    if (-not $Apps) { $Apps = @(Get-PckitWorkApps -NoExe) }
    $rows = New-Object System.Collections.ArrayList

    foreach ($a in @($Apps)) {
        foreach ($r in @($a.Reports)) {
            if (-not $r) { continue }
            $base = Resolve-PckitPath ([string]$r.path)
            if (-not (Test-Path -LiteralPath $base)) { continue }
            $dirs = if ($r.dirName) {
                @(Get-ChildItem -LiteralPath $base -Directory -Recurse -Depth 2 -Filter ([string]$r.dirName) -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
            } else { @($base) }
            foreach ($d in $dirs) {
                $mb = Get-PckitDirSizeMb -Path $d
                if ($mb -lt 50) { continue }
                [void]$rows.Add([pscustomobject]@{ Title = [string]$r.title; Path = $d; SizeMb = $mb; What = [string]$r.what })
            }
        }
    }

    # «Загрузки»: старые установщики и вообще крупные файлы
    $dl = Join-Path $env:USERPROFILE 'Downloads'
    if (Test-Path -LiteralPath $dl) {
        $old = (Get-Date).AddDays(-30)
        $inst = @(Get-ChildItem -LiteralPath $dl -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.exe', '.msi', '.iso', '.zip', '.rar', '.7z' -and $_.LastWriteTime -lt $old })
        $instMb = [math]::Round((($inst | Measure-Object Length -Sum).Sum) / 1MB, 1)
        if ($instMb -ge $MinMb) {
            [void]$rows.Add([pscustomobject]@{ Title = ('Загрузки: старые установщики и архивы ({0} шт., старше 30 дней)' -f $inst.Count); Path = $dl; SizeMb = $instMb; What = 'Скачанные .exe/.msi/.iso/.zip, которые обычно уже не нужны. Посмотрите и удалите ненужное сами.' })
        }
        $allMb = Get-PckitDirSizeMb -Path $dl
        if ($allMb -ge 5120) {
            [void]$rows.Add([pscustomobject]@{ Title = 'Папка «Загрузки» целиком'; Path = $dl; SizeMb = $allMb; What = 'Больше 5 ГБ. Часто там лежат забытые видео и копии проектов.' })
        }
    }

    $wo = Join-Path $env:SystemDrive 'Windows.old'
    if (Test-Path -LiteralPath $wo) {
        [void]$rows.Add([pscustomobject]@{ Title = 'Предыдущая Windows (Windows.old)'; Path = 'ms-settings:storagepolicies'; SizeMb = -1; What = 'Обычно 10–25 ГБ. Удаляется в Параметры → Система → Память → Временные файлы. После удаления откатиться на прошлую Windows нельзя.' })
    }
    return @($rows | Sort-Object SizeMb -Descending)
}

# шаг действия «мощная видеокарта для рабочих программ»
function Invoke-PckitStepWorkGpu {
    param($Step, $Journal, [switch]$Run)
    $exes = @(Get-PckitWorkApps | ForEach-Object { $_.Exes } | Where-Object { $_ })
    if (-not $exes.Count) { return [pscustomobject]@{ Status = 'skip'; Message = 'рабочих программ с видеокартой не найдено'; Failed = 0 } }
    $path = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    $todo = @()
    foreach ($e in $exes) {
        $cur = Get-PckitRegState -Path $path -Name $e
        $txt = if ($cur.Exists) { [string]$cur.Value } else { '' }
        if ((Get-PckitKvValue -Text $txt -Key 'GpuPreference') -ne '2') { $todo += [pscustomobject]@{ Exe = $e; Text = $txt } }
    }
    if (-not $todo.Count) { return [pscustomobject]@{ Status = 'ok'; Message = 'уже так'; Failed = 0 } }
    if (-not $Run) { return [pscustomobject]@{ Status = 'dry'; Message = ('мощная видеокарта для: {0}' -f ((@($todo | ForEach-Object { Split-Path -Leaf $_.Exe })) -join ', ')); Failed = 0 } }
    $failed = 0; $msgs = @()
    foreach ($t in $todo) {
        try { Add-PckitRegTracked -Journal $Journal -Path $path -Name $t.Exe -Value (Set-PckitKvValue -Text $t.Text -Key 'GpuPreference' -Value '2') -Type 'String' }
        catch { $failed++; $msgs += $_.Exception.Message }
    }
    if ($failed) { return [pscustomobject]@{ Status = 'fail'; Message = ($msgs -join '; '); Failed = $failed } }
    return [pscustomobject]@{ Status = 'ok'; Message = ''; Failed = 0 }
}

function Test-PckitVerifyWorkGpu {
    $exes = @(Get-PckitWorkApps | ForEach-Object { $_.Exes } | Where-Object { $_ })
    if (-not $exes.Count) { return [pscustomobject]@{ Ok = $false; Detail = 'рабочих программ не найдено'; NotApplicable = $true } }
    $bad = @($exes | Where-Object {
            $cur = Get-PckitRegState -Path 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -Name $_
            -not $cur.Exists -or (Get-PckitKvValue -Text ([string]$cur.Value) -Key 'GpuPreference') -ne '2'
        })
    return [pscustomobject]@{ Ok = ($bad.Count -eq 0); Detail = ('программ: {0}, не закреплено: {1}' -f $exes.Count, $bad.Count); NotApplicable = $false }
}
