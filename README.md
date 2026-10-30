# Reminder Calendar

A calendar app for Windows that reminds you of things with a pop-up alert. It runs in the system tray and needs nothing extra installed: it uses the PowerShell that ships with Windows.

- Month view with color-coded reminders
- Repeat every N minutes, hours, days, weeks (on chosen weekdays), months or years, with an optional end date
- Get alerted at the time, or 5 minutes up to 1 day before
- Pop-up alerts with Snooze 5 min / 15 min
- Starts with Windows (can be turned off in the app)

## Install

Open **PowerShell** and run:

```powershell
irm https://raw.githubusercontent.com/tareasacademy/ReminderCalendar/main/install.ps1 | iex
```

This installs the app to `%LOCALAPPDATA%\Programs\ReminderCalendar`, adds Start menu and desktop shortcuts, and starts it. Run the same command again to update.

## Uninstall

Go to **Settings → Apps → Installed apps → Reminder Calendar → Uninstall**, or run:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/tareasacademy/ReminderCalendar/main/install.ps1))) -Uninstall
```

Your reminders are kept in `%APPDATA%\ReminderCalendar`. Delete that folder to remove them too.

## Requirements

Windows 10 or 11.
