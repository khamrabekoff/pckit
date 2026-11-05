#Requires -Version 5.1
# pckit engine | health: read-only diagnostics for the "Отчёт" tab
# (ported in spirit from CleanPC 2.1 item 1: показать, что не так, ничего не меняя)

function New-PckitFinding {
    param(
        [ValidateSet('bad', 'warn', 'info', 'ok')][string]$Severity,
        [string]$Title,
        [string]$Detail,
        [string]$FixAction = '',
        [string]$Hint = '',
        [string]$Link = ''
    )
    return [pscustomobject]@{
        Severity  = $Severity
        Title     = $Title
        Detail    = $Detail
        FixAction = $FixAction
        Hint      = $Hint
        Link      = $Link
    }
}

function Get-PckitMachineSummary {
    $summary = [ordered]@{}

    try {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $summary.Cpu = ('{0} · {1} ядер / {2} потоков' -f $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)
    } catch { $summary.Cpu = 'не определено' }

    try {
        $modules = @(Get-CimInstance Win32_PhysicalMemory)
        $total = ($modules | Measure-Object -Property Capacity -Sum).Sum / 1GB
        $sizes = ($modules | ForEach-Object { [math]::Round($_.Capacity / 1GB) }) -join '+'
        $speeds = ($modules | ForEach-Object { $_.Speed } | Sort-Object -Unique) -join '/'
        $summary.Ram = ('{0:N0} ГБ ({1} планки: {2}; {3} МГц)' -f $total, $modules.Count, $sizes, $speeds)
        $summary.RamModules = $modules.Count
        # объём по каналам из подписи слота: «P0 CHANNEL A», «ChannelB-DIMM0», «DIMM_A1» …
        $channels = @{}
        foreach ($m in $modules) {
            $label = ('{0} {1}' -f $m.BankLabel, $m.DeviceLocator)
            $ch = $null
            if ($label -match '(?i)channel\s*([A-H])\b') { $ch = $matches[1].ToUpper() }
            elseif ($label -match '(?i)\bDIMM[_\s]?([A-H])\d') { $ch = $matches[1].ToUpper() }
            if (-not $ch) { $channels = $null; break }
            if (-not $channels.ContainsKey($ch)) { $channels[$ch] = 0 }
            $channels[$ch] += [math]::Round($m.Capacity / 1GB)
        }
        $summary.RamChannels = $channels
        $summary.RamSpeeds = @($modules | ForEach-Object { $_.Speed } | Sort-Object -Unique)
    } catch { $summary.Ram = 'не определено'; $summary.RamModules = 0 }

    try {
        $gpus = @(Get-CimInstance Win32_VideoController)
        $main = $gpus | Sort-Object -Property AdapterRAM -Descending | Select-Object -First 1
        $summary.Gpu = ('{0} · драйвер {1} от {2}' -f $main.Name, $main.DriverVersion,
            $(if ($main.DriverDate) { ([datetime]$main.DriverDate).ToString('dd.MM.yyyy') } else { '—' }))
        $summary.GpuDriverDate = $main.DriverDate
        $summary.GpuName = $main.Name
    } catch { $summary.Gpu = 'не определено'; $summary.GpuDriverDate = $null }

    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $summary.Os = ('{0} · build {1}' -f $os.Caption, $os.BuildNumber)
        $summary.Uptime = ('{0:N0} ч' -f ((Get-Date) - $os.LastBootUpTime).TotalHours)
    } catch { $summary.Os = 'не определено' }

    try {
        $sys = Get-PSDrive -Name ($env:SystemDrive.Substring(0, 1)) -ErrorAction SilentlyContinue
        if ($sys) {
            $summary.Disk = ('{0}: свободно {1:N1} ГБ из {2:N0} ГБ' -f $env:SystemDrive.Substring(0, 1),
                ($sys.Free / 1GB), (($sys.Free + $sys.Used) / 1GB))
            $summary.DiskFreePercent = [math]::Round(($sys.Free / ($sys.Free + $sys.Used)) * 100, 1)
        }
    } catch { $summary.Disk = 'не определено'; $summary.DiskFreePercent = 100 }

    return [pscustomobject]$summary
}


function Get-PckitHealthReport {
    param([string]$ActionsDir)

    $findings = New-Object System.Collections.ArrayList
    $machine = Get-PckitMachineSummary

    # ---- RAM: каналы
    $chanKnown = ($machine.RamChannels -and $machine.RamChannels.Count -ge 1 -and $machine.RamModules -gt 1)
    if ($chanKnown) {
        $sizes = @($machine.RamChannels.Values | Sort-Object -Unique)
        $desc = (@($machine.RamChannels.Keys | Sort-Object | ForEach-Object { '{0}: {1} ГБ' -f $_, $machine.RamChannels[$_] }) -join ', ')
        if ($machine.RamChannels.Count -eq 1) {
            [void]$findings.Add((New-PckitFinding -Severity 'warn' -Title 'Вся память в одном канале' `
                        -Detail ('Планки стоят в одном канале ({0}) — это одноканальный режим, минус 5–15% fps в CS2.' -f $desc) `
                        -Hint 'Переставьте планки в слоты разных каналов (обычно A2 и B2 — смотрите инструкцию к плате).'))
        } elseif ($sizes.Count -eq 1) {
            [void]$findings.Add((New-PckitFinding -Severity 'ok' -Title 'Память в двухканальном режиме' -Detail ('Каналы поровну: {0}.' -f $desc)))
        } else {
            [void]$findings.Add((New-PckitFinding -Severity 'warn' -Title 'Каналы памяти заполнены неравномерно' `
                        -Detail ('{0}. Равная часть работает в двухканале, остаток — в одноканале.' -f $desc) `
                        -Hint 'Для полного двухканала нужен одинаковый объём в каждом канале.'))
        }
    }
    if ($machine.RamModules -gt 0 -and -not $chanKnown) {
        if ($machine.RamModules -eq 1) {
            [void]$findings.Add((New-PckitFinding -Severity 'warn' -Title 'Одна планка памяти — одноканальный режим' `
                        -Detail 'Одна планка = половина пропускной способности памяти. В CS2 это обычно минус 5–15% fps.' `
                        -Hint 'Добавьте вторую такую же планку в слоты A2/B2.'))
        }
        elseif (($machine.RamModules % 2) -eq 1) {
            [void]$findings.Add((New-PckitFinding -Severity 'warn' -Title ('Планек памяти: {0} — часть работает в одноканале' -f $machine.RamModules) `
                        -Detail 'Нечётное число планок почти всегда означает, что часть памяти идёт в одноканальном режиме.' `
                        -Hint 'Проверьте в CPU-Z: вкладка Memory, Channel. Для симметрии ставят 2 или 4 планки в A2/B2.'))
        }
    }
    if ($machine.RamModules -gt 0) {
        if (@($machine.RamSpeeds).Count -gt 1) {
            [void]$findings.Add((New-PckitFinding -Severity 'warn' -Title 'Планки памяти с разной частотой' `
                        -Detail ('Обнаружены частоты: {0} МГц. Система работает по самой медленной.' -f (@($machine.RamSpeeds) -join ', ')) `
                        -Hint 'Либо оставьте одинаковые планки, либо включите XMP и проверьте, что все держат одну частоту.'))
        }
    }

    # ---- Диск
    if ($machine.DiskFreePercent -lt 10) {
        [void]$findings.Add((New-PckitFinding -Severity 'bad' -Title ('Мало места на {0}: {1}% свободно' -f $env:SystemDrive, $machine.DiskFreePercent) `
                    -Detail 'При заполнении ниже 10% Windows и игры начинают тормозить: файл подкачки и кэш некуда писать.' `
                    -Hint 'Освободите место: временные файлы, кэш обновлений, старые игры.' -Link 'pckit:clean'))
    }
    elseif ($machine.DiskFreePercent -lt 20) {
        [void]$findings.Add((New-PckitFinding -Severity 'warn' -Title ('Место на {0}: {1}% свободно' -f $env:SystemDrive, $machine.DiskFreePercent) `
                    -Detail 'Для CS2 и Windows рекомендуют держать не меньше 15–20% свободного места.' `
                    -Hint 'Можно почистить кэши и временные файлы.' -Link 'pckit:clean'))
    }
    else {
        [void]$findings.Add((New-PckitFinding -Severity 'ok' -Title 'Места на диске достаточно' -Detail $machine.Disk))
    }

    # ---- Питание
    $balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
    $activePlan = $null
    try {
        $out = & powercfg /getactivescheme 2>$null
        if ($out -match '([0-9a-fA-F-]{36})') { $activePlan = $matches[1] }
    } catch { }
    if ($activePlan -eq $balanced) {
        [void]$findings.Add((New-PckitFinding -Severity 'warn' -Title 'Схема питания «Сбалансированная»' `
                    -Detail 'Windows экономит частоты процессора, из-за этого бывают просадки кадров.' `
                    -FixAction 'power.plan' -Hint 'Включите «Максимальная производительность».'))
    }
    elseif ($activePlan) {
        [void]$findings.Add((New-PckitFinding -Severity 'ok' -Title 'Схема питания настроена' -Detail ('активная: {0}' -f $activePlan)))
    }

    # ---- Game DVR / ускорение мыши / MMCSS / Power Throttling (через действия)
    $known = @{}
    if ($ActionsDir -and (Test-Path -LiteralPath (Join-Path $ActionsDir 'actions.json'))) {
        $actions = Get-PckitActions -Directory $ActionsDir
        foreach ($a in $actions) {
            $state = Test-PckitActionState -Action $a
            $known[[string]$a.id] = $state
            if ($state.Status -ne 'notApplied') { continue }

            switch ([string]$a.id) {
                'gamedvr.off' {
                    [void]$findings.Add((New-PckitFinding -Severity 'info' -Title 'Game DVR записывает игру в фоне' `
                                -Detail 'Фоновая запись забирает диск и память, иногда съедает 1–3% fps.' `
                                -FixAction 'gamedvr.off' -Hint 'Можно отключить во разделе «Настройки».'))
                }
                'mouse.accel.off' {
                    [void]$findings.Add((New-PckitFinding -Severity 'info' -Title 'Включено ускорение мыши' `
                                -Detail 'Прицел «догоняет» движение: аим менее предсказуем. На fps не влияет.' `
                                -FixAction 'mouse.accel.off' -Hint 'Отключается во разделе «Настройки».'))
                }
                'mmcss.games' {
                    [void]$findings.Add((New-PckitFinding -Severity 'info' -Title 'Приоритет игр в планировщике не настроен' `
                                -Detail 'Игра конкурирует с фоновыми задачами за процессор.' `
                                -FixAction 'mmcss.games' -Hint 'Настраивается во разделе «Настройки».'))
                }
            }
        }
    }

    # ---- умные советы по железу и настройкам CS2
    if (Get-Command Get-PckitSmartFindings -ErrorAction SilentlyContinue) {
        try { foreach ($sf in @(Get-PckitSmartFindings)) { [void]$findings.Add($sf) } } catch { }
    }

    # ---- старые версии драйверов в хранилище Windows
    if (-not (Get-Command Get-PckitOldDrivers -ErrorAction SilentlyContinue)) {
        $cleanFile = Join-Path $PSScriptRoot 'Clean.ps1'
        if (Test-Path -LiteralPath $cleanFile) { . $cleanFile }
    }
    if (Get-Command Get-PckitOldDrivers -ErrorAction SilentlyContinue) {
        try {
            $oldDrv = @(Get-PckitOldDriversCached)
            if ($oldDrv.Count) {
                $oldMb = ($oldDrv | Measure-Object -Property SizeMb -Sum).Sum
                $names = (@($oldDrv | ForEach-Object { $_.Title } | Select-Object -Unique) | Select-Object -First 4) -join ', '
                [void]$findings.Add((New-PckitFinding -Severity 'info' -Title ('Старые версии драйверов: {0} шт., {1:N0} МБ' -f $oldDrv.Count, $oldMb) `
                            -Detail ('Заменены более новыми и не используются: {0}.' -f $names) `
                            -Hint 'Можно удалить: «Чистка» → «Старые версии драйверов». Новейшие и используемые версии останутся.' -Link 'pckit:clean'))
            }
        } catch { }
    }

    # ---- Драйвер видеокарты
    if ($machine.GpuDriverDate) {
        try {
            $age = ((Get-Date) - [datetime]$machine.GpuDriverDate).TotalDays
            if ($age -gt 240) {
                [void]$findings.Add((New-PckitFinding -Severity 'warn' -Title ('Драйвер видеокарты старый: {0:N0} дней' -f $age) `
                            -Detail ('{0} · версия {1}' -f $machine.GpuName, $machine.Gpu) `
                            -Hint 'Свежий драйвер часто даёт больше, чем любые твики реестра.' -Link 'pckit:driver'))
            }
            else {
                [void]$findings.Add((New-PckitFinding -Severity 'ok' -Title ('Драйвер видеокарты не старый: {0:N0} дн.' -f $age) -Detail $machine.Gpu -Hint 'Есть ли версия новее — кнопка «Свежий ли драйвер?» (спросит сайт NVIDIA).' -Link 'pckit:driver'))
            }
        } catch { }
    }

    # ---- Незавершённая перезагрузка
    $pending = $false
    foreach ($k in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        )) {
        if (Test-Path -LiteralPath $k) { $pending = $true }
    }
    if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' ) {
        $pfro = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue)
        if ($pfro) { $pending = $true }
    }
    if ($pending) {
        [void]$findings.Add((New-PckitFinding -Severity 'warn' -Title 'Windows ждёт перезагрузку' `
                    -Detail 'После обновлений часть изменений не применяется, пока не перезагрузитесь.' `
                    -Hint 'Перезагрузите ПК перед игрой.' -Link 'ms-settings:windowsupdate'))
    }

    # ---- Временные файлы
    $tempMb = 0
    foreach ($dir in @($env:TEMP, (Join-Path $env:SystemRoot 'Temp'))) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        try {
            $sum = (Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum).Sum
            if ($sum) { $tempMb += ($sum / 1MB) }
        } catch { }
    }
    if ($tempMb -gt 5120) {
        [void]$findings.Add((New-PckitFinding -Severity 'info' -Title ('Временных файлов на {0:N1} ГБ' -f ($tempMb / 1024)) `
                    -Detail 'Их можно удалить: место освободится, системе станет легче.' `
                    -Hint 'Удаляется в разделе «Чистка».' -Link 'pckit:clean'))
    }

    # ---- Автозагрузка
    $startupCount = 0
    foreach ($k in @(
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
            'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
        )) {
        $props = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
        if ($props) { $startupCount += @($props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }).Count }
    }
    foreach ($dir in @(
            (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup')
            (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup')
        )) {
        if (Test-Path -LiteralPath $dir) {
            $startupCount += @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue).Count
        }
    }
    if ($startupCount -gt 15) {
        [void]$findings.Add((New-PckitFinding -Severity 'info' -Title ('В автозагрузке {0} программ' -f $startupCount) `
                    -Detail 'Каждая стартует вместе с Windows и занимает память и диск в первые минуты.' `
                    -Hint 'Раздел «Автозагрузка»: выключите лишнее.' -Link 'pckit:startup'))
    }

    # ---- Виртуализация (VBS/HVCI)
    $vbs = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -Name EnableVirtualizationBasedSecurity -ErrorAction SilentlyContinue)
    if ($vbs -and $vbs.EnableVirtualizationBasedSecurity -eq 1) {
        [void]$findings.Add((New-PckitFinding -Severity 'info' -Title 'Включена изоляция ядра (VBS/HVCI)' `
                    -Detail 'Это защита, но в играх она иногда стоит 3–8% fps.' `
                    -Hint 'Выключать или нет — ваш выбор: безопасность против производительности. Программа этого не трогает.'))
    }

    # ---- CS2
    $cs2 = Find-PckitCs2
    if ($cs2) {
        [void]$findings.Add((New-PckitFinding -Severity 'ok' -Title 'CS2 найдена' -Detail $cs2))
        $onSystemDrive = $cs2.StartsWith($env:SystemDrive, [StringComparison]::OrdinalIgnoreCase)
        if (-not $onSystemDrive) {
            [void]$findings.Add((New-PckitFinding -Severity 'info' -Title 'CS2 установлена не на системный диск' `
                        -Detail 'Это нормально и даже хорошо: система и игра не мешают друг другу.'))
        }
    }
    else {
        [void]$findings.Add((New-PckitFinding -Severity 'info' -Title 'CS2 не найдена' `
                    -Detail 'Искал в библиотеках Steam. Если игра установлена — проверьте путь Steam.'))
    }

    # ---- Журнал (что уже сделано программой)
    $journal = Read-PckitJournal
    $journalCount = Get-PckitJournalCount -Journal $journal
    if ($journalCount -gt 0) {
        [void]$findings.Add((New-PckitFinding -Severity 'info' -Title ('В журнале {0} изменений — их можно отменить' -f $journalCount) `
                    -Detail ('журнал от {0}' -f $journal.created) `
                    -Hint 'Кнопка «Отменить изменения» во вкладке «Вернуть» или «Настройки».'))
    }

    $bad = @($findings | Where-Object { $_.Severity -eq 'bad' }).Count
    $warn = @($findings | Where-Object { $_.Severity -eq 'warn' }).Count
    $info = @($findings | Where-Object { $_.Severity -eq 'info' }).Count
    $okCount = @($findings | Where-Object { $_.Severity -eq 'ok' }).Count

    return [pscustomobject]@{
        Created    = (Get-Date).ToString('s')
        Machine    = $machine
        Findings   = $findings.ToArray()
        Bad        = $bad
        Warn       = $warn
        Info       = $info
        Ok         = $okCount
        Cs2Path    = $cs2
        JournalAge = $journal.created
        JournalCount = $journalCount
    }
}

function Save-PckitHealthReport {
    param(
        $Report,
        [string]$Directory,
        [ValidateSet('txt', 'html')][string]$Format = 'txt'
    )

    if (-not $Directory) {
        $Directory = Join-Path $env:USERPROFILE 'Documents\pckit\Отчёты'
    }
    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Force -Path $Directory | Out-Null }

    $stamp = (Get-Date).ToString('yyyy-MM-dd_HHmm')
    $labels = @{ 'bad' = 'проблема'; 'warn' = 'предупреждение'; 'info' = 'заметка'; 'ok' = 'в порядке' }

    if ($Format -eq 'html') {
        $file = Join-Path $Directory ('pckit-{0}.html' -f $stamp)
        $sb = New-Object System.Text.StringBuilder

        [void]$sb.AppendLine('<!doctype html><html lang="ru"><head><meta charset="utf-8">')
        [void]$sb.AppendLine('<title>pckit by odilbek — отчёт</title><style>')
        [void]$sb.AppendLine('body{font-family:"Segoe UI",Arial,sans-serif;max-width:900px;margin:24px auto;padding:0 16px;color:#222;line-height:1.45}')
        [void]$sb.AppendLine('h1{font-size:22px;margin:0 0 4px} h2{font-size:15px;margin:26px 0 8px;color:#444}')
        [void]$sb.AppendLine('.muted{color:#777;font-size:13px} .bad{color:#b42828} .warn{color:#a06e0f} .info{color:#1e6496} .ok{color:#1e7832}')
        [void]$sb.AppendLine('table{border-collapse:collapse;width:100%;font-size:14px} td{padding:7px 0;border-bottom:1px solid #eee;vertical-align:top}')
        [void]$sb.AppendLine('td.k{color:#777;width:150px} .f{padding:10px 0;border-bottom:1px solid #f0f0f0}')
        [void]$sb.AppendLine('.f b{font-size:14px} .f .d{font-size:13px;color:#444} .f .h{font-size:13px;color:#666;font-style:italic}')
        [void]$sb.AppendLine('.sum{display:flex;gap:18px;font-size:14px;margin:8px 0 0}')
        [void]$sb.AppendLine('</style></head><body>')

        [void]$sb.AppendLine('<h1>pckit by odilbek — отчёт о проверке</h1>')
        [void]$sb.AppendLine(('<p class="muted">{0}</p>' -f (Get-Date).ToString('dd.MM.yyyy HH:mm')))

        [void]$sb.AppendLine('<h2>Компьютер</h2><table>')
        foreach ($p in $Report.Machine.PSObject.Properties) {
            if ($p.Name -in 'RamModules', 'RamSpeeds', 'RamChannels', 'GpuDriverDate', 'GpuName', 'DiskFreePercent') { continue }
            [void]$sb.AppendLine(('<tr><td class="k">{0}</td><td>{1}</td></tr>' -f $p.Name, [System.Net.WebUtility]::HtmlEncode([string]$p.Value)))
        }
        [void]$sb.AppendLine('</table>')

        [void]$sb.AppendLine('<h2>Итог</h2>')
        [void]$sb.AppendLine(('<div class="sum"><span class="bad">проблем: {0}</span><span class="warn">предупреждений: {1}</span><span class="info">заметок: {2}</span><span class="ok">в порядке: {3}</span></div>' -f `
                    $Report.Bad, $Report.Warn, $Report.Info, $Report.Ok))

        foreach ($group in @(@('Проблемы', 'bad'), @('Предупреждения', 'warn'), @('Заметки', 'info'), @('В порядке', 'ok'))) {
            $items = @($Report.Findings | Where-Object { $_.Severity -eq $group[1] })
            if (-not $items.Count) { continue }
            [void]$sb.AppendLine(('<h2 class="{0}">{1}</h2>' -f $group[1], $group[0]))
            foreach ($f in $items) {
                [void]$sb.AppendLine(('<div class="f"><b class="{0}">{1}</b>' -f $group[1], [System.Net.WebUtility]::HtmlEncode([string]$f.Title)))
                if ($f.Detail) { [void]$sb.AppendLine(('<div class="d">{0}</div>' -f [System.Net.WebUtility]::HtmlEncode([string]$f.Detail))) }
                if ($f.Hint) { [void]$sb.AppendLine(('<div class="h">что делать: {0}</div>' -f [System.Net.WebUtility]::HtmlEncode([string]$f.Hint))) }
                [void]$sb.AppendLine('</div>')
            }
        }

        if ($Report.JournalCount -gt 0) {
            [void]$sb.AppendLine('<h2>Журнал изменений</h2>')
            [void]$sb.AppendLine(('<p class="muted">записей: {0}, от {1}. Откат — кнопка «Отменить всё» во вкладке «История и отмена».</p>' -f $Report.JournalCount, $Report.JournalAge))
        }

        [void]$sb.AppendLine('</body></html>')
        [IO.File]::WriteAllText($file, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
        return $file
    }

    $file = Join-Path $Directory ('pckit-{0}.txt' -f $stamp)
    $lines = New-Object System.Collections.ArrayList

    [void]$lines.Add('pckit by odilbek — отчёт о проверке')
    [void]$lines.Add(('Дата: {0}' -f (Get-Date).ToString('dd.MM.yyyy HH:mm')))
    [void]$lines.Add('')
    [void]$lines.Add('КОМПЬЮТЕР')
    foreach ($p in $Report.Machine.PSObject.Properties) {
        if ($p.Name -in 'RamModules', 'RamSpeeds', 'RamChannels', 'GpuDriverDate', 'GpuName', 'DiskFreePercent') { continue }
        [void]$lines.Add(('  {0,-10} {1}' -f ($p.Name + ':'), $p.Value))
    }
    [void]$lines.Add('')
    [void]$lines.Add(('ИТОГ: проблем {0} · предупреждений {1} · заметок {2} · в порядке {3}' -f $Report.Bad, $Report.Warn, $Report.Info, $Report.Ok))
    [void]$lines.Add('')

    foreach ($group in @(
            @('ПРОБЛЕМЫ', 'bad'), @('ПРЕДУПРЕЖДЕНИЯ', 'warn'), @('ЗАМЕТКИ', 'info'), @('В ПОРЯДКЕ', 'ok')
        )) {
        $items = @($Report.Findings | Where-Object { $_.Severity -eq $group[1] })
        if (-not $items.Count) { continue }
        [void]$lines.Add('--- ' + $group[0] + ' ---')
        foreach ($f in $items) {
            [void]$lines.Add(('  • {0}' -f $f.Title))
            if ($f.Detail) { [void]$lines.Add(('      {0}' -f $f.Detail)) }
            if ($f.Hint) { [void]$lines.Add(('      что делать: {0}' -f $f.Hint)) }
        }
        [void]$lines.Add('')
    }

    if ($Report.JournalCount -gt 0) {
        [void]$lines.Add('ЖУРНАЛ ИЗМЕНЕНИЙ')
        [void]$lines.Add(('  записей: {0} (от {1})' -f $Report.JournalCount, $Report.JournalAge))
        [void]$lines.Add('  откат: кнопка «Отменить всё» или pckit.ps1 undo -Run')
    }

    [IO.File]::WriteAllText($file, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    return $file
}