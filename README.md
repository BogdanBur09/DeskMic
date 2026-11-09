# DeskMic 🎙️

> Transform your retro **iPhone 4s (iOS 9.3, armv7 32-bit)** into a low-latency, high-fidelity wireless PC microphone over Wi-Fi with dedicated Windows GUI receiver, zero-drift latency reset, and real-time DSP noise filtering.

![Platform](https://img.shields.io/badge/iOS-9.0%2B%20%7C%20iPhone%204s-blue)
![Architecture](https://img.shields.io/badge/Arch-armv7%2032--bit-orange)
![Windows](https://img.shields.io/badge/Windows-Receiver%20GUI-green)
![License](https://img.shields.io/badge/License-MIT-lightgrey)

---

## 🌟 Highlights

* **Ultra-Low Battery & CPU Usage**: 
  * Direct Linear PCM audio streaming over raw POSIX UDP sockets.
  * No lossy real-time encoding on the iPhone A5 chip (~0% overhead, incredible battery life).
  * Windows receiver consumes < 7 MB RAM and 0.2% CPU on PC.
* **Apple Dual-Mic Ambient Cancellation**:
  * Utilizes both physical microphone capsules on the iPhone 4s: primary bottom voice capsule + top ambient reference capsule for real-time differential acoustic cancellation.
* **Smart Audio DSP Suite**:
  * **80 Hz Low-Cut (High-Pass)**: Eliminates mechanical desk knocks, keyboard bottoming-out thumps, and room rumble.
  * **Mouse De-Clicker**: Detects extreme slew-rate impulses to suppress sharp plastic mouse clicks.
  * **Smart Noise Gate**: Silences background typing when not speaking with ~160ms release hold.
  * **Fast Peak Limiter**: Tames loud transient clacks from spiking above your vocal volume.
  * **Hardware Pre-amp Gain Slider**: Continuous `0.05x` to `1.00x` analog slider with instant `0.50x (Default)` reset.
* **Zero-Drift Latency Reset**:
  * Dedicated **`⚡ RESET LATENCY`** button on PC receiver flushes backlogged UDP socket and driver buffers instantly back to 0 ms real-time sync.
* **Lock-Screen Background Streaming**:
  * `UIBackgroundModes: audio` ensures continuous streaming when the iPhone screen is locked.

---

## 📁 Repository Structure

```
├── DeskMic.ipa                  # Ready-to-install iOS package (Sideloadly / AltStore / AppSync)
├── DeskMic_installer.deb        # Jailbreak Debian package for Cydia / Zebra / Filza / SSH
├── DeskMic_Receiver.exe         # Standalone Windows GUI executable (zero install needed)
├── receiver.py                  # Python Tkinter receiver source code
├── run_receiver.bat             # Convenience Windows launcher script
├── requirements.txt             # Python dependencies (sounddevice, numpy)
├── RootViewController.m         # iPhone 4s UIKit & DSP audio pipeline (Objective-C)
├── RootViewController.h         # Controller header & state definitions
├── AppDelegate.m / .h           # iOS application lifecycle
├── main.m                       # Entry point
├── Makefile                     # Theos compilation configuration
├── control                      # Debian package metadata
├── Info.plist                   # iOS bundle configuration & audio background mode
└── Resources/                   # App bundle resources
```

---

## 🚀 Quick Start

### 1. iPhone 4s Installation

You can install DeskMic via either method:

* **Method A (Jailbroken / Cydia / Filza)**:
  * Transfer [`DeskMic_installer.deb`](DeskMic_installer.deb) to the phone and install with Filza or via terminal:
    ```bash
    dpkg -i DeskMic_installer.deb && uicache
    ```
* **Method B (Sideload / IPA)**:
  * Install [`DeskMic.ipa`](DeskMic.ipa) using **Sideloadly**, **AltStore**, or **AppSync Unified**.

### 2. Windows PC Receiver Setup

1. **Routing Audio to Discord / Games / OBS**:
   * Install [VB-Audio Virtual Cable](https://vb-audio.com/Cable/) (Free) or Virtual Audio Cable.
   * `DeskMic_Receiver` will automatically detect and route audio into `CABLE Input` (Line 1).
   * In Discord / Game voice settings, set your **Input Device** to `CABLE Output (VB-Audio Virtual Cable)`.
2. **Launch Receiver**:
   * Run [`DeskMic_Receiver.exe`](DeskMic_Receiver.exe) directly, or execute `python receiver.py`.
   * Note the IP displayed prominently at the top (e.g. `192.168.1.138`).

### 3. Connect & Stream

1. Open **DeskMic** on the iPhone 4s.
2. Enter the IP shown on your PC receiver.
3. Tap **START STREAMING**.
4. The receiver will instantly switch to **● Streaming Active** and the live VU level meter will respond.
5. If delay slowly accumulates after hours of continuous gaming, tap **`⚡ RESET LATENCY`** to instantly clear backlogged packets back to 0 ms.

---

## 🛠️ Compilation from Source (Theos)

Requirements: Linux or WSL with Theos installed and `iPhoneOS9.3.sdk` (or iOS 9 SDK).

```bash
# Build Debian package (.deb)
make clean && make package FINALPACKAGE=1

# Build IPA (.ipa)
make package PACKAGE_FORMAT=ipa FINALPACKAGE=1
```

---

## 📄 License

MIT License. Designed with retro-hardware love for keeping classic devices alive and functional.
