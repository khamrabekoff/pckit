#Requires -Version 5.1
# pckit engine | snapshot: честный замер ПК «до/после» + HTML-отчёт сравнения
# Только чтение: счётчики (CIM, не локализуются), журнал загрузок, реестр, ping до 1.1.1.1 и 8.8.8.8.
# Ничего в системе не меняет. Снимки пишет только в %LOCALAPPDATA%\pckit\snapshots.

# папка снимков можно подменить (тесты): $script:PckitSnapshotDir = '...'
$script:PckitSnapshotDir = $null

# ---------- статистика ----------
function Get-PckitPercentile {
    param($Values, [double]$P)
    $v = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object)
    if (-not $v.Count) { return $null }
    if ($v.Count -eq 1) { return $v[0] }
    $pos = ($v.Count - 1) * $P
    $lo = [math]::Floor($pos); $hi = [math]::Ceiling($pos)
    return ($v[$lo] + ($v[$hi] - $v[$lo]) * ($pos - $lo))
}

function Get-PckitMedian { param($Values) return (Get-PckitPercentile -Values $Values -P 0.5) }

function Get-PckitIqr {
    param($Values)
    $q1 = Get-PckitPercentile -Values $Values -P 0.25
    $q3 = Get-PckitPercentile -Values $Values -P 0.75
    if ($null -eq $q1 -or $null -eq $q3) { return 0 }
    return ($q3 - $q1)
}

function Get-PckitStdDev {
    param($Values)
    $v = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if ($v.Count -lt 2) { return 0 }
    $avg = ($v | Measure-Object -Average).Average
    $sum = 0.0
    foreach ($x in $v) { $sum += ($x - $avg) * ($x - $avg) }
    return [math]::Sqrt($sum / $v.Count)
}

# ---------- папки ----------
function Get-PckitSnapshotDir {
    if ($script:PckitSnapshotDir) { return $script:PckitSnapshotDir }
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = Join-Path $env:USERPROFILE 'AppData\Local' }
    return (Join-Path $base 'pckit\snapshots')
}

# ---------- автозагрузка ----------
function Test-PckitStartupApproved {
    # нет записи = включено; первый байт чётный (02/06) = включено, нечётный (03...) = выключено
    param([string]$SubKey, [string]$Name)
    foreach ($hive in 'HKCU', 'HKLM') {
        try {
            $key = Get-Item -LiteralPath ('{0}:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\{1}' -f $hive, $SubKey) -ErrorAction Stop
            $val = $key.GetValue($Name, $null)
            if ($val -is [byte[]] -and $val.Length -gt 0 -and (($val[0] -band 1) -eq 1)) { return $false }
        } catch { }
    }
    return $true
}

function Get-PckitStartupItems {
    $items = New-Object System.Collections.ArrayList
    $runKeys = @(
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = 'Run'; Tag = 'HKCU' },
        @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = 'Run'; Tag = 'HKLM' },
        @{ Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'Run32'; Tag = 'HKLM32' }
    )
    foreach ($rk in $runKeys) {
        try {
            $key = Get-Item -LiteralPath $rk.Path -ErrorAction Stop
            foreach ($n in $key.GetValueNames()) {
                if (-not $n) { continue }
                if (Test-PckitStartupApproved -SubKey $rk.Approved -Name $n) { [void]$items.Add(('{0} [{1}]' -f $n, $rk.Tag)) }
            }
        } catch { }
    }
    foreach ($folder in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))) {
        if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue)) {
            if ($f.Name -ieq 'desktop.ini') { continue }
            if (Test-PckitStartupApproved -SubKey 'StartupFolder' -Name $f.Name) { [void]$items.Add(('{0} [папка]' -f $f.Name)) }
        }
    }
    # без «запятой»: вызывающий код делает @(...) сам, иначе Count всегда был бы 1
    return @($items)
}

# ---------- замер ----------
function Get-PckitSnapshot {
    param(
        [string]$Label = 'снимок',
        [int]$Samples = 10,
        [int]$IntervalSeconds = 2,
        [switch]$NoPing
    )
    $errors = New-Object System.Collections.ArrayList
    $snap = [ordered]@{
        Time = (Get-Date).ToString('s'); Label = $Label; Computer = $env:COMPUTERNAME
        OsBuild = $null; PowerPlan = $null; FreeSpaceMb = $null; Processes = $null; ServicesRunning = $null
        Startup = $null; Cpu = $null; Dpc = $null; Interrupt = $null; DpcPerSec = $null; RamUsedMb = $null
        Boot = $null; Ping = $null; Errors = @()
    }

    try { $snap.OsBuild = [string](Get-CimInstance Win32_OperatingSystem).BuildNumber } catch { [void]$errors.Add("OsBuild: $($_.Exception.Message)") }

    try {
        $raw = (& powercfg /getactivescheme 2>$null | Out-String).Trim()
        if ($raw -match '\(([^)]+)\)\s*$') { $snap.PowerPlan = $Matches[1].Trim() }
        elseif ($raw) { $snap.PowerPlan = $raw }
    } catch { [void]$errors.Add("PowerPlan: $($_.Exception.Message)") }

    try {
        $sysDrive = $env:SystemDrive.Substring(0, 1)
        $d = Get-PSDrive -Name $sysDrive -ErrorAction Stop
        $snap.FreeSpaceMb = [math]::Round($d.Free / 1MB, 0)
    } catch { [void]$errors.Add("FreeSpaceMb: $($_.Exception.Message)") }

    try { $snap.Processes = @(Get-Process).Count } catch { [void]$errors.Add("Processes: $($_.Exception.Message)") }
    try { $snap.ServicesRunning = @(Get-Service | Where-Object { $_.Status -eq 'Running' }).Count } catch { [void]$errors.Add("Services: $($_.Exception.Message)") }

    try {
        $st = @(Get-PckitStartupItems)
        $snap.Startup = [pscustomobject]@{ Count = $st.Count; Items = $st }
    } catch { [void]$errors.Add("Startup: $($_.Exception.Message)") }

    # CPU / DPC / прерывания / ОЗУ: Win32_PerfFormattedData_* и Win32_OperatingSystem не локализуются
    $cpu = New-Object System.Collections.ArrayList; $dpc = New-Object System.Collections.ArrayList
    $irq = New-Object System.Collections.ArrayList; $dpcs = New-Object System.Collections.ArrayList
    $ram = New-Object System.Collections.ArrayList
    try {
        if ($Samples -lt 1) { $Samples = 1 }
        [void](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop) # прогрев
        for ($i = 0; $i -lt $Samples; $i++) {
            if ($i -gt 0 -or $IntervalSeconds -gt 0) { Start-Sleep -Seconds ([math]::Max(1, $IntervalSeconds)) }
            try {
                $p = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
                [void]$cpu.Add([double]$p.PercentProcessorTime); [void]$dpc.Add([double]$p.PercentDPCTime)
                [void]$irq.Add([double]$p.PercentInterruptTime); [void]$dpcs.Add([double]$p.DPCsQueuedPersec)
            } catch { [void]$errors.Add("CPU sample: $($_.Exception.Message)") }
            try {
                $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
                [void]$ram.Add([math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1024, 0))
            } catch { [void]$errors.Add("RAM sample: $($_.Exception.Message)") }
        }
    } catch { [void]$errors.Add("Counters: $($_.Exception.Message)") }
    if ($cpu.Count) {
        $snap.Cpu = [pscustomobject]@{ Median = [math]::Round((Get-PckitMedian $cpu), 2); P95 = [math]::Round((Get-PckitPercentile $cpu 0.95), 2); Samples = @($cpu) }
        $snap.Dpc = [pscustomobject]@{ Median = [math]::Round((Get-PckitMedian $dpc), 2); Samples = @($dpc) }
        $snap.Interrupt = [pscustomobject]@{ Median = [math]::Round((Get-PckitMedian $irq), 2); Samples = @($irq) }
        $snap.DpcPerSec = [pscustomobject]@{ Median = [math]::Round((Get-PckitMedian $dpcs), 0) }
    }
    if ($ram.Count) { $snap.RamUsedMb = [pscustomobject]@{ Median = [math]::Round((Get-PckitMedian $ram), 0); Samples = @($ram) } }

    # время загрузки (Diagnostics-Performance, Id 100) — без прав журнал может быть недоступен
    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 5 -ErrorAction Stop)
        $times = New-Object System.Collections.ArrayList
        foreach ($e in $events) {
            $xml = [xml]$e.ToXml()
            $node = $xml.Event.EventData.Data | Where-Object { $_.Name -eq 'BootTime' } | Select-Object -First 1
            if ($node) { [void]$times.Add([double]$node.'#text') }
        }
        if ($times.Count) {
            $snap.Boot = [pscustomobject]@{ Last = @($times); Median = [math]::Round((Get-PckitMedian $times), 0); LastAt = $events[0].TimeCreated.ToString('s'); Available = $true }
        } else {
            $snap.Boot = [pscustomobject]@{ Last = @(); Median = $null; LastAt = $null; Available = $false }
        }
    } catch {
        $snap.Boot = [pscustomobject]@{ Last = @(); Median = $null; LastAt = $null; Available = $false }
    }

    if (-not $NoPing) {
        try {
            $pings = New-Object System.Collections.ArrayList
            $png = New-Object System.Net.NetworkInformation.Ping
            foreach ($h in '1.1.1.1', '8.8.8.8') {
                $rtt = New-Object System.Collections.ArrayList; $lost = 0; $count = 20
                for ($i = 0; $i -lt $count; $i++) {
                    try {
                        $r = $png.Send($h, 1000)
                        if ($r.Status -eq 'Success') { [void]$rtt.Add([double]$r.RoundtripTime) } else { $lost++ }
                    } catch { $lost++ }
                    Start-Sleep -Milliseconds 50
                }
                if ($rtt.Count) {
                    $m = $rtt | Measure-Object -Minimum -Maximum -Average
                    [void]$pings.Add([pscustomobject]@{ Host = $h; Min = $m.Minimum; Avg = [math]::Round($m.Average, 1); Max = $m.Maximum
                            Jitter = [math]::Round((Get-PckitStdDev $rtt), 1); LossPct = [math]::Round(100.0 * $lost / $count, 0) })
                } else {
                    [void]$pings.Add([pscustomobject]@{ Host = $h; Min = $null; Avg = $null; Max = $null; Jitter = $null; LossPct = 100 })
                }
            }
            $snap.Ping = @($pings)
        } catch { [void]$errors.Add("Ping: $($_.Exception.Message)") }
    }

    $snap.Errors = @($errors)
    return [pscustomobject]$snap
}

# ---------- хранение ----------
function Save-PckitSnapshot {
    param($Snapshot)
    $dir = Get-PckitSnapshotDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $label = ([string]$Snapshot.Label -replace '[\\/:*?"<>|\s]+', '_').Trim('_')
    if (-not $label) { $label = 'snapshot' }
    $path = Join-Path $dir ('{0}-{1}.json' -f (Get-Date).ToString('yyyyMMdd-HHmmss'), $label)
    $json = $Snapshot | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function Read-PckitSnapshot {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-PckitSnapshots {
    $dir = Get-PckitSnapshotDir
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $list = New-Object System.Collections.ArrayList
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $s = Read-PckitSnapshot -Path $f.FullName
            $t = ConvertTo-PckitDate $s.Time
            if (-not $t) { $t = $f.LastWriteTime }
            [void]$list.Add([pscustomobject]@{ Path = $f.FullName; Time = $t; Label = [string]$s.Label })
        } catch { }
    }
    return @($list | Sort-Object -Property Time -Descending)
}

function ConvertTo-PckitDate {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value }
    $out = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$out)) { return $out }
    return $null
}

# ---------- сравнение ----------
$script:PckitRu = [Globalization.CultureInfo]::GetCultureInfo('ru-RU')

function Format-PckitNum {
    param($Value, [string]$Fmt = 'N1')
    if ($null -eq $Value) { return '—' }
    return ([double]$Value).ToString($Fmt, $script:PckitRu)
}

function Format-PckitMb {
    param($Mb)
    if ($null -eq $Mb) { return '—' }
    if ([math]::Abs([double]$Mb) -ge 1024) { return ('{0} ГБ' -f (Format-PckitNum ([double]$Mb / 1024) 'N1')) }
    return ('{0} МБ' -f (Format-PckitNum $Mb 'N0'))
}

function Format-PckitDeltaText {
    param($Delta, [scriptblock]$Fmt)
    if ($null -eq $Delta) { return '—' }
    $text = & $Fmt ([math]::Abs([double]$Delta))
    if ([double]$Delta -gt 0) { return "+$text" }
    if ([double]$Delta -lt 0) { return "−$text" }
    return $text
}

function New-PckitCompareRow {
    param([string]$Metric, $BeforeValue, $AfterValue, [string]$Before, [string]$After, [string]$Delta, [string]$Verdict, [string]$Note = '')
    return [pscustomobject]@{ Metric = $Metric; Before = $Before; After = $After; Delta = $Delta; Verdict = $Verdict; Note = $Note; BeforeValue = $BeforeValue; AfterValue = $AfterValue }
}

function Get-PckitExactRow {
    # точные метрики: любое изменение — факт. HigherIsBetter задаёт направление
    param([string]$Metric, $B, $A, [bool]$HigherIsBetter, [scriptblock]$Fmt, [string]$Note = '')
    if ($null -eq $B -or $null -eq $A) {
        return New-PckitCompareRow $Metric $B $A '—' '—' '—' 'нет данных' $Note
    }
    $d = [double]$A - [double]$B
    if ($d -eq 0) { $v = 'без изменений' }
    elseif (($d -gt 0) -eq $HigherIsBetter) { $v = 'лучше' } else { $v = 'хуже' }
    return New-PckitCompareRow $Metric $B $A (& $Fmt ([double]$B)) (& $Fmt ([double]$A)) (Format-PckitDeltaText $d $Fmt) $v $Note
}

function Get-PckitBandRow {
    # точная, но «живая» метрика (меньше = лучше): изменение в пределах ±Band — шум
    param([string]$Metric, $B, $A, [double]$Band, [scriptblock]$Fmt, [string]$Note = '')
    if ($null -eq $B -or $null -eq $A) {
        return New-PckitCompareRow $Metric $B $A '—' '—' '—' 'нет данных' $Note
    }
    $d = [double]$A - [double]$B
    if ($d -eq 0) { $v = 'без изменений' }
    elseif ([math]::Abs($d) -le $Band) { $v = 'в пределах шума' }
    elseif ($d -lt 0) { $v = 'лучше' } else { $v = 'хуже' }
    return New-PckitCompareRow $Metric $B $A (& $Fmt ([double]$B)) (& $Fmt ([double]$A)) (Format-PckitDeltaText $d $Fmt) $v $Note
}
function Get-PckitNoisyRow {
    # шумные метрики (меньше = лучше): значимо только если |Delta| > max(2*IQR «до», минимум)
    param([string]$Metric, $BMedian, $AMedian, $BSamples, [double]$MinThreshold, [scriptblock]$Fmt, [string]$Note = '')
    if ($null -eq $BMedian -or $null -eq $AMedian) {
        return New-PckitCompareRow $Metric $BMedian $AMedian '—' '—' '—' 'нет данных' $Note
    }
    $d = [double]$AMedian - [double]$BMedian
    $thr = [math]::Max(2 * (Get-PckitIqr $BSamples), $MinThreshold)
    if ([math]::Abs($d) -gt $thr) { if ($d -lt 0) { $v = 'лучше' } else { $v = 'хуже' } } else { $v = 'в пределах шума' }
    $n = ('порог шума ±{0}' -f (& $Fmt $thr))
    if ($Note) { $n = "$Note; $n" }
    return New-PckitCompareRow $Metric $BMedian $AMedian (& $Fmt ([double]$BMedian)) (& $Fmt ([double]$AMedian)) (Format-PckitDeltaText $d $Fmt) $v $n
}

function Compare-PckitSnapshot {
    param($Before, $After)
    $rows = New-Object System.Collections.ArrayList
    $fmtMb = { param($x) Format-PckitMb $x }
    $fmtInt = { param($x) Format-PckitNum $x 'N0' }
    $fmtPct = { param($x) ('{0} %' -f (Format-PckitNum $x 'N1')) }
    $fmtPct2 = { param($x) ('{0} %' -f (Format-PckitNum $x 'N2')) }
    $fmtMs = { param($x) ('{0} мс' -f (Format-PckitNum $x 'N0')) }
    $fmtMs1 = { param($x) ('{0} мс' -f (Format-PckitNum $x 'N1')) }
    $fmtPerSec = { param($x) ('{0} /с' -f (Format-PckitNum $x 'N0')) }

    # точные
    [void]$rows.Add((Get-PckitExactRow 'Свободно на системном диске' $Before.FreeSpaceMb $After.FreeSpaceMb $true $fmtMb 'факт'))
    [void]$rows.Add((Get-PckitExactRow 'Элементов автозагрузки' $Before.Startup.Count $After.Startup.Count $false $fmtInt 'факт'))
    # число процессов и служб само гуляет (обновления, браузер, драйверы) — мелкую разницу считаем шумом
    [void]$rows.Add((Get-PckitBandRow 'Процессов' $Before.Processes $After.Processes 10 $fmtInt 'само колеблется на ±10'))
    [void]$rows.Add((Get-PckitBandRow 'Запущено служб' $Before.ServicesRunning $After.ServicesRunning 4 $fmtInt 'службы стартуют по требованию: ±4 — норма'))

    # шумные
    [void]$rows.Add((Get-PckitNoisyRow 'Загрузка CPU в простое' $Before.Cpu.Median $After.Cpu.Median $Before.Cpu.Samples 1 $fmtPct 'шумная метрика'))
    [void]$rows.Add((Get-PckitNoisyRow 'Время в DPC' $Before.Dpc.Median $After.Dpc.Median $Before.Dpc.Samples 0.3 $fmtPct2 'шумная метрика'))
    [void]$rows.Add((Get-PckitNoisyRow 'Время в прерываниях' $Before.Interrupt.Median $After.Interrupt.Median $Before.Interrupt.Samples 0.3 $fmtPct2 'шумная метрика'))
    [void]$rows.Add((Get-PckitNoisyRow 'ОЗУ занято в простое' $Before.RamUsedMb.Median $After.RamUsedMb.Median $Before.RamUsedMb.Samples 150 $fmtMb 'шумная метрика'))

    # загрузка
    $bb = $Before.Boot; $ab = $After.Boot
    $bAt = ConvertTo-PckitDate $bb.LastAt; $aAt = ConvertTo-PckitDate $ab.LastAt
    $bLast = @($ab.Last) | Where-Object { $null -ne $_ } | Select-Object -First 1
    if (-not $bb -or -not $ab -or -not $bb.Available -or -not $ab.Available -or $null -eq $bb.Median -or $null -eq $bLast) {
        [void]$rows.Add((New-PckitCompareRow 'Время загрузки Windows' $null $null '—' '—' '—' 'нет данных' 'журнал загрузок недоступен (возможно, нужны права администратора)'))
    } elseif ($aAt -and $bAt -and $aAt -le $bAt) {
        [void]$rows.Add((New-PckitCompareRow 'Время загрузки Windows' $bb.Median $null (& $fmtMs $bb.Median) 'не измерено' '—' 'нужна перезагрузка' 'после замера «до» ПК ещё не перезагружали — новой записи о загрузке нет'))
    } else {
        $d = [double]$bLast - [double]$bb.Median
        $thr = 0.10 * [double]$bb.Median
        if ([math]::Abs($d) -gt $thr) { if ($d -lt 0) { $v = 'лучше' } else { $v = 'хуже' } } else { $v = 'в пределах шума' }
        [void]$rows.Add((New-PckitCompareRow 'Время загрузки Windows' $bb.Median $bLast (& $fmtMs $bb.Median) (& $fmtMs $bLast) (Format-PckitDeltaText $d $fmtMs) $v 'последняя загрузка против медианы «до»; шум ±10%'))
    }

    # пинг — контроль
    $pingNote = 'контроль: зависит от провайдера, а не от настроек ПК'
    foreach ($bp in @($Before.Ping)) {
        if (-not $bp) { continue }
        $ap = @($After.Ping) | Where-Object { $_ -and $_.Host -eq $bp.Host } | Select-Object -First 1
        foreach ($m in @(@('Avg', 'среднее'), @('Jitter', 'джиттер'))) {
            $name = ('Пинг {0}, {1}' -f $bp.Host, $m[1])
            $bv = $bp.($m[0]); $av = $null
            if ($ap) { $av = $ap.($m[0]) }
            if ($null -eq $bv -or $null -eq $av) { [void]$rows.Add((New-PckitCompareRow $name $bv $av '—' '—' '—' 'нет данных' $pingNote)); continue }
            $d = [double]$av - [double]$bv
            if ([math]::Abs($d) -gt 3) { if ($d -lt 0) { $v = 'лучше' } else { $v = 'хуже' } } else { $v = 'в пределах шума' }
            [void]$rows.Add((New-PckitCompareRow $name $bv $av (& $fmtMs1 $bv) (& $fmtMs1 $av) (Format-PckitDeltaText $d $fmtMs1) $v $pingNote))
        }
    }

    # схема питания — информативно
    if ($Before.PowerPlan -or $After.PowerPlan) {
        if ([string]$Before.PowerPlan -eq [string]$After.PowerPlan) { $v = 'без изменений'; $n = '' } else { $v = 'изменено'; $n = 'схема питания другая — это настройка, а не результат замера; сравнение остальных строк менее честное' }
        [void]$rows.Add((New-PckitCompareRow 'Схема питания' $Before.PowerPlan $After.PowerPlan ([string]$Before.PowerPlan) ([string]$After.PowerPlan) '—' $v $n))
    }
    return @($rows)
}

# ---------- HTML-отчёт ----------
function Save-PckitCompareReport {
    param($Before, $After, $Rows, $Fps, [string]$OutDir)
    if (-not $Rows) { $Rows = Compare-PckitSnapshot -Before $Before -After $After }
    if (-not $OutDir) { $OutDir = Join-Path $env:USERPROFILE 'Documents\pckit\Отчёты' }
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $cls = @{ 'лучше' = 'good'; 'хуже' = 'bad'; 'без изменений' = 'neutral'; 'в пределах шума' = 'neutral'; 'нужна перезагрузка' = 'warn'; 'нет данных' = 'neutral'; 'изменено' = 'info' }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!doctype html><html lang="ru"><head><meta charset="utf-8">')
    [void]$sb.AppendLine('<title>pckit by odilbek — сравнение до/после</title><style>')
    [void]$sb.AppendLine('body{font-family:"Segoe UI",Arial,sans-serif;max-width:980px;margin:24px auto;padding:0 16px;color:#222;line-height:1.45}')
    [void]$sb.AppendLine('h1{font-size:22px;margin:0 0 4px} h2{font-size:15px;margin:26px 0 8px;color:#444} .muted{color:#777;font-size:13px}')
    [void]$sb.AppendLine('table{border-collapse:collapse;width:100%;font-size:14px} th{text-align:left;color:#555;font-weight:600;border-bottom:2px solid #ddd;padding:6px 8px}')
    [void]$sb.AppendLine('td{padding:7px 8px;border-bottom:1px solid #eee;vertical-align:top} td.note{color:#777;font-size:12px}')
    [void]$sb.AppendLine('.good{color:#1e7832;font-weight:600} .bad{color:#b42828;font-weight:600} .warn{color:#a06e0f;font-weight:600} .info{color:#1e6496;font-weight:600} .neutral{color:#777}')
    [void]$sb.AppendLine('.box{background:#f6f6f6;border-radius:6px;padding:10px 16px;font-size:13px} .box li{margin:4px 0}')
    [void]$sb.AppendLine('</style></head><body>')
    [void]$sb.AppendLine('<h1>pckit by odilbek — сравнение до/после</h1>')
    [void]$sb.AppendLine(('<p class="muted">До: {0} ({1}) · После: {2} ({3}) · отчёт создан {4}</p>' -f `
                (& $enc $Before.Time), (& $enc $Before.Label), (& $enc $After.Time), (& $enc $After.Label), (Get-Date).ToString('dd.MM.yyyy HH:mm')))

    [void]$sb.AppendLine('<h2>Метрики</h2><table><tr><th>Метрика</th><th>До</th><th>После</th><th>Изменение</th><th>Вердикт</th><th>Примечание</th></tr>')
    foreach ($r in @($Rows)) {
        $c = $cls[[string]$r.Verdict]; if (-not $c) { $c = 'neutral' }
        [void]$sb.AppendLine(('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td class="{4}">{5}</td><td class="note">{6}</td></tr>' -f `
                    (& $enc $r.Metric), (& $enc $r.Before), (& $enc $r.After), (& $enc $r.Delta), $c, (& $enc $r.Verdict), (& $enc $r.Note)))
    }
    [void]$sb.AppendLine('</table>')

    if ($Fps -and $Fps.Before -and $Fps.After) {
        $fb = $Fps.Before; $fa = $Fps.After
        [void]$sb.AppendLine('<h2>FPS (замер PresentMon)</h2><table><tr><th>Показатель</th><th>До</th><th>После</th><th>Изменение</th></tr>')
        $defs = @(
            @('Средний FPS', 'AvgFps', 'N1', $true), @('1% low, FPS', 'Low1Fps', 'N1', $true), @('0,1% low, FPS', 'Low01Fps', 'N1', $true),
            @('Время кадра p99, мс', 'P99FrameMs', 'N2', $false), @('Кадров в замере', 'Frames', 'N0', $true)
        )
        foreach ($d in $defs) {
            $bv = $fb.($d[1]); $av = $fa.($d[1])
            $delta = '—'; $c = 'neutral'
            if ($null -ne $bv -and $null -ne $av) {
                $diff = [double]$av - [double]$bv
                $delta = (Format-PckitNum $diff $d[2]); if ($diff -gt 0) { $delta = "+$delta" }
                if ($d[1] -ne 'Frames' -and [double]$bv -ne 0 -and [math]::Abs($diff / [double]$bv) -gt 0.02) {
                    if (($diff -gt 0) -eq $d[3]) { $c = 'good' } else { $c = 'bad' }
                }
            }
            [void]$sb.AppendLine(('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td class="{3}">{4}</td></tr>' -f (& $enc $d[0]), (& $enc (Format-PckitNum $bv $d[2])), (& $enc (Format-PckitNum $av $d[2])), $c, (& $enc $delta)))
        }
        [void]$sb.AppendLine('</table><p class="muted">Изменение меньше 2% не подсвечивается: разброс между двумя прогонами в игре обычно такого же порядка.</p>')
    }

    [void]$sb.AppendLine('<h2>Как читать честно</h2><div class="box"><ul>')
    [void]$sb.AppendLine('<li><b>Место на диске и автозагрузка</b> — факты: число либо изменилось, либо нет.</li>')
    [void]$sb.AppendLine('<li><b>ОЗУ, CPU, DPC и прерывания в простое</b> — шумные метрики. Меньше порога шума — это не улучшение и не ухудшение.</li>')
    [void]$sb.AppendLine('<li><b>Время загрузки</b> появляется только после перезагрузки; одна загрузка сильно зависит от того, что запускалось рядом.</li>')
    [void]$sb.AppendLine('<li><b>FPS</b> — только по замеру PresentMon в одной и той же сцене. Без замера мы про FPS ничего не утверждаем.</li>')
    [void]$sb.AppendLine('<li><b>Пинг</b> — контроль: он зависит от провайдера, а не от настроек ПК.</li>')
    [void]$sb.AppendLine('<li>Фраз вроде «ускорено на X%» здесь нет намеренно: их нельзя честно получить без замера.</li>')
    [void]$sb.AppendLine('</ul></div></body></html>')

    $file = Join-Path $OutDir ('Сравнение-{0}.html' -f (Get-Date).ToString('yyyyMMdd-HHmm'))
    [IO.File]::WriteAllText($file, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    return $file
}
