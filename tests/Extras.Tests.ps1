#Requires -Version 5.1
# pckit | тесты: драйвер NVIDIA (разбор ответов сайта), сеть (статистика и выводы), отчёт для друга, «шум» в результате.
# Запуск: powershell -NoProfile -File tests\Extras.Tests.ps1. В интернет не ходит, систему не меняет.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'engine\Common.ps1')
. (Join-Path $root 'engine\Journal.ps1')
. (Join-Path $root 'engine\Actions.ps1')
. (Join-Path $root 'engine\Health.ps1')
. (Join-Path $root 'engine\Snapshot.ps1')
. (Join-Path $root 'engine\Network.ps1')
. (Join-Path $root 'engine\Share.ps1')
. (Join-Path $root 'engine\Clean.ps1')

$tmp = Join-Path $env:TEMP ('pckit-extras-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:PckitStateRoot = $tmp

$script:Pass = 0; $script:Fail = 0
function Assert-That {
    param([string]$Name, [bool]$Condition, [string]$Info = '')
    if ($Condition) { $script:Pass++; Write-Host ('PASS  {0}' -f $Name) -ForegroundColor Green }
    else { $script:Fail++; Write-Host ('FAIL  {0}  {1}' -f $Name, $Info) -ForegroundColor Red }
}

try {
    # ---------- драйвер ----------
    Assert-That 'версия: 32.0.16.2101 → 621.01' ((ConvertTo-PckitNvidiaVersion '32.0.16.2101') -eq '621.01')
    Assert-That 'версия: 32.0.15.6094 → 560.94' ((ConvertTo-PckitNvidiaVersion '32.0.15.6094') -eq '560.94')
    Assert-That 'версия: 31.0.15.3623 → 536.23' ((ConvertTo-PckitNvidiaVersion '31.0.15.3623') -eq '536.23')
    Assert-That 'версия: мусор → $null' ($null -eq (ConvertTo-PckitNvidiaVersion 'abc'))
    Assert-That 'сравнение: старее' ((Compare-PckitDriverVersion '621.01' '621.14') -eq -1)
    Assert-That 'сравнение: та же' ((Compare-PckitDriverVersion '621.14' '621.14') -eq 0)
    Assert-That 'сравнение: новее' ((Compare-PckitDriverVersion '622.00' '621.14') -eq 1)

    $xml = "<?xml version=`"1.0`"?><LookupValueSearch><LookupValues>" +
        "<LookupValue ParentID=`"120`">`r<Name>GeForce RTX 3070 Ti</Name>`r<Value>965</Value></LookupValue>" +
        "<LookupValue ParentID=`"120`">`r<Name>GeForce RTX 3070</Name>`r<Value>933</Value></LookupValue>" +
        "<LookupValue ParentID=`"127`">`r<Name>NVIDIA GeForce RTX 4060</Name>`r<Value>1023</Value></LookupValue>" +
        "<LookupValue ParentID=`"101`">`r<Name>GeForce GTX 1060</Name>`r<Value>817</Value></LookupValue>" +
        "</LookupValues></LookupValueSearch>"
    $p = Find-PckitNvidiaProduct -GpuName 'NVIDIA GeForce RTX 3070' -LookupXml $xml
    Assert-That 'модель: точное совпадение, не Ti' ($p.Pfid -eq '933' -and $p.Psid -eq '120') $p.Pfid
    $p = Find-PckitNvidiaProduct -GpuName 'NVIDIA GeForce RTX 4060' -LookupXml $xml
    Assert-That 'модель: новое имя с «NVIDIA »' ($p.Pfid -eq '1023')
    $p = Find-PckitNvidiaProduct -GpuName 'NVIDIA GeForce GTX 1060 6GB' -LookupXml $xml
    Assert-That 'модель: GTX 1060 6GB → GTX 1060' ($p.Pfid -eq '817')
    Assert-That 'модель: нет в списке → $null' ($null -eq (Find-PckitNvidiaProduct -GpuName 'NVIDIA Quadro X' -LookupXml $xml))

    $json = '{ "Success" : "1", "IDS" : [{ "downloadInfo": { "Success" : "1", "Name" : "GeForce%20Game%20Ready%20Driver", "Version" : "621.14", "ReleaseDateTime" : "Wed Nov 04, 2026", "DetailsURL" : "https://www.nvidia.com/en-us/drivers/details/283968/", "DownloadURL" : "https://us.download.nvidia.com/x.exe", "DownloadURLFileSize" : "1.04 GB" } }] }'
    $l = ConvertFrom-PckitNvidiaLookup -Json $json
    Assert-That 'ответ NVIDIA: версия и имя' ($l.Version -eq '621.14' -and $l.Name -eq 'GeForce Game Ready Driver')
    Assert-That 'ответ NVIDIA: дата' ($l.Date -and ([datetime]$l.Date).ToString('yyyy-MM-dd') -eq '2026-11-04')
    Assert-That 'ответ NVIDIA: пустой → $null' ($null -eq (ConvertFrom-PckitNvidiaLookup -Json '{ "Success" : "0", "IDS" : [] }'))
    $c = Get-PckitDriverCheck -Hw ([pscustomobject]@{ GpuVendor = 'amd'; GpuName = 'AMD Radeon RX 6700 XT'; GpuDriverVersion = '31.0.1' })
    Assert-That 'не NVIDIA: в интернет не ходим, даём ссылку' ($c.Status -eq 'novendor' -and $c.Message -match 'amd.com')

    # ---------- сеть ----------
    $s = Get-PckitPingStats -Samples @(10, 12, $null, 11, 30)
    Assert-That 'пинг: потери' ($s.Lost -eq 1 -and $s.LossPct -eq 20)
    Assert-That 'пинг: медиана' ($s.Median -eq 11) $s.Median
    Assert-That 'пинг: джиттер' ([math]::Abs($s.Jitter - 7.33) -lt 0.1) $s.Jitter
    $s0 = Get-PckitPingStats -Samples @($null, $null)
    Assert-That 'пинг: всё потеряно' ($s0.LossPct -eq 100 -and $null -eq $s0.Median)

    $pop = { param($desc, $med, $jit, $loss) [pscustomobject]@{ Pop = [pscustomobject]@{ Desc = $desc }; Stats = [pscustomobject]@{ Median = $med; Jitter = $jit; LossPct = $loss } } }
    $goodGw = [pscustomobject]@{ Median = 1; Jitter = 0.3; LossPct = 0 }
    $v = Get-PckitNetworkVerdict -Gateway $goodGw -Pops @((& $pop 'Stockholm' 35 0.5 0)) -Loaded $null -IdleOfBest $null -WifiOnly $false
    Assert-That 'сеть: всё хорошо' ($v.Level -eq 'ok' -and ($v.Tips -join ' ') -match 'в порядке')
    $badGw = [pscustomobject]@{ Median = 6; Jitter = 18; LossPct = 3 }
    $v = Get-PckitNetworkVerdict -Gateway $badGw -Pops @((& $pop 'Stockholm' 70 20 3)) -Loaded $null -IdleOfBest $null -WifiOnly $true
    Assert-That 'сеть: Wi-Fi дома — виноват Wi-Fi' ($v.Level -eq 'bad' -and ($v.Tips -join ' ') -match 'Wi-Fi')
    $v = Get-PckitNetworkVerdict -Gateway $goodGw -Pops @((& $pop 'Frankfurt' 60 1 4)) -Loaded $null -IdleOfBest $null -WifiOnly $false
    Assert-That 'сеть: потери за домом — провайдер' (($v.Tips -join ' ') -match 'провайдер')
    $loaded = [pscustomobject]@{ Stats = [pscustomobject]@{ Median = 156; Jitter = 41; LossPct = 1.9 }; DownloadMbps = 81 }
    $v = Get-PckitNetworkVerdict -Gateway $goodGw -Pops @((& $pop 'Stockholm' 70 0.4 0)) -Loaded $loaded -IdleOfBest ([pscustomobject]@{ Median = 70 }) -WifiOnly $false
    $row = @($v.Rows | Where-Object { $_.Name -match 'качает' })[0]
    Assert-That 'сеть: рост пинга под нагрузкой найден' ($row.Verdict -eq 'bad' -and $row.Value -match '\+86') $row.Value
    Assert-That 'сеть: совет про SQM / паузу закачек' (($v.Tips -join ' ') -match 'SQM')
    $v = Get-PckitNetworkVerdict -Gateway $goodGw -Pops @((& $pop 'Far' 130 1 0)) -Loaded $null -IdleOfBest $null -WifiOnly $false
    Assert-That 'сеть: далёкие серверы' ((@($v.Rows | Where-Object { $_.Name -eq 'Ближайшие серверы' })[0]).Verdict -eq 'bad')

    # ---------- режим «Для работы» ----------
    $catalog = @(Get-PckitWorkCatalog)
    Assert-That 'работа: каталог программ читается' ($catalog.Count -ge 4)
    $badPaths = @()
    foreach ($c in $catalog) {
        foreach ($x in @($c.caches) + @($c.reports)) {
            if (-not $x) { continue }
            $p = [string]$x.path
            # только папки внутри профиля пользователя, никогда — системные или целые AppData
            if ($p -notmatch '^%(APPDATA|LOCALAPPDATA)%\\.+\\.+' ) { $badPaths += $p }
        }
    }
    Assert-That 'работа: все пути кэшей узкие и внутри профиля' ($badPaths.Count -eq 0) ($badPaths -join '; ')
    $allIds = @(Get-PckitActions -Directory (Join-Path $root 'data') | ForEach-Object { [string]$_.id })
    $missing = @(Get-PckitWorkProfileIds | Where-Object { $allIds -notcontains $_ })
    Assert-That 'работа: все действия рабочего набора существуют' ($missing.Count -eq 0) ($missing -join ', ')
    $gameOnly = @(Get-PckitWorkProfileIds | Where-Object { $_ -like 'nv.*' -or $_ -like 'cs2.*' -or $_ -like 'svc.*' -or $_ -like 'myth.*' })
    Assert-That 'работа: нет игровых, экспертных и мифов' ($gameOnly.Count -eq 0) ($gameOnly -join ', ')

    $fake = @(
        [pscustomobject]@{ Name = 'Adobe Photoshop 2025'; Location = (Join-Path $tmp 'ps') },
        [pscustomobject]@{ Name = 'Autodesk Revit 2025'; Location = '' },
        [pscustomobject]@{ Name = 'Notepad++'; Location = '' }
    )
    New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'ps\bin') | Out-Null
    Set-Content -LiteralPath (Join-Path $tmp 'ps\bin\Photoshop.exe') -Value 'x'
    $apps = @(Get-PckitWorkApps -Installed $fake)
    $ad = @($apps | Where-Object Id -eq 'adobe')[0]
    Assert-That 'работа: Photoshop найден' ($ad -and ($ad.Programs -contains 'Adobe Photoshop 2025'))
    Assert-That 'работа: exe найден в папке установки' ($ad -and (@($ad.Exes) -match 'Photoshop\.exe$').Count -ge 1) (@($ad.Exes) -join ', ')
    Assert-That 'работа: Revit найден' (@($apps | Where-Object Id -eq 'autodesk').Count -eq 1)
    Assert-That 'работа: чужие программы не цепляются' (@($apps | Where-Object { $_.Programs -contains 'Notepad++' }).Count -eq 0)
    $tg = @(Get-PckitWorkCleanTargets -Apps $apps)
    Assert-That 'работа: цели чистки — только безопасные кэши' (@($tg | Where-Object { $_.Risk -ne 'low' -or $_.Kind -ne 'dir' }).Count -eq 0)

    # ---------- исправления после ревью ----------
    $v = Get-PckitNetworkVerdict -Gateway $goodGw -Pops @((& $pop 'Stockholm' 70 0.4 0)) -Loaded ([pscustomobject]@{ Stats = [pscustomobject]@{ Median = 70; Jitter = 0; LossPct = 0 }; DownloadMbps = 0; Failed = $true }) -IdleOfBest ([pscustomobject]@{ Median = 70 }) -WifiOnly $false
    $row = @($v.Rows | Where-Object { $_.Name -match 'качает' })[0]
    Assert-That 'сеть: закачка не пошла — не «+0 мс, в порядке»' ($row.Value -match 'не проверено' -and $row.Verdict -ne 'ok') $row.Value
    $env:USERNAME_SAVE = $env:USERNAME
    try {
        $env:USERNAME = 'user'
        $s1 = Hide-PckitPersonal 'UserGpuPreferences в C:\Users\user\Desktop и c:\users\USER'
        Assert-That 'отчёт: короткое имя не портит слова' ($s1 -match 'UserGpuPreferences' -and $s1 -notmatch '(?i)\\users\\user(\\|$)' -and $s1 -match '<пользователь>') $s1
    } finally { $env:USERNAME = $env:USERNAME_SAVE }

    # откат партии: значение, уже записанное прошлой партией, попадает и в новую
    $tk = 'HKCU:\Software\pckit-test-batch'
    New-Item -Path $tk -Force | Out-Null
    Set-ItemProperty -LiteralPath $tk -Name 'V' -Value 'orig'
    $j = New-PckitJournal
    $script:PckitBatchSince = '2026-01-01T10:00:00'
    Add-PckitRegTracked -Journal $j -Path $tk -Name 'V' -Value 'b1' -Type String
    $j.registry[0].at = '2026-01-01T10:00:01'
    Set-ItemProperty -LiteralPath $tk -Name 'V' -Value 'manual'
    $script:PckitBatchSince = '2026-01-01T11:00:00'
    Add-PckitRegTracked -Journal $j -Path $tk -Name 'V' -Value 'b2' -Type String
    Add-PckitRegTracked -Journal $j -Path $tk -Name 'V' -Value 'b2' -Type String
    $script:PckitBatchSince = $null
    Assert-That 'журнал: новая партия пишет своё «до», внутри партии — один раз' (@($j.registry).Count -eq 2)
    Save-PckitJournal -Journal $j | Out-Null
    function Restore-PckitNvidiaJournal { param($Entries, [switch]$Run) return @() }
    [void](Restore-PckitJournal -Journal (Read-PckitJournal) -Run -Since '2026-01-01T11:00:00')
    Assert-That 'откат партии вернул значение до неё' ((Get-ItemProperty -LiteralPath $tk).V -eq 'manual') (Get-ItemProperty -LiteralPath $tk).V
    [void](Restore-PckitJournal -Journal (Read-PckitJournal) -Run)
    Assert-That 'полный откат вернул исходное' ((Get-ItemProperty -LiteralPath $tk).V -eq 'orig') (Get-ItemProperty -LiteralPath $tk).V
    Remove-Item -LiteralPath $tk -Recurse -Force

    # ---------- «шум» в сравнении ----------
    $fmt = { param($x) '{0:N0}' -f $x }
    Assert-That 'процессов +3 — шум' ((Get-PckitBandRow 'Процессов' 167 170 10 $fmt).Verdict -eq 'в пределах шума')
    Assert-That 'процессов −25 — лучше' ((Get-PckitBandRow 'Процессов' 170 145 10 $fmt).Verdict -eq 'лучше')
    Assert-That 'служб +9 — хуже' ((Get-PckitBandRow 'Служб' 90 99 4 $fmt).Verdict -eq 'хуже')

    # ---------- отчёт для друга ----------
    $hw = [pscustomobject]@{ GpuVendor = 'nvidia'; GpuName = 'NVIDIA GeForce RTX 3070'; GpuDriverVersion = '32.0.16.2101'; GpuDriverDate = (Get-Date '2026-10-19')
        HybridGpu = $false; GpuList = @(); CpuName = 'AMD Ryzen 5 5600X'; CpuCores = 6; CpuThreads = 12; RamGb = 32; RamType = 'DDR4'; RamMhz = 3200; RamRatedMhz = 3200; RamModules = 2
        SystemSsd = $true; SystemDiskName = 'Samsung'; Displays = @([pscustomobject]@{ Primary = $true; Width = 1920; Height = 1080; Hz = 144; MaxHz = 280 })
        PrimaryHz = 144; PrimaryMaxHz = 280; Build = 26300; Laptop = $false; OnBattery = $false; WifiOnly = $false; WiredNetwork = $true; Hags = $true
        Cs2Path = 'C:\x'; Cs2Video = [pscustomobject]@{ Width = 1280; Height = 960; RefreshHz = 144; Fullscreen = 1; VSync = 1; LowLatency = 0 } }
    $health = [pscustomobject]@{ Bad = 1; Warn = 0; Findings = @(
            (New-PckitFinding -Severity 'bad' -Title ('Путь {0}\Desktop <script>' -f $env:USERPROFILE) -Detail ('ПК {0}' -f $env:COMPUTERNAME))) }
    $html = New-PckitShareReport -Hw $hw -Health $health -ActionStates @() -Plan @() -JournalCount 5 -Network $null
    Assert-That 'отчёт: HTML-документ' ($html.StartsWith('<!DOCTYPE html>') -and $html.Contains('</html>'))
    Assert-That 'отчёт: нет пути профиля' (-not $html.Contains($env:USERPROFILE))
    Assert-That 'отчёт: нет имени ПК' (-not ($html -match [regex]::Escape($env:COMPUTERNAME)))
    Assert-That 'отчёт: текст экранирован' (-not $html.Contains('<script>'))
    Assert-That 'отчёт: монитор не на максимуме отмечен красным' ($html -match 'class="bad"><th>Монитор')
    Assert-That 'отчёт: версия NVIDIA показана' ($html -match '621\.01')
    $path = Save-PckitShareReport -Html $html -Folder $tmp
    Assert-That 'отчёт: сохранён с BOM (кириллица в любом браузере)' ((Test-Path -LiteralPath $path) -and [IO.File]::ReadAllBytes($path)[0] -eq 0xEF)
} catch {
    $script:Fail++
    Write-Host ('FAIL  необработанное исключение: {0} (строка {1})' -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber) -ForegroundColor Red
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ('Итого: PASS {0}, FAIL {1}' -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
