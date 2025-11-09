# ===== START MENU MANAGER =====
# Two run modes:
#   1. Interactive (no arguments): Shows menu to select READ/SAVE/ENFORCE
#   2. Automated (-Auto flag): Runs ENFORCE mode without prompts (for scheduled tasks)
param(
    [switch]$Auto,                              # Use this flag when running from scheduled task (enforce mode, no prompts)
    [ValidateSet('READ', 'SAVE', 'ENFORCE')]
    [string]$Mode                               # Directly specify mode (skips menu)
)

$target           = "C:\ProgramData\Microsoft\Windows\Start Menu"
$configPath       = "D:\OneDrive\Backups\Start Menu\StartMenuConfig.json"
$logPath          = "D:\OneDrive\Backups\Start Menu\StartMenuManager.log"
$quarantineFolder = "Programs\Unsorted"         # Relative to $target.

# Script-level variables
$script:createdFolders = @{}                    # Cache for folder existence checks (used by Ensure_Folder)

# Determine run mode (use internal $currentMode since parameter validation prevents reassignment to $null)
if ($Auto) {
    $currentMode = "ENFORCE"                    # Automated mode: Run ENFORCE immediately without prompts
    $dryRun = $false
    $interactiveMode = $false
} else {
    # Interactive mode: If -Mode parameter is provided, use it; else it will be null (will show menu)
    $currentMode = $Mode
    $dryRun = $true
    $interactiveMode = $true
}

# ============================================= COMMON UTILITY FUNCTIONS ==========================================

function Show_ModeMenu {
    Write-Host ""
    Write-Host ("="*100) -ForegroundColor Cyan
    Write-Host " START MENU MANAGER - Select Mode" -ForegroundColor Cyan
    Write-Host ("="*100) -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1] READ    - Display current config structure" -ForegroundColor White
    Write-Host "  [2] SAVE    - Save current Start Menu to config" -ForegroundColor White
    Write-Host "  [3] ENFORCE - Organize Start Menu based on config" -ForegroundColor White
    Write-Host "  [4] EXIT    - Exit the script" -ForegroundColor White
    Write-Host ""
    
    # Loop until valid option is selected
    while ($true) {
        Write-Host "Select an option (1-4): " -ForegroundColor Yellow -NoNewline
        
        # Read key and filter out modifier keys (Alt, Ctrl, Shift, etc.)
        do {
            $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            $choice = $key.Character
        } while ($choice -match '[\x00-\x1F]')  # Skip control characters.
                                                # \x00 and \x1F are hexadecimal character codes for 0 and 31 respectively.
                                                # [\x00-\x1F] = matches any character in the range 0-31 (ASCII control characters)
        Write-Host $choice
        
        switch ($choice) {
            '1' { return "READ" }
            '2' { return "SAVE" }
            '3' { return "ENFORCE" }
            '4' { return "EXIT" }
            default { 
                Write-Host "Invalid option. Please try again." -ForegroundColor Red
            }
        }
    }
}

function Write_Log { 
    param([string]$msg, [string]$Color = "White", [switch]$ToScreen)
    # Always write to log file
    $msg | Add-Content -Path $logPath
    # Optionally write to screen with color
    if ($ToScreen) { Write-Host $msg -ForegroundColor $Color }
}

function Get_RelativePath {
    param([string]$fullPath)
    # Convert absolute path to relative path from $target, return "Root" for base folder
    $relPath = $fullPath.Substring($target.Length).TrimStart('\')
    if ([string]::IsNullOrEmpty($relPath)) { return "Root" } else { return $relPath }
}

function Ensure_Folder {
    param([string]$path)
    # Check cache first to avoid repeated disk checks
    if (-not $script:createdFolders.ContainsKey($path)) {                              # $script: = access script-level variable
        if (-not (Test-Path $path)) { 
            New-Item -ItemType Directory -Path $path -Force | Out-Null                 # Create folder, suppress output to console
            Write_Log "**Created folder:** $path"
        } else {
            Write_Log "**Folder already exists:** $path"
        }
        $script:createdFolders[$path] = $true
    }
}

function Normalize_ShortcutName {
    param([string]$name)
    # Strip version/architecture info so "Chrome v120 (64-bit).lnk" becomes "Chrome.lnk"
    # - Remove ["(64-bit)", "(Beta)", etc.], ["v1.2.3", "2025", etc.], ["- Setup" at end], and multiple spaces to one
    $n = $name -replace '\s*\((Preview|Beta|Insiders|64-bit|32-bit|x64|x86)\)', '' `
               -replace '\s*v?\d+(\.\d+)*', '' `
               -replace '\s+-\s+Setup$', '' `
               -replace '\s+', ' '
    $n = $n.Trim()

    # Ensure .lnk suffix remains if present
    if ($n -notmatch '\.lnk$' -and $name -match '\.lnk$') { $n = "$n.lnk" }
    return $n
}

function Get_ShortcutMatchKey {
    param(
        [string]$shortcutName,
        [hashtable]$AllConfigShortcuts,
        [hashtable]$ExpectedMap
    )
    # Determine the correct key to use for looking up expected folder
    $norm = Normalize_ShortcutName $shortcutName
    
    if ($AllConfigShortcuts.ContainsKey($norm) -and $AllConfigShortcuts[$norm].Count -gt 1) {
        # VARIANT CASE: Multiple shortcuts in config normalize to this name
        return $(if ($ExpectedMap.ContainsKey($shortcutName)) { $shortcutName } else { $null })
    } else {
        # NORMAL CASE: No variants exist for this normalized name
        if ($ExpectedMap.ContainsKey($norm)) { 
            return $norm
        } elseif ($ExpectedMap.ContainsKey($shortcutName)) { 
            return $shortcutName
        } else { 
            return $null
        }
    }
}

# ============================================= SAVE MODE FUNCTIONS ============================================
# Functions used only by Invoke_SaveMode

function Scan_StartMenuShortcuts {
    param(
        [string]$TargetPath
    )
    # Scan Start Menu and build tree structure with shortcut details
    
    Write-Host "Scanning Start Menu to generate config file..." -ForegroundColor Cyan
    Write_Log "Scanning Start Menu: $TargetPath"
    
    # Create WScript.Shell COM object to read shortcut targets
    $shell = New-Object -ComObject WScript.Shell
    
    $tree = @{}
    
    # Collect shortcuts grouped by relative folder, including target paths
    Get-ChildItem -Path $TargetPath -Recurse -Filter *.lnk -Force | ForEach-Object {
        $relativePath = $_.DirectoryName.Substring($TargetPath.Length).TrimStart('\')
        $folder = if ([string]::IsNullOrEmpty($relativePath)) { "Root" } else { $relativePath }

        if (-not $tree.ContainsKey($folder)) {
            $tree[$folder] = @{}
        }
        
        # Read shortcut details
        try {
            $shortcut = $shell.CreateShortcut($_.FullName)
            $tree[$folder][$_.Name] = @{
                TargetPath = $shortcut.TargetPath
                Arguments = $shortcut.Arguments
                WorkingDirectory = $shortcut.WorkingDirectory
                IconLocation = $shortcut.IconLocation
                Description = $shortcut.Description
            }
        } catch {
            Write_Log "Warning: Could not read shortcut details for $($_.Name): $_"
            # Still add the shortcut even if we can't read details
            $tree[$folder][$_.Name] = @{}
        }
    }
    
    # Release COM object
    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($shell) | Out-Null
    
    # Add important system folders even if they have no shortcuts
    # This ensures they're preserved in ENFORCE mode
    $systemFolders = @("Programs\Startup")
    foreach ($sysFolder in $systemFolders) {
        if (-not $tree.ContainsKey($sysFolder)) {
            # Check if the folder actually exists before adding
            $sysFolderPath = Join-Path $TargetPath $sysFolder
            if (Test-Path $sysFolderPath) {
                $tree[$sysFolder] = @{}
                Write_Log "Added empty system folder to config: $sysFolder"
            }
        }
    }
    
    # Sort folders alphabetically, and sort shortcuts within each folder
    # Use [ordered] to preserve insertion order when converting to JSON
    $sortedTree = [ordered]@{}
    foreach ($folder in ($tree.Keys | Sort-Object)) {
        $sortedTree[$folder] = [ordered]@{}
        foreach ($shortcutName in ($tree[$folder].Keys | Sort-Object)) {
            $sortedTree[$folder][$shortcutName] = $tree[$folder][$shortcutName]
        }
    }
    
    return $sortedTree
}

function Calculate_ConfigDiff {
    param(
        [PSCustomObject]$OldConfig,
        [PSCustomObject]$NewConfig
    )
    # Compare old and new configs, display differences, return whether changes were found
    
    Write-Host ""
    Write-Host ("="*100) -ForegroundColor Magenta
    Write-Host " CHANGES FROM PREVIOUS CONFIG" -ForegroundColor Magenta
    Write-Host ("="*100) -ForegroundColor Magenta
    Write-Host ""
    Write_Log "`n========== CHANGES FROM PREVIOUS CONFIG =========="
    
    $changesFound = $false
    
    # Check for new/removed folders
    $oldFolders = @($OldConfig.PSObject.Properties.Name)
    $newFolders = @($NewConfig.PSObject.Properties.Name)
    
    $addedFolders = $newFolders | Where-Object { $_ -notin $oldFolders }
    $removedFolders = $oldFolders | Where-Object { $_ -notin $newFolders }
    
    if ($addedFolders.Count -gt 0) {
        $changesFound = $true
        Write_Log "NEW FOLDERS ($($addedFolders.Count)):" -Color Green -ToScreen
        foreach ($folder in ($addedFolders | Sort-Object)) {
            Write_Log "  + $folder" -Color Green -ToScreen
        }
        Write-Host ""
    }
    
    if ($removedFolders.Count -gt 0) {
        $changesFound = $true
        Write_Log "REMOVED FOLDERS ($($removedFolders.Count)):" -Color Red -ToScreen
        foreach ($folder in ($removedFolders | Sort-Object)) {
            Write_Log "  - $folder" -Color Red -ToScreen
        }
        Write-Host ""
    }
    
    # Check for changed shortcuts in common folders
    $commonFolders = $newFolders | Where-Object { $_ -in $oldFolders }
    foreach ($folder in ($commonFolders | Sort-Object)) {
        $oldShortcuts = @($OldConfig.$folder.PSObject.Properties.Name)
        $newShortcuts = @($NewConfig.$folder.PSObject.Properties.Name)
        
        $added = $newShortcuts | Where-Object { $_ -notin $oldShortcuts }
        $removed = $oldShortcuts | Where-Object { $_ -notin $newShortcuts }
        
        if ($added.Count -gt 0 -or $removed.Count -gt 0) {
            $changesFound = $true
            Write-Host "$folder" -ForegroundColor Yellow -NoNewline
            Write-Host " (+$($added.Count) / -$($removed.Count))" -ForegroundColor Gray
            Write_Log "$folder (+$($added.Count) / -$($removed.Count))"
            
            foreach ($sc in ($added | Sort-Object)) {
                Write_Log "      + $sc" -Color Green -ToScreen
            }
            foreach ($sc in ($removed | Sort-Object)) {
                Write_Log "      - $sc" -Color Red -ToScreen
            }
            Write-Host ""
        }
    }
    
    if (-not $changesFound) {
        Write_Log "No changes detected." -Color Gray -ToScreen
        Write-Host ""
    }
    
    Write-Host ("="*100) -ForegroundColor Magenta
    Write-Host ""
    Write_Log "=================================================="
    
    return $changesFound
}

function Save_ConfigFile {
    param(
        [hashtable]$ConfigTree,
        [string]$ConfigPath
    )
    # Save config JSON file and display summary
    
    $folderCount = $ConfigTree.Keys.Count
    $shortcutCount = ($ConfigTree.Values | ForEach-Object { $_.Keys.Count } | Measure-Object -Sum).Sum
    
    Write-Host "Saving config..." -ForegroundColor Cyan
    $ConfigTree | ConvertTo-Json -Depth 10 -Compress:$false | Out-File $ConfigPath -Encoding UTF8
    
    Write-Host "[OK] Config file saved successfully!" -ForegroundColor Green
    Write-Host "  Location: $ConfigPath" -ForegroundColor Gray
    Write-Host "  Folders: $folderCount" -ForegroundColor Gray
    Write-Host "  Shortcuts: $shortcutCount" -ForegroundColor Gray
    Write_Log "Config file written: $ConfigPath - $folderCount folders, $shortcutCount shortcuts"
}

function Create_StartMenuBackup {
    param(
        [string]$TargetPath,
        [string]$ConfigPath
    )
    # Create zip backup of Start Menu folder (including empty folders)
    
    Write-Host "`nCreating backup..." -ForegroundColor Cyan
    $backupPath = Join-Path (Split-Path $ConfigPath -Parent) "StartMenuBackup_$(Get-Date -Format 'yyyyMMdd_HHmmss').zip"
    
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        if (Test-Path $backupPath) { Remove-Item $backupPath -Force }
        [System.IO.Compression.ZipFile]::CreateFromDirectory($TargetPath, $backupPath, [System.IO.Compression.CompressionLevel]::Optimal, $true)
        Write-Host "[OK] Backup created successfully!" -ForegroundColor Green
        Write-Host "  Location: $backupPath" -ForegroundColor Gray
        Write_Log "Backup created: $backupPath"
    } catch {
        Write-Host "[ERROR] Failed to create backup: $_" -ForegroundColor Red
        Write_Log "Failed to create backup: $_"
    }
}

# ============================================= DISPLAY FUNCTIONS ==============================================
# Functions for displaying config structure (used by READ and SAVE modes)

function Display_Config {
    param(
        [PSCustomObject]$Config,
        [string]$Title = "START MENU CONFIGURATION"
    )
    
    # Single pass: collect all data needed for display and totals
    $folderData = @()
    $allShortcutNames = @()
    $totalShortcuts = 0
    
    foreach ($folderKey in ($Config.PSObject.Properties.Name | Sort-Object)) {
        $shortcuts = $Config.$folderKey
        $shortcutNames = @($shortcuts.PSObject.Properties.Name | Sort-Object)
        
        $folderData += @{
            Name = $folderKey
            Shortcuts = $shortcutNames
            Count = $shortcutNames.Count
        }
        
        $allShortcutNames += $shortcutNames
        $totalShortcuts += $shortcutNames.Count
    }
    
    # Display header with totals
    Write-Host ""
    Write-Host ("="*100) -ForegroundColor Cyan
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host ("="*100) -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Total Folders: $($folderData.Count)" -ForegroundColor Gray
    Write-Host "Total Shortcuts: $totalShortcuts" -ForegroundColor Gray
    Write-Host ""
    Write-Host ("="*100) -ForegroundColor Cyan
    Write-Host ""

    # Calculate column layout once for ALL items (ensures alignment across directories)
    $layout = Calculate_ColumnLayout -AllItems $allShortcutNames -IndentSpaces 6
    
    # Display folders with shortcuts
    foreach ($folder in $folderData) {
        Write-Host "  $($folder.Name)" -ForegroundColor Yellow -NoNewline
        Write-Host " ($($folder.Count) shortcuts)" -ForegroundColor Gray
        
        if ($folder.Count -gt 0) {
            Format_InColumns -Items $folder.Shortcuts -IndentSpaces 6 -ColumnWidth $layout.ColumnWidth -NumColumns $layout.NumColumns
        }
        
        Write-Host ""
    }
}

function Calculate_ColumnLayout {
    param(
        [string[]]$AllItems,
        [int]$IndentSpaces = 6,
        [int]$MinColumnWidth = 25,
        [int]$ColumnPadding = 4
    )
    
    # Get console width (force refresh)
    try {
        $consoleWidth = $Host.UI.RawUI.WindowSize.Width
        if ($consoleWidth -le 0) { $consoleWidth = 120 }
    } catch {
        $consoleWidth = 120
    }
    
    # Calculate available width after indent
    $availableWidth = $consoleWidth - $IndentSpaces
    
    # Find the longest item across ALL directories
    $maxItemLength = 0
    foreach ($item in $AllItems) {
        if ($item.Length -gt $maxItemLength) {
            $maxItemLength = $item.Length
        }
    }
    
    # Column width is the max item length plus padding
    $columnWidth = $maxItemLength + $ColumnPadding
    
    # Ensure minimum column width
    if ($columnWidth -lt $MinColumnWidth) { $columnWidth = $MinColumnWidth }
    
    # Calculate how many columns fit
    $numColumns = [Math]::Max(1, [Math]::Floor($availableWidth / $columnWidth))
    
    return @{
        ColumnWidth = $columnWidth
        NumColumns = $numColumns
        ConsoleWidth = $consoleWidth
    }
}

function Format_InColumns {
    param(
        [string[]]$Items,
        [int]$IndentSpaces = 6,
        [int]$ColumnWidth,
        [int]$NumColumns
    )
    
    if ($Items.Count -eq 0) { return }
    
    # Calculate number of rows needed
    $numRows = [Math]::Ceiling($Items.Count / $NumColumns)
    
    # Build and display rows
    $indent = " " * $IndentSpaces
    for ($row = 0; $row -lt $numRows; $row++) {
        $line = $indent
        for ($col = 0; $col -lt $NumColumns; $col++) {
            $index = $row + ($col * $numRows)
            if ($index -lt $Items.Count) {
                $item = $Items[$index]
                # Pad to column width (except last column)
                if ($col -lt ($NumColumns - 1)) {
                    $line += $item.PadRight($ColumnWidth)
                } else {
                    $line += $item
                }
            }
        }
        Write-Host $line -ForegroundColor White
    }
}

# ============================================= ENFORCE MODE FUNCTIONS =========================================
# Functions used only by Invoke_EnforceMode

function Build_ConfigLookupTable {
    param(
        [PSCustomObject]$ConfigRaw,
        [string]$TargetPath
    )
    
    # Problem: Different shortcuts may normalize to the same name after stripping versions/architecture
    # Examples: ODBC 32-bit and ODBC 64-bit both become ODBC.lnk after normalization
    # Solution: Detect when multiple shortcuts normalize to same name, and use full names for those
    $allConfigShortcuts = @{}      # Temporary: normalized name -> array of original names
    $expectedMap = @{}             # Final lookup: shortcut name -> folder
    $shortcutDetailsMap = @{}      # Map of shortcut -> details for recreation
    
    # PASS 1: Group all shortcuts by normalized name to detect collisions
    foreach ($folderKey in $ConfigRaw.PSObject.Properties.Name) {
        $shortcuts = $ConfigRaw.$folderKey
        foreach ($sc in $shortcuts.PSObject.Properties.Name) {
            $norm = Normalize_ShortcutName $sc
            if (-not $allConfigShortcuts.ContainsKey($norm)) {
                $allConfigShortcuts[$norm] = @()
            }
            $allConfigShortcuts[$norm] += @{Original = $sc; Folder = $folderKey}
            
            # Store details for later use (for recreation)
            $shortcutDetailsMap["$folderKey\$sc"] = $shortcuts.$sc
        }
    }
    
    # PASS 2: Build final lookup map, using full names for variants, normalized names for others
    foreach ($folderKey in $ConfigRaw.PSObject.Properties.Name) {
        if ($folderKey -ne "Root" -and -not [string]::IsNullOrEmpty($folderKey)) {
            Ensure_Folder (Join-Path $TargetPath $folderKey)
        }
        
        $shortcuts = $ConfigRaw.$folderKey
        foreach ($sc in $shortcuts.PSObject.Properties.Name) {
            $norm = Normalize_ShortcutName $sc
            
            # Decide what key to use in $expectedMap
            if ($allConfigShortcuts[$norm].Count -gt 1) {
                $keyToUse = $sc  # Use full original name for variants
            } else {
                $keyToUse = $norm  # Use normalized name for unique shortcuts
            }
            
            if ($expectedMap.ContainsKey($keyToUse)) {
                Write_Log "**Config duplicate:** $keyToUse (folder $($expectedMap[$keyToUse]) vs $folderKey)"
            }
            $expectedMap[$keyToUse] = $folderKey
        }
    }
    
    return @{
        AllConfigShortcuts = $allConfigShortcuts
        ExpectedMap = $expectedMap
        ShortcutDetailsMap = $shortcutDetailsMap
    }
}

function Scan_AndOrganizeShortcuts {
    param(
        [string]$TargetPath,
        [hashtable]$AllConfigShortcuts,
        [hashtable]$ExpectedMap,
        [string]$QuarantineFolder
    )
    
    Write-Host "Scanning shortcuts at $TargetPath..." -ForegroundColor Cyan
    $allShortcuts = Get-ChildItem -Path $TargetPath -Recurse -Filter *.lnk -Force
    
    $actualIndex = @{}
    $processed = @{}
    $plannedMoves = [System.Collections.Generic.List[hashtable]]::new()
    $plannedDeletes = [System.Collections.Generic.List[hashtable]]::new()
    $foldersToCheck = @{}

    Write-Host "Processing $(($allShortcuts | Measure-Object).Count) shortcuts..." -ForegroundColor Cyan

    foreach ($item in $allShortcuts) {
        $norm = Normalize_ShortcutName $item.Name
        
        # Get match key using helper function
        $matchKey = Get_ShortcutMatchKey -shortcutName $item.Name `
        -AllConfigShortcuts $AllConfigShortcuts -ExpectedMap $ExpectedMap
    
        # For duplicate detection, use the match key
        $indexKey = if ($matchKey -and $matchKey -eq $item.Name) { $item.Name } else { $norm }
    
        # Check for unexpected duplicates
        if ($actualIndex.ContainsKey($indexKey)) {
            $existing = $actualIndex[$indexKey]
            Write_Log "Duplicate found: '$($item.Name)' at $($item.DirectoryName) clashes with '$($existing.Name)' at $($existing.DirectoryName) (both normalize to '$norm')"
                
            # Get correct folder from config using helper function
            $correctFolder = if ($matchKey -and $ExpectedMap.ContainsKey($matchKey)) {
                $ExpectedMap[$matchKey]
            } else {
                $existingKey = Get_ShortcutMatchKey -shortcutName $existing.Name `
                    -AllConfigShortcuts $AllConfigShortcuts -ExpectedMap $ExpectedMap
                if ($existingKey -and $ExpectedMap.ContainsKey($existingKey)) { $ExpectedMap[$existingKey] } else { $null }
            }
            
            # Compare locations
            $itemFolder = Get_RelativePath $item.DirectoryName
            $existingFolder = Get_RelativePath $existing.DirectoryName
            
            # Delete the one in wrong location
            if ($correctFolder) {
                if ($itemFolder -ne $correctFolder) {
                    Write_Log "  -> Deleting duplicate from wrong location: '$($item.Name)' at $itemFolder (correct: $correctFolder)"
                    $plannedDeletes.Add(@{ Path = $item.FullName; Name = $item.Name; Folder = $itemFolder; CorrectFolder = $correctFolder })
                    $foldersToCheck[$item.DirectoryName] = $true
                    continue
                } elseif ($existingFolder -ne $correctFolder) {
                    Write_Log "  -> Deleting duplicate from wrong location: '$($existing.Name)' at $existingFolder (correct: $correctFolder)"
                    $plannedDeletes.Add(@{ Path = $existing.FullName; Name = $existing.Name; Folder = $existingFolder; CorrectFolder = $correctFolder })
                    $foldersToCheck[$existing.DirectoryName] = $true
                    $actualIndex[$indexKey] = $item
                }
            } else {
                Write_Log "  -> Neither duplicate matches config. Deleting second: '$($item.Name)'"
                $plannedDeletes.Add(@{ Path = $item.FullName; Name = $item.Name; Folder = $itemFolder; CorrectFolder = "Unknown" })
                $foldersToCheck[$item.DirectoryName] = $true
                continue
            }
        }
        $actualIndex[$indexKey] = $item
    
        if ($matchKey) {
            # KNOWN SHORTCUT: Move to correct folder
            $relFolder = $ExpectedMap[$matchKey]
            $destFolder = if ($relFolder -eq "Root" -or [string]::IsNullOrEmpty($relFolder)) {
                $TargetPath
            } else {
                Join-Path $TargetPath $relFolder
            }
            $destPath = Join-Path $destFolder $item.Name
            
            # Only move if it's not already in the right place
            if ($item.FullName -ne $destPath) {
                $currentFolder = Get_RelativePath $item.DirectoryName
                $plannedMoves.Add(@{
                    Type = "Move"
                    Source = $item.FullName
                    Destination = $destPath
                    Name = $item.Name
                    CurrentFolder = $currentFolder
                    DestFolder = $relFolder
                })
                $foldersToCheck[$item.DirectoryName] = $true
            }
            $processed[$matchKey] = $true
        } else {
            # UNKNOWN SHORTCUT: Quarantine
            $currentFolder = Get_RelativePath $item.DirectoryName
            $qDest = Join-Path $TargetPath $QuarantineFolder | Join-Path -ChildPath $item.Name
            
            if ($item.FullName -ne $qDest) {
                $plannedMoves.Add(@{
                    Type = "Quarantine"
                    Source = $item.FullName
                    Destination = $qDest
                    Name = $item.Name
                    CurrentFolder = $currentFolder
                    DestFolder = $QuarantineFolder
                })
            }
        }
    }
    
    return @{
        PlannedMoves = $plannedMoves
        PlannedDeletes = $plannedDeletes
        Processed = $processed
        FoldersToCheck = $foldersToCheck
    }
}

function Detect_MissingShortcuts {
    param(
        [hashtable]$ExpectedMap,
        [hashtable]$Processed,
        [hashtable]$ShortcutDetailsMap
    )
    
    $missingShortcuts = [System.Collections.Generic.List[hashtable]]::new()
    $seenMissing = @{}  # Track to avoid duplicates
    
    foreach ($normName in $ExpectedMap.Keys) {
        if (-not $Processed.ContainsKey($normName)) {
            $expectedFolder = $ExpectedMap[$normName]
            $uniqueKey = "$expectedFolder\$normName"
            
            # Skip if already processed
            if ($seenMissing.ContainsKey($uniqueKey)) {
                continue
            }
            $seenMissing[$uniqueKey] = $true
            
            Write_Log "**Missing expected shortcut:** $normName (expected in $expectedFolder)"
            
            $detailKey = "$expectedFolder\$normName"
            $details = $ShortcutDetailsMap[$detailKey]
            
            if ($details -and $details.TargetPath) {
                $missingShortcuts.Add(@{
                    Name = $normName
                    Folder = $expectedFolder
                    Details = $details
                })
            } else {
                Write_Log "  Cannot recreate - no saved details for $normName"
            }
        }
    }
    
    return $missingShortcuts
}

function Detect_EmptyFolders {
    param(
        [string]$TargetPath,
        [PSCustomObject]$ConfigRaw,
        $PlannedMoves = @()
    )
    
    $emptyFoldersToDelete = [System.Collections.Generic.List[hashtable]]::new()
    
    # Build set of expected folders from config
    $expectedFolders = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($folderKey in $ConfigRaw.PSObject.Properties.Name) {
        if ($folderKey -ne "Root" -and -not [string]::IsNullOrEmpty($folderKey)) {
            $folderPath = Join-Path $TargetPath $folderKey
            $expectedFolders.Add($folderPath) | Out-Null
        }
    }
    
    # Build sets of folders being emptied/filled by moves
    $foldersBeingEmptied = @{}
    $foldersReceivingFiles = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    
    foreach ($move in @($PlannedMoves)) {
        # Track source folders losing files
        $sourceFolder = Split-Path $move.Source -Parent
        if (-not $foldersBeingEmptied.ContainsKey($sourceFolder)) {
            $foldersBeingEmptied[$sourceFolder] = @()
        }
        $foldersBeingEmptied[$sourceFolder] += $move.Source
        
        # Track destination folders receiving files
        $destFolder = Split-Path $move.Destination -Parent
        $foldersReceivingFiles.Add($destFolder) | Out-Null
    }
    
    # Scan ALL folders (deepest first for proper deletion order)
    $allFolders = Get-ChildItem -Path $TargetPath -Directory -Recurse -Force -ErrorAction SilentlyContinue | 
        Sort-Object { $_.FullName.Split('\').Count } -Descending
    
    foreach ($folder in $allFolders) {
        try {
            # Skip if it's an expected folder (preserved even if empty)
            if ($expectedFolders.Contains($folder.FullName)) {
                continue
            }
            
            # Skip if this folder is receiving files from moves (won't be empty)
            if ($foldersReceivingFiles.Contains($folder.FullName)) {
                continue
            }
            
            # Check if folder is currently empty
            $items = Get-ChildItem -Path $folder.FullName -Force -ErrorAction SilentlyContinue
            $currentCount = if ($null -eq $items) { 0 } else { $items.Count }
            
            $willBeEmpty = $false
            
            if ($currentCount -eq 0) {
                $willBeEmpty = $true
            } elseif ($foldersBeingEmptied.ContainsKey($folder.FullName)) {
                # Check if ALL items in this folder are being moved out
                $movingOut = $foldersBeingEmptied[$folder.FullName]
                $allItemPaths = $items | ForEach-Object { $_.FullName }
                
                # If all items are in the moving-out list, folder will be empty
                $remaining = $allItemPaths | Where-Object { $_ -notin $movingOut }
                if ($remaining.Count -eq 0) {
                    $willBeEmpty = $true
                }
            }
            
            if ($willBeEmpty) {
                $relPath = Get_RelativePath $folder.FullName
                Write_Log "Empty folder found: $relPath"
                $emptyFoldersToDelete.Add(@{
                    Path = $folder.FullName
                    DisplayFolder = $relPath
                })
            }
        } catch {
            # Ignore errors during scanning
        }
    }
    
    return $emptyFoldersToDelete
}

function Display_EnforcePreview {
    param(
        $PlannedMoves,
        $PlannedDeletes,
        $EmptyFoldersToDelete,
        $MissingShortcuts,
        [bool]$DryRun
    )
    
    # If dry-run mode, show summary and ask for confirmation
    if ($DryRun) {
        Write-Host ""
        Write-Host ("="*70) -ForegroundColor Cyan
        Write-Host " SUMMARY - Planned Changes" -ForegroundColor Cyan
        Write-Host ("="*70) -ForegroundColor Cyan
        Write-Host ""
    
        # Show moves (wrap in @() to prevent unwrapping single items)
        $toMove = @($PlannedMoves | Where-Object { $_.Type -eq "Move" })
        if ($toMove.Count -gt 0) {
            Write_Log "MOVES TO CORRECT FOLDERS ($($toMove.Count)):" -Color Green -ToScreen
            foreach ($move in $toMove) {
                Write-Host "  ➡️ " -NoNewline -ForegroundColor Green
                Write-Host "$($move.Name.PadRight(35)) " -NoNewline -ForegroundColor White
                Write-Host "$("[Move]".PadRight(20)) " -NoNewline -ForegroundColor Green
                Write-Host "FROM: " -NoNewline -ForegroundColor DarkGray
                Write-Host "$($move.CurrentFolder.PadRight(30)) " -NoNewline -ForegroundColor Gray
                Write-Host "-> TO: " -NoNewline -ForegroundColor DarkGray
                Write-Host "$($move.DestFolder)" -ForegroundColor Gray
                Write_Log "  - $($move.Name) FROM: $($move.CurrentFolder) -> TO: $($move.DestFolder)"
            }
            Write-Host ""
        }
    
        # Show quarantines (wrap in @() to prevent unwrapping single items)
        $toQuarantine = @($PlannedMoves | Where-Object { $_.Type -eq "Quarantine" })
        if ($toQuarantine.Count -gt 0) {
            Write_Log "UNKNOWN SHORTCUTS TO QUARANTINE ($($toQuarantine.Count)):" -Color Yellow -ToScreen
            foreach ($move in $toQuarantine) {
                Write-Host "  🥅 " -NoNewline -ForegroundColor Yellow
                Write-Host "$($move.Name.PadRight(35)) " -NoNewline -ForegroundColor White
                Write-Host "$("[Quarantine]".PadRight(20)) " -NoNewline -ForegroundColor Yellow
                Write-Host "FROM: " -NoNewline -ForegroundColor DarkGray
                Write-Host "$($move.CurrentFolder.PadRight(30)) " -NoNewline -ForegroundColor Gray
                Write-Host "-> TO: " -NoNewline -ForegroundColor DarkGray
                Write-Host "$($move.DestFolder)" -ForegroundColor Gray
                Write_Log "  - $($move.Name) FROM: $($move.CurrentFolder) -> TO: $($move.DestFolder)"
            }
            Write-Host ""
        }
        
        # Show deletes
        if ($PlannedDeletes.Count -gt 0) {
            Write_Log "DUPLICATE SHORTCUTS TO DELETE ($($PlannedDeletes.Count)):" -Color Red -ToScreen
            foreach ($delete in $PlannedDeletes) {
                Write_Log "  - $($delete.Name) at $($delete.Folder)" -Color Red -ToScreen
            }
            Write-Host ""
        }
        
        # Show empty folders (wrap in @() to handle single items correctly)
        if ($EmptyFoldersToDelete.Count -gt 0) {
            Write_Log "EMPTY FOLDERS TO DELETE ($($EmptyFoldersToDelete.Count)):" -Color Magenta -ToScreen
            foreach ($folder in @($EmptyFoldersToDelete)) {
                Write-Host "  🗑️ " -NoNewline -ForegroundColor Magenta
                Write-Host "$($folder.DisplayFolder.PadRight(35)) " -NoNewline -ForegroundColor Magenta
                Write-Host "$("[Delete]".PadRight(20))" -ForegroundColor Magenta
                Write_Log "  - $($folder.DisplayFolder)"
            }
            Write-Host ""
        }
        
        # Show missing shortcuts to recreate
        if ($MissingShortcuts.Count -gt 0) {
            Write_Log "MISSING SHORTCUTS TO RECREATE ($($MissingShortcuts.Count)):" -Color Cyan -ToScreen
            foreach ($missing in $MissingShortcuts) {
                Write-Host "  ➕ " -NoNewline -ForegroundColor Cyan
                Write-Host "$($missing.Name.PadRight(35)) " -NoNewline -ForegroundColor White
                Write-Host "$("[Recreate]".PadRight(20)) " -NoNewline -ForegroundColor Cyan
                Write-Host "IN: " -NoNewline -ForegroundColor DarkGray
                Write-Host "$($missing.Folder)" -ForegroundColor Gray
                Write_Log "  - $($missing.Name) IN: $($missing.Folder)"
            }
            Write-Host ""
        }
        
        Write-Host ("="*70) -ForegroundColor Cyan
        
        # Ask for confirmation
        $response = Read-Host "Do you want to proceed with these changes? (Y/N)"
        return ($response -eq 'Y' -or $response -eq 'y')
    }
    
    return $true  # Automated mode, proceed
}

function Execute_ShortcutMoves {
    param(
        $PlannedMoves,
        [ref]$SuccessCount,
        [ref]$ErrorCount
    )
    
    if ($PlannedMoves.Count -eq 0) { return }
    
    foreach ($move in $PlannedMoves) {
        try {
            # Ensure destination folder exists
            $destFolder = Split-Path $move.Destination -Parent
            Ensure_Folder $destFolder
            
            # Use PowerShell Move-Item (requires admin privileges)
            Move-Item -Path $move.Source -Destination $move.Destination -Force -ErrorAction Stop
            
            # Determine operation emoji and type based on move type
            $emoji = if ($move.Type -eq "Quarantine") { "🥅" } else { "➡️" }
            $operation = if ($move.Type -eq "Quarantine") { "[Quarantine]" } else { "[Move]" }
            
            # Print compact success line with operation-specific emoji, alignment, and status at end
            Write-Host "  $emoji " -NoNewline -ForegroundColor Green
            Write-Host "$($move.Name.PadRight(35)) " -NoNewline -ForegroundColor White
            Write-Host "$($operation.PadRight(20)) " -NoNewline -ForegroundColor Green
            Write-Host "FROM: " -NoNewline -ForegroundColor DarkGray
            Write-Host "$($move.CurrentFolder.PadRight(30)) " -NoNewline -ForegroundColor Gray
            Write-Host "-> TO: " -NoNewline -ForegroundColor DarkGray
            Write-Host "$($move.DestFolder.PadRight(30)) " -NoNewline -ForegroundColor Gray
            Write-Host "✅" -ForegroundColor Green
            
            Write_Log "$($move.Type): $($move.Name) from $($move.CurrentFolder) to $($move.DestFolder)"
            $SuccessCount.Value++
        } catch {
            # Print compact error line with status at end
            $emoji = if ($move.Type -eq "Quarantine") { "🥅" } else { "➡️" }
            $operation = if ($move.Type -eq "Quarantine") { "[Quarantine]" } else { "[Move]" }
            Write-Host "  $emoji " -NoNewline
            Write-Host "$($move.Name.PadRight(35)) " -NoNewline -ForegroundColor White
            Write-Host "$($operation.PadRight(20)) " -NoNewline -ForegroundColor Red
            Write-Host "FROM: " -NoNewline -ForegroundColor DarkGray
            Write-Host "$($move.CurrentFolder.PadRight(30)) " -NoNewline -ForegroundColor Gray
            Write-Host "-> TO: " -NoNewline -ForegroundColor DarkGray
            Write-Host "$($move.DestFolder.PadRight(30)) " -NoNewline -ForegroundColor Gray
            Write-Host "❌" -ForegroundColor Red
            
            Write_Log "$($move.Type) failed: $($move.Name) - $_"
            $ErrorCount.Value++
        }
    }
}

function Execute_ShortcutRecreations {
    param(
        $MissingShortcuts,
        [string]$TargetPath,
        [ref]$SuccessCount,
        [ref]$ErrorCount
    )
    
    if ($MissingShortcuts.Count -eq 0) { return }
    
    $shell = New-Object -ComObject WScript.Shell
    
    foreach ($missing in $MissingShortcuts) {
        try {
            $folder = if ($missing.Folder -eq "Root" -or [string]::IsNullOrEmpty($missing.Folder)) {
                $TargetPath
            } else {
                Join-Path $TargetPath $missing.Folder
            }
            Ensure_Folder $folder
            
            $shortcutPath = Join-Path $folder $missing.Name
            
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = $missing.Details.TargetPath
            if ($missing.Details.Arguments) { $shortcut.Arguments = $missing.Details.Arguments }
            if ($missing.Details.WorkingDirectory) { $shortcut.WorkingDirectory = $missing.Details.WorkingDirectory }
            if ($missing.Details.IconLocation) { $shortcut.IconLocation = $missing.Details.IconLocation }
            if ($missing.Details.Description) { $shortcut.Description = $missing.Details.Description }
            $shortcut.Save()
            
            # Print compact success line with recreation emoji, alignment, and status at end
            Write-Host "  ➕ " -NoNewline -ForegroundColor Cyan
            Write-Host "$($missing.Name.PadRight(35)) " -NoNewline -ForegroundColor White
            Write-Host "$("[Recreate]".PadRight(20)) " -NoNewline -ForegroundColor Cyan
            Write-Host "IN: " -NoNewline -ForegroundColor DarkGray
            Write-Host "$($missing.Folder.PadRight(61)) " -NoNewline -ForegroundColor Gray
            Write-Host "✅" -ForegroundColor Green
            
            Write_Log "Recreated: $($missing.Name) in $($missing.Folder)"
            $SuccessCount.Value++
        } catch {
            # Print compact error line with status at end
            Write-Host "  ➕ " -NoNewline
            Write-Host "$($missing.Name.PadRight(35)) " -NoNewline -ForegroundColor White
            Write-Host "$("[Recreate]".PadRight(20)) " -NoNewline -ForegroundColor Red
            Write-Host "IN: " -NoNewline -ForegroundColor DarkGray
            Write-Host "$($missing.Folder.PadRight(61)) " -NoNewline -ForegroundColor Gray
            Write-Host "❌" -ForegroundColor Red
            
            Write_Log "Recreate failed: $($missing.Name) - $_"
            $ErrorCount.Value++
        }
    }
    
    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($shell) | Out-Null
}

function Execute_FolderDeletes {
    param(
        $EmptyFoldersToDelete,
        [ref]$SuccessCount,
        [ref]$ErrorCount
    )
    
    if ($EmptyFoldersToDelete.Count -eq 0) { return }
    
    foreach ($folder in $EmptyFoldersToDelete) {
        try {
            # Double-check folder is still empty before deletion
            $items = Get-ChildItem -Path $folder.Path -Force -ErrorAction SilentlyContinue
            if ($null -eq $items -or $items.Count -eq 0) {
                Remove-Item -Path $folder.Path -Force -ErrorAction Stop
                
                # Print compact success line with deletion emoji, alignment, and status at end
                Write-Host "  🗑️ " -NoNewline -ForegroundColor Magenta
                Write-Host "$($folder.DisplayFolder.PadRight(35)) " -NoNewline -ForegroundColor Magenta
                Write-Host "$("[Delete]".PadRight(20)) " -NoNewline -ForegroundColor Magenta
                Write-Host " ".PadRight(62) -NoNewline
                Write-Host "✅" -ForegroundColor Green
                
                Write_Log "Deleted empty folder: $($folder.DisplayFolder)"
                $SuccessCount.Value++
            } else {
                # Print compact skip line with delete emoji in first column, warning in last
                Write-Host "  🗑️  " -NoNewline -ForegroundColor Magenta
                Write-Host "$($folder.DisplayFolder.PadRight(35)) " -NoNewline -ForegroundColor Magenta
                Write-Host "$("[Delete]".PadRight(20)) " -NoNewline -ForegroundColor Yellow
                Write-Host " ".PadRight(62) -NoNewline
                Write-Host "⚠️" -ForegroundColor Yellow
                
                Write_Log "Skipped deletion (folder not empty): $($folder.DisplayFolder)"
            }
        } catch {
            # Print compact error line with delete emoji in first column, error in last
            Write-Host "  🗑️  " -NoNewline -ForegroundColor Magenta
            Write-Host "$($folder.DisplayFolder.PadRight(35)) " -NoNewline -ForegroundColor Magenta
            Write-Host "$("[Delete]".PadRight(20)) " -NoNewline -ForegroundColor Red
            Write-Host " ".PadRight(62) -NoNewline
            Write-Host "❌" -ForegroundColor Red
            
            Write_Log "Error deleting folder: $($folder.DisplayFolder) - $_"
            $ErrorCount.Value++
        }
    }
}

# =============================================================================================================
# ============================================= MODE ENTRY POINTS =============================================
# =============================================================================================================
# Main mode orchestration functions

function Invoke_SaveMode {
    # Load old config if it exists (for diff)
    $oldConfig = $null
    if (Test-Path $configPath) {
        try {
            $oldConfig = Get-Content $configPath -Raw | ConvertFrom-Json
            Write_Log "Loaded existing config for comparison"
        } catch {
            Write_Log "Warning: Could not load existing config for comparison: $_"
        }
    }
    
    # Scan Start Menu and build configuration tree
    $sortedTree = Scan_StartMenuShortcuts -TargetPath $target
    
    # Convert to PSCustomObject for diff comparison (must go through JSON to properly convert nested hashtables)
    $newConfig = $sortedTree | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    
    # Show differences if old config exists
    $changesFound = $false
    if ($oldConfig) {
        $changesFound = Calculate_ConfigDiff -OldConfig $oldConfig -NewConfig $newConfig
    }
    
    # Ask for confirmation if there are changes and in dry-run mode
    $proceed = $true
    if ($changesFound -and $dryRun) {
        Write-Host ("="*100) -ForegroundColor Cyan
        $response = Read-Host "Do you want to save these changes? (Y/N)"
        $proceed = ($response -eq 'Y' -or $response -eq 'y')
        Write-Host ""
    }
    
    if (-not $proceed) {
        Write_Log "Save operation cancelled by user" -Color Yellow -ToScreen
        return
    }
    
    # Save config file
    Save_ConfigFile -ConfigTree $sortedTree -ConfigPath $configPath
    
    # Create backup
    Create_StartMenuBackup -TargetPath $target -ConfigPath $configPath
    
    # Display the saved configuration
    Write-Host ""
    $savedConfig = Get-Content $configPath -Raw | ConvertFrom-Json
    Display_Config -Config $savedConfig -Title "SAVED CONFIGURATION"
}

function Invoke_ReadMode {
    if (-not (Test-Path $configPath)) { throw "Config not found: $configPath" }
    
    Write-Host "Reading config file..." -ForegroundColor Cyan
    Write_Log "Reading config: $configPath"
    
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    
    Write-Host "Config File: $configPath" -ForegroundColor Gray
    Display_Config -Config $config
    
    Write_Log "Displayed config structure"
}


function Invoke_EnforceMode {
    if (-not (Test-Path $configPath)) { throw "Config not found: $configPath" }
    
    $configRaw = Get-Content $configPath -Raw | ConvertFrom-Json
    
    # Build config lookup tables
    $configData = Build_ConfigLookupTable -ConfigRaw $configRaw -TargetPath $target
    
    # Scan and organize shortcuts
    $scanResults = Scan_AndOrganizeShortcuts -TargetPath $target `
        -AllConfigShortcuts $configData.AllConfigShortcuts `
        -ExpectedMap $configData.ExpectedMap `
        -QuarantineFolder $quarantineFolder
    
    # Detect missing shortcuts that need recreation
    $missingShortcuts = Detect_MissingShortcuts -ExpectedMap $configData.ExpectedMap `
        -Processed $scanResults.Processed `
        -ShortcutDetailsMap $configData.ShortcutDetailsMap
    
    # Detect empty folders (pass planned moves to detect folders that will become empty)
    $emptyFoldersToDelete = Detect_EmptyFolders -TargetPath $target -ConfigRaw $configRaw -PlannedMoves $scanResults.PlannedMoves
    
    # Check if there are any changes
    $hasChanges = ($scanResults.PlannedMoves.Count -gt 0 -or $scanResults.PlannedDeletes.Count -gt 0 -or `
                   $emptyFoldersToDelete.Count -gt 0 -or $missingShortcuts.Count -gt 0)
    
    if (-not $hasChanges) {
        Write_Log "No changes needed - all shortcuts are already in correct locations!" -Color Green -ToScreen
        return
    }
    
    # Display preview and get confirmation
    # Use @() to prevent PowerShell from unwrapping single-item collections
    $proceed = Display_EnforcePreview -PlannedMoves $scanResults.PlannedMoves `
        -PlannedDeletes $scanResults.PlannedDeletes `
        -EmptyFoldersToDelete $emptyFoldersToDelete `
        -MissingShortcuts @($missingShortcuts) `
        -DryRun $dryRun
    
    # If user cancelled, exit early
    if (-not $proceed) {
        Write_Log "Operation cancelled by user" -Color Yellow -ToScreen
        return
    }
    
    # Execute all changes
    Write-Host ""
    Write-Host ("="*70) -ForegroundColor Green
    Write-Host " EXECUTION" -ForegroundColor Green
    Write-Host ("="*70) -ForegroundColor Green

    $successCount = 0
    $errorCount = 0

    # Execute moves
    Execute_ShortcutMoves -PlannedMoves $scanResults.PlannedMoves `
        -SuccessCount ([ref]$successCount) -ErrorCount ([ref]$errorCount)
    
    # Execute recreations (use @() to prevent unwrapping single-item collections)
    Execute_ShortcutRecreations -MissingShortcuts @($missingShortcuts) `
        -TargetPath $target `
        -SuccessCount ([ref]$successCount) -ErrorCount ([ref]$errorCount)
    
    # Execute folder deletes (use @() to prevent unwrapping single-item collections)
    Execute_FolderDeletes -EmptyFoldersToDelete @($emptyFoldersToDelete) `
        -SuccessCount ([ref]$successCount) -ErrorCount ([ref]$errorCount)
    
    Write-Host ""
    
    # Summary
    Write-Host ""
    Write_Log "`nCompleted! $successCount successful, $errorCount errors." -Color $(if ($errorCount -eq 0) { "Green" } else { "Yellow" }) -ToScreen
    Write_Log "See log: $logPath" -Color Gray -ToScreen
}

# =============================================================================================================
# ============================================= MAIN LOOP =====================================================
# =============================================================================================================
while ($true) {
    # Show interactive menu if needed (only if mode not already set)
    if ($interactiveMode -and -not $currentMode) {
        $currentMode = Show_ModeMenu
        if ($currentMode -eq "EXIT") {
            exit 0
        }
    }
    
    # Auto-elevate if not running as administrator (required for ENFORCE mode)
    if ($currentMode -eq "ENFORCE") {
        $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        
        if (-not $isAdmin) {
            Write-Host "Administrator privileges required. Elevating..." -ForegroundColor Yellow
            
            # Detect current PowerShell executable
            $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
            
            # Build arguments - pass the current mode so elevated window doesn't show menu
            $scriptArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Mode', $currentMode)
            
            # Elevate PowerShell (opens in new window, runs in the selected mode with preview)
            Start-Process $psExe -ArgumentList $scriptArgs -Verb RunAs
            
            exit 0
        }
    }
    
    # Initialize for current run
    Write_Log "`n============================== $(Get-Date) ==============================`n"
    Write_Log "MODE: $currentMode, $(if ($interactiveMode) { 'MANUAL' } else { 'AUTOMATED' })" -Color Cyan -ToScreen
    Write-Host ""
    
    if (-not (Test-Path $target)) { throw "Target not found: $target" }
    
    # Execute selected mode
    switch ($currentMode) {
        "SAVE"    { Invoke_SaveMode }
        "READ"    { Invoke_ReadMode }
        "ENFORCE" { Invoke_EnforceMode }
    }
    
    # After mode completes: loop back to menu (interactive) or exit (automated)
    if (-not $interactiveMode) {
        break  # Exit in automated mode
    }
    # In interactive mode: reset mode so menu shows again, then loop continues
    $currentMode = $null
}
