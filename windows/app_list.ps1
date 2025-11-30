# ============================================
# Windows Application Inventory Script
# ============================================

Write-Host "Starting application inventory..." -ForegroundColor Cyan
Write-Host ""

# Create timestamp for filenames
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$outputPath = "$env:USERPROFILE\Desktop"

# Ensure output directory exists
if (-not (Test-Path $outputPath)) {
    New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
}

# ============================================
# Win32 / Desktop Applications
# ============================================
Write-Host "Collecting Win32/Desktop applications..." -ForegroundColor Yellow

try {
    $win32Apps = @()
    
    # Check 64-bit registry location
    Write-Host "  - Scanning 64-bit applications..."
    $win32Apps += Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName } |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallDate, InstallLocation, 
                      @{Name="Architecture";Expression={"x64"}},
                      @{Name="EstimatedSizeMB";Expression={[math]::Round($_.EstimatedSize/1024, 2)}}
    
    # Check 32-bit registry location (on 64-bit systems)
    if (Test-Path "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall") {
        Write-Host "  - Scanning 32-bit applications..."
        $win32Apps += Get-ItemProperty HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName } |
            Select-Object DisplayName, DisplayVersion, Publisher, InstallDate, InstallLocation,
                          @{Name="Architecture";Expression={"x86"}},
                          @{Name="EstimatedSizeMB";Expression={[math]::Round($_.EstimatedSize/1024, 2)}}
    }
    
    # Check current user installations
    Write-Host "  - Scanning user-specific applications..."
    $win32Apps += Get-ItemProperty HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName } |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallDate, InstallLocation,
                      @{Name="Architecture";Expression={"User"}},
                      @{Name="EstimatedSizeMB";Expression={[math]::Round($_.EstimatedSize/1024, 2)}}
    
    # Remove duplicates and sort
    $win32Apps = $win32Apps | 
        Sort-Object -Property DisplayName -Unique |
        Sort-Object DisplayName
    
    $win32OutputFile = "$outputPath\Installed_Win32_Apps_$timestamp.csv"
    $win32Apps | Export-Csv -Path $win32OutputFile -NoTypeInformation -Encoding UTF8
    
    Write-Host "  ✓ Found $($win32Apps.Count) Win32 applications" -ForegroundColor Green
    Write-Host "  ✓ Saved to: $win32OutputFile" -ForegroundColor Green
}
catch {
    Write-Host "  ✗ Error collecting Win32 apps: $_" -ForegroundColor Red
}

Write-Host ""

# ============================================
# Microsoft Store / UWP Applications
# ============================================
Write-Host "Collecting Microsoft Store applications..." -ForegroundColor Yellow

try {
    $storeApps = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
        Select-Object Name, 
                      PackageFullName, 
                      Version,
                      Publisher,
                      InstallLocation,
                      Architecture,
                      @{Name="IsFramework";Expression={$_.IsFramework}},
                      @{Name="SignatureKind";Expression={$_.SignatureKind}},
                      @{Name="Status";Expression={$_.Status}} |
        Sort-Object Name
    
    $storeOutputFile = "$outputPath\Installed_Store_Apps_$timestamp.csv"
    $storeApps | Export-Csv -Path $storeOutputFile -NoTypeInformation -Encoding UTF8
    
    Write-Host "  ✓ Found $($storeApps.Count) Store applications" -ForegroundColor Green
    Write-Host "  ✓ Saved to: $storeOutputFile" -ForegroundColor Green
}
catch {
    Write-Host "  ✗ Error collecting Store apps: $_" -ForegroundColor Red
}

Write-Host ""

# ============================================
# Summary Report
# ============================================
$summaryFile = "$outputPath\App_Inventory_Summary_$timestamp.txt"
$summary = @"
======================================
Windows Application Inventory Summary
======================================
Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Computer: $env:COMPUTERNAME
User: $env:USERNAME
OS: $((Get-WmiObject Win32_OperatingSystem).Caption)

Total Win32 Applications: $($win32Apps.Count)
Total Store Applications: $($storeApps.Count)
Total Applications: $($win32Apps.Count + $storeApps.Count)

Output Files:
- Win32 Apps (CSV): Installed_Win32_Apps_$timestamp.csv
- Store Apps (CSV): Installed_Store_Apps_$timestamp.csv
- Summary: App_Inventory_Summary_$timestamp.txt

All files saved to: $outputPath
======================================
"@

$summary | Out-File -FilePath $summaryFile -Encoding UTF8

Write-Host "======================================" -ForegroundColor Cyan
Write-Host "Inventory Complete!" -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "Total Win32 Apps: $($win32Apps.Count)" -ForegroundColor White
Write-Host "Total Store Apps: $($storeApps.Count)" -ForegroundColor White
Write-Host "Total Apps: $($win32Apps.Count + $storeApps.Count)" -ForegroundColor White
Write-Host ""
Write-Host "Files saved to your Desktop:" -ForegroundColor Cyan
Write-Host "  - Installed_Win32_Apps_$timestamp.csv"
Write-Host "  - Installed_Store_Apps_$timestamp.csv"
Write-Host "  - App_Inventory_Summary_$timestamp.txt"
Write-Host ""