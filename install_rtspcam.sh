#!/usr/bin/env bash
set -euo pipefail

# ── Appearance ────────────────────────────────
if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
  BOLD="$(tput bold)"; RESET="$(tput sgr0)"
  GREEN="$(tput setaf 2)"; RED="$(tput setaf 1)"; CYAN="$(tput setaf 6)"
else BOLD=""; RESET=""; GREEN=""; RED=""; CYAN=""; fi
CHECK="${GREEN}✔${RESET}"; CROSS="${RED}✖${RESET}"; ARROW="${CYAN}➜${RESET}"

banner() { cat <<'BANNER'
  _____ _______ _____ _____  _____ _____ 
 |  __ \__   __/ ____|  __ \|  __ \_   _|
 | |__) | | | | (___ | |__) | |__) || |  
 |  _  /  | |  \___ \|  ___/|  ___/ | |  
 | | \ \  | |  ____) | |    | |    _| |_ 
 |_|  \_\ |_| |_____/|_|    |_|   |_____|
                                         
BANNER
echo -e "        RTSP camera for Raspberry Pi (Zero 2 W ready)\n"; }
log(){ echo -e "$1 $2"; }; ok(){ log "${CHECK}" "$1"; }; step(){ log "${ARROW}" "$1"; }

# ── Defaults ────────────────────────────────
WIDTH=1280; HEIGHT=720; FPS=25; BITRATE=2000000
PORT=8554; PATH_SEGMENT="live"
SERVICE_NAME="rtspcam"
RUN_DIR="/opt/${SERVICE_NAME}"
RUN_SCRIPT="${RUN_DIR}/run.sh"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
MTX_SERVICE="mediamtx"
MTX_DIR="/opt/${MTX_SERVICE}"
MTX_BIN="${MTX_DIR}/mediamtx"
MTX_CFG="${MTX_DIR}/mediamtx.yml"
MTX_UNIT="/etc/systemd/system/${MTX_SERVICE}.service"

# ── Helpers ────────────────────────────────
require_root(){ [[ $EUID -eq 0 ]] || { echo "${CROSS} Run as root"; exit 1; }; }
arch(){ case "$(uname -m)" in aarch64|arm64) echo "arm64";; armv7l) echo "armv7";; *) echo "arm64";; esac; }

# ── Cleanup old installs ────────────────────
cleanup_old(){
  step "Cleaning old installations"
  systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl disable --now "${MTX_SERVICE}" >/dev/null 2>&1 || true
  rm -f "${UNIT_FILE}" "${MTX_UNIT}" 2>/dev/null || true
  systemctl daemon-reload || true
  rm -rf "${RUN_DIR}" "${MTX_DIR}" 2>/dev/null || true
}

# ── Install MediaMTX ────────────────────────
install_mediamtx(){
  step "Installing MediaMTX"
  install -d -m 0755 "${MTX_DIR}"
  local A; A="$(arch)"
  local URL
  if [[ "${A}" = "arm64" ]]; then
    URL="https://github.com/bluenviron/mediamtx/releases/download/v1.14.0/mediamtx_v1.14.0_linux_arm64.tar.gz"
  else
    URL="https://github.com/bluenviron/mediamtx/releases/download/v1.14.0/mediamtx_v1.14.0_linux_armv7.tar.gz"
  fi
  echo "Downloading: $URL"
  curl -fL -o "${MTX_DIR}/mediamtx.tgz" "$URL"
  tar -xzf "${MTX_DIR}/mediamtx.tgz" -C "${MTX_DIR}"
  rm -f "${MTX_DIR}/mediamtx.tgz"
  chmod +x "${MTX_BIN}"

  # config
  cat >"${MTX_CFG}" <<EOF
rtspAddress: :${PORT}
paths:
  ${PATH_SEGMENT}: {}
EOF

  # systemd unit
  cat >"${MTX_UNIT}" <<EOF
[Unit]
Description=MediaMTX RTSP Server
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
WorkingDirectory=${MTX_DIR}
ExecStart=${MTX_BIN} ${MTX_CFG}
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${MTX_SERVICE}"
  ok "MediaMTX installed"
}

# ── Install camera push ─────────────────────
install_rtspcam(){
  step "Installing camera push service"
  install -d -m 0755 "${RUN_DIR}"
  cat >"${RUN_SCRIPT}" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
if command -v rpicam-vid >/dev/null 2>&1; then CAMBIN="rpicam-vid";
elif command -v libcamera-vid >/dev/null 2>&1; then CAMBIN="libcamera-vid";
else echo "ERROR: No camera binary found." >&2; exit 1; fi

WIDTH="${WIDTH:-1280}"; HEIGHT="${HEIGHT:-720}"; FPS="${FPS:-25}"
BITRATE="${BITRATE:-2000000}"; PORT="${PORT:-8554}"; PATH_SEGMENT="${PATH_SEGMENT:-live}"

"$CAMBIN" -t 0 --inline -n \
  --width "$WIDTH" --height "$HEIGHT" \
  --framerate "$FPS" --bitrate "$BITRATE" \
  --codec h264 -o - \
| ffmpeg -hide_banner -loglevel warning \
    -re -fflags +genpts \
    -r "$FPS" -i pipe:0 \
    -c copy \
    -f rtsp -rtsp_transport tcp \
    "rtsp://127.0.0.1:${PORT}/${PATH_SEGMENT}"
EOS
  chmod +x "${RUN_SCRIPT}"

  cat >"${UNIT_FILE}" <<EOF
[Unit]
Description=RTSP camera (push to MediaMTX)
After=${MTX_SERVICE}.service
Wants=${MTX_SERVICE}.service
[Service]
Type=simple
ExecStartPre=/bin/sleep 3
Environment=WIDTH=${WIDTH}
Environment=HEIGHT=${HEIGHT}
Environment=FPS=${FPS}
Environment=BITRATE=${BITRATE}
Environment=PORT=${PORT}
Environment=PATH_SEGMENT=${PATH_SEGMENT}
WorkingDirectory=${RUN_DIR}
ExecStart=/bin/bash -lc '${RUN_SCRIPT}'
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}"
  ok "Camera service installed"
}

# ── Main ────────────────────────────────────
banner
require_root
cleanup_old

step "Installing packages"
apt-get update -y
apt-get install -y --no-install-recommends ffmpeg rpicam-apps || \
apt-get install -y --no-install-recommends ffmpeg libcamera-apps
ok "Dependencies installed"

install_mediamtx
install_rtspcam

IP=$(hostname -I | awk "{print \$1}")
echo
echo "${CHECK} Installation complete"
echo "${ARROW} RTSP URL: ${BOLD}rtsp://${IP}:${PORT}/${PATH_SEGMENT}${RESET}"
