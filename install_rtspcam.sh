#!/usr/bin/env bash
# ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
# ┃  RTSPPI — Polished Installer (Pi Zero 2 W friendly)         ┃
# ┃  rpicam-vid/libcamera-vid → ffmpeg (RTSP server) + systemd  ┃
# ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
# Usage:
#   sudo bash install_rtspcam.sh [--width 1280] [--height 720] \
#        [--fps 25] [--bitrate 2000000] [--port 8554] [--path live.sdp]
#
# Maintenance:
#   sudo bash install_rtspcam.sh --status
#   sudo bash install_rtspcam.sh --restart
#   sudo bash install_rtspcam.sh --uninstall
#
# After install:  rtsp://<pi-ip>:<port>/<path>
# Defaults (Zero 2 W friendly): 1280x720 @ 25fps, 2 Mbps, TCP
set -euo pipefail

# ───────────────────────── Appearance ──────────────────────────
if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
  BOLD="$(tput bold)"; DIM="$(tput dim)"; RESET="$(tput sgr0)"
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"; BLUE="$(tput setaf 4)"; CYAN="$(tput setaf 6)"
else
  BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""
fi
CHECK="${GREEN}✔${RESET}"
CROSS="${RED}✖${RESET}"
ARROW="${CYAN}➜${RESET}"
INFO="${BLUE}ℹ${RESET}"
WARN="${YELLOW}⚠${RESET}"

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

log() { echo -e "$1 $2"; }
ok()  { log "${CHECK}" "$1"; }
err() { log "${CROSS}" "$1"; }
inf() { log "${INFO}"  "$1"; }
wrn() { log "${WARN}"  "$1"; }
step(){ log "${ARROW}" "${BOLD}$1${RESET}"; }

# ─────────────────────── Defaults & Flags ──────────────────────
WIDTH=1280
HEIGHT=720
FPS=25
BITRATE=2000000      # 2 Mbps default—smooth over 2.4GHz Wi-Fi
PORT=8554
PATH_SEGMENT="live.sdp"

SERVICE_NAME="rtspcam"
RUN_DIR="/opt/${SERVICE_NAME}"
RUN_SCRIPT="${RUN_DIR}/run.sh"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

ACTION="install"

print_help() {
  cat <<EOF
${BOLD}RTSPPI Installer${RESET}

${BOLD}Install (default):${RESET}
  sudo bash $0 [--width 1280] [--height 720] [--fps 25] [--bitrate 2000000] [--port 8554] [--path live.sdp]

${BOLD}Maintenance:${RESET}
  sudo bash $0 --status
  sudo bash $0 --restart
  sudo bash $0 --uninstall

${BOLD}Flags:${RESET}
  --width N        Video width (default: ${WIDTH})
  --height N       Video height (default: ${HEIGHT})
  --fps N          Frames per second (default: ${FPS})
  --bitrate N      H.264 bitrate in bits/sec (default: ${BITRATE})
  --port N         RTSP port (default: ${PORT})
  --path NAME      RTSP path/stream name (default: ${PATH_SEGMENT})
  -h, --help       Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --width)    WIDTH="${2:-}"; shift 2;;
    --height)   HEIGHT="${2:-}"; shift 2;;
    --fps)      FPS="${2:-}"; shift 2;;
    --bitrate)  BITRATE="${2:-}"; shift 2;;
    --port)     PORT="${2:-}"; shift 2;;
    --path)     PATH_SEGMENT="${2:-}"; shift 2;;
    --status)   ACTION="status"; shift;;
    --restart)  ACTION="restart"; shift;;
    --uninstall)ACTION="uninstall"; shift;;
    -h|--help)  print_help; exit 0;;
    *) wrn "Unknown argument: $1"; print_help; exit 1;;
  esac
done

# ───────────────────────── Sanity checks ───────────────────────
require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Please run as root: ${BOLD}sudo bash $0${RESET}"
    exit 1
  fi
}

require_apt() {
  if ! command -v apt-get >/dev/null 2>&1; then
    err "This installer expects ${BOLD}apt-get${RESET} (Debian/Raspberry Pi OS)."
    exit 1
  fi
}

detect_pi() {
  local model="Unknown"
  [[ -f /proc/device-tree/model ]] && model="$(tr -d '\0' </proc/device-tree/model)"
  inf "Detected device: ${BOLD}${model}${RESET}"
}

# ────────────────────────── Actions ────────────────────────────
do_install() {
  banner
  require_root
  require_apt
  detect_pi

  step "Installing packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  # Prefer rpicam-apps (Bookworm); fallback to libcamera-apps (older)
  apt-get install -y --no-install-recommends ffmpeg rpicam-apps || \
  apt-get install -y --no-install-recommends ffmpeg libcamera-apps
  ok "ffmpeg + camera apps installed"

  step "Creating runtime directory"
  install -d -m 0755 "${RUN_DIR}"
  ok "Created ${RUN_DIR}"

  step "Writing runner script"
  cat >"${RUN_SCRIPT}" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

# Choose the camera app available on this system
if command -v rpicam-vid >/dev/null 2>&1; then
  CAMBIN="rpicam-vid"
elif command -v libcamera-vid >/dev/null 2>&1; then
  CAMBIN="libcamera-vid"
else
  echo "ERROR: Neither rpicam-vid nor libcamera-vid found. Install rpicam-apps or libcamera-apps." >&2
  exit 1
fi

WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FPS="${FPS:-25}"
BITRATE="${BITRATE:-2000000}"
PORT="${PORT:-8554}"
PATH_SEGMENT="${PATH_SEGMENT:-live.sdp}"

# Camera → ffmpeg (RTSP server). No 'exec' on the left side!
# Use robust listen syntax: bind all interfaces with -listen 1
"$CAMBIN" \
  -t 0 --inline -n \
  --width "$WIDTH" --height "$HEIGHT" \
  --framerate "$FPS" --bitrate "$BITRATE" \
  --codec h264 -o - \
| ffmpeg -hide_banner -loglevel warning \
  -re -fflags +genpts \
  -r "$FPS" -i pipe:0 \
  -c copy \
  -f rtsp -listen 1 "rtsp://:${PORT}/${PATH_SEGMENT}"
EOS
  chmod +x "${RUN_SCRIPT}"
  ok "Runner at ${RUN_SCRIPT}"

  step "Creating systemd service"
  cat >"${UNIT_FILE}" <<EOF
[Unit]
Description=RTSP camera (rpicam-vid/libcamera-vid -> ffmpeg)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# Boot delay so nothing else grabs the camera right at boot
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
  ok "Service file at ${UNIT_FILE}"

  step "Enabling service"
  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}" >/dev/null || true
  sleep 1
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    ok "Service started"
  else
    wrn "Service not active yet. Check logs with: journalctl -u ${SERVICE_NAME} -n 80 --no-pager"
  fi

  # Firewall (optional)
  if command -v ufw >/dev/null 2>&1; then
    step "Opening firewall port ${PORT}/tcp (ufw)"
    ufw allow "${PORT}/tcp" >/dev/null || true
    ok "Firewall updated"
  fi

  # Show result
  echo
  step "All set!"
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  ip="${ip:-$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)}"
  echo -e "${INFO} Stream URL: ${BOLD}rtsp://${ip:-<pi-ip>}:${PORT}/${PATH_SEGMENT}${RESET}"
  echo -e "${INFO} Check listening: ${BOLD}ss -tlnp | grep ${PORT}${RESET}"
  echo -e "${INFO} Logs: ${BOLD}journalctl -fu ${SERVICE_NAME}${RESET}"
  echo -e "${INFO} Change settings: ${BOLD}sudo systemctl edit ${SERVICE_NAME}${RESET} ${DIM}(or edit ${UNIT_FILE})${RESET}"
  echo -e "${INFO} Restart now: ${BOLD}sudo systemctl restart ${SERVICE_NAME}${RESET}"
  echo
  ok  "Done"
}

do_status() {
  require_root
  banner
  step "Service status"
  systemctl --no-pager --full status "${SERVICE_NAME}" || true
  echo
  echo -e "${INFO} Logs (tail): ${BOLD}journalctl -u ${SERVICE_NAME} -n 80 --no-pager${RESET}"
}

do_restart() {
  require_root
  banner
  step "Restarting ${SERVICE_NAME}"
  systemctl restart "${SERVICE_NAME}"
  systemctl is-active --quiet "${SERVICE_NAME}" && ok "Service active"
  echo -e "${INFO} Live logs: ${BOLD}journalctl -fu ${SERVICE_NAME}${RESET}"
}

do_uninstall() {
  require_root
  banner
  step "Stopping & disabling service"
  systemctl disable --now "${SERVICE_NAME}" >/dev/null || true
  ok "Service stopped"

  step "Removing files"
  rm -f "${UNIT_FILE}"
  rm -f "${RUN_SCRIPT}"
  rmdir "${RUN_DIR}" 2>/dev/null || true
  ok "Removed ${UNIT_FILE} and ${RUN_DIR}"

  step "Reloading systemd"
  systemctl daemon-reload
  ok "Uninstalled cleanly"
}

# ────────────────────────── Dispatcher ─────────────────────────
trap 'echo -e "\n${CROSS} ${BOLD}Aborted${RESET}"' INT
case "${ACTION}" in
  install)   do_install ;;
  status)    do_status  ;;
  restart)   do_restart ;;
  uninstall) do_uninstall ;;
  *) err "Unknown action: ${ACTION}"; exit 1 ;;
esac
