#!/usr/bin/env pwsh
# =========================================================================
# PORTABLE CURSOR CONFIGURATION SCRIPT (PowerShell 7)
# USE: Run this script AFTER installing Cursor to configure portable mode.
# NOTE: This script MUST be run with elevated (Administrator) privileges.
# =========================================================================

# --- CONFIGURATION ---
$CUSTOM_INSTALL_DIR  = "D:\SW\Cursor"
$PORTABLE_DATA_DIR   = "D:\SW\Cursor\data"
$PORTABLE_EXT_DIR    = "D:\SW\Cursor\data\extensions"

# --- END CONFIGURATION ---

# Build list of registry keys to update
Write-Host "`nScanning for Cursor registry keys..." -ForegroundColor Cyan
$REG_KEYS = @(
    "Registry::HKEY_CLASSES_ROOT\Applications\Cursor.exe\shell\open\command",
    "Registry::HKEY_CLASSES_ROOT\*\shell\Cursor\command",
    "Registry::HKEY_CURRENT_USER\Software\Classes\Applications\Cursor.exe\shell\open\command"
)

# Find all Cursor.* ProgIds (file type associations)
$cursorProgIds = Get-ChildItem "Registry::HKEY_CLASSES_ROOT" -ErrorAction SilentlyContinue | 
    Where-Object { $_.PSChildName -match '^Cursor\.' -or $_.PSChildName -eq 'CursorSourceFile' -or $_.PSChildName -eq 'cursor' } |
    ForEach-Object {
        $cmdPath = "Registry::HKEY_CLASSES_ROOT\$($_.PSChildName)\shell\open\command"
        if (Test-Path -LiteralPath $cmdPath) {
            $cmdPath
        }
    }

$REG_KEYS += $cursorProgIds
Write-Host "Found $($REG_KEYS.Count) registry keys to update" -ForegroundColor Green

# Build the target registry value (what we'll set them to)
$RegValue = "`"$CUSTOM_INSTALL_DIR\Cursor.exe`" --user-data-dir=`"$PORTABLE_DATA_DIR`" --extensions-dir=`"$PORTABLE_EXT_DIR`" `"%1`""

# --- PREVIEW REGISTRY KEYS ---
Write-Host "`n============================================================="
Write-Host "  PREVIEW - Registry Keys to Update"
Write-Host "============================================================="
Write-Host "`nThe following registry keys will be updated to:" -ForegroundColor Yellow
Write-Host "`n$RegValue`n" -ForegroundColor Cyan

$keysWithValues = @()
foreach ($key in $REG_KEYS) {
    try {
        $currentValue = (Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).'(Default)'
        if ($currentValue) {
            $keysWithValues += @{
                Key = $key
                Value = $currentValue
            }
        }
    } catch {
        # Skip keys that can't be read
    }
}

# Group and display
$total = $keysWithValues.Count
Write-Host "`nTotal keys with existing values: $total" -ForegroundColor Cyan
for ($i = 0; $i -lt $total; $i++) {
    Write-Host "`n  [$($i+1)] $($keysWithValues[$i].Key)" -ForegroundColor Gray
    Write-Host "      Current: $($keysWithValues[$i].Value)" -ForegroundColor DarkGray
}

Write-Host "`n============================================================="
Write-Host "`nDo you want to proceed with updating these registry keys?" -ForegroundColor Yellow
Write-Host "Type 'yes' to continue or 'no' to exit: " -ForegroundColor Yellow -NoNewline
$confirmation = Read-Host

if ($confirmation -ne 'yes') {
    Write-Host "`nOperation cancelled by user." -ForegroundColor Red
    Write-Host "`nPress any key to exit..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 0
}

Write-Host "`nProceeding with registry updates..." -ForegroundColor Green

# --- AUTO-ELEVATION ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "`nAdministrator privileges required for registry modification." -ForegroundColor Yellow
    Write-Host "Elevating..." -ForegroundColor Yellow
    
    # Detect current PowerShell executable (Core vs Desktop)
    $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    
    # Build arguments for elevated process
    $scriptArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    
    # Elevate PowerShell (opens in new window with admin rights)
    Start-Process $psExe -ArgumentList $scriptArgs -Verb RunAs
    
    exit 0
}

Write-Host "`n============================================================="
Write-Host "  PORTABLE CURSOR CONFIGURATION"
Write-Host "============================================================="

# Verify Cursor is installed
if (-not (Test-Path "$CUSTOM_INSTALL_DIR\Cursor.exe")) {
    Write-Host "`n[ERROR] Cursor.exe not found at: $CUSTOM_INSTALL_DIR" -ForegroundColor Red
    Write-Host "Please install Cursor first, or update CUSTOM_INSTALL_DIR in the script." -ForegroundColor Yellow
    Write-Host "`nPress any key to exit..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

Write-Host "[SUCCESS] Found Cursor installation at: $CUSTOM_INSTALL_DIR" -ForegroundColor Green

# --- 1. CREATE PORTABLE DIRECTORIES ---
Write-Host "`n============================================================="
Write-Host "  [1/2] CREATING PORTABLE DIRECTORIES"
Write-Host "============================================================="
if (-not (Test-Path $PORTABLE_DATA_DIR)) {
    New-Item -Path $PORTABLE_DATA_DIR -ItemType Directory -Force | Out-Null
    Write-Host "[SUCCESS] Created data directory: $PORTABLE_DATA_DIR" -ForegroundColor Green
} else {
    Write-Host "[SUCCESS] Data directory already exists: $PORTABLE_DATA_DIR" -ForegroundColor Green
}
if (-not (Test-Path $PORTABLE_EXT_DIR)) {
    New-Item -Path $PORTABLE_EXT_DIR -ItemType Directory -Force | Out-Null
    Write-Host "[SUCCESS] Created extensions directory: $PORTABLE_EXT_DIR" -ForegroundColor Green
} else {
    Write-Host "[SUCCESS] Extensions directory already exists: $PORTABLE_EXT_DIR" -ForegroundColor Green
}

# --- 2. CONFIGURE PORTABILITY FLAGS IN WINDOWS REGISTRY ---
Write-Host "`n============================================================="
Write-Host "  [2/2] CONFIGURING PORTABILITY FLAGS IN WINDOWS REGISTRY"
Write-Host "============================================================="

Write-Host "`nUpdating $($REG_KEYS.Count) registry keys..." -ForegroundColor Cyan
$successCount = 0
$failCount = 0

foreach ($key in $REG_KEYS) {
    Write-Host "`nProcessing: $key" -ForegroundColor Gray
    
    try {
        # Ensure the registry key exists
        if (-not (Test-Path -LiteralPath $key)) {
            Write-Host "  Creating key..." -ForegroundColor Yellow
            New-Item -Path $key -Force | Out-Null
        }
        
        # Set new value
        Set-ItemProperty -LiteralPath $key -Name '(Default)' -Value $RegValue -Force -ErrorAction Stop
        
        # Verify it was set
        $newValue = (Get-ItemProperty -LiteralPath $key).'(Default)'
        if ($newValue -eq $RegValue) {
            Write-Host "  ✓ Successfully updated" -ForegroundColor Green
            $successCount++
        } else {
            throw "Verification failed"
        }
    } catch {
        Write-Host "  ✗ Failed: $($_.Exception.Message)" -ForegroundColor Red
        $failCount++
    }
}

Write-Host "`nRegistry update summary:" -ForegroundColor Cyan
Write-Host "  Success: $successCount" -ForegroundColor Green
Write-Host "  Failed: $failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Gray" })

if ($successCount -eq 0) {
    Write-Host "`n[CRITICAL ERROR] No registry keys were updated successfully!" -ForegroundColor Red
    Write-Host "`nPress any key to exit..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

Write-Host "`n============================================================="
Write-Host "  CONFIGURATION COMPLETE!"
Write-Host "============================================================="
Write-Host "`nCursor is now configured in portable mode:" -ForegroundColor Green
Write-Host "  Data Directory: $PORTABLE_DATA_DIR" -ForegroundColor Cyan
Write-Host "  Extensions Directory: $PORTABLE_EXT_DIR" -ForegroundColor Cyan

# Verify registry values
Write-Host "`n============================================================="
Write-Host "  VERIFICATION - Current Registry Values"
Write-Host "============================================================="
foreach ($key in $REG_KEYS) {
    Write-Host "`n$key" -ForegroundColor Yellow
    try {
        $value = (Get-ItemProperty -LiteralPath $key -ErrorAction Stop).'(Default)'
        Write-Host "  $value" -ForegroundColor Gray
    } catch {
        Write-Host "  [ERROR] Cannot read: $_" -ForegroundColor Red
    }
}

Write-Host "`n============================================================="
Write-Host "`nPress any key to exit..." -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
