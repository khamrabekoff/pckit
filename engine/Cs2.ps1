#Requires -Version 5.1
# pckit engine | cs2: autoexec.cfg и параметры запуска Steam. Только обычные консольные команды игры —
# никаких сторонних файлов в папке игры, ничего, что трогает античит (FACEIT/VAC).

$script:PckitCfgBegin = '// >>> pckit: начало (не редактируйте между этими строками — pckit перезапишет)'
$script:PckitCfgEnd = '// <<< pckit: конец'

function Get-PckitCs2CfgDir {
    $cs2 = Find-PckitCs2
    if (-not $cs2) { return $null }
    $dir = Join-Path $cs2 'game\csgo\cfg'
    if (Test-Path -LiteralPath $dir) { return $dir }
    return $null
}

function Get-PckitBackupDir {
    $dir = Join-Path (Get-PckitStateRoot) 'backup'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return $dir
}

function New-PckitFileBackup {
    param([string]$Path)
    $name = '{0}-{1}-{2}' -f (Get-Date).ToString('yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6)), (Split-Path -Leaf $Path)
    $dest = Join-Path (Get-PckitBackupDir) $name
    Copy-Item -LiteralPath $Path -Destination $dest -Force
    return $dest
}

# текст блока pckit внутри autoexec.cfg
function Get-PckitCs2CfgBlock {
    param([string[]]$Lines)
    return (@($script:PckitCfgBegin) + @($Lines) + @($script:PckitCfgEnd)) -join "`r`n"
}

# вставить/заменить блок pckit, остальной текст пользователя не трогаем
function Set-PckitCfgBlockText {
    param([string]$Text, [string]$Block)
    $pattern = '(?s)' + [regex]::Escape($script:PckitCfgBegin) + '.*?' + [regex]::Escape($script:PckitCfgEnd)
    if ([regex]::IsMatch($Text, $pattern)) {
        return [regex]::Replace($Text, $pattern, { param($m) $Block }, 1)
    }
    $t = $Text.TrimEnd()
    if ($t) { $t += "`r`n`r`n" }
    return ($t + $Block + "`r`n")
}

function Get-PckitCfgBlockLines {
    param([string]$Text)
    $pattern = '(?s)' + [regex]::Escape($script:PckitCfgBegin) + '\r?\n(.*?)\r?\n?' + [regex]::Escape($script:PckitCfgEnd)
    $m = [regex]::Match($Text, $pattern)
    if (-not $m.Success) { return $null }
    return @($m.Groups[1].Value -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# шаг: { "type": "cs2cfg", "lines": ["rate 786432", ...] }
function Invoke-PckitStepCs2Cfg {
    param($Step, $Journal, [switch]$Run)

    $dir = Get-PckitCs2CfgDir
    if (-not $dir) { return [pscustomobject]@{ Status = 'skip'; Message = 'CS2 не найдена'; Failed = 0 } }
    $file = Join-Path $dir 'autoexec.cfg'
    $lines = @($Step.lines | ForEach-Object { [string]$_ })
    $block = Get-PckitCs2CfgBlock -Lines $lines
    $exists = Test-Path -LiteralPath $file
    $old = if ($exists) { [IO.File]::ReadAllText($file) } else { '' }

    $cur = Get-PckitCfgBlockLines -Text $old
    if ($cur -and ((@($cur) -join "`n") -eq ((@($lines | ForEach-Object { $_.Trim() } | Where-Object { $_ })) -join "`n"))) {
        return [pscustomobject]@{ Status = 'ok'; Message = 'уже так'; Failed = 0 }
    }
    if (-not $Run) {
        $what = if ($exists) { 'дописать блок pckit в autoexec.cfg' } else { 'создать autoexec.cfg' }
        return [pscustomobject]@{ Status = 'dry'; Message = $what; Failed = 0 }
    }
    try {
        $new = Set-PckitCfgBlockText -Text $old -Block $block
        if ($exists) {
            $bak = New-PckitFileBackup -Path $file
            if ($Journal) { Add-PckitFileTracked -Journal $Journal -Target $file -BackupPath $bak }
        } elseif ($Journal) {
            Add-PckitCommandTracked -Journal $Journal -Undo ('del /f /q "{0}"' -f $file) -Note 'CS2: удалить созданный autoexec.cfg'
        }
        # без BOM: движок Source 2 читает cfg как обычный текст
        [IO.File]::WriteAllText($file, $new, (New-Object System.Text.UTF8Encoding($false)))
        return [pscustomobject]@{ Status = 'ok'; Message = ''; Failed = 0 }
    } catch {
        return [pscustomobject]@{ Status = 'fail'; Message = $_.Exception.Message; Failed = 1 }
    }
}

function Test-PckitVerifyCs2Cfg {
    param($Verify)
    $dir = Get-PckitCs2CfgDir
    if (-not $dir) { return [pscustomobject]@{ Ok = $false; Detail = 'CS2 не найдена'; NotApplicable = $true } }
    $file = Join-Path $dir 'autoexec.cfg'
    if (-not (Test-Path -LiteralPath $file)) { return [pscustomobject]@{ Ok = $false; Detail = 'autoexec.cfg нет'; NotApplicable = $false } }
    $cur = Get-PckitCfgBlockLines -Text ([IO.File]::ReadAllText($file))
    return [pscustomobject]@{ Ok = [bool]$cur; Detail = $(if ($cur) { 'блок pckit есть' } else { 'блока pckit нет' }); NotApplicable = $false }
}

# ---------- localconfig.vdf (параметры запуска) ----------

# токены VDF: строки в кавычках и фигурные скобки, с позициями в тексте
function Get-PckitVdfTokens {
    param([string]$Text)
    $tokens = New-Object System.Collections.ArrayList
    $i = 0; $n = $Text.Length
    while ($i -lt $n) {
        $c = $Text[$i]
        if ($c -eq '"') {
            $start = $i; $i++
            $sb = New-Object System.Text.StringBuilder
            while ($i -lt $n -and $Text[$i] -ne '"') {
                if ($Text[$i] -eq '\' -and $i + 1 -lt $n) { [void]$sb.Append($Text[$i + 1]); $i += 2; continue }
                [void]$sb.Append($Text[$i]); $i++
            }
            $i++
            [void]$tokens.Add([pscustomobject]@{ Kind = 's'; Value = $sb.ToString(); Start = $start; End = $i })
        } elseif ($c -eq '{' -or $c -eq '}') {
            [void]$tokens.Add([pscustomobject]@{ Kind = [string]$c; Value = [string]$c; Start = $i; End = $i + 1 }); $i++
        } elseif ($c -eq '/' -and $i + 1 -lt $n -and $Text[$i + 1] -eq '/') {
            while ($i -lt $n -and $Text[$i] -ne "`n") { $i++ }
        } else { $i++ }
    }
    return $tokens.ToArray()
}

# найти блок по пути ключей (без учёта регистра): индекс токена '{' и '}' блока
function Find-PckitVdfBlock {
    param($Tokens, [string[]]$Path)
    $stack = New-Object System.Collections.ArrayList
    $pendingKey = $null
    for ($t = 0; $t -lt $Tokens.Count; $t++) {
        $tok = $Tokens[$t]
        if ($tok.Kind -eq 's') {
            if ($null -eq $pendingKey) {
                # ключ, если следом идёт '{' или строка-значение
                if ($t + 1 -lt $Tokens.Count -and $Tokens[$t + 1].Kind -eq 's') { $t++; continue }
                $pendingKey = $tok.Value
            }
        } elseif ($tok.Kind -eq '{') {
            [void]$stack.Add([pscustomobject]@{ Key = $pendingKey; Open = $t })
            $pendingKey = $null
            if ($stack.Count -eq $Path.Count) {
                $match = $true
                for ($k = 0; $k -lt $Path.Count; $k++) { if ([string]$stack[$k].Key -ine $Path[$k]) { $match = $false; break } }
                if ($match) {
                    # ищем закрывающую скобку
                    $depth = 0
                    for ($j = $t; $j -lt $Tokens.Count; $j++) {
                        if ($Tokens[$j].Kind -eq '{') { $depth++ }
                        elseif ($Tokens[$j].Kind -eq '}') { $depth--; if ($depth -eq 0) { return [pscustomobject]@{ Open = $t; Close = $j } } }
                    }
                    return $null
                }
            }
        } elseif ($tok.Kind -eq '}') {
            if ($stack.Count) { $stack.RemoveAt($stack.Count - 1) }
            $pendingKey = $null
        }
    }
    return $null
}

# значение ключа верхнего уровня внутри блока: { ValueToken } или $null
function Find-PckitVdfValue {
    param($Tokens, $Block, [string]$Key)
    $depth = 0
    for ($t = $Block.Open + 1; $t -lt $Block.Close; $t++) {
        $tok = $Tokens[$t]
        if ($tok.Kind -eq '{') { $depth++; continue }
        if ($tok.Kind -eq '}') { $depth--; continue }
        if ($depth -eq 0 -and $tok.Kind -eq 's' -and $t + 1 -lt $Block.Close -and $Tokens[$t + 1].Kind -eq 's') {
            if ($tok.Value -ieq $Key) { return $Tokens[$t + 1] }
            $t++
        }
    }
    return $null
}

function ConvertTo-PckitVdfString {
    param([string]$Value)
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Get-PckitLocalConfigPath {
    $user = Get-PckitSteamUserDir
    if (-not $user) { return $null }
    $f = Join-Path $user 'config\localconfig.vdf'
    if (Test-Path -LiteralPath $f) { return $f }
    return $null
}

$script:PckitCs2AppPath = @('UserLocalConfigStore', 'Software', 'Valve', 'Steam', 'apps', '730')

function Get-PckitCs2LaunchOptions {
    $file = Get-PckitLocalConfigPath
    if (-not $file) { return $null }
    $text = [IO.File]::ReadAllText($file)
    $tokens = Get-PckitVdfTokens -Text $text
    $block = Find-PckitVdfBlock -Tokens $tokens -Path $script:PckitCs2AppPath
    if (-not $block) { return [pscustomobject]@{ File = $file; Value = ''; Found = $false } }
    $v = Find-PckitVdfValue -Tokens $tokens -Block $block -Key 'LaunchOptions'
    return [pscustomobject]@{ File = $file; Value = $(if ($v) { $v.Value } else { '' }); Found = $true }
}

# добавить недостающие параметры к уже заданным пользователем
function Merge-PckitLaunchOptions {
    param([string]$Current, [string[]]$Add)
    $result = $Current.Trim()
    foreach ($opt in $Add) {
        $o = $opt.Trim()
        if (-not $o) { continue }
        if ((' ' + $result + ' ') -like ('* ' + $o + ' *')) { continue }
        $result = ($result + ' ' + $o).Trim()
    }
    return $result
}

# шаг: { "type": "cs2launch", "add": ["+exec autoexec"] }
function Invoke-PckitStepCs2Launch {
    param($Step, $Journal, [switch]$Run)

    $file = Get-PckitLocalConfigPath
    if (-not $file) { return [pscustomobject]@{ Status = 'skip'; Message = 'не найден профиль Steam (localconfig.vdf)'; Failed = 0 } }
    $add = @($Step.add | ForEach-Object { [string]$_ })
    $text = [IO.File]::ReadAllText($file)
    $tokens = Get-PckitVdfTokens -Text $text
    $block = Find-PckitVdfBlock -Tokens $tokens -Path $script:PckitCs2AppPath
    if (-not $block) { return [pscustomobject]@{ Status = 'skip'; Message = 'CS2 ещё ни разу не запускалась в этом Steam'; Failed = 0 } }
    $valTok = Find-PckitVdfValue -Tokens $tokens -Block $block -Key 'LaunchOptions'
    $cur = if ($valTok) { $valTok.Value } else { '' }
    $new = Merge-PckitLaunchOptions -Current $cur -Add $add
    if ($new -eq $cur.Trim()) { return [pscustomobject]@{ Status = 'ok'; Message = 'уже так'; Failed = 0 } }
    if (-not $Run) { return [pscustomobject]@{ Status = 'dry'; Message = ('параметры запуска: {0}' -f $new); Failed = 0 } }

    # Steam держит файл в памяти и перезапишет его при выходе — менять только при закрытом Steam
    if (@(Get-Process -Name 'steam' -ErrorAction SilentlyContinue).Count) {
        return [pscustomobject]@{ Status = 'fail'; Message = 'закройте Steam (значок у часов → Выход) и примените ещё раз'; Failed = 1 }
    }
    try {
        if ($valTok) {
            $out = $text.Substring(0, $valTok.Start) + (ConvertTo-PckitVdfString $new) + $text.Substring($valTok.End)
        } else {
            $open = $tokens[$block.Open]
            # отступ как у соседних строк блока
            $lineStart = $text.LastIndexOf("`n", [math]::Max(0, $open.Start - 1)) + 1
            $indent = ($text.Substring($lineStart, $open.Start - $lineStart) -replace '[^\t ]', '') + "`t"
            $insert = "`n" + $indent + '"LaunchOptions"' + "`t`t" + (ConvertTo-PckitVdfString $new)
            $out = $text.Substring(0, $open.End) + $insert + $text.Substring($open.End)
        }
        $bak = New-PckitFileBackup -Path $file
        [IO.File]::WriteAllText($file, $out, (New-Object System.Text.UTF8Encoding($false)))
        if ($Journal) { Add-PckitFileTracked -Journal $Journal -Target $file -BackupPath $bak }
        return [pscustomobject]@{ Status = 'ok'; Message = ''; Failed = 0 }
    } catch {
        return [pscustomobject]@{ Status = 'fail'; Message = $_.Exception.Message; Failed = 1 }
    }
}

function Test-PckitVerifyCs2Launch {
    param($Verify)
    $lo = $null
    try { $lo = Get-PckitCs2LaunchOptions } catch { }
    if (-not $lo) { return [pscustomobject]@{ Ok = $false; Detail = 'нет профиля Steam'; NotApplicable = $true } }
    if (-not $lo.Found) { return [pscustomobject]@{ Ok = $false; Detail = 'CS2 не запускалась'; NotApplicable = $true } }
    $missing = @(@($Verify.add) | Where-Object { (' ' + $lo.Value + ' ') -notlike ('* ' + ([string]$_).Trim() + ' *') })
    $detail = if ($lo.Value) { ('сейчас: {0}' -f $lo.Value) } else { 'пусто' }
    return [pscustomobject]@{ Ok = ($missing.Count -eq 0); Detail = $detail; NotApplicable = $false }
}
