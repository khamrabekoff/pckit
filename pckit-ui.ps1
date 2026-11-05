#Requires -Version 5.1
<#
    pckit-ui.ps1 — окно выбора: что сохранить с этого ПК.

    Запуск:  .\pckit-ui.ps1
    Самопроверка без показа окна (рендер в PNG):  .\pckit-ui.ps1 -SelfTest
#>
[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$Headless,
    [string]$PackTo,
    [int]$Tab = 1,
    [switch]$ApplyTest,
    [string]$SelfTestPath,
    [string]$SelfTestSize = '1120x740'
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
# стили Windows (группы в списках, современные кнопки) — только если включить ДО создания первого элемента окна
[System.Windows.Forms.Application]::EnableVisualStyles()
# чёткий текст на мониторах с масштабом 125–200%: объявляем процесс DPI-aware до создания окна
try {
    Add-Type -Namespace PckitNative -Name Dpi -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -ErrorAction Stop
    [void][PckitNative.Dpi]::SetProcessDPIAware()
} catch { }

$ErrorActionPreference = 'Stop'
$script:Root = $PSScriptRoot
if (-not $SelfTestPath) { $SelfTestPath = Join-Path $script:Root 'state\ui-selftest.png' }

# окно работает с правами администратора: иначе чистка и игры не смогут менять настройки
$isAdminNow = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdminNow -and -not $SelfTest -and -not $Headless) {
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
            # путь в кавычках: в «D:\Climadens\Ai Projects\...» есть пробел, без них перезапуск не находит файл
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath)
        ) | Out-Null
        return
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Без прав администратора программа не сможет чистить и настраивать систему.',
            'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
}

# ------------------------------------------------------------------- журнал ошибок и защита от падений
. (Join-Path $script:Root 'engine\Common.ps1')
$script:PckitAppVersion = $script:PckitVersion
$script:LogDir = Join-Path $env:LOCALAPPDATA 'pckit\logs'
try { if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null } } catch { }
$script:LogFile = Join-Path $script:LogDir ('pckit-{0}.log' -f (Get-Date).ToString('yyyy-MM-dd'))

function Write-UiLog {
    param([string]$Message, [string]$Level = 'info')
    try {
        $line = '{0} [{1}] {2}' -f (Get-Date).ToString('HH:mm:ss'), $Level, $Message
        [IO.File]::AppendAllText($script:LogFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
    } catch { }
}

# старые логи (старше 30 дней) не копим
try { Get-ChildItem -LiteralPath $script:LogDir -Filter 'pckit-*.log' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | Remove-Item -Force -ErrorAction SilentlyContinue } catch { }
Write-UiLog ('запуск pckit {0} · Windows {1} · PowerShell {2}' -f $script:PckitAppVersion, [Environment]::OSVersion.Version, $PSVersionTable.PSVersion)

# любая ошибка в кнопке — понятное окно и запись в лог, программа продолжает работать
$script:CrashShown = $false
function Show-UiCrash {
    param($Exception)
    $msg = if ($Exception) { [string]$Exception.Message } else { 'неизвестная ошибка' }
    Write-UiLog ("ОШИБКА: {0}`r`n{1}" -f $msg, $(if ($Exception) { $Exception.ToString() } else { '' })) 'err'
    if ($script:CrashShown) { return }
    $script:CrashShown = $true
    try {
        $a = [System.Windows.Forms.MessageBox]::Show(
            ("Что-то пошло не так:`r`n{0}`r`n`r`nПрограмма продолжит работать, ваши настройки не пострадали — все изменения записаны в журнал и отменяются кнопкой «Вернуть как было».`r`n`r`nСохранить отчёт об ошибке на Рабочий стол, чтобы отправить разработчику?" -f $msg),
            'pckit by odilbek — ошибка', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Error)
        if ($a -eq [System.Windows.Forms.DialogResult]::Yes) { Save-UiLogBundle | Out-Null }
    } finally { $script:CrashShown = $false }
}

# все логи pckit одним файлом на Рабочий стол
function Save-UiLogBundle {
    try {
        $dest = Join-Path ([Environment]::GetFolderPath('Desktop')) ('pckit-лог-{0}.zip' -f (Get-Date).ToString('yyyy-MM-dd_HH-mm'))
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $tmp = Join-Path $env:TEMP ('pckit-log-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        Copy-Item -Path (Join-Path $script:LogDir '*.log') -Destination $tmp -ErrorAction SilentlyContinue
        $info = "pckit {0}`r`nWindows {1}`r`nPowerShell {2}`r`n" -f $script:PckitAppVersion, [Environment]::OSVersion.Version, $PSVersionTable.PSVersion
        [IO.File]::WriteAllText((Join-Path $tmp 'версия.txt'), $info, (New-Object System.Text.UTF8Encoding($true)))
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
        [System.IO.Compression.ZipFile]::CreateFromDirectory($tmp, $dest)
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $dest)
        return $dest
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show(('Не удалось сохранить лог: ' + $_.Exception.Message), 'pckit by odilbek')
        return $null
    }
}

if (-not $SelfTest -and -not $Headless) {
    try { [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException) } catch { }
    [System.Windows.Forms.Application]::add_ThreadException({ param($s, $e) Show-UiCrash $e.Exception })
    [AppDomain]::CurrentDomain.add_UnhandledException({ param($s, $e) Write-UiLog ('СБОЙ: ' + [string]$e.ExceptionObject) 'err' })
}

# второй экземпляр не открываем: два окна одновременно меняли бы один журнал
if (-not $SelfTest -and -not $Headless) {
    $createdNew = $false
    $script:InstanceMutex = New-Object System.Threading.Mutex($true, 'Local\pckit-by-odilbek-ui', [ref]$createdNew)
    if (-not $createdNew) {
        [void][System.Windows.Forms.MessageBox]::Show('pckit уже открыт — посмотрите на панели задач.', 'pckit by odilbek',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
}

. (Join-Path $script:Root 'engine\Common.ps1')
. (Join-Path $script:Root 'engine\Recipes.ps1')
. (Join-Path $script:Root 'engine\Catalog.ps1')
. (Join-Path $script:Root 'engine\Packer.ps1')
. (Join-Path $script:Root 'engine\Planner.ps1')
. (Join-Path $script:Root 'engine\Journal.ps1')
. (Join-Path $script:Root 'engine\Actions.ps1')
. (Join-Path $script:Root 'engine\Health.ps1')
. (Join-Path $script:Root 'engine\Clean.ps1')
. (Join-Path $script:Root 'engine\RestorePoint.ps1')
. (Join-Path $script:Root 'engine\Applier.ps1')
. (Join-Path $script:Root 'engine\Snapshot.ps1')
. (Join-Path $script:Root 'engine\PresentMon.ps1')
. (Join-Path $script:Root 'engine\Startup.ps1')

$script:Catalog = $null
$script:Checked = New-Object 'System.Collections.Generic.HashSet[string]'
$script:ItemsById = @{}
$script:Suppress = $false
$script:Busy = $false

$GroupTitles = [ordered]@{
    'app'     = '📦  Программы'
    'appdata' = '🗂  Данные и настройки приложений'
    'files'   = '📁  Файлы и папки'
    'os'      = '⚙  Настройки Windows'
    'network' = '🌐  Сеть'
    'dev'     = '🛠  Для разработчика'
    'drivers' = '🔧  Драйверы'
}

# --------------------------------------------------------------------- form
$form = New-Object System.Windows.Forms.Form
$form.Text = ('pckit by odilbek · v{0}' -f $script:PckitAppVersion)
$form.Size = New-Object System.Drawing.Size(1120, 740)
$form.MinimumSize = New-Object System.Drawing.Size(1060, 600)   # уже — обрезаются ряды кнопок
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 252)
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
# маленький экран (1366×768) или масштаб 150%: окно не должно вылезать за край — подгоняем под рабочую область
$form.Add_Load({
        try {
            $wa = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
            if ($form.Width -gt $wa.Width -or $form.Height -gt $wa.Height) {
                $form.MinimumSize = New-Object System.Drawing.Size([Math]::Min($form.MinimumSize.Width, $wa.Width), [Math]::Min($form.MinimumSize.Height, $wa.Height))
                $form.Bounds = $wa
            }
        } catch { }
    })
$form.KeyPreview = $true
$form.Add_KeyDown({
        param($s, $e)
        # Ctrl+F — в строку поиска (вкладка «Сохранить»)
        if ($e.Control -and $e.KeyCode -eq 'F' -and $tabs.SelectedTab -eq $tabSave) { $search.Focus() | Out-Null; $e.SuppressKeyPress = $true }
    })

$header =New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = 62
$header.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($header)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Что сохранить?'
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
$title.Location = New-Object System.Drawing.Point(18, 10)
$title.AutoSize = $true
$header.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Отметьте нужное и нажмите «Собрать профиль». Файл потом восстановит всё на чистой Windows.'
$subtitle.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 120)
$subtitle.Location = New-Object System.Drawing.Point(20, 38)
$subtitle.AutoSize = $true
$header.Controls.Add($subtitle)

$search = New-Object System.Windows.Forms.TextBox
$search.Width = 230
$search.Location = New-Object System.Drawing.Point(600, 18)
$search.Anchor = 'Top,Right'
$search.AccessibleName = 'Поиск по пунктам'
$header.Controls.Add($search)

$searchHint = New-Object System.Windows.Forms.Label
$searchHint.Text = 'поиск'
$searchHint.ForeColor = [System.Drawing.Color]::Gray
$searchHint.Location = New-Object System.Drawing.Point(606, 21)
$searchHint.AutoSize = $true
$header.Controls.Add($searchHint)

$presetBox = New-Object System.Windows.Forms.ComboBox
$presetBox.DropDownStyle = 'DropDownList'
$presetBox.Width = 160
$presetBox.Location = New-Object System.Drawing.Point(840, 18)
$presetBox.Anchor = 'Top,Right'
[void]$presetBox.Items.AddRange(@('Своё', 'Минимум', 'Работа', 'Всё'))
$presetBox.SelectedIndex = 1
$presetBox.AccessibleName = 'Набор пунктов'
$header.Controls.Add($presetBox)

$presetLabel = New-Object System.Windows.Forms.Label
$presetLabel.Text = 'набор:'
$presetLabel.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 120)
$presetLabel.Location = New-Object System.Drawing.Point(790, 21)
$presetLabel.AutoSize = $true
$presetLabel.Anchor = 'Top,Right'
$header.Controls.Add($presetLabel)

# ------------------------------------------------------------- tree + details
$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'
$split.SplitterDistance = 660
$split.Panel1.Padding = New-Object System.Windows.Forms.Padding(12, 8, 6, 8)
$split.Panel2.Padding = New-Object System.Windows.Forms.Padding(6, 8, 12, 8)
$split.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 252)

$tree = New-Object System.Windows.Forms.TreeView
$tree.AccessibleName = 'Что сохранить'
$tree.Dock = 'Fill'
$tree.CheckBoxes = $true
$tree.FullRowSelect = $false
$tree.ShowLines = $false
$tree.ShowPlusMinus = $true
$tree.HideSelection = $false
$tree.BorderStyle = 'None'
$tree.BackColor = [System.Drawing.Color]::White
$tree.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$tree.ItemHeight = 24
$split.Panel1.Controls.Add($tree)

$detailsTitle = New-Object System.Windows.Forms.Label
$detailsTitle.Text = 'Выберите пункт слева'
$detailsTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
$detailsTitle.Dock = 'Top'
$detailsTitle.Height = 30
$detailsTitle.AutoEllipsis = $true
$split.Panel2.Controls.Add($detailsTitle)

$details = New-Object System.Windows.Forms.TextBox
$details.Multiline = $true
$details.ReadOnly = $true
$details.ScrollBars = 'Vertical'
$details.Dock = 'Fill'
$details.BorderStyle = 'FixedSingle'
$details.BackColor = [System.Drawing.Color]::White
$details.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$split.Panel2.Controls.Add($details)

$details.Text = @(
    'Как это работает:'
    ''
    '1. Слева — всё, что нашлось на компьютере, по группам.'
    '2. Галочка = сохранить. В строке виден размер.'
    '3. «Собрать профиль» — получится один файл *.pckit.'
    '   Скопируйте его на внешний диск.'
    '4. После переустановки Windows запустите:'
    '   .\pckit.ps1 apply -Profile my.pckit -Run'
    ''
    'Красным отмечены рискованные пункты (личные данные,'
    'привязка к системе), жёлтым — «осторожно».'
    'Нажмите на любой пункт слева, чтобы увидеть,'
    'что именно из него копируется.'
) -join "`r`n"
$details.BringToFront()

$form.Controls.Add($split)
$split.BringToFront()

# ------------------------------------------------------------------- footer
$footer = New-Object System.Windows.Forms.Panel
$footer.Dock = 'Bottom'
$footer.Height = 64
$footer.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($footer)
$footer.BringToFront()

$status = New-Object System.Windows.Forms.Label
$status.Text = 'Готово'
$status.Location = New-Object System.Drawing.Point(18, 12)
$status.AutoSize = $true
$status.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 80)
$footer.Controls.Add($status)

$statusInfo = New-Object System.Windows.Forms.Label
$statusInfo.Text = ''
$statusInfo.Location = New-Object System.Drawing.Point(18, 34)
$statusInfo.AutoSize = $true
$statusInfo.ForeColor = [System.Drawing.Color]::FromArgb(130, 130, 140)
$footer.Controls.Add($statusInfo)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Style = 'Marquee'
$progress.Width = 220
$progress.Height = 8
$progress.Location = New-Object System.Drawing.Point(430, 28)
$progress.Anchor = 'Bottom,Left'
$progress.Visible = $false
$footer.Controls.Add($progress)

$packButton = New-Object System.Windows.Forms.Button
$packButton.Text = 'Собрать профиль...'
$packButton.Width = 190
$packButton.Height = 36
$packButton.Location = New-Object System.Drawing.Point(880, 12)
$packButton.Anchor = 'Top,Right'
$packButton.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$packButton.ForeColor = [System.Drawing.Color]::White
$packButton.FlatStyle = 'Flat'
$packButton.FlatAppearance.BorderSize = 0
$packButton.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$footer.Controls.Add($packButton)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = 'Обновить'
$refreshButton.Width = 100
$refreshButton.Height = 30
$refreshButton.Location = New-Object System.Drawing.Point(770, 15)
$refreshButton.Anchor = 'Top,Right'
$refreshButton.FlatStyle = 'System'
$footer.Controls.Add($refreshButton)

$allButton = New-Object System.Windows.Forms.Button
$allButton.Text = 'Всё'
$allButton.Width = 70
$allButton.Height = 30
$allButton.Location = New-Object System.Drawing.Point(690, 15)
$allButton.Anchor = 'Top,Right'
$allButton.FlatStyle = 'System'
$footer.Controls.Add($allButton)

$noneButton = New-Object System.Windows.Forms.Button
$noneButton.Text = 'Ничего'
$noneButton.Width = 70
$noneButton.Height = 30
$noneButton.Location = New-Object System.Drawing.Point(614, 15)
$noneButton.Anchor = 'Top,Right'
$noneButton.FlatStyle = 'System'
$footer.Controls.Add($noneButton)

# ------------------------------------------------------------------- layout
$form.Controls.Remove($header)
$form.Controls.Remove($split)
$form.Controls.Remove($footer)

$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'
$layout.ColumnCount = 1
$layout.RowCount = 3
$layout.ColumnStyles.Clear()
[void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
$layout.RowStyles.Clear()
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 62)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 64)))

$header.Dock = 'Fill'
$split.Dock = 'Fill'
$footer.Dock = 'Fill'
$layout.Controls.Add($header, 0, 0)
$layout.Controls.Add($split, 0, 1)
$layout.Controls.Add($footer, 0, 2)
# ------------------------------------------------------------------ theme
# стиль Windows 11 (светлый): серый фон, белые карточки со скруглением, синий акцент
$script:Theme = @{
    Bg          = [System.Drawing.Color]::FromArgb(243, 243, 243)
    Sidebar     = [System.Drawing.Color]::FromArgb(238, 238, 238)
    Card        = [System.Drawing.Color]::White
    CardHover   = [System.Drawing.Color]::FromArgb(249, 249, 249)
    Border      = [System.Drawing.Color]::FromArgb(229, 229, 229)
    BorderBtn   = [System.Drawing.Color]::FromArgb(209, 209, 209)
    Accent      = [System.Drawing.Color]::FromArgb(0, 103, 192)
    AccentHover = [System.Drawing.Color]::FromArgb(25, 117, 197)
    Text        = [System.Drawing.Color]::FromArgb(27, 27, 27)
    Muted       = [System.Drawing.Color]::FromArgb(96, 96, 96)
    NavHover    = [System.Drawing.Color]::FromArgb(230, 230, 230)
}
$script:IconFont = 'Segoe MDL2 Assets'   # есть в Windows 10 и 11

function New-PckitRoundPath {
    param([System.Drawing.Rectangle]$Rect, [int]$Radius)
    $d = $Radius * 2
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($Rect.X, $Rect.Y, $d, $d, 180, 90)
    $path.AddArc($Rect.Right - $d, $Rect.Y, $d, $d, 270, 90)
    $path.AddArc($Rect.Right - $d, $Rect.Bottom - $d, $d, $d, 0, 90)
    $path.AddArc($Rect.X, $Rect.Bottom - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}

function Get-HomeGreeting {
    $h = (Get-Date).Hour
    if ($h -lt 5) { return 'Доброй ночи' }
    if ($h -lt 12) { return 'Доброе утро' }
    if ($h -lt 18) { return 'Добрый день' }
    return 'Добрый вечер'
}

# ------------------------------------------------------------------ home tab
$tabHome = New-Object System.Windows.Forms.TabPage
$tabHome.Text = '  Главная  '
$tabHome.BackColor = $script:Theme.Bg
$tabHome.AutoScroll = $true   # на низком экране карточки прокручиваются, а не обрезаются

$homeTitle = New-Object System.Windows.Forms.Label
$homeTitle.Text = (Get-HomeGreeting)
$homeTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 18)
$homeTitle.ForeColor = $script:Theme.Text
$homeTitle.Location = New-Object System.Drawing.Point(24, 14)
$homeTitle.AutoSize = $true
$tabHome.Controls.Add($homeTitle)

$homeStatus = New-Object System.Windows.Forms.Label
$homeStatus.Text = 'Проверяю состояние компьютера...'
$homeStatus.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$homeStatus.Location = New-Object System.Drawing.Point(26, 56)
$homeStatus.AutoSize = $true
$homeStatus.ForeColor = $script:Theme.Muted
$tabHome.Controls.Add($homeStatus)

$homeHw = New-Object System.Windows.Forms.Label
$homeHw.Text = ''
$homeHw.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$homeHw.Location = New-Object System.Drawing.Point(26, 80)
$homeHw.AutoSize = $true
$homeHw.ForeColor = $script:Theme.Muted
$tabHome.Controls.Add($homeHw)

$homeNext = New-Object System.Windows.Forms.LinkLabel
$homeNext.Text = ''
$homeNext.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$homeNext.Location = New-Object System.Drawing.Point(26, 98)
$homeNext.AutoSize = $true
$homeNext.LinkColor = $script:Theme.Accent
$homeNext.ActiveLinkColor = $script:Theme.Accent
$tabHome.Controls.Add($homeNext)
# экспертный режим больше не нужен: все разделы — в боковом меню
$homeExpertLink = New-Object System.Windows.Forms.LinkLabel
$homeExpertLink.Visible = $false
$tabHome.Controls.Add($homeExpertLink)

$homeProgress = New-Object System.Windows.Forms.Label
$homeProgress.Text = ''
$homeProgress.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$homeProgress.Location = New-Object System.Drawing.Point(26, 470)
$homeProgress.AutoSize = $true
$homeProgress.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 120)
$tabHome.Controls.Add($homeProgress)

function New-HomeCard {
    param(
        [string]$Icon,
        [string]$Title,
        [string]$Subtitle,
        [int]$Left,
        [int]$Top,
        [scriptblock]$OnClick
    )

    $card = New-Object System.Windows.Forms.Panel
    $card.Size = New-Object System.Drawing.Size(510, 150)
    $card.Location = New-Object System.Drawing.Point($Left, $Top)
    $card.BackColor = $script:Theme.Bg      # сама карточка рисуется скруглённой в Paint
    $card.Cursor = [System.Windows.Forms.Cursors]::Hand

    # иконка в «плашке» акцентного цвета, как в Параметрах Windows 11
    $iconLabel = New-Object System.Windows.Forms.Label
    $iconLabel.Text = $Icon
    $iconLabel.Font = New-Object System.Drawing.Font($script:IconFont, 18)
    $iconLabel.ForeColor = $script:Theme.Accent
    $iconLabel.BackColor = [System.Drawing.Color]::Transparent
    $iconLabel.TextAlign = 'MiddleCenter'
    $iconLabel.Location = New-Object System.Drawing.Point(20, 22)
    $iconLabel.Size = New-Object System.Drawing.Size(44, 44)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $Title
    $titleLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 12.5)
    $titleLabel.ForeColor = $script:Theme.Text
    $titleLabel.BackColor = [System.Drawing.Color]::Transparent
    $titleLabel.Location = New-Object System.Drawing.Point(80, 20)
    $titleLabel.AutoSize = $true

    $subLabel = New-Object System.Windows.Forms.Label
    $subLabel.Text = $Subtitle
    $subLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $subLabel.Location = New-Object System.Drawing.Point(81, 50)
    $subLabel.Size = New-Object System.Drawing.Size(400, 58)
    $subLabel.ForeColor = $script:Theme.Muted
    $subLabel.BackColor = [System.Drawing.Color]::Transparent

    $card.Add_Paint({
            param($s, $e)
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $rect = New-Object System.Drawing.Rectangle(0, 0, ($s.Width - 1), ($s.Height - 1))
            $path = New-PckitRoundPath -Rect $rect -Radius 8
            $hot = $script:CardHot.ContainsKey($s) -and $script:CardHot[$s]
            $fill = if ($hot) { $script:Theme.CardHover } else { $script:Theme.Card }
            $brush = New-Object System.Drawing.SolidBrush($fill)
            $g.FillPath($brush, $path)
            # фокус с клавиатуры — заметная акцентная рамка
            if ($s.Focused) { $pen = New-Object System.Drawing.Pen($script:Theme.Accent, 2) }
            else { $pen = New-Object System.Drawing.Pen($script:Theme.Border, 1) }
            $g.DrawPath($pen, $path)
            # плашка под иконкой
            $iconRect = New-Object System.Drawing.Rectangle(20, 22, 44, 44)
            $iconPath = New-PckitRoundPath -Rect $iconRect -Radius 8
            $iconBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(230, 240, 250))
            $g.FillPath($iconBrush, $iconPath)
            $brush.Dispose(); $pen.Dispose(); $iconBrush.Dispose(); $path.Dispose(); $iconPath.Dispose()
        })

    $card.Controls.Add($iconLabel)
    $card.Controls.Add($titleLabel)
    $card.Controls.Add($subLabel)

    # действие храним в Tag: обработчик не зависит от переменных функции
    $card.Tag = $OnClick
    $iconLabel.Tag = $OnClick
    $titleLabel.Tag = $OnClick
    $subLabel.Tag = $OnClick

    $click = {
        param($sender, $e)
        $action = $sender.Tag
        if (-not $action -and $sender.Parent) { $action = $sender.Parent.Tag }
        if (-not $action) { return }
        try {
            & $action
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show(
                ('Не удалось выполнить действие: ' + $_.Exception.Message),
                'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    }
    $card.Add_Click($click)
    $iconLabel.Add_Click($click)
    $titleLabel.Add_Click($click)
    $subLabel.Add_Click($click)

    # клавиатура и экранный диктор: карточка — полноценная кнопка (Tab, Enter, Space), с заметным фокусом
    $card.TabStop = $true
    $card.AccessibleRole = [System.Windows.Forms.AccessibleRole]::PushButton
    $card.AccessibleName = $Title
    $card.AccessibleDescription = $Subtitle
    foreach ($child in @($iconLabel, $titleLabel, $subLabel)) { $child.AccessibleRole = [System.Windows.Forms.AccessibleRole]::None }
    $card.Add_Enter({ param($s, $e) $s.Invalidate($true) })
    $card.Add_Leave({ param($s, $e) $s.Invalidate($true) })
    # подсветка при наведении: дочерние надписи не должны «гасить» её
    $hoverOn = {
        param($s, $e)
        $c = if ($s -is [System.Windows.Forms.Panel]) { $s } else { $s.Parent }
        if (-not ($script:CardHot.ContainsKey($c) -and $script:CardHot[$c])) { $script:CardHot[$c] = $true; $c.Invalidate($true) }
    }
    $hoverOff = {
        param($s, $e)
        $c = if ($s -is [System.Windows.Forms.Panel]) { $s } else { $s.Parent }
        $inside = $c.ClientRectangle.Contains($c.PointToClient([System.Windows.Forms.Cursor]::Position))
        if (-not $inside) { $script:CardHot[$c] = $false; $c.Invalidate($true) }
    }
    foreach ($ctl in @($card, $iconLabel, $titleLabel, $subLabel)) { $ctl.Add_MouseEnter($hoverOn); $ctl.Add_MouseLeave($hoverOff) }
    $card.Add_KeyDown({
            param($s, $e)
            if ($e.KeyCode -in 'Return', 'Space') {
                $e.Handled = $true
                $e.SuppressKeyPress = $true
                if ($s.Tag) { try { & $s.Tag } catch { [void][System.Windows.Forms.MessageBox]::Show(('Не удалось выполнить действие: ' + $_.Exception.Message), 'pckit by odilbek') } }
            }
        })
    $card.Add_MouseDown({ param($s, $e) $s.Focus() | Out-Null })
    $card.Anchor = 'Top,Left'
    [void]$script:HomeCards.Add($card)

    $tabHome.Controls.Add($card)
    return $card
}

$script:HomeCards = New-Object System.Collections.ArrayList
$script:CardHot = @{}

function Set-HomeLayout {
    # «Ускорить для игр» — на всю ширину, остальные — в две колонки; на узком окне карточки не выходят за край
    $w = [Math]::Max(520, $tabHome.ClientSize.Width)
    $gap = 24
    $cardW = [int](($w - 3 * $gap) / 2)
    $cardH = 104
    $top = 120
    $col = 0
    $bottom = $top
    foreach ($c in $script:HomeCards) {
        $c.Height = $cardH
        if ($c.Name -eq 'wide') {
            if ($col -ne 0) { $top += $cardH + 12; $col = 0 }
            $c.Width = $w - 2 * $gap
            $c.Left = $gap
            $c.Top = $top
            $top += $cardH + 12
        } else {
            $c.Width = $cardW
            $c.Left = $gap + $col * ($cardW + $gap)
            $c.Top = $top
            if ($col -eq 1) { $top += $cardH + 12; $col = 0 } else { $col = 1 }
        }
        $bottom = $c.Top + $cardH
        foreach ($ch in $c.Controls) { if ($ch -is [System.Windows.Forms.Label] -and $ch.Width -gt 100) { $ch.Width = [Math]::Max(200, $c.Width - 100) } }
    }
    if ($homeMore) { $homeMore.Top = $bottom + 14; $homeProgress.Top = $bottom + 42 } else { $homeProgress.Top = $bottom + 12 }
}
# иконки — символы шрифта Segoe MDL2 Assets
$script:Icons = @{
    Home = [string][char]0xE80F; Game = [string][char]0xE7FC; Clean = [string][char]0xEA99; Result = [string][char]0xE9D2
    Health = [string][char]0xE95E; Save = [string][char]0xE74E; Restore = [string][char]0xE896; Manual = [string][char]0xE8B7
    Done = [string][char]0xE81C; Boost = [string][char]0xEC4A; Startup = [string][char]0xE7E8
}
# Главная: шесть понятных кнопок. Редкое (сеть, отчёт, «до и после») — строкой ссылок ниже и в меню слева.
$cardBoost = New-HomeCard -Icon $script:Icons.Boost -Title 'Ускорить для игр' -Subtitle 'Рекомендуется. Подберу безопасные настройки под ваш ПК (Windows, видеокарта, CS2), почищу мусор и скажу, что сделать руками.' -Left 24 -Top 96 -OnClick {
    Invoke-HomeAll
}
$cardBoost.Name = 'wide'
[void](New-HomeCard -Icon ([string][char]0xE945) -Title 'Максимальное ускорение' -Subtitle 'Всё из «Ускорить» плюс экспертные настройки: службы, телеметрия, индексация. Для тех, кому важен каждый кадр.' -Left 24 -Top 96 -OnClick {
        Invoke-HomeAll -Max
    })
[void](New-HomeCard -Icon ([string][char]0xE821) -Title 'Для работы' -Subtitle 'Офис, Photoshop, AutoCAD, Revit: настройки без игровых, мусор и кэши программ, крупные забытые файлы.' -Left 554 -Top 96 -OnClick {
        Invoke-HomeWork
    })
[void](New-HomeCard -Icon $script:Icons.Clean -Title 'Почистить диск' -Subtitle 'Только безопасные кэши и временные файлы. Сначала покажу, сколько места освободится.' -Left 554 -Top 96 -OnClick {
        Invoke-HomeClean
    })
[void](New-HomeCard -Icon $script:Icons.Health -Title 'Проверить ПК' -Subtitle 'Найду, что мешает: монитор, память, драйвер, настройки CS2. Ничего не меняю.' -Left 554 -Top 262 -OnClick {
        Invoke-HomeCheck
    })
[void](New-HomeCard -Icon ([string][char]0xE7A7) -Title 'Вернуть как было' -Subtitle 'Отменить всё, что изменил pckit. Ваши файлы и программы не трогаются.' -Left 24 -Top 262 -OnClick {
        Invoke-DoneUndo
    })

# «Ещё»: то, что нужно не каждый день
$homeMore = New-Object System.Windows.Forms.LinkLabel
$homeMoreItems = @(
    @('Результат «до и после»', { Invoke-HomeResult }),
    @('Сеть для CS2', { Invoke-HomeNetwork }),
    @('Отчёт для друга', { Invoke-HomeShare }),
    @('Сохранить программы и настройки перед переустановкой Windows', { $tabs.SelectedTab = $tabSave; Update-NavSelection })
)
$homeMoreText = 'Ещё:  '
$homeMoreLinks = @()
foreach ($mi in $homeMoreItems) {
    if ($homeMoreLinks.Count) { $homeMoreText += '   ·   ' }
    $homeMoreLinks += , @($homeMoreText.Length, $mi[0].Length, $mi[1])
    $homeMoreText += $mi[0]
}
$homeMore.Text = $homeMoreText
$homeMore.Links.Clear()
foreach ($l in $homeMoreLinks) { [void]$homeMore.Links.Add($l[0], $l[1], $l[2]) }
$homeMore.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$homeMore.LinkColor = $script:Theme.Accent
$homeMore.ActiveLinkColor = $script:Theme.Accent
$homeMore.ForeColor = $script:Theme.Muted
$homeMore.AutoSize = $true
$homeMore.Location = New-Object System.Drawing.Point(26, 440)
$homeMore.Add_LinkClicked({
        param($s, $e)
        try { & $e.Link.LinkData } catch { [void][System.Windows.Forms.MessageBox]::Show(('Не удалось выполнить действие: ' + $_.Exception.Message), 'pckit by odilbek') }
    })
$tabHome.Controls.Add($homeMore)
$homeExpertLink.AccessibleName = 'Все настройки (экспертный режим)'
$homeNext.Add_LinkClicked({ param($s, $e) if ($s.Tag) { try { & $s.Tag } catch { } } })
$tabHome.Add_Resize({ Set-HomeLayout })
Set-HomeLayout

# ------------------------------------------------------------------- tabs
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabs.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$tabs.Padding = New-Object System.Drawing.Point(16, 6)

$tabSave = New-Object System.Windows.Forms.TabPage
$tabSave.Text = '  Сохранить  '
$tabRestore = New-Object System.Windows.Forms.TabPage
$tabRestore.Text = '  Вернуть  '
$tabManual = New-Object System.Windows.Forms.TabPage
$tabManual.Text = '  Вручную  '
foreach ($tp in @($tabSave, $tabRestore, $tabManual)) {
    $tp.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 252)
    $tp.Padding = New-Object System.Windows.Forms.Padding(4)
}
[void]$tabs.TabPages.Add($tabSave)
[void]$tabs.TabPages.Add($tabRestore)
[void]$tabs.TabPages.Add($tabManual)
$tabSave.Controls.Add($layout)
$form.Controls.Add($tabs)

# --------------------------------------------------------------- restore tab
$restoreLayout = New-Object System.Windows.Forms.TableLayoutPanel
$restoreLayout.Dock = 'Fill'
$restoreLayout.ColumnCount = 1
$restoreLayout.RowCount = 3
$restoreLayout.ColumnStyles.Clear()
[void]$restoreLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
$restoreLayout.RowStyles.Clear()
[void]$restoreLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 84)))
[void]$restoreLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
[void]$restoreLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 54)))

$restoreTop = New-Object System.Windows.Forms.Panel
$restoreTop.Dock = 'Fill'
$restoreTop.BackColor = [System.Drawing.Color]::White

$openProfileButton = New-Object System.Windows.Forms.Button
$openProfileButton.Text = 'Открыть профиль...'
$openProfileButton.Location = New-Object System.Drawing.Point(14, 14)
$openProfileButton.Size = New-Object System.Drawing.Size(180, 34)
$restoreTop.Controls.Add($openProfileButton)

$restorePathLabel = New-Object System.Windows.Forms.Label
$restorePathLabel.Text = 'Профиль не выбран'
$restorePathLabel.Location = New-Object System.Drawing.Point(206, 14)
$restorePathLabel.AutoSize = $true
$restorePathLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$restoreTop.Controls.Add($restorePathLabel)

$restoreHintLabel = New-Object System.Windows.Forms.Label
$restoreHintLabel.Text = 'Сначала покажу план: что поставить, что скопировать, что останется руками.'
$restoreHintLabel.Location = New-Object System.Drawing.Point(208, 42)
$restoreHintLabel.AutoSize = $true
$restoreHintLabel.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 130)
$restoreTop.Controls.Add($restoreHintLabel)

$dryRunCheck = New-Object System.Windows.Forms.CheckBox
$dryRunCheck.Text = 'пробный прогон'
$dryRunCheck.Checked = $true
$dryRunCheck.AutoSize = $true
$dryRunCheck.Location = New-Object System.Drawing.Point(700, 20)
$dryRunCheck.Anchor = 'Top,Right'
$restoreTop.Controls.Add($dryRunCheck)

$applyButton = New-Object System.Windows.Forms.Button
$applyButton.Text = 'Применить'
$applyButton.Size = New-Object System.Drawing.Size(150, 34)
$applyButton.Location = New-Object System.Drawing.Point(855, 14)
$applyButton.Anchor = 'Top,Right'
$applyButton.Enabled = $false
$applyButton.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$applyButton.ForeColor = [System.Drawing.Color]::White
$applyButton.FlatStyle = 'Flat'
$applyButton.FlatAppearance.BorderSize = 0
$applyButton.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$restoreTop.Controls.Add($applyButton)

$restoreList = New-Object System.Windows.Forms.ListView
$restoreList.AccessibleName = 'Шаги плана восстановления'
$restoreList.Dock = 'Fill'
$restoreList.View = 'Details'
$restoreList.FullRowSelect = $true
$restoreList.GridLines = $false
$restoreList.BorderStyle = 'FixedSingle'
$restoreList.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$restoreList.BackColor = [System.Drawing.Color]::White
[void]$restoreList.Columns.Add('Действие', 120)
[void]$restoreList.Columns.Add('Пункт', 330)
[void]$restoreList.Columns.Add('Подробности', 430)
[void]$restoreList.Columns.Add('Результат', 130)

$restoreBottom = New-Object System.Windows.Forms.Panel
$restoreBottom.Dock = 'Fill'
$restoreBottom.BackColor = [System.Drawing.Color]::White

$restoreStatus = New-Object System.Windows.Forms.Label
$restoreStatus.Text = 'Откройте профиль, чтобы увидеть план.'
$restoreStatus.Location = New-Object System.Drawing.Point(14, 10)
$restoreStatus.AutoSize = $true
$restoreStatus.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 80)
$restoreBottom.Controls.Add($restoreStatus)

$applyProgress = New-Object System.Windows.Forms.ProgressBar
$applyProgress.Location = New-Object System.Drawing.Point(14, 32)
$applyProgress.Size = New-Object System.Drawing.Size(420, 10)
$applyProgress.Style = 'Continuous'
$restoreBottom.Controls.Add($applyProgress)

$undoButton = New-Object System.Windows.Forms.Button
$undoButton.Text = 'Отменить изменения'
$undoButton.Size = New-Object System.Drawing.Size(190, 30)
$undoButton.Location = New-Object System.Drawing.Point(820, 8)
$undoButton.FlatStyle = 'System'
$restoreBottom.Controls.Add($undoButton)

$restoreLayout.Controls.Add($restoreTop, 0, 0)
$restoreLayout.Controls.Add($restoreList, 0, 1)
$restoreLayout.Controls.Add($restoreBottom, 0, 2)
$tabRestore.Controls.Add($restoreLayout)

function Set-RestoreLayout {
    $w = $restoreTop.ClientSize.Width
    if ($w -le 560) { return }
    $applyButton.Left = $w - $applyButton.Width - 16
    $dryRunCheck.Left = $applyButton.Left - $dryRunCheck.Width - 22
    $bw = $restoreBottom.ClientSize.Width
    if ($bw -gt 400) { $undoButton.Left = $bw - $undoButton.Width - 16 }
}
$restoreTop.Add_Resize({ Set-RestoreLayout })

# ---------------------------------------------------------------- manual tab
$manualLayout = New-Object System.Windows.Forms.TableLayoutPanel
$manualLayout.Dock = 'Fill'
$manualLayout.ColumnCount = 1
$manualLayout.RowCount = 3
$manualLayout.ColumnStyles.Clear()
[void]$manualLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
$manualLayout.RowStyles.Clear()
[void]$manualLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 62)))
[void]$manualLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
[void]$manualLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 52)))

$manualTop = New-Object System.Windows.Forms.Panel
$manualTop.Dock = 'Fill'
$manualTop.BackColor = [System.Drawing.Color]::White

$manualTitle = New-Object System.Windows.Forms.Label
$manualTitle.Text = 'Программы, которые ставятся руками'
$manualTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
$manualTitle.Location = New-Object System.Drawing.Point(14, 8)
$manualTitle.AutoSize = $true
$manualTop.Controls.Add($manualTitle)

$manualHint = New-Object System.Windows.Forms.Label
$manualHint.Text = 'У них нет пакета winget. Двойной щелчок — открыть страницу загрузки.'
$manualHint.Location = New-Object System.Drawing.Point(16, 34)
$manualHint.AutoSize = $true
$manualHint.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 130)
$manualTop.Controls.Add($manualHint)

$manualList = New-Object System.Windows.Forms.ListView
$manualList.AccessibleName = 'Программы для ручной установки'
$manualList.Dock = 'Fill'
$manualList.View = 'Details'
$manualList.FullRowSelect = $true
$manualList.BorderStyle = 'FixedSingle'
$manualList.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$manualList.BackColor = [System.Drawing.Color]::White
[void]$manualList.Columns.Add('Программа', 250)
[void]$manualList.Columns.Add('Производитель', 170)
[void]$manualList.Columns.Add('Что учесть после переустановки', 520)
[void]$manualList.Columns.Add('На этом ПК', 110)

$manualBottom = New-Object System.Windows.Forms.Panel
$manualBottom.Dock = 'Fill'
$manualBottom.BackColor = [System.Drawing.Color]::White

$openLinkButton = New-Object System.Windows.Forms.Button
$openLinkButton.Text = 'Открыть страницу загрузки'
$openLinkButton.Location = New-Object System.Drawing.Point(14, 10)
$openLinkButton.Size = New-Object System.Drawing.Size(220, 32)
$manualBottom.Controls.Add($openLinkButton)

$copyLinkButton = New-Object System.Windows.Forms.Button
$copyLinkButton.Text = 'Скопировать ссылку'
$copyLinkButton.Location = New-Object System.Drawing.Point(244, 10)
$copyLinkButton.Size = New-Object System.Drawing.Size(170, 32)
$manualBottom.Controls.Add($copyLinkButton)

$manualStatus = New-Object System.Windows.Forms.Label
$manualStatus.Text = ''
$manualStatus.Location = New-Object System.Drawing.Point(430, 18)
$manualStatus.AutoSize = $true
$manualStatus.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 130)
$manualBottom.Controls.Add($manualStatus)

$manualLayout.Controls.Add($manualTop, 0, 0)
$manualLayout.Controls.Add($manualList, 0, 1)
$manualLayout.Controls.Add($manualBottom, 0, 2)
$tabManual.Controls.Add($manualLayout)

# ------------------------------------------------------------------- game tab
$tabGame = New-Object System.Windows.Forms.TabPage
$tabGame.Text = '  Игры  '
$tabGame.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 252)
$tabGame.Padding = New-Object System.Windows.Forms.Padding(4)

$gameLayout = New-Object System.Windows.Forms.TableLayoutPanel
$gameLayout.Dock = 'Fill'
$gameLayout.ColumnCount = 1
$gameLayout.RowCount = 3
$gameLayout.ColumnStyles.Clear()
[void]$gameLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
$gameLayout.RowStyles.Clear()
[void]$gameLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 62)))
[void]$gameLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
[void]$gameLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 104)))

$gameTop = New-Object System.Windows.Forms.Panel
$gameTop.Dock = 'Fill'
$gameTop.BackColor = [System.Drawing.Color]::White

$gameTitle = New-Object System.Windows.Forms.Label
$gameTitle.Text = 'Настройки: Windows, видеокарта, CS2'
$gameTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
$gameTitle.Location = New-Object System.Drawing.Point(14, 8)
$gameTitle.AutoSize = $true
$gameTop.Controls.Add($gameTitle)

$gameHint = New-Object System.Windows.Forms.Label
$gameHint.Text = 'Отметьте нужное. Каждое действие можно отменить — изменения записываются в журнал.'
$gameHint.Location = New-Object System.Drawing.Point(16, 34)
$gameHint.AutoSize = $true
$gameHint.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 130)
$gameTop.Controls.Add($gameHint)

$script:GameSearchHint = ''
$gameFilter = New-Object System.Windows.Forms.ComboBox
$gameFilter.DropDownStyle = 'DropDownList'
$gameFilter.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$gameFilter.Size = New-Object System.Drawing.Size(200, 24)
[void]$gameFilter.Items.AddRange(@('Все настройки', 'Подобрано под мой ПК', 'Ещё не включено', 'Мифы и плацебо'))
$gameFilter.SelectedIndex = 0
$gameFilter.AccessibleName = 'Показать'
$gameTop.Controls.Add($gameFilter)

$gameSearchLabel = New-Object System.Windows.Forms.Label
$gameSearchLabel.Text = 'Поиск:'
$gameSearchLabel.AutoSize = $true
$gameSearchLabel.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 120)
$gameTop.Controls.Add($gameSearchLabel)

$gameSearch = New-Object System.Windows.Forms.TextBox
$gameSearch.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$gameSearch.Size = New-Object System.Drawing.Size(200, 24)
$gameSearch.AccessibleName = 'Поиск настройки'
$gameTop.Controls.Add($gameSearch)

$gameShown = New-Object System.Windows.Forms.Label
$gameShown.Text = ''
$gameShown.AutoSize = $true
$gameShown.ForeColor = [System.Drawing.Color]::FromArgb(130, 130, 140)
$gameTop.Controls.Add($gameShown)

# справа в шапке: фильтр сверху, поиск снизу
$gameTop.Add_Resize({
        $x = $gameTop.ClientSize.Width - 214
        $gameFilter.Location = New-Object System.Drawing.Point($x, 6)
        $gameSearch.Location = New-Object System.Drawing.Point($x, 33)
        $gameSearchLabel.Location = New-Object System.Drawing.Point(($x - 46), 36)
        $gameShown.Visible = $false
        $gameHint.MaximumSize = New-Object System.Drawing.Size([Math]::Max(200, $x - 70), 0)
    })
$gameList = New-Object System.Windows.Forms.ListView
$gameList.AccessibleName = 'Настройки для игр'
$gameList.Dock = 'Fill'
$gameList.View = 'Details'
$gameList.CheckBoxes = $true
$gameList.ShowItemToolTips = $true
$gameList.ShowGroups = $true
$gameList.FullRowSelect = $true
$gameList.BorderStyle = 'FixedSingle'
$gameList.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$gameList.BackColor = [System.Drawing.Color]::White
[void]$gameList.Columns.Add('Действие', 340)
[void]$gameList.Columns.Add('Для вашего ПК', 330)
[void]$gameList.Columns.Add('Эффект', 80)
[void]$gameList.Columns.Add('Сейчас', 130)
[void]$gameList.Columns.Add('Раздел', 120)

$gameBottom = New-Object System.Windows.Forms.Panel
$gameBottom.Dock = 'Fill'
$gameBottom.BackColor = [System.Drawing.Color]::White

$gameDetails = New-Object System.Windows.Forms.Label
$gameDetails.Location = New-Object System.Drawing.Point(14, 6)
$gameDetails.Size = New-Object System.Drawing.Size(660, 38)
$gameDetails.Anchor = 'Top,Left,Right'
$gameDetails.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$gameDetails.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 80)
$gameBottom.Controls.Add($gameDetails)

$gameApplyButton = New-Object System.Windows.Forms.Button
$gameApplyButton.Text = 'Применить отмеченные'
$gameApplyButton.Location = New-Object System.Drawing.Point(14, 50)
$gameApplyButton.Size = New-Object System.Drawing.Size(200, 32)
$gameApplyButton.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$gameApplyButton.ForeColor = [System.Drawing.Color]::White
$gameApplyButton.FlatStyle = 'Flat'
$gameApplyButton.FlatAppearance.BorderSize = 0
$gameApplyButton.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$gameBottom.Controls.Add($gameApplyButton)

$gameCheckButton = New-Object System.Windows.Forms.Button
$gameCheckButton.Text = 'Проверить'
$gameCheckButton.Location = New-Object System.Drawing.Point(224, 50)
$gameCheckButton.Size = New-Object System.Drawing.Size(110, 32)
$gameCheckButton.FlatStyle = 'System'
$gameBottom.Controls.Add($gameCheckButton)

$gamePresetButton = New-Object System.Windows.Forms.Button
$gamePresetButton.Text = 'Подобрать под мой ПК'
$gamePresetButton.Location = New-Object System.Drawing.Point(344, 50)
$gamePresetButton.Size = New-Object System.Drawing.Size(210, 32)
$gamePresetButton.FlatStyle = 'System'
$gameBottom.Controls.Add($gamePresetButton)

$gameUndoButton = New-Object System.Windows.Forms.Button
$gameUndoButton.Text = 'Отменить изменения'
$gameUndoButton.Location = New-Object System.Drawing.Point(564, 50)
$gameUndoButton.Size = New-Object System.Drawing.Size(180, 32)
$gameUndoButton.FlatStyle = 'System'
$gameBottom.Controls.Add($gameUndoButton)

$gameDryRun = New-Object System.Windows.Forms.CheckBox
$gameDryRun.Text = 'только показать'
$gameDryRun.Checked = $false
$gameDryRun.AutoSize = $true
$gameDryRun.Location = New-Object System.Drawing.Point(680, 8)
$gameBottom.Controls.Add($gameDryRun)

$gameRestorePoint = New-Object System.Windows.Forms.CheckBox
$gameRestorePoint.Text = 'точка восстановления'
$gameRestorePoint.Checked = $true
$gameRestorePoint.AutoSize = $true
$gameRestorePoint.Location = New-Object System.Drawing.Point(810, 8)
$gameBottom.Controls.Add($gameRestorePoint)

$gameStatus = New-Object System.Windows.Forms.Label
$gameStatus.Text = ''
$gameStatus.Location = New-Object System.Drawing.Point(690, 34)
$gameStatus.AutoSize = $true
$gameStatus.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 130)
$gameBottom.Controls.Add($gameStatus)

$gameLayout.Controls.Add($gameTop, 0, 0)
$gameLayout.Controls.Add($gameList, 0, 1)
$gameLayout.Controls.Add($gameBottom, 0, 2)
$tabGame.Controls.Add($gameLayout)
[void]$tabs.TabPages.Add($tabGame)

# ------------------------------------------------------------------ clean tab
$tabClean = New-Object System.Windows.Forms.TabPage
$tabClean.Text = '  Чистка  '
$tabClean.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 252)
$tabClean.Padding = New-Object System.Windows.Forms.Padding(4)

$cleanLayout = New-Object System.Windows.Forms.TableLayoutPanel
$cleanLayout.Dock = 'Fill'
$cleanLayout.ColumnCount = 1
$cleanLayout.RowCount = 3
$cleanLayout.ColumnStyles.Clear()
[void]$cleanLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
$cleanLayout.RowStyles.Clear()
[void]$cleanLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 62)))
[void]$cleanLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
[void]$cleanLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 96)))

$cleanTop = New-Object System.Windows.Forms.Panel
$cleanTop.Dock = 'Fill'
$cleanTop.BackColor = [System.Drawing.Color]::White

$cleanTitle = New-Object System.Windows.Forms.Label
$cleanTitle.Text = 'Чистка диска'
$cleanTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
$cleanTitle.Location = New-Object System.Drawing.Point(14, 6)
$cleanTitle.AutoSize = $true
$cleanTop.Controls.Add($cleanTitle)

$cleanSubtitle = New-Object System.Windows.Forms.Label
$cleanSubtitle.Text = 'Сначала считаем размер, потом удаляем. Удаляется только содержимое кэшей — сами папки остаются.'
$cleanSubtitle.Location = New-Object System.Drawing.Point(16, 30)
$cleanSubtitle.AutoSize = $true
$cleanSubtitle.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 120)
$cleanTop.Controls.Add($cleanSubtitle)

$cleanList = New-Object System.Windows.Forms.ListView
$cleanList.AccessibleName = 'Что можно очистить'
$cleanList.Dock = 'Fill'
$cleanList.View = 'Details'
$cleanList.CheckBoxes = $true
$cleanList.FullRowSelect = $true
$cleanList.BorderStyle = 'FixedSingle'
$cleanList.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$cleanList.BackColor = [System.Drawing.Color]::White
[void]$cleanList.Columns.Add('Что', 260)
[void]$cleanList.Columns.Add('Что это', 440)
[void]$cleanList.Columns.Add('Размер', 110)
[void]$cleanList.Columns.Add('Права', 100)

$cleanBottom = New-Object System.Windows.Forms.Panel
$cleanBottom.Dock = 'Fill'
$cleanBottom.BackColor = [System.Drawing.Color]::White

$cleanSummary = New-Object System.Windows.Forms.Label
$cleanSummary.Text = 'Размеры ещё не посчитаны — нажмите «Посчитать».'
$cleanSummary.Location = New-Object System.Drawing.Point(14, 6)
$cleanSummary.AutoSize = $true
$cleanSummary.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$cleanBottom.Controls.Add($cleanSummary)

$cleanHint = New-Object System.Windows.Forms.Label
$cleanHint.Text = ''
$cleanHint.Location = New-Object System.Drawing.Point(16, 26)
$cleanHint.Size = New-Object System.Drawing.Size(1060, 20)
$cleanHint.Anchor = 'Top,Left,Right'
$cleanHint.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 130)
$cleanBottom.Controls.Add($cleanHint)

$cleanCountButton = New-Object System.Windows.Forms.Button
$cleanCountButton.Text = 'Посчитать'
$cleanCountButton.Location = New-Object System.Drawing.Point(14, 50)
$cleanCountButton.Size = New-Object System.Drawing.Size(130, 32)
$cleanCountButton.FlatStyle = 'System'
$cleanBottom.Controls.Add($cleanCountButton)

$cleanSafeButton = New-Object System.Windows.Forms.Button
$cleanSafeButton.Text = 'Отметить безопасное'
$cleanSafeButton.Location = New-Object System.Drawing.Point(154, 50)
$cleanSafeButton.Size = New-Object System.Drawing.Size(190, 32)
$cleanSafeButton.FlatStyle = 'System'
$cleanBottom.Controls.Add($cleanSafeButton)

$cleanRunButton = New-Object System.Windows.Forms.Button
$cleanRunButton.Text = 'Очистить отмеченное'
$cleanRunButton.Location = New-Object System.Drawing.Point(354, 50)
$cleanRunButton.Size = New-Object System.Drawing.Size(200, 32)
$cleanRunButton.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$cleanRunButton.ForeColor = [System.Drawing.Color]::White
$cleanRunButton.FlatStyle = 'Flat'
$cleanRunButton.FlatAppearance.BorderSize = 0
$cleanRunButton.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$cleanBottom.Controls.Add($cleanRunButton)

$cleanLayout.Controls.Add($cleanTop, 0, 0)
$cleanLayout.Controls.Add($cleanList, 0, 1)
$cleanLayout.Controls.Add($cleanBottom, 0, 2)
$tabClean.Controls.Add($cleanLayout)
[void]$tabs.TabPages.Add($tabClean)

# ----------------------------------------------------------------- report tab
$tabHealth = New-Object System.Windows.Forms.TabPage
$tabHealth.Text = '  Отчёт  '
$tabHealth.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 252)
$tabHealth.Padding = New-Object System.Windows.Forms.Padding(4)

$healthLayout = New-Object System.Windows.Forms.TableLayoutPanel
$healthLayout.Dock = 'Fill'
$healthLayout.ColumnCount = 1
$healthLayout.RowCount = 3
$healthLayout.ColumnStyles.Clear()
[void]$healthLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
$healthLayout.RowStyles.Clear()
[void]$healthLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 64)))
[void]$healthLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
[void]$healthLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 96)))

$healthTop = New-Object System.Windows.Forms.Panel
$healthTop.Dock = 'Fill'
$healthTop.BackColor = [System.Drawing.Color]::White

$healthTitle = New-Object System.Windows.Forms.Label
$healthTitle.Text = 'Проверка компьютера'
$healthTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
$healthTitle.Location = New-Object System.Drawing.Point(14, 6)
$healthTitle.AutoSize = $true
$healthTop.Controls.Add($healthTitle)

$healthMachineLabel = New-Object System.Windows.Forms.Label
$healthMachineLabel.Text = 'Нажмите «Проверить ПК» — это только чтение, ничего не меняется.'
$healthMachineLabel.Location = New-Object System.Drawing.Point(16, 30)
$healthMachineLabel.Size = New-Object System.Drawing.Size(1060, 28)
$healthMachineLabel.Anchor = 'Top,Left,Right'
$healthMachineLabel.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 120)
$healthTop.Controls.Add($healthMachineLabel)

$healthList = New-Object System.Windows.Forms.ListView
$healthList.Dock = 'Fill'
$healthList.View = 'Details'
$healthList.FullRowSelect = $true
$healthList.BorderStyle = 'FixedSingle'
$healthList.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$healthList.BackColor = [System.Drawing.Color]::White
[void]$healthList.Columns.Add('Важность', 110)
[void]$healthList.Columns.Add('Что найдено', 400)
[void]$healthList.Columns.Add('Подробности', 500)

$healthBottom = New-Object System.Windows.Forms.Panel
$healthBottom.Dock = 'Fill'
$healthBottom.BackColor = [System.Drawing.Color]::White

$healthSummary = New-Object System.Windows.Forms.Label
$healthSummary.Text = 'Проверка ещё не запускалась.'
$healthSummary.Location = New-Object System.Drawing.Point(14, 6)
$healthSummary.AutoSize = $true
$healthSummary.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$healthBottom.Controls.Add($healthSummary)

$healthHint = New-Object System.Windows.Forms.Label
$healthHint.Text = ''
$healthHint.Location = New-Object System.Drawing.Point(16, 26)
$healthHint.Size = New-Object System.Drawing.Size(1060, 20)
$healthHint.Anchor = 'Top,Left,Right'
$healthHint.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 130)
$healthBottom.Controls.Add($healthHint)

$healthCheckButton = New-Object System.Windows.Forms.Button
$healthCheckButton.Text = 'Проверить ПК'
$healthCheckButton.Location = New-Object System.Drawing.Point(14, 50)
$healthCheckButton.Size = New-Object System.Drawing.Size(150, 32)
$healthCheckButton.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$healthCheckButton.ForeColor = [System.Drawing.Color]::White
$healthCheckButton.FlatStyle = 'Flat'
$healthCheckButton.FlatAppearance.BorderSize = 0
$healthCheckButton.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$healthBottom.Controls.Add($healthCheckButton)

$healthSaveButton = New-Object System.Windows.Forms.Button
$healthSaveButton.Text = 'Сохранить отчёт'
$healthSaveButton.Location = New-Object System.Drawing.Point(174, 50)
$healthSaveButton.Size = New-Object System.Drawing.Size(160, 32)
$healthSaveButton.FlatStyle = 'System'
$healthSaveButton.Enabled = $false
$healthBottom.Controls.Add($healthSaveButton)

$healthFixButton = New-Object System.Windows.Forms.Button
$healthFixButton.Text = 'Перейти к исправлению'
$healthFixButton.Location = New-Object System.Drawing.Point(344, 50)
$healthFixButton.Size = New-Object System.Drawing.Size(130, 32)
$healthFixButton.FlatStyle = 'System'
$healthFixButton.Enabled = $false
$healthBottom.Controls.Add($healthFixButton)

$healthDriverButton = New-Object System.Windows.Forms.Button
$healthDriverButton.Text = 'Свежий ли драйвер?'
$healthDriverButton.Location = New-Object System.Drawing.Point(484, 50)
$healthDriverButton.Size = New-Object System.Drawing.Size(150, 32)
$healthDriverButton.FlatStyle = 'System'
$healthBottom.Controls.Add($healthDriverButton)
$healthDriverButton.Add_Click({ Invoke-DriverCheck })

$healthShareButton = New-Object System.Windows.Forms.Button
$healthShareButton.Text = 'Отчёт для друга'
$healthShareButton.Location = New-Object System.Drawing.Point(644, 50)
$healthShareButton.Size = New-Object System.Drawing.Size(140, 32)
$healthShareButton.FlatStyle = 'System'
$healthBottom.Controls.Add($healthShareButton)
$healthShareButton.Add_Click({ Invoke-HomeShare })
$healthLayout.Controls.Add($healthTop, 0, 0)
$healthLayout.Controls.Add($healthList, 0, 1)
$healthLayout.Controls.Add($healthBottom, 0, 2)
$tabHealth.Controls.Add($healthLayout)
[void]$tabs.TabPages.Add($tabHealth)

# ----------------------------------------------------------------- result tab
$tabResult = New-Object System.Windows.Forms.TabPage
$tabResult.Text = '  Результат  '
$tabResult.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 252)
$tabResult.Padding = New-Object System.Windows.Forms.Padding(4)

$resultLayout = New-Object System.Windows.Forms.TableLayoutPanel
$resultLayout.Dock = 'Fill'
$resultLayout.ColumnCount = 1
$resultLayout.RowCount = 3
$resultLayout.ColumnStyles.Clear()
[void]$resultLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
$resultLayout.RowStyles.Clear()
[void]$resultLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 64)))
[void]$resultLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
[void]$resultLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 136)))

$resultTop = New-Object System.Windows.Forms.Panel
$resultTop.Dock = 'Fill'
$resultTop.BackColor = [System.Drawing.Color]::White

$resultTitle = New-Object System.Windows.Forms.Label
$resultTitle.Text = 'Результат: до и после'
$resultTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
$resultTitle.Location = New-Object System.Drawing.Point(14, 6)
$resultTitle.AutoSize = $true
$resultTop.Controls.Add($resultTitle)

$resultInfo = New-Object System.Windows.Forms.Label
$resultInfo.Text = 'Замер «до» → ускорение и чистка → замер «после». Где разница меньше случайного разброса, так и пишем: «в пределах шума».'
$resultInfo.Location = New-Object System.Drawing.Point(16, 30)
$resultInfo.Size = New-Object System.Drawing.Size(1060, 28)
$resultInfo.Anchor = 'Top,Left,Right'
$resultInfo.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 120)
$resultTop.Controls.Add($resultInfo)

$resultList = New-Object System.Windows.Forms.ListView
$resultList.AccessibleName = 'Сравнение до и после'
$resultList.Dock = 'Fill'
$resultList.View = 'Details'
$resultList.FullRowSelect = $true
$resultList.BorderStyle = 'FixedSingle'
$resultList.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$resultList.BackColor = [System.Drawing.Color]::White
[void]$resultList.Columns.Add('Что меряем', 250)
[void]$resultList.Columns.Add('До', 140)
[void]$resultList.Columns.Add('После', 140)
[void]$resultList.Columns.Add('Разница', 120)
[void]$resultList.Columns.Add('Вывод', 150)
[void]$resultList.Columns.Add('Пояснение', 300)

$resultBottom = New-Object System.Windows.Forms.Panel
$resultBottom.Dock = 'Fill'
$resultBottom.BackColor = [System.Drawing.Color]::White

$resultSummary = New-Object System.Windows.Forms.Label
$resultSummary.Text = 'Замеров ещё нет.'
$resultSummary.Location = New-Object System.Drawing.Point(14, 6)
$resultSummary.AutoSize = $true
$resultSummary.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$resultBottom.Controls.Add($resultSummary)

$resultHint = New-Object System.Windows.Forms.Label
$resultHint.Text = 'Замер длится около 20 секунд. Закройте браузер и лаунчеры и не трогайте ПК — так «до» и «после» честно сравнимы.'
$resultHint.Location = New-Object System.Drawing.Point(16, 26)
$resultHint.Size = New-Object System.Drawing.Size(1060, 20)
$resultHint.Anchor = 'Top,Left,Right'
$resultHint.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 130)
$resultBottom.Controls.Add($resultHint)

$resultBeforeButton = New-Object System.Windows.Forms.Button
$resultBeforeButton.Text = 'Замерить «до»'
$resultBeforeButton.Location = New-Object System.Drawing.Point(14, 50)
$resultBeforeButton.Size = New-Object System.Drawing.Size(150, 32)
$resultBeforeButton.FlatStyle = 'System'
$resultBottom.Controls.Add($resultBeforeButton)

$resultAfterButton = New-Object System.Windows.Forms.Button
$resultAfterButton.Text = 'Замерить «после» и сравнить'
$resultAfterButton.Location = New-Object System.Drawing.Point(174, 50)
$resultAfterButton.Size = New-Object System.Drawing.Size(240, 32)
$resultAfterButton.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$resultAfterButton.ForeColor = [System.Drawing.Color]::White
$resultAfterButton.FlatStyle = 'Flat'
$resultAfterButton.FlatAppearance.BorderSize = 0
$resultAfterButton.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$resultBottom.Controls.Add($resultAfterButton)

$resultOpenButton = New-Object System.Windows.Forms.Button
$resultOpenButton.Text = 'Открыть отчёт'
$resultOpenButton.Location = New-Object System.Drawing.Point(424, 50)
$resultOpenButton.Size = New-Object System.Drawing.Size(140, 32)
$resultOpenButton.FlatStyle = 'System'
$resultOpenButton.Enabled = $false
$resultBottom.Controls.Add($resultOpenButton)

$resultFpsBeforeButton = New-Object System.Windows.Forms.Button
$resultFpsBeforeButton.Text = 'FPS в CS2: «до»'
$resultFpsBeforeButton.Location = New-Object System.Drawing.Point(14, 92)
$resultFpsBeforeButton.Size = New-Object System.Drawing.Size(150, 32)
$resultFpsBeforeButton.FlatStyle = 'System'
$resultBottom.Controls.Add($resultFpsBeforeButton)

$resultFpsAfterButton = New-Object System.Windows.Forms.Button
$resultFpsAfterButton.Text = 'FPS в CS2: «после»'
$resultFpsAfterButton.Location = New-Object System.Drawing.Point(174, 92)
$resultFpsAfterButton.Size = New-Object System.Drawing.Size(160, 32)
$resultFpsAfterButton.FlatStyle = 'System'
$resultBottom.Controls.Add($resultFpsAfterButton)

$resultFpsLabel = New-Object System.Windows.Forms.Label
$resultFpsLabel.Text = 'FPS меряется программой Intel PresentMon, 60 секунд, только вне матчей FACEIT.'
$resultFpsLabel.Location = New-Object System.Drawing.Point(346, 100)
$resultFpsLabel.Size = New-Object System.Drawing.Size(730, 20)
$resultFpsLabel.Anchor = 'Top,Left,Right'
$resultFpsLabel.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 100)
$resultBottom.Controls.Add($resultFpsLabel)

$resultLayout.Controls.Add($resultTop, 0, 0)
$resultLayout.Controls.Add($resultList, 0, 1)
$resultLayout.Controls.Add($resultBottom, 0, 2)
$tabResult.Controls.Add($resultLayout)
[void]$tabs.TabPages.Add($tabResult)

# ---------------------------------------------------------------- startup tab
$tabStartup = New-Object System.Windows.Forms.TabPage
$tabStartup.Text = '  Автозагрузка  '
$tabStartup.Padding = New-Object System.Windows.Forms.Padding(4)

$startupLayout = New-Object System.Windows.Forms.TableLayoutPanel
$startupLayout.Dock = 'Fill'
$startupLayout.ColumnCount = 1
$startupLayout.RowCount = 3
[void]$startupLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
[void]$startupLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 64)))
[void]$startupLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
[void]$startupLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 100)))

$startupTop = New-Object System.Windows.Forms.Panel
$startupTop.Dock = 'Fill'

$startupTitle = New-Object System.Windows.Forms.Label
$startupTitle.Text = 'Автозагрузка'
$startupTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
$startupTitle.Location = New-Object System.Drawing.Point(14, 6)
$startupTitle.AutoSize = $true
$startupTop.Controls.Add($startupTitle)

$startupSubtitle = New-Object System.Windows.Forms.Label
$startupSubtitle.Text = 'Программы, которые стартуют вместе с Windows. Отключение не удаляет программу — её можно включить обратно.'
$startupSubtitle.Location = New-Object System.Drawing.Point(16, 34)
$startupSubtitle.AutoSize = $true
$startupSubtitle.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 120)
$startupTop.Controls.Add($startupSubtitle)

$startupList = New-Object System.Windows.Forms.ListView
$startupList.AccessibleName = 'Программы в автозагрузке'
$startupList.Dock = 'Fill'
$startupList.View = 'Details'
$startupList.CheckBoxes = $true
$startupList.FullRowSelect = $true
$startupList.Font = New-Object System.Drawing.Font('Segoe UI', 9)
[void]$startupList.Columns.Add('Программа', 240)
[void]$startupList.Columns.Add('Издатель', 180)
[void]$startupList.Columns.Add('Сейчас', 90)
[void]$startupList.Columns.Add('Совет', 140)
[void]$startupList.Columns.Add('Откуда запускается', 200)

$startupBottom = New-Object System.Windows.Forms.Panel
$startupBottom.Dock = 'Fill'

$startupSummary = New-Object System.Windows.Forms.Label
$startupSummary.Text = ''
$startupSummary.Location = New-Object System.Drawing.Point(14, 6)
$startupSummary.AutoSize = $true
$startupSummary.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$startupBottom.Controls.Add($startupSummary)

$startupHint = New-Object System.Windows.Forms.Label
$startupHint.Text = 'Выберите строку — внизу появится команда запуска и совет.'
$startupHint.Location = New-Object System.Drawing.Point(16, 28)
$startupHint.Size = New-Object System.Drawing.Size(1000, 20)
$startupHint.Anchor = 'Top,Left,Right'
$startupHint.AutoEllipsis = $true
$startupHint.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 130)
$startupBottom.Controls.Add($startupHint)

$startupDisableButton = New-Object System.Windows.Forms.Button
$startupDisableButton.Text = 'Отключить отмеченные'
$startupDisableButton.Location = New-Object System.Drawing.Point(14, 56)
$startupDisableButton.Size = New-Object System.Drawing.Size(200, 32)
$startupDisableButton.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$startupDisableButton.ForeColor = [System.Drawing.Color]::White
$startupBottom.Controls.Add($startupDisableButton)

$startupEnableButton = New-Object System.Windows.Forms.Button
$startupEnableButton.Text = 'Включить отмеченные'
$startupEnableButton.Location = New-Object System.Drawing.Point(224, 56)
$startupEnableButton.Size = New-Object System.Drawing.Size(180, 32)
$startupBottom.Controls.Add($startupEnableButton)

$startupPresetButton = New-Object System.Windows.Forms.Button
$startupPresetButton.Text = 'Отметить «можно отключить»'
$startupPresetButton.Location = New-Object System.Drawing.Point(414, 56)
$startupPresetButton.Size = New-Object System.Drawing.Size(220, 32)
$startupBottom.Controls.Add($startupPresetButton)

$startupRefreshButton = New-Object System.Windows.Forms.Button
$startupRefreshButton.Text = 'Обновить'
$startupRefreshButton.Location = New-Object System.Drawing.Point(644, 56)
$startupRefreshButton.Size = New-Object System.Drawing.Size(110, 32)
$startupBottom.Controls.Add($startupRefreshButton)

$startupLayout.Controls.Add($startupTop, 0, 0)
$startupLayout.Controls.Add($startupList, 0, 1)
$startupLayout.Controls.Add($startupBottom, 0, 2)
$tabStartup.Controls.Add($startupLayout)
[void]$tabs.TabPages.Add($tabStartup)

# ------------------------------------------------------------------ done tab
$tabDone = New-Object System.Windows.Forms.TabPage
$tabDone.Text = '  История и отмена  '
$tabDone.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 252)
$tabDone.Padding = New-Object System.Windows.Forms.Padding(4)

$doneLayout = New-Object System.Windows.Forms.TableLayoutPanel
$doneLayout.Dock = 'Fill'
$doneLayout.ColumnCount = 1
$doneLayout.RowCount = 3
$doneLayout.ColumnStyles.Clear()
[void]$doneLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
$doneLayout.RowStyles.Clear()
[void]$doneLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 62)))
[void]$doneLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
[void]$doneLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 72)))

$doneTop = New-Object System.Windows.Forms.Panel
$doneTop.Dock = 'Fill'
$doneTop.BackColor = [System.Drawing.Color]::White

$doneTitle = New-Object System.Windows.Forms.Label
$doneTitle.Text = 'Что я сделал'
$doneTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
$doneTitle.Location = New-Object System.Drawing.Point(14, 6)
$doneTitle.AutoSize = $true
$doneTop.Controls.Add($doneTitle)

$doneSubtitle = New-Object System.Windows.Forms.Label
$doneSubtitle.Text = 'Все изменения, которые программа внесла в систему. Любое можно отменить.'
$doneSubtitle.Location = New-Object System.Drawing.Point(16, 32)
$doneSubtitle.AutoSize = $true
$doneSubtitle.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 120)
$doneTop.Controls.Add($doneSubtitle)

$doneList = New-Object System.Windows.Forms.ListView
$doneList.AccessibleName = 'Сделанные изменения'
$doneList.Dock = 'Fill'
$doneList.View = 'Details'
$doneList.FullRowSelect = $true
$doneList.BorderStyle = 'FixedSingle'
$doneList.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$doneList.BackColor = [System.Drawing.Color]::White
[void]$doneList.Columns.Add('Когда', 150)
[void]$doneList.Columns.Add('Что изменено', 520)
[void]$doneList.Columns.Add('Детали', 430)

$doneBottom = New-Object System.Windows.Forms.Panel
$doneBottom.Dock = 'Fill'
$doneBottom.BackColor = [System.Drawing.Color]::White

$doneSummary = New-Object System.Windows.Forms.Label
$doneSummary.Text = 'Журнал пуст — программа ещё ничего не меняла.'
$doneSummary.Location = New-Object System.Drawing.Point(14, 6)
$doneSummary.AutoSize = $true
$doneBottom.Controls.Add($doneSummary)

$doneRefreshButton = New-Object System.Windows.Forms.Button
$doneRefreshButton.Text = 'Обновить'
$doneRefreshButton.Location = New-Object System.Drawing.Point(14, 30)
$doneRefreshButton.Size = New-Object System.Drawing.Size(120, 30)
$doneRefreshButton.FlatStyle = 'System'
$doneBottom.Controls.Add($doneRefreshButton)

$doneUndoButton = New-Object System.Windows.Forms.Button
$doneUndoButton.Text = 'Отменить всё'
$doneUndoButton.Location = New-Object System.Drawing.Point(144, 30)
$doneUndoButton.Size = New-Object System.Drawing.Size(170, 30)
$doneUndoButton.FlatStyle = 'System'
$doneBottom.Controls.Add($doneUndoButton)

$doneLayout.Controls.Add($doneTop, 0, 0)
$doneLayout.Controls.Add($doneList, 0, 1)
$doneLayout.Controls.Add($doneBottom, 0, 2)
$tabDone.Controls.Add($doneLayout)
[void]$tabs.TabPages.Add($tabDone)

# ----------------------------------------------------------------- network tab
$tabNetwork = New-Object System.Windows.Forms.TabPage
$tabNetwork.Text = '  Сеть  '
$tabNetwork.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 252)
$tabNetwork.Padding = New-Object System.Windows.Forms.Padding(4)

$netLayout = New-Object System.Windows.Forms.TableLayoutPanel
$netLayout.Dock = 'Fill'
$netLayout.ColumnCount = 1
$netLayout.RowCount = 3
[void]$netLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
[void]$netLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 64)))
[void]$netLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
[void]$netLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 150)))

$netTop = New-Object System.Windows.Forms.Panel
$netTop.Dock = 'Fill'
$netTop.BackColor = [System.Drawing.Color]::White
$netTitle = New-Object System.Windows.Forms.Label
$netTitle.Text = 'Сеть для CS2: виноват интернет или ПК?'
$netTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
$netTitle.Location = New-Object System.Drawing.Point(14, 6)
$netTitle.AutoSize = $true
$netTop.Controls.Add($netTitle)
$netInfo = New-Object System.Windows.Forms.Label
$netInfo.Text = 'Пинг, скачки и потери до роутера и до серверов Valve, через которые идут матчи CS2. Около 40 секунд, играть в это время не нужно.'
$netInfo.Location = New-Object System.Drawing.Point(16, 30)
$netInfo.Size = New-Object System.Drawing.Size(1060, 28)
$netInfo.Anchor = 'Top,Left,Right'
$netInfo.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 120)
$netTop.Controls.Add($netInfo)

$netList = New-Object System.Windows.Forms.ListView
$netList.AccessibleName = 'Результаты проверки сети'
$netList.Dock = 'Fill'
$netList.View = 'Details'
$netList.FullRowSelect = $true
$netList.BorderStyle = 'FixedSingle'
$netList.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$netList.BackColor = [System.Drawing.Color]::White
[void]$netList.Columns.Add('Что меряем', 330)
[void]$netList.Columns.Add('Результат', 330)
[void]$netList.Columns.Add('Вывод', 110)
[void]$netList.Columns.Add('Норма', 260)

$netBottom = New-Object System.Windows.Forms.Panel
$netBottom.Dock = 'Fill'
$netBottom.BackColor = [System.Drawing.Color]::White
$netTips = New-Object System.Windows.Forms.Label
$netTips.Text = 'Проверок ещё не было.'
$netTips.Location = New-Object System.Drawing.Point(14, 6)
$netTips.Size = New-Object System.Drawing.Size(1060, 70)
$netTips.Anchor = 'Top,Left,Right'
$netTips.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$netBottom.Controls.Add($netTips)
$netRunButton = New-Object System.Windows.Forms.Button
$netRunButton.Text = 'Проверить сеть'
$netRunButton.Location = New-Object System.Drawing.Point(14, 92)
$netRunButton.Size = New-Object System.Drawing.Size(200, 32)
$netRunButton.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$netRunButton.ForeColor = [System.Drawing.Color]::White
$netRunButton.FlatStyle = 'Flat'
$netRunButton.FlatAppearance.BorderSize = 0
$netRunButton.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$netBottom.Controls.Add($netRunButton)
$netLoad = New-Object System.Windows.Forms.CheckBox
$netLoad.Text = 'и под нагрузкой — как будто дома кто-то качает (скачает до 300 МБ тестовых данных)'
$netLoad.Checked = $true
$netLoad.AutoSize = $true
$netLoad.Location = New-Object System.Drawing.Point(230, 99)
$netBottom.Controls.Add($netLoad)

$netLayout.Controls.Add($netTop, 0, 0)
$netLayout.Controls.Add($netList, 0, 1)
$netLayout.Controls.Add($netBottom, 0, 2)
$tabNetwork.Controls.Add($netLayout)

# главная страница — первая и по умолчанию
# порядок важен для самопроверки (-Tab N): новые разделы — в конец
$script:AdvancedPages = @($tabSave, $tabRestore, $tabManual, $tabGame, $tabClean, $tabHealth, $tabResult, $tabDone, $tabStartup, $tabNetwork)
$script:ExpertMode = $true

# все разделы всегда на месте — переключение через боковое меню; функция оставлена для совместимости
function Set-UiMode {
    param([bool]$Expert)
    $script:ExpertMode = $true
}

$tabs.TabPages.Clear()
[void]$tabs.TabPages.Add($tabHome)
foreach ($page in $script:AdvancedPages) { [void]$tabs.TabPages.Add($page) }
$tabs.SelectedTab = $tabHome

# ------------------------------------------------------------------ sidebar
# заголовки вкладок скрыты; разделы переключаются меню слева, как в Параметрах Windows 11
$tabs.Appearance = [System.Windows.Forms.TabAppearance]::FlatButtons
$tabs.SizeMode = [System.Windows.Forms.TabSizeMode]::Fixed
$tabs.ItemSize = New-Object System.Drawing.Size(0, 1)
foreach ($page in $tabs.TabPages) { $page.BackColor = $script:Theme.Bg }

$sidebar = New-Object System.Windows.Forms.Panel
$sidebar.Dock = 'Fill'
$sidebar.BackColor = $script:Theme.Bg
$sidebar.Padding = New-Object System.Windows.Forms.Padding(8, 0, 4, 0)

$brand = New-Object System.Windows.Forms.Label
$brand.Text = 'pckit'
$brand.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 15)
$brand.ForeColor = $script:Theme.Text
$brand.Location = New-Object System.Drawing.Point(18, 14)
$brand.AutoSize = $true
$sidebar.Controls.Add($brand)

$brandSub = New-Object System.Windows.Forms.Label
$brandSub.Text = 'by odilbek'
$brandSub.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$brandSub.ForeColor = $script:Theme.Muted
$brandSub.Location = New-Object System.Drawing.Point(20, 44)
$brandSub.AutoSize = $true
$sidebar.Controls.Add($brandSub)

$script:NavItems = New-Object System.Collections.ArrayList

function Update-NavSelection {
    foreach ($n in $script:NavItems) { $n.Invalidate($true) }
}

function New-NavItem {
    param([string]$Icon, [string]$Text, $Page, [int]$Top)

    $item = New-Object System.Windows.Forms.Panel
    $item.Location = New-Object System.Drawing.Point(8, $Top)
    $item.Size = New-Object System.Drawing.Size(196, 38)
    $item.BackColor = $script:Theme.Bg
    $item.Cursor = [System.Windows.Forms.Cursors]::Hand
    $item.Tag = $Page
    $item.TabStop = $true
    $item.AccessibleRole = [System.Windows.Forms.AccessibleRole]::PageTab
    $item.AccessibleName = $Text

    $ic = New-Object System.Windows.Forms.Label
    $ic.Text = $Icon
    $ic.Font = New-Object System.Drawing.Font($script:IconFont, 11.5)
    $ic.ForeColor = $script:Theme.Text
    $ic.BackColor = [System.Drawing.Color]::Transparent
    $ic.TextAlign = 'MiddleCenter'
    $ic.Location = New-Object System.Drawing.Point(12, 7)
    $ic.Size = New-Object System.Drawing.Size(24, 24)
    $ic.Tag = $Page

    $tx = New-Object System.Windows.Forms.Label
    $tx.Text = $Text
    $tx.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $tx.ForeColor = $script:Theme.Text
    $tx.BackColor = [System.Drawing.Color]::Transparent
    $tx.Location = New-Object System.Drawing.Point(44, 9)
    $tx.AutoSize = $true
    $tx.Tag = $Page

    $item.Controls.Add($ic)
    $item.Controls.Add($tx)

    $item.Add_Paint({
            param($s, $e)
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $selected = ($tabs.SelectedTab -eq $s.Tag)
            $hot = $script:CardHot.ContainsKey($s) -and $script:CardHot[$s]
            if ($selected -or $hot) {
                $rect = New-Object System.Drawing.Rectangle(0, 0, ($s.Width - 1), ($s.Height - 1))
                $path = New-PckitRoundPath -Rect $rect -Radius 6
                $color = if ($selected) { $script:Theme.Card } else { $script:Theme.NavHover }
                $b = New-Object System.Drawing.SolidBrush($color)
                $g.FillPath($b, $path)
                $b.Dispose(); $path.Dispose()
            }
            if ($selected) {
                # акцентная «таблетка» слева, как у выбранного раздела в Windows 11
                $pill = New-PckitRoundPath -Rect (New-Object System.Drawing.Rectangle(0, 10, 3, 17)) -Radius 1
                $pb = New-Object System.Drawing.SolidBrush($script:Theme.Accent)
                $g.FillPath($pb, $pill)
                $pb.Dispose(); $pill.Dispose()
            }
            if ($s.Focused) {
                $fp = New-Object System.Drawing.Pen($script:Theme.Accent, 1)
                $g.DrawRectangle($fp, 1, 1, $s.Width - 3, $s.Height - 3)
                $fp.Dispose()
            }
        })

    $go = {
        param($s, $e)
        $page = $s.Tag
        if ($page) { $tabs.SelectedTab = $page }
    }
    $navOn = {
        param($s, $e)
        $c = if ($s -is [System.Windows.Forms.Panel]) { $s } else { $s.Parent }
        $script:CardHot[$c] = $true; $c.Invalidate($true)
    }
    $navOff = {
        param($s, $e)
        $c = if ($s -is [System.Windows.Forms.Panel]) { $s } else { $s.Parent }
        if (-not $c.ClientRectangle.Contains($c.PointToClient([System.Windows.Forms.Cursor]::Position))) { $script:CardHot[$c] = $false; $c.Invalidate($true) }
    }
    foreach ($ctl in @($item, $ic, $tx)) { $ctl.Add_Click($go); $ctl.Add_MouseEnter($navOn); $ctl.Add_MouseLeave($navOff) }
    $item.Add_Enter({ param($s, $e) $s.Invalidate($true) })
    $item.Add_Leave({ param($s, $e) $s.Invalidate($true) })
    $item.Add_KeyDown({
            param($s, $e)
            if ($e.KeyCode -in 'Return', 'Space') { $e.SuppressKeyPress = $true; $tabs.SelectedTab = $s.Tag }
        })

    [void]$script:NavItems.Add($item)
    $sidebar.Controls.Add($item)
    return $item
}

function New-NavHeader {
    param([string]$Text, [int]$Top)
    $h = New-Object System.Windows.Forms.Label
    $h.Text = $Text
    $h.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 8.5)
    $h.ForeColor = $script:Theme.Muted
    $h.Location = New-Object System.Drawing.Point(20, $Top)
    $h.AutoSize = $true
    $sidebar.Controls.Add($h)
}

$navTop = 84
# меню: «Главная» — для всех; ниже — то же самое по шагам, для тех, кто хочет выбрать сам
[void](New-NavItem -Icon $script:Icons.Home -Text 'Главная' -Page $tabHome -Top $navTop)
$navTop += 46
New-NavHeader -Text 'Выбрать самому' -Top $navTop
$navTop += 24
foreach ($entry in @(
        @($script:Icons.Game, 'Настройки', $tabGame),
        @($script:Icons.Clean, 'Чистка', $tabClean),
        @($script:Icons.Startup, 'Автозагрузка', $tabStartup),
        @($script:Icons.Health, 'Проверка', $tabHealth),
        @($script:Icons.Result, 'До и после', $tabResult),
        @(([string][char]0xE968), 'Сеть', $tabNetwork),
        @($script:Icons.Done, 'История и отмена', $tabDone))) {
    [void](New-NavItem -Icon $entry[0] -Text $entry[1] -Page $entry[2] -Top $navTop)
    $navTop += 38
}
$navTop += 8
New-NavHeader -Text 'Перенос на новую Windows' -Top $navTop
$navTop += 24
foreach ($entry in @(
        @($script:Icons.Save, 'Сохранить', $tabSave),
        @($script:Icons.Restore, 'Вернуть', $tabRestore),
        @($script:Icons.Manual, 'Установить вручную', $tabManual))) {
    [void](New-NavItem -Icon $entry[0] -Text $entry[1] -Page $entry[2] -Top $navTop)
    $navTop += 38
}

$navFoot = New-Object System.Windows.Forms.Label
$navFoot.Text = ''
$navFoot.Visible = $false   # подсказка про отмену теперь — кнопка «Вернуть как было» на главной
$navFoot.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$navFoot.ForeColor = $script:Theme.Muted
$navFoot.Size = New-Object System.Drawing.Size(190, 48)
$navFoot.Anchor = 'Bottom,Left'
$navFoot.Location = New-Object System.Drawing.Point(18, 560)
$sidebar.Controls.Add($navFoot)

$navAbout = New-Object System.Windows.Forms.LinkLabel
$navAbout.Text = ('О программе · v{0}' -f $script:PckitAppVersion)
$navAbout.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$navAbout.AutoSize = $true
$navAbout.LinkColor = $script:Theme.Muted
$navAbout.ActiveLinkColor = $script:Theme.Accent
$navAbout.Anchor = 'Bottom,Left'
$navAbout.Location = New-Object System.Drawing.Point(18, 612)
$sidebar.Controls.Add($navAbout)
$navAbout.Add_LinkClicked({ Show-AboutDialog })

$sidebar.Add_Resize({
        $navFoot.Top = [Math]::Max($navTop + 12, $sidebar.ClientSize.Height - 82)
        $navAbout.Top = $navFoot.Top + 52
    })

# ------------------------------------------------------------------- о программе, лог, удаление
function Show-AboutDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'О программе'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterParent'
    $dlg.ClientSize = New-Object System.Drawing.Size(460, 300)
    $dlg.BackColor = [System.Drawing.Color]::White
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)

    $t = New-Object System.Windows.Forms.Label
    $t.Text = ('pckit by odilbek  ·  версия {0}' -f $script:PckitAppVersion)
    $t.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
    $t.Location = New-Object System.Drawing.Point(18, 16); $t.AutoSize = $true
    $dlg.Controls.Add($t)

    $d = New-Object System.Windows.Forms.Label
    $d.Text = "Бесплатная настройка ПК для игр (CS2) и для работы.`r`n`r`n• Только безопасные для FACEIT и VAC изменения.`r`n• Каждое изменение записывается и отменяется кнопкой «Вернуть как было».`r`n• Перед изменениями — точка восстановления Windows.`r`n• Ничего не отправляет в интернет: обращается только к сайтам NVIDIA, Steam и Cloudflare (тест сети) — и только когда вы нажали кнопку."
    $d.Location = New-Object System.Drawing.Point(20, 50); $d.Size = New-Object System.Drawing.Size(425, 150)
    $d.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 80)
    $dlg.Controls.Add($d)

    $bLog = New-Object System.Windows.Forms.Button
    $bLog.Text = 'Сохранить лог для разработчика'
    $bLog.Location = New-Object System.Drawing.Point(20, 210); $bLog.Size = New-Object System.Drawing.Size(230, 32); $bLog.FlatStyle = 'System'
    $bLog.Add_Click({ Save-UiLogBundle | Out-Null })
    $dlg.Controls.Add($bLog)

    $bDel = New-Object System.Windows.Forms.Button
    $bDel.Text = 'Удалить pckit с этого ПК...'
    $bDel.Location = New-Object System.Drawing.Point(20, 250); $bDel.Size = New-Object System.Drawing.Size(230, 32); $bDel.FlatStyle = 'System'
    $bDel.Add_Click({ $dlg.Close(); Invoke-UninstallPckit })
    $dlg.Controls.Add($bDel)

    $bClose = New-Object System.Windows.Forms.Button
    $bClose.Text = 'Закрыть'
    $bClose.Location = New-Object System.Drawing.Point(330, 250); $bClose.Size = New-Object System.Drawing.Size(110, 32); $bClose.FlatStyle = 'System'
    $bClose.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dlg.Controls.Add($bClose)
    $dlg.AcceptButton = $bClose
    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
}

# удалить следы pckit: копии программы, замеры, логи, журнал. Отчёты в «Документах» и точки восстановления не трогаем.
function Invoke-UninstallPckit {
    $journal = Read-PckitJournal
    $hasChanges = -not (Test-PckitJournalEmpty -Journal $journal)
    $undoFirst = $false
    if ($hasChanges) {
        $q = [System.Windows.Forms.MessageBox]::Show(
            ("pckit менял настройки этого ПК ({0} изменений).`r`n`r`nДа — сначала вернуть всё как было, потом удалить программу.`r`nНет — удалить программу, а настройки оставить (отменить их потом будет нечем).`r`nОтмена — ничего не делать." -f (Get-PckitJournalCount -Journal $journal)),
            'pckit by odilbek — удаление', [System.Windows.Forms.MessageBoxButtons]::YesNoCancel, [System.Windows.Forms.MessageBoxIcon]::Question,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button1)
        if ($q -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
        $undoFirst = ($q -eq [System.Windows.Forms.DialogResult]::Yes)
    } else {
        $q = [System.Windows.Forms.MessageBox]::Show("Удалить pckit с этого ПК?`r`n`r`nУдалятся копии программы, замеры, логи и служебные файлы. Отчёты в «Документы\pckit» и точки восстановления Windows останутся.",
            'pckit by odilbek — удаление', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($q -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    if ($undoFirst) {
        $body = { param($root) . (Join-Path $root 'engine\Common.ps1'); . (Join-Path $root 'engine\Journal.ps1'); return (Restore-PckitJournal -Journal (Read-PckitJournal) -Run) }
        $res = (Invoke-Remote -Body $body -Arguments @($script:Root))[0]
        if ($res.Failed -gt 0) {
            [void][System.Windows.Forms.MessageBox]::Show(("Вернуть удалось не всё (ошибок: {0}). Удаление остановлено, чтобы не потерять журнал — посмотрите «История и отмена»." -f $res.Failed), 'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
    }
    Write-UiLog 'удаление pckit'
    $dirs = @((Join-Path $env:LOCALAPPDATA 'pckit'))
    try { $dirs += (Get-PckitStateRoot) } catch { }
    # программа сама лежит в %LOCALAPPDATA%\pckit — удаляем после выхода, отдельным процессом
    $list = ($dirs | Where-Object { $_ -and $_ -like '*pckit*' } | ForEach-Object { 'rmdir /s /q "{0}"' -f $_ }) -join ' & '
    Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c timeout /t 3 /nobreak >nul & ' + $list) -WindowStyle Hidden
    [void][System.Windows.Forms.MessageBox]::Show('pckit удалён. Окно закроется, файлы исчезнут через несколько секунд. Спасибо, что пользовались!', 'pckit by odilbek')
    $form.Close()
}

$tabs.Add_SelectedIndexChanged({ Update-NavSelection })

# окно: меню слева, содержимое справа
$form.Controls.Remove($tabs)
$shell = New-Object System.Windows.Forms.TableLayoutPanel
$shell.Dock = 'Fill'
$shell.ColumnCount = 2
$shell.RowCount = 1
$shell.BackColor = $script:Theme.Bg
[void]$shell.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 216)))
[void]$shell.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
[void]$shell.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
$shell.Controls.Add($sidebar, 0, 0)
$shell.Controls.Add($tabs, 1, 0)
$tabs.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 8)
$sidebar.Margin = New-Object System.Windows.Forms.Padding(0)
$form.Controls.Add($shell)
$form.BackColor = $script:Theme.Bg

# --------------------------------------------------------------- game tab logic
$script:Actions = @()

function Test-ActionSupported {
    param($Action)
    if (-not $Action.minBuild) { return $true }
    return ([Environment]::OSVersion.Version.Build -ge [int]$Action.minBuild)
}

$script:Hw = $null

# портрет ПК (видеокарта, ноутбук, диск, монитор, CS2) — считается в фоне один раз
function Get-UiHardware {
    if ($script:Hw) { return $script:Hw }
    try {
        $body = {
            param($root)
            . (Join-Path $root 'engine\Common.ps1')
            . (Join-Path $root 'engine\Journal.ps1')
            . (Join-Path $root 'engine\Actions.ps1')
            return (Get-PckitHardwareProfile)
        }
        $script:Hw = (Invoke-Remote -Body $body -Arguments @($script:Root))[0]
    } catch { $script:Hw = Get-PckitHardwareProfile }
    # тот же портрет — движку в этом окне (проверки requires не будут сканировать ПК ещё раз)
    $script:PckitHardwareCache = $script:Hw
    return $script:Hw
}

# «рекомендуемые» — подобраны под этот ПК: высокий/средний эффект, без экспертных и мифов,
# с учётом железа (requires / skipIf / boostIf в actions.json)
function Test-ActionRecommended {
    param($Action)
    return [bool](Get-PckitSmartAdvice -Action $Action -Hw (Get-UiHardware)).Recommended
}

function Get-ActionReason {
    param($Action)
    return [string](Get-PckitSmartAdvice -Action $Action -Hw (Get-UiHardware)).Reason
}

# понятный список того, что не получилось: «• Название: причина»
function Get-ApplyFailText {
    param($Res)
    $lines = New-Object System.Collections.ArrayList
    foreach ($r in @($Res.Results)) {
        if (-not $r) { continue }
        foreach ($s in @($r.Results)) {
            if ($s -and $s.Status -eq 'fail') {
                [void]$lines.Add(('  • {0}: {1}' -f $r.Action.title, $s.Message))
                break
            }
        }
    }
    if (-not $lines.Count) { return '' }
    return ("`r`n`r`nНе получилось:`r`n" + ($lines -join "`r`n"))
}

function Update-GameDetails {
    if (-not $gameList.SelectedItems.Count) { return }
    $a = $gameList.SelectedItems[0].Tag
    if (-not $a) { return }
    if ($a.myth) {
        $gameDetails.Text = ('Миф: {0}' -f $a.what) + "`r`n" + ('На самом деле: {0}' -f $a.effect)
        return
    }
    $text = ('Что делает: {0}' -f $a.what) + "`r`n" + ('Что даёт: {0}' -f $a.effect)
    if ($a.note) { $text += ('  Важно: {0}' -f $a.note) }
    $text += ('  Для вашего ПК: {0}.' -f (Get-ActionReason $a))
    $gameDetails.Text = $text
    if ($script:Tip) { $script:Tip.SetToolTip($gameDetails, $text) }
}

$script:GameItems = New-Object System.Collections.ArrayList   # все строки; в списке видны только прошедшие фильтр

function Update-GameStatuses {
    if (-not $script:Actions.Count) { return }
    $state = Get-PckitActionsState -Actions $script:Actions -SkipProgress
    $byId = @{}
    foreach ($s in $state) { $byId[[string]$s.Action.id] = $s }
    $applied = 0
    $applicable = 0
    foreach ($item in $script:GameItems) {
        $s = $byId[[string]$item.Tag.id]
        if (-not $s) { continue }
        if ($s.Status -notin 'myth', 'unsupported', 'notfit') { $applicable++ }
        switch ($s.Status) {
            'applied' { $item.SubItems[3].Text = 'включено'; $item.ForeColor = [System.Drawing.Color]::FromArgb(30, 120, 50); $applied++ }
            'partial' { $item.SubItems[3].Text = 'частично'; $item.ForeColor = [System.Drawing.Color]::FromArgb(150, 110, 20) }
            'myth' { $item.SubItems[3].Text = 'не применяется'; $item.ForeColor = [System.Drawing.Color]::FromArgb(140, 140, 150) }
            'unsupported' { $item.SubItems[3].Text = 'не для этой Windows'; $item.ForeColor = [System.Drawing.Color]::FromArgb(140, 140, 150) }
            'notfit' { $item.SubItems[3].Text = 'не подходит'; $item.ForeColor = [System.Drawing.Color]::FromArgb(140, 140, 150); $item.Checked = $false }
            default {
                $item.SubItems[3].Text = 'выключено'
                $item.ForeColor = if ($item.Tag.expert) { [System.Drawing.Color]::FromArgb(120, 70, 20) } else { [System.Drawing.Color]::FromArgb(40, 40, 45) }
            }
        }
        $item.ToolTipText = ("{0}`r`nСейчас: {1}. {2}" -f $item.Tag.what, $item.SubItems[3].Text, $(if ($s.Detail) { '(' + $s.Detail + ')' } else { '' }))
    }
    $script:GameStatusBase = ('включено: {0} из {1}' -f $applied, $applicable)
    $gameStatus.Text = $script:GameStatusBase
    Update-GameFilter
}

# фильтр + поиск: перестраиваем видимый список из общего, галки и группы сохраняются
function Update-GameFilter {
    $mode = [string]$gameFilter.SelectedItem
    $q = ([string]$gameSearch.Text).Trim()
    if ($q -eq $script:GameSearchHint) { $q = '' }
    $selId = $null
    if ($gameList.SelectedItems.Count) { $selId = [string]$gameList.SelectedItems[0].Tag.id }
    $gameList.BeginUpdate()
    try {
        $gameList.Items.Clear()
        foreach ($item in $script:GameItems) {
            $a = $item.Tag
            $state = [string]$item.SubItems[3].Text
            $show = switch ($mode) {
                'Подобрано под мой ПК' { [bool]$item.Text.StartsWith('★') }
                'Ещё не включено' { -not $a.myth -and $state -in 'выключено', 'частично' }
                'Мифы и плацебо' { [bool]$a.myth }
                default { -not $a.myth }
            }
            if ($show -and $q) {
                $hay = ('{0} {1} {2} {3}' -f $a.title, $a.what, $a.group, $item.SubItems[1].Text)
                $show = ($hay.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0)
            }
            if ($show) {
                [void]$gameList.Items.Add($item)
                # после Items.Clear() строка теряет группу — возвращаем
                if ($script:GameGroups -and $script:GameGroups.ContainsKey([string]$a.group)) { $item.Group = $script:GameGroups[[string]$a.group] }
            }
        }
    } finally { $gameList.EndUpdate() }
    if ($selId) {
        foreach ($item in $gameList.Items) { if ([string]$item.Tag.id -eq $selId) { $item.Selected = $true; break } }
    }
    $gameStatus.Text = ('{0} · в списке: {1} из {2}' -f $script:GameStatusBase, $gameList.Items.Count, $script:GameItems.Count)
}

# порядок разделов: сначала самое заметное для игры
$script:GameGroupOrder = @('Видеокарта', 'CS2', 'Работа', 'Питание', 'Игровой режим', 'Планировщик', 'Ввод', 'Графика', 'Сеть', 'Фон', 'Исправления', 'Удобство', 'Конфиденциальность', 'Службы и задачи', 'Мифы')

function Initialize-GameTab {
    $script:Actions = @(Get-PckitActions -Directory (Join-Path $script:Root 'data'))
    $gameHint.Text = 'Определяю железо...'
    [System.Windows.Forms.Application]::DoEvents()
    $hw = Get-UiHardware
    $hwLine = Format-PckitHardwareLine $hw
    if ($hwLine) { $homeHw.Text = ('Ваш ПК: ' + $hwLine) }
    if ($hwLine) { $gameHint.Text = ('Ваш ПК: {0}  ·  ★ — подобрано под него' -f $hwLine) }
    else { $gameHint.Text = 'Отметьте нужное. Каждое действие можно отменить — изменения записываются в журнал.' }

    # группы в нужном порядке; незнакомые разделы — в конец
    $gameList.Groups.Clear()
    $groups = @{}
    $names = @($script:GameGroupOrder) + @($script:Actions | ForEach-Object { [string]$_.group } | Where-Object { $script:GameGroupOrder -notcontains $_ } | Select-Object -Unique)
    foreach ($n in $names) {
        if (-not @($script:Actions | Where-Object { [string]$_.group -eq $n }).Count) { continue }
        $g = New-Object System.Windows.Forms.ListViewGroup($n, $n)
        [void]$gameList.Groups.Add($g)
        $groups[$n] = $g
    }

    $script:GameGroups = $groups
    $script:GameItems.Clear()
    foreach ($a in $script:Actions) {
        $titleText = [string]$a.title
        if ($a.myth) { $titleText = 'Миф: ' + $titleText }
        elseif ($a.expert) { $titleText = '⚠ ' + $titleText }
        $adv = Get-PckitSmartAdvice -Action $a -Hw $hw
        if ($adv.Recommended -and -not $a.myth) { $titleText = '★ ' + $titleText }
        $item = New-Object System.Windows.Forms.ListViewItem($titleText)
        [void]$item.SubItems.Add([string]$adv.Reason)
        [void]$item.SubItems.Add([string]$a.effectLevel)
        [void]$item.SubItems.Add('')
        [void]$item.SubItems.Add([string]$a.group)
        $item.Tag = $a
        $item.Group = $groups[[string]$a.group]
        [void]$script:GameItems.Add($item)
    }

    Update-GameStatuses
    if ($gameList.Items.Count) { $gameList.Items[0].Selected = $true; Update-GameDetails }
}
# -------------------------------------------------------------- clean tab logic
$script:CleanTargets = @()
$script:CleanCounted = $false

function Initialize-CleanTab {
    $script:CleanTargets = @(Get-PckitCleanTargets)

    $cleanList.BeginUpdate()
    try {
        $cleanList.Items.Clear()
        foreach ($target in $script:CleanTargets) {
            $item = New-Object System.Windows.Forms.ListViewItem([string]$target.Title)
            [void]$item.SubItems.Add([string]$target.What)
            [void]$item.SubItems.Add('—')
            [void]$item.SubItems.Add($(if ($target.Admin) { 'админ' } else { '—' }))
            $item.Tag = $target
            if ($target.Risk -eq 'medium') { $item.ForeColor = [System.Drawing.Color]::FromArgb(160, 110, 15) }
            [void]$cleanList.Items.Add($item)
        }
    } finally { $cleanList.EndUpdate() }
}

function Update-CleanSummary {
    $total = 0.0
    foreach ($item in $cleanList.Items) {
        $text = [string]$item.SubItems[2].Text
        $value = 0.0
        if ($text -match '([\d\.,]+)\s*ГБ') { $value = [double](($matches[1] -replace ',', '.')) * 1024 }
        elseif ($text -match '([\d\.,]+)\s*МБ') { $value = [double](($matches[1] -replace ',', '.')) }
        $total += $value
    }
    $cleanSummary.Text = ('Всего можно освободить: {0}' -f (Format-PckitSize $total))
}

function Count-CleanSizes {
    $cleanCountButton.Enabled = $false
    $cleanSummary.Text = 'Считаю размеры...'
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $body = {
            param($root)
            . (Join-Path $root 'engine\Common.ps1')
            . (Join-Path $root 'engine\Clean.ps1')
            $targets = Get-PckitCleanTargets
            return (Get-PckitCleanSizes -Targets $targets)
        }
        $out = Invoke-Remote -Body $body -Arguments @($script:Root)
        foreach ($row in @($out)) {
            foreach ($item in $cleanList.Items) {
                if ($item.Tag -and [string]$item.Tag.Id -eq [string]$row.Target.Id) {
                    # -1 = размер заранее не узнать (DISM): покажем «?», в сумму не идёт
                    if ([double]$row.SizeMb -lt 0) { $item.SubItems[2].Text = '?' }
                    else { $item.SubItems[2].Text = (Format-PckitSize $row.SizeMb) }
                    break
                }
            }
        }
        $script:CleanCounted = $true
        Update-CleanSummary
    } catch {
        $cleanSummary.Text = 'Не удалось посчитать: ' + $_.Exception.Message
    } finally {
        $cleanCountButton.Enabled = $true
    }
}

# ---------------------------------------------------------------- done tab logic
function Fill-DoneList {
    param($Journal)

    if (-not $Journal) { $Journal = Read-PckitJournal }
    $rows = @(Get-PckitJournalSummary -Journal $Journal | Sort-Object -Property At -Descending)

    $doneList.BeginUpdate()
    try {
        $doneList.Items.Clear()
        foreach ($r in $rows) {
            $when = [string]$r.At
            try { $when = ([datetime]$r.At).ToString('dd.MM.yyyy HH:mm') } catch { }
            $item = New-Object System.Windows.Forms.ListViewItem($when)
            [void]$item.SubItems.Add([string]$r.Title)
            [void]$item.SubItems.Add([string]$r.Detail)
            $item.Tag = $r
            [void]$doneList.Items.Add($item)
        }
    } finally { $doneList.EndUpdate() }

    if ($rows.Count) {
        $when = [string]$Journal.created
        try { $when = ([datetime]$Journal.created).ToString('dd.MM.yyyy HH:mm') } catch { }
        $doneSummary.Text = ('Изменений: {0} · журнал от {1}' -f $rows.Count, $when)
        $doneUndoButton.Enabled = $true
    } else {
        $doneSummary.Text = 'Журнал пуст — программа ещё ничего не меняла.'
        $doneUndoButton.Enabled = $false
    }
}

function Invoke-DoneUndo {
    $journal = Read-PckitJournal
    if (Test-PckitJournalEmpty -Journal $journal) {
        [void][System.Windows.Forms.MessageBox]::Show('Отменять нечего: журнал пуст.', 'pckit by odilbek',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }

    $rows = @(Get-PckitJournalSummary -Journal $journal)
    $preview = (@($rows | Select-Object -First 10) | ForEach-Object { '  • ' + $_.Title }) -join "`r`n"
    $more = ''
    if ($rows.Count -gt 10) { $more = "`r`n  … и ещё " + ($rows.Count - 10) }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Вернуть всё как было?`r`n`r`n" + $preview + $more), 'pckit by odilbek',
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $doneUndoButton.Enabled = $false
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $body = {
            param($root)
            . (Join-Path $root 'engine\Common.ps1')
            . (Join-Path $root 'engine\Journal.ps1')
            $j = Read-PckitJournal
            return (Restore-PckitJournal -Journal $j -Run)
        }
        $res = (Invoke-Remote -Body $body -Arguments @($script:Root))[0]
        Fill-DoneList
        try { Update-HomeNext } catch { }
        $left = @($res.Items | Where-Object { $_.Status -eq 'fail' } | Select-Object -First 5 | ForEach-Object { '  • {0}: {1}' -f $_.Title, $_.Message })
        $tail = if ($left.Count) { "`r`n`r`nНе получилось (останется в «История и отмена», можно повторить):`r`n" + ($left -join "`r`n") } else { "`r`n`r`nПерезагрузите ПК, чтобы всё вернулось полностью." }
        [void][System.Windows.Forms.MessageBox]::Show(
            ('Отменено: {0}, ошибок: {1}.' -f $res.Ok, $res.Failed) + $tail, 'pckit by odilbek',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show(('Не удалось отменить: ' + $_.Exception.Message), 'pckit by odilbek',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    } finally {
        $doneUndoButton.Enabled = $true
    }
}

# -------------------------------------------------------------- result logic
$script:LastCompare = $null
$script:FpsBefore = $null
$script:FpsAfter = $null

function Get-PckitFpsDir {
    $dir = Join-Path $env:LOCALAPPDATA 'pckit\fps'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return $dir
}

# последний замер «до», если после него ещё не было «после» (то есть сравнение впереди)
function Get-PendingBeforeSnapshot {
    foreach ($s in @(Get-PckitSnapshots)) {
        if ($s.Label -eq 'после') { return $null }
        if ($s.Label -eq 'до') { return $s }
    }
    return $null
}

function Get-LatestBeforeSnapshot {
    foreach ($s in @(Get-PckitSnapshots)) { if ($s.Label -eq 'до') { return $s } }
    return $null
}

function Invoke-SnapshotRemote {
    param([string]$Label)
    $body = {
        param($root, $label)
        . (Join-Path $root 'engine\Common.ps1')
        . (Join-Path $root 'engine\Snapshot.ps1')
        $snap = Get-PckitSnapshot -Label $label -Samples 8 -IntervalSeconds 2
        $path = Save-PckitSnapshot -Snapshot $snap
        return [pscustomobject]@{ Snapshot = $snap; Path = $path }
    }
    return (Invoke-Remote -Body $body -Arguments @($script:Root, $Label))[0]
}

# перед первыми изменениями — замер «до»; если «до» уже ждёт сравнения, не перезаписываем его
function Invoke-EnsureBeforeSnapshot {
    param([scriptblock]$SetText)
    try {
        if (Get-PendingBeforeSnapshot) { return }
        if ($SetText) { & $SetText 'Замеряю ПК до изменений (около 20 секунд, не трогайте компьютер)...' }
        $script:Busy = $true
        try { [void](Invoke-SnapshotRemote -Label 'до') } finally { $script:Busy = $false }
    } catch {
        # замер — не повод не применять настройки: просто сравнения не будет
        if ($SetText) { & $SetText ('Замер «до» не удался: ' + $_.Exception.Message) }
    }
}

function Load-LatestFps {
    foreach ($which in 'до', 'после') {
        $f = Get-ChildItem -LiteralPath (Get-PckitFpsDir) -Filter ('fps-{0}-*.json' -f $which) -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $f) { continue }
        try {
            $data = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($which -eq 'до') { $script:FpsBefore = $data } else { $script:FpsAfter = $data }
        } catch { }
    }
    Update-FpsLabel
}

function Format-FpsShort {
    param($Fps)
    if (-not $Fps) { return 'нет замера' }
    return ('{0:N0} FPS, 1% low {1:N0}' -f [double]$Fps.AvgFps, [double]$Fps.Low1Fps)
}

function Update-FpsLabel {
    if (-not $script:FpsBefore -and -not $script:FpsAfter) {
        $resultFpsLabel.Text = 'FPS меряется программой Intel PresentMon, 60 секунд, только вне матчей FACEIT.'
        return
    }
    $resultFpsLabel.Text = ('FPS до: {0}   ·   после: {1}' -f (Format-FpsShort $script:FpsBefore), (Format-FpsShort $script:FpsAfter))
}

function Get-VerdictColor {
    param([string]$Verdict)
    switch ($Verdict) {
        'лучше' { return [System.Drawing.Color]::FromArgb(30, 120, 50) }
        'хуже' { return [System.Drawing.Color]::FromArgb(180, 40, 40) }
        'нужна перезагрузка' { return [System.Drawing.Color]::FromArgb(160, 110, 15) }
        'изменено' { return [System.Drawing.Color]::FromArgb(0, 100, 180) }
        default { return [System.Drawing.Color]::FromArgb(90, 90, 100) }
    }
}

function Fill-ResultList {
    param($Rows, $Before, $After)

    $resultList.BeginUpdate()
    try {
        $resultList.Items.Clear()
        foreach ($r in @($Rows)) {
            if (-not $r) { continue }
            $item = New-Object System.Windows.Forms.ListViewItem([string]$r.Metric)
            [void]$item.SubItems.Add([string]$r.Before)
            [void]$item.SubItems.Add([string]$r.After)
            [void]$item.SubItems.Add([string]$r.Delta)
            [void]$item.SubItems.Add([string]$r.Verdict)
            [void]$item.SubItems.Add([string]$r.Note)
            $item.ForeColor = Get-VerdictColor ([string]$r.Verdict)
            $item.Tag = $r
            [void]$resultList.Items.Add($item)
        }
    } finally { $resultList.EndUpdate() }

    $better = @($Rows | Where-Object { $_.Verdict -eq 'лучше' }).Count
    $worse = @($Rows | Where-Object { $_.Verdict -eq 'хуже' }).Count
    $when = ''
    try { $when = ('замер «до»: {0} · «после»: {1} · ' -f ([datetime]$Before.Time).ToString('dd.MM HH:mm'), ([datetime]$After.Time).ToString('dd.MM HH:mm')) } catch { }
    $resultSummary.Text = ('{0}лучше: {1} · хуже: {2} · остальное — без заметной разницы' -f $when, $better, $worse)
}

function Get-ResultSummaryText {
    param($Rows)
    $lines = New-Object System.Collections.ArrayList
    foreach ($r in @($Rows)) {
        if ($r.Verdict -in 'лучше', 'хуже', 'нужна перезагрузка') {
            [void]$lines.Add(('  • {0}: {1} → {2} ({3})' -f $r.Metric, $r.Before, $r.After, $r.Verdict))
        }
    }
    $noise = @($Rows | Where-Object { $_.Verdict -in 'в пределах шума', 'без изменений' }).Count
    if ($noise) { [void]$lines.Add(('  • без заметной разницы: {0} показателей (так тоже бывает — значит, там и не было проблемы)' -f $noise)) }
    if (-not $lines.Count) { [void]$lines.Add('  • заметных изменений нет') }
    return ($lines -join "`r`n")
}

function Invoke-ResultCompare {
    param([scriptblock]$SetText)

    $beforeInfo = Get-LatestBeforeSnapshot
    if (-not $beforeInfo) {
        $ask = [System.Windows.Forms.MessageBox]::Show(
            "Замера «до» ещё нет — сравнивать не с чем.`r`n`r`nЗамерить компьютер сейчас (около 20 секунд)? Потом нажмите «Ускорить для игр» или «Почистить диск» и нажмите «Результат» ещё раз.",
            'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($ask -ne [System.Windows.Forms.DialogResult]::Yes) { return $null }
        if ($SetText) { & $SetText 'Замеряю ПК (около 20 секунд, не трогайте компьютер)...' }
        $script:Busy = $true
        try { [void](Invoke-SnapshotRemote -Label 'до') } finally { $script:Busy = $false }
        [void][System.Windows.Forms.MessageBox]::Show('Замер «до» сохранён. Теперь ускорьте или почистите ПК, лучше перезагрузитесь — и нажмите «Результат».',
            'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return $null
    }

    if ($SetText) { & $SetText 'Замеряю ПК после изменений (около 20 секунд, не трогайте компьютер)...' }
    $script:Busy = $true
    try { $after = Invoke-SnapshotRemote -Label 'после' } finally { $script:Busy = $false }
    $before = Read-PckitSnapshot -Path $beforeInfo.Path
    $rows = @(Compare-PckitSnapshot -Before $before -After $after.Snapshot)

    $fps = $null
    if ($script:FpsBefore -and $script:FpsAfter) { $fps = [pscustomobject]@{ Before = $script:FpsBefore; After = $script:FpsAfter } }
    $report = $null
    try { $report = Save-PckitCompareReport -Before $before -After $after.Snapshot -Rows $rows -Fps $fps } catch { }

    $script:LastCompare = [pscustomobject]@{ Before = $before; After = $after.Snapshot; Rows = $rows; Report = $report }
    Fill-ResultList -Rows $rows -Before $before -After $after.Snapshot
    $resultOpenButton.Enabled = [bool]$report
    return $script:LastCompare
}

# вердикт «помогло / не помогло»; если стало хуже — предложить откатить только последнюю партию изменений
function Invoke-SmartVerdict {
    param($Cmp)
    $v = Get-PckitSmartVerdict -Rows $Cmp.Rows -FpsBefore $script:FpsBefore -FpsAfter $script:FpsAfter
    $text = $v.Headline
    if (@($v.Lines).Count) { $text += "`r`n" + ((@($v.Lines) | ForEach-Object { '  • ' + $_ }) -join "`r`n") }
    # вердикт крупно в шапке вкладки «Результат»
    try {
        $resultInfo.Text = $v.Headline + $(if (@($v.Lines).Count) { '  ' + @($v.Lines)[0] } else { '' })
        $resultInfo.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
        $resultInfo.ForeColor = switch ($v.Level) {
            'good' { [System.Drawing.Color]::FromArgb(30, 120, 50) }
            'bad' { [System.Drawing.Color]::FromArgb(180, 40, 40) }
            default { [System.Drawing.Color]::FromArgb(70, 70, 80) }
        }
    } catch { }

    $batch = $null
    try { $batch = Get-PckitLastBatch } catch { }
    if ($v.SuggestUndo -and $batch -and $batch.since) {
        $titles = @()
        foreach ($a in @(Get-PckitActions -Directory (Join-Path $script:Root 'data'))) {
            if (@($batch.ids) -contains [string]$a.id) { $titles += ('  • ' + $a.title) }
        }
        $ask = [System.Windows.Forms.MessageBox]::Show(
            ($text + "`r`n`r`nОткатить последние изменения ({0})?`r`n{1}`r`n`r`nБолее ранние изменения останутся." -f ([datetime]$batch.since).ToString('dd.MM HH:mm'), (($titles | Select-Object -First 12) -join "`r`n")),
            'pckit by odilbek — стало хуже', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($ask -eq [System.Windows.Forms.DialogResult]::Yes) {
            $body = {
                param($root, $since)
                . (Join-Path $root 'engine\Common.ps1')
                . (Join-Path $root 'engine\Journal.ps1')
                . (Join-Path $root 'engine\Actions.ps1')
                $r = Restore-PckitJournal -Journal (Read-PckitJournal) -Run -Since $since
                if ($r.Failed -eq 0) { Clear-PckitLastBatch }
                return $r
            }
            try {
                $res = (Invoke-Remote -Body $body -Arguments @($script:Root, [string]$batch.since))[0]
                [void][System.Windows.Forms.MessageBox]::Show(
                    ("Откатил: {0}, ошибок: {1}.`r`n`r`nПерезагрузите ПК и сделайте замер ещё раз." -f $res.Ok, $res.Failed),
                    'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            } catch {
                [void][System.Windows.Forms.MessageBox]::Show(('Не удалось откатить: ' + $_.Exception.Message), 'pckit by odilbek',
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            }
        }
        return $null
    }
    return $text
}

# после изменений ПК перезагрузили, а сравнения ещё не было — пора честно сравнить «до» и «после»
function Get-RebootCompareState {
    $before = Get-PendingBeforeSnapshot
    if (-not $before) { return $null }
    try {
        $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
    } catch { return $null }
    if ($boot -le $before.Time) { return $null }
    $journal = Read-PckitJournal
    if (Test-PckitJournalEmpty -Journal $journal) { return $null }
    return [pscustomobject]@{ Before = $before; Boot = $boot; UptimeSec = ((Get-Date) - $boot).TotalSeconds }
}

function Invoke-RebootComparePrompt {
    $st = Get-RebootCompareState
    if (-not $st) { return }
    # первые минуты после загрузки Windows занята сама собой: замер был бы нечестным
    if ($st.UptimeSec -lt 180) {
        $wait = [int](180 - $st.UptimeSec) + 5
        $script:RebootTimer = New-Object System.Windows.Forms.Timer
        $script:RebootTimer.Interval = [math]::Max(1000, $wait * 1000)
        $script:RebootTimer.Add_Tick({ $script:RebootTimer.Stop(); Invoke-RebootComparePrompt })
        $script:RebootTimer.Start()
        $homeStatus.Text = ('После перезагрузки сравню «до» и «после» через {0} с — пусть Windows догрузится' -f $wait)
        return
    }
    $ask = [System.Windows.Forms.MessageBox]::Show(
        ("Вы перезагрузили ПК после настройки ({0}).`r`n`r`nСравнить «до» и «после» прямо сейчас? Это около 20 секунд — закройте браузер и не трогайте компьютер." -f $st.Before.Time.ToString('dd.MM HH:mm')),
        'pckit by odilbek — пора проверить результат', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($ask -eq [System.Windows.Forms.DialogResult]::Yes) { Invoke-HomeResult }
}

function Invoke-HomeResult {
    try {
        $cmp = Invoke-ResultCompare -SetText { param($t) Set-HomeProgress $t }
        if (-not $cmp) { return }
        $verdict = Invoke-SmartVerdict -Cmp $cmp
        if ($null -eq $verdict) { return }
        $text = $verdict + "`r`n`r`nЧто изменилось:`r`n`r`n" + (Get-ResultSummaryText $cmp.Rows)
        if ($script:FpsBefore -and $script:FpsAfter) {
            $text += ("`r`n  • FPS в CS2: {0} → {1}" -f (Format-FpsShort $script:FpsBefore), (Format-FpsShort $script:FpsAfter))
        }
        if ($cmp.Report) {
            $text += "`r`n`r`nОткрыть подробный отчёт?"
            $ans = [System.Windows.Forms.MessageBox]::Show($text, 'pckit by odilbek — результат',
                [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)
            if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) { Start-Process $cmp.Report }
        } else {
            [void][System.Windows.Forms.MessageBox]::Show($text, 'pckit by odilbek — результат',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        }
    } finally {
        Set-HomeProgress ''
    }
}

function Invoke-FpsMeasure {
    param([ValidateSet('до', 'после')][string]$Which)

    $exe = Find-PckitPresentMon
    if (-not $exe) {
        $resultFpsLabel.Text = 'Узнаю последнюю версию PresentMon...'
        [System.Windows.Forms.Application]::DoEvents()
        $rel = $null
        try {
            $body = { param($root) . (Join-Path $root 'engine\PresentMon.ps1'); return (Get-PckitPresentMonRelease) }
            $rel = (Invoke-Remote -Body $body -Arguments @($script:Root))[0]
        } catch {
            Update-FpsLabel
            [void][System.Windows.Forms.MessageBox]::Show(('Не удалось связаться с GitHub: ' + $_.Exception.Message), 'pckit by odilbek',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        $ask = [System.Windows.Forms.MessageBox]::Show(
            ("Для замера FPS нужна программа Intel PresentMon — бесплатная, с открытым кодом (лицензия MIT).`r`n`r`n" +
                ("Файл: {0} ({1:N1} МБ), версия {2}`r`n" -f $rel.Name, ($rel.SizeBytes / 1MB), $rel.Version) +
                "Откуда: официальный релиз github.com/GameTechDev/PresentMon`r`nПроверка: цифровая подпись Intel — без неё файл удаляется.`r`nКуда: %LOCALAPPDATA%\pckit\tools`r`n`r`nСкачать?"),
            'pckit by odilbek — PresentMon', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($ask -ne [System.Windows.Forms.DialogResult]::Yes) { Update-FpsLabel; return }
        $resultFpsLabel.Text = 'Скачиваю PresentMon и проверяю подпись...'
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $body = { param($root, $url, $name) . (Join-Path $root 'engine\PresentMon.ps1'); return (Install-PckitPresentMon -Url $url -Name $name) }
            $exe = (Invoke-Remote -Body $body -Arguments @($script:Root, $rel.Url, $rel.Name))[0]
        } catch {
            Update-FpsLabel
            [void][System.Windows.Forms.MessageBox]::Show(('PresentMon не установлен: ' + $_.Exception.Message), 'pckit by odilbek',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            return
        }
    }

    if (@(Get-Process -Name 'FACEIT', 'faceitclient' -ErrorAction SilentlyContinue).Count) {
        $f = [System.Windows.Forms.MessageBox]::Show(
            "Запущен клиент FACEIT. Замер FPS делайте только вне матчей FACEIT — в практике, с ботами или на демке.`r`n`r`nВы сейчас НЕ в матче FACEIT?",
            'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($f -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }

    $go = [System.Windows.Forms.MessageBox]::Show(
        ("Замер FPS «{0}» — 60 секунд.`r`n`r`n1. CS2 должна быть запущена, вы на карте (практика, боты или демка — НЕ матч FACEIT).`r`n2. Нажмите ОК и сразу переключитесь в игру.`r`n3. Для «до» и «после» повторяйте одну и ту же сцену — иначе сравнение нечестное.`r`n`r`nPresentMon только читает события Windows о кадрах и в игру не вмешивается." -f $Which),
        'pckit by odilbek — замер FPS', [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Information)
    if ($go -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $resultFpsBeforeButton.Enabled = $false
    $resultFpsAfterButton.Enabled = $false
    $resultFpsLabel.Text = ('Идёт замер FPS «{0}» (60 секунд)...' -f $Which)
    [System.Windows.Forms.Application]::DoEvents()
    $script:Busy = $true
    try {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $csv = Join-Path (Get-PckitFpsDir) ('fps-{0}-{1}.csv' -f $Which, $stamp)
        $body = {
            param($root, $exe, $csv)
            . (Join-Path $root 'engine\PresentMon.ps1')
            $cap = Invoke-PckitFpsCapture -Exe $exe -ProcessName 'cs2.exe' -Seconds 60 -OutCsv $csv
            if (-not $cap.Csv) { throw ('PresentMon не записал замер (код {0}). Перезапустите ПК и попробуйте ещё раз.' -f $cap.ExitCode) }
            return (Read-PckitFpsCsv -Path $cap.Csv)
        }
        $fps = (Invoke-Remote -Body $body -Arguments @($script:Root, $exe, $csv))[0]
        if (-not $fps -or [int]$fps.Frames -lt 100) { throw 'слишком мало кадров — игра была свёрнута или на паузе?' }
        $json = $fps | ConvertTo-Json -Depth 4
        [IO.File]::WriteAllText((Join-Path (Get-PckitFpsDir) ('fps-{0}-{1}.json' -f $Which, $stamp)), $json, (New-Object System.Text.UTF8Encoding($false)))
        if ($Which -eq 'до') { $script:FpsBefore = $fps } else { $script:FpsAfter = $fps }
        Update-FpsLabel
        [void][System.Windows.Forms.MessageBox]::Show(
            ("FPS «{0}»: средний {1:N0}, 1% low {2:N0}, 0.1% low {3:N0}, 99% кадров быстрее {4:N1} мс." -f $Which, [double]$fps.AvgFps, [double]$fps.Low1Fps, [double]$fps.Low01Fps, [double]$fps.P99FrameMs),
            'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    } catch {
        Update-FpsLabel
        [void][System.Windows.Forms.MessageBox]::Show(('Замер FPS не получился: ' + $_.Exception.Message), 'pckit by odilbek',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
    } finally {
        $script:Busy = $false
        $resultFpsBeforeButton.Enabled = $true
        $resultFpsAfterButton.Enabled = $true
    }
}

# --------------------------------------------------------------- home actions
function Set-HomeProgress {
    param([string]$Text)
    $homeProgress.Text = $Text
    [System.Windows.Forms.Application]::DoEvents()
}

# подсказка «что дальше» на главной: одна понятная ссылка на следующий шаг
# первый запуск: три строки «с чего начать»
function Show-WelcomeOnce {
    $flag = Join-Path $env:LOCALAPPDATA 'pckit\welcome-v2.flag'
    if (Test-Path -LiteralPath $flag) { return }
    [void][System.Windows.Forms.MessageBox]::Show(
        ("Привет! Это pckit {0}.`r`n`r`n1. Игровой ПК — нажмите «Ускорить для игр».`r`n   Хотите выжать всё — «Максимальное ускорение».`r`n   Рабочий ПК (офис, Photoshop, AutoCAD, Revit) — «Для работы».`r`n2. Перезагрузите компьютер.`r`n3. Откройте pckit снова — он сам сравнит «до» и «после».`r`n`r`nВсё, что программа меняет, отменяется кнопкой «Вернуть как было». Наведите мышь на кнопку — появится подсказка." -f $script:PckitAppVersion),
        'pckit by odilbek — добро пожаловать', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    try {
        $dir = Split-Path -Parent $flag
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Set-Content -LiteralPath $flag -Value (Get-Date).ToString('s')
    } catch { }
}
function Update-HomeNext {
    $text = ''; $action = $null
    try {
        $journal = Read-PckitJournal
        $empty = Test-PckitJournalEmpty -Journal $journal
        if (Get-RebootCompareState) {
            $text = 'Дальше: вы перезагрузились — сравните «до» и «после» →'; $action = { Invoke-HomeResult }
        } elseif (-not $empty -and (Get-PendingBeforeSnapshot)) {
            $text = 'Дальше: перезагрузите ПК — потом pckit сам предложит сравнить результат'
        } elseif ($empty) {
            $text = 'С чего начать: «Ускорить для игр» или «Для работы» — займёт пару минут'
        } elseif ($script:Health -and ($script:Health.Bad + $script:Health.Warn) -gt 0) {
            $text = ('Дальше: посмотрите замечания ({0}) — часть из них исправляется руками →' -f ($script:Health.Bad + $script:Health.Warn))
            $action = { Set-UiMode $true; $tabs.SelectedTab = $tabHealth; Update-NavSelection }
        } else {
            $text = 'Всё настроено — можно играть. Перед важной игрой загляните в «Сеть для CS2».'
        }
    } catch { }
    $homeNext.Text = $text
    $homeNext.Tag = $action
    if ($action) { $homeNext.LinkArea = New-Object System.Windows.Forms.LinkArea(0, $text.Length) }
    else { $homeNext.LinkArea = New-Object System.Windows.Forms.LinkArea(0, 0) }
}

function Invoke-HomeCheck {
    param([switch]$Quiet)

    Set-HomeProgress 'Проверяю компьютер...'
    try {
        Run-HealthCheck
        if (-not $script:Health) { return }
        $h = $script:Health

        if ($h.Bad -eq 0 -and $h.Warn -eq 0) {
            $homeStatus.Text = 'Компьютер в порядке — можно играть'
            $homeStatus.ForeColor = [System.Drawing.Color]::FromArgb(30, 120, 50)
        } elseif ($h.Bad -gt 0) {
            $homeStatus.Text = ('Есть проблемы: {0} — стоит посмотреть' -f $h.Bad)
            $homeStatus.ForeColor = [System.Drawing.Color]::FromArgb(180, 40, 40)
        } else {
            $homeStatus.Text = ('Замечаний: {0} — ничего критичного' -f $h.Warn)
            $homeStatus.ForeColor = [System.Drawing.Color]::FromArgb(160, 110, 15)
        }

        Update-HomeNext
        if ($Quiet) { return }

        $top = @($h.Findings | Where-Object { $_.Severity -in 'bad', 'warn' } | Select-Object -First 3)
        $lines = @("Проблем: $($h.Bad) · предупреждений: $($h.Warn) · заметок: $($h.Info)")
        foreach ($f in $top) { $lines += ('  • ' + $f.Title) }
        [void][System.Windows.Forms.MessageBox]::Show(($lines -join "`r`n"), 'pckit by odilbek — проверка готово',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    } finally {
        Set-HomeProgress ''
    }
}

# --- общие части «Почистить», «Ускорить» и «Всё сразу» ---

# что безопасно почистить: { Ids, TotalMb }
function Get-HomeCleanPlan {
    $body = {
        param($root)
        . (Join-Path $root 'engine\Common.ps1')
        . (Join-Path $root 'engine\Clean.ps1')
        # быстрая чистка: только безопасное и быстрое — без DISM, без «только сообщить» и без кэшей разработчика
        $targets = @(Get-PckitCleanTargets | Where-Object { $_.Risk -eq 'low' -and $_.Kind -notin 'dism', 'info', 'drivers' -and $_.Group -ne 'Разработка' })
        return [pscustomobject]@{ Sizes = (Get-PckitCleanSizes -Targets $targets); Ids = @($targets | ForEach-Object { $_.Id }) }
    }
    $out = (Invoke-Remote -Body $body -Arguments @($script:Root))[0]
    $total = 0.0
    $ids = New-Object System.Collections.ArrayList
    foreach ($s in @($out.Sizes)) {
        if ([double]$s.SizeMb -gt 0) { $total += [double]$s.SizeMb; [void]$ids.Add([string]$s.Target.Id) }
    }
    return [pscustomobject]@{ Ids = @($ids); TotalMb = $total }
}

function Invoke-HomeCleanRun {
    param([string[]]$Ids)
    $body = {
        param($root, $ids)
        . (Join-Path $root 'engine\Common.ps1')
        . (Join-Path $root 'engine\Clean.ps1')
        $all = Get-PckitCleanTargets
        $sel = @($all | Where-Object { $ids -contains $_.Id })
        return (Invoke-PckitClean -Targets $sel -Run)
    }
    Write-UiLog ('чистка: ' + ($Ids -join ', '))
    $res = (Invoke-Remote -Body $body -Arguments @($script:Root, $Ids))[0]
    Write-UiLog ('чистка: освобождено {0} МБ' -f $res.FreedMb)
    return $res
}

# что подобрано под этот ПК и ещё не включено: { Hw, Recommended, DoneCount }
function Get-HomeBoostPlan {
    # -Ids: свой набор (например, «Для работы») — берём из него всё, что не исключено правилами skipIf для этого железа
    # -Max: всё, что подходит этому железу, включая экспертные и слабые настройки (кроме мифов и того, что вредит этому ПК по skipIf)
    param([string[]]$Ids, [switch]$Max)
    $hw = Get-UiHardware
    $actions = @(Get-PckitActions -Directory (Join-Path $script:Root 'data'))
    if ($Max) {
        $candidates = @($actions | Where-Object {
                $adv = Get-PckitSmartAdvice -Action $_ -Hw $hw
                $adv.Applicable -and [string]$_.id -ne 'work.gpu' -and -not ($_.skipIf -and (Test-PckitHwCondition -Cond $_.skipIf -Hw $hw))
            })
    } elseif ($Ids) {
        $candidates = @($actions | Where-Object { $Ids -contains [string]$_.id -and -not $_.myth -and -not ($_.skipIf -and (Test-PckitHwCondition -Cond $_.skipIf -Hw $hw)) })
    } else {
        $candidates = @($actions | Where-Object { Test-ActionRecommended $_ })
    }
    $stateBody = {
        param($root, $ids)
        . (Join-Path $root 'engine\Common.ps1')
        . (Join-Path $root 'engine\Journal.ps1')
        . (Join-Path $root 'engine\Actions.ps1')
        $all = Get-PckitActions -Directory (Join-Path $root 'data')
        return @(Get-PckitActionsState -Actions @($all | Where-Object { $ids -contains $_.id }) -SkipProgress)
    }
    $done = @{}
    try {
        foreach ($s in @(Invoke-Remote -Body $stateBody -Arguments @($script:Root, @($candidates | ForEach-Object { $_.id })))) {
            if ($s -and $s.Status -in 'applied', 'notfit') { $done[[string]$s.Action.id] = $true }
        }
    } catch { }
    return [pscustomobject]@{
        Hw          = $hw
        Recommended = @($candidates | Where-Object { -not $done.ContainsKey([string]$_.id) })
        DoneCount   = $done.Count
    }
}

function Get-HomeSteamNote {
    param($Recommended)
    if (@($Recommended | Where-Object { $_.id -eq 'cs2.launch' }).Count -and @(Get-Process -Name 'steam' -ErrorAction SilentlyContinue).Count) {
        return "`r`n`r`nSteam сейчас открыт: параметр запуска CS2 применится, только если закрыть Steam (значок у часов → Выход)."
    }
    return ''
}

# точка восстановления: текст для итога или $null, если пользователь передумал
function New-HomeRestorePoint {
    Set-HomeProgress 'Создаю точку восстановления...'
    try {
        $rpBody = {
            param($root)
            . (Join-Path $root 'engine\Common.ps1')
            . (Join-Path $root 'engine\RestorePoint.ps1')
            return (New-PckitRestorePoint -Run)
        }
        $rp = (Invoke-Remote -Body $rpBody -Arguments @($script:Root))[0]
        if ($rp.Status -eq 'created') { return (' Точка восстановления создана.' + $(if ($rp.EnabledNow) { (' Для этого включена защита системы на диске {0}.' -f $env:SystemDrive) } else { '' })) }
        if ($rp.Status -eq 'exists') { return ' Свежая точка восстановления уже есть.' }
        if ($rp.Status -eq 'throttled') { return ' (Windows не создал точку восстановления; изменения всё равно отменяются кнопкой «Вернуть как было».)' }
        if ($rp.Status -eq 'failed') { throw $rp.Message }
        return ''
    } catch {
        # без точки восстановления молча не продолжаем: решает пользователь
        $cont = [System.Windows.Forms.MessageBox]::Show(
            ("Не удалось создать точку восстановления:`r`n{0}`r`n`r`nПродолжить без неё? Изменения всё равно записываются в журнал и отменяются кнопкой." -f $_.Exception.Message),
            'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($cont -ne [System.Windows.Forms.DialogResult]::Yes) { return $null }
        return ' Точки восстановления нет.'
    }
}

function Invoke-HomeBoostRun {
    param([string[]]$Ids)
    $body = {
        param($root, $ids)
        . (Join-Path $root 'engine\Common.ps1')
        . (Join-Path $root 'engine\Journal.ps1')
        . (Join-Path $root 'engine\Actions.ps1')
        $actions = Get-PckitActions -Directory (Join-Path $root 'data')
        $sel = @($actions | Where-Object { $ids -contains $_.id })
        return (Invoke-PckitActions -Actions $sel -Run)
    }
    Write-UiLog ('применяю: ' + ($Ids -join ', '))
    $res = (Invoke-Remote -Body $body -Arguments @($script:Root, $Ids))[0]
    foreach ($r in @($res.Results)) { foreach ($s in @($r.Results)) { if ($s.Status -eq 'fail') { Write-UiLog ('не применилось: {0}: {1}' -f $r.Action.id, $s.Message) 'warn' } } }
    return $res
}

$script:RebootText = 'Перезагрузите ПК: часть настроек действует только после этого. Потом откройте pckit — он сам предложит сравнить «до» и «после», а если стало хуже, откатит именно эти изменения.'

function Invoke-HomeClean {
    Set-HomeProgress 'Считаю, что можно почистить...'
    try {
        $plan = Get-HomeCleanPlan
        if ($plan.TotalMb -lt 1) {
            [void][System.Windows.Forms.MessageBox]::Show('Чистить нечего — всё уже чисто.', 'pckit by odilbek',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }
        $answer = [System.Windows.Forms.MessageBox]::Show(
            ("Можно безопасно освободить примерно {0}.`r`n`r`nПочистить?" -f (Format-PckitSize $plan.TotalMb)),
            'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        Invoke-EnsureBeforeSnapshot -SetText { param($t) Set-HomeProgress $t }
        Set-HomeProgress 'Очищаю...'
        $res = Invoke-HomeCleanRun -Ids $plan.Ids
        [void][System.Windows.Forms.MessageBox]::Show(
            ('Готово. Освобождено: {0}.' -f (Format-PckitSize $res.FreedMb)), 'pckit by odilbek',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        Invoke-HomeCheck -Quiet
    } finally {
        Set-HomeProgress ''
    }
}

function Invoke-HomeBoost {
    Set-HomeProgress 'Изучаю ваш ПК: видеокарта, монитор, диск, CS2...'
    try { $plan = Get-HomeBoostPlan } finally { Set-HomeProgress '' }
    $recommended = @($plan.Recommended)

    if (-not $recommended.Count) {
        [void][System.Windows.Forms.MessageBox]::Show(
            ("Ваш ПК уже настроен: всё, что подходит именно ему ({0}), включено.`r`n`r`nОстальное можно посмотреть во разделе «Настройки», а что ещё мешает — в «Проверке»." -f (Format-PckitHardwareLine $plan.Hw)),
            'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }

    $names = ($recommended | ForEach-Object { '  • {0} — {1}' -f $_.title, (Get-ActionReason $_) }) -join "`r`n"
    $already = if ($plan.DoneCount) { ("`r`nУже настроено раньше: {0}." -f $plan.DoneCount) } else { '' }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Ваш ПК: {0}`r`n`r`nПодобрал под него:`r`n$names$already{1}`r`n`r`nВсё записывается в журнал и отменяется одной кнопкой. Перед изменениями я замерю ПК (около 20 секунд), чтобы потом честно показать результат." -f (Format-PckitHardwareLine $plan.Hw), (Get-HomeSteamNote $recommended)),
        'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    Invoke-EnsureBeforeSnapshot -SetText { param($t) Set-HomeProgress $t }
    $rpNote = New-HomeRestorePoint
    if ($null -eq $rpNote) { Set-HomeProgress ''; return }

    Set-HomeProgress 'Применяю настройки...'
    try {
        $res = Invoke-HomeBoostRun -Ids @($recommended | ForEach-Object { $_.id })
        $okCount = @($res.Results).Count - $res.Failed
        [void][System.Windows.Forms.MessageBox]::Show(
            ("Готово. Применено настроек: {0}, ошибок: {1}.{2}{3}`r`n`r`n{4}`r`nОтменить всё — кнопка «Вернуть как было»." -f $okCount, $res.Failed, $rpNote, (Get-ApplyFailText $res), $script:RebootText),
            'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        Invoke-HomeCheck -Quiet
    } finally {
        Set-HomeProgress ''
    }
}

# «Ускорить для игр» (и «Максимальное ускорение» с -Max): проверка → настройки под этот ПК → безопасная чистка → что сделать руками → перезагрузка
function Invoke-HomeAll {
    param([switch]$Max)
    Set-HomeProgress 'Шаг 1 из 3: изучаю ваш ПК...'
    try {
        $boost = Get-HomeBoostPlan -Max:$Max
        Set-HomeProgress 'Шаг 2 из 3: считаю, что можно почистить...'
        $clean = Get-HomeCleanPlan
        Set-HomeProgress 'Шаг 3 из 3: ищу, что мешает играм...'
        Run-HealthCheck
    } finally { Set-HomeProgress '' }

    $recommended = @($boost.Recommended)
    # то, что программа исправить не может: монитор, XMP, Reflex, диск — человек делает руками
    $manual = @()
    if ($script:Health) {
        $manual = @($script:Health.Findings | Where-Object { $_.Severity -in 'bad', 'warn' -and -not $_.FixAction })
    }
    # свежий драйвер NVIDIA — тоже «руками»: ставит человек, не программа
    try {
        Set-HomeProgress 'Проверяю, свежий ли драйвер видеокарты...'
        $dc = Get-UiDriverCheck
        if ($dc -and $dc.Status -eq 'outdated') {
            $manual = @([pscustomobject]@{ Title = ('Вышел новый драйвер NVIDIA {0} (у вас {1})' -f $dc.Latest.Version, $dc.Installed); Hint = '«Проверка» → «Свежий ли драйвер?» откроет страницу NVIDIA'; Severity = 'warn' }) + $manual
        }
    } catch { } finally { Set-HomeProgress '' }

    $parts = New-Object System.Collections.ArrayList
    if ($Max -and $recommended.Count) {
        # рискованное — отдельным списком и с последствиями, остальное — одной строкой
        $risky = @($recommended | Where-Object { $_.expert -or [string]$_.risk -ne 'low' })
        $safe = @($recommended | Where-Object { -not ($_.expert -or [string]$_.risk -ne 'low') })
        if ($safe.Count) { [void]$parts.Add(('Безопасные настройки под ваш ПК: {0} (всё, что делает «Ускорить», и ещё слабые по эффекту).' -f $safe.Count)) }
        if ($risky.Count) {
            [void]$parts.Add(("С риском ({0}) — у некоторых есть цена:`r`n{1}" -f $risky.Count, (($risky | ForEach-Object { $why = if ($_.note) { [string]$_.note } else { [string]$_.effect }; '  • {0}' -f $_.title + $(if ($why) { "`r`n      " + $why } else { '' }) }) -join "`r`n")))
        }
    } elseif ($recommended.Count) {
        [void]$parts.Add(("Настройки под ваш ПК ({0}):`r`n{1}" -f $recommended.Count, (($recommended | ForEach-Object { '  • ' + $_.title }) -join "`r`n")))
    } else {
        [void]$parts.Add('Настройки: всё, что подходит вашему ПК, уже включено.')
    }
    if ($clean.TotalMb -ge 1) { [void]$parts.Add(('Чистка: освобожу примерно {0} (только безопасное).' -f (Format-PckitSize $clean.TotalMb))) }
    else { [void]$parts.Add('Чистка: чистить нечего.') }

    if (-not $recommended.Count -and $clean.TotalMb -lt 1) {
        $msg = 'Ваш ПК уже настроен и чист.'
        if ($manual.Count) { $msg += "`r`n`r`nОсталось сделать руками:`r`n" + (($manual | ForEach-Object { '  • {0} — {1}' -f $_.Title, $_.Hint }) -join "`r`n") }
        [void][System.Windows.Forms.MessageBox]::Show($msg, 'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }

    $caption = if ($Max) { 'pckit by odilbek — максимальное ускорение' } else { 'pckit by odilbek — ускорить для игр' }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Ваш ПК: {0}`r`n`r`n{1}{2}`r`n`r`nПеред изменениями замерю ПК (около 20 секунд) и создам точку восстановления. Всё отменяется кнопкой «Вернуть как было». Начать?" -f (Format-PckitHardwareLine $boost.Hw), ($parts -join "`r`n`r`n"), (Get-HomeSteamNote $recommended)),
        $caption, [System.Windows.Forms.MessageBoxButtons]::YesNo, $(if ($Max) { [System.Windows.Forms.MessageBoxIcon]::Warning } else { [System.Windows.Forms.MessageBoxIcon]::Question }),
        $(if ($Max) { [System.Windows.Forms.MessageBoxDefaultButton]::Button2 } else { [System.Windows.Forms.MessageBoxDefaultButton]::Button1 }))
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    Invoke-EnsureBeforeSnapshot -SetText { param($t) Set-HomeProgress $t }
    $summary = New-Object System.Collections.ArrayList
    try {
        if ($recommended.Count) {
            $rpNote = New-HomeRestorePoint
            if ($null -eq $rpNote) { Set-HomeProgress ''; return }
            Set-HomeProgress 'Применяю настройки...'
            $res = Invoke-HomeBoostRun -Ids @($recommended | ForEach-Object { $_.id })
            [void]$summary.Add(('Настройки: применено {0}, ошибок {1}.{2}{3}' -f (@($res.Results).Count - $res.Failed), $res.Failed, $rpNote, (Get-ApplyFailText $res)))
        }
        if ($clean.TotalMb -ge 1) {
            Set-HomeProgress 'Очищаю...'
            $cr = Invoke-HomeCleanRun -Ids $clean.Ids
            [void]$summary.Add(('Чистка: освобождено {0}.' -f (Format-PckitSize $cr.FreedMb)))
        }
    } finally { Set-HomeProgress '' }

    $text = 'Готово.' + "`r`n`r`n" + ($summary -join "`r`n")
    if ($manual.Count) {
        $text += "`r`n`r`nЭто программа исправить не может — сделайте руками:`r`n" + (($manual | Select-Object -First 6 | ForEach-Object { '  • {0}' -f $_.Title + $(if ($_.Hint) { ' — ' + $_.Hint } else { '' }) }) -join "`r`n")
    }
    $text += "`r`n`r`n" + $script:RebootText + "`r`n`r`nПерезагрузить компьютер сейчас?"
    $rb = [System.Windows.Forms.MessageBox]::Show($text, 'pckit by odilbek — готово',
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
    Invoke-HomeCheck -Quiet
    if ($rb -eq [System.Windows.Forms.DialogResult]::Yes) {
        # 10 секунд, чтобы успеть сохранить открытое; отмена — shutdown /a
        & shutdown.exe /r /t 10 /c 'pckit: перезагрузка после настройки' 2>&1 | Out-Null
    }
}

# «Для работы»: настройки офисного/рабочего ПК (без игровых), чистка мусора и кэшей рабочих программ,
# крупное и спорное — только показать
function Invoke-HomeWork {
    Set-HomeProgress 'Шаг 1 из 3: изучаю ПК и рабочие программы...'
    try {
        $plan = Get-HomeBoostPlan -Ids @(Get-PckitWorkProfileIds)
        $hw = $plan.Hw
        $appBody = {
            param($root)
            . (Join-Path $root 'engine\Common.ps1')
            . (Join-Path $root 'engine\Journal.ps1')
            . (Join-Path $root 'engine\Actions.ps1')
            $apps = @(Get-PckitWorkApps -NoExe)
            return [pscustomobject]@{ Apps = $apps; Reports = @(Get-PckitWorkReports -Apps $apps) }
        }
        Set-HomeProgress 'Шаг 2 из 3: ищу рабочие программы и крупные забытые файлы...'
        $info = (Invoke-Remote -Body $appBody -Arguments @($script:Root))[0]
        $reports = @($info.Reports | Where-Object { $_ })
        Set-HomeProgress 'Шаг 3 из 3: считаю мусор...'
        $clean = Get-HomeCleanPlan
    } finally { Set-HomeProgress '' }

    $todo = @($plan.Recommended)
    $apps = @($info.Apps)
    $appsText = if ($apps.Count) { (($apps | ForEach-Object { '  • {0}' -f (($_.Programs | Select-Object -First 2) -join ', ') + $(if (-not $_.Programs.Count) { $_.Title } else { '' }) }) -join "`r`n") } else { '  • известных рабочих программ не нашёл — сделаю общую уборку' }
    $setText = if ($todo.Count) { (($todo | ForEach-Object { '  • ' + $_.title }) -join "`r`n") } else { '  • всё уже настроено' }
    $cleanText = if ($clean.TotalMb -ge 1) { ('освобожу примерно {0} (временные файлы, кэши браузеров и рабочих программ)' -f (Format-PckitSize $clean.TotalMb)) } else { 'чистить нечего' }

    if (-not $todo.Count -and $clean.TotalMb -lt 1 -and -not $reports.Count) {
        [void][System.Windows.Forms.MessageBox]::Show('Этот ПК уже настроен и чист.', 'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Рабочий ПК: {0}`r`n`r`nНашёл программы:`r`n{1}`r`n`r`nНастройки ({2}):`r`n{3}`r`n`r`nЧистка: {4}.`r`n`r`nКрупное и спорное (бэкапы, «Загрузки», кэш OneDrive) НЕ удаляю — в конце покажу списком.`r`nПеред изменениями — замер и точка восстановления; настройки отменяются кнопкой «Вернуть как было». Начать?" -f (Format-PckitHardwareLine $hw), $appsText, $todo.Count, $setText, $cleanText),
        'pckit by odilbek — для работы', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    Invoke-EnsureBeforeSnapshot -SetText { param($t) Set-HomeProgress $t }
    $summary = New-Object System.Collections.ArrayList
    try {
        if ($todo.Count) {
            $rpNote = New-HomeRestorePoint
            if ($null -eq $rpNote) { Set-HomeProgress ''; return }
            Set-HomeProgress 'Применяю настройки...'
            $res = Invoke-HomeBoostRun -Ids @($todo | ForEach-Object { $_.id })
            [void]$summary.Add(('Настройки: применено {0}, ошибок {1}.{2}{3}' -f (@($res.Results).Count - $res.Failed), $res.Failed, $rpNote, (Get-ApplyFailText $res)))
        }
        if ($clean.TotalMb -ge 1) {
            Set-HomeProgress 'Очищаю...'
            $cr = Invoke-HomeCleanRun -Ids $clean.Ids
            [void]$summary.Add(('Чистка: освобождено {0}.' -f (Format-PckitSize $cr.FreedMb)))
        }
    } finally { Set-HomeProgress '' }

    $text = 'Готово.' + "`r`n`r`n" + ($summary -join "`r`n")
    $folders = @()
    if ($reports.Count) {
        $text += "`r`n`r`nКрупное — посмотрите и удалите сами, если не нужно:"
        foreach ($r in ($reports | Select-Object -First 8)) {
            $size = if ([double]$r.SizeMb -ge 0) { Format-PckitSize $r.SizeMb } else { 'много' }
            $text += ("`r`n  • {0} — {1}`r`n     {2}" -f $r.Title, $size, $r.What)
            if ([string]$r.Path -notlike 'ms-settings:*' -and $folders -notcontains $r.Path) { $folders += [string]$r.Path }
        }
    }
    if ($folders.Count) {
        $text += "`r`n`r`nОткрыть эти папки, чтобы посмотреть?"
        $o = [System.Windows.Forms.MessageBox]::Show($text, 'pckit by odilbek — готово', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)
        if ($o -eq [System.Windows.Forms.DialogResult]::Yes) { foreach ($p in ($folders | Select-Object -First 4)) { try { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $p) } catch { } } }
    } else {
        [void][System.Windows.Forms.MessageBox]::Show($text, 'pckit by odilbek — готово', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }
    Invoke-HomeCheck -Quiet
}

function Invoke-HomePack {
    if (-not $script:Catalog) {
        Set-HomeProgress 'Собираю список программ...'
        try {
            Invoke-CatalogScan
            Save-CatalogCache
        } finally { Set-HomeProgress '' }
    }
    if (-not $script:Catalog) { return }

    $documents = [Environment]::GetFolderPath('MyDocuments')
    $save = New-Object System.Windows.Forms.SaveFileDialog
    $save.Title = 'Куда сохранить слепок'
    $save.Filter = 'Слепок pckit (*.pckit)|*.pckit'
    $save.FileName = ('slepok-{0}.pckit' -f (Get-Date).ToString('yyyy-MM-dd'))
    $save.InitialDirectory = $documents
    if ($save.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $outFile = $save.FileName

    $ids = @()
    foreach ($item in $script:Catalog.Items) {
        if (($item.Kind -eq 'app' -and $item.Default) -or ($item.Kind -eq 'os' -and $item.Default)) { $ids += [string]$item.Id }
    }

    Set-HomeProgress 'Сохраняю настройки...'
    try {
        $catalogJson = ConvertTo-PckitJson $script:Catalog
        $body = {
            param($root, $catalogJson, $ids, $outFile)
            . (Join-Path $root 'engine\Common.ps1')
            . (Join-Path $root 'engine\Recipes.ps1')
            . (Join-Path $root 'engine\Catalog.ps1')
            . (Join-Path $root 'engine\Packer.ps1')
            $catalog = $catalogJson | ConvertFrom-Json
            $selection = @($catalog.Items | Where-Object { $ids -contains $_.Id })
            $name = [IO.Path]::GetFileNameWithoutExtension($outFile)
            $result = New-PckitProfile -Catalog $catalog -Selection $selection -OutFile $outFile -Name $name
            return [pscustomobject]@{ Path = $result.Path; SizeMb = $result.SizeMb; Items = $result.Items }
        }
        $res = (Invoke-Remote -Body $body -Arguments @($script:Root, $catalogJson, $ids, $outFile))[0]
        [void][System.Windows.Forms.MessageBox]::Show(
            ("Слепок готов:`r`n{0}`r`n`r`nОбъектов: {1}. Скопируйте файл на флешку или внешний диск — после переустановки Windows он вернёт программы и настройки." -f $res.Path, $res.Items),
            'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    } finally {
        Set-HomeProgress ''
    }
}

# ------------------------------------------------------------- report tab logic
$script:Health = $null

function Get-SeverityLabel([string]$Severity) {
    switch ($Severity) {
        'bad' { return 'проблема' }
        'warn' { return 'предупреждение' }
        'info' { return 'заметка' }
        default { return 'в порядке' }
    }
}

function Fill-HealthList {
    if (-not $script:Health) { return }

    $rank = @{ 'bad' = 0; 'warn' = 1; 'info' = 2; 'ok' = 3 }
    $sorted = @($script:Health.Findings | Sort-Object -Property @{ Expression = { $r = $rank[[string]$_.Severity]; if ($null -eq $r) { 9 } else { $r } } })

    $healthList.BeginUpdate()
    try {
        $healthList.Items.Clear()
        foreach ($f in $sorted) {
            $item = New-Object System.Windows.Forms.ListViewItem((Get-SeverityLabel $f.Severity))
            [void]$item.SubItems.Add([string]$f.Title)
            [void]$item.SubItems.Add([string]$f.Detail)
            $item.Tag = $f
            switch ($f.Severity) {
                'bad' { $item.ForeColor = [System.Drawing.Color]::FromArgb(180, 40, 40) }
                'warn' { $item.ForeColor = [System.Drawing.Color]::FromArgb(160, 110, 15) }
                'info' { $item.ForeColor = [System.Drawing.Color]::FromArgb(30, 100, 150) }
                default { $item.ForeColor = [System.Drawing.Color]::FromArgb(30, 120, 50) }
            }
            [void]$healthList.Items.Add($item)
        }
    } finally { $healthList.EndUpdate() }

    $healthSummary.Text = ('Проблем: {0} · предупреждений: {1} · заметок: {2} · в порядке: {3}' -f `
            $script:Health.Bad, $script:Health.Warn, $script:Health.Info, $script:Health.Ok)
    $m = $script:Health.Machine
    $healthMachineLabel.Text = ('{0} · {1} · {2} · {3}' -f $m.Cpu, $m.Ram, $m.GpuName, $m.Disk)
    $healthSaveButton.Enabled = $true
    $healthFixButton.Enabled = $false
    if ($healthList.Items.Count) { $healthList.Items[0].Selected = $true }
}

function Run-HealthCheck {
    $healthCheckButton.Enabled = $false
    $healthSummary.Text = 'Проверяю...'
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $body = {
            param($root)
            . (Join-Path $root 'engine\Common.ps1')
            . (Join-Path $root 'engine\Journal.ps1')
            . (Join-Path $root 'engine\Actions.ps1')
            . (Join-Path $root 'engine\Health.ps1')
            return (Get-PckitHealthReport -ActionsDir (Join-Path $root 'data'))
        }
        $out = Invoke-Remote -Body $body -Arguments @($script:Root)
        $script:Health = $out[0]
        Fill-HealthList
    } catch {
        $healthSummary.Text = 'Ошибка проверки: ' + $_.Exception.Message
    } finally {
        $healthCheckButton.Enabled = $true
    }
}

function GoTo-FixAction {
    param([string]$ActionId)
    if (-not $ActionId) { return }
    # нужная строка может быть скрыта фильтром — показываем всё
    $gameSearch.Text = ''
    $gameFilter.SelectedIndex = 0
    Update-GameFilter
    foreach ($item in $gameList.Items) {
        if ($item.Tag -and [string]$item.Tag.id -eq $ActionId) {
            $item.Checked = $true
            $item.Selected = $true
            $item.EnsureVisible()
            break
        }
    }
    Set-UiMode $true
    $tabs.SelectedTab = $tabGame
}

# ------------------------------------------------------------ remote helpers
$script:ProfilePath = $null
$script:RemoteTick = $null

function Invoke-Remote {
    param([scriptblock]$Body, [object[]]$Arguments)

    $ps = [powershell]::Create()
    [void]$ps.AddScript($Body)
    foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
    $async = $ps.BeginInvoke()
    while (-not $async.IsCompleted) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($script:RemoteTick) { & $script:RemoteTick }
        Start-Sleep -Milliseconds 120
    }
    try {
        $output = $ps.EndInvoke($async)
        $errors = @($ps.Streams.Error)
        foreach ($er in $errors) { Write-UiLog ('фон: ' + $er.ToString() + ' @ ' + $er.InvocationInfo.PositionMessage) 'warn' }
    } finally {
        $ps.Dispose()   # раньше при исключении из EndInvoke runspace утекал
    }
    # одна несмертельная ошибка (например, нет доступа к одной папке) не должна отбрасывать весь результат
    if ($errors.Count -and -not @($output).Count) { throw $errors[0].ToString() }
    return $output
}

function Fill-RestoreList {
    param($Plan)

    $restoreList.BeginUpdate()
    try {
        $restoreList.Items.Clear()
        foreach ($step in $Plan) {
            if ($step.Action -eq 'skip') { continue }
            $item = New-Object System.Windows.Forms.ListViewItem($step.Action)
            [void]$item.SubItems.Add([string]$step.Title)
            [void]$item.SubItems.Add([string]$step.Detail)
            [void]$item.SubItems.Add('')
            $item.Tag = $step
            if ($step.Risk -eq 'high') { $item.ForeColor = [System.Drawing.Color]::FromArgb(180, 50, 50) }
            elseif ($step.Action -eq 'manual') { $item.ForeColor = [System.Drawing.Color]::FromArgb(150, 100, 10) }
            [void]$restoreList.Items.Add($item)
        }
    } finally { $restoreList.EndUpdate() }
    $restoreStatus.Text = ('Шагов в плане: {0}' -f $restoreList.Items.Count)
}

function Fill-ManualList {
    $manufacturerFile = Join-Path $script:Root 'data\manual-apps.json'
    $manualList.BeginUpdate()
    try {
        $manualList.Items.Clear()
        if (-not (Test-Path -LiteralPath $manufacturerFile)) { return }
        $rawManual = Get-Content -LiteralPath $manufacturerFile -Raw -Encoding UTF8
        $parsedManual = ConvertFrom-Json $rawManual
        $entries = @($parsedManual)

        $installedNames = @()
        if ($script:Catalog) { $installedNames = @($script:Catalog.Items | Where-Object { $_.Kind -eq 'app' } | ForEach-Object { $_.Title }) }

        foreach ($entry in $entries) {
            $item = New-Object System.Windows.Forms.ListViewItem([string]$entry.title)
            [void]$item.SubItems.Add([string]$entry.vendor)
            [void]$item.SubItems.Add([string]$entry.note)
            $here = 'нет'
            if ($installedNames.Count -and $entry.pattern) {
                foreach ($name in $installedNames) {
                    try { if ($name -match $entry.pattern) { $here = 'да'; break } } catch { }
                }
            }
            [void]$item.SubItems.Add($here)
            $item.Tag = $entry
            if ($here -eq 'нет') { $item.ForeColor = [System.Drawing.Color]::FromArgb(130, 130, 140) }
            [void]$manualList.Items.Add($item)
        }
    } finally { $manualList.EndUpdate() }
    $manualStatus.Text = ('карточек: {0}' -f $manualList.Items.Count)
}

# --------------------------------------------------------------- tab handlers
$openProfileButton.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = 'Выберите профиль'
        $dlg.Filter = 'Профиль pckit (*.pckit)|*.pckit|Все файлы (*.*)|*.*'
        if ($dlg.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }

        $script:ProfilePath = $dlg.FileName
        $restorePathLabel.Text = [IO.Path]::GetFileName($dlg.FileName)
        $restoreHintLabel.Text = 'Считаю план...'
        $restoreStatus.Text = 'Считаю план...'
        $applyButton.Enabled = $false
        [System.Windows.Forms.Application]::DoEvents()

        try {
            $body = {
                param($root, $profilePath)
                . (Join-Path $root 'engine\Common.ps1')
                . (Join-Path $root 'engine\Recipes.ps1')
                . (Join-Path $root 'engine\Catalog.ps1')
                . (Join-Path $root 'engine\Packer.ps1')
                . (Join-Path $root 'engine\Planner.ps1')
                . (Join-Path $root 'engine\Journal.ps1')
                . (Join-Path $root 'engine\Applier.ps1')
                $p = Expand-PckitProfile -Path $profilePath
                try {
                    $plan = Get-PckitPlan -Manifest $p.Manifest
                    $names = @($p.Manifest.manual | ForEach-Object { $_.title })
                } finally { Close-PckitProfile $p }
                return [pscustomobject]@{ Plan = $plan; Manual = $names }
            }
            $out = Invoke-Remote -Body $body -Arguments @($script:Root, $script:ProfilePath)
            $plan = @($out[0].Plan)
            Fill-RestoreList -Plan $plan
            $installCount = @($plan | Where-Object { $_.Action -eq 'install' }).Count
            $manualCount = @($plan | Where-Object { $_.Action -eq 'manual' }).Count
            $restoreHintLabel.Text = ('К установке: {0} программ · вручную: {1} · скопировать: {2} наборов' -f $installCount, $manualCount, (@($plan | Where-Object { $_.Action -like 'copy*' }).Count))
            $applyButton.Enabled = $true
        } catch {
            $restoreStatus.Text = 'Не удалось прочитать профиль'
            $restoreHintLabel.Text = $_.Exception.Message
        }
    })

$applyButton.Add_Click({
        if (-not $script:ProfilePath) { return }

        $run = -not $dryRunCheck.Checked
        if ($run) {
            # реальное применение: показываем, что именно изменится, кнопка по умолчанию — «Нет»
            $steps = @($restoreList.Items | ForEach-Object { $_.Tag } | Where-Object { $_ })
            $count = { param($a) @($steps | Where-Object { $_.Action -in $a }).Count }
            $risky = @($steps | Where-Object { $_.Risk -eq 'high' -and $_.Action -notin 'skip', 'note', 'manual' })
            $summary = "Применить профиль по-настоящему?`r`n`r`n" +
            ('  • установить программ: {0}' -f (& $count @('install'))) + "`r`n" +
            ('  • скопировать наборы файлов: {0}' -f (& $count @('copy', 'copyfile'))) + "`r`n" +
            ('  • записей реестра / сетей Wi-Fi / hosts / драйверов: {0}' -f (& $count @('regimport', 'wifi', 'hosts', 'drivers'))) + "`r`n" +
            ('  • настроек Windows: {0}' -f (& $count @('timezone', 'languages', 'powerplan', 'env', 'command')))
            if ($risky.Count) {
                $summary += "`r`n`r`nРискованные шаги:`r`n" + ((@($risky | Select-Object -First 8) | ForEach-Object { '  ! ' + $_.Title }) -join "`r`n")
            }
            $summary += "`r`n`r`nФайлы, которые будут заменены, сначала уходят в бэкап; изменения записываются в журнал и отменяются кнопкой «Вернуть как было» на главной."
            $go = [System.Windows.Forms.MessageBox]::Show($summary, 'pckit by odilbek — применить',
                [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning,
                [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
            if ($go -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        $script:ApplyProgress = [hashtable]::Synchronized(@{ Text = 'готовлю'; Index = 0; Total = 0 })
        $script:RemoteTick = {
            $pr = $script:ApplyProgress
            $restoreStatus.Text = ('{0}  ({1}/{2})' -f $pr['Text'], $pr['Index'], $pr['Total'])
            if ($pr['Total'] -gt 0) {
                $applyProgress.Maximum = [Math]::Max(1, [int]$pr['Total'])
                $applyProgress.Value = [Math]::Min([int]$pr['Index'], $applyProgress.Maximum)
            }
        }

        $applyButton.Enabled = $false
        $openProfileButton.Enabled = $false
        [System.Windows.Forms.Application]::DoEvents()

        try {
            $body = {
                param($root, $profilePath, $progress, $run)
                . (Join-Path $root 'engine\Common.ps1')
                . (Join-Path $root 'engine\Recipes.ps1')
                . (Join-Path $root 'engine\Catalog.ps1')
                . (Join-Path $root 'engine\Packer.ps1')
                . (Join-Path $root 'engine\Planner.ps1')
                . (Join-Path $root 'engine\Journal.ps1')
                . (Join-Path $root 'engine\Applier.ps1')
                $p = Expand-PckitProfile -Path $profilePath
                try {
                    $plan = Get-PckitPlan -Manifest $p.Manifest
                    $result = Invoke-PckitPlan -Plan $plan -ProfileRoot $p.Root -Run:$run -Progress $progress
                } finally { Close-PckitProfile $p }
                return $result
            }
            $out = Invoke-Remote -Body $body -Arguments @($script:Root, $script:ProfilePath, $script:ApplyProgress, $run)
            $result = $out[0]

            $map = @{}
            foreach ($r in @($result.Results)) {
                if ($r.Step -and $r.Step.ItemId) { $map[[string]$r.Step.ItemId] = $r.Status }
            }
            foreach ($item in $restoreList.Items) {
                $step = $item.Tag
                if ($step -and $step.ItemId -and $map.ContainsKey([string]$step.ItemId)) {
                    $item.SubItems[3].Text = [string]$map[[string]$step.ItemId]
                }
            }

            $okCount = @($result.Results | Where-Object { $_.Status -eq 'ok' }).Count
            $failCount = @($result.Results | Where-Object { $_.Status -eq 'fail' }).Count
            if ($run) {
                $restoreStatus.Text = ('Готово: успешно {0}, ошибок {1}. Лог: {2}' -f $okCount, $failCount, $result.LogFile)
                $restoreHintLabel.Text = ('Бэкапы изменённых файлов: {0}' -f $result.Backups)
            } else {
                $restoreStatus.Text = ('Пробный прогон: {0} шагов проверено, ничего не изменено' -f @($result.Results).Count)
                $restoreHintLabel.Text = 'Чтобы применить по-настоящему — снимите галочку «пробный прогон».'
            }
        } catch {
            $restoreStatus.Text = 'Ошибка: ' + $_.Exception.Message
        } finally {
            $script:RemoteTick = $null
            $applyButton.Enabled = $true
            $openProfileButton.Enabled = $true
        }
    })

$undoButton.Add_Click({
        $journal = Read-PckitJournal
        if (Test-PckitJournalEmpty -Journal $journal) {
            [void][System.Windows.Forms.MessageBox]::Show('Отменять нечего: журнал изменений пуст.',
                'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }

        $undoPlan = @(Get-PckitUndoPlan -Journal $journal)
        $preview = (@($undoPlan | Select-Object -First 12) | ForEach-Object { '  • ' + $_.Kind + ': ' + $_.Title }) -join "`r`n"
        $more = ''
        if ($undoPlan.Count -gt 12) { $more = "`r`n  … и ещё " + ($undoPlan.Count - 12) }
        $text = "Отменить изменения, сделанные программой?`r`n`r`n" + $preview + $more +
        "`r`n`r`nФайлы вернутся из бэкапа, параметры реестра — к прежним значениям."

        $answer = [System.Windows.Forms.MessageBox]::Show($text, 'pckit by odilbek — отмена',
            [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $undoButton.Enabled = $false
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $body = {
                param($root)
                . (Join-Path $root 'engine\Common.ps1')
                . (Join-Path $root 'engine\Journal.ps1')
                $j = Read-PckitJournal
                return (Restore-PckitJournal -Journal $j -Run)
            }
            $out = Invoke-Remote -Body $body -Arguments @($script:Root)
            $res = $out[0]
            $icon = [System.Windows.Forms.MessageBoxIcon]::Information
            if ($res.Failed -gt 0) { $icon = [System.Windows.Forms.MessageBoxIcon]::Warning }
            [void][System.Windows.Forms.MessageBox]::Show(
                ("Отменено: {0}, ошибок: {1}." -f $res.Ok, $res.Failed), 'pckit by odilbek', 
                [System.Windows.Forms.MessageBoxButtons]::OK, $icon)
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show(('Не удалось отменить: ' + $_.Exception.Message),
                'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        } finally {
            $undoButton.Enabled = $true
        }
    })

$doneRefreshButton.Add_Click({ Fill-DoneList })
$doneUndoButton.Add_Click({ Invoke-DoneUndo })
# кнопка на разделе «Настройки» раньше не была подключена, хотя на неё ссылается текст после применения
$gameUndoButton.Add_Click({ Invoke-DoneUndo })

$resultBeforeButton.Add_Click({
        $resultBeforeButton.Enabled = $false
        $resultSummary.Text = 'Замеряю ПК (около 20 секунд, не трогайте компьютер)...'
        [System.Windows.Forms.Application]::DoEvents()
        $script:Busy = $true
        try {
            [void](Invoke-SnapshotRemote -Label 'до')
            $resultSummary.Text = ('Замер «до» сохранён ({0}). Теперь ускорьте или почистите ПК и нажмите «Замерить «после» и сравнить».' -f (Get-Date).ToString('dd.MM HH:mm'))
        } catch {
            $resultSummary.Text = 'Замер не удался: ' + $_.Exception.Message
        } finally {
            $script:Busy = $false
            $resultBeforeButton.Enabled = $true
        }
    })

$resultAfterButton.Add_Click({
        $resultAfterButton.Enabled = $false
        try {
            $cmp = Invoke-ResultCompare -SetText { param($t) $resultSummary.Text = $t; [System.Windows.Forms.Application]::DoEvents() }
            if ($cmp) {
                $verdict = Invoke-SmartVerdict -Cmp $cmp
                if ($verdict) {
                    [void][System.Windows.Forms.MessageBox]::Show($verdict, 'pckit by odilbek — вердикт',
                        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
                }
            }
        } catch {
            $resultSummary.Text = 'Сравнение не удалось: ' + $_.Exception.Message
        } finally {
            $resultAfterButton.Enabled = $true
        }
    })

$resultOpenButton.Add_Click({
        if ($script:LastCompare -and $script:LastCompare.Report -and (Test-Path -LiteralPath $script:LastCompare.Report)) { Start-Process $script:LastCompare.Report }
    })

$resultList.Add_SelectedIndexChanged({
        if (-not $resultList.SelectedItems.Count) { return }
        $r = $resultList.SelectedItems[0].Tag
        if ($r -and $r.Note) { $resultHint.Text = [string]$r.Note }
    })

$resultFpsBeforeButton.Add_Click({ Invoke-FpsMeasure -Which 'до' })
$resultFpsAfterButton.Add_Click({ Invoke-FpsMeasure -Which 'после' })

# ------------------------------------------------------------ startup logic
function Fill-StartupList {
    $entries = @(Get-PckitStartupEntries)
    $startupList.BeginUpdate()
    try {
        $startupList.Items.Clear()
        foreach ($e in $entries) {
            $title = [string]$e.Name
            if ($e.Description -and $e.Description -ne $e.Name -and $title.Length -gt 28) { $title = [string]$e.Description }
            $item = New-Object System.Windows.Forms.ListViewItem($title)
            [void]$item.SubItems.Add($(if ($e.Publisher) { [string]$e.Publisher } else { '—' }))
            [void]$item.SubItems.Add($(if ($e.Enabled) { 'включено' } else { 'выключено' }))
            [void]$item.SubItems.Add([string]$e.Advice)
            [void]$item.SubItems.Add([string]$e.Where)
            $item.Tag = $e
            if (-not $e.Enabled) { $item.ForeColor = [System.Drawing.Color]::FromArgb(140, 140, 150) }
            elseif ($e.Advice -eq 'можно отключить') { $item.ForeColor = $script:Theme.Accent }
            elseif ($e.Advice -eq 'нужно') { $item.ForeColor = [System.Drawing.Color]::FromArgb(30, 120, 50) }
            [void]$startupList.Items.Add($item)
        }
    } finally { $startupList.EndUpdate() }
    $on = @($entries | Where-Object { $_.Enabled }).Count
    $canOff = @($entries | Where-Object { $_.Enabled -and $_.Advice -eq 'можно отключить' }).Count
    $startupSummary.Text = ('Запускается вместе с Windows: {0} из {1}. Можно смело отключить: {2}.' -f $on, $entries.Count, $canOff)
}

function Set-StartupChecked {
    param([bool]$Enabled)
    $sel = @()
    $risky = @()
    foreach ($item in $startupList.Items) {
        if (-not $item.Checked) { continue }
        $e = $item.Tag
        if ([bool]$e.Enabled -eq $Enabled) { continue }
        $sel += $e
        if (-not $Enabled -and $e.Advice -eq 'нужно') { $risky += ('  • ' + $e.Name) }
    }
    if (-not $sel.Count) {
        $msg = if ($Enabled) { 'Отметьте выключенные программы, которые нужно включить.' } else { 'Отметьте включённые программы, которые нужно отключить.' }
        [void][System.Windows.Forms.MessageBox]::Show($msg, 'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    if ($risky.Count) {
        $a = [System.Windows.Forms.MessageBox]::Show(
            ("Среди отмеченных есть то, что лучше оставить (драйвер, античит или защита Windows):`r`n`r`n" + ($risky -join "`r`n") +
                "`r`n`r`nНапример, без античита FACEIT не запустится матч, без утилиты мыши могут сброситься её настройки. Всё равно отключить?"),
            'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($a -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    if (-not $Enabled) {
        Invoke-EnsureBeforeSnapshot -SetText { param($t) $startupSummary.Text = $t; [System.Windows.Forms.Application]::DoEvents() }
    }
    $res = Set-PckitStartupEntries -Entries $sel -Enabled $Enabled
    Fill-StartupList
    Fill-DoneList
    $verb = if ($Enabled) { 'Включено' } else { 'Отключено' }
    $text = ('{0}: {1}, ошибок: {2}. Изменения вступят в силу при следующем входе в Windows; отменить — кнопкой «Вернуть как было».' -f $verb, $res.Ok, $res.Failed)
    if ($res.Failed) { $text += "`r`n`r`n" + (@($res.Messages) -join "`r`n") }
    [void][System.Windows.Forms.MessageBox]::Show($text, 'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
}

$startupDisableButton.Add_Click({ Set-StartupChecked -Enabled $false })
$startupEnableButton.Add_Click({ Set-StartupChecked -Enabled $true })
$startupRefreshButton.Add_Click({ Fill-StartupList })
$startupPresetButton.Add_Click({
        foreach ($item in $startupList.Items) { $item.Checked = ($item.Tag.Enabled -and $item.Tag.Advice -eq 'можно отключить') }
    })
$startupList.Add_SelectedIndexChanged({
        if (-not $startupList.SelectedItems.Count) { return }
        $e = $startupList.SelectedItems[0].Tag
        $startupHint.Text = ('{0}  ·  {1}' -f $e.AdviceNote, $e.Command)
    })

$cleanCountButton.Add_Click({ Count-CleanSizes })

$cleanList.Add_SelectedIndexChanged({
        if (-not $cleanList.SelectedItems.Count) { return }
        $target = $cleanList.SelectedItems[0].Tag
        $text = ('{0}  ·  риск: {1}' -f $target.What, $target.Risk)
        if ($target.Note) { $text += ('  ·  ' + $target.Note) }
        if ($target.Kind -eq 'info') { $text += '  ·  двойной щелчок — открыть Параметры' }
        $cleanHint.Text = $text
    })

$cleanList.Add_DoubleClick({
        if (-not $cleanList.SelectedItems.Count) { return }
        $target = $cleanList.SelectedItems[0].Tag
        if ($target -and $target.Kind -eq 'info' -and $target.Link) { try { Start-Process ([string]$target.Link) } catch { } }
    })

$cleanSafeButton.Add_Click({
        $n = 0
        $mb = 0.0
        foreach ($item in $cleanList.Items) {
            # «Отметить безопасное» = только безопасное: остальные галки снимаем
            # DISM долгий, а «только сообщить» нечего отмечать — их пользователь отмечает сам
            $safe = [bool]($item.Tag -and $item.Tag.Risk -eq 'low' -and $item.Tag.Kind -notin 'dism', 'info')
            $item.Checked = $safe
            if ($safe) { $n++; $mb += (ConvertFrom-PckitSizeText ([string]$item.SubItems[2].Text)) }
        }
        $cleanSummary.Text = ('Отмечено безопасных: {0}. Можно освободить: {1}' -f $n, $(if ($mb -gt 0) { Format-PckitSize $mb } else { 'размер не посчитан — нажмите «Посчитать»' }))
    })

$cleanRunButton.Add_Click({
        $ids = @()
        $totalMb = 0.0
        $hasDism = $false
        foreach ($item in $cleanList.Items) {
            if (-not $item.Checked) { continue }
            if ($item.Tag.Kind -eq 'info') { continue }   # удаляется через Параметры Windows
            if ($item.Tag.Kind -eq 'dism') { $hasDism = $true }
            $ids += [string]$item.Tag.Id
            $text = [string]$item.SubItems[2].Text
            $totalMb += (ConvertFrom-PckitSizeText $text)
        }
        if ($hasDism) {
            $d = [System.Windows.Forms.MessageBox]::Show(
                "Отмечено сжатие хранилища компонентов (WinSxS) — это штатная команда Windows DISM, она идёт 5–30 минут. Окно в это время будет занято.`r`n`r`nПродолжить?",
                'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($d -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        $driversAsked = ($ids -contains 'drivers.old')
        if ($ids -contains 'drivers.old') {
            $cleanSummary.Text = 'Ищу старые версии драйверов...'
            [System.Windows.Forms.Application]::DoEvents()
            $old = @()
            try {
                $body = { param($root) . (Join-Path $root 'engine\Common.ps1'); . (Join-Path $root 'engine\Clean.ps1'); return @(Get-PckitOldDrivers) }
                $old = @(Invoke-Remote -Body $body -Arguments @($script:Root) | Where-Object { $_ })
            } catch { }
            if (-not $old.Count) {
                $ids = @($ids | Where-Object { $_ -ne 'drivers.old' })
                [void][System.Windows.Forms.MessageBox]::Show('Старых версий драйверов нет — удалять нечего.', 'pckit by odilbek',
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            } else {
                $lines = ($old | Select-Object -First 15 | ForEach-Object { '  • {0}: версия {1} (оставляю {2}), {3}' -f $_.Title, $_.Version, $_.Newest, (Format-PckitSize $_.SizeMb) }) -join "`r`n"
                if ($old.Count -gt 15) { $lines += ("`r`n  … и ещё {0}" -f ($old.Count - 15)) }
                $dq = [System.Windows.Forms.MessageBox]::Show(
                    ("Удалю старые версии драйверов ({0}):`r`n`r`n{1}`r`n`r`nНовейшая версия каждого драйвера и всё, что сейчас используется устройствами, остаются. Удаление штатное (pnputil), без принудительного режима: если драйвер ещё нужен, Windows его не отдаст.`r`n`r`nОтменить нельзя — старую версию можно вернуть только установкой драйвера заново. Удалить?" -f $old.Count, $lines),
                    'pckit by odilbek — старые драйверы', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning,
                    [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
                if ($dq -ne [System.Windows.Forms.DialogResult]::Yes) { $ids = @($ids | Where-Object { $_ -ne 'drivers.old' }) }
            }
        }
        if (-not $ids.Count -and $driversAsked) { Update-CleanSummary; return }
        if (-not $ids.Count) {
            [void][System.Windows.Forms.MessageBox]::Show('Отметьте хотя бы один пункт.', 'pckit by odilbek',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }

        $answer = [System.Windows.Forms.MessageBox]::Show(
            ("Удалить содержимое {0} кэшей?`r`nОсвободится примерно {1}.`r`n`r`nЭто необратимо: корзину и кэши восстановить нельзя. Закройте браузеры, чтобы их кэш очистился полностью." -f $ids.Count, (Format-PckitSize $totalMb)),
            'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        Invoke-EnsureBeforeSnapshot -SetText { param($t) $cleanSummary.Text = $t; [System.Windows.Forms.Application]::DoEvents() }
        $cleanRunButton.Enabled = $false
        $cleanSummary.Text = 'Очищаю...'
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $body = {
                param($root, $ids)
                . (Join-Path $root 'engine\Common.ps1')
                . (Join-Path $root 'engine\Clean.ps1')
                $all = Get-PckitCleanTargets
                $sel = @($all | Where-Object { $ids -contains $_.Id })
                return (Invoke-PckitClean -Targets $sel -Run)
            }
            $out = Invoke-Remote -Body $body -Arguments @($script:Root, $ids)
            $res = $out[0]
            $skipped = 0
            foreach ($r in @($res.Results)) { $skipped += [int]$r.Skipped }
            $script:CleanCounted = $false
            Count-CleanSizes
            [void][System.Windows.Forms.MessageBox]::Show(
                ("Освобождено: {0}.`r`nПропущено занятых файлов: {1} — это нормально." -f (Format-PckitSize $res.FreedMb), $skipped),
                'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show(('Ошибка очистки: ' + $_.Exception.Message), 'pckit by odilbek',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        } finally {
            $cleanRunButton.Enabled = $true
        }
    })

$tabs.Add_SelectedIndexChanged({
        if ($tabs.SelectedTab -eq $tabClean -and -not $script:CleanCounted) { Count-CleanSizes }
    })

$healthCheckButton.Add_Click({ Run-HealthCheck })

$healthSaveButton.Add_Click({
        if (-not $script:Health) { return }
        try {
            $file = Save-PckitHealthReport -Report $script:Health -Format html
            $answer = [System.Windows.Forms.MessageBox]::Show(
                ("Отчёт сохранён:`r`n{0}`r`n`r`nОткрыть его?" -f $file), 'pckit by odilbek',
                [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)
            if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) { Start-Process $file }
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show(('Не удалось сохранить: ' + $_.Exception.Message),
                'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    })

# ---------- сеть для CS2 ----------
$script:LastNetwork = $null

function Fill-NetworkList {
    param($Net)
    $netList.BeginUpdate()
    try {
        $netList.Items.Clear()
        foreach ($r in @($Net.Verdict.Rows)) {
            $item = New-Object System.Windows.Forms.ListViewItem([string]$r.Name)
            [void]$item.SubItems.Add([string]$r.Value)
            [void]$item.SubItems.Add($(switch ($r.Verdict) { 'ok' { 'в порядке' } 'warn' { 'заметно' } 'bad' { 'плохо' } default { '' } }))
            [void]$item.SubItems.Add([string]$r.Note)
            $item.ForeColor = switch ($r.Verdict) {
                'ok' { [System.Drawing.Color]::FromArgb(30, 120, 50) }
                'warn' { [System.Drawing.Color]::FromArgb(160, 110, 15) }
                'bad' { [System.Drawing.Color]::FromArgb(180, 40, 40) }
                default { [System.Drawing.Color]::FromArgb(40, 40, 45) }
            }
            [void]$netList.Items.Add($item)
        }
    } finally { $netList.EndUpdate() }
    $when = ''
    try { $when = ([datetime]$Net.Time).ToString('dd.MM HH:mm') + ': ' } catch { }
    $netTips.Text = $when + ((@($Net.Verdict.Tips) | ForEach-Object { '• ' + $_ }) -join "`r`n")
    $netTips.ForeColor = switch ($Net.Verdict.Level) {
        'ok' { [System.Drawing.Color]::FromArgb(30, 120, 50) }
        'warn' { [System.Drawing.Color]::FromArgb(150, 100, 10) }
        default { [System.Drawing.Color]::FromArgb(170, 40, 40) }
    }
}

function Invoke-NetworkTest {
    if (@(Get-Process -Name 'cs2' -ErrorAction SilentlyContinue).Count) {
        $q = [System.Windows.Forms.MessageBox]::Show("CS2 запущена. Проверку лучше делать не во время матча: тест под нагрузкой сам создаёт лаги на 10 секунд.`r`n`r`nВы сейчас не в матче?",
            'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($q -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    $netRunButton.Enabled = $false
    $netList.Items.Clear()
    $netTips.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 100)
    $netTips.Text = 'Проверяю: роутер → ближайшие серверы Valve' + $(if ($netLoad.Checked) { ' → пинг под нагрузкой' } else { '' }) + '. Около 40 секунд...'
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $body = {
            param($root, $load, $wifi)
            . (Join-Path $root 'engine\Network.ps1')
            return (Invoke-PckitNetworkTest -LoadTest:$load -WifiOnly $wifi)
        }
        $wifi = $false
        try { $wifi = [bool](Get-UiHardware).WifiOnly } catch { }
        $net = (Invoke-Remote -Body $body -Arguments @($script:Root, [bool]$netLoad.Checked, $wifi))[0]
        $script:LastNetwork = $net
        try {
            $dir = Join-Path $env:LOCALAPPDATA 'pckit'
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            [IO.File]::WriteAllText((Join-Path $dir 'network-last.json'), ($net | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
        Fill-NetworkList -Net $net
    } catch {
        $netTips.Text = 'Проверка не удалась: ' + $_.Exception.Message + ' — есть ли интернет?'
        $netTips.ForeColor = [System.Drawing.Color]::FromArgb(170, 40, 40)
    } finally {
        $netRunButton.Enabled = $true
    }
}

# ---------- отчёт для друга ----------
function Invoke-HomeShare {
    $ask = [System.Windows.Forms.MessageBox]::Show(
        "Соберу отчёт о ПК в один файл на Рабочем столе: железо, драйвер, настройки CS2, что нашла проверка, что включено, последняя проверка сети и FPS.`r`n`r`nЛичного в нём нет: ни имени пользователя и ПК, ни файлов, ни паролей. Отправьте файл тому, кто поможет — он откроется в любом браузере.`r`n`r`nСобрать (около 20 секунд)?",
        'pckit by odilbek — отчёт для друга', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($ask -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    Set-HomeProgress 'Собираю отчёт о ПК...'
    $prevSummary = $healthSummary.Text
    $healthSummary.Text = 'Собираю отчёт о ПК...'
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $body = {
            param($root, $net, $fb, $fa)
            . (Join-Path $root 'engine\Common.ps1')
            . (Join-Path $root 'engine\Journal.ps1')
            . (Join-Path $root 'engine\Actions.ps1')
            . (Join-Path $root 'engine\Health.ps1')
            . (Join-Path $root 'engine\Share.ps1')
            $hw = Get-PckitHardwareProfile
            $health = Get-PckitHealthReport -ActionsDir (Join-Path $root 'data')
            $actions = Get-PckitActions -Directory (Join-Path $root 'data')
            $states = @(Get-PckitActionsState -Actions $actions -SkipProgress)
            $plan = @(Get-PckitSmartPlan -Actions $actions -Hw $hw)
            $driver = $null
            try { $driver = Get-PckitDriverCheck -Hw $hw } catch { }
            $html = New-PckitShareReport -Hw $hw -Health $health -ActionStates $states -Plan $plan -JournalCount (Get-PckitJournalCount -Journal (Read-PckitJournal)) -Network $net -FpsBefore $fb -FpsAfter $fa -Driver $driver
            return (Save-PckitShareReport -Html $html)
        }
        $path = (Invoke-Remote -Body $body -Arguments @($script:Root, $script:LastNetwork, $script:FpsBefore, $script:FpsAfter))[0]
        $open = [System.Windows.Forms.MessageBox]::Show(
            ("Готово: {0}`r`n`r`nОткрыть отчёт? (Папка с файлом тоже откроется — оттуда его удобно перетащить в Telegram или Discord.)" -f $path),
            'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)
        if ($open -eq [System.Windows.Forms.DialogResult]::Yes) {
            Start-Process $path
            Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $path)
        }
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show(('Не удалось собрать отчёт: ' + $_.Exception.Message), 'pckit by odilbek',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    } finally {
        Set-HomeProgress ''
        $healthSummary.Text = $prevSummary
    }
}

function Invoke-HomeNetwork {
    Set-UiMode $true
    $tabs.SelectedTab = $tabNetwork
    Update-NavSelection
    [System.Windows.Forms.Application]::DoEvents()
    Invoke-NetworkTest
}

# свежий ли драйвер видеокарты — спрашиваем сайт NVIDIA (только чтение, ничего не скачиваем)
function Get-UiDriverCheck {
    $body = {
        param($root)
        . (Join-Path $root 'engine\Common.ps1')
        . (Join-Path $root 'engine\Journal.ps1')
        . (Join-Path $root 'engine\Actions.ps1')
        return (Get-PckitDriverCheck)
    }
    return (Invoke-Remote -Body $body -Arguments @($script:Root))[0]
}

function Invoke-DriverCheck {
    Set-HomeProgress 'Спрашиваю у NVIDIA, какой драйвер последний...'
    $prevSummary = $healthSummary.Text
    $healthSummary.Text = 'Спрашиваю у NVIDIA, какой драйвер последний...'
    [System.Windows.Forms.Application]::DoEvents()
    try { $c = Get-UiDriverCheck } catch { $c = $null } finally { Set-HomeProgress '' }
    $healthSummary.Text = $prevSummary
    if (-not $c) { return }
    $title = 'pckit by odilbek — драйвер видеокарты'
    switch ($c.Status) {
        'outdated' {
            $when = if ($c.Latest.Date) { ' от ' + ([datetime]$c.Latest.Date).ToString('dd.MM.yyyy') } else { '' }
            $ask = [System.Windows.Forms.MessageBox]::Show(
                ("Вышел новый драйвер NVIDIA.`r`n`r`nУ вас: {0}`r`nПоследний: {1}{2} ({3}, {4})`r`n`r`nНовые драйверы часто исправляют фризы и добавляют fps в свежих играх. Открыть официальную страницу NVIDIA, чтобы скачать?`r`n`r`nСовет: ставьте с галкой «Выполнить чистую установку», а саму CS2 перед этим закройте." -f $c.Installed, $c.Latest.Version, $when, $c.Latest.Name, $c.Latest.Size),
                $title, [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)
            if ($ask -eq [System.Windows.Forms.DialogResult]::Yes -and $c.Latest.DetailsUrl -like 'https://www.nvidia.com/*') { Start-Process $c.Latest.DetailsUrl }
        }
        'ok' { [void][System.Windows.Forms.MessageBox]::Show(("Драйвер свежий: {0} — это последняя версия для {1}." -f $c.Installed, $c.Product), $title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) }
        'newer' { [void][System.Windows.Forms.MessageBox]::Show(("У вас {0} — новее, чем последняя стабильная на сайте ({1}). Всё в порядке." -f $c.Installed, $c.Latest.Version), $title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) }
        default { [void][System.Windows.Forms.MessageBox]::Show([string]$c.Message, $title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) }
    }
}
# куда ведёт замечание: настройка во разделе «Настройки», раздел программы или страница Параметров Windows
function Invoke-HealthFix {
    param($Finding)
    if (-not $Finding) { return }
    if ($Finding.FixAction) { GoTo-FixAction -ActionId ([string]$Finding.FixAction); return }
    $link = [string]$Finding.Link
    switch ($link) {
        '' {
            $msg = [string]$Finding.Title
            if ($Finding.Detail) { $msg += "`r`n`r`n" + $Finding.Detail }
            if ($Finding.Hint) { $msg += "`r`n`r`nЧто делать: " + $Finding.Hint }
            [void][System.Windows.Forms.MessageBox]::Show($msg, 'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        }
        'pckit:clean' { Set-UiMode $true; $tabs.SelectedTab = $tabClean; Update-NavSelection }
        'pckit:startup' { Set-UiMode $true; $tabs.SelectedTab = $tabStartup; Update-NavSelection }
        'pckit:driver' { Invoke-DriverCheck }
        'pckit:network' { Invoke-HomeNetwork }
        default { try { Start-Process $link } catch { } }
    }
}

$healthList.Add_SelectedIndexChanged({
        if (-not $healthList.SelectedItems.Count) { $healthFixButton.Enabled = $false; return }
        $f = $healthList.SelectedItems[0].Tag
        $healthFixButton.Enabled = [bool]($f -and ($f.FixAction -or $f.Link))
        $healthFixButton.Text = if ($f.FixAction) { 'Исправить' } elseif ([string]$f.Link -like 'pckit:*') { 'Перейти' } elseif ($f.Link) { 'Открыть настройки' } else { 'Подробнее' }
        $parts = @()
        if ($f.Detail) { $parts += [string]$f.Detail }
        if ($f.Hint) { $parts += 'что делать: ' + [string]$f.Hint }
        $healthHint.Text = ($parts -join '   ·   ')
    })

$healthFixButton.Add_Click({
        if (-not $healthList.SelectedItems.Count) { return }
        Invoke-HealthFix -Finding $healthList.SelectedItems[0].Tag
    })

# двойной щелчок: исправить, открыть нужный раздел или показать полный текст
$healthList.Add_DoubleClick({
        if (-not $healthList.SelectedItems.Count) { return }
        Invoke-HealthFix -Finding $healthList.SelectedItems[0].Tag
    })
$netRunButton.Add_Click({ Invoke-NetworkTest })
$gameList.Add_SelectedIndexChanged({ Update-GameDetails })
$gameFilter.Add_SelectedIndexChanged({ if ($script:GameItems.Count) { Update-GameFilter } })
$gameSearch.Add_TextChanged({ if ($script:GameItems.Count) { Update-GameFilter } })

# мифы и то, что не подходит этой Windows, отметить нельзя
$gameList.Add_ItemCheck({
        param($s, $e)
        $a = $gameList.Items[$e.Index].Tag
        if ($a -and ($a.myth -or -not (Test-ActionSupported $a) -or $gameList.Items[$e.Index].SubItems[3].Text -eq 'не подходит')) { $e.NewValue = [System.Windows.Forms.CheckState]::Unchecked }
    })

$gameCheckButton.Add_Click({ Update-GameStatuses })

$gamePresetButton.Add_Click({
        foreach ($item in $script:GameItems) {
            $item.Checked = (Test-ActionRecommended $item.Tag)
        }
        $gameStatus.Text = 'отмечено то, что подходит вашему ПК (★)'
    })

$gameApplyButton.Add_Click({
        $ids = @()
        $expertTitles = @()
        foreach ($item in $script:GameItems) {
            if (-not $item.Checked) { continue }
            $ids += [string]$item.Tag.id
            if ($item.Tag.expert) { $expertTitles += ('  • ' + [string]$item.Tag.title + ' — ' + [string]$item.Tag.effect) }
        }
        if (-not $ids.Count) {
            [void][System.Windows.Forms.MessageBox]::Show('Отметьте хотя бы одно действие.', 'pckit by odilbek',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }

        $run = -not $gameDryRun.Checked
        if ($run -and $expertTitles.Count) {
            $warn = [System.Windows.Forms.MessageBox]::Show(
                ("Отмечены экспертные настройки — они отключают службы и задачи Windows:`r`n`r`n" + ($expertTitles -join "`r`n") +
                    "`r`n`r`nРеальный выигрыш небольшой, а часть функций Windows перестанет работать. Всё отменяется кнопкой «Отменить изменения». Продолжить?"),
                'pckit by odilbek — эксперт', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning,
                [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
            if ($warn -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        if ($run) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                ('Применить настроек: {0}? Каждое изменение записывается в журнал, откат — кнопкой «Отменить изменения».' -f $ids.Count),
                'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            Invoke-EnsureBeforeSnapshot -SetText { param($t) $gameStatus.Text = $t; [System.Windows.Forms.Application]::DoEvents() }
        }

        if ($run -and $gameRestorePoint.Checked) {
            $gameStatus.Text = 'создаю точку восстановления...'
            [System.Windows.Forms.Application]::DoEvents()
            try {
                $rpBody = {
                    param($root)
                    . (Join-Path $root 'engine\Common.ps1')
                    . (Join-Path $root 'engine\RestorePoint.ps1')
                    return (New-PckitRestorePoint -Run)
                }
                $rp = (Invoke-Remote -Body $rpBody -Arguments @($script:Root))[0]
                $script:LastRestorePoint = $rp
                if ($rp.Status -eq 'failed') {
                    $continue = [System.Windows.Forms.MessageBox]::Show(
                        ("Не удалось создать точку восстановления:`r`n{0}`r`n`r`nПродолжить без неё?" -f $rp.Message),
                        'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
                    if ($continue -ne [System.Windows.Forms.DialogResult]::Yes) { return }
                }
            } catch { }
        }

        $gameApplyButton.Enabled = $false
        $gameStatus.Text = 'применяю...'
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $body = {
                param($root, $ids, $run)
                . (Join-Path $root 'engine\Common.ps1')
                . (Join-Path $root 'engine\Journal.ps1')
                . (Join-Path $root 'engine\Actions.ps1')
                $actions = Get-PckitActions -Directory (Join-Path $root 'data')
                $sel = @($actions | Where-Object { $ids -contains $_.id })
                return (Invoke-PckitActions -Actions $sel -Run:$run)
            }
            $out = Invoke-Remote -Body $body -Arguments @($script:Root, $ids, $run)
            $res = $out[0]
            Update-GameStatuses

            if ($run) {
                $msg = ('Применено действий: {0}, ошибок: {1}.' -f @($res.Results).Count, $res.Failed) + (Get-ApplyFailText $res)
                if ($res.JournalPath) { $msg += "`r`n`r`nЖурнал: " + $res.JournalPath }
            } else {
                $msg = ('Пробный прогон: {0} действий проверено, ничего не изменено.' -f @($res.Results).Count)
            }
            [void][System.Windows.Forms.MessageBox]::Show($msg, 'pckit by odilbek',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show(('Ошибка: ' + $_.Exception.Message), 'pckit by odilbek',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        } finally {
            $gameApplyButton.Enabled = $true
        }
    })

$openLinkButton.Add_Click({
        if (-not $manualList.SelectedItems.Count) { return }
        $entry = $manualList.SelectedItems[0].Tag
        if ($entry -and $entry.url) { [void](Open-PckitUrl -Url ([string]$entry.url)) }
    })

$copyLinkButton.Add_Click({
        if (-not $manualList.SelectedItems.Count) { return }
        $entry = $manualList.SelectedItems[0].Tag
        if ($entry -and $entry.url) {
            [System.Windows.Forms.Clipboard]::SetText([string]$entry.url)
            $manualStatus.Text = 'ссылка скопирована'
        }
    })

$manualList.Add_DoubleClick({
        if (-not $manualList.SelectedItems.Count) { return }
        $entry = $manualList.SelectedItems[0].Tag
        if ($entry -and $entry.url) { [void](Open-PckitUrl -Url ([string]$entry.url)) }
    })

# --------------------------------------------------------------- ui helpers
function Set-Busy {
    param([string]$Text, [bool]$On)
    $script:Busy = $On
    $status.Text = $Text
    $progress.Visible = $On
    $refreshButton.Enabled = -not $On
    $packButton.Enabled = -not $On
    $presetBox.Enabled = -not $On
    $allButton.Enabled = -not $On
    $noneButton.Enabled = -not $On
    [System.Windows.Forms.Application]::DoEvents()
}

function Get-ItemLabel {
    param($Item)
    $text = $Item.Title
    if ($Item.SizeMb -gt 0) { $text += ('   ·  ' + (Format-PckitSize $Item.SizeMb)) }
    if ($Item.Risk -eq 'high') { $text += '   ⚠ риск' }
    elseif ($Item.Risk -eq 'medium') { $text += '   ·  осторожно' }
    return $text
}

function Get-ItemColor {
    param($Item)
    if ($Item.Risk -eq 'high') { return [System.Drawing.Color]::FromArgb(190, 60, 60) }
    if ($Item.Risk -eq 'medium') { return [System.Drawing.Color]::FromArgb(150, 110, 20) }
    return [System.Drawing.Color]::FromArgb(40, 40, 45)
}

function Show-ItemDetails {
    param($Item)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('Что:      {0}' -f $Item.Title))
    $lines.Add(('Тип:      {0}' -f $Item.Kind))
    if ($Item.SizeMb -gt 0) { $lines.Add(('Размер:   {0}' -f (Format-PckitSize $Item.SizeMb))) }
    $riskText = switch ($Item.Risk) { 'high' { 'высокий — данные личные или привязаны к системе' } 'medium' { 'средний' } default { 'низкий' } }
    $lines.Add(('Риск:     {0}' -f $riskText))
    $lines.Add('')

    switch ($Item.Kind) {
        'app' {
            $lines.Add(('Пакет:    {0}' -f $Item.Meta.WingetId))
            $lines.Add(('Версия:   {0}' -f $Item.Meta.Version))
            $lines.Add(('Издатель: {0}' -f $Item.Meta.Publisher))
            if (-not $Item.Meta.WingetId) {
                $lines.Add('')
                $lines.Add('Нет пакета winget — поставится вручную, установщик скачаете сами.')
            }
        }
        'appdata' {
            $lines.Add(('Рецепт:   {0}' -f $Item.Meta.RecipeId))
            $lines.Add('')
            $lines.Add('Что копируется:')
            foreach ($step in @($Item.Meta.Steps)) {
                $target = if ($step.path) { [string]$step.path } elseif ($step.key) { 'реестр: ' + $step.key } elseif ($step.capture) { 'команда: ' + $step.capture } else { '' }
                $lines.Add(('  {0,-9} {1}' -f $step.type, $target))
                if ($step.exclude) { $lines.Add(('            кроме: {0}' -f (@($step.exclude) -join ', '))) }
            }
        }
        'files' {
            $lines.Add(('Путь:     {0}' -f $Item.Meta.Target))
            $modeText = 'копировать в профиль'
            if ($Item.Meta.Mode -eq 'reference') { $modeText = 'запомнить путь, не копировать' }
            $lines.Add(('Режим:    {0}' -f $modeText))
        }
        'os' {
            foreach ($p in $Item.Meta.PSObject.Properties) {
                if ($p.Value -is [string] -or $p.Value -is [int] -or $p.Value -is [bool]) {
                    $lines.Add(('{0,-10} {1}' -f ($p.Name + ':'), $p.Value))
                }
            }
        }
        'network' {
            foreach ($p in $Item.Meta.PSObject.Properties) {
                if ($p.Value -is [array]) { $lines.Add(('{0}: {1}' -f $p.Name, (@($p.Value) -join ', '))) }
                elseif ($p.Value -is [string]) { $lines.Add(('{0}: {1}' -f $p.Name, $p.Value)) }
            }
        }
        'dev' {
            foreach ($p in $Item.Meta.PSObject.Properties) {
                if ($p.Value -is [string]) { $lines.Add(('{0,-10} {1}' -f ($p.Name + ':'), $p.Value)) }
            }
        }
        'drivers' {
            $lines.Add('Драйверы из DriverStore. Нужен запуск от администратора.')
        }
    }

    $detailsTitle.Text = $Item.Title
    $details.Text = ($lines -join "`r`n")
}

function Set-UiLayout {
    $w = $split.Width
    if ($w -le 300) { return }
    $d = [int]($w * 0.58)
    if ($d -lt 340) { $d = 340 }
    if ($d -gt ($w - 280)) { $d = $w - 280 }
    $split.SplitterDistance = $d
}

function Update-Status {
    $count = 0
    $size = 0.0
    $manual = 0
    foreach ($id in $script:Checked) {
        $item = $script:ItemsById[$id]
        if (-not $item) { continue }
        $count++
        $size += [double]$item.SizeMb
        if ($item.Kind -eq 'app' -and -not $item.Meta.WingetId) { $manual++ }
    }
    if ($size -gt 0) {
        $status.Text = ('Выбрано: {0} объектов · примерно {1}' -f $count, (Format-PckitSize $size))
    } else {
        $status.Text = ('Выбрано: {0} объектов' -f $count)
    }
    if ($manual -gt 0) {
        $statusInfo.Text = ('из них {0} придётся ставить вручную (нет пакета winget)' -f $manual)
    } else {
        $statusInfo.Text = 'программы ставятся через winget, данные копируются из профиля'
    }
    $packButton.Enabled = (-not $script:Busy) -and ($count -gt 0)
}

function Add-TreeGroup {
    param([string]$Key, [string]$Title, $Parent)
    $node = New-Object System.Windows.Forms.TreeNode
    $node.Text = $Title
    $node.Name = 'g:' + $Key
    $node.Tag = $null
    $node.NodeFont = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
    $node.ForeColor = [System.Drawing.Color]::FromArgb(40, 40, 45)
    if ($Parent) { [void]$Parent.Nodes.Add($node) } else { [void]$tree.Nodes.Add($node) }
    return $node
}

function Update-GroupState {
    param($Node)
    if (-not $Node -or $Node.Nodes.Count -eq 0) { return }
    $total = 0
    $checked = 0
    foreach ($child in $Node.Nodes) {
        $total++
        if ($child.Checked) { $checked++ }
    }
    $script:Suppress = $true
    try {
        if ($checked -eq 0) { $Node.Checked = $false }
        elseif ($checked -eq $total) { $Node.Checked = $true }
    } finally { $script:Suppress = $false }
}

function Populate-Tree {
    param([string]$Filter = '')

    $script:Suppress = $true
    $tree.BeginUpdate()
    try {
        $tree.Nodes.Clear()
        if (-not $script:Catalog) { return }

        $filterText = $Filter.Trim().ToLower()
        foreach ($key in $GroupTitles.Keys) {
            $items = @($script:Catalog.Items | Where-Object { $_.Kind -eq $key })
            if ($filterText) {
                $items = @($items | Where-Object { $_.Title.ToLower().Contains($filterText) -or $_.Id.ToLower().Contains($filterText) })
            }
            if (-not $items.Count) { continue }

            $groupNode = Add-TreeGroup -Key $key -Title ('{0}  ({1})' -f $GroupTitles[$key], $items.Count)

            foreach ($item in ($items | Sort-Object Title)) {
                $node = New-Object System.Windows.Forms.TreeNode
                $node.Text = Get-ItemLabel -Item $item
                $node.Tag = $item
                $node.Name = 'i:' + $item.Id
                $node.ForeColor = Get-ItemColor -Item $item
                $node.Checked = $script:Checked.Contains($item.Id)
                [void]$groupNode.Nodes.Add($node)
            }
            Update-GroupState -Node $groupNode
            if ($groupNode.Nodes.Count -le 12) { $groupNode.Expand() } else { $groupNode.Expand() }
        }
    } finally {
        $tree.EndUpdate()
        $script:Suppress = $false
    }
}

function Set-SelectionFromPreset {
    param([string]$PresetName)

    $script:Checked.Clear()
    foreach ($item in $script:Catalog.Items) {
        $take = $false
        switch ($PresetName) {
            'Минимум' {
                $take = ($item.Kind -eq 'app' -and $item.Default) -or ($item.Kind -eq 'os' -and $item.Default)
            }
            'Работа' {
                $take = (($item.Kind -in 'app', 'appdata', 'files', 'os') -and $item.Default) -or
                        ($item.Id -in 'dev.gitconfig', 'dev.env')
            }
            'Всё' {
                $take = ($item.Kind -ne 'drivers') -and ($item.Exists -ne $false)
            }
        }
        if ($take) { [void]$script:Checked.Add($item.Id) }
    }
    Populate-Tree -Filter $search.Text
    Update-Status
}

# ------------------------------------------------------------------ scanning
function Invoke-CatalogScan {
    Set-Busy -Text 'Сканирую установленные программы и настройки...' -On $true

    $body = {
        param($root)
        . (Join-Path $root 'engine\Common.ps1')
        . (Join-Path $root 'engine\Recipes.ps1')
        . (Join-Path $root 'engine\Catalog.ps1')
        $catalog = Get-PckitCatalog -RecipeDir (Join-Path $root 'recipes')
        return $catalog
    }

    try {
        $output = Invoke-Remote -Body $body -Arguments @($script:Root)
    } catch {
        Set-Busy -Text 'Готово' -On $false   # иначе кнопки остаются заблокированными после сбоя
        throw
    }

    $catalog = $output[0]
    $script:Catalog = $catalog
    $script:ItemsById = @{}
    foreach ($item in $catalog.Items) { $script:ItemsById[$item.Id] = $item }

    $machine = $catalog.Machine
    $form.Text = ('pckit by odilbek · v{0}' -f $script:PckitAppVersion)
    Set-Busy -Text 'Готово' -On $false
}

function Load-CatalogFromFile {
    $file = Join-Path $script:Root 'state\catalog.json'
    if (-not (Test-Path -LiteralPath $file)) { return $false }
    try {
        $catalog = Read-PckitJson $file
        if (-not $catalog -or -not $catalog.Items) { return $false }
        $script:Catalog = $catalog
    } catch { return $false }

    $script:ItemsById = @{}
    foreach ($item in $script:Catalog.Items) { $script:ItemsById[$item.Id] = $item }
    $machine = $script:Catalog.Machine
    $form.Text = ('pckit by odilbek · v{0}' -f $script:PckitAppVersion)
    return $true
}

function Save-CatalogCache {
    if (-not $script:Catalog) { return }
    $dir = Join-Path $script:Root 'state'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Save-PckitJson -Path (Join-Path $dir 'catalog.json') -Object $script:Catalog
}

# -------------------------------------------------------------------- packing
function Invoke-PackProfile {
    $selected = @()
    foreach ($id in $script:Checked) {
        if ($script:ItemsById.ContainsKey($id)) { $selected += $script:ItemsById[$id] }
    }
    if ($selected.Count -eq 0) { return }

    # профиль не шифруется: ключи, пароли Wi-Fi и личные файлы лежат в нём как есть
    $risky = @($selected | Where-Object { $_.Risk -eq 'high' })
    if ($risky.Count -and -not $PackTo) {
        $list = (@($risky | Select-Object -First 8) | ForEach-Object { '  • ' + $_.Title }) -join "`r`n"
        $ask = [System.Windows.Forms.MessageBox]::Show(
            ("В профиль попадут чувствительные данные (ключи, пароли, личные файлы):`r`n`r`n{0}`r`n`r`nФайл .pckit НЕ шифруется. Храните его только на своём носителе и не отправляйте другим. Продолжить?" -f $list),
            'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($ask -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }

    if ($PackTo) {
        $outFile = $PackTo
    } else {
        $save = New-Object System.Windows.Forms.SaveFileDialog
        $save.Title = 'Куда сохранить профиль'
        $save.Filter = 'Профиль pckit (*.pckit)|*.pckit'
        $save.FileName = 'my-profile.pckit'
        $save.InitialDirectory = $env:USERPROFILE
        if ($save.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $outFile = $save.FileName
    }

    Set-Busy -Text ('Собираю профиль: {0} объектов...' -f $selected.Count) -On $true

    $catalogJson = ConvertTo-PckitJson $script:Catalog
    $ids = @($selected | ForEach-Object { $_.Id })

    $body = {
        param($root, $catalogJson, $ids, $outFile)
        . (Join-Path $root 'engine\Common.ps1')
        . (Join-Path $root 'engine\Recipes.ps1')
        . (Join-Path $root 'engine\Catalog.ps1')
        . (Join-Path $root 'engine\Packer.ps1')
        $catalog = $catalogJson | ConvertFrom-Json
        $selection = @($catalog.Items | Where-Object { $ids -contains $_.Id })
        $name = [IO.Path]::GetFileNameWithoutExtension($outFile)
        $result = New-PckitProfile -Catalog $catalog -Selection $selection -OutFile $outFile -Name $name
        return [pscustomobject]@{
            Path    = $result.Path
            SizeMb  = $result.SizeMb
            Items   = $result.Items
            Payload = $result.Payload
            Manual  = $result.Manual
        }
    }

    $ps = [powershell]::Create()
    [void]$ps.AddScript($body)
    [void]$ps.AddArgument($script:Root)
    [void]$ps.AddArgument($catalogJson)
    [void]$ps.AddArgument($ids)
    [void]$ps.AddArgument($outFile)
    $async = $ps.BeginInvoke()
    while (-not $async.IsCompleted) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 150
    }
    $output = $ps.EndInvoke($async)
    $errors = $ps.Streams.Error
    $ps.Dispose()

    Set-Busy -Text 'Готово' -On $false

    if ($errors.Count) {
        [void][System.Windows.Forms.MessageBox]::Show(
            ("Не получилось собрать профиль:`r`n`r`n" + $errors[0].ToString()), 'pckit',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }

    $res = $output[0]
    $text = @(
        'Профиль собран.'
        ''
        ('Файл:      {0}' -f $res.Path)
        ('Размер:    {0}' -f (Format-PckitSize $res.SizeMb))
        ('Объектов:  {0}' -f $res.Items)
        ('Файлов:    {0}' -f $res.Payload)
        ('Вручную:   {0}' -f $res.Manual)
        ''
        'Скопируйте этот файл на внешний диск — на чистой Windows запустите:'
        ('  .\pckit.ps1 apply -Profile "{0}" -Run' -f $res.Path)
    ) -join "`r`n"

    if ($Headless) {
        Write-Host 'HEADLESS RESULT:'
        Write-Host $text
    } else {
        [void][System.Windows.Forms.MessageBox]::Show($text, 'pckit — готово',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }
}

# -------------------------------------------------------------------- events
$tree.Add_AfterCheck({
        param($sender, $e)
        if ($script:Suppress) { return }
        $node = $e.Node
        if ($node.Name -like 'g:*') {
            $script:Suppress = $true
            try {
                foreach ($child in $node.Nodes) {
                    $child.Checked = $node.Checked
                    if ($node.Checked) { [void]$script:Checked.Add($child.Tag.Id) } else { [void]$script:Checked.Remove($child.Tag.Id) }
                }
            } finally { $script:Suppress = $false }
            Update-Status
            return
        }
        if ($node.Tag) {
            if ($node.Checked) { [void]$script:Checked.Add($node.Tag.Id) } else { [void]$script:Checked.Remove($node.Tag.Id) }
            Update-GroupState -Node $node.Parent
        }
        Update-Status
    })

$tree.Add_AfterSelect({
        param($sender, $e)
        if ($e.Node -and $e.Node.Tag) { Show-ItemDetails -Item $e.Node.Tag }
        else {
            $detailsTitle.Text = $e.Node.Text
            $details.Text = ('Пунктов в разделе: {0}' -f $e.Node.Nodes.Count)
        }
    })

$search.Add_TextChanged({
        $searchHint.Visible = [string]::IsNullOrEmpty($search.Text)
        Populate-Tree -Filter $search.Text
    })

$presetBox.Add_SelectedIndexChanged({
        if ($script:Catalog) { Set-SelectionFromPreset -PresetName $presetBox.SelectedItem }
    })

$allButton.Add_Click({
        if (-not $script:Catalog) { return }
        $script:Checked.Clear()
        foreach ($item in $script:Catalog.Items) { if ($item.Kind -ne 'drivers') { [void]$script:Checked.Add($item.Id) } }
        Populate-Tree -Filter $search.Text
        Update-Status
    })

$noneButton.Add_Click({
        $script:Checked.Clear()
        Populate-Tree -Filter $search.Text
        Update-Status
    })

$refreshButton.Add_Click({
        try {
            Invoke-CatalogScan
            Save-CatalogCache
            Set-SelectionFromPreset -PresetName $presetBox.SelectedItem
            Update-Status
        } catch {
            Set-Busy -Text 'Готово' -On $false
            [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'pckit — ошибка сканирования',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    })

$packButton.Add_Click({
        try { Invoke-PackProfile }
        catch {
            Set-Busy -Text 'Готово' -On $false
            [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'pckit — ошибка',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    })

# ------------------------------------------------------------------- подсказки при наведении
$script:Tip = New-Object System.Windows.Forms.ToolTip
$script:Tip.AutoPopDelay = 15000
$script:Tip.InitialDelay = 400
$script:Tip.ReshowDelay = 200
$tipMap = @(
    @($gameApplyButton, 'Применить отмеченные настройки. Перед этим — замер «до» и точка восстановления. Всё записывается в журнал.'),
    @($gameCheckButton, 'Перечитать, что сейчас включено на этом ПК (ничего не меняет).'),
    @($gamePresetButton, 'Отметить ★ — то, что подходит именно вашему железу. Снимет остальные галки.'),
    @($gameUndoButton, 'Вернуть всё, что программа меняла, как было до неё.'),
    @($gameDryRun, 'Ничего не менять — только показать, что было бы сделано.'),
    @($gameRestorePoint, 'Перед изменениями создать точку восстановления Windows (запасной откат).'),
    @($gameFilter, 'Какие настройки показывать в списке.'),
    @($gameSearch, 'Найти настройку по словам: «мышь», «NVIDIA», «питание»…'),
    @($cleanSafeButton, 'Отметить только безопасное: временные файлы и кэши. Корзина, драйверы и WinSxS — только вручную.'),
    @($cleanRunButton, 'Удалить отмеченное. Перед этим покажу, сколько освободится.'),
    @($healthCheckButton, 'Проверить ПК заново: железо, драйверы, настройки CS2. Ничего не меняет.'),
    @($healthSaveButton, 'Сохранить отчёт проверки в файл (Документы\pckit\Отчёты).'),
    @($healthFixButton, 'Перейти туда, где это исправляется. Двойной щелчок по строке делает то же самое.'),
    @($resultBeforeButton, 'Замерить ПК сейчас, до изменений (около 20 секунд, не трогайте компьютер).'),
    @($resultAfterButton, 'Замерить ещё раз и честно сравнить с «до». Лучше после перезагрузки.'),
    @($resultFpsBeforeButton, 'Замер FPS в CS2 за 60 секунд — до изменений. Только вне матчей FACEIT.'),
    @($resultFpsAfterButton, 'Тот же замер после изменений — на той же сцене, иначе сравнение нечестное.')
)
foreach ($pair in $tipMap) { if ($pair[0]) { $script:Tip.SetToolTip($pair[0], $pair[1]) } }
foreach ($card in $script:HomeCards) {
    foreach ($ctl in @($card) + @($card.Controls)) { $script:Tip.SetToolTip($ctl, [string]$card.AccessibleDescription) }
}
$form.Add_Shown({
        Set-UiLayout
        Set-RestoreLayout
        Initialize-GameTab
        Initialize-CleanTab
        Fill-DoneList
        try { Load-LatestFps } catch { }
        try { $nf = Join-Path $env:LOCALAPPDATA 'pckit\network-last.json'; if (Test-Path -LiteralPath $nf) { $script:LastNetwork = Get-Content -LiteralPath $nf -Raw -Encoding UTF8 | ConvertFrom-Json; Fill-NetworkList -Net $script:LastNetwork } } catch { }
        try { Fill-StartupList } catch { $startupSummary.Text = 'Не удалось прочитать автозагрузку: ' + $_.Exception.Message }

        if (-not $SelfTest) {
            $script:HomeTimer = New-Object System.Windows.Forms.Timer
            $script:HomeTimer.Interval = 1500
            $script:HomeTimer.Add_Tick({
                    $script:HomeTimer.Stop()
                    try { Show-WelcomeOnce } catch { }
                    try { Invoke-HomeCheck -Quiet } catch { }
                    try { Invoke-RebootComparePrompt } catch { }
                })
            $script:HomeTimer.Start()
        }
        if (Load-CatalogFromFile) {
            Set-SelectionFromPreset -PresetName $presetBox.SelectedItem
            Update-Status
        } else {
            try {
                Invoke-CatalogScan
                Save-CatalogCache
                Set-SelectionFromPreset -PresetName $presetBox.SelectedItem
                Update-Status
            } catch {
                Set-Busy -Text 'Готово' -On $false
                $status.Text = 'Ошибка сканирования — нажмите «Обновить»'
                $statusInfo.Text = $_.Exception.Message
            }
        }
    })

# ------------------------------------------------------------------- theme pass
# один проход по всем элементам: фон, кнопки, списки, заголовки — в стиле Windows 11
function Set-PckitTheme {
    param($Root)

    $oldBgs = @(
        [System.Drawing.Color]::FromArgb(250, 250, 252).ToArgb(),
        [System.Drawing.Color]::White.ToArgb(),
        [System.Drawing.SystemColors]::Control.ToArgb()
    )
    $oldPrimary = [System.Drawing.Color]::FromArgb(0, 120, 212).ToArgb()
    $mutedOld = @(
        [System.Drawing.Color]::FromArgb(110, 110, 120).ToArgb(),
        [System.Drawing.Color]::FromArgb(120, 120, 130).ToArgb(),
        [System.Drawing.Color]::FromArgb(130, 130, 140).ToArgb()
    )

    foreach ($c in @($Root.Controls)) {
        if ($script:HomeCards -contains $c -or $script:NavItems -contains $c) { continue }

        if ($c -is [System.Windows.Forms.Button]) {
            $c.FlatStyle = 'Flat'
            $c.Cursor = [System.Windows.Forms.Cursors]::Hand
            if ($c.Height -lt 32) { $c.Height = 32 }
            if ($c.BackColor.ToArgb() -eq $oldPrimary) {
                $c.BackColor = $script:Theme.Accent
                $c.ForeColor = [System.Drawing.Color]::White
                $c.FlatAppearance.BorderSize = 0
                $c.FlatAppearance.MouseOverBackColor = $script:Theme.AccentHover
                $c.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(0, 84, 158)
            } else {
                $c.BackColor = $script:Theme.Card
                $c.ForeColor = $script:Theme.Text
                $c.FlatAppearance.BorderSize = 1
                $c.FlatAppearance.BorderColor = $script:Theme.BorderBtn
                $c.FlatAppearance.MouseOverBackColor = $script:Theme.CardHover
                $c.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
            }
            continue
        }
        if ($c -is [System.Windows.Forms.ListView] -or $c -is [System.Windows.Forms.TreeView]) {
            $c.BorderStyle = 'None'
            $c.BackColor = $script:Theme.Card
            $c.ForeColor = $script:Theme.Text
            continue
        }
        if ($c -is [System.Windows.Forms.Label]) {
            if ($c.Font.Name -eq 'Segoe UI Semibold' -and [Math]::Abs($c.Font.Size - 10.5) -lt 0.1) {
                $c.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 13)
            }
            if ($mutedOld -contains $c.ForeColor.ToArgb()) { $c.ForeColor = $script:Theme.Muted }
        }
        if ($c -is [System.Windows.Forms.Panel] -or $c -is [System.Windows.Forms.TableLayoutPanel] -or
            $c -is [System.Windows.Forms.SplitContainer] -or $c -is [System.Windows.Forms.SplitterPanel] -or
            $c -is [System.Windows.Forms.TabPage]) {
            if ($oldBgs -contains $c.BackColor.ToArgb()) { $c.BackColor = $script:Theme.Bg }
        }
        if ($c.Controls.Count) { Set-PckitTheme -Root $c }
    }
}
Set-PckitTheme -Root $form

# ------------------------------------------------------------------- adaptive layout
# одна «резиновая» колонка в каждом списке забирает свободную ширину — без горизонтальной прокрутки
$script:ListFill = @{}
function Update-ListFill {
    param($List)
    if (-not $script:ListFill.ContainsKey($List)) { return }
    $idx = $script:ListFill[$List]
    $others = 0
    for ($i = 0; $i -lt $List.Columns.Count; $i++) { if ($i -ne $idx) { $others += $List.Columns[$i].Width } }
    $w = $List.ClientSize.Width - $others - 4
    if ($w -lt 120) { $w = 120 }
    $List.Columns[$idx].Width = $w
}
function Set-ListFill {
    param($List, [int]$FillIndex, [int[]]$Widths)
    for ($i = 0; $i -lt $Widths.Count; $i++) { if ($i -lt $List.Columns.Count -and $i -ne $FillIndex) { $List.Columns[$i].Width = $Widths[$i] } }
    $script:ListFill[$List] = $FillIndex
    $List.Add_Resize({ param($s, $e) Update-ListFill $s })
    Update-ListFill $List
}
Set-ListFill -List $gameList -FillIndex 1 -Widths @(310, 0, 72, 128, 112)
Set-ListFill -List $cleanList -FillIndex 1 -Widths @(250, 0, 90, 70)
Set-ListFill -List $healthList -FillIndex 2 -Widths @(100, 340, 0)
Set-ListFill -List $resultList -FillIndex 5 -Widths @(200, 120, 120, 80, 135, 0)
Set-ListFill -List $doneList -FillIndex 2 -Widths @(130, 420, 0)
Set-ListFill -List $startupList -FillIndex 0 -Widths @(0, 190, 90, 140, 240)

# «Настройки»: флажки справа прижимаются к краю, описание занимает остаток (до трёх строк, кнопки ниже)
$gameLayout.RowStyles[2].Height = 120
$gameDetails.Height = 56
$gameDetails.AutoEllipsis = $true
foreach ($b in @($gameApplyButton, $gameCheckButton, $gamePresetButton, $gameUndoButton)) { $b.Top = 70 }
$gameBottom.Add_Resize({
        $w = $gameBottom.ClientSize.Width
        $gameRestorePoint.Left = $w - $gameRestorePoint.Width - 14
        $gameDryRun.Left = $gameRestorePoint.Left - $gameDryRun.Width - 18
        $gameStatus.Left = $gameDryRun.Left
        $gameDetails.Width = [Math]::Max(200, $gameDryRun.Left - 28)
    })

# «Сохранить»: поиск и набор выстраиваются справа налево и не наезжают друг на друга
$header.Add_Resize({
        $w = $header.ClientSize.Width
        $presetBox.Left = $w - $presetBox.Width - 16
        $presetLabel.Left = $presetBox.Left - $presetLabel.Width - 6
        $search.Left = $presetLabel.Left - $search.Width - 16
        $searchHint.Left = $search.Left + 6
        $searchHint.BackColor = $search.BackColor
        $searchHint.BringToFront()
    })
$footer.Add_Resize({
        $statusInfo.AutoSize = $false
        $statusInfo.AutoEllipsis = $true
        $statusInfo.Width = [Math]::Max(150, $noneButton.Left - 30)
        $statusInfo.Height = 20
    })

# ------------------------------------------------------------------- run
[System.Windows.Forms.Application]::add_ThreadException({
        param($sender, $e)
        # полная трассировка в файл: по одной строке в окне ошибку не разобрать
        $logPath = $null
        try {
            $logDir = Join-Path $script:Root 'state\logs'
            New-Item -ItemType Directory -Force -Path $logDir | Out-Null
            $logPath = Join-Path $logDir ('ui-error-{0}.log' -f (Get-Date).ToString('yyyy-MM-dd_HHmmss'))
            [IO.File]::WriteAllText($logPath, $e.Exception.ToString(), (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
        $tail = if ($logPath) { "`r`n`r`nПодробности записаны в файл:`r`n" + $logPath } else { '' }
        [void][System.Windows.Forms.MessageBox]::Show(
            ('Что-то пошло не так: ' + $e.Exception.Message + $tail),
            'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    })
$form.Add_FormClosing({
        param($sender, $e)
        if ($script:Busy) {
            $ask = [System.Windows.Forms.MessageBox]::Show(
                "Сейчас выполняется операция. Если закрыть окно, она может остановиться посередине.`r`n`r`nЗакрыть всё равно?",
                'pckit by odilbek', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning,
                [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
            if ($ask -ne [System.Windows.Forms.DialogResult]::Yes) { $e.Cancel = $true }
        }
    })

if ($SelfTest) {
    Write-Host 'selftest: catalog'
    if (-not (Load-CatalogFromFile)) {
        Invoke-CatalogScan
        Save-CatalogCache
    }
    Write-Host 'selftest: selection'
    Set-SelectionFromPreset -PresetName 'Работа'
    Update-Status
    Write-Host ('selftest: nodes = ' + $tree.GetNodeCount($true))
    $sz = @($SelfTestSize -split 'x' | ForEach-Object { [int]$_ })
    $form.MinimumSize = New-Object System.Drawing.Size(600, 400)
    $form.Size = New-Object System.Drawing.Size($sz[0], $sz[1])
    $form.StartPosition = 'Manual'
    $form.ShowInTaskbar = $false
    $form.Location = New-Object System.Drawing.Point(-4000, -4000)
    Write-Host 'selftest: show'
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 600
    [System.Windows.Forms.Application]::DoEvents()
    Set-UiLayout
    Set-RestoreLayout
    [System.Windows.Forms.Application]::DoEvents()
    Write-Host ('selftest: visible nodes = ' + $tree.GetNodeCount($true))
    $found = $null
    foreach ($g in $tree.Nodes) {
        foreach ($c in $g.Nodes) {
            if ($c.Tag -and $c.Tag.Kind -eq 'app' -and $c.Tag.Meta.WingetId) { $found = $c; break }
        }
        if ($found) { break }
    }
    if ($found) {
        $tree.SelectedNode = $found
        [System.Windows.Forms.Application]::DoEvents()
    }
    if ($Tab -lt 1 -or $Tab -gt 11) { $Tab = 1 }
    if ($Tab -gt 1) { Set-UiMode $true }
    $tabs.SelectedIndex = $Tab - 1
    [System.Windows.Forms.Application]::DoEvents()

    if ($Tab -eq 8) {
        Write-Host 'selftest: result tab'
        $b = Get-PckitSnapshot -Label 'до' -Samples 2 -IntervalSeconds 1 -NoPing
        $a = Get-PckitSnapshot -Label 'после' -Samples 2 -IntervalSeconds 1 -NoPing
        $rows = @(Compare-PckitSnapshot -Before $b -After $a)
        Fill-ResultList -Rows $rows -Before $b -After $a
        Write-Host ('selftest: result rows = ' + $rows.Count)
        [System.Windows.Forms.Application]::DoEvents()
    }
    if ($Tab -eq 5) {
        Write-Host ('selftest: game items = {0}' -f $gameList.Items.Count)
        Write-Host ('selftest: groups = {0}, first item group = {1}, showgroups = {2}, visualstyles = {3}' -f $gameList.Groups.Count, $gameList.Items[0].Group.Header, $gameList.ShowGroups, [System.Windows.Forms.Application]::RenderWithVisualStyles)
        $gameList.EnsureVisible(0)
        [System.Windows.Forms.Application]::DoEvents()
    }
    if ($Tab -eq 9) {
        Write-Host 'selftest: done tab'
        $demoJournal = New-PckitJournal
        Add-PckitRegTracked -Journal $demoJournal -Path 'HKCU:\Software\pckit-demo' -Name 'GameDVR_Enabled' -Value 0 -Type DWord
        Add-PckitCommandTracked -Journal $demoJournal -Undo 'powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e' -Note 'схема электропитания'
        Fill-DoneList -Journal $demoJournal
        Remove-Item 'HKCU:\Software\pckit-demo' -Recurse -Force -ErrorAction SilentlyContinue
        [System.Windows.Forms.Application]::DoEvents()
    }
    if ($Tab -eq 6) {
        Write-Host 'selftest: clean tab'
        Count-CleanSizes
        [System.Windows.Forms.Application]::DoEvents()
    }
    if ($Tab -eq 7) {
        Write-Host 'selftest: health check'
        $script:Health = Get-PckitHealthReport -ActionsDir (Join-Path $script:Root 'data')
        Fill-HealthList
        [System.Windows.Forms.Application]::DoEvents()
    }
    if ($Tab -eq 1) {
        Write-Host 'selftest: home check'
        Invoke-HomeCheck -Quiet
        [System.Windows.Forms.Application]::DoEvents()
    }
    if ($Tab -eq 3) {
        $demo = Join-Path $script:Root 'demo.pckit'
        if (Test-Path -LiteralPath $demo) {
            Write-Host 'selftest: plan from demo.pckit'
            $opened = Expand-PckitProfile -Path $demo
            $plan = Get-PckitPlan -Manifest $opened.Manifest
            Close-PckitProfile $opened
            Fill-RestoreList -Plan $plan
            $restorePathLabel.Text = 'demo.pckit'
            $applyButton.Enabled = $true
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
    if ($Tab -eq 4) {
        Write-Host 'selftest: manual list'
        Fill-ManualList
        [System.Windows.Forms.Application]::DoEvents()
    }

    if ($ApplyTest -and $Tab -eq 3) {
        $demoPath = Join-Path $script:Root 'demo.pckit'
        $prog = [hashtable]::Synchronized(@{ Text = ''; Index = 0; Total = 0 })
        $body = {
            param($root, $profilePath, $progress, $run)
            . (Join-Path $root 'engine\Common.ps1')
            . (Join-Path $root 'engine\Recipes.ps1')
            . (Join-Path $root 'engine\Catalog.ps1')
            . (Join-Path $root 'engine\Packer.ps1')
            . (Join-Path $root 'engine\Planner.ps1')
            . (Join-Path $root 'engine\Journal.ps1')
            . (Join-Path $root 'engine\Applier.ps1')
            $p = Expand-PckitProfile -Path $profilePath
            try {
                $plan = Get-PckitPlan -Manifest $p.Manifest
                $result = Invoke-PckitPlan -Plan $plan -ProfileRoot $p.Root -Run:$run -Progress $progress
            } finally { Close-PckitProfile $p }
            return $result
        }
        $res = Invoke-Remote -Body $body -Arguments @($script:Root, $demoPath, $prog, $false)
        $rr = $res[0]
        Write-Host ('selftest: apply dry-run steps = {0}, log = {1}' -f @($rr.Results).Count, $rr.LogFile)
        foreach ($g in (@($rr.Results) | Group-Object Status)) { Write-Host ('   {0}: {1}' -f $g.Name, $g.Count) }
    }


    $cards = @($tabHome.Controls | Where-Object { $_.GetType().Name -eq 'Panel' })
    $withAction = @($cards | Where-Object { $_.Tag -is [scriptblock] })
    Write-Host ('selftest: карточек {0}, с действием {1}' -f $cards.Count, $withAction.Count)

    Write-Host 'selftest: draw'
    $bitmap = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bitmap, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $dir = Split-Path -Parent $SelfTestPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $bitmap.Save($SelfTestPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    Write-Host ('selftest: saved ' + $SelfTestPath)

    $firstApp = $tree.Nodes[0].Nodes[0]
    $before = $script:Checked.Count
    $firstApp.Checked = $true
    [System.Windows.Forms.Application]::DoEvents()
    Write-Host ('selftest: check toggle {0} -> {1}, status: {2}' -f $before, $script:Checked.Count, $status.Text)

    $groupNode = $tree.Nodes[0]
    $groupNode.Checked = $true
    [System.Windows.Forms.Application]::DoEvents()
    Write-Host ('selftest: group check -> {0} items, status: {1}' -f $script:Checked.Count, $status.Text)

    if ($PackTo) {
        Write-Host 'selftest: packing through UI path'
        Invoke-PackProfile
        Write-Host ('selftest: profile exists = ' + (Test-Path -LiteralPath $PackTo))
    }

    $form.Hide()
    $form.Dispose()
    return
}
try {
    [void]$form.ShowDialog()
} catch {
    Write-UiLog ('окно закрылось с ошибкой: ' + $_.Exception.ToString()) 'err'
    Show-UiCrash $_.Exception
} finally {
    Write-UiLog 'выход'
    $form.Dispose()
}
