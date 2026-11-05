#Requires -Version 5.1
# pckit | полный прогон в Windows Sandbox: применить ВСЕ настройки → проверить → откатить → сравнить реестр,
# чистка, «для работы» (без программ), отчёт для друга, скриншоты всех вкладок.
# Запускается сам из pckit-test.wsb. Результаты — в tests\sandbox\out (папка проекта, проброшена в песочницу).

$ErrorActionPreference = 'Continue'
$src = 'C:\pckit-src'
$out = 'C:\pckit-out'
$work = 'C:\pckit'
New-Item -ItemType Directory -Force -Path $out | Out-Null
Get-ChildItem -LiteralPath $out -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
$log = Join-Path $out 'result.txt'
function Say { param([string]$m) $line = '{0}  {1}' -f (Get-Date).ToString('HH:mm:ss'), $m; Add-Content -LiteralPath $log -Value $line -Encoding UTF8; Write-Host $line }
$script:Fails = 0
function Check { param([string]$Name, [bool]$Ok, [string]$Info = '') if ($Ok) { Say "PASS  $Name" } else { $script:Fails++; Say "FAIL  $Name  $Info" } }

Say ('Windows {0}, PowerShell {1}' -f [Environment]::OSVersion.Version, $PSVersionTable.PSVersion)
Copy-Item -LiteralPath $src -Destination $work -Recurse -Force
Remove-Item -LiteralPath (Join-Path $work 'dist') -Recurse -Force -ErrorAction SilentlyContinue

try {
    . (Join-Path $work 'engine\Common.ps1')
    . (Join-Path $work 'engine\Journal.ps1')
    . (Join-Path $work 'engine\Actions.ps1')
    . (Join-Path $work 'engine\Health.ps1')
    . (Join-Path $work 'engine\Clean.ps1')
    . (Join-Path $work 'engine\Share.ps1')

    $actions = @(Get-PckitActions -Directory (Join-Path $work 'data'))
    $targets = @($actions | Where-Object { -not $_.myth })
    Say ('действий: {0}, к применению: {1}' -f $actions.Count, $targets.Count)

    # снимок всех затрагиваемых значений реестра
    function Get-RegSnapshot {
        $map = @{}
        foreach ($a in $targets) {
            foreach ($s in @($a.steps)) {
                if (-not $s -or [string]$s.type -notin 'reg', 'regkv') { continue }
                $name = Expand-PckitActionText -Text ([string]$s.name)
                if (-not $name) { continue }
                $st = Get-PckitRegState -Path ([string]$s.path) -Name $name
                $map[('{0}::{1}' -f $s.path, $name)] = if ($st.Exists) { (@($st.Value) -join ',') } else { '<нет>' }
            }
        }
        return $map
    }
    function Get-SvcSnapshot { $m = @{}; foreach ($n in 'SysMain', 'DiagTrack', 'dmwappushservice', 'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'WSearch') { $i = Get-PckitServiceInfo -Name $n; $m[$n] = [string]$i.Mode }; return $m }
    $plan0 = Get-PckitActivePowerPlan
    $reg0 = Get-RegSnapshot
    $svc0 = Get-SvcSnapshot

    $hw = Get-PckitHardwareProfile
    Say ('железо: {0}' -f (Format-PckitHardwareLine $hw))

    # 1. применить всё
    $res = Invoke-PckitActions -Actions $targets -Run
    Check 'применение без исключений' ($null -ne $res)
    foreach ($r in @($res.Results)) {
        foreach ($s in @($r.Results)) { if ($s.Status -eq 'fail') { Say ('  не применилось: {0}: {1}' -f $r.Action.id, $s.Message) } }
    }
    Check 'применение: ошибок нет' ($res.Failed -eq 0) ('ошибок: {0}' -f $res.Failed)

    # 2. проверить, что включилось
    $states = @(Get-PckitActionsState -Actions $targets -SkipProgress)
    foreach ($s in $states) {
        if ($s.Status -in 'notfit', 'unsupported') { Say ('  пропущено (не подходит): {0} — {1}' -f $s.Action.id, $s.Detail); continue }
        Check ('включено: {0}' -f $s.Action.id) ($s.Status -eq 'applied') ('{0}: {1}' -f $s.Status, $s.Detail)
    }

    # 3. откатить всё и сравнить
    $j = Read-PckitJournal
    Say ('в журнале: {0}' -f (Get-PckitJournalCount -Journal $j))
    $rr = Restore-PckitJournal -Journal $j -Run
    Check 'откат без ошибок' ($rr.Failed -eq 0) ('ошибок: {0}' -f $rr.Failed)
    foreach ($i in @($rr.Items)) { if ($i.Status -eq 'fail') { Say ('  откат не удался: {0}: {1}' -f $i.Title, $i.Message) } }
    $reg1 = Get-RegSnapshot
    $diff = @($reg0.Keys | Where-Object { $reg0[$_] -ne $reg1[$_] })
    Check 'реестр после отката как был' ($diff.Count -eq 0) (($diff | Select-Object -First 10 | ForEach-Object { '{0}: было {1}, стало {2}' -f $_, $reg0[$_], $reg1[$_] }) -join ' | ')
    $svc1 = Get-SvcSnapshot
    $sdiff = @($svc0.Keys | Where-Object { $svc0[$_] -ne $svc1[$_] })
    Check 'службы после отката как были' ($sdiff.Count -eq 0) (($sdiff | ForEach-Object { '{0}: {1} -> {2}' -f $_, $svc0[$_], $svc1[$_] }) -join ' | ')
    Check 'схема питания вернулась' ((Get-PckitActivePowerPlan) -eq $plan0) ('{0} -> {1}' -f $plan0, (Get-PckitActivePowerPlan))
    Check 'журнал пуст после отката' (Test-PckitJournalEmpty -Journal (Read-PckitJournal))

    # 4. чистка (всё безопасное + старые драйверы)
    $ct = @(Get-PckitCleanTargets | Where-Object { $_.Risk -eq 'low' -and $_.Kind -notin 'dism', 'info' })
    $cr = Invoke-PckitClean -Targets $ct -Run
    Check 'чистка без падений' ($null -ne $cr)
    foreach ($x in @($cr.Results)) { if ($x.Status -eq 'fail') { Say ('  чистка: {0}: {1}' -f $x.Target.Title, $x.Message) } }
    Say ('чистка: освобождено {0} МБ' -f $cr.FreedMb)
    $dr = Remove-PckitOldDrivers
    Say ('старых драйверов найдено: {0}' -f @($dr.Items).Count)

    # 5. проверка ПК, работа, отчёт
    $health = Get-PckitHealthReport -ActionsDir (Join-Path $work 'data')
    Check 'проверка ПК работает' ($health -and @($health.Findings).Count -gt 0)
    $apps = @(Get-PckitWorkApps); $rep = @(Get-PckitWorkReports -Apps $apps)
    Say ('рабочие программы: {0}, крупное: {1}' -f $apps.Count, $rep.Count)
    $html = New-PckitShareReport -Hw $hw -Health $health -ActionStates $states -Plan @(Get-PckitSmartPlan -Actions $actions -Hw $hw) -JournalCount 0 -Network $null
    $p = Save-PckitShareReport -Html $html -Folder $out
    Check 'отчёт для друга сохранён' (Test-Path -LiteralPath $p)
} catch {
    $script:Fails++
    Say ('FAIL  исключение: {0} @ {1}' -f $_.Exception.Message, $_.InvocationInfo.PositionMessage)
}

# 6. скриншоты всех вкладок (окно рисуется вне экрана)
foreach ($tab in 1..11) {
    $png = Join-Path $out ('tab{0:00}.png' -f $tab)
    $o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $work 'pckit-ui.ps1') -SelfTest -Tab $tab -SelfTestSize '1366x728' -SelfTestPath $png 2>&1 | Out-String
    Check ('окно, вкладка {0}' -f $tab) (Test-Path -LiteralPath $png) (($o -split "`n" | Where-Object { $_ -match 'Exception|ошибк|error' } | Select-Object -First 2) -join ' ')
}

Say ''
Say ('ИТОГО: ошибок {0}' -f $script:Fails)
Set-Content -LiteralPath (Join-Path $out 'done.flag') -Value $script:Fails
