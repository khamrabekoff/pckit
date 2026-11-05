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

function Test-PckitRestoreEnabled {
    param([string]$Drive = $env:SystemDrive)

    try {
        $sessions = @(Get-CimInstance -Namespace 'root\default' -ClassName SystemRestore -ErrorAction Stop)
        foreach ($s in $sessions) {
            if ([string]$s.Description -match [regex]::Escape($Drive)) { return $true }
        }
    } catch { }
    return $false
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

    $enabled = Test-PckitRestoreEnabled
    if (-not $enabled) {
        try { Enable-ComputerRestore -Drive ($env:SystemDrive + '\') -ErrorAction Stop } catch { }
    }

    try {
        Checkpoint-Computer -Description $Description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
    } catch {
        return [pscustomobject]@{
            Status  = 'failed'
            Message = $_.Exception.Message
            Minutes = $recentMinutes
            Last    = $last
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
        Message = if ($createdNow) { 'точка восстановления создана' } else { 'Windows не создал точку: не чаще одного раза в сутки' }
        Minutes = $recentMinutes
        Last    = if ($after.Count) { $after[0] } else { $last }
    }
}
