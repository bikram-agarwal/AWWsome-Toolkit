# Pixel Intelligence Partition Extraction & Analysis

## 📦 Contents
- Pixel partition extraction workflow (WSL2 + F2FS)
- Sparse to raw image conversion
- WSL2 setup and kernel customization
- Mounting Android `.img` files in WSL2
- Gemini Nano / AICore model fingerprinting
- Future additions: My encounters with rooting tools, Magisk modules, bootloader tweaks etc.
  
---

## 1. Converting Sparse Image to Raw Image

### 1. Download the Factory Image (macOS)
- From Google's [Pixel Factory Image](https://developers.google.com/android/images) site, download the factory image ZIP to your macOS device.
    - e.g. `mustang-bd1a.250702.001-factory-c37e6f51.zip`
- Extract the large image ZIP from that.
    - e.g. `image-mustang-bd1a.250702.001.zip`
- Extract the `userdata_exp.ai.img` from that.

### 2. Convert Sparse to Raw Using `simg2img` (macOS)
- On macOS, install the `simg2img` tool via this command:
  ```bash
  brew install simg2img
  ```
- Run the following command to convert the sparse image:
  ```bash
  simg2img userdata_exp.ai.img userdata_exp_raw.ai.img
  ```
- This produces a raw image suitable for mounting.

### 3. Inspect Raw Image Format (macOS)
- Use the `file -s` command to inspect the raw image format:
  ```bash
  file -s userdata_exp_raw.ai.img
  ```
- Expected output:
  ```bash
  userdata_exp_raw.ai.img: F2FS filesystem data, UUID=... , volume name "/intelligence"
  ```
- In our case, the output revealed it was an F2FS image — critical for knowing how to mount it later.

---

## 2. Enabling/Installing WSL2 on Windows

### 1. Enable Virtualization Support
- Open PowerShell as Administrator and run the following commands:
  ```powershell
  dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
  dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
  ```
- These commands ensure your system supports virtualization and the Windows Subsystem for Linux.

### 2. Install WSL and Set Version to WSL2
- Run:
  ```powershell
  wsl --install
  ```
- This installs the default Linux distribution and sets WSL2 as the default version.
- Note: The default distro is usually Ubuntu, but we explicitly installed Ubuntu to ensure compatibility with tools like `mount`, `file`, and `strings`.

### 3. Verify WSL Version
- Run:
  ```powershell
  wsl --list --verbose
  ```
- Confirm that your installed distro is using version 2.

### 4. Update Kernel (if needed)
- If prompted, download and install the [WSL2 Linux kernel update package](https://aka.ms/wsl2kernel).

---

## 3. Mounting the `/intelligence` Partition in WSL2 (Windows)

### 1. Custom Kernel with F2FS Support
- Download a pre‑built WSL2 kernel with F2FS enabled (`bzImage-x64v3`) to avoid compiling from source.
    - Example: [`bzImage-x64v3`](https://github.com/Locietta/xanmod-kernel-WSL2/releases)
- Rename it and add the path in `C:\Users\<YourName>\.wslconfig`:
  ```
  [wsl2]
  kernel=kernel=D:\SW\P10PXL\wsl-f2fs-kernel
  ```
- Shutdown WSL:
  ```powershell
  wsl --shutdown
  ```

### 2. Verify F2FS Support (WSL)
- Relaunch the WSL Ubuntu and run this command: 
  ```bash
  cat /proc/filesystems | grep f2fs
  ```
- Output containing `f2fs` confirms support.

### 3. Mount the Image (WSL)
```bash
sudo mkdir /mnt/pixel
sudo mount -t f2fs -o loop /mnt/d/SW/P10PXL/userdata_exp_raw.ai.img /mnt/pixel
```
- Expected output: No error message if successful.

---

## 4. Copying files from mounted image to Windows (WSL) 📁
- Create a Windows‑accessible folder:
```bash
mkdir -p /mnt/d/SW/P10PXL/extract
```
- Copy all files (non‑hidden):
```bash
cp -r /mnt/pixel/* /mnt/d/SW/P10PXL/extract/
```
- Verify file counts (including hidden files) matched:
```bash
find /mnt/pixel -mindepth 1 -printf '.' | wc -c
find /mnt/d/SW/P10PXL/extract -mindepth 1 -printf '.' | wc -c
```
- Expected output: Same number for both commands.

---

## 4. Fingerprinting Model Files (WSL)
- Ran a script to scan `.tflite`, `.binarypb`, and `data0` for keywords:
```bash
{ for f in $(find /mnt/pixel -type f -name "*.tflite"); do
    echo "=== $f ==="
    file "$f" | sed 's/^/ /' strings -n 20 "$f" | grep -E -i 'vision|image|camera|speech|voice|text|nlp|gemini|embedding|classif|detect' | head -n 10
    echo
  done
  for f in $(find /mnt/pixel -type f -name "*.binarypb"); do
    echo "=== $f ===" strings -n 20 "$f" | grep -E -i 'vision|image|camera|speech|voice|text|nlp|gemini|embedding|classif|detect' | head -n 10
    echo
  done
  echo "=== data0 blob ==="
  file /mnt/pixel/**/data0 strings -n 20 /mnt/pixel/**/data0 | head -n 20
} > /mnt/d/SW/P10PXL/model_fingerprint.txt
```
- This produced a Windows‑readable `model_fingerprint.txt` with:
    - Model architecture hints (`resnet`, `vit`, `dense`, `blocks_adapter`)
    - Task keywords (`vision`, `speech`, `nlp`, `gemini`)
    - Confirmation of large shared weight blob (`data0`)

---

## 5. Analysis Summary
From the fingerprinting:
- **High‑value Gemini/AICore candidates**:
    - `cross_layer_*` (multimodal transformer fusion layers)
    - `dot_attention_global_*` (attention heads)
    - `image_encoder-*`, `image_adaptor-*`, `ple_proj-*` (vision embedding pipeline)
    - [`manifest.binarypb`](https://manifest.binarypb), [`config.binarypb`](https://config.binarypb), `data0` (model manifest/config/weights)
- **Lower‑priority**:
    - `audio_*` models (speech/audio processing, likely unrelated to Gemini issue)

---

## ✅ End Result
You now have:
- A repeatable method to convert sparse factory images to raw format.
- A method to mount and extract `/intelligence` from a Pixel factory image in WSL2.
- A clean copy of all files into Windows.
- A fingerprinting process to identify which files are likely part of Gemini Nano / AICore.
