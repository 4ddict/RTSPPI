#!/usr/bin/env bash
# ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
# ┃  RTSPPI — Polished Installer (Pi Zero 2 W friendly)         ┃
# ┃  rpicam-vid/libcamera-vid → ffmpeg (push) → MediaMTX (RTSP) ┃
# ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
set -euo pipefail

# ── Appearance ─────────────────────────────────────────────────
if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
  BOLD="$(tput bold)"; DIM="$(tput dim)"; RESET="$(tput sgr0)"
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"; BLUE="$(tput setaf 4)"; CYAN="$(tput setaf 6)"
else BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; fi
CHECK="${GREEN}✔${RESET}"; CROSS="${RED}✖${RESET}"; ARROW="${CYAN}➜${RESET}"; INFO="${BLUE}ℹ${RESET}"; WARN="${YELLOW}⚠${RESET}"
banner(){ cat <<'BANNER'
  _____ _______ _____ _____  _____ _____ 
 |  __ \__   __/ ____|  __ \|  __ \_   _|
 | |__) | | | | (___ | |__) | |__) || |  
 |  _  /  | |  \___ \|  ___/|  ___/ | |  
 | | \ \  | |  ____) | |    | |    _| |_ 
 |_|  \_\ |_| |_____/|_|    |_|   |_____|
                                         
BANNER
echo -e "        ${DIM}RTSP camera for Raspberry Pi (Zero 2 W ready)${RESET}\n"; }
log(){ echo -e "$1 $2"; }; ok(){ log "${CHECK}" "$1"; }; err(){ log "${CROSS}" "$1"; }; wrn(){ log "${WARN}" "$1"; }; step(){ log "${ARROW}" "${BOLD}$1${RESET}"; }

# ── Defaults & flags ───────────────────────────────────────────
WIDTH=1280; HEIGHT=720; FPS=25; BITRATE=2000000
PORT=8554; PATH_SEGMENT="live"
SERVICE_NAME="rtspcam"; RUN_DIR="/opt/${SERVICE_NAME}"; RUN_SCRIPT="${RUN_DIR}/run.sh"; UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
MTX_SERVICE="mediamtx"; MTX_DIR="/opt/${MTX_SERVICE}"; MTX_BIN="${MTX_DIR}/mediamtx"; MTX_UNIT="/etc/systemd/system/${MTX_SERVICE}.service"; MTX_CFG="${MTX_DIR}/mediamtx.yml"
ACTION="install"

print_help(){ cat <<EOF
${BOLD}RTSPPI Installer${RESET}
Install:   sudo bash $0 [--width 1280] [--height 720] [--fps 25] [--bitrate 2000000] [--port 8554] [--path live]
Status:    sudo bash $0 --status
Restart:   sudo bash $0 --restart
Uninstall: sudo bash $0 --uninstall
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
    *) wrn "Unknown arg: $1"; print_help; exit 1;;
  esac
done

# ── Helpers ────────────────────────────────────────────────────
require_root(){ [[ $EUID -eq 0 ]] || { err "Run as root: sudo bash $0"; exit 1; }; }
require_apt(){ command -v apt-get >/dev/null 2>&1 || { err "Needs apt-get (Debian/Raspberry Pi OS)"; exit 1; }; }
arch_name(){
  case "$(uname -m)" in
    aarch64|arm64) echo "arm64" ;;  # Pi 64-bit
    armv7l)        echo "armv7" ;;  # Pi 32-bit
    *)             echo "arm64" ;;
  esac
}

# ── Cleanup old installs ───────────────────────────────────────
cleanup_old(){
  step "Cleaning up old installations (if any)"
  systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl disable --now "${MTX_SERVICE}" >/dev/null 2>&1 || true
  rm -f "${UNIT_FILE}" "${MTX_UNIT}" 2>/dev/null || true
  systemctl daemon-reload || true
  rm -f "${RUN_SCRIPT}" 2>/dev/null || true
  rmdir "${RUN_DIR}" 2>/dev/null || true
  # if partial mediamtx dir exists but no binary, blow it away
  [[ -d "${MTX_DIR}" && ! -x "${MTX_BIN}" ]] && rm -rf "${MTX_DIR}"
  ok "Old units removed"
}

# ── Fetch latest MediaMTX (scrape releases page) ───────────────
# Finds first matching URL for our arch, tries .tar.gz then .zip, extracts it.
install_mediamtx(){
  step "Installing MediaMTX (RTSP server)"
  install -d -m 0755 "${MTX_DIR}"
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends curl ca-certificates unzip >/dev/null

  local ARCH="$(arch_name)"                 # arm64 or armv7
  local PAGE
  PAGE="$(curl -fsSL https://github.com/bluenviron/mediamtx/releases)" || { err "Cannot reach releases page"; exit 1; }

  # Look for assets like mediamtx_vX.Y.Z_linux_arm64.tar.gz (or armv7)
  # 1) tar.gz preferred
  local URL_TGZ
  URL_TGZ="$(echo "$PAGE" | grep -Eo "https://github.com/bluenviron/mediamtx/releases/download/[^/]+/mediamtx_v[0-9\.]+_linux_${ARCH}\.tar\.gz" | head -n1 || true)"
  # 2) fallback to .zip
  local URL_ZIP
  URL_ZIP="$(echo "$PAGE" | grep -Eo "https://github.com/bluenviron/mediamtx/releases/download/[^/]+/mediamtx_v[0-9\.]+_linux_${ARCH}\.zip" | head -n1 || true)"

  if [[ -z "${URL_TGZ}" && -z "${URL_ZIP}" ]]; then
    # try legacy arm64v8 naming if arm64
    if [[ "${ARCH}" = "arm64" ]]; then
      URL_TGZ="$(echo "$PAGE" | grep -Eo "https://github.com/bluenviron/mediamtx/releases/download/[^/]+/mediamtx_v[0-9\.]+_linux_arm64v8\.tar\.gz" | head -n1 || true)"
      URL_ZIP="$(echo "$PAGE" | grep -Eo "https://github.com/bluenviron/mediamtx/releases/download/[^/]+/mediamtx_v[0-9\.]+_linux_arm64v8\.zip" | head -n1 || true)"
    fi
  fi

  if [[ -n "${URL_TGZ}" ]]; then
    echo "➜ Fetching ${URL_TGZ}"
    curl -fsSL --retry 3 -o "${MTX_DIR}/mediamtx.tar.gz" "${URL_TGZ}"
    tar -xzf "${MTX_DIR}/mediamtx.tar.gz" -C "${MTX_DIR}"
  elif [[ -n "${URL_ZIP}" ]]; then
    echo "➜ Fetching ${URL_ZIP}"
    curl -fsSL --retry 3 -o "${MTX_DIR}/mediamtx.zip" "${URL_ZIP}"
    unzip -o "${MTX_DIR}/mediamtx.zip" -d "${MTX_DIR}" >/dev/null
  else
    err "No MediaMTX asset found for ${ARCH}. Please download manually from releases."
    exit 1
  fi

  [[ -x "${MTX_BIN}" ]] || { err "mediamtx binary missing after extract"; exit 1; }
  chmod +x "${MTX_BIN}"

  # Minimal config
  cat >"${MTX_CFG}" <<EOF
rtspAddress: :${PORT}
readTimeout: 10s
writeTimeout: 10s
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
ExecStart=${MTX_BIN} -conf ${MTX_CFG}
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

# ── Main actions ───────────────────────────────────────────────
do_install(){
  banner; require_root; require_apt; cleanup_old

  step "Installing packages (ffmpeg + camera apps)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends ffmpeg rpicam-apps || apt-get install -y --no-install-recommends ffmpeg libcamera-apps
  ok "Installed ffmpeg and camera tools"

  install_mediamtx

  step "Creating runtime directory"
  install -d -m 0755 "${RUN_DIR}"

  step "Writing runner (push to MediaMTX)"
  cat >"${RUN_SCRIPT}" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

# Pick camera binary
if command -v rpicam-vid >/dev/null 2>&1; then
  CAMBIN="rpicam-vid"
elif command -v libcamera-vid >/devnull 2>&1; then
  CAMBIN="libcamera-vid"
else
  echo "ERROR: Neither rpicam-vid nor libcamera-vid found." >&2
  exit 1
fi

WIDTH="${WIDTH:-1280}"; HEIGHT="${HEIGHT:-720}"; FPS="${FPS:-25}"; BITRATE="${BITRATE:-2000000}"
PORT="${PORT:-8554}"; PATH_SEGMENT="${PATH_SEGMENT:-live}"

# Camera → ffmpeg (client) → MediaMTX (server on localhost)
"$CAMBIN" \
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

  step "Creating systemd service (camera push)"
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

  local ip; ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo
  step "All set!"
  echo -e "${INFO} Stream URL: ${BOLD}rtsp://${ip:-<pi-ip>}:${PORT}/${PATH_SEGMENT}${RESET}"
  echo -e "${INFO} Server listening: ${BOLD}ss -tlnp | grep ${PORT}${RESET}  ${DIM}(should show mediamtx)${RESET}"
  echo -e "${INFO} Logs (rtsp):   ${BOLD}journalctl -fu ${MTX_SERVICE}${RESET}"
  echo -e "${INFO} Logs (camera): ${BOLD}journalctl -fu ${SERVICE_NAME}${RESET}"
  ok "Done"
}

do_status(){ require_root; banner; systemctl --no-pager --full status "${MTX_SERVICE}" || true; echo; systemctl --no-pager --full status "${SERVICE_NAME}" || true; }
do_restart(){ require_root; banner; systemctl restart "${MTX_SERVICE}"; systemctl restart "${SERVICE_NAME}"; ok "Restarted"; }
do_uninstall(){
  require_root; banner
  systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl disable --now "${MTX_SERVICE}" >/dev/null 2>&1 || true
  rm -f "${UNIT_FILE}" "${MTX_UNIT}" "${RUN_SCRIPT}" 2>/dev/null || true
  rmdir "${RUN_DIR}" 2>/dev/null || true
  rm -rf "${MTX_DIR}"
  systemctl daemon-reload
  ok "Uninstalled cleanly"
}

trap 'echo -e "\n${CROSS} ${BOLD}Aborted${RESET}"' INT
case "${ACTION}" in
  install) do_install ;;
  status)  do_status ;;
  restart) do_restart ;;
  uninstall) do_uninstall ;;
  *) err "Unknown action: ${ACTION}"; exit 1 ;;
esac
