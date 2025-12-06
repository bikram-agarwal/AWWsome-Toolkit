<#
.SYNOPSIS
    Automatically sets folder icons to match the software executable inside each folder.

.DESCRIPTION
    This script scans through folders in a specified directory and sets each folder's
    icon to match the icon of the main executable found inside that folder.
    This is particularly useful for portable software collections.
    
    Edit the CONFIGURATION section below to customize behavior.

.NOTES
    Author: AWWsome-Toolkit
    Requires: Windows with PowerShell 5.1 or later
    The script creates desktop.ini files and sets folder attributes.
#>

# ============================================================================
# CONFIGURATION - Edit these settings before running
# ============================================================================

# Target folder path (leave empty to be prompted)
$TARGET_PATH = "E:\SW"  # Example: "E:\SW" or "C:\PortableApps"

# Mode selection
$MODE = "set"                # Options: "set" or "remove"
$INTERACTIVE_SELECT = $true # Set to $true to choose which folders to process from a list
$CONFIRM_EACH = $true       # Set to $true to confirm each folder before setting icon

# Processing options
$PROCESS_RECURSIVE = $false  # Set to $true to process subfolders recursively
$USE_GUI_PICKER = $false     # Set to $true to use folder browser GUI (may not work in terminals)

# Advanced options
$SPECIFIC_EXE_NAME = ""      # Leave empty for auto-detect, or specify like "app.exe"

# ============================================================================
# DO NOT EDIT BELOW THIS LINE
# ============================================================================

# Function to find the main executable in a folder
function Find-MainExecutable {
    param(
        [string]$FolderPath,
        [string]$SpecificExeName = ""
    )
    
    # If a specific exe name is provided, look for it first
    if ($SpecificExeName) {
        $specificExe = Get-ChildItem -Path $FolderPath -Filter $SpecificExeName -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($specificExe) {
            return $specificExe.FullName
        }
    }
    
    # Get folder name for pattern matching
    $folderName = Split-Path $FolderPath -Leaf
    
    # Optimization: Get all exes once and cache in memory
    $exesInRoot = @(Get-ChildItem -Path $FolderPath -Filter "*.exe" -File -ErrorAction SilentlyContinue)
    
    # Priority 1: Look for exe with folder name in root
    $match = $exesInRoot | Where-Object { $_.Name -like "*$folderName*" } | Select-Object -First 1
    if ($match) { return $match.FullName }
    
    # Priority 2: Any exe in root
    if ($exesInRoot.Count -gt 0) { return $exesInRoot[0].FullName }
    
    # Cache all subdirectory exes (only scan once)
    $allExes = @(Get-ChildItem -Path $FolderPath -Filter "*.exe" -Recurse -File -ErrorAction SilentlyContinue)
    if ($allExes.Count -eq 0) { return $null }
    
    # Priority 3: Exe with folder name in subdirectories
    $match = $allExes | Where-Object { $_.Name -like "*$folderName*" } | Select-Object -First 1
    if ($match) { return $match.FullName }
    
    # Priority 4: Common executable names
    $commonNames = @("app.exe", "main.exe", "launcher.exe", "start.exe")
    foreach ($name in $commonNames) {
        $match = $allExes | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($match) { return $match.FullName }
    }
    
    # Priority 5: First exe (excluding system/installer patterns)
    $excludeRegex = "(unins|uninst|update|crash|helper|setup|install)"
    $match = $allExes | Where-Object { $_.Name -inotmatch $excludeRegex } | Select-Object -First 1
    if ($match) { return $match.FullName }
    
    # Fallback: Return any exe
    return $allExes[0].FullName
}

# Function to set folder icon
function Set-FolderIcon {
    param(
        [string]$FolderPath,
        [string]$IconPath
    )
    
    try {
        # Create desktop.ini content
        $desktopIniPath = Join-Path $FolderPath "desktop.ini"
        
        # Make icon path relative or absolute
        $iconReference = $IconPath
        
        $iniContent = @"
[.ShellClassInfo]
IconResource=$iconReference,0
[ViewState]
Mode=
Vid=
FolderType=Generic
"@
        
        # Write desktop.ini file
        Set-Content -Path $desktopIniPath -Value $iniContent -Force
        
        # Set desktop.ini attributes (Hidden + System)
        $desktopIniFile = Get-Item $desktopIniPath -Force
        $desktopIniFile.Attributes = 'Hidden,System'
        
        # Set folder attributes (ReadOnly to enable custom icon)
        $folder = Get-Item $FolderPath -Force
        if (-not ($folder.Attributes -band [System.IO.FileAttributes]::ReadOnly)) {
            $folder.Attributes = $folder.Attributes -bor [System.IO.FileAttributes]::ReadOnly
        }
        
        return $true
    }
    catch {
        Write-Warning "Failed to set icon for $FolderPath : $_"
        return $false
    }
}

# Function to remove folder icon
function Remove-FolderIcon {
    param(
        [string]$FolderPath
    )
    
    try {
        $desktopIniPath = Join-Path $FolderPath "desktop.ini"
        
        # Check if desktop.ini exists
        if (Test-Path $desktopIniPath -Force) {
            # Remove the desktop.ini file
            Remove-Item -Path $desktopIniPath -Force -ErrorAction Stop
            
            # Remove ReadOnly attribute from folder
            $folder = Get-Item $FolderPath -Force
            if ($folder.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
                $folder.Attributes = $folder.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
            }
            
            return $true
        }
        else {
            return $false  # No desktop.ini found
        }
    }
    catch {
        Write-Warning "Failed to remove icon for $FolderPath : $_"
        return $false
    }
}

# Function to refresh Explorer windows (optional, doesn't always work)
function Refresh-Explorer {
    try {
        $shellApplication = New-Object -ComObject Shell.Application
        $shellApplication.Windows() | ForEach-Object { $_.Refresh() }
    }
    catch {
        # Silently fail - not critical
    }
}

# Main script
function Main {
    # If no target path provided, prompt for it
    if ([string]::IsNullOrWhiteSpace($TARGET_PATH)) {
        Write-Host "`n=== Folder Icon Setter ===" -ForegroundColor Cyan
        Write-Host "No target path specified.`n" -ForegroundColor Yellow
        
        # Use GUI only if explicitly requested
        if ($USE_GUI_PICKER) {
            try {
                Write-Host "Opening folder browser dialog..." -ForegroundColor Gray
                Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
                
                $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
                $folderBrowser.Description = "Select the folder containing software folders"
                $folderBrowser.RootFolder = [System.Environment+SpecialFolder]::MyComputer
                
                if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                    $script:TARGET_PATH = $folderBrowser.SelectedPath
                }
                else {
                    Write-Host "No folder selected. Exiting." -ForegroundColor Yellow
                    return
                }
            }
            catch {
                Write-Warning "Failed to open GUI dialog: $_"
                Write-Host "Falling back to text input...`n" -ForegroundColor Yellow
            }
        }
        
        # Text input (default or fallback)
        if (-not $USE_GUI_PICKER -or [string]::IsNullOrWhiteSpace($TARGET_PATH)) {
            Write-Host "Enter the full path to the folder containing software folders:" -ForegroundColor White
            Write-Host "(e.g., E:\SW or C:\PortableApps)" -ForegroundColor Gray
            $script:TARGET_PATH = Read-Host "Path"
            
            if ([string]::IsNullOrWhiteSpace($TARGET_PATH)) {
                Write-Host "No path provided. Exiting." -ForegroundColor Yellow
                return
            }
            
            # Remove quotes if user pasted a path with quotes
            $script:TARGET_PATH = $TARGET_PATH.Trim('"').Trim("'")
        }
    }
    
    # Validate target path
    if (-not (Test-Path $TARGET_PATH)) {
        Write-Error "Target path does not exist: $TARGET_PATH"
        return
    }
    
    Write-Host "`n=== Folder Icon Setter ===" -ForegroundColor Cyan
    Write-Host "Target Path: $TARGET_PATH" -ForegroundColor White
    Write-Host "Mode: " -NoNewline
    if ($MODE -eq "remove") {
        Write-Host "REMOVE custom icons" -ForegroundColor Red
    }
    else {
        Write-Host "SET custom icons" -ForegroundColor Green
    }
    Write-Host "Recursive: $PROCESS_RECURSIVE" -ForegroundColor White
    Write-Host "Interactive select: $INTERACTIVE_SELECT" -ForegroundColor White
    Write-Host "Confirm each: $CONFIRM_EACH`n" -ForegroundColor White
    
    # Get all folders
    if ($PROCESS_RECURSIVE) {
        $folders = Get-ChildItem -Path $TARGET_PATH -Directory -Recurse
    }
    else {
        $folders = Get-ChildItem -Path $TARGET_PATH -Directory
    }
    
    if ($folders.Count -eq 0) {
        Write-Host "No folders found in the target path." -ForegroundColor Yellow
        return
    }
    
    # Interactive folder selection mode
    if ($INTERACTIVE_SELECT) {
        Write-Host "`nAvailable Folders:" -ForegroundColor Cyan
        Write-Host ("=" * 70)
        
        for ($i = 0; $i -lt $folders.Count; $i++) {
            Write-Host ("{0,3}. {1}" -f ($i + 1), $folders[$i].Name) -ForegroundColor Green
        }
        
        Write-Host ("=" * 70)
        Write-Host "Total: $($folders.Count) folders" -ForegroundColor White
        Write-Host ""
        Write-Host "Enter folder numbers (space-separated), 'all', or 'q' to quit:" -ForegroundColor Yellow
        $selection = Read-Host "Selection"
        
        if ($selection -in 'q', 'Q') {
            Write-Host "Operation cancelled." -ForegroundColor Yellow
            return
        }
        
        if ($selection.ToLower() -eq "all") {
            # Keep all folders
            Write-Host "Processing all $($folders.Count) folders...`n" -ForegroundColor Cyan
        }
        else {
            # Parse selected indices
            $indices = $selection -split '\s+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
            
            if ($indices.Count -eq 0) {
                Write-Host "No valid selections. Exiting." -ForegroundColor Yellow
                return
            }
            
            # Filter folders based on selection
            $selectedFolders = @()
            foreach ($idx in $indices) {
                if ($idx -ge 1 -and $idx -le $folders.Count) {
                    $selectedFolders += $folders[$idx - 1]
                }
                else {
                    Write-Host "Invalid index: $idx (skipped)" -ForegroundColor Red
                }
            }
            
            if ($selectedFolders.Count -eq 0) {
                Write-Host "No valid folders selected. Exiting." -ForegroundColor Yellow
                return
            }
            
            $folders = $selectedFolders
            Write-Host "Processing $($folders.Count) selected folder(s)...`n" -ForegroundColor Cyan
        }
    }
    
    $successCount = 0
    $failCount = 0
    $skippedCount = 0
    
    foreach ($folder in $folders) {
        Write-Host "Processing: " -NoNewline
        Write-Host $folder.Name -ForegroundColor Yellow -NoNewline
        Write-Host " ... " -NoNewline
        
        if ($MODE -eq "remove") {
            # Remove mode
            $result = Remove-FolderIcon -FolderPath $folder.FullName
            
            if ($result) {
                Write-Host "Removed" -ForegroundColor Green -NoNewline
                Write-Host " [OK]" -ForegroundColor Green
                $successCount++
            }
            elseif ($result -eq $false -and (Test-Path (Join-Path $folder.FullName "desktop.ini") -Force)) {
                Write-Host " [FAILED]" -ForegroundColor Red
                $failCount++
            }
            else {
                Write-Host "No custom icon" -ForegroundColor DarkGray -NoNewline
                Write-Host " [SKIPPED]" -ForegroundColor DarkYellow
                $skippedCount++
            }
        }
        else {
            # Set mode
            # Find main executable
            $exePath = Find-MainExecutable -FolderPath $folder.FullName -SpecificExeName $SPECIFIC_EXE_NAME
            
            if ($exePath) {
                $exeFileName = Split-Path $exePath -Leaf
                Write-Host "Found: " -NoNewline -ForegroundColor Gray
                Write-Host $exeFileName -NoNewline -ForegroundColor Green
                
                # Ask for confirmation if enabled
                $shouldSet = $true
                
                if ($CONFIRM_EACH) {
                    Write-Host ""
                    $response = Read-Host "  Use $exeFileName? (Y/n/q or type exe name)"
                    
                    if ($response -in 'q', 'Q') {
                        Write-Host "`nUser cancelled operation." -ForegroundColor Yellow
                        break
                    }
                    
                    # Check if user provided an alternative exe name
                    if ($response -match '\.exe$') {
                        # User provided an exe name, search for it
                        $altExe = Get-ChildItem -Path $folder.FullName -Filter $response -Recurse -File -ErrorAction SilentlyContinue | 
                                  Select-Object -First 1
                        
                        if ($altExe) {
                            $exePath = $altExe.FullName
                            $exeFileName = $altExe.Name
                            Write-Host "  Using: " -NoNewline -ForegroundColor Gray
                            Write-Host $exeFileName -NoNewline -ForegroundColor Cyan
                            $shouldSet = $true
                        }
                        else {
                            Write-Host "  Could not find '$response' in folder" -ForegroundColor Red -NoNewline
                            $shouldSet = $false
                        }
                    }
                    elseif ($response -in 'n', 'N') {
                        $shouldSet = $false
                    }
                    else {
                        # Yes or Enter - use detected exe
                        $shouldSet = ($response -in '', 'y', 'Y')
                    }
                    
                    Write-Host "  " -NoNewline
                }
                
                if ($shouldSet) {
                    # Set folder icon
                    $success = Set-FolderIcon -FolderPath $folder.FullName -IconPath $exePath
                    
                    if ($success) {
                        Write-Host " [OK]" -ForegroundColor Green
                        $successCount++
                    }
                    else {
                        Write-Host " [FAILED]" -ForegroundColor Red
                        $failCount++
                    }
                }
                else {
                    Write-Host " [SKIPPED by user]" -ForegroundColor DarkYellow
                    $skippedCount++
                }
            }
            else {
                Write-Host "No executable found" -ForegroundColor DarkGray -NoNewline
                Write-Host " [SKIPPED]" -ForegroundColor DarkYellow
                $skippedCount++
            }
        }
    }
    
    # Summary
    Write-Host "`n=== Summary ===" -ForegroundColor Cyan
    Write-Host "Total folders: " -NoNewline
    Write-Host $folders.Count -ForegroundColor White
    
    if ($MODE -eq "remove") {
        Write-Host "Successfully removed: " -NoNewline
        Write-Host $successCount -ForegroundColor Green
    }
    else {
        Write-Host "Successfully set: " -NoNewline
        Write-Host $successCount -ForegroundColor Green
    }
    
    Write-Host "Failed: " -NoNewline
    Write-Host $failCount -ForegroundColor Red
    Write-Host "Skipped: " -NoNewline
    Write-Host $skippedCount -ForegroundColor Yellow
    
    # Refresh Explorer
    Write-Host "`nRefreshing Explorer windows..." -ForegroundColor Gray
    Refresh-Explorer
    
    if ($MODE -eq "remove") {
        Write-Host "`nDone! Custom icons removed. You may need to refresh the folder view (F5) or restart Explorer." -ForegroundColor Cyan
    }
    else {
        Write-Host "`nDone! You may need to refresh the folder view (F5) or restart Explorer to see changes." -ForegroundColor Cyan
    }
}

# Run main function
Main

