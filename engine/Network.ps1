#Requires -Version 5.1
# pckit engine | network: пинг, скачки (джиттер) и потери до серверов Valve для CS2, до роутера и под нагрузкой.
# Серверы берутся из официального списка Steam Datagram Relay (api.steampowered.com, ISteamApps/GetSDRConfig, appid 730):
# через эти узлы идёт трафик матчей CS2. Только пинг (ICMP) и, по согласию, тестовое скачивание с speed.cloudflare.com.

function Get-PckitSdrPops {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $j = Invoke-RestMethod -Uri 'https://api.steampowered.com/ISteamApps/GetSDRConfig/v1/?appid=730' -TimeoutSec 15 -UserAgent 'pckit' -ErrorAction Stop
    $list = New-Object System.Collections.ArrayList
    foreach ($p in $j.pops.PSObject.Properties) {
        $ips = @(@($p.Value.relays) | ForEach-Object { [string]$_.ipv4 } | Where-Object { $_ })
        if (-not $ips.Count) { continue }
        [void]$list.Add([pscustomobject]@{ Code = [string]$p.Name; Desc = [string]$p.Value.desc; Ips = $ips })
    }
    return $list.ToArray()
}

# статистика по массиву задержек (мс; $null = потеря)
function Get-PckitPingStats {
    param([object[]]$Samples)
    $ok = @($Samples | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    $sent = @($Samples).Count
    $lost = $sent - $ok.Count
    $res = [ordered]@{ Sent = $sent; Lost = $lost; LossPct = 0.0; Median = $null; Min = $null; Max = $null; Jitter = $null }
    if ($sent -gt 0) { $res.LossPct = [math]::Round(100.0 * $lost / $sent, 1) }
    if ($ok.Count) {
        $sorted = @($ok | Sort-Object)
        $res.Median = $sorted[[int][math]::Floor(($sorted.Count - 1) / 2)]
        $res.Min = $sorted[0]; $res.Max = $sorted[-1]
        # джиттер — средняя разница между соседними пингами (как в RFC 3550, без сглаживания)
        if ($ok.Count -ge 2) {
            $sum = 0.0
            for ($i = 1; $i -lt $ok.Count; $i++) { $sum += [math]::Abs($ok[$i] - $ok[$i - 1]) }
            $res.Jitter = [math]::Round($sum / ($ok.Count - 1), 1)
        } else { $res.Jitter = 0 }
    }
    return [pscustomobject]$res
}

function Measure-PckitPing {
    param([string]$Address, [int]$Count = 40, [int]$IntervalMs = 50, [int]$TimeoutMs = 1000)
    $ping = New-Object System.Net.NetworkInformation.Ping
    $samples = New-Object System.Collections.ArrayList
    try {
        for ($i = 0; $i -lt $Count; $i++) {
            $r = $null
            try { $r = $ping.Send($Address, $TimeoutMs) } catch { }
            if ($r -and $r.Status -eq 'Success') { [void]$samples.Add([double]$r.RoundtripTime) } else { [void]$samples.Add($null) }
            if ($IntervalMs -gt 0) { Start-Sleep -Milliseconds $IntervalMs }
        }
    } finally { $ping.Dispose() }
    return (Get-PckitPingStats -Samples $samples.ToArray())
}

# по одному пингу на все узлы сразу — чтобы найти ближайшие
function Find-PckitNearestPops {
    param($Pops, [int]$Take = 3)
    $tasks = New-Object System.Collections.ArrayList
    foreach ($p in $Pops) {
        $ping = New-Object System.Net.NetworkInformation.Ping
        [void]$tasks.Add([pscustomobject]@{ Pop = $p; Ping = $ping; Task = $ping.SendPingAsync($p.Ips[0], 1500) })
    }
    try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($tasks | ForEach-Object { $_.Task }), 4000) } catch { }
    $res = New-Object System.Collections.ArrayList
    foreach ($t in $tasks) {
        try {
            if ($t.Task.IsCompleted -and -not $t.Task.IsFaulted -and $t.Task.Result.Status -eq 'Success') {
                [void]$res.Add([pscustomobject]@{ Pop = $t.Pop; Ms = [double]$t.Task.Result.RoundtripTime })
            }
        } catch { }
        $t.Ping.Dispose()
    }
    return @($res | Sort-Object Ms | Select-Object -First $Take)
}

function Get-PckitGateway {
    try {
        $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
            Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
        if ($r) { return [string]$r.NextHop }
    } catch { }
    return $null
}

# пинг под нагрузкой: 3 потока качают тестовые данные (в память, на диск ничего не пишется), параллельно пингуем
function Measure-PckitLoadedPing {
    param([string]$Address, [int]$Seconds = 10, [int]$MaxMbPerStream = 100)
    $shared = [hashtable]::Synchronized(@{ Stop = $false; Bytes = [long]0 })
    # Cloudflare отдаёт не больше ~50 МБ за запрос — качаем кусками по 25 МБ по кругу, пока не скажут «стоп»
    $worker = {
        param($shared, $url, $maxBytes)
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        $buf = New-Object byte[] 65536
        $total = [long]0
        while (-not $shared.Stop -and $total -lt $maxBytes) {
            $req = [System.Net.HttpWebRequest]::Create($url)
            $req.UserAgent = 'pckit'
            $req.Timeout = 15000
            $resp = $req.GetResponse()
            try {
                $stream = $resp.GetResponseStream()
                while (-not $shared.Stop -and $total -lt $maxBytes) {
                    $n = $stream.Read($buf, 0, $buf.Length)
                    if ($n -le 0) { break }
                    $total += $n
                    [System.Threading.Monitor]::Enter($shared.SyncRoot)
                    try { $shared.Bytes += $n } finally { [System.Threading.Monitor]::Exit($shared.SyncRoot) }
                }
            } finally { $resp.Close() }
        }
    }
    $jobs = New-Object System.Collections.ArrayList
    $maxBytes = [long]$MaxMbPerStream * 1000000
    try {
        for ($i = 0; $i -lt 3; $i++) {
            $ps = [powershell]::Create()
            [void]$ps.AddScript($worker).AddArgument($shared).AddArgument('https://speed.cloudflare.com/__down?bytes=25000000').AddArgument($maxBytes)
            [void]$jobs.Add([pscustomobject]@{ Ps = $ps; Async = $ps.BeginInvoke() })
        }
        Start-Sleep -Milliseconds 1500   # разгон закачки
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $b0 = $shared.Bytes
        $count = [math]::Max(10, [int]($Seconds * 1000 / 150))
        $stats = Measure-PckitPing -Address $Address -Count $count -IntervalMs 100
        $sec = $sw.Elapsed.TotalSeconds
        $b1 = $shared.Bytes
        $mbps = if ($sec -gt 0) { [math]::Round(($b1 - $b0) * 8 / 1e6 / $sec, 0) } else { $null }
        # меньше ~1 МБ за время замера — нагрузки не было (нет доступа к тестовому серверу), сравнивать нечего
        $failed = (($b1 - $b0) -lt 1000000)
        return [pscustomobject]@{ Stats = $stats; DownloadMbps = $mbps; DownloadedMb = [math]::Round($b1 / 1e6, 0); Failed = $failed }
    } finally {
        $shared.Stop = $true
        foreach ($j in $jobs) {
            try { [void]$j.Async.AsyncWaitHandle.WaitOne(5000) } catch { }
            try { $j.Ps.Stop() } catch { }
            $j.Ps.Dispose()
        }
    }
}
function New-PckitNetRow {
    param([string]$Name, [string]$Value, [string]$Verdict, [string]$Note = '')
    return [pscustomobject]@{ Name = $Name; Value = $Value; Verdict = $Verdict; Note = $Note }
}

# выводы по замерам: строки таблицы + короткие советы
function Get-PckitNetworkVerdict {
    param($Gateway, $Pops, $Loaded, $IdleOfBest, [bool]$WifiOnly)
    $rows = New-Object System.Collections.ArrayList
    $tips = New-Object System.Collections.ArrayList
    $worst = 'ok'
    $bump = { param($lvl) if ($lvl -eq 'bad') { $script:__w = 'bad' } elseif ($lvl -eq 'warn' -and $script:__w -ne 'bad') { $script:__w = 'warn' } }
    $script:__w = 'ok'

    if ($Gateway) {
        $lvl = 'ok'
        if ($Gateway.LossPct -gt 0 -or ($Gateway.Median -ne $null -and $Gateway.Median -gt 10) -or ($Gateway.Jitter -ne $null -and $Gateway.Jitter -gt 5)) { $lvl = 'warn' }
        if ($Gateway.LossPct -ge 2 -or ($Gateway.Jitter -ne $null -and $Gateway.Jitter -gt 15)) { $lvl = 'bad' }
        & $bump $lvl
        [void]$rows.Add((New-PckitNetRow 'До роутера (дома)' ('{0} мс, скачки {1} мс, потери {2}%' -f $Gateway.Median, $Gateway.Jitter, $Gateway.LossPct) $lvl 'должно быть 1–3 мс и 0% потерь'))
        if ($lvl -ne 'ok') {
            if ($WifiOnly) { [void]$tips.Add('Проблема уже дома, между ПК и роутером: Wi-Fi. Кабель решит это полностью; если нельзя — 5 ГГц и роутер поближе.') }
            else { [void]$tips.Add('Проблема уже дома, между ПК и роутером: проверьте кабель и порт, перезагрузите роутер.') }
        }
    }

    foreach ($p in @($Pops)) {
        $s = $p.Stats
        $lvl = 'ok'
        if ($s.LossPct -gt 0 -or ($s.Jitter -ne $null -and $s.Jitter -gt 5)) { $lvl = 'warn' }
        if ($s.LossPct -ge 2 -or ($s.Jitter -ne $null -and $s.Jitter -gt 12) -or $null -eq $s.Median) { $lvl = 'bad' }
        & $bump $lvl
        $val = if ($null -eq $s.Median) { 'не отвечает' } else { ('{0} мс, скачки {1} мс, потери {2}%' -f $s.Median, $s.Jitter, $s.LossPct) }
        [void]$rows.Add((New-PckitNetRow ('Серверы Valve: {0}' -f $p.Pop.Desc) $val $lvl 'через эти узлы идут матчи CS2'))
    }
    $best = @($Pops | Where-Object { $null -ne $_.Stats.Median } | Sort-Object { $_.Stats.Median }) | Select-Object -First 1
    if ($best) {
        $m = [double]$best.Stats.Median
        $txt = if ($m -le 40) { 'отличный пинг для CS2' } elseif ($m -le 70) { 'нормальный пинг' } elseif ($m -le 100) { 'играбельно, но заметно' } else { 'высокий пинг — сервера далеко' }
        [void]$rows.Add((New-PckitNetRow 'Ближайшие серверы' ('{0}: {1} мс' -f $best.Pop.Desc, $m) $(if ($m -le 70) { 'ok' } elseif ($m -le 100) { 'warn' } else { 'bad' }) $txt))
        if (@($Pops | Where-Object { $_.Stats.LossPct -gt 0 }).Count -and -not ($Gateway -and $Gateway.LossPct -gt 0)) {
            [void]$tips.Add('Пакеты теряются за пределами дома — это у провайдера или по пути до серверов. Запишите время и напишите провайдеру; ПК тут не виноват.')
        }
        if ($best.Stats.Jitter -gt 5 -and -not ($Gateway -and $Gateway.Jitter -gt 5)) {
            [void]$tips.Add('Пинг «скачет» на пути к серверам. Если так каждый вечер — вероятно, перегружен канал провайдера.')
        }
    }

    if ($Loaded -and $Loaded.Failed) {
        [void]$rows.Add((New-PckitNetRow 'Пинг, когда кто-то качает' 'не проверено: тестовая закачка не пошла' 'warn' 'нет доступа к speed.cloudflare.com — повторите позже'))
    } elseif ($Loaded -and $IdleOfBest -and $null -ne $Loaded.Stats.Median -and $null -ne $IdleOfBest.Median) {
        $delta = [math]::Round([double]$Loaded.Stats.Median - [double]$IdleOfBest.Median, 0)
        $lvl = if ($delta -le 15) { 'ok' } elseif ($delta -le 50) { 'warn' } else { 'bad' }
        & $bump $lvl
        $speed = if ($Loaded.DownloadMbps) { (' (скорость скачивания ~{0} Мбит/с)' -f $Loaded.DownloadMbps) } else { '' }
        [void]$rows.Add((New-PckitNetRow 'Пинг, когда кто-то качает' ('+{0} мс, потери {1}%{2}' -f $delta, $Loaded.Stats.LossPct, $speed) $lvl 'рост до 15 мс — норма'))
        if ($lvl -ne 'ok') {
            [void]$tips.Add(('Когда дома что-то качается (Steam, торрент, видео), пинг растёт на {0} мс — отсюда лаги «то есть, то нет». Ставьте закачки на паузу перед матчем или включите в роутере SQM / Smart QoS.' -f $delta))
        }
    }

    if ($script:__w -eq 'ok' -and -not $tips.Count) { [void]$tips.Add('Сеть в порядке: если в игре лагает — дело не в интернете, смотрите «Проверку» и FPS.') }
    return [pscustomobject]@{ Level = $script:__w; Rows = $rows.ToArray(); Tips = $tips.ToArray() }
}

function Invoke-PckitNetworkTest {
    param([switch]$LoadTest, [bool]$WifiOnly = $false)
    $gwIp = Get-PckitGateway
    $gw = $null
    if ($gwIp) { $gw = Measure-PckitPing -Address $gwIp -Count 30 -IntervalMs 30 -TimeoutMs 500 }

    $pops = @(Get-PckitSdrPops)
    $near = @(Find-PckitNearestPops -Pops $pops -Take 3)
    $measured = New-Object System.Collections.ArrayList
    foreach ($n in $near) {
        $st = Measure-PckitPing -Address $n.Pop.Ips[0] -Count 40 -IntervalMs 50
        [void]$measured.Add([pscustomobject]@{ Pop = $n.Pop; Ip = $n.Pop.Ips[0]; Stats = $st })
    }

    $loaded = $null; $idle = $null
    $best = @($measured | Where-Object { $null -ne $_.Stats.Median } | Sort-Object { $_.Stats.Median }) | Select-Object -First 1
    if ($LoadTest -and $best) {
        $idle = $best.Stats
        try { $loaded = Measure-PckitLoadedPing -Address $best.Ip -Seconds 10 } catch { $loaded = $null }
    }
    $verdict = Get-PckitNetworkVerdict -Gateway $gw -Pops $measured.ToArray() -Loaded $loaded -IdleOfBest $idle -WifiOnly $WifiOnly
    return [pscustomobject]@{
        Time     = (Get-Date).ToString('s')
        Gateway  = $gw
        GatewayIp = $gwIp
        Pops     = $measured.ToArray()
        Loaded   = $loaded
        Verdict  = $verdict
    }
}
