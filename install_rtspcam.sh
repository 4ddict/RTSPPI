#!/usr/bin/env bash
set -Eeuo pipefail

# ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
# ┃ RTSPPI — Optimized Installer                              ┃
# ┃ rpicam-vid/libcamera-vid → ffmpeg (push) → MediaMTX      ┃
# ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛

# -----------------------------
# Config (override via env vars)
# -----------------------------
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FPS="${FPS:-25}"
BITRATE="${BITRATE:-2000000}"
INTRA="${INTRA:-15}"
PORT="${PORT:-8554}"
PATH_SEGMENT="${PATH_SEGMENT:-live.sdp}"

SERVICE_NAME="rtspcam"
RUN_DIR="/opt/${SERVICE_NAME}"
RUN_SCRIPT="${RUN_DIR}/run.sh"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

MTX_SERVICE="mediamtx"
MTX_DIR="/opt/${MTX_SERVICE}"
MTX_BIN="${MTX_DIR}/mediamtx"
MTX_CFG="${MTX_DIR}/mediamtx.yml"
MTX_UNIT="/etc/systemd/system/${MTX_SERVICE}.service"
MTX_VERSION="${MTX_VERSION:-v1.16.3}"
MTX_VERSION_FILE="${MTX_DIR}/.installed-version"

HC_NAME="rtsp-healthcheck"
HC_BIN="/usr/local/bin/${HC_NAME}.sh"
HC_SERVICE="/etc/systemd/system/${HC_NAME}.service"
HC_TIMER="/etc/systemd/system/${HC_NAME}.timer"
HC_INTERVAL="${HC_INTERVAL:-1min}"
HC_BOOT_DELAY="${HC_BOOT_DELAY:-2min}"
HC_TIMEOUT_US="${HC_TIMEOUT_US:-3000000}"

ACTION="${1:-install}"

# -----------------------------
# Appearance
# -----------------------------
if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
  BOLD="$(tput bold)"
  DIM="$(tput dim)"
  RESET="$(tput sgr0)"
  GREEN="$(tput setaf 2)"
  RED="$(tput setaf 1)"
  CYAN="$(tput setaf 6)"
else
  BOLD=""
  DIM=""
  RESET=""
  GREEN=""
  RED=""
  CYAN=""
fi

CHECK="${GREEN}✔${RESET}"
CROSS="${RED}✖${RESET}"
ARROW="${CYAN}➜${RESET}"

banner() {
  cat <<'BANNER'
 _____ _______ _____ _____ _____ _____
|  __ \__   __/ ____|  __ \|  __ \_   _|
| |__) | | | | (___ | |__) | |__) || |
|  _  /  | |  \___ \|  ___/|  ___/ | |
| | \ \  | |  ____) | |    | |    _| |_
|_|  \_\ |_| |_____/|_|    |_|   |_____|
BANNER
  printf '%bRTSP camera for Raspberry Pi (optimized installer)%b\n\n' "${DIM}" "${RESET}"
}

log()  { printf '%b %s\n' "$1" "$2"; }
ok()   { log "${CHECK}" "$1"; }
step() { log "${ARROW}" "$1"; }
err()  { log "${CROSS}" "$1" >&2; }

# -----------------------------
# Helpers
# -----------------------------
require_root() {
  [[ "${EUID}" -eq 0 ]] || { err "Run as root"; exit 1; }
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; exit 1; }
}

require_apt() {
  require_cmd apt-get
  require_cmd dpkg-query
}

require_systemd() {
  require_cmd systemctl
}

detect_arch() {
  case "$(uname -m)" in
    aarch64|arm64) echo "arm64" ;;
    armv7l) echo "armv7" ;;
    *)
      err "Unsupported architecture: $(uname -m)"
      exit 1
      ;;
  esac
}

write_if_changed() {
  local target="$1"
  local mode="${2:-0644}"
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp"

  if [[ ! -f "$target" ]] || ! cmp -s "$tmp" "$target"; then
    install -D -m "$mode" "$tmp" "$target"
    rm -f "$tmp"
    return 0
  fi

  rm -f "$tmp"
  return 1
}

pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

apt_install_missing() {
  local pkgs=()
  local pkg

  for pkg in "$@"; do
    pkg_installed "$pkg" || pkgs+=("$pkg")
  done

  if ((${#pkgs[@]} > 0)); then
    step "Installing packages: ${pkgs[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    dpkg --configure -a || true
    apt-get install -y --no-install-recommends "${pkgs[@]}"
  else
    ok "Required packages already installed"
  fi
}

set_key_value_in_file() {
  local file="$1"
  local key="$2"
  local value="$3"

  if [[ ! -f "$file" ]]; then
    printf '%s=%s\n' "$key" "$value" >"$file"
    return 0
  fi

  if grep -q "^${key}=" "$file"; then
    local current
    current="$(grep "^${key}=" "$file" | tail -n1 | cut -d= -f2- || true)"
    if [[ "$current" != "$value" ]]; then
      sed -i "s/^${key}=.*/${key}=${value}/" "$file"
      return 0
    fi
    return 1
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
    return 0
  fi
}

need_restart=false
need_daemon_reload=false

mark_restart() {
  need_restart=true
}

mark_daemon_reload() {
  need_daemon_reload=true
}

reload_systemd_if_needed() {
  if [[ "$need_daemon_reload" == true ]]; then
    systemctl daemon-reload
    need_daemon_reload=false
  fi
}

restart_services_if_needed() {
  if [[ "$need_restart" == true ]]; then
    systemctl restart "${MTX_SERVICE}" "${SERVICE_NAME}"
    need_restart=false
  fi
}

print_help() {
  cat <<EOF
Usage:
  sudo bash $0 install
  sudo bash $0 status
  sudo bash $0 restart
  sudo bash $0 uninstall

Optional environment overrides:
  WIDTH HEIGHT FPS BITRATE INTRA PORT PATH_SEGMENT
  MTX_VERSION
  HC_INTERVAL HC_BOOT_DELAY HC_TIMEOUT_US

Examples:
  sudo WIDTH=1920 HEIGHT=1080 FPS=30 BITRATE=4000000 bash $0 install
  sudo PORT=8555 PATH_SEGMENT=cam.sdp bash $0 install
  sudo MTX_VERSION=v1.16.3 bash $0 install
EOF
}

# -----------------------------
# Install packages
# -----------------------------
install_packages() {
  step "Installing dependencies"

  apt_install_missing curl ca-certificates ffmpeg

  if command -v rpicam-vid >/dev/null 2>&1 || command -v libcamera-vid >/dev/null 2>&1; then
    ok "Camera app already available"
    return
  fi

  if apt-cache show rpicam-apps >/dev/null 2>&1; then
    apt_install_missing rpicam-apps || apt_install_missing libcamera-apps
  else
    apt_install_missing libcamera-apps
  fi

  if command -v rpicam-vid >/dev/null 2>&1 || command -v libcamera-vid >/dev/null 2>&1; then
    ok "Installed camera apps"
  else
    err "Camera apps were not installed correctly"
    exit 1
  fi
}

# -----------------------------
# System polish
# -----------------------------
system_polish() {
  step "Applying system tweaks"

  local cfg="/boot/firmware/config.txt"

  if [[ -f "$cfg" ]]; then
    if ! grep -q '^gpu_mem=' "$cfg"; then
      echo 'gpu_mem=128' >>"$cfg"
      ok "Set gpu_mem=128"
    else
      local cur
      cur="$(grep '^gpu_mem=' "$cfg" | tail -n1 | cut -d= -f2 || echo 0)"
      if [[ "${cur:-0}" -lt 128 ]]; then
        sed -i 's/^gpu_mem=.*/gpu_mem=128/' "$cfg"
        ok "Raised gpu_mem to 128"
      else
        ok "gpu_mem already ${cur}"
      fi
    fi
  else
    err "Could not find ${cfg}, skipping GPU memory tweak"
  fi

  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    if write_if_changed /etc/NetworkManager/conf.d/wifi-powersave.conf 0644 <<'EOF'
[connection]
wifi.powersave = 2
EOF
    then
      systemctl restart NetworkManager || true
      ok "Disabled Wi-Fi powersave via NetworkManager"
    else
      ok "Wi-Fi powersave already configured (NetworkManager)"
    fi
  else
    if write_if_changed /etc/modprobe.d/wlan-pm.conf 0644 <<'EOF'
options brcmfmac power_management=off
options 8192cu rtw_power_mgnt=0
EOF
    then
      ok "Disabled Wi-Fi powersave via modprobe config"
    else
      ok "Wi-Fi powersave already configured (modprobe)"
    fi
  fi
}

# -----------------------------
# Install MediaMTX
# -----------------------------
install_mediamtx() {
  step "Installing MediaMTX"

  install -d -m 0755 "${MTX_DIR}"

  local arch url tarball
  arch="$(detect_arch)"
  tarball="${MTX_DIR}/mediamtx.tgz"

  if [[ "$arch" == "arm64" ]]; then
    url="https://github.com/bluenviron/mediamtx/releases/download/${MTX_VERSION}/mediamtx_${MTX_VERSION}_linux_arm64.tar.gz"
  else
    url="https://github.com/bluenviron/mediamtx/releases/download/${MTX_VERSION}/mediamtx_${MTX_VERSION}_linux_armv7.tar.gz"
  fi

  if [[ ! -x "${MTX_BIN}" ]] || [[ ! -f "${MTX_VERSION_FILE}" ]] || [[ "$(cat "${MTX_VERSION_FILE}" 2>/dev/null || true)" != "${MTX_VERSION}" ]]; then
    step "Downloading MediaMTX ${MTX_VERSION}"
    curl -fL --retry 3 --connect-timeout 15 -o "${tarball}" "${url}"
    tar -xzf "${tarball}" -C "${MTX_DIR}"
    rm -f "${tarball}"
    chmod +x "${MTX_BIN}"
    printf '%s\n' "${MTX_VERSION}" > "${MTX_VERSION_FILE}"
    ok "Installed MediaMTX ${MTX_VERSION}"
  else
    ok "MediaMTX ${MTX_VERSION} already installed"
  fi

  if write_if_changed "${MTX_CFG}" 0644 <<EOF
logLevel: info

rtsp: yes
rtspAddress: :${PORT}
protocols: [tcp]

paths:
  all:
EOF
  then
    ok "Updated MediaMTX config"
    mark_restart
  else
    ok "MediaMTX config unchanged"
  fi

  if write_if_changed "${MTX_UNIT}" 0644 <<EOF
[Unit]
Description=MediaMTX RTSP server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${MTX_BIN} ${MTX_CFG}
Restart=always
RestartSec=2
WorkingDirectory=${MTX_DIR}

[Install]
WantedBy=multi-user.target
EOF
  then
    ok "Updated MediaMTX service"
    mark_daemon_reload
    mark_restart
  else
    ok "MediaMTX service unchanged"
  fi

  reload_systemd_if_needed
  systemctl enable --now "${MTX_SERVICE}"
}

# -----------------------------
# Install RTSP runner
# -----------------------------
install_rtspcam() {
  step "Installing RTSP camera runner"

  install -d -m 0755 "${RUN_DIR}"

  if write_if_changed "${RUN_SCRIPT}" 0755 <<'EOF'
#!/usr/bin/env bash
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

if command -v rpicam-vid >/dev/null 2>&1; then
  CAMBIN="rpicam-vid"
elif command -v libcamera-vid >/dev/null 2>&1; then
  CAMBIN="libcamera-vid"
else
  die "Neither rpicam-vid nor libcamera-vid found"
fi

wait_for_port() {
  local host="$1" port="$2" tries="${3:-60}"
  local i
  for ((i=1; i<=tries; i++)); do
    if (echo >/dev/tcp/"$host"/"$port") >/dev/null 2>&1; then
      return 0
    fi
    [[ "$i" -eq 1 ]] && log "Waiting for RTSP server ${host}:${port}..."
    sleep 1
  done
  return 1
}

wait_for_port 127.0.0.1 "${PORT}" 60 || die "RTSP server not reachable on 127.0.0.1:${PORT}"

trap 'pkill -P $$ >/dev/null 2>&1 || true' INT TERM EXIT

while true; do
  log "Starting push -> rtsp://127.0.0.1:${PORT}/${PATH_SEGMENT} (${WIDTH}x${HEIGHT}@${FPS}, ${BITRATE}bps, intra=${INTRA})"

  "$CAMBIN" \
    -t 0 --inline -n \
    --width "${WIDTH}" \
    --height "${HEIGHT}" \
    --framerate "${FPS}" \
    --bitrate "${BITRATE}" \
    --intra "${INTRA}" \
    --codec h264 \
    -o - \
  | ffmpeg \
      -hide_banner \
      -loglevel warning \
      -fflags nobuffer \
      -flags low_delay \
      -thread_queue_size 512 \
      -use_wallclock_as_timestamps 1 \
      -i pipe:0 \
      -c copy \
      -an \
      -muxdelay 0 \
      -muxpreload 0 \
      -f rtsp \
      -rtsp_transport tcp \
      "rtsp://127.0.0.1:${PORT}/${PATH_SEGMENT}"

  rc=$?
  log "Pipeline exited (code ${rc}). Restarting in 2s..."
  sleep 2
done
EOF
  then
    ok "Updated runner script"
    mark_restart
  else
    ok "Runner script unchanged"
  fi

  if write_if_changed "${UNIT_FILE}" 0644 <<EOF
[Unit]
Description=RTSP camera push pipeline
After=network-online.target ${MTX_SERVICE}.service
Wants=network-online.target
Requires=${MTX_SERVICE}.service

[Service]
Type=simple
Environment=WIDTH=${WIDTH}
Environment=HEIGHT=${HEIGHT}
Environment=FPS=${FPS}
Environment=BITRATE=${BITRATE}
Environment=INTRA=${INTRA}
Environment=PORT=${PORT}
Environment=PATH_SEGMENT=${PATH_SEGMENT}
ExecStart=${RUN_SCRIPT}
Restart=always
RestartSec=2
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF
  then
    ok "Updated RTSP camera service"
    mark_daemon_reload
    mark_restart
  else
    ok "RTSP camera service unchanged"
  fi

  reload_systemd_if_needed
  systemctl enable --now "${SERVICE_NAME}"
}

# -----------------------------
# Install healthcheck
# -----------------------------
install_healthcheck() {
  step "Installing healthcheck"

  if write_if_changed "${HC_BIN}" 0755 <<EOF
#!/usr/bin/env bash
set -euo pipefail

ffprobe \
  -v error \
  -rtsp_transport tcp \
  -timeout ${HC_TIMEOUT_US} \
  rtsp://127.0.0.1:${PORT}/${PATH_SEGMENT} \
  -show_streams >/dev/null \
  || systemctl restart ${SERVICE_NAME}
EOF
  then
    ok "Updated healthcheck script"
  else
    ok "Healthcheck script unchanged"
  fi

  if write_if_changed "${HC_SERVICE}" 0644 <<EOF
[Unit]
Description=RTSP healthcheck (restart ${SERVICE_NAME} on failure)

[Service]
Type=oneshot
ExecStart=${HC_BIN}
EOF
  then
    ok "Updated healthcheck service"
    mark_daemon_reload
  else
    ok "Healthcheck service unchanged"
  fi

  if write_if_changed "${HC_TIMER}" 0644 <<EOF
[Unit]
Description=Run RTSP healthcheck on interval

[Timer]
OnBootSec=${HC_BOOT_DELAY}
OnUnitActiveSec=${HC_INTERVAL}
AccuracySec=10s
Unit=${HC_NAME}.service

[Install]
WantedBy=timers.target
EOF
  then
    ok "Updated healthcheck timer"
    mark_daemon_reload
  else
    ok "Healthcheck timer unchanged"
  fi

  reload_systemd_if_needed
  systemctl enable --now "${HC_NAME}.timer"
}

# -----------------------------
# Actions
# -----------------------------
do_install() {
  banner
  require_root
  require_apt
  require_systemd

  install_packages
  system_polish
  install_mediamtx
  install_rtspcam
  install_healthcheck
  restart_services_if_needed

  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

  ok "Installation complete"
  echo
  printf '%b RTSP (live): %brtsp://%s:%s/live%b\n' "${ARROW}" "${BOLD}" "${ip:-<ip>}" "${PORT}" "${RESET}"
  printf '%b RTSP (live.sdp): %brtsp://%s:%s/live.sdp%b\n' "${ARROW}" "${BOLD}" "${ip:-<ip>}" "${PORT}" "${RESET}"
  printf '%b VLC tip: append %b?transport=tcp%b\n' "${ARROW}" "${BOLD}" "${RESET}"
  echo
  printf '%bStatus:%b systemctl status %s %s --no-pager -l\n' "${DIM}" "${RESET}" "${MTX_SERVICE}" "${SERVICE_NAME}"
  printf '%bLogs:%b journalctl -u %s -u %s -n 60 --no-pager\n' "${DIM}" "${RESET}" "${MTX_SERVICE}" "${SERVICE_NAME}"
  printf '%bReboot recommended%b if gpu_mem changed.\n' "${DIM}" "${RESET}"
}

do_status() {
  banner
  require_root
  systemctl --no-pager --full status "${MTX_SERVICE}" || true
  echo
  systemctl --no-pager --full status "${SERVICE_NAME}" || true
  echo
  systemctl --no-pager --full status "${HC_NAME}.timer" || true
}

do_restart() {
  banner
  require_root
  systemctl restart "${MTX_SERVICE}" "${SERVICE_NAME}" "${HC_NAME}.timer"
  ok "Restarted services"
}

do_uninstall() {
  banner
  require_root

  systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl disable --now "${MTX_SERVICE}" >/dev/null 2>&1 || true
  systemctl disable --now "${HC_NAME}.timer" >/dev/null 2>&1 || true

  rm -f "${UNIT_FILE}" "${MTX_UNIT}" "${HC_SERVICE}" "${HC_TIMER}" "${HC_BIN}"
  rm -rf "${RUN_DIR}" "${MTX_DIR}"

  systemctl daemon-reload
  ok "Uninstalled cleanly"
}

trap 'printf "\n%b Aborted%b\n" "${CROSS}" "${RESET}"' INT

case "${ACTION}" in
  install)   do_install ;;
  status)    do_status ;;
  restart)   do_restart ;;
  uninstall) do_uninstall ;;
  help|-h|--help) print_help ;;
  *)
    err "Unknown action: ${ACTION}"
    print_help
    exit 1
    ;;
esac
