# Registry Tweaks Menu
# Run as Administrator for system-level tweaks

$tweaks = @(
    @{
        Name = "Enable Admin Protection"
        Description = "Enhances security for administrator accounts"
        Action = {
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableAdminProtection" -Value 1 -Type DWord
        }
    },
    @{
        Name = "Register 'ps' command for PowerShell 7"
        Description = "Type 'ps' in Run/CMD to launch PowerShell 7"
        Action = {
            $psPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\ps.exe"
            if (!(Test-Path $psPath)) { New-Item -Path $psPath -Force | Out-Null }
            Set-ItemProperty -Path $psPath -Name "(Default)" -Value "E:\SW\PowerShell\pwsh.exe"
            Set-ItemProperty -Path $psPath -Name "Path" -Value "E:\SW\PowerShell\"
        }
    },
    @{
        Name = "Remove Gallery from File Explorer"
        Description = "Removes the Gallery feature from Explorer navigation"
        Action = {
            # User-level
            $userPath = "HKCU:\Software\Classes\CLSID\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}"
            if (!(Test-Path $userPath)) { New-Item -Path $userPath -Force | Out-Null }
            Set-ItemProperty -Path $userPath -Name "System.IsPinnedToNameSpaceTree" -Value 0 -Type DWord
            
            # System-level
            $sysPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace_41040327\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}"
            if (Test-Path $sysPath) { Remove-Item -Path $sysPath -Recurse -Force }
        }
    },
    @{
        Name = "Remove Linux from File Explorer"
        Description = "Removes Linux from Windows File Explorer navigation tree"
        Action = {
            $clsidPath = "HKCU:\Software\Classes\CLSID\{B2B4A4D1-2754-4140-A2EB-9A76D9D7CDC6}"
            if (!(Test-Path $clsidPath)) { New-Item -Path $clsidPath -Force | Out-Null }
            Set-ItemProperty -Path $clsidPath -Name "System.IsPinnedToNameSpaceTree" -Value 0 -Type DWord
        }
    },
    @{
        Name = "Remove AMD from Context Menu"
        Description = "Removes AMD from context menu"
        Action = {
            $blockPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked"
            if (!(Test-Path $blockPath)) { New-Item -Path $blockPath -Force | Out-Null }
            Set-ItemProperty -Path $blockPath -Name "{FDADFEE3-02D1-4E7C-A511-380F4C98D73B}" -Value "" -Type String
        }
    }
)

Write-Host "`n=== Windows Registry Tweaks ===" -ForegroundColor Cyan
Write-Host "Select tweaks to apply (comma-separated, e.g., 1,3 or 'all'):`n" -ForegroundColor Yellow

for ($i = 0; $i -lt $tweaks.Count; $i++) {
    Write-Host "  [$($i+1)] $($tweaks[$i].Name)" -ForegroundColor Green
    Write-Host "      $($tweaks[$i].Description)" -ForegroundColor Gray
}

Write-Host "`n  [A] Apply All" -ForegroundColor Cyan
Write-Host "  [0] Exit`n" -ForegroundColor Red

$selection = Read-Host "Your choice"

if ($selection -eq '0' -or [string]::IsNullOrWhiteSpace($selection)) {
    Write-Host "Cancelled." -ForegroundColor Red
    exit
}

$selected = @()
if ($selection -match '^[Aa](ll)?$') {
    $selected = 0..($tweaks.Count - 1)
} else {
    # Use safe conversion (-as [int]) to handle invalid input gracefully
    $selected = $selection -split ',' | ForEach-Object { 
        $num = $_.Trim() -as [int]
        if ($null -ne $num) { $num - 1 } else { $null }
    } | Where-Object { $null -ne $_ -and $_ -ge 0 -and $_ -lt $tweaks.Count }
}

if ($selected.Count -eq 0) {
    Write-Host "No valid selection." -ForegroundColor Red
    exit
}

Write-Host "`nApplying $($selected.Count) tweak(s)..." -ForegroundColor Yellow

foreach ($idx in $selected) {
    try {
        Write-Host "  [✓] $($tweaks[$idx].Name)..." -ForegroundColor Green
        & $tweaks[$idx].Action
    } catch {
        Write-Host "  [✗] Failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "`nDone! Some changes may require restart/re-login." -ForegroundColor Cyan

