#!/bin/bash

echo "📦 Updating and installing with minimal dependencies..."

sudo apt update
sudo apt install -y --no-install-recommends \
    curl \
    ffmpeg \
    rpicam-apps \
    libcamera-apps \
    libcamera0 \
    libavcodec59 \
    libavformat59 \
    libavutil57 \
    libswscale6

echo "✅ Dependencies installed"

echo "📂 Creating RTSP stream script..."

cat <<EOF | sudo tee /usr/local/bin/start_rtspcam.sh > /dev/null
#!/bin/bash
libcamera-vid \\
  --width 1280 --height 720 --framerate 25 \\
  --bitrate 4000000 --inline --codec h264 -t 0 -o - | \\
  ffmpeg -re -i - -vcodec copy -f rtsp rtsp://0.0.0.0:8554/live.sdp
EOF

sudo chmod +x /usr/local/bin/start_rtspcam.sh

echo "🛠 Creating systemd service..."

cat <<EOF | sudo tee /etc/systemd/system/rtspcam.service > /dev/null
[Unit]
Description=RTSP Camera Streamer
After=network.target

[Service]
ExecStart=/usr/local/bin/start_rtspcam.sh
Restart=always
User=pi
Group=video

[Install]
WantedBy=multi-user.target
EOF

echo "🔄 Enabling service to start on boot..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable rtspcam.service
sudo systemctl start rtspcam.service

echo "✅ RTSP camera service started!"
echo "🌐 Stream URL: rtsp://<your-pi-ip>:8554/live.sdp"
