<#
.SYNOPSIS
    Copies or moves files from a source folder into a destination folder.
    Replaces an existing file only when the source file is smaller.

.DESCRIPTION
    Edit the configuration below, then run the script.
    The two folders can be any paths. One sitting inside the other is fine.
    Only files directly in the source folder are included. Subfolders are ignored.
    When the destination already has that file and it is smaller or the same size,
    the destination file is left unchanged and the source file stays put.
#>

# ============================================
# CONFIGURATION - Edit these before running
# ============================================
$Source = "E:\OneDrive\Legion\Downloads\Media\new"
$Destination = "E:\OneDrive\Legion\Downloads\Media"
$Operation = "move"
$WhatIf = $false
# ============================================

trap {
    Write-Host $_.Exception.Message -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 1
}

$Operation = $Operation.Trim().ToLowerInvariant()
if ($Operation -ne "copy" -and $Operation -ne "move") {
    throw "Operation must be copy or move: $Operation"
}

$sourceFolderItem = Get-Item -LiteralPath $Source -ErrorAction SilentlyContinue
if ($null -eq $sourceFolderItem -or -not $sourceFolderItem.PSIsContainer) {
    throw "Source folder not found: $Source"
}

$destinationFolderItem = Get-Item -LiteralPath $Destination -ErrorAction SilentlyContinue
if ($null -eq $destinationFolderItem -or -not $destinationFolderItem.PSIsContainer) {
    throw "Destination folder not found: $Destination"
}

$sourceFolder = $sourceFolderItem.FullName
$destinationFolder = $destinationFolderItem.FullName

if ($sourceFolder.Equals($destinationFolder, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Source and destination are the same folder: $sourceFolder"
}

$replacedLines = [System.Collections.Generic.List[object]]::new()
$transferredLines = [System.Collections.Generic.List[object]]::new()
$keptLines = [System.Collections.Generic.List[object]]::new()
$failedLines = [System.Collections.Generic.List[object]]::new()
$sourceFiles = @(Get-ChildItem -LiteralPath $sourceFolder -File)
$sourceFileCount = $sourceFiles.Count
$sourceFileIndex = 0

Write-Host "Source: $sourceFolder"
Write-Host "Destination: $destinationFolder"
Write-Host "Operation: $Operation"
if ($WhatIf) {
    Write-Host "What if: no files will be changed"
}
Write-Host ""

foreach ($sourceFile in $sourceFiles) {
    $sourceFileIndex++
    $targetPath = Join-Path $destinationFolder $sourceFile.Name
    $targetFile = $null
    $failReason = $null
    $progressAction = "Keep"

    if ($sourceFile.FullName.Equals($targetPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        $progressAction = "Fail"
        $failReason = "source and destination path are the same file"
    } else {
        $targetFile = Get-Item -LiteralPath $targetPath -ErrorAction SilentlyContinue
        if ($null -eq $targetFile) {
            $progressAction = "Move"
            if ($Operation -eq "copy") {
                $progressAction = "Copy"
            }
        } elseif ($targetFile.PSIsContainer) {
            $progressAction = "Fail"
            $failReason = "destination name is a folder"
        } elseif ($sourceFile.Length -lt $targetFile.Length) {
            $progressAction = "Replace"
        }
    }

    $progressSizeText = "{0:N2} MB" -f ($sourceFile.Length / 1MB)
    if ($sourceFile.Length -lt 1MB) {
        $progressSizeText = "{0:N2} KB" -f ($sourceFile.Length / 1KB)
    }
    Write-Progress -Activity "Processing files" `
        -Status ("[{0}/{1}] {2}: {3} ({4})" -f $sourceFileIndex, $sourceFileCount, $progressAction, $sourceFile.Name, $progressSizeText) `
        -PercentComplete ([int](($sourceFileIndex - 1) * 100 / $sourceFileCount))

    try {
        if ($progressAction -eq "Fail") {
            $failedDestinationMb = $null
            if ($null -ne $targetFile -and -not $targetFile.PSIsContainer) {
                $failedDestinationMb = $targetFile.Length / 1MB
            }
            $failedLines.Add([pscustomobject]@{ Name = $sourceFile.Name; SourceMb = $sourceFile.Length / 1MB; DestinationMb = $failedDestinationMb; Reason = $failReason })
        } elseif ($progressAction -eq "Keep") {
            $keptLines.Add([pscustomobject]@{ Name = $sourceFile.Name; SourceMb = $sourceFile.Length / 1MB; DestinationMb = $targetFile.Length / 1MB; Reason = $null })
        } elseif ($progressAction -eq "Replace") {
            if (-not $WhatIf) {
                if ($targetFile.IsReadOnly) {
                    $targetFile.IsReadOnly = $false
                }
                if ($Operation -eq "copy") {
                    Copy-Item -LiteralPath $sourceFile.FullName -Destination $targetPath -Force -ErrorAction Stop
                } else {
                    $sameVolume = [System.IO.Path]::GetPathRoot($sourceFile.FullName).Equals(
                        [System.IO.Path]::GetPathRoot($targetPath),
                        [System.StringComparison]::OrdinalIgnoreCase)
                    if ($sameVolume) {
                        [System.IO.File]::Replace($sourceFile.FullName, $targetPath, [NullString]::Value)
                    } else {
                        $incomingPath = "$targetPath.replacing"
                        if (Test-Path -LiteralPath $incomingPath) {
                            throw "Temporary file already exists: $incomingPath"
                        }
                        Move-Item -LiteralPath $sourceFile.FullName -Destination $incomingPath -ErrorAction Stop
                        Remove-Item -LiteralPath $targetPath -Force -ErrorAction Stop
                        Move-Item -LiteralPath $incomingPath -Destination $targetPath -ErrorAction Stop
                    }
                }
            }
            $replacedLines.Add([pscustomobject]@{ Name = $sourceFile.Name; SourceMb = $sourceFile.Length / 1MB; DestinationMb = $targetFile.Length / 1MB; Reason = $null })
        } else {
            if (-not $WhatIf) {
                if ($Operation -eq "copy") {
                    Copy-Item -LiteralPath $sourceFile.FullName -Destination $targetPath -ErrorAction Stop
                } else {
                    Move-Item -LiteralPath $sourceFile.FullName -Destination $targetPath -ErrorAction Stop
                }
            }
            $transferredLines.Add([pscustomobject]@{ Name = $sourceFile.Name; SourceMb = $sourceFile.Length / 1MB; DestinationMb = $null; Reason = $null })
        }
    } catch {
        $failedDestinationMb = $null
        if ($null -ne $targetFile -and -not $targetFile.PSIsContainer) {
            $failedDestinationMb = $targetFile.Length / 1MB
        }
        $failedLines.Add([pscustomobject]@{ Name = $sourceFile.Name; SourceMb = $sourceFile.Length / 1MB; DestinationMb = $failedDestinationMb; Reason = $_.Exception.Message })
    }
}

Write-Progress -Activity "Processing files" -Completed

$transferredLabel = "Moved"
if ($Operation -eq "copy") {
    $transferredLabel = "Copied"
}
if ($WhatIf) {
    $transferredLabel = "Would $Operation"
}

$replacedLabel = "Replaced"
$keptLabel = "Kept"
if ($WhatIf) {
    $replacedLabel = "Would replace"
    $keptLabel = "Would keep"
}

$resultGroups = @(
    @{ Label = $replacedLabel; Lines = $replacedLines; Color = "Green" },
    @{ Label = $transferredLabel; Lines = $transferredLines; Color = "Cyan" },
    @{ Label = $keptLabel; Lines = $keptLines; Color = "Yellow" },
    @{ Label = "Failed"; Lines = $failedLines; Color = "Red" }
)

$tableFormat = "{0,-40} {1,12} {2,12}"
$printedGroup = $false
foreach ($resultGroup in $resultGroups) {
    if ($resultGroup.Lines.Count -eq 0) {
        continue
    }
    Write-Host ("{0} ({1})" -f $resultGroup.Label, $resultGroup.Lines.Count) -ForegroundColor $resultGroup.Color
    Write-Host ($tableFormat -f "File", "Source", "Dest")
    Write-Host ($tableFormat -f ("-" * 40), ("-" * 12), ("-" * 12))
    foreach ($resultRow in $resultGroup.Lines) {
        $fileLabel = $resultRow.Name
        if ($fileLabel.Length -gt 40) {
            $fileLabel = $fileLabel.Substring(0, 37) + "..."
        }
        $sourceText = "{0:N2} MB" -f $resultRow.SourceMb
        if ($resultRow.SourceMb -lt 1) {
            $sourceText = "{0:N2} KB" -f ($resultRow.SourceMb * 1KB)
        }
        $destinationText = ""
        if ($null -ne $resultRow.DestinationMb) {
            $destinationText = "{0:N2} MB" -f $resultRow.DestinationMb
            if ($resultRow.DestinationMb -lt 1) {
                $destinationText = "{0:N2} KB" -f ($resultRow.DestinationMb * 1KB)
            }
        }
        $tableLine = $tableFormat -f $fileLabel, $sourceText, $destinationText
        if ($resultRow.Reason) {
            $tableLine = "$tableLine  $($resultRow.Reason)"
        }
        Write-Host $tableLine
    }
    Write-Host ""
    $printedGroup = $true
}

if (-not $printedGroup) {
    Write-Host "No files in source."
    Write-Host ""
}

Read-Host "Press Enter to close"
