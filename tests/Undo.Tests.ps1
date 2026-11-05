#Requires -Version 5.1
# pckit | тесты отката, защиты от чужого профиля и чистки. Запуск: powershell -NoProfile -File tests\Undo.Tests.ps1
# Систему не трогает: powercfg, cmd, schtasks и службы подменены функциями, файлы — во временной папке.
# Работает и в PowerShell 7 вне Windows (так его можно гонять в любом CI).

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$isWin = [Environment]::OSVersion.Platform -eq 'Win32NT'
$tmpBase = if ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
$tmp = Join-Path $tmpBase ('pckit-undo-test-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
if (-not $isWin) {
    # пути Windows для движка — внутри временной папки
    $env:USERPROFILE = Join-Path $tmp 'user'; $env:APPDATA = Join-Path $env:USERPROFILE 'AppData\Roaming'; $env:LOCALAPPDATA = Join-Path $env:USERPROFILE 'AppData\Local'
}

. (Join-Path $root 'engine\Common.ps1')
. (Join-Path $root 'engine\Recipes.ps1')
. (Join-Path $root 'engine\Planner.ps1')
. (Join-Path $root 'engine\Journal.ps1')
. (Join-Path $root 'engine\Actions.ps1')
. (Join-Path $root 'engine\Clean.ps1')
$script:PckitStateRoot = $tmp   # никогда не трогать настоящий %ProgramData%\pckit

$script:Pass = 0
$script:Fail = 0
function Assert-That {
    param([string]$Name, [bool]$Condition, [string]$Info = '')
    if ($Condition) { $script:Pass++; Write-Host ('PASS  {0}' -f $Name) -ForegroundColor Green }
    else { $script:Fail++; Write-Host ('FAIL  {0}  {1}' -f $Name, $Info) -ForegroundColor Red }
}

# ---------- поддельные powercfg / cmd / schtasks / службы ----------
$BAL = '381b4222-f694-41f0-9685-ff5bb260df2e'
$ULT = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$global:PC = @{ Active = $BAL; Schemes = @($BAL, '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c', $ULT); Values = @{} }
$global:Svc = @{}
$global:Tasks = @{}
function global:powercfg {
    $a = @($args | ForEach-Object { [string]$_ })
    $global:LASTEXITCODE = 0
    switch ($a[0]) {
        '/getactivescheme' { return ('GUID: {0}  (x)' -f $global:PC.Active) }
        '/setactive' {
            if ($a[1] -ieq 'scheme_current') { return }
            if ($global:PC.Schemes -contains $a[1]) { $global:PC.Active = $a[1] } else { $global:LASTEXITCODE = 1 }
            return
        }
        '/query' {
            $k = '{0}|{1}|{2}' -f $a[1], $a[2], $a[3]
            $ac = if ($global:PC.Values.ContainsKey("$k|ac")) { $global:PC.Values["$k|ac"] } else { 1 }
            $dc = if ($global:PC.Values.ContainsKey("$k|dc")) { $global:PC.Values["$k|dc"] } else { 1 }
            return @(('AC: 0x{0:x8}' -f $ac), ('DC: 0x{0:x8}' -f $dc))
        }
        '/setacvalueindex' { $global:PC.Values[('{0}|{1}|{2}|ac' -f $a[1], $a[2], $a[3])] = [int]$a[4]; return }
        '/setdcvalueindex' { $global:PC.Values[('{0}|{1}|{2}|dc' -f $a[1], $a[2], $a[3])] = [int]$a[4]; return }
    }
}
function global:cmd {
    $line = [string]$args[1]
    $global:LASTEXITCODE = 0
    foreach ($part in ($line -split '&&')) {
        $t = @($part.Trim() -split '\s+')
        if ($t[0] -eq 'powercfg') { $rest = @($t[1..($t.Count - 1)]); $null = powercfg @rest; continue }
        if ($part.Trim() -match '^sc config "(.+)" start= (\S+)$') { $global:Svc[$matches[1]].Start = $matches[2]; continue }
        if ($part.Trim() -match '^schtasks /Change /TN "(.+)" /ENABLE$') {
            if ($global:Tasks.ContainsKey($matches[1])) { $global:Tasks[$matches[1]] = 'Ready' } else { $global:LASTEXITCODE = 1 }
        }
    }
}
function global:schtasks { $global:LASTEXITCODE = $(if ($global:Tasks.ContainsKey([string]$args[2])) { 0 } else { 1 }) }
function global:Get-Service {
    param($Name, $ErrorAction)
    if ($global:Svc.ContainsKey($Name)) { [pscustomobject]@{ Name = $Name; Status = $(if ($global:Svc[$Name].Running) { 'Running' } else { 'Stopped' }) } }
}
function global:Start-Service {
    param($Name, $ErrorAction)
    if ($global:Svc[$Name].Start -eq 'disabled') { throw 'служба отключена' }
    $global:Svc[$Name].Running = $true
}

try {
    # ---------- 1. «Ускорить» -> «Вернуть как было»: схема питания возвращается ----------
    $actions = @(Get-PckitActions -Directory (Join-Path $root 'data') | Where-Object { $_.id -in 'power.plan', 'usb.suspend.off' })
    Assert-That 'в данных есть power.plan и usb.suspend.off' ($actions.Count -eq 2)
    $null = Invoke-PckitActions -Actions $actions -Run
    Assert-That 'после применения — максимальная схема' ($global:PC.Active -eq $ULT)
    $r = Restore-PckitJournal -Journal (Read-PckitJournal) -Run
    Assert-That 'откат вернул сбалансированную схему' ($r.Failed -eq 0 -and $global:PC.Active -eq $BAL) $global:PC.Active
    Assert-That 'откат вернул настройку USB' ($global:PC.Values[('{0}|2a737441-1930-4402-8d77-b2bebba308a3|48e6b7a6-50f5-4782-a5d4-53bb8f07e226|ac' -f $ULT)] -eq 1)

    # дважды «Ускорить» (вторая партия), затем полный откат
    $global:PC.Active = $BAL; $global:PC.Values = @{}
    $null = Invoke-PckitActions -Actions $actions -Run
    Start-Sleep -Seconds 1
    $null = Invoke-PckitActions -Actions @($actions | Where-Object { $_.id -eq 'power.plan' }) -Run
    $null = Restore-PckitJournal -Journal (Read-PckitJournal) -Run
    Assert-That 'два применения подряд: откат всё равно возвращает исходную схему' ($global:PC.Active -eq $BAL)

    # ---------- 2. порядок команд: обратный, запуск служб — в конце ----------
    $cmds = @(
        [pscustomobject]@{ undo = 'powercfg /setactive A' },
        [pscustomobject]@{ undo = 'sc config "S" start= auto' },
        [pscustomobject]@{ undo = 'net start "S"' },
        [pscustomobject]@{ undo = 'powercfg /setactive B' }
    )
    $order = @(Get-PckitUndoCommandOrder -Commands $cmds | ForEach-Object { $_.undo })
    Assert-That 'порядок отката: B, sc config, A, net start' (($order -join ' | ') -eq 'powercfg /setactive B | sc config "S" start= auto | powercfg /setactive A | net start "S"') ($order -join ' | ')

    # ---------- 3. откат не «застревает» ----------
    $global:Svc = @{ SysMain = @{ Start = 'disabled'; Running = $false } }
    $global:Tasks = @{ '\T\Here' = 'Disabled' }
    $j = New-PckitJournal
    Add-PckitCommandTracked -Journal $j -Undo 'sc config "SysMain" start= auto'
    Add-PckitCommandTracked -Journal $j -Undo 'net start "SysMain"'
    Add-PckitCommandTracked -Journal $j -Undo 'schtasks /Change /TN "\T\Here" /ENABLE'
    Add-PckitCommandTracked -Journal $j -Undo 'schtasks /Change /TN "\T\GoneAfterUpdate" /ENABLE'
    [void](Save-PckitJournal -Journal $j)
    $r = Restore-PckitJournal -Journal (Read-PckitJournal) -Run
    Assert-That 'пропавшая задача — пропуск, а не ошибка' ($r.Failed -eq 0 -and @($r.Items | Where-Object { $_.Status -eq 'skip' }).Count -eq 1)
    Assert-That 'служба включена и запущена' ($global:Svc.SysMain.Start -eq 'auto' -and $global:Svc.SysMain.Running)
    Assert-That 'журнал после отката пуст' (Test-PckitJournalEmpty -Journal (Read-PckitJournal))
    # уже запущенная служба — тоже не ошибка
    Add-PckitCommandTracked -Journal ($j = New-PckitJournal) -Undo 'net start "SysMain"'
    [void](Save-PckitJournal -Journal $j)
    Assert-That '«служба уже запущена» — не ошибка' ((Restore-PckitJournal -Journal (Read-PckitJournal) -Run).Failed -eq 0)
    # то, что не вернулось, остаётся в журнале одно, без уже вернувшегося
    $global:Svc = @{ X = @{ Start = 'disabled'; Running = $false } }
    $j = New-PckitJournal
    Add-PckitCommandTracked -Journal $j -Undo 'net start "X"'     # служба всё ещё отключена -> ошибка
    Add-PckitCommandTracked -Journal $j -Undo 'powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e'
    [void](Save-PckitJournal -Journal $j)
    $r = Restore-PckitJournal -Journal (Read-PckitJournal) -Run
    $left = Read-PckitJournal
    Assert-That 'в журнале осталась только неудачная запись' ($r.Failed -eq 1 -and @($left.commands).Count -eq 1 -and $left.commands[0].undo -eq 'net start "X"')
    [void](Save-PckitJournal -Journal (New-PckitJournal))

    # ---------- 4. чужой профиль ----------
    $m = '{"items":[
      {"id":"appdata:obs","kind":"appdata","title":"OBS","meta":{"recipe":"obs","steps":[{"type":"dir","payload":"p/1","target":"%APPDATA%\\obs-studio"}]}},
      {"id":"appdata:obs","kind":"appdata","title":"evil-dir","meta":{"recipe":"obs","steps":[{"type":"dir","payload":"p/2","target":"%APPDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\Startup"}]}},
      {"id":"appdata:7zip","kind":"appdata","title":"7zip","meta":{"recipe":"7zip","steps":[{"type":"registry","payload":"p/r.reg","target":"HKCU\\Software\\7-Zip"}]}},
      {"id":"appdata:7zip","kind":"appdata","title":"evil-reg","meta":{"recipe":"7zip","steps":[{"type":"registry","payload":"p/r.reg","target":"HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\Run"}]}},
      {"id":"files.desktop","kind":"files","title":"desk","payload":"p/d","meta":{"mode":"copy","target":"%USERPROFILE%\\Desktop"}},
      {"id":"files.desktop","kind":"files","title":"evil-files","payload":"p/d","meta":{"mode":"copy","target":"C:\\ProgramData\\Microsoft\\Windows\\Start Menu\\Programs\\StartUp"}},
      {"id":"dev.evil","kind":"dev","title":"evil-dev","payload":"p/NTUSER.DAT","meta":{"type":"file"}}
    ]}' | ConvertFrom-Json
    $plan = @(Get-PckitPlan -Manifest $m -CurrentIndex @{ ByName = @{}; ByWinget = @{} } 6>$null)
    $byTitle = { param($t) @($plan | Where-Object { $_.Title -like ($t + '*') })[0] }
    Assert-That 'профиль: путь из рецепта принят' ((& $byTitle 'OBS').Action -eq 'copy')
    Assert-That 'профиль: ветка из рецепта принята' ((& $byTitle '7zip').Action -eq 'regimport')
    Assert-That 'профиль: «Автозагрузка» вместо папки рецепта отклонена' ((& $byTitle 'evil-dir').Action -eq 'note')
    Assert-That 'профиль: HKLM\...\Run отклонён' ((& $byTitle 'evil-reg').Action -eq 'note')
    Assert-That 'профиль: подменённая папка «Рабочий стол» отклонена' ((& $byTitle 'evil-files').Action -eq 'note')
    Assert-That 'профиль: произвольный файл в профиль пользователя отклонён' ((& $byTitle 'evil-dev').Action -eq 'note')
    Assert-That 'профиль: нет пустого пункта «вручную»' (-not @($plan | Where-Object { $_.Action -eq 'manual' -and -not $_.Title }).Count)

    $reg = Join-Path $tmp 'a.reg'
    [IO.File]::WriteAllText($reg, "Windows Registry Editor Version 5.00`r`n`r`n[HKEY_CURRENT_USER\Software\7-Zip]`r`n`"Lang`"=`"ru`"`r`n`r`n[HKEY_CURRENT_USER\Software\7-Zip\FM]`r`n", [Text.Encoding]::Unicode)
    Assert-That '.reg: своя ветка — можно' ((Test-PckitRegFileScope -Path $reg -Key 'HKCU\Software\7-Zip').Safe)
    [IO.File]::AppendAllText($reg, "`r`n[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Run]`r`n`"x`"=`"c:\\evil.exe`"`r`n", [Text.Encoding]::Unicode)
    Assert-That '.reg: чужая ветка в файле — отказ' (-not (Test-PckitRegFileScope -Path $reg -Key 'HKCU\Software\7-Zip').Safe)
    $reg2 = Join-Path $tmp 'b.reg'
    [IO.File]::WriteAllText($reg2, "Windows Registry Editor Version 5.00`r`n`r`n[HKEY_CURRENT_USER\Software\7-ZipEvil]`r`n", [Text.Encoding]::Unicode)
    Assert-That '.reg: похожее имя ветки — отказ' (-not (Test-PckitRegFileScope -Path $reg2 -Key 'HKCU\Software\7-Zip').Safe)
    Assert-That '.reg: ветка не из HKCU\Software — отказ' (-not (Test-PckitRegFileScope -Path $reg2 -Key 'HKLM\Software\7-Zip').Safe)

    Assert-That 'переменные: обычная можно' ((Test-PckitEnvAllowed 'JAVA_HOME') -and (Test-PckitEnvAllowed 'GOPATH'))
    Assert-That 'переменные: COR_PROFILER, NODE_OPTIONS, PSModulePath — нельзя' (-not (Test-PckitEnvAllowed 'COR_PROFILER') -and -not (Test-PckitEnvAllowed 'node_options') -and -not (Test-PckitEnvAllowed 'PSModulePath'))

    if ($isWin) {
        Assert-That 'цель: папка внутри профиля — можно' ((Test-PckitRestoreTarget -Path '%APPDATA%\obs-studio').Safe)
        Assert-That 'цель: «Автозагрузка» — нельзя' (-not (Test-PckitRestoreTarget -Path '%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\x').Safe)
        Assert-That 'цель: вне профиля — нельзя' (-not (Test-PckitRestoreTarget -Path 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp').Safe)
    }

    # ---------- 5. чистка ----------
    $c = Join-Path $tmp 'clean'
    $mk = { param($t) [pscustomobject]@{ Id = $t[0]; Kind = 'dir'; Paths = @($t[1]); Risk = 'low'; Group = 'x' } }
    $targets = @(
        (& $mk @('discord.cache', (Join-Path $c 'discord\Cache\Cache_Data'))),
        (& $mk @('discord.code', (Join-Path $c 'discord\Code Cache'))),
        (& $mk @('work.discord', (Join-Path $c 'discord\Code Cache'))),
        (& $mk @('work.discord2', (Join-Path $c 'discord\Cache\Cache_Data\sub'))),
        (& $mk @('other', (Join-Path $c 'other')))
    )
    $ded = @(Remove-PckitCleanDuplicates -Targets $targets | ForEach-Object { $_.Id })
    Assert-That 'чистка: повторы путей убраны (кэш Discord не считается дважды)' (($ded -join ',') -eq 'discord.cache,discord.code,other') ($ded -join ',')

    # вложенная ссылка на «важную» папку: её содержимое не удаляется
    $cache = Join-Path $tmp 'cache'
    $important = Join-Path $tmp 'important'
    New-Item -ItemType Directory -Force -Path (Join-Path $cache 'sub\deeper'), $important | Out-Null
    Set-Content -LiteralPath (Join-Path $important 'doc.txt') -Value 'keep'
    Set-Content -LiteralPath (Join-Path $cache 'a.tmp') -Value 'x'
    Set-Content -LiteralPath (Join-Path $cache 'sub\deeper\b.tmp') -Value 'y'
    $linked = $false
    try {
        if ($isWin) { New-Item -ItemType Junction -Path (Join-Path $cache 'sub\link') -Target $important | Out-Null }
        else { New-Item -ItemType SymbolicLink -Path (Join-Path $cache 'sub\link') -Target $important | Out-Null }
        $linked = $true
    } catch { }
    $rm = Remove-PckitTreeContent -Path $cache
    Assert-That 'чистка: содержимое удалено' (-not @(Get-ChildItem -LiteralPath $cache -Force).Count) (@(Get-ChildItem -LiteralPath $cache -Force -Recurse | ForEach-Object { $_.FullName }) -join '; ')
    if ($linked) { Assert-That 'чистка: файлы по вложенной ссылке целы' (Test-Path -LiteralPath (Join-Path $important 'doc.txt')) }

    # исключения с путём (рецепт Telegram: user_data\cache)
    $pat = @('user_data\cache', '*.tmp', 'logs')
    Assert-That 'исключение с путём: user_data\cache\x — исключено' (Test-PckitPathMatch -RelativePath 'user_data\cache\x.bin' -Patterns $pat)
    Assert-That 'исключение с путём: user_data\stickers — нет' (-not (Test-PckitPathMatch -RelativePath 'user_data\stickers\a' -Patterns $pat))
    Assert-That 'исключение по имени работает как раньше' (Test-PckitPathMatch -RelativePath 'logs\a.log' -Patterns $pat)
} catch {
    $script:Fail++
    Write-Host ('FAIL  необработанное исключение: {0} (строка {1})' -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber) -ForegroundColor Red
} finally {
    foreach ($f in 'powercfg', 'cmd', 'schtasks', 'Get-Service', 'Start-Service') { Remove-Item -LiteralPath ('Function:\' + $f) -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ('Итого: PASS {0}, FAIL {1}' -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
