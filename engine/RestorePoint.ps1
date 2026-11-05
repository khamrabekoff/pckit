#Requires -Version 5.1
# pckit engine | restore point: системная точка восстановления перед изменениями
# (идея из CleanPC 2.1: точка восстановления перед оптимизацией)

function Get-PckitRestorePoints {
    param([int]$Count = 5)

    $points = @()
    try {
        $points = @(Get-ComputerRestorePoint -ErrorAction Stop | Sort-Object -Property CreationTime -Descending | Select-Object -First $Count)
    } catch { }
    return $points
}

function New-PckitRestorePoint {
    param(
        [string]$Description = 'pckit by odilbek',
        [switch]$Run
    )

    $last = $null
    $points = Get-PckitRestorePoints -Count 1
    if ($points.Count) { $last = $points[0] }

    $recentMinutes = $null
    if ($last) {
        try {
            $created = [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$last.CreationTime)
            $recentMinutes = [math]::Round(((Get-Date) - $created).TotalMinutes, 0)
        } catch {
            try { $recentMinutes = [math]::Round(((Get-Date) - [datetime]$last.CreationTime).TotalMinutes, 0) } catch { }
        }
    }

    if (-not $Run) {
        return [pscustomobject]@{
            Status  = 'dry'
            Message = if ($last) { ('последняя точка: {0}' -f $last.Description) } else { 'точек восстановления нет' }
            Minutes = $recentMinutes
            Last    = $last
        }
    }

    if ($recentMinutes -ne $null -and $recentMinutes -lt 60) {
        return [pscustomobject]@{
            Status  = 'exists'
            Message = ('свежая точка уже есть ({0:N0} мин назад): {1}' -f $recentMinutes, $last.Description)
            Minutes = $recentMinutes
            Last    = $last
        }
    }

    # Windows создаёт точку не чаще раза в сутки (SystemRestorePointCreationFrequency, по умолчанию 1440 минут):
    # утренняя точка Windows Update иначе означала бы «изменения без свежей точки». Снимаем ограничение на время вызова.
    $srKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $freqName = 'SystemRestorePointCreationFrequency'
    $freqBefore = $null
    $freqSet = $false
    try {
        $item = Get-Item -LiteralPath $srKey -ErrorAction Stop
        if ($item.GetValueNames() -contains $freqName) { $freqBefore = $item.GetValue($freqName) }
        New-ItemProperty -LiteralPath $srKey -Name $freqName -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        $freqSet = $true
    } catch { }

    $enabledNow = $false
    try {
        try {
            Checkpoint-Computer -Description $Description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        } catch {
            # защита системы выключена — включаем на системном диске и пробуем ещё раз (пользователю об этом скажем)
            Enable-ComputerRestore -Drive ($env:SystemDrive + '\') -ErrorAction Stop
            $enabledNow = $true
            Checkpoint-Computer -Description $Description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        }
    } catch {
        return [pscustomobject]@{
            Status  = 'failed'
            Message = $_.Exception.Message
            Minutes = $recentMinutes
            Last    = $last
        }
    } finally {
        if ($freqSet) {
            try {
                if ($null -eq $freqBefore) { Remove-ItemProperty -LiteralPath $srKey -Name $freqName -Force -ErrorAction Stop }
                else { New-ItemProperty -LiteralPath $srKey -Name $freqName -Value $freqBefore -PropertyType DWord -Force -ErrorAction Stop | Out-Null }
            } catch { }
        }
    }

    $after = Get-PckitRestorePoints -Count 1
    $createdNow = $false
    if ($after.Count) {
        try {
            $created = [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$after[0].CreationTime)
            $createdNow = (((Get-Date) - $created).TotalMinutes -lt 5)
        } catch {
            try { $createdNow = (((Get-Date) - [datetime]$after[0].CreationTime).TotalMinutes -lt 5) } catch { }
        }
    }

    return [pscustomobject]@{
        Status  = if ($createdNow) { 'created' } else { 'throttled' }
        Message = if ($createdNow) { 'точка восстановления создана' + $(if ($enabledNow) { ' (включил защиту системы на диске ' + $env:SystemDrive + ')' } else { '' }) } else { 'Windows не создал точку' }
        EnabledNow = $enabledNow
        Minutes = $recentMinutes
        Last    = if ($after.Count) { $after[0] } else { $last }
    }
}
