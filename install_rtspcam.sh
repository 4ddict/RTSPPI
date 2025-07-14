#!/bin/bash
set -e

echo "📸 RTSP Camera Installer for Raspberry Pi (OV5647, libcamera + MediaMTX)"
echo "🧼 Updating system and installing minimal dependencies..."

sudo apt update
sudo apt full-upgrade -y
sudo apt install -y --no-install-recommends \
    libcamera-apps \
    ffmpeg \
    curl \
    tar

echo "📦 Ensuring legacy libcamera0 is not present..."
sudo apt purge -y libcamera0 || true

echo "📁 Creating /opt/mediamtx directory..."
sudo mkdir -p /opt
cd /opt

echo "📡 Downloading and installing MediaMTX RTSP server..."

ARCH="arm64"
LATEST_URL=$(curl -s https://api.github.com/repos/bluenviron/mediamtx/releases/latest | \
  grep "browser_download_url" | grep "mediamtx_linux_${ARCH}.tar.gz" | cut -d '"' -f 4)

if [[ -z "$LATEST_URL" ]]; then
  echo "❌ Failed to find MediaMTX release for architecture $ARCH."
  exit 1
fi

sudo curl -L "$LATEST_URL" -o mediamtx.tar.gz
sudo tar -xzf mediamtx.tar.gz
sudo rm mediamtx.tar.gz
sudo mv mediamtx_linux_${ARCH} mediamtx

echo "🔧 Creating MediaMTX config file..."

sudo tee /opt/mediamtx/mediamtx.yml > /dev/null <<EOF
serverProtocols: [rtsp]
paths:
  all:
    source: record
EOF

echo "🧾 Creating systemd service..."

sudo tee /etc/systemd/system/rtspcam.service > /dev/null <<EOF
[Unit]
Description=RTSP Camera Stream
After=network.target

[Service]
ExecStart=/bin/bash -c '/usr/bin/libcamera-vid --width 1280 --height 720 --framerate 25 --bitrate 4000000 --inline --codec h264 -t 0 -o - | /usr/bin/ffmpeg -re -i - -vcodec copy -f rtsp rtsp://127.0.0.1:8554/live.sdp'
Restart=always
User=pi

[Install]
WantedBy=multi-user.target
EOF

echo "🔧 Enabling MediaMTX as systemd service..."

sudo tee /etc/systemd/system/mediamtx.service > /dev/null <<EOF
[Unit]
Description=MediaMTX RTSP Server
After=network.target

[Service]
ExecStart=/opt/mediamtx/mediamtx
Restart=always
User=pi

[Install]
WantedBy=multi-user.target
EOF

echo "🚀 Enabling and starting services..."

sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable rtspcam.service
sudo systemctl enable mediamtx.service
sudo systemctl start mediamtx.service
sudo systemctl start rtspcam.service

echo "✅ RTSP camera is now running on rtsp://<your_pi_ip>:8554/live.sdp"
