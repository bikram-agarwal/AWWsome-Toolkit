# Pixel AI Intelligence Partition Extraction & Analysis

## 📦 Contents
- Pixel partition extraction workflow (WSL2 + F2FS)
- Sparse to raw image conversion
- WSL2 setup and kernel customization
- Mounting Android `.img` files in WSL2
- Gemini Nano / AICore model fingerprinting
- Future additions: My encounters with rooting tools, Magisk modules, bootloader tweaks etc.
  
---

## 💻 Enabling/Installing WSL2 on Windows

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

## 🗜️ Converting Sparse Image to Raw Image

### 1. Download the Pixel Factory Image (Windows)
- From Google's [Pixel Factory Image](https://developers.google.com/android/images) site, download the factory image zip to your Windows device.
    - e.g. `mustang-bd1a.250702.001-factory-c37e6f51.zip`
- Extract the large image zip from that.
    - e.g. `image-mustang-bd1a.250702.001.zip`
- Extract the `userdata_exp.ai.img` from that image zip.

### 2. Convert Sparse to Raw Using `simg2img` (macOS)
- On WSL, install the `simg2img` tool via this command:
  ```bash
  sudo apt install android-sdk-libsparse-utils
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

## 📂 Mounting the `/intelligence` Partition in WSL2

### 1. Custom Kernel with F2FS Support
- Download a pre‑built WSL2 kernel with F2FS enabled (`bzImage-x64v3`) to avoid compiling from source.
    - Example: [`bzImage-x64v3`](https://github.com/Locietta/xanmod-kernel-WSL2/releases)
- Rename it and add the path in `C:\Users\<YourName>\.wslconfig`:
  ```
  [wsl2]
  kernel=kernel=D:\\SW\\P10PXL\\wsl-f2fs-kernel
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

## 📁 Copying files from mounted image to Windows
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

## 🧠 Fingerprinting Model Files (Optional)
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

## 📊 Analysis Summary
There are a total of 192 files in the image.
![Image Extract](https://github.com/user-attachments/assets/cef952d1-1c9c-4abb-90a6-792557565c2c)
- **`.tflite` (188 files):** — TensorFlow Lite models used for on-device inference. These are optimized neural network models for tasks like vision, audio, and multimodal processing.
    - `audio_adapter_*`, `audio_layer_*`: Handle audio preprocessing and feature extraction.
    - `cross_layer_*` (32 files): Multimodal transformer fusion layers that combine inputs from different modalities (e.g., image + text).
    - `dot_attention_global_*` (130 files): Attention heads used in transformer architectures.
    - `image_adaptor-*`, `image_encoder-*`, `ple_proj-*`: Vision embedding pipeline components that convert raw image data into feature vectors.
- **`.binarypb` (3 files):** Protocol buffer files used to store structured metadata and configuration.
    - `checkpoint.binarypb`: Likely used to track model training or versioning checkpoints.
    - `config.binarypb`: Contains configuration parameters for model execution or runtime behavior.
    - `manifest.binarypb`: Describes the model bundle contents, including file paths, types, and relationships.
- **`data0` file (1.5 GB)** — A large shared weight blob containing the actual trained parameters for the models. This file is referenced by the `.binarypb` manifest and config files and used by the `.tflite` models during inference.

---

## ✅ End Result
You now have:
- A repeatable method to convert sparse factory images to raw format.
- A method to mount and extract `/intelligence` from a Pixel factory image in WSL2.
- A clean copy of all files into Windows.
- A fingerprinting process to identify which files are likely part of Gemini Nano / AICore.

## ❓ Open Questions
While we've successfully extracted and fingerprinted the `/intelligence` partition, it's still unclear whether these files can be placed back onto a Pixel device in a specific path to enable Gemini Nano or AICore features.

We know: 
- On Pixel 10 series, there is a `/data/vendor/intelligence` folder/mount which has these `.tflite` and other such files.
- On Pixel 9 series, [AI Core](https://play.google.com/store/apps/details?id=com.google.android.aicore) app stores AI Models somewhere under `/data/user/0/com.google.android.aicore` 
  
We don't yet know:
- Whether simply copying the `.tflite`, `.binarypb`, and `data0` files to a devices will trigger AICore to load them.
- If additional permissions, signatures, or system-level integration are required to activate these features.

Further experimentation is needed to determine if these extracted models can be used to re-enable or sideload AI features on-device.
