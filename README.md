# Startup Cleaner

A small, dark-themed Windows app for managing the programs that start with Windows - the same list Task Manager shows under **Startup apps**, but with a real **Remove** button.

- **Remove** startup entries completely (not just disable them)
- **Disable / Enable** them, exactly like Task Manager does
- App icons and friendly names
- Automatic backup before every removal

## Usage

1. Download or clone this repo.
2. Double-click `StartupCleaner.cmd`.
3. Accept the admin prompt (needed for entries that apply to all users).

Select one or more apps, then click **Disable / Enable** or **Remove** (or press `Delete`). The `...` menu has *Open file location*, *Open backups folder* and *Refresh*.

No install and no dependencies - it is a single PowerShell script using the WinForms that ships with Windows 10/11.

## What it covers

| Source | Remove | Disable |
| --- | --- | --- |
| `HKCU` / `HKLM` `...\CurrentVersion\Run` (incl. 32-bit `WOW6432Node`) | Yes | Yes |
| Startup folders (current user and all users) | Yes | Yes |
| Store / MSIX apps (Terminal, To Do, ...) | No - uninstall the app instead | Yes |

## Backups and restoring

Before removing anything, the app saves a backup in a `backups` folder next to the script:

- Registry entries are saved as `.reg` files - double-click one to restore it.
- Startup-folder shortcuts are copied there - move the file back into `shell:startup` to restore it.

## Notes

Task Manager can keep showing entries that are already gone until you close and reopen it.
