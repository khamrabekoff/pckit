#Requires -Version 5.1
# pckit engine | smart: подбор настроек под конкретный ПК и честный вердикт «помогло / не помогло»
#
# В actions.json у действия могут быть поля:
#   "requires": { условия }                — без них действие не применяется вообще (например, только NVIDIA)
#   "skipIf":   { условия }, "skipWhy": "" — подходит, но этому ПК не рекомендуем
#   "boostIf":  { условия }, "boostWhy": "" — рекомендуем этому ПК, даже если эффект в общем случае низкий
# Условия: gpu ("nvidia"/"amd"/"intel" или список), laptop, hybridGpu, ssd, cs2, hags (true/false),
#          ramGbMin, ramGbMax, cpuCoresMax (числа). Все условия в объекте должны выполниться.

function Test-PckitHwCondition {
    param($Cond, $Hw)
    if (-not $Cond) { return $true }
    foreach ($p in $Cond.PSObject.Properties) {
        $v = $p.Value
        switch ($p.Name) {
            'gpu'         { if (@($v | ForEach-Object { [string]$_ }) -notcontains [string]$Hw.GpuVendor) { return $false } }
            'laptop'      { if ([bool]$Hw.Laptop -ne [bool]$v) { return $false } }
            'hybridGpu'   { if ([bool]$Hw.HybridGpu -ne [bool]$v) { return $false } }
            'ssd'         { if ($null -eq $Hw.SystemSsd -or [bool]$Hw.SystemSsd -ne [bool]$v) { return $false } }
            'cs2'         { if ([bool]$Hw.Cs2Path -ne [bool]$v) { return $false } }
            'hags'        { if ($null -eq $Hw.Hags -or [bool]$Hw.Hags -ne [bool]$v) { return $false } }
            'ramGbMin'    { if ([double]$Hw.RamGb -lt [double]$v) { return $false } }
            'ramGbMax'    { if ([double]$Hw.RamGb -gt [double]$v) { return $false } }
            'cpuCoresMax' { if ([int]$Hw.CpuCores -gt [int]$v) { return $false } }
            default       { }
        }
    }
    return $true
}

function Get-PckitRequiresText {
    param($Cond, $Hw)
    $parts = New-Object System.Collections.ArrayList
    foreach ($p in $Cond.PSObject.Properties) {
        switch ($p.Name) {
            'gpu' {
                $names = @($p.Value | ForEach-Object { switch ([string]$_) { 'nvidia' { 'NVIDIA' } 'amd' { 'AMD' } 'intel' { 'Intel' } default { $_ } } }) -join '/'
                $have = if ($Hw.GpuName) { $Hw.GpuName } else { 'не определена' }
                [void]$parts.Add(('только для видеокарт {0} (у вас: {1})' -f $names, $have))
            }
            'cs2'       { if ($p.Value) { [void]$parts.Add('CS2 не найдена в библиотеках Steam') } }
            'hybridGpu' { if ($p.Value) { [void]$parts.Add('нужно для ноутбуков с двумя видеокартами') } }
            'laptop'    { [void]$parts.Add($(if ($p.Value) { 'только для ноутбуков' } else { 'не для ноутбуков' })) }
            'ssd'       { [void]$parts.Add($(if ($p.Value) { 'только если Windows на SSD' } else { 'только если Windows на HDD' })) }
            default     { }
        }
    }
    if (-not $parts.Count) { return 'не подходит этому ПК' }
    return ($parts -join '; ')
}

# решение по одному действию: { Applicable, Recommended, Reason }
function Get-PckitSmartAdvice {
    param($Action, $Hw)

    if ($Action.myth) { return [pscustomobject]@{ Applicable = $false; Recommended = $false; Reason = 'миф: не применяется' } }
    if ($Action.minBuild -and [Environment]::OSVersion.Version.Build -lt [int]$Action.minBuild) {
        return [pscustomobject]@{ Applicable = $false; Recommended = $false; Reason = 'не для этой версии Windows' }
    }
    if ($Action.requires -and -not (Test-PckitHwCondition -Cond $Action.requires -Hw $Hw)) {
        return [pscustomobject]@{ Applicable = $false; Recommended = $false; Reason = (Get-PckitRequiresText -Cond $Action.requires -Hw $Hw) }
    }

    $rec = (-not $Action.expert) -and ([string]$Action.effectLevel -in 'высокий', 'средний')
    $reason = if ($rec) { 'подходит вашему ПК' } else { 'по желанию' }
    if ($Action.expert) { $reason = 'экспертная настройка — по желанию' }
    if ($Action.danger) { $rec = $false; $reason = 'на свой страх и риск — для тестов' }

    if ($Action.boostIf -and (Test-PckitHwCondition -Cond $Action.boostIf -Hw $Hw)) {
        $rec = $true
        $reason = if ($Action.boostWhy) { [string]$Action.boostWhy } else { 'особенно полезно вашему ПК' }
    }
    if ($Action.skipIf -and (Test-PckitHwCondition -Cond $Action.skipIf -Hw $Hw)) {
        $rec = $false
        $reason = if ($Action.skipWhy) { [string]$Action.skipWhy } else { 'вашему ПК не рекомендуется' }
    }
    return [pscustomobject]@{ Applicable = $true; Recommended = $rec; Reason = $reason }
}

# весь список: [{ Action, Applicable, Recommended, Reason }]
function Get-PckitSmartPlan {
    param($Actions, $Hw)
    if (-not $Hw) { $Hw = Get-PckitHardwareProfile }
    $out = New-Object System.Collections.ArrayList
    foreach ($a in @($Actions)) {
        if (-not $a) { continue }
        $adv = Get-PckitSmartAdvice -Action $a -Hw $Hw
        [void]$out.Add([pscustomobject]@{ Action = $a; Applicable = $adv.Applicable; Recommended = $adv.Recommended; Reason = $adv.Reason })
    }
    return $out.ToArray()
}

# ---------- последняя партия изменений (для «откатить, если не помогло») ----------

function Save-PckitLastBatch {
    param([string]$Since, [string[]]$Ids, [string]$Kind = 'boost')
    $path = Join-Path (Get-PckitStateRoot) 'last-batch.json'
    $data = [pscustomobject]@{ since = $Since; ids = @($Ids); kind = $Kind; at = (Get-Date).ToString('s') }
    [IO.File]::WriteAllText($path, ($data | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
}

function Get-PckitLastBatch {
    $path = Join-Path (Get-PckitStateRoot) 'last-batch.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Clear-PckitLastBatch {
    $path = Join-Path (Get-PckitStateRoot) 'last-batch.json'
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}

# ---------- вердикт ----------

# Rows — Compare-PckitSnapshot; FpsBefore/After — Read-PckitFpsCsv (AvgFps, Low1Fps, P99FrameMs)
function Get-PckitSmartVerdict {
    param($Rows, $FpsBefore, $FpsAfter)

    $lines = New-Object System.Collections.ArrayList
    $score = 0
    $suggestUndo = $false
    $fpsKnown = $false

    if ($FpsBefore -and $FpsAfter -and [double]$FpsBefore.AvgFps -gt 0 -and [double]$FpsBefore.Low1Fps -gt 0) {
        $fpsKnown = $true
        $avg = ([double]$FpsAfter.AvgFps - [double]$FpsBefore.AvgFps) / [double]$FpsBefore.AvgFps * 100
        $low = ([double]$FpsAfter.Low1Fps - [double]$FpsBefore.Low1Fps) / [double]$FpsBefore.Low1Fps * 100
        # 3% — типичный разброс одинаковых прогонов одной сцены
        $fmt = { param($x) if ($x -ge 0) { '+{0:N1}%' -f $x } else { '−{0:N1}%' -f [math]::Abs($x) } }
        if ($avg -gt 3 -or $low -gt 3) {
            $score += 2
            [void]$lines.Add(('FPS вырос: средний {0}, 1% low {1}.' -f (& $fmt $avg), (& $fmt $low)))
        }
        if ($avg -lt -3 -or $low -lt -5) {
            $score -= 3
            $suggestUndo = $true
            [void]$lines.Add(('FPS упал: средний {0}, 1% low {1}. Скорее всего, мешает одна из новых настроек.' -f (& $fmt $avg), (& $fmt $low)))
        }
        if ($avg -ge -3 -and $avg -le 3 -and $low -ge -3 -and $low -le 3) {
            [void]$lines.Add('FPS без заметной разницы (в пределах ±3% — это шум между прогонами).')
        }
    }

    $better = @($Rows | Where-Object { $_.Verdict -eq 'лучше' })
    $worse = @($Rows | Where-Object { $_.Verdict -eq 'хуже' })
    $score += $better.Count - $worse.Count
    foreach ($w in $worse) {
        if ([string]$w.Metric -match 'DPC|прерыван') {
            $score -= 1
            [void]$lines.Add(('Хуже стало «{0}» — это задержки драйверов, они влияют на плавность. ' -f $w.Metric))
            if (-not $fpsKnown) { $suggestUndo = $true }
        }
    }
    if (@($Rows | Where-Object { $_.Verdict -eq 'нужна перезагрузка' }).Count) {
        [void]$lines.Add('Часть изменений видна только после перезагрузки — перезагрузитесь и сравните ещё раз.')
    }

    $level = 'neutral'
    if ($score -ge 2) { $level = 'good' } elseif ($score -le -2 -or $suggestUndo) { $level = 'bad' }

    $head = switch ($level) {
        'good'    { 'Помогло: компьютер стал работать лучше.' }
        'bad'     { 'Не помогло: после изменений стало хуже.' }
        default   { 'Заметной разницы нет — значит, узкого места там и не было.' }
    }
    if (-not $fpsKnown) { [void]$lines.Add('Для честной оценки в игре сделайте замер FPS «до» и «после» на одной и той же сцене.') }

    return [pscustomobject]@{
        Level       = $level
        Headline    = $head
        Lines       = $lines.ToArray()
        SuggestUndo = $suggestUndo
        FpsKnown    = $fpsKnown
    }
}

# ---------- советы по железу и настройкам игры (для «Проверки») ----------

function Get-PckitSmartFindings {
    param($Hw)
    # проверка — всегда по свежему состоянию (частота монитора, настройки CS2 могли поменяться минуту назад)
    if (-not $Hw) { $Hw = Get-PckitHardwareProfile -Refresh }
    $f = New-Object System.Collections.ArrayList

    if ($Hw.GpuName -or $Hw.CpuName) {
        [void]$f.Add((New-PckitFinding -Severity 'info' -Title ('Ваш ПК: {0}' -f (Format-PckitHardwareLine $Hw)) `
                    -Detail 'pckit подбирает настройки под это железо: лишнее для вашего ПК не предлагается.'))
    }

    # ---- монитор
    if ($Hw.PrimaryHz -and $Hw.PrimaryMaxHz -and $Hw.PrimaryMaxHz -gt $Hw.PrimaryHz + 1) {
        [void]$f.Add((New-PckitFinding -Severity 'bad' -Title ('Монитор работает на {0} Гц, а умеет {1} Гц' -f $Hw.PrimaryHz, $Hw.PrimaryMaxHz) `
                    -Detail 'Вы видите меньше кадров, чем показывает монитор. Это самая частая и самая обидная ошибка.' `
                    -Hint 'Параметры → Система → Дисплей → Расширенные параметры дисплея → Частота обновления: выберите максимум.' -Link 'ms-settings:display-advancedsettings'))
    } elseif ($Hw.PrimaryHz -ge 100) {
        [void]$f.Add((New-PckitFinding -Severity 'ok' -Title ('Монитор на максимальной частоте: {0} Гц' -f $Hw.PrimaryHz) -Detail ''))
    }

    # ---- настройки видео в CS2
    $v = $Hw.Cs2Video
    if ($v) {
        $maxHz = if ($Hw.PrimaryMaxHz) { $Hw.PrimaryMaxHz } else { $Hw.PrimaryHz }
        if ($v.RefreshHz -and $maxHz -and $v.RefreshHz + 1 -lt $maxHz) {
            [void]$f.Add((New-PckitFinding -Severity 'warn' -Title ('В CS2 выставлено {0} Гц при мониторе {1} Гц' -f $v.RefreshHz, $maxHz) `
                        -Detail 'Игра выводит картинку реже, чем может монитор.' `
                        -Hint 'CS2 → Настройки → Видео → Частота обновления: выберите максимальную.'))
        }
        if ($v.VSync -eq 1) {
            [void]$f.Add((New-PckitFinding -Severity 'warn' -Title 'В CS2 включена вертикальная синхронизация' `
                        -Detail 'V-Sync добавляет задержку ввода — для соревновательной игры её выключают.' `
                        -Hint 'CS2 → Настройки → Видео → Дополнительно → Вертикальная синхронизация: выкл.'))
        }
        if ($Hw.GpuVendor -eq 'nvidia' -and $v.LowLatency -eq 0) {
            [void]$f.Add((New-PckitFinding -Severity 'warn' -Title 'В CS2 выключен NVIDIA Reflex' `
                        -Detail 'Reflex снижает задержку ввода на видеокартах NVIDIA, особенно когда карта загружена на 100%.' `
                        -Hint 'CS2 → Настройки → Видео → Дополнительно → NVIDIA Reflex Low Latency: «Вкл.».'))
        }
        if ($v.Fullscreen -eq 0) {
            [void]$f.Add((New-PckitFinding -Severity 'info' -Title 'CS2 запущена в окне' `
                        -Detail 'Полноэкранный режим обычно даёт меньше задержку и чуть больше fps, чем оконный.' `
                        -Hint 'CS2 → Настройки → Видео → Режим отображения: «Полный экран».'))
        }
    }

    # ---- память: XMP / DOCP
    $jedec = @{ 'DDR4' = 2666; 'DDR5' = 4800; 'DDR3' = 1333 }
    if ($Hw.RamType -and $Hw.RamMhz -and $jedec.ContainsKey($Hw.RamType) -and $Hw.RamMhz -le $jedec[$Hw.RamType]) {
        [void]$f.Add((New-PckitFinding -Severity 'warn' -Title ('Память работает на {0} МГц — похоже, XMP/EXPO выключен' -f $Hw.RamMhz) `
                    -Detail ('Для {0} это базовая частота. Большинство игровых планок умеют больше; в CS2 частота памяти напрямую влияет на 1% low.' -f $Hw.RamType) `
                    -Hint 'В BIOS включите профиль XMP (Intel) или DOCP/EXPO (AMD). pckit сам BIOS не трогает.'))
    }
    if ($Hw.RamGb -and $Hw.RamGb -lt 16) {
        [void]$f.Add((New-PckitFinding -Severity 'info' -Title ('Памяти {0} ГБ' -f $Hw.RamGb) `
                    -Detail 'Для CS2 + Discord + браузера комфортно от 16 ГБ. При 8 ГБ закрывайте лишнее перед игрой.'))
    }

    # ---- диск
    if ($Hw.SystemSsd -eq $false) {
        [void]$f.Add((New-PckitFinding -Severity 'warn' -Title 'Windows стоит на HDD' `
                    -Detail 'Жёсткий диск — главный тормоз загрузки Windows, программ и карт в CS2.' `
                    -Hint 'Самое заметное улучшение за свои деньги — SSD для Windows и игры.'))
    }

    # ---- видеокарта
    if ($Hw.IntegratedOnly) {
        [void]$f.Add((New-PckitFinding -Severity 'info' -Title ('Только встроенная графика: {0}' -f $Hw.GpuName) `
                    -Detail 'Основной резерв fps — в настройках игры: разрешение и качество теней/текстур.'))
    }
    if ($Hw.HybridGpu -and $Hw.Cs2Exe) {
        $pref = Get-PckitRegState -Path 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -Name ([string]$Hw.Cs2Exe)
        if (-not $pref.Exists -or (Get-PckitKvValue -Text ([string]$pref.Value) -Key 'GpuPreference') -ne '2') {
            [void]$f.Add((New-PckitFinding -Severity 'warn' -Title 'CS2 не закреплена за мощной видеокартой' `
                        -Detail 'У вас две видеокарты; Windows может запустить игру на встроенной.' `
                        -FixAction 'gpu.cs2.highperf' -Hint 'Включается во разделе «Настройки» → «CS2 всегда на мощной видеокарте».'))
        }
    }

    # ---- ноутбук и сеть
    if ($Hw.OnBattery) {
        [void]$f.Add((New-PckitFinding -Severity 'warn' -Title 'Ноутбук работает от батареи' `
                    -Detail 'От батареи процессор и видеокарта режут частоты — fps ниже в разы.' `
                    -Hint 'Для игры подключите зарядку.' -Link 'ms-settings:batterysaver'))
    }
    if ($Hw.WifiOnly) {
        [void]$f.Add((New-PckitFinding -Severity 'info' -Title 'Интернет по Wi-Fi' `
                    -Detail 'Wi-Fi даёт скачки пинга и потери пакетов, даже при хорошем сигнале.' `
                    -Hint 'Для матчей лучше кабель. Если нельзя — роутер 5 ГГц и поближе.'))
    }
    return $f.ToArray()
}
