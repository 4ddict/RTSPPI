#!/bin/bash

set -e

echo "📦 Updating package lists..."
sudo apt update -y

echo "📦 Installing minimal dependencies..."
sudo apt install -y --no-install-recommends \
  libcamera-ipa libcamera0.5 \
  ffmpeg curl tar

echo "📦 Downloading and installing MediaMTX RTSP server..."
cd /opt
sudo curl -L -o mediamtx.tar.gz https://github.com/bluenviron/mediamtx/releases/latest/download/mediamtx_linux_arm64.tar.gz
sudo tar -xzf mediamtx.tar.gz
sudo rm mediamtx.tar.gz

# Create RTSP config
cat <<EOF | sudo tee /opt/mediamtx/mediamtx.yml > /dev/null
serverProtocols: [udp, tcp]
paths:
  all:
    source: rtsp://localhost:8554/live.sdp
    sourceProtocol: udp
EOF

echo "📄 Creating systemd service..."

# Create systemd unit for RTSP camera stream
sudo tee /etc/systemd/system/rtspcam.service > /dev/null <<EOF
[Unit]
Description=RTSP Camera Stream (libcamera + ffmpeg + MediaMTX)
After=network.target

[Service]
ExecStart=/bin/bash -c 'libcamera-vid --width 1280 --height 720 --framerate 25 --bitrate 4000000 --inline --codec h264 -t 0 -o - | ffmpeg -re -i - -vcodec copy -f rtsp rtsp://127.0.0.1:8554/live.sdp'
Restart=always
User=pi

[Install]
WantedBy=multi-user.target
EOF

echo "📄 Creating systemd service for MediaMTX..."

# Create systemd unit for MediaMTX server
sudo tee /etc/systemd/system/mediamtx.service > /dev/null <<EOF
[Unit]
Description=MediaMTX RTSP Server
After=network.target

[Service]
WorkingDirectory=/opt/mediamtx
ExecStart=/opt/mediamtx/mediamtx
Restart=always
User=pi

[Install]
WantedBy=multi-user.target
EOF

echo "🚀 Enabling and starting services..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable rtspcam.service mediamtx.service
sudo systemctl start rtspcam.service mediamtx.service

echo "✅ RTSP Camera is now running on rtsp://<your_pi_ip>:8554/live.sdp"
