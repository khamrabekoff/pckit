#Requires -Version 5.1
# pckit | тесты умного подбора, CS2 (autoexec / параметры запуска), отката партии и NVIDIA-журнала.
# Запуск: powershell -NoProfile -File tests\Smart.Tests.ps1
# Пишет только во временную папку и HKCU:\Software\pckit-test (удаляются в конце). Драйвер NVIDIA и Steam не трогает.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

. (Join-Path $root 'engine\Common.ps1')
. (Join-Path $root 'engine\Journal.ps1')
. (Join-Path $root 'engine\Actions.ps1')
. (Join-Path $root 'engine\Health.ps1')

$tmp = Join-Path $env:TEMP ('pckit-smart-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:PckitStateRoot = $tmp

$script:Pass = 0
$script:Fail = 0
function Assert-That {
    param([string]$Name, [bool]$Condition, [string]$Info = '')
    if ($Condition) { $script:Pass++; Write-Host ('PASS  {0}' -f $Name) -ForegroundColor Green }
    else { $script:Fail++; Write-Host ('FAIL  {0}  {1}' -f $Name, $Info) -ForegroundColor Red }
}

function New-Hw {
    param([hashtable]$Over = @{})
    $h = [ordered]@{ GpuVendor = 'nvidia'; GpuName = 'NVIDIA GeForce RTX 3070'; Laptop = $false; HybridGpu = $false; SystemSsd = $true
        Cs2Path = 'C:\Games\cs2'; Cs2Exe = 'C:\Games\cs2\game\bin\win64\cs2.exe'; Hags = $true; RamGb = 32; CpuCores = 6 }
    foreach ($k in $Over.Keys) { $h[$k] = $Over[$k] }
    return [pscustomobject]$h
}

$testKey = 'HKCU:\Software\pckit-test'
try {
    $actions = @(Get-PckitActions -Directory (Join-Path $root 'data'))
    $byId = @{}; foreach ($a in $actions) { $byId[[string]$a.id] = $a }

    # ---------- условия и подбор ----------
    $desk = New-Hw
    $lap = New-Hw @{ Laptop = $true; HybridGpu = $true }
    $amd = New-Hw @{ GpuVendor = 'amd'; GpuName = 'AMD Radeon RX 6700 XT' }
    $nocs = New-Hw @{ Cs2Path = $null; Cs2Exe = $null }
    $weak = New-Hw @{ RamGb = 8; CpuCores = 4; SystemSsd = $false }

    Assert-That 'условие gpu: nvidia' (Test-PckitHwCondition -Cond ([pscustomobject]@{ gpu = 'nvidia' }) -Hw $desk)
    Assert-That 'условие gpu: список' (Test-PckitHwCondition -Cond ([pscustomobject]@{ gpu = @('nvidia', 'amd') }) -Hw $amd)
    Assert-That 'условие gpu: не подходит' (-not (Test-PckitHwCondition -Cond ([pscustomobject]@{ gpu = 'nvidia' }) -Hw $amd))
    Assert-That 'условие ramGbMax' (Test-PckitHwCondition -Cond ([pscustomobject]@{ ramGbMax = 8 }) -Hw $weak)
    Assert-That 'условие ssd неизвестен = не выполнено' (-not (Test-PckitHwCondition -Cond ([pscustomobject]@{ ssd = $false }) -Hw (New-Hw @{ SystemSsd = $null })))

    $a = Get-PckitSmartAdvice -Action $byId['nv.cs2.power'] -Hw $desk
    Assert-That 'NVIDIA-настройка рекомендована на RTX' ($a.Applicable -and $a.Recommended)
    $a = Get-PckitSmartAdvice -Action $byId['nv.cs2.power'] -Hw $amd
    Assert-That 'NVIDIA-настройка не подходит AMD' (-not $a.Applicable -and $a.Reason -match 'NVIDIA') $a.Reason
    $a = Get-PckitSmartAdvice -Action $byId['cs2.autoexec'] -Hw $nocs
    Assert-That 'CS2-настройка не подходит без CS2' (-not $a.Applicable)
    $a = Get-PckitSmartAdvice -Action $byId['power.throttling.off'] -Hw $lap
    Assert-That 'ноутбук: Power Throttling не рекомендуем' ($a.Applicable -and -not $a.Recommended -and $a.Reason -match 'батаре') $a.Reason
    $a = Get-PckitSmartAdvice -Action $byId['power.throttling.off'] -Hw $desk
    Assert-That 'ПК: Power Throttling рекомендуем' ($a.Recommended)
    $a = Get-PckitSmartAdvice -Action $byId['gpu.cs2.highperf'] -Hw $lap
    Assert-That 'две видеокарты: закрепить CS2 рекомендуем' ($a.Recommended)
    $a = Get-PckitSmartAdvice -Action $byId['gpu.cs2.highperf'] -Hw $desk
    Assert-That 'одна видеокарта: закрепление по желанию' (-not $a.Recommended)
    $a = Get-PckitSmartAdvice -Action $byId['visualfx.perf'] -Hw $weak
    Assert-That '8 ГБ: облегчённый интерфейс рекомендуем' ($a.Recommended)
    $a = Get-PckitSmartAdvice -Action $byId['svc.sysmain.off'] -Hw $weak
    Assert-That 'HDD: SysMain не трогаем' (-not $a.Recommended -and $a.Reason -match 'HDD')
    $a = Get-PckitSmartAdvice -Action $byId['myth.nagle'] -Hw $desk
    Assert-That 'мифы никогда не рекомендуются' (-not $a.Recommended -and -not $a.Applicable)

    $plan = @(Get-PckitSmartPlan -Actions $actions -Hw $amd)
    Assert-That 'план: столько же строк, сколько действий' ($plan.Count -eq $actions.Count)
    Assert-That 'план AMD: ни одной NVIDIA-рекомендации' (@($plan | Where-Object { $_.Recommended -and $_.Action.id -like 'nv.*' }).Count -eq 0)

    # requires через движок: notfit в проверке и пропуск при применении
    $script:PckitHardwareCache = $amd
    $st = Test-PckitActionState -Action $byId['nv.cs2.power']
    Assert-That 'проверка: notfit на AMD' ($st.Status -eq 'notfit')
    $r = Invoke-PckitAction -Action $byId['nv.cs2.power'] -Journal (New-PckitJournal) -Run
    Assert-That 'применение: пропуск на AMD' ($r.Results[0].Status -eq 'skip' -and $r.Failed -eq 0)
    $script:PckitHardwareCache = $nocs
    $r = Invoke-PckitAction -Action $byId['gpu.cs2.highperf'] -Journal (New-PckitJournal)
    Assert-That 'подстановка {cs2exe} без CS2: пропуск' ($r.Results[0].Status -eq 'skip')
    $script:PckitHardwareCache = $desk
    Assert-That 'подстановка {cs2exe}' ((Expand-PckitActionText -Text '{cs2exe}') -eq $desk.Cs2Exe)

    # ---------- autoexec ----------
    $b1 = Get-PckitCs2CfgBlock -Lines @('rate 786432', 'cl_hud_telemetry_ping_show 1')
    $user = "bind f `"+use`"`r`nsensitivity 1.1"
    $t1 = Set-PckitCfgBlockText -Text $user -Block $b1
    Assert-That 'autoexec: строки пользователя сохранены' ($t1.StartsWith($user))
    Assert-That 'autoexec: блок прочитан' ((@(Get-PckitCfgBlockLines -Text $t1) -join '|') -eq 'rate 786432|cl_hud_telemetry_ping_show 1')
    $b2 = Get-PckitCs2CfgBlock -Lines @('rate 196608')
    $t2 = Set-PckitCfgBlockText -Text ($t1 + "`r`nviewmodel_fov 68") -Block $b2
    Assert-That 'autoexec: блок заменён, а не задвоен' (([regex]::Matches($t2, 'pckit: начало')).Count -eq 1 -and $t2 -match 'rate 196608' -and $t2 -notmatch '786432')
    Assert-That 'autoexec: строки после блока сохранены' ($t2 -match 'viewmodel_fov 68')
    Assert-That 'autoexec: пустой файл' ((Set-PckitCfgBlockText -Text '' -Block $b1).StartsWith('// >>> pckit'))

    # шаг cs2cfg на временной папке
    $cfgDir = Join-Path $tmp 'cfg'; New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    function Get-PckitCs2CfgDir { return $cfgDir }
    $j = New-PckitJournal
    $step = [pscustomobject]@{ type = 'cs2cfg'; lines = @('rate 786432', 'echo "x"') }
    $r = Invoke-PckitStepCs2Cfg -Step $step -Journal $j -Run
    $cfg = Join-Path $cfgDir 'autoexec.cfg'
    Assert-That 'cs2cfg: файл создан' ($r.Status -eq 'ok' -and (Test-Path -LiteralPath $cfg))
    Assert-That 'cs2cfg: без BOM' ([IO.File]::ReadAllBytes($cfg)[0] -ne 0xEF)
    Assert-That 'cs2cfg: в журнале «файл создал pckit»' (@($j.cs2).Count -eq 1 -and $j.cs2[0].kind -eq 'cfg' -and $j.cs2[0].created)
    $r = Invoke-PckitStepCs2Cfg -Step $step -Journal $j -Run
    Assert-That 'cs2cfg: повторно — «уже так»' ($r.Message -eq 'уже так')
    Assert-That 'cs2cfg: проверка' ((Test-PckitVerifyCs2Cfg -Verify $null).Ok)
    # пользователь дописал свою строку — откат убирает только блок pckit и не удаляет файл
    [IO.File]::AppendAllText($cfg, "bind x +jump`r`n")
    $rr = Restore-PckitJournal -Journal $j -Run
    $left = [IO.File]::ReadAllText($cfg)
    Assert-That 'cs2cfg: откат убрал только блок pckit' ($rr.Failed -eq 0 -and $left -match 'bind x \+jump' -and $left -notmatch 'pckit') $left
    # файл, в котором после отката ничего не осталось, удаляется (его создал pckit)
    Remove-Item -LiteralPath $cfg -Force
    $j = New-PckitJournal
    [void](Invoke-PckitStepCs2Cfg -Step $step -Journal $j -Run)
    [void](Restore-PckitJournal -Journal $j -Run)
    Assert-That 'cs2cfg: созданный pckit файл удалён при откате' (-not (Test-Path -LiteralPath $cfg))

    # ---------- localconfig.vdf ----------
    $vdf = @"
"UserLocalConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"apps"
				{
					"570"
					{
						"LaunchOptions"		"-dota"
					}
					"730"
					{
						"LastPlayed"		"1793824513"
						"cloud"
						{
							"LaunchOptions"		"nested-not-me"
						}
					}
				}
			}
		}
	}
}
"@
    $vdfFile = Join-Path $tmp 'localconfig.vdf'
    [IO.File]::WriteAllText($vdfFile, $vdf, (New-Object System.Text.UTF8Encoding($false)))
    function Get-PckitLocalConfigPath { return $vdfFile }
    function Get-PckitBackupDir { return $tmp }
    function Get-Process { }   # «Steam закрыт»

    $lo = Get-PckitCs2LaunchOptions
    Assert-That 'vdf: блок 730 найден, вложенный LaunchOptions не спутан' ($lo.Found -and $lo.Value -eq '') $lo.Value
    $j = New-PckitJournal
    $r = Invoke-PckitStepCs2Launch -Step ([pscustomobject]@{ add = @('+exec autoexec') }) -Journal $j -Run
    $lo = Get-PckitCs2LaunchOptions
    Assert-That 'vdf: параметр добавлен' ($r.Status -eq 'ok' -and $lo.Value -eq '+exec autoexec') $lo.Value
    Assert-That 'vdf: dota не тронута' ([IO.File]::ReadAllText($vdfFile) -match '"LaunchOptions"\s+"-dota"')
    Assert-That 'vdf: в журнале только добавленный параметр' (@($j.cs2).Count -eq 1 -and $j.cs2[0].kind -eq 'launch' -and (@($j.cs2[0].added) -join ',') -eq '+exec autoexec' -and -not @($j.files).Count)
    $r = Invoke-PckitStepCs2Launch -Step ([pscustomobject]@{ add = @('+exec autoexec', '-novid') }) -Journal $j -Run
    Assert-That 'vdf: дописано к существующему' ((Get-PckitCs2LaunchOptions).Value -eq '+exec autoexec -novid')
    # значения с кавычками и обратным слэшем переживают запись/чтение
    $txt = [IO.File]::ReadAllText($vdfFile)
    $tok = Get-PckitVdfTokens -Text $txt
    $blk = Find-PckitVdfBlock -Tokens $tok -Path $script:PckitCs2AppPath
    $vt = Find-PckitVdfValue -Tokens $tok -Block $blk -Key 'LaunchOptions'
    $tricky = '+exec "my cfg" -path C:\x'
    [IO.File]::WriteAllText($vdfFile, $txt.Substring(0, $vt.Start) + (ConvertTo-PckitVdfString $tricky) + $txt.Substring($vt.End), (New-Object System.Text.UTF8Encoding($false)))
    Assert-That 'vdf: экранирование кавычек и \' ((Get-PckitCs2LaunchOptions).Value -eq $tricky) (Get-PckitCs2LaunchOptions).Value
    Assert-That 'merge: без дублей' ((Merge-PckitLaunchOptions -Current '-novid +exec autoexec' -Add @('+exec autoexec')) -eq '-novid +exec autoexec')
    # пользователь сам добавил свой параметр — откат убирает только параметры pckit
    $txt = [IO.File]::ReadAllText($vdfFile)
    $tok = Get-PckitVdfTokens -Text $txt
    $vt = Find-PckitVdfValue -Tokens $tok -Block (Find-PckitVdfBlock -Tokens $tok -Path $script:PckitCs2AppPath) -Key 'LaunchOptions'
    [IO.File]::WriteAllText($vdfFile, $txt.Substring(0, $vt.Start) + (ConvertTo-PckitVdfString '-mine +exec autoexec -novid') + $txt.Substring($vt.End), (New-Object System.Text.UTF8Encoding($false)))
    # Steam открыт — откат не трогает файл (Steam перезаписал бы его) и остаётся в журнале
    function Get-Process { [pscustomobject]@{ Name = 'steam' } }
    $rr = Restore-PckitJournal -Journal $j -Run
    Assert-That 'vdf: при открытом Steam откат ждёт' ($rr.Failed -eq 2 -and (Get-PckitCs2LaunchOptions).Value -eq '-mine +exec autoexec -novid')
    function Get-Process { }
    $rr = Restore-PckitJournal -Journal (Read-PckitJournal) -Run
    Assert-That 'vdf: откат убрал только параметры pckit' ($rr.Failed -eq 0 -and (Get-PckitCs2LaunchOptions).Value -eq '-mine') (Get-PckitCs2LaunchOptions).Value
    Assert-That 'vdf: после отката dota не тронута' ([IO.File]::ReadAllText($vdfFile) -match '"LaunchOptions"\s+"-dota"')
    Assert-That 'vdf: журнал пуст после удачного отката' (Test-PckitJournalEmpty -Journal (Read-PckitJournal))
    Remove-Item Function:\Get-Process

    # ---------- откат только последней партии (-Since) ----------
    if (-not (Test-Path -LiteralPath $testKey)) { New-Item -Path $testKey -Force | Out-Null }
    Set-ItemProperty -LiteralPath $testKey -Name 'A' -Value 'a0'
    Set-ItemProperty -LiteralPath $testKey -Name 'B' -Value 'b0'
    $j = New-PckitJournal
    Add-PckitRegTracked -Journal $j -Path $testKey -Name 'A' -Value 'a1' -Type 'String'
    $j.registry[0].at = '2026-01-01T10:00:00'
    $since = '2026-01-01T11:00:00'
    Add-PckitRegTracked -Journal $j -Path $testKey -Name 'B' -Value 'b1' -Type 'String'
    $j.registry[1].at = '2026-01-01T11:00:05'
    [void]$j.nvidia.Add([pscustomobject]@{ exe = 'cs2.exe'; id = 8102046; title = 't'; restore = 'default'; value = $null; at = '2026-01-01T11:00:06' })
    Save-PckitJournal -Journal $j | Out-Null
    Assert-That 'журнал: nvidia считается' ((Get-PckitJournalCount -Journal (Read-PckitJournal)) -eq 3)

    # драйвер в тестах не трогаем: подменяем откат NVIDIA
    $script:NvRestored = 0
    function Restore-PckitNvidiaJournal { param($Entries, [switch]$Run) $script:NvRestored += @($Entries).Count; return @([pscustomobject]@{ Kind = 'видеокарта'; Title = 'x'; Status = 'ok'; Message = '' }) }

    $rr = Restore-PckitJournal -Journal (Read-PckitJournal) -Run -Since $since
    $p = Get-ItemProperty -LiteralPath $testKey
    Assert-That 'партия: B откатился' ($p.B -eq 'b0') $p.B
    Assert-That 'партия: A (раньше партии) остался' ($p.A -eq 'a1') $p.A
    Assert-That 'партия: NVIDIA откатили' ($script:NvRestored -eq 1)
    $left = Read-PckitJournal
    Assert-That 'партия: в журнале осталась только ранняя запись' (@($left.registry).Count -eq 1 -and $left.registry[0].name -eq 'A' -and @($left.nvidia).Count -eq 0)

    # повторная запись одной NVIDIA-настройки не теряет первое «до»
    $j = New-PckitJournal
    Add-PckitNvTracked -Journal $j -Exe 'cs2.exe' -Id 1 -Title 't' -Previous ([pscustomobject]@{ Status = 'ok'; UserSet = $true; Value = 5; Profile = 'p' })
    Add-PckitNvTracked -Journal $j -Exe 'cs2.exe' -Id 1 -Title 't' -Previous ([pscustomobject]@{ Status = 'ok'; UserSet = $true; Value = 9; Profile = 'p' })
    Assert-That 'nvidia: одна запись, первое значение' (@($j.nvidia).Count -eq 1 -and [int]$j.nvidia[0].value -eq 5 -and $j.nvidia[0].restore -eq 'value')
    $j = New-PckitJournal
    Add-PckitNvTracked -Journal $j -Exe 'cs2.exe' -Id 2 -Title 't' -Previous ([pscustomobject]@{ Status = 'ok'; UserSet = $false; Value = 0; Profile = 'p' })
    Assert-That 'nvidia: значение драйвера → откат «по умолчанию»' ($j.nvidia[0].restore -eq 'default')

    # ---------- вердикт ----------
    $rowsN = @([pscustomobject]@{ Metric = 'Процессов'; Verdict = 'без изменений' })
    $fb = [pscustomobject]@{ AvgFps = 400; Low1Fps = 200 }
    $v = Get-PckitSmartVerdict -Rows $rowsN -FpsBefore $fb -FpsAfter ([pscustomobject]@{ AvgFps = 430; Low1Fps = 220 })
    Assert-That 'вердикт: FPS вырос = помогло' ($v.Level -eq 'good' -and -not $v.SuggestUndo) $v.Level
    $v = Get-PckitSmartVerdict -Rows $rowsN -FpsBefore $fb -FpsAfter ([pscustomobject]@{ AvgFps = 360; Low1Fps = 170 })
    Assert-That 'вердикт: FPS упал = предложить откат' ($v.Level -eq 'bad' -and $v.SuggestUndo)
    $v = Get-PckitSmartVerdict -Rows $rowsN -FpsBefore $fb -FpsAfter ([pscustomobject]@{ AvgFps = 405; Low1Fps = 199 })
    Assert-That 'вердикт: ±3% = шум' ($v.Level -eq 'neutral' -and -not $v.SuggestUndo)
    $v = Get-PckitSmartVerdict -Rows @([pscustomobject]@{ Metric = 'Время в DPC'; Verdict = 'хуже' }) -FpsBefore $null -FpsAfter $null
    Assert-That 'вердикт: DPC хуже без FPS = предложить откат' ($v.SuggestUndo -and -not $v.FpsKnown)

    # ---------- последняя партия ----------
    Save-PckitLastBatch -Since '2026-01-01T11:00:00' -Ids @('a', 'b')
    $lb = Get-PckitLastBatch
    Assert-That 'партия сохраняется' ($lb.since -eq '2026-01-01T11:00:00' -and @($lb.ids).Count -eq 2)
    Clear-PckitLastBatch
    Assert-That 'партия очищается' ($null -eq (Get-PckitLastBatch))

    # ---------- советы ----------
    $hwBad = New-Hw @{ PrimaryHz = 60; PrimaryMaxHz = 144; RamType = 'DDR4'; RamMhz = 2133; OnBattery = $true; WifiOnly = $true
        Cs2Video = [pscustomobject]@{ RefreshHz = 60; VSync = 1; LowLatency = 0; Fullscreen = 0 } }
    $titles = @(Get-PckitSmartFindings -Hw $hwBad | ForEach-Object { $_.Title }) -join ' | '
    Assert-That 'совет: монитор не на максимуме' ($titles -match '60 Гц, а умеет 144') $titles
    Assert-That 'совет: XMP' ($titles -match 'XMP')
    Assert-That 'совет: Reflex' ($titles -match 'Reflex')
    Assert-That 'совет: V-Sync в игре' ($titles -match 'вертикальная синхронизация')
    Assert-That 'совет: батарея' ($titles -match 'батаре')
    $hwGood = New-Hw @{ PrimaryHz = 280; PrimaryMaxHz = 280; RamType = 'DDR4'; RamMhz = 3200; Cs2Video = [pscustomobject]@{ RefreshHz = 280; VSync = 0; LowLatency = 1; Fullscreen = 1 } }
    $bad = @(Get-PckitSmartFindings -Hw $hwGood | Where-Object { $_.Severity -in 'bad', 'warn' })
    Assert-That 'советы: у настроенного ПК замечаний нет' ($bad.Count -eq 0) (($bad | ForEach-Object { $_.Title }) -join '; ')

    # ---------- старые драйверы: только логика отбора ----------
    . (Join-Path $root 'engine\Clean.ps1')
    $pk = {
        param($pub, $inf, $prov, $cls, $ver, $date)
        [pscustomobject]@{ Published = $pub; Inf = $inf; Provider = $prov; Class = $cls; Version = $ver; Date = [datetime]$date; Folder = $null }
    }
    $pkgs = @(
        (& $pk 'oem1.inf' 'nv_disp.inf' 'NVIDIA' 'Display' '32.0.15.6094' '2024-08-01'),
        (& $pk 'oem2.inf' 'nv_disp.inf' 'NVIDIA' 'Display' '32.0.16.2101' '2026-10-19'),
        (& $pk 'oem3.inf' 'nv_disp.inf' 'NVIDIA' 'Display' '31.0.15.5222' '2024-03-01'),
        (& $pk 'oem4.inf' 'ibt.inf' 'Intel' 'Bluetooth' '24.10.0.4' '2023-01-01'),
        (& $pk 'oem5.inf' 'ibt.inf' 'Intel' 'Bluetooth' '24.40.10.3' '2025-01-01'),
        (& $pk 'oem6.inf' 'ibt.inf' 'Intel' 'Bluetooth' '24.10.0.4' '2023-01-01'),
        (& $pk 'oem7.inf' 'solo.inf' 'Realtek' 'Net' '1.0.0.0' '2020-01-01'),
        (& $pk 'oem8.inf' 'dup.inf' 'X' 'System' '2.0.0.0' '2021-01-01'),
        (& $pk 'oem9.inf' 'dup.inf' 'X' 'System' '2.0.0.0' '2022-01-01'),
        (& $pk 'oem10.inf' 'nv_disp.inf' 'Other Vendor' 'Display' '1.0.0.0' '2019-01-01')
    )
    $inUse = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [void]$inUse.Add('OEM6.INF')
    $sel = @(Select-PckitOldDrivers -Packages $pkgs -InUse $inUse)
    $ids = @($sel | ForEach-Object { $_.Published } | Sort-Object)
    Assert-That 'драйверы: старые NVIDIA найдены' ($ids -contains 'oem1.inf' -and $ids -contains 'oem3.inf')
    Assert-That 'драйверы: новейший остаётся' ($ids -notcontains 'oem2.inf' -and $ids -notcontains 'oem5.inf')
    Assert-That 'драйверы: используемый устройством остаётся' ($ids -notcontains 'oem6.inf')
    Assert-That 'драйверы: старый Intel без устройства удаляется' ($ids -contains 'oem4.inf')
    Assert-That 'драйверы: единственная версия не трогается' ($ids -notcontains 'oem7.inf')
    Assert-That 'драйверы: дубли одной версии не трогаются' ($ids -notcontains 'oem8.inf' -and $ids -notcontains 'oem9.inf')
    Assert-That 'драйверы: другой производитель — другая группа' ($ids -notcontains 'oem10.inf')
    Assert-That 'драйверы: ровно 3 кандидата' ($ids.Count -eq 3) ($ids -join ',')
    Assert-That 'драйверы: указана версия, которая остаётся' (@($sel | Where-Object { $_.Published -eq 'oem1.inf' })[0].Newest -eq '32.0.16.2101')
    Assert-That 'драйверы: пункт чистки выключен по умолчанию (риск medium)' ((@(Get-PckitCleanTargets | Where-Object { $_.Id -eq 'drivers.old' })[0]).Risk -eq 'medium')
} catch {
    $script:Fail++
    Write-Host ('FAIL  необработанное исключение: {0} (строка {1})' -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber) -ForegroundColor Red
} finally {
    if (Test-Path -LiteralPath $testKey) { Remove-Item -LiteralPath $testKey -Recurse -Force }
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host ('Итого: PASS {0}, FAIL {1}' -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
