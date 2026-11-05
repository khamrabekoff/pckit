#Requires -Version 5.1
# pckit engine | catalog: what exists on this machine

function ConvertFrom-WingetList {
    param([string[]]$Lines)

    $rows = New-Object System.Collections.Generic.List[object]
    $columns = $null

    foreach ($line in $Lines) {
        if ($null -eq $columns) {
            if ($line -match '^Name\s+Id\s+Version') {
                $found = New-Object System.Collections.Generic.List[object]
                foreach ($name in @('Name', 'Id', 'Version', 'Available', 'Source')) {
                    $idx = $line.IndexOf($name)
                    if ($idx -ge 0) { $found.Add([pscustomobject]@{ Name = $name; Start = $idx }) }
                }
                if ($found.Count -ge 3) { $columns = @($found | Sort-Object Start) }
            }
            continue
        }
        if ($line -match '^\s*-+\s*$') { continue }
        if (-not $line.Trim()) { continue }

        $values = @{}
        for ($i = 0; $i -lt $columns.Count; $i++) {
            $start = $columns[$i].Start
            $end = if ($i + 1 -lt $columns.Count) { $columns[$i + 1].Start } else { $line.Length }
            if ($start -ge $line.Length) { $values[$columns[$i].Name] = ''; continue }
            $len = [Math]::Min($end - $start, $line.Length - $start)
            $values[$columns[$i].Name] = $line.Substring($start, $len).Trim()
        }
        if (-not $values['Name']) { continue }
        $rows.Add([pscustomobject]@{
            Name    = $values['Name']
            Id      = $values['Id']
            Version = $values['Version']
            Source  = if ($values.ContainsKey('Source')) { $values['Source'] } else { '' }
        })
    }
    return $rows
}

function Get-PckitRegistryApps {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $apps = Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName -and -not $_.SystemComponent -and
            $_.DisplayName -notlike '*Update for*' -and
            $_.DisplayName -notlike '*Security Update*' -and
            $_.DisplayName -notlike '*Обновление для*'
        } |
        Sort-Object DisplayName -Unique

    return @($apps | ForEach-Object {
            [pscustomobject]@{
                Name            = [string]$_.DisplayName
                Version         = [string]$_.DisplayVersion
                Publisher       = [string]$_.Publisher
                InstallLocation = [string]$_.InstallLocation
            }
        })
}

function Get-PckitWingetRows {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) { return @() }
    $lines = & $winget.Source list --accept-source-agreements --disable-interactivity 2>$null
    if (-not $lines) { return @() }
    return @(ConvertFrom-WingetList -Lines $lines)
}

function Get-PckitInstalledApps {
    param($Recipes, [switch]$SkipSizes)

    $registry = @(Get-PckitRegistryApps)
    $wingetRows = @(Get-PckitWingetRows)

    $wingetByName = @{}
    foreach ($row in $wingetRows) {
        if (-not $row.Id) { continue }
        if ($row.Id -match '^(ARP|MSIX)\\') { continue }
        $key = Get-PckitNormalizedName $row.Name
        if ($key -and -not $wingetByName.ContainsKey($key)) { $wingetByName[$key] = $row }
    }

    $items = New-Object System.Collections.Generic.List[object]
    $recipeHits = New-Object System.Collections.Generic.HashSet[string]

    # installer components and runtimes are reinstalled by their parent product
    $componentRx = 'Visual C\+\+|Redistributable|Runtime|SDK|Material Library|LocalDB|Update for|Survey Program|Maintenance Service|Network License Manager|App Manager|Unit Schemas|Open in Desktop|ASP\.NET'
    foreach ($app in $registry) {
        if ($app.Name -match $componentRx) { continue }
        if (-not $app.Name) { continue }
        $norm = Get-PckitNormalizedName $app.Name
        if (-not $norm) { continue }

        $wingetId = ''
        if ($wingetByName.ContainsKey($norm)) {
            $wingetId = [string]$wingetByName[$norm].Id
        } else {
            foreach ($key in $wingetByName.Keys) {
                if ($key.Length -lt 6) { continue }
                $delta = [Math]::Abs($key.Length - $norm.Length)
                if ($delta -le 8 -and ($key.StartsWith($norm) -or $norm.StartsWith($key))) {
                    $wingetId = [string]$wingetByName[$key].Id
                    break
                }
            }
        }

        $source = if ($wingetId) { 'winget' } else { 'installer' }
        $id = if ($wingetId) { 'app:' + $wingetId } else { 'app:' + $norm }

        $items.Add([pscustomobject]@{
                Id       = $id
                Kind     = 'app'
                Title    = $app.Name
                Subtitle = if ($wingetId) { 'winget · ' + $app.Version } else { 'вручную · ' + $app.Version }
                Risk     = 'low'
                SizeMb   = 0
                Default  = [bool]$wingetId
                Meta     = [pscustomobject]@{
                    DisplayName     = $app.Name
                    WingetId        = $wingetId
                    Source          = $source
                    Version         = $app.Version
                    Publisher       = $app.Publisher
                    InstallLocation = $app.InstallLocation
                }
            })

        $recipe = Find-PckitRecipe -Recipes $Recipes -DisplayName $app.Name -WingetId $wingetId
        if ($recipe -and -not $recipeHits.Contains($recipe.Id)) {
            [void]$recipeHits.Add($recipe.Id)
            $size = if ($SkipSizes) { 0 } else { Get-PckitRecipeSize -Recipe $recipe }
            $items.Add([pscustomobject]@{
                    Id       = 'appdata:' + $recipe.Id
                    Kind     = 'appdata'
                    Title    = $recipe.Title + ' — данные и настройки'
                    Subtitle = ('рецепт {0} · {1} шагов' -f $recipe.Id, $recipe.Steps.Count)
                    Risk     = $recipe.Risk
                    SizeMb   = $size
                    Default  = ($recipe.Risk -ne 'high')
                    Meta     = [pscustomobject]@{
                        RecipeId = $recipe.Id
                        Steps    = $recipe.Steps
                        App      = $app.Name
                    }
                })
        }
    }

    return $items
}

function Get-PckitStoreApps {
    $pkgs = Get-AppxPackage -ErrorAction SilentlyContinue |
        Where-Object { -not $_.IsFramework -and $_.SignatureKind -ne 'System' } |
        Where-Object { $_.Name -notlike 'Microsoft.*' -and $_.Name -notlike '*MicrosoftEdge*' }
    return @($pkgs | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_.Name; Family = [string]$_.PackageFamilyName }
        } | Sort-Object Name -Unique)
}

function Get-PckitFileItems {
    param([switch]$SkipSizes)

    $defs = @(
        @{ Id = 'files.desktop'; Title = 'Рабочий стол'; Path = '%USERPROFILE%\Desktop'; Mode = 'copy'; Default = $true; Risk = 'low' }
        @{ Id = 'files.documents'; Title = 'Документы'; Path = '%USERPROFILE%\Documents'; Mode = 'copy'; Default = $true; Risk = 'low' }
        @{ Id = 'files.pictures'; Title = 'Изображения'; Path = '%USERPROFILE%\Pictures'; Mode = 'copy'; Default = $false; Risk = 'low' }
        @{ Id = 'files.downloads'; Title = 'Загрузки'; Path = '%USERPROFILE%\Downloads'; Mode = 'copy'; Default = $false; Risk = 'low' }
        @{ Id = 'files.videos'; Title = 'Видео'; Path = '%USERPROFILE%\Videos'; Mode = 'reference'; Default = $false; Risk = 'low' }
        @{ Id = 'files.music'; Title = 'Музыка'; Path = '%USERPROFILE%\Music'; Mode = 'reference'; Default = $false; Risk = 'low' }
        @{ Id = 'files.savedgames'; Title = 'Сохранения игр'; Path = '%USERPROFILE%\Saved Games'; Mode = 'copy'; Default = $false; Risk = 'low' }
        @{ Id = 'files.ssh'; Title = 'SSH-ключи (.ssh)'; Path = '%USERPROFILE%\.ssh'; Mode = 'copy'; Default = $false; Risk = 'high' }
        @{ Id = 'files.gpg'; Title = 'GPG-ключи'; Path = '%APPDATA%\gnupg'; Mode = 'copy'; Default = $false; Risk = 'high' }
    )

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($d in $defs) {
        $resolved = Resolve-PckitPath $d.Path
        $exists = Test-Path -LiteralPath $resolved
        $size = 0
        $files = 0
        if ($exists -and -not $SkipSizes) {
            $info = Get-PckitFolderInfo -Path $resolved
            $size = $info.SizeMb
            $files = $info.FileCount
        }
        $items.Add([pscustomobject]@{
                Id       = $d.Id
                Kind     = 'files'
                Title    = $d.Title
                Subtitle = if ($d.Mode -eq 'reference') { 'запомнить путь, не копировать' } else { ('{0} файлов' -f $files) }
                Risk     = $d.Risk
                SizeMb   = $size
                Default  = [bool]($d.Default -and $exists)
                Exists   = $exists
                Meta     = [pscustomobject]@{ Mode = $d.Mode; Target = $d.Path; Resolved = $resolved }
            })
    }
    return $items
}

function Get-PckitOsItems {
    param([switch]$SkipSizes)

    $items = New-Object System.Collections.Generic.List[object]
    $isAdmin = Test-PckitAdmin

    $tz = Get-TimeZone
    $items.Add([pscustomobject]@{
            Id = 'os.timezone'; Kind = 'os'; Title = 'Часовой пояс'; Subtitle = $tz.Id
            Risk = 'low'; SizeMb = 0; Default = $true; Meta = [pscustomobject]@{ Id = $tz.Id; Display = $tz.DisplayName }
        })

    $langs = @(Get-WinUserLanguageList -ErrorAction SilentlyContinue | ForEach-Object { $_.LanguageTag })
    $items.Add([pscustomobject]@{
            Id = 'os.languages'; Kind = 'os'; Title = 'Языки и раскладки'; Subtitle = ($langs -join ', ')
            Risk = 'low'; SizeMb = 0; Default = $true; Meta = [pscustomobject]@{ List = $langs }
        })

    $plan = $null
    try {
        $powerOut = & powercfg /getactivescheme 2>$null
        if ($powerOut -match '([0-9a-fA-F-]{36})') { $plan = $matches[1] }
    } catch { }
    if ($plan) {
        $items.Add([pscustomobject]@{
                Id = 'os.powerplan'; Kind = 'os'; Title = 'Схема электропитания'; Subtitle = $plan
                Risk = 'low'; SizeMb = 0; Default = $true; Meta = [pscustomobject]@{ Guid = $plan }
            })
    }

    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $hostsCustom = @()
    if (Test-Path -LiteralPath $hostsPath) {
        $hostsCustom = @(Get-Content -LiteralPath $hostsPath -ErrorAction SilentlyContinue |
                Where-Object { $_ -and $_ -notmatch '^\s*#' })
    }
    $items.Add([pscustomobject]@{
            Id = 'os.hosts'; Kind = 'os'; Title = 'Файл hosts'; Subtitle = ('{0} активных строк' -f $hostsCustom.Count)
            Risk = 'medium'; SizeMb = 0; Default = ($hostsCustom.Count -gt 0)
            Meta = [pscustomobject]@{ Source = $hostsPath }
        })

    $wifi = @()
    try {
        $wifiOut = & netsh wlan show profiles 2>$null
        $wifi = @($wifiOut | ForEach-Object { if ($_ -match ':\s*(.+)$') { $matches[1].Trim() } } | Where-Object { $_ })
    } catch { }
    $items.Add([pscustomobject]@{
            Id = 'os.wifi'; Kind = 'network'; Title = 'Wi-Fi профили'; Subtitle = ('{0} сетей' -f $wifi.Count)
            Risk = 'high'; SizeMb = 0; Default = $false
            Meta = [pscustomobject]@{ Profiles = $wifi; Note = 'при запуске от администратора в файл попадут пароли Wi-Fi открытым текстом — храните .pckit как пароль' }
        })

    $tasks = @()
    try {
        $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue |
                Where-Object { $_.TaskPath -notlike '\Microsoft*' } |
                ForEach-Object { '{0}{1}' -f $_.TaskPath, $_.TaskName })
    } catch { }
    $items.Add([pscustomobject]@{
            Id = 'os.tasks'; Kind = 'os'; Title = 'Задачи планировщика'; Subtitle = ('{0} своих задач' -f $tasks.Count)
            Risk = 'low'; SizeMb = 0; Default = $false; Meta = [pscustomobject]@{ Tasks = $tasks; Restore = 'note' }
        })

    $printers = @()
    try { $printers = @(Get-Printer -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) } catch { }
    $items.Add([pscustomobject]@{
            Id = 'os.printers'; Kind = 'os'; Title = 'Принтеры'; Subtitle = ($printers -join ', ')
            Risk = 'low'; SizeMb = 0; Default = $false; Meta = [pscustomobject]@{ Printers = $printers; Restore = 'note' }
        })

    $drives = @()
    try {
        $drives = @(Get-CimInstance Win32_MappedLogicalDisk -ErrorAction SilentlyContinue |
                ForEach-Object { '{0} -> {1}' -f $_.DeviceID, $_.ProviderName })
    } catch { }
    $items.Add([pscustomobject]@{
            Id = 'os.mappeddrives'; Kind = 'network'; Title = 'Сетевые диски'; Subtitle = ($drives -join '; ')
            Risk = 'low'; SizeMb = 0; Default = $false; Meta = [pscustomobject]@{ Drives = $drives; Restore = 'note' }
        })

    $items.Add([pscustomobject]@{
            Id = 'os.drivers'; Kind = 'drivers'; Title = 'Драйверы (DriverStore)'; Subtitle = if ($isAdmin) { 'доступно' } else { 'нужен запуск от администратора' }
            Risk = 'high'; SizeMb = 0; Default = $false; Meta = [pscustomobject]@{ NeedsAdmin = $true }
        })

    return $items
}

function Get-PckitDevItems {
    $items = New-Object System.Collections.Generic.List[object]
    $has = { param($n) [bool](Get-Command $n -ErrorAction SilentlyContinue) }

    $gitConfig = Join-Path $env:USERPROFILE '.gitconfig'
    if (Test-Path -LiteralPath $gitConfig) {
        $items.Add([pscustomobject]@{
                Id = 'dev.gitconfig'; Kind = 'dev'; Title = 'Git: глобальный конфиг'; Subtitle = '.gitconfig'
                Risk = 'low'; SizeMb = 0; Default = $true
                Meta = [pscustomobject]@{ Type = 'file'; Source = $gitConfig }
            })
    }

    $items.Add([pscustomobject]@{
            Id = 'dev.env'; Kind = 'dev'; Title = 'Переменные среды пользователя'; Subtitle = 'PATH и прочее'
            Risk = 'medium'; SizeMb = 0; Default = $true
            Meta = [pscustomobject]@{ Type = 'env'; Restore = 'merge' }
        })

    if (& $has 'code') {
        $items.Add([pscustomobject]@{
                Id = 'dev.vscode'; Kind = 'dev'; Title = 'Расширения VS Code'; Subtitle = 'список + установка'
                Risk = 'low'; SizeMb = 0; Default = $true
                Meta = [pscustomobject]@{ Type = 'command'; Capture = 'code --list-extensions'; RestoreTemplate = 'code --install-extension {line}' }
            })
    }
    if (& $has 'npm') {
        $items.Add([pscustomobject]@{
                Id = 'dev.npm'; Kind = 'dev'; Title = 'npm: глобальные пакеты'; Subtitle = 'список'
                Risk = 'low'; SizeMb = 0; Default = $false
                Meta = [pscustomobject]@{ Type = 'command'; Capture = 'npm ls -g --depth=0'; RestoreTemplate = ''; Restore = 'note' }
            })
    }
    if (& $has 'pip') {
        $items.Add([pscustomobject]@{
                Id = 'dev.pip'; Kind = 'dev'; Title = 'Python: пакеты pip'; Subtitle = 'список'
                Risk = 'low'; SizeMb = 0; Default = $false
                Meta = [pscustomobject]@{ Type = 'command'; Capture = 'pip list'; RestoreTemplate = ''; Restore = 'note' }
            })
    }
    if (& $has 'dotnet') {
        $items.Add([pscustomobject]@{
                Id = 'dev.dotnet'; Kind = 'dev'; Title = 'dotnet tools'; Subtitle = 'список'
                Risk = 'low'; SizeMb = 0; Default = $false
                Meta = [pscustomobject]@{ Type = 'command'; Capture = 'dotnet tool list -g'; RestoreTemplate = ''; Restore = 'note' }
            })
    }
    if (& $has 'wsl') {
        $items.Add([pscustomobject]@{
                Id = 'dev.wsl'; Kind = 'dev'; Title = 'WSL: дистрибутивы'; Subtitle = 'список'
                Risk = 'low'; SizeMb = 0; Default = $false
                Meta = [pscustomobject]@{ Type = 'command'; Capture = 'wsl -l -v'; RestoreTemplate = ''; Restore = 'note' }
            })
    }
    return $items
}

function Get-PckitCatalog {
    param(
        [string]$RecipeDir,
        [switch]$SkipSizes
    )

    $recipes = @(Get-PckitRecipes -Directory $RecipeDir)

    Write-PckitLog -Level step -Message 'Сканирую установленные программы...'
    $apps = @(Get-PckitInstalledApps -Recipes $recipes -SkipSizes:$SkipSizes)

    Write-PckitLog -Level step -Message 'Сканирую пользовательские папки, ОС и инструменты разработчика...'
    $files = @(Get-PckitFileItems -SkipSizes:$SkipSizes)
    $os = @(Get-PckitOsItems -SkipSizes:$SkipSizes)
    $dev = @(Get-PckitDevItems)
    $store = @(Get-PckitStoreApps)

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($i in $apps) { $items.Add($i) }
    foreach ($i in $files) { $items.Add($i) }
    foreach ($i in $os) { $items.Add($i) }
    foreach ($i in $dev) { $items.Add($i) }

    if ($store.Count) {
        $items.Add([pscustomobject]@{
                Id = 'app.store'; Kind = 'app'; Title = 'Приложения Microsoft Store'; Subtitle = ('{0} шт. — ставятся из Store' -f $store.Count)
                Risk = 'low'; SizeMb = 0; Default = $false
                Meta = [pscustomobject]@{ Store = @($store | ForEach-Object { $_.Name }); Restore = 'note' }
            })
    }

    $osInfo = Get-CimInstance Win32_OperatingSystem
    $machine = [pscustomobject]@{
        Computer = $env:COMPUTERNAME
        User     = $env:USERNAME
        Caption  = [string]$osInfo.Caption
        Build    = [string]$osInfo.BuildNumber
        Locale   = (Get-Culture).Name
        TimeZone = (Get-TimeZone).Id
        Admin    = (Test-PckitAdmin)
        Created  = (Get-Date).ToString('s')
        Pckit    = $PckitVersion
    }

    return [pscustomobject]@{
        Machine = $machine
        Items   = $items.ToArray()
        Recipes = $recipes
    }
}
