#Requires -Version 5.1
# pckit engine | verifier: did the restore actually work, and what is left to do by hand

function Test-PckitRestore {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$ProfileRoot
    )

    $checks = New-Object System.Collections.Generic.List[object]
    $current = Get-PckitCurrentAppIndex

    foreach ($item in $Manifest.items) {
        switch ([string]$item.kind) {
            'app' {
                $wingetId = [string]$item.meta.wingetId
                if (-not $wingetId) {
                    $checks.Add([pscustomobject]@{ Title = $item.title; Status = 'manual'; Detail = 'нет пакета winget' })
                    continue
                }
                $status = if ($current.ByWinget.ContainsKey($wingetId.ToLower())) { 'ok' } else { 'missing' }
                $checks.Add([pscustomobject]@{ Title = $item.title; Status = $status; Detail = $wingetId })
            }
            'appdata' {
                foreach ($step in @($item.meta.steps)) {
                    if (-not $step.payload -or $step.type -eq 'command') { continue }
                    if ($step.type -in 'dir', 'file') {
                        $target = Resolve-PckitPath ([string]$step.target)
                        $status = if (Test-Path -LiteralPath $target) { 'ok' } else { 'missing' }
                        $checks.Add([pscustomobject]@{ Title = ($item.title + ' — ' + (Split-Path -Leaf $target)); Status = $status; Detail = $target })
                    }
                }
            }
            'files' {
                $target = Resolve-PckitPath ([string]$item.meta.target)
                $status = if (Test-Path -LiteralPath $target) { 'ok' } else { 'missing' }
                if ([string]$item.meta.mode -eq 'reference' -and $status -eq 'missing') { $status = 'manual' }
                $checks.Add([pscustomobject]@{ Title = $item.title; Status = $status; Detail = $target })
            }
            'os' {
                switch ([string]$item.id) {
                    'os.timezone' {
                        $now = (Get-TimeZone).Id
                        $status = if ($now -ieq [string]$item.meta.id) { 'ok' } else { 'diff' }
                        $checks.Add([pscustomobject]@{ Title = $item.title; Status = $status; Detail = ('сейчас: ' + $now) })
                    }
                    'os.languages' {
                        $now = @(Get-WinUserLanguageList -ErrorAction SilentlyContinue | ForEach-Object { $_.LanguageTag })
                        $want = @($item.meta.list)
                        $status = if (($want | Where-Object { $now -notcontains $_ }).Count -eq 0) { 'ok' } else { 'diff' }
                        $checks.Add([pscustomobject]@{ Title = $item.title; Status = $status; Detail = ($now -join ', ') })
                    }
                    'os.hosts' {
                        $checks.Add([pscustomobject]@{ Title = $item.title; Status = 'manual'; Detail = 'проверьте вручную' })
                    }
                    default {
                        $checks.Add([pscustomobject]@{ Title = $item.title; Status = 'manual'; Detail = 'вручную' })
                    }
                }
            }
            'network' {
                if ([string]$item.id -eq 'os.wifi') {
                    $now = @()
                    try {
                        $now = @(& netsh wlan show profiles 2>$null | ForEach-Object { if ($_ -match ':\s*(.+)$') { $matches[1].Trim() } } | Where-Object { $_ })
                    } catch { }
                    $want = @($item.meta.profiles)
                    $missing = @($want | Where-Object { $now -notcontains $_ })
                    $status = if ($missing.Count -eq 0) { 'ok' } else { 'diff' }
                    $detail = if ($missing.Count) { ('не хватает: ' + ($missing -join ', ')) } else { ('профилей: {0}' -f $now.Count) }
                    $checks.Add([pscustomobject]@{ Title = $item.title; Status = $status; Detail = $detail })
                } else {
                    $checks.Add([pscustomobject]@{ Title = $item.title; Status = 'manual'; Detail = 'вручную' })
                }
            }
            'dev' {
                if ([string]$item.meta.type -eq 'env') {
                    $vars = $item.meta.vars
                    $missing = 0
                    foreach ($p in $vars.PSObject.Properties) {
                        if (-not [Environment]::GetEnvironmentVariable($p.Name, 'User')) { $missing++ }
                    }
                    $status = if ($missing -eq 0) { 'ok' } else { 'diff' }
                    $checks.Add([pscustomobject]@{ Title = $item.title; Status = $status; Detail = ('не задано: {0}' -f $missing) })
                } else {
                    $checks.Add([pscustomobject]@{ Title = $item.title; Status = 'manual'; Detail = 'проверьте вручную' })
                }
            }
            default {
                $checks.Add([pscustomobject]@{ Title = $item.title; Status = 'manual'; Detail = 'вручную' })
            }
        }
    }

    return [pscustomobject]@{
        Checks = $checks.ToArray()
        Manual = @($Manifest.manual | Where-Object { $_ })
    }
}

function Show-PckitVerify {
    param($Verify)

    $groups = $Verify.Checks | Group-Object Status
    Write-PckitLog -Level step -Message 'Проверка результата'
    foreach ($g in ($groups | Sort-Object Name)) {
        $color = switch ($g.Name) { 'ok' { 'Green' } 'missing' { 'Red' } 'diff' { 'Yellow' } default { 'Gray' } }
        Write-Host ('  {0,-8} {1}' -f $g.Name, $g.Count) -ForegroundColor $color
    }

    $bad = @($Verify.Checks | Where-Object { $_.Status -in 'missing', 'diff' })
    if ($bad.Count) {
        Write-Host ''
        foreach ($b in $bad) { Write-Host ('  [{0}] {1} — {2}' -f $b.Status, $b.Title, $b.Detail) -ForegroundColor Yellow }
    }

    if (@($Verify.Manual).Count) {
        Write-Host ''
        Write-PckitLog -Level warn -Message 'осталось руками:'
        foreach ($m in $Verify.Manual) {
            Write-Host ('  - {0}  ({1})' -f $m.title, $m.reason) -ForegroundColor Yellow
        }
    }
    Write-Host ''
}
