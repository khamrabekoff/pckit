#Requires -Version 5.1
# pckit engine | driver: сравнить установленный драйвер NVIDIA с последним на сайте NVIDIA.
# Только чтение: ничего не скачивает и не ставит — даёт ссылку на официальную страницу драйвера.
# Источники: справочник моделей www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=3
# и поиск драйвера gfwsl.geforce.com/.../AjaxDriverService.php (их же использует сайт NVIDIA).

# версия Windows-драйвера 32.0.16.2101 -> версия NVIDIA 621.01
function ConvertTo-PckitNvidiaVersion {
    param([string]$WindowsVersion)
    $parts = @($WindowsVersion -split '\.')
    if ($parts.Count -lt 4) { return $null }
    $digits = ($parts[2] + $parts[3].PadLeft(4, '0'))
    if ($digits.Length -lt 5) { return $null }
    $tail = $digits.Substring($digits.Length - 5)
    return ('{0}.{1}' -f [int]$tail.Substring(0, 3), $tail.Substring(3, 2))
}

function Compare-PckitDriverVersion {
    # -1 — установленная старее, 0 — та же, 1 — новее (бета/ноутбучная ветка)
    param([string]$Installed, [string]$Latest)
    try {
        $a = [version]$Installed; $b = [version]$Latest
        if ($a -lt $b) { return -1 } elseif ($a -gt $b) { return 1 } else { return 0 }
    } catch { return 0 }
}

function Invoke-PckitWebText {
    param([string]$Url, [int]$TimeoutSec = 12)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -UserAgent 'pckit' -ErrorAction Stop
    return [string]$r.Content
}

# модель видеокарты -> { Psid, Pfid, Name } по справочнику NVIDIA; $null, если не нашлась
function Find-PckitNvidiaProduct {
    param([string]$GpuName, [string]$LookupXml)
    $want = ($GpuName -replace '^NVIDIA\s+', '' -replace '\s+', ' ').Trim()
    $best = $null
    foreach ($m in [regex]::Matches($LookupXml, '<LookupValue ParentID="(\d+)">\s*<Name>([^<]+)</Name>\s*<Value>(\d+)</Value>')) {
        # в справочнике новые модели записаны с «NVIDIA », старые — без
        $name = ([System.Net.WebUtility]::HtmlDecode($m.Groups[2].Value) -replace '^NVIDIA\s+', '').Trim()
        if ($name -ieq $want) { return [pscustomobject]@{ Psid = $m.Groups[1].Value; Pfid = $m.Groups[3].Value; Name = $name } }
        if (-not $best -and $want -like ($name + '*') -and $name.Length -ge 10) {
            $best = [pscustomobject]@{ Psid = $m.Groups[1].Value; Pfid = $m.Groups[3].Value; Name = $name }
        }
    }
    return $best
}

function ConvertFrom-PckitNvidiaLookup {
    param([string]$Json)
    $data = $Json | ConvertFrom-Json
    $info = @($data.IDS)[0].downloadInfo
    if (-not $info -or [string]$info.Success -ne '1') { return $null }
    $date = $null
    try { $date = [datetime]::ParseExact(([string]$info.ReleaseDateTime).Substring(4), 'MMM dd, yyyy', [Globalization.CultureInfo]::InvariantCulture) } catch { }
    return [pscustomobject]@{
        Version     = [string]$info.Version
        Name        = [Uri]::UnescapeDataString([string]$info.Name)
        Date        = $date
        DetailsUrl  = [string]$info.DetailsURL
        DownloadUrl = [string]$info.DownloadURL
        Size        = [string]$info.DownloadURLFileSize
    }
}

# итог проверки: { Status = ok|outdated|newer|novendor|offline|unknown, Installed, Latest, Product, Message }
function Get-PckitDriverCheck {
    param($Hw)
    if (-not $Hw) { $Hw = Get-PckitHardwareProfile }
    $res = [ordered]@{ Status = 'unknown'; Installed = $null; Latest = $null; Product = $null; Message = ''; Gpu = [string]$Hw.GpuName }

    if ($Hw.GpuVendor -ne 'nvidia') {
        $res.Status = 'novendor'
        $res.Message = switch ($Hw.GpuVendor) {
            'amd' { 'Для AMD: свежий драйвер — на amd.com/support (AMD Software: Adrenalin).' }
            'intel' { 'Для Intel: свежий драйвер — через Intel Driver & Support Assistant.' }
            default { 'Проверка драйвера пока только для NVIDIA.' }
        }
        return [pscustomobject]$res
    }

    $res.Installed = ConvertTo-PckitNvidiaVersion -WindowsVersion $Hw.GpuDriverVersion
    try {
        $xml = Invoke-PckitWebText -Url 'https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=3'
        $product = Find-PckitNvidiaProduct -GpuName $Hw.GpuName -LookupXml $xml
        $exact = [bool]$product
        # не нашли модель — берём актуальную ветку настольных GeForce: номер версии у них общий
        if (-not $product) { $product = [pscustomobject]@{ Psid = '120'; Pfid = '929'; Name = 'GeForce RTX 30 (общая ветка)' } }
        $res.Product = $product.Name
        $os = if ([Environment]::OSVersion.Version.Build -ge 22000) { '135' } else { '57' }
        $url = 'https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&psid={0}&pfid={1}&osID={2}&languageCode=1033&beta=0&isWHQL=1&dltype=-1&dch=1&upCRD=0&qnf=0&sort1=0&numberOfResults=1' -f $product.Psid, $product.Pfid, $os
        $latest = ConvertFrom-PckitNvidiaLookup -Json (Invoke-PckitWebText -Url $url)
        if (-not $latest) { $res.Status = 'unknown'; $res.Message = 'NVIDIA не вернула данные о драйвере.'; return [pscustomobject]$res }
        $res.Latest = $latest
        if (-not $res.Installed) { $res.Status = 'unknown'; $res.Message = 'Не удалось прочитать версию установленного драйвера.'; return [pscustomobject]$res }
        switch (Compare-PckitDriverVersion -Installed $res.Installed -Latest $latest.Version) {
            -1 { $res.Status = 'outdated' }
            0 { $res.Status = 'ok' }
            1 { $res.Status = 'newer' }
        }
        if (-not $exact) { $res.Message = 'Модель не нашлась в справочнике NVIDIA — сравнил с общей веткой GeForce.' }
    } catch {
        $res.Status = 'offline'
        $res.Message = ('Не удалось связаться с сайтом NVIDIA: {0}' -f $_.Exception.Message)
    }
    return [pscustomobject]$res
}
