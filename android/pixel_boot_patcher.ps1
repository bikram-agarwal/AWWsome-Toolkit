Set-StrictMode -Version Latest
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$FactoryPattern = '*-factory-*.zip'
$ImagePattern = 'image-*.zip'
$KernelPattern = '*AnyKernel3.zip'
$Magiskboot = Join-Path $ScriptDir 'magiskboot-svoboda18.exe'
$ExtractLog = Join-Path $ScriptDir 'extract_log.txt'
$Extractor = "D:\SW\WinRAR\WinRAR.exe"

function Write-Info($s){ Write-Host "[INFO] $s" }
function Write-Ok($s){ Write-Host "[OK]  $s" -ForegroundColor Green }
function Write-Err($s){ Write-Host "[ERROR] $s" -ForegroundColor Red }
function Write-DebugLog($s){ Write-Host "[DEBUG] $s" -ForegroundColor DarkGray }

# Checking Prerequisites
Write-Host ""
Write-Host "==================== [1/4] Checking Prerequisites ===================="
Write-Info "Validating required tools and files"
if (-not (Test-Path $Magiskboot)) { 
    Write-Err "magiskboot exe not found at $Magiskboot"; 
    exit 1 
} else { Write-Ok "magiskboot exe found" }

# Validate WinRAR path at the beginning
if (-not (Test-Path $Extractor)) {
    Write-Err "Nothing found at $Extractor. Please install WinRAR/7z or update the path."
    exit 1
} else { Write-Ok "WinRAR found" }

# Check for factory zip
$FactoryZip = Get-ChildItem -Path $ScriptDir -Filter $FactoryPattern -File -ErrorAction SilentlyContinue | Select-Object -First 1
if ($FactoryZip) {
    Write-Ok "Factory image zip found: $($FactoryZip.Name)"
} else {
    Write-Info "No factory image matching pattern $FactoryPattern in $ScriptDir. This is optional if an extracted/cached image-*.zip exists."
}

# Check for kernel zip
$KernelZip = Get-ChildItem -Path $ScriptDir -Filter $KernelPattern -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $KernelZip) {
    Write-Err "No kernel zip matching pattern $KernelPattern in $ScriptDir"
    exit 1
} else {
    Write-Ok "Kernel zip found: $($KernelZip.Name)"
}

# Extracting Zips/Images
Write-Host ""
Write-Host "==================== [2/4] Extracting Zips/Images ===================="
# Look for cached image zip
$ImageZip = Get-ChildItem -Path $ScriptDir -Filter $ImagePattern -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($ImageZip) {
    Write-Ok "Found cached image zip: $($ImageZip.FullName)"
} else {
    # If not found, attempt to extract factory zip
    if (-not $FactoryZip) {
        Write-Err "Neither a cached $ImagePattern nor a factory image ($FactoryPattern) were found in $ScriptDir. One of these is required."
        exit 1
    }
    Remove-Item -Path $ExtractLog -ErrorAction SilentlyContinue
    Write-Info "Extracting factory image to $ScriptDir"
    try {
        & $Extractor x -ibck -y -o+ -inul $FactoryZip.FullName $ScriptDir
        $ImageZip = Get-ChildItem -Path $ScriptDir -Filter $ImagePattern -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $ImageZip) {
            Write-Err "Could not find $ImagePattern inside extracted factory image"
            exit 1
        }
    } catch {
        Write-Err "WinRAR failed to extract factory image: $_"
        exit 1
    }
    Write-Ok "Found image zip: $($ImageZip.FullName)"
}

# Extract boot.img from image zip
Remove-Item -Path $ExtractLog -ErrorAction SilentlyContinue
Write-Info "Extracting boot.img from $($ImageZip.FullName) to $ScriptDir"
try {
    & $Extractor x -ibck -y -o+ -inul -n"boot.img" $ImageZip.FullName $ScriptDir
    $BootImgPath = Join-Path $ScriptDir 'boot.img'
    Write-DebugLog "Checking for boot.img at: $BootImgPath"
    Start-Sleep -Seconds 1  # Wait briefly to ensure file system updates
    if (-not (Test-Path $BootImgPath)) {
        Write-Err "boot.img not found after WinRAR extraction"
        exit 1
    }
} catch {
    Write-Err "WinRAR failed to extract boot.img: $_"
    exit 1
}

if (-not (Test-Path $BootImgPath)) { Write-Err "boot.img not found after extraction"; exit 1 } else { Write-Ok "boot.img extracted" }

# Extract Image from kernel zip using WinRAR
Remove-Item -Path $ExtractLog -ErrorAction SilentlyContinue
Write-Info "Extracting Image from $($KernelZip.FullName) to $ScriptDir"
try {
    & $Extractor x -ibck -y -o+ -inul -n"Image" $KernelZip.FullName $ScriptDir
    $KernelImgPath = Join-Path $ScriptDir 'Image'
    Write-DebugLog "Checking for Image at: $KernelImgPath"
    Start-Sleep -Seconds 1  # Wait briefly to ensure file system updates
    if (-not (Test-Path $KernelImgPath)) {
        Write-Err "Image not found after WinRAR extraction"
        exit 1
    }
} catch {
    Write-Err "WinRAR failed to extract Image: $_"
    exit 1
}

if (-not (Test-Path $KernelImgPath)) { Write-Err "Image not found after extraction"; exit 1 } else { Write-Ok "Image extracted" }

# Patching Boot
Write-Host ""
Write-Host "==================== [3/4] Patching Boot ===================="
Write-Info "Running magiskboot to patch the boot image"
& $Magiskboot unpack 'boot.img'
if ($LASTEXITCODE -ne 0) { Write-Err "magiskboot unpack failed"; exit 1 }
if (-not (Test-Path 'kernel')) { Write-Err "No kernel created by magiskboot"; exit 1 }
Write-Ok "Boot image unpacked"

# Replace kernel
Remove-Item -Path 'kernel' -ErrorAction SilentlyContinue
Move-Item -Path 'Image' -Destination 'kernel' -Force
if (-not (Test-Path 'kernel')) { Write-Err "Failed to replace kernel"; exit 1 }
Write-Ok "Kernel replaced"

# Repack
& $Magiskboot repack 'boot.img'
if ($LASTEXITCODE -ne 0) { Write-Err "magiskboot repack failed"; exit 1 }
if (-not (Test-Path 'new-boot.img')) { Write-Err "new-boot.img not created"; exit 1 }
Write-Ok "Boot repacked"

# SHA1
try {
    $sha = & $Magiskboot sha1 'new-boot.img' 2>&1
    Write-Host "SHA1: $sha"
} catch {
    Write-Err "Failed to calculate SHA1: $_"
    exit 1
}

# Result
Write-Host ""
Write-Host "==================== [4/4] Result ===================="
Write-Info "Finalizing and saving the patched boot image"
# Copy out
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$OutFile = Join-Path $ScriptDir "boot_patched_$timestamp.img"
Move-Item -Path 'new-boot.img' -Destination $OutFile -Force
Write-Ok "Patched image saved to $OutFile"

Write-Ok "SUCCESS"

# Pause before exiting to keep the window open if run by double-clicking
Write-Host ""
Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
exit 0
