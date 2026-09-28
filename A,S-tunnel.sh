#!/usr/bin/env bash
set -euo pipefail

APP_NAME="A,S"
TG_ID="@Asnejad"
VERSION="3.0.0"

GITHUB_REPO="github.com/ariansaeedi56-prog/A,S-tunnel"

# MUST match GitHub file name exactly:
SCRIPT_FILENAME="A,S-tunnel.sh"
SELF_URL="https://raw.githubusercontent.com/ariansaeedi56-prog/A-S-tunnel/main/${SCRIPT_FILENAME}"

PY="/opt/A,S/A,S.py"
PY_URL="https://raw.githubusercontent.com/ariansaeedi56-prog/A-S-tunnel/main/A,S.py"

INSTALL_PATH="/usr/local/bin/A,S-tunnel"

BASE="/etc/A,S_manager"
CONF="$BASE/profiles"
BIN_DIR="/opt/A,S/bin"
# Prepended to every screen session so all protocols (not just A,S native) get
# the same higher file-descriptor ceiling for handling many connections.
ULIMIT_PREFIX='ulimit -Hn 1048576 >/dev/null 2>&1 || true; ulimit -Sn 1048576 >/dev/null 2>&1 || true; '

# Where human-readable progress messages go. Interactive runs write to the
# terminal; --api / --healthcheck run without a controlling terminal (systemd,
# cron), where writing to /dev/tty fails and — under `set -e` — used to abort
# the function right after the tunnel had already started, which the web panel
# then reported as "save failed".
TTY_OUT="/dev/tty"
case "${1:-}" in --api|--healthcheck) TTY_OUT="/dev/stderr" ;; esac

LOG_DIR="/var/log/A,S"

# Every key a profile may contain (reset before each load so one profile's
# values can never leak into the next one).
PROFILE_KEYS="METHOD ROLE IRAN_IP BRIDGE SYNC AUTO_SYNC PORTS BH_ROLE TOKEN TRANSPORT BIND_PORT FORWARD_PORTS SERVER_IP RT_ROLE LOCAL_IP PEER_IP SELF_TUN_IP PEER_TUN_IP FRP_ROLE DEST_IP PORT_MODE RANGE_START RANGE_END PROTO PQ_ROLE SECRET_KEY SERVER_PORT KCP_MODE CONN MTU BLOCK FORWARD_UDP_PORTS SOCKS5_PORT SOCKS5_USER SOCKS5_PASS ROUTER_MAC"
MAX=10

HC_SCRIPT="/usr/local/bin/A,S-health-check"
HC_CRON_TAG="# A,STunnelHealthCheck"

WEBPANEL_DIR="/opt/A,S/webpanel"
WEBPANEL_ENV="$BASE/webpanel.env"
WEBPANEL_UNIT="AS-webpanel"
WEBPANEL_SERVICE="/etc/systemd/system/${WEBPANEL_UNIT}.service"

# Colors
if [[ -t 1 ]]; then
  CLR_RESET="\033[0m"; CLR_DIM="\033[2m"; CLR_BOLD="\033[1m"
  CLR_RED="\033[31m"; CLR_GREEN="\033[32m"; CLR_YELLOW="\033[33m"
  CLR_CYAN="\033[36m"; CLR_WHITE="\033[97m"
else
  CLR_RESET=""; CLR_DIM=""; CLR_BOLD=""
  CLR_RED=""; CLR_GREEN=""; CLR_YELLOW=""
  CLR_CYAN=""; CLR_WHITE=""
fi

need_root(){ [[ "$(id -u)" == "0" ]] || { echo "Run as root (sudo -i)"; exit 1; }; }
pause(){ read -r -p "Press Enter to continue..." _ < /dev/tty || true; }
have(){ command -v "$1" >/dev/null 2>&1; }

apt_try_install(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y "$@" >/dev/null 2>&1 || true
}

fetch_url_to(){
  local url out
  url="$1"
  out="$2"
  if have curl; then
    curl -fsSL "$url" -o "$out"
  else
    have wget || apt_try_install wget
    wget -qO "$out" "$url"
  fi
}

detect_arch(){
  local m; m="$(uname -m)"
  case "$m" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "amd64" ;;
  esac
}

# $1 = owner/repo   $2 = regex (POSIX ERE) to match against asset filename
gh_latest_asset_url(){
  local repo pattern
  repo="$1"
  pattern="$2"
  have jq || apt_try_install jq
  curl -fsSL -H "Accept: application/vnd.github+json" -H "User-Agent: A,S-tunnel" \
    "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
    | jq -r --arg p "$pattern" '.assets[]? | select(.name|test($p)) | .browser_download_url' \
    | head -n1
}

install_backhaul(){
  [[ -x "$BIN_DIR/backhaul" ]] && return 0
  echo "[*] Installing Backhaul..." > "$TTY_OUT"
  local arch; arch="$(detect_arch)"
  local url; url="$(gh_latest_asset_url "Musixal/Backhaul" "linux_${arch}\\.tar\\.gz$")"
  [[ -n "$url" ]] || { echo "[-] Could not find a Backhaul release asset for linux_${arch}." > "$TTY_OUT"; return 1; }
  local tmp; tmp="$(mktemp -d)"
  fetch_url_to "$url" "$tmp/bh.tar.gz" || { rm -rf "$tmp"; return 1; }
  tar -xzf "$tmp/bh.tar.gz" -C "$tmp" 2>/dev/null || true
  find "$tmp" -maxdepth 2 -type f -iname "backhaul*" ! -name "*.toml" ! -name "*.md" -exec cp {} "$BIN_DIR/backhaul" \; 2>/dev/null || true
  chmod +x "$BIN_DIR/backhaul" 2>/dev/null || true
  rm -rf "$tmp"
  [[ -x "$BIN_DIR/backhaul" ]] || { echo "[-] Backhaul install failed." > "$TTY_OUT"; return 1; }
  echo "[+] Backhaul installed at $BIN_DIR/backhaul" > "$TTY_OUT"
}

install_rathole(){
  [[ -x "$BIN_DIR/rathole" ]] && return 0
  echo "[*] Installing Rathole..." > "$TTY_OUT"
  local arch; arch="$(detect_arch)"
  local archname="x86_64"; [[ "$arch" == "arm64" ]] && archname="aarch64"
  local url="" suf ext
  for suf in "unknown-linux-musl" "unknown-linux-gnu"; do
    for ext in "zip" "tar\\.gz"; do
      url="$(gh_latest_asset_url "rapiz1/rathole" "${archname}-${suf}\\.${ext}$")"
      [[ -n "$url" ]] && break 2
    done
  done
  [[ -n "$url" ]] || { echo "[-] Could not find a rathole release asset for ${archname}." > "$TTY_OUT"; return 1; }
  local tmp; tmp="$(mktemp -d)"
  fetch_url_to "$url" "$tmp/rt.pkg" || { rm -rf "$tmp"; return 1; }
  if [[ "$url" == *.zip ]]; then
    have unzip || apt_try_install unzip
    unzip -o "$tmp/rt.pkg" -d "$tmp" >/dev/null 2>&1 || true
  else
    tar -xzf "$tmp/rt.pkg" -C "$tmp" 2>/dev/null || true
  fi
  find "$tmp" -maxdepth 2 -type f -iname "rathole" -exec cp {} "$BIN_DIR/rathole" \; 2>/dev/null || true
  chmod +x "$BIN_DIR/rathole" 2>/dev/null || true
  rm -rf "$tmp"
  [[ -x "$BIN_DIR/rathole" ]] || { echo "[-] Rathole install failed." > "$TTY_OUT"; return 1; }
  echo "[+] Rathole installed at $BIN_DIR/rathole" > "$TTY_OUT"
}

install_frp(){
  [[ -x "$BIN_DIR/frps" && -x "$BIN_DIR/frpc" ]] && return 0
  echo "[*] Installing FRP..." > "$TTY_OUT"
  local arch; arch="$(detect_arch)"
  local url; url="$(gh_latest_asset_url "fatedier/frp" "linux_${arch}\\.tar\\.gz$")"
  [[ -n "$url" ]] || { echo "[-] Could not find an FRP release asset for linux_${arch}." > "$TTY_OUT"; return 1; }
  local tmp; tmp="$(mktemp -d)"
  fetch_url_to "$url" "$tmp/frp.tar.gz" || { rm -rf "$tmp"; return 1; }
  tar -xzf "$tmp/frp.tar.gz" -C "$tmp" --strip-components=1 2>/dev/null || true
  [[ -f "$tmp/frps" && -f "$tmp/frpc" ]] || { echo "[-] FRP archive layout unexpected." > "$TTY_OUT"; rm -rf "$tmp"; return 1; }
  cp "$tmp/frps" "$BIN_DIR/frps"; cp "$tmp/frpc" "$BIN_DIR/frpc"
  chmod +x "$BIN_DIR/frps" "$BIN_DIR/frpc"
  rm -rf "$tmp"
  [[ -x "$BIN_DIR/frps" && -x "$BIN_DIR/frpc" ]] || { echo "[-] FRP install failed." > "$TTY_OUT"; return 1; }
  echo "[+] FRP installed at $BIN_DIR/frps, $BIN_DIR/frpc" > "$TTY_OUT"
}

install_gost(){
  [[ -x "$BIN_DIR/gost" ]] && return 0
  echo "[*] Installing Gost..." > "$TTY_OUT"
  local arch; arch="$(detect_arch)"
  local url; url="$(gh_latest_asset_url "go-gost/gost" "linux_${arch}\\.tar\\.gz$")"
  [[ -n "$url" ]] || { echo "[-] Could not find a Gost release asset for linux_${arch}." > "$TTY_OUT"; return 1; }
  local tmp; tmp="$(mktemp -d)"
  fetch_url_to "$url" "$tmp/gost.tar.gz" || { rm -rf "$tmp"; return 1; }
  tar -xzf "$tmp/gost.tar.gz" -C "$tmp" 2>/dev/null || true
  find "$tmp" -maxdepth 2 -type f -iname "gost" -exec cp {} "$BIN_DIR/gost" \; 2>/dev/null || true
  chmod +x "$BIN_DIR/gost" 2>/dev/null || true
  rm -rf "$tmp"
  [[ -x "$BIN_DIR/gost" ]] || { echo "[-] Gost install failed." > "$TTY_OUT"; return 1; }
  echo "[+] Gost installed at $BIN_DIR/gost" > "$TTY_OUT"
}

is_installed(){ [[ -x "$INSTALL_PATH" ]]; }

ensure(){
  mkdir -p "$CONF"
  mkdir -p "$BIN_DIR"
  mkdir -p "$LOG_DIR"
  mkdir -p "$(dirname "$PY")"
  have screen  || apt_try_install screen
  have python3 || apt_try_install python3
  have curl    || apt_try_install curl
  have figlet  || apt_try_install figlet
  have ss      || apt_try_install iproute2
  have ip      || apt_try_install iproute2
  have crontab || apt_try_install cron
  have jq      || apt_try_install jq
  have tar     || apt_try_install tar
  have unzip   || apt_try_install unzip

  if [[ ! -f "$PY" ]]; then
    echo "[*] Python core not found. Downloading: $PY_URL" > "$TTY_OUT"
    fetch_url_to "$PY_URL" "$PY"
    chmod +x "$PY" || true
  fi
  [[ -f "$PY" ]] || { echo "Missing python file: $PY"; exit 1; }
}

install_script(){
  echo "[*] Installing to: $INSTALL_PATH" > "$TTY_OUT"
  mkdir -p "$(dirname "$INSTALL_PATH")"

  # If executed from a file path, copy it. Otherwise download from SELF_URL.
  if [[ -f "$0" ]] && [[ "$0" != "bash" ]] && [[ "$0" != "/dev/fd/"* ]]; then
    cp -f "$0" "$INSTALL_PATH"
  else
    fetch_url_to "$SELF_URL" "$INSTALL_PATH"
  fi
  chmod +x "$INSTALL_PATH"
  echo "[+] Installed. Run: sudo A,S-tunnel" > "$TTY_OUT"
}

update_script(){
  echo "[*] Updating from: $SELF_URL" > "$TTY_OUT"
  local tmp; tmp="$(mktemp)"
  fetch_url_to "$SELF_URL" "$tmp"

  if ! head -n 1 "$tmp" | grep -q "bash"; then
    echo "[-] Update failed: invalid file downloaded." > "$TTY_OUT"
    rm -f "$tmp"
    return 1
  fi
  chmod +x "$tmp"

  if is_installed; then
    mv -f "$tmp" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    echo "[+] Updated. Run again: sudo A,S-tunnel" > "$TTY_OUT"
  else
    mv -f "$tmp" "./${SCRIPT_FILENAME}"
    chmod +x "./${SCRIPT_FILENAME}"
    echo "[+] Updated file saved locally: ./${SCRIPT_FILENAME}" > "$TTY_OUT"
  fi
}

disable_cron_healthcheck(){
  local tmp; tmp="$(mktemp)"
  (crontab -l 2>/dev/null || true) | grep -vF "${HC_CRON_TAG}" >"$tmp" || true
  crontab "$tmp" || true
  rm -f "$tmp"
  echo "[+] Cron disabled." > "$TTY_OUT"
}

# ---- Per-slot scheduled restart (independent of the health-check cron) ----
# Health-check only restarts a slot if it's found stopped; this restarts a
# slot on a fixed schedule regardless of state — useful for flushing stale
# connections/memory on long-running tunnels.
slot_restart_tag(){ echo "# A,SSlotRestart:$1"; }

set_slot_restart_cron(){
  local prof="$1" hours="$2" tag; tag="$(slot_restart_tag "$prof")"
  [[ "$hours" =~ ^[0-9]+$ ]] || hours=6
  [[ "$hours" -lt 1 ]] && hours=1
  local line="0 */$hours * * * ${INSTALL_PATH} --api restart ${prof} >/dev/null 2>&1 ${tag}"
  local tmp; tmp="$(mktemp)"
  (crontab -l 2>/dev/null || true) | grep -vF "$tag" >"$tmp" || true
  echo "$line" >>"$tmp"
  crontab "$tmp"
  rm -f "$tmp"
}

clear_slot_restart_cron(){
  local prof="$1" tag; tag="$(slot_restart_tag "$prof")"
  local tmp; tmp="$(mktemp)"
  (crontab -l 2>/dev/null || true) | grep -vF "$tag" >"$tmp" || true
  crontab "$tmp"
  rm -f "$tmp"
}

get_slot_restart_hours(){
  local prof="$1" tag; tag="$(slot_restart_tag "$prof")"
  local line; line="$(crontab -l 2>/dev/null | grep -F "$tag" || true)"
  [[ -n "$line" ]] || { echo ""; return; }
  echo "$line" | sed -n 's#^0 \*/\([0-9]\+\) .*#\1#p'
}

optimize_server(){
  echo "" > "$TTY_OUT"
  echo "[*] Optimizing network settings and hardening the kernel (applies to every tunnel protocol)..." > "$TTY_OUT"

  # Ensure tools that are commonly missing on minimal images
  have sysctl  || apt_try_install procps
  have modprobe || apt_try_install kmod
  have ss || apt_try_install iproute2

  # Cron is optional but health-check uses crontab
  have crontab || apt_try_install cron

  # Try loading BBR module (no hard fail)
  modprobe tcp_bbr >/dev/null 2>&1 || true

  local cc qdisc
  cc="cubic"
  qdisc="pfifo_fast"
  if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
    cc="bbr"; qdisc="fq"
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
    echo "[+] BBR is available and enabled." > "$TTY_OUT"
  else
    echo "[!] BBR is NOT available on this kernel — keeping the default congestion control." > "$TTY_OUT"
  fi

  # Persist settings (idempotent, separate file). This always applies — not just
  # when BBR is available — since every protocol (Backhaul/Rathole/FRP/Gost/GRE/
  # A,S native) benefits from the same backlog, keepalive and anti-spoofing tuning.
  local conf="/etc/sysctl.d/99-A,S-tunnel.conf"
  cat > "$conf" <<EOF
# A,S Tunnel — network performance + security tuning (shared by every protocol)
net.core.default_qdisc=$qdisc
net.ipv4.tcp_congestion_control=$cc

# Socket buffer ceilings
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216

# Connection handling under load: bigger backlog, faster stale-connection reuse
net.core.somaxconn=65535
net.core.netdev_max_backlog=65535
net.ipv4.tcp_max_syn_backlog=65535
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
net.ipv4.ip_local_port_range=1024 65535
fs.file-max=1000000

# Security hardening: SYN-flood protection, anti-spoofing, no source routing/redirects.
# rp_filter uses loose mode (2), not strict (1) — reverse tunnels legitimately see
# asymmetric routing, and strict mode can silently drop their own traffic.
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.icmp_echo_ignore_broadcasts=1
EOF

  sysctl --system >/dev/null 2>&1 || sysctl -p "$conf" >/dev/null 2>&1 || true

  # Raise the system-wide open-file ceiling too, backing up the per-session
  # ulimit bump every protocol's screen session already applies at start.
  local limits_conf="/etc/security/limits.d/99-A,S-tunnel.conf"
  cat > "$limits_conf" <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

  echo "[+] Applied sysctl + file-descriptor hardening (performance and security)." > "$TTY_OUT"
  echo "[i] tcp_congestion_control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" > "$TTY_OUT"
  echo "[i] default_qdisc:         $(sysctl -n net.core.default_qdisc 2>/dev/null)" > "$TTY_OUT"
  echo "[i] tcp_syncookies:        $(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null)" > "$TTY_OUT"
  if [[ "$cc" != "bbr" ]]; then
    echo "[i] Hint: upgrade the kernel to also get BBR congestion control." > "$TTY_OUT"
  fi
}

uninstall_script(){
  disable_cron_healthcheck >/dev/null 2>&1 || true
  rm -f "$HC_SCRIPT" >/dev/null 2>&1 || true
  rm -f "$INSTALL_PATH" >/dev/null 2>&1 || true
  echo "[+] Uninstalled: $INSTALL_PATH" > "$TTY_OUT"
}

# Info (best-effort)
get_public_ip(){ curl -fsSL --max-time 3 https://api.ipify.org 2>/dev/null || true; }
get_ipinfo_field(){
  local field ip
  field="$1"
  ip="$2"
  [[ -n "$ip" ]] || { echo ""; return 0; }
  local json
  json="$(curl -fsSL --max-time 4 "https://ipinfo.io/${ip}/json" 2>/dev/null || true)"
  [[ -n "$json" ]] || { echo ""; return 0; }
  echo "$json" | tr -d '\n' | sed -n "s/.*\"${field}\":[ ]*\"\\([^\"]*\\)\".*/\\1/p" | head -n1
}
get_location_string(){
  local ip city region country
  ip="$(get_public_ip)"
  city="$(get_ipinfo_field city "$ip")"
  region="$(get_ipinfo_field region "$ip")"
  country="$(get_ipinfo_field country "$ip")"
  if [[ -n "$city" || -n "$region" || -n "$country" ]]; then
    echo "${city}${city:+, }${region}${region:+, }${country}"
  else
    echo "Unknown"
  fi
}
get_datacenter_string(){
  local ip org
  ip="$(get_public_ip)"
  org="$(get_ipinfo_field org "$ip")"
  [[ -n "$org" ]] && echo "$org" || echo "Unknown"
}

# Profiles
pick_role(){
  while true; do
    echo "" > "$TTY_OUT"
    echo -e "${CLR_DIM}┌───────────────────────────┐${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_BOLD}Which side is this?${CLR_RESET}     ${CLR_DIM}│${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}├───────────────────────────┤${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}1${CLR_RESET}) 🌍  EU (foreign)         ${CLR_DIM}│${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}2${CLR_RESET}) 🇮🇷  IRAN                ${CLR_DIM}│${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}└───────────────────────────┘${CLR_RESET}" > "$TTY_OUT"
    read -r -p "Select: " x < /dev/tty
    if [[ "$x" == "1" ]]; then echo "eu"; return 0; fi
    if [[ "$x" == "2" ]]; then echo "iran"; return 0; fi
    echo -e "${CLR_RED}Invalid.${CLR_RESET}" > "$TTY_OUT"
  done
}
slot_status(){
  local role i prof
  role="$1"
  i="$2"
  prof="${role}${i}"
  if [[ -f "$CONF/${prof}.env" ]]; then
    local m; m="$(get_method "$prof")"
    if is_running "$prof" 2>/dev/null; then
      echo -e "${CLR_GREEN}●${CLR_RESET} ${CLR_DIM}[$m]${CLR_RESET}"
    else
      echo -e "${CLR_RED}●${CLR_RESET} ${CLR_DIM}[$m]${CLR_RESET}"
    fi
  else
    echo -e "${CLR_DIM}○ empty${CLR_RESET}"
  fi
}
pick_slot(){
  local role title
  role="$1"
  title="EU"; [[ "$role" == "iran" ]] && title="IRAN"
  echo "" > "$TTY_OUT"
  echo -e "${CLR_DIM}┌───────────────────────────────────────┐${CLR_RESET}" > "$TTY_OUT"
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_BOLD}${title} slots${CLR_RESET}  ${CLR_DIM}(● on  ● off  ○ empty)${CLR_RESET}   ${CLR_DIM}│${CLR_RESET}" > "$TTY_OUT"
  echo -e "${CLR_DIM}├───────────────────────────────────────┤${CLR_RESET}" > "$TTY_OUT"
  for i in $(seq 1 "$MAX"); do
    printf "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}%2s${CLR_RESET}) %-6s  %b\n" "$i" "${role}${i}" "$(slot_status "$role" "$i")" > "$TTY_OUT"
  done
  echo -e "${CLR_DIM}└───────────────────────────────────────┘${CLR_RESET}" > "$TTY_OUT"
  read -r -p "Slot number: " slot < /dev/tty
  [[ "$slot" =~ ^[0-9]+$ ]] && [[ "$slot" -ge 1 ]] && [[ "$slot" -le "$MAX" ]] || { echo "Invalid"; exit 1; }
  echo "${role}${slot}"
}

# ===================== Tunnel method selection =====================

edit_profile(){
  local prof f role
  prof="$1"
  f="$CONF/${prof}.env"
  role="${prof%%[0-9]*}"
  echo "" > "$TTY_OUT"
  echo -e "${CLR_DIM}┌───────────────────────────────────────────────────┐${CLR_RESET}" > "$TTY_OUT"
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_YELLOW}${CLR_BOLD}⚙  Configuring: ${prof}${CLR_RESET}" > "$TTY_OUT"
  echo -e "${CLR_DIM}├───────────────────────────────────────────────────┤${CLR_RESET}" > "$TTY_OUT"
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}1${CLR_RESET}) A,S native   ${CLR_DIM}packet reverse tunnel (built-in)${CLR_RESET}" > "$TTY_OUT"
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}2${CLR_RESET}) Backhaul     ${CLR_DIM}TCP/WS/WSS multiplexed tunnel${CLR_RESET}" > "$TTY_OUT"
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}3${CLR_RESET}) Rathole      ${CLR_DIM}lightweight NAT-traversal tunnel${CLR_RESET}" > "$TTY_OUT"
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}4${CLR_RESET}) GRE          ${CLR_DIM}kernel-level IP tunnel${CLR_RESET}" > "$TTY_OUT"
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}5${CLR_RESET}) FRP          ${CLR_DIM}fast reverse proxy${CLR_RESET}" > "$TTY_OUT"
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}6${CLR_RESET}) Gost         ${CLR_DIM}per-port IPv4/IPv6 forwarder${CLR_RESET}" > "$TTY_OUT"
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}7${CLR_RESET}) Paqet        ${CLR_DIM}raw packet tunnel (KCP over pcap)${CLR_RESET}" > "$TTY_OUT"
  echo -e "${CLR_DIM}└───────────────────────────────────────────────────┘${CLR_RESET}" > "$TTY_OUT"
  read -r -p "Select [1-7]: " m < /dev/tty
  case "$m" in
    1) edit_profile_asnative "$prof" "$f" "$role" || true ;;
    2) edit_profile_backhaul "$prof" "$f" "$role" || true ;;
    3) edit_profile_rathole  "$prof" "$f" "$role" || true ;;
    4) edit_profile_gre      "$prof" "$f" "$role" || true ;;
    5) edit_profile_frp      "$prof" "$f" "$role" || true ;;
    6) edit_profile_gost     "$prof" "$f" "$role" || true ;;
    7) edit_profile_paqet    "$prof" "$f" "$role" || true ;;
    *) echo "Invalid." > "$TTY_OUT"; return 1 ;;
  esac

  if [[ -f "$f" ]]; then
    echo "" > "$TTY_OUT"
    echo -e "${CLR_CYAN}▶ Starting tunnel...${CLR_RESET}" > "$TTY_OUT"
    run_slot "$prof" || true
    echo "" > "$TTY_OUT"
    status_slot "$prof" || true
  fi
}

edit_profile_asnative(){
  local prof f role
  prof="$1"
  f="$2"
  role="$3"
  if [[ "$role" == "eu" ]]; then
    read -r -p "Iran IP: " IRAN_IP < /dev/tty
    read -r -p "Bridge port (e.g. 7000): " BRIDGE < /dev/tty
    read -r -p "Sync port   (e.g. 7001): " SYNC < /dev/tty
    cat >"$f" <<EOF
METHOD=asnative
ROLE=eu
IRAN_IP=$IRAN_IP
BRIDGE=$BRIDGE
SYNC=$SYNC
EOF
  else
    read -r -p "Bridge port (e.g. 7000): " BRIDGE < /dev/tty
    read -r -p "Sync port   (e.g. 7001): " SYNC < /dev/tty
    read -r -p "Auto-Sync ports from EU? (y/n): " AS < /dev/tty
    if [[ "${AS,,}" == "y" ]]; then
      cat >"$f" <<EOF
METHOD=asnative
ROLE=iran
BRIDGE=$BRIDGE
SYNC=$SYNC
AUTO_SYNC=true
PORTS=
EOF
    else
      read -r -p "Manual ports CSV (e.g. 80,443,2083): " PORTS < /dev/tty
      cat >"$f" <<EOF
METHOD=asnative
ROLE=iran
BRIDGE=$BRIDGE
SYNC=$SYNC
AUTO_SYNC=false
PORTS=$PORTS
EOF
    fi
  fi
  echo "[+] Saved $f" > "$TTY_OUT"
}

# Backhaul docs: the box you want to run in listening ("server") mode opens
# the control port + forwarded ports; the other box ("client") dials out to
# it. Ask explicitly rather than guessing from eu/iran, since either box can
# play either role depending on your firewall situation.
edit_profile_backhaul(){
  local prof f role
  prof="$1"
  f="$2"
  role="$3"
  echo "1) Server (listens; opens the control port + forwarded ports)" > "$TTY_OUT"
  echo "2) Client (dials out to the Server)" > "$TTY_OUT"
  read -r -p "This profile is: " bhr < /dev/tty
  TOKEN="$(prompt_token "$bhr")"
  read -r -p "Transport [tcp/ws/wss] (default tcp): " TRANSPORT < /dev/tty
  TRANSPORT="${TRANSPORT:-tcp}"
  if [[ "$bhr" == "1" ]]; then
    read -r -p "Control bind port (e.g. 3080): " BIND_PORT < /dev/tty
    read -r -p "Ports to forward, CSV (e.g. 443,8080,2083): " FORWARD_PORTS < /dev/tty
    cat >"$f" <<EOF
METHOD=backhaul
ROLE=$role
BH_ROLE=server
TOKEN=$TOKEN
TRANSPORT=$TRANSPORT
BIND_PORT=$BIND_PORT
FORWARD_PORTS=$FORWARD_PORTS
EOF
  else
    read -r -p "Server IP: " SERVER_IP < /dev/tty
    read -r -p "Server control port (e.g. 3080): " BIND_PORT < /dev/tty
    cat >"$f" <<EOF
METHOD=backhaul
ROLE=$role
BH_ROLE=client
TOKEN=$TOKEN
TRANSPORT=$TRANSPORT
SERVER_IP=$SERVER_IP
BIND_PORT=$BIND_PORT
EOF
  fi
  echo "[+] Saved $f" > "$TTY_OUT"
}

edit_profile_rathole(){
  local prof f role
  prof="$1"
  f="$2"
  role="$3"
  echo "1) Server (public side, exposes the ports)" > "$TTY_OUT"
  echo "2) Client (behind NAT/filtering, forwards local services out)" > "$TTY_OUT"
  read -r -p "This profile is: " rtr < /dev/tty
  TOKEN="$(prompt_token "$rtr")"
  read -r -p "Ports to forward, CSV (e.g. 443,8080,2083): " FORWARD_PORTS < /dev/tty
  if [[ "$rtr" == "1" ]]; then
    read -r -p "Control bind port (e.g. 2333): " BIND_PORT < /dev/tty
    cat >"$f" <<EOF
METHOD=rathole
ROLE=$role
RT_ROLE=server
TOKEN=$TOKEN
BIND_PORT=$BIND_PORT
FORWARD_PORTS=$FORWARD_PORTS
EOF
  else
    read -r -p "Server IP: " SERVER_IP < /dev/tty
    read -r -p "Server control port (e.g. 2333): " BIND_PORT < /dev/tty
    cat >"$f" <<EOF
METHOD=rathole
ROLE=$role
RT_ROLE=client
TOKEN=$TOKEN
SERVER_IP=$SERVER_IP
BIND_PORT=$BIND_PORT
FORWARD_PORTS=$FORWARD_PORTS
EOF
  fi
  echo "[+] Saved $f" > "$TTY_OUT"
}

edit_profile_frp(){
  local prof f role
  prof="$1"
  f="$2"
  role="$3"
  echo "1) Server (frps, public side)" > "$TTY_OUT"
  echo "2) Client (frpc, dials out to the Server)" > "$TTY_OUT"
  read -r -p "This profile is: " fr < /dev/tty
  TOKEN="$(prompt_token "$fr")"
  if [[ "$fr" == "1" ]]; then
    read -r -p "Control bind port (e.g. 7000): " BIND_PORT < /dev/tty
    cat >"$f" <<EOF
METHOD=frp
ROLE=$role
FRP_ROLE=server
TOKEN=$TOKEN
BIND_PORT=$BIND_PORT
EOF
  else
    read -r -p "Server IP: " SERVER_IP < /dev/tty
    read -r -p "Server control port (e.g. 7000): " BIND_PORT < /dev/tty
    read -r -p "Ports to forward, CSV (e.g. 443,8080,2083): " FORWARD_PORTS < /dev/tty
    cat >"$f" <<EOF
METHOD=frp
ROLE=$role
FRP_ROLE=client
TOKEN=$TOKEN
SERVER_IP=$SERVER_IP
BIND_PORT=$BIND_PORT
FORWARD_PORTS=$FORWARD_PORTS
EOF
  fi
  echo "[+] Saved $f" > "$TTY_OUT"
}

# Writes KEY=VALUE lines with shell-safe quoting (empty values are skipped).
write_env_file(){
  local f kv k v
  f="$1"; shift
  : > "$f"
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    [[ -n "$v" ]] || continue
    printf '%s=%q\n' "$k" "$v" >> "$f"
  done
}

edit_profile_paqet(){
  local prof f role pqr port key custom mode conn mtu block mac
  local traffic fports uports sport suser spass sip
  prof="$1"; f="$2"; role="$3"
  echo "1) Server  (abroad / EU — waits for the client)" > "$TTY_OUT"
  echo "2) Client  (Iran — dials the server and exposes forwarded ports or SOCKS5)" > "$TTY_OUT"
  read -r -p "This profile is: " pqr < /dev/tty
  read -r -p "Tunnel port (default 8888): " port < /dev/tty
  port="${port:-8888}"
  key="$(prompt_token "$pqr")"
  mode="fast"; conn="4"; mtu="1150"; block="aes-128-gcm"
  read -r -p "Customize KCP mode / connections / MTU / encryption? (y/N): " custom < /dev/tty
  if [[ "${custom,,}" == "y" ]]; then
    read -r -p "KCP mode [normal/fast/fast2/fast3] (default fast): " mode < /dev/tty
    read -r -p "Connections 1-32 (default 4): " conn < /dev/tty
    read -r -p "MTU 100-9000 (default 1150): " mtu < /dev/tty
    read -r -p "Encryption [aes-128-gcm/aes/aes-128/aes-192/aes-256/none] (default aes-128-gcm): " block < /dev/tty
    mode="${mode:-fast}"; conn="${conn:-4}"; mtu="${mtu:-1150}"; block="${block:-aes-128-gcm}"
  fi
  read -r -p "Router MAC (Enter = auto-detect): " mac < /dev/tty
  if [[ "$pqr" == "1" ]]; then
    write_env_file "$f" "METHOD=paqet" "ROLE=$role" "PQ_ROLE=server" "SERVER_PORT=$port" "SECRET_KEY=$key" \
      "KCP_MODE=$mode" "CONN=$conn" "MTU=$mtu" "BLOCK=$block" "ROUTER_MAC=$mac"
  else
    read -r -p "Server IP (the abroad server): " sip < /dev/tty
    echo "1) Port forwarding   2) SOCKS5 proxy" > "$TTY_OUT"
    read -r -p "Traffic type (default 1): " traffic < /dev/tty
    fports=""; uports=""; sport=""; suser=""; spass=""
    if [[ "${traffic:-1}" == "2" ]]; then
      read -r -p "SOCKS5 port (default 1080): " sport < /dev/tty
      sport="${sport:-1080}"
      read -r -p "SOCKS5 username (Enter = no auth): " suser < /dev/tty
      if [[ -n "$suser" ]]; then read -r -p "SOCKS5 password: " spass < /dev/tty; fi
    else
      read -r -p "TCP ports to forward, CSV (default 9090): " fports < /dev/tty
      fports="${fports:-9090}"
      read -r -p "UDP ports to forward, CSV (Enter = none): " uports < /dev/tty
    fi
    write_env_file "$f" "METHOD=paqet" "ROLE=$role" "PQ_ROLE=client" "SERVER_IP=$sip" "SERVER_PORT=$port" "SECRET_KEY=$key" \
      "KCP_MODE=$mode" "CONN=$conn" "MTU=$mtu" "BLOCK=$block" "ROUTER_MAC=$mac" \
      "FORWARD_PORTS=$fports" "FORWARD_UDP_PORTS=$uports" "SOCKS5_PORT=$sport" "SOCKS5_USER=$suser" "SOCKS5_PASS=$spass"
  fi
  echo "[+] Saved $f" > "$TTY_OUT"
  if [[ "$block" == "none" || "$block" == "null" ]]; then
    echo -e "${CLR_YELLOW}[!] Encryption is off — traffic between the two servers is readable by anyone on the path.${CLR_RESET}" > "$TTY_OUT"
  fi
  echo -e "${CLR_DIM}    Paqet needs the same tunnel port and secret key on both servers (server = abroad, client = Iran).${CLR_RESET}" > "$TTY_OUT"
}

edit_profile_gost(){
  local prof f role
  prof="$1"
  f="$2"
  role="$3"
  read -r -p "Destination (Kharej) IP — where traffic gets forwarded to: " DEST_IP < /dev/tty
  echo "1) Manual ports (comma separated)" > "$TTY_OUT"
  echo "2) Port range" > "$TTY_OUT"
  read -r -p "Select: " pm < /dev/tty
  local PORT_MODE PORTS RANGE_START RANGE_END
  if [[ "$pm" == "2" ]]; then
    read -r -p "Range start,end (e.g. 54,65000): " rng < /dev/tty
    RANGE_START="${rng%%,*}"; RANGE_END="${rng##*,}"
    PORT_MODE="range"; PORTS=""
  else
    read -r -p "Ports CSV (e.g. 443,8080,2083): " PORTS < /dev/tty
    PORT_MODE="manual"; RANGE_START=""; RANGE_END=""
  fi
  echo "1) tcp   2) udp   3) grpc" > "$TTY_OUT"
  read -r -p "Protocol: " po < /dev/tty
  local PROTO="tcp"
  [[ "$po" == "2" ]] && PROTO="udp"
  [[ "$po" == "3" ]] && PROTO="grpc"
  cat >"$f" <<EOF
METHOD=gost
ROLE=$role
DEST_IP=$DEST_IP
PORT_MODE=$PORT_MODE
PORTS=$PORTS
RANGE_START=$RANGE_START
RANGE_END=$RANGE_END
PROTO=$PROTO
EOF
  echo "[+] Saved $f" > "$TTY_OUT"
  if [[ "$PROTO" == "tcp" || "$PROTO" == "udp" ]]; then
    echo -e "${CLR_DIM}[i] Plain ${PROTO} forwarding isn't encrypted between the two ends.${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}    Use protocol 3 (grpc) instead if the traffic itself needs TLS, or make sure${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}    whatever you're forwarding (HTTPS, SSH, etc.) is already encrypted end-to-end.${CLR_RESET}" > "$TTY_OUT"
  fi
}
edit_profile_gre(){
  local prof f role
  prof="$1"
  f="$2"
  role="$3"
  read -r -p "This host's public IP (local): " LOCAL_IP < /dev/tty
  read -r -p "Peer public IP (remote): " PEER_IP < /dev/tty
  local SELF_TUN_IP PEER_TUN_IP
  if [[ "$role" == "eu" ]]; then
    SELF_TUN_IP="10.10.10.1"; PEER_TUN_IP="10.10.10.2"
  else
    SELF_TUN_IP="10.10.10.2"; PEER_TUN_IP="10.10.10.1"
  fi
  cat >"$f" <<EOF
METHOD=gre
ROLE=$role
LOCAL_IP=$LOCAL_IP
PEER_IP=$PEER_IP
SELF_TUN_IP=$SELF_TUN_IP
PEER_TUN_IP=$PEER_TUN_IP
EOF
  echo "[+] Saved $f (GRE tunnel IP: $SELF_TUN_IP <-> $PEER_TUN_IP)" > "$TTY_OUT"
  echo -e "${CLR_YELLOW}[!] GRE carries traffic in plaintext — anyone on the path can read it.${CLR_RESET}" > "$TTY_OUT"
  echo -e "${CLR_DIM}    Restrict the interface to this one peer with iptables, e.g.:${CLR_RESET}" > "$TTY_OUT"
  echo -e "${CLR_DIM}    iptables -A INPUT -p gre ! -s ${PEER_IP} -j DROP${CLR_RESET}" > "$TTY_OUT"
  echo -e "${CLR_DIM}    Add IPsec on top if the traffic itself needs confidentiality.${CLR_RESET}" > "$TTY_OUT"
}

# ---- Config file generators (called right before starting each backend) ----

csv_ports_to_array(){
  local csv="$1"; IFS=',' read -ra _P <<< "$csv"
  local p
  for p in "${_P[@]}"; do
    p="$(echo "$p" | xargs)"
    [[ -n "$p" ]] && echo "$p"
  done
}

write_backhaul_config(){
  local prof f cfg
  prof="$1"
  f="$CONF/${prof}.env"
  cfg="$CONF/${prof}.toml"
  # shellcheck disable=SC1090
  load_profile "$prof"
  if [[ "$BH_ROLE" == "server" ]]; then
    local lines="" p
    while IFS= read -r p; do
      [[ -n "$p" ]] && lines+="  \"${p}=${p}\",\n"
    done < <(csv_ports_to_array "$FORWARD_PORTS")
    cat > "$cfg" <<EOF
[server]
bind_addr = "0.0.0.0:${BIND_PORT}"
transport = "${TRANSPORT:-tcp}"
token = "${TOKEN}"
ports = [
$(printf "%b" "$lines")
]
EOF
  else
    cat > "$cfg" <<EOF
[client]
remote_addr = "${SERVER_IP}:${BIND_PORT}"
transport = "${TRANSPORT:-tcp}"
token = "${TOKEN}"
EOF
  fi
}

write_rathole_config(){
  local prof f cfg
  prof="$1"
  f="$CONF/${prof}.env"
  cfg="$CONF/${prof}.toml"
  # shellcheck disable=SC1090
  load_profile "$prof"
  if [[ "$RT_ROLE" == "server" ]]; then
    { echo "[server]"; echo "bind_addr = \"0.0.0.0:${BIND_PORT}\""; echo "default_token = \"${TOKEN}\""; } > "$cfg"
    local p
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      { echo ""; echo "[server.services.svc${p}]"; echo "bind_addr = \"0.0.0.0:${p}\""; } >> "$cfg"
    done < <(csv_ports_to_array "$FORWARD_PORTS")
  else
    { echo "[client]"; echo "remote_addr = \"${SERVER_IP}:${BIND_PORT}\""; echo "default_token = \"${TOKEN}\""; } > "$cfg"
    local p
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      { echo ""; echo "[client.services.svc${p}]"; echo "local_addr = \"127.0.0.1:${p}\""; } >> "$cfg"
    done < <(csv_ports_to_array "$FORWARD_PORTS")
  fi
}

write_frp_config(){
  local prof f cfg
  prof="$1"
  f="$CONF/${prof}.env"
  cfg="$CONF/${prof}.toml"
  # shellcheck disable=SC1090
  load_profile "$prof"
  if [[ "$FRP_ROLE" == "server" ]]; then
    cat > "$cfg" <<EOF
bindPort = ${BIND_PORT}
auth.method = "token"
auth.token = "${TOKEN}"
EOF
  else
    cat > "$cfg" <<EOF
serverAddr = "${SERVER_IP}"
serverPort = ${BIND_PORT}
auth.method = "token"
auth.token = "${TOKEN}"
EOF
    local p
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      cat >> "$cfg" <<EOF

[[proxies]]
name = "p${p}"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${p}
remotePort = ${p}
EOF
    done < <(csv_ports_to_array "$FORWARD_PORTS")
  fi
}

# ===================== Paqet (raw packet tunnel) helpers =====================

paqet_valid_ip(){
  local ip a b c d
  ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"; c="${BASH_REMATCH[3]}"; d="${BASH_REMATCH[4]}"
  (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 ))
}
paqet_valid_port(){ [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
paqet_safe_text(){ [[ "$1" =~ ^[A-Za-z0-9._@:+=-]+$ ]]; }

# Validates the currently loaded profile (call load_profile first).
paqet_validate(){
  local p mode conn mtu
  if [[ "$PQ_ROLE" != "server" && "$PQ_ROLE" != "client" ]]; then
    echo "[-] Paqet: role must be server or client." > "$TTY_OUT"; return 1
  fi
  if ! paqet_valid_port "$SERVER_PORT"; then
    echo "[-] Paqet: invalid tunnel port '${SERVER_PORT}'." > "$TTY_OUT"; return 1
  fi
  if [[ ${#SECRET_KEY} -lt 8 ]] || ! paqet_safe_text "$SECRET_KEY"; then
    echo "[-] Paqet: secret key needs 8+ characters (letters, digits and . _ @ : + = - only)." > "$TTY_OUT"; return 1
  fi
  mode="${KCP_MODE:-fast}"
  case "$mode" in normal|fast|fast2|fast3) ;; *) echo "[-] Paqet: KCP mode must be normal, fast, fast2 or fast3." > "$TTY_OUT"; return 1 ;; esac
  case "${BLOCK:-aes-128-gcm}" in aes-128-gcm|aes|aes-128|aes-192|aes-256|none|null) ;; *) echo "[-] Paqet: unknown encryption '${BLOCK}'." > "$TTY_OUT"; return 1 ;; esac
  conn="${CONN:-4}"; mtu="${MTU:-1150}"
  if ! [[ "$conn" =~ ^[0-9]+$ ]] || (( 10#$conn < 1 || 10#$conn > 32 )); then
    echo "[-] Paqet: connections must be 1-32." > "$TTY_OUT"; return 1
  fi
  if ! [[ "$mtu" =~ ^[0-9]+$ ]] || (( 10#$mtu < 100 || 10#$mtu > 9000 )); then
    echo "[-] Paqet: MTU must be 100-9000." > "$TTY_OUT"; return 1
  fi
  if [[ -n "$ROUTER_MAC" ]] && ! [[ "$ROUTER_MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
    echo "[-] Paqet: router MAC must look like aa:bb:cc:dd:ee:ff." > "$TTY_OUT"; return 1
  fi
  [[ "$PQ_ROLE" == "server" ]] && return 0

  if ! paqet_valid_ip "$SERVER_IP"; then
    echo "[-] Paqet: server IP '${SERVER_IP}' is not a valid IPv4 address." > "$TTY_OUT"; return 1
  fi
  if [[ -z "$FORWARD_PORTS" && -z "$FORWARD_UDP_PORTS" && -z "$SOCKS5_PORT" ]]; then
    echo "[-] Paqet client: give forward ports or a SOCKS5 port." > "$TTY_OUT"; return 1
  fi
  for p in $(csv_ports_to_array "$FORWARD_PORTS") $(csv_ports_to_array "$FORWARD_UDP_PORTS"); do
    if ! paqet_valid_port "$p"; then echo "[-] Paqet: invalid forward port '$p'." > "$TTY_OUT"; return 1; fi
    if [[ "$p" == "$SERVER_PORT" ]]; then
      echo "[-] Paqet: forward port $p equals the tunnel port — that would create an endless traffic loop." > "$TTY_OUT"; return 1
    fi
  done
  if [[ -n "$SOCKS5_PORT" ]] && ! paqet_valid_port "$SOCKS5_PORT"; then
    echo "[-] Paqet: invalid SOCKS5 port." > "$TTY_OUT"; return 1
  fi
  if [[ -n "$SOCKS5_USER$SOCKS5_PASS" ]]; then
    if [[ -z "$SOCKS5_USER" || -z "$SOCKS5_PASS" ]] || ! paqet_safe_text "$SOCKS5_USER" || ! paqet_safe_text "$SOCKS5_PASS"; then
      echo "[-] Paqet: SOCKS5 needs both a user and a password (letters, digits and . _ @ : + = - only)." > "$TTY_OUT"; return 1
    fi
  fi
  return 0
}

# Sets NET_IFACE / NET_LOCAL_IP / NET_GW_IP / NET_GW_MAC (globals) from the default route.
paqet_net_info(){
  NET_IFACE=""; NET_LOCAL_IP=""; NET_GW_IP=""; NET_GW_MAC=""
  NET_IFACE="$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}' || true)"
  NET_GW_IP="$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}' || true)"
  if [[ -n "$NET_IFACE" ]]; then
    NET_LOCAL_IP="$(ip -4 -o addr show dev "$NET_IFACE" 2>/dev/null | awk '{print $4; exit}' | cut -d/ -f1 || true)"
  fi
  if [[ -n "$NET_GW_IP" ]]; then
    ping -c 1 -W 1 "$NET_GW_IP" >/dev/null 2>&1 || true
    NET_GW_MAC="$(ip neigh show "$NET_GW_IP" 2>/dev/null | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -n1 || true)"
  fi
  NET_IFACE="${NET_IFACE:-eth0}"
}

install_paqet(){
  [[ -x "$BIN_DIR/paqet" ]] && return 0
  echo "[*] Installing Paqet..." > "$TTY_OUT"
  local arch archname url tmp bin
  arch="$(detect_arch)"
  archname="amd64"; [[ "$arch" == "arm64" ]] && archname="arm64"
  # raw-packet transport needs libpcap + iptables (and persistence for the rules)
  have iptables || apt_try_install iptables
  if ! ldconfig -p 2>/dev/null | grep -q 'libpcap'; then apt_try_install libpcap-dev; fi
  have netfilter-persistent || apt_try_install iptables-persistent
  url="$(gh_latest_asset_url "hanselime/paqet" "paqet-linux-${archname}-.*\\.tar\\.gz$")"
  [[ -n "$url" ]] || { echo "[-] Could not find a Paqet release asset for linux-${archname}." > "$TTY_OUT"; return 1; }
  tmp="$(mktemp -d)"
  fetch_url_to "$url" "$tmp/paqet.tar.gz" || { rm -rf "$tmp"; return 1; }
  tar -xzf "$tmp/paqet.tar.gz" -C "$tmp" 2>/dev/null || true
  bin="$(find "$tmp" -type f -name 'paqet*' ! -name '*.tar.gz' ! -name '*.yaml' ! -name '*.yml' ! -name '*.md' 2>/dev/null | head -n1 || true)"
  if [[ -z "$bin" ]]; then
    echo "[-] Paqet binary not found inside the archive." > "$TTY_OUT"; rm -rf "$tmp"; return 1
  fi
  cp "$bin" "$BIN_DIR/paqet"
  chmod +x "$BIN_DIR/paqet"
  rm -rf "$tmp"
  [[ -x "$BIN_DIR/paqet" ]] || { echo "[-] Paqet install failed." > "$TTY_OUT"; return 1; }
  echo "[+] Paqet installed at $BIN_DIR/paqet" > "$TTY_OUT"
}

write_paqet_config(){
  local prof cfg mode conn mtu block mac p
  prof="$1"
  cfg="$CONF/${prof}.yaml"
  load_profile "$prof"
  paqet_validate || return 1
  paqet_net_info
  mode="${KCP_MODE:-fast}"; conn="${CONN:-4}"; mtu="${MTU:-1150}"; block="${BLOCK:-aes-128-gcm}"
  mac="${ROUTER_MAC:-$NET_GW_MAC}"
  if [[ -z "$mac" || -z "$NET_LOCAL_IP" ]]; then
    echo "[-] Paqet: could not detect the local IP / router MAC (interface ${NET_IFACE}). Set the router MAC in the profile." > "$TTY_OUT"
    return 1
  fi
  {
    if [[ "$PQ_ROLE" == "server" ]]; then
      echo "# Paqet server — generated by A,S Tunnel"
      echo "role: \"server\""
      echo "log:"
      echo "  level: \"info\""
      echo "listen:"
      echo "  addr: \":${SERVER_PORT}\""
      echo "network:"
      echo "  interface: \"${NET_IFACE}\""
      echo "  ipv4:"
      echo "    addr: \"${NET_LOCAL_IP}:${SERVER_PORT}\""
      echo "    router_mac: \"${mac}\""
      echo "  tcp:"
      echo "    local_flag: [\"PA\"]"
    else
      echo "# Paqet client — generated by A,S Tunnel"
      echo "role: \"client\""
      echo "log:"
      echo "  level: \"info\""
      if [[ -n "$FORWARD_PORTS$FORWARD_UDP_PORTS" ]]; then
        echo "forward:"
        for p in $(csv_ports_to_array "$FORWARD_PORTS"); do
          echo "  - listen: \"0.0.0.0:${p}\""
          echo "    target: \"127.0.0.1:${p}\""
          echo "    protocol: \"tcp\""
        done
        for p in $(csv_ports_to_array "$FORWARD_UDP_PORTS"); do
          echo "  - listen: \"0.0.0.0:${p}\""
          echo "    target: \"127.0.0.1:${p}\""
          echo "    protocol: \"udp\""
        done
      fi
      if [[ -n "$SOCKS5_PORT" ]]; then
        echo "socks5:"
        echo "  - listen: \"127.0.0.1:${SOCKS5_PORT}\""
        if [[ -n "$SOCKS5_USER" ]]; then
          echo "    username: \"${SOCKS5_USER}\""
          echo "    password: \"${SOCKS5_PASS}\""
        fi
      fi
      echo "network:"
      echo "  interface: \"${NET_IFACE}\""
      echo "  ipv4:"
      echo "    addr: \"${NET_LOCAL_IP}:0\""
      echo "    router_mac: \"${mac}\""
      echo "  tcp:"
      echo "    local_flag: [\"PA\"]"
      echo "    remote_flag: [\"PA\"]"
      echo "server:"
      echo "  addr: \"${SERVER_IP}:${SERVER_PORT}\""
    fi
    echo "transport:"
    echo "  protocol: \"kcp\""
    echo "  conn: ${conn}"
    echo "  kcp:"
    echo "    key: \"${SECRET_KEY}\""
    echo "    mode: \"${mode}\""
    echo "    block: \"${block}\""
    echo "    mtu: ${mtu}"
  } > "$cfg"
  chmod 600 "$cfg" 2>/dev/null || true
}

# Prints "port proto" for every port this Paqet profile needs raw-socket iptables rules for.
paqet_rule_ports(){
  local p
  load_profile "$1"
  if [[ "$PQ_ROLE" == "server" ]]; then
    echo "${SERVER_PORT} tcp"
  else
    for p in $(csv_ports_to_array "$FORWARD_PORTS"); do echo "$p tcp"; done
    for p in $(csv_ports_to_array "$FORWARD_UDP_PORTS"); do echo "$p udp"; done
    if [[ -n "$SOCKS5_PORT" ]]; then echo "${SOCKS5_PORT} tcp"; fi
  fi
}

paqet_iptables_rule(){
  local action port proto
  action="$1"; port="$2"; proto="$3"
  have iptables || return 0
  # always delete first so "add" stays idempotent across restarts
  iptables -t raw -D PREROUTING -p "$proto" --dport "$port" -j NOTRACK 2>/dev/null || true
  iptables -t raw -D OUTPUT -p "$proto" --sport "$port" -j NOTRACK 2>/dev/null || true
  if [[ "$proto" == "tcp" ]]; then
    iptables -t mangle -D OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -j DROP 2>/dev/null || true
  fi
  [[ "$action" == "add" ]] || return 0
  iptables -t raw -A PREROUTING -p "$proto" --dport "$port" -j NOTRACK
  iptables -t raw -A OUTPUT -p "$proto" --sport "$port" -j NOTRACK
  if [[ "$proto" == "tcp" ]]; then
    iptables -t mangle -A OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -j DROP
  fi
}

save_iptables(){
  if have netfilter-persistent; then
    netfilter-persistent save >/dev/null 2>&1 || true
  elif [[ -f /etc/init.d/iptables || -f /usr/lib/systemd/system/iptables.service ]]; then
    service iptables save >/dev/null 2>&1 || true
  elif have iptables-save && [[ -d /etc/iptables ]]; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  fi
}

paqet_iptables_apply(){
  local port proto
  while read -r port proto; do
    [[ -n "$port" ]] || continue
    paqet_iptables_rule add "$port" "$proto" || echo "[!] iptables rule for ${port}/${proto} failed." > "$TTY_OUT"
  done < <(paqet_rule_ports "$1")
  save_iptables
}

paqet_iptables_remove(){
  local port proto
  while read -r port proto; do
    [[ -n "$port" ]] || continue
    paqet_iptables_rule del "$port" "$proto" || true
  done < <(paqet_rule_ports "$1")
  save_iptables
}

# ===================== Runtime control (per method) =====================

session_name(){ echo "A,S_$1"; }
log_file(){ echo "$LOG_DIR/$1.log"; }

# Resets every known key, then sources the profile (see PROFILE_KEYS).
load_profile(){
  local prof f k
  prof="$1"
  f="$CONF/${prof}.env"
  for k in $PROFILE_KEYS; do printf -v "$k" '%s' ""; done
  # shellcheck disable=SC1090
  source "$f"
}

log_event(){
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  printf '%s %s\n' "$(date '+%F %T')" "$2" >> "$(log_file "$1")" 2>/dev/null || true
}

get_method(){
  local prof f m
  prof="$1"
  f="$CONF/${prof}.env"
  [[ -f "$f" ]] || { echo "asnative"; return; }
  m="$(grep -m1 '^METHOD=' "$f" | cut -d= -f2- || true)"
  echo "${m:-asnative}"
}

is_running(){
  local prof m s out
  prof="$1"
  m="$(get_method "$prof")"
  if [[ "$m" == "gre" ]]; then
    ip link show "gre${prof}" >/dev/null 2>&1
  else
    s="$(session_name "$prof")"
    out="$(screen -ls 2>/dev/null || true)"
    grep -q "\.${s}[[:space:]]" <<<"$out"
  fi
}

# Runs <cmd> in a detached screen session and tees everything it prints to the
# slot's log file (that file feeds the live-log views of both CLI and web panel).
# Returns 1 (and shows the last log lines) if the process dies right away.
launch_in_screen(){
  local prof cmd s lf sz
  prof="$1"; cmd="$2"
  s="$(session_name "$prof")"
  lf="$(log_file "$prof")"
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  if [[ -f "$lf" ]]; then
    sz="$(stat -c %s "$lf" 2>/dev/null || echo 0)"
    if [[ "$sz" -gt 5242880 ]]; then
      tail -c 1048576 "$lf" > "$lf.tmp" 2>/dev/null && mv -f "$lf.tmp" "$lf" || true
    fi
  fi
  screen -S "$s" -X quit >/dev/null 2>&1 || true
  screen -dmS "$s" bash -lc "${ULIMIT_PREFIX}export PYTHONUNBUFFERED=1; { echo \"=== \$(date '+%F %T') starting ${prof} ===\"; ${cmd}; echo \"=== \$(date '+%F %T') process exited (code \$?) ===\"; } 2>&1 | tee -a '${lf}'"
  sleep 1.5
  if ! is_running "$prof"; then
    echo "[-] ${prof} exited right after starting. Last log lines:" > "$TTY_OUT"
    tail -n 15 "$lf" 2>/dev/null > "$TTY_OUT" || true
    return 1
  fi
  return 0
}

run_slot_asnative(){
  local prof cmd
  prof="$1"
  load_profile "$prof"
  if [[ "$ROLE" == "eu" ]]; then
    cmd="printf '1\n%s\n%s\n%s\n' '$IRAN_IP' '$BRIDGE' '$SYNC' | PAHLAVI_POOL=\"${PAHLAVI_POOL:-0}\" python3 '$PY'"
  elif [[ "${AUTO_SYNC:-true}" == "true" || -z "$AUTO_SYNC" ]]; then
    cmd="printf '2\n%s\n%s\ny\n' '$BRIDGE' '$SYNC' | PAHLAVI_POOL=\"${PAHLAVI_POOL:-0}\" python3 '$PY'"
  else
    cmd="printf '2\n%s\n%s\nn\n%s\n' '$BRIDGE' '$SYNC' '$PORTS' | PAHLAVI_POOL=\"${PAHLAVI_POOL:-0}\" python3 '$PY'"
  fi
  launch_in_screen "$prof" "$cmd" || return 1
  echo "[+] Started: $(session_name "$prof") (A,S native)" > "$TTY_OUT"
}

run_backhaul_slot(){
  local prof
  prof="$1"
  install_backhaul || return 1
  write_backhaul_config "$prof"
  launch_in_screen "$prof" "'$BIN_DIR/backhaul' -c '$CONF/${prof}.toml'" || return 1
  echo "[+] Started: $(session_name "$prof") (backhaul)" > "$TTY_OUT"
}

run_rathole_slot(){
  local prof flag
  prof="$1"
  load_profile "$prof"
  install_rathole || return 1
  write_rathole_config "$prof"
  [[ "$RT_ROLE" == "server" ]] && flag="--server" || flag="--client"
  launch_in_screen "$prof" "'$BIN_DIR/rathole' $flag '$CONF/${prof}.toml'" || return 1
  echo "[+] Started: $(session_name "$prof") (rathole)" > "$TTY_OUT"
}

run_frp_slot(){
  local prof bin
  prof="$1"
  load_profile "$prof"
  install_frp || return 1
  write_frp_config "$prof"
  [[ "$FRP_ROLE" == "server" ]] && bin="frps" || bin="frpc"
  launch_in_screen "$prof" "'$BIN_DIR/$bin' -c '$CONF/${prof}.toml'" || return 1
  echo "[+] Started: $(session_name "$prof") (frp $FRP_ROLE)" > "$TTY_OUT"
}

gost_port_list(){
  local prof
  prof="$1"
  load_profile "$prof"
  if [[ "${PORT_MODE:-manual}" == "range" ]]; then
    seq "$RANGE_START" "$RANGE_END"
  else
    csv_ports_to_array "$PORTS"
  fi
}

run_gost_slot(){
  local prof args n p
  prof="$1"
  load_profile "$prof"
  install_gost || return 1
  args=""; n=0
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    args+=" -L=${PROTO}://:${p}/[${DEST_IP}]:${p}"
    n=$((n+1))
  done < <(gost_port_list "$prof")
  [[ -n "$args" ]] || { echo "[-] No ports to forward." > "$TTY_OUT"; return 1; }
  launch_in_screen "$prof" "'$BIN_DIR/gost'$args" || return 1
  echo "[+] Started: $(session_name "$prof") (gost, ${n} port(s) -> ${DEST_IP})" > "$TTY_OUT"
}

run_paqet_slot(){
  local prof
  prof="$1"
  load_profile "$prof"
  install_paqet || return 1
  write_paqet_config "$prof" || return 1
  paqet_iptables_apply "$prof" || true
  launch_in_screen "$prof" "'$BIN_DIR/paqet' run -c '$CONF/${prof}.yaml'" || return 1
  echo "[+] Started: $(session_name "$prof") (paqet ${PQ_ROLE})" > "$TTY_OUT"
}

run_gre_slot(){
  local prof ifname
  prof="$1"
  load_profile "$prof"
  ifname="gre${prof}"
  if ip link show "$ifname" >/dev/null 2>&1; then ip link del "$ifname" >/dev/null 2>&1 || true; fi
  if ! ip tunnel add "$ifname" mode gre remote "$PEER_IP" local "$LOCAL_IP" ttl 255; then
    echo "[-] Could not create GRE interface $ifname (check the local/peer IPs and that the gre module is available)." > "$TTY_OUT"
    log_event "$prof" "GRE: failed to create $ifname"
    return 1
  fi
  ip link set "$ifname" up
  ip addr add "${SELF_TUN_IP}/30" dev "$ifname" 2>/dev/null || true
  log_event "$prof" "GRE up: $ifname ${SELF_TUN_IP} <-> ${PEER_TUN_IP} (local ${LOCAL_IP}, peer ${PEER_IP})"
  echo "[+] GRE up: $ifname  ${SELF_TUN_IP} <-> ${PEER_TUN_IP}" > "$TTY_OUT"
  echo "[i] You can now route/NAT specific ports across this tunnel with iptables as needed." > "$TTY_OUT"
}
stop_gre_slot(){
  local prof ifname
  prof="$1"
  ifname="gre${prof}"
  ip link del "$ifname" >/dev/null 2>&1 || true
  log_event "$prof" "GRE down: $ifname"
  echo "[+] GRE down: $ifname" > "$TTY_OUT"
}
status_gre_slot(){
  local prof ifname
  prof="$1"
  ifname="gre${prof}"
  if ip link show "$ifname" >/dev/null 2>&1; then
    echo -e "Profile: $prof | Method: gre | Interface: $ifname | Running: ${CLR_GREEN}ON${CLR_RESET}" > "$TTY_OUT"
  else
    echo -e "Profile: $prof | Method: gre | Running: ${CLR_RED}OFF${CLR_RESET}" > "$TTY_OUT"
  fi
}

run_slot(){
  local prof f m
  prof="$1"
  f="$CONF/${prof}.env"
  [[ -f "$f" ]] || { echo "Profile not found: $prof" > "$TTY_OUT"; return 1; }
  m="$(get_method "$prof")"
  case "$m" in
    asnative) run_slot_asnative "$prof" ;;
    backhaul) run_backhaul_slot "$prof" ;;
    rathole)  run_rathole_slot "$prof" ;;
    frp)      run_frp_slot "$prof" ;;
    gost)     run_gost_slot "$prof" ;;
    paqet)    run_paqet_slot "$prof" ;;
    gre)      run_gre_slot "$prof" ;;
    *) echo "[-] Unknown method: $m" > "$TTY_OUT"; return 1 ;;
  esac
}

stop_slot(){
  local prof m s
  prof="$1"
  m="$(get_method "$prof")"
  if [[ "$m" == "gre" ]]; then
    stop_gre_slot "$prof"
  else
    s="$(session_name "$prof")"
    screen -S "$s" -X quit >/dev/null 2>&1 || true
    log_event "$prof" "=== stopped by user/panel ==="
    echo "[+] Stopped: $s" > "$TTY_OUT"
  fi
}
restart_slot(){ local prof="$1"; stop_slot "$prof" >/dev/null 2>&1 || true; sleep 0.5; run_slot "$prof"; }
status_slot(){
  local prof f m st
  prof="$1"
  f="$CONF/${prof}.env"
  [[ -f "$f" ]] || { echo "Profile not found: $prof" > "$TTY_OUT"; return 1; }
  m="$(get_method "$prof")"
  if [[ "$m" == "gre" ]]; then
    status_gre_slot "$prof"
  else
    st="${CLR_RED}OFF${CLR_RESET}"
    if is_running "$prof"; then st="${CLR_GREEN}ON${CLR_RESET}"; fi
    echo -e "Profile: $prof | Method: $m | Running: $st" > "$TTY_OUT"
  fi
}
delete_slot(){
  local prof f m
  prof="$1"
  f="$CONF/${prof}.env"
  m="$(get_method "$prof")"
  stop_slot "$prof" >/dev/null 2>&1 || true
  clear_slot_restart_cron "$prof" >/dev/null 2>&1 || true
  if [[ "$m" == "paqet" ]]; then paqet_iptables_remove "$prof" >/dev/null 2>&1 || true; fi
  rm -f "$CONF/${prof}.toml" "$CONF/${prof}.yaml" "$(log_file "$prof")" >/dev/null 2>&1 || true
  if [[ -f "$f" ]]; then rm -f "$f"; echo "[+] Deleted: $f" > "$TTY_OUT"; else echo "[-] Not found: $f" > "$TTY_OUT"; fi
}

# Live log in the terminal (tail -f). Ctrl+C returns to the menu.
logs_slot(){
  local prof m lf
  prof="$1"
  m="$(get_method "$prof")"
  lf="$(log_file "$prof")"
  if [[ "$m" == "gre" ]]; then
    echo "[i] Interface counters:" > "$TTY_OUT"
    ip -s link show "gre${prof}" 2>/dev/null > "$TTY_OUT" || echo "[-] Interface not up." > "$TTY_OUT"
  fi
  if [[ ! -f "$lf" ]]; then
    echo "[i] No log yet for ${prof} — start it first." > "$TTY_OUT"
    return 0
  fi
  echo -e "${CLR_DIM}[i] Live log for ${prof} — press Ctrl+C to go back.${CLR_RESET}" > "$TTY_OUT"
  trap ':' INT
  tail -n 60 -f "$lf" || true
  trap - INT
  echo "" > "$TTY_OUT"
}

# Change one field of an existing profile (or re-run the whole wizard), then restart it.
env_get(){ ( set +u; load_profile "$1"; printf '%s' "${!2-}" ); }
env_set(){
  local f k v tmp line found
  f="$1"; k="$2"; v="$3"
  tmp="$(mktemp)"
  found=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$k="* ]]; then
      printf '%s=%q\n' "$k" "$v" >> "$tmp"; found=1
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$f"
  if [[ $found -eq 0 ]]; then printf '%s=%q\n' "$k" "$v" >> "$tmp"; fi
  mv -f "$tmp" "$f"
}

change_config_menu(){
  local prof f c i k keys key nv
  prof="$1"
  f="$CONF/${prof}.env"
  [[ -f "$f" ]] || { echo "Profile not found: $prof" > "$TTY_OUT"; return 1; }
  echo "" > "$TTY_OUT"
  echo -e "${CLR_BOLD}✏️  Change config — ${prof} [$(get_method "$prof")]${CLR_RESET}" > "$TTY_OUT"
  echo "1) Edit one field" > "$TTY_OUT"
  echo "2) Re-run the full wizard (you can pick another protocol)" > "$TTY_OUT"
  echo "0) Cancel" > "$TTY_OUT"
  read -r -p "Select: " c < /dev/tty
  case "$c" in
    1)
      keys=()
      while IFS='=' read -r k _; do
        [[ -n "$k" && "$k" != "METHOD" && "$k" != "ROLE" ]] && keys+=("$k")
      done < "$f"
      if [[ ${#keys[@]} -eq 0 ]]; then echo "No editable fields." > "$TTY_OUT"; return 0; fi
      i=1
      for k in "${keys[@]}"; do
        printf '  %2d) %-16s = %s\n' "$i" "$k" "$(env_get "$prof" "$k")" > "$TTY_OUT"
        i=$((i+1))
      done
      read -r -p "Field number (0 = cancel): " c < /dev/tty
      if [[ ! "$c" =~ ^[0-9]+$ || "$c" -lt 1 || "$c" -gt ${#keys[@]} ]]; then echo "Cancelled." > "$TTY_OUT"; return 0; fi
      key="${keys[$((c-1))]}"
      read -r -p "New value for ${key}: " nv < /dev/tty
      env_set "$f" "$key" "$nv"
      echo "[+] ${key} updated — restarting ${prof}..." > "$TTY_OUT"
      restart_slot "$prof" || true
      status_slot "$prof" || true
      ;;
    2)
      edit_profile "$prof" || true
      ;;
    *) echo "Cancelled." > "$TTY_OUT" ;;
  esac
}

install_healthcheck_script(){
  # Reuses this script's own dispatch logic (run_slot/is_running), so every
  # tunnel method is auto-restarted the same way, without duplicating logic.
  cat >"$HC_SCRIPT" <<EOF
#!/usr/bin/env bash
exec "${INSTALL_PATH}" --healthcheck
EOF
  chmod +x "$HC_SCRIPT"
}
enable_cron_healthcheck(){
  install_healthcheck_script

  echo "" > "$TTY_OUT"
  read -r -p "Enter interval in minutes (default: 1): " interval < /dev/tty || true
  interval=${interval:-1}

  if ! [[ "$interval" =~ ^[0-9]+$ ]]; then
    echo "[!] Invalid number. Using default 1 minute." > "$TTY_OUT"
    interval=1
  fi
  if [ "$interval" -lt 1 ]; then interval=1; fi

  local line="*/$interval * * * * ${HC_SCRIPT} >/dev/null 2>&1 ${HC_CRON_TAG}"
  local tmp; tmp="$(mktemp)"
  (crontab -l 2>/dev/null || true) | grep -vF "${HC_CRON_TAG}" >"$tmp" || true
  echo "$line" >>"$tmp"
  crontab "$tmp"
  rm -f "$tmp"
  echo "[+] Cron enabled (every $interval minute(s))." > "$TTY_OUT"
}

write_webpanel_app(){
  cat > "$WEBPANEL_DIR/app.py" <<'PYEOF'
#!/usr/bin/env python3
import json, os, secrets, subprocess
from flask import Flask, request, jsonify, send_from_directory
from werkzeug.security import check_password_hash

APP_DIR = os.path.dirname(os.path.abspath(__file__))
INSTALL_PATH = os.environ.get("INSTALL_PATH", "/usr/local/bin/A,S-tunnel")
PORT = int(os.environ.get("PORT", "8088"))
USERNAME = os.environ.get("USERNAME", "")
PASSWORD_HASH = os.environ.get("PASSWORD_HASH", "")
HTTPS = os.environ.get("HTTPS", "false") == "true"
CERT_FILE = os.environ.get("CERT_FILE", "")
KEY_FILE = os.environ.get("KEY_FILE", "")

app = Flask(__name__, static_folder=None)


def run_api(args, stdin_data=None, timeout=180):
    if not os.path.isfile(INSTALL_PATH):
        return {"error": "script_not_installed",
                "hint": "Run the CLI menu once (option 5: Install script) so " + INSTALL_PATH + " exists."}, 500
    cmd = [INSTALL_PATH, "--api"] + args
    try:
        p = subprocess.run(cmd, input=stdin_data, capture_output=True, text=True, timeout=timeout)
    except Exception as e:
        return {"error": str(e)}, 500
    out = (p.stdout or "").strip()
    if not out:
        return {"error": "empty_response", "stderr": p.stderr}, 500
    try:
        return json.loads(out), 200
    except Exception:
        return {"error": "bad_response", "raw": out, "stderr": p.stderr}, 500


def check_auth():
    if not USERNAME or not PASSWORD_HASH:
        return True
    auth = request.authorization
    if not auth:
        return False
    if not secrets.compare_digest(auth.username or "", USERNAME):
        return False
    return check_password_hash(PASSWORD_HASH, auth.password or "")


@app.before_request
def guard():
    if request.path.startswith("/api/") and request.path != "/api/whoami":
        if not check_auth():
            return jsonify({"error": "unauthorized"}), 401
    if request.path == "/api/whoami":
        if not check_auth():
            return jsonify({"authenticated": False}), 401


@app.get("/")
def index():
    return send_from_directory(APP_DIR, "index.html")


@app.get("/api/whoami")
def whoami():
    return jsonify({"authenticated": True, "username": USERNAME})


@app.get("/api/info")
def info():
    data, code = run_api(["info"])
    return jsonify(data), code


@app.get("/api/slots")
def slots():
    data, code = run_api(["list"])
    return jsonify(data), code


@app.get("/api/slots/<prof>")
def slot_get(prof):
    data, code = run_api(["get", prof])
    return jsonify(data), code


@app.post("/api/slots/<prof>")
def slot_save(prof):
    body = json.dumps(request.get_json(force=True, silent=True) or {})
    data, code = run_api(["save", prof], stdin_data=body)
    return jsonify(data), code


@app.post("/api/slots/<prof>/<action>")
def slot_action(prof, action):
    if action not in ("start", "stop", "restart"):
        return jsonify({"error": "bad_action"}), 400
    data, code = run_api([action, prof])
    return jsonify(data), code


@app.delete("/api/slots/<prof>")
def slot_delete(prof):
    data, code = run_api(["delete", prof])
    return jsonify(data), code


@app.get("/api/slots/<prof>/logs")
def slot_logs(prof):
    lines = request.args.get("lines", "300")
    if not lines.isdigit():
        lines = "300"
    data, code = run_api(["logs", prof, lines], timeout=30)
    return jsonify(data), code


@app.post("/api/healthcheck")
def healthcheck():
    body = request.get_json(force=True, silent=True) or {}
    minutes = str(body.get("minutes", 1))
    data, code = run_api(["hc", "on" if body.get("enabled") else "off", minutes])
    return jsonify(data), code


@app.post("/api/slots/<prof>/restartcron")
def slot_restartcron(prof):
    body = request.get_json(force=True, silent=True) or {}
    hours = str(body.get("hours", 6))
    data, code = run_api(["restartcron", prof, "on" if body.get("enabled") else "off", hours])
    return jsonify(data), code


@app.post("/api/optimize")
def optimize():
    data, code = run_api(["optimize"])
    return jsonify(data), code


if __name__ == "__main__":
    ssl_ctx = None
    if HTTPS and CERT_FILE and KEY_FILE and os.path.isfile(CERT_FILE) and os.path.isfile(KEY_FILE):
        ssl_ctx = (CERT_FILE, KEY_FILE)
    app.run(host="0.0.0.0", port=PORT, ssl_context=ssl_ctx)
PYEOF
}

write_webpanel_html(){
  cat > "$WEBPANEL_DIR/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>A,S Tunnel Panel</title>
<style>
  :root{
    --bg1:#0f0c29; --bg2:#302b63; --bg3:#24243e;
    --accent:#7ee8fa; --accent2:#a682ff;
    --glass:rgba(255,255,255,0.07); --glass-brd:rgba(255,255,255,0.14);
    --green:#3ddc84; --red:#ff5c7a; --yellow:#ffd166; --dim:rgba(255,255,255,0.55);
  }
  *{box-sizing:border-box}
  html,body{height:100%}
  body{
    margin:0; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Arial,sans-serif;
    color:#fff; min-height:100%;
    background:linear-gradient(135deg,var(--bg1),var(--bg2) 50%,var(--bg3));
    background-attachment:fixed;
    padding:env(safe-area-inset-top,0) 0 env(safe-area-inset-bottom,0);
  }
  body::before{
    content:""; position:fixed; inset:0; pointer-events:none; z-index:0;
    background:
      radial-gradient(circle at 15% 20%, rgba(126,232,250,0.18), transparent 40%),
      radial-gradient(circle at 85% 80%, rgba(166,130,255,0.18), transparent 40%),
      radial-gradient(circle at 50% 100%, rgba(255,209,102,0.08), transparent 45%);
  }
  .wrap{position:relative; z-index:1; max-width:1140px; margin:0 auto; padding:20px 16px 60px}
  .glass{
    background:var(--glass); backdrop-filter:blur(18px); -webkit-backdrop-filter:blur(18px);
    border:1px solid var(--glass-brd); border-radius:18px;
    box-shadow:0 8px 32px rgba(0,0,0,0.35);
  }
  section{margin-bottom:20px}
  section > .sec-head{display:flex; align-items:center; justify-content:space-between; margin:0 0 10px 4px}
  section > .sec-head h2{font-size:13px; text-transform:uppercase; letter-spacing:1.2px; color:var(--dim); margin:0; display:flex; align-items:center; gap:6px}

  header.glass{padding:16px 20px; display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:12px; margin-bottom:18px}
  .brand{display:flex; align-items:center; gap:12px}
  .brand .logo{
    width:42px; height:42px; border-radius:12px; display:flex; align-items:center; justify-content:center;
    background:linear-gradient(135deg,var(--accent),var(--accent2)); font-size:20px; flex:none;
    box-shadow:0 4px 14px rgba(126,232,250,0.35);
  }
  header h1{font-size:18px; margin:0; font-weight:700; letter-spacing:.3px}
  header .sub{font-size:12px; color:var(--dim); margin-top:2px}
  .author-badge{
    display:inline-flex; align-items:center; gap:6px; font-size:11px; color:var(--dim);
    padding:5px 10px; border-radius:999px; background:rgba(255,255,255,0.06); border:1px solid var(--glass-brd);
    text-decoration:none;
  }
  .author-badge b{color:#fff}
  .author-badge:hover{background:rgba(255,255,255,0.12)}

  .stats-row{display:flex; gap:10px; flex-wrap:wrap}
  .stat{
    flex:1 1 140px; padding:14px 16px; display:flex; flex-direction:column; gap:4px;
  }
  .stat .label{font-size:11px; color:var(--dim); text-transform:uppercase; letter-spacing:.6px}
  .stat .value{font-size:15px; font-weight:600}

  .pill{display:inline-flex; align-items:center; gap:6px; padding:5px 12px; border-radius:999px; font-size:12px; background:rgba(255,255,255,0.08); border:1px solid var(--glass-brd)}
  .dot{width:8px; height:8px; border-radius:50%}
  .dot.on{background:var(--green); box-shadow:0 0 8px var(--green)}
  .dot.off{background:var(--red); box-shadow:0 0 8px var(--red)}
  .dot.empty{background:rgba(255,255,255,0.25)}
  .cols{display:grid; grid-template-columns:1fr 1fr; gap:18px}
  @media (max-width:760px){.cols{grid-template-columns:1fr} .stats-row{flex-direction:column}}
  .col-box{padding:16px}
  .slot{
    padding:14px 16px; margin-bottom:10px; border-radius:14px; cursor:pointer;
    display:flex; justify-content:space-between; align-items:center; gap:10px;
    transition:transform .15s ease, background .15s ease; border:1px solid transparent;
  }
  .slot:last-child{margin-bottom:0}
  .slot:hover{transform:translateY(-2px); background:rgba(255,255,255,0.11)}
  .slot.is-on{border-color:rgba(61,220,132,0.35)}
  .slot .name{font-weight:600; font-size:14px}
  .slot .meta{font-size:11px; color:var(--dim); margin-top:2px; text-transform:capitalize}
  .btnrow{display:flex; gap:8px; margin-top:18px; flex-wrap:wrap}
  button{
    font-family:inherit; cursor:pointer; border:1px solid var(--glass-brd); color:#fff;
    background:rgba(255,255,255,0.08); padding:9px 16px; border-radius:12px; font-size:13px;
    transition:background .15s ease, transform .1s ease;
  }
  button:hover{background:rgba(255,255,255,0.16)}
  button:active{transform:scale(.97)}
  button.primary{background:linear-gradient(135deg,var(--accent),var(--accent2)); color:#10121c; font-weight:700; border:none}
  button.danger{background:rgba(255,92,122,0.18); border-color:rgba(255,92,122,0.4)}
  button.ghost{background:transparent}
  input,select{
    width:100%; padding:10px 12px; border-radius:10px; border:1px solid var(--glass-brd);
    background:rgba(0,0,0,0.25); color:#fff; font-size:14px; font-family:inherit; margin-top:4px;
  }
  label{font-size:12px; color:var(--dim); display:block; margin-top:12px}
  .field-grid{display:grid; grid-template-columns:1fr 1fr; gap:0 14px}
  .field-grid .full{grid-column:1/-1}
  .modal-bg{
    position:fixed; inset:0; background:rgba(5,5,15,0.6); backdrop-filter:blur(4px);
    display:flex; align-items:center; justify-content:center; z-index:50; padding:16px;
  }
  .modal{width:100%; max-width:480px; max-height:88vh; overflow-y:auto; padding:22px}
  .modal h3{margin:0 0 4px}
  .modal .close{position:absolute; top:14px; right:18px; cursor:pointer; font-size:20px; color:var(--dim)}
  .hidden{display:none !important}
  pre.logbox{
    white-space:pre-wrap; word-break:break-word; background:rgba(0,0,0,0.35); border-radius:10px;
    padding:12px; font-size:12px; max-height:50vh; overflow-y:auto; border:1px solid var(--glass-brd);
  }
  .toast{
    position:fixed; bottom:20px; left:50%; transform:translateX(-50%); z-index:100;
    padding:12px 20px; border-radius:12px; font-size:13px; opacity:0; transition:opacity .25s ease;
    pointer-events:none;
  }
  .toast.show{opacity:1}
  .gate{position:fixed; inset:0; z-index:200; display:flex; align-items:center; justify-content:center; padding:16px}
  .gate .box{width:100%; max-width:380px; padding:30px}
  .gate .glogo{
    width:56px; height:56px; margin:0 auto 14px; border-radius:16px; display:flex; align-items:center; justify-content:center;
    background:linear-gradient(135deg,var(--accent),var(--accent2)); font-size:26px;
    box-shadow:0 6px 20px rgba(126,232,250,0.35);
  }
  .footer-note{text-align:center; color:var(--dim); font-size:11px; margin-top:28px; display:flex; flex-direction:column; gap:8px; align-items:center}
  .switch{position:relative; display:inline-block; width:42px; height:24px}
  .switch input{opacity:0; width:0; height:0}
  .slider{position:absolute; cursor:pointer; inset:0; background:rgba(255,255,255,0.15); border-radius:24px; transition:.2s}
  .slider:before{content:""; position:absolute; height:18px; width:18px; left:3px; top:3px; background:#fff; border-radius:50%; transition:.2s}
  input:checked + .slider{background:linear-gradient(135deg,var(--accent),var(--accent2))}
  input:checked + .slider:before{transform:translateX(18px)}
  .modal{max-width:560px}
  .tabs{display:flex; gap:8px; margin:12px 0 6px}
  .tab{padding:7px 14px; border-radius:10px; font-size:13px}
  .tab.active{background:linear-gradient(135deg,var(--accent),var(--accent2)); color:#10121c; font-weight:700; border-color:transparent}
  .slotmsg{white-space:pre-wrap; word-break:break-word; font-size:12px; margin-top:12px; color:var(--dim); padding:0}
  .slotmsg.ok{color:var(--green)}
  .slotmsg.err{color:var(--red); background:rgba(255,92,122,0.10); border:1px solid rgba(255,92,122,0.3); border-radius:10px; padding:10px}
  .logbar{display:flex; gap:10px; align-items:center; flex-wrap:wrap; margin-bottom:8px; font-size:12px; color:var(--dim)}
  .logbar select{width:auto; margin-top:0; padding:6px 8px}
  button:disabled{opacity:.55; cursor:wait}
</style>
</head>
<body>

<div id="gate" class="gate">
  <div class="box glass">
    <div class="glogo">🚀</div>
    <h3 style="margin:0 0 2px; text-align:center">A,S Tunnel Panel</h3>
    <p style="color:var(--dim); font-size:13px; text-align:center; margin-top:2px">Sign in to manage your tunnels</p>
    <label>Username</label>
    <input id="userInput" type="text" autocomplete="username" placeholder="Username">
    <label>Password</label>
    <input id="passInput" type="password" autocomplete="current-password" placeholder="Password">
    <div class="btnrow"><button class="primary" style="width:100%" onclick="submitLogin()">🔓 Sign in</button></div>
    <div id="gateError" style="color:var(--red); font-size:12px; margin-top:10px; text-align:center"></div>
    <div class="footer-note" style="margin-top:22px">
      <a class="author-badge" href="https://t.me/Asnejad" target="_blank" rel="noopener">✈️ Built by <b>A,S</b> · @Asnejad</a>
    </div>
  </div>
</div>

<div class="wrap hidden" id="app">
  <header class="glass">
    <div class="brand">
      <div class="logo">🚀</div>
      <div>
        <h1>A,S Tunnel</h1>
        <div class="sub" id="infoLine">loading…</div>
      </div>
    </div>
    <div style="display:flex; gap:8px; align-items:center; flex-wrap:wrap">
      <span class="pill">🕒 Health check
        <label class="switch"><input type="checkbox" id="hcToggle" onchange="toggleHC()"><span class="slider"></span></label>
      </span>
      <button class="ghost" onclick="runOptimize()">🚀 Optimize</button>
      <button class="ghost" onclick="loadSlots()">⟳ Refresh</button>
      <button class="ghost" onclick="logout()">🔒 Logout</button>
    </div>
  </header>

  <section>
    <div class="sec-head"><h2>📊 Overview</h2></div>
    <div class="stats-row">
      <div class="stat glass"><span class="label">Version</span><span class="value" id="stVersion">—</span></div>
      <div class="stat glass"><span class="label">Location</span><span class="value" id="stLocation">—</span></div>
      <div class="stat glass"><span class="label">Datacenter</span><span class="value" id="stDatacenter">—</span></div>
      <div class="stat glass"><span class="label">Active tunnels</span><span class="value" id="stActive">—</span></div>
    </div>
  </section>

  <section>
    <div class="sec-head"><h2>🎛 Tunnels</h2><span class="sub" style="font-size:11px; color:var(--dim)">click a slot to configure</span></div>
    <div class="cols">
      <div class="col">
        <div class="sec-head"><h2>🌍 EU</h2></div>
        <div class="col-box glass" id="euList"></div>
      </div>
      <div class="col">
        <div class="sec-head"><h2>🇮🇷 IRAN</h2></div>
        <div class="col-box glass" id="iranList"></div>
      </div>
    </div>
  </section>

  <div class="footer-note">
    <a class="author-badge" href="https://t.me/Asnejad" target="_blank" rel="noopener">✈️ Crafted by <b>A,S</b> · @Asnejad</a>
    <span>Keep this URL and password private</span>
  </div>
</div>

<!-- Slot modal: Config + Live log -->
<div id="slotModal" class="modal-bg hidden">
  <div class="modal glass" style="position:relative">
    <span class="close" onclick="closeModal('slotModal')">✕</span>
    <h3 id="modalTitle">Slot</h3>
    <div class="sub" id="modalSub" style="color:var(--dim); font-size:12px"></div>

    <div class="tabs">
      <button class="tab active" data-tab="config" onclick="switchTab('config')">⚙ Config</button>
      <button class="tab" data-tab="log" onclick="switchTab('log')">📜 Live log</button>
    </div>

    <div id="paneConfig">
      <label>Protocol</label>
      <select id="methodSelect" onchange="renderFields()">
        <option value="asnative">A,S Native</option>
        <option value="backhaul">Backhaul</option>
        <option value="rathole">Rathole</option>
        <option value="gre">GRE</option>
        <option value="frp">FRP</option>
        <option value="gost">Gost</option>
        <option value="paqet">Paqet</option>
      </select>

      <div id="fieldsBox"></div>

      <div class="btnrow">
        <button id="saveBtn" class="primary" onclick="saveSlot()">💾 Save & Apply</button>
        <button id="startBtn" onclick="doAction('start')">▶ Start</button>
        <button id="stopBtn" onclick="doAction('stop')">⏹ Stop</button>
        <button id="restartBtn" onclick="doAction('restart')">🔁 Restart</button>
      </div>
      <div class="btnrow">
        <button class="danger" onclick="deleteSlot()">🗑 Delete</button>
      </div>

      <label style="margin-top:18px">⏱ Scheduled restart <span style="color:var(--dim)">(regardless of status)</span></label>
      <div style="display:flex; gap:10px; align-items:center; margin-top:6px">
        <label class="switch"><input type="checkbox" id="rcToggle"><span class="slider"></span></label>
        <input id="rcHours" type="text" placeholder="every N hours" style="margin-top:0; max-width:140px">
        <button onclick="saveRestartCron()">💾 Save</button>
      </div>

      <div id="slotMsg" class="slotmsg"></div>
    </div>

    <div id="paneLog" class="hidden">
      <div class="logbar">
        <span>Live</span>
        <label class="switch"><input type="checkbox" id="liveToggle" checked onchange="startLive()"><span class="slider"></span></label>
        <select id="logLines" onchange="refreshLog(true)">
          <option value="100">last 100 lines</option>
          <option value="300" selected>last 300 lines</option>
          <option value="1000">last 1000 lines</option>
        </select>
        <button onclick="refreshLog(true)">⟳ Refresh</button>
        <span id="logStamp"></span>
      </div>
      <pre class="logbox" id="logsBox">…</pre>
    </div>
  </div>
</div>

<div id="toast" class="toast glass"></div>

<script>
let AUTH = localStorage.getItem('as_auth') || '';
let SLOTS = [];
let CURRENT = null;

const FIELD_DEFS = {
  asnative_eu: [
    {k:'IRAN_IP', l:'Iran IP', t:'text'},
    {k:'BRIDGE', l:'Bridge port', t:'text', ph:'7000'},
    {k:'SYNC', l:'Sync port', t:'text', ph:'7001'},
  ],
  asnative_iran: [
    {k:'BRIDGE', l:'Bridge port', t:'text', ph:'7000'},
    {k:'SYNC', l:'Sync port', t:'text', ph:'7001'},
    {k:'AUTO_SYNC', l:'Auto-sync ports?', t:'select', opts:['true','false']},
    {k:'PORTS', l:'Manual ports (CSV, if auto-sync=false)', t:'text', full:true},
  ],
  backhaul: [
    {k:'BH_ROLE', l:'Role', t:'select', opts:['server','client']},
    {k:'TOKEN', l:'Shared token', t:'text', full:true},
    {k:'TRANSPORT', l:'Transport', t:'select', opts:['tcp','ws','wss']},
    {k:'BIND_PORT', l:'Control port', t:'text'},
    {k:'SERVER_IP', l:'Server IP (client only)', t:'text'},
    {k:'FORWARD_PORTS', l:'Forward ports CSV (server only)', t:'text', full:true},
  ],
  rathole: [
    {k:'RT_ROLE', l:'Role', t:'select', opts:['server','client']},
    {k:'TOKEN', l:'Shared token', t:'text', full:true},
    {k:'BIND_PORT', l:'Control port', t:'text'},
    {k:'SERVER_IP', l:'Server IP (client only)', t:'text'},
    {k:'FORWARD_PORTS', l:'Forward ports CSV', t:'text', full:true},
  ],
  gre: [
    {k:'LOCAL_IP', l:'This host public IP', t:'text', full:true},
    {k:'PEER_IP', l:'Peer public IP', t:'text', full:true},
  ],
  frp: [
    {k:'FRP_ROLE', l:'Role', t:'select', opts:['server','client']},
    {k:'TOKEN', l:'Shared token', t:'text', full:true},
    {k:'BIND_PORT', l:'Control port', t:'text'},
    {k:'SERVER_IP', l:'Server IP (client only)', t:'text'},
    {k:'FORWARD_PORTS', l:'Forward ports CSV (client only)', t:'text', full:true},
  ],
  paqet: [
    {k:'PQ_ROLE', l:'Role', t:'select', opts:['server','client']},
    {k:'SERVER_PORT', l:'Tunnel port', t:'text', ph:'8888'},
    {k:'SECRET_KEY', l:'Secret key (same on both sides)', t:'text', full:true},
    {k:'SERVER_IP', l:'Server IP (client only)', t:'text', full:true},
    {k:'KCP_MODE', l:'KCP mode', t:'select', opts:['fast','normal','fast2','fast3']},
    {k:'BLOCK', l:'Encryption', t:'select', opts:['aes-128-gcm','aes','aes-128','aes-192','aes-256','none']},
    {k:'CONN', l:'Connections (1-32)', t:'text', ph:'4'},
    {k:'MTU', l:'MTU', t:'text', ph:'1150'},
    {k:'FORWARD_PORTS', l:'TCP ports to forward (client)', t:'text', full:true},
    {k:'FORWARD_UDP_PORTS', l:'UDP ports to forward (client)', t:'text', full:true},
    {k:'SOCKS5_PORT', l:'SOCKS5 port (client)', t:'text'},
    {k:'SOCKS5_USER', l:'SOCKS5 user', t:'text'},
    {k:'SOCKS5_PASS', l:'SOCKS5 password', t:'text'},
    {k:'ROUTER_MAC', l:'Router MAC (blank = auto)', t:'text', full:true},
  ],
  gost: [
    {k:'DEST_IP', l:'Destination (Kharej) IP', t:'text', full:true},
    {k:'PORT_MODE', l:'Port mode', t:'select', opts:['manual','range']},
    {k:'PORTS', l:'Ports CSV (if manual)', t:'text', full:true},
    {k:'RANGE_START', l:'Range start (if range)', t:'text'},
    {k:'RANGE_END', l:'Range end (if range)', t:'text'},
    {k:'PROTO', l:'Protocol', t:'select', opts:['tcp','udp','grpc']},
  ],
};

function api(path, opts={}){
  opts.headers = Object.assign({'Content-Type':'application/json','Authorization':'Basic '+AUTH}, opts.headers||{});
  return fetch(path, opts).then(async r=>{
    const data = await r.json().catch(()=>({error:'bad_json'}));
    if(r.status===401){ showGate('Invalid username or password.'); throw new Error('unauthorized'); }
    return data;
  });
}

function showGate(err){
  document.getElementById('gate').classList.remove('hidden');
  document.getElementById('app').classList.add('hidden');
  document.getElementById('gateError').textContent = err || '';
}
function submitLogin(){
  const u = document.getElementById('userInput').value.trim();
  const p = document.getElementById('passInput').value;
  AUTH = btoa(u + ':' + p);
  localStorage.setItem('as_auth', AUTH);
  boot();
}
function logout(){
  localStorage.removeItem('as_auth');
  AUTH = '';
  document.getElementById('passInput').value = '';
  showGate('');
}

function toast(msg, isErr){
  const el = document.getElementById('toast');
  el.textContent = msg;
  el.style.background = isErr ? 'rgba(255,92,122,0.25)' : 'rgba(61,220,132,0.22)';
  el.classList.add('show');
  clearTimeout(el._t);
  el._t = setTimeout(()=>el.classList.remove('show'), 2600);
}

function closeModal(id){
  if(id==='slotModal'){ stopLive(); }
  document.getElementById(id).classList.add('hidden');
}

async function boot(){
  if(!AUTH){ showGate(''); return; }
  try{
    const info = await api('/api/info');
    if(info.error){ showGate('Invalid credentials or server error.'); return; }
    document.getElementById('gate').classList.add('hidden');
    document.getElementById('app').classList.remove('hidden');
    document.getElementById('infoLine').textContent = 'Multi-protocol tunnel dashboard';
    document.getElementById('stVersion').textContent = 'v' + (info.version || '?');
    document.getElementById('stLocation').textContent = info.location || 'Unknown';
    document.getElementById('stDatacenter').textContent = info.datacenter || 'Unknown';
    loadSlots();
  }catch(e){ /* gate already shown */ }
}

async function loadSlots(){
  const data = await api('/api/slots');
  if(!Array.isArray(data)) return;
  SLOTS = data;
  renderList('eu'); renderList('iran');
  document.getElementById('stActive').textContent = SLOTS.filter(s=>s.running).length + ' / ' + SLOTS.length;
}

function slotFor(role,i){ return SLOTS.find(s=>s.role===role && s.slot===i); }

function renderList(role){
  const box = document.getElementById(role+'List');
  box.innerHTML = '';
  for(let i=1;i<=10;i++){
    const s = slotFor(role,i);
    const div = document.createElement('div');
    div.className = 'slot' + (s && s.running ? ' is-on' : '');
    const dotClass = !s ? 'empty' : (s.running ? 'on' : 'off');
    div.innerHTML = `
      <div>
        <div class="name">${role}${i}</div>
        <div class="meta">${s ? s.method : 'empty'}</div>
      </div>
      <span class="dot ${dotClass}"></span>`;
    div.onclick = ()=>openSlot(role, i, s);
    box.appendChild(div);
  }
}

function openSlot(role, i, existing){
  CURRENT = {prof: role+i, role, i};
  document.getElementById('modalTitle').textContent = CURRENT.prof;
  paintStatus(existing ? !!existing.running : false, !!existing);
  setMsg('', '');
  switchTab('config');
  const sel = document.getElementById('methodSelect');
  sel.value = existing ? existing.method : 'asnative';
  renderFields();
  document.getElementById('rcToggle').checked = false;
  document.getElementById('rcHours').value = '';
  if(existing){
    api('/api/slots/'+CURRENT.prof).then(d=>{
      if(d.fields){ fillFields(d.fields); }
      if(d.restart_hours){
        document.getElementById('rcToggle').checked = true;
        document.getElementById('rcHours').value = d.restart_hours;
      }
    });
  }
  document.getElementById('slotModal').classList.remove('hidden');
}

function fieldDefsFor(){
  const m = document.getElementById('methodSelect').value;
  if(m === 'asnative') return FIELD_DEFS['asnative_' + CURRENT.role];
  return FIELD_DEFS[m];
}

function renderFields(){
  const defs = fieldDefsFor();
  const box = document.getElementById('fieldsBox');
  box.innerHTML = '<div class="field-grid"></div>';
  const grid = box.firstChild;
  defs.forEach(f=>{
    const wrap = document.createElement('div');
    if(f.full) wrap.className = 'full';
    let inputHtml;
    if(f.t === 'select'){
      inputHtml = `<select id="f_${f.k}">${f.opts.map(o=>`<option value="${o}">${o}</option>`).join('')}</select>`;
    } else {
      inputHtml = `<input id="f_${f.k}" type="text" placeholder="${f.ph||''}">`;
    }
    wrap.innerHTML = `<label>${f.l}</label>${inputHtml}`;
    grid.appendChild(wrap);
  });
}

function fillFields(fields){
  Object.keys(fields).forEach(k=>{
    const el = document.getElementById('f_'+k);
    if(el) el.value = fields[k];
  });
}

function collectFields(){
  const defs = fieldDefsFor();
  const out = {};
  defs.forEach(f=>{
    const el = document.getElementById('f_'+f.k);
    if(el && el.value !== '') out[f.k] = el.value;
  });
  return out;
}

function setMsg(text, kind){
  const el = document.getElementById('slotMsg');
  el.textContent = text || '';
  el.className = 'slotmsg ' + (kind || '');
}
function setBusy(on, label){
  ['saveBtn','startBtn','stopBtn','restartBtn'].forEach(id=>{ const b=document.getElementById(id); if(b) b.disabled = on; });
  const sb = document.getElementById('saveBtn');
  if(on && label){ sb.dataset.label = sb.dataset.label || sb.textContent; sb.textContent = '⏳ ' + label; }
  if(!on && sb.dataset.label){ sb.textContent = sb.dataset.label; delete sb.dataset.label; }
}
function paintStatus(running, known){
  const el = document.getElementById('modalSub');
  el.textContent = known === false ? 'new slot' : (running ? '🟢 running' : '🔴 stopped');
}
async function refreshSlotState(){
  await loadSlots();
  const d = await api('/api/slots/'+CURRENT.prof);
  if(d && !d.error){ paintStatus(!!d.running); return d; }
  return null;
}

async function saveSlot(){
  const method = document.getElementById('methodSelect').value;
  const fields = collectFields();
  setBusy(true, 'Saving & applying…');
  setMsg('Saving and starting the tunnel…', '');
  try{
    const res = await api('/api/slots/'+CURRENT.prof, {method:'POST', body: JSON.stringify({method, fields})});
    await refreshSlotState();
    const t = new Date().toLocaleTimeString();
    if(res.ok){
      setMsg('✔ Saved and running  ('+t+')', 'ok');
      toast('Saved & running ✔');
    } else if(res.saved){
      setMsg('✔ Config saved, but the tunnel is not running:\n' + (res.log || res.error || 'unknown error'), 'err');
      toast('Saved — but not running', true);
    } else {
      setMsg('✖ ' + (res.log || res.hint || res.error || 'Save failed'), 'err');
      toast('Save failed', true);
    }
  }catch(e){
    if(e.message !== 'unauthorized') setMsg('✖ Request failed: ' + e.message, 'err');
  }finally{
    setBusy(false);
  }
}

async function doAction(action){
  setBusy(true);
  setMsg(action + '…', '');
  try{
    const res = await api(`/api/slots/${CURRENT.prof}/${action}`, {method:'POST'});
    await refreshSlotState();
    if(res.ok){ setMsg('✔ ' + action + ' done', 'ok'); toast(action + ' ok ✔'); }
    else { setMsg('✖ ' + action + ' failed:\n' + (res.log || res.hint || res.error || ''), 'err'); toast(action + ' failed', true); }
  }catch(e){
    if(e.message !== 'unauthorized') setMsg('✖ Request failed: ' + e.message, 'err');
  }finally{
    setBusy(false);
  }
}

async function deleteSlot(){
  if(!confirm('Delete '+CURRENT.prof+'? This stops it and removes its config, log and schedule.')) return;
  const res = await api('/api/slots/'+CURRENT.prof, {method:'DELETE'});
  if(res.ok){ toast('Deleted'); closeModal('slotModal'); loadSlots(); }
  else { toast('Delete failed', true); }
}

async function saveRestartCron(){
  const enabled = document.getElementById('rcToggle').checked;
  const hours = document.getElementById('rcHours').value || '6';
  const res = await api('/api/slots/'+CURRENT.prof+'/restartcron', {method:'POST', body: JSON.stringify({enabled, hours})});
  if(res.ok){ setMsg(enabled ? '✔ Restarts every '+hours+'h' : '✔ Scheduled restart disabled', 'ok'); toast(enabled ? 'Scheduled every '+hours+'h ✔' : 'Schedule disabled ✔'); }
  else { toast('Failed', true); setMsg(res.error || 'Failed', 'err'); }
}

/* ---------- tabs + live log ---------- */
let LIVE_TIMER = null;
function switchTab(name){
  document.querySelectorAll('.tab').forEach(t=>t.classList.toggle('active', t.dataset.tab === name));
  document.getElementById('paneConfig').classList.toggle('hidden', name !== 'config');
  document.getElementById('paneLog').classList.toggle('hidden', name !== 'log');
  if(name === 'log'){ refreshLog(true); startLive(); } else { stopLive(); }
}
function startLive(){
  stopLive();
  if(document.getElementById('liveToggle').checked){ LIVE_TIMER = setInterval(()=>refreshLog(false), 2000); }
}
function stopLive(){ if(LIVE_TIMER){ clearInterval(LIVE_TIMER); LIVE_TIMER = null; } }
async function refreshLog(force){
  if(!CURRENT) return;
  const box = document.getElementById('logsBox');
  const n = document.getElementById('logLines').value;
  try{
    const res = await api(`/api/slots/${CURRENT.prof}/logs?lines=${n}`);
    const nearBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 60;
    box.textContent = res.logs || res.error || '(no output yet)';
    if(force || nearBottom) box.scrollTop = box.scrollHeight;
    if(typeof res.running === 'boolean') paintStatus(res.running);
    document.getElementById('logStamp').textContent = 'updated ' + new Date().toLocaleTimeString();
  }catch(e){ /* auth problems already show the login gate */ }
}

async function toggleHC(){
  const enabled = document.getElementById('hcToggle').checked;
  let minutes = 1;
  if(enabled){
    minutes = prompt('Health-check interval in minutes:', '1') || '1';
  }
  const res = await api('/api/healthcheck', {method:'POST', body: JSON.stringify({enabled, minutes})});
  toast(res.ok ? 'Health check updated ✔' : 'Failed', !res.ok);
}

async function runOptimize(){
  toast('Optimizing server…');
  const res = await api('/api/optimize', {method:'POST'});
  toast(res.log ? 'Optimize done ✔' : 'Failed', !res.log);
}

document.getElementById('passInput').addEventListener('keydown', e=>{ if(e.key==='Enter') submitLogin(); });
document.getElementById('userInput').addEventListener('keydown', e=>{ if(e.key==='Enter') document.getElementById('passInput').focus(); });
boot();
</script>
</body>
</html>
HTMLEOF
}

gen_password(){ head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 14; }
gen_username(){ echo "admin_$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
gen_port(){ if have shuf; then shuf -i 20000-59999 -n1; else echo $(( (RANDOM % 40000) + 20000 )); fi; }
hash_password(){ python3 -c "from werkzeug.security import generate_password_hash; import sys; print(generate_password_hash(sys.argv[1]))" "$1"; }
gen_strong_token(){ head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32; }

# An empty shared token effectively disables auth on Backhaul/Rathole/FRP —
# never leave it blank; auto-generate a strong one instead.
prompt_token(){
  local t side
  side="${1:-1}"   # wizards pass the role choice: 1 = server (may generate), 2 = client (must paste)
  if [[ "$side" == "2" ]]; then
    while true; do
      read -r -p "Shared token (copy it from the server side): " t < /dev/tty
      [[ -n "$t" ]] && break
      echo "A token is required on the client side." > "$TTY_OUT"
    done
    echo "$t"
    return 0
  fi
  read -r -p "Shared token (Enter to auto-generate a strong one): " t < /dev/tty
  if [[ -z "$t" ]]; then
    t="$(gen_strong_token)"
    echo -e "${CLR_DIM}[+] Generated token: ${CLR_YELLOW}${t}${CLR_RESET}${CLR_DIM} — use the exact same value on the client side.${CLR_RESET}" > "$TTY_OUT"
  fi
  echo "$t"
}

# Single-quotes every value: PASSWORD_HASH looks like "pbkdf2:sha256:N$salt$hash" and
# an unquoted '$' in the file gets re-interpreted as a variable reference the next
# time this file is `source`d — under `set -u` that crashes with "unbound variable".
write_webpanel_env(){
  local panel_ip https port username phash cert key
  panel_ip="$1"
  https="$2"
  port="$3"
  username="$4"
  phash="$5"
  cert="$6"
  key="$7"
  cat > "$WEBPANEL_ENV" <<EOF
PANEL_IP='${panel_ip}'
HTTPS='${https}'
PORT='${port}'
USERNAME='${username}'
PASSWORD_HASH='${phash}'
CERT_FILE='${cert}'
KEY_FILE='${key}'
EOF
}

make_selfsigned_cert(){
  local ip dir
  ip="$1"
  dir="$WEBPANEL_DIR/certs"
  mkdir -p "$dir"
  have openssl || apt_try_install openssl
  openssl req -x509 -newkey rsa:2048 -keyout "$dir/key.pem" -out "$dir/cert.pem" \
    -days 825 -nodes -subj "/CN=${ip:-A,S-tunnel}" >/dev/null 2>&1
  echo "$dir/cert.pem|$dir/key.pem"
}

install_webpanel(){
  echo "" > "$TTY_OUT"
  echo "[*] Setting up Web Panel..." > "$TTY_OUT"

  if [[ ! -f "$INSTALL_PATH" ]]; then
    echo "[*] The web panel calls the installed script, which isn't set up yet — installing it first..." > "$TTY_OUT"
    install_script
  fi

  have python3 || apt_try_install python3
  python3 -c "import flask, werkzeug" >/dev/null 2>&1 || { pip3 install --break-system-packages flask >/dev/null 2>&1 || apt_try_install python3-flask; }

  mkdir -p "$WEBPANEL_DIR"

  local PANEL_IP HTTPS PORT USERNAME PASSWORD_HASH CERT_FILE KEY_FILE
  PANEL_IP=""
  HTTPS=""
  PORT=""
  USERNAME=""
  PASSWORD_HASH=""
  CERT_FILE=""
  KEY_FILE=""
  if [[ -f "$WEBPANEL_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$WEBPANEL_ENV"
  fi

  local detected; detected="$(get_public_ip)"
  read -r -p "Panel IP (Enter to auto-detect: ${detected:-unknown}): " ip_in < /dev/tty
  local panel_ip="${ip_in:-${detected:-$PANEL_IP}}"

  read -r -p "Enable HTTPS with a self-signed cert? (y/n, default n): " https_in < /dev/tty
  local https="false"; [[ "${https_in,,}" == "y" ]] && https="true"

  local port; port="$(gen_port)"
  local username; username="$(gen_username)"
  local password; password="$(gen_password)"
  local phash; phash="$(hash_password "$password")"

  local cert_file key_file
  cert_file=""
  key_file=""
  if [[ "$https" == "true" ]]; then
    local pair; pair="$(make_selfsigned_cert "$panel_ip")"
    cert_file="${pair%|*}"; key_file="${pair#*|}"
  fi

  write_webpanel_env "$panel_ip" "$https" "$port" "$username" "$phash" "$cert_file" "$key_file"

  write_webpanel_app
  write_webpanel_html

  # Clean up a leftover unit file from an older version that used a comma in the name
  rm -f "/etc/systemd/system/A,S-webpanel.service" 2>/dev/null || true

  cat > "$WEBPANEL_SERVICE" <<EOF
[Unit]
Description=A,S Tunnel Web Panel
After=network.target

[Service]
Type=simple
EnvironmentFile=$WEBPANEL_ENV
Environment=INSTALL_PATH=$INSTALL_PATH
ExecStart=/usr/bin/env python3 "$WEBPANEL_DIR/app.py"
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$WEBPANEL_UNIT" >/dev/null 2>&1 || true
  systemctl restart "$WEBPANEL_UNIT"

  local scheme="http"; [[ "$https" == "true" ]] && scheme="https"
  echo "" > "$TTY_OUT"
  echo -e "${CLR_GREEN}[+] Web panel is running.${CLR_RESET}" > "$TTY_OUT"
  echo -e "URL:      ${CLR_CYAN}${scheme}://${panel_ip:-<server-ip>}:${port}/${CLR_RESET}" > "$TTY_OUT"
  echo -e "Username: ${CLR_YELLOW}${username}${CLR_RESET}" > "$TTY_OUT"
  echo -e "Password: ${CLR_YELLOW}${password}${CLR_RESET}" > "$TTY_OUT"
  [[ "$https" == "true" ]] && echo -e "${CLR_DIM}Self-signed cert — your browser will warn once, that's expected.${CLR_RESET}" > "$TTY_OUT"
  echo -e "${CLR_DIM}The password is only shown now — write it down. Use menu 4/5 to change or reset it later.${CLR_RESET}" > "$TTY_OUT"
  echo -e "${CLR_DIM}Keep this URL/credentials private — equivalent to root access. Restrict the port with a firewall where possible.${CLR_RESET}" > "$TTY_OUT"
}

change_webpanel_credentials(){
  if [[ ! -f "$WEBPANEL_ENV" ]]; then echo "[-] Web panel not installed yet." > "$TTY_OUT"; return; fi
  local PANEL_IP HTTPS PORT USERNAME PASSWORD_HASH CERT_FILE KEY_FILE
  PANEL_IP=""
  HTTPS=""
  PORT=""
  USERNAME=""
  PASSWORD_HASH=""
  CERT_FILE=""
  KEY_FILE=""
  # shellcheck disable=SC1090
  source "$WEBPANEL_ENV"
  read -r -p "New username (Enter to keep '${USERNAME}'): " u < /dev/tty
  read -r -p "New password (Enter to auto-generate): " p < /dev/tty
  [[ -n "$u" ]] && USERNAME="$u"
  [[ -z "$p" ]] && p="$(gen_password)"
  PASSWORD_HASH="$(hash_password "$p")"
  write_webpanel_env "$PANEL_IP" "$HTTPS" "$PORT" "$USERNAME" "$PASSWORD_HASH" "$CERT_FILE" "$KEY_FILE"
  systemctl restart "$WEBPANEL_UNIT" >/dev/null 2>&1 || true
  echo "" > "$TTY_OUT"
  echo -e "${CLR_GREEN}[+] Credentials updated.${CLR_RESET}" > "$TTY_OUT"
  echo -e "Username: ${CLR_YELLOW}${USERNAME}${CLR_RESET}" > "$TTY_OUT"
  echo -e "Password: ${CLR_YELLOW}${p}${CLR_RESET}" > "$TTY_OUT"
}

reset_webpanel_credentials(){
  if [[ ! -f "$WEBPANEL_ENV" ]]; then echo "[-] Web panel not installed yet." > "$TTY_OUT"; return; fi
  local PANEL_IP HTTPS PORT USERNAME PASSWORD_HASH CERT_FILE KEY_FILE
  PANEL_IP=""
  HTTPS=""
  PORT=""
  USERNAME=""
  PASSWORD_HASH=""
  CERT_FILE=""
  KEY_FILE=""
  # shellcheck disable=SC1090
  source "$WEBPANEL_ENV"
  USERNAME="$(gen_username)"
  local p; p="$(gen_password)"
  PASSWORD_HASH="$(hash_password "$p")"
  write_webpanel_env "$PANEL_IP" "$HTTPS" "$PORT" "$USERNAME" "$PASSWORD_HASH" "$CERT_FILE" "$KEY_FILE"
  systemctl restart "$WEBPANEL_UNIT" >/dev/null 2>&1 || true
  echo "" > "$TTY_OUT"
  echo -e "${CLR_GREEN}[+] Credentials reset.${CLR_RESET}" > "$TTY_OUT"
  echo -e "Username: ${CLR_YELLOW}${USERNAME}${CLR_RESET}" > "$TTY_OUT"
  echo -e "Password: ${CLR_YELLOW}${p}${CLR_RESET}" > "$TTY_OUT"
}

disable_webpanel(){
  systemctl stop "$WEBPANEL_UNIT" >/dev/null 2>&1 || true
  systemctl disable "$WEBPANEL_UNIT" >/dev/null 2>&1 || true
  echo "[+] Web panel stopped and disabled (config kept)." > "$TTY_OUT"
}

uninstall_webpanel(){
  read -r -p "This removes the web panel completely (service, files, certs, credentials). Continue? (y/n): " c < /dev/tty
  [[ "${c,,}" == "y" ]] || { echo "Cancelled." > "$TTY_OUT"; return; }
  systemctl stop "$WEBPANEL_UNIT" >/dev/null 2>&1 || true
  systemctl disable "$WEBPANEL_UNIT" >/dev/null 2>&1 || true
  rm -f "$WEBPANEL_SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/A,S-webpanel.service" 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf "$WEBPANEL_DIR" 2>/dev/null || true
  rm -f "$WEBPANEL_ENV" 2>/dev/null || true
  echo "[+] Web panel fully removed." > "$TTY_OUT"
}

show_webpanel_info(){
  if [[ ! -f "$WEBPANEL_ENV" ]]; then echo "[-] Web panel not installed yet." > "$TTY_OUT"; return; fi
  local PANEL_IP HTTPS PORT USERNAME PASSWORD_HASH CERT_FILE KEY_FILE
  PANEL_IP=""
  HTTPS=""
  PORT=""
  USERNAME=""
  PASSWORD_HASH=""
  CERT_FILE=""
  KEY_FILE=""
  # shellcheck disable=SC1090
  source "$WEBPANEL_ENV"
  local active="inactive"
  systemctl is-active --quiet "$WEBPANEL_UNIT" && active="active"
  local scheme="http"; [[ "$HTTPS" == "true" ]] && scheme="https"
  echo -e "Status:   ${active}" > "$TTY_OUT"
  echo -e "URL:      ${scheme}://${PANEL_IP:-<server-ip>}:${PORT}/" > "$TTY_OUT"
  echo -e "Username: ${USERNAME}" > "$TTY_OUT"
  echo -e "${CLR_DIM}(Password is stored hashed — use menu 4/5 to set a new one if forgotten.)${CLR_RESET}" > "$TTY_OUT"
}

webpanel_menu(){
  while true; do
    echo "" > "$TTY_OUT"
    echo -e "${CLR_DIM}┌───────────────────────────────────────┐${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_BOLD}🌐 Web Panel${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}├───────────────────────────────────────┤${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}1${CLR_RESET}) Install / Reconfigure" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}2${CLR_RESET}) Disable" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}3${CLR_RESET}) Show URL & Username" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}4${CLR_RESET}) Change username/password" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}5${CLR_RESET}) Reset to random credentials" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_RED}6${CLR_RESET}) Uninstall web panel  ${CLR_DIM}(remove everything)${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_DIM}0) Back${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}└───────────────────────────────────────┘${CLR_RESET}" > "$TTY_OUT"
    read -r -p "Select: " c < /dev/tty
    case "$c" in
      1) install_webpanel || true; pause ;;
      2) disable_webpanel || true; pause ;;
      3) show_webpanel_info || true; pause ;;
      4) change_webpanel_credentials || true; pause ;;
      5) reset_webpanel_credentials || true; pause ;;
      6) uninstall_webpanel || true; pause ;;
      0) return ;;
      *) echo "Invalid." > "$TTY_OUT" ;;
    esac
  done
}

print_banner(){
  local loc dc inst
  loc="$(get_location_string)"
  dc="$(get_datacenter_string)"
  inst="${CLR_RED}NOT INSTALLED${CLR_RESET}"
  if is_installed; then inst="${CLR_GREEN}INSTALLED${CLR_RESET}"; fi

  echo -e "${CLR_CYAN}${CLR_BOLD}"
  if have figlet; then
    figlet -f slant "$APP_NAME" 2>/dev/null || figlet "$APP_NAME" 2>/dev/null || true
  else
    echo "$APP_NAME"
  fi
  echo -e "${CLR_RESET}"

  echo -e "${CLR_GREEN}Version:${CLR_RESET} v${VERSION}"
  echo -e "${CLR_GREEN}GitHub:${CLR_RESET} ${GITHUB_REPO}"
  echo -e "${CLR_GREEN}Telegram ID:${CLR_RESET} ${TG_ID}"
  echo -e "${CLR_DIM}============================================================${CLR_RESET}"
  echo -e "${CLR_CYAN}Location:${CLR_RESET} ${loc}"
  echo -e "${CLR_CYAN}Datacenter:${CLR_RESET} ${dc}"
  echo -e "${CLR_CYAN}Script:${CLR_RESET} ${inst}"
  echo -e "${CLR_DIM}============================================================${CLR_RESET}"
}

manage_slot_menu(){
  local prof="$1"
  while true; do
    local st="${CLR_RED}● OFF${CLR_RESET}"; is_running "$prof" 2>/dev/null && st="${CLR_GREEN}● ON${CLR_RESET}"
    local rc; rc="$(get_slot_restart_hours "$prof")"
    local rc_label="${CLR_DIM}off${CLR_RESET}"; [[ -n "$rc" ]] && rc_label="${CLR_GREEN}every ${rc}h${CLR_RESET}"
    echo "" > "$TTY_OUT"
    echo -e "${CLR_DIM}┌───────────────────────────────────────────┐${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_YELLOW}${CLR_BOLD}${prof}${CLR_RESET}  ${CLR_DIM}[$(get_method "$prof")]${CLR_RESET}  ${st}" > "$TTY_OUT"
    echo -e "${CLR_DIM}├───────────────────────────────────────────┤${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}1${CLR_RESET}) 📄 Show profile" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}2${CLR_RESET}) ▶️  Start" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}3${CLR_RESET}) ⏹  Stop" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}4${CLR_RESET}) 🔁 Restart" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}5${CLR_RESET}) 📊 Status" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}6${CLR_RESET}) 📜 Live log  ${CLR_DIM}(Ctrl+C to exit)${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}8${CLR_RESET}) ⏱  Scheduled restart  ${CLR_DIM}(${rc_label}${CLR_DIM})${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}9${CLR_RESET}) ✏️  Change config" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_RED}7${CLR_RESET}) 🗑  Delete slot" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_DIM}0) ↩ Back${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}└───────────────────────────────────────────┘${CLR_RESET}" > "$TTY_OUT"
    read -r -p "Select: " c < /dev/tty
    case "$c" in
      1) cat "$CONF/${prof}.env" 2>/dev/null > "$TTY_OUT" || echo "Profile not found." > "$TTY_OUT"; pause ;;
      2) run_slot "$prof" || true; pause ;;
      3) stop_slot "$prof" || true; pause ;;
      4) restart_slot "$prof" || true; pause ;;
      5) status_slot "$prof" || true; pause ;;
      6) logs_slot "$prof" || true ;;
      7) delete_slot "$prof" || true; pause ;;
      8) schedule_restart_menu "$prof" || true; pause ;;
      9) change_config_menu "$prof" || true; pause ;;
      0) return ;;
      *) echo "Invalid." > "$TTY_OUT" ;;
    esac
  done
}

schedule_restart_menu(){
  local prof="$1" cur; cur="$(get_slot_restart_hours "$prof")"
  echo "" > "$TTY_OUT"
  if [[ -n "$cur" ]]; then
    echo -e "Current: restarts automatically every ${CLR_GREEN}${cur}h${CLR_RESET}, regardless of status." > "$TTY_OUT"
  else
    echo -e "Current: ${CLR_DIM}no scheduled restart${CLR_RESET}" > "$TTY_OUT"
  fi
  echo "1) Enable / update interval" > "$TTY_OUT"
  echo "2) Disable" > "$TTY_OUT"
  read -r -p "Select: " c < /dev/tty
  case "$c" in
    1)
      read -r -p "Restart every N hours (default 6): " h < /dev/tty
      h="${h:-6}"
      set_slot_restart_cron "$prof" "$h" || true
      echo "[+] ${prof} will restart every ${h}h." > "$TTY_OUT"
      ;;
    2)
      clear_slot_restart_cron "$prof" || true
      echo "[+] Scheduled restart disabled for ${prof}." > "$TTY_OUT"
      ;;
    *) echo "Invalid." > "$TTY_OUT" ;;
  esac
}

# ===================== Non-interactive API (used by the web panel) =====================
# Every action here reuses the exact same functions as the interactive menu
# (run_slot/stop_slot/get_method/is_running/...), so the CLI and the web
# panel are always reading and writing the same profile files — there is
# only one source of truth, never two copies of the logic.

json_str(){ printf '%s' "$1" | jq -Rs .; }
api_json_field(){ printf '"%s":%s' "$1" "$(json_str "$2")"; }
valid_prof(){ [[ "$1" =~ ^(eu|iran)([1-9]|10)$ ]]; }

api_list(){
  echo "["
  local first=1 role i prof f m running
  for role in eu iran; do
    for i in $(seq 1 "$MAX"); do
      prof="${role}${i}"; f="$CONF/${prof}.env"
      [[ -f "$f" ]] || continue
      m="$(get_method "$prof")"
      running=false; is_running "$prof" 2>/dev/null && running=true
      [[ $first -eq 1 ]] || echo ","
      first=0
      printf '{%s,%s,%s,"running":%s,"slot":%s}' \
        "$(api_json_field prof "$prof")" "$(api_json_field role "$role")" \
        "$(api_json_field method "$m")" "$running" "$i"
    done
  done
  echo ""; echo "]"
}

api_get(){
  local prof f m running rc first k v
  prof="$1"
  f="$CONF/${prof}.env"
  valid_prof "$prof" || { echo '{"error":"bad_slot"}'; return 1; }
  [[ -f "$f" ]] || { echo '{"error":"not_found"}'; return 1; }
  m="$(get_method "$prof")"
  running=false; if is_running "$prof" 2>/dev/null; then running=true; fi
  rc="$(get_slot_restart_hours "$prof")"
  printf '{%s,%s,"running":%s,%s,"fields":{' "$(api_json_field prof "$prof")" "$(api_json_field method "$m")" "$running" "$(api_json_field restart_hours "$rc")"
  first=1
  while IFS='=' read -r k _; do
    [[ -n "$k" ]] || continue
    if [[ "$k" == "METHOD" || "$k" == "ROLE" ]]; then continue; fi
    # value comes from *sourcing* the profile, so %q-escaping written by api_save is undone
    # (reading the raw text would show backslashes and double-escape them on the next save)
    v="$(env_get "$prof" "$k")"
    if [[ $first -eq 0 ]]; then printf ','; fi
    first=0
    printf '%s' "$(api_json_field "$k" "$v")"
  done < "$f"
  echo "}}"
}

api_save(){
  local prof f role
  prof="$1"
  f="$CONF/${prof}.env"
  role="${prof%%[0-9]*}"
  valid_prof "$prof" || { echo '{"error":"bad_slot"}'; return 1; }
  local body; body="$(cat)"
  local method; method="$(printf '%s' "$body" | jq -r '.method // empty' 2>/dev/null)"
  [[ -n "$method" ]] || { echo '{"error":"missing_method"}'; return 1; }

  local allowed=""
  case "$method" in
    asnative) allowed="IRAN_IP BRIDGE SYNC AUTO_SYNC PORTS" ;;
    backhaul) allowed="BH_ROLE TOKEN TRANSPORT BIND_PORT FORWARD_PORTS SERVER_IP" ;;
    rathole)  allowed="RT_ROLE TOKEN BIND_PORT FORWARD_PORTS SERVER_IP" ;;
    gre)      allowed="LOCAL_IP PEER_IP SELF_TUN_IP PEER_TUN_IP" ;;
    frp)      allowed="FRP_ROLE TOKEN BIND_PORT SERVER_IP FORWARD_PORTS" ;;
    gost)     allowed="DEST_IP PORT_MODE PORTS RANGE_START RANGE_END PROTO" ;;
    paqet)    allowed="PQ_ROLE SECRET_KEY SERVER_IP SERVER_PORT KCP_MODE CONN MTU BLOCK FORWARD_PORTS FORWARD_UDP_PORTS SOCKS5_PORT SOCKS5_USER SOCKS5_PASS ROUTER_MAC" ;;
    *) echo '{"error":"bad_method"}'; return 1 ;;
  esac

  {
    echo "METHOD=$method"
    echo "ROLE=$role"
    local k v
    for k in $allowed; do
      v="$(printf '%s' "$body" | jq -r --arg k "$k" '.fields[$k] // empty' 2>/dev/null)"
      [[ -n "$v" ]] || continue
      printf '%s=%q\n' "$k" "$v"   # %q: safely shell-quoted, so later `source` can never execute injected input
    done
  } > "$f"

  if [[ "$method" == "gre" ]] && ! grep -q '^SELF_TUN_IP=' "$f"; then
    if [[ "$role" == "eu" ]]; then printf 'SELF_TUN_IP=10.10.10.1\nPEER_TUN_IP=10.10.10.2\n' >> "$f"
    else printf 'SELF_TUN_IP=10.10.10.2\nPEER_TUN_IP=10.10.10.1\n' >> "$f"; fi
  fi

  local log ok running
  log="$(run_slot "$prof" 2>&1)" && ok=0 || ok=$?
  running=false; if is_running "$prof"; then running=true; fi
  # "saved":true — the config is on disk no matter whether the start succeeded
  if [[ $ok -eq 0 ]]; then
    printf '{"ok":true,"saved":true,"running":%s}\n' "$running"
  else
    printf '{"ok":false,"saved":true,"running":%s,"log":%s}\n' "$running" "$(json_str "$log")"
  fi
}

api_simple(){
  local action prof
  action="$1"
  prof="$2"
  valid_prof "$prof" || { echo '{"error":"bad_slot"}'; return 1; }
  [[ -f "$CONF/${prof}.env" ]] || { echo '{"error":"not_found"}'; return 1; }
  local log ok
  log="$("${action}_slot" "$prof" 2>&1)" && ok=0 || ok=$?
  local running=false
  if is_running "$prof" 2>/dev/null; then running=true; fi
  if [[ $ok -eq 0 ]]; then printf '{"ok":true,"running":%s}\n' "$running"; else printf '{"ok":false,"running":%s,"log":%s}\n' "$running" "$(json_str "$log")"; fi
}

api_status(){
  local prof="$1"
  valid_prof "$prof" || { echo '{"error":"bad_slot"}'; return 1; }
  [[ -f "$CONF/${prof}.env" ]] || { echo '{"error":"not_found"}'; return 1; }
  local m; m="$(get_method "$prof")"
  local running=false; is_running "$prof" 2>/dev/null && running=true
  printf '{%s,%s,"running":%s}\n' "$(api_json_field prof "$prof")" "$(api_json_field method "$m")" "$running"
}

api_logs(){
  local prof n m lf out tmpf sn running
  prof="$1"; n="${2:-300}"
  valid_prof "$prof" || { echo '{"error":"bad_slot"}'; return 1; }
  [[ "$n" =~ ^[0-9]+$ ]] || n=300
  if [[ "$n" -gt 5000 ]]; then n=5000; fi
  m="$(get_method "$prof")"
  lf="$(log_file "$prof")"
  out=""
  if [[ "$m" == "gre" ]]; then
    out="$(ip -s link show "gre${prof}" 2>&1 || true)"
  fi
  if [[ -f "$lf" ]]; then
    if [[ -n "$out" ]]; then out+=$'\n\n'; fi
    out+="$(tail -n "$n" "$lf" 2>/dev/null || true)"
  elif [[ "$m" != "gre" ]]; then
    sn="$(session_name "$prof")"; tmpf="$(mktemp)"
    screen -S "$sn" -X hardcopy "$tmpf" >/dev/null 2>&1 || true
    out="$(cat "$tmpf" 2>/dev/null || true)"
    rm -f "$tmpf"
  fi
  running=false; if is_running "$prof" 2>/dev/null; then running=true; fi
  printf '{"logs":%s,"running":%s}\n' "$(json_str "$out")" "$running"
}

api_hc(){
  if [[ "$1" == "on" ]]; then
    install_healthcheck_script
    local interval="${2:-1}"; [[ "$interval" =~ ^[0-9]+$ ]] || interval=1; [[ "$interval" -lt 1 ]] && interval=1
    local line="*/$interval * * * * ${HC_SCRIPT} >/dev/null 2>&1 ${HC_CRON_TAG}"
    local tmp; tmp="$(mktemp)"
    (crontab -l 2>/dev/null || true) | grep -vF "${HC_CRON_TAG}" >"$tmp" || true
    echo "$line" >>"$tmp"; crontab "$tmp"; rm -f "$tmp"
  else
    disable_cron_healthcheck >/dev/null 2>&1 || true
  fi
  echo '{"ok":true}'
}

api_restartcron(){
  local prof onoff hours
  prof="$1"
  onoff="$2"
  hours="${3:-6}"
  valid_prof "$prof" || { echo '{"error":"bad_slot"}'; return 1; }
  [[ -f "$CONF/${prof}.env" ]] || { echo '{"error":"not_found"}'; return 1; }
  if [[ "$onoff" == "on" ]]; then
    set_slot_restart_cron "$prof" "$hours"
  else
    clear_slot_restart_cron "$prof"
  fi
  echo '{"ok":true}'
}

api_optimize(){ local out; out="$(optimize_server 2>&1)"; printf '{"log":%s}\n' "$(json_str "$out")"; }

api_info(){
  local loc dc; loc="$(get_location_string)"; dc="$(get_datacenter_string)"
  printf '{%s,%s,%s}\n' "$(api_json_field version "$VERSION")" "$(api_json_field location "$loc")" "$(api_json_field datacenter "$dc")"
}

# ===================== Main =====================
need_root
ensure

if [[ "${1:-}" == "--api" ]]; then
  shift
  sub="${1:-}"; shift || true
  case "$sub" in
    list)     api_list ;;
    get)      api_get "${1:-}" ;;
    save)     api_save "${1:-}" ;;
    start)    api_simple run "${1:-}" ;;
    stop)     api_simple stop "${1:-}" ;;
    restart)  api_simple restart "${1:-}" ;;
    delete)   api_simple delete "${1:-}" ;;
    status)   api_status "${1:-}" ;;
    logs)     api_logs "${1:-}" "${2:-300}" ;;
    hc)       api_hc "${1:-off}" "${2:-1}" ;;
    restartcron) api_restartcron "${1:-}" "${2:-off}" "${3:-6}" ;;
    optimize) api_optimize ;;
    info)     api_info ;;
    *) echo '{"error":"unknown_command"}' ;;
  esac
  exit 0
fi

# Internal entry point used by the cron health-check (see install_healthcheck_script).
if [[ "${1:-}" == "--healthcheck" ]]; then
  for role in eu iran; do
    for i in $(seq 1 "$MAX"); do
      prof="${role}${i}"
      [[ -f "$CONF/${prof}.env" ]] || continue
      is_running "$prof" || run_slot "$prof" >/dev/null 2>&1 || true
    done
  done
  exit 0
fi

while true; do
  clear || true
  print_banner

  echo -e "${CLR_DIM}┌────────────────────────────────────────────────────┐${CLR_RESET}"
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_BOLD}TUNNELS${CLR_RESET}"
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_WHITE}${CLR_BOLD}1${CLR_RESET}) 🛠  Create/Update profile"
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_WHITE}${CLR_BOLD}2${CLR_RESET}) 🎛  Manage tunnel  ${CLR_DIM}(start/stop/status/logs)${CLR_RESET}"
  echo -e "${CLR_DIM}│${CLR_RESET}"
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_BOLD}RELIABILITY${CLR_RESET}"
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_WHITE}${CLR_BOLD}3${CLR_RESET}) ✅ Enable cron health-check"
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_WHITE}${CLR_BOLD}4${CLR_RESET}) ❌ Disable cron health-check"
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_WHITE}${CLR_BOLD}8${CLR_RESET}) 🚀 Optimize server  ${CLR_DIM}(BBR + sysctl)${CLR_RESET}"
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_WHITE}${CLR_BOLD}9${CLR_RESET}) 🌐 Web panel  ${CLR_DIM}(glass dashboard)${CLR_RESET}"
  echo -e "${CLR_DIM}│${CLR_RESET}"
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_BOLD}SCRIPT${CLR_RESET}"
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_WHITE}${CLR_BOLD}5${CLR_RESET}) 📦 Install script  ${CLR_DIM}(system-wide)${CLR_RESET}"
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_WHITE}${CLR_BOLD}6${CLR_RESET}) 🔄 Update script   ${CLR_DIM}(self-update)${CLR_RESET}"
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_WHITE}${CLR_BOLD}7${CLR_RESET}) 🗑  Uninstall script"
  echo -e "${CLR_DIM}│${CLR_RESET}"
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_RED}${CLR_BOLD}0${CLR_RESET}) 🚪 Exit"
  echo -e "${CLR_DIM}└────────────────────────────────────────────────────┘${CLR_RESET}"

  read -r -p "Select: " c < /dev/tty
  case "$c" in
    1) role="$(pick_role)"; prof="$(pick_slot "$role")"; edit_profile "$prof" || true; pause ;;
    2) role="$(pick_role)"; prof="$(pick_slot "$role")"; manage_slot_menu "$prof" || true ;;
    3) enable_cron_healthcheck || true; pause ;;
    4) disable_cron_healthcheck || true; pause ;;
    5) install_script || true; pause ;;
    6) update_script || true; pause ;;
    7) uninstall_script || true; pause ;;
    8) optimize_server || true; pause ;;
    9) webpanel_menu || true ;;
    0) exit 0 ;;
    *) echo "Invalid."; sleep 1 ;;
  esac
done
