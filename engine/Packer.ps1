#Requires -Version 5.1
# pckit engine | packer: create and open a *.pckit profile

function Copy-PckitTree {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$Exclude = @()
    )
    if (-not (Test-Path -LiteralPath $Source)) { return $false }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    $dirExcludes = @()
    $fileExcludes = @()
    foreach ($p in $Exclude) {
        if (-not $p) { continue }
        if ($p -match '[*?]') { $fileExcludes += $p } else { $dirExcludes += $p }
    }

    # /XJ: не заходить в junction-ссылки (иначе в AppData можно уйти по кругу или скопировать чужое)
    $roboArgs = @($Source, $Destination, '/E', '/XJ', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    if ($dirExcludes.Count) { $roboArgs += '/XD'; $roboArgs += $dirExcludes }
    if ($fileExcludes.Count) { $roboArgs += '/XF'; $roboArgs += $fileExcludes }

    $out = & robocopy @roboArgs 2>&1
    $code = $LASTEXITCODE
    if ($code -ge 8) {
        throw ('robocopy завершился с кодом {0}: {1}' -f $code, (($out | Select-Object -Last 3) -join ' '))
    }
    return $true
}

function New-PckitProfileItem {
    param(
        $Item,
        [string]$Root
    )

    $payloadRoot = Join-Path $Root 'payload'
    $entry = [ordered]@{
        id      = $Item.Id
        kind    = $Item.Kind
        title   = $Item.Title
        risk    = $Item.Risk
        sizeMb  = [double]$Item.SizeMb
        payload = $null
        meta    = [ordered]@{}
    }

    switch ($Item.Kind) {
        'app' {
            foreach ($k in 'DisplayName', 'WingetId', 'Source', 'Version', 'Publisher') {
                if ($Item.Meta.PSObject.Properties.Name -contains $k) { $entry.meta[$k] = $Item.Meta.$k }
            }
            if ($Item.Meta.PSObject.Properties.Name -contains 'Store') { $entry.meta['Store'] = @($Item.Meta.Store) }
            if ($Item.Meta.PSObject.Properties.Name -contains 'Restore') { $entry.meta['Restore'] = $Item.Meta.Restore }
        }
        'appdata' {
            $entry.meta['recipe'] = [string]$Item.Meta.RecipeId
            $entry.meta['app'] = [string]$Item.Meta.App
            $steps = New-Object System.Collections.Generic.List[object]
            $index = 0
            foreach ($step in $Item.Meta.Steps) {
                $index++
                $copy = [ordered]@{
                    type    = [string]$step.type
                    payload = $null
                    target  = $null
                    exclude = @($step.exclude)
                }
                switch ([string]$step.type) {
                    'dir' {
                        $target = Resolve-PckitPath ([string]$step.path)
                        $dest = Join-Path $payloadRoot ('appdata\{0}\{1}' -f $Item.Meta.RecipeId, $index)
                        if (Copy-PckitTree -Source $target -Destination $dest -Exclude @($step.exclude)) {
                            $copy.payload = $dest.Substring($Root.Length).TrimStart('\')
                            $copy.target = [string]$step.path
                        }
                    }
                    'file' {
                        $target = Resolve-PckitPath ([string]$step.path)
                        if (Test-Path -LiteralPath $target) {
                            $dest = Join-Path $payloadRoot ('appdata\{0}\{1}' -f $Item.Meta.RecipeId, $index)
                            New-Item -ItemType Directory -Force -Path $dest | Out-Null
                            Copy-Item -LiteralPath $target -Destination $dest -Force
                            $copy.payload = (Join-Path $dest (Split-Path -Leaf $target)).Substring($Root.Length).TrimStart('\')
                            $copy.target = [string]$step.path
                        }
                    }
                    'registry' {
                        $key = [string]$step.key
                        $dest = Join-Path $payloadRoot ('registry\{0}-{1}.reg' -f $Item.Meta.RecipeId, $index)
                        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
                        & reg export $key $dest /y 2>$null | Out-Null
                        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $dest)) {
                            $copy.payload = $dest.Substring($Root.Length).TrimStart('\')
                            $copy.target = $key
                        }
                    }
                    'command' {
                        $text = ''
                        try { $text = (& cmd /c $step.capture 2>$null | Out-String) } catch { }
                        if ($text) {
                            $dest = Join-Path $payloadRoot ('command\{0}-{1}.txt' -f $Item.Meta.RecipeId, $index)
                            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
                            [IO.File]::WriteAllText($dest, $text, (New-Object System.Text.UTF8Encoding($false)))
                            $copy.payload = $dest.Substring($Root.Length).TrimStart('\')
                            $copy.target = [string]$step.restoreTemplate
                        }
                    }
                    default { $copy.target = [string]$step.note }
                }
                $steps.Add([pscustomobject]$copy)
            }
            $entry.meta['steps'] = $steps.ToArray()
        }
        'files' {
            $entry.meta['mode'] = [string]$Item.Meta.Mode
            $entry.meta['target'] = [string]$Item.Meta.Target
            if ($Item.Meta.Mode -eq 'copy') {
                $dest = Join-Path $payloadRoot ('files\{0}' -f ($Item.Id -replace '^files\.', ''))
                if (Copy-PckitTree -Source $Item.Meta.Resolved -Destination $dest) {
                    $entry.payload = $dest.Substring($Root.Length).TrimStart('\')
                }
            }
        }
        'os' {
            foreach ($prop in $Item.Meta.PSObject.Properties) { $entry.meta[$prop.Name] = $prop.Value }
            if ($Item.Id -eq 'os.hosts') {
                $dest = Join-Path $payloadRoot 'os\hosts'
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
                Copy-Item -LiteralPath $Item.Meta.Source -Destination $dest -Force
                $entry.payload = $dest.Substring($Root.Length).TrimStart('\')
            }
        }
        'network' {
            foreach ($prop in $Item.Meta.PSObject.Properties) { $entry.meta[$prop.Name] = $prop.Value }
            if ($Item.Id -eq 'os.wifi') {
                $dest = Join-Path $payloadRoot 'wifi'
                New-Item -ItemType Directory -Force -Path $dest | Out-Null
                # без key=clear пароль зашифрован под текущую установку Windows и после переустановки бесполезен
                if (Test-PckitAdmin) {
                    & netsh wlan export profile folder="$dest" key=clear 2>$null | Out-Null
                    $entry.meta['passwordsIncluded'] = $true
                } else {
                    & netsh wlan export profile folder="$dest" 2>$null | Out-Null
                    $entry.meta['passwordsIncluded'] = $false
                }
                $entry.payload = $dest.Substring($Root.Length).TrimStart('\')
            }
        }
        'dev' {
            foreach ($prop in $Item.Meta.PSObject.Properties) { $entry.meta[$prop.Name] = $prop.Value }
            switch ([string]$Item.Meta.Type) {
                'file' {
                    $source = [string]$Item.Meta.Source
                    if (Test-Path -LiteralPath $source) {
                        $dest = Join-Path $payloadRoot ('dev\{0}' -f (Split-Path -Leaf $source))
                        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
                        Copy-Item -LiteralPath $source -Destination $dest -Force
                        $entry.payload = $dest.Substring($Root.Length).TrimStart('\')
                    }
                }
                'env' {
                    $vars = [ordered]@{}
                    foreach ($v in ([Environment]::GetEnvironmentVariables('User')).GetEnumerator()) { $vars[[string]$v.Key] = [string]$v.Value }
                    $entry.meta['vars'] = $vars
                }
                'command' {
                    $text = ''
                    try { $text = (& cmd /c ([string]$Item.Meta.Capture) 2>$null | Out-String) } catch { }
                    if ($text) {
                        $dest = Join-Path $payloadRoot ('command\{0}.txt' -f ($Item.Id -replace '[^a-z0-9\.\-]', '_'))
                        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
                        [IO.File]::WriteAllText($dest, $text, (New-Object System.Text.UTF8Encoding($false)))
                        $entry.payload = $dest.Substring($Root.Length).TrimStart('\')
                    }
                }
            }
        }
        'drivers' {
            if (Test-PckitAdmin) {
                $dest = Join-Path $payloadRoot 'drivers'
                New-Item -ItemType Directory -Force -Path $dest | Out-Null
                & pnputil /export-driver * "$dest" 2>$null | Out-Null
                $entry.payload = $dest.Substring($Root.Length).TrimStart('\')
            }
        }
    }

    return [pscustomobject]$entry
}

function New-PckitProfile {
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][object[]]$Selection,
        [string]$OutFile,
        [string]$Name = 'profile'
    )

    if (-not $OutFile) { $OutFile = Join-Path (Get-Location).Path ('{0}.pckit' -f $Name) }
    $root = New-PckitTempDir -Prefix 'pckit-pack'
    try {

    $entries = New-Object System.Collections.Generic.List[object]
    $manual = New-Object System.Collections.Generic.List[object]
    $index = 0

    foreach ($item in $Selection) {
        $index++
        Write-Progress -Activity 'Упаковка профиля' -Status $item.Title -PercentComplete (($index / $Selection.Count) * 100)
        try {
            $entry = New-PckitProfileItem -Item $item -Root $root
            $entries.Add($entry)
            if ($item.Kind -eq 'app' -and -not $entry.meta['wingetId']) {
                $info = Get-PckitManualAppInfo -Title $item.Title
                $manualEntry = [ordered]@{
                    title     = $item.Title
                    publisher = [string]$entry.meta['publisher']
                    reason    = 'нет пакета winget — скачать установщик'
                    url       = ''
                    note      = ''
                    account   = $false
                }
                if ($info) {
                    $manualEntry.url = [string]$info.url
                    $manualEntry.note = [string]$info.note
                    $manualEntry.account = [bool]$info.needsAccount
                }
                $manual.Add($manualEntry)
            }
        } catch {
            Write-PckitLog -Level warn -Message ('{0}: не удалось снять — {1}' -f $item.Title, $_.Exception.Message)
            $manual.Add([ordered]@{ title = $item.Title; publisher = ''; reason = ('ошибка захвата: ' + $_.Exception.Message) })
        }
    }
    Write-Progress -Activity 'Упаковка профиля' -Completed

    $manifest = [ordered]@{
        schema   = 1
        name     = $Name
        created  = (Get-Date).ToString('s')
        pckit    = $PckitVersion
        machine  = $Catalog.Machine
        items    = $entries.ToArray()
        manual   = $manual.ToArray()
    }
    Save-PckitJson -Path (Join-Path $root 'manifest.json') -Object $manifest

    $payloadDir = Join-Path $root 'payload'
    $sums = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $payloadDir) {
        foreach ($f in (Get-ChildItem -LiteralPath $payloadDir -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
            $rel = $f.FullName.Substring($root.Length).TrimStart('\')
            $sums.Add(('{0} *{1}' -f $hash, $rel))
        }
    }
    [IO.File]::WriteAllText((Join-Path $root 'checksums.sha256'), ($sums -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

    # пишем во временный файл и переименовываем: оборванная упаковка не затрёт старый рабочий профиль
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $tmpOut = $OutFile + '.tmp'
    if (Test-Path -LiteralPath $tmpOut) { Remove-Item -LiteralPath $tmpOut -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory($root, $tmpOut, [IO.Compression.CompressionLevel]::Optimal, $false)
    Move-Item -LiteralPath $tmpOut -Destination $OutFile -Force

    $sizeMb = [math]::Round((Get-Item -LiteralPath $OutFile).Length / 1MB, 1)

    } finally {
        # временная папка может содержать пароли Wi-Fi — убираем в любом случае
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        Path    = $OutFile
        SizeMb  = $sizeMb
        Items   = $entries.Count
        Payload = $sums.Count
        Manual  = $manual.Count
        Manifest = $manifest
    }
}

function Expand-PckitProfile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw ('профиль не найден: {0}' -f $Path) }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = New-PckitTempDir -Prefix 'pckit-open'
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($Path)
        try {
            foreach ($entry in $zip.Entries) {
                $dest = [IO.Path]::GetFullPath((Join-Path $root ($entry.FullName -replace '/', '\')))
                # Zip Slip: запись должна остаться внутри временной папки
                if (-not (Test-PckitUnderRoot -Path $dest -Root $root)) {
                    throw ('небезопасный путь в архиве: {0}' -f $entry.FullName)
                }
                if ([string]::IsNullOrEmpty($entry.Name)) {
                    New-Item -ItemType Directory -Force -Path $dest | Out-Null
                    continue
                }
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
            }
        } finally { $zip.Dispose() }

        $manifest = $null
        try { $manifest = Read-PckitJson (Join-Path $root 'manifest.json') }
        catch { throw ('manifest.json повреждён: {0}' -f $_.Exception.Message) }
        if (-not $manifest) { throw 'в профиле нет manifest.json' }
        if (-not $manifest.items) { throw 'в манифесте нет списка объектов' }
        if ($manifest.schema -and [int]$manifest.schema -gt 1) {
            throw ('профиль создан более новой версией pckit (schema {0}) — обновите программу' -f $manifest.schema)
        }

        $check = Test-PckitProfileChecksums -Root $root
        if ($check.Bad.Count) {
            throw ('профиль повреждён, не совпали контрольные суммы: {0}' -f (($check.Bad | Select-Object -First 3) -join ', '))
        }
    } catch {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    return [pscustomobject]@{ Root = $root; Manifest = $manifest; Verified = $check.HasSums; FilesChecked = $check.Checked }
}

function Test-PckitProfileChecksums {
    # сверяет payload с checksums.sha256; ловит порчу при копировании на флешку (от умышленной подмены не защищает)
    param([Parameter(Mandatory)][string]$Root)

    $bad = New-Object System.Collections.Generic.List[string]
    $file = Join-Path $Root 'checksums.sha256'
    if (-not (Test-Path -LiteralPath $file)) {
        return [pscustomobject]@{ HasSums = $false; Checked = 0; Bad = @() }
    }
    $listed = @{}
    foreach ($line in (Get-Content -LiteralPath $file -Encoding UTF8)) {
        if ($line -notmatch '^([0-9A-Fa-f]{64}) \*(.+)$') { continue }
        $rel = $matches[2]
        $full = [IO.Path]::GetFullPath((Join-Path $Root $rel))
        if (-not (Test-PckitUnderRoot -Path $full -Root $Root)) { $bad.Add($rel); continue }
        $listed[$full.ToLower()] = $true
        if (-not (Test-Path -LiteralPath $full)) { $bad.Add($rel + ' (нет файла)'); continue }
        if ((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash -ne $matches[1].ToUpper()) { $bad.Add($rel) }
    }
    $payload = Join-Path $Root 'payload'
    if (Test-Path -LiteralPath $payload) {
        foreach ($f in (Get-ChildItem -LiteralPath $payload -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            if (-not $listed.ContainsKey($f.FullName.ToLower())) { $bad.Add(($f.FullName.Substring($Root.Length).TrimStart('\')) + ' (лишний файл)') }
        }
    }
    return [pscustomobject]@{ HasSums = $true; Checked = $listed.Count; Bad = $bad.ToArray() }
}

function Close-PckitProfile {
    param($Profile)
    if ($Profile -and $Profile.Root -and (Test-Path -LiteralPath $Profile.Root)) {
        Remove-Item -LiteralPath $Profile.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
