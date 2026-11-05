#Requires -Version 5.1
# pckit engine | planner: turn a manifest into an executable plan (dry-run friendly)

function Get-PckitCurrentAppIndex {
    $index = @{ ByName = @{}; ByWinget = @{} }
    try {
        $rows = @(Get-PckitWingetRows)
        foreach ($r in $rows) {
            if (-not $r.Id) { continue }
            if ($r.Id -match '^(ARP|MSIX)\\') { continue }
            $index.ByWinget[$r.Id.ToLower()] = $true
        }
    } catch { }
    try {
        foreach ($a in (Get-PckitRegistryApps)) {
            $n = Get-PckitNormalizedName $a.Name
            if ($n) { $index.ByName[$n] = $true }
        }
    } catch { }
    return $index
}

function Get-PckitPlanStep {
    param(
        [string]$Action,
        [string]$ItemId,
        [string]$Title,
        [string]$Detail,
        [string]$Risk = 'low',
        [double]$SizeMb = 0,
        $Meta = $null
    )
    return [pscustomobject]@{
        Action = $Action
        ItemId = $ItemId
        Title  = $Title
        Detail = $Detail
        Risk   = $Risk
        SizeMb = $SizeMb
        Meta   = $Meta
    }
}

# Файл профиля может быть чужим: куда писать, берём не из него, а из своих рецептов и известных папок.
# Рецепт -> разрешённые цели шагов (path для dir/file, key для registry), как они записаны в recipes\*.json
function Get-PckitRecipeTargets {
    param([string]$RecipeDir)
    if (-not $RecipeDir) { $RecipeDir = Join-Path (Split-Path -Parent $script:PckitEngineDir) 'recipes' }
    $map = @{}
    foreach ($r in @(Get-PckitRecipes -Directory $RecipeDir)) {
        $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($st in @($r.Steps)) {
            if ([string]$st.type -in 'dir', 'file' -and $st.path) { [void]$set.Add(([string]$st.path).TrimEnd('\')) }
            if ([string]$st.type -eq 'registry' -and $st.key) { [void]$set.Add((ConvertTo-PckitRegHiveName ([string]$st.key))) }
            if ([string]$st.type -eq 'command' -and $st.restoreTemplate) { [void]$set.Add([string]$st.restoreTemplate) }
        }
        $map[[string]$r.Id] = $set
    }
    return $map
}

function Test-PckitRecipeTarget {
    param($Targets, [string]$RecipeId, [string]$Type, [string]$Target)
    if (-not $RecipeId -or -not $Targets.ContainsKey($RecipeId)) { return $false }
    $t = if ($Type -eq 'registry') { ConvertTo-PckitRegHiveName $Target } else { $Target.TrimEnd('\') }
    return $Targets[$RecipeId].Contains($t)
}

function Get-PckitPlan {
    param(
        [Parameter(Mandatory)]$Manifest,
        $CurrentIndex = $null,
        [string]$RecipeDir
    )

    if (-not $CurrentIndex) { $CurrentIndex = Get-PckitCurrentAppIndex }
    $recipeTargets = Get-PckitRecipeTargets -RecipeDir $RecipeDir
    $fileDefs = @{}
    foreach ($d in @(Get-PckitFileDefs)) { $fileDefs[[string]$d.Id] = $d }

    $steps = New-Object System.Collections.Generic.List[object]
    # apps listed in manifest.manual are reported once at the end, not twice
    $manualTitles = @(@($Manifest.manual) | ForEach-Object { [string]$_.title })

    foreach ($item in $Manifest.items) {
        switch ([string]$item.kind) {
            'app' {
                $wingetId = [string]$item.meta.wingetId
                if (-not $wingetId) {
                    if ($manualTitles -contains [string]$item.title) { continue }
                    $steps.Add((Get-PckitPlanStep -Action 'manual' -ItemId $item.id -Title $item.title -Risk $item.risk `
                                -Detail 'нет пакета winget: нужен установщик вручную' -Meta $item.meta))
                    continue
                }
                if ($CurrentIndex.ByWinget.ContainsKey($wingetId.ToLower())) {
                    $steps.Add((Get-PckitPlanStep -Action 'skip' -ItemId $item.id -Title $item.title -Risk $item.risk `
                                -Detail 'уже установлено'))
                    continue
                }
                $steps.Add((Get-PckitPlanStep -Action 'install' -ItemId $item.id -Title $item.title -Risk $item.risk `
                            -Detail ('winget install --id {0}' -f $wingetId) -Meta $item.meta))
            }
            'appdata' {
                foreach ($step in @($item.meta.steps)) {
                    if ($step.payload -and ([string]$step.type -in 'dir', 'file', 'registry' -or ([string]$step.type -eq 'command' -and $step.target)) -and
                        -not (Test-PckitRecipeTarget -Targets $recipeTargets -RecipeId ([string]$item.meta.recipe) -Type ([string]$step.type) -Target ([string]$step.target))) {
                        $steps.Add((Get-PckitPlanStep -Action 'note' -ItemId $item.id -Title $item.title -Risk 'high' `
                                    -Detail ('отклонено: «{0}» не совпадает с рецептом pckit — так бывает у чужого или изменённого профиля' -f $step.target)))
                        continue
                    }
                    if (-not $step.payload) {
                        $steps.Add((Get-PckitPlanStep -Action 'note' -ItemId $item.id -Title $item.title -Risk $item.risk `
                                    -Detail ('шаг {0}: не захвачен' -f $step.type)))
                        continue
                    }
                    switch ([string]$step.type) {
                        'dir' {
                            $target = Resolve-PckitPath ([string]$step.target)
                            $exists = Test-Path -LiteralPath $target
                            $steps.Add((Get-PckitPlanStep -Action 'copy' -ItemId $item.id -Title ($item.title + ' — ' + (Split-Path -Leaf $target)) `
                                        -Risk $item.risk -SizeMb $item.sizeMb `
                                        -Detail (('{0} -> {1}' -f $step.payload, $target) + $(if ($exists) { ' (перезапись, с бэкапом)' } else { '' })) `
                                        -Meta ([pscustomobject]@{ Payload = $step.payload; Target = $target; Exclude = @($step.exclude) })))
                        }
                        'file' {
                            $target = Resolve-PckitPath ([string]$step.target)
                            $steps.Add((Get-PckitPlanStep -Action 'copyfile' -ItemId $item.id -Title ($item.title + ' — ' + (Split-Path -Leaf $target)) `
                                        -Risk $item.risk -SizeMb $item.sizeMb -Detail ('{0} -> {1}' -f $step.payload, $target) `
                                        -Meta ([pscustomobject]@{ Payload = $step.payload; Target = $target })))
                        }
                        'registry' {
                            $steps.Add((Get-PckitPlanStep -Action 'regimport' -ItemId $item.id -Title ($item.title + ' — реестр') `
                                        -Risk $item.risk -Detail ('{0} -> {1}' -f $step.target, $step.payload) `
                                        -Meta ([pscustomobject]@{ Payload = $step.payload; Key = $step.target })))
                        }
                        'command' {
                            if ($step.target) {
                                $steps.Add((Get-PckitPlanStep -Action 'command' -ItemId $item.id -Title ($item.title + ' — команды') `
                                            -Risk $item.risk -Detail ('выполнить: ' + $step.target) `
                                            -Meta ([pscustomobject]@{ Payload = $step.payload; Template = $step.target })))
                            } else {
                                $steps.Add((Get-PckitPlanStep -Action 'note' -ItemId $item.id -Title ($item.title + ' — список') `
                                            -Risk $item.risk -Detail ('сохранён список: ' + $step.payload) `
                                            -Meta ([pscustomobject]@{ Payload = $step.payload })))
                            }
                        }
                        default {
                            $steps.Add((Get-PckitPlanStep -Action 'note' -ItemId $item.id -Title $item.title -Risk $item.risk -Detail 'ручной шаг'))
                        }
                    }
                }
            }
            'files' {
                $def = $fileDefs[[string]$item.id]
                if (-not $def -or [string]$def.Path -ine [string]$item.meta.target) {
                    $steps.Add((Get-PckitPlanStep -Action 'note' -ItemId $item.id -Title $item.title -Risk 'high' `
                                -Detail ('отклонено: неизвестная папка «{0}» — так бывает у чужого или изменённого профиля' -f $item.meta.target)))
                    continue
                }
                $target = Resolve-PckitPath ([string]$def.Path)
                if ([string]$item.meta.mode -eq 'reference' -or -not $item.payload) {
                    $steps.Add((Get-PckitPlanStep -Action 'checkexists' -ItemId $item.id -Title $item.title -Risk $item.risk `
                                -Detail ('проверить наличие: ' + $target) -Meta ([pscustomobject]@{ Target = $target })))
                } else {
                    $exists = Test-Path -LiteralPath $target
                    $steps.Add((Get-PckitPlanStep -Action 'copy' -ItemId $item.id -Title $item.title -Risk $item.risk -SizeMb $item.sizeMb `
                                -Detail (('{0} -> {1}' -f $item.payload, $target) + $(if ($exists) { ' (добавит файлы к существующим)' } else { '' })) `
                                -Meta ([pscustomobject]@{ Payload = $item.payload; Target = $target; Merge = $true })))
                }
            }
            'os' {
                switch ([string]$item.id) {
                    'os.timezone' {
                        $steps.Add((Get-PckitPlanStep -Action 'timezone' -ItemId $item.id -Title $item.title -Risk $item.risk `
                                    -Detail ('Set-TimeZone -Id ' + $item.meta.id) -Meta $item.meta))
                    }
                    'os.languages' {
                        $steps.Add((Get-PckitPlanStep -Action 'languages' -ItemId $item.id -Title $item.title -Risk $item.risk `
                                    -Detail (($item.meta.list) -join ', ') -Meta $item.meta))
                    }
                    'os.powerplan' {
                        $steps.Add((Get-PckitPlanStep -Action 'powerplan' -ItemId $item.id -Title $item.title -Risk $item.risk `
                                    -Detail ('powercfg /setactive ' + $item.meta.guid) -Meta $item.meta))
                    }
                    'os.hosts' {
                        if ($item.payload) {
                            $steps.Add((Get-PckitPlanStep -Action 'hosts' -ItemId $item.id -Title $item.title -Risk $item.risk `
                                        -Detail 'заменить hosts (с бэкапом)' -Meta ([pscustomobject]@{ Payload = $item.payload })))
                        }
                    }
                    default {
                        $steps.Add((Get-PckitPlanStep -Action 'note' -ItemId $item.id -Title $item.title -Risk $item.risk -Detail 'переносится вручную'))
                    }
                }
            }
            'network' {
                if ([string]$item.id -eq 'os.wifi' -and $item.payload) {
                    $steps.Add((Get-PckitPlanStep -Action 'wifi' -ItemId $item.id -Title $item.title -Risk $item.risk `
                                -Detail ('импорт профилей из ' + $item.payload) -Meta ([pscustomobject]@{ Payload = $item.payload; passwordsIncluded = $item.meta.passwordsIncluded })))
                } else {
                    $steps.Add((Get-PckitPlanStep -Action 'note' -ItemId $item.id -Title $item.title -Risk $item.risk -Detail 'переносится вручную'))
                }
            }
            'dev' {
                $type = [string]$item.meta.type
                if ($type -eq 'file' -and $item.payload -and $item.id -eq 'dev.gitconfig') {
                    $target = Join-Path $env:USERPROFILE '.gitconfig'
                    $steps.Add((Get-PckitPlanStep -Action 'copyfile' -ItemId $item.id -Title $item.title -Risk $item.risk `
                                -Detail ('{0} -> {1}' -f $item.payload, $target) -Meta ([pscustomobject]@{ Payload = $item.payload; Target = $target })))
                }
                elseif ($type -eq 'env') {
                    $steps.Add((Get-PckitPlanStep -Action 'env' -ItemId $item.id -Title $item.title -Risk $item.risk `
                                -Detail ('{0} переменных' -f $item.meta.vars.PSObject.Properties.Count) -Meta $item.meta))
                }
                elseif ($type -eq 'command' -and $item.meta.restoreTemplate -and $item.payload) {
                    $steps.Add((Get-PckitPlanStep -Action 'command' -ItemId $item.id -Title $item.title -Risk $item.risk `
                                -Detail ('выполнить: ' + $item.meta.restoreTemplate) `
                                -Meta ([pscustomobject]@{ Payload = $item.payload; Template = $item.meta.restoreTemplate })))
                }
                else {
                    $steps.Add((Get-PckitPlanStep -Action 'note' -ItemId $item.id -Title $item.title -Risk $item.risk -Detail ('список: ' + $item.payload)))
                }
            }
            'drivers' {
                $steps.Add((Get-PckitPlanStep -Action 'drivers' -ItemId $item.id -Title $item.title -Risk $item.risk `
                            -Detail 'pnputil /add-driver (нужен администратор)' -Meta ([pscustomobject]@{ Payload = $item.payload })))
            }
            default {
                $steps.Add((Get-PckitPlanStep -Action 'note' -ItemId $item.id -Title $item.title -Risk $item.risk -Detail 'неизвестный тип'))
            }
        }
    }

    foreach ($m in @($Manifest.manual)) {
        if (-not $m) { continue }
        $steps.Add((Get-PckitPlanStep -Action 'manual' -ItemId ('manual:' + $m.title) -Title $m.title -Risk 'medium' `
                    -Detail ([string]$m.reason) -Meta $m))
    }

    # order: installs first, then data, then settings
    $order = @{ 'install' = 0; 'manual' = 1; 'copy' = 2; 'copyfile' = 2; 'regimport' = 3; 'wifi' = 3; 'hosts' = 3; 'drivers' = 3;
        'command' = 4; 'env' = 4; 'timezone' = 5; 'languages' = 5; 'powerplan' = 5; 'checkexists' = 6; 'note' = 7; 'skip' = 8
    }
    return @($steps | Sort-Object -Property @{ Expression = { $order[[string]$_.Action] } }, ItemId)
}

function Show-PckitPlan {
    param([object[]]$Plan)

    $byAction = $Plan | Group-Object Action
    Write-Host ''
    Write-PckitLog -Level step -Message 'План восстановления'
    foreach ($g in $byAction) {
        $totalMb = ($g.Group | Measure-Object -Property SizeMb -Sum).Sum
        $sizeText = if ($totalMb -gt 0) { ' · ' + (Format-PckitSize $totalMb) } else { '' }
        Write-Host ('  {0,-12} {1,3}{2}' -f ($g.Name + ':'), $g.Count, $sizeText) -ForegroundColor Gray
    }
    Write-Host ''
    foreach ($step in $Plan) {
        if ($step.Action -eq 'skip') { continue }
        $color = switch ($step.Risk) { 'high' { 'Red' } 'medium' { 'Yellow' } default { 'White' } }
        Write-Host ('  [{0,-10}] {1}' -f $step.Action, $step.Title) -ForegroundColor $color
        if ($step.Detail) { Write-Host ('               {0}' -f $step.Detail) -ForegroundColor DarkGray }
    }
    $skipped = @($Plan | Where-Object { $_.Action -eq 'skip' }).Count
    if ($skipped) { Write-Host ('  (пропущено как установленное: {0})' -f $skipped) -ForegroundColor DarkGray }
}
