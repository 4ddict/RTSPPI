# 📡 RTSPPi – RTSP Camera Streamer for Raspberry Pi

**High-performance, low-latency RTSP streaming from Raspberry Pi camera modules**  
Streams H.264 video via hardware-accelerated `rpicam-vid`/`libcamera-vid` → `ffmpeg` → `MediaMTX`.  
Works seamlessly with **Scrypted, Home Assistant, VLC, ffmpeg, and more**.

> ✅ Optimized for Raspberry Pi Zero 2 W running Raspberry Pi OS Lite (Bookworm, kernel 6.12)  
> ✅ Uses [MediaMTX](https://github.com/bluenviron/mediamtx) as the RTSP server for compatibility and stability

---

## 🎯 Project Goals

- 📡 RTSP stream using H.264 (GPU-accelerated)  
- ⚡️ Low latency with tuned FFmpeg flags (`-fflags nobuffer -flags low_delay -muxdelay 0`)  
- 🛡️ Robust server via MediaMTX (TCP only, wildcard paths)  
- 🔄 Self-restarting via `systemd` on boot or failure  
- 💾 Easily adjustable settings (resolution, bitrate, FPS, keyframe interval)  
- 🚫 No browser/UI overhead — just raw RTSP stream  

---

## 📦 Requirements

| Component        | Example Model     |
|------------------|-------------------|
| Raspberry Pi     | Zero 2 W, 3B+, 4  |
| Camera Module    | OV5647, HQ, V2    |
| OS               | Raspberry Pi OS Lite (Bookworm) |

---

## 🚀 Quick Install

Run this on a fresh Raspberry Pi OS (Lite) install:

```bash
curl -fsSL https://raw.githubusercontent.com/4ddict/RTSPPI/main/install_rtspcam.sh -o install_rtspcam.sh && chmod +x install_rtspcam.sh && sudo ./install_rtspcam.sh
```

This will:

- Install dependencies (`ffmpeg`, camera apps, system tools)  
- Download and configure **MediaMTX** RTSP server  
- Set up **`rtspcam` service** to auto-start and push video into MediaMTX  

---

## 📡 RTSP Stream URL

Once installed, your Pi will automatically stream on boot.

Open the stream in **VLC, Scrypted, ffmpeg, Home Assistant**, etc.:

```
rtsp://<your-pi-ip>:8554/live
rtsp://<your-pi-ip>:8554/live.sdp
```

💡 Both URLs are valid (wildcard path config).  

For VLC, force TCP for stability:

```bash
vlc --rtsp-tcp rtsp://<your-pi-ip>:8554/live.sdp
```

---

## ⚙️ Configuration

To change resolution, bitrate, or FPS:

1. Edit `/etc/systemd/system/rtspcam.service`
2. Change these lines:

```bash
WIDTH=1280
HEIGHT=720
FPS=25
BITRATE=2000000
INTRA=25
```

3. Apply changes:

```bash
sudo systemctl daemon-reload
sudo systemctl restart rtspcam
```

---

## 🧹 Uninstall

To fully remove RTSPPi:

```bash
sudo systemctl disable --now rtspcam mediamtx
sudo rm -rf /opt/rtspcam /opt/mediamtx \
  /etc/systemd/system/rtspcam.service \
  /etc/systemd/system/mediamtx.service
sudo systemctl daemon-reload
```

---

## ✅ Features

- ✅ Hardware-accelerated H.264 via `rpicam-vid` / `libcamera-vid`  
- ✅ Low-latency streaming (fast keyframes, tuned ffmpeg flags)  
- ✅ MediaMTX RTSP server (TCP only, wildcard paths)  
- ✅ Auto-start on boot via `systemd`  
- ✅ Works with Scrypted, Home Assistant, VLC, ffmpeg  
- ✅ Lightweight and reliable on Pi Zero 2 W  

---

## 🛠️ Troubleshooting

- ❓ **Stream not loading?**
  - Use the correct URL: `rtsp://<pi-ip>:8554/live` (or `/live.sdp`)
  - Ensure TCP is used (add `--rtsp-tcp` in VLC)
  - Run: `sudo systemctl status rtspcam mediamtx`
  - Logs: `journalctl -u rtspcam -u mediamtx -n 50 --no-pager`

- ❓ **Stream laggy?**
  - Lower `WIDTH`/`HEIGHT`
  - Lower FPS or bitrate
  - Adjust `INTRA` (keyframe interval) for smoother playback

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
  - VLC (with `--rtsp-tcp`)  
  - ffmpeg  
  - Home Assistant  
