#Requires -Version 5.1
# pckit engine | applier: execute a plan with backups, logs and dry-run support

function Get-PckitStatePath {
    param([string]$Child)
    $base = Get-PckitStateRoot
    if (-not (Test-Path -LiteralPath $base)) { New-Item -ItemType Directory -Force -Path $base | Out-Null }
    if ($Child) {
        $p = Join-Path $base $Child
        if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
        return $p
    }
    return $base
}

function Write-PckitApplyLog {
    param([string]$LogFile, [string]$Message, [string]$Level = 'info')
    Write-PckitLog -Message $Message -Level $Level
    if ($LogFile) {
        $line = '{0} [{1}] {2}' -f (Get-Date).ToString('HH:mm:ss'), $Level, $Message
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    }
}

function Backup-PckitTarget {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][string]$Label
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $dest = Join-Path $BackupRoot $Label
    if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Force -Path $dest | Out-Null }
    $leaf = Split-Path -Leaf $Path
    $target = Join-Path $dest $leaf
    $i = 1
    while (Test-Path -LiteralPath $target) {
        $target = Join-Path $dest ('{0}_{1}' -f $leaf, $i)
        $i++
    }
    if (Test-Path -LiteralPath $Path -PathType Container) {
        Move-Item -LiteralPath $Path -Destination $target -Force
    } else {
        Move-Item -LiteralPath $Path -Destination $target -Force
    }
    return $target
}

function Invoke-PckitStep {
    param(
        $Step,
        [string]$ProfileRoot,
        [string]$BackupRoot,
        [string]$LogFile,
        [object]$Journal = $null,
        [switch]$Run
    )

    $result = [pscustomobject]@{
        Step   = $Step
        Status = 'dry'
        Detail = ''
        Msg    = ''
    }

    $payloadPath = $null
    if ($Step.Meta -and $Step.Meta.PSObject.Properties.Name -contains 'Payload' -and $Step.Meta.Payload) {
        # бросает исключение, если путь выходит за пределы распакованного профиля
        $payloadPath = Resolve-PckitPayload -ProfileRoot $ProfileRoot -Relative ([string]$Step.Meta.Payload)
    }

    # куда профиль просит писать — проверяем до любых действий (чужой профиль не должен трогать C:\Windows или корень профиля пользователя)
    if ($Step.Action -in 'copy', 'copyfile' -and $Step.Meta.Target) {
        $guard = Test-PckitRestoreTarget -Path ([string]$Step.Meta.Target)
        if (-not $guard.Safe) {
            $result.Status = 'fail'
            $result.Msg = ('отказ: {0} ({1})' -f $guard.Reason, $Step.Meta.Target)
            return $result
        }
    }

    switch ($Step.Action) {
        'install' {
            $id = [string]$Step.Meta.wingetId
            if (-not $Run) { $result.Status = 'dry'; $result.Msg = ('winget install --id {0} -e' -f $id); break }
            Write-PckitApplyLog -LogFile $LogFile -Message ('установка: ' + $Step.Title)
            $out = & winget install --id $id -e --accept-package-agreements --accept-source-agreements 2>&1
            $code = $LASTEXITCODE
            $text = ($out | Out-String)
            if ($code -eq 0 -or $text -match 'already installed|уже установлен') {
                $result.Status = 'ok'
            } else {
                $result.Status = 'fail'
                $result.Msg = ('winget код {0}' -f $code)
            }
        }
        'copy' {
            $target = Resolve-PckitPath ([string]$Step.Meta.Target)
            if (-not $payloadPath -or -not (Test-Path -LiteralPath $payloadPath)) {
                $result.Status = 'fail'; $result.Msg = 'нет payload'; break
            }
            if (-not $Run) { $result.Status = 'dry'; $result.Msg = ('копировать {0} -> {1}' -f $Step.Meta.Payload, $target); break }
            $moved = $null
            if ((Test-Path -LiteralPath $target) -and -not $Step.Meta.Merge) {
                $moved = Backup-PckitTarget -Path $target -BackupRoot $BackupRoot -Label ($Step.ItemId -replace '[^a-z0-9\.\-]', '_')
                Write-PckitApplyLog -LogFile $LogFile -Message ('бэкап: {0}' -f $moved)
            }
            if ($Journal -and $moved) { Add-PckitFileTracked -Journal $Journal -Target $target -BackupPath $moved }
            New-Item -ItemType Directory -Force -Path $target | Out-Null
            Copy-PckitTree -Source $payloadPath -Destination $target -Exclude @($Step.Meta.Exclude) | Out-Null
            $result.Status = 'ok'
        }
        'copyfile' {
            $target = Resolve-PckitPath ([string]$Step.Meta.Target)
            if (-not $payloadPath -or -not (Test-Path -LiteralPath $payloadPath)) {
                $result.Status = 'fail'; $result.Msg = 'нет payload'; break
            }
            if (-not $Run) { $result.Status = 'dry'; $result.Msg = ('копировать файл -> {0}' -f $target); break }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            $moved = $null
            if (Test-Path -LiteralPath $target) {
                $moved = Backup-PckitTarget -Path $target -BackupRoot $BackupRoot -Label ($Step.ItemId -replace '[^a-z0-9\.\-]', '_')
                Write-PckitApplyLog -LogFile $LogFile -Message ('бэкап: {0}' -f $moved)
            }
            if ($Journal -and $moved) { Add-PckitFileTracked -Journal $Journal -Target $target -BackupPath $moved }
            Copy-Item -LiteralPath $payloadPath -Destination $target -Force
            $result.Status = 'ok'
        }
        'regimport' {
            if (-not $payloadPath -or -not (Test-Path -LiteralPath $payloadPath)) {
                $result.Status = 'fail'; $result.Msg = 'нет файла реестра'; break
            }
            $scope = Test-PckitRegFileScope -Path $payloadPath -Key ([string]$Step.Meta.Key)
            if (-not $scope.Safe) { $result.Status = 'fail'; $result.Msg = ('отказ: {0}' -f $scope.Reason); break }
            if (-not $Run) { $result.Status = 'dry'; $result.Msg = ('импорт {0}' -f $Step.Meta.Key); break }
            $regBackupDir = Join-Path $BackupRoot 'registry'
            New-Item -ItemType Directory -Force -Path $regBackupDir | Out-Null
            $regFile = Join-Path $regBackupDir ('{0}.reg' -f ($Step.ItemId -replace '[^a-z0-9\.\-]', '_'))
            if ($Step.Meta.Key) {
                & reg export ([string]$Step.Meta.Key) $regFile /y 2>$null | Out-Null
                if (Test-Path -LiteralPath $regFile) {
                    if ($Journal) { Add-PckitRegKeyTracked -Journal $Journal -Key ([string]$Step.Meta.Key) -BackupFile $regFile }
                }
            }
            & reg import $payloadPath 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $result.Status = 'ok' } else { $result.Status = 'fail'; $result.Msg = ('reg код {0}' -f $LASTEXITCODE) }
        }
        'command' {
            if (-not $payloadPath -or -not (Test-Path -LiteralPath $payloadPath)) {
                $result.Status = 'note'; $result.Msg = 'список не захвачен'; break
            }
            $lines = @(Get-Content -LiteralPath $payloadPath -Encoding UTF8 | Where-Object { $_.Trim() -and $_ -notmatch '^\s*(>|Name|Version|---)' })
            $template = [string]$Step.Meta.Template
            if (-not (Test-PckitCommandTemplate -Template $template)) {
                $result.Status = 'fail'; $result.Msg = ('шаблон команды не из белого списка: {0}' -f $template); break
            }
            if (-not $Run) { $result.Status = 'dry'; $result.Msg = ('команд: {0}' -f $lines.Count); break }
            $parts = $template.Trim() -split ' '
            $exe = $parts[0]
            $fixed = @($parts[1..($parts.Count - 2)])   # всё между программой и {line}
            $ok = 0
            $rejected = 0
            foreach ($line in $lines) {
                $arg = $line.Trim()
                if (-not (Test-PckitCommandArg -Text $arg)) { $rejected++; continue }
                try {
                    # без cmd /c: аргумент передаётся как есть, подставить в него команду нельзя
                    & $exe @fixed $arg 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) { $ok++ }
                } catch { }
            }
            $result.Status = if ($ok -eq $lines.Count) { 'ok' } else { 'partial' }
            $result.Msg = ('{0}/{1}' -f $ok, $lines.Count) + $(if ($rejected) { (', отклонено строк: {0}' -f $rejected) } else { '' })
        }
        'env' {
            $vars = $Step.Meta.vars
            if (-not $Run) { $result.Status = 'dry'; $result.Msg = ('переменных: {0}' -f $vars.PSObject.Properties.Count); break }
            $set = 0
            $denied = @()
            foreach ($p in $vars.PSObject.Properties) {
                if (-not (Test-PckitEnvAllowed -Name $p.Name)) { $denied += $p.Name; continue }
                $current = [Environment]::GetEnvironmentVariable($p.Name, 'User')
                if (-not $current) {
                    [Environment]::SetEnvironmentVariable($p.Name, [string]$p.Value, 'User')
                    $set++
                }
            }
            $result.Status = 'ok'
            $result.Msg = ('добавлено: {0}' -f $set) + $(if ($denied.Count) { ('; не переношу (небезопасно): {0}' -f ($denied -join ', ')) } else { '' })
        }
        'timezone' {
            if (-not $Run) { $result.Status = 'dry'; $result.Msg = ('Set-TimeZone ' + $Step.Meta.id); break }
            $prevTz = (Get-TimeZone).Id
            try {
                Set-TimeZone -Id ([string]$Step.Meta.id) -ErrorAction Stop
                if ($Journal) { Add-PckitCommandTracked -Journal $Journal -Undo ('tzutil /s "{0}"' -f $prevTz) -Note 'часовой пояс' }
                $result.Status = 'ok'
            }
            catch { $result.Status = 'fail'; $result.Msg = $_.Exception.Message }
        }
        'languages' {
            if (-not $Run) { $result.Status = 'dry'; $result.Msg = (($Step.Meta.list) -join ', '); break }
            try {
                # тип списка берём у самой системы: класса Microsoft.InternationalSettings.Language не существует
                $list = $null
                foreach ($tag in @($Step.Meta.list)) {
                    if ([string]$tag -notmatch '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$') { continue }
                    $one = New-WinUserLanguageList -Language $tag -ErrorAction SilentlyContinue
                    if (-not $one) { continue }
                    if ($null -eq $list) { $list = $one } else { $list.Add($one[0]) }
                }
                if ($list) { Set-WinUserLanguageList -LanguageList $list -Force; $result.Status = 'ok' }
                else { $result.Status = 'fail'; $result.Msg = 'не удалось собрать список языков' }
            } catch { $result.Status = 'fail'; $result.Msg = $_.Exception.Message }
        }
        'powerplan' {
            if (-not $Run) { $result.Status = 'dry'; $result.Msg = ('powercfg /setactive ' + $Step.Meta.guid); break }
            $prevPlan = ''
            $powerOut = & powercfg /getactivescheme 2>$null
            if ($powerOut -match '([0-9a-fA-F-]{36})') { $prevPlan = $matches[1] }
            & powercfg /setactive ([string]$Step.Meta.guid) 2>&1 | Out-Null
            $result.Status = if ($LASTEXITCODE -eq 0) { 'ok' } else { 'fail' }
            if ($result.Status -eq 'ok' -and $prevPlan -and $Journal) {
                Add-PckitCommandTracked -Journal $Journal -Undo ('powercfg /setactive {0}' -f $prevPlan) -Note 'схема электропитания'
            }
        }
        'hosts' {
            $target = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
            if (-not $payloadPath -or -not (Test-Path -LiteralPath $payloadPath)) { $result.Status = 'fail'; $result.Msg = 'нет payload'; break }
            if (-not $Run) { $result.Status = 'dry'; $result.Msg = 'заменить hosts (с бэкапом)'; break }
            if (-not (Test-PckitAdmin)) { $result.Status = 'fail'; $result.Msg = 'нужен администратор'; break }
            $backup = Backup-PckitTarget -Path $target -BackupRoot $BackupRoot -Label 'hosts'
            if ($Journal -and $backup) { Add-PckitFileTracked -Journal $Journal -Target $target -BackupPath $backup }
            Copy-Item -LiteralPath $payloadPath -Destination $target -Force
            $result.Status = 'ok'
            $result.Msg = ('бэкап: ' + $backup)
        }
        'wifi' {
            if (-not $payloadPath -or -not (Test-Path -LiteralPath $payloadPath)) { $result.Status = 'fail'; $result.Msg = 'нет профилей'; break }
            $xmls = @(Get-ChildItem -LiteralPath $payloadPath -Filter *.xml -File -ErrorAction SilentlyContinue)
            if (-not $Run) { $result.Status = 'dry'; $result.Msg = ('профилей: {0}' -f $xmls.Count); break }
            $ok = 0
            foreach ($x in $xmls) {
                & netsh wlan add profile filename="$($x.FullName)" user=current 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { $ok++ }
            }
            $result.Status = if ($xmls.Count -eq 0 -or $ok -eq $xmls.Count) { 'ok' } elseif ($ok -eq 0) { 'fail' } else { 'partial' }
            $result.Msg = ('{0}/{1}' -f $ok, $xmls.Count)
            if ($Step.Meta -and $Step.Meta.passwordsIncluded -eq $false) {
                $result.Msg += ' (пароли не сохранялись — вводить заново)'
            }
        }
        'drivers' {
            if (-not $payloadPath -or -not (Test-Path -LiteralPath $payloadPath)) { $result.Status = 'note'; $result.Msg = 'драйверы не выгружены (нужен администратор)'; break }
            if (-not $Run) { $result.Status = 'dry'; $result.Msg = 'pnputil /add-driver'; break }
            if (-not (Test-PckitAdmin)) { $result.Status = 'fail'; $result.Msg = 'нужен администратор'; break }
            & pnputil /add-driver "$payloadPath\*.inf" /install /subdirs 2>&1 | Out-Null
            $result.Status = if ($LASTEXITCODE -eq 0) { 'ok' } else { 'fail' }
        }
        'checkexists' {
            $target = Resolve-PckitPath ([string]$Step.Meta.Target)
            $result.Status = if (Test-Path -LiteralPath $target) { 'ok' } else { 'missing' }
            $result.Msg = $target
        }
        'manual' {
            $result.Status = 'manual'
            $result.Msg = $Step.Detail
        }
        'note' {
            $result.Status = 'note'
            $result.Msg = $Step.Detail
        }
        'skip' {
            $result.Status = 'skip'
        }
        default {
            $result.Status = 'unknown'
        }
    }
    return $result
}

function Invoke-PckitPlan {
    param(
        [Parameter(Mandatory)][object[]]$Plan,
        [Parameter(Mandatory)][string]$ProfileRoot,
        [switch]$Run,
        [hashtable]$Progress = $null
    )

    $journal = Read-PckitJournal
    $stamp = (Get-Date).ToString('yyyy-MM-dd_HHmmss')
    $backupRoot = Join-Path (Get-PckitStatePath 'backups') $stamp
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    $logDir = Get-PckitStatePath 'logs'
    $logFile = Join-Path $logDir ('apply-{0}.log' -f $stamp)

    Write-PckitApplyLog -LogFile $logFile -Level step -Message ('применение плана: {0} шагов, режим {1}' -f $Plan.Count, $(if ($Run) { 'ЗАПУСК' } else { 'dry-run' }))

    $results = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($step in $Plan) {
        if ($step.Action -eq 'skip') {
            $results.Add([pscustomobject]@{ Step = $step; Status = 'skip'; Detail = ''; Msg = 'уже установлено' })
            continue
        }
        $i++
        Write-Progress -Activity 'Применение' -Status $step.Title -PercentComplete (($i / $Plan.Count) * 100)
        if ($Progress) {
            $Progress['Text'] = $step.Title
            $Progress['Index'] = $i
            $Progress['Total'] = $Plan.Count
        }
        try {
            $r = Invoke-PckitStep -Step $step -ProfileRoot $ProfileRoot -BackupRoot $backupRoot -LogFile $logFile -Journal $journal -Run:$Run
        } catch {
            $r = [pscustomobject]@{ Step = $step; Status = 'fail'; Detail = ''; Msg = $_.Exception.Message }
        }
        if ($r.Status -in 'fail', 'partial') {
            Write-PckitApplyLog -LogFile $logFile -Message ('{0}: {1} {2}' -f $r.Status, $step.Title, $r.Msg) -Level warn
        }
        elseif ($r.Status -eq 'dry') {
            Write-PckitApplyLog -LogFile $logFile -Message ('{0}: {1}' -f $step.Title, $r.Msg) -Level info
        }
        $results.Add($r)
    }
    Write-Progress -Activity 'Применение' -Completed

    $journalPath = $null
    if ($Run -and -not (Test-PckitJournalEmpty -Journal $journal)) {
        $journalPath = Save-PckitJournal -Journal $journal
    }

    Write-PckitApplyLog -LogFile $logFile -Level step -Message 'готово'
    return [pscustomobject]@{
        Results     = $results.ToArray()
        LogFile     = $logFile
        Backups     = $backupRoot
        JournalPath = $journalPath
        Run         = [bool]$Run
    }
}

function Show-PckitApplyResult {
    param($Result)

    $groups = $Result.Results | Group-Object Status
    Write-Host ''
    foreach ($g in ($groups | Sort-Object Name)) {
        $color = switch ($g.Name) { 'ok' { 'Green' } 'fail' { 'Red' } 'dry' { 'Cyan' } 'manual' { 'Yellow' } default { 'Gray' } }
        Write-Host ('  {0,-8} {1}' -f $g.Name, $g.Count) -ForegroundColor $color
    }
    $failed = @($Result.Results | Where-Object { $_.Status -eq 'fail' })
    if ($failed.Count) {
        Write-Host ''
        Write-PckitLog -Level warn -Message 'что не получилось:'
        foreach ($f in $failed) { Write-Host ('  - {0}: {1}' -f $f.Step.Title, $f.Msg) -ForegroundColor Red }
    }
    Write-Host ''
    if ($Result.Run) {
        Write-PckitLog -Level info -Message ('лог:    {0}' -f $Result.LogFile)
        Write-PckitLog -Level info -Message ('бэкапы: {0}' -f $Result.Backups)
    } else {
        Write-PckitLog -Level info -Message 'это был dry-run: ничего не изменено. Для запуска добавьте -Run'
    }
}
