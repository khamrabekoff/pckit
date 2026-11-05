#Requires -Version 5.1
# pckit engine | clean: what can be deleted, how much it frees, and safe deletion
# (ported from CleanPC 2.1 items 3-4: чистка диска и игровая чистка)
#
# Kind цели: 'dir' (содержимое папок), 'recycle' (корзина), 'files' (файлы по маскам Patterns, не рекурсивно),
# 'dism' (штатная очистка WinSxS, размер заранее неизвестен: SizeMb = -1), 'info' (ничего не удаляет, только Link).

function Get-PckitChromiumProfileCachePaths {
    # папки кэша внутри одного профиля Chromium (только существующие)
    param([string]$ProfileDir)

    $out = New-Object System.Collections.ArrayList
    if (-not $ProfileDir -or -not (Test-Path -LiteralPath $ProfileDir)) { return @() }
    $cacheData = Join-Path $ProfileDir 'Cache\Cache_Data'
    $cacheOld = Join-Path $ProfileDir 'Cache'
    if (Test-Path -LiteralPath $cacheData) { [void]$out.Add($cacheData) }
    elseif (Test-Path -LiteralPath $cacheOld) { [void]$out.Add($cacheOld) }
    foreach ($name in 'Code Cache', 'GPUCache') {
        $p = Join-Path $ProfileDir $name
        if (Test-Path -LiteralPath $p) { [void]$out.Add($p) }
    }
    return $out.ToArray()
}

function Get-PckitChromiumCachePaths {
    # корень "User Data": все профили (Default, Profile *, Guest Profile)
    param([string]$UserDataRoot)

    $out = New-Object System.Collections.ArrayList
    if (-not $UserDataRoot -or -not (Test-Path -LiteralPath $UserDataRoot)) { return @() }
    $profiles = @(Get-ChildItem -LiteralPath $UserDataRoot -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'Default' -or $_.Name -eq 'Guest Profile' -or $_.Name -like 'Profile *' })
    foreach ($pr in $profiles) {
        foreach ($p in @(Get-PckitChromiumProfileCachePaths -ProfileDir $pr.FullName)) { [void]$out.Add($p) }
    }
    return $out.ToArray()
}

function Get-PckitCleanTargets {
    $steamRoot = $null
    $steamShader = $null
    try {
        $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
        if ($steam) {
            $steamRoot = ($steam -replace '/', '\')
            $candidate = Join-Path $steamRoot 'steamapps\shadercache'
            if (Test-Path -LiteralPath $candidate) { $steamShader = $candidate }
        }
    } catch { }

    $targets = New-Object System.Collections.ArrayList

    $add = {
        param($Id, $Group, $Title, $What, $Paths, $Risk, $Admin, $Kind = 'dir', $Note = '', $Patterns = @(), $Link = '')

        [void]$targets.Add([pscustomobject]@{
                Id       = $Id
                Group    = $Group
                Title    = $Title
                What     = $What
                Paths    = @($Paths | Where-Object { $_ })
                Risk     = $Risk
                Admin    = [bool]$Admin
                Kind     = $Kind
                Note     = $Note
                Patterns = @($Patterns | Where-Object { $_ })
                Link     = $Link
            })
    }

    # добавляет цель, только если хотя бы один из путей существует на этом ПК
    $addIfExists = {
        param($Id, $Group, $Title, $What, $Paths, $Risk, $Admin, $Kind = 'dir', $Note = '', $Patterns = @(), $Link = '')

        $existing = @(@($Paths) | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
        if ($existing.Count -eq 0) { return }
        & $add $Id $Group $Title $What $existing $Risk $Admin $Kind $Note $Patterns $Link
    }

    & $add 'temp.user' 'Временные файлы' 'Временные файлы программ' `
        'Сюда пишут установщики и программы. Удаление безопасно: активные файлы пропускаются.' `
        @($env:TEMP) 'low' $false

    & $add 'temp.windows' 'Временные файлы' 'Временная папка Windows' `
        'Служебный Temp самой Windows. Безопасно, но нужны права администратора.' `
        @((Join-Path $env:SystemRoot 'Temp')) 'low' $true

    & $add 'updates.download' 'Обновления' 'Кэш скачанных обновлений Windows' `
        'Уже установленные обновления остаются; удаляется только скачанное. Освобождает чаще всего 1–5 ГБ.' `
        @((Join-Path $env:SystemRoot 'SoftwareDistribution\Download')) 'medium' $true

    & $add 'do.cache' 'Обновления' 'Кэш доставки обновлений (Delivery Optimization)' `
        'Копии обновлений для раздачи другим ПК. Удаление безопасно.' `
        @((Join-Path $env:ProgramData 'Microsoft\Windows\DeliveryOptimization\Cache')) 'low' $true

    & $add 'wer.reports' 'Отчёты' 'Отчёты о падениях программ' `
        'Дампы и отчёты Windows Error Reporting. Нужны только для разбора сбоев.' `
        @((Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive')) 'low' $true

    & $add 'crash.dumps' 'Отчёты' 'Дампы падений приложений' `
        'Файлы CrashDumps от упавших программ. Могут занимать гигабайты.' `
        @((Join-Path $env:LOCALAPPDATA 'CrashDumps')) 'low' $false

    # --- браузеры на Chromium: все профили ---
    $chromiumDefs = @(
        @{ Id = 'chrome.cache'; Title = 'Кэш Google Chrome'; Root = 'Google\Chrome\User Data'
            What = 'Кэш страниц и скриптов во всех профилях. Закладки, пароли и история не затрагиваются.' },
        @{ Id = 'edge.cache'; Title = 'Кэш Microsoft Edge'; Root = 'Microsoft\Edge\User Data'
            What = 'Кэш страниц и скриптов во всех профилях. Закладки и пароли не затрагиваются.' },
        @{ Id = 'brave.cache'; Title = 'Кэш Brave'; Root = 'BraveSoftware\Brave-Browser\User Data'
            What = 'Кэш страниц и скриптов во всех профилях. Закладки, пароли и история не затрагиваются.' },
        @{ Id = 'yandex.cache'; Title = 'Кэш Яндекс Браузера'; Root = 'Yandex\YandexBrowser\User Data'
            What = 'Кэш страниц и скриптов во всех профилях. Закладки, пароли и история не затрагиваются.' },
        @{ Id = 'vivaldi.cache'; Title = 'Кэш Vivaldi'; Root = 'Vivaldi\User Data'
            What = 'Кэш страниц и скриптов во всех профилях. Закладки, пароли и история не затрагиваются.' }
    )
    foreach ($def in $chromiumDefs) {
        $root = Join-Path $env:LOCALAPPDATA $def.Root
        if (-not (Test-Path -LiteralPath $root)) { continue }
        & $add $def.Id 'Браузеры' $def.Title $def.What @(Get-PckitChromiumCachePaths -UserDataRoot $root) 'low' $false
    }

    # Opera: без профилей, кэш прямо в папке программы
    $operaPaths = @()
    foreach ($op in 'Opera Stable', 'Opera GX Stable') {
        $operaPaths += @(Get-PckitChromiumProfileCachePaths -ProfileDir (Join-Path $env:LOCALAPPDATA ('Opera Software\' + $op)))
    }
    if ($operaPaths.Count -gt 0) {
        & $add 'opera.cache' 'Браузеры' 'Кэш Opera / Opera GX' `
            'Кэш страниц и скриптов. Закладки, пароли и история не затрагиваются.' `
            $operaPaths 'low' $false
    }

    # Firefox: кэш лежит в Local, а куки/пароли/история — в Roaming
    $ffPaths = @()
    $ffProfiles = Join-Path $env:LOCALAPPDATA 'Mozilla\Firefox\Profiles'
    if (Test-Path -LiteralPath $ffProfiles) {
        foreach ($pr in @(Get-ChildItem -LiteralPath $ffProfiles -Directory -Force -ErrorAction SilentlyContinue)) {
            foreach ($n in 'cache2', 'startupCache', 'jumpListCache', 'thumbnails') {
                $p = Join-Path $pr.FullName $n
                if (Test-Path -LiteralPath $p) { $ffPaths += $p }
            }
        }
    }
    if ($ffPaths.Count -gt 0) {
        & $add 'firefox.cache' 'Браузеры' 'Кэш Mozilla Firefox' `
            'Кэш страниц и миниатюры. Куки, пароли, история — в другой папке, не затрагиваются.' `
            $ffPaths 'low' $false
    }

    # --- программы ---
    $discordPaths = @()
    foreach ($d in 'discord', 'discordptb', 'discordcanary') {
        $discordPaths += @(Get-PckitChromiumProfileCachePaths -ProfileDir (Join-Path $env:APPDATA $d))
    }
    if ($discordPaths.Count -gt 0) {
        & $add 'discord.cache' 'Программы' 'Кэш Discord' `
            'Кэш картинок и скриптов. Вход и настройки не теряются.' `
            $discordPaths 'low' $false 'dir' 'Закройте Discord — иначе часть файлов пропустится.'
    }

    # --- игровые кэши (шейдеры): честно про лаги после очистки ---
    $shaderWarn = ' После очистки первые катки/карты будут подлагивать, пока кэш не соберётся заново — чистить, только если есть проблемы с графикой или нужно место.'

    & $add 'shader.nvidia' 'Игровые кэши' 'Кэш шейдеров NVIDIA' `
        ('Кэш скомпилированных шейдеров.' + $shaderWarn) `
        @((Join-Path $env:LOCALAPPDATA 'NVIDIA\DXCache'),
        (Join-Path $env:LOCALAPPDATA 'NVIDIA\GLCache'),
        (Join-Path $env:ProgramData 'NVIDIA Corporation\NV_Cache')) 'medium' $false

    & $add 'shader.dx' 'Игровые кэши' 'Кэш шейдеров DirectX' `
        ('Общий кэш D3D.' + $shaderWarn) `
        @((Join-Path $env:LOCALAPPDATA 'D3DSCache')) 'medium' $false

    & $add 'shader.amd' 'Игровые кэши' 'Кэш шейдеров AMD' `
        ('Кэш видеокарт Radeon.' + $shaderWarn) `
        @((Join-Path $env:LOCALAPPDATA 'AMD\DxCache'),
        (Join-Path $env:LOCALAPPDATA 'AMD\GLCache')) 'medium' $false

    if ($steamShader) {
        & $add 'steam.shader' 'Игровые кэши' 'Кэш шейдеров Steam' `
            ('Кэш шейдеров для игр Steam.' + $shaderWarn) `
            @($steamShader) 'medium' $false
    }

    # --- игровые лаунчеры ---
    $steamWeb = @((Join-Path $env:LOCALAPPDATA 'Steam\htmlcache'))
    $steamLogs = @()
    if ($steamRoot) {
        $steamWeb += (Join-Path $steamRoot 'appcache\httpcache')
        $steamLogs = @((Join-Path $steamRoot 'logs'), (Join-Path $steamRoot 'dumps'))
    }
    & $addIfExists 'steam.web' 'Игровые лаунчеры' 'Веб-кэш Steam' `
        'Кэш встроенного браузера Steam (магазин, сообщество, оверлей). Игры и сохранения не затрагиваются.' `
        $steamWeb 'low' $false
    & $addIfExists 'steam.logs' 'Игровые лаунчеры' 'Логи и дампы Steam' `
        'Служебные журналы и дампы падений Steam. Нужны только для разбора сбоев.' `
        $steamLogs 'low' $false

    $epicPaths = @()
    $epicSaved = Join-Path $env:LOCALAPPDATA 'EpicGamesLauncher\Saved'
    if (Test-Path -LiteralPath $epicSaved) {
        $epicPaths += @(Get-ChildItem -LiteralPath $epicSaved -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'webcache*' } | ForEach-Object { $_.FullName })
        $epicPaths += (Join-Path $epicSaved 'Logs')
    }
    & $addIfExists 'epic.cache' 'Игровые лаунчеры' 'Кэш Epic Games Launcher' `
        'Веб-кэш и журналы лаунчера. Игры и вход не затрагиваются.' `
        $epicPaths 'low' $false

    & $addIfExists 'battlenet.cache' 'Игровые лаунчеры' 'Кэш Battle.net' `
        'Кэш лаунчера Blizzard. Игры не затрагиваются, кэш соберётся заново.' `
        @((Join-Path $env:ProgramData 'Battle.net\Cache'),
        (Join-Path $env:LOCALAPPDATA 'Battle.net\Cache'),
        (Join-Path $env:APPDATA 'Battle.net\Cache')) 'low' $true

    # --- система ---
    & $add 'thumbs.cache' 'Система' 'Кэш миниатюр и значков Проводника' `
        'Миниатюры картинок пересоберутся; часть файлов занята Проводником и будет пропущена — это нормально.' `
        @((Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer')) 'low' $false 'files' '' @('thumbcache_*.db', 'iconcache_*.db')

    # маски объединены: *.log в CBS/DISM/DataStore\Logs, *.cab в CBS, *.etl в WindowsUpdate
    # (в этих служебных папках других файлов с такими расширениями, нужных системе, нет)
    $winLogDirs = @(
        (Join-Path $env:SystemRoot 'Logs\CBS'),
        (Join-Path $env:SystemRoot 'Logs\DISM'),
        (Join-Path $env:SystemRoot 'SoftwareDistribution\DataStore\Logs'),
        (Join-Path $env:SystemRoot 'Logs\WindowsUpdate'))
    & $add 'windows.logs' 'Система' 'Журналы обслуживания Windows' `
        'Логи CBS, DISM и Центра обновлений. Нужны только для разбора сбоев обновления.' `
        $winLogDirs 'low' $true 'files' '' @('*.log', '*.cab', '*.etl')

    & $add 'winsxs.cleanup' 'Система' 'Сжать хранилище компонентов Windows (WinSxS)' `
        'Штатная очистка Microsoft: удаляет старые версии системных файлов, заменённые обновлениями. Обычно 0,5–5 ГБ.' `
        @() 'low' $true 'dism' 'Занимает 5–30 минут.'

    & $add 'drivers.old' 'Система' 'Старые версии драйверов' `
        'Устаревшие копии драйверов в хранилище Windows (DriverStore), которые заменены более новой версией того же драйвера. Новейшая версия и всё, что сейчас используется устройствами, остаются. Перед удалением покажу список.' `
        @() 'medium' $true 'drivers' 'Необратимо: удалённую версию можно вернуть только переустановкой драйвера.'

    $windowsOld = Join-Path $env:SystemDrive 'Windows.old'
    if (Test-Path -LiteralPath $windowsOld) {
        & $add 'windows.old' 'Система' 'Предыдущая установка Windows (Windows.old)' `
            'Копия прошлой Windows после обновления. Удалить: Параметры → Система → Память → Временные файлы → «Предыдущие установки Windows». После удаления откат на прошлую версию невозможен.' `
            @($windowsOld) 'medium' $true 'info' '' @() 'ms-settings:storagepolicies'
    }

    # --- разработка ---
    & $addIfExists 'dev.caches' 'Разработка' 'Кэши pip, npm, NuGet' `
        'Пакеты скачаются заново при следующей установке.' `
        @((Join-Path $env:LOCALAPPDATA 'pip\Cache'),
        (Join-Path $env:LOCALAPPDATA 'npm-cache'),
        (Join-Path $env:APPDATA 'npm-cache'),
        (Join-Path $env:LOCALAPPDATA 'NuGet\v3-cache')) 'low' $false

    & $add 'recycle.bin' 'Корзина' 'Корзина' `
        'Файлы, которые вы уже удалили. Восстановить их после очистки нельзя.' `
        @() 'medium' $false 'recycle'

    # кэши найденных рабочих программ (Adobe, Autodesk, Teams, Discord…)
    try { foreach ($wt in @(Get-PckitWorkCleanTargets)) { [void]$targets.Add($wt) } } catch { }

    return (Remove-PckitCleanDuplicates -Targets $targets.ToArray())
}

# одна и та же папка не должна попасть в две цели (кэш Discord есть и в общих целях, и в рабочих программах):
# иначе сумма «освобожу примерно» больше, чем потом удаляется. Путь внутри уже взятого — тоже повтор.
function Remove-PckitCleanDuplicates {
    param([object[]]$Targets)
    $taken = New-Object System.Collections.ArrayList
    $out = New-Object System.Collections.ArrayList
    foreach ($t in @($Targets)) {
        if ($t.Kind -notin 'dir', 'files') { [void]$out.Add($t); continue }
        $kept = @()
        foreach ($p in @($t.Paths)) {
            $full = Resolve-PckitPath ([string]$p)
            $dup = $false
            foreach ($q in $taken) {
                if ($full -ieq $q.Path -or ($q.Kind -eq 'dir' -and (Test-PckitUnderRoot -Path $full -Root $q.Path))) { $dup = $true; break }
            }
            if (-not $dup) { $kept += $p }
        }
        if (-not $kept.Count) { continue }
        foreach ($p in $kept) { [void]$taken.Add([pscustomobject]@{ Path = (Resolve-PckitPath ([string]$p)); Kind = $t.Kind }) }
        $t.Paths = @($kept)
        [void]$out.Add($t)
    }
    return $out.ToArray()
}

function Get-PckitMatchingFiles {
    # файлы прямо в папке (не рекурсивно), подходящие под любую из масок
    param([string]$Folder, [string[]]$Patterns)

    if (-not $Patterns -or $Patterns.Count -eq 0) { return @() }
    return @(Get-ChildItem -LiteralPath $Folder -File -Force -ErrorAction SilentlyContinue |
            Where-Object {
                $n = $_.Name
                foreach ($pat in $Patterns) { if ($n -like $pat) { return $true } }
                return $false
            })
}

function Get-PckitCleanSize {
    param($Target)

    if ($Target.Kind -eq 'recycle') {
        try {
            $shell = New-Object -ComObject Shell.Application
            $bin = $shell.Namespace(10)
            $sum = 0
            if ($bin) {
                foreach ($item in @($bin.Items())) { $sum += [double]$item.Size }
            }
            return [pscustomobject]@{ SizeMb = [math]::Round($sum / 1MB, 1); Files = @($bin.Items()).Count }
        } catch {
            return [pscustomobject]@{ SizeMb = 0; Files = 0 }
        }
    }

    if ($Target.Kind -eq 'dism') {
        # размер хранилища компонентов заранее не посчитать
        return [pscustomobject]@{ SizeMb = -1; Files = 0 }
    }

    if ($Target.Kind -eq 'drivers') {
        $old = @(Get-PckitOldDrivers)
        $mb = ($old | Measure-Object -Property SizeMb -Sum).Sum
        if (-not $mb) { $mb = 0 }
        return [pscustomobject]@{ SizeMb = [math]::Round($mb, 1); Files = $old.Count }
    }

    $sum = 0.0
    $count = 0
    foreach ($path in @($Target.Paths)) {
        $resolved = Resolve-PckitPath $path
        if (-not $resolved -or -not (Test-Path -LiteralPath $resolved)) { continue }
        try {
            if ($Target.Kind -eq 'files') {
                $files = @(Get-PckitMatchingFiles -Folder $resolved -Patterns $Target.Patterns)
            } else {
                $files = Get-ChildItem -LiteralPath $resolved -Recurse -File -Force -ErrorAction SilentlyContinue
            }
            $sum += ($files | Measure-Object -Property Length -Sum).Sum
            $count += @($files).Count
        } catch { }
    }
    return [pscustomobject]@{ SizeMb = [math]::Round($sum / 1MB, 1); Files = $count }
}

function Get-PckitCleanSizes {
    param($Targets)

    $result = New-Object System.Collections.ArrayList
    foreach ($t in $Targets) {
        $size = Get-PckitCleanSize -Target $t
        [void]$result.Add([pscustomobject]@{
                Target = $t
                SizeMb = $size.SizeMb
                Files  = $size.Files
            })
    }
    return $result.ToArray()
}

# удалить содержимое папки, не заходя в junction/symlink на любой глубине (они удаляются как ссылки):
# Remove-Item -Recurse в Windows PowerShell 5.1 может пройти по вложенной ссылке и стереть чужие файлы.
# Файлы удаляются по одному — занятый пропускается, остальное в той же папке всё равно чистится.
function Remove-PckitTreeContent {
    param([string]$Path)
    $bytes = 0.0; $deleted = 0; $skipped = 0
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        try {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                if ($item.PSIsContainer) { [IO.Directory]::Delete($item.FullName, $false) }
                else { [IO.File]::Delete($item.FullName) }
                $deleted++
                continue
            }
            if ($item.PSIsContainer) {
                $sub = Remove-PckitTreeContent -Path $item.FullName
                $bytes += $sub.Bytes; $deleted += $sub.Deleted; $skipped += $sub.Skipped
                if ($sub.Skipped -eq 0) {
                    try { [IO.Directory]::Delete($item.FullName, $false); $deleted++ } catch { $skipped++ }
                }
            } else {
                $size = [double]$item.Length
                if ($item.Attributes -band [IO.FileAttributes]::ReadOnly) { $item.Attributes = $item.Attributes -bxor [IO.FileAttributes]::ReadOnly }
                [IO.File]::Delete($item.FullName)
                $bytes += $size
                $deleted++
            }
        } catch {
            $skipped++
        }
    }
    return [pscustomobject]@{ Bytes = $bytes; Deleted = $deleted; Skipped = $skipped }
}

function Remove-PckitFolderContent {
    param([string]$Path)

    $freed = 0.0
    $deleted = 0
    $skipped = 0

    $resolved = Resolve-PckitPath $Path
    if (-not $resolved -or -not (Test-Path -LiteralPath $resolved)) {
        return [pscustomobject]@{ FreedMb = 0; Deleted = 0; Skipped = 0 }
    }

    $guard = Test-PckitSafePath -Path $resolved -AllowSystem
    if (-not $guard.Safe) {
        throw ('чистка отменена: {0} ({1})' -f $guard.Reason, $resolved)
    }

    $r = Remove-PckitTreeContent -Path $resolved
    $freed = $r.Bytes; $deleted = $r.Deleted; $skipped = $r.Skipped
    return [pscustomobject]@{
        FreedMb = [math]::Round($freed / 1MB, 1)
        Deleted = $deleted
        Skipped = $skipped
    }
}

function Remove-PckitFilesByPattern {
    # удаляет только файлы по маскам прямо в папке (не рекурсивно); занятые пропускает
    param([string]$Path, [string[]]$Patterns)

    $freed = 0.0
    $deleted = 0
    $skipped = 0

    $resolved = Resolve-PckitPath $Path
    if (-not $resolved -or -not (Test-Path -LiteralPath $resolved)) {
        return [pscustomobject]@{ FreedMb = 0; Deleted = 0; Skipped = 0 }
    }

    $guard = Test-PckitSafePath -Path $resolved -AllowSystem
    if (-not $guard.Safe) {
        throw ('чистка отменена: {0} ({1})' -f $guard.Reason, $resolved)
    }

    foreach ($file in @(Get-PckitMatchingFiles -Folder $resolved -Patterns $Patterns)) {
        try {
            $size = $file.Length
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $freed += [double]$size
            $deleted++
        } catch {
            $skipped++
        }
    }
    return [pscustomobject]@{
        FreedMb = [math]::Round($freed / 1MB, 1)
        Deleted = $deleted
        Skipped = $skipped
    }
}

function Invoke-PckitDismCleanup {
    # штатная очистка хранилища компонентов (без /ResetBase); FreedMb = прирост свободного места системного диска
    $letter = $env:SystemDrive.Substring(0, 1)
    $before = (New-Object IO.DriveInfo $letter).AvailableFreeSpace
    $dism = Join-Path $env:SystemRoot 'System32\Dism.exe'
    $out = & $dism /Online /Cleanup-Image /StartComponentCleanup 2>&1
    $code = $LASTEXITCODE
    $after = (New-Object IO.DriveInfo $letter).AvailableFreeSpace
    $freedMb = [math]::Max(0, [math]::Round(($after - $before) / 1MB, 1))
    return [pscustomobject]@{ ExitCode = $code; FreedMb = $freedMb; Output = (($out | Out-String).Trim()) }
}

function Invoke-PckitClean {
    param(
        [object[]]$Targets,
        [switch]$Run
    )

    $results = New-Object System.Collections.ArrayList
    $totalFreed = 0.0

    foreach ($t in $Targets) {
        $status = 'dry'
        $freed = 0.0
        $deleted = 0
        $skipped = 0
        $message = ''

        if ($Run) {
            try {
                if ($t.Kind -eq 'recycle') {
                    $before = Get-PckitCleanSize -Target $t
                    Clear-RecycleBin -Force -ErrorAction Stop
                    $freed = [double]$before.SizeMb
                    $deleted = $before.Files
                    $status = 'ok'
                } elseif ($t.Kind -eq 'info') {
                    $status = 'skip'
                    $message = 'удаляется через Параметры Windows'
                } elseif ($t.Kind -eq 'drivers') {
                    $r = Remove-PckitOldDrivers -Run
                    $freed = $r.FreedMb
                    $deleted = $r.Deleted
                    $skipped = $r.Skipped
                    $status = if ($r.Deleted -gt 0 -or $r.Skipped -eq 0) { 'ok' } else { 'fail' }
                    if ($r.Skipped -gt 0) { $message = ('Windows не дала удалить: {0} (они ещё нужны устройствам)' -f $r.Skipped) }
                } elseif ($t.Kind -eq 'dism') {
                    $r = Invoke-PckitDismCleanup
                    $freed = $r.FreedMb
                    if ($r.ExitCode -eq 0 -or $r.ExitCode -eq 3010) {
                        $status = 'ok'
                        if ($r.ExitCode -eq 3010) { $message = 'нужна перезагрузка' }
                    } else {
                        $status = 'fail'
                        $message = ('Dism.exe завершился с кодом {0}' -f $r.ExitCode)
                    }
                } elseif ($t.Kind -eq 'files') {
                    foreach ($path in @($t.Paths)) {
                        $r = Remove-PckitFilesByPattern -Path $path -Patterns $t.Patterns
                        $freed += $r.FreedMb
                        $deleted += $r.Deleted
                        $skipped += $r.Skipped
                    }
                    $status = 'ok'
                } else {
                    foreach ($path in @($t.Paths)) {
                        $r = Remove-PckitFolderContent -Path $path
                        $freed += $r.FreedMb
                        $deleted += $r.Deleted
                        $skipped += $r.Skipped
                    }
                    $status = 'ok'
                }
            } catch {
                $status = 'fail'
                $message = $_.Exception.Message
            }
        } else {
            $size = Get-PckitCleanSize -Target $t
            $freed = [double]$size.SizeMb
            $deleted = $size.Files
        }

        if ($freed -gt 0) { $totalFreed += $freed }   # -1 (размер неизвестен) в сумму не идёт
        [void]$results.Add([pscustomobject]@{
                Target  = $t
                Status  = $status
                FreedMb = [math]::Round($freed, 1)
                Deleted = $deleted
                Skipped = $skipped
                Message = $message
            })
    }

    return [pscustomobject]@{
        Results  = $results.ToArray()
        FreedMb  = [math]::Round($totalFreed, 1)
        Run      = [bool]$Run
    }
}

# ---------- старые версии драйверов (DriverStore) ----------
# Берём только сторонние пакеты (не входящие в Windows). Группа = один и тот же драйвер:
# исходное имя .inf + производитель + класс устройства. В группе оставляем новейшую версию,
# остальные — кандидаты на удаление, кроме тех, что сейчас назначены какому-либо устройству.
# Удаление — штатный `pnputil /delete-driver oemNN.inf` БЕЗ /force: занятый драйвер Windows не удалит.

function ConvertTo-PckitDriverVersion {
    param([string]$Text)
    try { return [version]$Text } catch { return [version]'0.0' }
}

function Get-PckitDriversInUse {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($d in @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop)) {
            if ($d.InfName) { [void]$set.Add([string]$d.InfName) }
        }
    } catch { }
    return , $set
}

# пакеты драйверов в формате движка: { Published, Inf, Provider, Class, Version, Date, Folder }
function Get-PckitDriverPackages {
    $list = New-Object System.Collections.ArrayList
    $raw = @()
    try { $raw = @(Get-WindowsDriver -Online -ErrorAction Stop) } catch { return @() }
    foreach ($d in $raw) {
        if ($d.Inbox) { continue }
        $folder = $null
        if ($d.OriginalFileName) { $folder = Split-Path -Parent ([string]$d.OriginalFileName) }
        [void]$list.Add([pscustomobject]@{
                Published = [string]$d.Driver
                Inf       = if ($d.OriginalFileName) { (Split-Path -Leaf ([string]$d.OriginalFileName)).ToLowerInvariant() } else { '' }
                Provider  = [string]$d.ProviderName
                Class     = [string]$d.ClassName
                Version   = [string]$d.Version
                Date      = $d.Date
                Folder    = $folder
            })
    }
    return $list.ToArray()
}

# чистая логика отбора (тестируется без Windows): $Packages — из Get-PckitDriverPackages, $InUse — HashSet имён oemNN.inf
function Select-PckitOldDrivers {
    param($Packages, $InUse)
    $result = New-Object System.Collections.ArrayList
    $groups = @($Packages | Where-Object { $_ -and $_.Inf -and $_.Published -match '^oem\d+\.inf$' } |
            Group-Object { '{0}|{1}|{2}' -f $_.Inf, $_.Provider, $_.Class })
    foreach ($g in $groups) {
        if ($g.Count -lt 2) { continue }
        $sorted = @($g.Group | Sort-Object -Property @{ Expression = { ConvertTo-PckitDriverVersion $_.Version }; Descending = $true }, @{ Expression = { $_.Date }; Descending = $true })
        $newest = $sorted[0]
        foreach ($p in ($sorted | Select-Object -Skip 1)) {
            if ($InUse -and $InUse.Contains([string]$p.Published)) { continue }
            # одинаковая версия — это не «старая», а дубль; его тоже не трогаем, чтобы не гадать
            if ((ConvertTo-PckitDriverVersion $p.Version) -ge (ConvertTo-PckitDriverVersion $newest.Version)) { continue }
            [void]$result.Add([pscustomobject]@{
                    Published = $p.Published
                    Title     = ('{0} ({1})' -f $p.Provider, $p.Class)
                    Inf       = $p.Inf
                    Version   = $p.Version
                    Newest    = $newest.Version
                    Folder    = $p.Folder
                    SizeMb    = 0.0
                })
        }
    }
    return $result.ToArray()
}

function Get-PckitOldDrivers {
    if (-not (Test-PckitAdmin)) { return @() }
    $old = @(Select-PckitOldDrivers -Packages @(Get-PckitDriverPackages) -InUse (Get-PckitDriversInUse))
    foreach ($o in $old) {
        if ($o.Folder -and (Test-Path -LiteralPath $o.Folder)) {
            $sum = (Get-ChildItem -LiteralPath $o.Folder -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            if ($sum) { $o.SizeMb = [math]::Round($sum / 1MB, 1) }
        }
    }
    return $old
}

# для «Проверки»: тот же список, но не чаще раза в 6 часов (перечисление DriverStore медленное)
function Get-PckitOldDriversCached {
    $file = Join-Path $env:LOCALAPPDATA 'pckit\olddrivers-cache.json'
    if (Test-Path -LiteralPath $file) {
        try {
            if (((Get-Date) - (Get-Item -LiteralPath $file).LastWriteTime).TotalHours -lt 6) {
                return @(Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json | Where-Object { $_ })
            }
        } catch { }
    }
    $list = @(Get-PckitOldDrivers)
    try {
        $dir = Split-Path -Parent $file
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject @($list) -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
    return $list
}

function Remove-PckitOldDrivers {
    param([switch]$Run)
    $old = @(Get-PckitOldDrivers)
    $freed = 0.0; $deleted = 0; $skipped = 0
    $items = New-Object System.Collections.ArrayList
    foreach ($o in $old) {
        $status = 'dry'; $msg = ''
        if ($Run) {
            $pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
            $out = & $pnputil /delete-driver $o.Published 2>&1
            if ($LASTEXITCODE -eq 0) { $status = 'ok'; $deleted++; $freed += $o.SizeMb }
            else { $status = 'skip'; $skipped++; $msg = (($out | Out-String).Trim() -split "`r?`n" | Select-Object -Last 1) }
        }
        [void]$items.Add([pscustomobject]@{ Driver = $o; Status = $status; Message = $msg })
    }
    if ($Run) { Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'pckit\olddrivers-cache.json') -Force -ErrorAction SilentlyContinue }
    return [pscustomobject]@{ Items = $items.ToArray(); FreedMb = [math]::Round($freed, 1); Deleted = $deleted; Skipped = $skipped }
}

# рабочие программы: их кэши тоже чистятся здесь
. (Join-Path $PSScriptRoot 'Work.ps1')
