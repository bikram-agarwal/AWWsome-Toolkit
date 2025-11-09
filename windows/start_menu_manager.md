# 📂 Start Menu Manager

A dual-mode PowerShell script that automates Windows Start Menu organization. 

**😤 The Problem**

Tired of every app randomly dumping shortcuts all over your Start Menu? One installer creates a shortcut directly in the root. Another creates a dedicated folder for a single shortcut. That utility you installed bypasses the Programs folder entirely. You spend 20 minutes organizing everything into neat folders... only to have it descend into chaos again after a few weeks of updates and new installations. Sound familiar?

**💡 The Solution**

This script solves that problem permanently. Set up your ideal folder structure once, and let the script maintain it automatically. Every shortcut knows its place, and new installations get quarantined for review instead of cluttering your organized menu.

## ✨ Features

### Core Functionality
- **Three Operating Modes**: 
  - **READ** - Display your current config structure without making changes
  - **SAVE** - Backup current Start Menu structure to a JSON config file
  - **ENFORCE** - Restore the Start Menu to match your saved structure
- **Smart Normalization**: Handles app version updates gracefully (e.g., `Chrome v120 (64-bit).lnk` → `Chrome v121.lnk` automatically matches)
- **Architecture Variant Detection**: Intelligently manages different variants like "ODBC (32-bit)" and "ODBC (64-bit)" as separate entries
- **Duplicate Management**: Automatically detects and removes duplicate shortcuts, keeping the one in the correct location
- **Quarantine System**: Moves unrecognized shortcuts to `Programs\Unsorted` with automatic numbering for duplicates

### Performance & Usability
- **Parallel Processing**: PowerShell 7+ automatically uses multi-threading for 2-3x faster scanning on systems with 100+ shortcuts
- **Dry-Run Mode**: Preview all changes before applying them (enabled by default for manual runs)
- **Interactive Menu**: User-friendly menu system for selecting modes
- **Comprehensive Logging**: All actions logged with timestamps and detailed information
- **Auto-Elevation**: Automatically requests admin privileges when needed

### Automation
- **Scheduled Task Support**: Run daily via Windows Task Scheduler to maintain organization
- **Automated Mode**: Non-interactive execution for scheduled tasks with `-Auto` flag

## 🔬 Technical Details: Start Menu Locations

Windows maintains **two separate Start Menu locations**:

### 👥 All Users (System-Wide)
```
C:\ProgramData\Microsoft\Windows\Start Menu\Programs
```
- Shortcuts here appear for **all users** on the system
- Most installers place shortcuts here (requires admin privileges)
- **This is the default target** for this script

### 👤 Current User (Per-User)
```
%APPDATA%\Microsoft\Windows\Start Menu\Programs
(Typically: C:\Users\YourName\AppData\Roaming\Microsoft\Windows\Start Menu\Programs)
```
- Shortcuts here appear **only for your user account**
- Some portable apps and user-installed software use this location
- Windows merges both locations when displaying the Start Menu

### ⚙️ Script Configuration

The script can manage **either location** by changing the `$target` variable:

```powershell
# For All Users (default):
$target = "C:\ProgramData\Microsoft\Windows\Start Menu"

# For Current User only:
$target = "$env:APPDATA\Microsoft\Windows\Start Menu"
```

You can run the script twice with different configs to manage both locations separately, or use the Pro Tip below for a unified approach.

### 💎 Pro Tip: Junction for Unified Management

If you're the only user or want to manage everything from one place, create a **directory junction** from your user Start Menu to the all-users Start Menu:

```powershell
# ⚠️ CAUTION: Advanced users only! Backup first!
# Run PowerShell as Administrator

# 1. Backup and consolidate shortcuts
$userMenu = "$env:APPDATA\Microsoft\Windows\Start Menu"
$allUsersMenu = "C:\ProgramData\Microsoft\Windows\Start Menu"

# Move user shortcuts to all-users location
Move-Item "$userMenu\Programs\*" "$allUsersMenu\Programs\" -Force

# Remove the old folder
Remove-Item "$userMenu\Programs" -Recurse -Force

# Create junction (symbolic link)
cmd /c mklink /J "$userMenu\Programs" "$allUsersMenu\Programs"
```

**Benefits:**
- ✅ Single location to manage all shortcuts
- ✅ No duplicate shortcuts in different locations
- ✅ Simplified maintenance and organization

**Risks:**
- ⚠️ Changes affect all users on the system (if multi-user setup)
- ⚠️ Requires admin privileges for all shortcut operations
- ⚠️ Some installers might behave unexpectedly

> **⚠️ DISCLAIMER:** Creating junctions modifies system directories. While generally safe, I am not responsible for any issues, data loss, or system instability that may result. Always backup important data and test in a non-production environment first. Proceed at your own risk.

## 📋 Prerequisites

- Windows 10/11
- PowerShell 5.1 or higher
  - **PowerShell 7+** recommended for 2-3x faster performance via parallel processing
- Administrator privileges (for ENFORCE mode and scheduled task setup)

## ⚒️ Setup

### 1️⃣ Initial Configuration

Edit the `start_menu_manager.ps1` script configuration variables to match your paths:

```powershell
$target           = "C:\ProgramData\Microsoft\Windows\Start Menu"
$configPath       = "D:\OneDrive\Backups\Start Menu\StartMenuConfig.json"
$logPath          = "D:\OneDrive\Backups\Start Menu\StartMenuManager.log"
$quarantineFolder = "Programs\Unsorted"
```

### 2️⃣ Organize Your Start Menu

Manually organize your Start Menu folders exactly how you want them. Take your time - this becomes your baseline.

### 3️⃣ Generate Your Configuration

Launch PowerShell and run:

```powershell
.\start_menu_manager.ps1
```

Select option **[2] SAVE** from the menu, or run directly:

```powershell
.\start_menu_manager.ps1 -Mode SAVE
```

This creates `StartMenuConfig.json` with your current Start Menu structure.

### 4️⃣ Test Your Configuration

Intentionally misplace some shortcuts, then run the script in manual mode:

```powershell
.\start_menu_manager.ps1
```

Select option **[3] ENFORCE** from the menu. The script will show you what would change and ask for confirmation before proceeding.

### 5️⃣ Set Up Automation (Optional)

To run the script automatically every day:

1. **Open Task Scheduler**: Press `Win + R`, type `taskschd.msc`, press Enter

2. **Create New Task**: Click "Create Task..." (not "Basic Task") in the Actions panel

3. **General Tab**:
   - Name: `Start Menu Manager`
   - Description: `Automatically organizes Start Menu shortcuts`
   - Select: ☑ "Run whether user is logged on or not"
   - Select: ☑ "Run with highest privileges"

4. **Triggers Tab**:
   - Click "New..." → Begin the task: `On a schedule`
   - Settings: `Daily` at `7:00 PM` (or your preferred time)
   - Check: ☑ "Enabled" → Click OK

5. **Actions Tab**:
   - Click "New..." → Action: `Start a program`
   - Program/script: Browse to your PowerShell executable
     - PowerShell 7: `C:\Program Files\PowerShell\7\pwsh.exe` (recommended)
     - PowerShell 5: `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`
   - Add arguments (all on one line):
   ```
   -NoProfile -ExecutionPolicy Bypass -File "D:\Path\To\Your\start_menu_manager.ps1" -Auto
   ```
   - ⚠️ **Replace with your actual script path!**
   - Click OK

6. **Conditions Tab**:
   - Uncheck: "Start the task only if the computer is on AC power"

7. **Settings Tab**:
   - Check: ☑ "Allow task to be run on demand"
   - Check: ☑ "Run task as soon as possible after a scheduled start is missed"

8. Click **OK** and enter your Windows password when prompted

**Test it**: Right-click the task → "Run" and check `StartMenuManager.log` to verify!

## 🚀 Usage

### 🖱️ Interactive Menu

Simply run the script without parameters to access the interactive menu:

```powershell
.\start_menu_manager.ps1
```

You'll see:
```
======================================================================================================
 START MENU MANAGER - Select Mode
======================================================================================================

  [1] READ    - Display current config structure
  [2] SAVE    - Save current Start Menu to config
  [3] ENFORCE - Organize Start Menu based on config
  [4] EXIT    - Exit the script

Select an option (1-4):
```

### 📝 Direct Mode Selection

**Display current configuration:**
```powershell
.\start_menu_manager.ps1 -Mode READ
```

**Generate/update configuration:**
```powershell
.\start_menu_manager.ps1 -Mode SAVE
```

**Restore Start Menu (with preview):**
```powershell
.\start_menu_manager.ps1 -Mode ENFORCE
```

**Restore Start Menu (automated, no preview):**
```powershell
.\start_menu_manager.ps1 -Auto
```

### 📊 Understanding the Output

#### Terminal Output (Preview Mode)

```powershell
MODE: ENFORCE, MANUAL

Scanning shortcuts at C:\ProgramData\Microsoft\Windows\Start Menu...
Processing 135 shortcuts...

======================================================================
 SUMMARY - Planned Changes
======================================================================

MOVES TO CORRECT FOLDERS (3):
  ➡️ Chrome.lnk                           [Move]               FROM: Root                      -> TO: Programs                       

MISSING SHORTCUTS TO RECREATE (1):
  ➕ WinRAR.lnk                           [Recreate]           IN: Programs                                                           

UNKNOWN SHORTCUTS TO QUARANTINE (2):
  🥅 Unknown App.lnk                      [Quarantine]         FROM: Programs                  -> TO: Programs\Unsorted              
  🥅 what.lnk -> what (1).lnk             [Quarantine]         FROM: Programs\New folder       -> TO: Programs\Unsorted              

DUPLICATE SHORTCUTS TO DELETE (1):
  🎭 WeMod.lnk                            [Delete]             IN: Programs                                                           

EMPTY FOLDERS TO DELETE (1):
  🗑️ Programs\New folder                  [Delete]                                                                                   

======================================================================

Do you want to proceed with these changes? (Y/N):
```

#### Execution Output

```
======================================================================
 EXECUTION
======================================================================
➡️ Chrome.lnk                           [Move]               FROM: Root                      -> TO: Programs                        ✅
➕ WinRAR.lnk                           [Recreate]           IN: Programs                                                           ✅
🥅 Unknown App.lnk                      [Quarantine]         FROM: Programs                  -> TO: Programs\Unsorted               ✅
🥅 what.lnk -> what (1).lnk             [Quarantine]         FROM: Programs\New folder       -> TO: Programs\Unsorted               ✅
🎭 WeMod.lnk                            [Delete]             IN: Programs                                                           ✅
🗑️ Programs\New folder                  [Delete]                                                                                    ✅

Completed! 6 successful, 0 errors.
See log: D:\OneDrive\Backups\Start Menu\StartMenuManager.log
```

#### Log File Format

```
============================== 11/09/2025 19:00:00 ==============================

MODE: ENFORCE, AUTOMATED

Scanning shortcuts at C:\ProgramData\Microsoft\Windows\Start Menu...
Processing 135 shortcuts...

Move: Chrome.lnk from Root to Programs
Recreate: WinRAR.lnk in Programs
Quarantine: Unknown App.lnk from Programs to Programs\Unsorted
Quarantine: what.lnk -> what (1).lnk from Programs\New folder to Programs\Unsorted
Deleted duplicate: WeMod.lnk from Programs
Deleted empty folder: Programs\New folder

Completed! 6 successful, 0 errors.
```

## 🎯 How It Works

### 💾 SAVE Mode
1. Scans your entire Start Menu structure recursively
2. Reads shortcut details (target path, arguments, icon, description)
3. Groups shortcuts by their current folders
4. Generates a JSON configuration file with alphabetically sorted folders and shortcuts
5. Creates a timestamped zip backup of your entire Start Menu
6. **PowerShell 7+**: Uses parallel processing (5 threads) for 2-3x faster scanning

### 📖 READ Mode
1. Loads the configuration file
2. Displays the folder structure with shortcut counts
3. Shows shortcuts in column layout for easy reading
4. No changes made to the file system

### 🛡️ ENFORCE Mode

**Planning Phase:**
1. Loads the configuration file and builds lookup tables
2. Scans all current Start Menu shortcuts
3. Compares current locations with expected locations
4. Identifies actions needed:
   - **Moves**: Shortcuts in wrong folders
   - **Recreations**: Missing shortcuts (uses saved details)
   - **Quarantines**: Unknown shortcuts (not in config)
   - **Duplicate Deletes**: Multiple copies of the same shortcut
   - **Folder Cleanups**: Empty folders after moves

**Preview Phase (Manual Mode):**
- Displays all planned changes with emojis and formatting
- Shows before/after locations for moves
- Asks for user confirmation: `Do you want to proceed with these changes? (Y/N)`

**Execution Phase:**
1. Creates necessary folders
2. **Moves** shortcuts to correct folders
3. **Recreates** missing shortcuts with original properties
4. **Quarantines** unknown shortcuts (with numbered names for duplicates: `app.lnk`, `app (1).lnk`, etc.)
5. **Deletes** duplicate shortcuts (keeps the one in the correct location)
6. **Removes** empty folders
7. Displays results with success/error indicators (✅/❌)

## 🏥 Quarantine Folder

Any shortcut not listed in your config gets moved to `Programs\Unsorted`. This prevents cluttering your organized folders with new installations.

**Handling Quarantined Shortcuts:**

Periodically review `Programs\Unsorted` and:
1. **Keep & Organize**: Move desired shortcuts to proper folders, then run `-Mode SAVE` to update config
2. **Delete**: Remove unwanted shortcuts
3. **Leave in Quarantine**: They'll stay there until you decide

**Duplicate Unknown Shortcuts:**
If the script finds multiple copies of an unknown shortcut, it automatically numbers them:
- First one: `app.lnk` (or keeps existing name in quarantine)
- Second one: `app (1).lnk`
- Third one: `app (2).lnk`

## 🔧 Troubleshooting

### ❌ "Config not found" Error

**Problem:** Script can't find `StartMenuConfig.json`

**Solution:** Run the script with `-Mode SAVE` to generate it first

### ⚙️ PowerShell Version Check

**Check your version:**
```powershell
$PSVersionTable.PSVersion
```

**Upgrade to PowerShell 7 for better performance:**
- Download from: https://github.com/PowerShell/PowerShell/releases
- Parallel processing provides 2-3x speedup for systems with 100+ shortcuts

### ⏰ Scheduled Task Not Running

**Problem:** Task shows in Task Scheduler but doesn't execute

**Possible causes and solutions:**

1. **Access Denied (0x1)**: Task running as SYSTEM can't access OneDrive paths
   - **Solution**: Edit task → General tab → Change user to your own account (not SYSTEM)

2. **File Locked**: Log file open in an editor
   - **Solution**: Close the log file before the task runs

3. **Wrong Script Path**: Task points to old location
   - **Solution**: Edit task → Actions tab → Update the file path

4. **Wrong Arguments**: Missing or incorrect `-Auto` flag
   - **Solution**: Edit task → Actions tab → Verify arguments include `-Auto` (not `-Automated`)

5. **PowerShell Execution Policy**: Scripts blocked
   - **Solution**: Ensure arguments include `-ExecutionPolicy Bypass`

### 📄 Shortcuts Lose Icons After Moving

**Problem:** Moved shortcuts show blank/generic icons

**Cause:** Windows icon cache needs refresh

**Solution:**
1. Quick fix: Restart Windows Explorer
   - Open Task Manager (Ctrl+Shift+Esc)
   - Find "Windows Explorer" → Right-click → Restart
2. If icons still broken, recreate the shortcut using the script's recreation feature

### 🔒 Permission Errors During Execution

**Problem:** "Access denied" errors when moving shortcuts

**Solution:**
- ENFORCE mode requires administrator privileges
- The script will auto-elevate if needed
- Ensure your user account has admin rights
- Check that antivirus isn't blocking the script

### 🐌 Slow Performance with Many Shortcuts

**Problem:** Script takes a long time to scan

**Optimization tips:**
1. **Upgrade to PowerShell 7**: Get 2-3x speedup with parallel processing
   - Script automatically detects and uses parallel mode on PowerShell 7+
2. **Close other programs**: Reduces I/O contention
3. **Check disk health**: Slow disk can impact scanning speed

## 💎 Best Practices

1. **Start Clean**: Run `-Mode SAVE` on a freshly organized Start Menu to create your ideal baseline
2. **Regular Maintenance**: Check quarantine folder weekly for new installations
3. **Backup Config**: Keep a copy of `StartMenuConfig.json` - it's your organizational blueprint
4. **Test Changes**: Always run manual mode first after editing the config
5. **Review Logs**: Periodically check the log file for errors or unexpected behavior
6. **Use PowerShell 7**: Get significant performance improvements with parallel processing
7. **Version Control**: Store your config in Git/OneDrive for history and backup

## 🎨 Customization

### Change Quarantine Folder

Edit line 14 in the script:
```powershell
$quarantineFolder = "Programs\My Custom Folder"  # Relative to $target
```

### Adjust Normalization Rules

Edit the `Normalize_ShortcutName` function (lines 100-122) to customize how shortcuts are matched across versions:

```powershell
$n = $name -replace '\s*\((Preview|Beta|Insiders|64-bit|32-bit|x64|x86)\)', '' `
           -replace '\s*v?\d+(\.\d+)*', '' `
           -replace '\s+-\s+Setup$', '' `
           -replace '\s+', ' '
```

### Preserve Additional System Folders

Edit line 298 to add folders that should never be deleted:
```powershell
$systemFolders = @("Programs\Startup", "Programs\Administrative Tools")
```

## ❓ FAQ

**Q: What about Microsoft Store apps?**  
A: Store apps don't use `.lnk` shortcuts - they're managed separately by Windows. This script only handles traditional shortcuts.

**Q: Can I have the same shortcut in multiple folders?**  
A: No, each shortcut can only be in one location. The config uses a flat lookup where each shortcut maps to exactly one folder.

**Q: Does this work with shortcuts in nested folders?**  
A: Yes! The script recursively scans all folders at any depth (e.g., `Programs\Development\IDEs\Visual Studio.lnk`).

**Q: Will this break anything?**  
A: No. It only moves `.lnk` files, which are just pointers. The actual programs remain untouched. However, pinned Start Menu tiles may need to be re-pinned if their shortcuts move.

**Q: Can I exclude certain shortcuts from being moved?**  
A: Add them to your config in their current location, then they'll be left alone. Alternatively, don't include them in the config and they'll be quarantined.

**Q: What if I accidentally delete my config file?**  
A: Just re-run `-Mode SAVE` to create a new config based on your current Start Menu state. The script also creates automatic timestamped zip backups.

**Q: Does it work on Windows Server?**  
A: Yes, as long as PowerShell 5.1+ is installed. The script works on any Windows version with a Start Menu.

**Q: Can I run this on multiple computers with the same config?**  
A: Yes! Store your config in OneDrive/Dropbox and point all machines to the same file. Great for maintaining consistent organization across devices.

## 📄 License

This script is provided as-is without warranty. Feel free to modify and distribute.

## 🤝 Contributing

Found a bug or have a feature request? Contributions welcome!

---

**Made with ❤️ for everyone tired of Start Menu chaos**
