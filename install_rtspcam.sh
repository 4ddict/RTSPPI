#!/bin/bash
set -e

echo "📷 Installing RTSP Camera Streamer (fully automated)..."

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
  echo "❌ Please run this script as root (use sudo)"
  exit 1
fi

echo "📦 Updating packages..."
apt update -y

echo "📦 Installing minimal dependencies..."
apt install --no-install-recommends -y \
  libcamera0 \
  libcamera-ipa \
  rpicam-apps \
  ffmpeg \
  curl \
  tar

# Set up installation directory
INSTALL_DIR="/opt/rtspcam"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "🌐 Downloading MediaMTX (RTSP server)..."
ARCH="arm64"
MTX_URL="https://github.com/bluenviron/mediamtx/releases/latest/download/mediamtx_linux_${ARCH}.tar.gz"

curl -fsSL "$MTX_URL" -o mediamtx.tar.gz

if ! file mediamtx.tar.gz | grep -q "gzip compressed"; then
  echo "❌ Downloaded MediaMTX file is not a valid gzip archive"
  rm -f mediamtx.tar.gz
  exit 1
fi

tar -xvzf mediamtx.tar.gz
rm mediamtx.tar.gz
chmod +x mediamtx

# Optional: create default MediaMTX config (but it's optional in newer versions)
cat <<EOF > "$INSTALL_DIR/mediamtx.yml"
paths:
  all:
    source: rtsp://localhost:8554/live.sdp
    sourceProtocol: udp
EOF

# Create systemd service
SERVICE_FILE="/etc/systemd/system/rtspcam.service"
echo "🛠 Creating systemd service at $SERVICE_FILE"

cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=RTSP Camera Streamer (libcamera-vid + ffmpeg + MediaMTX)
After=network.target

[Service]
ExecStart=/bin/bash -c 'libcamera-vid --width 1280 --height 720 --framerate 25 --bitrate 4000000 --inline --codec h264 -t 0 -o - | ffmpeg -re -i - -vcodec copy -f rtsp rtsp://127.0.0.1:8554/live.sdp &>/dev/null & sleep 2 && $INSTALL_DIR/mediamtx'
WorkingDirectory=$INSTALL_DIR
Restart=always
User=pi

[Install]
WantedBy=multi-user.target
EOF

echo "🔄 Enabling and starting service..."
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable rtspcam.service
systemctl start rtspcam.service

echo ""
echo "✅ RTSP Camera is installed and running!"
echo ""
echo "🛰 RTSP Stream URL: rtsp://<YOUR_PI_IP>:8554/live.sdp"
echo "🔁 Service: rtspcam.service (auto-starts on boot)"
echo ""
