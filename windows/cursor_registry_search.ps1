#!/usr/bin/env pwsh
# Search registry for Cursor.exe references using PowerShell
# This will help us find ANY registry keys we might have missed

Write-Host "Searching registry for Cursor.exe command entries..." -ForegroundColor Cyan
Write-Host "This may take a minute..." -ForegroundColor Gray
Write-Host ""

$results = @()

# Function to recursively search registry
function Search-RegistryForCursor {
    param([string]$Path)
    
    try {
        # Check if current key has a (Default) value with Cursor.exe
        $props = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($props -and $props.'(Default)' -and $props.'(Default)' -like "*Cursor.exe*") {
            return @{
                Key = $Path
                Value = $props.'(Default)'
            }
        }
    } catch {
        # Ignore access denied errors
    }
    
    return $null
}

# Search specific registry paths where file associations live
$searchPaths = @(
    "Registry::HKEY_CLASSES_ROOT\Applications\Cursor.exe",
    "Registry::HKEY_CLASSES_ROOT\*",
    "Registry::HKEY_CURRENT_USER\Software\Classes\Applications\Cursor.exe",
    "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts"
)

Write-Host "Searching known Cursor ProgIds..." -ForegroundColor Yellow
# Get all Cursor.* ProgIds
$progIds = Get-ChildItem "Registry::HKEY_CLASSES_ROOT" -ErrorAction SilentlyContinue | 
    Where-Object { $_.PSChildName -match '^Cursor\.' -or $_.PSChildName -eq 'CursorSourceFile' -or $_.PSChildName -eq 'cursor' }

foreach ($progId in $progIds) {
    $cmdPath = Join-Path $progId.PSPath "shell\open\command"
    $result = Search-RegistryForCursor -Path $cmdPath
    if ($result) {
        $results += $result
    }
}

Write-Host "Searching other registry locations..." -ForegroundColor Yellow
foreach ($searchPath in $searchPaths) {
    if (Test-Path -LiteralPath $searchPath) {
        # Search recursively in this path
        try {
            Get-ChildItem -LiteralPath $searchPath -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                $result = Search-RegistryForCursor -Path $_.PSPath
                if ($result) {
                    $results += $result
                }
            }
        } catch {
            # Ignore errors
        }
    }
}

Write-Host "`n============================================================="
Write-Host "  SEARCH RESULTS"
Write-Host "============================================================="
Write-Host "Found $($results.Count) registry entries containing Cursor.exe`n" -ForegroundColor Green

# Group by whether they have portable flags or not
$withFlags = @()
$withoutFlags = @()

foreach ($result in $results) {
    if ($result.Value -match '--user-data-dir') {
        $withFlags += $result
    } else {
        $withoutFlags += $result
    }
}

Write-Host "✓ Already updated (with --user-data-dir): $($withFlags.Count)" -ForegroundColor Green
Write-Host "✗ Missing portable flags: $($withoutFlags.Count)" -ForegroundColor Red

if ($withoutFlags.Count -gt 0) {
    Write-Host "`n============================================================="
    Write-Host "  ENTRIES MISSING PORTABLE FLAGS"
    Write-Host "============================================================="
    
    foreach ($result in $withoutFlags) {
        Write-Host "`n$($result.Key)" -ForegroundColor Yellow
        Write-Host "  $($result.Value)" -ForegroundColor Gray
    }
}

Write-Host "`n============================================================="
Write-Host "`nPress any key to exit..." -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

