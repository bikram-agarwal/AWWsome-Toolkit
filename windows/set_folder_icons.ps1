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

# Function to print folders in a terminal-width-aware grid
function Show-FolderGrid {
    param(
        [array]$Folders
    )

    $terminalWidth = 80
    try {
        $terminalWidth = [Math]::Max(40, $Host.UI.RawUI.WindowSize.Width)
    }
    catch {
        # Some hosts do not expose a window size.
    }

    $folderCount = $Folders.Count
    $indexWidth = $folderCount.ToString().Length
    $folderLabels = @()

    for ($folderIndex = 0; $folderIndex -lt $folderCount; $folderIndex++) {
        $folderLabels += ("{0,$indexWidth}. {1}" -f ($folderIndex + 1), $Folders[$folderIndex].Name)
    }

    $longestLabelLength = ($folderLabels | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    $preferredCellWidth = [Math]::Min([Math]::Max($longestLabelLength + 2, 20), 42)
    $columnCount = [Math]::Max(1, [Math]::Floor($terminalWidth / $preferredCellWidth))
    $columnCount = [Math]::Min($columnCount, $folderCount)
    $cellWidth = [Math]::Max(20, [Math]::Floor($terminalWidth / $columnCount))
    $rowCount = [Math]::Ceiling($folderCount / $columnCount)

    for ($rowIndex = 0; $rowIndex -lt $rowCount; $rowIndex++) {
        $rowCells = @()

        for ($columnIndex = 0; $columnIndex -lt $columnCount; $columnIndex++) {
            $folderIndex = ($rowIndex * $columnCount) + $columnIndex

            if ($folderIndex -lt $folderCount) {
                $cellText = $folderLabels[$folderIndex]
                $contentWidth = $cellWidth - 2

                if ($cellText.Length -gt $contentWidth) {
                    $trimmedWidth = [Math]::Max(1, $contentWidth - 3)
                    $cellText = $cellText.Substring(0, $trimmedWidth) + "..."
                }

                $rowCells += $cellText.PadRight($cellWidth)
            }
        }

        Write-Host ($rowCells -join "") -ForegroundColor Green
    }
}

# Function to parse folder selections like "1 3 5" or "1-4 9"
function Resolve-FolderSelection {
    param(
        [string]$Selection,
        [int]$FolderCount
    )

    $selectedIndices = [System.Collections.Generic.List[int]]::new()
    $invalidSelections = @()
    $selectionParts = $Selection -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($selectionPart in $selectionParts) {
        if ($selectionPart -match '^(\d+)-(\d+)$') {
            $rangeStart = [int]$Matches[1]
            $rangeEnd = [int]$Matches[2]

            if ($rangeStart -lt 1 -or $rangeEnd -gt $FolderCount -or $rangeStart -gt $rangeEnd) {
                $invalidSelections += $selectionPart
                continue
            }

            for ($folderNumber = $rangeStart; $folderNumber -le $rangeEnd; $folderNumber++) {
                if (-not $selectedIndices.Contains($folderNumber)) {
                    $selectedIndices.Add($folderNumber)
                }
            }
        }
        elseif ($selectionPart -match '^\d+$') {
            $folderNumber = [int]$selectionPart

            if ($folderNumber -lt 1 -or $folderNumber -gt $FolderCount) {
                $invalidSelections += $selectionPart
                continue
            }

            if (-not $selectedIndices.Contains($folderNumber)) {
                $selectedIndices.Add($folderNumber)
            }
        }
        else {
            $invalidSelections += $selectionPart
        }
    }

    return [PSCustomObject]@{
        Indices = @($selectedIndices)
        InvalidSelections = $invalidSelections
    }
}

# Function to print a clear ASCII banner for major sections
function Show-Banner {
    param(
        [string]$Title
    )

    $terminalWidth = 80
    try {
        $terminalWidth = [Math]::Max(70, $Host.UI.RawUI.WindowSize.Width)
    }
    catch {
        # Some hosts do not expose a window size.
    }

    $bannerWidth = $terminalWidth - 2
    $innerWidth = $bannerWidth - 2
    $borderLine = "=" * $bannerWidth
    $titleText = " $($Title.ToUpperInvariant()) "

    if ($titleText.Length -gt $innerWidth) {
        $titleText = $titleText.Substring(0, $innerWidth)
    }

    $leftPadding = [Math]::Floor(($innerWidth - $titleText.Length) / 2)
    $rightPadding = $innerWidth - $titleText.Length - $leftPadding
    $titleLine = "=" + (" " * $leftPadding) + $titleText + (" " * $rightPadding) + "="

    Write-Host ""
    Write-Host $borderLine -ForegroundColor Cyan
    Write-Host $titleLine -ForegroundColor Cyan
    Write-Host $borderLine -ForegroundColor Cyan
}

# Function to print metadata with aligned separators
function Show-MetadataLine {
    param(
        [string]$Label,
        [string]$Value,
        [ConsoleColor]$ValueColor = [ConsoleColor]::White
    )

    $labelWidth = 20
    $metadataPrefix = $Label.PadRight($labelWidth) + " : "

    Write-Host $metadataPrefix -NoNewline -ForegroundColor White
    Write-Host $Value -ForegroundColor $ValueColor
}

# Main script
function Main {
    # If no target path provided, prompt for it
    if ([string]::IsNullOrWhiteSpace($TARGET_PATH)) {
        Show-Banner -Title "Folder Icon Setter"
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
    
    Show-Banner -Title "Folder Icon Setter"
    Write-Host "This tool can set custom folder icons using the app executable inside each folder." -ForegroundColor White
    Write-Host "It will not move or delete your files, and you can review folders before changes are made.`n" -ForegroundColor White
    Show-MetadataLine -Label "Working folder" -Value $TARGET_PATH
    if ($MODE -eq "remove") {
        Show-MetadataLine -Label "Action" -Value "remove custom folder icons" -ValueColor Yellow
    }
    else {
        Show-MetadataLine -Label "Action" -Value "set custom folder icons" -ValueColor Green
    }
    if ($PROCESS_RECURSIVE) {
        Show-MetadataLine -Label "Scanning" -Value "this folder and all subfolders"
    }
    else {
        Show-MetadataLine -Label "Scanning" -Value "only folders directly inside $TARGET_PATH"
    }
    if ($INTERACTIVE_SELECT) {
        Show-MetadataLine -Label "Folder choice" -Value "you can choose which folders to process"
    }
    else {
        Show-MetadataLine -Label "Folder choice" -Value "every found folder will be processed"
    }
    if ($MODE -eq "remove") {
        Show-MetadataLine -Label "Before each change" -Value "selected custom icons will be removed automatically"
    }
    elseif ($CONFIRM_EACH) {
        Show-MetadataLine -Label "Before each change" -Value "ask me first"
    }
    else {
        Show-MetadataLine -Label "Before each change" -Value "continue automatically"
    }
    Write-Host ""
    
    # Get all folders
    Write-Progress -Activity "Scanning folders" -Status "Looking for folders in $TARGET_PATH" -PercentComplete -1
    if ($PROCESS_RECURSIVE) {
        $folders = Get-ChildItem -Path $TARGET_PATH -Directory -Recurse
    }
    else {
        $folders = Get-ChildItem -Path $TARGET_PATH -Directory
    }
    Write-Progress -Activity "Scanning folders" -Completed
    
    if ($folders.Count -eq 0) {
        Write-Host "No folders found in the target path." -ForegroundColor Yellow
        return
    }
    
    # Interactive folder selection mode
    if ($INTERACTIVE_SELECT) {
        $sectionWidth = 78
        try {
            $sectionWidth = [Math]::Max(68, $Host.UI.RawUI.WindowSize.Width - 2)
        }
        catch {
            # Some hosts do not expose a window size.
        }
        $sectionSeparator = "-" * $sectionWidth

        Write-Host "`nChoose Folders" -ForegroundColor Cyan
        Write-Host $sectionSeparator -ForegroundColor Cyan
        
        Show-FolderGrid -Folders $folders
        
        Write-Host $sectionSeparator -ForegroundColor Cyan
        Write-Host "Found $($folders.Count) folders." -ForegroundColor White
        Write-Host "Type folder numbers like: 1 4 7" -ForegroundColor White
        Write-Host "Type a range like: 1-5 9 12" -ForegroundColor White
        Write-Host "Type 'all' to select everything, or 'q' to quit safely." -ForegroundColor Yellow

        while ($true) {
            $selection = Read-Host "Your choice"

            if ($selection -in 'q', 'Q') {
                Write-Host "Operation cancelled. No changes were made." -ForegroundColor Yellow
                return
            }

            if ($selection.ToLower() -eq "all") {
                Write-Host "Processing all $($folders.Count) folders...`n" -ForegroundColor Cyan
                break
            }

            $selectionResult = Resolve-FolderSelection -Selection $selection -FolderCount $folders.Count

            if ($selectionResult.InvalidSelections.Count -gt 0) {
                Write-Host "I could not understand: $($selectionResult.InvalidSelections -join ', ')" -ForegroundColor Yellow
                Write-Host "Try examples like 1 3 5, 1-5 9, all, or q." -ForegroundColor White
                continue
            }

            if ($selectionResult.Indices.Count -eq 0) {
                Write-Host "No folders selected yet. Try examples like 1 3 5, 1-5 9, all, or q." -ForegroundColor Yellow
                continue
            }

            # Filter folders based on selection
            $selectedFolders = @()
            foreach ($folderNumber in $selectionResult.Indices) {
                $selectedFolders += $folders[$folderNumber - 1]
            }

            $folders = $selectedFolders
            Write-Host "Processing $($folders.Count) selected folder(s)...`n" -ForegroundColor Cyan
            break
        }
    }
    
    $successCount = 0
    $failCount = 0
    $skippedCount = 0
    $processedCount = 0
    $userCancelled = $false

    for ($folderIndex = 0; $folderIndex -lt $folders.Count; $folderIndex++) {
        $folder = $folders[$folderIndex]
        $progressPercent = [int](($folderIndex / $folders.Count) * 100)
        Write-Progress -Activity "Processing folders" -Status "Folder $($folderIndex + 1) of $($folders.Count): $($folder.Name)" -PercentComplete $progressPercent
        Write-Host "Folder $($folderIndex + 1) of $($folders.Count): " -NoNewline
        Write-Host $folder.Name -ForegroundColor Yellow -NoNewline
        Write-Host " ... " -NoNewline
        
        if ($MODE -eq "remove") {
            # Remove mode
            $result = Remove-FolderIcon -FolderPath $folder.FullName
            
            if ($result) {
                Write-Host "custom icon removed [OK]" -ForegroundColor Green
                $successCount++
            }
            elseif ($result -eq $false -and (Test-Path (Join-Path $folder.FullName "desktop.ini") -Force)) {
                Write-Host "could not remove icon [FAILED]" -ForegroundColor Red
                $failCount++
            }
            else {
                Write-Host "no custom icon found [SKIPPED]" -ForegroundColor DarkYellow
                $skippedCount++
            }
        }
        else {
            # Set mode
            # Find main executable
            $exePath = Find-MainExecutable -FolderPath $folder.FullName -SpecificExeName $SPECIFIC_EXE_NAME
            
            if ($exePath) {
                $exeFileName = Split-Path $exePath -Leaf
                Write-Host "found " -NoNewline -ForegroundColor Gray
                Write-Host $exeFileName -NoNewline -ForegroundColor Green
                
                # Ask for confirmation if enabled
                $shouldSet = $true
                
                if ($CONFIRM_EACH) {
                    Write-Host ""
                    Write-Host "Press Enter to use it. Type n to skip, q to quit, or type another .exe name." -ForegroundColor Gray

                    while ($true) {
                        $response = Read-Host "Choice"

                        if ($response -in 'q', 'Q') {
                            Write-Host "`nOperation cancelled. Changes already completed were kept." -ForegroundColor Yellow
                            $userCancelled = $true
                            break
                        }

                        if ($response -in '', 'y', 'Y') {
                            $shouldSet = $true
                            break
                        }

                        if ($response -in 'n', 'N') {
                            $shouldSet = $false
                            break
                        }

                        # Check if user provided an alternative exe name
                        if ($response -match '\.exe$') {
                            $altExe = Get-ChildItem -Path $folder.FullName -Filter $response -Recurse -File -ErrorAction SilentlyContinue |
                                Select-Object -First 1

                            if ($altExe) {
                                $exePath = $altExe.FullName
                                $exeFileName = $altExe.Name
                                Write-Host "Using $exeFileName instead." -ForegroundColor Cyan
                                $shouldSet = $true
                                break
                            }

                            Write-Host "I could not find '$response' in this folder. Try another .exe name, press Enter to use $exeFileName, type n to skip, or q to quit." -ForegroundColor Yellow
                            continue
                        }

                        Write-Host "I did not understand that. Press Enter to use $exeFileName, type n to skip, q to quit, or type another .exe name." -ForegroundColor Yellow
                    }

                    if ($userCancelled) {
                        break
                    }

                    Write-Host "  " -NoNewline
                }
                
                if ($shouldSet) {
                    # Set folder icon
                    $success = Set-FolderIcon -FolderPath $folder.FullName -IconPath $exePath
                    
                    if ($success) {
                        Write-Host "icon set [OK]" -ForegroundColor Green
                        $successCount++
                    }
                    else {
                        Write-Host "could not set icon [FAILED]" -ForegroundColor Red
                        $failCount++
                    }
                }
                else {
                    Write-Host "skipped by user [SKIPPED]" -ForegroundColor DarkYellow
                    $skippedCount++
                }
            }
            else {
                Write-Host "no executable found [SKIPPED]" -ForegroundColor DarkYellow
                $skippedCount++
            }
        }

        if ($userCancelled) {
            break
        }

        $processedCount++
    }
    Write-Progress -Activity "Processing folders" -Completed
    
    # Summary
    Write-Host "`n=== Summary ===" -ForegroundColor Cyan
    Write-Host "Selected folders: " -NoNewline
    Write-Host $folders.Count -ForegroundColor White
    Write-Host "Finished folders: " -NoNewline
    Write-Host $processedCount -ForegroundColor White
    
    Write-Host "Changed: " -NoNewline
    Write-Host $successCount -ForegroundColor Green
    Write-Host "Skipped: " -NoNewline
    Write-Host $skippedCount -ForegroundColor Yellow
    Write-Host "Failed: " -NoNewline
    Write-Host $failCount -ForegroundColor Red

    if ($userCancelled) {
        Write-Host "Status: cancelled by user before all selected folders were processed." -ForegroundColor Yellow
    }
    
    # Refresh Explorer
    Write-Host "`nRefreshing Explorer windows..." -ForegroundColor Gray
    Refresh-Explorer
    
    if ($MODE -eq "remove") {
        Write-Host "`nDone. Custom icons were removed where possible." -ForegroundColor Cyan
        Write-Host "Next step: refresh File Explorer with F5 if the view does not update." -ForegroundColor White
    }
    else {
        Write-Host "`nDone. Folder icons were updated where possible." -ForegroundColor Cyan
        Write-Host "Next step: refresh File Explorer with F5 if icons do not update." -ForegroundColor White
    }
}

# Run main function
Main

