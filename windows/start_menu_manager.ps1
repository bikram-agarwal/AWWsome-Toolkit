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
$script:normalizeCache = @{}                    # Cache for normalized shortcut names (performance optimization)
$script:consoleWidth = try { $Host.UI.RawUI.WindowSize.Width } catch { 120 }  # Cache console width

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
    if (-not $script:createdFolders.ContainsKey($path)) {
        if (-not (Test-Path $path)) { 
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            Write_Log "**Created folder:** $path"
        }
        # Only log on creation, not on "already exists" (reduces I/O significantly)
        $script:createdFolders[$path] = $true
    }
}

function Normalize_ShortcutName {
    param([string]$name)
    
    # Check cache first (optimization: avoid repeated regex operations)
    if ($script:normalizeCache.ContainsKey($name)) {
        return $script:normalizeCache[$name]
    }
    
    # Strip version/architecture info so "Chrome v120 (64-bit).lnk" becomes "Chrome.lnk"
    # - Remove ["(64-bit)", "(Beta)", etc.], ["v1.2.3", "2025", etc.], ["- Setup" at end], and multiple spaces to one
    $n = $name -replace '\s*\((Preview|Beta|Insiders|64-bit|32-bit|x64|x86)\)', '' `
               -replace '\s*v?\d+(\.\d+)*', '' `
               -replace '\s+-\s+Setup$', '' `
               -replace '\s+', ' '
    $n = $n.Trim()

    # Ensure .lnk suffix remains if present
    if ($n -notmatch '\.lnk$' -and $name -match '\.lnk$') { $n = "$n.lnk" }
    
    # Cache result
    $script:normalizeCache[$name] = $n
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

function Format_ActionLine {
    param(
        [string]$Emoji,
        [string]$Name,
        [string]$Operation,
        [string]$Source = "",
        [string]$Destination = "",
        [string]$StatusEmoji = "",
        [string]$EmojiColor = "White",
        [string]$OperationColor = "White"
    )
    # Optimized: Build formatted line with consistent column widths
    
    $line = "  $Emoji $($Name.PadRight(35)) $($Operation.PadRight(20))"
    
    # Build the middle section (paths) with fixed total width for alignment
    $middleSection = ""
    if ($Source) {
        $middleSection = " FROM: $($Source.PadRight(25)) -> TO: $Destination"
    } elseif ($Destination) {
        $middleSection = " IN: $Destination"
    }
    
    # Pad middle section to fixed width (60 chars) to align status emojis
    $line += $middleSection.PadRight(60)
    
    if ($StatusEmoji) {
        $line += " $StatusEmoji"
    }
    
    return $line
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
    
    # Check PowerShell version for parallel processing capability
    $canUseParallel = $PSVersionTable.PSVersion.Major -ge 7
    
    if ($canUseParallel) {
        # PowerShell 7+: Use parallel processing for faster scanning (especially with 100+ shortcuts)
        Write-Host "Using parallel processing for faster scanning..." -ForegroundColor Gray
        
        $shortcuts = Get-ChildItem -Path $TargetPath -Recurse -Filter *.lnk -File -Force
        
        # Thread-safe collection for results
        $results = [System.Collections.Concurrent.ConcurrentBag[hashtable]]::new()
        
        $shortcuts | ForEach-Object -Parallel {
            $targetPath = $using:TargetPath
            $item = $_
            
            # Each thread creates its own COM object (COM objects can't be shared)
            $shell = New-Object -ComObject WScript.Shell
            
            try {
                $relativePath = $item.DirectoryName.Substring($targetPath.Length).TrimStart('\')
                $folder = if ([string]::IsNullOrEmpty($relativePath)) { "Root" } else { $relativePath }
                
                # Read shortcut details
                try {
                    $shortcut = $shell.CreateShortcut($item.FullName)
                    $details = @{
                        Folder = $folder
                        Name = $item.Name
                        TargetPath = $shortcut.TargetPath
                        Arguments = $shortcut.Arguments
                        WorkingDirectory = $shortcut.WorkingDirectory
                        IconLocation = $shortcut.IconLocation
                        Description = $shortcut.Description
                    }
                } catch {
                    # Still add the shortcut even if we can't read details
                    $details = @{
                        Folder = $folder
                        Name = $item.Name
                    }
                }
                
                ($using:results).Add($details)
            } finally {
                # Release COM object
                [System.Runtime.Interopservices.Marshal]::ReleaseComObject($shell) | Out-Null
            }
        } -ThrottleLimit 5
        
        # Build tree from results
        $tree = @{}
        foreach ($result in $results) {
            $folder = $result.Folder
            $name = $result.Name
            
            if (-not $tree.ContainsKey($folder)) {
                $tree[$folder] = @{}
            }
            
            # Extract shortcut properties (everything except Folder and Name)
            $properties = @{}
            foreach ($key in $result.Keys) {
                if ($key -notin @('Folder', 'Name')) {
                    $properties[$key] = $result[$key]
                }
            }
            $tree[$folder][$name] = $properties
        }
    } else {
        # PowerShell 5.x: Use traditional sequential processing
        $shell = New-Object -ComObject WScript.Shell
        $tree = @{}
        
        Get-ChildItem -Path $TargetPath -Recurse -Filter *.lnk -File -Force | ForEach-Object {
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
    }
    
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
            # Sort properties within each shortcut alphabetically
            $shortcutDetails = $tree[$folder][$shortcutName]
            $sortedDetails = [ordered]@{}
            foreach ($propName in ($shortcutDetails.Keys | Sort-Object)) {
                $sortedDetails[$propName] = $shortcutDetails[$propName]
            }
            $sortedTree[$folder][$shortcutName] = $sortedDetails
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
    
    # Use built-in ConvertTo-Json (much faster than manual building)
    # Note: Sorting is already done in Scan_StartMenuShortcuts via [ordered] hashtables
    $ConfigTree | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath -Encoding UTF8
    
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
    
    # Use cached console width (optimization: avoid repeated console queries)
    $consoleWidth = $script:consoleWidth
    
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
    
    # OPTIMIZED: Single-pass processing instead of double iteration
    # Problem: Different shortcuts may normalize to the same name after stripping versions/architecture
    # Solution: Detect collisions and build all maps in one pass
    
    $allConfigShortcuts = @{}      # Temporary: normalized name -> array of original names
    $expectedMap = @{}             # Final lookup: shortcut name -> folder
    $shortcutDetailsMap = @{}      # Map of shortcut -> details for recreation
    
    # Single pass: build all data structures at once
    foreach ($folderKey in $ConfigRaw.PSObject.Properties.Name) {
        # Create folders early
        if ($folderKey -ne "Root" -and -not [string]::IsNullOrEmpty($folderKey)) {
            Ensure_Folder (Join-Path $TargetPath $folderKey)
        }
        
        $shortcuts = $ConfigRaw.$folderKey
        foreach ($sc in $shortcuts.PSObject.Properties.Name) {
            $norm = Normalize_ShortcutName $sc
            
            # Track for collision detection
            if (-not $allConfigShortcuts.ContainsKey($norm)) {
                $allConfigShortcuts[$norm] = @()
            }
            $allConfigShortcuts[$norm] += @{Original = $sc; Folder = $folderKey}
            
            # Store details for recreation
            $shortcutDetailsMap["$folderKey\$sc"] = $shortcuts.$sc
        }
    }
    
    # Second mini-pass: build expectedMap now that we know which are variants
    foreach ($folderKey in $ConfigRaw.PSObject.Properties.Name) {
        $shortcuts = $ConfigRaw.$folderKey
        foreach ($sc in $shortcuts.PSObject.Properties.Name) {
            $norm = Normalize_ShortcutName $sc
            
            # Decide key: full name for variants, normalized for unique
            $keyToUse = if ($allConfigShortcuts[$norm].Count -gt 1) { $sc } else { $norm }
            
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
    $allShortcuts = @(Get-ChildItem -Path $TargetPath -Recurse -Filter *.lnk -File -Force)
    
    $actualIndex = @{}
    $processed = @{}
    # Pre-allocate list capacity for better performance (estimate: ~10% of shortcuts need actions)
    $plannedMoves = [System.Collections.Generic.List[hashtable]]::new([Math]::Max(10, $allShortcuts.Count / 10))
    $plannedDeletes = [System.Collections.Generic.List[hashtable]]::new(10)
    $foldersToCheck = @{}
    $quarantineCounter = @{}  # Track numbering for unknown duplicate shortcuts

    Write-Host "Processing $($allShortcuts.Count) shortcuts..." -ForegroundColor Cyan

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
            
            # Handle known shortcuts (in config)
            if ($correctFolder) {
                if ($itemFolder -ne $correctFolder -and $existingFolder -eq $correctFolder) {
                    # Current item is wrong, existing is correct -> delete current
                    Write_Log "  -> Deleting duplicate from wrong location: '$($item.Name)' at $itemFolder (correct: $correctFolder)"
                    $plannedDeletes.Add(@{ Path = $item.FullName; Name = $item.Name; Folder = $itemFolder; CorrectFolder = $correctFolder })
                    $foldersToCheck[$item.DirectoryName] = $true
                    continue
                } elseif ($existingFolder -ne $correctFolder -and $itemFolder -eq $correctFolder) {
                    # Existing is wrong, current is correct -> remove any planned move for existing, delete it, update index
                    Write_Log "  -> Deleting duplicate from wrong location: '$($existing.Name)' at $existingFolder (correct: $correctFolder)"
                    
                    # Remove any planned move for the existing shortcut
                    for ($i = $plannedMoves.Count - 1; $i -ge 0; $i--) {
                        if ($plannedMoves[$i].Source -eq $existing.FullName) {
                            Write_Log "  -> Removing conflicting planned move for '$($existing.Name)'"
                            $plannedMoves.RemoveAt($i)
                            break
                        }
                    }
                    
                    $plannedDeletes.Add(@{ Path = $existing.FullName; Name = $existing.Name; Folder = $existingFolder; CorrectFolder = $correctFolder })
                    $foldersToCheck[$existing.DirectoryName] = $true
                    $actualIndex[$indexKey] = $item
                } elseif ($itemFolder -eq $correctFolder -and $existingFolder -eq $correctFolder) {
                    # Both are in correct location -> delete current (keep first found)
                    Write_Log "  -> Both duplicates in correct location. Deleting second: '$($item.Name)' at $itemFolder"
                    $plannedDeletes.Add(@{ Path = $item.FullName; Name = $item.Name; Folder = $itemFolder; CorrectFolder = $correctFolder })
                    $foldersToCheck[$item.DirectoryName] = $true
                    continue
                } else {
                    # Both are wrong -> delete current (keep first found)
                    Write_Log "  -> Both duplicates in wrong location. Deleting second: '$($item.Name)' at $itemFolder (correct: $correctFolder)"
                    $plannedDeletes.Add(@{ Path = $item.FullName; Name = $item.Name; Folder = $itemFolder; CorrectFolder = $correctFolder })
                    $foldersToCheck[$item.DirectoryName] = $true
                    continue
                }
            } else {
                # Handle unknown shortcuts (not in config) - need to quarantine with numbered names
                Write_Log "  -> Both duplicates are unknown. Will quarantine with numbered names."
                
                # Check if either is already in the quarantine folder
                $qFolder = Join-Path $TargetPath $QuarantineFolder
                $itemInQuarantine = $item.DirectoryName -eq $qFolder
                $existingInQuarantine = $existing.DirectoryName -eq $qFolder
                
                if ($existingInQuarantine -and -not $itemInQuarantine) {
                    # Existing is already in quarantine, leave it alone and number the current item
                    if (-not $quarantineCounter.ContainsKey($norm)) {
                        $quarantineCounter[$norm] = 0
                    }
                    $quarantineCounter[$norm]++
                    $number = $quarantineCounter[$norm]
                    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($item.Name)
                    $extension = [System.IO.Path]::GetExtension($item.Name)
                    $numberedName = "$baseName ($number)$extension"
                    
                    $currentFolder = Get_RelativePath $item.DirectoryName
                    $qDest = Join-Path $TargetPath $QuarantineFolder | Join-Path -ChildPath $numberedName
                    
                    $plannedMoves.Add(@{
                        Type = "Quarantine"
                        Source = $item.FullName
                        Destination = $qDest
                        Name = $item.Name
                        NewName = $numberedName
                        CurrentFolder = $currentFolder
                        DestFolder = $QuarantineFolder
                    })
                    
                    Write_Log "  -> Will quarantine '$($item.Name)' from $currentFolder as '$numberedName'"
                    continue
                } elseif ($itemInQuarantine -and -not $existingInQuarantine) {
                    # Current item is already in quarantine, remove any planned move for existing and number the existing
                    # Remove any planned quarantine move for the existing shortcut
                    for ($i = $plannedMoves.Count - 1; $i -ge 0; $i--) {
                        if ($plannedMoves[$i].Source -eq $existing.FullName) {
                            Write_Log "  -> Removing conflicting planned quarantine for '$($existing.Name)'"
                            $plannedMoves.RemoveAt($i)
                            break
                        }
                    }
                    
                    # Number the existing one
                    if (-not $quarantineCounter.ContainsKey($norm)) {
                        $quarantineCounter[$norm] = 0
                    }
                    $quarantineCounter[$norm]++
                    $number = $quarantineCounter[$norm]
                    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($existing.Name)
                    $extension = [System.IO.Path]::GetExtension($existing.Name)
                    $numberedName = "$baseName ($number)$extension"
                    
                    $existingCurrentFolder = Get_RelativePath $existing.DirectoryName
                    $qDest = Join-Path $TargetPath $QuarantineFolder | Join-Path -ChildPath $numberedName
                    
                    $plannedMoves.Add(@{
                        Type = "Quarantine"
                        Source = $existing.FullName
                        Destination = $qDest
                        Name = $existing.Name
                        NewName = $numberedName
                        CurrentFolder = $existingCurrentFolder
                        DestFolder = $QuarantineFolder
                    })
                    
                    Write_Log "  -> Will quarantine '$($existing.Name)' from $existingCurrentFolder as '$numberedName'"
                    $actualIndex[$indexKey] = $item
                } else {
                    # Neither or both are in quarantine folder - number the current one (keep first found)
                    if (-not $quarantineCounter.ContainsKey($norm)) {
                        $quarantineCounter[$norm] = 0
                    }
                    $quarantineCounter[$norm]++
                    $number = $quarantineCounter[$norm]
                    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($item.Name)
                    $extension = [System.IO.Path]::GetExtension($item.Name)
                    $numberedName = "$baseName ($number)$extension"
                    
                    $currentFolder = Get_RelativePath $item.DirectoryName
                    $qDest = Join-Path $TargetPath $QuarantineFolder | Join-Path -ChildPath $numberedName
                    
                    $plannedMoves.Add(@{
                        Type = "Quarantine"
                        Source = $item.FullName
                        Destination = $qDest
                        Name = $item.Name
                        NewName = $numberedName
                        CurrentFolder = $currentFolder
                        DestFolder = $QuarantineFolder
                    })
                    
                    Write_Log "  -> Will quarantine '$($item.Name)' as '$numberedName'"
                    continue
                }
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
    
    # Pre-allocate with estimate (usually only a few missing shortcuts)
    $missingShortcuts = [System.Collections.Generic.List[hashtable]]::new(10)
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
    
    # Pre-allocate with estimate (usually only a few empty folders)
    $emptyFoldersToDelete = [System.Collections.Generic.List[hashtable]]::new(5)
    $seenFolders = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)  # Track to avoid duplicates
    
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
            # Skip if already processed (avoid duplicates)
            if ($seenFolders.Contains($folder.FullName)) {
                continue
            }
            
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
                $seenFolders.Add($folder.FullName) | Out-Null
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
                $line = Format_ActionLine -Emoji "➡️" -Name $move.Name -Operation "[Move]" `
                    -Source $move.CurrentFolder -Destination $move.DestFolder
                Write-Host $line -ForegroundColor Green
                Write_Log "  - $($move.Name) FROM: $($move.CurrentFolder) -> TO: $($move.DestFolder)"
            }
            Write-Host ""
        }
        
        # Show missing shortcuts to recreate
        if ($MissingShortcuts.Count -gt 0) {
            Write_Log "MISSING SHORTCUTS TO RECREATE ($($MissingShortcuts.Count)):" -Color Cyan -ToScreen
            foreach ($missing in $MissingShortcuts) {
                $line = Format_ActionLine -Emoji "➕" -Name $missing.Name -Operation "[Recreate]" `
                    -Destination $missing.Folder
                Write-Host $line -ForegroundColor Cyan
                Write_Log "  - $($missing.Name) IN: $($missing.Folder)"
            }
            Write-Host ""
        }
    
        # Show quarantines (wrap in @() to prevent unwrapping single items)
        $toQuarantine = @($PlannedMoves | Where-Object { $_.Type -eq "Quarantine" })
        if ($toQuarantine.Count -gt 0) {
            Write_Log "UNKNOWN SHORTCUTS TO QUARANTINE ($($toQuarantine.Count)):" -Color Yellow -ToScreen
            foreach ($move in $toQuarantine) {
                # Check if it's being renamed (duplicate unknown shortcut)
                $displayName = if ($move.NewName) { "$($move.Name) -> $($move.NewName)" } else { $move.Name }
                $line = Format_ActionLine -Emoji "🥅" -Name $displayName -Operation "[Quarantine]" `
                    -Source $move.CurrentFolder -Destination $move.DestFolder
                Write-Host $line -ForegroundColor Yellow
                if ($move.NewName) {
                    Write_Log "  - $($move.Name) -> $($move.NewName) FROM: $($move.CurrentFolder) -> TO: $($move.DestFolder)"
                } else {
                    Write_Log "  - $($move.Name) FROM: $($move.CurrentFolder) -> TO: $($move.DestFolder)"
                }
            }
            Write-Host ""
        }

        # Show deletes (duplicates)
        if ($PlannedDeletes.Count -gt 0) {
            Write_Log "DUPLICATE SHORTCUTS TO DELETE ($($PlannedDeletes.Count)):" -Color Red -ToScreen
            foreach ($delete in $PlannedDeletes) {
                $line = Format_ActionLine -Emoji "🎭" -Name $delete.Name -Operation "[Delete]" `
                    -Destination $delete.Folder
                Write-Host $line -ForegroundColor Red
                Write_Log "  - $($delete.Name) IN: $($delete.Folder)"
            }
            Write-Host ""
        }        

        # Show empty folders (wrap in @() to handle single items correctly)
        if ($EmptyFoldersToDelete.Count -gt 0) {
            Write_Log "EMPTY FOLDERS TO DELETE ($($EmptyFoldersToDelete.Count)):" -Color Magenta -ToScreen
            foreach ($folder in @($EmptyFoldersToDelete)) {
                $line = Format_ActionLine -Emoji "🗑️" -Name $folder.DisplayFolder -Operation "[Delete]"
                Write-Host $line -ForegroundColor Magenta
                Write_Log "  - $($folder.DisplayFolder)"
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
            $color = if ($move.Type -eq "Quarantine") { "Yellow" } else { "Green" }
            
            # Display name (handle renamed shortcuts)
            $displayName = if ($move.NewName) { "$($move.Name) -> $($move.NewName)" } else { $move.Name }
            
            # Print compact success line (optimized)
            $line = Format_ActionLine -Emoji $emoji -Name $displayName -Operation $operation `
                -Source $move.CurrentFolder -Destination $move.DestFolder -StatusEmoji "✅"
            Write-Host $line -ForegroundColor $color
            
            if ($move.NewName) {
                Write_Log "$($move.Type): $($move.Name) -> $($move.NewName) from $($move.CurrentFolder) to $($move.DestFolder)"
            } else {
                Write_Log "$($move.Type): $($move.Name) from $($move.CurrentFolder) to $($move.DestFolder)"
            }
            $SuccessCount.Value++
        } catch {
            # Print compact error line (optimized - always use Red for errors regardless of type)
            $emoji = if ($move.Type -eq "Quarantine") { "🥅" } else { "➡️" }
            $operation = if ($move.Type -eq "Quarantine") { "[Quarantine]" } else { "[Move]" }
            $displayName = if ($move.NewName) { "$($move.Name) -> $($move.NewName)" } else { $move.Name }
            $line = Format_ActionLine -Emoji $emoji -Name $displayName -Operation $operation `
                -Source $move.CurrentFolder -Destination $move.DestFolder -StatusEmoji "❌"
            Write-Host $line -ForegroundColor Red
            
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
            
            # Print compact success line (optimized)
            $line = Format_ActionLine -Emoji "➕" -Name $missing.Name -Operation "[Recreate]" `
                -Destination $missing.Folder -StatusEmoji "✅"
            Write-Host $line -ForegroundColor Cyan
            
            Write_Log "Recreated: $($missing.Name) in $($missing.Folder)"
            $SuccessCount.Value++
        } catch {
            # Print compact error line (optimized)
            $line = Format_ActionLine -Emoji "➕" -Name $missing.Name -Operation "[Recreate]" `
                -Destination $missing.Folder -StatusEmoji "❌"
            Write-Host $line -ForegroundColor Red
            
            Write_Log "Recreate failed: $($missing.Name) - $_"
            $ErrorCount.Value++
        }
    }
    
    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($shell) | Out-Null
}

function Execute_ShortcutDeletes {
    param(
        $PlannedDeletes,
        [ref]$SuccessCount,
        [ref]$ErrorCount
    )
    
    if ($PlannedDeletes.Count -eq 0) { return }
    
    foreach ($delete in $PlannedDeletes) {
        try {
            Remove-Item -Path $delete.Path -Force -ErrorAction Stop
            
            # Print compact success line (optimized)
            $line = Format_ActionLine -Emoji "🎭" -Name $delete.Name -Operation "[Delete]" `
                -Destination $delete.Folder -StatusEmoji "✅"
            Write-Host $line -ForegroundColor Red
            
            Write_Log "Deleted duplicate: $($delete.Name) from $($delete.Folder)"
            $SuccessCount.Value++
        } catch {
            # Print compact error line (optimized)
            $line = Format_ActionLine -Emoji "🎭" -Name $delete.Name -Operation "[Delete]" `
                -Destination $delete.Folder -StatusEmoji "❌"
            Write-Host $line -ForegroundColor Red
            
            Write_Log "Delete failed: $($delete.Name) - $_"
            $ErrorCount.Value++
        }
    }
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
                
                # Print compact success line (optimized)
                $line = Format_ActionLine -Emoji "🗑️" -Name $folder.DisplayFolder -Operation "[Delete]" -StatusEmoji "✅"
                Write-Host $line -ForegroundColor Magenta
                
                Write_Log "Deleted empty folder: $($folder.DisplayFolder)"
                $SuccessCount.Value++
            } else {
                # Print compact skip line (optimized)
                $line = Format_ActionLine -Emoji "🗑️" -Name $folder.DisplayFolder -Operation "[Delete]" -StatusEmoji "⚠️"
                Write-Host $line -ForegroundColor Yellow
                
                Write_Log "Skipped deletion (folder not empty): $($folder.DisplayFolder)"
            }
        } catch {
            # Print compact error line (optimized)
            $line = Format_ActionLine -Emoji "🗑️" -Name $folder.DisplayFolder -Operation "[Delete]" -StatusEmoji "❌"
            Write-Host $line -ForegroundColor Red
            
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
    $proceed = Display_EnforcePreview -PlannedMoves @($scanResults.PlannedMoves) `
        -PlannedDeletes @($scanResults.PlannedDeletes) `
        -EmptyFoldersToDelete @($emptyFoldersToDelete) `
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

    # Execute in correct order: moves -> recreations -> quarantines -> duplicate deletes -> folder deletes
    
    # 1. Execute moves (regular moves only, not quarantines)
    $regularMoves = @($scanResults.PlannedMoves | Where-Object { $_.Type -eq "Move" })
    if ($regularMoves.Count -gt 0) {
        Execute_ShortcutMoves -PlannedMoves $regularMoves `
            -SuccessCount ([ref]$successCount) -ErrorCount ([ref]$errorCount)
    }
    
    # 2. Execute recreations (use @() to prevent unwrapping single-item collections)
    Execute_ShortcutRecreations -MissingShortcuts @($missingShortcuts) `
        -TargetPath $target `
        -SuccessCount ([ref]$successCount) -ErrorCount ([ref]$errorCount)
    
    # 3. Execute quarantines
    $quarantineMoves = @($scanResults.PlannedMoves | Where-Object { $_.Type -eq "Quarantine" })
    if ($quarantineMoves.Count -gt 0) {
        Execute_ShortcutMoves -PlannedMoves $quarantineMoves `
            -SuccessCount ([ref]$successCount) -ErrorCount ([ref]$errorCount)
    }
    
    # 4. Execute duplicate deletes
    if ($scanResults.PlannedDeletes.Count -gt 0) {
        Execute_ShortcutDeletes -PlannedDeletes @($scanResults.PlannedDeletes) `
            -SuccessCount ([ref]$successCount) -ErrorCount ([ref]$errorCount)
    }
    
    # 5. Execute folder deletes (use @() to prevent unwrapping single-item collections)
    Execute_FolderDeletes -EmptyFoldersToDelete @($emptyFoldersToDelete) `
        -SuccessCount ([ref]$successCount) -ErrorCount ([ref]$errorCount)
    
    # Summary
    Write-Host ""
    Write_Log "Completed! $successCount successful, $errorCount errors." -Color $(if ($errorCount -eq 0) { "Green" } else { "Yellow" }) -ToScreen
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
