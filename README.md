# 📡 RTSPPi – RTSP Camera Streamer for Raspberry Pi

**High-performance, headless RTSP streaming from Raspberry Pi camera modules**  
Streams H.264 video via hardware-accelerated `libcamera-vid` and `ffmpeg`, ideal for Scrypted, Home Assistant, VLC, and more.

> ✅ Optimized for Raspberry Pi Zero 2 W running Raspberry Pi OS Lite (Bookworm, kernel 6.12)

---

## 🎯 Project Goals

- 🔄 RTSP stream using H.264 (GPU-accelerated)
- ⚡️ Minimal resource usage (perfect for Pi Zero 2 W)
- 🚫 No browser/UI overhead — just raw stream
- 🧠 Headless operation with `systemd` autostart
- 💾 Easily adjustable settings (resolution, bitrate, FPS)

---

## 📦 Requirements

| Component        | Example Model     |
|------------------|-------------------|
| Raspberry Pi     | Zero 2 W, 3B+, 4  |
| Camera Module    | OV5647, HQ, V2    |
| OS               | Raspberry Pi OS Lite (Bookworm) |

---

## 🚀 Quick Install

Run this on a fresh Raspberry Pi OS Lite install:

```bash
curl -fsSL https://raw.githubusercontent.com/4ddict/RTSPPI/main/install_rtspcam.sh -o install_rtspcam.sh
chmod +x install_rtspcam.sh
sudo ./install_rtspcam.sh
```

---

## 📡 RTSP Stream URL

Once installed, your Pi will automatically stream on boot.

Open the stream in VLC, Scrypted, ffmpeg, etc.:

```
rtsp://<your-pi-ip>:8554/live.sdp
```

_Example:_  
`rtsp://192.168.0.221:8554/live.sdp`

---

## ⚙️ Configuration

To change resolution, bitrate, or FPS:

1. Edit `/opt/rtspcam/start_stream.sh`
2. Change these lines:

```bash
WIDTH=1280
HEIGHT=720
FPS=25
BITRATE=4000000
```

3. Restart the service:

```bash
sudo systemctl restart rtspcam
```

---

## 🧹 Uninstall

To fully remove RTSPPi:

```bash
sudo systemctl disable --now rtspcam
sudo rm -rf /opt/rtspcam /etc/systemd/system/rtspcam.service
sudo systemctl daemon-reload
```

---

## ✅ Features

- ✅ Hardware-accelerated H.264 encoding via `libcamera-vid`
- ✅ Live RTSP stream via `ffmpeg`
- ✅ Auto-start on boot via `systemd`
- ✅ Works with Scrypted, Home Assistant, VLC, ffmpeg
- ✅ Lightweight and fast for Pi Zero 2 W

---

## 🛠️ Troubleshooting

- ❓ **Stream not loading?**
  - Make sure port `8554` is not blocked
  - Run: `sudo systemctl status rtspcam`
  - Check logs: `journalctl -u rtspcam`

- ❓ **Stream laggy?**
  - Lower resolution (e.g. 960x540)
  - Lower FPS or bitrate

---

## 👨‍💻 Author

Made with 💻 + ❤️ by [**@4ddict**](https://github.com/4ddict)

Feel free to [open issues](https://github.com/4ddict/RTSPPI/issues) or contribute!

---

## 🧪 Tested

- ✅ Raspberry Pi Zero 2 W
- ✅ Raspberry Pi OS Lite (Bookworm, 2025)
- ✅ Camera Modules: OV5647, V2, HQ
- ✅ Works with:
  - Scrypted
  - VLC
  - ffmpeg
  - Home Assistant
