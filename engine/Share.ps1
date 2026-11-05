#Requires -Version 5.1
# pckit engine | share: «отчёт для друга» — всё о ПК одним HTML-файлом, чтобы помочь удалённо.
# Без личного: нет имени пользователя и ПК, путей к профилю, IP-адресов, паролей, файлов.

function ConvertTo-PckitHtml {
    param([string]$Text)
    return [System.Net.WebUtility]::HtmlEncode([string]$Text)
}

function Format-PckitShareRow {
    param([string]$Name, [string]$Value, [string]$Cls = '')
    return ('<tr class="{2}"><th>{0}</th><td>{1}</td></tr>' -f (ConvertTo-PckitHtml $Name), (ConvertTo-PckitHtml $Value), $Cls)
}

# убираем из текста имя пользователя и путь к его профилю
function Hide-PckitPersonal {
    param([string]$Text)
    if (-not $Text) { return $Text }
    $t = $Text
    if ($env:USERPROFILE) { $t = $t.Replace($env:USERPROFILE, '%USERPROFILE%') }
    # имя пользователя — только как папка профиля (\Users\имя), иначе короткие имена вроде «user» портят обычные слова
    if ($env:USERNAME) { $t = $t -replace ('(?i)\\Users\\' + [regex]::Escape($env:USERNAME) + '(?=\\|\b|$)'), '\Users\<пользователь>' }
    if ($env:COMPUTERNAME) { $t = $t -replace ('(?i)(?<![\w-])' + [regex]::Escape($env:COMPUTERNAME) + '(?![\w-])'), '<ПК>' }
    return $t
}

function New-PckitShareReport {
    param(
        $Hw,
        $Health,
        $ActionStates,      # Get-PckitActionsState
        $Plan,              # Get-PckitSmartPlan
        [int]$JournalCount = 0,
        $Network,           # Invoke-PckitNetworkTest (или $null)
        $FpsBefore,
        $FpsAfter,
        $Driver             # Get-PckitDriverCheck (или $null)
    )

    $sb = New-Object System.Text.StringBuilder
    $add = { param($s) [void]$sb.AppendLine($s) }

    & $add '<!DOCTYPE html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
    & $add '<title>pckit — отчёт о ПК</title><style>'
    & $add 'body{font-family:"Segoe UI",Arial,sans-serif;background:#f6f7f9;color:#1d1d22;margin:0;padding:24px;line-height:1.45}'
    & $add '.wrap{max-width:980px;margin:0 auto}h1{font-size:24px;margin:0 0 4px}h2{font-size:17px;margin:28px 0 8px}'
    & $add '.muted{color:#6b6b76;font-size:13px}.card{background:#fff;border:1px solid #e3e3ea;border-radius:10px;padding:14px 18px;margin:8px 0}'
    & $add 'table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #eee;vertical-align:top;font-size:14px}th{width:34%;font-weight:600;color:#44444e}'
    & $add '.bad td,.bad th{color:#b4282a}.warn td,.warn th{color:#9a6a0a}.ok td,.ok th{color:#1e7a32}.info td,.info th{color:#2b2b33}'
    & $add '.pill{display:inline-block;padding:2px 10px;border-radius:12px;font-size:13px;margin:2px 4px 2px 0;background:#eef1f6}'
    & $add '</style></head><body><div class="wrap">'
    & $add ('<h1>Отчёт о ПК</h1><div class="muted">Создан программой pckit by odilbek · {0}. Личных данных в отчёте нет: ни имён, ни файлов, ни паролей.</div>' -f (Get-Date).ToString('dd.MM.yyyy HH:mm'))

    # ---- коротко
    $bad = 0; $warn = 0
    if ($Health) { $bad = [int]$Health.Bad; $warn = [int]$Health.Warn }
    $summary = if ($bad) { ('Есть проблемы: {0}, предупреждений: {1}' -f $bad, $warn) } elseif ($warn) { ('Предупреждений: {0}, критичного нет' -f $warn) } else { 'Серьёзных замечаний нет' }
    & $add ('<div class="card"><b>{0}</b><br>{1}</div>' -f (ConvertTo-PckitHtml (Format-PckitHardwareLine $Hw)), (ConvertTo-PckitHtml $summary))

    # ---- железо
    & $add '<h2>Железо и система</h2><div class="card"><table>'
    & $add (Format-PckitShareRow 'Видеокарта' $Hw.GpuName)
    $drv = [string]$Hw.GpuDriverVersion
    if ($Hw.GpuVendor -eq 'nvidia') { $nv = ConvertTo-PckitNvidiaVersion -WindowsVersion $Hw.GpuDriverVersion; if ($nv) { $drv = ('{0} ({1})' -f $nv, $Hw.GpuDriverVersion) } }
    if ($Hw.GpuDriverDate) { try { $drv += ' от ' + ([datetime]$Hw.GpuDriverDate).ToString('dd.MM.yyyy') } catch { } }
    $drvCls = ''
    if ($Driver -and $Driver.Status -eq 'outdated') { $drv += (' — есть новее: {0}' -f $Driver.Latest.Version); $drvCls = 'warn' }
    elseif ($Driver -and $Driver.Status -eq 'ok') { $drv += ' — последний'; $drvCls = 'ok' }
    & $add (Format-PckitShareRow 'Драйвер видеокарты' $drv $drvCls)
    if ($Hw.HybridGpu) { & $add (Format-PckitShareRow 'Две видеокарты' ((@($Hw.GpuList) | ForEach-Object { $_.Name }) -join ' + ')) }
    & $add (Format-PckitShareRow 'Процессор' ('{0} · {1} ядер / {2} потоков' -f $Hw.CpuName, $Hw.CpuCores, $Hw.CpuThreads))
    $ram = ('{0} ГБ' -f $Hw.RamGb)
    if ($Hw.RamType) { $ram += (' {0}' -f $Hw.RamType) }
    if ($Hw.RamMhz) { $ram += (', работает на {0} МГц (паспорт {1})' -f $Hw.RamMhz, $Hw.RamRatedMhz) }
    $ram += (', планок: {0}' -f $Hw.RamModules)
    & $add (Format-PckitShareRow 'Память' $ram)
    $disk = if ($null -eq $Hw.SystemSsd) { 'не определено' } elseif ($Hw.SystemSsd) { 'SSD' } else { 'HDD' }
    & $add (Format-PckitShareRow 'Диск с Windows' ('{0} ({1})' -f $disk, $Hw.SystemDiskName))
    foreach ($d in @($Hw.Displays)) {
        $cls = if ($d.MaxHz -gt $d.Hz + 1) { 'bad' } else { '' }
        & $add (Format-PckitShareRow $(if ($d.Primary) { 'Монитор (основной)' } else { 'Монитор' }) ('{0}×{1}, {2} Гц (максимум {3} Гц)' -f $d.Width, $d.Height, $d.Hz, $d.MaxHz) $cls)
    }
    & $add (Format-PckitShareRow 'Windows' ('сборка {0}' -f $Hw.Build))
    & $add (Format-PckitShareRow 'Тип ПК' $(if ($Hw.Laptop) { 'ноутбук' + $(if ($Hw.OnBattery) { ', сейчас от батареи' } else { '' }) } else { 'настольный' }))
    & $add (Format-PckitShareRow 'Интернет' $(if ($Hw.WifiOnly) { 'Wi-Fi' } elseif ($Hw.WiredNetwork) { 'кабель' } else { 'не определено' }))
    & $add (Format-PckitShareRow 'HAGS (аппаратное планирование GPU)' $(if ($null -eq $Hw.Hags) { 'по умолчанию' } elseif ($Hw.Hags) { 'включено' } else { 'выключено' }))
    & $add '</table></div>'

    # ---- CS2
    & $add '<h2>CS2</h2><div class="card"><table>'
    if ($Hw.Cs2Path) {
        & $add (Format-PckitShareRow 'Установлена' 'да')
        $v = $Hw.Cs2Video
        if ($v) {
            & $add (Format-PckitShareRow 'Разрешение в игре' ('{0}×{1}' -f $v.Width, $v.Height))
            & $add (Format-PckitShareRow 'Частота в игре' ('{0} Гц' -f $v.RefreshHz) $(if ($Hw.PrimaryMaxHz -and $v.RefreshHz + 1 -lt $Hw.PrimaryMaxHz) { 'bad' } else { '' }))
            & $add (Format-PckitShareRow 'Режим' $(if ($v.Fullscreen -eq 1) { 'полный экран' } else { 'в окне' }))
            & $add (Format-PckitShareRow 'V-Sync' $(if ($v.VSync -eq 1) { 'включён' } else { 'выключен' }) $(if ($v.VSync -eq 1) { 'warn' } else { '' }))
            & $add (Format-PckitShareRow 'NVIDIA Reflex' $(switch ($v.LowLatency) { 0 { 'выключен' } 1 { 'включён' } 2 { 'включён + boost' } default { '—' } }))
        }
    } else {
        & $add (Format-PckitShareRow 'Установлена' 'не найдена в Steam')
    }
    & $add '</table></div>'

    # ---- проверка
    if ($Health) {
        & $add '<h2>Что нашла проверка</h2><div class="card"><table>'
        foreach ($f in @($Health.Findings | Sort-Object { switch ($_.Severity) { 'bad' { 0 } 'warn' { 1 } 'info' { 2 } default { 3 } } })) {
            $val = [string]$f.Detail
            if ($f.Hint) { $val += ' Что делать: ' + $f.Hint }
            & $add (Format-PckitShareRow (Hide-PckitPersonal $f.Title) (Hide-PckitPersonal $val) ([string]$f.Severity))
        }
        & $add '</table></div>'
    }

    # ---- настройки
    if ($ActionStates) {
        $byId = @{}
        foreach ($p in @($Plan)) { $byId[[string]$p.Action.id] = $p }
        $on = @(); $todo = @(); $nf = @()
        foreach ($s in @($ActionStates)) {
            if ($s.Status -eq 'myth') { continue }
            $p = $byId[[string]$s.Action.id]
            if ($s.Status -eq 'applied') { $on += [string]$s.Action.title }
            elseif ($s.Status -in 'notfit', 'unsupported') { $nf += [string]$s.Action.title }
            elseif ($p -and $p.Recommended) { $todo += [string]$s.Action.title }
        }
        & $add ('<h2>Настройки pckit</h2><div class="card"><div class="muted">Включено: {0} · подходит этому ПК, но не включено: {1} · не подходит этому железу: {2} · изменений в журнале: {3}</div>' -f $on.Count, $todo.Count, $nf.Count, $JournalCount)
        if ($todo.Count) { & $add ('<p><b>Стоит включить:</b><br>{0}</p>' -f (($todo | ForEach-Object { '<span class="pill">' + (ConvertTo-PckitHtml $_) + '</span>' }) -join '')) }
        if ($on.Count) { & $add ('<p><b>Уже включено:</b><br>{0}</p>' -f (($on | ForEach-Object { '<span class="pill">' + (ConvertTo-PckitHtml $_) + '</span>' }) -join '')) }
        & $add '</div>'
    }

    # ---- сеть
    if ($Network -and $Network.Verdict) {
        $when = ''
        try { $when = ([datetime]$Network.Time).ToString('dd.MM HH:mm') } catch { }
        & $add ('<h2>Сеть (проверка {0})</h2><div class="card"><table>' -f (ConvertTo-PckitHtml $when))
        foreach ($r in @($Network.Verdict.Rows)) { & $add (Format-PckitShareRow $r.Name $r.Value ([string]$r.Verdict -replace '^ok$', 'ok')) }
        & $add '</table>'
        foreach ($tip in @($Network.Verdict.Tips)) { & $add ('<p>• {0}</p>' -f (ConvertTo-PckitHtml $tip)) }
        & $add '</div>'
    }

    # ---- FPS
    if ($FpsBefore -or $FpsAfter) {
        & $add '<h2>FPS в CS2</h2><div class="card"><table>'
        foreach ($pair in @(@('до', $FpsBefore), @('после', $FpsAfter))) {
            $fp = $pair[1]
            if (-not $fp) { continue }
            & $add (Format-PckitShareRow ('Замер «{0}»' -f $pair[0]) ('средний {0:N0}, 1% low {1:N0}, 0.1% low {2:N0}' -f [double]$fp.AvgFps, [double]$fp.Low1Fps, [double]$fp.Low01Fps))
        }
        & $add '</table></div>'
    }

    & $add '<p class="muted">Чтобы помочь: посмотрите красные и жёлтые строки. То, что исправляется кнопкой, есть в pckit (раздел «Игры» и «Проверка»).</p>'
    & $add '</div></body></html>'
    return $sb.ToString()
}

function Save-PckitShareReport {
    param([string]$Html, [string]$Folder)
    if (-not $Folder) { $Folder = [Environment]::GetFolderPath('Desktop') }
    if (-not (Test-Path -LiteralPath $Folder)) { New-Item -ItemType Directory -Force -Path $Folder | Out-Null }
    $path = Join-Path $Folder ('pckit-отчёт-{0}.html' -f (Get-Date).ToString('yyyy-MM-dd_HH-mm'))
    [IO.File]::WriteAllText($path, $Html, (New-Object System.Text.UTF8Encoding($true)))
    return $path
}
