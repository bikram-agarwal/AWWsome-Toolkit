# ================================
# Windows Feature Toggle Framework
# ================================
# Usage:
#   Enable-Feature "LockScreenWidgets"
#   Disable-Feature "StartMenuRedesign"
#   Query-Feature "HardwareInfoCards"
#   List-Features
# ================================

# Check if running as admin, if not, elevate
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Elevating to administrator..." -ForegroundColor Yellow
    $wtPath = Get-Command wt.exe -ErrorAction SilentlyContinue
    if ($wtPath) {
        $wtArgs = "new-tab --title `"ViVeTool Script`" pwsh.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        Start-Process wt.exe -ArgumentList $wtArgs -Verb RunAs
    } else {
        Start-Process pwsh.exe -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File","`"$PSCommandPath`"" -Verb RunAs
    }
    exit
}

# Check for ViVeTool in PATH
$vivetool = Get-Command ViVeTool.exe -ErrorAction SilentlyContinue
if (-not $vivetool) {
    Write-Host "ERROR: ViVeTool.exe not found in PATH" -ForegroundColor Red
    Write-Host "Download from: https://github.com/thebookisclosed/ViVe/releases" -ForegroundColor Yellow
    Write-Host "Add its location to your PATH environment variable" -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit 1
}
$vivetool = $vivetool.Source

# Dictionary of features
$FeatureMap = @{
    "AutoSuperResolution"     = @(396959)
    "TaskbarSearchBox"        = @(408877)
    "StartMenuRecs"           = @(47205210,48433719,49221331)
    "ExplorerImprovements"    = @(48504539)
    "SnapAssistSmart"         = @(48655351)
    "StartMenuPersonalization"= @(48697323,48433719)
    "SettingsRefinements"     = @(49402389,49453572)
    "LockScreenWidgets"       = @(50179255,53672489)
    "HardwareInfoCards"       = @(51784082,54618938)
    "StartMenuRedesign"       = @(55495322,49381526,49820095)
    "ExplorerDetailsPane"     = @(5587902)
    "TaskbarGlanceView"       = @(56231044)
    "StartMenu2.0"            = @(56493452)
    "Oct2025Bundle"           = @(57048226)
    "SettingsExperiment58383" = @(58383338)
    "SettingsExperiment59270" = @(59270880)
    "AdminProtection"         = @(45172197)
}

$LogFile = "$env:USERPROFILE\FeatureToggleLog.csv"
$BuildNumber = $null
$FeatureList = @()

# Initialize log
if (-not (Test-Path $LogFile)) {
    "Timestamp,Build,Feature,IDs,Action,Result" | Out-File $LogFile
}

function Get-BuildInfo {
    if ($null -eq $script:BuildNumber) {
        $script:BuildNumber = [System.Environment]::OSVersion.Version.Build
    }
    return $script:BuildNumber
}

function Write-Log($Feature, $IDs, $Action, $Result) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $build = Get-BuildInfo
    "$timestamp,$build,$Feature,""$($IDs -join ';')"",$Action,$Result" | Out-File $LogFile -Append
}

function Enable-Feature($Name) {
    if (-not $FeatureMap.ContainsKey($Name)) {
        Write-Host "Unknown feature: $Name" -ForegroundColor Red
        Write-Host "Use 'List-Features' to see available features" -ForegroundColor Yellow
        return
    }
    
    $ids = $FeatureMap[$Name]
    Write-Host "Enabling $Name..." -ForegroundColor Cyan
    
    foreach ($id in $ids) {
        $result = & $vivetool /enable /id:$id 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Feature ID $id enabled" -ForegroundColor Green
        } else {
            Write-Host "  Feature ID $id failed: $result" -ForegroundColor Red
        }
    }
    
    Write-Log $Name $ids "Enabled" "Success"
    Write-Host "Restart required for changes to take effect" -ForegroundColor Yellow
}

function Disable-Feature($Name) {
    if (-not $FeatureMap.ContainsKey($Name)) {
        Write-Host "Unknown feature: $Name" -ForegroundColor Red
        Write-Host "Use 'List-Features' to see available features" -ForegroundColor Yellow
        return
    }
    
    $ids = $FeatureMap[$Name]
    Write-Host "Disabling $Name..." -ForegroundColor Cyan
    
    foreach ($id in $ids) {
        $result = & $vivetool /disable /id:$id 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Feature ID $id disabled" -ForegroundColor Green
        } else {
            Write-Host "  Feature ID $id failed: $result" -ForegroundColor Red
        }
    }
    
    Write-Log $Name $ids "Disabled" "Success"
    Write-Host "Restart required for changes to take effect" -ForegroundColor Yellow
}

function Query-Feature($Name) {
    if (-not $FeatureMap.ContainsKey($Name)) {
        Write-Host "Unknown feature: $Name" -ForegroundColor Red
        Write-Host "Use 'List-Features' to see available features" -ForegroundColor Yellow
        return
    }
    
    $ids = $FeatureMap[$Name]
    Write-Host "Querying $Name..." -ForegroundColor Cyan
    
    foreach ($id in $ids) {
        Write-Host "`nFeature ID: $id" -ForegroundColor Yellow
        & $vivetool /query /id:$id
    }
}

function List-Features {
    $sorted = $FeatureMap.Keys | Sort-Object
    Write-Host "`nAvailable Features:" -ForegroundColor Cyan
    Write-Host ("=" * 60)
    
    $index = 1
    $script:FeatureList = @()
    foreach ($feature in $sorted) {
        $idCount = $FeatureMap[$feature].Count
        $script:FeatureList += $feature
        Write-Host ("{0,3}. {1,-30} ({2} ID(s))" -f $index, $feature, $idCount) -ForegroundColor Green
        $index++
    }
    
    Write-Host ("=" * 60)
    Write-Host "Build: $(Get-BuildInfo)" -ForegroundColor Yellow
}

# ================================
# Main Execution
# ================================

# If arguments provided, execute directly
if ($args.Count -ge 2) {
    $action = $args[0]
    $feature = $args[1]
    
    switch ($action.ToLower()) {
        "enable"  { Enable-Feature $feature }
        "disable" { Disable-Feature $feature }
        "query"   { Query-Feature $feature }
        default   { 
            Write-Host "Invalid action: $action" -ForegroundColor Red
            Write-Host "Valid actions: enable, disable, query" -ForegroundColor Yellow
        }
    }
    Read-Host "`nPress Enter to exit"
    exit
}

# Interactive menu
while ($true) {
    Clear-Host
    Write-Host "╔════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  Windows Feature Toggle - Build $(Get-BuildInfo)" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1) Enable Feature" -ForegroundColor Green
    Write-Host "2) Disable Feature" -ForegroundColor Red
    Write-Host "3) Query Feature Status" -ForegroundColor Yellow
    Write-Host "4) List All Features" -ForegroundColor Cyan
    Write-Host "5) Exit" -ForegroundColor Gray
    Write-Host ""
    
    $choice = Read-Host "Select option"
    
    switch ($choice) {
        "1" {
            List-Features
            Write-Host ""
            Write-Host "Enter feature numbers (space-separated) or 'all':" -ForegroundColor Yellow
            $input = Read-Host
            
            if ($input.ToLower() -eq "all") {
                foreach ($feature in $script:FeatureList) {
                    Enable-Feature $feature
                }
            } else {
                $indices = $input -split '\s+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
                foreach ($idx in $indices) {
                    if ($idx -ge 1 -and $idx -le $script:FeatureList.Count) {
                        Enable-Feature $script:FeatureList[$idx - 1]
                    } else {
                        Write-Host "Invalid index: $idx" -ForegroundColor Red
                    }
                }
            }
            Read-Host "`nPress Enter to continue"
        }
        "2" {
            List-Features
            Write-Host ""
            Write-Host "Enter feature numbers (space-separated) or 'all':" -ForegroundColor Yellow
            $input = Read-Host
            
            if ($input.ToLower() -eq "all") {
                foreach ($feature in $script:FeatureList) {
                    Disable-Feature $feature
                }
            } else {
                $indices = $input -split '\s+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
                foreach ($idx in $indices) {
                    if ($idx -ge 1 -and $idx -le $script:FeatureList.Count) {
                        Disable-Feature $script:FeatureList[$idx - 1]
                    } else {
                        Write-Host "Invalid index: $idx" -ForegroundColor Red
                    }
                }
            }
            Read-Host "`nPress Enter to continue"
        }
        "3" {
            List-Features
            Write-Host ""
            Write-Host "Enter feature numbers (space-separated) or 'all':" -ForegroundColor Yellow
            $input = Read-Host
            
            if ($input.ToLower() -eq "all") {
                foreach ($feature in $script:FeatureList) {
                    Query-Feature $feature
                }
            } else {
                $indices = $input -split '\s+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
                foreach ($idx in $indices) {
                    if ($idx -ge 1 -and $idx -le $script:FeatureList.Count) {
                        Query-Feature $script:FeatureList[$idx - 1]
                    } else {
                        Write-Host "Invalid index: $idx" -ForegroundColor Red
                    }
                }
            }
            Read-Host "`nPress Enter to continue"
        }
        "4" {
            List-Features
            Read-Host "`nPress Enter to continue"
        }
        "5" {
            Write-Host "Exiting..." -ForegroundColor Yellow
            exit
        }
        default {
            Write-Host "Invalid choice" -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}