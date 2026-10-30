#requires -version 5.1
# Reminder Calendar - a tray app that keeps a calendar of reminders and
# shows a pop-up alert when they're due.
param([switch]$Minimized, [string]$Snapshot)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
# Route WinForms (tray menu) errors to our handler instead of a crash dialog.
[System.Windows.Forms.Application]::SetUnhandledExceptionMode('CatchException')

$AppName      = 'Reminder Calendar'
$ScriptPath   = $PSCommandPath
$DataDir      = Join-Path $env:APPDATA 'ReminderCalendar'
$DataFile     = Join-Path $DataDir 'reminders.json'
$SettingsFile = Join-Path $DataDir 'settings.json'
$StartupLnk   = Join-Path ([Environment]::GetFolderPath('Startup')) "$AppName.lnk"
$Fmt          = 'yyyy-MM-ddTHH:mm:ss'
$Inv          = [Globalization.CultureInfo]::InvariantCulture
$Dot          = [string][char]0x00B7
$LogFile      = Join-Path $env:APPDATA 'ReminderCalendar\error.log'
$RepeatOptions = [ordered]@{ 'Never' = 'None'; 'Minutes' = 'Minutely'; 'Hours' = 'Hourly'; 'Days' = 'Daily'; 'Weeks' = 'Weekly'; 'Months' = 'Monthly'; 'Years' = 'Yearly' }
$RepeatUnits   = @{ Minutely = 'minute'; Hourly = 'hour'; Daily = 'day'; Weekly = 'week'; Monthly = 'month'; Yearly = 'year' }
$LeadOptions   = [ordered]@{ 'At time' = 0; '5 min' = 5; '10 min' = 10; '15 min' = 15; '30 min' = 30; '1 hour' = 60; '2 hours' = 120; '1 day' = 1440 }
$Colors        = [ordered]@{ Violet = '#7C5CFF'; Blue = '#3B82F6'; Teal = '#14B8A6'; Green = '#22C55E'; Amber = '#F59E0B'; Rose = '#F43F5E' }

# ---- single instance: a second launch just tells the running one to show itself
$created   = $false
$mutex     = New-Object System.Threading.Mutex($true, 'Local\ReminderCalendarMutex', [ref]$created)
$showEvent = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\ReminderCalendarShow')
if (-not $created -and -not $Snapshot) { [void]$showEvent.Set(); return }

# ---- storage
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

function Import-Data {
    $script:Reminders = New-Object System.Collections.ArrayList
    if (Test-Path $DataFile) {
        try {
            $items = Get-Content $DataFile -Raw | ConvertFrom-Json
            foreach ($r in $items) {
                if (-not $r) { continue }
                Initialize-Reminder $r
                [void]$script:Reminders.Add($r)
            }
        } catch {}
    }
}

function Save-Data {
    ConvertTo-Json -InputObject @($script:Reminders) -Depth 4 | Set-Content -Path $DataFile -Encoding UTF8
}

function Save-Settings {
    $script:Settings | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8
}

$firstRun = -not (Test-Path $SettingsFile)
$Settings = [pscustomobject]@{ Popups = $true }
if (-not $firstRun) { try { $Settings = Get-Content $SettingsFile -Raw | ConvertFrom-Json } catch {} }

# ---- dates and repeats
function ConvertTo-Date([string]$s) { [datetime]::ParseExact($s, $Fmt, $Inv) }
function Get-Start($r) { ConvertTo-Date $r.Start }

# Older saves don't have the newer fields.
function Initialize-Reminder($r) {
    if (-not $r.PSObject.Properties['Color'])    { $r | Add-Member Color $Colors.Violet }
    if (-not $r.PSObject.Properties['Interval']) { $r | Add-Member Interval 1 }
    if (-not $r.PSObject.Properties['Days'])     { $r | Add-Member Days @() }
    if (-not $r.PSObject.Properties['Until'])    { $r | Add-Member Until '' }
    if (-not $r.Repeat) { $r.Repeat = 'None' }
}

function Get-Interval($r) { [math]::Max(1, [int]$r.Interval) }

# Weekdays (0 = Sunday) a weekly reminder lands on; defaults to the start's weekday.
function Get-WeekDays($r) {
    $d = @($r.Days | Where-Object { $_ -ne $null } | ForEach-Object { [int]$_ } | Sort-Object -Unique)
    if ($d.Count) { $d } else { , @([int](Get-Start $r).DayOfWeek) }
}

# Longest possible gap between two occurrences.
function Get-MaxGap($r) {
    $k = Get-Interval $r
    switch ($r.Repeat) {
        'Minutely' { [TimeSpan]::FromMinutes($k) }
        'Hourly'   { [TimeSpan]::FromHours($k) }
        'Daily'    { [TimeSpan]::FromDays($k) }
        'Weekly'   { [TimeSpan]::FromDays(7 * $k) }
        'Monthly'  { [TimeSpan]::FromDays(31 * $k) }
        'Yearly'   { [TimeSpan]::FromDays(366 * $k) }
        default    { [TimeSpan]::Zero }
    }
}

function Get-OccurrencesInRange($r, [datetime]$a, [datetime]$b, [int]$Max = 0) {
    $list = New-Object System.Collections.Generic.List[datetime]
    $s = Get-Start $r
    if ($r.Repeat -eq 'None') {
        if ($s -ge $a -and $s -lt $b) { $list.Add($s) }
        return , $list
    }
    if ($r.Until) { $end = (ConvertTo-Date $r.Until).Date.AddDays(1); if ($b -gt $end) { $b = $end } }
    if ($a -lt $s) { $a = $s }
    if ($a -ge $b) { return , $list }
    $k = Get-Interval $r

    switch ($r.Repeat) {
        { $_ -in 'Minutely', 'Hourly', 'Daily' } {
            $step = Get-MaxGap $r
            $n = [long][math]::Floor(($a - $s).Ticks / $step.Ticks)
            $o = $s.AddTicks($n * $step.Ticks)
            while ($o -lt $a) { $o = $o + $step }
            while ($o -lt $b -and (-not $Max -or $list.Count -lt $Max)) { $list.Add($o); $o = $o + $step }
        }
        { $_ -in 'Monthly', 'Yearly' } {
            $months = if ($r.Repeat -eq 'Monthly') { $k } else { 12 * $k }
            $diff = ($a.Year - $s.Year) * 12 + $a.Month - $s.Month
            $n = [math]::Max(0, [math]::Floor($diff / $months) - 1)
            while ($true) {
                $o = $s.AddMonths([int]($n * $months))
                if ($o -ge $b) { break }
                if ($o -ge $a) { $list.Add($o) }
                $n++
            }
        }
        'Weekly' {
            $days = Get-WeekDays $r
            $week0 = $s.Date.AddDays(-[int]$s.DayOfWeek)
            $m = [math]::Floor([math]::Floor(($a.Date - $week0).TotalDays / 7) / $k)
            while ($true) {
                $ws = $week0.AddDays(7 * $k * $m)
                if ($ws -ge $b) { break }
                foreach ($d in $days) {
                    $o = $ws.AddDays($d) + $s.TimeOfDay
                    if ($o -ge $a -and $o -lt $b) { $list.Add($o) }
                }
                $m++
            }
        }
    }
    return , $list
}

# Latest occurrence whose alert time (occurrence - lead) has already arrived.
function Get-DueOccurrence($r, [datetime]$now) {
    $t = $now.AddMinutes([int]$r.Lead)
    $from = if ($r.Repeat -eq 'None') { [datetime]::MinValue } else { $t - (Get-MaxGap $r) }
    $occ = Get-OccurrencesInRange $r $from $t.AddTicks(1)
    if ($occ.Count) { $occ[$occ.Count - 1] } else { $null }
}

function Get-RepeatText($r) {
    if ($r.Repeat -eq 'None') { return 'Does not repeat' }
    $k = Get-Interval $r
    $unit = $RepeatUnits[$r.Repeat]
    $text = if ($k -eq 1) { "Every $unit" } else { "Every $k ${unit}s" }
    if ($r.Repeat -eq 'Weekly') {
        $days = @(Get-WeekDays $r)
        $names = [Globalization.CultureInfo]::CurrentCulture.DateTimeFormat.AbbreviatedDayNames
        if ($k -eq 1 -and ($days -join ',') -eq '1,2,3,4,5') { $text = 'Every weekday' }
        elseif ($k -eq 1 -and $days.Count -eq 7) { $text = 'Every day' }
        else { $text += ' on ' + (($days | ForEach-Object { $names[$_] }) -join ', ') }
    }
    if ($r.Until) { $text += ' until ' + (ConvertTo-Date $r.Until).ToString('MMM d, yyyy') }
    $text
}

# Occurrences of every reminder in [a, b), sorted by time. Minute/hour repeats would flood the
# views, so -PerDay keeps only their first occurrence each day and -FirstOnly only their next one.
function Get-Agenda([datetime]$a, [datetime]$b, [switch]$PerDay, [switch]$FirstOnly) {
    $rows = foreach ($r in $script:Reminders) {
        if ($r.Repeat -in 'Minutely', 'Hourly' -and $FirstOnly) {
            foreach ($o in (Get-OccurrencesInRange $r $a $b 1)) { [pscustomobject]@{ R = $r; O = $o } }
        } elseif ($r.Repeat -in 'Minutely', 'Hourly' -and $PerDay) {
            for ($d = $a.Date; $d -lt $b; $d = $d.AddDays(1)) {
                $lo = if ($d -lt $a) { $a } else { $d }
                foreach ($o in (Get-OccurrencesInRange $r $lo $d.AddDays(1) 1)) { [pscustomobject]@{ R = $r; O = $o } }
            }
        } else {
            foreach ($o in (Get-OccurrencesInRange $r $a $b)) { [pscustomobject]@{ R = $r; O = $o } }
        }
    }
    @($rows | Sort-Object O)
}

function Get-LeadText([int]$m) {
    if ($m -eq 0) { return 'At time' }
    foreach ($k in $LeadOptions.Keys) { if ($LeadOptions[$k] -eq $m) { return "$k before" } }
    "$m min before"
}

function Format-Minutes([int]$m) {
    if ($m -lt 60) { return "$m min" }
    if ($m -lt 1440) { $h = [math]::Floor($m / 60); $r = $m % 60; return $(if ($r) { "$h h $r min" } else { "$h h" }) }
    $d = [math]::Round($m / 1440); "$d day" + $(if ($d -ne 1) { 's' })
}

function Format-ShortTime([datetime]$t) {
    $tt = $t.ToString('tt')
    $t.ToString('h:mm') + $(if ($tt) { $tt.Substring(0, 1).ToLower() })
}

function Format-DayLabel([datetime]$d) {
    $today = (Get-Date).Date
    if ($d.Date -eq $today) { 'Today' }
    elseif ($d.Date -eq $today.AddDays(1)) { 'Tomorrow' }
    else { $d.ToString('dddd, MMM d') }
}

function ConvertFrom-TimeText([string]$s) {
    $s = ($s.Trim().ToLower() -replace '\.', '')
    if ($s -eq 'noon') { return New-TimeSpan -Hours 12 }
    if ($s -eq 'midnight') { return New-TimeSpan }
    if ($s -notmatch '^(\d{1,2})(?::?(\d{2}))?\s*(a|am|p|pm)?$') { return $null }
    $h = [int]$Matches[1]
    $m = if ($Matches[2]) { [int]$Matches[2] } else { 0 }
    $ap = $Matches[3]
    if ($ap) {
        if ($h -lt 1 -or $h -gt 12) { return $null }
        if ($ap -like 'p*' -and $h -ne 12) { $h += 12 }
        if ($ap -like 'a*' -and $h -eq 12) { $h = 0 }
    }
    if ($h -gt 23 -or $m -gt 59) { return $null }
    New-TimeSpan -Hours $h -Minutes $m
}

function ConvertFrom-DateText([string]$s) {
    $d = [datetime]::MinValue
    if ([datetime]::TryParseExact($s.Trim(), 'ddd, MMM d, yyyy', $null, 'AllowWhiteSpaces', [ref]$d)) { return $d.Date }
    if ([datetime]::TryParse($s.Trim(), [ref]$d)) { return $d.Date }
    $null
}

# ---- icon (accent tile with today's day number)
function New-IconBitmap([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $d = [int]($size * 0.5); $w = $size - 1
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $d, $d, 180, 90); $path.AddArc($w - $d, 0, $d, $d, 270, 90)
    $path.AddArc($w - $d, $w - $d, $d, $d, 0, 90); $path.AddArc(0, $w - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(124, 92, 255))), $path)
    $font = New-Object System.Drawing.Font('Segoe UI', [float]($size * 0.5), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $g.DrawString((Get-Date).Day.ToString(), $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, 1, $size, $size)), $sf)
    $g.Dispose()
    $bmp
}

# ---- start with Windows
function Set-Startup([bool]$on) {
    if (-not $on) { Remove-Item $StartupLnk -ErrorAction SilentlyContinue; return }
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($StartupLnk)
    $s.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -Minimized"
    $s.WorkingDirectory = Split-Path $ScriptPath
    $s.WindowStyle = 7
    $s.Save()
}

# ---- dark title bar (Windows 11)
try {
    Add-Type -Namespace RC -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);'
} catch {}

function Set-DarkTitleBar($window) {
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        $v = 1; [void][RC.Dwm]::DwmSetWindowAttribute($h, 20, [ref]$v, 4)        # immersive dark mode
        $c = 0x0015110F; [void][RC.Dwm]::DwmSetWindowAttribute($h, 35, [ref]$c, 4) # caption color = #0F1115
    } catch {}
}

# ---- theme
$ThemeXaml = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <SolidColorBrush x:Key="Bg" Color="#0F1115"/>
  <SolidColorBrush x:Key="Side" Color="#14171D"/>
  <SolidColorBrush x:Key="Surface" Color="#1A1E26"/>
  <SolidColorBrush x:Key="Surface2" Color="#232833"/>
  <SolidColorBrush x:Key="Line" Color="#272D39"/>
  <SolidColorBrush x:Key="Text" Color="#E8EAF0"/>
  <SolidColorBrush x:Key="Muted" Color="#8A93A6"/>
  <SolidColorBrush x:Key="Faint" Color="#4A5263"/>
  <SolidColorBrush x:Key="Accent" Color="#7C5CFF"/>
  <SolidColorBrush x:Key="AccentHover" Color="#9378FF"/>
  <SolidColorBrush x:Key="Danger" Color="#F43F5E"/>
  <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>

  <Style x:Key="BtnBase" TargetType="Button">
    <Setter Property="Foreground" Value="{StaticResource Text}"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Padding" Value="14,8"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                  BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.75"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="AccentBtn" TargetType="Button" BasedOn="{StaticResource BtnBase}">
    <Setter Property="Background" Value="{StaticResource Accent}"/>
    <Setter Property="Foreground" Value="White"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{StaticResource AccentHover}"/></Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Ghost" TargetType="Button" BasedOn="{StaticResource BtnBase}">
    <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{StaticResource Surface2}"/></Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="DangerGhost" TargetType="Button" BasedOn="{StaticResource Ghost}">
    <Setter Property="Foreground" Value="{StaticResource Danger}"/>
    <Setter Property="BorderBrush" Value="#4A2433"/>
  </Style>
  <Style x:Key="Icon" TargetType="Button" BasedOn="{StaticResource BtnBase}">
    <Setter Property="Width" Value="34"/>
    <Setter Property="Height" Value="34"/>
    <Setter Property="Padding" Value="0"/>
    <Setter Property="FontFamily" Value="{StaticResource Icons}"/>
    <Setter Property="FontSize" Value="14"/>
    <Setter Property="Foreground" Value="{StaticResource Muted}"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{StaticResource Surface2}"/>
        <Setter Property="Foreground" Value="{StaticResource Text}"/>
      </Trigger>
    </Style.Triggers>
  </Style>

  <Style x:Key="Input" TargetType="TextBox">
    <Setter Property="Foreground" Value="{StaticResource Text}"/>
    <Setter Property="Background" Value="{StaticResource Surface2}"/>
    <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Padding" Value="5,8"/>
    <Setter Property="FontSize" Value="14"/>
    <Setter Property="CaretBrush" Value="{StaticResource Text}"/>
    <Setter Property="SelectionBrush" Value="{StaticResource Accent}"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="TextBox">
          <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                  BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
            <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                          VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Faint}"/></Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key="Pill" TargetType="RadioButton">
    <Setter Property="Foreground" Value="{StaticResource Muted}"/>
    <Setter Property="Margin" Value="0,0,6,6"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Border x:Name="b" Background="{StaticResource Surface2}" BorderBrush="{StaticResource Line}" BorderThickness="1"
                  CornerRadius="15" Padding="12,5">
            <ContentPresenter/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Faint}"/>
              <Setter Property="Foreground" Value="{StaticResource Text}"/>
            </Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="b" Property="Background" Value="{StaticResource Accent}"/>
              <Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/>
              <Setter Property="Foreground" Value="White"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key="Swatch" TargetType="RadioButton">
    <Setter Property="Margin" Value="0,0,8,0"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Grid Width="30" Height="30" Background="Transparent">
            <Ellipse x:Name="ring" Stroke="Transparent" StrokeThickness="2"/>
            <Ellipse Width="20" Height="20" Fill="{TemplateBinding Background}"/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ring" Property="Stroke" Value="{StaticResource Faint}"/></Trigger>
            <Trigger Property="IsChecked" Value="True"><Setter TargetName="ring" Property="Stroke" Value="{StaticResource Text}"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key="Switch" TargetType="CheckBox">
    <Setter Property="Foreground" Value="{StaticResource Text}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="CheckBox">
          <Grid Background="Transparent">
            <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <ContentPresenter VerticalAlignment="Center"/>
            <Border x:Name="track" Grid.Column="1" Width="38" Height="20" CornerRadius="10"
                    Background="{StaticResource Surface2}" BorderBrush="{StaticResource Faint}" BorderThickness="1">
              <Ellipse x:Name="knob" Width="12" Height="12" Fill="{StaticResource Muted}" HorizontalAlignment="Left" Margin="4,0,0,0"/>
            </Border>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="track" Property="Background" Value="{StaticResource Accent}"/>
              <Setter TargetName="track" Property="BorderBrush" Value="{StaticResource Accent}"/>
              <Setter TargetName="knob" Property="Fill" Value="White"/>
              <Setter TargetName="knob" Property="HorizontalAlignment" Value="Right"/>
              <Setter TargetName="knob" Property="Margin" Value="0,0,4,0"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key="DayChip" TargetType="CheckBox">
    <Setter Property="Foreground" Value="{StaticResource Muted}"/>
    <Setter Property="Margin" Value="0,0,6,0"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="CheckBox">
          <Border x:Name="b" Width="34" Height="34" CornerRadius="17" Background="{StaticResource Surface2}"
                  BorderBrush="{StaticResource Line}" BorderThickness="1">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Faint}"/>
              <Setter Property="Foreground" Value="{StaticResource Text}"/>
            </Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="b" Property="Background" Value="{StaticResource Accent}"/>
              <Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/>
              <Setter Property="Foreground" Value="White"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key="DayCell" TargetType="Border">
    <Setter Property="Background" Value="{StaticResource Surface}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{StaticResource Surface2}"/></Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Card" TargetType="Border">
    <Setter Property="Background" Value="{StaticResource Surface}"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{StaticResource Surface2}"/></Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="FieldLabel" TargetType="TextBlock">
    <Setter Property="Foreground" Value="{StaticResource Muted}"/>
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Margin" Value="2,14,0,7"/>
  </Style>

  <Style TargetType="ScrollBar">
    <Setter Property="Width" Value="8"/>
    <Setter Property="MinWidth" Value="8"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ScrollBar">
          <Track x:Name="PART_Track" IsDirectionReversed="True">
            <Track.Thumb>
              <Thumb>
                <Thumb.Template>
                  <ControlTemplate TargetType="Thumb"><Border CornerRadius="4" Background="#353C4B" Margin="1,0"/></ControlTemplate>
                </Thumb.Template>
              </Thumb>
            </Track.Thumb>
          </Track>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType="ToolTip">
    <Setter Property="Background" Value="{StaticResource Surface2}"/>
    <Setter Property="Foreground" Value="{StaticResource Text}"/>
    <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
  </Style>
</ResourceDictionary>
'@

$MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Reminder Calendar" Width="1320" Height="820" MinWidth="1120" MinHeight="680"
        WindowStartupLocation="CenterScreen" Background="{StaticResource Bg}"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13" Foreground="{StaticResource Text}"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Grid Background="{StaticResource Bg}">
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="256"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="320"/>
      </Grid.ColumnDefinitions>

      <!-- sidebar -->
      <Border Background="{StaticResource Side}" BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0">
        <Grid Margin="20,22,20,20">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/><RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <StackPanel Orientation="Horizontal">
            <Border Width="40" Height="40" CornerRadius="11" Background="{StaticResource Accent}">
              <TextBlock Text="&#xE787;" FontFamily="{StaticResource Icons}" FontSize="18" Foreground="White"
                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
              <TextBlock Text="Reminders" FontSize="17" FontWeight="SemiBold"/>
              <TextBlock x:Name="TxtClock" Foreground="{StaticResource Muted}" FontSize="12" Margin="0,1,0,0"/>
            </StackPanel>
          </StackPanel>
          <Button x:Name="BtnNew" Grid.Row="1" Style="{StaticResource AccentBtn}" Margin="0,24,0,0" Padding="14,11">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE710;" FontFamily="{StaticResource Icons}" FontSize="12" VerticalAlignment="Center" Margin="0,1,9,0"/>
              <TextBlock Text="New reminder"/>
            </StackPanel>
          </Button>
          <TextBlock Grid.Row="2" Text="COMING UP" Foreground="{StaticResource Muted}" FontSize="11" FontWeight="SemiBold" Margin="2,28,0,4"/>
          <ScrollViewer Grid.Row="3" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="0,0,-10,0">
            <StackPanel x:Name="UpList" Margin="0,0,10,0"/>
          </ScrollViewer>
          <StackPanel Grid.Row="4" Margin="0,14,0,0">
            <Border Height="1" Background="{StaticResource Line}" Margin="0,0,0,16"/>
            <CheckBox x:Name="ChkStartup" Style="{StaticResource Switch}" Content="Start with Windows" Margin="0,0,0,16"/>
            <Button x:Name="BtnTest" Style="{StaticResource Ghost}" Content="Send test notification"/>
          </StackPanel>
        </Grid>
      </Border>

      <!-- month -->
      <Grid Grid.Column="1" Margin="24,20,18,18">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <Grid>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock x:Name="TxtMonth" FontSize="28" FontWeight="SemiBold"/>
            <TextBlock x:Name="TxtYear" FontSize="28" Foreground="{StaticResource Muted}" Margin="10,0,0,0"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
            <Button x:Name="BtnToday" Style="{StaticResource Ghost}" Content="Today" Margin="0,0,10,0"/>
            <Button x:Name="BtnPrev" Style="{StaticResource Icon}" Content="&#xE76B;" ToolTip="Previous month"/>
            <Button x:Name="BtnNext" Style="{StaticResource Icon}" Content="&#xE76C;" ToolTip="Next month"/>
          </StackPanel>
        </Grid>
        <UniformGrid x:Name="WeekHdr" Grid.Row="1" Columns="7" Margin="0,18,0,4"/>
        <UniformGrid x:Name="MonthGrid" Grid.Row="2" Columns="7" Rows="6"/>
      </Grid>

      <!-- selected day -->
      <Border Grid.Column="2" Background="{StaticResource Side}" BorderBrush="{StaticResource Line}" BorderThickness="1,0,0,0">
        <Grid Margin="22,22,22,20">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <Grid>
            <StackPanel>
              <TextBlock x:Name="TxtDayName" FontSize="24" FontWeight="SemiBold"/>
              <TextBlock x:Name="TxtDayDate" Foreground="{StaticResource Muted}" FontSize="13.5" Margin="0,2,0,0"/>
            </StackPanel>
            <Button x:Name="BtnAddDay" Style="{StaticResource Icon}" Content="&#xE710;" HorizontalAlignment="Right"
                    VerticalAlignment="Top" ToolTip="Add a reminder on this day"/>
          </Grid>
          <ScrollViewer Grid.Row="1" Margin="0,20,-12,0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel x:Name="DayList" Margin="0,0,12,0"/>
          </ScrollViewer>
        </Grid>
      </Border>
    </Grid>

    <!-- add / edit -->
    <Grid x:Name="Overlay" Visibility="Collapsed" Background="#B8080A0E">
      <Border Width="620" Background="{StaticResource Surface}" CornerRadius="16" BorderBrush="{StaticResource Line}"
              BorderThickness="1" Padding="26,22,12,22" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,24">
        <Border.Effect><DropShadowEffect BlurRadius="40" ShadowDepth="8" Opacity="0.5" Color="Black"/></Border.Effect>
        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel Margin="0,0,14,0">
          <Grid>
            <TextBlock x:Name="EdHeading" FontSize="20" FontWeight="SemiBold"/>
            <Button x:Name="EdClose" Style="{StaticResource Icon}" Content="&#xE711;" FontSize="12" HorizontalAlignment="Right" Margin="0,-6,-10,0"/>
          </Grid>
          <TextBlock Style="{StaticResource FieldLabel}" Text="What do you want to remember?"/>
          <TextBox x:Name="EdTitle" Style="{StaticResource Input}" FontSize="15"/>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="150"/></Grid.ColumnDefinitions>
            <StackPanel>
              <TextBlock Style="{StaticResource FieldLabel}" Text="Date"/>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBox x:Name="EdDate" Style="{StaticResource Input}"/>
                <Button x:Name="EdDatePrev" Grid.Column="1" Style="{StaticResource Icon}" Content="&#xE76B;" Margin="4,0,0,0" ToolTip="Day before"/>
                <Button x:Name="EdDateNext" Grid.Column="2" Style="{StaticResource Icon}" Content="&#xE76C;" ToolTip="Day after"/>
              </Grid>
            </StackPanel>
            <StackPanel Grid.Column="2">
              <TextBlock Style="{StaticResource FieldLabel}" Text="Time"/>
              <TextBox x:Name="EdTime" Style="{StaticResource Input}" ToolTip="e.g. 3:30 PM, 3pm, 15:30"/>
            </StackPanel>
          </Grid>
          <TextBlock Style="{StaticResource FieldLabel}" Text="Repeat"/>
          <WrapPanel x:Name="EdRepeat"/>
          <Border x:Name="EdRepeatOpts" Background="{StaticResource Bg}" CornerRadius="10" Padding="14,12" Margin="0,2,0,4">
            <StackPanel>
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="Every" Foreground="{StaticResource Muted}" Width="46" VerticalAlignment="Center"/>
                <Button x:Name="EdIntMinus" Style="{StaticResource Icon}" Content="&#xE738;" Width="30" Height="30" FontSize="11"/>
                <TextBox x:Name="EdInterval" Style="{StaticResource Input}" Width="54" Padding="0,6" TextAlignment="Center" Margin="4,0"/>
                <Button x:Name="EdIntPlus" Style="{StaticResource Icon}" Content="&#xE710;" Width="30" Height="30" FontSize="11"/>
                <TextBlock x:Name="EdUnit" VerticalAlignment="Center" Margin="10,0,0,0" FontSize="14"/>
              </StackPanel>
              <StackPanel x:Name="EdDaysRow" Orientation="Horizontal" Margin="0,12,0,0">
                <TextBlock Text="On" Foreground="{StaticResource Muted}" Width="46" VerticalAlignment="Center"/>
                <StackPanel x:Name="EdDays" Orientation="Horizontal"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                <TextBlock Text="Ends" Foreground="{StaticResource Muted}" Width="46" VerticalAlignment="Center"/>
                <RadioButton x:Name="EdEndNever" Style="{StaticResource Pill}" Content="Never" Margin="0,0,6,0" GroupName="Ends" VerticalAlignment="Center"/>
                <RadioButton x:Name="EdEndOn" Style="{StaticResource Pill}" Content="On date" Margin="0,0,8,0" GroupName="Ends" VerticalAlignment="Center"/>
                <TextBox x:Name="EdUntil" Style="{StaticResource Input}" Width="170" Padding="4,5"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                <TextBlock Text="&#xE8EE;" FontFamily="{StaticResource Icons}" Foreground="{StaticResource AccentHover}" VerticalAlignment="Center" Margin="0,1,8,0"/>
                <TextBlock x:Name="EdRepeatSummary" Foreground="{StaticResource AccentHover}" FontWeight="SemiBold"/>
              </StackPanel>
            </StackPanel>
          </Border>
          <TextBlock Style="{StaticResource FieldLabel}" Text="Notify me" Margin="2,8,0,7"/>
          <WrapPanel x:Name="EdLead"/>
          <TextBlock Style="{StaticResource FieldLabel}" Text="Color" Margin="2,8,0,5"/>
          <StackPanel x:Name="EdColors" Orientation="Horizontal" Margin="-4,0,0,0"/>
          <TextBlock Style="{StaticResource FieldLabel}" Text="Notes"/>
          <TextBox x:Name="EdNotes" Style="{StaticResource Input}" AcceptsReturn="True" TextWrapping="Wrap" Height="64"
                   VerticalContentAlignment="Top" VerticalScrollBarVisibility="Auto"/>
          <TextBlock x:Name="EdError" Foreground="{StaticResource Danger}" Margin="2,10,0,0" Visibility="Collapsed"/>
          <Grid Margin="0,20,0,0">
            <Button x:Name="EdDelete" Style="{StaticResource DangerGhost}" Content="Delete" HorizontalAlignment="Left"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
              <Button x:Name="EdCancel" Style="{StaticResource Ghost}" Content="Cancel" Margin="0,0,8,0"/>
              <Button x:Name="EdSave" Style="{StaticResource AccentBtn}" Content="Save reminder" Padding="18,9"/>
            </StackPanel>
          </Grid>
        </StackPanel>
        </ScrollViewer>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

$PopupXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" Topmost="True"
        ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize" SizeToContent="Height" Width="400"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13" Foreground="{StaticResource Text}"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Border x:Name="Root" Margin="16" Background="{StaticResource Surface}" CornerRadius="14"
          BorderBrush="{StaticResource Line}" BorderThickness="1">
    <Border.Effect><DropShadowEffect BlurRadius="24" ShadowDepth="4" Opacity="0.6" Color="Black"/></Border.Effect>
    <Border.RenderTransform><TranslateTransform x:Name="Slide" X="40"/></Border.RenderTransform>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Border x:Name="Stripe" CornerRadius="13,0,0,13"/>
      <StackPanel Grid.Column="1" Margin="16,14,14,16">
        <Grid>
          <StackPanel Orientation="Horizontal">
            <TextBlock x:Name="Bell" Text="&#xEA8F;" FontFamily="{StaticResource Icons}" FontSize="13" VerticalAlignment="Center"/>
            <TextBlock Text="REMINDER" Foreground="{StaticResource Muted}" FontSize="11" FontWeight="SemiBold" Margin="8,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <Button x:Name="BtnX" Style="{StaticResource Icon}" Width="26" Height="26" FontSize="10" Content="&#xE8BB;"
                  HorizontalAlignment="Right" Margin="0,-4,-4,0"/>
        </Grid>
        <TextBlock x:Name="PTitle" FontSize="18" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,8,0,0"/>
        <TextBlock x:Name="PWhen" Foreground="{StaticResource Muted}" Margin="0,4,0,0"/>
        <TextBlock x:Name="PNotes" TextWrapping="Wrap" Margin="0,10,0,0" FontSize="12.5" MaxHeight="80" TextTrimming="CharacterEllipsis"/>
        <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
          <Button x:Name="BtnS5" Style="{StaticResource Ghost}" Content="Snooze 5 min" Padding="12,7" Margin="0,0,8,0"/>
          <Button x:Name="BtnS15" Style="{StaticResource Ghost}" Content="15 min" Padding="12,7" Margin="0,0,8,0"/>
          <Button x:Name="BtnDismiss" Style="{StaticResource AccentBtn}" Content="Got it" Padding="18,7"/>
        </StackPanel>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@

$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'
$app.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Parse($ThemeXaml))
$Res = $app.Resources

# An error inside any click/key handler would otherwise end the message loop and close the app.
# Log it and keep running instead.
function Write-ErrorLog($ex) {
    try { Add-Content -Path $LogFile -Value ("[{0}] {1}" -f (Get-Date -Format s), ($ex | Out-String)) } catch {}
}
$app.add_DispatcherUnhandledException({ Write-ErrorLog $_.Exception; $_.Handled = $true })
[System.Windows.Forms.Application]::add_ThreadException({ Write-ErrorLog $_.Exception })

$win = [Windows.Markup.XamlReader]::Parse($MainXaml)
foreach ($n in 'TxtClock', 'BtnNew', 'UpList', 'ChkStartup', 'BtnTest', 'TxtMonth', 'TxtYear', 'BtnToday',
               'BtnPrev', 'BtnNext', 'WeekHdr', 'MonthGrid', 'TxtDayName', 'TxtDayDate', 'BtnAddDay', 'DayList', 'Overlay',
               'EdHeading', 'EdClose', 'EdTitle', 'EdDate', 'EdDatePrev', 'EdDateNext', 'EdTime', 'EdRepeat', 'EdLead',
               'EdColors', 'EdNotes', 'EdError', 'EdDelete', 'EdCancel', 'EdSave', 'EdRepeatOpts', 'EdIntMinus',
               'EdInterval', 'EdIntPlus', 'EdUnit', 'EdDaysRow', 'EdDays', 'EdEndNever', 'EdEndOn', 'EdUntil', 'EdRepeatSummary') {
    Set-Variable -Name $n -Value $win.FindName($n)
}

$iconBmp = New-IconBitmap 64
$trayIcon = [System.Drawing.Icon]::FromHandle($iconBmp.GetHicon())
$win.Icon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($trayIcon.Handle, [System.Windows.Int32Rect]::Empty,
    [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
$win.add_SourceInitialized({ Set-DarkTitleBar $win })

# ---- small element builders
function Th([double]$l, [double]$t, [double]$r, [double]$b) { New-Object System.Windows.Thickness($l, $t, $r, $b) }
function Get-Brush([string]$hex, [int]$alpha = 255) {
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
    $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb($alpha, $c.R, $c.G, $c.B))
    $b.Freeze()
    $b
}
function New-Text([string]$text, [double]$size = 13, $brush = $null, [string]$weight = 'Normal') {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $text
    $t.FontSize = $size
    $t.FontWeight = [System.Windows.FontWeights]::$weight
    $t.TextTrimming = 'CharacterEllipsis'
    if ($brush) { $t.Foreground = $brush }
    $t
}
function New-Glyph([int]$code, [double]$size = 12, $brush = $null) {
    $t = New-Text ([string][char]$code) $size $brush
    $t.FontFamily = $Res['Icons']
    $t.VerticalAlignment = 'Center'
    $t
}
function New-Badge([int]$glyph, [string]$text) {
    $b = New-Object System.Windows.Controls.Border
    $b.Background = $Res['Bg']
    $b.CornerRadius = New-Object System.Windows.CornerRadius(6)
    $b.Padding = Th 7 3 8 3
    $b.Margin = Th 0 0 6 6
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'
    $g = New-Glyph $glyph 10.5 $Res['Muted']
    $g.Margin = Th 0 1 6 0
    [void]$sp.Children.Add($g)
    $tb = New-Text $text 11.5 $Res['Muted']
    $tb.TextWrapping = 'Wrap'
    $tb.TextTrimming = 'None'
    $tb.MaxWidth = 165
    [void]$sp.Children.Add($tb)
    $b.Child = $sp
    $b
}
function Get-ReminderColor($r) { if ($r.Color) { $r.Color } else { $Colors.Violet } }

# ---- state
$script:SelDate   = (Get-Date).Date
$script:ViewMonth = New-Object DateTime($SelDate.Year, $SelDate.Month, 1)
$script:Editing   = $null
$script:DeleteArmed = $false

# ---- month grid
foreach ($i in 0..6) {
    $t = New-Text ([Globalization.CultureInfo]::CurrentCulture.DateTimeFormat.AbbreviatedDayNames[$i].ToUpper()) 11 $Res['Muted'] 'SemiBold'
    $t.Margin = Th 12 0 0 0
    [void]$WeekHdr.Children.Add($t)
}

function Select-Date([datetime]$d) {
    $script:SelDate = $d.Date
    $m = New-Object DateTime($d.Year, $d.Month, 1)
    $script:ViewMonth = $m
    Update-Views
}

function Update-Month {
    $vm = $script:ViewMonth
    $TxtMonth.Text = $vm.ToString('MMMM')
    $TxtYear.Text = $vm.ToString('yyyy')
    $first = $vm.AddDays(-[int]$vm.DayOfWeek)
    $byDay = @{}
    foreach ($row in (Get-Agenda $first $first.AddDays(42) -PerDay)) {
        $k = $row.O.Date
        if (-not $byDay.ContainsKey($k)) { $byDay[$k] = New-Object System.Collections.ArrayList }
        [void]$byDay[$k].Add($row)
    }
    $cellH = if ($MonthGrid.ActualHeight -gt 0) { $MonthGrid.ActualHeight / 6 } else { 90 }
    $maxChips = [math]::Max(1, [math]::Floor(($cellH - 6 - 12 - 30) / 21))
    $today = (Get-Date).Date

    $MonthGrid.Children.Clear()
    for ($i = 0; $i -lt 42; $i++) {
        $d = $first.AddDays($i)
        $cell = New-Object System.Windows.Controls.Border
        $cell.Style = $Res['DayCell']
        $cell.Margin = Th 3 3 3 3
        $cell.CornerRadius = New-Object System.Windows.CornerRadius(10)
        $cell.Padding = Th 8 6 8 6
        $cell.BorderThickness = Th 1.5 1.5 1.5 1.5
        $cell.BorderBrush = if ($d -eq $script:SelDate) { $Res['Accent'] } else { [System.Windows.Media.Brushes]::Transparent }
        if ($d.Month -ne $vm.Month) { $cell.Opacity = 0.4 }
        $cell.Tag = $d

        $sp = New-Object System.Windows.Controls.StackPanel
        if ($d -eq $today) {
            $dot = New-Object System.Windows.Controls.Border
            $dot.Width = 26; $dot.Height = 26
            $dot.CornerRadius = New-Object System.Windows.CornerRadius(13)
            $dot.Background = $Res['Accent']
            $dot.HorizontalAlignment = 'Left'
            $n = New-Text $d.Day.ToString() 12.5 ([System.Windows.Media.Brushes]::White) 'Bold'
            $n.HorizontalAlignment = 'Center'; $n.VerticalAlignment = 'Center'
            $dot.Child = $n
            [void]$sp.Children.Add($dot)
        } else {
            $n = New-Text $d.Day.ToString() 13 $null 'SemiBold'
            $n.Margin = Th 4 4 0 4
            [void]$sp.Children.Add($n)
        }

        $rows = $byDay[$d]
        if ($rows) {
            $show = if ($rows.Count -le $maxChips) { $rows.Count } else { $maxChips - 1 }
            for ($j = 0; $j -lt [math]::Max(0, $show); $j++) {
                $row = $rows[$j]
                $hex = Get-ReminderColor $row.R
                $chip = New-Object System.Windows.Controls.Border
                $chip.Background = Get-Brush $hex 46
                $chip.CornerRadius = New-Object System.Windows.CornerRadius(5)
                $chip.Padding = Th 6 2 6 3
                $chip.Margin = Th 0 3 0 0
                $g = New-Object System.Windows.Controls.DockPanel
                $e = New-Object System.Windows.Shapes.Ellipse
                $e.Width = 6; $e.Height = 6; $e.Fill = Get-Brush $hex
                $e.Margin = Th 0 1 6 0
                [System.Windows.Controls.DockPanel]::SetDock($e, 'Left')
                [void]$g.Children.Add($e)
                $txt = New-Text $row.R.Title 11.5
                $chip.ToolTip = "{0}  {1}" -f $row.O.ToString('h:mm tt'), $row.R.Title
                [void]$g.Children.Add($txt)
                $chip.Child = $g
                [void]$sp.Children.Add($chip)
            }
            if ($rows.Count -gt $show) {
                $more = New-Text "+$($rows.Count - $show) more" 11 $Res['Muted'] 'SemiBold'
                $more.Margin = Th 4 4 0 0
                [void]$sp.Children.Add($more)
            }
        }
        $cell.Child = $sp
        $cell.add_MouseLeftButtonDown({
            $d = [datetime]$this.Tag
            if ($_.ClickCount -ge 2) { Select-Date $d; Open-Editor $null $d }
            else { Select-Date $d }
        })
        [void]$MonthGrid.Children.Add($cell)
    }
}

# ---- selected-day panel
function New-ReminderCard($row) {
    $r = $row.R
    $hex = Get-ReminderColor $r
    $card = New-Object System.Windows.Controls.Border
    $card.Style = $Res['Card']
    $card.CornerRadius = New-Object System.Windows.CornerRadius(12)
    $card.Padding = Th 14 12 8 12
    $card.Margin = Th 0 0 0 10
    $card.Cursor = 'Hand'
    $card.Tag = $r
    $frequent = $r.Repeat -in 'Minutely', 'Hourly'
    if ($row.O -lt (Get-Date) -and -not ($frequent -and $row.O.Date -eq (Get-Date).Date)) { $card.Opacity = 0.5 }

    $grid = New-Object System.Windows.Controls.Grid
    foreach ($w in 'Auto', '*', 'Auto') {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = [System.Windows.GridLength]$(if ($w -eq '*') { New-Object System.Windows.GridLength(1, 'Star') } else { [System.Windows.GridLength]::Auto })
        $grid.ColumnDefinitions.Add($cd)
    }
    $bar = New-Object System.Windows.Controls.Border
    $bar.Width = 4
    $bar.CornerRadius = New-Object System.Windows.CornerRadius(2)
    $bar.Background = Get-Brush $hex
    $bar.Margin = Th 0 2 12 2
    [void]$grid.Children.Add($bar)

    $sp = New-Object System.Windows.Controls.StackPanel
    [System.Windows.Controls.Grid]::SetColumn($sp, 1)
    $timeText = $(if ($frequent) { 'From ' }) + $row.O.ToString('h:mm tt')
    [void]$sp.Children.Add((New-Text $timeText 12 (Get-Brush $hex) 'SemiBold'))
    $title = New-Text $r.Title 15 $null 'SemiBold'
    $title.TextWrapping = 'Wrap'
    $title.Margin = Th 0 2 0 0
    [void]$sp.Children.Add($title)
    $badges = New-Object System.Windows.Controls.WrapPanel
    $badges.Margin = Th 0 8 0 0
    [void]$badges.Children.Add((New-Badge 0xEA8F (Get-LeadText ([int]$r.Lead))))
    if ($r.Repeat -ne 'None') { [void]$badges.Children.Add((New-Badge 0xE8EE (Get-RepeatText $r))) }
    [void]$sp.Children.Add($badges)
    if ($r.Notes) {
        $notes = New-Text $r.Notes 12.5 $Res['Muted']
        $notes.TextWrapping = 'Wrap'
        $notes.Margin = Th 0 2 0 0
        [void]$sp.Children.Add($notes)
    }
    [void]$grid.Children.Add($sp)

    $acts = New-Object System.Windows.Controls.StackPanel
    [System.Windows.Controls.Grid]::SetColumn($acts, 2)
    foreach ($a in @(@(0xE70F, 'Edit'), @(0xE74D, 'Delete'))) {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Style = $Res['Icon']
        $btn.Width = 30; $btn.Height = 30; $btn.FontSize = 12.5
        $btn.Content = [string][char]$a[0]
        $btn.ToolTip = $a[1]
        $btn.Tag = @{ R = $r; Action = $a[1] }
        $btn.add_Click({
            $t = $this.Tag
            if ($t.Action -eq 'Edit') { Open-Editor $t.R } else { Open-Editor $t.R; Invoke-EditorDelete }
        })
        [void]$acts.Children.Add($btn)
    }
    [void]$grid.Children.Add($acts)

    $card.Child = $grid
    $card.add_MouseLeftButtonDown({ if ($_.ClickCount -ge 2) { Open-Editor $this.Tag } })
    $card
}

function Update-Day {
    $d = $script:SelDate
    $TxtDayName.Text = Format-DayLabel $d
    if ($TxtDayName.Text -like '*,*') { $TxtDayName.Text = $d.ToString('dddd') }
    $TxtDayDate.Text = $d.ToString('MMMM d, yyyy')
    $DayList.Children.Clear()
    $rows = Get-Agenda $d $d.AddDays(1) -PerDay
    foreach ($row in $rows) { [void]$DayList.Children.Add((New-ReminderCard $row)) }
    if ($rows.Count -eq 0) {
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Margin = Th 0 70 0 0
        $sp.HorizontalAlignment = 'Center'
        $ic = New-Glyph 0xE787 40 $Res['Faint']
        $ic.HorizontalAlignment = 'Center'
        [void]$sp.Children.Add($ic)
        $h = New-Text 'Nothing planned' 16 $null 'SemiBold'
        $h.HorizontalAlignment = 'Center'; $h.Margin = Th 0 16 0 0
        [void]$sp.Children.Add($h)
        $p = New-Text 'Double-click any day on the calendar, or add one here.' 12.5 $Res['Muted']
        $p.TextWrapping = 'Wrap'; $p.TextAlignment = 'Center'; $p.MaxWidth = 220; $p.Margin = Th 0 6 0 0
        [void]$sp.Children.Add($p)
        $btn = New-Object System.Windows.Controls.Button
        $btn.Style = $Res['AccentBtn']
        $btn.Content = 'Add reminder'
        $btn.HorizontalAlignment = 'Center'
        $btn.Margin = Th 0 18 0 0
        $btn.add_Click({ Open-Editor $null $script:SelDate })
        [void]$sp.Children.Add($btn)
        [void]$DayList.Children.Add($sp)
    }
}

# ---- coming up (sidebar)
function Update-Upcoming {
    $now = Get-Date
    $UpList.Children.Clear()
    $rows = @(Get-Agenda $now $now.Date.AddDays(15) -FirstOnly | Select-Object -First 30)
    $lastDay = $null
    foreach ($row in $rows) {
        if ($row.O.Date -ne $lastDay) {
            $lastDay = $row.O.Date
            $h = New-Text (Format-DayLabel $lastDay) 12 $Res['Muted'] 'SemiBold'
            $h.Margin = Th 2 12 0 6
            [void]$UpList.Children.Add($h)
        }
        $hex = Get-ReminderColor $row.R
        $card = New-Object System.Windows.Controls.Border
        $card.Style = $Res['Card']
        $card.CornerRadius = New-Object System.Windows.CornerRadius(10)
        $card.Padding = Th 10 8 10 9
        $card.Margin = Th 0 0 0 6
        $card.Cursor = 'Hand'
        $card.Tag = $row.O
        $dp = New-Object System.Windows.Controls.DockPanel
        $bar = New-Object System.Windows.Controls.Border
        $bar.Width = 3
        $bar.CornerRadius = New-Object System.Windows.CornerRadius(1.5)
        $bar.Background = Get-Brush $hex
        $bar.Margin = Th 0 1 10 1
        [System.Windows.Controls.DockPanel]::SetDock($bar, 'Left')
        [void]$dp.Children.Add($bar)
        $sp = New-Object System.Windows.Controls.StackPanel
        [void]$sp.Children.Add((New-Text $row.R.Title 13 $null 'SemiBold'))
        $sub = $row.O.ToString('h:mm tt') + $(if ($row.R.Repeat -ne 'None') { "  $Dot  $(Get-RepeatText $row.R)" })
        $st = New-Text $sub 11.5 $Res['Muted']
        $st.Margin = Th 0 2 0 0
        [void]$sp.Children.Add($st)
        [void]$dp.Children.Add($sp)
        $card.Child = $dp
        $card.add_MouseLeftButtonDown({ Select-Date ([datetime]$this.Tag) })
        [void]$UpList.Children.Add($card)
    }
    if ($rows.Count -eq 0) {
        $t = New-Text 'Nothing in the next two weeks.' 12.5 $Res['Muted']
        $t.Margin = Th 2 10 0 0
        [void]$UpList.Children.Add($t)
    }
}

function Update-Clock { $TxtClock.Text = (Get-Date).ToString('dddd, h:mm tt') }

function Update-Views {
    Update-Clock
    Update-Month
    Update-Day
    Update-Upcoming
}

# ---- editor
$RepeatPills = @{}
foreach ($k in $RepeatOptions.Keys) {
    $rb = New-Object System.Windows.Controls.RadioButton
    $rb.Style = $Res['Pill']; $rb.Content = $k; $rb.Tag = $RepeatOptions[$k]
    $rb.add_Checked({ Update-RepeatEditor })
    [void]$EdRepeat.Children.Add($rb)
    $RepeatPills[$RepeatOptions[$k]] = $rb
}
$LeadPills = @{}
foreach ($k in $LeadOptions.Keys) {
    $rb = New-Object System.Windows.Controls.RadioButton
    $rb.Style = $Res['Pill']; $rb.Content = $k; $rb.Tag = $LeadOptions[$k]
    [void]$EdLead.Children.Add($rb)
    $LeadPills[$LeadOptions[$k]] = $rb
}
$ColorPills = @{}
foreach ($k in $Colors.Keys) {
    $rb = New-Object System.Windows.Controls.RadioButton
    $rb.Style = $Res['Swatch']; $rb.Background = Get-Brush $Colors[$k]; $rb.Tag = $Colors[$k]; $rb.ToolTip = $k
    [void]$EdColors.Children.Add($rb)
    $ColorPills[$Colors[$k]] = $rb
}
$DayChips = @()
$dayNames = [Globalization.CultureInfo]::CurrentCulture.DateTimeFormat
foreach ($i in 0..6) {
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Style = $Res['DayChip']
    $cb.Content = $dayNames.ShortestDayNames[$i].Substring(0, 1)
    $cb.ToolTip = $dayNames.DayNames[$i]
    $cb.Tag = $i
    $cb.add_Click({ Update-RepeatEditor })
    [void]$EdDays.Children.Add($cb)
    $DayChips += $cb
}

function Get-Checked($panel) {
    foreach ($c in $panel.Children) { if ($c.IsChecked) { return $c.Tag } }
    $null
}

function Show-EditorError([string]$msg) {
    $EdError.Text = $msg
    $EdError.Visibility = 'Visible'
}

# Read the repeat fields into a reminder-shaped object (used for the live summary and for saving).
function Get-EditorRepeat {
    $repeat = [string](Get-Checked $EdRepeat)
    if (-not $repeat) { $repeat = 'None' }
    $k = 0
    if (-not [int]::TryParse($EdInterval.Text.Trim(), [ref]$k) -or $k -lt 1) { $k = 0 }
    $date = ConvertFrom-DateText $EdDate.Text
    if (-not $date) { $date = $script:SelDate }
    $until = ''
    if ($EdEndOn.IsChecked) { $u = ConvertFrom-DateText $EdUntil.Text; $until = if ($u) { $u.ToString($Fmt) } else { $null } }
    [pscustomobject]@{
        Repeat   = $repeat
        Interval = $k
        Days     = @($DayChips | Where-Object { $_.IsChecked } | ForEach-Object { [int]$_.Tag })
        Until    = $until
        Start    = $date.ToString($Fmt)
    }
}

function Update-RepeatEditor {
    $repeat = [string](Get-Checked $EdRepeat)
    if (-not $repeat -or $repeat -eq 'None') { $EdRepeatOpts.Visibility = 'Collapsed'; return }
    $EdRepeatOpts.Visibility = 'Visible'
    $EdDaysRow.Visibility = if ($repeat -eq 'Weekly') { 'Visible' } else { 'Collapsed' }
    $EdUntil.Visibility = if ($EdEndOn.IsChecked) { 'Visible' } else { 'Hidden' }
    $x = Get-EditorRepeat
    $unit = $RepeatUnits[$repeat]
    $EdUnit.Text = if ($x.Interval -eq 1) { $unit } else { "${unit}s" }
    if ($x.Interval -lt 1) { $EdRepeatSummary.Text = 'Enter how often (1 or more)'; return }
    if ($null -eq $x.Until) { $EdRepeatSummary.Text = 'Enter an end date'; return }
    $EdRepeatSummary.Text = Get-RepeatText $x
}

function Step-Interval([int]$delta) {
    $k = 1
    [void][int]::TryParse($EdInterval.Text.Trim(), [ref]$k)
    $EdInterval.Text = [string][math]::Min(999, [math]::Max(1, $k + $delta))
}

function Open-Editor($r, $date = $null) {
    Show-Main
    $script:Editing = $r
    $script:DeleteArmed = $false
    $EdDelete.Content = 'Delete'
    $EdError.Visibility = 'Collapsed'
    if ($r) {
        $start = Get-Start $r
        $EdHeading.Text = 'Edit reminder'
        $EdTitle.Text = $r.Title
        $EdNotes.Text = $r.Notes
        $EdDelete.Visibility = 'Visible'
        $repeat = $r.Repeat
        $lead = [int]$r.Lead
        $color = Get-ReminderColor $r
        $interval = Get-Interval $r
        $days = if ($r.Repeat -eq 'Weekly') { @(Get-WeekDays $r) } else { @([int]$start.DayOfWeek) }
        $until = $r.Until
    } else {
        $base = if ($date) { ([datetime]$date).Date } else { $script:SelDate }
        $start = $base.AddHours((Get-Date).Hour + 1)   # next whole hour on that day
        if ($start.Date -ne $base) { $start = $base.AddHours(9) }
        $EdHeading.Text = 'New reminder'
        $EdTitle.Text = ''
        $EdNotes.Text = ''
        $EdDelete.Visibility = 'Collapsed'
        $repeat = 'None'; $lead = 10; $color = $Colors.Violet
        $interval = 1; $days = @([int]$start.DayOfWeek); $until = ''
    }
    $EdDate.Text = $start.ToString('ddd, MMM d, yyyy')
    $EdTime.Text = $start.ToString('h:mm tt')
    $EdInterval.Text = [string]$interval
    foreach ($c in $DayChips) { $c.IsChecked = $days -contains [int]$c.Tag }
    if ($until) {
        $EdEndOn.IsChecked = $true
        $EdUntil.Text = (ConvertTo-Date $until).ToString('ddd, MMM d, yyyy')
    } else {
        $EdEndNever.IsChecked = $true
        $EdUntil.Text = $start.AddMonths(1).ToString('ddd, MMM d, yyyy')
    }
    if ($RepeatPills[$repeat]) { $RepeatPills[$repeat].IsChecked = $true } else { $RepeatPills['None'].IsChecked = $true }
    if ($LeadPills[$lead]) { $LeadPills[$lead].IsChecked = $true } else { foreach ($p in $LeadPills.Values) { $p.IsChecked = $false } }
    if ($ColorPills[$color]) { $ColorPills[$color].IsChecked = $true } else { $ColorPills[$Colors.Violet].IsChecked = $true }
    Update-RepeatEditor
    $Overlay.Visibility = 'Visible'
    [void]$win.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Input, [action]{ [void]$EdTitle.Focus(); $EdTitle.SelectAll() })
}

function Close-Editor {
    $Overlay.Visibility = 'Collapsed'
    $script:Editing = $null
}

function Save-Editor {
    $title = $EdTitle.Text.Trim()
    if (-not $title) { Show-EditorError 'Give your reminder a name.'; [void]$EdTitle.Focus(); return }
    $date = ConvertFrom-DateText $EdDate.Text
    if (-not $date) { Show-EditorError "Couldn't read that date. Try something like Nov 3, 2026."; [void]$EdDate.Focus(); return }
    $time = ConvertFrom-TimeText $EdTime.Text
    if ($null -eq $time) { Show-EditorError "Couldn't read that time. Try 3:30 PM, 3pm or 15:30."; [void]$EdTime.Focus(); return }
    $lead = Get-Checked $EdLead
    if ($null -eq $lead) { $lead = if ($script:Editing) { [int]$script:Editing.Lead } else { 0 } }
    $rep = Get-EditorRepeat
    if ($rep.Repeat -ne 'None') {
        if ($rep.Interval -lt 1) { Show-EditorError 'Repeat every... needs to be a number, 1 or more.'; [void]$EdInterval.Focus(); return }
        if ($rep.Repeat -eq 'Weekly' -and $rep.Days.Count -eq 0) { Show-EditorError 'Pick at least one day of the week.'; return }
        if ($null -eq $rep.Until) { Show-EditorError "Couldn't read the end date."; [void]$EdUntil.Focus(); return }
        if ($rep.Until -and (ConvertTo-Date $rep.Until) -lt $date) { Show-EditorError 'The end date is before the start date.'; return }
    }

    $r = $script:Editing
    if (-not $r) {
        $r = [pscustomobject]@{ Id = [guid]::NewGuid().ToString(); Title = ''; Notes = ''; Start = ''; Repeat = 'None'; Lead = 0
                                LastFired = ''; SnoozeUntil = ''; Color = ''; Interval = 1; Days = @(); Until = '' }
        [void]$script:Reminders.Add($r)
    }
    $when = $date + $time
    $r.Title = $title
    $r.Notes = $EdNotes.Text.Trim()
    $r.Start = $when.ToString($Fmt)
    $r.Repeat = $rep.Repeat
    $r.Interval = if ($rep.Repeat -eq 'None') { 1 } else { $rep.Interval }
    $r.Days = if ($rep.Repeat -eq 'Weekly') { $rep.Days } else { @() }
    $r.Until = if ($rep.Repeat -eq 'None') { '' } else { [string]$rep.Until }
    $r.Lead = [int]$lead
    $r.Color = [string](Get-Checked $EdColors)
    $r.SnoozeUntil = ''
    # Don't fire for occurrences that are already over; do fire if we're inside the alert window.
    $due = Get-DueOccurrence $r (Get-Date)
    $r.LastFired = if ($due -and $due -lt (Get-Date)) { $due.ToString($Fmt) } else { '' }

    Save-Data
    Close-Editor
    Select-Date $when
}

function Invoke-EditorDelete {
    if (-not $script:Editing) { return }
    if (-not $script:DeleteArmed) {
        $script:DeleteArmed = $true
        $EdDelete.Content = $(if ($script:Editing.Repeat -ne 'None') { 'Delete all repeats?' } else { 'Click again to delete' })
        return
    }
    $script:Reminders.Remove($script:Editing)
    Save-Data
    Close-Editor
    Update-Views
}

function Move-EditorDate([int]$days) {
    $d = ConvertFrom-DateText $EdDate.Text
    if (-not $d) { $d = $script:SelDate }
    $EdDate.Text = $d.AddDays($days).ToString('ddd, MMM d, yyyy')
}

$EdSave.add_Click({ Save-Editor })
$EdCancel.add_Click({ Close-Editor })
$EdClose.add_Click({ Close-Editor })
$EdDelete.add_Click({ Invoke-EditorDelete })
$EdDatePrev.add_Click({ Move-EditorDate -1 })
$EdDateNext.add_Click({ Move-EditorDate 1 })
$EdIntMinus.add_Click({ Step-Interval -1 })
$EdIntPlus.add_Click({ Step-Interval 1 })
$EdInterval.add_TextChanged({ Update-RepeatEditor })
$EdUntil.add_TextChanged({ Update-RepeatEditor })
$EdDate.add_TextChanged({ Update-RepeatEditor })
$EdEndNever.add_Checked({ Update-RepeatEditor })
$EdEndOn.add_Checked({ Update-RepeatEditor })
$EdTime.add_LostFocus({ $t = ConvertFrom-TimeText $EdTime.Text; if ($null -ne $t) { $EdTime.Text = ([datetime]::Today + $t).ToString('h:mm tt') } })
$EdDate.add_LostFocus({ $d = ConvertFrom-DateText $EdDate.Text; if ($d) { $EdDate.Text = $d.ToString('ddd, MMM d, yyyy') } })
$EdUntil.add_LostFocus({ $d = ConvertFrom-DateText $EdUntil.Text; if ($d) { $EdUntil.Text = $d.ToString('ddd, MMM d, yyyy') } })
$Overlay.add_MouseLeftButtonDown({ if ($_.OriginalSource -eq $Overlay) { Close-Editor } })

# ---- notifications
$script:Popups = New-Object System.Collections.ArrayList

function Update-PopupPositions {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $y = $wa.Bottom
    foreach ($p in $script:Popups) {
        $y -= $p.ActualHeight
        $p.Left = $wa.Right - $p.Width
        $p.Top = $y
    }
}

$AlertSound = @("$env:SystemRoot\Media\Windows Notify Calendar.wav", "$env:SystemRoot\Media\Windows Notify.wav") | Where-Object { Test-Path $_ } | Select-Object -First 1
function Invoke-AlertSound {
    try {
        if ($AlertSound) { (New-Object System.Media.SoundPlayer $AlertSound).Play() }
        else { [System.Media.SystemSounds]::Asterisk.Play() }
    } catch {}
}

function Show-Popup($r, [string]$when) {
    $p = [Windows.Markup.XamlReader]::Parse($PopupXaml)
    $hex = Get-ReminderColor $r
    $p.FindName('Stripe').Background = Get-Brush $hex
    $p.FindName('Bell').Foreground = Get-Brush $hex
    $p.FindName('PTitle').Text = $r.Title
    $p.FindName('PWhen').Text = $when
    $notes = $p.FindName('PNotes')
    if ($r.Notes) { $notes.Text = $r.Notes } else { $notes.Visibility = 'Collapsed' }
    foreach ($b in @(@('BtnS5', 5), @('BtnS15', 15), @('BtnDismiss', 0), @('BtnX', 0))) {
        $btn = $p.FindName($b[0])
        $btn.Tag = @{ R = $r; W = $p; M = $b[1] }
        $btn.add_Click({
            $t = $this.Tag
            if ($t.M) {
                $t.R.SnoozeUntil = (Get-Date).AddMinutes($t.M).ToString($Fmt)
                Save-Data
            }
            $t.W.Close()
        })
    }
    $p.add_Closed({ $script:Popups.Remove($this); Update-PopupPositions })
    $p.add_ContentRendered({
        Update-PopupPositions
        $ease = New-Object System.Windows.Media.Animation.CubicEase
        $ease.EasingMode = 'EaseOut'
        $dur = [System.Windows.Duration][TimeSpan]::FromMilliseconds(260)
        $fade = New-Object System.Windows.Media.Animation.DoubleAnimation(0, 1, $dur)
        $slide = New-Object System.Windows.Media.Animation.DoubleAnimation(40, 0, $dur)
        $slide.EasingFunction = $ease
        $root = $this.FindName('Root')
        $root.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
        $this.FindName('Slide').BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $slide)
    })
    $p.FindName('Root').Opacity = 0
    [void]$script:Popups.Insert(0, $p)
    $wa = [System.Windows.SystemParameters]::WorkArea
    $p.Left = $wa.Right - $p.Width
    $p.Top = $wa.Bottom - 200
    $p.Show()
    Invoke-AlertSound
    $p
}

function Show-Reminder($r, [datetime]$occ) {
    $now = Get-Date
    $when = if ($occ.Date -eq $now.Date) { 'Today at ' + $occ.ToString('h:mm tt') } else { $occ.ToString('ddd, MMM d \a\t h:mm tt') }
    $mins = [int][math]::Round(($occ - $now).TotalMinutes)
    $headline = if ($mins -gt 1) { "In $(Format-Minutes $mins)  $Dot  $when" }
                elseif ($mins -lt -2) { "Missed  $Dot  was $when" }
                else { "Now  $Dot  $when" }
    [void](Show-Popup $r $headline)
}

function Invoke-ReminderCheck {
    $now = Get-Date
    $changed = $false
    foreach ($r in @($script:Reminders)) {
        if ($r.SnoozeUntil) {
            if ($now -ge (ConvertTo-Date $r.SnoozeUntil)) {
                $r.SnoozeUntil = ''
                $changed = $true
                $occ = if ($r.LastFired) { ConvertTo-Date $r.LastFired } else { Get-Start $r }
                Show-Reminder $r $occ
            }
            continue
        }
        $occ = Get-DueOccurrence $r $now
        if ($occ -and (-not $r.LastFired -or $occ -gt (ConvertTo-Date $r.LastFired))) {
            $r.LastFired = $occ.ToString($Fmt)
            $changed = $true
            Show-Reminder $r $occ
        }
    }
    if ($changed) { Save-Data; if ($win.IsVisible) { Update-Views } }
}

# ---- main window wiring
function Show-Main {
    if (-not $win.IsVisible) { $win.Show(); Update-Views }
    if ($win.WindowState -eq 'Minimized') { $win.WindowState = 'Normal' }
    [void]$win.Activate()
}

$BtnNew.add_Click({ Open-Editor $null $script:SelDate })
$BtnAddDay.add_Click({ Open-Editor $null $script:SelDate })
$BtnToday.add_Click({ Select-Date (Get-Date) })
$BtnPrev.add_Click({ $script:ViewMonth = $script:ViewMonth.AddMonths(-1); Update-Month })
$BtnNext.add_Click({ $script:ViewMonth = $script:ViewMonth.AddMonths(1); Update-Month })
$BtnTest.add_Click({
    [void](Show-Popup ([pscustomobject]@{ Title = 'Test reminder'; Notes = 'This is what your reminders will look like.'; Color = $Colors.Violet; SnoozeUntil = '' }) "Now  $Dot  Today at $((Get-Date).ToString('h:mm tt'))")
})
$ChkStartup.add_Click({ Set-Startup ([bool]$ChkStartup.IsChecked) })
$MonthGrid.add_SizeChanged({ if ($_.HeightChanged) { Update-Month } })

$win.add_PreviewKeyDown({
    $e = $_   # inside switch, $_ becomes the switch value
    $ctrl = [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control
    if ($Overlay.Visibility -eq 'Visible') {
        if ($e.Key -eq 'Escape') { Close-Editor; $e.Handled = $true }
        elseif ($e.Key -eq 'Return' -and (-not $EdNotes.IsKeyboardFocused -or $ctrl)) { Save-Editor; $e.Handled = $true }
        return
    }
    $handled = $true
    switch ($e.Key) {
        'N'        { if ($ctrl) { Open-Editor $null $script:SelDate } else { $handled = $false } }
        'Left'     { Select-Date $script:SelDate.AddDays(-1) }
        'Right'    { Select-Date $script:SelDate.AddDays(1) }
        'Up'       { Select-Date $script:SelDate.AddDays(-7) }
        'Down'     { Select-Date $script:SelDate.AddDays(7) }
        'Return'   { Open-Editor $null $script:SelDate }
        'PageUp'   { $script:ViewMonth = $script:ViewMonth.AddMonths(-1); Update-Month }
        'PageDown' { $script:ViewMonth = $script:ViewMonth.AddMonths(1); Update-Month }
        default    { $handled = $false }
    }
    if ($handled) { $e.Handled = $true }
})

# ---- tray icon
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $trayIcon
$tray.Text = $AppName
$tray.Visible = -not $Snapshot

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add('Open calendar')
$miOpen.Font = New-Object System.Drawing.Font($menu.Font, [System.Drawing.FontStyle]::Bold)
$miOpen.add_Click({ Show-Main })
$menu.Items.Add('New reminder...').add_Click({ Open-Editor $null $script:SelDate })
[void]$menu.Items.Add('-')
$menu.Items.Add('Exit').add_Click({
    $script:Exiting = $true
    $tray.Visible = $false
    foreach ($p in @($script:Popups)) { $p.Close() }
    $win.Close()
    $app.Shutdown()
})
$tray.ContextMenuStrip = $menu
$tray.add_MouseClick({ if ($_.Button -eq 'Left') { Show-Main } })


# Closing the window just hides it - reminders keep running in the tray.
$script:Exiting = $false
$win.add_Closing({
    if (-not $script:Exiting) {
        $_.Cancel = $true
        Close-Editor
        $win.Hide()
    }
})

# ---- go
Import-Data
if ($firstRun) { Save-Settings; Set-Startup $true }
$ChkStartup.IsChecked = Test-Path $StartupLnk
# keep the startup shortcut pointing at this script if it was moved
if ($ChkStartup.IsChecked) { Set-Startup $true }

if ($Snapshot) {
    # dev aid: render the main window, the editor and a popup to PNGs, then quit
    function Save-Visual($el, [string]$path) {
        $el.UpdateLayout()
        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]$el.ActualWidth, [int]$el.ActualHeight, 96, 96, 'Pbgra32')
        $rtb.Render($el)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [IO.File]::Create($path); $enc.Save($fs); $fs.Close()
    }
    function Invoke-Click($btn) { $btn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $btn))) }
    function Invoke-Key([string]$key) {
        $src = [System.Windows.PresentationSource]::FromVisual($win)
        $e = New-Object System.Windows.Input.KeyEventArgs([System.Windows.Input.Keyboard]::PrimaryDevice, $src, 0, [System.Windows.Input.Key]$key)
        $e.RoutedEvent = [System.Windows.Input.Keyboard]::PreviewKeyDownEvent
        $win.RaiseEvent($e)
    }
    New-Item -ItemType Directory -Force $Snapshot | Out-Null
    $win.Show(); Update-Views
    Save-Visual $win.Content (Join-Path $Snapshot 'main.png')

    # click through the app the way a person would
    Invoke-Click $BtnNext; Invoke-Click $BtnPrev; Invoke-Click $BtnToday
    foreach ($k in 'Left', 'Right', 'Down', 'Up', 'PageDown', 'PageUp') { Invoke-Key $k }
    Invoke-Click $BtnNew
    $EdTitle.Text = 'Drink water'
    $RepeatPills['Minutely'].IsChecked = $true
    $EdInterval.Text = '45'
    Invoke-Click $EdIntPlus
    Invoke-Click $EdSave
    Invoke-Key 'Return'
    $EdTitle.Text = 'Piano lesson'
    $RepeatPills['Weekly'].IsChecked = $true
    $DayChips[1].IsChecked = $true; $DayChips[3].IsChecked = $true
    $EdEndOn.IsChecked = $true
    $EdUntil.Text = 'Dec 18, 2026'
    Update-RepeatEditor
    Save-Visual $win.Content (Join-Path $Snapshot 'editor.png')
    Invoke-Key 'Return'
    Invoke-Click $BtnTest
    $p = $script:Popups[0]
    $p.FindName('Root').Opacity = 1; $p.FindName('Slide').X = 0
    Save-Visual $p.Content (Join-Path $Snapshot 'popup.png')
    Invoke-Click $p.FindName('BtnS5')
    Open-Editor ($script:Reminders | Where-Object Title -eq 'Drink water')
    Invoke-Click $EdDelete; Invoke-Click $EdDelete
    Update-Views
    Save-Visual $win.Content (Join-Path $Snapshot 'after.png')

    # let queued dispatcher work run, then quit
    $quit = New-Object System.Windows.Threading.DispatcherTimer
    $quit.Interval = [TimeSpan]::FromSeconds(2)
    $quit.add_Tick({ $app.Shutdown() })
    $quit.Start()
    [void]$app.Run()
    return
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$script:LastDay = (Get-Date).Date
$timer.add_Tick({
    if ($showEvent.WaitOne(0)) { Show-Main }
    Invoke-ReminderCheck
    if ($win.IsVisible -and (Get-Date).Second -eq 0) {
        if ((Get-Date).Date -ne $script:LastDay) { $script:LastDay = (Get-Date).Date; Update-Views } else { Update-Clock }
    }
})
$timer.Start()

if (-not $Minimized) { Show-Main }
Invoke-ReminderCheck

try {
    [void]$app.Run()
} finally {
    $timer.Stop()
    $tray.Visible = $false
    $tray.Dispose()
    $mutex.ReleaseMutex()
}
