# 📂 Start Menu Manager

## 😤 The Problem

Tired of every app and their mama randomly dumping shortcuts all over your Start Menu? One app creates a shortcut directly in the parent of Programs folder. Another decides it needs its own dedicated folder for a single shortcut. That utility you installed? It bypassed the Programs folder entirely and planted itself at the top level. You spend 20 minutes organizing everything into neat folders, feeling productive... only to have it turn into chaos again after a few weeks of installing updates and new software.

**Sound familiar?**

## 💡 The Solution

A dual-mode PowerShell script that automates Windows Start Menu organization. Set up your ideal folder structure once, and let the script maintain it automatically. Every shortcut knows its place, and new installations get quarantined for review instead of cluttering your organized menu.

## ✨ Features

- **Two Operating Modes**: Backup current Start Menu structure OR restore the Start Menu to a previously saved structure. 
- **Smart Normalization**: Handles app version updates gracefully (e.g., `Chrome 120.lnk` → `Chrome 121.lnk` automatically matches)
- **Architecture Variant Detection**: Intelligently manages duplicate variants like "ODBC (32-bit)" and "ODBC (64-bit)"
- **Dry-Run Mode**: Preview changes before applying them (enabled by default for manual runs)
- **Automated Scheduling**: Run daily via Windows Task Scheduler to maintain organization
- **Comprehensive Logging**: All actions logged with timestamps and detailed information
- **Quarantine Unknown Shortcuts**: Automatically moves unrecognized shortcuts to "Unsorted" folder

## 🔮 How It Works

### 💾 SAVE Mode
1. Scans your entire Start Menu structure
2. Groups shortcuts by their current folders
3. Generates a JSON configuration file with alphabetically sorted folders and shortcuts
4. Outputs: `StartMenuConfig.json`

### 🛡️ ENFORCE Mode
1. Reads the configuration file
2. Scans all current Start Menu shortcuts
3. Compares current locations with expected locations
4. In **manual mode**: Shows preview and asks for confirmation
5. In **automated mode**: Executes changes immediately
6. Moves misplaced shortcuts to correct folders
7. Quarantines unknown shortcuts to "Programs\Unsorted"

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

# 1. Remove existing user Start Menu (backup first!)
$userMenu = "$env:APPDATA\Microsoft\Windows\Start Menu"
$allUsersMenu = "C:\ProgramData\Microsoft\Windows\Start Menu"

# Backup your user shortcuts first
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
- Administrator privileges (for scheduled task setup only, or junction creation)

## ⚒️ Setup

### 1️⃣ Initial Configuration

Go to the Start Menu folder and organize it the way you want. Once you are happy with it, prepare the script. Edit the variables at the top of `start_menu_manager.ps1` to match your paths:

```powershell
$target           = "C:\ProgramData\Microsoft\Windows\Start Menu"
$configPath       = "D:\OneDrive\Backups\StartMenuConfig.json"
$logPath          = "D:\OneDrive\Backups\StartMenuManager.log"
$quarantineFolder = "Programs\Unsorted"
```

Launch a PowerShell terminal and run the script to generate your baseline configuration: 

```powershell
.\start_menu_manager.ps1 -Save
```

This creates `StartMenuConfig.json` with your current Start Menu structure.

### 2️⃣ Test Your Configuration

To test, misplace some of the shortcuts in the Start Menu folder, and then run the script in manual mode (dry-run is enabled by default):

```powershell
.\start_menu_manager.ps1
```
This shows what would change and asks for confirmation before proceeding.

### 3️⃣ Set Up Automation (Optional)

To run the script automatically every day, create a Windows Scheduled Task:

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
   - Program/script: `PowerShell.exe`
   - Add arguments (all on one line):
   ```
   -NoProfile -ExecutionPolicy Bypass -File "D:\Path\To\Your\start_menu_manager.ps1" -Automated
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

### 🖱️ Manual Execution

**Generate/Update Configuration:**
```powershell
.\start_menu_manager.ps1 -Save
```

**Restore Start Menu (with preview):**
```powershell
.\start_menu_manager.ps1
```

**Restore Start Menu (no preview):**
```powershell
.\start_menu_manager.ps1 -Automated
```

### 📊 Understanding the Output

**Terminal Output:**
```powershell
MODE: ENFORCE, MANUAL

Scanning shortcuts at C:\ProgramData\Microsoft\Windows\Start Menu...
Processing 135 shortcuts...

====================================================================
 SUMMARY - Planned Changes
====================================================================

MOVES TO CORRECT FOLDERS (5):
  - Chrome 121.lnk
    FROM: Root -> TO: Programs
  - Steam.lnk
    FROM: Programs -> TO: Programs\Gaming

UNKNOWN SHORTCUTS TO QUARANTINE (2):
  - Unknown App.lnk
    FROM: Programs -> TO: Programs\Unsorted

====================================================================

Do you want to proceed with these changes? (Y/N): 
```

**Log File Format:**
```
============================== 11/04/2025 19:00:00 ==============================

MODE: ENFORCE, AUTOMATED

Moved: Chrome 121.lnk FROM: Root -> TO: Programs
Quarantined: Unknown App.lnk FROM: Programs -> TO: Programs\Unsorted

Completed! 2 successful, 0 errors.
```

## 🏥 Quarantine Folder

Any shortcut not listed in your config gets moved to `Programs\Unsorted`. This prevents cluttering your organized folders with new installations. Periodically check this folder and either:
1. Add desired shortcuts to your config (in their proper folders)
2. Delete unwanted shortcuts
3. Re-run with `-Save` to update your config with the new structure

## 🔧 Troubleshooting

### ❌ "Config not found" Error

**Problem:** Script can't find `StartMenuConfig.json`

**Solution:** Run `.\start_menu_manager.ps1 -Save` to generate it

### ⏰ Scheduled Task Not Running

**Problem:** Task shows in Task Scheduler but doesn't execute

**Possible causes:**
1. **Access Denied (0x1)**: Task running as SYSTEM can't access OneDrive paths
   - Solution: Edit the task → General tab → Change user account to your own account instead of SYSTEM
2. **File locked**: Log file open in editor
   - Solution: Close the log file before task runs
3. **Script path changed**: Task points to old location
   - Solution: Edit the task → Actions tab → Update the script path
4. **Wrong arguments**: Missing or incorrect `-Automated` flag
   - Solution: Edit the task → Actions tab → Verify arguments include `-Automated`

### 📄 Shortcuts Lose Icons After Moving

**Problem:** Moved shortcuts show blank/generic icons

**Cause:** Windows icon cache needs refresh

**Solution:**
Quick fix: Restart Windows Explorer from Task Manager


## 💎 Best Practices

1. **Start Clean**: Run `-Save` on a freshly organized Start Menu to create your ideal baseline
2. **Regular Maintenance**: Check quarantine folder weekly for new installations
3. **Backup Config**: Keep a copy of your `StartMenuConfig.json` - it's your organizational blueprint
4. **Test Changes**: Always run manual mode first after editing config
5. **Review Logs**: Periodically check the log file for errors or unexpected behavior

## ❓ FAQ
**Q: What about Microsoft Store apps?**  
A: Store apps don't use `.lnk` shortcuts - they're managed separately by Windows. This script only handles traditional shortcuts.

**Q: Can I have the same shortcut in multiple folders?**  
A: No, each shortcut can only be in one location. The config uses a flat lookup where each shortcut maps to one folder.

**Q: Does this work with shortcuts in nested folders?**  
A: Yes! The script recursively scans all folders. 

**Q: Will this break anything?**  
A: No. It only moves `.lnk` files, which are just pointers. The actual programs remain untouched. However, pinned Start Menu tiles may need to be re-pinned if their shortcuts move.

