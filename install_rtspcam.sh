#!/usr/bin/env bash
# ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
# ┃  RTSPPI — Full Installer (Zero 2 W friendly, low-latency)   ┃
# ┃  rpicam-vid/libcamera-vid → ffmpeg (push) → MediaMTX (RTSP) ┃
# ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
set -euo pipefail

# ── Appearance ─────────────────────────────────────────────────
if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
  BOLD="$(tput bold)"; DIM="$(tput dim)"; RESET="$(tput sgr0)"
  GREEN="$(tput setaf 2)"; RED="$(tput setaf 1)"; CYAN="$(tput setaf 6)"
else BOLD=""; DIM=""; RESET=""; GREEN=""; RED=""; CYAN=""; fi
CHECK="${GREEN}✔${RESET}"; CROSS="${RED}✖${RESET}"; ARROW="${CYAN}➜${RESET}"
banner(){ cat <<'BANNER'
  _____ _______ _____ _____  _____ _____ 
 |  __ \__   __/ ____|  __ \|  __ \_   _|
 | |__) | | | | (___ | |__) | |__) || |  
 |  _  /  | |  \___ \|  ___/|  ___/ | |  
 | | \ \  | |  ____) | |    | |    _| |_ 
 |_|  \_\ |_| |_____/|_|    |_|   |_____|
                                         
BANNER
echo -e "        ${DIM}RTSP camera for Raspberry Pi (Zero 2 W ready)${RESET}\n"; }
log(){ echo -e "$1 $2"; }; ok(){ log "${CHECK}" "$1"; }; step(){ log "${ARROW}" "$1"; }; err(){ log "${CROSS}" "$1"; }

# ── Defaults (no downscaling) ─────────────────────────────────
WIDTH=1280; HEIGHT=720; FPS=25; BITRATE=2000000; INTRA=15
PORT=8554; PATH_SEGMENT="live.sdp"  # default to .sdp for client compatibility
SERVICE_NAME="rtspcam"
RUN_DIR="/opt/${SERVICE_NAME}"
RUN_SCRIPT="${RUN_DIR}/run.sh"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

MTX_SERVICE="mediamtx"
MTX_DIR="/opt/${MTX_SERVICE}"
MTX_BIN="${MTX_DIR}/mediamtx"
MTX_CFG="${MTX_DIR}/mediamtx.yml"
MTX_UNIT="/etc/systemd/system/${MTX_SERVICE}.service"

# Healthcheck timer/service
HC_BIN="/usr/local/bin/rtsp-healthcheck.sh"
HC_SERVICE="/etc/systemd/system/rtsp-healthcheck.service"
HC_TIMER="/etc/systemd/system/rtsp-healthcheck.timer"

ACTION="install"

print_help(){ cat <<EOF
${BOLD}RTSPPI Installer${RESET}

Install (default):
  sudo bash $0 [--width 1280] [--height 720] [--fps 25] [--bitrate 2000000] [--intra 15] [--port 8554] [--path live.sdp]

Maintenance:
  sudo bash $0 --status | --restart | --uninstall

Flags:
  --width N      default ${WIDTH}
  --height N     default ${HEIGHT}
  --fps N        default ${FPS}
  --bitrate N    bits/sec, default ${BITRATE}
  --intra N      keyframe interval (frames), default ${INTRA}
  --port N       RTSP port, default ${PORT}
  --path NAME    RTSP path, default ${PATH_SEGMENT}
  -h, --help     Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --width) WIDTH="${2:-}"; shift 2;;
    --height) HEIGHT="${2:-}"; shift 2;;
    --fps) FPS="${2:-}"; shift 2;;
    --bitrate) BITRATE="${2:-}"; shift 2;;
    --intra) INTRA="${2:-}"; shift 2;;
    --port) PORT="${2:-}"; shift 2;;
    --path) PATH_SEGMENT="${2:-}"; shift 2;;
    --status) ACTION="status"; shift;;
    --restart) ACTION="restart"; shift;;
    --uninstall) ACTION="uninstall"; shift;;
    -h|--help) print_help; exit 0;;
    *) err "Unknown arg: $1"; print_help; exit 1;;
  esac
done

# ── Helpers ────────────────────────────────────────────────────
require_root(){ [[ $EUID -eq 0 ]] || { err "Run as root: sudo bash $0"; exit 1; }; }
require_apt(){ command -v apt-get >/dev/null 2>&1 || { err "Needs apt-get (Debian/Raspberry Pi OS)"; exit 1; }; }
arch(){ case "$(uname -m)" in aarch64|arm64) echo "arm64";; armv7l) echo "armv7";; *) echo "arm64";; esac; }

# ── Cleanup old installs ───────────────────────────────────────
cleanup_old(){
  step "Cleaning up old installations (if any)"
  systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl disable --now "${MTX_SERVICE}" >/dev/null 2>&1 || true
  systemctl disable --now rtsp-healthcheck.timer >/dev/null 2>&1 || true
  rm -f "${UNIT_FILE}" "${MTX_UNIT}" "${HC_SERVICE}" "${HC_TIMER}" 2>/dev/null || true
  systemctl daemon-reload || true
  rm -rf "${RUN_DIR}" 2>/dev/null || true
  [[ -d "${MTX_DIR}" && ! -x "${MTX_BIN}" ]] && rm -rf "${MTX_DIR}" || true
  ok "Old installations cleaned"
}

# ── Install packages ───────────────────────────────────────────
install_packages(){
  step "Installing packages (ffmpeg + camera apps)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  dpkg --configure -a || true
  apt-get install -y --no-install-recommends curl ca-certificates ffmpeg rpicam-apps || \
  apt-get install -y --no-install-recommends curl ca-certificates ffmpeg libcamera-apps
  ok "Installed ffmpeg and camera tools"
}

# ── System polish (GPU mem, Wi-Fi powersave off) ───────────────
system_polish(){
  step "Applying system tweaks (GPU mem ≥128MB, Wi-Fi powersave off)"
  local cfg="/boot/firmware/config.txt"
  if [[ -f "$cfg" ]]; then
    if ! grep -q '^gpu_mem=' "$cfg"; then
      echo 'gpu_mem=128' >>"$cfg"
      ok "Set gpu_mem=128"
    else
      local cur; cur="$(grep '^gpu_mem=' "$cfg" | tail -n1 | cut -d= -f2 || echo 0)"
      if [[ "${cur:-0}" -lt 128 ]]; then
        sed -i 's/^gpu_mem=.*/gpu_mem=128/' "$cfg"
        ok "Raised gpu_mem to 128"
      else
        ok "gpu_mem already ${cur}"
      fi
    fi
  else
    err "Could not find ${cfg} (skipping GPU mem tweak)"
  fi

  # Disable Wi-Fi powersave (NetworkManager if present; else kernel modules)
  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    install -d /etc/NetworkManager/conf.d
    tee /etc/NetworkManager/conf.d/wifi-powersave.conf >/dev/null <<'EOF'
[connection]
wifi.powersave = 2
EOF
    systemctl restart NetworkManager || true
    ok "Wi-Fi powersave disabled via NetworkManager"
  else
    tee /etc/modprobe.d/wlan-pm.conf >/dev/null <<'EOF'
options brcmfmac power_management=off
options 8192cu rtw_power_mgnt=0
EOF
    ok "Wi-Fi powersave disabled via modprobe config"
  fi
}

# ── Install MediaMTX v1.14.0 (ARM64/ARMv7) ─────────────────────
install_mediamtx(){
  step "Installing MediaMTX (RTSP server)"
  install -d -m 0755 "${MTX_DIR}"
  local A; A="$(arch)"
  local URL
  if [[ "${A}" = "arm64" ]]; then
    URL="https://github.com/bluenviron/mediamtx/releases/download/v1.14.0/mediamtx_v1.14.0_linux_arm64.tar.gz"
  else
    URL="https://github.com/bluenviron/mediamtx/releases/download/v1.14.0/mediamtx_v1.14.0_linux_armv7.tar.gz"
  fi
  echo "Downloading: ${URL}"
  curl -fL --retry 3 -o "${MTX_DIR}/mediamtx.tgz" "${URL}"
  tar -xzf "${MTX_DIR}/mediamtx.tgz" -C "${MTX_DIR}"
  rm -f "${MTX_DIR}/mediamtx.tgz"
  [[ -x "${MTX_BIN}" ]] || { err "mediamtx binary missing after extract"; exit 1; }
  chmod +x "${MTX_BIN}"

  # TCP-only + timeouts + wildcard paths (accepts /live and /live.sdp)
  cat >"${MTX_CFG}" <<EOF
rtspAddress: :${PORT}
protocols: [tcp]
readTimeout: 10s
writeTimeout: 10s
paths:
  "~^.*$": {}
EOF

  # systemd unit (positional config arg; no -c / -conf) + hardening
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
LimitNOFILE=65535
MemoryMax=160M

# Hardening
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
ProtectKernelModules=yes
LockPersonality=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
RestrictNamespaces=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${MTX_SERVICE}"
  ok "MediaMTX installed and started"
}

# ── Install camera push (low-latency) ──────────────────────────
install_rtspcam(){
  step "Installing camera push service (low-latency)"
  install -d -m 0755 "${RUN_DIR}"

  cat >"${RUN_SCRIPT}" <<'EOS'
#!/usr/bin/env bash
# RTSP push runner — low-latency tuned
set -Eeuo pipefail

WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FPS="${FPS:-25}"
BITRATE="${BITRATE:-2000000}"
INTRA="${INTRA:-15}"
PORT="${PORT:-8554}"
PATH_SEGMENT="${PATH_SEGMENT:-live.sdp}"

log() { printf '[rtspcam] %s\n' "$*"; }
die() { printf '[rtspcam] ERROR: %s\n' "$*" >&2; exit 1; }

CAMBIN=""
if command -v rpicam-vid >/dev/null 2>&1; then CAMBIN="rpicam-vid";
elif command -v libcamera-vid >/dev/null 2>&1; then CAMBIN="libcamera-vid";
else die "Neither rpicam-vid nor libcamera-vid found."; fi
log "Using camera binary: $CAMBIN"

wait_for_port() {
  local host="$1" port="$2" tries="${3:-60}"
  for ((i=1;i<=tries;i++)); do
    if (echo >/dev/tcp/"$host"/"$port") >/dev/null 2>&1; then return 0; fi
    [[ $i -eq 1 ]] && log "Waiting for RTSP server ${host}:${port}..."
    sleep 1
  done
  return 1
}
wait_for_port 127.0.0.1 "${PORT}" 60 || die "RTSP server not reachable on 127.0.0.1:${PORT}"

trap 'pkill -P $$ || true' INT TERM

while true; do
  log "Starting push -> rtsp://127.0.0.1:${PORT}/${PATH_SEGMENT}  (${WIDTH}x${HEIGHT}@${FPS}, ${BITRATE}bps, intra=${INTRA})"

  "$CAMBIN" \
    -t 0 --inline -n \
    --width "${WIDTH}" --height "${HEIGHT}" \
    --framerate "${FPS}" --bitrate "${BITRATE}" \
    --intra "${INTRA}" \
    --codec h264 -o - \
  | ffmpeg -hide_banner -loglevel warning \
      -fflags nobuffer -flags low_delay -strict experimental \
      -thread_queue_size 512 \
      -use_wallclock_as_timestamps 1 \
      -i pipe:0 \
      -c copy -an \
      -muxdelay 0 -muxpreload 0 \
      -f rtsp -rtsp_transport tcp \
      "rtsp://127.0.0.1:${PORT}/${PATH_SEGMENT}"

  rc=$?
  log "Pipeline exited (code ${rc}). Restarting in 2s..."
  sleep 2
done
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
Environment=INTRA=${INTRA}
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

# Hardening
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
RestrictNamespaces=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}"
  ok "Camera service installed and started"
}

# ── Health watchdog ────────────────────────────────────────────
install_healthcheck(){
  step "Installing health watchdog (restart rtspcam if stream stalls)"
  tee "${HC_BIN}" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -e
# timeout in microseconds (3s)
ffprobe -v error -rtsp_transport tcp -timeout 3000000 \
  rtsp://127.0.0.1:8554/live.sdp -show_streams >/dev/null \
  || systemctl restart rtspcam
EOF
  chmod +x "${HC_BIN}"

  tee "${HC_SERVICE}" >/dev/null <<'EOF'
[Unit]
Description=RTSP healthcheck (restart rtspcam on failure)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/rtsp-healthcheck.sh
EOF

  tee "${HC_TIMER}" >/dev/null <<'EOF'
[Unit]
Description=Run RTSP healthcheck every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s
Unit=rtsp-healthcheck.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now rtsp-healthcheck.timer
  ok "Health watchdog enabled"
}

# ── Actions ────────────────────────────────────────────────────
do_install(){
  banner; require_root; require_apt; cleanup_old
  install_packages
  system_polish
  install_mediamtx
  install_rtspcam
  install_healthcheck

  local ip; ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo
  ok "Installation complete"
  echo -e "${ARROW} RTSP (live):      ${BOLD}rtsp://${ip:-<pi-ip>}:${PORT}/live${RESET}"
  echo -e "${ARROW} RTSP (live.sdp):  ${BOLD}rtsp://${ip:-<pi-ip>}:${PORT}/live.sdp${RESET}"
  echo -e "${ARROW} VLC tip: append ${BOLD}?transport=tcp${RESET}"
  echo
  echo -e "${DIM}Status:${RESET}  systemctl status ${MTX_SERVICE} ${SERVICE_NAME} --no-pager -l"
  echo -e "${DIM}Logs:${RESET}    journalctl -u ${MTX_SERVICE} -u ${SERVICE_NAME} -n 60 --no-pager"
  echo -e "${DIM}Tune:${RESET}    edit /etc/systemd/system/${SERVICE_NAME}.service (WIDTH/HEIGHT/FPS/BITRATE/INTRA) → daemon-reload → restart"
  echo -e "${DIM}Reboot recommended to apply GPU mem change if modified.${RESET}"
}

do_status(){ require_root; banner; systemctl --no-pager --full status "${MTX_SERVICE}" || true; echo; systemctl --no-pager --full status "${SERVICE_NAME}" || true; }
do_restart(){ require_root; banner; systemctl restart "${MTX_SERVICE}"; systemctl restart "${SERVICE_NAME}"; ok "Restarted"; }
do_uninstall(){
  require_root; banner
  systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl disable --now "${MTX_SERVICE}" >/dev/null 2>&1 || true
  systemctl disable --now rtsp-healthcheck.timer >/dev/null 2>&1 || true
  rm -f "${UNIT_FILE}" "${MTX_UNIT}" "${HC_SERVICE}" "${HC_TIMER}" 2>/dev/null || true
  systemctl daemon-reload
  rm -rf "${RUN_DIR}" "${MTX_DIR}"
  ok "Uninstalled cleanly"
}

trap 'echo -e "\n${CROSS} Aborted${RESET}"' INT
case "${ACTION}" in
  install) do_install ;;
  status)  do_status ;;
  restart) do_restart ;;
  uninstall) do_uninstall ;;
  *) err "Unknown action: ${ACTION}"; exit 1 ;;
esac
