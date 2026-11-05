#Requires -Version 5.1
# pckit | тесты движка действий. Запуск: powershell -NoProfile -File tests\Actions.Tests.ps1
# Реально пишет только в HKCU:\Software\pckit-test (удаляется в конце). Журнал — во временной папке.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

. (Join-Path $root 'engine\Common.ps1')
. (Join-Path $root 'engine\Journal.ps1')
. (Join-Path $root 'engine\Actions.ps1')

# СРАЗУ: никогда не трогать настоящий %ProgramData%\pckit\undo.json
$stateDir = Join-Path $env:TEMP 'pckit-test-state'
if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null }
$script:PckitStateRoot = $stateDir

$script:Pass = 0
$script:Fail = 0
function Assert-That {
    param([string]$Name, [bool]$Condition, [string]$Info = '')
    if ($Condition) { $script:Pass++; Write-Host ('PASS  {0}' -f $Name) -ForegroundColor Green }
    else { $script:Fail++; Write-Host ('FAIL  {0}  {1}' -f $Name, $Info) -ForegroundColor Red }
}

$testKey = 'HKCU:\Software\pckit-test'

try {
    # ---------- actions.json ----------
    $actions = $null
    try { $actions = Get-PckitActions -Directory (Join-Path $root 'data') } catch { }
    Assert-That 'actions.json парсится' ($actions -and @($actions).Count -gt 0)

    $ids = @($actions | ForEach-Object { $_.id })
    Assert-That 'id уникальны' ($ids.Count -eq @($ids | Select-Object -Unique).Count)

    $stepTypes = @('reg', 'regkv', 'powerplan', 'service', 'task', 'powercfg', 'hibernate', 'netpower', 'devreg', 'nvidia', 'cs2cfg', 'cs2launch', 'workgpu')
    $verifyTypes = @('reg', 'regkv', 'powerplan', 'service', 'task', 'powercfg', 'netpower', 'devreg', 'nvidia', 'cs2cfg', 'cs2launch', 'workgpu')

    $bad = New-Object System.Collections.ArrayList
    foreach ($a in $actions) {
        if ($a.myth) {
            if (@($a.steps | Where-Object { $_ }).Count -gt 0) { [void]$bad.Add(('{0}: у мифа есть steps' -f $a.id)) }
            if (-not $a.expert) { [void]$bad.Add(('{0}: миф не expert' -f $a.id)) }
            continue
        }
        if (@($a.steps | Where-Object { $_ }).Count -eq 0) { [void]$bad.Add(('{0}: нет steps' -f $a.id)) }
        if (@($a.verify | Where-Object { $_ }).Count -eq 0) { [void]$bad.Add(('{0}: нет verify' -f $a.id)) }
        foreach ($s in @($a.steps)) { if ($stepTypes -notcontains [string]$s.type) { [void]$bad.Add(('{0}: шаг {1}' -f $a.id, $s.type)) } }
        foreach ($v in @($a.verify)) { if ($verifyTypes -notcontains [string]$v.type) { [void]$bad.Add(('{0}: проверка {1}' -f $a.id, $v.type)) } }
    }
    Assert-That 'структура действий (steps/verify/типы/myth)' ($bad.Count -eq 0) ($bad -join '; ')

    # ---------- dry-run и состояние ----------
    $dryOk = $true; $dryErr = ''
    try { $null = Invoke-PckitActions -Actions @($actions) } catch { $dryOk = $false; $dryErr = $_.Exception.Message }
    Assert-That 'dry-run Invoke-PckitActions без исключений' $dryOk $dryErr

    $states = $null; $stErr = ''
    try { $states = Get-PckitActionsState -Actions @($actions) -SkipProgress } catch { $stErr = $_.Exception.Message }
    Assert-That 'Get-PckitActionsState без исключений' ($null -ne $states) $stErr
    $allowed = @('applied', 'partial', 'notApplied', 'myth', 'unsupported', 'notfit')
    $badStatus = @($states | Where-Object { $allowed -notcontains $_.Status })
    Assert-That 'статусы из допустимого множества' ($badStatus.Count -eq 0)

    $mythAction = @($actions | Where-Object { $_.myth })[0]
    $mr = Invoke-PckitAction -Action $mythAction -Journal (New-PckitJournal) -Run:$false
    Assert-That 'myth: Invoke даёт skip' ($mr.Results[0].Status -eq 'skip')

    # «на свой риск»: всегда expert, никогда не рекомендуется и не попадает в «Всё сразу»
    $hwT = Get-PckitHardwareProfile
    $dBad = @($actions | Where-Object { $_.danger } | Where-Object { -not $_.expert -or $_.myth -or (Get-PckitSmartAdvice -Action $_ -Hw $hwT).Recommended } | ForEach-Object { $_.id })
    Assert-That 'danger: expert, не миф, не рекомендуется' (@($actions | Where-Object { $_.danger }).Count -gt 0 -and $dBad.Count -eq 0) ($dBad -join ', ')

    # devreg: поиск устройств не падает и не даёт пустых путей; неизвестная цель — пусто и skip
    $devBad = @()
    foreach ($tg in 'display', 'net', 'tcpif', 'pcidisplay') {
        foreach ($p in @(Get-PckitDevRegTargets -Step ([pscustomobject]@{ target = $tg; name = '*EEE'; ndi = $true; sub = 'x' }))) {
            if (-not $p -or [string]$p -notlike 'HKLM:\*') { $devBad += ('{0}: "{1}"' -f $tg, $p) }
        }
    }
    Assert-That 'devreg: пути устройств корректны' ($devBad.Count -eq 0) ($devBad -join '; ')
    $none = [pscustomobject]@{ type = 'devreg'; target = 'nothing'; name = 'X'; value = 1 }
    Assert-That 'devreg: нет устройств -> 0 путей' (@(Get-PckitDevRegTargets -Step $none).Count -eq 0)
    Assert-That 'devreg: нет устройств -> skip' ((Invoke-PckitStepDevReg -Step $none -Run).Status -eq 'skip')
    Assert-That 'devreg: проверка без устройств не падает' ((Test-PckitVerifyDevReg -Verify $none).Ok)
    Assert-That 'myth: Test даёт myth' ((Test-PckitActionState -Action $mythAction).Status -eq 'myth')

    $future = [pscustomobject]@{ id = 'x'; title = 'x'; minBuild = 999999; steps = @([pscustomobject]@{ type = 'hibernate' }); verify = @([pscustomobject]@{ type = 'netpower' }) }
    Assert-That 'minBuild: Test даёт unsupported' ((Test-PckitActionState -Action $future).Status -eq 'unsupported')
    $fr = Invoke-PckitAction -Action $future -Journal (New-PckitJournal) -Run:$false
    Assert-That 'minBuild: Invoke даёт skip' ($fr.Results[0].Status -eq 'skip' -and $fr.Results[0].Message -eq 'не для этой версии Windows')

    $sum = Get-PckitActionSummary -Action $mythAction
    Assert-That 'Get-PckitActionSummary: Myth/Expert' ($sum.Myth -and $sum.Expert)

    # ---------- powerplan-first ----------
    $fake = @(
        [pscustomobject]@{ id = 'a'; steps = @([pscustomobject]@{ type = 'reg' }) },
        [pscustomobject]@{ id = 'b'; steps = @([pscustomobject]@{ type = 'powerplan' }) },
        [pscustomobject]@{ id = 'c'; steps = @([pscustomobject]@{ type = 'powercfg' }) },
        [pscustomobject]@{ id = 'd'; steps = @([pscustomobject]@{ type = 'reg' }, [pscustomobject]@{ type = 'powerplan' }) }
    )
    $sorted = @(Sort-PckitActionsPowerFirst -Actions $fake | ForEach-Object { $_.id })
    Assert-That 'сортировка powerplan-first (стабильная)' (($sorted -join ',') -eq 'b,d,a,c') ($sorted -join ',')

    # ---------- разбор powercfg ----------
    $sample = @(
        'GUID схемы питания: 381b4222-f694-41f0-9685-ff5bb260df2e  (Сбалансированная)',
        '  Псевдоним GUID: SCHEME_BALANCED',
        '  Минимально возможное значение: 0x00000000',
        '  Максимально возможное значение: 0xffffffff',
        '  Индекс текущей настройки питания переменного тока: 0x00000001',
        '  Индекс текущей настройки питания постоянного тока: 0x00000000'
    )
    $pv = Get-PckitPowerValueFromQuery -Text $sample
    Assert-That 'разбор powercfg: AC=1, DC=0' ($pv -and $pv.Ac -eq 1 -and $pv.Dc -eq 0)
    Assert-That 'разбор powercfg: нет значений -> $null' ($null -eq (Get-PckitPowerValueFromQuery -Text 'ошибка'))

    # ---------- реальная запись в HKCU:\Software\pckit-test ----------
    New-Item -Path $testKey -Force | Out-Null
    New-ItemProperty -LiteralPath $testKey -Name 'Kv' -Value 'Foo=1;Bar=2;' -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $testKey -Name 'Bin' -Value ([byte[]](1, 2, 3)) -PropertyType Binary -Force | Out-Null
    New-ItemProperty -LiteralPath $testKey -Name 'Str' -Value 'old' -PropertyType String -Force | Out-Null

    $synthetic = [pscustomobject]@{
        id = 'test.synthetic'; title = 'test'
        steps = @(
            [pscustomobject]@{ type = 'regkv'; path = $testKey; name = 'Kv'; key = 'Bar'; value = '5' },
            [pscustomobject]@{ type = 'regkv'; path = $testKey; name = 'Kv'; key = 'Baz'; value = '1' },
            [pscustomobject]@{ type = 'reg'; path = $testKey; name = 'Bin'; value = @(144, 18, 3, 128, 16, 0, 0, 0); valueType = 'Binary' },
            [pscustomobject]@{ type = 'reg'; path = $testKey; name = 'Str'; value = 'new'; valueType = 'String' },
            [pscustomobject]@{ type = 'reg'; path = $testKey; name = 'Fresh'; value = 7; valueType = 'DWord' }
        )
        verify = @(
            [pscustomobject]@{ type = 'regkv'; path = $testKey; name = 'Kv'; key = 'Bar'; value = '5' },
            [pscustomobject]@{ type = 'regkv'; path = $testKey; name = 'Kv'; key = 'Baz'; value = '1' },
            [pscustomobject]@{ type = 'reg'; path = $testKey; name = 'Bin'; value = @(144, 18, 3, 128, 16, 0, 0, 0) },
            [pscustomobject]@{ type = 'reg'; path = $testKey; name = 'Fresh'; value = 7 }
        )
    }
    Assert-That 'synthetic: до применения notApplied/partial' ((Test-PckitActionState -Action $synthetic).Status -ne 'applied')

    $journal = New-PckitJournal
    $r = Invoke-PckitAction -Action $synthetic -Journal $journal -Run
    Assert-That 'synthetic: применение без ошибок' ($r.Failed -eq 0) (($r.Results | ForEach-Object { $_.Message }) -join ';')

    $kv = (Get-ItemProperty -LiteralPath $testKey -Name 'Kv').Kv
    Assert-That 'regkv: итоговая строка' ($kv -eq 'Foo=1;Bar=5;Baz=1;') $kv
    $st = Test-PckitActionState -Action $synthetic
    Assert-That 'synthetic: verify -> applied' ($st.Status -eq 'applied') (($st.Checks | ForEach-Object { $_.Detail }) -join ';')

    $rr = Restore-PckitJournal -Journal $journal -Run
    Assert-That 'Restore-PckitJournal без ошибок' ($rr.Failed -eq 0)
    $props = Get-ItemProperty -LiteralPath $testKey
    Assert-That 'откат: regkv вернулся' ($props.Kv -eq 'Foo=1;Bar=2;') $props.Kv
    Assert-That 'откат: Binary вернулся' ((@($props.Bin) -join ',') -eq '1,2,3') (@($props.Bin) -join ',')
    Assert-That 'откат: String вернулся' ($props.Str -eq 'old')
    Assert-That 'откат: новое значение удалено' ($null -eq $props.Fresh)
} catch {
    $script:Fail++
    Write-Host ('FAIL  необработанное исключение: {0}' -f $_.Exception.Message) -ForegroundColor Red
} finally {
    if (Test-Path -LiteralPath 'HKCU:\Software\pckit-test') { Remove-Item -LiteralPath 'HKCU:\Software\pckit-test' -Recurse -Force }
    if (Test-Path -LiteralPath $stateDir) { Remove-Item -LiteralPath $stateDir -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host ('Итого: PASS {0}, FAIL {1}' -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
