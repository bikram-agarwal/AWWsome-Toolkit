# Pixel Boot Patch: Windows Script

## 🛠️ Overview
If you want to root your Pixel device using the KernelSU based GKI offerings, this PowerShell script automates the boot image patching process, as described in the [📖 KernelSU Installation Guide](https://kernelsu.org/guide/installation.html#using-magiskboot-on-PC). Specifically, it:

1. Unzips the user-provided device factory image zip and extracts the boot.img from it. 
2. Extracts the GKI kernel image from the user-provided kernel zip. 
3. Unpacks the stock `boot.img` to extract the kernel.
2. Replaces the kernel with the GKI kernel `Image` file.
3. Repackages the `boot.img` into a new patched image.
4. Outputs the patched image for flashing to the device.

## 🚨 Disclaimer
**Use this script at your own risk.**

- The author is not responsible for any damage to your device, including but not limited to bricking, data loss, or hardware failure.
- Ensure you understand the process and have backups of your data before proceeding.
- This script is provided "as is" without any warranty.

## 📋 Prerequisites
Before running the script, ensure the following requirements are met:

1. **Windows Operating System**: The script is designed to run on Windows.
2. **PowerShell**: Ensure PowerShell is installed and accessible.
3. **WinRAR**: Install WinRAR and update the script with the correct path to `WinRAR.exe`.
   - [Download WinRAR](https://www.win-rar.com/download.html)
4. **magiskboot**: Place the `magiskboot.exe` executable in the same directory as the script.
   - Download magiskboot: [from svoboda18](https://github.com/svoboda18/magiskboot/releases/latest) or [from PiNaCode](https://github.com/PinNaCode/magiskboot_build/releases/latest)
5. **Factory Image**: Place the phone's factory image ZIP file (matching the pattern `*-factory-*.zip`) in the same directory as the script.
    - Pixel Factory Images: [Stable](https://developers.google.com/android/images), [Beta](https://developer.android.com/about/versions/16/qpr2/download)
6. **Kernel ZIP**: Place the GKI kernel ZIP file (matching the pattern `*AnyKernel3.zip`) in the same directory as the script.
    - [WildKernels](https://github.com/WildKernels/GKI_KernelSU_SUSFS/releases)

### My Setup
This was my environment during writing and testing this script: 
* Pixel 9 Pro XL, running Android 16 QPR2 Beta 3.1
* WildKernel GKI Mode, using `WKSU-13974-SUSFS_v1.5.12-android14-6.1.155-lts-Normal-BBG-AnyKernel3.zip`

So this script should work on any Pixel 7, 8, 9, 10 series phones, using WKSU kernel. It might work on other phone and kernel combo too, but I haven't tested any other. Experiment (at your own risk) and see. 

## 🚀 How to Use

### Step 1: Prepare the Environment
1. Download and install WinRAR.
2. Ideally, create a new directory somewhere and save this script in it. 
3. Place the `magiskboot.exe` executable in the same directory as the script.
4. Place the factory image ZIP and kernel ZIP files to the same directory.
5. Open the script in any text editor and edit the variables in the script, as per your environment - 
    ```powershell
    $FactoryPattern = '*-factory-*.zip'
    $ImagePattern = 'image-*.zip'
    $KernelPattern = '*AnyKernel3.zip'
    $Magiskboot = Join-Path $ScriptDir 'magiskboot-svoboda18.exe'
    $Extractor = "D:\SW\WinRAR\WinRAR.exe"
    ```

### Step 2: Run the Script
1. Open PowerShell.
2. Navigate to the directory containing the script and required files.
   ```powershell
   cd "D:\SW\platform-tools-36.0.0\boot_patcher"
   ```
3. Run the script:
   ```powershell
   .\pixel_boot_patcher.ps1
   ```
4. Follow the on-screen instructions. The script will:
   - Validate prerequisites.
   - Extract the factory image and kernel ZIP.
   - Patch the boot image using `magiskboot`.
   - Save the patched boot image with a timestamp.

### Step 3: Verify the Output
- The patched boot image will be saved in the same directory with a name like `boot_patched_YYYYMMDD_HHMMSS.img`.
- Check the console output for the SHA1 hash of the patched image.

### Step 4: Flash the Patched Image
- Use `fastboot` to flash the patched image to your device.
    ```powershell
    fastboot flash boot_a boot_patched.img
    ```

## 🐞 Troubleshooting
- **WinRAR Not Found**: Ensure the path to `WinRAR.exe` is correct in the script.
- **Missing Files**: Ensure all required files (factory image, kernel ZIP, `magiskboot`) are in the correct directory.

## 📜 License
This script is free to use and modify. However, the author assumes no responsibility for its use.

---

**Happy Patching!**