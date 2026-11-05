#Requires -Version 5.1
# тест движка автозагрузки: реальная автозагрузка только читается, запись — в HKCU:\Software\pckit-test
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:PckitEngineDir = Join-Path $root 'engine'
. (Join-Path $root 'engine\Common.ps1')
. (Join-Path $root 'engine\Journal.ps1')
. (Join-Path $root 'engine\Startup.ps1')
$script:PckitStateRoot = Join-Path $env:TEMP 'pckit-startup-test-state'
New-Item -ItemType Directory -Force -Path $script:PckitStateRoot | Out-Null

$pass = 0; $fail = 0
function Check([string]$Name, [bool]$Ok) {
    if ($Ok) { $script:pass++; Write-Host ('PASS  ' + $Name) -ForegroundColor Green }
    else { $script:fail++; Write-Host ('FAIL  ' + $Name) -ForegroundColor Red }
}

# 1. разбор командной строки
Check 'exe в кавычках' ((Get-PckitStartupExe '"C:\Program Files\App\app.exe" --min') -eq 'C:\Program Files\App\app.exe')
Check 'exe без кавычек с аргументами' ((Get-PckitStartupExe 'C:\Tools\x.exe /silent') -eq 'C:\Tools\x.exe')
Check 'переменные среды' ((Get-PckitStartupExe '%windir%\system32\a.exe') -eq (Join-Path $env:windir 'system32\a.exe'))

# 2. советы
Check 'Discord — можно отключить' ((Get-PckitStartupAdvice -Name 'Discord' -Exe 'C:\x\Update.exe' -Publisher 'Discord Inc.').Advice -eq 'можно отключить')
Check 'FACEIT — нужно' ((Get-PckitStartupAdvice -Name 'FACEIT' -Exe 'C:\x\faceit.exe' -Publisher 'FACEIT').Advice -eq 'нужно')
Check 'SecurityHealth — нужно' ((Get-PckitStartupAdvice -Name 'SecurityHealth' -Exe 'C:\Windows\system32\SecurityHealthSystray.exe' -Publisher 'Microsoft').Advice -eq 'нужно')
Check 'неизвестное — на усмотрение' ((Get-PckitStartupAdvice -Name 'FooBar' -Exe 'C:\x\foo.exe' -Publisher 'Foo').Advice -eq 'на ваше усмотрение')

# 3. реальный список (только чтение)
$entries = @(Get-PckitStartupEntries)
Check 'список автозагрузки читается' ($null -ne $entries)
Check 'у каждой записи есть путь StartupApproved' (@($entries | Where-Object { -not $_.ApprovedPath }).Count -eq 0)
Check 'записи — объекты, а не вложенный массив' (@($entries | Where-Object { $_ -is [array] }).Count -eq 0)
foreach ($e in $entries) { Write-Host ('      {0,-34} {1,-9} {2,-20} {3}' -f $e.Name, $(if ($e.Enabled) { 'вкл' } else { 'выкл' }), $e.Advice, $e.Publisher) -ForegroundColor DarkGray }

# 4. выключить/включить и откат — на фиктивной записи в тестовой ветке
$testKey = 'HKCU:\Software\pckit-test\StartupApproved\Run'
Remove-Item -LiteralPath 'HKCU:\Software\pckit-test' -Recurse -Force -ErrorAction SilentlyContinue
$fake = [pscustomobject]@{ Name = 'FakeApp'; ApprovedPath = $testKey; ApprovedName = 'FakeApp'; Enabled = $true }
Check 'нет записи = включено' (Get-PckitApprovedState -ApprovedPath $testKey -Name 'FakeApp')

$j = New-PckitJournal
$r = Set-PckitStartupEnabled -Entry $fake -Enabled $false -Journal $j
Check 'отключение записано' ($r.Status -eq 'ok')
Check 'после отключения — выключено' (-not (Get-PckitApprovedState -ApprovedPath $testKey -Name 'FakeApp'))
$val = (Get-Item -LiteralPath $testKey).GetValue('FakeApp')
Check 'формат как у Диспетчера задач (12 байт, 03)' ($val.Length -eq 12 -and $val[0] -eq 3)
Check 'журнал помнит, что записи не было' (@($j.registry).Count -eq 1 -and -not $j.registry[0].existed)

$res = Restore-PckitJournal -Journal $j -Run
Check 'откат без ошибок' ($res.Failed -eq 0)
Check 'после отката снова включено' (Get-PckitApprovedState -ApprovedPath $testKey -Name 'FakeApp')

$fake.Enabled = $false
New-ItemProperty -LiteralPath $testKey -Name 'FakeApp' -Value ([byte[]](3, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8)) -PropertyType Binary -Force | Out-Null
$j2 = New-PckitJournal
[void](Set-PckitStartupEnabled -Entry $fake -Enabled $true -Journal $j2)
Check 'включение записано (02)' ((Get-Item -LiteralPath $testKey).GetValue('FakeApp')[0] -eq 2)
[void](Restore-PckitJournal -Journal $j2 -Run)
Check 'откат вернул прежние байты' ((Get-Item -LiteralPath $testKey).GetValue('FakeApp')[4] -eq 1)

Remove-Item -LiteralPath 'HKCU:\Software\pckit-test' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $script:PckitStateRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ('Итого: PASS {0}, FAIL {1}' -f $pass, $fail)
if ($fail) { exit 1 }
