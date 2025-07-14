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

LATEST_URL=$(curl -s https://api.github.com/repos/bluenviron/mediamtx/releases/latest | \
  jq -r ".assets[] | select(.name | test(\"mediamtx_linux_${ARCH}.tar.gz\")) | .browser_download_url")

curl -L "$LATEST_URL" -o mediamtx.tar.gz
tar -xzf mediamtx.tar.gz
sudo mv mediamtx /usr/local/bin/mediamtx
chmod +x /usr/local/bin/mediamtx
cd ~
rm -rf "$TMP_DIR"

echo "📝 Creating RTSP camera stream service..."

# Create systemd service
sudo tee /etc/systemd/system/rtspcam.service > /dev/null <<EOF
[Unit]
Description=Raspberry Pi RTSP Camera Stream
After=network.target

[Service]
ExecStart=/bin/bash -c '/usr/bin/libcamera-vid --width 1280 --height 720 --framerate 25 --bitrate 4000000 --inline --codec h264 -t 0 -o - | /usr/bin/ffmpeg -re -i - -vcodec copy -f rtsp rtsp://localhost:8554/live.sdp'
Restart=always
User=pi
Environment=LIBCAMERA_LOG_LEVELS=3

[Install]
WantedBy=multi-user.target
EOF

echo "📝 Creating MediaMTX service..."

# Create MediaMTX service
sudo tee /etc/systemd/system/mediamtx.service > /dev/null <<EOF
[Unit]
Description=MediaMTX RTSP Server
After=network.target

[Service]
ExecStart=/usr/local/bin/mediamtx
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

echo "✅ RTSP camera is now running."
echo "📺 Stream URL: rtsp://<your-pi-ip>:8554/live.sdp"
