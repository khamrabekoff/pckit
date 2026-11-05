#Requires -Version 5.1
# pckit engine | common helpers (dot-sourced by pckit.ps1)

# единая версия программы: окно, CLI, профили .pckit и сборка берут её отсюда
$script:PckitVersion = '2.3.0'
$script:PckitEngineDir = $PSScriptRoot

function Write-PckitLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('info', 'ok', 'warn', 'err', 'step')][string]$Level = 'info'
    )
    $prefix = switch ($Level) { 'ok' { '[ ok ]' } 'warn' { '[warn]' } 'err' { '[fail]' } 'step' { '[----]' } default { '      ' } }
    $color = switch ($Level) { 'ok' { 'Green' } 'warn' { 'Yellow' } 'err' { 'Red' } 'step' { 'Cyan' } default { 'Gray' } }
    Write-Host ('{0} {1}' -f $prefix, $Message) -ForegroundColor $color
}

function Get-PckitNormalizedName {
    param([string]$Text)
    if (-not $Text) { return '' }
    return ($Text.ToLower() -replace '[^a-z0-9а-яё]', '')
}

function Resolve-PckitPath {
    param([string]$Path)
    if (-not $Path) { return '' }
    $p = $Path.Trim().Trim('"')
    $p = [Environment]::ExpandEnvironmentVariables($p)
    if ($p -eq '~') { $p = $env:USERPROFILE }
    elseif ($p.StartsWith('~\')) { $p = Join-Path $env:USERPROFILE $p.Substring(2) }
    return $p.TrimEnd('\')
}

function Test-PckitSafePath {
    param([string]$Path, [switch]$AllowSystem)   # -AllowSystem: чистка кэша внутри Windows\Temp допустима
    $p = Resolve-PckitPath $Path
    if (-not $p) { return [pscustomobject]@{ Safe = $false; Reason = 'пустой путь' } }
    $full = $p
    if (Test-Path -LiteralPath $p) {
        try { $full = (Resolve-Path -LiteralPath $p).Path } catch { }
    }
    $tooWide = @(
        $env:SystemRoot,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData,
        $env:USERPROFILE,
        $env:APPDATA,
        $env:LOCALAPPDATA
    )
    foreach ($b in $tooWide) {
        if (-not $b) { continue }
        if ($full.TrimEnd('\') -ieq $b.TrimEnd('\')) {
            return [pscustomobject]@{ Safe = $false; Reason = ('слишком широкий путь: {0}' -f $b) }
        }
    }
    # только сама папка Windows и Program Files (раньше совпадало и с ...\Microsoft\Windows\Start Menu)
    foreach ($sys in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($AllowSystem) { break }
        if ($sys -and (($full.TrimEnd('\') -ieq $sys.TrimEnd('\')) -or (Test-PckitUnderRoot -Path $full -Root $sys))) {
            return [pscustomobject]@{ Safe = $false; Reason = ('системная папка: {0}' -f $sys) }
        }
    }
    if ($full -match '(?i)^[a-z]:\\?$') {
        return [pscustomobject]@{ Safe = $false; Reason = 'корень диска' }
    }
    return [pscustomobject]@{ Safe = $true; Reason = '' }
}

# папки пользователя, которые умеет сохранять pckit (Catalog и проверка чужого профиля в Planner)
function Get-PckitFileDefs {
    return @(
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
}

# куда восстановление может писать файлы: только внутри профиля пользователя и не в «Автозагрузку»
# (программа работает от администратора, а файл профиля может быть чужим)
function Test-PckitRestoreTarget {
    param([string]$Path)
    $p = Resolve-PckitPath $Path
    if (-not $p) { return [pscustomobject]@{ Safe = $false; Reason = 'пустой путь' } }
    if (-not (Test-PckitUnderRoot -Path $p -Root $env:USERPROFILE)) {
        return [pscustomobject]@{ Safe = $false; Reason = 'вне папки пользователя' }
    }
    foreach ($sf in @([Environment]::GetFolderPath('Startup'), (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'))) {
        if ($sf -and (($p.TrimEnd('\') -ieq $sf.TrimEnd('\')) -or (Test-PckitUnderRoot -Path $p -Root $sf))) {
            return [pscustomobject]@{ Safe = $false; Reason = 'папка «Автозагрузка»' }
        }
    }
    return (Test-PckitSafePath -Path $p)
}

function ConvertTo-PckitRegHiveName {
    param([string]$Key)
    $k = $Key.Trim().TrimEnd('\')
    $k = $k -replace '^(?i)HKCU(:)?\\', 'HKEY_CURRENT_USER\' -replace '^(?i)HKLM(:)?\\', 'HKEY_LOCAL_MACHINE\'
    return $k
}

# .reg из профиля трогает только свою ветку (и только HKCU): иначе чужой файл мог бы записать что угодно в HKLM от администратора
function Test-PckitRegFileScope {
    param([string]$Path, [string]$Key)
    $root = ConvertTo-PckitRegHiveName $Key
    if ($root -notmatch '^(?i)HKEY_CURRENT_USER\\Software\\.+') {
        return [pscustomobject]@{ Safe = $false; Reason = ('ветка не из HKCU\Software: {0}' -f $Key) }
    }
    $text = [IO.File]::ReadAllText($Path)
    foreach ($m in [regex]::Matches($text, '(?m)^\s*\[(-?)([^\]\r\n]+)\]')) {
        $sec = ConvertTo-PckitRegHiveName $m.Groups[2].Value
        if (-not (($sec -ieq $root) -or $sec.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase))) {
            return [pscustomobject]@{ Safe = $false; Reason = ('в файле есть чужая ветка: {0}' -f $sec) }
        }
    }
    return [pscustomobject]@{ Safe = $true; Reason = '' }
}

# переменные среды, через которые можно подсунуть код любой программе (или самой pckit) — из профиля не восстанавливаем
$script:PckitEnvDeny = '^(?i)(PATH|PATHEXT|COMSPEC|PSMODULEPATH|WINDIR|SYSTEMROOT|SYSTEMDRIVE|TEMP|TMP|USERPROFILE|APPDATA|LOCALAPPDATA|PROGRAMDATA|PROGRAMFILES.*|COR_.*|CORECLR_.*|COMPLUS_.*|DOTNET_.*|NODE_OPTIONS|NODE_PATH|JAVA_TOOL_OPTIONS|_JAVA_OPTIONS|JDK_JAVA_OPTIONS|PYTHONSTARTUP|PYTHONPATH|PYTHONHOME|PERL5OPT|PERL5LIB|RUBYOPT|GIT_SSH|GIT_SSH_COMMAND|GIT_EXEC_PATH|GIT_ASKPASS|SSH_ASKPASS|__PSLOCKDOWNPOLICY)$'
function Test-PckitEnvAllowed {
    param([string]$Name)
    return ($Name -match '^[A-Za-z_][A-Za-z0-9_]{0,100}$' -and $Name -notmatch $script:PckitEnvDeny)
}

function Test-PckitUnderRoot {
    # true, если Path лежит строго внутри Root (защита от ..\ и подмены путей из чужого профиля)
    param([string]$Path, [string]$Root)
    if (-not $Path -or -not $Root) { return $false }
    try {
        $sep = [IO.Path]::DirectorySeparatorChar   # на Windows GetFullPath и так приводит / к \
        $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
        $base = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + $sep
    } catch { return $false }
    return $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)
}

function Resolve-PckitPayload {
    # путь к файлу внутри распакованного профиля; бросает исключение, если он выходит за его пределы
    param([string]$ProfileRoot, [string]$Relative)
    if (-not $Relative) { return $null }
    $full = [IO.Path]::GetFullPath((Join-Path $ProfileRoot $Relative))
    if (-not (Test-PckitUnderRoot -Path $full -Root $ProfileRoot)) {
        throw ('путь вне профиля: {0}' -f $Relative)
    }
    return $full
}

# Команды восстановления берутся из файла профиля, а файл может быть чужим.
# Разрешены только известные шаблоны и простые аргументы — без метасимволов оболочки.
$script:PckitAllowedTemplates = @(
    'code --install-extension {line}'
)

function Test-PckitCommandTemplate {
    param([string]$Template)
    return ($script:PckitAllowedTemplates -contains $Template.Trim())
}

function Test-PckitCommandArg {
    param([string]$Text)
    return [bool]($Text -match '^[A-Za-z0-9][A-Za-z0-9_.@/=+\-]{0,200}$')
}

function Open-PckitUrl {
    # ссылки приходят и из чужого профиля: открываем только http(s), а не произвольный файл или программу
    param([string]$Url)
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin 'http', 'https') { return $false }
    Start-Process -FilePath $uri.AbsoluteUri
    return $true
}

function Test-PckitPathMatch {
    param([string]$RelativePath, [string[]]$Patterns)
    if (-not $Patterns) { return $false }
    $segments = $RelativePath -split '\\'
    foreach ($p in $Patterns) {
        if (-not $p) { continue }
        # шаблон с путём (user_data\cache) — от корня копируемой папки, вместе со всем содержимым
        if ($p -match '\\') {
            $pp = $p.Trim('\')
            if ($RelativePath -ieq $pp -or $RelativePath.StartsWith($pp + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
            continue
        }
        foreach ($s in $segments) {
            if ($p -match '[*?]') { if ($s -like $p) { return $true } }
            elseif ($s -ieq $p) { return $true }
        }
    }
    return $false
}

function Get-PckitFolderInfo {
    param(
        [string]$Path,
        [string[]]$Exclude = @()
    )
    $p = Resolve-PckitPath $Path
    if (-not $p -or -not (Test-Path -LiteralPath $p)) {
        return [pscustomobject]@{ Exists = $false; SizeMb = 0; FileCount = 0; Path = $p }
    }
    $sum = 0
    $count = 0
    $files = Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        if ($Exclude.Count) {
            $rel = $f.FullName.Substring($p.Length).TrimStart('\')
            if (Test-PckitPathMatch -RelativePath $rel -Patterns $Exclude) { continue }
        }
        $sum += $f.Length
        $count++
    }
    return [pscustomobject]@{
        Exists    = $true
        SizeMb    = [math]::Round($sum / 1MB, 2)
        FileCount = $count
        Path      = $p
    }
}

function New-PckitTempDir {
    param([string]$Prefix = 'pckit')
    $dir = Join-Path $env:TEMP ('{0}-{1}' -f $Prefix, [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

function ConvertTo-PckitJson {
    param($Object)
    return ($Object | ConvertTo-Json -Depth 12)
}

function Read-PckitJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Save-PckitJson {
    param([string]$Path, $Object)
    $json = ConvertTo-PckitJson $Object
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-PckitAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PckitFreeSpaceMb {
    param([string]$Path)
    try {
        $root = [IO.Path]::GetPathRoot($Path)
        $drive = Get-PSDrive -Name $root.Substring(0, 1) -ErrorAction SilentlyContinue
        if ($drive) { return [math]::Round($drive.Free / 1MB, 0) }
    } catch { }
    return $null
}

function Format-PckitSize {
    param([double]$Mb)
    if ($Mb -ge 1024) { return ('{0:N1} ГБ' -f ($Mb / 1024)) }
    return ('{0:N0} МБ' -f $Mb)
}
function ConvertFrom-PckitSizeText {
    # «1 023 МБ» / «2,5 ГБ» -> мегабайты; пробелы-разделители тысяч (в том числе неразрывные) не ломают разбор
    param([string]$Text)
    if ($Text -notmatch '([\d\s  .,]*\d)\s*(ГБ|МБ)') { return 0.0 }
    $num = ($matches[1] -replace '[\s  ]', '') -replace ',', '.'
    $mb = 0.0
    if (-not [double]::TryParse($num, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$mb)) { return 0.0 }
    if ($matches[2] -eq 'ГБ') { $mb *= 1024 }
    return $mb
}

function Get-PckitManualAppInfo {
    param([string]$Title)

    if (-not $script:PckitManualApps) {
        $script:PckitManualApps = @()
        $file = Join-Path (Split-Path -Parent $script:PckitEngineDir) 'data\manual-apps.json'
        if (Test-Path -LiteralPath $file) {
            try {
                $raw = Get-Content -LiteralPath $file -Raw -Encoding UTF8
                $parsed = ConvertFrom-Json $raw
                $script:PckitManualApps = @($parsed)
            } catch { }
        }
    }
    foreach ($entry in $script:PckitManualApps) {
        if (-not $entry.pattern) { continue }
        try { if ($Title -match $entry.pattern) { return $entry } } catch { }
    }
    return $null
}