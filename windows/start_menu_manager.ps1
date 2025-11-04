# ===== Start Menu Manager =====
# Two modes:
#   1. SAVE mode (-Save flag): Scans Start Menu and generates config file. Run in this mode when you want to save the current state of the Start Menu to the config file.
#   2. ENFORCE mode (default): Organizes shortcuts based on config file. Run in this mode when you want to organize the Start Menu based on the config file.
param(
    [switch]$Save,      # Use this flag to generate config file from current Start Menu
    [switch]$Automated   # Use this flag when running from scheduled task (enforce mode, no dry-run)
)

$target           = "C:\ProgramData\Microsoft\Windows\Start Menu"
$configPath       = "D:\OneDrive\Backups\StartMenuConfig.json"
$logPath          = "D:\OneDrive\Backups\StartMenuManager.log"
$quarantineFolder = "Programs\Unsorted"   # relative to $target

# Determine mode
if ($Save) {
    $mode = "SAVE"
    $runType = "MANUAL"
    $dryRun = $false
} else {
    $mode = "ENFORCE"
    # Dry Run Mode: Shows what will be changed and asks for confirmation
    # Set to $true  = Preview changes, then ask to proceed (for manual runs)
    # Set to $false = Execute changes immediately without confirmation (for automation)
    if ($Automated) {
        $dryRun = $false
        $runType = "AUTOMATED"
    } else {
        $dryRun = $true
        $runType = "MANUAL"
    }
}

# ============================================= HELPER FUNCTIONS ==============================================
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

function Write_Log { 
    param([string]$msg, [string]$Color = "White", [switch]$ToScreen)
    # Always write to log file
    $msg | Add-Content -Path $logPath
    # Optionally write to screen with color
    if ($ToScreen) { Write-Host $msg -ForegroundColor $Color }
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

# ============================================= INITIALIZATION ================================================
Write_Log "`n============================== $(Get-Date) ==============================`n"
Write_Log "MODE: $mode, $runType" -Color Cyan -ToScreen
Write-Host ""

if (-not (Test-Path $target)) { throw "Target not found: $target" }

# =============================================================================================================
# ================================== SAVE MODE: GENERATE CONFIG FILE ==========================================
# =============================================================================================================

if ($mode -eq "SAVE") {
    Write-Host "Scanning Start Menu to generate config file..." -ForegroundColor Cyan
    Write_Log "Scanning Start Menu: $target"
    
    $tree = @{}
    
    # Collect shortcuts grouped by relative folder
    Get-ChildItem -Path $target -Recurse -Filter *.lnk -Force | ForEach-Object {
        $relativePath = $_.DirectoryName.Substring($target.Length).TrimStart('\')
        $folder = if ([string]::IsNullOrEmpty($relativePath)) { "Root" } else { $relativePath }

        if (-not $tree.ContainsKey($folder)) {
            $tree[$folder] = @()
        }
        $tree[$folder] += $_.Name
    }
    
    # Sort folders alphabetically, and sort shortcuts within each folder
    # Use [ordered] to preserve insertion order when converting to JSON
    $sortedTree = [ordered]@{}
    foreach ($folder in ($tree.Keys | Sort-Object)) {
        $sortedTree[$folder] = $tree[$folder] | Sort-Object
    }
    
    # Pretty-print JSON with indentation
    $sortedTree | ConvertTo-Json -Depth 5 -Compress:$false | Out-File $configPath -Encoding UTF8
    
    $folderCount = $sortedTree.Keys.Count
    $shortcutCount = ($sortedTree.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
    
    Write-Host "[OK] Config file generated successfully!" -ForegroundColor Green
    Write-Host "  Location: $configPath" -ForegroundColor Gray
    Write-Host "  Folders: $folderCount" -ForegroundColor Gray
    Write-Host "  Shortcuts: $shortcutCount" -ForegroundColor Gray
    Write_Log "Config file written: $configPath - $folderCount folders, $shortcutCount shortcuts"
    exit
}
# =============================================================================================================
# ================================== ENFORCE MODE: ORGANIZE SHORTCUTS =========================================
# =============================================================================================================
if (-not (Test-Path $configPath)) { throw "Config not found: $configPath" }

$configRaw = Get-Content $configPath -Raw | ConvertFrom-Json
$createdFolders = @{}                                                                  # Empty hashtable to cache folder existence checks
$quarantinePath = Join-Path $target $quarantineFolder
Ensure_Folder $quarantinePath


# ========================================== BUILD CONFIG LOOKUP TABLE ========================================
# Problem: Different shortcuts may normalize to the same name after stripping versions/architecture
# Examples: ODBC 32-bit and ODBC 64-bit both become ODBC.lnk after normalization
# Solution: Detect when multiple shortcuts normalize to same name, and use full names for those
$allConfigShortcuts = @{}                                                              # Temporary: normalized name -> array of original names
$expectedMap = @{}                                                                     # Final lookup: shortcut name -> folder

# ============= PASS 1: Group all shortcuts by normalized name to detect collisions ================
# Any shortcuts that normalize to the same name will end up in the same array
foreach ($folderKey in $configRaw.PSObject.Properties.Name) {                          # Loop through each folder in the config file
    $shortcuts = $configRaw.$folderKey                                                 # Get the shortcuts for the current folder
    foreach ($sc in $shortcuts) {                                                      # Loop through each shortcut in the current folder
        $norm = Normalize_ShortcutName $sc
        if (-not $allConfigShortcuts.ContainsKey($norm)) {                             # If the normalized name is not in the hashtable
            $allConfigShortcuts[$norm] = @()                                           # Create a new array for the normalized name
        }
        $allConfigShortcuts[$norm] += @{Original = $sc; Folder = $folderKey}           # Add the shortcut's info to the array, with full original name and folder name
    }
}

# === PASS 2: Build final lookup map, using full names for variants, normalized names for others ===
foreach ($folderKey in $configRaw.PSObject.Properties.Name) {                          # Loop through each folder in the config file
    if ($folderKey -ne "Root" -and -not [string]::IsNullOrEmpty($folderKey)) {         # If the folder is not the root folder and is not empty
        Ensure_Folder (Join-Path $target $folderKey)                                   # Create the folder if it doesn't exist
    }
    
    # Add each shortcut to the lookup map
    $shortcuts = $configRaw.$folderKey                                                 # Get the shortcuts for the current folder
    foreach ($sc in $shortcuts) {                                                      # Loop through each shortcut in the current folder
        $norm = Normalize_ShortcutName $sc
        
        # Decide what key to use in $expectedMap
        if ($allConfigShortcuts[$norm].Count -gt 1) {                                  # If there are multiple shortcuts that normalize to the same name
            $keyToUse = $sc                                                            # Use the full original name
        } else {
            $keyToUse = $norm                                                          # Use the normalized name
        }
        
        if ($expectedMap.ContainsKey($keyToUse)) {
            Write_Log "**Config duplicate:** $keyToUse (folder $($expectedMap[$keyToUse]) vs $folderKey)"
        }
        $expectedMap[$keyToUse] = $folderKey
    }
}
# Result: $expectedMap contains:
#   - Normalized names for unique shortcuts (e.g., Chrome.lnk matches any Chrome version)
#   - Full original names for collision variants (e.g., ODBC 32-bit and ODBC 64-bit each get their own entry)


# ================================= SCAN AND ORGANIZE SHORTCUTS ===============================================
Write-Host "Scanning shortcuts at $target..." -ForegroundColor Cyan
# Get-ChildItem returns FileInfo objects with properties like .Name and .FullName
# (PowerShell displays some of them as a table, but the code accesses the actual object properties)
$allShortcuts = Get-ChildItem -Path $target -Recurse -Filter *.lnk -Force

$actualIndex = @{}     # Track shortcuts we've seen to detect duplicates
$processed = @{}       # Track which shortcuts we've handled successfully
$plannedMoves = @()    # Collect all move operations (execute at end)

Write-Host "Processing $(($allShortcuts | Measure-Object).Count) shortcuts..." -ForegroundColor Cyan

foreach ($item in $allShortcuts) {
    $norm = Normalize_ShortcutName $item.Name
    
    # Check if this shortcut is tracked in our config
    # Strategy depends on whether this normalized name has known variants in config
    if ($allConfigShortcuts.ContainsKey($norm) -and $allConfigShortcuts[$norm].Count -gt 1) {
        # VARIANT CASE: Multiple shortcuts in config normalize to this name
        # Must match by FULL name only to distinguish between variants
        # Example: Both "Windows PowerShell ISE.lnk" and "Windows PowerShell ISE (x86).lnk" 
        #          normalize to "Windows PowerShell ISE.lnk", so we need exact full name match
        $matchKey = if ($expectedMap.ContainsKey($item.Name)) { $item.Name } else { $null }
    } else {
        # NORMAL CASE: No variants exist for this normalized name
        # Try normalized name first (flexible), then full name (exact)
        # Example: "Chrome v120.lnk" normalizes to "Chrome.lnk" -> matches on normalized key
        $matchKey = if ($expectedMap.ContainsKey($norm)) { 
            $norm  # Match on normalized name (handles version changes automatically)
        } elseif ($expectedMap.ContainsKey($item.Name)) { 
            $item.Name  # Match on full name (for exact matches)
        } else { 
            $null  # Not in config -> will be quarantined
        }
    }
    
    # For duplicate detection, use the match key (which may be full name for variants)
    $indexKey = if ($matchKey -and $matchKey -eq $item.Name) { $item.Name } else { $norm }
    
    # Check for unexpected duplicates (two different files with same key, not expected variants)
    if ($actualIndex.ContainsKey($indexKey)) {
        $existing = $actualIndex[$indexKey]
        Write_Log "Duplicate found: '$($item.Name)' at $($item.DirectoryName) clashes with '$($existing.Name)' at $($existing.DirectoryName) (both normalize to '$norm')"
        continue  # Skip this duplicate
    }
    $actualIndex[$indexKey] = $item
    
    if ($matchKey) {
        # ===== KNOWN SHORTCUT: Move to correct folder =====
        $relFolder = $expectedMap[$matchKey]                                           # Look up the folder name from the config file
        # Handle special "Root" case (main Start Menu folder)
        $destFolder = if ($relFolder -eq "Root" -or [string]::IsNullOrEmpty($relFolder)) {
            $target
        } else {
            Join-Path $target $relFolder
        }
        # Use ACTUAL filename, not normalized name (normalized is only for matching)
        $destPath = Join-Path $destFolder $item.Name
        
        # Only move if it's not already in the right place
        if ($item.FullName -ne $destPath) {
            # Calculate current relative folder for display
            $currentRelPath = $item.DirectoryName.Substring($target.Length).TrimStart('\')
            $currentFolder = if ([string]::IsNullOrEmpty($currentRelPath)) { "Root" } else { $currentRelPath }
            
            # Collect this move operation
            $plannedMoves += @{
                Type = "Move"
                Source = $item.FullName
                Destination = $destPath
                Name = $item.Name
                CurrentFolder = $currentFolder
                DestFolder = $relFolder
            }
        }
        $processed[$matchKey] = $true
    } else {
        # ===== UNKNOWN SHORTCUT: Quarantine it =====
        $qDest = Join-Path $quarantinePath $item.Name
        if ($item.FullName -ne $qDest) {
            # Calculate current relative folder for display
            $currentRelPath = $item.DirectoryName.Substring($target.Length).TrimStart('\')
            $currentFolder = if ([string]::IsNullOrEmpty($currentRelPath)) { "Root" } else { $currentRelPath }
            
            # Collect this quarantine operation
            $plannedMoves += @{
                Type = "Quarantine"
                Source = $item.FullName
                Destination = $qDest
                Name = $item.Name
                CurrentFolder = $currentFolder
                DestFolder = $quarantineFolder
            }
        }
    }
}

# ===== Report missing shortcuts =====
# Check if any shortcuts in config weren't found on the system
foreach ($normName in $expectedMap.Keys) {  # Loop through all shortcuts we expect
    if (-not $processed.ContainsKey($normName)) {  # If we didn't process it (not found)
        Write_Log "**Missing expected shortcut:** $normName (expected in $($expectedMap[$normName]))"
    }
}


# =========================================== PREVIEW CHANGES =================================================
if ($plannedMoves.Count -eq 0) {
    # No changes needed
    Write_Log "No changes needed - all shortcuts are already in correct locations!" -Color Green -ToScreen
    exit
}

# If dry-run mode, show summary and ask for confirmation
if ($dryRun) {
    Write-Host ""
    Write-Host ("="*70) -ForegroundColor Cyan
    Write-Host " SUMMARY - Planned Changes" -ForegroundColor Cyan
    Write-Host ("="*70) -ForegroundColor Cyan
    Write-Host ""
    
    # Group and display moves
    $moves = $plannedMoves | Where-Object { $_.Type -eq "Move" }
    $quarantines = $plannedMoves | Where-Object { $_.Type -eq "Quarantine" }
    
    # Log the preview summary to file
    Write_Log "`n========== PLANNED CHANGES SUMMARY =========="
    if ($moves.Count -gt 0) {
        Write-Host "MOVES TO CORRECT FOLDERS ($($moves.Count)):" -ForegroundColor Green
        Write_Log "MOVES TO CORRECT FOLDERS ($($moves.Count)):"
        foreach ($move in $moves) {
            Write-Host "  - $($move.Name)" -ForegroundColor White
            Write-Host "    FROM: $($move.CurrentFolder)" -ForegroundColor Gray -NoNewline
            Write-Host " -> TO: $($move.DestFolder)" -ForegroundColor Cyan
            Write_Log "  - $($move.Name) FROM: $($move.CurrentFolder) -> TO: $($move.DestFolder)"
        }
        Write-Host ""
    }
    
    if ($quarantines.Count -gt 0) {
        Write-Host "UNKNOWN SHORTCUTS TO QUARANTINE ($($quarantines.Count)):" -ForegroundColor Yellow
        Write_Log "UNKNOWN SHORTCUTS TO QUARANTINE ($($quarantines.Count)):"
        foreach ($q in $quarantines) {
            Write-Host "  - $($q.Name)" -ForegroundColor White
            Write-Host "    FROM: $($q.CurrentFolder)" -ForegroundColor Gray -NoNewline
            Write-Host " -> TO: $($q.DestFolder)" -ForegroundColor Cyan
            Write_Log "  - $($q.Name) FROM: $($q.CurrentFolder) -> TO: $($q.DestFolder)"
        }
        Write-Host ""
    }
    
    Write-Host ("="*70) -ForegroundColor Cyan
    Write-Host ""
    
    # Ask for confirmation
    $response = Read-Host "Do you want to proceed with these changes? (Y/N)"
    
    if ($response -notmatch '^[Yy]') {
        # User cancelled
        Write-Host ""
        Write_Log "`nOperation cancelled by user. No changes were made." -Color Yellow -ToScreen
        Write-Host "See log: $logPath" -ForegroundColor Gray
        exit
    }
}

# ======================================== EXECUTE CHANGES ====================================================
# This block executes only if the user confirms in the preview section OR if dryRun is set to false
Write_Log "`n========== EXECUTION ==========" -Color Green -ToScreen
Write-Host ""

$successCount = 0
$errorCount = 0

foreach ($move in $plannedMoves) {
    try {
        Move-Item -Path $move.Source -Destination $move.Destination -Force -ErrorAction Stop
        if ($move.Type -eq "Move") {
            Write-Host "  [OK] Moved: $($move.Name) -> $($move.DestFolder)" -ForegroundColor Green
            Write_Log "Moved: $($move.Name) FROM: $($move.CurrentFolder) -> TO: $($move.DestFolder)"
            $successCount++
        } else {
            Write-Host "  [WARN] Quarantined: $($move.Name) -> $($move.DestFolder)" -ForegroundColor Yellow
            Write_Log "Quarantined: $($move.Name) FROM: $($move.CurrentFolder) -> TO: $($move.DestFolder)"
            $successCount++
        }
    } catch {
        Write-Host "  [ERROR] Error: $($move.Name) - $_" -ForegroundColor Red
        Write_Log "Error: $($move.Name) - $_"
        $errorCount++
    }
}

Write-Host ""
Write_Log "`nCompleted! $successCount successful, $errorCount errors." -Color $(if ($errorCount -eq 0) { "Green" } else { "Yellow" }) -ToScreen
Write-Host "See log: $logPath" -ForegroundColor Gray
