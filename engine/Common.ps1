#Requires -Version 5.1
# pckit engine | common helpers (dot-sourced by pckit.ps1)

$script:PckitVersion = '0.2.0'
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

function Test-PckitUnderRoot {
    # true, если Path лежит строго внутри Root (защита от ..\ и подмены путей из чужого профиля)
    param([string]$Path, [string]$Root)
    if (-not $Path -or -not $Root) { return $false }
    try {
        $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
        $base = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
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