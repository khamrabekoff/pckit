#Requires -Version 5.1
# pckit engine | recipes: declarative "where an app keeps its data"

$script:PckitStepTypes = @('dir', 'file', 'registry', 'command', 'note', 'list')

function Get-PckitRecipes {
    param([string]$Directory)

    $result = New-Object System.Collections.Generic.List[object]
    if (-not $Directory -or -not (Test-Path -LiteralPath $Directory)) { return $result }

    foreach ($file in (Get-ChildItem -LiteralPath $Directory -Filter *.json -File -ErrorAction SilentlyContinue)) {
        $raw = $null
        try {
            $raw = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Write-PckitLog -Level warn -Message ('рецепт {0} не читается: {1}' -f $file.Name, $_.Exception.Message)
            continue
        }
        if (-not $raw.id -or -not $raw.steps) {
            Write-PckitLog -Level warn -Message ('рецепт {0}: нет id или steps — пропущен' -f $file.Name)
            continue
        }

        $recipe = [pscustomobject]@{
            Id                 = [string]$raw.id
            Title              = if ($raw.title) { [string]$raw.title } else { [string]$raw.id }
            Risk               = if ($raw.risk) { [string]$raw.risk } else { 'low' }
            DisplayNamePattern = if ($raw.match -and $raw.match.displayName) { [string]$raw.match.displayName } else { '' }
            WingetId           = if ($raw.match -and $raw.match.winget) { [string]$raw.match.winget } else { '' }
            Steps              = @($raw.steps)
            File               = $file.FullName
        }
        $problems = Test-PckitRecipe -Recipe $recipe
        if ($problems.Count) {
            foreach ($p in $problems) { Write-PckitLog -Level warn -Message ('рецепт {0}: {1}' -f $recipe.Id, $p) }
        }
        $result.Add($recipe)
    }
    return $result
}

function Test-PckitRecipe {
    param($Recipe)

    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($step in $Recipe.Steps) {
        $type = [string]$step.type
        if ($PckitStepTypes -notcontains $type) {
            $problems.Add(('неизвестный тип шага "{0}"' -f $type))
            continue
        }
        if ($type -in 'dir', 'file') {
            $check = Test-PckitSafePath -Path ([string]$step.path)
            if (-not $check.Safe) { $problems.Add(('шаг {0}: {1} ({2})' -f $type, $check.Reason, $step.path)) }
        }
        if ($type -eq 'registry' -and -not $step.key) {
            $problems.Add('шаг registry без key')
        }
    }
    return $problems
}

function Find-PckitRecipe {
    param(
        $Recipes,
        [string]$DisplayName,
        [string]$WingetId
    )

    foreach ($r in $Recipes) {
        if ($WingetId -and $r.WingetId -and $r.WingetId -ieq $WingetId) { return $r }
    }
    foreach ($r in $Recipes) {
        if (-not $r.DisplayNamePattern -or -not $DisplayName) { continue }
        try {
            if ($DisplayName -match $r.DisplayNamePattern) { return $r }
        } catch { }
    }
    return $null
}

function Get-PckitRecipeSize {
    param($Recipe)

    $mb = 0.0
    foreach ($step in $Recipe.Steps) {
        if ($step.type -eq 'dir') {
            $info = Get-PckitFolderInfo -Path ([string]$step.path) -Exclude @($step.exclude)
            $mb += $info.SizeMb
        }
        elseif ($step.type -eq 'file') {
            $p = Resolve-PckitPath ([string]$step.path)
            if (Test-Path -LiteralPath $p) {
                $mb += [math]::Round((Get-Item -LiteralPath $p).Length / 1MB, 2)
            }
        }
    }
    return [math]::Round($mb, 2)
}
