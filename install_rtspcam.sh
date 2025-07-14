#!/bin/bash
set -e

echo "📸 Installing RTSP Camera Streamer"

# Detect current user (not root)
CURRENT_USER=$(logname)

echo "👤 Detected user: $CURRENT_USER"
echo "📦 Installing minimal dependencies..."

sudo apt update
sudo apt install -y --no-install-recommends \
  libcamera-apps ffmpeg curl tar jq

echo "📡 Downloading and installing MediaMTX RTSP server..."

ARCH="arm64"
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"

RELEASE_JSON=$(curl -s https://api.github.com/repos/bluenviron/mediamtx/releases/latest)

LATEST_URL=$(echo "$RELEASE_JSON" | jq -r '.assets[] | select(.name | test("mediamtx_v.*_linux_'$ARCH'\\.tar\\.gz$")) | .browser_download_url')

if [[ -z "$LATEST_URL" || "$LATEST_URL" == "null" ]]; then
  echo "❌ Could not find a valid MediaMTX release URL for architecture $ARCH"
  exit 1
fi

echo "📦 Downloading: $LATEST_URL"
curl -L "$LATEST_URL" -o mediamtx.tar.gz
tar -xzf mediamtx.tar.gz
sudo mv mediamtx /usr/local/bin/
chmod +x /usr/local/bin/mediamtx

echo "🔧 Creating RTSP camera systemd service..."

sudo tee /etc/systemd/system/rtspcam.service > /dev/null <<EOF
[Unit]
Description=RTSP Camera Stream (libcamera + ffmpeg + MediaMTX)
After=network.target

[Service]
ExecStart=/bin/bash -c '/usr/bin/libcamera-vid --width 1280 --height 720 --framerate 25 --bitrate 4000000 --inline --codec h264 -t 0 -o - | /usr/bin/ffmpeg -re -i - -vcodec copy -f rtsp rtsp://localhost:8554/live.sdp'
Restart=always
User=$CURRENT_USER

[Install]
WantedBy=multi-user.target
EOF

echo "🛰 Creating MediaMTX config and service..."

# Basic config (no auth, single RTSP stream)
sudo tee /etc/mediamtx.yml > /dev/null <<EOF
paths:
  all:
    source: publisher
    runOnDemandRestart: yes
EOF

sudo tee /etc/systemd/system/mediamtx.service > /dev/null <<EOF
[Unit]
Description=MediaMTX RTSP Server
After=network.target

[Service]
ExecStart=/usr/local/bin/mediamtx /etc/mediamtx.yml
Restart=always
User=$CURRENT_USER

[Install]
WantedBy=multi-user.target
EOF

echo "🔄 Enabling and starting services..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable mediamtx.service rtspcam.service
sudo systemctl start mediamtx.service rtspcam.service

PI_IP=$(hostname -I | awk '{print $1}')
echo "✅ All done!"
echo "📺 Your RTSP stream is available at: rtsp://$PI_IP:8554/live.sdp"

