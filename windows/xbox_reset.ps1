<#
.SYNOPSIS
    Resets Xbox and Gaming apps by uninstalling and optionally reinstalling them.

.DESCRIPTION
    This script removes all Xbox-related AppX packages and stops gaming services.
    After a reboot, it can reinstall apps via winget or open Microsoft Store pages.
    Useful for fixing Xbox app issues, Game Pass problems, or Game Bar glitches.

.NOTES
    Requires Administrator privileges (auto-elevates if needed).
    "Both" mode: Uninstall -> Auto-reboot -> Auto-resume elevated (no UAC)

    These are the manual steps to uninstall and reinstall the apps:
    Get-AppxPackage Microsoft.GamingApp | Remove-AppxPackage -AllUsers
    Get-AppxPackage Microsoft.XboxGamingOverlay | Remove-AppxPackage -AllUsers
    Get-AppxPackage Microsoft.XboxIdentityProvider | Remove-AppxPackage -AllUsers
    Get-AppxPackage Microsoft.XboxSpeechToTextOverlay | Remove-AppxPackage -AllUsers
    Get-AppxPackage Microsoft.GamingServices | Remove-AppxPackage -AllUsers
    Stop-Service GamingServices -Force
    Stop-Service GamingServicesNet -Force
    start ms-windows-store://pdp/?productid=9MWPM2CQNLHN
    start ms-windows-store://pdp/?productid=9MV0B5HZVK9Z
    start ms-windows-store://pdp/?productid=9WZDNCRD1HKW
    start ms-windows-store://pdp/?productid=9NZKPSTSNW4P
#>

param(
    [switch]$Resume  # Internal flag: set automatically after reboot
)

# ============================================================================
# CONFIGURATION - Edit these options before running
# ============================================================================

# Which phase to run: "Uninstall", "Reinstall", or "Both"
$Phase = "Both"

# Installation method: "Winget" (automatic) or "Store" (opens Store pages)
$InstallMethod = "Winget"

# ============================================================================
# Xbox packages and Store product IDs
# ============================================================================

$XboxPackages = @(
    "Microsoft.GamingApp"              # Xbox App
    "Microsoft.XboxGamingOverlay"      # Game Bar (Win+G)
    "Microsoft.XboxIdentityProvider"   # Xbox Sign-in
    "Microsoft.XboxSpeechToTextOverlay"# Speech-to-Text Overlay
    "Microsoft.GamingServices"         # Gaming Services (required for Game Pass)
)

$GamingServices = @("GamingServices", "GamingServicesNet")

$StoreProducts = @{
    "Gaming Services"        = "9MWPM2CQNLHN"
    "Xbox App"               = "9MV0B5HZVK9Z"
    "Xbox Identity Provider" = "9WZDNCRD1HKW"
    "Xbox Game Bar"          = "9NZKPSTSNW4P"
}

$PsExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }

# ============================================================================
# FUNCTIONS
# ============================================================================

function Test_Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Uninstall_XboxPackages {
    Write-Host "`n=== PHASE 1: Uninstalling Xbox Packages ===" -ForegroundColor Cyan
    
    foreach ($package in $XboxPackages) {
        Write-Host "  Removing $package... " -NoNewline
        $pkg = Get-AppxPackage -Name $package -ErrorAction SilentlyContinue
        if ($pkg) {
            try {
                $pkg | Remove-AppxPackage -AllUsers -ErrorAction Stop
                Write-Host "Done" -ForegroundColor Green
            }
            catch {
                Write-Host "Failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        else {
            Write-Host "Not installed" -ForegroundColor Yellow
        }
    }

    Write-Host "`n  Stopping Gaming Services..." -ForegroundColor Cyan
    $GamingServices | ForEach-Object {
        $service = Get-Service -Name $_ -ErrorAction SilentlyContinue
        if ($service -and $service.Status -eq 'Running') {
            Write-Host "    Stopping $_... " -NoNewline
            try {
                Stop-Service -Name $_ -Force -ErrorAction Stop
                Write-Host "Done" -ForegroundColor Green
            }
            catch {
                Write-Host "Failed (may require reboot)" -ForegroundColor Yellow
            }
        }
    }
}

function Register_ResumeAfterReboot {
    <#
    .SYNOPSIS
        Registers script to auto-run ELEVATED after reboot using Task Scheduler.
        This avoids UAC prompt by using "Run with highest privileges" setting.
    #>
    $taskName = "XboxReset_Resume"
    
    # Create scheduled task that runs once at logon with highest privileges
    $action = New-ScheduledTaskAction -Execute $PsExe -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Resume"
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    
    try {
        # Remove any existing task
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        
        # Register new task
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -ErrorAction Stop | Out-Null
        Write-Host "  Registered for auto-resume after reboot." -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "  Failed to register scheduled task: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Install_ViaWinget {
    Write-Host "`n=== PHASE 2: Installing via Winget ===" -ForegroundColor Cyan
    
    # Check if winget is available
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "[ERROR] Winget not found. Falling back to Store method." -ForegroundColor Red
        Open_StorePage
        return
    }

    foreach ($app in $StoreProducts.GetEnumerator()) {
        Write-Host "  Installing $($app.Key)... " -ForegroundColor White
        $result = winget install --id $app.Value --source msstore --accept-package-agreements --accept-source-agreements --silent 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    Done" -ForegroundColor Green
        }
        else {
            Write-Host "    Failed or already installed" -ForegroundColor Yellow
        }
    }

    Write-Host "`n[!] Reboot recommended after installation." -ForegroundColor Yellow
}

function Open_StorePage {
    Write-Host "`n=== PHASE 2: Opening Store for Reinstallation ===" -ForegroundColor Cyan
    Write-Host "`nApps to install:" -ForegroundColor Yellow
    
    $i = 1
    foreach ($app in $StoreProducts.GetEnumerator()) {
        Write-Host "  $i. $($app.Key)" -ForegroundColor White
        $i++
    }
    
    Write-Host "`nOpening each Store page (press any key for next)..." -ForegroundColor Cyan
    foreach ($app in $StoreProducts.GetEnumerator()) {
        Write-Host "`n  Opening: $($app.Key)... " -NoNewline -ForegroundColor White
        Start-Process "ms-windows-store://pdp/?productid=$($app.Value)"
        Start-Sleep -Milliseconds 800  # Give Store time to launch
        Write-Host "After installing, press any key to continue..." -ForegroundColor Yellow
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }

    Write-Host "`n[!] Install each app from Store, then reboot when done." -ForegroundColor Yellow
}

function Install_XboxPackages {
    switch ($InstallMethod) {
        "Winget" { Install_ViaWinget }
        "Store"  { Open_StorePage }
        default  { 
            Write-Host "[ERROR] Invalid InstallMethod. Use 'Winget' or 'Store'" -ForegroundColor Red 
        }
    }
}

function Reboot_WithCountdown {
    Write-Host "`nRebooting in 10 seconds... (Ctrl+C to cancel)" -ForegroundColor Yellow
    for ($i = 10; $i -gt 0; $i--) {
        Write-Host "`r  $i seconds remaining...  " -NoNewline -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    }
    Write-Host ""
    Restart-Computer -Force
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Host "============================================" -ForegroundColor Magenta
Write-Host "         Xbox/Gaming Apps Reset Tool        " -ForegroundColor Magenta  
Write-Host "============================================" -ForegroundColor Magenta

# Auto-elevate to Administrator if needed
if (-not (Test_Administrator)) {
    Write-Host "`n[!] Elevating to Administrator..." -ForegroundColor Yellow
    Start-Process $PsExe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

# Check if resuming after reboot
if ($Resume) {
    Write-Host "`n[!] Resuming after reboot..." -ForegroundColor Cyan
    
    # Clean up scheduled task (it's already done its job)
    Unregister-ScheduledTask -TaskName "XboxReset_Resume" -Confirm:$false -ErrorAction SilentlyContinue
    
    Install_XboxPackages
    Write-Host "`nXbox Reset Complete!" -ForegroundColor Green
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit
}

# Execute based on phase
switch ($Phase) {
    "Uninstall" {
        Uninstall_XboxPackages
        Write-Host "`n[!] Reboot required before reinstalling apps." -ForegroundColor Yellow
    }
    "Reinstall" {
        Install_XboxPackages
    }
    "Both" {
        Uninstall_XboxPackages
        Write-Host "`n[!] Preparing for auto-resume after reboot..." -ForegroundColor Cyan
        if (Register_ResumeAfterReboot) {
            Reboot_WithCountdown -Seconds 10
        }
        else {
            Write-Host "`n[!] Enabling auto-resume failed. Manually reboot and then manually run script again with Phase = 'Reinstall'." -ForegroundColor Yellow
        }
    }
    default {
        Write-Host "[ERROR] Invalid phase. Use 'Uninstall', 'Reinstall', or 'Both'" -ForegroundColor Red
    }
}

Write-Host "`nDone!" -ForegroundColor Green
