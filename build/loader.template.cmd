<# :
@echo off
setlocal
set "PCKIT_SELF=%~f0"
title pckit by odilbek
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create([IO.File]::ReadAllText($env:PCKIT_SELF, [Text.Encoding]::UTF8)))"
if errorlevel 1 pause
exit /b
#>
$ErrorActionPreference = 'Stop'

$self = $env:PCKIT_SELF
if (-not $self -or -not (Test-Path -LiteralPath $self)) { throw 'не найден файл программы (PCKIT_SELF)' }

Write-Host ''
Write-Host '  pckit by odilbek' -ForegroundColor Cyan
Write-Host '  подготовка...' -ForegroundColor DarkGray

$b64 = '@@B64@@'

Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
$bytes = [Convert]::FromBase64String(($b64 -replace '\s', ''))
$dir = Join-Path $env:LOCALAPPDATA 'pckit\app-@@HASH10@@'

# файл не должен быть повреждён при копировании (флешка, мессенджер)
$sha = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)) -replace '-', '').ToLower()
if ($sha -ne '@@SHA@@') { throw 'файл повреждён: контрольная сумма не совпала. Скачайте или скопируйте его заново.' }

$memory = New-Object System.IO.MemoryStream
$memory.Write($bytes, 0, $bytes.Length)
$memory.Position = 0
$zip = New-Object System.IO.Compression.ZipArchive($memory, [System.IO.Compression.ZipArchiveMode]::Read)
try {
    # уже распакованная копия сверяется с архивом при каждом запуске: если антивирус убрал файл
    # или его кто-то подменил, ставим заново (файлы потом запускаются с правами администратора)
    $intact = Test-Path -LiteralPath (Join-Path $dir 'pckit-ui.ps1')
    if ($intact) {
        foreach ($entry in $zip.Entries) {
            if ([string]::IsNullOrEmpty($entry.Name)) { continue }
            $f = Join-Path $dir ($entry.FullName -replace '/', '\')
            if (-not (Test-Path -LiteralPath $f) -or (Get-Item -LiteralPath $f).Length -ne $entry.Length) { $intact = $false; break }
            $ms = New-Object System.IO.MemoryStream
            $es = $entry.Open()
            try { $es.CopyTo($ms) } finally { $es.Dispose() }
            $a = $ms.ToArray(); $ms.Dispose()
            $disk = [IO.File]::ReadAllBytes($f)
            for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $disk[$i]) { $intact = $false; break } }
            if (-not $intact) { break }
        }
    }

    if (-not $intact) {
        # распаковываем во временную папку и переименовываем: оборванная распаковка не оставит битую установку
        $tmp = $dir + '.tmp-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        foreach ($entry in $zip.Entries) {
            $target = [IO.Path]::GetFullPath((Join-Path $tmp ($entry.FullName -replace '/', '\')))
            if (-not $target.StartsWith($tmp + '\', [StringComparison]::OrdinalIgnoreCase)) { throw ('небезопасный путь в архиве: ' + $entry.FullName) }
            if ([string]::IsNullOrEmpty($entry.Name)) {
                New-Item -ItemType Directory -Force -Path $target | Out-Null
                continue
            }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        Move-Item -LiteralPath $tmp -Destination $dir
    }
} finally {
    $zip.Dispose()
    $memory.Dispose()
}

# старые версии приложения не копим (оставляем текущую и одну предыдущую)
try {
    Get-ChildItem -LiteralPath (Split-Path -Parent $dir) -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $dir } | Sort-Object LastWriteTime -Descending | Select-Object -Skip 1 |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
} catch { }

$exe = Join-Path $dir 'pckit-ui.ps1'
if ($env:PCKIT_NO_LAUNCH) {
    Write-Host ('  распаковано в ' + $dir) -ForegroundColor Green
    return
}

try {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $exe + '"')
} catch {
    Write-Host ''
    Write-Host '  Не получилось запустить с правами администратора (окно UAC было закрыто?).' -ForegroundColor Yellow
    Write-Host '  Без этих прав нельзя чистить систему и менять настройки. Запустите файл ещё раз и нажмите «Да».' -ForegroundColor Yellow
    exit 1
}