# ===== START MENU MANAGER =====
# Two run modes:
#   1. Interactive (no arguments): Shows menu to select READ/SAVE/ENFORCE
#   2. Automated (-Auto flag): Runs ENFORCE mode without prompts (for scheduled tasks)
param(
    [switch]$Auto,                              # Use this flag when running from scheduled task (enforce mode, no prompts)
    [ValidateSet('READ', 'SAVE', 'ENFORCE')]
    [string]$Mode                               # Directly specify mode (skips menu)
)

$target             = "C:\ProgramData\Microsoft\Windows\Start Menu"
$userStartMenuPath  = "$env:APPDATA\Microsoft\Windows\Start Menu"
$configPath         = "E:\OneDrive\Backups\Start Menu\StartMenuConfig.json"
$logPath            = "E:\OneDrive\Backups\Start Menu\StartMenuManager.log"
$quarantineFolder   = "Programs\Unsorted"         # Relative to $target.

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

function Show_Banner {
    param(
        [string]$Title,
        [ConsoleColor]$Color = [ConsoleColor]::Cyan,
        [string]$SeparatorCharacter = "-"
    )

    $borderLine = Get_SeparatorLine -SeparatorCharacter $SeparatorCharacter
    $bannerWidth = $borderLine.Length
    $innerWidth = $bannerWidth - 2
    $titleText = " $($Title.ToUpperInvariant()) "

    if ($titleText.Length -gt $innerWidth) {
        $titleText = $titleText.Substring(0, $innerWidth)
    }

    $leftPadding = [Math]::Floor(($innerWidth - $titleText.Length) / 2)
    $rightPadding = $innerWidth - $titleText.Length - $leftPadding
    $titleLine = $SeparatorCharacter + (" " * $leftPadding) + $titleText + (" " * $rightPadding) + $SeparatorCharacter

    Write-Host ""
    Write-Host $borderLine -ForegroundColor $Color
    Write-Host $titleLine -ForegroundColor $Color
    Write-Host $borderLine -ForegroundColor $Color
}

function Get_SeparatorLine {
    param(
        [string]$SeparatorCharacter = "-"
    )

    $terminalWidth = 80
    try {
        $terminalWidth = [Math]::Max(70, $Host.UI.RawUI.WindowSize.Width)
    }
    catch {
        # Some hosts do not expose a window size.
    }

    if ([string]::IsNullOrWhiteSpace($SeparatorCharacter)) {
        $SeparatorCharacter = "-"
    }
    if ($SeparatorCharacter.Length -gt 1) {
        $SeparatorCharacter = $SeparatorCharacter.Substring(0, 1)
    }

    return $SeparatorCharacter * ($terminalWidth - 2)
}

function Show_SeparatorLine {
    param(
        [ConsoleColor]$Color = [ConsoleColor]::Cyan,
        [string]$SeparatorCharacter = "-"
    )

    Write-Host (Get_SeparatorLine -SeparatorCharacter $SeparatorCharacter) -ForegroundColor $Color
}

function Show_StatusLine {
    param(
        [string]$Label,
        [string]$Value,
        [ConsoleColor]$ValueColor = [ConsoleColor]::White
    )

    $labelWidth = 19
    Write-Host ("  " + $Label.PadRight($labelWidth) + " : ") -NoNewline -ForegroundColor Gray
    Write-Host $Value -ForegroundColor $ValueColor
}

function Show_ModeExplanation {
    param(
        [string]$SelectedMode
    )

    Show_Banner -Title "What This Mode Does"
    switch ($SelectedMode) {
        "READ" {
            Write-Host "  This only displays your saved Start Menu configuration." -ForegroundColor White
            Write-Host "  Nothing will be changed on disk." -ForegroundColor Green
        }
        "SAVE" {
            Write-Host "  This scans the current system Start Menu and updates the saved configuration file." -ForegroundColor White
            Write-Host "  If changes are found, you will be asked before the config is saved." -ForegroundColor Yellow
        }
        "ENFORCE" {
            Write-Host "  This compares your Start Menu with the saved configuration and prepares a cleanup plan." -ForegroundColor White
            if ($dryRun) {
                Write-Host "  You will see a preview first. No changes happen until you confirm." -ForegroundColor Yellow
            } else {
                Write-Host "  Automated mode is active, so the plan will run without prompts." -ForegroundColor Yellow
            }
        }
    }
    Write-Host ""
}

function Show_RunStatus {
    param(
        [string]$SelectedMode,
        [bool]$IsAdmin
    )

    Show_Banner -Title "Run Status"
    Show_StatusLine -Label "Mode" -Value $SelectedMode -ValueColor Cyan
    Show_StatusLine -Label "Run style" -Value $(if ($interactiveMode) { "Manual prompts enabled" } else { "Automated run" }) -ValueColor $(if ($interactiveMode) { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow })
    Show_StatusLine -Label "Config file" -Value $configPath
    Show_StatusLine -Label "System Start Menu" -Value $target
    Show_StatusLine -Label "User Start Menu" -Value $userStartMenuPath
    Show_StatusLine -Label "Admin access" -Value $(if ($IsAdmin) { "Available" } else { "Not required for this mode" }) -ValueColor $(if ($IsAdmin) { [ConsoleColor]::Green } else { [ConsoleColor]::Gray })
    Show_StatusLine -Label "Preview mode" -Value $(if ($dryRun) { "Changes require confirmation" } else { "Prompts skipped" }) -ValueColor $(if ($dryRun) { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow })
    Show_StatusLine -Label "Log file" -Value $logPath
    Write-Host ""
}

function Confirm_Action {
    param(
        [string]$Message
    )

    while ($true) {
        $response = Read-Host "$Message Type Y to continue, N to cancel [N]"
        $cleanResponse = $response.Trim()

        if ([string]::IsNullOrWhiteSpace($cleanResponse) -or $cleanResponse -match '^(n|no)$') {
            Write-Host "Cancelled. No changes were made." -ForegroundColor Yellow
            return $false
        }
        if ($cleanResponse -match '^(y|yes)$') {
            return $true
        }

        Write-Host "Please type Y to continue or N to cancel." -ForegroundColor Red
    }
}

function Show_ColorLegend {
    Write-Host "Legend:" -ForegroundColor Gray
    Write-Host "  Green   = safe or additive change" -ForegroundColor Green
    Write-Host "  Yellow  = needs review" -ForegroundColor Yellow
    Write-Host "  Magenta = delete or remove" -ForegroundColor Magenta
    Write-Host ""
}

function Show_EnforceActionSummary {
    param(
        [array]$PlannedMoves,
        [array]$PlannedDeletes,
        [array]$EmptyFoldersToDelete,
        [array]$MissingShortcuts,
        [array]$PlannedUserMigrations
    )

    $shortcutsToMigrate = @($PlannedUserMigrations | Where-Object { $_.Type -eq "Migrate" })
    $userDuplicatesToDelete = @($PlannedUserMigrations | Where-Object { $_.Type -eq "Delete" })
    $shortcutsToMove = @($PlannedMoves | Where-Object { $_.Type -eq "Move" })
    $shortcutsToQuarantine = @($PlannedMoves | Where-Object { $_.Type -eq "Quarantine" })

    Show_Banner -Title "Action Summary"
    Show_StatusLine -Label "User migrations" -Value "$($shortcutsToMigrate.Count) shortcut(s)" -ValueColor Green
    Show_StatusLine -Label "User duplicates" -Value "$($userDuplicatesToDelete.Count) shortcut(s) to delete" -ValueColor Magenta
    Show_StatusLine -Label "Move to folders" -Value "$($shortcutsToMove.Count) shortcut(s)" -ValueColor Green
    Show_StatusLine -Label "Recreate missing" -Value "$($MissingShortcuts.Count) shortcut(s)" -ValueColor Green
    Show_StatusLine -Label "Quarantine unknown" -Value "$($shortcutsToQuarantine.Count) shortcut(s)" -ValueColor Yellow
    Show_StatusLine -Label "Delete duplicates" -Value "$($PlannedDeletes.Count) shortcut(s)" -ValueColor Magenta
    Show_StatusLine -Label "Delete folders" -Value "$($EmptyFoldersToDelete.Count) empty folder(s)" -ValueColor Magenta
    Write-Host ""
}

function Show_FinalSummary {
    param(
        [string]$Title,
        [System.Collections.IDictionary]$Details
    )

    Show_Banner -Title $Title -Color $(if ($Details["Errors"] -and $Details["Errors"] -gt 0) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Green })
    foreach ($summaryKey in $Details.Keys) {
        $valueColor = if ($summaryKey -match 'Error' -and $Details[$summaryKey] -gt 0) { [ConsoleColor]::Yellow } else { [ConsoleColor]::White }
        Show_StatusLine -Label $summaryKey -Value $Details[$summaryKey] -ValueColor $valueColor
    }
    Write-Host ""
}

function Show_ModeMenu {
    Show_Banner -Title "Start Menu Manager - Select Mode" -SeparatorCharacter "="
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
    param([string]$TargetPath)
    
    Write-Host "Scanning Start Menu to generate config file..." -ForegroundColor Gray
    Write_Log "Scanning Start Menu: $TargetPath"
    
    Write-Progress -Activity "Scanning Start Menu" -Status "Finding shortcuts..." -PercentComplete 5
    $tree = @{}
    $shortcuts = @(Get-ChildItem -Path $TargetPath -Recurse -Filter *.lnk -File -Force)
    Write-Host "Found $($shortcuts.Count) shortcuts." -ForegroundColor Gray
    
    # Helper to read shortcut details
    $ReadShortcut = {
        param($shell, $item, $targetPath)
        $rel = $item.DirectoryName.Substring($targetPath.Length).TrimStart('\')
        $folder = if ($rel) { $rel } else { "Root" }
        try {
            $sc = $shell.CreateShortcut($item.FullName)
            @{ Folder = $folder; Name = $item.Name; TargetPath = $sc.TargetPath; Arguments = $sc.Arguments
               WorkingDirectory = $sc.WorkingDirectory; IconLocation = $sc.IconLocation; Description = $sc.Description }
        } catch { @{ Folder = $folder; Name = $item.Name } }
    }
    
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        # PowerShell 7+: Parallel processing
        Write-Host "Using parallel processing..." -ForegroundColor Gray
        Write-Progress -Activity "Scanning Start Menu" -Status "Reading shortcut details..." -PercentComplete 35
        $results = [System.Collections.Concurrent.ConcurrentBag[hashtable]]::new()
        $shortcuts | ForEach-Object -Parallel {
            $shell = New-Object -ComObject WScript.Shell
            try {
                $rel = $_.DirectoryName.Substring($using:TargetPath.Length).TrimStart('\')
                $folder = if ($rel) { $rel } else { "Root" }
                try { $sc = $shell.CreateShortcut($_.FullName)
                    $r = @{ Folder = $folder; Name = $_.Name; TargetPath = $sc.TargetPath; Arguments = $sc.Arguments
                            WorkingDirectory = $sc.WorkingDirectory; IconLocation = $sc.IconLocation; Description = $sc.Description }
                } catch { $r = @{ Folder = $folder; Name = $_.Name } }
                ($using:results).Add($r)
            } finally { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($shell) | Out-Null }
        } -ThrottleLimit 5
        foreach ($r in $results) {
            if (-not $tree[$r.Folder]) { $tree[$r.Folder] = @{} }
            $props = @{}; $r.Keys | Where-Object { $_ -notin 'Folder','Name' } | ForEach-Object { $props[$_] = $r[$_] }
            $tree[$r.Folder][$r.Name] = $props
        }
    } else {
        # PowerShell 5.x: Sequential
        $shell = New-Object -ComObject WScript.Shell
        $shortcutIndex = 0
        foreach ($item in $shortcuts) {
            $shortcutIndex++
            $percentComplete = if ($shortcuts.Count -gt 0) { [Math]::Min(95, [Math]::Floor(($shortcutIndex / $shortcuts.Count) * 90) + 5) } else { 95 }
            Write-Progress -Activity "Scanning Start Menu" -Status "Reading $($item.Name)" -PercentComplete $percentComplete
            $r = & $ReadShortcut $shell $item $TargetPath
            if (-not $tree[$r.Folder]) { $tree[$r.Folder] = @{} }
            $props = @{}; $r.Keys | Where-Object { $_ -notin 'Folder','Name' } | ForEach-Object { $props[$_] = $r[$_] }
            $tree[$r.Folder][$item.Name] = $props
        }
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($shell) | Out-Null
    }
    
    # Add preserved system folders
    $startupPath = Join-Path $TargetPath "Programs\Startup"
    if (-not $tree["Programs\Startup"] -and (Test-Path $startupPath)) {
        $tree["Programs\Startup"] = @{}; Write_Log "Added empty system folder: Programs\Startup"
    }
    
    # Sort and return
    $sorted = [ordered]@{}
    foreach ($folder in ($tree.Keys | Sort-Object)) {
        $sorted[$folder] = [ordered]@{}
        foreach ($shortcut in ($tree[$folder].Keys | Sort-Object)) {
            $sorted[$folder][$shortcut] = [ordered]@{}
            foreach ($prop in ($tree[$folder][$shortcut].Keys | Sort-Object)) {
                $sorted[$folder][$shortcut][$prop] = $tree[$folder][$shortcut][$prop]
            }
        }
    }
    Write-Progress -Activity "Scanning Start Menu" -Completed
    return $sorted
}

function Calculate_ConfigDiff {
    param([PSCustomObject]$OldConfig, [PSCustomObject]$NewConfig)
    
    Show_Banner -Title "Changes From Previous Config" -Color Magenta
    Write-Host ""
    Write_Log "`n---------- CHANGES FROM PREVIOUS CONFIG ----------"
    
    $changesFound = $false
    $oldFolders = @($OldConfig.PSObject.Properties.Name)
    $newFolders = @($NewConfig.PSObject.Properties.Name)
    
    # Show added/removed folders
    @{Items = @($newFolders | Where-Object { $_ -notin $oldFolders }); Label = "NEW FOLDERS"; Prefix = "+"; Color = "Green"},
    @{Items = @($oldFolders | Where-Object { $_ -notin $newFolders }); Label = "REMOVED FOLDERS"; Prefix = "-"; Color = "Red"} | ForEach-Object {
        $group = $_
        if ($group.Items.Count -gt 0) {
            $changesFound = $true
            Write_Log "$($group.Label) ($($group.Items.Count)):" -Color $group.Color -ToScreen
            $group.Items | Sort-Object | ForEach-Object { Write_Log "  $($group.Prefix) $_" -Color $group.Color -ToScreen }
            Write-Host ""
        }
    }
    
    # Show changed shortcuts in common folders
    $newFolders | Where-Object { $_ -in $oldFolders } | Sort-Object | ForEach-Object {
        $folder = $_; $old = @($OldConfig.$folder.PSObject.Properties.Name); $new = @($NewConfig.$folder.PSObject.Properties.Name)
        $added = @($new | Where-Object { $_ -notin $old }); $removed = @($old | Where-Object { $_ -notin $new })
        if ($added.Count -gt 0 -or $removed.Count -gt 0) {
            $changesFound = $true
            Write-Host "$folder" -ForegroundColor Yellow -NoNewline; Write-Host " (+$($added.Count) / -$($removed.Count))" -ForegroundColor Gray
            Write_Log "$folder (+$($added.Count) / -$($removed.Count))"
            $added | Sort-Object | ForEach-Object { Write_Log "      + $_" -Color Green -ToScreen }
            $removed | Sort-Object | ForEach-Object { Write_Log "      - $_" -Color Red -ToScreen }
            Write-Host ""
        }
    }
    
    if (-not $changesFound) { Write_Log "No changes detected." -Color Gray -ToScreen; Write-Host "" }
    Show_SeparatorLine -Color Magenta; Write-Host ""; Write_Log "--------------------------------------------------"
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
    
    Write-Host "Saving config..." -ForegroundColor Gray
    
    # Use built-in ConvertTo-Json (much faster than manual building)
    # Note: Sorting is already done in Scan_StartMenuShortcuts via [ordered] hashtables
    $ConfigTree | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath -Encoding UTF8
    
    Write-Host "[OK] Config file saved successfully!" -ForegroundColor Green
    Write-Host "  Location: $ConfigPath" -ForegroundColor Gray
    Write-Host "  Folders: $folderCount" -ForegroundColor Gray
    Write-Host "  Shortcuts: $shortcutCount" -ForegroundColor Gray
    Write_Log "Config file written: $ConfigPath - $folderCount folders, $shortcutCount shortcuts"

    return [PSCustomObject]@{
        FolderCount = $folderCount
        ShortcutCount = $shortcutCount
        ConfigPath = $ConfigPath
    }
}

function Create_StartMenuBackup {
    param(
        [string]$TargetPath,
        [string]$BackupFolder,
        [string]$Label = "StartMenu"  # "System", "User", or custom label
    )
    # Create zip backup of Start Menu folder (including empty folders)
    
    if (-not (Test-Path $TargetPath)) {
        Write_Log "Backup skipped - path does not exist: $TargetPath"
        return $null
    }
    
    Write-Host "Creating $Label backup..." -ForegroundColor Gray
    Write-Progress -Activity "Creating Backups" -Status "Creating $Label backup..." -PercentComplete 50
    $backupPath = Join-Path $BackupFolder "$($Label)Backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').zip"
    
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        if (Test-Path $backupPath) { Remove-Item $backupPath -Force }
        [System.IO.Compression.ZipFile]::CreateFromDirectory($TargetPath, $backupPath, [System.IO.Compression.CompressionLevel]::Optimal, $true)
        Write-Progress -Activity "Creating Backups" -Status "$Label backup complete" -PercentComplete 100
        Write-Host "  ✅ Backup: $backupPath" -ForegroundColor Green
        Write_Log "Backup created: $backupPath"
        Write-Progress -Activity "Creating Backups" -Completed
        return $backupPath
    } catch {
        Write-Progress -Activity "Creating Backups" -Completed
        Write-Host "  ❌ Backup failed: $_" -ForegroundColor Red
        Write_Log "Failed to create backup: $_"
        return $null
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
    Show_Banner -Title $Title
    Write-Host ""
    Write-Host "Total Folders: $($folderData.Count)" -ForegroundColor Gray
    Write-Host "Total Shortcuts: $totalShortcuts" -ForegroundColor Gray
    Write-Host ""
    Show_SeparatorLine
    Write-Host ""

    if ($folderData.Count -eq 0) {
        Write-Host "No folders are saved in this configuration yet." -ForegroundColor Yellow
        Write-Host ""
        return
    }

    # Calculate column layout once for ALL items (ensures alignment across directories)
    $layout = Calculate_ColumnLayout -AllItems $allShortcutNames -IndentSpaces 6
    
    # Display folders with shortcuts
    foreach ($folder in $folderData) {
        Write-Host "  $($folder.Name)" -ForegroundColor Yellow -NoNewline
        Write-Host " ($($folder.Count) shortcuts)" -ForegroundColor Gray
        
        if ($folder.Count -gt 0) {
            Format_InColumns -Items $folder.Shortcuts -IndentSpaces 6 -ColumnWidth $layout.ColumnWidth -NumColumns $layout.NumColumns
        } else {
            Write-Host "      (no shortcuts in this folder)" -ForegroundColor DarkGray
        }
        
        Write-Host ""
    }
}

function Calculate_ColumnLayout {
    param(
        [string[]]$AllItems,
        [int]$IndentSpaces = 6,
        [int]$MinColumnWidth = 25,
        [int]$ColumnPadding = 4,
        [int]$MaxColumnWidth = 42
    )
    
    # Use cached console width (optimization: avoid repeated console queries)
    $consoleWidth = $script:consoleWidth
    
    # Calculate available width after indent
    $availableWidth = [Math]::Max($MinColumnWidth, $consoleWidth - $IndentSpaces - 2)
    
    # Find the longest item across ALL directories
    $maxItemLength = 0
    foreach ($item in $AllItems) {
        if ($item.Length -gt $maxItemLength) {
            $maxItemLength = $item.Length
        }
    }
    
    # Cap preferred width so one long shortcut does not collapse the whole list to 1-2 columns.
    $preferredColumnWidth = [Math]::Min(
        [Math]::Max($maxItemLength + $ColumnPadding, $MinColumnWidth),
        $MaxColumnWidth
    )
    
    # Calculate how many columns fit
    $numColumns = [Math]::Max(1, [Math]::Floor($availableWidth / $preferredColumnWidth))
    $columnWidth = [Math]::Max($MinColumnWidth, [Math]::Floor($availableWidth / $numColumns))
    
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
                $contentWidth = if ($col -lt ($NumColumns - 1)) { $ColumnWidth - 2 } else { $ColumnWidth }

                if ($item.Length -gt $contentWidth) {
                    $trimmedWidth = [Math]::Max(1, $contentWidth - 3)
                    $item = $item.Substring(0, $trimmedWidth) + "..."
                }

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

function Scan_UserShortcutsForMigration {
    # Scan user Start Menu and build list of planned migrations (preview only, no file operations)
    
    $plannedMigrations = [System.Collections.Generic.List[hashtable]]::new()
    
    if (-not (Test-Path $userStartMenuPath)) {
        Write-Host "User Start Menu path was not found. Skipping user shortcut migration scan." -ForegroundColor Gray
        return $plannedMigrations
    }
    
    # Get all shortcuts from user location (including Startup folder)
    Write-Progress -Activity "Preparing Enforcement" -Status "Scanning user Start Menu..." -PercentComplete 10
    $userShortcuts = @(Get-ChildItem -Path $userStartMenuPath -Recurse -Filter *.lnk -File -Force)
    
    if ($userShortcuts.Count -eq 0) {
        Write-Host "No user Start Menu shortcuts found to migrate." -ForegroundColor Gray
        Write-Progress -Activity "Preparing Enforcement" -Completed
        return $plannedMigrations
    }
    
    $userShortcutIndex = 0
    foreach ($shortcut in $userShortcuts) {
        $userShortcutIndex++
        $percentComplete = [Math]::Min(30, [Math]::Floor(($userShortcutIndex / $userShortcuts.Count) * 20) + 10)
        Write-Progress -Activity "Preparing Enforcement" -Status "Checking user shortcut $($shortcut.Name)" -PercentComplete $percentComplete

        # Calculate relative path from user start menu
        $basePath = $userStartMenuPath.TrimEnd('\') + '\'
        $relativePath = $shortcut.FullName.Substring($basePath.Length)
        
        # Determine destination in system-wide location
        $destPath = Join-Path $target $relativePath
        
        # Check if destination already exists
        $alreadyExists = Test-Path $destPath
        
        $plannedMigrations.Add(@{
            Name = $shortcut.Name
            Source = $shortcut.FullName
            Destination = $destPath
            RelativePath = $relativePath
            AlreadyExists = $alreadyExists
            Type = if ($alreadyExists) { "Delete" } else { "Migrate" }
        })
    }
    
    Write-Progress -Activity "Preparing Enforcement" -Completed
    return $plannedMigrations
}

function Execute_UserMigrations {
    param($PlannedMigrations, [ref]$SuccessCount, [ref]$ErrorCount)
    
    if ($PlannedMigrations.Count -eq 0) { return }
    
    Show_Banner -Title "User Start Menu Changes"
    
    # Migrate shortcuts
    Write-Host "`nMigrating shortcuts to system-wide location..." -ForegroundColor Gray
    $migrateCount = 0; $deleteCount = 0
    $migrationIndex = 0
    foreach ($migration in $PlannedMigrations) {
        $migrationIndex++
        $percentComplete = [Math]::Min(80, [Math]::Floor(($migrationIndex / $PlannedMigrations.Count) * 70) + 10)
        Write-Progress -Activity "Applying User Start Menu Changes" -Status "Processing $($migration.Name)" -PercentComplete $percentComplete
        try {
            Ensure_Folder (Split-Path $migration.Destination -Parent)
            if ($migration.AlreadyExists) {
                Remove-Item -Path $migration.Source -Force -ErrorAction Stop
                Write-Host "  🗑️  $($migration.Name.PadRight(40)) [Already exists in system]" -ForegroundColor Magenta
                Write_Log "Deleted user shortcut: $($migration.Name) - exists at $($migration.RelativePath)"; $deleteCount++
            } else {
                Move-Item -Path $migration.Source -Destination $migration.Destination -Force -ErrorAction Stop
                Write-Host "  ✅ $($migration.Name.PadRight(40)) -> $($migration.RelativePath)" -ForegroundColor Green
                Write_Log "Migrated: $($migration.Name) to $($migration.RelativePath)"; $migrateCount++
            }
            $SuccessCount.Value++
        } catch {
            Write-Host "  ❌ $($migration.Name.PadRight(40)) [Error: $_]" -ForegroundColor Red
            Write_Log "Migration failed: $($migration.Name) - $_"; $ErrorCount.Value++
        }
    }
    Write-Host "  Migrated: $migrateCount, Deleted (duplicates): $deleteCount" -ForegroundColor Gray
    
    # Clean up empty user folders (preserve Programs\Startup)
    Write-Host "`nCleaning up empty folders..." -ForegroundColor Gray
    $startupPath = Join-Path $userStartMenuPath "Programs\Startup"
    $basePath = $userStartMenuPath.TrimEnd('\') + '\'
    $cleanedCount = 0
    $preservedShown = $false
    
    $userFolders = @(Get-ChildItem -Path $userStartMenuPath -Directory -Recurse -Force -ErrorAction SilentlyContinue | 
        Sort-Object { $_.FullName.Split('\').Count } -Descending)
    $folderIndex = 0
    foreach ($userFolder in $userFolders) {
        $folderIndex++
        $percentComplete = if ($userFolders.Count -gt 0) { [Math]::Min(99, [Math]::Floor(($folderIndex / $userFolders.Count) * 19) + 80) } else { 99 }
        Write-Progress -Activity "Applying User Start Menu Changes" -Status "Cleaning empty folders..." -PercentComplete $percentComplete
        if ($userFolder.FullName -eq $startupPath) {
            if (-not $preservedShown) { Write-Host "  📌 Preserved: Programs\Startup" -ForegroundColor Yellow; $preservedShown = $true }
            continue
        }
        $items = @(Get-ChildItem -Path $userFolder.FullName -Force -ErrorAction SilentlyContinue)
        if ($items.Count -eq 0) {
            try {
                Remove-Item -Path $userFolder.FullName -Force -ErrorAction Stop
                $rel = $userFolder.FullName.Substring($basePath.Length)
                Write-Host "  🗑️  Removed: $rel" -ForegroundColor Magenta
                Write_Log "Removed empty user folder: $rel"; $cleanedCount++
            } catch { Write_Log "Could not remove: $($userFolder.FullName) - $_" }
        }
    }
    Write-Progress -Activity "Applying User Start Menu Changes" -Completed
    if ($cleanedCount -eq 0) { Write-Host "  (none)" -ForegroundColor Gray }
    Write-Host ""
}

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
    $configFolders = @($ConfigRaw.PSObject.Properties.Name)
    
    # Single pass: build all data structures at once
    $configFolderIndex = 0
    foreach ($folderKey in $configFolders) {
        $configFolderIndex++
        $percentComplete = if ($configFolders.Count -gt 0) { [Math]::Min(45, [Math]::Floor(($configFolderIndex / $configFolders.Count) * 15) + 30) } else { 45 }
        Write-Progress -Activity "Preparing Enforcement" -Status "Reading config folder $folderKey" -PercentComplete $percentComplete

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
    foreach ($folderKey in $configFolders) {
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
    Write-Progress -Activity "Preparing Enforcement" -Status "Config lookup ready" -PercentComplete 45
    
    return @{
        AllConfigShortcuts = $allConfigShortcuts
        ExpectedMap = $expectedMap
        ShortcutDetailsMap = $shortcutDetailsMap
    }
}

function Scan_AndOrganizeShortcuts {
    param([string]$TargetPath, [hashtable]$AllConfigShortcuts, [hashtable]$ExpectedMap, [string]$QuarantineFolder)
    
    Write-Host "Scanning shortcuts at $TargetPath..." -ForegroundColor Gray
    Write-Progress -Activity "Preparing Enforcement" -Status "Scanning system Start Menu..." -PercentComplete 50
    $allShortcuts = @(Get-ChildItem -Path $TargetPath -Recurse -Filter *.lnk -File -Force)
    
    $actualIndex = @{}; $processed = @{}; $foldersToCheck = @{}; $quarantineCounter = @{}
    $plannedMoves = [System.Collections.Generic.List[hashtable]]::new([Math]::Max(10, $allShortcuts.Count / 10))
    $plannedDeletes = [System.Collections.Generic.List[hashtable]]::new(10)
    $qFolder = Join-Path $TargetPath $QuarantineFolder

    # Helper: Create numbered quarantine name
    $GetNumberedName = {
        param($name, $norm)
        if (-not $quarantineCounter.ContainsKey($norm)) { $quarantineCounter[$norm] = 0 }
        $quarantineCounter[$norm]++
        $base = [System.IO.Path]::GetFileNameWithoutExtension($name)
        $ext = [System.IO.Path]::GetExtension($name)
        return "$base ($($quarantineCounter[$norm]))$ext"
    }
    
    # Helper: Add quarantine move
    $AddQuarantine = {
        param($file, $newName, $folder)
        $dest = Join-Path $qFolder $(if ($newName) { $newName } else { $file.Name })
        $plannedMoves.Add(@{ Type = "Quarantine"; Source = $file.FullName; Destination = $dest; Name = $file.Name
            NewName = $newName; CurrentFolder = $folder; DestFolder = $QuarantineFolder })
    }
    
    # Helper: Remove conflicting planned move
    $RemoveConflictingMove = {
        param($sourcePath, $name)
        for ($i = $plannedMoves.Count - 1; $i -ge 0; $i--) {
            if ($plannedMoves[$i].Source -eq $sourcePath) {
                Write_Log "  -> Removing conflicting planned move for '$name'"
                $plannedMoves.RemoveAt($i); break
            }
        }
    }

    Write-Host "Processing $($allShortcuts.Count) shortcuts..." -ForegroundColor Gray

    $systemShortcutIndex = 0
    foreach ($item in $allShortcuts) {
        $systemShortcutIndex++
        $percentComplete = if ($allShortcuts.Count -gt 0) { [Math]::Min(80, [Math]::Floor(($systemShortcutIndex / $allShortcuts.Count) * 30) + 50) } else { 80 }
        Write-Progress -Activity "Preparing Enforcement" -Status "Checking $($item.Name)" -PercentComplete $percentComplete

        $norm = Normalize_ShortcutName $item.Name
        $matchKey = Get_ShortcutMatchKey -shortcutName $item.Name -AllConfigShortcuts $AllConfigShortcuts -ExpectedMap $ExpectedMap
        $indexKey = if ($matchKey -and $matchKey -eq $item.Name) { $item.Name } else { $norm }
    
        # Handle duplicates
        if ($actualIndex.ContainsKey($indexKey)) {
            $existing = $actualIndex[$indexKey]
            Write_Log "Duplicate found: '$($item.Name)' at $($item.DirectoryName) clashes with '$($existing.Name)' at $($existing.DirectoryName)"
            
            $correctFolder = if ($matchKey -and $ExpectedMap.ContainsKey($matchKey)) { $ExpectedMap[$matchKey] }
                else { $ek = Get_ShortcutMatchKey -shortcutName $existing.Name -AllConfigShortcuts $AllConfigShortcuts -ExpectedMap $ExpectedMap
                       if ($ek -and $ExpectedMap.ContainsKey($ek)) { $ExpectedMap[$ek] } else { $null } }
            
            $itemFolder = Get_RelativePath $item.DirectoryName
            $existingFolder = Get_RelativePath $existing.DirectoryName
            
            if ($correctFolder) {
                # Known shortcut duplicate handling
                $itemCorrect = $itemFolder -eq $correctFolder
                $existingCorrect = $existingFolder -eq $correctFolder
                
                if (-not $itemCorrect -and $existingCorrect) {
                    Write_Log "  -> Deleting duplicate from wrong location: '$($item.Name)' at $itemFolder"
                    $plannedDeletes.Add(@{ Path = $item.FullName; Name = $item.Name; Folder = $itemFolder })
                    $foldersToCheck[$item.DirectoryName] = $true; continue
                } elseif ($itemCorrect -and -not $existingCorrect) {
                    Write_Log "  -> Deleting duplicate from wrong location: '$($existing.Name)' at $existingFolder"
                    & $RemoveConflictingMove $existing.FullName $existing.Name
                    $plannedDeletes.Add(@{ Path = $existing.FullName; Name = $existing.Name; Folder = $existingFolder })
                    $foldersToCheck[$existing.DirectoryName] = $true; $actualIndex[$indexKey] = $item
                } else {
                    Write_Log "  -> Deleting duplicate: '$($item.Name)' at $itemFolder"
                    $plannedDeletes.Add(@{ Path = $item.FullName; Name = $item.Name; Folder = $itemFolder })
                    $foldersToCheck[$item.DirectoryName] = $true; continue
                }
            } else {
                # Unknown shortcut duplicate - quarantine with numbered names
                Write_Log "  -> Both duplicates are unknown. Will quarantine with numbered names."
                $itemInQ = $item.DirectoryName -eq $qFolder
                $existingInQ = $existing.DirectoryName -eq $qFolder
                
                if ($existingInQ -and -not $itemInQ) {
                    $numberedName = & $GetNumberedName $item.Name $norm
                    & $AddQuarantine $item $numberedName $itemFolder
                    Write_Log "  -> Will quarantine '$($item.Name)' as '$numberedName'"; continue
                } elseif ($itemInQ -and -not $existingInQ) {
                    & $RemoveConflictingMove $existing.FullName $existing.Name
                    $numberedName = & $GetNumberedName $existing.Name $norm
                    & $AddQuarantine $existing $numberedName (Get_RelativePath $existing.DirectoryName)
                    Write_Log "  -> Will quarantine '$($existing.Name)' as '$numberedName'"; $actualIndex[$indexKey] = $item
                } else {
                    $numberedName = & $GetNumberedName $item.Name $norm
                    & $AddQuarantine $item $numberedName $itemFolder
                    Write_Log "  -> Will quarantine '$($item.Name)' as '$numberedName'"; continue
                }
            }
        }
        $actualIndex[$indexKey] = $item
    
        if ($matchKey) {
            # Known shortcut: move to correct folder
            $relFolder = $ExpectedMap[$matchKey]
            $destFolder = if ($relFolder -eq "Root" -or [string]::IsNullOrEmpty($relFolder)) { $TargetPath } else { Join-Path $TargetPath $relFolder }
            $destPath = Join-Path $destFolder $item.Name
            
            if ($item.FullName -ne $destPath) {
                $plannedMoves.Add(@{ Type = "Move"; Source = $item.FullName; Destination = $destPath
                    Name = $item.Name; CurrentFolder = (Get_RelativePath $item.DirectoryName); DestFolder = $relFolder })
                $foldersToCheck[$item.DirectoryName] = $true
            }
            $processed[$matchKey] = $true
        } else {
            # Unknown shortcut: quarantine
            $qDest = Join-Path $qFolder $item.Name
            if ($item.FullName -ne $qDest) {
                $plannedMoves.Add(@{ Type = "Quarantine"; Source = $item.FullName; Destination = $qDest
                    Name = $item.Name; CurrentFolder = (Get_RelativePath $item.DirectoryName); DestFolder = $QuarantineFolder })
            }
        }
    }
    Write-Progress -Activity "Preparing Enforcement" -Status "System scan complete" -PercentComplete 80
    
    return @{ PlannedMoves = $plannedMoves; PlannedDeletes = $plannedDeletes; Processed = $processed; FoldersToCheck = $foldersToCheck }
}

function Detect_MissingShortcuts {
    param([hashtable]$ExpectedMap, [hashtable]$Processed, [hashtable]$ShortcutDetailsMap)
    
    $missingShortcuts = [System.Collections.Generic.List[hashtable]]::new(10)
    $seenMissing = @{}
    $expectedKeys = @($ExpectedMap.Keys)
    
    $expectedKeyIndex = 0
    foreach ($normName in $expectedKeys) {
        $expectedKeyIndex++
        $percentComplete = if ($expectedKeys.Count -gt 0) { [Math]::Min(90, [Math]::Floor(($expectedKeyIndex / $expectedKeys.Count) * 10) + 80) } else { 90 }
        Write-Progress -Activity "Preparing Enforcement" -Status "Checking for missing shortcuts..." -PercentComplete $percentComplete

        if ($Processed.ContainsKey($normName)) { continue }
        $folder = $ExpectedMap[$normName]
        $key = "$folder\$normName"
        if ($seenMissing[$key]) { continue }
        $seenMissing[$key] = $true
        
        Write_Log "**Missing expected shortcut:** $normName (expected in $folder)"
        $details = $ShortcutDetailsMap[$key]
        if ($details -and $details.TargetPath) {
            $missingShortcuts.Add(@{ Name = $normName; Folder = $folder; Details = $details })
        } else { Write_Log "  Cannot recreate - no saved details for $normName" }
    }
    return $missingShortcuts
}

function Detect_EmptyFolders {
    param([string]$TargetPath, [PSCustomObject]$ConfigRaw, $PlannedMoves = @(), $PlannedDeletes = @(), $FoldersCreatedByMigration = $null)
    
    $emptyFoldersToDelete = [System.Collections.Generic.List[hashtable]]::new(5)
    $seenFolders = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    
    # Build set of preserved folders (NEVER delete these)
    $preservedFolders = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    # 1. The target path itself and its Programs subfolder (critical system folders)
    $preservedFolders.Add($TargetPath) | Out-Null
    $preservedFolders.Add((Join-Path $TargetPath "Programs")) | Out-Null
    $preservedFolders.Add((Join-Path $TargetPath "Programs\Startup")) | Out-Null  # Always preserve Startup folder
    # 2. All folders defined in config (expected folder structure)
    $ConfigRaw.PSObject.Properties.Name | Where-Object { $_ -ne "Root" -and $_ } | ForEach-Object { $preservedFolders.Add((Join-Path $TargetPath $_)) | Out-Null }
    
    # Track folders losing/receiving files
    $foldersBeingEmptied = @{}
    $foldersReceivingFiles = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    
    foreach ($move in @($PlannedMoves)) {
        $src = Split-Path $move.Source -Parent
        if (-not $foldersBeingEmptied[$src]) { $foldersBeingEmptied[$src] = @() }
        $foldersBeingEmptied[$src] += $move.Source
        $foldersReceivingFiles.Add((Split-Path $move.Destination -Parent)) | Out-Null
    }
    foreach ($delete in @($PlannedDeletes)) {
        $src = Split-Path $delete.Path -Parent
        if (-not $foldersBeingEmptied[$src]) { $foldersBeingEmptied[$src] = @() }
        $foldersBeingEmptied[$src] += $delete.Path
    }
    
    # Helper to check if folder will be empty
    $WillBeEmpty = {
        param($folderPath, $currentItems)
        if ($currentItems.Count -eq 0) { return $true }
        if (-not $foldersBeingEmptied[$folderPath]) { return $false }
        $remaining = @($currentItems.FullName | Where-Object { $_ -notin $foldersBeingEmptied[$folderPath] })
        return $remaining.Count -eq 0
    }
    
    # Scan existing folders (deepest first)
    $foldersToScan = @(Get-ChildItem -Path $TargetPath -Directory -Recurse -Force -ErrorAction SilentlyContinue | 
        Sort-Object { $_.FullName.Split('\').Count } -Descending)
    $folderScanIndex = 0
    foreach ($folder in $foldersToScan) {
        $folderScanIndex++
        $percentComplete = if ($foldersToScan.Count -gt 0) { [Math]::Min(98, [Math]::Floor(($folderScanIndex / $foldersToScan.Count) * 8) + 90) } else { 98 }
        Write-Progress -Activity "Preparing Enforcement" -Status "Checking empty folders..." -PercentComplete $percentComplete

        if ($seenFolders.Contains($folder.FullName) -or $preservedFolders.Contains($folder.FullName) -or 
            $foldersReceivingFiles.Contains($folder.FullName)) { continue }
        
        $items = @(Get-ChildItem -Path $folder.FullName -Force -ErrorAction SilentlyContinue)
        if (& $WillBeEmpty $folder.FullName $items) {
            Write_Log "Empty folder found: $(Get_RelativePath $folder.FullName)"
            $seenFolders.Add($folder.FullName) | Out-Null
            $emptyFoldersToDelete.Add(@{ Path = $folder.FullName; DisplayFolder = (Get_RelativePath $folder.FullName) })
        }
    }
    
    # Also check folders that will be CREATED by migrations (they may end up empty after moves)
    if ($FoldersCreatedByMigration) {
        foreach ($folderPath in $FoldersCreatedByMigration) {
            # Skip preserved folders and folders that will receive files
            if ($seenFolders.Contains($folderPath) -or $preservedFolders.Contains($folderPath) -or 
                $foldersReceivingFiles.Contains($folderPath)) { continue }
            
            # Safety: Never delete folders at or above the "Programs" level (must be at least 2 levels deep)
            $relPath = Get_RelativePath $folderPath
            if ($relPath -eq "Root" -or $relPath -eq "Programs" -or -not $relPath.Contains('\')) { continue }
            
            # This folder will be created by migration - check if all its contents will be moved out
            if ($foldersBeingEmptied[$folderPath]) {
                # Folder will have files migrated in, then moved out - it will be empty
                Write_Log "Empty folder found (post-migration): $relPath"
                $seenFolders.Add($folderPath) | Out-Null
                $emptyFoldersToDelete.Add(@{ Path = $folderPath; DisplayFolder = $relPath })
            }
        }
    }
    
    Write-Progress -Activity "Preparing Enforcement" -Completed
    return $emptyFoldersToDelete
}

function Display_PreviewSection {
    # Helper to display a preview section with consistent formatting
    param([string]$Title, [string]$Color, [array]$Items, [scriptblock]$FormatItem)
    
    if ($Items.Count -eq 0) { return }
    Write_Log "$Title ($($Items.Count)):" -Color $Color -ToScreen
    foreach ($item in $Items) { & $FormatItem $item }
    Write-Host ""
}

function Display_EnforcePreview {
    param($PlannedMoves, $PlannedDeletes, $EmptyFoldersToDelete, $MissingShortcuts, $PlannedUserMigrations, [bool]$DryRun)
    
    if (-not $DryRun) { return $true }  # Automated mode, proceed
    
    Show_EnforceActionSummary -PlannedMoves $PlannedMoves `
        -PlannedDeletes $PlannedDeletes `
        -EmptyFoldersToDelete $EmptyFoldersToDelete `
        -MissingShortcuts $MissingShortcuts `
        -PlannedUserMigrations $PlannedUserMigrations
    Show_ColorLegend

    Show_Banner -Title "Summary - Planned Changes"
    Write-Host ""
    
    # User migrations (Green = positive, Magenta = deletions)
    $toMigrate = @($PlannedUserMigrations | Where-Object { $_.Type -eq "Migrate" })
    $toDeleteUser = @($PlannedUserMigrations | Where-Object { $_.Type -eq "Delete" })
    Display_PreviewSection "USER SHORTCUTS TO MIGRATE" "Green" $toMigrate {
        param($m); Write-Host (Format_ActionLine -Emoji "📥" -Name $m.Name -Operation "[Migrate]" -Destination $m.RelativePath) -ForegroundColor Green
        Write_Log "  - $($m.Name) -> $($m.RelativePath)"
    }
    Display_PreviewSection "USER SHORTCUTS TO DELETE (already in system)" "Magenta" $toDeleteUser {
        param($m); Write-Host (Format_ActionLine -Emoji "🗑️" -Name $m.Name -Operation "[Delete]" -Destination "(exists in system)") -ForegroundColor Magenta
        Write_Log "  - $($m.Name) [already exists at $($m.RelativePath)]"
    }
    
    # System moves, recreations, quarantines
    $toMove = @($PlannedMoves | Where-Object { $_.Type -eq "Move" })
    $toQuarantine = @($PlannedMoves | Where-Object { $_.Type -eq "Quarantine" })
    
    Display_PreviewSection "MOVES TO CORRECT FOLDERS" "Green" $toMove {
        param($m); Write-Host (Format_ActionLine -Emoji "➡️" -Name $m.Name -Operation "[Move]" -Source $m.CurrentFolder -Destination $m.DestFolder) -ForegroundColor Green
        Write_Log "  - $($m.Name) FROM: $($m.CurrentFolder) -> TO: $($m.DestFolder)"
    }
    Display_PreviewSection "MISSING SHORTCUTS TO RECREATE" "Green" @($MissingShortcuts) {
        param($m); Write-Host (Format_ActionLine -Emoji "➕" -Name $m.Name -Operation "[Recreate]" -Destination $m.Folder) -ForegroundColor Green
        Write_Log "  - $($m.Name) IN: $($m.Folder)"
    }
    Display_PreviewSection "UNKNOWN SHORTCUTS TO QUARANTINE" "Yellow" $toQuarantine {
        param($m); $dn = if ($m.NewName) { "$($m.Name) -> $($m.NewName)" } else { $m.Name }
        Write-Host (Format_ActionLine -Emoji "🥅" -Name $dn -Operation "[Quarantine]" -Source $m.CurrentFolder -Destination $m.DestFolder) -ForegroundColor Yellow
        Write_Log "  - $dn FROM: $($m.CurrentFolder) -> TO: $($m.DestFolder)"
    }
    Display_PreviewSection "DUPLICATE SHORTCUTS TO DELETE" "Magenta" @($PlannedDeletes) {
        param($d); Write-Host (Format_ActionLine -Emoji "🎭" -Name $d.Name -Operation "[Delete]" -Destination $d.Folder) -ForegroundColor Magenta
        Write_Log "  - $($d.Name) IN: $($d.Folder)"
    }
    Display_PreviewSection "EMPTY FOLDERS TO DELETE" "Magenta" @($EmptyFoldersToDelete) {
        param($f); Write-Host (Format_ActionLine -Emoji "🗑️" -Name $f.DisplayFolder -Operation "[Delete]") -ForegroundColor Magenta
        Write_Log "  - $($f.DisplayFolder)"
    }
    
    Show_SeparatorLine
    return Confirm_Action -Message "Proceed with these Start Menu changes?"
}

function Execute_PlannedActions {
    # Generic executor for all action types: moves, quarantines, deletes, recreations, folder deletes
    param(
        $Actions,
        [string]$ActionType,  # "Move", "Quarantine", "Delete", "Recreate", "FolderDelete"
        [string]$TargetPath = "",
        [ref]$SuccessCount,
        [ref]$ErrorCount
    )
    
    if ($Actions.Count -eq 0) { return }
    
    # Action type configuration (Green=positive, Yellow=warning, Magenta=deletion)
    $config = switch ($ActionType) {
        "Move"         { @{ Emoji = "➡️"; Op = "[Move]"; Color = "Green"; LogPrefix = "Move" } }
        "Quarantine"   { @{ Emoji = "🥅"; Op = "[Quarantine]"; Color = "Yellow"; LogPrefix = "Quarantine" } }
        "Delete"       { @{ Emoji = "🎭"; Op = "[Delete]"; Color = "Magenta"; LogPrefix = "Deleted duplicate" } }
        "Recreate"     { @{ Emoji = "➕"; Op = "[Recreate]"; Color = "Green"; LogPrefix = "Recreated" } }
        "FolderDelete" { @{ Emoji = "🗑️"; Op = "[Delete]"; Color = "Magenta"; LogPrefix = "Deleted empty folder" } }
    }
    
    # For recreations, we need a COM shell object
    $shell = if ($ActionType -eq "Recreate") { New-Object -ComObject WScript.Shell } else { $null }
    
    $actionIndex = 0
    foreach ($action in $Actions) {
        $actionIndex++
        $percentComplete = if ($Actions.Count -gt 0) { [Math]::Min(99, [Math]::Floor(($actionIndex / $Actions.Count) * 100)) } else { 99 }
        $progressName = if ($action.Name) { $action.Name } elseif ($action.DisplayFolder) { $action.DisplayFolder } else { $ActionType }
        Write-Progress -Activity "Applying $ActionType actions" -Status "Processing $progressName" -PercentComplete $percentComplete

        try {
            $displayName = $action.Name
            $logMsg = ""
            
            switch ($ActionType) {
                "Move" {
                    Ensure_Folder (Split-Path $action.Destination -Parent)
                    Move-Item -Path $action.Source -Destination $action.Destination -Force -ErrorAction Stop
                    $displayName = if ($action.NewName) { "$($action.Name) -> $($action.NewName)" } else { $action.Name }
                    $logMsg = "$($config.LogPrefix): $displayName from $($action.CurrentFolder) to $($action.DestFolder)"
                }
                "Quarantine" {
                    Ensure_Folder (Split-Path $action.Destination -Parent)
                    Move-Item -Path $action.Source -Destination $action.Destination -Force -ErrorAction Stop
                    $displayName = if ($action.NewName) { "$($action.Name) -> $($action.NewName)" } else { $action.Name }
                    $logMsg = "$($config.LogPrefix): $displayName from $($action.CurrentFolder) to $($action.DestFolder)"
                }
                "Delete" {
                    Remove-Item -Path $action.Path -Force -ErrorAction Stop
                    $logMsg = "$($config.LogPrefix): $($action.Name) from $($action.Folder)"
                }
                "Recreate" {
                    $folder = if ($action.Folder -eq "Root" -or [string]::IsNullOrEmpty($action.Folder)) { $TargetPath } else { Join-Path $TargetPath $action.Folder }
                    Ensure_Folder $folder
                    $sc = $shell.CreateShortcut((Join-Path $folder $action.Name))
                    $sc.TargetPath = $action.Details.TargetPath
                    if ($action.Details.Arguments) { $sc.Arguments = $action.Details.Arguments }
                    if ($action.Details.WorkingDirectory) { $sc.WorkingDirectory = $action.Details.WorkingDirectory }
                    if ($action.Details.IconLocation) { $sc.IconLocation = $action.Details.IconLocation }
                    if ($action.Details.Description) { $sc.Description = $action.Details.Description }
                    $sc.Save()
                    $logMsg = "$($config.LogPrefix): $($action.Name) in $($action.Folder)"
                }
                "FolderDelete" {
                    $items = Get-ChildItem -Path $action.Path -Force -ErrorAction SilentlyContinue
                    if ($null -ne $items -and $items.Count -gt 0) {
                        # Folder not empty - skip with warning
                        $line = Format_ActionLine -Emoji $config.Emoji -Name $action.DisplayFolder -Operation $config.Op -StatusEmoji "⚠️"
                        Write-Host $line -ForegroundColor Yellow
                        Write_Log "Skipped deletion (folder not empty): $($action.DisplayFolder)"
                        continue
                    }
                    Remove-Item -Path $action.Path -Force -ErrorAction Stop
                    $displayName = $action.DisplayFolder
                    $logMsg = "$($config.LogPrefix): $($action.DisplayFolder)"
                }
            }
            
            # Success output
            $src = if ($action.CurrentFolder) { $action.CurrentFolder } else { "" }
            $dst = if ($action.DestFolder) { $action.DestFolder } elseif ($action.Folder) { $action.Folder } elseif ($action.DisplayFolder) { "" } else { "" }
            $line = Format_ActionLine -Emoji $config.Emoji -Name $displayName -Operation $config.Op -Source $src -Destination $dst -StatusEmoji "✅"
            Write-Host $line -ForegroundColor $config.Color
            Write_Log $logMsg
            $SuccessCount.Value++
        } catch {
            # Error output
            $line = Format_ActionLine -Emoji $config.Emoji -Name $displayName -Operation $config.Op -StatusEmoji "❌"
            Write-Host $line -ForegroundColor Red
            Write_Log "$($config.LogPrefix) failed: $displayName - $_"
            $ErrorCount.Value++
        }
    }
    
    if ($shell) { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($shell) | Out-Null }
    Write-Progress -Activity "Applying $ActionType actions" -Completed
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
        Show_SeparatorLine
        $proceed = Confirm_Action -Message "Save these changes to the Start Menu config?"
        Write-Host ""
    }
    
    if (-not $proceed) {
        Write_Log "Save operation cancelled by user" -Color Yellow -ToScreen
        Show_FinalSummary -Title "Save Cancelled" -Details ([ordered]@{
            "Changed" = "Nothing"
            "Status" = "Config save was cancelled before writing changes"
            "Config path" = $configPath
            "Log path" = $logPath
        })
        return
    }
    
    # Save config file
    $saveStats = Save_ConfigFile -ConfigTree $sortedTree -ConfigPath $configPath
    
    # Create backup
    $backupPath = Create_StartMenuBackup -TargetPath $target -BackupFolder (Split-Path $configPath -Parent) -Label "SystemStartMenu"
    
    # Display the saved configuration
    Write-Host ""
    $savedConfig = Get-Content $configPath -Raw | ConvertFrom-Json
    Display_Config -Config $savedConfig -Title "SAVED CONFIGURATION"

    Show_FinalSummary -Title "Save Complete" -Details ([ordered]@{
        "Changed" = $(if ($changesFound) { "Config updated from current Start Menu" } else { "No previous differences found" })
        "Folders" = $saveStats.FolderCount
        "Shortcuts" = $saveStats.ShortcutCount
        "Config path" = $saveStats.ConfigPath
        "Backup path" = $(if ($backupPath) { $backupPath } else { "Backup was not created" })
        "Log path" = $logPath
        "Next step" = "Use READ to review or ENFORCE to organize the Start Menu"
    })
}

function Invoke_ReadMode {
    if (-not (Test-Path $configPath)) {
        Show_FinalSummary -Title "Config Not Found" -Details ([ordered]@{
            "Status" = "There is no saved Start Menu config yet"
            "Expected path" = $configPath
            "Next step" = "Run SAVE first to create the config"
        })
        return
    }
    
    Write-Host "Reading config file..." -ForegroundColor Gray
    Write_Log "Reading config: $configPath"
    
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    
    Write-Host "Config File: $configPath" -ForegroundColor Gray
    Display_Config -Config $config
    
    Write_Log "Displayed config structure"
}


function Invoke_EnforceMode {
    if (-not (Test-Path $configPath)) {
        Show_FinalSummary -Title "Config Not Found" -Details ([ordered]@{
            "Status" = "ENFORCE needs a saved config before it can organize the Start Menu"
            "Expected path" = $configPath
            "Next step" = "Run SAVE first to create the config"
        })
        return
    }
    
    # First, scan user shortcuts for migration (preview only, no file operations yet)
    $plannedUserMigrations = Scan_UserShortcutsForMigration
    
    $configRaw = Get-Content $configPath -Raw | ConvertFrom-Json
    
    # Build config lookup tables
    $configData = Build_ConfigLookupTable -ConfigRaw $configRaw -TargetPath $target
    
    # Scan and organize shortcuts (existing system shortcuts)
    $scanResults = Scan_AndOrganizeShortcuts -TargetPath $target `
        -AllConfigShortcuts $configData.AllConfigShortcuts `
        -ExpectedMap $configData.ExpectedMap `
        -QuarantineFolder $quarantineFolder
    
    # Also plan moves for user shortcuts that will be migrated (they'll need organizing too)
    # This ensures migrated shortcuts end up in the correct folder per config
    # Also track folders that will be created by migrations (for empty folder detection)
    $foldersCreatedByMigration = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    
    foreach ($migration in @($plannedUserMigrations)) {
        if ($migration.Type -eq "Migrate") {
            # Track folder that will be created by this migration
            $migrationDestFolder = Split-Path $migration.Destination -Parent
            $foldersCreatedByMigration.Add($migrationDestFolder) | Out-Null
            
            # Check if this shortcut needs to be moved after migration
            $matchKey = Get_ShortcutMatchKey -shortcutName $migration.Name `
                -AllConfigShortcuts $configData.AllConfigShortcuts -ExpectedMap $configData.ExpectedMap
            
            if ($matchKey -and $configData.ExpectedMap.ContainsKey($matchKey)) {
                $expectedFolder = $configData.ExpectedMap[$matchKey]
                $expectedFullPath = if ($expectedFolder -eq "Root" -or [string]::IsNullOrEmpty($expectedFolder)) {
                    $target
                } else {
                    Join-Path $target $expectedFolder
                }
                $expectedDestPath = Join-Path $expectedFullPath $migration.Name
                
                # Mark as processed - migrated shortcuts don't need recreation
                $scanResults.Processed[$matchKey] = $true
                
                # If migration destination differs from expected location, also plan a move
                if ($migration.Destination -ne $expectedDestPath) {
                    $migrationFolder = Get_RelativePath $migrationDestFolder
                    $scanResults.PlannedMoves.Add(@{
                        Type = "Move"
                        Source = $migration.Destination  # Source is where migration puts it
                        Destination = $expectedDestPath
                        Name = $migration.Name
                        CurrentFolder = $migrationFolder
                        DestFolder = $expectedFolder
                    })
                }
            } else {
                # Unknown shortcut being migrated - will need quarantine after migration
                $migrationFolder = Get_RelativePath $migrationDestFolder
                $qDest = Join-Path $target $quarantineFolder | Join-Path -ChildPath $migration.Name
                
                if ($migration.Destination -ne $qDest) {
                    $scanResults.PlannedMoves.Add(@{
                        Type = "Quarantine"
                        Source = $migration.Destination
                        Destination = $qDest
                        Name = $migration.Name
                        CurrentFolder = $migrationFolder
                        DestFolder = $quarantineFolder
                    })
                }
            }
        }
    }
    
    # Detect missing shortcuts that need recreation
    $missingShortcuts = Detect_MissingShortcuts -ExpectedMap $configData.ExpectedMap `
        -Processed $scanResults.Processed `
        -ShortcutDetailsMap $configData.ShortcutDetailsMap
    
    # Detect empty folders (pass planned moves, deletes, and folders created by migrations)
    $emptyFoldersToDelete = Detect_EmptyFolders -TargetPath $target -ConfigRaw $configRaw `
        -PlannedMoves $scanResults.PlannedMoves -PlannedDeletes $scanResults.PlannedDeletes `
        -FoldersCreatedByMigration $foldersCreatedByMigration
    
    # Check if there are any changes
    $hasChanges = ($scanResults.PlannedMoves.Count -gt 0 -or $scanResults.PlannedDeletes.Count -gt 0 -or `
                   $emptyFoldersToDelete.Count -gt 0 -or $missingShortcuts.Count -gt 0 -or `
                   $plannedUserMigrations.Count -gt 0)
    
    if (-not $hasChanges) {
        Write_Log "No changes needed - all shortcuts are already in correct locations!" -Color Green -ToScreen
        Show_FinalSummary -Title "No Changes Needed" -Details ([ordered]@{
            "Changed" = "Nothing"
            "Status" = "Your Start Menu already matches the saved config"
            "Config path" = $configPath
            "Log path" = $logPath
            "Next step" = "You can close this window or choose another mode"
        })
        return
    }
    
    # Display preview and get confirmation
    # Use @() to prevent PowerShell from unwrapping single-item collections
    $proceed = Display_EnforcePreview -PlannedMoves @($scanResults.PlannedMoves) `
        -PlannedDeletes @($scanResults.PlannedDeletes) `
        -EmptyFoldersToDelete @($emptyFoldersToDelete) `
        -MissingShortcuts @($missingShortcuts) `
        -PlannedUserMigrations @($plannedUserMigrations) `
        -DryRun $dryRun
    
    # If user cancelled, exit early
    if (-not $proceed) {
        Write_Log "Operation cancelled by user" -Color Yellow -ToScreen
        Show_FinalSummary -Title "Operation Cancelled" -Details ([ordered]@{
            "Changed" = "Nothing"
            "Status" = "Preview was cancelled before any changes were applied"
            "Config path" = $configPath
            "Log path" = $logPath
        })
        return
    }
    
    # Create backups before making any changes
    $backupFolder = Split-Path $configPath -Parent
    $hasUserChanges = $plannedUserMigrations.Count -gt 0
    $hasSystemChanges = ($scanResults.PlannedMoves.Count -gt 0 -or $scanResults.PlannedDeletes.Count -gt 0 -or 
                         $missingShortcuts.Count -gt 0 -or $emptyFoldersToDelete.Count -gt 0)
    
    Show_Banner -Title "Creating Backups"
    
    $userBackupPath = $null
    $systemBackupPath = $null
    if ($hasUserChanges) {
        $userBackupPath = Create_StartMenuBackup -TargetPath $userStartMenuPath -BackupFolder $backupFolder -Label "UserStartMenu"
    }
    if ($hasSystemChanges) {
        $systemBackupPath = Create_StartMenuBackup -TargetPath $target -BackupFolder $backupFolder -Label "SystemStartMenu"
    }
    if (-not $hasUserChanges -and -not $hasSystemChanges) {
        Write-Host "  No backups needed (no changes planned)" -ForegroundColor Gray
    }
    
    # Execute all changes
    Show_Banner -Title "Execution"
    $successCount = 0
    $errorCount = 0

    # Execute in correct order: user migrations -> moves -> recreations -> quarantines -> duplicate deletes -> folder deletes
    
    # 0. Execute user migrations first (moves user shortcuts to system location)
    if ($plannedUserMigrations.Count -gt 0) {
        Execute_UserMigrations -PlannedMigrations @($plannedUserMigrations) `
            -SuccessCount ([ref]$successCount) -ErrorCount ([ref]$errorCount)
    }
    
    # 1-5. Execute all planned system path actions
    $regularMoves = @($scanResults.PlannedMoves | Where-Object { $_.Type -eq "Move" })
    $quarantineMoves = @($scanResults.PlannedMoves | Where-Object { $_.Type -eq "Quarantine" })
    
    if ($hasSystemChanges) {
        Show_Banner -Title "System Start Menu Changes"
    }
    
    Execute_PlannedActions -Actions $regularMoves -ActionType "Move" -SuccessCount ([ref]$successCount) -ErrorCount ([ref]$errorCount)
    Execute_PlannedActions -Actions @($missingShortcuts) -ActionType "Recreate" -TargetPath $target -SuccessCount ([ref]$successCount) -ErrorCount ([ref]$errorCount)
    Execute_PlannedActions -Actions $quarantineMoves -ActionType "Quarantine" -SuccessCount ([ref]$successCount) -ErrorCount ([ref]$errorCount)
    Execute_PlannedActions -Actions @($scanResults.PlannedDeletes) -ActionType "Delete" -SuccessCount ([ref]$successCount) -ErrorCount ([ref]$errorCount)
    Execute_PlannedActions -Actions @($emptyFoldersToDelete) -ActionType "FolderDelete" -SuccessCount ([ref]$successCount) -ErrorCount ([ref]$errorCount)
    
    # Summary
    Write-Host ""
    Write_Log "Completed! $successCount successful, $errorCount errors." -Color $(if ($errorCount -eq 0) { "Green" } else { "Yellow" }) -ToScreen
    Write_Log "See log: $logPath" -Color Gray -ToScreen
    Show_FinalSummary -Title "Enforce Complete" -Details ([ordered]@{
        "Changed" = "$successCount action(s) completed"
        "Errors" = $errorCount
        "User changes" = "$($plannedUserMigrations.Count) planned"
        "System changes" = "$($regularMoves.Count + $quarantineMoves.Count + $scanResults.PlannedDeletes.Count + $missingShortcuts.Count + $emptyFoldersToDelete.Count) planned"
        "User backup" = $(if ($userBackupPath) { $userBackupPath } else { "Not needed" })
        "System backup" = $(if ($systemBackupPath) { $systemBackupPath } else { "Not needed" })
        "Log path" = $logPath
        "Next step" = $(if ($errorCount -eq 0) { "Review the Start Menu or use READ to view the saved config" } else { "Review errors in the log before running ENFORCE again" })
    })
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

    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Show_ModeExplanation -SelectedMode $currentMode
    
    # Auto-elevate if not running as administrator (required for ENFORCE mode)
    if ($currentMode -eq "ENFORCE") {
        if (-not $isAdmin) {
            $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
            $scriptArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Mode', $currentMode)
            if ($Auto) { $scriptArgs += '-Auto' }

            Show_Banner -Title "Administrator Access Needed" -Color Yellow
            Write-Host "  ENFORCE needs administrator access because it changes the system Start Menu." -ForegroundColor White
            Write-Host "  Windows may ask for permission before the script continues." -ForegroundColor Yellow
            Write-Host ""

            $sudoCmd = Get-Command sudo -ErrorAction SilentlyContinue
            if ($sudoCmd) {
                Write-Host "Using sudo for same-window elevation..." -ForegroundColor Gray
                & sudo $psExe @scriptArgs
                exit 0
            }
            Write-Host "Sudo is not enabled, so the elevated run will open in a new window." -ForegroundColor Yellow
            Write-Host "Tip: enable sudo in Settings > System > Advanced if you want same-window elevation later." -ForegroundColor Gray
            Start-Process $psExe -ArgumentList $scriptArgs -Verb RunAs
            exit 0
        }
    }
    
    # Initialize for current run
    Write_Log "`n------------------------------ $(Get-Date) ------------------------------`n"
    Write_Log "MODE: $currentMode, $(if ($interactiveMode) { 'MANUAL' } else { 'AUTOMATED' })" -Color Cyan -ToScreen
    Write-Host ""
    Show_RunStatus -SelectedMode $currentMode -IsAdmin $isAdmin
    
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
