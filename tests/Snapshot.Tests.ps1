#Requires -Version 5.1
# Тесты Snapshot.ps1 и PresentMon.ps1: powershell -NoProfile -File tests\Snapshot.Tests.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'engine\Common.ps1')
. (Join-Path $root 'engine\Snapshot.ps1')
. (Join-Path $root 'engine\PresentMon.ps1')

$script:fail = 0
function Check {
    param([string]$Name, [bool]$Cond, [string]$Info = '')
    if ($Cond) { Write-Host ('PASS  {0}' -f $Name) -ForegroundColor Green }
    else { $script:fail++; Write-Host ('FAIL  {0}  {1}' -f $Name, $Info) -ForegroundColor Red }
}
function Near { param([double]$A, [double]$B, [double]$Tol) return ([math]::Abs($A - $B) -le $Tol) }

$tmp = Join-Path $env:TEMP ('pckit-snap-test-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    # 1. реальный снимок
    $err = $null
    try { $snap = Get-PckitSnapshot -Label test -Samples 3 -IntervalSeconds 1 } catch { $err = $_.Exception.Message }
    Check 'Get-PckitSnapshot без исключений' ($null -eq $err) $err
    Check 'ключевые поля заполнены' ($snap.OsBuild -and $snap.PowerPlan -and $null -ne $snap.FreeSpaceMb -and $snap.Processes -and $snap.ServicesRunning -and $null -ne $snap.Startup -and $null -ne $snap.Cpu -and $null -ne $snap.RamUsedMb -and $null -ne $snap.Dpc -and $null -ne $snap.Interrupt) ($snap.Errors -join '; ')
    Check 'пинг: две цели' (@($snap.Ping).Count -eq 2)
    Write-Host ('  ОС build {0}, схема «{1}», свободно {2}, процессов {3}, служб {4}, автозагрузка {5}' -f $snap.OsBuild, $snap.PowerPlan, (Format-PckitSize $snap.FreeSpaceMb), $snap.Processes, $snap.ServicesRunning, $snap.Startup.Count)
    Write-Host ('  CPU {0} % (p95 {1}), DPC {2} %, прерывания {3} %, DPC/с {4}, ОЗУ {5}' -f $snap.Cpu.Median, $snap.Cpu.P95, $snap.Dpc.Median, $snap.Interrupt.Median, $snap.DpcPerSec.Median, (Format-PckitSize $snap.RamUsedMb.Median))
    Write-Host ('  загрузка: доступно={0}, медиана={1} мс, последняя={2}' -f $snap.Boot.Available, $snap.Boot.Median, $snap.Boot.LastAt)
    foreach ($p in @($snap.Ping)) { Write-Host ('  пинг {0}: avg {1} мс, джиттер {2}, потери {3} %' -f $p.Host, $p.Avg, $p.Jitter, $p.LossPct) }
    if ($snap.Errors.Count) { Write-Host ('  ошибки замера: ' + ($snap.Errors -join '; ')) -ForegroundColor Yellow }

    # 2. сравнение на синтетике
    function New-Fake {
        param($Free, $Cpu, $LastAt)
        [pscustomobject]@{
            Time = '2026-01-01T10:00:00'; Label = 'x'; PowerPlan = 'Высокая производительность'
            FreeSpaceMb = $Free; Processes = 100; ServicesRunning = 80; Startup = [pscustomobject]@{ Count = 5; Items = @() }
            Cpu = [pscustomobject]@{ Median = $Cpu; Samples = @(($Cpu - 0.2), $Cpu, ($Cpu + 0.2)) }
            Dpc = [pscustomobject]@{ Median = 0.5; Samples = @(0.5, 0.5, 0.5) }
            Interrupt = [pscustomobject]@{ Median = 0.3; Samples = @(0.3, 0.3, 0.3) }
            RamUsedMb = [pscustomobject]@{ Median = 8000; Samples = @(8000, 8010, 7990) }
            Boot = [pscustomobject]@{ Last = @(30000, 31000); Median = 30500; LastAt = $LastAt; Available = $true }
            Ping = @()
        }
    }
    $b = New-Fake 10000 5.0 '2026-01-01T09:00:00'
    $a = New-Fake 20000 5.5 '2026-01-01T09:00:00'
    $rows = Compare-PckitSnapshot -Before $b -After $a
    $free = $rows | Where-Object { $_.Metric -like 'Свободно*' }
    $cpuRow = $rows | Where-Object { $_.Metric -like 'Загрузка CPU*' }
    $boot = $rows | Where-Object { $_.Metric -like 'Время загрузки*' }
    Check 'место выросло -> лучше' ($free.Verdict -eq 'лучше') $free.Verdict
    Check 'CPU +0,5 п.п. -> в пределах шума' ($cpuRow.Verdict -eq 'в пределах шума') $cpuRow.Verdict
    Check 'Boot LastAt тот же -> нужна перезагрузка' ($boot.Verdict -eq 'нужна перезагрузка') $boot.Verdict
    $a2 = New-Fake 20000 8.0 '2026-01-01T12:00:00'
    $rows2 = Compare-PckitSnapshot -Before $b -After $a2
    Check 'CPU +3 п.п. -> хуже' (($rows2 | Where-Object { $_.Metric -like 'Загрузка CPU*' }).Verdict -eq 'хуже')
    Check 'загрузка после перезагрузки сравнивается' (($rows2 | Where-Object { $_.Metric -like 'Время загрузки*' }).Verdict -in 'лучше', 'хуже', 'в пределах шума')
    Write-Host ('  пример: {0}: {1} -> {2} ({3}) {4}' -f $free.Metric, $free.Before, $free.After, $free.Delta, $free.Verdict)

    # 3. хранение
    $script:PckitSnapshotDir = Join-Path $tmp 'snaps'
    $path = Save-PckitSnapshot -Snapshot $snap
    Check 'снимок сохранён' (Test-Path -LiteralPath $path)
    $back = Read-PckitSnapshot -Path $path
    Check 'снимок читается обратно' ($back.Label -eq 'test' -and $back.Processes -eq $snap.Processes)
    Check 'Get-PckitSnapshots видит снимок' (@(Get-PckitSnapshots).Count -eq 1)
    $rt = Compare-PckitSnapshot -Before $back -After $back
    Check 'сравнение после JSON-круга без исключений' ($rt.Count -ge 8)

    # 4. HTML
    $evil = [pscustomobject]@{ Metric = '<script>alert(1)</script>'; Before = '1'; After = '2'; Delta = '+1'; Verdict = 'лучше'; Note = 'x'; BeforeValue = 1; AfterValue = 2 }
    $fpsB = [pscustomobject]@{ Frames = 1000; AvgFps = 240; Low1Fps = 50; Low01Fps = 50; P99FrameMs = 20; DurationSec = 4 }
    $fpsA = [pscustomobject]@{ Frames = 1000; AvgFps = 260; Low1Fps = 60; Low01Fps = 55; P99FrameMs = 16.6; DurationSec = 4 }
    $html = Save-PckitCompareReport -Before $b -After $a -Rows (@($rows) + $evil) -Fps ([pscustomobject]@{ Before = $fpsB; After = $fpsA }) -OutDir (Join-Path $tmp 'reports')
    Check 'HTML создан' (Test-Path -LiteralPath $html)
    $text = [IO.File]::ReadAllText($html, [Text.Encoding]::UTF8)
    Check 'HTML: заголовок' ($text -match 'сравнение до/после')
    Check 'HTML: <script> экранирован' (($text -notmatch '<script>') -and ($text -match '&lt;script&gt;'))
    Check 'HTML: таблица FPS' ($text -match 'Средний FPS')

    # 5. CSV
    foreach ($col in 'MsBetweenPresents', 'FrameTime') {
        $csv = Join-Path $tmp ("fps-$col.csv")
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("Application,ProcessID,$col,Other")
        for ($i = 0; $i -lt 1000; $i++) {
            $ms = 4; if ($i % 100 -eq 99) { $ms = 20 }
            $lines.Add(('cs2.exe,1234,{0},0' -f $ms.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)))
        }
        [IO.File]::WriteAllLines($csv, $lines)
        $r = Read-PckitFpsCsv -Path $csv
        $expAvg = 1000.0 * 1000 / (990 * 4 + 10 * 20)
        Check "CSV $col : кадры" ($r.Frames -eq 1000)
        Check "CSV $col : AvgFps" (Near $r.AvgFps $expAvg 0.5) $r.AvgFps
        Check "CSV $col : Low1Fps ~ 50" (Near $r.Low1Fps 50 1) $r.Low1Fps
        Check "CSV $col : Low01Fps ~ 50" (Near $r.Low01Fps 50 1) $r.Low01Fps
        Check "CSV $col : P99 = 20 мс" (Near $r.P99FrameMs 20 0.1) $r.P99FrameMs
        Check "CSV $col : длительность 4,16 с" (Near $r.DurationSec 4.2 0.1) $r.DurationSec
    }

    # 6. выбор ассета
    $rel = '{"tag_name":"v2.3.1","assets":[
      {"name":"PresentMonCapture-2.3.1.msi","browser_download_url":"https://github.com/GameTechDev/PresentMon/releases/download/v2.3.1/PresentMonCapture-2.3.1.msi","size":100},
      {"name":"PresentMon-2.3.1-arm64.exe","browser_download_url":"https://github.com/GameTechDev/PresentMon/releases/download/v2.3.1/PresentMon-2.3.1-arm64.exe","size":200},
      {"name":"PresentMon-2.3.1.msi","browser_download_url":"https://github.com/GameTechDev/PresentMon/releases/download/v2.3.1/PresentMon-2.3.1.msi","size":300},
      {"name":"PresentMonService-2.3.1-x64.exe","browser_download_url":"https://x/PresentMonService-2.3.1-x64.exe","size":400},
      {"name":"PresentMon-2.3.1-x64.exe","browser_download_url":"https://github.com/GameTechDev/PresentMon/releases/download/v2.3.1/PresentMon-2.3.1-x64.exe","size":980320},
      {"name":"ReleaseSymbols.zip","browser_download_url":"https://x/ReleaseSymbols.zip","size":500}]}' | ConvertFrom-Json
    $asset = Select-PckitPresentMonAsset -Release $rel
    Check 'ассет: x64 exe консоли' ($asset.Name -eq 'PresentMon-2.3.1-x64.exe' -and $asset.Version -eq '2.3.1' -and $asset.SizeBytes -eq 980320 -and $asset.Url -like '*PresentMon-2.3.1-x64.exe') ($asset | Out-String)
    Check 'ассет: нет подходящего -> $null' ($null -eq (Select-PckitPresentMonAsset -Release ('{"tag_name":"v1","assets":[{"name":"a.msi"}]}' | ConvertFrom-Json)))
}
catch {
    $script:fail++
    Write-Host ('FAIL  исключение: {0}' -f $_.Exception.Message) -ForegroundColor Red
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:fail) { Write-Host ('ПРОВАЛЕНО: {0}' -f $script:fail) -ForegroundColor Red; exit 1 }
Write-Host 'ВСЕ ТЕСТЫ ПРОШЛИ' -ForegroundColor Green
exit 0
