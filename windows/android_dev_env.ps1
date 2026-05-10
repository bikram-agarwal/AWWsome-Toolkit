<#
    Android SDK + Flutter Web setup (no Android Studio).

    Parameters:
    - SdkRoot: Android SDK directory (default D:\Android_SDK)
    - AndroidPlatform: platform API id, e.g. android-36
    - BuildToolsPackage: sdkmanager package id, e.g. build-tools;35.0.0

    The script:
    - Resolves latest Windows command-line tools ZIP from repository2-1.xml
    - Requires a JDK (JAVA_HOME or java on PATH); sets JAVA_HOME if missing but java is found
    - Creates cmdline-tools\latest layout, installs platform-tools + platform + build-tools
    - Sets ANDROID_HOME, ANDROID_SDK_ROOT, merges User PATH once, sets CHROME_EXECUTABLE
    - Accepts SDK licenses non-interactively, runs flutter doctor
#>

[CmdletBinding()]
param(
    [string]$SdkRoot = "D:\Android_SDK",
    [string]$AndroidPlatform = "android-36",
    [string]$BuildToolsPackage = "build-tools;35.0.0"
)

$ErrorActionPreference = "Stop"

function Get-CommandLineToolsZipUrl {
    $repositoryUrl = "https://dl.google.com/android/repository/repository2-1.xml"
    Write-Host "Fetching latest command-line tools revision from repository index..." -ForegroundColor Yellow
    $response = Invoke-WebRequest -Uri $repositoryUrl -UseBasicParsing
    $revisionMatches = [regex]::Matches(
        $response.Content,
        'commandlinetools-win-(\d+)_latest\.zip'
    )
    if ($revisionMatches.Count -eq 0) {
        throw "Could not find commandlinetools-win zip entries in repository2-1.xml."
    }
    $maxRevision = ($revisionMatches | ForEach-Object { [long]$_.Groups[1].Value } | Measure-Object -Maximum).Maximum
    $zipUrl = "https://dl.google.com/android/repository/commandlinetools-win-${maxRevision}_latest.zip"
    Write-Host "Using command-line tools build $maxRevision" -ForegroundColor Gray
    return $zipUrl
}

function Resolve-JavaHome {
    if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME "bin\java.exe"))) {
        return (Resolve-Path -LiteralPath $env:JAVA_HOME).Path
    }

    $javaCommand = Get-Command java -ErrorAction SilentlyContinue
    if ($javaCommand -and $javaCommand.Source) {
        $javaExecutable = Get-Item -LiteralPath $javaCommand.Source
        $jdkHome = $javaExecutable.Directory.Parent.FullName
        if (Test-Path (Join-Path $jdkHome "bin\java.exe")) {
            return $jdkHome
        }
    }

    $studioJbrJava = Join-Path $env:ProgramFiles "Android\Android Studio\jbr\bin\java.exe"
    if (Test-Path -LiteralPath $studioJbrJava) {
        return (Get-Item -LiteralPath $studioJbrJava).Directory.Parent.FullName
    }

    $adoptiumRoot = Join-Path $env:ProgramFiles "Eclipse Adoptium"
    if (Test-Path -LiteralPath $adoptiumRoot) {
        $jdkDirs = Get-ChildItem -LiteralPath $adoptiumRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName "bin\java.exe") }
        if ($jdkDirs) {
            return ($jdkDirs | Sort-Object Name -Descending | Select-Object -First 1).FullName
        }
    }

    return $null
}

function Merge-UserPathEntries {
    param(
        [string[]]$AdditionalPaths
    )
    $existingUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $pathSegments = [System.Collections.Generic.List[string]]::new()
    if ($existingUserPath) {
        foreach ($segment in ($existingUserPath -split ";")) {
            if (-not $segment) { continue }
            $normalizedExisting = $segment.Trim().TrimEnd("\")
            if (-not $normalizedExisting) { continue }
            if (-not $pathSegments.Contains($normalizedExisting)) {
                [void]$pathSegments.Add($normalizedExisting)
            }
        }
    }
    foreach ($additional in $AdditionalPaths) {
        if (-not $additional) { continue }
        $normalized = $additional.Trim().TrimEnd("\")
        if (-not $normalized) { continue }
        if (-not $pathSegments.Contains($normalized)) {
            [void]$pathSegments.Add($normalized)
        }
    }
    $mergedPath = $pathSegments -join ";"
    [Environment]::SetEnvironmentVariable("Path", $mergedPath, "User")
}

function Sync-SessionEnvironment {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $pathParts = @($machinePath, $userPath) | Where-Object { $_ }
    $env:Path = $pathParts -join ";"
}

Write-Host "=== ANDROID SDK + FLUTTER SETUP START ===" -ForegroundColor Cyan

$javaHome = Resolve-JavaHome
if (-not $javaHome) {
    Write-Host "No JDK found. Install a JDK (e.g. Eclipse Temurin), set JAVA_HOME, or add java.exe to PATH, then re-run." -ForegroundColor Red
    exit 1
}
Write-Host "Using JDK at: $javaHome" -ForegroundColor Gray
if (-not $env:JAVA_HOME) {
    [Environment]::SetEnvironmentVariable("JAVA_HOME", $javaHome, "User")
    $env:JAVA_HOME = $javaHome
    Write-Host "Set user JAVA_HOME to $javaHome" -ForegroundColor Yellow
} else {
    $env:JAVA_HOME = $javaHome
}

$CmdToolsDir = Join-Path $SdkRoot "cmdline-tools"
$LatestDir = Join-Path $CmdToolsDir "latest"
$ZipPath = Join-Path $env:TEMP "cmdline-tools.zip"
$ZipUrl = Get-CommandLineToolsZipUrl

$Browser = "C:\Program Files\Google\Chrome\Application\chrome.exe"
if (-not (Test-Path -LiteralPath $Browser)) {
    $Browser = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
}

Write-Host "Creating SDK directory structure..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path $SdkRoot | Out-Null
New-Item -ItemType Directory -Force -Path $CmdToolsDir | Out-Null

Write-Host "Downloading Android command-line tools..." -ForegroundColor Yellow
Invoke-WebRequest -Uri $ZipUrl -OutFile $ZipPath

Write-Host "Extracting tools..." -ForegroundColor Yellow
if (Test-Path -LiteralPath $LatestDir) { Remove-Item -LiteralPath $LatestDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $LatestDir | Out-Null
Expand-Archive -Path $ZipPath -DestinationPath $LatestDir

if (Test-Path -LiteralPath (Join-Path $LatestDir "cmdline-tools")) {
    $nested = Join-Path $LatestDir "cmdline-tools"
    Get-ChildItem -LiteralPath $nested -Force | Move-Item -Destination $LatestDir -Force
    Remove-Item -LiteralPath $nested -Recurse -Force
}

$SdkManager = Join-Path $LatestDir "bin\sdkmanager.bat"
$platformPackage = "platforms;$AndroidPlatform"

Write-Host "Accepting SDK licenses (required before install)..." -ForegroundColor Yellow
$licenseInput = ("y`n" * 120)
$licenseInput | & $SdkManager --sdk_root=$SdkRoot --licenses

Write-Host "Installing Android SDK components (single sdkmanager run)..." -ForegroundColor Yellow
# Avoid installing cmdline-tools;latest in this same run (sdkmanager runs from that folder; self-update can fail on Windows file locks).
$packagesToInstall = @(
    "platform-tools",
    $platformPackage,
    $BuildToolsPackage
)
& $SdkManager --sdk_root=$SdkRoot @packagesToInstall

Write-Host "Setting environment variables..." -ForegroundColor Yellow
[Environment]::SetEnvironmentVariable("ANDROID_HOME", $SdkRoot, "User")
[Environment]::SetEnvironmentVariable("ANDROID_SDK_ROOT", $SdkRoot, "User")
$env:ANDROID_HOME = $SdkRoot
$env:ANDROID_SDK_ROOT = $SdkRoot

$pathsToAdd = @(
    (Join-Path $SdkRoot "platform-tools"),
    (Join-Path $LatestDir "bin")
)
Merge-UserPathEntries -AdditionalPaths $pathsToAdd
Sync-SessionEnvironment

Write-Host "Configuring Flutter Web browser (Chrome preferred, else Edge)..." -ForegroundColor Yellow
if (Test-Path -LiteralPath $Browser) {
    [Environment]::SetEnvironmentVariable("CHROME_EXECUTABLE", $Browser, "User")
    $env:CHROME_EXECUTABLE = $Browser
} else {
    Write-Host "Browser executable not found at expected path." -ForegroundColor Red
}

Write-Host "Running Flutter validations..." -ForegroundColor Yellow
flutter doctor
Write-Host "=== SETUP COMPLETE ===" -ForegroundColor Green
Write-Host "Open a new terminal (or log off/on) if another app still sees old PATH or JAVA_HOME." -ForegroundColor Gray
Write-Host "To refresh command-line tools later, open a new shell and run: sdkmanager `"cmdline-tools;latest`"" -ForegroundColor Gray
