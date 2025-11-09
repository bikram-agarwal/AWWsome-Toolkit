# AWWsome-Toolkit

A collection of practical scripts and utilities spanning **Android**, **Windows**, and **Web** (AWW) platforms. This toolkit brings together helpful automation and maintenance scripts for enthusiasts who like to tinker, optimize, and automate their tech workflows.

## 📱 Android

### Pixel Boot Patcher
Automates the boot image patching process for rooting Pixel devices using KernelSU-based GKI kernels.

- **Script**: [`pixel_boot_patcher.ps1`](android/pixel_boot_patcher.ps1)
- **Guide**: [`pixel_boot_patcher.md`](android/pixel_boot_patcher.md)
- **What it does**: Extracts factory images, replaces the kernel with GKI, and repackages a patched boot image ready for flashing to gain root. 
- **Platform**: Windows (PowerShell)
- **Requirements**: WinRAR, magiskboot, factory image, kernel ZIP

### Pixel AI Porting
Documentation for extrating AI models from the Pixel 10 factory image.

- **Guide**: [`PixelAIPorting.md`](android/PixelAIPorting.md)

## 🪟 Windows

### Start Menu Manager
Automated Start Menu backup / restore, with scheduling.
- **Script**: [`start_menu_manager.ps1`](windows/start_menu_manager.ps1)
- **Guide**: [`start_menu_manager.md`](windows/start_menu_manager.md)
- **What it does**:
  - 📖 **READ mode**: Display current config structure
  - 💾 **SAVE mode**: Scan Start Menu and generate configuration file
  - 🛡️ **ENFORCE mode**: Organize shortcuts based on configuration
- **Features**:
  - 🖱️ Interactive menu system for easy mode selection
  - ⚡ Parallel processing (PowerShell 7+) for 2-3x faster scanning
  - 🎭 Automatic duplicate detection and removal
  - ➕ Missing shortcut recreation with original properties
  - 🥅 Quarantines unknown shortcuts to "Unsorted" with smart numbering
  - 🏃 Auto-elevation when admin privileges needed
  - 📅 Scheduled task support for daily automation
  - 👁️ Dry-run preview before making changes
  - 📊 Comprehensive logging with timestamps
- **Smart Features**:
  - Handles app version updates (e.g., Chrome 120 → Chrome 121)
  - Manages architecture variants (32-bit/64-bit) as separate entries
- **Use case**: Permanently maintain Start Menu organization, especially useful after software updates or new installations

### Windows Cleanup
Comprehensive system cleanup tool and documentation for reclaiming disk space safely.

- **Module**: [`Windows_Cleanup.psm1`](windows/Windows_Cleanup.psm1)
- **Guide**: [`Windows_Cleanup.md`](windows/Windows_Cleanup.md)
- **What it covers**:
  - Container layers (Sandbox, WSL)
  - Browser data (Edge, Chrome)
  - Outlook temporary files
  - Driver cache cleanup
  - Windows Installer orphans
  - System restore points management

## 🌐 Web

### Calendar to Task Sync
Google Apps Script with a sleek web interface for syncing calendar events to Google Tasks.

- **Script**: [`calendar_to_task.js`](web/calendar_to_task.js)
- **Guide**: [`calendar_to_task.md`](web/calendar_to_task.md)
- **What it does**: 
  - Picks up unwatched events from the `Entertainment` calendar and creates tasks in the `Backlog` list
  - Automatically removes tasks from task list when corresponding events in calendar are marked watched
  - Conversely, marks events in calendar as watched when tasks in task list are marked completed
- **Features**:
  - 🌐 **Browser-based dashboard** with real-time visual reports
  - 🎨 **5 theme options** (Ocean Blue, Forest Green, Sunset Orange, Purple Dream, Rose Pink)
  - 🌓 **Light/Dark mode** with system preference support
  - 📅 **Custom date ranges** for flexible sync period selection
  - 📊 **Collapsible phase tables** with detailed status indicators
- **Platform**: Google Apps Script (Web App)
- **Use case**: Perfect for tracking watchlists, entertainment queues, or any calendar-based TODO workflow

## 🚀 Getting Started

Each tool includes its own documentation with detailed setup instructions, prerequisites, and usage examples. Navigate to the respective folders and read the accompanying `.md` files for complete guides.

## ⚠️ Disclaimer

These scripts are provided "as is" without warranty. Always:
- Backup your data before running system-level scripts
- Review and understand what each script does
- Use at your own risk (especially for Android rooting tools)

## 🤝 Contributing

Found a bug? Have a useful script to add? Contributions are welcome! Feel free to open an issue or submit a pull request.

## 📜 License

Free to use and modify. See individual script headers for any specific licensing information.

---

**Happy tinkering!** 🛠️
