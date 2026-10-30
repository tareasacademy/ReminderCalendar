# Reminder Calendar installer.
#
#   Install / update:  irm https://raw.githubusercontent.com/tareasacademy/ReminderCalendar/main/install.ps1 | iex
#   Uninstall:         & ([scriptblock]::Create((irm https://raw.githubusercontent.com/tareasacademy/ReminderCalendar/main/install.ps1))) -Uninstall
#                      (or Settings > Apps > Installed apps > Reminder Calendar > Uninstall)
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'

$Repo       = 'tareasacademy/ReminderCalendar'   # <-- your GitHub user/repo
$Branch     = 'main'
$AppName    = 'Reminder Calendar'
$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\ReminderCalendar'
$AppFile    = Join-Path $InstallDir 'ReminderCalendar.ps1'
$Uninstaller = Join-Path $InstallDir 'uninstall.ps1'
$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ReminderCalendar'
$PowerShellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$IconFile   = Join-Path $InstallDir 'icon.ico'
$Icon       = $IconFile
$Shortcuts  = @(
    (Join-Path ([Environment]::GetFolderPath('Programs')) "$AppName.lnk"),
    (Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppName.lnk"),
    (Join-Path ([Environment]::GetFolderPath('Startup')) "$AppName.lnk")
)

function Stop-App {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*ReminderCalendar.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function New-Shortcut([string]$path, [string]$extraArgs = '') {
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($path)
    $s.TargetPath = $PowerShellExe
    $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$AppFile`" $extraArgs".Trim()
    $s.WorkingDirectory = $InstallDir
    $s.IconLocation = $Icon
    $s.WindowStyle = 7
    $s.Save()
}

if ($Uninstall) {
    Write-Host "Uninstalling $AppName..."
    Stop-App
    foreach ($l in $Shortcuts) { Remove-Item $l -ErrorAction SilentlyContinue }
    Remove-Item $UninstallKey -Recurse -ErrorAction SilentlyContinue
    Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "$AppName has been removed. Your reminders are still in $env:APPDATA\ReminderCalendar - delete that folder to remove them too." -ForegroundColor Green
    return
}

Write-Host "Installing $AppName..."
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

# Use the files next to this script when run from a clone; otherwise download them from GitHub.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
function Get-AppFile([string]$name) {
    $tmp = Join-Path $env:TEMP "ReminderCalendar-$([guid]::NewGuid())-$name"
    $local = if ($PSScriptRoot) { Join-Path $PSScriptRoot $name }
    if ($local -and (Test-Path $local)) { Copy-Item $local $tmp }
    else { Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/$Repo/refs/heads/$Branch/$name" -OutFile $tmp }
    $tmp
}
$newApp  = Get-AppFile 'ReminderCalendar.ps1'
$newIcon = Get-AppFile 'icon.ico'

Stop-App   # so an update can replace the file
Move-Item $newApp $AppFile -Force
Move-Item $newIcon $IconFile -Force
Unblock-File $AppFile

# Uninstaller + entry in Settings > Apps
@"
`$ErrorActionPreference = 'SilentlyContinue'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { `$_.CommandLine -like '*ReminderCalendar.ps1*' } | ForEach-Object { Stop-Process -Id `$_.ProcessId -Force }
$(($Shortcuts | ForEach-Object { "Remove-Item '$_'" }) -join "`n")
Remove-Item '$UninstallKey' -Recurse
Remove-Item '$InstallDir' -Recurse -Force
"@ | Set-Content -Path $Uninstaller -Encoding UTF8

New-Item -Path $UninstallKey -Force | Out-Null
$props = @{
    DisplayName     = $AppName
    DisplayIcon     = $Icon
    Publisher       = $Repo.Split('/')[0]
    InstallLocation = $InstallDir
    UninstallString = "`"$PowerShellExe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Uninstaller`""
    NoModify        = 1
    NoRepair        = 1
}
foreach ($k in $props.Keys) { Set-ItemProperty -Path $UninstallKey -Name $k -Value $props[$k] }

New-Shortcut $Shortcuts[0]
New-Shortcut $Shortcuts[1]
New-Shortcut $Shortcuts[2] '-Minimized'   # start with Windows (can be turned off in the app)

Start-Process $PowerShellExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$AppFile`"" -WindowStyle Hidden
Write-Host "$AppName is installed and running. Find it in the Start menu, on your desktop, or in the system tray." -ForegroundColor Green
