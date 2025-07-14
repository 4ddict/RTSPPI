#!/bin/bash

set -e

SERVICE_NAME="rtspcam"
INSTALL_DIR="/opt/$SERVICE_NAME"
STREAM_PORT=8554

# === Uninstall logic ===
if [[ "$1" == "--uninstall" ]]; then
    echo "> Removing RTSP camera service..."
    sudo systemctl stop $SERVICE_NAME.service || true
    sudo systemctl disable $SERVICE_NAME.service || true
    sudo rm -f /etc/systemd/system/$SERVICE_NAME.service
    sudo rm -rf "$INSTALL_DIR"
    sudo rm -f /usr/local/bin/mediamtx
    echo "✅ Uninstalled successfully."
    exit 0
fi

# === Reinstall logic ===
if [[ "$1" == "--reinstall" ]]; then
    bash "$0" --uninstall
    bash "$0"
    exit 0
fi

# === Ensure required tools ===
echo "> Installing dependencies..."
sudo apt update
sudo apt install -y libcamera-apps ffmpeg curl tar

# === Install mediamtx (RTSP server) ===
echo "> Installing RTSP server (mediamtx)..."
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
curl -L -o mediamtx.tar.gz https://github.com/bluenviron/mediamtx/releases/latest/download/mediamtx_linux_arm64.tar.gz
tar -xvzf mediamtx.tar.gz
sudo mv mediamtx /usr/local/bin/
cd ~
sudo rm -rf "$TMP_DIR"

# === Set up stream script ===
echo "> Setting up streaming service..."
sudo mkdir -p "$INSTALL_DIR"

cat <<EOF | sudo tee "$INSTALL_DIR/stream.sh" > /dev/null
#!/bin/bash
/usr/local/bin/mediamtx &
sleep 1
libcamera-vid --width 1280 --height 720 --framerate 25 --bitrate 4000000 --inline --codec h264 -t 0 -o - | \
ffmpeg -re -i - -vcodec copy -f rtsp rtsp://localhost:$STREAM_PORT/cam
EOF

sudo chmod +x "$INSTALL_DIR/stream.sh"

# === Create systemd service ===
cat <<EOF | sudo tee /etc/systemd/system/$SERVICE_NAME.service > /dev/null
[Unit]
Description=RTSP Camera Streamer
After=network.target

[Service]
ExecStart=$INSTALL_DIR/stream.sh
Restart=always
User=pi

[Install]
WantedBy=multi-user.target
EOF

# === Enable service ===
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable $SERVICE_NAME.service
sudo systemctl start $SERVICE_NAME.service

# === Output ===
IP=$(hostname -I | awk '{print $1}')
echo "===================================="
echo " ✅  Installed and Running!"
echo " 🔄  Reboot recommended"
echo " 📡  RTSP Stream: rtsp://$IP:$STREAM_PORT/cam"
echo " 🧹  Uninstall: ./install_rtspcam.sh --uninstall"
echo " ♻️  Reinstall: ./install_rtspcam.sh --reinstall"
echo "===================================="
