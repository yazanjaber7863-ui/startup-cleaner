# StartupCleaner - list, disable, enable and remove Windows startup apps
# (the same entries Task Manager shows under "Startup apps").

# Relaunch elevated so HKLM entries and the all-users Startup folder can be changed.
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    exit
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$BackupDir = Join-Path $PSScriptRoot 'backups'
$ApprovedRoot = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
$PackagedRoot = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'

# Each source: where entries live, and which StartupApproved subkey tracks their enabled state.
$RegSources = @(
    @{ Hive = 'HKCU'; Path = 'Software\Microsoft\Windows\CurrentVersion\Run';             Approved = 'Run' }
    @{ Hive = 'HKLM'; Path = 'Software\Microsoft\Windows\CurrentVersion\Run';             Approved = 'Run' }
    @{ Hive = 'HKLM'; Path = 'Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'Run32' }
)
$FolderSources = @(
    @{ Hive = 'HKCU'; Path = [Environment]::GetFolderPath('Startup') }
    @{ Hive = 'HKLM'; Path = [Environment]::GetFolderPath('CommonStartup') }
)

function Get-ApprovedState($hive, $subkey, $name) {
    $bytes = (Get-ItemProperty -Path "${hive}:\$ApprovedRoot\$subkey" -Name $name -ErrorAction SilentlyContinue).$name
    if ($bytes -and ($bytes[0] -band 1)) { 'Disabled' } else { 'Enabled' }
}

function Set-ApprovedState($hive, $subkey, $name, [bool]$enabled) {
    $key = "${hive}:\$ApprovedRoot\$subkey"
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    $bytes = [byte[]](@([byte]$(if ($enabled) { 2 } else { 3 })) + (,[byte]0 * 11))
    if (-not $enabled) {
        # Task Manager stores the disable time as a FILETIME in bytes 4-11.
        [BitConverter]::GetBytes([DateTime]::Now.ToFileTime()).CopyTo($bytes, 4)
    }
    New-ItemProperty -Path $key -Name $name -Value $bytes -PropertyType Binary -Force | Out-Null
}

# Pull the executable out of a command line such as
#   "C:\Program Files\App\app.exe" --flag   or   C:\Program Files\Parsec\parsecd.exe app_silent=1
function Resolve-ExePath([string]$cmd) {
    $cmd = [Environment]::ExpandEnvironmentVariables($cmd).Trim()
    if ($cmd.StartsWith('"')) {
        $path = $cmd.Substring(1, $cmd.IndexOf('"', 1) - 1)
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
        return $null
    }
    $parts = $cmd -split ' '
    for ($i = $parts.Count; $i -ge 1; $i--) {
        $path = $parts[0..($i - 1)] -join ' '
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    }
    $null
}

function Get-FileIcon([string]$path) {
    try { if ($path) { return ([System.Drawing.Icon]::ExtractAssociatedIcon($path)).ToBitmap() } } catch {}
    $null
}

# Friendly name the way Task Manager does it: the exe's file description, else the entry name.
function Get-FriendlyName([string]$exe, [string]$fallback) {
    if ($exe) {
        $desc = (Get-Item -LiteralPath $exe -ErrorAction SilentlyContinue).VersionInfo.FileDescription
        if ($desc -and $desc.Trim()) { return $desc.Trim() }
    }
    $fallback
}

function Get-PackageInfo([string]$familyName) {
    $info = @{ Name = $null; Icon = $null }
    $app = $script:StartApps | Where-Object { $_.AppID -like "$familyName!*" } | Select-Object -First 1
    if ($app) { $info.Name = $app.Name }
    $pkg = Get-AppxPackage -Name ($familyName -split '_')[0] -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkg) {
        try {
            [xml]$manifest = Get-Content -LiteralPath (Join-Path $pkg.InstallLocation 'AppxManifest.xml') -Raw
            $visual = $manifest.Package.Applications.Application | Select-Object -First 1 | ForEach-Object { $_.VisualElements }
            $logo = $visual.Square44x44Logo
            if ($logo) {
                $dir = Join-Path $pkg.InstallLocation (Split-Path $logo -Parent)
                $base = [IO.Path]::GetFileNameWithoutExtension($logo)
                # Prefer the unplated 32px variant, then any scaled variant.
                $file = Get-ChildItem -LiteralPath $dir -Filter "$base*.png" -ErrorAction SilentlyContinue |
                    Sort-Object { if ($_.Name -match 'targetsize-32_altform-unplated') { 0 } elseif ($_.Name -match 'targetsize-32') { 1 } elseif ($_.Name -match 'scale-100') { 2 } else { 3 } } |
                    Select-Object -First 1
                if ($file) {
                    $ms = New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($file.FullName))
                    $info.Icon = [System.Drawing.Image]::FromStream($ms)
                }
            }
            if (-not $info.Name -and $manifest.Package.Properties.DisplayName -notlike 'ms-resource:*') {
                $info.Name = $manifest.Package.Properties.DisplayName
            }
        } catch {}
    }
    $info
}

function Get-StartupEntries {
    $list = New-Object System.Collections.Generic.List[object]

    foreach ($src in $RegSources) {
        $key = Get-Item -Path "$($src.Hive):\$($src.Path)" -ErrorAction SilentlyContinue
        if (-not $key) { continue }
        foreach ($name in $key.GetValueNames()) {
            if ($name -eq '') { continue }
            $cmd = [string]$key.GetValue($name, '', 'DoNotExpandEnvironmentNames')
            $exe = Resolve-ExePath $cmd
            $list.Add([pscustomobject]@{
                Name     = $name
                Display  = Get-FriendlyName $exe $name
                Icon     = Get-FileIcon $exe
                Status   = Get-ApprovedState $src.Hive $src.Approved $name
                Type     = 'Registry'
                Location = "$($src.Hive)\$($src.Path)"
                Command  = $cmd
                Hive     = $src.Hive
                Approved = $src.Approved
                Target   = $name
                Kind     = [Microsoft.Win32.RegistryValueKind]$key.GetValueKind($name)
            })
        }
    }

    foreach ($src in $FolderSources) {
        if (-not (Test-Path $src.Path)) { continue }
        foreach ($file in Get-ChildItem -Path $src.Path -File -ErrorAction SilentlyContinue | Where-Object Name -ne 'desktop.ini') {
            $cmd = $file.FullName
            $iconSource = $file.FullName
            if ($file.Extension -eq '.lnk') {
                $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($file.FullName)
                $cmd = "$($lnk.TargetPath) $($lnk.Arguments)".Trim()
                $iconPath = ($lnk.IconLocation -split ',')[0]
                $iconSource = if ($iconPath -and (Test-Path -LiteralPath $iconPath)) { $iconPath } else { $lnk.TargetPath }
            }
            $list.Add([pscustomobject]@{
                Name     = $file.BaseName
                Display  = $file.BaseName
                Icon     = Get-FileIcon $iconSource
                Status   = Get-ApprovedState $src.Hive 'StartupFolder' $file.Name
                Type     = 'Startup folder'
                Location = $src.Path
                Command  = $cmd
                Hive     = $src.Hive
                Approved = 'StartupFolder'
                Target   = $file.FullName
                Kind     = $null
            })
        }
    }

    # Store/MSIX apps (Terminal, Command Palette, To Do...) register StartupTasks in their
    # manifest. They cannot be deleted without uninstalling the app, only disabled.
    if (Test-Path $PackagedRoot) {
        $script:StartApps = @(Get-StartApps)
        foreach ($task in Get-ChildItem -Path $PackagedRoot -ErrorAction SilentlyContinue | Get-ChildItem -ErrorAction SilentlyContinue) {
            $state = (Get-ItemProperty -Path $task.PSPath -Name State -ErrorAction SilentlyContinue).State
            if ($null -eq $state) { continue }
            $pkg = Split-Path (Split-Path $task.Name -Parent) -Leaf
            $info = Get-PackageInfo $pkg
            $list.Add([pscustomobject]@{
                Name     = "$(($pkg -split '_')[0]) ($($task.PSChildName))"
                Display  = $(if ($info.Name) { $info.Name } else { ($pkg -split '_')[0] })
                Icon     = $info.Icon
                Status   = $(if ($state -in 2, 4) { 'Enabled' } else { 'Disabled' })
                Type     = 'Store app'
                Location = $pkg
                Command  = ''
                Hive     = 'HKCU'
                Approved = $null
                Target   = $task.PSPath
                Kind     = $null
            })
        }
    }

    $list | Sort-Object Display
}

function ConvertTo-RegString([string]$s) { $s.Replace('\', '\\').Replace('"', '\"') }

function Backup-Entry($e) {
    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safe = ($e.Name -replace '[^\w\.-]', '_')
    if ($e.Type -eq 'Registry') {
        $root = if ($e.Hive -eq 'HKCU') { 'HKEY_CURRENT_USER' } else { 'HKEY_LOCAL_MACHINE' }
        $keyPath = $e.Location.Substring(5)
        $value = if ($e.Kind -eq 'ExpandString') {
            # REG_EXPAND_SZ has to be written as UTF-16LE hex in .reg files.
            'hex(2):' + (([Text.Encoding]::Unicode.GetBytes($e.Command + "`0") | ForEach-Object { $_.ToString('x2') }) -join ',')
        } else { '"' + (ConvertTo-RegString $e.Command) + '"' }
        $reg = "Windows Registry Editor Version 5.00`r`n`r`n[$root\$keyPath]`r`n`"$(ConvertTo-RegString $e.Name)`"=$value`r`n"
        $file = Join-Path $BackupDir "$stamp-$safe.reg"
        Set-Content -Path $file -Value $reg -Encoding Unicode
    } else {
        $file = Join-Path $BackupDir "$stamp-$(Split-Path $e.Target -Leaf)"
        Copy-Item -Path $e.Target -Destination $file
    }
    $file
}

function Remove-Entry($e) {
    $backup = Backup-Entry $e
    if ($e.Type -eq 'Registry') {
        Remove-ItemProperty -Path "$($e.Hive):\$($e.Location.Substring(5))" -Name $e.Target -ErrorAction Stop
        $approvedName = $e.Target
    } else {
        Remove-Item -Path $e.Target -Force -ErrorAction Stop
        $approvedName = Split-Path $e.Target -Leaf
    }
    Remove-ItemProperty -Path "$($e.Hive):\$ApprovedRoot\$($e.Approved)" -Name $approvedName -ErrorAction SilentlyContinue
    $backup
}

function Set-EntryEnabled($e, [bool]$enabled) {
    if ($e.Type -eq 'Store app') {
        Set-ItemProperty -Path $e.Target -Name State -Value $(if ($enabled) { 2 } else { 1 }) -Type DWord
    } else {
        $name = if ($e.Type -eq 'Registry') { $e.Target } else { Split-Path $e.Target -Leaf }
        Set-ApprovedState $e.Hive $e.Approved $name $enabled
    }
}

# ---------------- UI ----------------

Add-Type -Namespace Native -Name Dwm -MemberDefinition @'
[DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
'@

function Rgb($hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
$C = @{
    Bg       = Rgb '#202020'
    Surface  = Rgb '#2b2b2b'
    Hover    = Rgb '#333333'
    Selected = Rgb '#383838'
    Text     = Rgb '#ffffff'
    Muted    = Rgb '#9d9d9d'
    Accent   = Rgb '#60cdff'
    On       = Rgb '#6ccb5f'
    Off      = Rgb '#8a8a8a'
    Danger   = Rgb '#c42b1c'
    DangerHi = Rgb '#d13a2b'
}
$FontBody  = New-Object System.Drawing.Font('Segoe UI', 10)
$FontTitle = New-Object System.Drawing.Font('Segoe UI Semibold', 18)
$FontSmall = New-Object System.Drawing.Font('Segoe UI', 9)
$FallbackIcon = [System.Drawing.SystemIcons]::Application.ToBitmap()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Startup Cleaner'
$form.ClientSize = New-Object System.Drawing.Size(520, 600)
$form.MinimumSize = New-Object System.Drawing.Size(420, 400)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $C.Bg
$form.ForeColor = $C.Text
$form.Font = $FontBody
$form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon("$env:windir\System32\Taskmgr.exe")
$form.Add_HandleCreated({
    # Dark title bar (Win10 20H1+) and Win11 rounded Mica-style backdrop.
    $on = 1; [void][Native.Dwm]::DwmSetWindowAttribute($form.Handle, 20, [ref]$on, 4)
})

# Header
$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = 84
$header.Padding = New-Object System.Windows.Forms.Padding(24, 18, 24, 0)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Startup apps'
$title.Font = $FontTitle
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(22, 14)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Font = $FontSmall
$subtitle.ForeColor = $C.Muted
$subtitle.AutoSize = $true
$subtitle.Location = New-Object System.Drawing.Point(25, 52)

$header.Controls.AddRange(@($title, $subtitle))

# App list
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.AllowUserToResizeColumns = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $true
$grid.RowHeadersVisible = $false
$grid.ColumnHeadersVisible = $false
$grid.AutoSizeColumnsMode = 'Fill'
$grid.BackgroundColor = $C.Bg
$grid.GridColor = $C.Bg
$grid.BorderStyle = 'None'
$grid.CellBorderStyle = 'None'
$grid.RowTemplate.Height = 48
$grid.DefaultCellStyle.BackColor = $C.Bg
$grid.DefaultCellStyle.ForeColor = $C.Text
$grid.DefaultCellStyle.SelectionBackColor = $C.Selected
$grid.DefaultCellStyle.SelectionForeColor = $C.Text
$grid.DefaultCellStyle.Font = $FontBody
# Smooth scrolling/redraw (DoubleBuffered is protected, so set it via reflection).
$grid.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($grid, $true)

$colIcon = New-Object System.Windows.Forms.DataGridViewImageColumn
$colIcon.Width = 56
$colIcon.AutoSizeMode = 'None'
$colIcon.ImageLayout = 'Zoom'
$colIcon.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(20, 12, 4, 12)
$colIcon.DefaultCellStyle.NullValue = $null
$colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colName.FillWeight = 100
$colStatus = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colStatus.Width = 110
$colStatus.AutoSizeMode = 'None'
$grid.Columns.AddRange([System.Windows.Forms.DataGridViewColumn[]]@($colIcon, $colName, $colStatus))

# Status column: coloured dot + text instead of plain text.
$grid.Add_CellPainting({
    param($s, $ev)
    if ($ev.RowIndex -lt 0 -or $ev.ColumnIndex -ne 2) { return }
    $ev.PaintBackground($ev.ClipBounds, $ev.State.HasFlag([System.Windows.Forms.DataGridViewElementStates]::Selected))
    $on = $ev.Value -eq 'Enabled'
    $g = $ev.Graphics
    $g.SmoothingMode = 'AntiAlias'
    $b = $ev.CellBounds
    $dotY = $b.Y + ($b.Height - 8) / 2
    $brush = New-Object System.Drawing.SolidBrush $(if ($on) { $C.On } else { $C.Off })
    $g.FillEllipse($brush, $b.X + 4, $dotY, 8, 8)
    $text = if ($on) { 'Enabled' } else { 'Disabled' }
    $rect = New-Object System.Drawing.Rectangle(($b.X + 18), $b.Y, ($b.Width - 18), $b.Height)
    [System.Windows.Forms.TextRenderer]::DrawText($g, $text, $FontSmall, $rect, $(if ($on) { $C.Text } else { $C.Muted }), [System.Windows.Forms.TextFormatFlags]'VerticalCenter,Left')
    $brush.Dispose()
    $ev.Handled = $true
})

# Hover highlight
$script:hoverRow = -1
$grid.Add_CellMouseEnter({ param($s, $ev)
    if ($ev.RowIndex -ge 0 -and -not $grid.Rows[$ev.RowIndex].Selected) { $grid.Rows[$ev.RowIndex].DefaultCellStyle.BackColor = $C.Hover }
    $script:hoverRow = $ev.RowIndex
})
$grid.Add_CellMouseLeave({ param($s, $ev)
    if ($ev.RowIndex -ge 0) { $grid.Rows[$ev.RowIndex].DefaultCellStyle.BackColor = $C.Bg }
})

# Bottom action bar
$bar = New-Object System.Windows.Forms.Panel
$bar.Dock = 'Bottom'
$bar.Height = 68
$bar.BackColor = $C.Surface

function New-Button($text, $back, $hover) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.FlatAppearance.MouseOverBackColor = $hover
    $b.FlatAppearance.MouseDownBackColor = $hover
    $b.BackColor = $back
    $b.ForeColor = $C.Text
    $b.Size = New-Object System.Drawing.Size(110, 34)
    $b.Cursor = 'Hand'
    $bar.Controls.Add($b)
    $b
}
$btnToggle = New-Button 'Disable' (Rgb '#3a3a3a') (Rgb '#454545')
$btnRemove = New-Button 'Remove' $C.Danger $C.DangerHi
$btnMore   = New-Button '...' $C.Surface (Rgb '#3a3a3a')
$btnMore.Size = New-Object System.Drawing.Size(40, 34)

$layoutBar = {
    $y = ($bar.Height - 34) / 2
    $btnRemove.Location = New-Object System.Drawing.Point(($bar.Width - 24 - $btnRemove.Width), $y)
    $btnToggle.Location = New-Object System.Drawing.Point(($btnRemove.Left - 8 - $btnToggle.Width), $y)
    $btnMore.Location   = New-Object System.Drawing.Point(20, $y)
}
$bar.Add_Resize($layoutBar)

# "..." menu for the rarely used actions
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.ShowImageMargin = $false
$menu.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer
$menu.BackColor = $C.Surface
$menu.ForeColor = $C.Text
$miOpen    = $menu.Items.Add('Open file location')
$miBackups = $menu.Items.Add('Open backups folder')
$miRefresh = $menu.Items.Add('Refresh')
foreach ($mi in $menu.Items) { $mi.BackColor = $C.Surface; $mi.ForeColor = $C.Text; $mi.Padding = New-Object System.Windows.Forms.Padding(4) }
$btnMore.Add_Click({ $menu.Show($btnMore, 0, -$menu.PreferredSize.Height) })
$grid.ContextMenuStrip = $menu

$form.Controls.Add($grid)
$form.Controls.Add($header)
$form.Controls.Add($bar)

$script:entries = @()

function Load-Grid {
    $form.Cursor = 'WaitCursor'
    $script:entries = @(Get-StartupEntries)
    $grid.Rows.Clear()
    foreach ($e in $script:entries) {
        $icon = if ($e.Icon) { $e.Icon } else { $FallbackIcon }
        $i = $grid.Rows.Add($icon, $e.Display, $e.Status)
        $grid.Rows[$i].Tag = $e
        if ($e.Status -eq 'Disabled') { $grid.Rows[$i].Cells[1].Style.ForeColor = $C.Muted }
    }
    $enabled = @($script:entries | Where-Object Status -eq 'Enabled').Count
    $subtitle.Text = "$enabled of $($script:entries.Count) apps start with Windows"
    $grid.CurrentCell = $null
    $grid.ClearSelection()
    Update-Buttons
    $form.Cursor = 'Default'
}

# Index loop: Windows PowerShell 5.1 doesn't enumerate SelectedRows through the pipeline.
function Get-Selected {
    $rows = $grid.SelectedRows
    @(for ($i = 0; $i -lt $rows.Count; $i++) { $rows[$i].Tag })
}

function Update-Buttons {
    $sel = @(Get-Selected)
    $any = $sel.Count -gt 0
    $btnToggle.Enabled = $any
    $btnRemove.Enabled = $any
    $allOff = $sel.Count -gt 0 -and -not ($sel | Where-Object Status -eq 'Enabled')
    $btnToggle.Text = if ($allOff) { 'Enable' } else { 'Disable' }
    foreach ($b in $btnToggle, $btnRemove) { $b.ForeColor = if ($b.Enabled) { $C.Text } else { $C.Muted } }
}
$grid.Add_SelectionChanged({
    foreach ($row in $grid.Rows) { if ($row.Selected) { $row.DefaultCellStyle.BackColor = $C.Bg } }
    Update-Buttons
})

function Show-Errors($errors) {
    if ($errors) { [void][System.Windows.Forms.MessageBox]::Show(($errors -join "`n"), 'Some apps failed', 'OK', 'Error') }
}

$btnRemove.Add_Click({
    $sel = @(Get-Selected)
    $removable = @($sel | Where-Object Type -ne 'Store app')
    $skipped = $sel.Count - $removable.Count
    if (-not $removable) {
        [void][System.Windows.Forms.MessageBox]::Show('Store apps can only be disabled, not removed. Uninstall the app to get rid of it.', 'Startup Cleaner')
        return
    }
    $names = ($removable | ForEach-Object { "  - $($_.Display)" }) -join "`n"
    $msg = "Remove these from startup?`n`n$names`n`nA backup is saved first, so you can restore them later."
    if ($skipped) { $msg += "`n`n$skipped Store app(s) skipped - those can only be disabled." }
    if ([System.Windows.Forms.MessageBox]::Show($msg, 'Remove from startup', 'YesNo', 'Warning') -ne 'Yes') { return }
    Show-Errors @(foreach ($e in $removable) {
        try { [void](Remove-Entry $e) } catch { "$($e.Display): $($_.Exception.Message)" }
    })
    Load-Grid
})

$btnToggle.Add_Click({
    $enable = $btnToggle.Text -eq 'Enable'
    Show-Errors @(foreach ($e in @(Get-Selected)) {
        try { Set-EntryEnabled $e $enable } catch { "$($e.Display): $($_.Exception.Message)" }
    })
    Load-Grid
})

$miOpen.Add_Click({
    $e = @(Get-Selected)[0]
    if (-not $e) { return }
    switch ($e.Type) {
        'Startup folder' { Start-Process explorer.exe "/select,`"$($e.Target)`"" }
        'Registry' {
            $exe = Resolve-ExePath $e.Command
            if ($exe) { Start-Process explorer.exe "/select,`"$exe`"" }
        }
        'Store app' { Start-Process 'ms-settings:startupapps' }
    }
})
$miBackups.Add_Click({
    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir | Out-Null }
    Start-Process explorer.exe $BackupDir
})
$miRefresh.Add_Click({ Load-Grid })
$grid.Add_KeyDown({ if ($_.KeyCode -eq 'Delete' -and $btnRemove.Enabled) { $btnRemove.PerformClick() } })
# Clicking empty space clears the selection.
$grid.Add_MouseDown({ param($s, $ev)
    if ($grid.HitTest($ev.X, $ev.Y).RowIndex -lt 0) { $grid.ClearSelection() }
    elseif ($ev.Button -eq 'Right') {
        $row = $grid.Rows[$grid.HitTest($ev.X, $ev.Y).RowIndex]
        if (-not $row.Selected) { $grid.ClearSelection(); $row.Selected = $true }
    }
})

$form.Add_Shown({ & $layoutBar; Load-Grid })
[void]$form.ShowDialog()
