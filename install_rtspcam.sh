#!/usr/bin/env bash
# ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
# ┃  RTSPPI — Polished Installer (Pi Zero 2 W friendly)         ┃
# ┃  rpicam-vid/libcamera-vid → ffmpeg (push) → MediaMTX (RTSP) ┃
# ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
# Usage:
#   sudo bash install_rtspcam.sh [--width 1280] [--height 720] \
#        [--fps 25] [--bitrate 2000000] [--port 8554] [--path live]
#
# Maintenance:
#   sudo bash install_rtspcam.sh --status
#   sudo bash install_rtspcam.sh --restart
#   sudo bash install_rtspcam.sh --uninstall
#
# After install:  rtsp://<pi-ip>:8554/live
set -euo pipefail

# ───────────────────────── Appearance ──────────────────────────
if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
  BOLD="$(tput bold)"; DIM="$(tput dim)"; RESET="$(tput sgr0)"
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"; BLUE="$(tput setaf 4)"; CYAN="$(tput setaf 6)"
else
  BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""
fi
CHECK="${GREEN}✔${RESET}"; CROSS="${RED}✖${RESET}"; ARROW="${CYAN}➜${RESET}"; INFO="${BLUE}ℹ${RESET}"; WARN="${YELLOW}⚠${RESET}"
banner() {
  cat <<'BANNER'
  _____ _______ _____ _____  _____ _____ 
 |  __ \__   __/ ____|  __ \|  __ \_   _|
 | |__) | | | | (___ | |__) | |__) || |  
 |  _  /  | |  \___ \|  ___/|  ___/ | |  
 | | \ \  | |  ____) | |    | |    _| |_ 
 |_|  \_\ |_| |_____/|_|    |_|   |_____|
                                         
BANNER
  echo -e "        ${DIM}RTSP camera for Raspberry Pi (Zero 2 W ready)${RESET}\n"
}
log(){ echo -e "$1 $2"; }; ok(){ log "${CHECK}" "$1"; }; err(){ log "${CROSS}" "$1"; }; step(){ log "${ARROW}" "${BOLD}$1${RESET}"; }

# ─────────────────────── Defaults & Flags ──────────────────────
WIDTH=1280; HEIGHT=720; FPS=25; BITRATE=2000000
PORT=8554; PATH_SEGMENT="live"

SERVICE_NAME="rtspcam"
RUN_DIR="/opt/${SERVICE_NAME}"
RUN_SCRIPT="${RUN_DIR}/run.sh"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

MTX_SERVICE="mediamtx"
MTX_DIR="/opt/${MTX_SERVICE}"
MTX_BIN="${MTX_DIR}/mediamtx"
MTX_UNIT="/etc/systemd/system/${MTX_SERVICE}.service"
MTX_CFG="${MTX_DIR}/mediamtx.yml"

ACTION="install"

print_help() {
  cat <<EOF
${BOLD}RTSPPI Installer${RESET}

Install (default):
  sudo bash $0 [--width 1280] [--height 720] [--fps 25] [--bitrate 2000000] [--port 8554] [--path live]

Maintenance:
  sudo bash $0 --status
  sudo bash $0 --restart
  sudo bash $0 --uninstall

Flags:
  --width N        Video width (default: ${WIDTH})
  --height N       Video height (default: ${HEIGHT})
  --fps N          Frames per second (default: ${FPS})
  --bitrate N      H.264 bitrate in bits/sec (default: ${BITRATE})
  --port N         RTSP port (default: ${PORT})
  --path NAME      Stream path (default: ${PATH_SEGMENT})
  -h, --help       Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --width) WIDTH="${2:-}"; shift 2;;
    --height) HEIGHT="${2:-}"; shift 2;;
    --fps) FPS="${2:-}"; shift 2;;
    --bitrate) BITRATE="${2:-}"; shift 2;;
    --port) PORT="${2:-}"; shift 2;;
    --path) PATH_SEGMENT="${2:-}"; shift 2;;
    --status) ACTION="status"; shift;;
    --restart) ACTION="restart"; shift;;
    --uninstall) ACTION="uninstall"; shift;;
    -h|--help) print_help; exit 0;;
    *) err "Unknown argument: $1"; print_help; exit 1;;
  esac
done

# ───────────────────────── Sanity helpers ──────────────────────
require_root(){ [[ $EUID -eq 0 ]] || { err "Run as root: sudo bash $0"; exit 1; }; }
require_apt(){ command -v apt-get >/dev/null 2>&1 || { err "Needs apt-get (Debian/Raspberry Pi OS)"; exit 1; }; }
arch_tag(){
  case "$(uname -m)" in
    aarch64|arm64) echo "linux_arm64v8" ;;
    armv7l)        echo "linux_armv7" ;;
    *)             echo "linux_arm64v8" ;;  # default
  esac
}

# ─────────────────────── Install MediaMTX ──────────────────────
install_mediamtx() {
  step "Installing MediaMTX (RTSP server)"
  install -d -m 0755 "${MTX_DIR}"
  local TAG="$(arch_tag)"
  # Try to fetch latest release; fallback to a known path if API blocked
  if command -v curl >/dev/null 2>&1; then
    local URL
    URL="$(curl -s https://api.github.com/repos/bluenviron/mediamtx/releases/latest \
        | grep browser_download_url | grep "${TAG}.tar.gz" | head -n1 | cut -d '"' -f 4 || true)"
    if [[ -z "${URL:-}" ]]; then
      URL="https://github.com/bluenviron/mediamtx/releases/latest/download/mediamtx_${TAG}.tar.gz"
    fi
    curl -L "${URL}" -o "${MTX_DIR}/mediamtx.tar.gz"
  else
    apt-get update -y >/dev/null
    apt-get install -y --no-install-recommends curl >/dev/null
    install_mediamtx; return
  fi
  tar -xzf "${MTX_DIR}/mediamtx.tar.gz" -C "${MTX_DIR}"
  rm -f "${MTX_DIR}/mediamtx.tar.gz"
  chmod +x "${MTX_BIN}"

  # Minimal config: listen on ${PORT}, allow publishing/reading
  cat >"${MTX_CFG}" <<EOF
rtspAddress: :${PORT}
readTimeout: 10s
writeTimeout: 10s
authMethods: [basic, digest]
paths:
  ${PATH_SEGMENT}:
    # no auth by default; add 'publishUser'/'publishPass' later if desired
EOF

  # systemd unit for MediaMTX
  cat >"${MTX_UNIT}" <<EOF
[Unit]
Description=MediaMTX RTSP Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${MTX_DIR}
ExecStart=${MTX_BIN}
Restart=always
RestartSec=2
LimitNOFILE=65535
MemoryMax=120M

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${MTX_SERVICE}" >/dev/null
  sleep 1
  systemctl is-active --quiet "${MTX_SERVICE}" && ok "MediaMTX running on :${PORT}"
}

# ────────────────────────── Actions ────────────────────────────
do_install() {
  banner
  require_root; require_apt

  step "Installing packages (ffmpeg + camera apps)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends ffmpeg rpicam-apps || \
  apt-get install -y --no-install-recommends ffmpeg libcamera-apps
  ok "Installed ffmpeg and camera tools"

  install_mediamtx

  step "Creating runtime directory"
  install -d -m 0755 "${RUN_DIR}"

  step "Writing runner (push to RTSP server)"
  cat >"${RUN_SCRIPT}" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

# Pick camera binary
if command -v rpicam-vid >/dev/null 2>&1; then
  CAMBIN="rpicam-vid"
elif command -v libcamera-vid >/dev/null 2>&1; then
  CAMBIN="libcamera-vid"
else
  echo "ERROR: Neither rpicam-vid nor libcamera-vid found." >&2
  exit 1
fi

WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FPS="${FPS:-25}"
BITRATE="${BITRATE:-2000000}"
PORT="${PORT:-8554}"
PATH_SEGMENT="${PATH_SEGMENT:-live}"

# Camera → ffmpeg (client) → MediaMTX (server on localhost)
"${CAMBIN}" \
  -t 0 --inline -n \
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

  step "Creating systemd service"
  cat >"${UNIT_FILE}" <<EOF
[Unit]
Description=RTSP camera (push to MediaMTX)
After=${MTX_SERVICE}.service
Wants=${MTX_SERVICE}.service

[Service]
Type=simple
# Small boot delay so nothing else grabs the camera right at boot
ExecStartPre=/bin/sleep 3

# Stream parameters (edit to taste)
Environment=WIDTH=${WIDTH}
Environment=HEIGHT=${HEIGHT}
Environment=FPS=${FPS}
Environment=BITRATE=${BITRATE}
Environment=PORT=${PORT}
Environment=PATH_SEGMENT=${PATH_SEGMENT}

WorkingDirectory=${RUN_DIR}
ExecStart=/bin/bash -lc '${RUN_SCRIPT}'

# Robustness
Restart=always
RestartSec=2
StartLimitBurst=0
LimitNOFILE=65535
MemoryMax=300M
KillSignal=SIGINT
TimeoutStopSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}" >/dev/null
  sleep 1

  echo
  step "All set!"
  local ip; ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo -e "${INFO} Stream URL: ${BOLD}rtsp://${ip:-<pi-ip>}:${PORT}/${PATH_SEGMENT}${RESET}"
  echo -e "${INFO} Check server: ${BOLD}ss -tlnp | grep ${PORT}${RESET}   ${DIM}(should show mediamtx listening)${RESET}"
  echo -e "${INFO} Logs (camera): ${BOLD}journalctl -fu ${SERVICE_NAME}${RESET}"
  echo -e "${INFO} Logs (rtsp):   ${BOLD}journalctl -fu ${MTX_SERVICE}${RESET}"
  ok "Done"
}

do_status() {
  require_root; banner
  step "MediaMTX status"; systemctl --no-pager --full status "${MTX_SERVICE}" || true
  echo
  step "Camera push status"; systemctl --no-pager --full status "${SERVICE_NAME}" || true
}

do_restart() {
  require_root; banner
  step "Restarting services"
  systemctl restart "${MTX_SERVICE}"
  systemctl restart "${SERVICE_NAME}"
  ok "Restarted"
}

do_uninstall() {
  require_root; banner
  step "Stopping services"
  systemctl disable --now "${SERVICE_NAME}" >/dev/null || true
  systemctl disable --now "${MTX_SERVICE}" >/dev/null || true
  step "Removing files"
  rm -f "${UNIT_FILE}" "${MTX_UNIT}"
  rm -f "${RUN_SCRIPT}"
  rmdir "${RUN_DIR}" 2>/dev/null || true
  rm -rf "${MTX_DIR}"
  systemctl daemon-reload
  ok "Uninstalled cleanly"
}

# ────────────────────────── Dispatcher ─────────────────────────
trap 'echo -e "\n${CROSS} ${BOLD}Aborted${RESET}"' INT
case "${ACTION}" in
  install)   do_install ;;
  status)    do_status ;;
  restart)   do_restart ;;
  uninstall) do_uninstall ;;
  *) err "Unknown action: ${ACTION}"; exit 1 ;;
esac
