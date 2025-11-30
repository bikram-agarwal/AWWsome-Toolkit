# ================================
# Windows Feature Toggle Framework
# ================================
# Enable-Feature "LockScreenWidgets"
# Disable-Feature "StartMenuRedesign"
# Query-Feature "HardwareInfoCards"
# ================================

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
}

# Log file
$LogFile = "$env:USERPROFILE\FeatureToggleLog.csv"

# Ensure log exists
if (-not (Test-Path $LogFile)) {
    "Timestamp,Build,Feature,IDs,Action" | Out-File $LogFile
}

function Get-BuildInfo {
    (Get-ComputerInfo).OsBuildNumber
}

function Write-Log($Feature,$IDs,$Action) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $build = Get-BuildInfo
    "$timestamp,$build,$Feature,""$($IDs -join ';')"",$Action" | Out-File $LogFile -Append
}

function Enable-Feature($Name) {
    if ($FeatureMap.ContainsKey($Name)) {
        $ids = $FeatureMap[$Name]
        & .\ViVeTool.exe /enable /id:$($ids -join ",")
        Write-Log $Name $ids "Enabled"
    } else {
        Write-Host "Unknown feature: $Name"
    }
}

function Disable-Feature($Name) {
    if ($FeatureMap.ContainsKey($Name)) {
        $ids = $FeatureMap[$Name]
        & .\ViVeTool.exe /disable /id:$($ids -join ",")
        Write-Log $Name $ids "Disabled"
    } else {
        Write-Host "Unknown feature: $Name"
    }
}

function Query-Feature($Name) {
    if ($FeatureMap.ContainsKey($Name)) {
        $ids = $FeatureMap[$Name]
        foreach ($id in $ids) {
            & .\ViVeTool.exe /query /id:$id
        }
    } else {
        Write-Host "Unknown feature: $Name"
    }
}