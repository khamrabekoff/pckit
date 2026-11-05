#Requires -Version 5.1
# pckit engine | actions: game/system tweaks as data (apply / verify / undo)

function Get-PckitActions {
    param([string]$Directory)

    $file = Join-Path $Directory 'actions.json'
    if (-not (Test-Path -LiteralPath $file)) { return @() }

    $raw = Get-Content -LiteralPath $file -Raw -Encoding UTF8
    $data = ConvertFrom-Json $raw
    return @($data)
}

function Get-PckitRegState {
    param([string]$Path, [string]$Name)

    $value = $null
    $exists = $false
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($item -and ($item.GetValueNames() -contains $Name)) {
            $exists = $true
            $value = $item.GetValue($Name)
        }
    }
    return [pscustomobject]@{ Exists = $exists; Value = $value }
}

function Get-PckitActivePowerPlan {
    $out = & powercfg /getactivescheme 2>$null
    if ($out -match '([0-9a-fA-F-]{36})') { return $matches[1] }
    return $null
}

# ---------- вспомогательные функции шагов ----------

# значение из строки вида "a=1;b=2;"
function Get-PckitKvValue {
    param([string]$Text, [string]$Key)
    foreach ($p in ($Text -split ';')) {
        $i = $p.IndexOf('=')
        if ($i -gt 0 -and $p.Substring(0, $i).Trim() -ieq $Key) { return $p.Substring($i + 1) }
    }
    return $null
}

function Set-PckitKvValue {
    param([string]$Text, [string]$Key, [string]$Value)
    $parts = New-Object System.Collections.ArrayList
    $found = $false
    foreach ($p in ($Text -split ';')) {
        if (-not $p.Trim()) { continue }
        $i = $p.IndexOf('=')
        if ($i -gt 0 -and $p.Substring(0, $i).Trim() -ieq $Key) {
            if (-not $found) { [void]$parts.Add(('{0}={1}' -f $Key, $Value)); $found = $true }
            continue
        }
        [void]$parts.Add($p)
    }
    if (-not $found) { [void]$parts.Add(('{0}={1}' -f $Key, $Value)) }
    return (($parts -join ';') + ';')
}

# значение массива байт из JSON (object[]) -> byte[]
function ConvertTo-PckitByteArray {
    param($Value)
    $list = New-Object System.Collections.ArrayList
    foreach ($b in @($Value)) { [void]$list.Add([byte]$b) }
    return , ([byte[]]$list.ToArray())
}

# вывод `powercfg /query` локализован: берём два последних 0x........ (AC, затем DC)
function Get-PckitPowerValueFromQuery {
    param($Text)
    $joined = (@($Text) | ForEach-Object { [string]$_ }) -join "`n"
    $found = [regex]::Matches($joined, '0x[0-9a-fA-F]{8}')
    if ($found.Count -lt 2) { return $null }
    $ac = [Convert]::ToInt64($found[$found.Count - 2].Value.Substring(2), 16)
    $dc = [Convert]::ToInt64($found[$found.Count - 1].Value.Substring(2), 16)
    return [pscustomobject]@{ Ac = $ac; Dc = $dc }
}

function Get-PckitPowerSetting {
    param([string]$Scheme, [string]$Subgroup, [string]$Setting)
    if (-not $Scheme) { return $null }
    $out = & powercfg /query $Scheme $Subgroup $Setting 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return (Get-PckitPowerValueFromQuery -Text $out)
}

function Get-PckitServiceInfo {
    param([string]$Name)
    $svc = $null
    try {
        $svc = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $Name.Replace("'", "''")) -ErrorAction Stop
    } catch { $svc = $null }
    if (-not $svc) { return [pscustomobject]@{ Exists = $false; Mode = $null; Running = $false } }

    $mode = switch ([string]$svc.StartMode) {
        'Auto'     { 'auto' }
        'Manual'   { 'demand' }
        'Disabled' { 'disabled' }
        'Boot'     { 'boot' }
        'System'   { 'system' }
        default    { 'demand' }
    }
    if ($mode -eq 'auto') {
        $d = Get-PckitRegState -Path ('HKLM:\SYSTEM\CurrentControlSet\Services\{0}' -f $Name) -Name 'DelayedAutostart'
        if ($d.Exists -and [int]$d.Value -eq 1) { $mode = 'delayed-auto' }
    }
    return [pscustomobject]@{ Exists = $true; Mode = $mode; Running = ([string]$svc.State -eq 'Running') }
}

function ConvertTo-PckitScMode {
    param([string]$StartType)
    switch -regex ($StartType) {
        '^(?i)disabled$'  { return 'disabled' }
        '^(?i)manual$'    { return 'demand' }
        '^(?i)automatic$' { return 'auto' }
        default           { return $null }
    }
}

function Test-PckitScModeEqual {
    param([string]$Current, [string]$Target)
    if ($Current -eq $Target) { return $true }
    if ($Target -eq 'auto' -and $Current -eq 'delayed-auto') { return $true }
    return $false
}

function Get-PckitTaskByPath {
    param([string]$Path)
    $idx = $Path.LastIndexOf('\')
    if ($idx -lt 0) { return $null }
    $taskPath = $Path.Substring(0, $idx + 1)
    $taskName = $Path.Substring($idx + 1)
    try {
        return (Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop)
    } catch { return $null }
}

function Get-PckitHibernateEnabled {
    $s = Get-PckitRegState -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name 'HibernateEnabled'
    if ($s.Exists) { return ([int]$s.Value -ne 0) }
    return (Test-Path -LiteralPath (Join-Path $env:SystemDrive '\hiberfil.sys'))
}

# физические адаптеры, которым Windows разрешает выключаться для экономии энергии
function Get-PckitNetPowerAdapters {
    $result = New-Object System.Collections.ArrayList
    $adapters = @()
    try { $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop) } catch { $adapters = @() }
    foreach ($a in $adapters) {
        $pm = $null
        try { $pm = Get-NetAdapterPowerManagement -Name $a.Name -ErrorAction Stop } catch { $pm = $null }
        if (-not $pm) { continue }
        [void]$result.Add([pscustomobject]@{ Name = [string]$a.Name; Allow = [string]$pm.AllowComputerToTurnOffDevice })
    }
    return $result.ToArray()
}

function Test-PckitActionSupported {
    param($Action)
    if ($Action.minBuild) {
        return ([Environment]::OSVersion.Version.Build -ge [int]$Action.minBuild)
    }
    return $true
}

# подстановки в путях и именах: {cs2exe} — полный путь к cs2.exe; $null, если подставить нечего
function Expand-PckitActionText {
    param([string]$Text)
    if ($Text -notmatch '\{[a-z0-9]+\}') { return $Text }
    if ($Text -match '\{cs2exe\}') {
        $hw = Get-PckitHardwareProfile
        if (-not $hw.Cs2Exe) { return $null }
        $Text = $Text.Replace('{cs2exe}', [string]$hw.Cs2Exe)
    }
    return $Text
}

# действие не подходит этому железу (requires) — причина или $null
function Get-PckitActionNotFitReason {
    param($Action)
    if (-not $Action.requires) { return $null }
    $hw = Get-PckitHardwareProfile
    if (Test-PckitHwCondition -Cond $Action.requires -Hw $hw) { return $null }
    return (Get-PckitRequiresText -Cond $Action.requires -Hw $hw)
}

# ---------- проверка состояния ----------

function Test-PckitActionState {
    param($Action)

    $balancedGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'
    $checks = New-Object System.Collections.ArrayList
    $applied = 0
    $total = 0

    if ($Action.myth) {
        return [pscustomobject]@{ Status = 'myth'; Checks = @(); Applied = 0; Total = 0 }
    }
    if (-not (Test-PckitActionSupported -Action $Action)) {
        return [pscustomobject]@{ Status = 'unsupported'; Checks = @(); Applied = 0; Total = 0 }
    }
    $notFit = Get-PckitActionNotFitReason -Action $Action
    if ($notFit) {
        return [pscustomobject]@{ Status = 'notfit'; Checks = @([pscustomobject]@{ Ok = $false; Detail = $notFit }); Applied = 0; Total = 0 }
    }

    foreach ($v in @($Action.verify)) {
        if (-not $v) { continue }
        $total++
        $ok = $false
        $detail = ''

        switch ([string]$v.type) {
            { $_ -in 'nvidia', 'cs2cfg', 'cs2launch', 'workgpu' } {
                $r = switch ([string]$v.type) {
                    'workgpu'   { Test-PckitVerifyWorkGpu }
                    'nvidia'    { Test-PckitVerifyNvidia -Verify $v }
                    'cs2cfg'    { Test-PckitVerifyCs2Cfg -Verify $v }
                    'cs2launch' { Test-PckitVerifyCs2Launch -Verify $v }
                }
                if ($r.NotApplicable) {
                    return [pscustomobject]@{ Status = 'notfit'; Checks = @([pscustomobject]@{ Ok = $false; Detail = $r.Detail }); Applied = 0; Total = 0 }
                }
                $ok = [bool]$r.Ok; $detail = [string]$r.Detail
            }
            'reg' {
                $state = Get-PckitRegState -Path ([string]$v.path) -Name ([string]$v.name)
                if ($state.Exists) {
                    if ($v.value -is [array] -or $state.Value -is [array]) {
                        $ok = ((@($state.Value) -join ',') -eq (@($v.value) -join ','))
                        $detail = ('сейчас: {0}' -f (@($state.Value) -join ','))
                    } else {
                        $ok = ([string]$state.Value -eq [string]$v.value)
                        $detail = ('сейчас: {0}' -f $state.Value)
                    }
                } else {
                    $detail = 'значения нет'
                }
            }
            'regkv' {
                $vName = Expand-PckitActionText -Text ([string]$v.name)
                if ($null -eq $vName) {
                    return [pscustomobject]@{ Status = 'notfit'; Checks = @([pscustomobject]@{ Ok = $false; Detail = 'CS2 не найдена' }); Applied = 0; Total = 0 }
                }
                $state = Get-PckitRegState -Path ([string]$v.path) -Name $vName
                if ($state.Exists) {
                    $cur = Get-PckitKvValue -Text ([string]$state.Value) -Key ([string]$v.key)
                    if ($null -ne $cur) {
                        $ok = ([string]$cur -eq [string]$v.value)
                        $detail = ('{0} сейчас: {1}' -f $v.key, $cur)
                    } else { $detail = ('{0}: не задано' -f $v.key) }
                } else {
                    $detail = 'значения нет'
                }
            }
            'powerplan' {
                $active = Get-PckitActivePowerPlan
                if ($v.notBalanced) {
                    $ok = ($active -and $active -ne $balancedGuid)
                    $detail = ('схема: {0}' -f $active)
                }
            }
            'service' {
                $info = Get-PckitServiceInfo -Name ([string]$v.name)
                if (-not $info.Exists) {
                    $ok = $true; $detail = 'службы нет'
                } else {
                    $target = ConvertTo-PckitScMode -StartType ([string]$v.startType)
                    $ok = [bool]($target -and (Test-PckitScModeEqual -Current $info.Mode -Target $target))
                    $detail = ('{0}: {1}' -f $v.name, $info.Mode)
                }
            }
            'task' {
                $t = Get-PckitTaskByPath -Path ([string]$v.path)
                if (-not $t) {
                    $ok = $true; $detail = 'задачи нет'
                } else {
                    $ok = ([string]$t.State -eq 'Disabled')
                    $detail = ('{0}: {1}' -f $t.TaskName, $t.State)
                }
            }
            'powercfg' {
                $scheme = Get-PckitActivePowerPlan
                $cur = Get-PckitPowerSetting -Scheme $scheme -Subgroup ([string]$v.subgroup) -Setting ([string]$v.setting)
                if ($cur) {
                    $ok = ([int64]$cur.Ac -eq [int64]$v.value)
                    $detail = ('от сети: {0}' -f $cur.Ac)
                } else {
                    $detail = 'настройки нет'
                }
            }
            'devreg' {
                $r = Test-PckitVerifyDevReg -Verify $v
                $ok = [bool]$r.Ok; $detail = [string]$r.Detail
            }
            'netpower' {
                $bad = @(Get-PckitNetPowerAdapters | Where-Object { $_.Allow -eq 'Enabled' })
                $ok = ($bad.Count -eq 0)
                if (-not $ok) { $detail = ('разрешено отключение: {0}' -f ((@($bad | ForEach-Object { $_.Name })) -join ', ')) }
            }
        }
        if ($ok) { $applied++ }
        [void]$checks.Add([pscustomobject]@{ Ok = $ok; Detail = $detail })
    }

    $status = 'notApplied'
    if ($total -gt 0 -and $applied -eq $total) { $status = 'applied' }
    elseif ($applied -gt 0) { $status = 'partial' }

    return [pscustomobject]@{
        Status = $status
        Checks = $checks.ToArray()
        Applied = $applied
        Total = $total
    }
}

function Get-PckitActionsState {
    param($Actions, [switch]$SkipProgress)

    $i = 0
    $result = New-Object System.Collections.ArrayList
    foreach ($action in $Actions) {
        $i++
        if (-not $SkipProgress) {
            Write-Progress -Activity 'Проверка настроек' -Status $action.title -PercentComplete (($i / @($Actions).Count) * 100)
        }
        $state = Test-PckitActionState -Action $action
        [void]$result.Add([pscustomobject]@{
                Action = $action
                Status = $state.Status
                Detail = ($state.Checks | ForEach-Object { $_.Detail } | Where-Object { $_ }) -join '; '
            })
    }
    if (-not $SkipProgress) { Write-Progress -Activity 'Проверка настроек' -Completed }
    return $result.ToArray()
}

# ---------- применение ----------

function Invoke-PckitStepService {
    param($Step, $Journal, [switch]$Run)

    $name = [string]$Step.name
    $target = ConvertTo-PckitScMode -StartType ([string]$Step.startType)
    if (-not $target) { return [pscustomobject]@{ Status = 'fail'; Message = ('неизвестный режим: {0}' -f $Step.startType); Failed = 1 } }

    $info = Get-PckitServiceInfo -Name $name
    if (-not $info.Exists) { return [pscustomobject]@{ Status = 'skip'; Message = ('службы {0} нет' -f $name); Failed = 0 } }
    if (Test-PckitScModeEqual -Current $info.Mode -Target $target) {
        return [pscustomobject]@{ Status = 'ok'; Message = 'уже так'; Failed = 0 }
    }
    if (-not $Run) {
        return [pscustomobject]@{ Status = 'dry'; Message = ('служба {0}: {1} -> {2}' -f $name, $info.Mode, $target); Failed = 0 }
    }

    try {
        & sc.exe config $name start= $target 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            return [pscustomobject]@{ Status = 'fail'; Message = ('sc код {0}' -f $LASTEXITCODE); Failed = 1 }
        }
        if ($Journal) {
            Add-PckitCommandTracked -Journal $Journal -Undo ('sc config "{0}" start= {1}' -f $name, $info.Mode) -Note ('служба {0}' -f $name)
        }
        if ($Step.stop -and $info.Running) {
            Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
            if ($Journal) {
                Add-PckitCommandTracked -Journal $Journal -Undo ('net start "{0}"' -f $name) -Note ('служба {0}: запустить' -f $name)
            }
        }
        return [pscustomobject]@{ Status = 'ok'; Message = ''; Failed = 0 }
    } catch {
        return [pscustomobject]@{ Status = 'fail'; Message = $_.Exception.Message; Failed = 1 }
    }
}

function Invoke-PckitStepTask {
    param($Step, $Journal, [switch]$Run)

    $path = [string]$Step.path
    $t = Get-PckitTaskByPath -Path $path
    if (-not $t) { return [pscustomobject]@{ Status = 'skip'; Message = 'задачи нет'; Failed = 0 } }
    if ([string]$t.State -eq 'Disabled') { return [pscustomobject]@{ Status = 'ok'; Message = 'уже так'; Failed = 0 } }
    if (-not $Run) { return [pscustomobject]@{ Status = 'dry'; Message = ('отключить задачу {0}' -f $path); Failed = 0 } }

    try {
        Disable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop | Out-Null
        if ($Journal) {
            Add-PckitCommandTracked -Journal $Journal -Undo ('schtasks /Change /TN "{0}" /ENABLE' -f $path) -Note ('задача {0}' -f $t.TaskName)
        }
        return [pscustomobject]@{ Status = 'ok'; Message = ''; Failed = 0 }
    } catch {
        return [pscustomobject]@{ Status = 'fail'; Message = $_.Exception.Message; Failed = 1 }
    }
}

function Invoke-PckitStepPowercfg {
    param($Step, $Journal, [switch]$Run)

    $sub = [string]$Step.subgroup
    $set = [string]$Step.setting
    $val = [int64]$Step.value
    $scheme = Get-PckitActivePowerPlan
    $prev = Get-PckitPowerSetting -Scheme $scheme -Subgroup $sub -Setting $set
    if (-not $prev) { return [pscustomobject]@{ Status = 'skip'; Message = 'настройки нет в этой системе'; Failed = 0 } }
    if ($prev.Ac -eq $val -and $prev.Dc -eq $val) { return [pscustomobject]@{ Status = 'ok'; Message = 'уже так'; Failed = 0 } }
    if (-not $Run) { return [pscustomobject]@{ Status = 'dry'; Message = ('powercfg {0} = {1} (от сети и от батареи)' -f $set, $val); Failed = 0 } }

    try {
        & powercfg /setacvalueindex $scheme $sub $set $val 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Status = 'fail'; Message = ('powercfg код {0}' -f $LASTEXITCODE); Failed = 1 } }
        & powercfg /setdcvalueindex $scheme $sub $set $val 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Status = 'fail'; Message = ('powercfg код {0}' -f $LASTEXITCODE); Failed = 1 } }
        & powercfg /setactive $scheme 2>&1 | Out-Null
        if ($Journal) {
            # scheme_current: применить значения, не переключая схему (иначе откат снова включал бы «максимальную»)
            $undo = 'powercfg /setacvalueindex {0} {1} {2} {3} && powercfg /setdcvalueindex {0} {1} {2} {4} && powercfg /setactive scheme_current' -f $scheme, $sub, $set, $prev.Ac, $prev.Dc
            Add-PckitCommandTracked -Journal $Journal -Undo $undo -Note 'настройка схемы питания'
        }
        return [pscustomobject]@{ Status = 'ok'; Message = ''; Failed = 0 }
    } catch {
        return [pscustomobject]@{ Status = 'fail'; Message = $_.Exception.Message; Failed = 1 }
    }
}

function Invoke-PckitStepHibernate {
    param($Step, $Journal, [switch]$Run)

    $was = Get-PckitHibernateEnabled
    if (-not $was) { return [pscustomobject]@{ Status = 'ok'; Message = 'уже так'; Failed = 0 } }
    if (-not $Run) { return [pscustomobject]@{ Status = 'dry'; Message = 'powercfg /hibernate off'; Failed = 0 } }

    try {
        & powercfg /hibernate off 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Status = 'fail'; Message = ('powercfg код {0}' -f $LASTEXITCODE); Failed = 1 } }
        if ($Journal) {
            Add-PckitCommandTracked -Journal $Journal -Undo 'powercfg /hibernate on' -Note 'гибернация'
        }
        return [pscustomobject]@{ Status = 'ok'; Message = ''; Failed = 0 }
    } catch {
        return [pscustomobject]@{ Status = 'fail'; Message = $_.Exception.Message; Failed = 1 }
    }
}

# devreg: одно значение реестра на всех подходящих устройствах этого ПК.
# target: display (ключ драйвера видеокарты, vendor), net (ключ драйвера физической сетевой карты),
#         tcpif (TCP-параметры интерфейса физической карты), pcidisplay (Enum\PCI видеокарты + sub).
# ndi: true — писать только если драйвер сетевой карты знает такой параметр (Ndi\Params\<name>).
function Get-PckitDevRegTargets {
    param($Step)

    $paths = New-Object System.Collections.ArrayList
    $physical = @()
    if ([string]$Step.target -in 'net', 'tcpif') {
        try { $physical = @(Get-NetAdapter -Physical -ErrorAction Stop) } catch { $physical = @() }
    }
    switch ([string]$Step.target) {
        'display' {
            $cls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
            foreach ($k in @(Get-ChildItem -LiteralPath $cls -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' })) {
                $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
                if (-not $p) { continue }
                if ($Step.vendor -and ([string]$p.ProviderName + ' ' + [string]$p.DriverDesc) -notmatch [regex]::Escape([string]$Step.vendor)) { continue }
                [void]$paths.Add(('{0}\{1}' -f $cls, $k.PSChildName))
            }
        }
        'net' {
            $cls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
            $guids = @($physical | ForEach-Object { ([string]$_.InterfaceGuid).ToLower() })
            foreach ($k in @(Get-ChildItem -LiteralPath $cls -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' })) {
                $id = [string](Get-ItemProperty -LiteralPath $k.PSPath -Name NetCfgInstanceId -ErrorAction SilentlyContinue).NetCfgInstanceId
                if (-not $id -or $guids -notcontains $id.ToLower()) { continue }
                $base = '{0}\{1}' -f $cls, $k.PSChildName
                if ($Step.ndi -and -not (Test-Path -LiteralPath ('{0}\Ndi\Params\{1}' -f $base, [string]$Step.name))) { continue }
                [void]$paths.Add($base)
            }
        }
        'tcpif' {
            foreach ($a in $physical) {
                $p = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{0}' -f ([string]$a.InterfaceGuid).ToLower()
                if (Test-Path -LiteralPath $p) { [void]$paths.Add($p) }
            }
        }
        'pcidisplay' {
            $devs = @()
            try { $devs = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop | Where-Object { $_.InstanceId -like 'PCI\*' }) } catch { $devs = @() }
            foreach ($d in $devs) {
                if ($Step.vendor -and ([string]$d.Manufacturer + ' ' + [string]$d.FriendlyName) -notmatch [regex]::Escape([string]$Step.vendor)) { continue }
                [void]$paths.Add(('HKLM:\SYSTEM\CurrentControlSet\Enum\{0}\Device Parameters' -f $d.InstanceId))
            }
        }
    }
    if ($Step.sub) {
        return @($paths | ForEach-Object { '{0}\{1}' -f $_, [string]$Step.sub })
    }
    return $paths.ToArray()
}

function Invoke-PckitStepDevReg {
    param($Step, $Journal, [switch]$Run)

    $targets = @(Get-PckitDevRegTargets -Step $Step)
    if ($targets.Count -eq 0) { return [pscustomobject]@{ Status = 'skip'; Message = 'нет подходящих устройств'; Failed = 0 } }
    $type = if ($Step.valueType) { [string]$Step.valueType } else { 'DWord' }
    $value = $Step.value
    if ($type -eq 'Binary') { $value = ConvertTo-PckitByteArray -Value $Step.value }
    if (-not $Run) {
        return [pscustomobject]@{ Status = 'dry'; Message = ('{0} = {1} ({2} шт.)' -f $Step.name, $Step.value, $targets.Count); Failed = 0 }
    }
    $failed = 0
    $msgs = New-Object System.Collections.ArrayList
    foreach ($p in $targets) {
        try { Add-PckitRegTracked -Journal $Journal -Path $p -Name ([string]$Step.name) -Value $value -Type $type }
        catch { $failed++; [void]$msgs.Add($_.Exception.Message) }
    }
    if ($failed -gt 0) { return [pscustomobject]@{ Status = 'fail'; Message = ($msgs -join '; '); Failed = $failed } }
    return [pscustomobject]@{ Status = 'ok'; Message = ''; Failed = 0 }
}

function Test-PckitVerifyDevReg {
    param($Verify)
    $targets = @(Get-PckitDevRegTargets -Step $Verify)
    if ($targets.Count -eq 0) { return [pscustomobject]@{ Ok = $true; Detail = 'нет подходящих устройств' } }
    $bad = 0
    foreach ($p in $targets) {
        $s = Get-PckitRegState -Path $p -Name ([string]$Verify.name)
        if (-not $s.Exists -or [string]$s.Value -ne [string]$Verify.value) { $bad++ }
    }
    return [pscustomobject]@{ Ok = ($bad -eq 0); Detail = ('{0}: {1} из {2} устройств' -f $Verify.name, ($targets.Count - $bad), $targets.Count) }
}

function Invoke-PckitStepNetPower {
    param($Step, $Journal, [switch]$Run)

    $todo = @(Get-PckitNetPowerAdapters | Where-Object { $_.Allow -eq 'Enabled' })
    if ($todo.Count -eq 0) { return [pscustomobject]@{ Status = 'ok'; Message = 'уже так'; Failed = 0 } }
    if (-not $Run) {
        return [pscustomobject]@{ Status = 'dry'; Message = ('не отключать для экономии: {0}' -f ((@($todo | ForEach-Object { $_.Name })) -join ', ')); Failed = 0 }
    }

    $failed = 0
    $msgs = New-Object System.Collections.ArrayList
    foreach ($a in $todo) {
        try {
            Set-NetAdapterPowerManagement -Name $a.Name -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop
            if ($Journal) {
                $cmd = "Set-NetAdapterPowerManagement -Name '{0}' -AllowComputerToTurnOffDevice Enabled" -f $a.Name.Replace("'", "''")
                $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
                Add-PckitCommandTracked -Journal $Journal -Undo ('powershell -NoProfile -NonInteractive -EncodedCommand {0}' -f $b64) -Note ('сетевая карта {0}' -f $a.Name)
            }
        } catch {
            $failed++; [void]$msgs.Add(('{0}: {1}' -f $a.Name, $_.Exception.Message))
        }
    }
    if ($failed -gt 0) { return [pscustomobject]@{ Status = 'fail'; Message = ($msgs -join '; '); Failed = $failed } }
    return [pscustomobject]@{ Status = 'ok'; Message = ''; Failed = 0 }
}

function Invoke-PckitAction {
    param(
        $Action,
        $Journal,
        [switch]$Run
    )

    $results = New-Object System.Collections.ArrayList
    $failed = 0

    $gate = $null
    if ($Action.myth) {
        $gate = 'информационная карточка: применить нельзя'
    } elseif (-not (Test-PckitActionSupported -Action $Action)) {
        $gate = 'не для этой версии Windows'
    } else {
        $nf = Get-PckitActionNotFitReason -Action $Action
        if ($nf) { $gate = ('не подходит этому ПК: {0}' -f $nf) }
    }
    if ($gate) {
        [void]$results.Add([pscustomobject]@{ Step = [pscustomobject]@{ type = 'skip' }; Status = 'skip'; Message = $gate })
        return [pscustomobject]@{ Action = $Action; Results = $results.ToArray(); Failed = 0; Run = [bool]$Run }
    }

    foreach ($step in @($Action.steps)) {
        if (-not $step) { continue }
        $status = 'dry'
        $msg = ''

        switch ([string]$step.type) {
            'reg' {
                $path = [string]$step.path
                $name = [string]$step.name
                $value = $step.value
                $type = if ($step.valueType) { [string]$step.valueType } else { 'DWord' }
                if ($type -eq 'Binary') { $value = ConvertTo-PckitByteArray -Value $step.value }
                if ($Run) {
                    try {
                        Add-PckitRegTracked -Journal $Journal -Path $path -Name $name -Value $value -Type $type
                        $status = 'ok'
                    } catch {
                        $status = 'fail'; $failed++; $msg = $_.Exception.Message
                    }
                } else {
                    $msg = ('{0} = {1}' -f $name, (@($value) -join ','))
                }
            }
            { $_ -in 'nvidia', 'cs2cfg', 'cs2launch', 'workgpu' } {
                $r = switch ([string]$step.type) {
                    'workgpu'   { Invoke-PckitStepWorkGpu -Step $step -Journal $Journal -Run:$Run }
                    'nvidia'    { Invoke-PckitStepNvidia -Step $step -Journal $Journal -Run:$Run }
                    'cs2cfg'    { Invoke-PckitStepCs2Cfg -Step $step -Journal $Journal -Run:$Run }
                    'cs2launch' { Invoke-PckitStepCs2Launch -Step $step -Journal $Journal -Run:$Run }
                }
                $status = $r.Status; $msg = $r.Message; $failed += $r.Failed
            }
            'regkv' {
                $path = [string]$step.path
                $name = Expand-PckitActionText -Text ([string]$step.name)
                $key = [string]$step.key
                $kvValue = [string]$step.value
                $curText = ''
                if ($null -ne $name) {
                    $cur = Get-PckitRegState -Path $path -Name $name
                    if ($cur.Exists) { $curText = [string]$cur.Value }
                }
                $newText = Set-PckitKvValue -Text $curText -Key $key -Value $kvValue
                if ($null -eq $name) {
                    $status = 'skip'; $msg = 'CS2 не найдена'
                } elseif ($Run) {
                    try {
                        Add-PckitRegTracked -Journal $Journal -Path $path -Name $name -Value $newText -Type 'String'
                        $status = 'ok'
                    } catch {
                        $status = 'fail'; $failed++; $msg = $_.Exception.Message
                    }
                } else {
                    $msg = ('{0}: {1}={2}' -f $name, $key, $kvValue)
                }
            }
            'service' {
                $r = Invoke-PckitStepService -Step $step -Journal $Journal -Run:$Run
                $status = $r.Status; $msg = $r.Message; $failed += $r.Failed
            }
            'task' {
                $r = Invoke-PckitStepTask -Step $step -Journal $Journal -Run:$Run
                $status = $r.Status; $msg = $r.Message; $failed += $r.Failed
            }
            'powercfg' {
                $r = Invoke-PckitStepPowercfg -Step $step -Journal $Journal -Run:$Run
                $status = $r.Status; $msg = $r.Message; $failed += $r.Failed
            }
            'hibernate' {
                $r = Invoke-PckitStepHibernate -Step $step -Journal $Journal -Run:$Run
                $status = $r.Status; $msg = $r.Message; $failed += $r.Failed
            }
            'devreg' {
                $r = Invoke-PckitStepDevReg -Step $step -Journal $Journal -Run:$Run
                $status = $r.Status; $msg = $r.Message; $failed += $r.Failed
            }
            'netpower' {
                $r = Invoke-PckitStepNetPower -Step $step -Journal $Journal -Run:$Run
                $status = $r.Status; $msg = $r.Message; $failed += $r.Failed
            }
            'powerplan' {
                if ($Run) {
                    try {
                        $prev = Get-PckitActivePowerPlan
                        $ultimate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
                        $high = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
                        & powercfg /setactive $ultimate 2>$null | Out-Null
                        if ($LASTEXITCODE -ne 0) { & powercfg /setactive $high 2>$null | Out-Null }

                        if ($LASTEXITCODE -eq 0) {
                            # схема уже была нужной — откатывать нечего
                            if ($Journal -and $prev -and $prev -ne (Get-PckitActivePowerPlan)) {
                                Add-PckitCommandTracked -Journal $Journal -Undo ('powercfg /setactive {0}' -f $prev) -Note 'схема электропитания'
                            }
                            $status = 'ok'
                        } else {
                            $status = 'fail'; $failed++; $msg = ('powercfg код {0}' -f $LASTEXITCODE)
                        }
                    } catch {
                        $status = 'fail'; $failed++; $msg = $_.Exception.Message
                    }
                } else {
                    $msg = 'powercfg /setactive <максимальная производительность>'
                }
            }
            default {
                $status = 'skip'; $msg = ('неизвестный шаг: {0}' -f $step.type)
            }
        }
        [void]$results.Add([pscustomobject]@{ Step = $step; Status = $status; Message = $msg })
    }

    return [pscustomobject]@{
        Action  = $Action
        Results = $results.ToArray()
        Failed  = $failed
        Run     = [bool]$Run
    }
}

# действия со схемой питания идут первыми, иначе powercfg-шаги лягут на старую схему
function Sort-PckitActionsPowerFirst {
    param([object[]]$Actions)

    $first = New-Object System.Collections.ArrayList
    $rest = New-Object System.Collections.ArrayList
    foreach ($a in @($Actions)) {
        $hasPlan = $false
        foreach ($s in @($a.steps)) { if ($s -and [string]$s.type -eq 'powerplan') { $hasPlan = $true; break } }
        if ($hasPlan) { [void]$first.Add($a) } else { [void]$rest.Add($a) }
    }
    return , @(@($first.ToArray()) + @($rest.ToArray()))
}

function Invoke-PckitActions {
    param(
        [object[]]$Actions,
        [switch]$Run
    )

    $journal = Read-PckitJournal
    $results = New-Object System.Collections.ArrayList
    $i = 0
    # граница партии: всё, что запишется в журнал с этого момента, можно откатить отдельно
    $since = (Get-Date).ToString('s')
    $script:PckitBatchSince = $since
    $countBefore = Get-PckitJournalCount -Journal $journal
    $ordered = Sort-PckitActionsPowerFirst -Actions $Actions
    $total = @($ordered).Count

    foreach ($action in $ordered) {
        $i++
        Write-Progress -Activity 'Применение настроек' -Status $action.title -PercentComplete (($i / $total) * 100)
        $before = @{}
        foreach ($k in $script:PckitJournalKinds) { $before[$k] = @($journal.$k).Count }
        $r = Invoke-PckitAction -Action $action -Journal $journal -Run:$Run
        [void]$results.Add($r)
        # метка действия на новых записях журнала: по ней переключатель в UI откатывает одно действие
        foreach ($k in $script:PckitJournalKinds) {
            $list = @($journal.$k)
            for ($j = $before[$k]; $j -lt $list.Count; $j++) {
                if ($list[$j]) { $list[$j] | Add-Member -NotePropertyName act -NotePropertyValue ([string]$action.id) -Force }
            }
        }
    }
    Write-Progress -Activity 'Применение настроек' -Completed
    $script:PckitBatchSince = $null

    $journalPath = $null
    if ($Run -and -not (Test-PckitJournalEmpty -Journal $journal)) {
        $journalPath = Save-PckitJournal -Journal $journal
        # партию запоминаем, только если она что-то записала — иначе «откатить последнее» указывало бы в пустоту
        if ((Get-PckitJournalCount -Journal $journal) -gt $countBefore) {
            try { Save-PckitLastBatch -Since $since -Ids @($ordered | ForEach-Object { [string]$_.id }) } catch { }
        }
    }

    $failed = 0
    foreach ($r in $results) { $failed += $r.Failed }

    return [pscustomobject]@{
        Results     = $results.ToArray()
        Failed      = $failed
        JournalPath = $journalPath
        Run         = [bool]$Run
    }
}

function Get-PckitActionSummary {
    param($Action)

    $steps = 0
    foreach ($s in @($Action.steps)) { if ($s) { $steps++ } }
    return [pscustomobject]@{
        Id      = [string]$Action.id
        Title   = [string]$Action.title
        Group   = [string]$Action.group
        What    = [string]$Action.what
        Effect  = [string]$Action.effect
        Level   = [string]$Action.effectLevel
        Risk    = [string]$Action.risk
        Steps   = $steps
        Expert  = [bool]$Action.expert
        Myth    = [bool]$Action.myth
        MinBuild = if ($Action.minBuild) { [int]$Action.minBuild } else { 0 }
        Note    = [string]$Action.note
    }
}

# умный подбор, железо, CS2 (используются шагами и проверками выше)
. (Join-Path $PSScriptRoot 'Hardware.ps1')
. (Join-Path $PSScriptRoot 'Cs2.ps1')
. (Join-Path $PSScriptRoot 'Smart.ps1')
. (Join-Path $PSScriptRoot 'Driver.ps1')
. (Join-Path $PSScriptRoot 'Work.ps1')
