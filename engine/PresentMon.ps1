#Requires -Version 5.1
# pckit engine | presentmon: опциональный замер FPS через Intel PresentMon (консольное приложение v2)
# PresentMon читает только ETW-события Windows (презенты кадров), в процесс игры не вмешивается и ничего не внедряет.
# В интерфейсе запускать ТОЛЬКО вне матчей FACEIT (античит не любит сторонние трассировщики во время матча).
# Скачивание — только из интерфейса после согласия пользователя; exe проверяется по подписи Intel.
# Флаги CLI взяты из официального README-ConsoleApplication.md (GameTechDev/PresentMon, ветка main).

function Get-PckitToolsDir {
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = Join-Path $env:USERPROFILE 'AppData\Local' }
    $dir = Join-Path $base 'pckit\tools'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return $dir
}

function Find-PckitPresentMon {
    $dir = Join-Path (Get-PckitToolsDir) 'PresentMon'
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $exe = Get-ChildItem -LiteralPath $dir -Filter 'PresentMon*.exe' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'x64' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($exe) { return $exe.FullName }
    return $null
}

function Select-PckitPresentMonAsset {
    # чистая функция: из JSON релиза выбирает консольное x64-приложение PresentMon-<ver>-x64.exe
    # (в релизе также лежат .msi установщика с UI/службой и ReleaseSymbols.zip — они не нужны)
    param($Release)
    if (-not $Release) { return $null }
    $version = ([string]$Release.tag_name).TrimStart('v', 'V')
    foreach ($a in @($Release.assets)) {
        if ([string]$a.name -match '^PresentMon-\d+(\.\d+)*(-[A-Za-z0-9]+)?-x64\.exe$') {
            return [pscustomobject]@{ Version = $version; Name = [string]$a.name; Url = [string]$a.browser_download_url; SizeBytes = [int64]$a.size }
        }
    }
    return $null
}

function Get-PckitPresentMonRelease {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/GameTechDev/PresentMon/releases/latest' -UserAgent 'pckit' -Headers @{ Accept = 'application/vnd.github+json' } -TimeoutSec 20
    $asset = Select-PckitPresentMonAsset -Release $rel
    if (-not $asset) { throw 'в последнем релизе PresentMon нет консольного приложения x64 (.exe)' }
    return $asset
}

function Install-PckitPresentMon {
    # вызывать ТОЛЬКО из интерфейса после согласия пользователя
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Name)
    $Name = Split-Path -Leaf $Name
    if ($Name -notmatch '^PresentMon-[\w\.\-]+\.exe$') { throw 'неожиданное имя файла PresentMon' }
    if ($Url -notmatch '^https://github\.com/GameTechDev/PresentMon/releases/download/') { throw 'адрес загрузки не из официального репозитория PresentMon' }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

    $dir = Join-Path (Get-PckitToolsDir) 'PresentMon'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = Join-Path $dir ($Name + '.part')
    $final = Join-Path $dir $Name
    try {
        Invoke-WebRequest -Uri $Url -OutFile $tmp -UserAgent 'pckit' -UseBasicParsing -TimeoutSec 300
        $sig = Get-AuthenticodeSignature -LiteralPath $tmp
        $subject = ''
        if ($sig.SignerCertificate) { $subject = [string]$sig.SignerCertificate.Subject }
        if ($sig.Status -ne 'Valid' -or $subject -notmatch 'Intel') {
            throw 'подпись не прошла проверку'
        }
        if (Test-Path -LiteralPath $final) { Remove-Item -LiteralPath $final -Force }
        Move-Item -LiteralPath $tmp -Destination $final -Force
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        throw
    }
    return $final
}

function Invoke-PckitFpsCapture {
    # Флаги (README-ConsoleApplication.md): --process_name, --output_file, --timed, --terminate_after_timed,
    # --stop_existing_session, --no_console_stats
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string]$ProcessName = 'cs2.exe',
        [int]$Seconds = 60,
        [Parameter(Mandatory)][string]$OutCsv
    )
    if (-not (Test-Path -LiteralPath $Exe)) { throw 'PresentMon не найден' }
    $procBase = [IO.Path]::GetFileNameWithoutExtension($ProcessName)
    if (-not @(Get-Process -Name $procBase -ErrorAction SilentlyContinue).Count) {
        throw ('процесс {0} не запущен: запустите CS2 и зайдите на карту' -f $ProcessName)
    }
    $dir = Split-Path -Parent $OutCsv
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if (Test-Path -LiteralPath $OutCsv) { Remove-Item -LiteralPath $OutCsv -Force }

    $argLine = '--process_name {0} --output_file "{1}" --timed {2} --terminate_after_timed --stop_existing_session --no_console_stats' -f $ProcessName, $OutCsv, $Seconds
    $p = Start-Process -FilePath $Exe -ArgumentList $argLine -WindowStyle Hidden -Wait -PassThru
    $exists = Test-Path -LiteralPath $OutCsv
    return [pscustomobject]@{ Csv = $(if ($exists) { $OutCsv } else { $null }); ExitCode = $p.ExitCode; Ok = ($exists -and $p.ExitCode -eq 0) }
}

function Get-PckitSlowestFrame {
    # кадр на границе худшей доли Fraction: при 1000 кадрах и 1% — 10-й по медленности
    param([double[]]$SortedDesc, [double]$Fraction)
    if (-not $SortedDesc.Count) { return $null }
    $idx = [int][math]::Ceiling($SortedDesc.Count * $Fraction) - 1
    if ($idx -lt 0) { $idx = 0 }
    if ($idx -ge $SortedDesc.Count) { $idx = $SortedDesc.Count - 1 }
    return $SortedDesc[$idx]
}

function Read-PckitFpsCsv {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw 'CSV не найден' }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $times = New-Object 'System.Collections.Generic.List[double]'
    $reader = New-Object System.IO.StreamReader($Path, [Text.Encoding]::UTF8)
    try {
        $header = $reader.ReadLine()
        if (-not $header) { throw 'CSV пустой' }
        $cols = @($header.TrimStart([char]0xFEFF).Split(',') | ForEach-Object { $_.Trim().Trim('"') })
        $idx = -1
        foreach ($name in 'FrameTime', 'MsBetweenPresents') {
            $idx = [array]::IndexOf($cols, $name)
            if ($idx -ge 0) { break }
        }
        if ($idx -lt 0) { throw 'в CSV нет колонки FrameTime или MsBetweenPresents' }
        while ($null -ne ($line = $reader.ReadLine())) {
            if (-not $line) { continue }
            $parts = $line.Split(',')
            if ($parts.Length -le $idx) { continue }
            $v = 0.0
            if ([double]::TryParse($parts[$idx].Trim('"'), [Globalization.NumberStyles]::Float, $inv, [ref]$v) -and $v -gt 0) { $times.Add($v) }
        }
    } finally { $reader.Dispose() }

    if (-not $times.Count) { throw 'в CSV нет кадров' }
    $sum = 0.0
    foreach ($t in $times) { $sum += $t }
    $desc = [double[]]($times.ToArray() | Sort-Object -Descending)
    $p99 = Get-PckitSlowestFrame $desc 0.01
    $p999 = Get-PckitSlowestFrame $desc 0.001
    return [pscustomobject]@{
        Frames      = $times.Count
        AvgFps      = [math]::Round(1000.0 * $times.Count / $sum, 2)
        Low1Fps     = [math]::Round(1000.0 / $p99, 2)
        Low01Fps    = [math]::Round(1000.0 / $p999, 2)
        P99FrameMs  = [math]::Round($p99, 3)
        DurationSec = [math]::Round($sum / 1000.0, 1)
    }
}
