#Requires -Version 5.1
# pckit engine | journal: every change is recorded so it can be undone exactly
# (ported from CleanPC 2.1: Set-RegTracked / undo.json)

$script:PckitStateRoot = $null
$script:PckitJournalKinds = @('registry', 'regkeys', 'files', 'commands', 'nvidia', 'cs2')

function Get-PckitStateRoot {
    if ($script:PckitStateRoot) { return $script:PckitStateRoot }

    $candidates = @(
        (Join-Path $env:ProgramData 'pckit'),
        (Join-Path (Split-Path -Parent $script:PckitEngineDir) 'state')
    )
    foreach ($dir in $candidates) {
        try {
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null }
            # журнал отката содержит команды, которые потом выполняются от администратора:
            # обычный пользователь не должен мочь его подменить
            if ((Test-PckitAdmin) -and $dir -like (Join-Path $env:ProgramData '*')) {
                & icacls $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' 2>&1 | Out-Null
            }
            $probe = Join-Path $dir '.write-test'
            Set-Content -LiteralPath $probe -Value 'ok' -ErrorAction Stop
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            $script:PckitStateRoot = (Resolve-Path -LiteralPath $dir).Path
            return $script:PckitStateRoot
        } catch { }
    }
    throw 'не удалось подготовить папку состояния (нет прав на запись)'
}

function New-PckitJournal {
    return [ordered]@{
        created  = (Get-Date).ToString('s')
        computer = $env:COMPUTERNAME
        registry = New-Object System.Collections.ArrayList
        regkeys  = New-Object System.Collections.ArrayList
        files    = New-Object System.Collections.ArrayList
        commands = New-Object System.Collections.ArrayList
        nvidia   = New-Object System.Collections.ArrayList
        cs2      = New-Object System.Collections.ArrayList
    }
}

function Read-PckitJournal {
    $path = Join-Path (Get-PckitStateRoot) 'undo.json'
    if (-not (Test-Path -LiteralPath $path)) { return (New-PckitJournal) }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $data = ConvertFrom-Json $raw
    } catch {
        # не затираем историю отката молча: откладываем битый файл в сторону
        try { Move-Item -LiteralPath $path -Destination ('{0}.corrupt-{1}' -f $path, (Get-Date).ToString('yyyyMMdd-HHmmss')) -Force } catch { }
        return (New-PckitJournal)
    }

    $journal = New-PckitJournal
    if ($data.created) { $journal.created = [string]$data.created }
    foreach ($k in $script:PckitJournalKinds) {
        foreach ($e in @($data.$k)) { if ($e) { [void]$journal.$k.Add($e) } }
    }
    return $journal
}

function Save-PckitJournal {
    param($Journal)
    $path = Join-Path (Get-PckitStateRoot) 'undo.json'
    $json = $Journal | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function Test-PckitJournalEmpty {
    param($Journal)
    return (Get-PckitJournalCount -Journal $Journal) -eq 0
}

function Get-PckitJournalCount {
    param($Journal)
    $n = 0
    foreach ($k in $script:PckitJournalKinds) { $n += @($Journal.$k | Where-Object { $_ }).Count }
    return $n
}

function Test-PckitRegValue {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    return ($item.GetValueNames() -contains $Name)
}

function Get-PckitRegValueInfo {
    param([string]$Path, [string]$Name)
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    if (-not ($item.GetValueNames() -contains $Name)) { return $null }
    return [pscustomobject]@{
        Existed = $true
        Type    = $item.GetValueKind($Name).ToString()
        Value   = $item.GetValue($Name)
    }
}

function Add-PckitRegTracked {
    param(
        $Journal,
        [string]$Path,
        [string]$Name,
        $Value,
        [string]$Type = 'DWord'
    )

    $already = $null
    # одно значение пишем один раз за партию; в новой партии — снова (её «до» нужно для отката только этой партии)
    foreach ($e in $Journal.registry) {
        if ($script:PckitBatchSince -and [string]$e.at -lt $script:PckitBatchSince) { continue }
        if ($e.path -ieq $Path -and $e.name -ieq $Name) { $already = $e; break }
    }
    if (-not $already) {
        $info = Get-PckitRegValueInfo -Path $Path -Name $Name
        $entry = [pscustomobject]@{
            path    = $Path
            name    = $Name
            existed = [bool]($info -and $info.Existed)
            type    = if ($info) { $info.Type } else { $null }
            value   = if ($info) { $info.Value } else { $null }
            at      = (Get-Date).ToString('s')
        }
        [void]$Journal.registry.Add($entry)
    }

    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction SilentlyContinue | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Remove-PckitRegTracked {
    param($Journal, [string]$Path, [string]$Name)

    $already = $null
    # одно значение пишем один раз за партию; в новой партии — снова (её «до» нужно для отката только этой партии)
    foreach ($e in $Journal.registry) {
        if ($script:PckitBatchSince -and [string]$e.at -lt $script:PckitBatchSince) { continue }
        if ($e.path -ieq $Path -and $e.name -ieq $Name) { $already = $e; break }
    }
    if (-not $already -and (Test-PckitRegValue -Path $Path -Name $Name)) {
        $info = Get-PckitRegValueInfo -Path $Path -Name $Name
        [void]$Journal.registry.Add([pscustomobject]@{
                path    = $Path
                name    = $Name
                existed = $true
                type    = $info.Type
                value   = $info.Value
                at      = (Get-Date).ToString('s')
            })
    }
    if (Test-PckitRegValue -Path $Path -Name $Name) {
        Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction SilentlyContinue
    }
}

function Add-PckitFileTracked {
    param($Journal, [string]$Target, [string]$BackupPath)
    if (-not $BackupPath) { return }
    [void]$Journal.files.Add([pscustomobject]@{
            target = $Target
            backup = $BackupPath
            at     = (Get-Date).ToString('s')
        })
}

function Add-PckitRegKeyTracked {
    param($Journal, [string]$Key, [string]$BackupFile)
    [void]$Journal.regkeys.Add([pscustomobject]@{
            key    = $Key
            backup = $BackupFile
            at     = (Get-Date).ToString('s')
        })
}

function Add-PckitCommandTracked {
    param($Journal, [string]$Undo, [string]$Note = '')
    [void]$Journal.commands.Add([pscustomobject]@{
            undo = $Undo
            note = $Note
            at   = (Get-Date).ToString('s')
        })
}

function Get-PckitUndoPlan {
    param($Journal)

    $plan = New-Object System.Collections.ArrayList
    foreach ($e in @($Journal.files)) {
        if (-not $e) { continue }
        [void]$plan.Add([pscustomobject]@{
                Kind  = 'файл'
                Title = [string]$e.target
                Detail = if (Test-Path -LiteralPath $e.backup) { 'вернуть из бэкапа' } else { 'бэкап не найден — пропустить' }
            })
    }
    foreach ($e in @($Journal.regkeys)) {
        if (-not $e) { continue }
        [void]$plan.Add([pscustomobject]@{
                Kind  = 'ветка реестра'
                Title = [string]$e.key
                Detail = if (Test-Path -LiteralPath $e.backup) { 'импортировать сохранённую копию' } else { 'копия не найдена — пропустить' }
            })
    }
    foreach ($e in @($Journal.registry)) {
        if (-not $e) { continue }
        $what = if ($e.existed) { 'вернуть значение' } else { 'удалить значение (его не было)' }
        [void]$plan.Add([pscustomobject]@{
                Kind  = 'параметр'
                Title = ('{0} :: {1}' -f $e.path, $e.name).Replace('HKEY_CURRENT_USER', 'HKCU').Replace('HKEY_LOCAL_MACHINE', 'HKLM')
                Detail = $what
            })
    }
    foreach ($e in @($Journal.commands)) {
        if (-not $e) { continue }
        [void]$plan.Add([pscustomobject]@{
                Kind  = 'команда'
                Title = [string]$e.undo
                Detail = [string]$e.note
            })
    }
    foreach ($e in @($Journal.nvidia)) {
        if (-not $e) { continue }
        [void]$plan.Add([pscustomobject]@{
                Kind  = 'видеокарта'
                Title = ('NVIDIA {0}: {1}' -f $e.exe, $e.title)
                Detail = if ([string]$e.restore -eq 'value') { 'вернуть прежнее значение' } else { 'вернуть «как в драйвере»' }
            })
    }
    foreach ($e in @($Journal.cs2)) {
        if (-not $e) { continue }
        [void]$plan.Add([pscustomobject]@{ Kind = 'CS2'; Title = (Get-PckitCs2EntryTitle $e); Detail = 'убрать только то, что добавил pckit' })
    }
    return $plan.ToArray()
}

# одна команда отката: { Status = ok|skip|fail; Message }
# то, чего в системе больше нет (задачу удалило обновление Windows, службу — удаление программы), вернуть нельзя: это пропуск, а не ошибка
function Invoke-PckitUndoCommand {
    param([string]$Undo)
    $res = { param($s, $m) [pscustomobject]@{ Status = $s; Message = $m } }

    # запуск службы — средствами PowerShell: «уже запущена» не считаем ошибкой (net start вернул бы код 2)
    if ($Undo -match '^net start "(.+)"$') {
        $name = $matches[1]
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $svc) { return (& $res 'skip' 'службы больше нет') }
        if ([string]$svc.Status -eq 'Running') { return (& $res 'ok' 'уже запущена') }
        try { Start-Service -Name $name -ErrorAction Stop; return (& $res 'ok' '') }
        catch { return (& $res 'fail' $_.Exception.Message) }
    }
    if ($Undo -match '^del /f /q "(.+)"$' -and -not (Test-Path -LiteralPath $matches[1])) { return (& $res 'skip' 'файла уже нет') }

    & cmd /c $Undo 2>&1 | Out-Null
    $code = $LASTEXITCODE
    if ($code -eq 0) { return (& $res 'ok' '') }

    if ($Undo -match '^schtasks /Change /TN "(.+)" /ENABLE$') {
        & schtasks /Query /TN $matches[1] 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { return (& $res 'skip' 'задачи больше нет') }
    }
    if ($Undo -match '^sc config "(.+?)" ') {
        & sc.exe query $matches[1] 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 1060) { return (& $res 'skip' 'службы больше нет') }
    }
    return (& $res 'fail' ("код $code"))
}

# порядок отката команд: последнее изменение — первым (иначе прежняя схема питания перекрывалась бы более новой записью);
# запуск служб — в самом конце, когда им уже вернули тип запуска
function Get-PckitUndoCommandOrder {
    param($Commands)
    $list = @($Commands | Where-Object { $_ })
    [array]::Reverse($list)
    $late = @($list | Where-Object { [string]$_.undo -match '^net start ' })
    $early = @($list | Where-Object { [string]$_.undo -notmatch '^net start ' })
    return , @($early + $late)
}

function Restore-PckitJournal {
    param($Journal, [switch]$Run, [string]$Since)

    # -Since: откатить только то, что записано начиная с этого времени (последняя партия)
    $sel = New-PckitJournal
    $rest = New-PckitJournal
    $rest.created = [string]$Journal.created
    foreach ($k in $script:PckitJournalKinds) {
        foreach ($e in @($Journal.$k)) {
            if (-not $e) { continue }
            if (-not $Since -or [string]$e.at -ge $Since) { [void]$sel.$k.Add($e) } else { [void]$rest.$k.Add($e) }
        }
    }
    $Journal = $sel
    # что не получилось вернуть — остаётся в журнале для повтора; вернувшееся и невозвратимое (skip) — убираем
    $keep = New-PckitJournal

    $result = New-Object System.Collections.ArrayList
    $ok = 0
    $failed = 0
    $note = {
        param($Kind, $Title, $Status, $Msg, $ListName, $Entry)
        if ($Status -eq 'ok') { $script:__ok++ } elseif ($Status -eq 'fail') { $script:__failed++; [void]$keep.$ListName.Add($Entry) }
        [void]$result.Add([pscustomobject]@{ Kind = $Kind; Title = $Title; Status = $Status; Message = $Msg })
    }
    $script:__ok = 0; $script:__failed = 0

    # CS2: убрать только своё (параметр запуска, блок в autoexec.cfg), остальное пользователя не трогаем
    $cs2 = @($Journal.cs2)
    [array]::Reverse($cs2)
    foreach ($e in $cs2) {
        if (-not $e) { continue }
        $status = 'dry'; $msg = ''
        if ($Run) { $r = Restore-PckitCs2Entry -Entry $e; $status = $r.Status; $msg = $r.Message }
        & $note 'CS2' (Get-PckitCs2EntryTitle $e) $status $msg 'cs2' $e
    }

    # files: newest first
    $files = @($Journal.files)
    [array]::Reverse($files)
    foreach ($e in $files) {
        if (-not $e) { continue }
        $status = 'dry'
        $msg = ''
        if ($Run) {
            try {
                if (Test-Path -LiteralPath $e.backup) {
                    if (Test-Path -LiteralPath $e.target) { Remove-Item -LiteralPath $e.target -Recurse -Force -ErrorAction SilentlyContinue }
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $e.target) | Out-Null
                    Move-Item -LiteralPath $e.backup -Destination $e.target -Force
                    $status = 'ok'
                } else {
                    $status = 'skip'; $msg = 'бэкап не найден'
                }
            } catch {
                $status = 'fail'; $msg = $_.Exception.Message
            }
        }
        & $note 'файл' ([string]$e.target) $status $msg 'files' $e
    }

    # registry keys
    $keys = @($Journal.regkeys)
    [array]::Reverse($keys)
    foreach ($e in $keys) {
        if (-not $e) { continue }
        $status = 'dry'
        $msg = ''
        if ($Run) {
            try {
                if (Test-Path -LiteralPath $e.backup) {
                    & reg import $e.backup 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) { $status = 'ok' } else { $status = 'fail'; $msg = "reg код $LASTEXITCODE" }
                } else {
                    $status = 'skip'; $msg = 'копия не найдена'
                }
            } catch {
                $status = 'fail'; $msg = $_.Exception.Message
            }
        }
        & $note 'ветка реестра' ([string]$e.key) $status $msg 'regkeys' $e
    }

    # registry values: reverse order
    $values = @($Journal.registry)
    [array]::Reverse($values)
    foreach ($e in $values) {
        if (-not $e) { continue }
        $status = 'dry'
        $msg = ''
        if ($Run) {
            try {
                if ($e.existed) {
                    if (-not (Test-Path -LiteralPath $e.path)) { New-Item -Path $e.path -Force | Out-Null }
                    # после JSON массивы приходят как object[] — возвращаем нужный тип реестра
                    $val = $e.value
                    switch ([string]$e.type) {
                        'Binary'      { $val = [byte[]]@($val) }
                        'MultiString' { $val = [string[]]@($val) }
                        'DWord'       { $val = [int]$val }
                        'QWord'       { $val = [long]$val }
                    }
                    New-ItemProperty -LiteralPath $e.path -Name $e.name -Value $val -PropertyType $e.type -Force | Out-Null
                } else {
                    if (Test-PckitRegValue -Path $e.path -Name $e.name) {
                        Remove-ItemProperty -LiteralPath $e.path -Name $e.name -Force
                    }
                }
                $status = 'ok'
            } catch {
                $status = 'fail'; $msg = $_.Exception.Message
            }
        }
        & $note 'параметр' ('{0} :: {1}' -f $e.path, $e.name) $status $msg 'registry' $e
    }

    # commands
    foreach ($e in (Get-PckitUndoCommandOrder -Commands $Journal.commands)) {
        $status = 'dry'
        $msg = ''
        if ($Run) {
            try { $r = Invoke-PckitUndoCommand -Undo ([string]$e.undo); $status = $r.Status; $msg = $r.Message }
            catch { $status = 'fail'; $msg = $_.Exception.Message }
        }
        & $note 'команда' ([string]$e.undo) $status $msg 'commands' $e
    }

    # профиль драйвера NVIDIA
    if (@($Journal.nvidia | Where-Object { $_ }).Count) {
        foreach ($r in @(Restore-PckitNvidiaJournal -Entries @($Journal.nvidia) -Run:$Run)) {
            & $note $r.Kind $r.Title $r.Status $r.Message 'nvidia' $r.Entry
        }
    }
    $ok = $script:__ok; $failed = $script:__failed

    if ($Run) {
        # в журнале остаются более ранние партии и то, что не удалось вернуть
        foreach ($k in $script:PckitJournalKinds) { foreach ($e in @($keep.$k)) { if ($e) { [void]$rest.$k.Add($e) } } }
        Save-PckitJournal -Journal $rest | Out-Null
    }

    return [pscustomobject]@{
        Items  = $result.ToArray()
        Ok     = $ok
        Failed = $failed
        Run    = [bool]$Run
    }
}
function Get-PckitJournalSummary {
    param($Journal)

    $rows = New-Object System.Collections.ArrayList
    $short = {
        param($Path)
        ([string]$Path).Replace('HKEY_CURRENT_USER', 'HKCU').Replace('HKEY_LOCAL_MACHINE', 'HKLM')
    }

    foreach ($e in @($Journal.registry)) {
        if (-not $e) { continue }
        $was = if ($e.existed) { '{0}' -f $e.value } else { 'не было' }
        [void]$rows.Add([pscustomobject]@{
                At     = [string]$e.at
                Kind   = 'параметр'
                Title  = ('{0} :: {1}' -f (& $short $e.path), $e.name)
                Detail = ('было: {0}' -f $was)
            })
    }
    foreach ($e in @($Journal.regkeys)) {
        if (-not $e) { continue }
        [void]$rows.Add([pscustomobject]@{
                At = [string]$e.at; Kind = 'ветка реестра'; Title = (& $short $e.key); Detail = 'импортирована копия'
            })
    }
    foreach ($e in @($Journal.files)) {
        if (-not $e) { continue }
        [void]$rows.Add([pscustomobject]@{
                At = [string]$e.at; Kind = 'файл'; Title = [string]$e.target; Detail = 'заменён, старая версия в бэкапе'
            })
    }
    foreach ($e in @($Journal.commands)) {
        if (-not $e) { continue }
        [void]$rows.Add([pscustomobject]@{
                At = [string]$e.at; Kind = 'команда'; Title = [string]$e.undo; Detail = [string]$e.note
            })
    }
    foreach ($e in @($Journal.nvidia)) {
        if (-not $e) { continue }
        $was = if ([string]$e.restore -eq 'value') { ('0x{0:X}' -f [uint32]$e.value) } else { 'как в драйвере' }
        [void]$rows.Add([pscustomobject]@{
                At = [string]$e.at; Kind = 'видеокарта'; Title = ('NVIDIA {0}: {1}' -f $e.exe, $e.title); Detail = ('было: {0}' -f $was)
            })
    }

    foreach ($e in @($Journal.cs2)) {
        if (-not $e) { continue }
        [void]$rows.Add([pscustomobject]@{
                At = [string]$e.at; Kind = 'CS2'; Title = (Get-PckitCs2EntryTitle $e)
                Detail = $(if ([string]$e.kind -eq 'launch') { 'было: без этих параметров' } elseif ($e.created) { 'было: файла не было' } else { 'было: без блока pckit' })
            })
    }
    return $rows.ToArray()
}
# профиль драйвера NVIDIA: запись и откат (journal.nvidia)
. (Join-Path $PSScriptRoot 'Nvidia.ps1')
# CS2: autoexec.cfg и параметры запуска (journal.cs2)
. (Join-Path $PSScriptRoot 'Cs2.ps1')
