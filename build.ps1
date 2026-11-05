#Requires -Version 5.1
# pckit | сборка одного файла dist\pckit-by-odilbek.cmd (загрузчик + ZIP в base64)
# Запуск: powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$dist = Join-Path $root 'dist'
$template = Join-Path $root 'build\loader.template.cmd'

# что кладём в архив (всё остальное — сборка, тесты, состояние — не нужно пользователю)
$include = @('pckit-ui.ps1', 'pckit.ps1', 'PCKIT.md', 'engine', 'data', 'recipes')

Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

# 1. проверка синтаксиса всех скриптов до сборки
$bad = 0
foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -Filter '*.ps1' | Where-Object { $_.FullName -notmatch '\\(dist|tests|build)\\' }) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
    foreach ($e in @($errors)) { $bad++; Write-Host ('  ошибка: {0}:{1} {2}' -f $f.Name, $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red }
    $head = [IO.File]::ReadAllBytes($f.FullName)
    if ($head.Length -lt 3 -or $head[0] -ne 0xEF -or $head[1] -ne 0xBB -or $head[2] -ne 0xBF) {
        $bad++; Write-Host ('  нет UTF-8 BOM: {0} (кириллица сломается в PowerShell 5.1)' -f $f.Name) -ForegroundColor Red
    }
}
foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -Filter '*.json' | Where-Object { $_.FullName -notmatch '\\(dist|tests|build|state)\\' }) {
    try { [void](Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { $bad++; Write-Host ('  битый JSON: {0} — {1}' -f $f.Name, $_.Exception.Message) -ForegroundColor Red }
}
if ($bad) { throw "сборка остановлена: ошибок $bad" }

# 2. ZIP в памяти, имена записей через '/', фиксированная дата — одинаковые исходники дают одинаковый хэш
$files = New-Object System.Collections.ArrayList
foreach ($name in $include) {
    $path = Join-Path $root $name
    if (-not (Test-Path -LiteralPath $path)) { throw "нет $name" }
    if ((Get-Item -LiteralPath $path).PSIsContainer) {
        foreach ($f in Get-ChildItem -LiteralPath $path -Recurse -File) { [void]$files.Add($f.FullName) }
    } else { [void]$files.Add((Resolve-Path -LiteralPath $path).Path) }
}
$sorted = @($files | Sort-Object)

$memory = New-Object System.IO.MemoryStream
$zip = New-Object System.IO.Compression.ZipArchive($memory, [System.IO.Compression.ZipArchiveMode]::Create, $true)
try {
    foreach ($full in $sorted) {
        $rel = $full.Substring($root.Length).TrimStart('\') -replace '\\', '/'
        $entry = $zip.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = [DateTimeOffset]::new(2026, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
        $stream = $entry.Open()
        try { $bytes = [IO.File]::ReadAllBytes($full); $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }
} finally { $zip.Dispose() }
$payload = $memory.ToArray()
$memory.Dispose()

$sha = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($payload)) -replace '-', '').ToLower()
$b64 = [Convert]::ToBase64String($payload)

# 3. загрузчик: только ASCII в строках cmd, UTF-8 без BOM, CRLF
$loader = [IO.File]::ReadAllText($template, [Text.Encoding]::UTF8)
$loader = $loader.Replace('@@B64@@', $b64).Replace('@@SHA@@', $sha).Replace('@@HASH10@@', $sha.Substring(0, 10))
$loader = ($loader -replace "`r?`n", "`r`n")
if ($loader -match '@@\w+@@') { throw 'в шаблоне остались незаменённые метки' }

New-Item -ItemType Directory -Force -Path $dist | Out-Null
$out = Join-Path $dist 'pckit-by-odilbek.cmd'
[IO.File]::WriteAllText($out, $loader, (New-Object System.Text.UTF8Encoding($false)))

$cmdSha = (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash
$readme = @"
pckit by odilbek — как пользоваться

1. Положите файл pckit-by-odilbek.cmd на рабочий стол и запустите двойным щелчком.
2. Windows спросит разрешение (UAC) — нажмите «Да». Права администратора нужны для чистки и настроек.
3. Если SmartScreen пишет «Windows защитила ваш компьютер» — «Подробнее» → «Выполнить в любом случае» (файл не подписан цифровой подписью).

Что умеет: ускорить ПК для игр, почистить кэши, замерить результат «до и после», сохранить программы и настройки в один файл .pckit и вернуть их после переустановки Windows, проверить состояние ПК.
Перед изменениями программа создаёт точку восстановления и пишет журнал: всё отменяется кнопкой «Отменить изменения».

Файл .pckit не шифруется (там могут быть ключи и пароли Wi-Fi) — не отправляйте его другим.

Контрольная сумма (SHA-256) файла pckit-by-odilbek.cmd:
$cmdSha
Файл проверяет сам себя при запуске.
"@
[IO.File]::WriteAllText((Join-Path $dist 'README.txt'), ($readme -replace "`r?`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))

Write-Host ('  собрано: {0}  ({1:N0} КБ, файлов в архиве: {2})' -f $out, ((Get-Item -LiteralPath $out).Length / 1KB), $sorted.Count) -ForegroundColor Green
Write-Host ('  payload sha256: {0}' -f $sha) -ForegroundColor DarkGray
