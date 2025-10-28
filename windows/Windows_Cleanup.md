<!--StartFragment -->
🧹 Windows Cleanup Reference Guide
 
This document summarizes the cleanup operations performed and provides safe repeatable steps for future maintenance.

# Sandbox and VM
**Path:** `C:\ProgramData\Microsoft\Windows\Containers\Layers`
### Purpose: 
- It stores container image layers used by Windows features like: Windows Sandbox, Windows Subsystem for Linux (WSL), Docker etc.
- Each “layer” is essentially a virtual disk snapshot (VHDX) containing a Windows base image, WinSxS copies, and other system files needed to spin up isolated environments.
- These can accumulate over time, especially if Sandbox or containerized apps have been launched multiple times.

### Cleanup: 
- If you don’t use Windows Sandbox, WSL etc., disable those features:
    - Search and open "_Turn windows features on or off_".
    - Uncheck whichever feature you don't use: Windows Sandbox, WSL etc. Reboot.
        - ⚠️ Caution: Do NOT uncheck _Containers_ by itself, if you use Sandbox or WSL. 
        - Do NOT uncheck _Virtual Machine Platform_ if you use WSL. 
    - After disabling and reboot, Windows should automatically clean up most of the container layers.
- Run this command to remove superseded component store files that sometimes get duplicated into container layers.
    ```powershell
    dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase
    ```
- If the Container Layers remain there even after disabling the features, you can try to manually delete them - 
    ```powershell
    robocopy "C:\Empty" "C:\ProgramData\Microsoft\Windows\Containers" /MIR
    rmdir "C:\ProgramData\Microsoft\Windows\Containers" /S /Q
    ```
    - (where C:\Empty is just an empty folder you create). This “mirrors” an empty folder over the target, wiping it much faster than Explorer.


# Browser Data
## Edge or Chrome
**Purpose:** Mostly browser cache, site data, extension blobs, and service worker storage.

### Cleanup: 
- Go to: `edge://settings/privacy/cookies/AllCookies` or `chrome://settings/content/all`
    - Sort by "_Most data_" to find heavy sites.
    - Delete individual site data or click "_Remove all_" for a full purge.
    - This targets IndexedDB, localStorage, and FileSystem API data, often the biggest contributors.
- Go to: `edge://settings/clearBrowserData` or `chrome://settings/clearBrowserData`
    - Select "_Cached images and files_", "_Cookies and other site data_", "_Hosted app data_" etc.
    - Choose “All time” for maximum effect.
    - ℹ️ Note: This won’t touch extension data or service worker caches.
- Go to: `C:\Users\Bikram\AppData\Local\Microsoft\Edge\User Data\` or `C:\Users\Bikram\AppData\Local\Google\Chrome Beta\User Data`
    - `Default`
        - This is your main Edge profile: bookmarks, history, cookies, saved passwords, extensions, etc.
        - ⚠️ Don’t delete the whole folder unless you want a full profile reset.
        - Inside it, the biggest sub‑culprits are usually:
            - ✅ `Cache`, `Code Cache`, `GPUCache` → safe to clear (Edge will rebuild as & when needed.).
            - ✅ `IndexedDB` → can be cleared, but you’ll lose offline data for some sites/extensions.
            - ✅ `Service Worker\CacheStorage`
                - This can balloon to several GB if sites use aggressive caching.
                - You can safely delete this folder only if you’re okay losing offline site data (e.g., PWAs or cached web apps).
    - `ProvenanceData`
        - Stores telemetry and experiment data for Edge features.
        - ✅ Safe to delete — Edge will recreate it if needed.
    - `component_crx_cache` & `extensions_crx_cache`
        - Cached extension packages.
        - ✅ Safe to delete — extensions will redownload if needed.

## Chrome
`C:\Users\Bikram\AppData\Local\Google\Chrome Beta\User DataOptGuideOnDeviceModel` (~4.0 GB)
- This is Chrome’s on‑device optimization guide ML model (used for page loading predictions, hints, etc.).
- ✅ Safe to delete — Chrome will redownload models if needed. They’re not critical for browsing.
- To permanently disable this feature: 
    - Run "Regedit.exe" 
    - Navigate to `HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Google\Chrome`
    - Create a new DWORD (32-bit) Value: GenAILocalFoundationalModelSettings 
    - Set Value: 1

## Internet Explorer
`C:\Users\Bikram\AppData\Local\Microsoft\Windows\INetCache\IE`

This path is part of the legacy Internet Explorer cache system. Even though you don’t actively use IE, the Trident engine (the old IE rendering engine) is still embedded in Windows and gets used by some apps and services (for example, parts of Outlook, legacy installers, or apps that embed a web control).

**🔎 What’s inside**
- Temporary internet/cache files created by apps that rely on the IE engine.
- They can include images, HTML fragments, or even leftover uploads (like photos you’ve attached to a web form).
- `PowerToys` downloads its installers here. 

**✅ Can you delete it?**
- Yes, it’s safe to delete the contents.
- Windows and apps will recreate the folder structure as needed.
- You won’t break anything by clearing it — at worst, some apps may need to re‑download cached resources.


# Outlook
`C:\Users\Bikram\AppData\Local\Microsoft\Olk`

When you open an email attachment directly from Outlook (instead of saving it first), Outlook makes a temporary copy in this hidden OLK folder. Outlook doesn’t always clean up after itself, so over time this folder can balloon with duplicate attachments, PDFs, Office docs, images, etc.
- ⚠️ Don’t delete the folder itself (Olk), ✅ delete only its contents.
- ⚠️ Don’t touch anything under AppData\Local\Microsoft\Outlook (different folder) — that’s where your actual OST/PST mailbox data lives.


# Installers / Drivers

## Windows Installer
**Path:** `C:\Windows\Installer` - 5 GB

### Purpose
- Every time you install, update, or patch software that uses the MSI/MSP installer system, Windows drops a copy of the installer package here.
- These cached files are what Windows uses later if you choose Repair, Update, or Uninstall for that program.

### Cleanup
- Run [**PatchCleaner**](https://www.homedev.com.au/free/patchcleaner). It will surface orphaned MSIs. You can either back them up to a different drive or delete them. 
- ⚠️ Do not manually delete files from here. You may break the ability to uninstall or update affected apps. You’d be stuck with “ghost” entries in Programs & Features that can’t be removed without registry surgery.

## DriverStore
`C:\Windows\System32\DriverStore\FileRepository`
- Purpose: Staging area for all drivers installed.
- Problem: Old versions accumulate (Intel Wi‑Fi, Bluetooth, NVIDIA, Killer NICs, etc.).
- Cleanup: Use [**DriverStore Explorer (RAPR)**](https://github.com/lostindark/DriverStoreExplorer) for safely deleting old unused drivers.

## OEM Driver Cache
`C:\Drivers`
- Purpose: OEM‑supplied driver installers (factory preload).
- Problem: Redundant once drivers are staged in DriverStore.
- Cleanup: Safe to delete or move to D: if you’re comfortable redownloading from OEM later, if needed. 
- ⚠️ Caution: If you rely on OEM utilities (Dolby, Killer Control Center, Energy Management), keep those folders.

## NVIDIA Installer2
`C:\Program Files\NVIDIA Corporation\Installer2`
- Purpose: Caches installers for GPU driver components (Display.Driver, PhysX, Audio, Container, etc.).
- Problem: Accumulates multiple versions, wasting GBs.
- Cleanup: Keep the newest folder per component family, prune older duplicates.


# System Criticals
- `C:\pagefile.sys`
    - Purpose: Virtual memory backing store. Used when RAM is full and for crash dumps.
    - Typical size: 1–1.5× RAM, but Windows auto‑manages.
    - Cleanup: Can shrink via *System Properties → Advanced -> Performance → Advanced -> Virtual Memory.
    - ⚠️ Caution: Too small → risk of out‑of‑memory errors or no crash dumps. Never delete manually.

- `C:\$MFT` (Master File Table)
    - Purpose: NTFS database of all files/directories.
    - Size: Grows with file count.
    - ⚠️ Caution: System‑managed. Cannot and should not be manually altered.
- `C:\$Extend\$Deleted`
    - Purpose: NTFS staging area for deleted metadata awaiting cleanup.
    - Cleanup: Reboot or `chkdsk /f` clears it.
    - ⚠️ Caution: Never delete manually.

- `C:\System Volume Information`
    - Purpose: Stores System Restore points, Volume Shadow Copies, indexing databases.
    - Cleanup:
        - Adjust via `sysdm.cpl → System Protection -> configuration`.
        - Or run: 
            ```powershell
            vssadmin list shadowstorage
            vssadmin resize shadowstorage /for=C: /on=C: /maxsize=5GB
            ```

