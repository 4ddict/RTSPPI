#!/bin/bash
set -e

echo "📦 Installing minimal dependencies..."
sudo apt update
sudo apt install -y --no-install-recommends \
    libcamera-apps \
    ffmpeg \
    curl \
    tar \
    jq

echo "📡 Downloading and installing MediaMTX RTSP server..."

ARCH="arm64"
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"

# Get the latest release info
RELEASE_JSON=$(curl -s https://api.github.com/repos/bluenviron/mediamtx/releases/latest)

# Parse the correct URL for arm64 binary
LATEST_URL=$(echo "$RELEASE_JSON" | jq -r ".assets[] | select(.name | test(\"mediamtx_linux_${ARCH}\\.tar\\.gz\")) | .browser_download_url")

# Check if URL was found
if [[ -z "$LATEST_URL" || "$LATEST_URL" == "null" ]]; then
  echo "❌ Could not find a valid MediaMTX release URL for architecture $ARCH"
  exit 1
fi

# Download and install
curl -L "$LATEST_URL" -o mediamtx.tar.gz
tar -xzf mediamtx.tar.gz
sudo mv mediamtx /usr/local/bin/
chmod +x /usr/local/bin/mediamtx
cd ~
rm -rf "$TMP_DIR"

echo "📝 Creating RTSP camera stream service..."

CURRENT_USER=$(whoami)

# Create systemd service for camera
sudo tee /etc/systemd/system/rtspcam.service > /dev/null <<EOF
[Unit]
Description=Raspberry Pi RTSP Camera Stream
After=network.target

[Service]
ExecStart=/bin/bash -c '/usr/bin/libcamera-vid --width 1280 --height 720 --framerate 25 --bitrate 4000000 --inline --codec h264 -t 0 -o - | /usr/bin/ffmpeg -re -i - -vcodec copy -f rtsp rtsp://localhost:8554/live.sdp'
Restart=always
User=${CURRENT_USER}
Environment=LIBCAMERA_LOG_LEVELS=3

[Install]
WantedBy=multi-user.target
EOF

echo "📝 Creating MediaMTX service..."

# Create systemd service for MediaMTX
sudo tee /etc/systemd/system/mediamtx.service > /dev/null <<EOF
[Unit]
Description=MediaMTX RTSP Server
After=network.target

[Service]
ExecStart=/usr/local/bin/mediamtx
Restart=always
User=${CURRENT_USER}

[Install]
WantedBy=multi-user.target
EOF

echo "🚀 Enabling and starting services..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable mediamtx.service
sudo systemctl enable rtspcam.service
sudo systemctl start mediamtx.service
sudo systemctl start rtspcam.service

echo "✅ RTSP camera is now running."
echo "📺 Stream URL: rtsp://<your-pi-ip>:8554/live.sdp"
