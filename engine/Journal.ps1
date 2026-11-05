#Requires -Version 5.1
# pckit engine | journal: every change is recorded so it can be undone exactly
# (ported from CleanPC 2.1: Set-RegTracked / undo.json)

$script:PckitStateRoot = $null

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
    foreach ($e in @($data.registry)) { if ($e) { [void]$journal.registry.Add($e) } }
    foreach ($e in @($data.regkeys)) { if ($e) { [void]$journal.regkeys.Add($e) } }
    foreach ($e in @($data.files)) { if ($e) { [void]$journal.files.Add($e) } }
    foreach ($e in @($data.commands)) { if ($e) { [void]$journal.commands.Add($e) } }
    foreach ($e in @($data.nvidia)) { if ($e) { [void]$journal.nvidia.Add($e) } }
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
    $n = @($Journal.registry).Count + @($Journal.regkeys).Count + @($Journal.files).Count + @($Journal.commands).Count
    if ($Journal.nvidia) { $n += @($Journal.nvidia | Where-Object { $_ }).Count }
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
    return $plan.ToArray()
}

function Restore-PckitJournal {
    param($Journal, [switch]$Run, [string]$Since)

    # -Since: откатить только то, что записано начиная с этого времени (последняя партия)
    $rest = $null
    if ($Since) {
        $sel = New-PckitJournal
        $rest = New-PckitJournal
        $rest.created = [string]$Journal.created
        foreach ($k in 'registry', 'regkeys', 'files', 'commands', 'nvidia') {
            foreach ($e in @($Journal.$k)) {
                if (-not $e) { continue }
                if ([string]$e.at -ge $Since) { [void]$sel.$k.Add($e) } else { [void]$rest.$k.Add($e) }
            }
        }
        $Journal = $sel
    }

    $result = New-Object System.Collections.ArrayList
    $ok = 0
    $failed = 0

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
                    $status = 'ok'; $ok++
                } else {
                    $status = 'skip'; $msg = 'бэкап не найден'
                }
            } catch {
                $status = 'fail'; $failed++; $msg = $_.Exception.Message
            }
        }
        [void]$result.Add([pscustomobject]@{ Kind = 'файл'; Title = [string]$e.target; Status = $status; Message = $msg })
    }

    # registry keys
    foreach ($e in @($Journal.regkeys)) {
        if (-not $e) { continue }
        $status = 'dry'
        $msg = ''
        if ($Run) {
            try {
                if (Test-Path -LiteralPath $e.backup) {
                    & reg import $e.backup 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) { $status = 'ok'; $ok++ } else { $status = 'fail'; $failed++; $msg = "reg код $LASTEXITCODE" }
                } else {
                    $status = 'skip'; $msg = 'копия не найдена'
                }
            } catch {
                $status = 'fail'; $failed++; $msg = $_.Exception.Message
            }
        }
        [void]$result.Add([pscustomobject]@{ Kind = 'ветка реестра'; Title = [string]$e.key; Status = $status; Message = $msg })
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
                $status = 'ok'; $ok++
            } catch {
                $status = 'fail'; $failed++; $msg = $_.Exception.Message
            }
        }
        [void]$result.Add([pscustomobject]@{ Kind = 'параметр'; Title = ('{0} :: {1}' -f $e.path, $e.name); Status = $status; Message = $msg })
    }

    # commands
    foreach ($e in @($Journal.commands)) {
        if (-not $e) { continue }
        $status = 'dry'
        $msg = ''
        if ($Run) {
            try {
                & cmd /c $e.undo 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { $status = 'ok'; $ok++ } else { $status = 'fail'; $failed++; $msg = "код $LASTEXITCODE" }
            } catch {
                $status = 'fail'; $failed++; $msg = $_.Exception.Message
            }
        }
        [void]$result.Add([pscustomobject]@{ Kind = 'команда'; Title = [string]$e.undo; Status = $status; Message = $msg })
    }

    # профиль драйвера NVIDIA
    if ($Journal.nvidia -and @($Journal.nvidia | Where-Object { $_ }).Count) {
        foreach ($r in @(Restore-PckitNvidiaJournal -Entries @($Journal.nvidia) -Run:$Run)) {
            if ($r.Status -eq 'ok') { $ok++ } elseif ($r.Status -eq 'fail') { $failed++ }
            [void]$result.Add($r)
        }
    }

    if ($Run -and $failed -eq 0) {
        if ($rest) { Save-PckitJournal -Journal $rest | Out-Null }
        else { Save-PckitJournal -Journal (New-PckitJournal) | Out-Null }
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

    return $rows.ToArray()
}
# профиль драйвера NVIDIA: запись и откат (journal.nvidia)
. (Join-Path $PSScriptRoot 'Nvidia.ps1')
