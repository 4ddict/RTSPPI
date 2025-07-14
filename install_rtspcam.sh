#!/bin/bash

set -e

echo "📦 Installing minimal dependencies..."
sudo apt update
sudo apt install -y --no-install-recommends \
  libcamera-apps \
  ffmpeg \
  curl \
  tar

echo "📡 Downloading and installing MediaMTX RTSP server..."
cd /opt
sudo curl -L https://github.com/bluenviron/mediamtx/releases/latest/download/mediamtx_linux_arm64.tar.gz -o mediamtx.tar.gz
sudo tar -xzf mediamtx.tar.gz
sudo rm mediamtx.tar.gz
sudo mv mediamtx_linux_arm64 mediamtx
sudo tee /etc/mediamtx.yml > /dev/null <<EOF
rtspAddress: ":8554"
paths:
  all:
    source: ffmpeg://
    sourceProtocol: udp
    sourceOnDemand: yes
    ffmpegCommand: >
      libcamera-vid --width 1280 --height 720 --framerate 25
      --bitrate 4000000 --inline --codec h264 -t 0 -o -
      | ffmpeg -re -i - -vcodec copy -f rtsp rtsp://127.0.0.1:8554/live.sdp
EOF

echo "🛠 Setting up systemd service..."
sudo tee /etc/systemd/system/rtspcam.service > /dev/null <<EOF
[Unit]
Description=MediaMTX RTSP Server
After=network.target

[Service]
ExecStart=/opt/mediamtx/mediamtx /etc/mediamtx.yml
Restart=always
User=pi

[Install]
WantedBy=multi-user.target
EOF

echo "🔁 Enabling and starting service..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable rtspcam.service
sudo systemctl start rtspcam.service

echo "✅ Done! RTSP stream available at rtsp://<your-pi-ip>:8554/live.sdp"
