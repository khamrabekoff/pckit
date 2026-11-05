#Requires -Version 5.1
# pckit tests | engine\Clean.ps1: цели, размеры, Kind files/info/dism, Chromium-хелпер
# Удаление проверяется только на искусственных папках в $env:TEMP\pckit-clean-test.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'engine\Common.ps1')
. (Join-Path $root 'engine\Clean.ps1')

$script:fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host ('PASS  ' + $Name) }
    else { Write-Host ('FAIL  ' + $Name + $(if ($Detail) { '  -> ' + $Detail })); $script:fail++ }
}

# --- 1. список целей ---
$targets = $null
try { $targets = @(Get-PckitCleanTargets); Check 'Get-PckitCleanTargets без исключений' $true }
catch { Check 'Get-PckitCleanTargets без исключений' $false $_.Exception.Message; exit 1 }

$ids = @($targets | ForEach-Object { $_.Id })
Check 'Id уникальны' (($ids | Select-Object -Unique).Count -eq $ids.Count)
$bad = @($targets | Where-Object { -not $_.Title -or -not $_.What -or $_.Risk -notin 'low', 'medium' })
Check 'у всех Title/What и Risk low|medium' ($bad.Count -eq 0) (($bad | ForEach-Object Id) -join ',')
$bad = @($targets | Where-Object { $_.Kind -notin 'dir', 'recycle', 'files', 'dism', 'info', 'drivers' })
Check 'Kind допустимый' ($bad.Count -eq 0) (($bad | ForEach-Object Id) -join ',')
$bad = @($targets | Where-Object { $_.Kind -eq 'files' -and @($_.Patterns).Count -eq 0 })
Check "у Kind 'files' есть Patterns" ($bad.Count -eq 0) (($bad | ForEach-Object Id) -join ',')
foreach ($id in 'shader.nvidia', 'shader.dx', 'shader.amd', 'steam.shader') {
    $t = $targets | Where-Object Id -eq $id
    if ($t) { Check ("$id Risk medium") ($t.Risk -eq 'medium') }
}
foreach ($id in 'thumbs.cache', 'windows.logs', 'winsxs.cleanup') {
    Check ("цель $id есть") (@($targets | Where-Object Id -eq $id).Count -eq 1)
}
$dismT = $targets | Where-Object Id -eq 'winsxs.cleanup'
Check 'winsxs.cleanup: dism, Admin, low' ($dismT.Kind -eq 'dism' -and $dismT.Admin -and $dismT.Risk -eq 'low')

# --- 2. размеры по реальным целям (только чтение) ---
$sizes = $null
try { $sizes = @(Get-PckitCleanSizes -Targets $targets); Check 'Get-PckitCleanSizes без исключений' $true }
catch { Check 'Get-PckitCleanSizes без исключений' $false $_.Exception.Message }
if ($sizes) {
    $d = $sizes | Where-Object { $_.Target.Kind -eq 'dism' }
    Check 'dism: SizeMb = -1' (@($d).Count -gt 0 -and @($d | Where-Object { $_.SizeMb -ne -1 }).Count -eq 0)
    Write-Host ''
    Write-Host 'Id / Kind / Risk / SizeMb / Files'
    foreach ($s in $sizes) { Write-Host ('  {0,-18} {1,-8} {2,-7} {3,10} {4,8}' -f $s.Target.Id, $s.Target.Kind, $s.Target.Risk, $s.SizeMb, $s.Files) }
    Write-Host ''
}

# --- 3. dry-run по реальным целям ---
try {
    $dry = Invoke-PckitClean -Targets $targets
    Check 'Invoke-PckitClean (dry) без исключений' $true
    $expect = [math]::Round((($dry.Results | Where-Object { $_.FreedMb -gt 0 } | Measure-Object FreedMb -Sum).Sum), 1)
    Check 'dry: FreedMb не учитывает -1' ($dry.FreedMb -ge 0 -and [math]::Abs($dry.FreedMb - $expect) -lt 0.5) ('{0} vs {1}' -f $dry.FreedMb, $expect)
    Check 'dry: статус всех целей dry' (@($dry.Results | Where-Object Status -ne 'dry').Count -eq 0)
} catch { Check 'Invoke-PckitClean (dry) без исключений' $false $_.Exception.Message }

# --- 4. искусственная структура ---
$base = Join-Path $env:TEMP 'pckit-clean-test'
if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
try {
    $ud = Join-Path $base 'User Data'
    $files = @{
        'User Data\Default\Cache\Cache_Data\x'     = 'x'
        'User Data\Default\Code Cache\js\z'        = 'z'
        'User Data\Default\GPUCache\g'             = 'g'
        'User Data\Default\Bookmarks'              = 'keep'
        'User Data\Profile 1\Code Cache\y'         = 'y'
        'User Data\Profile 1\Cache\old'            = 'old'
        'User Data\Profile 1\Cookies'              = 'keep'
        'User Data\Guest Profile\GPUCache\q'       = 'q'
        'User Data\System Profile\GPUCache\sys'    = 'keep'
        'User Data\Local State'                    = 'keep'
        'Explorer\thumbcache_1.db'                 = 't'
        'Explorer\iconcache_16.db'                 = 'i'
        'Explorer\a.db'                            = 'keep'
        'Explorer\sub\thumbcache_2.db'             = 'keep'
        'Info\data.bin'                            = 'keep'
    }
    foreach ($k in $files.Keys) {
        $f = Join-Path $base $k
        New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
        Set-Content -LiteralPath $f -Value $files[$k]
    }

    $paths = @(Get-PckitChromiumCachePaths -UserDataRoot $ud)
    Check 'Chromium-хелпер: 3 профиля, Default+Profile 1+Guest' ($paths.Count -eq 6) ($paths -join '; ')
    Check 'Chromium-хелпер: System Profile не берётся' (-not ($paths -match 'System Profile'))
    Check 'Chromium-хелпер: Cache_Data вместо Cache там, где он есть' (($paths -contains (Join-Path $ud 'Default\Cache\Cache_Data')) -and ($paths -contains (Join-Path $ud 'Profile 1\Cache')))

    $chromeT = [pscustomobject]@{ Id = 't.chrome'; Title = 't'; What = 'w'; Paths = $paths; Risk = 'low'; Admin = $false; Kind = 'dir'; Note = ''; Patterns = @(); Link = '' }
    $filesT = [pscustomobject]@{ Id = 't.files'; Title = 't'; What = 'w'; Paths = @((Join-Path $base 'Explorer')); Risk = 'low'; Admin = $false; Kind = 'files'; Note = ''; Patterns = @('thumbcache_*.db', 'iconcache_*.db'); Link = '' }
    $infoT = [pscustomobject]@{ Id = 't.info'; Title = 't'; What = 'w'; Paths = @((Join-Path $base 'Info')); Risk = 'medium'; Admin = $true; Kind = 'info'; Note = ''; Patterns = @(); Link = 'ms-settings:storagepolicies' }

    $sz = Get-PckitCleanSize -Target $filesT
    Check "files: размер считает только совпавшие (2 файла)" ($sz.Files -eq 2) ('Files=' + $sz.Files)

    $r = Invoke-PckitClean -Targets @($chromeT, $filesT, $infoT) -Run
    $st = @{}; foreach ($x in $r.Results) { $st[$x.Target.Id] = $x }
    Check 'Run: chromium ok' ($st['t.chrome'].Status -eq 'ok')
    Check 'Run: files ok' ($st['t.files'].Status -eq 'ok' -and $st['t.files'].Deleted -eq 2)
    Check "Run: info -> 'skip' с сообщением" ($st['t.info'].Status -eq 'skip' -and $st['t.info'].Message -like '*Параметры Windows*')

    $gone = 'User Data\Default\Cache\Cache_Data\x', 'User Data\Default\Code Cache\js\z', 'User Data\Default\GPUCache\g',
    'User Data\Profile 1\Code Cache\y', 'User Data\Profile 1\Cache\old', 'User Data\Guest Profile\GPUCache\q',
    'Explorer\thumbcache_1.db', 'Explorer\iconcache_16.db'
    $kept = 'User Data\Default\Bookmarks', 'User Data\Profile 1\Cookies', 'User Data\System Profile\GPUCache\sys',
    'User Data\Local State', 'Explorer\a.db', 'Explorer\sub\thumbcache_2.db', 'Info\data.bin'
    $notGone = @($gone | Where-Object { Test-Path -LiteralPath (Join-Path $base $_) })
    $lost = @($kept | Where-Object { -not (Test-Path -LiteralPath (Join-Path $base $_)) })
    Check 'удалено всё нужное' ($notGone.Count -eq 0) ($notGone -join '; ')
    Check 'остальное на месте' ($lost.Count -eq 0) ($lost -join '; ')
    Check 'FreedMb не отрицателен' ($r.FreedMb -ge 0)
} catch {
    Check 'тест на искусственных папках без исключений' $false $_.Exception.Message
} finally {
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}
Check 'тестовая папка удалена' (-not (Test-Path -LiteralPath $base))

# --- 5. защита путей для Kind files ---
foreach ($sub in 'Logs\CBS', 'Logs\DISM', 'SoftwareDistribution\DataStore\Logs', 'Logs\WindowsUpdate') {
    $g = Test-PckitSafePath -Path (Join-Path $env:SystemRoot $sub) -AllowSystem
    Check ("Test-PckitSafePath -AllowSystem пропускает $sub") $g.Safe
}

Write-Host ''
if ($script:fail -gt 0) { Write-Host ('FAILED: {0}' -f $script:fail); exit 1 }
Write-Host 'ALL PASS'
exit 0
