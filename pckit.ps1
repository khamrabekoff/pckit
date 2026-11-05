#Requires -Version 5.1
<#
    pckit (CLI) — выбрать, что сохранить с этого ПК, и вернуть это после переустановки Windows.

    Примеры:
        .\pckit.ps1 scan                       # что вообще есть на машине
        .\pckit.ps1 pack -Preset work          # собрать профиль profile.pckit
        .\pckit.ps1 plan -Profile .\profile.pckit
        .\pckit.ps1 apply -Profile .\profile.pckit          # dry-run
        .\pckit.ps1 apply -Profile .\profile.pckit -Run     # реально применить
        .\pckit.ps1 verify -Profile .\profile.pckit
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('scan', 'pack', 'plan', 'apply', 'verify', 'undo', 'health', 'snapshot', 'compare', 'help')]
    [string]$Command = 'help',

    [string]$Profile,
    [string]$Out,
    [string]$Name = 'profile',

    [ValidateSet('minimal', 'work', 'all')]
    [string]$Preset = 'work',

    [string[]]$Include = @(),
    [string[]]$Exclude = @(),

    [switch]$Run,
    [switch]$SkipSizes,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$script:PckitRoot = $PSScriptRoot
foreach ($file in @('Common', 'Recipes', 'Catalog', 'Packer', 'Planner', 'Journal', 'Actions', 'Health', 'Applier', 'Verifier', 'Snapshot')) {
    . (Join-Path $PSScriptRoot ('engine\{0}.ps1' -f $file))
}

# allow both "-Include a,b" and "-Include a -Include b" from cmd.exe and PowerShell
$Include = @($Include | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Exclude = @($Exclude | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

$RecipeDir = Join-Path $PSScriptRoot 'recipes'

function Select-PckitItems {
    param($Items, [string]$PresetName, [string[]]$IncludeIds, [string[]]$ExcludeIds)

    $selected = New-Object System.Collections.Generic.List[object]
    foreach ($i in $Items) {
        $take = $false
        switch ($PresetName) {
            'minimal' {
                $take = ($i.Kind -eq 'app' -and $i.Default) -or ($i.Kind -eq 'os' -and $i.Default)
            }
            'work' {
                $take = (($i.Kind -in 'app', 'appdata', 'files', 'os') -and $i.Default) -or
                        ($i.Id -in 'dev.gitconfig', 'dev.env')
            }
            'all' {
                $take = ($i.Kind -ne 'drivers') -and ($i.Exists -ne $false)
            }
        }
        if ($IncludeIds.Count) {
            foreach ($pat in $IncludeIds) {
                if ($i.Id -like $pat -or $i.Title -like $pat) { $take = $true }
            }
        }
        if ($ExcludeIds.Count) {
            foreach ($pat in $ExcludeIds) {
                if ($i.Id -like $pat -or $i.Title -like $pat) { $take = $false }
            }
        }
        if ($take) { $selected.Add($i) }
    }
    return $selected.ToArray()
}

function Show-PckitCatalogSummary {
    param($Catalog, $Selected)

    $groups = $Catalog.Items | Group-Object Kind
    Write-Host ''
    Write-PckitLog -Level step -Message ('Машина: {0} · {1} (build {2}) · {3}' -f $Catalog.Machine.Computer, $Catalog.Machine.Caption, $Catalog.Machine.Build, $Catalog.Machine.Timezone)
    Write-Host ''
    foreach ($g in ($groups | Sort-Object Name)) {
        $sizeMb = ($g.Group | Measure-Object -Property SizeMb -Sum).Sum
        $sizeText = if ($sizeMb -gt 0) { ' · ' + (Format-PckitSize $sizeMb) } else { '' }
        $picked = @($Selected | Where-Object { $_.Kind -eq $g.Name }).Count
        Write-Host ('  {0,-9} {1,4} шт  (выбрано {2,3}){3}' -f $g.Name, $g.Count, $picked, $sizeText) -ForegroundColor Gray
    }
    Write-Host ''

    $withData = @($Catalog.Items | Where-Object { $_.SizeMb -gt 0 } | Sort-Object SizeMb -Descending)
    if ($withData.Count) {
        Write-PckitLog -Level info -Message 'самое тяжёлое (первые 10):'
        foreach ($i in ($withData | Select-Object -First 10)) {
            Write-Host ('   {0,10}  {1}' -f (Format-PckitSize $i.SizeMb), $i.Title) -ForegroundColor DarkGray
        }
        Write-Host ''
    }
}

function Resolve-PckitProfilePath {
    param([string]$Path)
    if ($Path) { return (Resolve-Path -LiteralPath $Path).Path }
    $latest = Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.pckit -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { throw 'не указан -Profile, и рядом нет ни одного *.pckit' }
    return $latest.FullName
}

switch ($Command) {

    'help' {
        Write-Host ''
        Write-Host ('  pckit {0} — слепок ПК: что сохранить и как вернуть после переустановки Windows' -f $script:PckitVersion) -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  scan                        показать, что есть на машине (ничего не меняет)'
        Write-Host '  pack  -Preset work          собрать профиль (minimal | work | all)'
        Write-Host '        -Out .\my.pckit -Name "мой ПК"'
        Write-Host '        -Include "app:Google.*" -Exclude "files.downloads"'
        Write-Host '  plan    -Profile x.pckit    показать план восстановления (ничего не меняет)'
        Write-Host '  apply   -Profile x.pckit    dry-run плана'
        Write-Host '  apply   -Profile x.pckit -Run   применить (с бэкапами и логом)'
        Write-Host '  verify  -Profile x.pckit    проверить результат + список "осталось руками"'
        Write-Host '  undo                        показать, что можно отменить (журнал изменений)'
        Write-Host '  undo -Run                   отменить: вернуть файлы, реестр, настройки'
        Write-Host '  health                      проверить ПК и сохранить отчёт (ничего не меняет)'
        Write-Host '  snapshot -Name до           замерить ПК (место, автозагрузка, фон, загрузка, пинг) и сохранить'
        Write-Host '  compare                     сравнить последний замер «до» с новым замером «после» + HTML-отчёт'
        Write-Host ''
        Write-Host '  Профиль — zip-файл *.pckit: manifest.json + payload + checksums.' -ForegroundColor DarkGray
        Write-Host '  state\ — логи и бэкапы изменённых файлов.' -ForegroundColor DarkGray
        Write-Host ''
    }

    'scan' {
        $catalog = Get-PckitCatalog -RecipeDir $RecipeDir -SkipSizes:$SkipSizes
        Save-PckitJson -Path (Join-Path (Get-PckitStatePath) 'catalog.json') -Object $catalog
        $selected = Select-PckitItems -Items $catalog.Items -PresetName $Preset
        Show-PckitCatalogSummary -Catalog $catalog -Selected $selected
        Write-PckitLog -Level ok -Message ('объектов: {0}, рецептов: {1}, в пресете "{2}": {3}' -f $catalog.Items.Count, $catalog.Recipes.Count, $Preset, $selected.Count)
        Write-PckitLog -Level info -Message ('каталог сохранён: state\catalog.json')
    }

    'pack' {
        $catalog = Get-PckitCatalog -RecipeDir $RecipeDir -SkipSizes:$SkipSizes
        $selected = Select-PckitItems -Items $catalog.Items -PresetName $Preset -IncludeIds $Include -ExcludeIds $Exclude
        Show-PckitCatalogSummary -Catalog $catalog -Selected $selected

        $totalMb = ($selected | Measure-Object -Property SizeMb -Sum).Sum
        if ($totalMb -gt 0) {
            Write-PckitLog -Level info -Message ('к копированию примерно: {0}' -f (Format-PckitSize $totalMb))
        }
        if ($selected.Count -eq 0) { throw 'нечего сохранять: пустой выбор' }

        $result = New-PckitProfile -Catalog $catalog -Selection $selected -OutFile $Out -Name $Name
        Write-Host ''
        Write-PckitLog -Level ok -Message ('профиль: {0}' -f $result.Path)
        Write-PckitLog -Level info -Message ('  объектов: {0}, файлов в payload: {1}, размер: {2}' -f $result.Items, $result.Payload, (Format-PckitSize $result.SizeMb))
        Write-PckitLog -Level info -Message ('  руками после переустановки: {0}' -f $result.Manual)
        Write-PckitLog -Level warn -Message 'скопируйте этот файл на внешний диск — он вам понадобится на чистой системе'
    }

    'plan' {
        $path = Resolve-PckitProfilePath $Profile
        $p = Expand-PckitProfile -Path $path
        try {
            $plan = Get-PckitPlan -Manifest $p.Manifest
            Write-PckitLog -Level info -Message ('профиль: {0}  (создан {1})' -f (Split-Path -Leaf $path), $p.Manifest.created)
            Show-PckitPlan -Plan $plan
            $mb = ($plan | Measure-Object -Property SizeMb -Sum).Sum
            if ($mb -gt 0) { Write-PckitLog -Level info -Message ('к копированию: ' + (Format-PckitSize $mb)) }
        } finally {
            Close-PckitProfile $p
        }
    }

    'apply' {
        $path = Resolve-PckitProfilePath $Profile
        $p = Expand-PckitProfile -Path $path
        try {
            $plan = Get-PckitPlan -Manifest $p.Manifest
            Show-PckitPlan -Plan $plan
            $result = Invoke-PckitPlan -Plan $plan -ProfileRoot $p.Root -Run:$Run
            Show-PckitApplyResult -Result $result
        } finally {
            Close-PckitProfile $p
        }
    }

    'health' {
        $report = Get-PckitHealthReport -ActionsDir (Join-Path $PSScriptRoot 'data')

        Write-PckitLog -Level step -Message 'Компьютер'
        foreach ($name in 'Cpu', 'Ram', 'Gpu', 'Os', 'Disk', 'Uptime') {
            $value = $report.Machine.$name
            if ($value) { Write-Host ('  {0,-8} {1}' -f ($name + ':'), $value) -ForegroundColor Gray }
        }
        Write-Host ''

        foreach ($group in @(@('ПРОБЛЕМЫ', 'bad', 'Red'), @('ПРЕДУПРЕЖДЕНИЯ', 'warn', 'Yellow'),
                @('ЗАМЕТКИ', 'info', 'Cyan'), @('В ПОРЯДКЕ', 'ok', 'Green'))) {
            $items = @($report.Findings | Where-Object { $_.Severity -eq $group[1] })
            if (-not $items.Count) { continue }
            Write-Host ('  ' + $group[0]) -ForegroundColor $group[2]
            foreach ($f in $items) {
                Write-Host ('   - ' + $f.Title) -ForegroundColor $group[2]
                if ($f.Detail) { Write-Host ('       ' + $f.Detail) -ForegroundColor DarkGray }
                if ($f.Hint) { Write-Host ('       что делать: ' + $f.Hint) -ForegroundColor DarkGray }
            }
            Write-Host ''
        }

        $file = Save-PckitHealthReport -Report $report
        Write-PckitLog -Level ok -Message ('проблем: {0}, предупреждений: {1}, заметок: {2}, в порядке: {3}' -f $report.Bad, $report.Warn, $report.Info, $report.Ok)
        Write-PckitLog -Level info -Message ('отчёт сохранён: {0}' -f $file)
    }

    'undo' {
        $journal = Read-PckitJournal
        if (Test-PckitJournalEmpty -Journal $journal) {
            Write-PckitLog -Level warn -Message ('нечего отменять: журнал пуст ({0}\undo.json)' -f (Get-PckitStateRoot))
            break
        }

        $undoPlan = Get-PckitUndoPlan -Journal $journal
        Write-PckitLog -Level step -Message ('Журнал от {0}: {1} записей' -f $journal.created, @($undoPlan).Count)
        foreach ($u in $undoPlan) {
            Write-Host ('  [{0,-13}] {1}' -f $u.Kind, $u.Title) -ForegroundColor Gray
            if ($u.Detail) { Write-Host ('                  {0}' -f $u.Detail) -ForegroundColor DarkGray }
        }
        Write-Host ''

        $res = Restore-PckitJournal -Journal $journal -Run:$Run
        if ($Run) {
            Write-PckitLog -Level ok -Message ('отменено: {0}, ошибок: {1}' -f $res.Ok, $res.Failed)
            $failed = @($res.Items | Where-Object { $_.Status -eq 'fail' })
            foreach ($f in $failed) { Write-PckitLog -Level err -Message ('{0} — {1}' -f $f.Title, $f.Message) }
        } else {
            Write-PckitLog -Level info -Message 'это был пробный прогон: ничего не изменено. Для отката добавьте -Run'
        }
    }

    'snapshot' {
        $label = if ($PSBoundParameters.ContainsKey('Name')) { $Name } else { 'до' }
        Write-PckitLog -Level step -Message ('Замер «{0}» — около 20 секунд, не трогайте компьютер' -f $label)
        $snap = Get-PckitSnapshot -Label $label -Samples 8 -IntervalSeconds 2
        $file = Save-PckitSnapshot -Snapshot $snap
        Write-PckitLog -Level ok -Message ('сохранено: {0}' -f $file)
    }

    'compare' {
        $beforeInfo = @(Get-PckitSnapshots | Where-Object { $_.Label -eq 'до' }) | Select-Object -First 1
        if (-not $beforeInfo) { throw 'нет замера «до»: сначала .\pckit.ps1 snapshot -Name до' }
        Write-PckitLog -Level step -Message 'Замер «после» — около 20 секунд, не трогайте компьютер'
        $after = Get-PckitSnapshot -Label 'после' -Samples 8 -IntervalSeconds 2
        [void](Save-PckitSnapshot -Snapshot $after)
        $before = Read-PckitSnapshot -Path $beforeInfo.Path
        $rows = @(Compare-PckitSnapshot -Before $before -After $after)
        Write-Host ''
        foreach ($r in $rows) {
            $color = switch ([string]$r.Verdict) { 'лучше' { 'Green' } 'хуже' { 'Red' } 'нужна перезагрузка' { 'Yellow' } default { 'Gray' } }
            Write-Host ('  {0,-34} {1,14} → {2,-14} {3}' -f $r.Metric, $r.Before, $r.After, $r.Verdict) -ForegroundColor $color
        }
        Write-Host ''
        $file = Save-PckitCompareReport -Before $before -After $after -Rows $rows
        Write-PckitLog -Level info -Message ('отчёт: {0}' -f $file)
    }

    'verify' {
        $path = Resolve-PckitProfilePath $Profile
        $p = Expand-PckitProfile -Path $path
        try {
            $v = Test-PckitRestore -Manifest $p.Manifest -ProfileRoot $p.Root
            Show-PckitVerify -Verify $v
        } finally {
            Close-PckitProfile $p
        }
    }
}
