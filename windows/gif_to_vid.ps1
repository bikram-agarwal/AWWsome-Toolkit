# Path to ffmpeg.exe
$ffmpeg = "D:\SW\ffmpeg\bin\ffmpeg.exe"

# Ask user which format(s) to convert to
Write-Host "Choose conversion option:"
Write-Host "1. WebM only"
Write-Host "2. MP4 only"
Write-Host "3. Both WebM and MP4"
$choice = Read-Host "Enter 1, 2, or 3"

# Determine input mode
if ($args.Count -gt 0) {
    # Mode 2 or 3: arguments provided (drag & drop or manual list)
    $gifFiles = $args
} else {
    # Mode 1: no args, convert all GIFs in current dir
    $gifFiles = Get-ChildItem -Filter *.gif | ForEach-Object { $_.FullName }
}

# Print table header
"{0,-40} {1,-6} {2,10} {3,10} {4,10}" -f "File", "Fmt", "GIF_MB", "New_MB", "Saved_MB"
"{0,-40} {1,-6} {2,10} {3,10} {4,10}" -f ("-"*40), ("-"*6), ("-"*10), ("-"*10), ("-"*10)

# Totals
$totalGif = 0
$totalNew = 0
$totalSaved = 0

foreach ($gif in $gifFiles) {
    if (-not (Test-Path $gif)) {
        Write-Host "Skipping: $gif (not found)" -ForegroundColor Yellow
        continue
    }

    $gifSize = (Get-Item $gif).Length / 1MB
    $totalGif += $gifSize
    $fileName = [System.IO.Path]::GetFileName($gif)

    if ($choice -eq "1" -or $choice -eq "3") {
        Write-Host "Converting $fileName → WebM..."
        $webm = [System.IO.Path]::ChangeExtension($gif, ".webm")
        & $ffmpeg -v quiet -y -i $gif -c:v libvpx-vp9 -b:v 0 -crf 30 $webm
        $webmSize = (Get-Item $webm).Length / 1MB
        $saved = $gifSize - $webmSize
        "{0,-40} {1,-6} {2,10:N2} {3,10:N2} {4,10:N2}" -f $fileName, "WebM", $gifSize, $webmSize, $saved
        $totalNew   += $webmSize
        $totalSaved += $saved
    }

    if ($choice -eq "2" -or $choice -eq "3") {
        Write-Host "Converting $fileName → MP4..."
        $mp4 = [System.IO.Path]::ChangeExtension($gif, ".mp4")
        & $ffmpeg -v quiet -y -i $gif -movflags faststart -pix_fmt yuv420p `
            -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" -c:v libx264 -crf 24 $mp4
        $mp4Size = (Get-Item $mp4).Length / 1MB
        $saved = $gifSize - $mp4Size
        "{0,-40} {1,-6} {2,10:N2} {3,10:N2} {4,10:N2}" -f $fileName, "MP4", $gifSize, $mp4Size, $saved
        $totalNew   += $mp4Size
        $totalSaved += $saved
    }
}

# Totals
Write-Host ""
"{0,-40} {1,-6} {2,10} {3,10} {4,10}" -f "TOTAL", "", ("{0:N2}" -f $totalGif), ("{0:N2}" -f $totalNew), ("{0:N2}" -f $totalSaved)
