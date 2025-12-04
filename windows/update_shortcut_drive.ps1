<#
.SYNOPSIS
    Updates Windows shortcuts from one path to another.

.DESCRIPTION
    Simple interactive script that scans folders for shortcuts and updates their paths
    from a source path to a destination path. Works with drive letters or full paths.
#>

# ============================================
# CONFIGURATION - Edit these paths as needed
# ============================================
$SourcePath = "D:\"
$DestinationPath = "E:\"
# ============================================

Write-Host "`n=== Shortcut Path Updater ===" -ForegroundColor Cyan
Write-Host "Replacing: $SourcePath -> $DestinationPath" -ForegroundColor Yellow
Write-Host ""

# Normalize paths (ensure backslash at end for consistency)
if ($SourcePath -notmatch '\\$') {
    $SourcePath = $SourcePath + '\'
}
if ($DestinationPath -notmatch '\\$') {
    $DestinationPath = $DestinationPath + '\'
}

# Escape special regex characters in paths
$SourcePathEscaped = [regex]::Escape($SourcePath)

# Initialize COM object for working with shortcuts (once at the start)
$WshShell = New-Object -ComObject WScript.Shell

do {
    Write-Host ""
    
    # Ask user for folder path
    $FolderPath = Read-Host "Enter the path to the folder containing shortcuts"
    
    # Validate path
    if (-not (Test-Path $FolderPath)) {
        Write-Host "Error: Path not found!" -ForegroundColor Red
        Write-Host ""
        Write-Host "Try another folder? (Y/N): " -ForegroundColor Yellow -NoNewline
        $Retry = Read-Host
        if ($Retry -eq "Y" -or $Retry -eq "y") {
            continue
        } else {
            break
        }
    }

    # Find all shortcuts
    Write-Host "`nScanning for shortcuts..." -ForegroundColor Yellow
    $Shortcuts = Get-ChildItem -Path $FolderPath -Filter "*.lnk" -Recurse -ErrorAction SilentlyContinue
    
    if ($Shortcuts.Count -eq 0) {
        Write-Host "No shortcuts found in the specified folder." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Try another folder? (Y/N): " -ForegroundColor Yellow -NoNewline
        $Retry = Read-Host
        if ($Retry -eq "Y" -or $Retry -eq "y") {
            continue
        } else {
            break
        }
    }

    # Analyze shortcuts
    $ToUpdate = @()
    
    foreach ($ShortcutFile in $Shortcuts) {
        try {
            $Shortcut = $WshShell.CreateShortcut($ShortcutFile.FullName)
            $Target = $Shortcut.TargetPath
            $WorkingDir = $Shortcut.WorkingDirectory
            
            $NeedsUpdate = $false
            $NewTarget = $Target
            $NewWorkingDir = $WorkingDir
            
            if ($Target -match "^$SourcePathEscaped") {
                $NewTarget = $Target -replace "^$SourcePathEscaped", $DestinationPath
                $NeedsUpdate = $true
            }
            
            if ($WorkingDir -match "^$SourcePathEscaped") {
                $NewWorkingDir = $WorkingDir -replace "^$SourcePathEscaped", $DestinationPath
                $NeedsUpdate = $true
            }
            
            if ($NeedsUpdate) {
                $ToUpdate += [PSCustomObject]@{
                    File = $ShortcutFile.FullName
                    OldTarget = $Target
                    NewTarget = $NewTarget
                    OldWorkingDir = $WorkingDir
                    NewWorkingDir = $NewWorkingDir
                }
            }
        } catch {
            Write-Host "Warning: Could not read $($ShortcutFile.Name)" -ForegroundColor DarkGray
        }
    }
    
    # Show what will be changed
    if ($ToUpdate.Count -eq 0) {
        Write-Host "`nNo shortcuts pointing to $SourcePath found." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Try another folder? (Y/N): " -ForegroundColor Yellow -NoNewline
        $Retry = Read-Host
        if ($Retry -eq "Y" -or $Retry -eq "y") {
            continue
        } else {
            break
        }
    }

    Write-Host "`nFound $($ToUpdate.Count) shortcut(s) to update:" -ForegroundColor Green
    Write-Host ""
    
    foreach ($Item in $ToUpdate) {
        Write-Host "Shortcut: $($Item.File)" -ForegroundColor White
        
        if ($Item.OldTarget -ne $Item.NewTarget) {
            Write-Host "  Target:" -ForegroundColor Yellow
            Write-Host "    Old: $($Item.OldTarget)" -ForegroundColor Red
            Write-Host "    New: $($Item.NewTarget)" -ForegroundColor Green
        }
        
        if ($Item.OldWorkingDir -ne $Item.NewWorkingDir) {
            Write-Host "  Start in:" -ForegroundColor Yellow
            Write-Host "    Old: $($Item.OldWorkingDir)" -ForegroundColor Red
            Write-Host "    New: $($Item.NewWorkingDir)" -ForegroundColor Green
        }
        
        Write-Host ""
    }
    
    # Ask for consent
    Write-Host "Do you want to proceed with these changes? (Y/N): " -ForegroundColor Yellow -NoNewline
    $Consent = Read-Host
    
    if ($Consent -ne "Y" -and $Consent -ne "y") {
        Write-Host "`nOperation cancelled by user." -ForegroundColor Yellow
    } else {
        # Apply changes
        Write-Host "`nUpdating shortcuts..." -ForegroundColor Green
        $Updated = 0
        $Failed = 0
        
        foreach ($Item in $ToUpdate) {
            try {
                $Shortcut = $WshShell.CreateShortcut($Item.File)
                $Shortcut.TargetPath = $Item.NewTarget
                $Shortcut.WorkingDirectory = $Item.NewWorkingDir
                $Shortcut.Save()
                Write-Host "[OK] $($Item.File)" -ForegroundColor Green
                $Updated++
            } catch {
                Write-Host "[FAILED] $($Item.File) - $($_.Exception.Message)" -ForegroundColor Red
                $Failed++
            }
        }
        
        # Summary
        Write-Host "`n=== Complete ===" -ForegroundColor Cyan
        Write-Host "Successfully updated: $Updated" -ForegroundColor Green
        if ($Failed -gt 0) {
            Write-Host "Failed: $Failed" -ForegroundColor Red
        }
    }
    
    Write-Host ""
    Write-Host "Process another folder? (Y/N): " -ForegroundColor Yellow -NoNewline
    $Continue = Read-Host
    
} while ($Continue -eq "Y" -or $Continue -eq "y")

Write-Host "`nGoodbye!" -ForegroundColor Cyan

# Cleanup
[System.Runtime.Interopservices.Marshal]::ReleaseComObject($WshShell) | Out-Null

