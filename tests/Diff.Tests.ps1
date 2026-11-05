#Requires -Version 5.1
# тест tools\pckit-diff.ps1: скрипт только читает; сравнение снимков находит добавленное/удалённое/изменённое
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $root 'tools\pckit-diff.ps1'
$tmp = Join-Path $env:TEMP 'pckit-diff-test'
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$pass = 0; $fail = 0
function Check([string]$Name, [bool]$Ok) {
    if ($Ok) { $script:pass++; Write-Host ('PASS  ' + $Name) -ForegroundColor Green }
    else { $script:fail++; Write-Host ('FAIL  ' + $Name) -ForegroundColor Red }
}

# 1. синтаксис, BOM и «только чтение»
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($tool, [ref]$null, [ref]$errors)
Check 'скрипт без синтаксических ошибок' (@($errors).Count -eq 0)
$head = [IO.File]::ReadAllBytes($tool)[0..2]
Check 'UTF-8 BOM' ($head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF)
$code = [IO.File]::ReadAllText($tool, [Text.Encoding]::UTF8)
$writers = 'Set-ItemProperty|New-ItemProperty|Remove-Item|Remove-ItemProperty|Set-Service|Stop-Service|Start-Service|Disable-ScheduledTask|Enable-ScheduledTask|Register-ScheduledTask|reg\s+add|reg\s+delete|bcdedit\s+/set|powercfg\s+/(setactive|change|setacvalueindex|setdcvalueindex)|netsh\s+\S+\s+\S+\s+set|OpenSubKey\([^)]*\$true|CreateSubKey|SetValue|DeleteValue|Set-MpPreference'
Check 'в скрипте нет команд записи в систему' (-not ($code -match $writers))

# 2. сравнение двух синтетических снимков
function New-Snap($reg, $svc) {
    [ordered]@{
        meta = [ordered]@{ time = '2026-01-01T00:00:00'; admin = $true; tool = 'pckit-diff'; schema = 1 }
        'Реестр' = $reg; 'Службы' = $svc
    } | ConvertTo-Json -Depth 5
}
$utf8 = New-Object Text.UTF8Encoding($true)
$a = Join-Path $tmp 'a.json'; $b = Join-Path $tmp 'b.json'
[IO.File]::WriteAllText($a, (New-Snap @{ 'HKCU\X|Same' = 'DWord:1'; 'HKCU\X|Changed' = 'DWord:0'; 'HKCU\X|Gone' = 'DWord:5'; 'HKCU\Explorer\UserAssist|noise' = 'x' } @{ 'SysMain' = 'Auto; svchost' }), $utf8)
[IO.File]::WriteAllText($b, (New-Snap @{ 'HKCU\X|Same' = 'DWord:1'; 'HKCU\X|Changed' = 'DWord:1'; 'HKCU\X|New' = 'DWord:7'; 'HKCU\Explorer\UserAssist|noise' = 'y' } @{ 'SysMain' = 'Disabled; svchost' }), $utf8)
$report = Join-Path $tmp 'report.md'
$out = (& powershell -NoProfile -ExecutionPolicy Bypass -File $tool -Before $a -After $b -Report $report) -join "`n"
# вывод дочернего powershell идёт в кодировке консоли (стрелка → становится ?) — проверяем по файлу отчёта
if (Test-Path -LiteralPath $report) { $out = $out + "`n" + [IO.File]::ReadAllText($report) }
Check 'изменённое значение показано' ($out -match 'HKCU\\X\|Changed: DWord:0 → DWord:1')
Check 'добавленное значение показано' ($out -match '\+` HKCU\\X\|New = DWord:7')
Check 'удалённое значение показано' ($out -match '-` HKCU\\X\|Gone')
Check 'неизменное не попадает в отчёт' (-not ($out -match 'X\|Same'))
Check 'шум (UserAssist) отфильтрован' (-not ($out -match 'UserAssist'))
Check 'изменение типа запуска службы показано' ($out -match 'SysMain: Auto; svchost → Disabled; svchost')
Check 'отчёт записан в файл' (Test-Path -LiteralPath $report)
$all = (& powershell -NoProfile -ExecutionPolicy Bypass -File $tool -Before $a -After $b -NoFilter) -join "`n"
Check '-NoFilter возвращает шум' ($all -match 'UserAssist')
$same = (& powershell -NoProfile -ExecutionPolicy Bypass -File $tool -Before $a -After $a) -join "`n"
Check 'одинаковые снимки — «Отличий не найдено»' ($same -match 'Отличий не найдено')

# 3. живой снимок (только чтение)
$snapPath = Join-Path $tmp 'live.json'
& powershell -NoProfile -ExecutionPolicy Bypass -File $tool -Snapshot $snapPath | Out-Null
Check 'снимок создан' (Test-Path -LiteralPath $snapPath)
$s = Get-Content -LiteralPath $snapPath -Raw -Encoding UTF8 | ConvertFrom-Json
Check 'в снимке есть реестр (> 100 значений)' (@($s.'Реестр'.PSObject.Properties).Count -gt 100)
Check 'в снимке есть службы' (@($s.'Службы'.PSObject.Properties).Count -gt 20)
Check 'в снимке есть активная схема питания' ([bool]$s.'Электропитание'.'активная схема')
Check 'в снимке есть GameConfigStore или GraphicsDrivers' (@($s.'Реестр'.PSObject.Properties.Name | Where-Object { $_ -match 'GameConfigStore|GraphicsDrivers' }).Count -gt 0)
Check 'два подряд снимка почти не отличаются (шум < 50)' ($(
    $snap2 = Join-Path $tmp 'live2.json'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $tool -Snapshot $snap2 | Out-Null
    $d = (& powershell -NoProfile -ExecutionPolicy Bypass -File $tool -Before $snapPath -After $snap2) -join "`n"
    ($d -match 'Что изменилось') -and ([regex]::Matches($d, '(?m)^- `[+~-]`')).Count -lt 50
))

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ('{0} пройдено, {1} провалено' -f $pass, $fail)
if ($fail) { exit 1 }