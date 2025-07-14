#!/bin/bash

set -e

PROJECT_DIR="/opt/rtspcam"
SERVICE_NAME="rtspcam"
RTSP_PORT=8554

echo "🔧 Installing RTSP security camera..."

# Install dependencies
sudo apt update
sudo apt install -y libcamera-apps ffmpeg

# Create project directory
sudo mkdir -p "$PROJECT_DIR"
sudo tee "$PROJECT_DIR/start_stream.sh" > /dev/null <<'EOF'
#!/bin/bash

WIDTH=1280
HEIGHT=720
FPS=25
BITRATE=4000000

libcamera-vid \
  --width $WIDTH \
  --height $HEIGHT \
  --framerate $FPS \
  --bitrate $BITRATE \
  --inline \
  --codec h264 \
  -t 0 \
  -o - | \
ffmpeg -re -stream_loop -1 -i - \
  -vcodec copy -f rtsp rtsp://0.0.0.0:8554/live.sdp
EOF

sudo chmod +x "$PROJECT_DIR/start_stream.sh"

# Create systemd service
sudo tee /etc/systemd/system/$SERVICE_NAME.service > /dev/null <<EOF
[Unit]
Description=H.264 RTSP Camera Stream
After=network.target

[Service]
ExecStart=$PROJECT_DIR/start_stream.sh
WorkingDirectory=$PROJECT_DIR
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

# Enable and start service
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl start "$SERVICE_NAME"

# Summary
echo "===================================="
echo " ✅  RTSP Camera Installed and Running!"
echo " 📡  RTSP Stream: rtsp://$(hostname -I | awk '{print $1}'):$RTSP_PORT/live.sdp"
echo " 🧹  Uninstall: sudo systemctl disable --now $SERVICE_NAME && sudo rm -rf $PROJECT_DIR /etc/systemd/system/$SERVICE_NAME.service"
echo "===================================="
