#!/usr/bin/env bash
set -euo pipefail

APP_NAME="A,S"
TG_ID="@Asnejad"
VERSION="4.0.0"

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
case "${1:-}" in --api|--healthcheck|--join|--agent-refresh|--panel-refresh|--refresh-services) TTY_OUT="/dev/stderr" ;; esac

LOG_DIR="/var/log/A,S"

# Every key a profile may contain (reset before each load so one profile's
# values can never leak into the next one).
PROFILE_KEYS="METHOD ROLE IRAN_IP BRIDGE SYNC AUTO_SYNC PORTS BH_ROLE TOKEN TRANSPORT BIND_PORT FORWARD_PORTS SERVER_IP RT_ROLE LOCAL_IP PEER_IP SELF_TUN_IP PEER_TUN_IP FRP_ROLE DEST_IP PORT_MODE RANGE_START RANGE_END PROTO PQ_ROLE SECRET_KEY SERVER_PORT KCP_MODE CONN MTU BLOCK FORWARD_UDP_PORTS SOCKS5_PORT SOCKS5_USER SOCKS5_PASS ROUTER_MAC"

HC_SCRIPT="/usr/local/bin/A,S-health-check"
HC_CRON_TAG="# A,STunnelHealthCheck"

WEBPANEL_DIR="/opt/A,S/webpanel"
WEBPANEL_ENV="$BASE/webpanel.env"
WEBPANEL_UNIT="AS-webpanel"
WEBPANEL_SERVICE="/etc/systemd/system/${WEBPANEL_UNIT}.service"
MASTER_DIR="$BASE/master"
AGENT_UNIT="AS-agent"
AGENT_SERVICE="/etc/systemd/system/${AGENT_UNIT}.service"
AGENT_CFG="$BASE/agent.json"
DEPLOY_STAMP="$BASE/.deployed_version"

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

# Profiles — each tunnel is identified by a name the user picks (like the
# Paqet/Backhaul manager scripts), not a fixed numbered slot.

clean_profile_name(){
  local n
  n="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
  n="${n:0:32}"
  echo "${n:-tunnel}"
}

list_profiles(){
  local f
  shopt -s nullglob
  for f in "$CONF"/*.env; do basename "$f" .env; done | sort
  shopt -u nullglob
}

get_role(){
  local f r
  f="$CONF/$1.env"
  [[ -f "$f" ]] || { echo "iran"; return; }
  r="$(grep -m1 '^ROLE=' "$f" | cut -d= -f2- || true)"
  echo "${r:-iran}"
}

# Internal value stays eu/iran (eu = abroad/kharej side) so every existing
# ROLE check keeps working; only the wording shown to the user changes.
pick_side(){
  local x
  while true; do
    echo "" > "$TTY_OUT"
    echo -e "${CLR_DIM}┌─────────────────────────────────────────────┐${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_BOLD}Server or Client?${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}├─────────────────────────────────────────────┤${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}1${CLR_RESET}) 🌍 Server  ${CLR_DIM}(Abroad / Kharej)${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}2${CLR_RESET}) 🇮🇷 Client  ${CLR_DIM}(Iran)${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}└─────────────────────────────────────────────┘${CLR_RESET}" > "$TTY_OUT"
    read -r -p "Select: " x < /dev/tty
    if [[ "$x" == "1" ]]; then echo "eu"; return 0; fi
    if [[ "$x" == "2" ]]; then echo "iran"; return 0; fi
    echo -e "${CLR_RED}Invalid.${CLR_RESET}" > "$TTY_OUT"
  done
}

role_badge(){
  if [[ "$1" == "eu" ]]; then echo "🌍 Server (Abroad)"; else echo "🇮🇷 Client (Iran)"; fi
}

prompt_tunnel_name(){
  local raw name ow
  while true; do
    read -r -p "Tunnel name (e.g. server1, myclient): " raw < /dev/tty
    name="$(clean_profile_name "$raw")"
    if [[ -f "$CONF/${name}.env" ]]; then
      read -r -p "A tunnel named '${name}' already exists. Overwrite? (y/n): " ow < /dev/tty
      [[ "${ow,,}" == "y" ]] || continue
    fi
    echo "$name"
    return 0
  done
}

# ===================== Tunnel method selection =====================

edit_profile(){
  local prof f role
  prof="$1"
  f="$CONF/${prof}.env"
  role="$(pick_side)"
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
  bhr="1"; [[ "$role" == "iran" ]] && bhr="2"
  echo -e "${CLR_DIM}Role: $(role_badge "$role")${CLR_RESET}" > "$TTY_OUT"
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
  rtr="1"; [[ "$role" == "iran" ]] && rtr="2"
  echo -e "${CLR_DIM}Role: $(role_badge "$role")${CLR_RESET}" > "$TTY_OUT"
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
  fr="1"; [[ "$role" == "iran" ]] && fr="2"
  echo -e "${CLR_DIM}Role: $(role_badge "$role")${CLR_RESET}" > "$TTY_OUT"
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
  pqr="1"; [[ "$role" == "iran" ]] && pqr="2"
  echo -e "${CLR_DIM}Role: $(role_badge "$role")${CLR_RESET}" > "$TTY_OUT"
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

write_webpanel_core(){
  mkdir -p "$WEBPANEL_DIR"
  cat > "$WEBPANEL_DIR/asnode.py" <<'ASNODE_EOF'
#!/usr/bin/env python3
"""A,S Tunnel — shared helpers used by the master panel (app.py) and the node agent (agent.py).

Everything that touches the server goes through the installed script's `--api`
interface, so the CLI menu, the panel and remote nodes always see the same state.
"""
import json
import os
import re
import shlex
import shutil
import signal
import socket
import subprocess
import threading
import time
import urllib.request

INSTALL_PATH = os.environ.get("INSTALL_PATH", "/usr/local/bin/A,S-tunnel")
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
HOST_RE = re.compile(r"^(?:[A-Za-z0-9](?:[A-Za-z0-9.-]{0,250}[A-Za-z0-9])?|[0-9A-Fa-f:]{2,45})$")


def load_env(path):
    """Parse KEY='value' files written by the shell script (shell-quoted values)."""
    out = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                try:
                    parts = shlex.split(v, posix=True)
                    out[k.strip()] = parts[0] if parts else ""
                except ValueError:
                    out[k.strip()] = v.strip().strip("'\"")
    except OSError:
        pass
    return out


def run_api(args, stdin_data=None, timeout=180):
    if not os.path.isfile(INSTALL_PATH):
        return {"error": "script_not_installed",
                "hint": "Run the script once (menu option: Install script) so %s exists." % INSTALL_PATH}
    try:
        p = subprocess.run([INSTALL_PATH, "--api"] + [str(a) for a in args], input=stdin_data,
                           capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"error": "timeout"}
    except Exception as e:  # pragma: no cover
        return {"error": str(e)}
    out = (p.stdout or "").strip()
    if not out:
        return {"error": "empty_response", "stderr": (p.stderr or "")[-500:]}
    try:
        return json.loads(out)
    except ValueError:
        for line in reversed(out.splitlines()):
            try:
                return json.loads(line)
            except ValueError:
                continue
        return {"error": "bad_response", "raw": out[-500:]}


# ----------------------------------------------------------------- metrics
_cpu_lock = threading.Lock()
_cpu_prev = None
_cpu_last = (0.0, 0.0)


def _read_cpu():
    with open("/proc/stat") as f:
        vals = [int(x) for x in f.readline().split()[1:]]
    idle = vals[3] + (vals[4] if len(vals) > 4 else 0)
    return sum(vals), idle


def cpu_percent():
    global _cpu_prev, _cpu_last
    with _cpu_lock:
        now = time.time()
        if now - _cpu_last[0] < 1.0:
            return _cpu_last[1]
        try:
            tot, idle = _read_cpu()
            if _cpu_prev is None:
                _cpu_prev = (tot, idle)
                time.sleep(0.25)
                tot, idle = _read_cpu()
        except Exception:
            return 0.0
        dt, di = tot - _cpu_prev[0], idle - _cpu_prev[1]
        pct = 0.0 if dt <= 0 else max(0.0, min(100.0, (1.0 - di / dt) * 100.0))
        _cpu_prev = (tot, idle)
        _cpu_last = (now, round(pct, 1))
        return _cpu_last[1]


def mem_info():
    d = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, _, v = line.partition(":")
            parts = v.split()
            if parts:
                d[k] = int(parts[0]) * 1024
    total = d.get("MemTotal", 0)
    avail = d.get("MemAvailable", d.get("MemFree", 0))
    return max(0, total - avail), total


def metrics():
    try:
        used, total = mem_info()
    except Exception:
        used, total = 0, 0
    try:
        with open("/proc/uptime") as f:
            up = int(float(f.read().split()[0]))
    except Exception:
        up = 0
    try:
        load = [round(x, 2) for x in os.getloadavg()]
    except Exception:
        load = [0, 0, 0]
    return {"cpu": cpu_percent(), "ram_used": used, "ram_total": total,
            "ram_pct": round(used * 100.0 / total, 1) if total else 0.0,
            "uptime": up, "load": load}


# ------------------------------------------------------------ identity bits
_ip_cache = {"v": "", "t": 0.0, "busy": False}


def local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("203.0.113.1", 9))
        return s.getsockname()[0]
    except Exception:
        return ""
    finally:
        s.close()


def _refresh_ip():
    try:
        for url in ("https://api.ipify.org", "https://ifconfig.me/ip", "https://icanhazip.com"):
            try:
                req = urllib.request.Request(url, headers={"User-Agent": "A,S-tunnel"})
                with urllib.request.urlopen(req, timeout=3) as r:
                    v = r.read().decode().strip()
                if re.match(r"^[0-9A-Fa-f:.]{3,45}$", v):
                    _ip_cache["v"], _ip_cache["t"] = v, time.time()
                    return
            except Exception:
                continue
        _ip_cache["t"] = time.time() - 540  # nothing worked: retry in ~1 minute
    finally:
        _ip_cache["busy"] = False


def public_ip():
    """Cached public IP; refreshes in the background so callers never block."""
    now = time.time()
    if not _ip_cache["v"]:
        _ip_cache["v"] = local_ip()
        _ip_cache["t"] = now - 590
    if now - _ip_cache["t"] > 600 and not _ip_cache["busy"]:
        _ip_cache["busy"] = True
        threading.Thread(target=_refresh_ip, daemon=True).start()
    return _ip_cache["v"]


def script_version(path=None):
    try:
        with open(path or INSTALL_PATH, encoding="utf-8", errors="replace") as f:
            for _ in range(40):
                m = re.match(r'^VERSION="([^"]+)"', f.readline())
                if m:
                    return m.group(1)
    except OSError:
        pass
    return "?"


# ------------------------------------------------------------- net tools
def ensure_pkg(binary, apt_name):
    if shutil.which(binary):
        return True
    env = dict(os.environ, DEBIAN_FRONTEND="noninteractive")
    for cmd in (["apt-get", "update", "-y"], ["apt-get", "install", "-y", apt_name]):
        try:
            subprocess.run(cmd, env=env, capture_output=True, timeout=240)
        except Exception:
            pass
    return bool(shutil.which(binary))


def ping_host(target, count=3):
    target = str(target or "").strip()
    if not HOST_RE.match(target):
        return {"error": "bad_target"}
    try:
        count = max(1, min(10, int(count)))
    except (TypeError, ValueError):
        count = 3
    if not ensure_pkg("ping", "iputils-ping"):
        return {"error": "ping_not_available"}
    try:
        p = subprocess.run(["ping", "-n", "-c", str(count), "-W", "2", target],
                           capture_output=True, text=True, timeout=count * 3 + 5)
        out = p.stdout or ""
    except subprocess.TimeoutExpired:
        out = ""
    samples = [float(x) for x in re.findall(r"time[=<]([\d.]+)\s*ms", out)]
    m = re.search(r"(\d+(?:\.\d+)?)% packet loss", out)
    loss = float(m.group(1)) if m else (0.0 if samples else 100.0)
    res = {"ok": True, "target": target, "loss": loss, "samples": samples}
    if samples:
        res.update(min=round(min(samples), 2), avg=round(sum(samples) / len(samples), 2),
                   max=round(max(samples), 2))
    return res


_iperf = {"proc": None}
_iperf_lock = threading.Lock()


def iperf_stop():
    with _iperf_lock:
        p = _iperf.get("proc")
        if p is not None and p.poll() is None:
            try:
                os.killpg(p.pid, signal.SIGTERM)
            except Exception:
                pass
        _iperf["proc"] = None
    return {"ok": True}


def iperf_server(port):
    try:
        port = int(port)
    except (TypeError, ValueError):
        return {"error": "bad_port"}
    if not 1024 <= port <= 65535:
        return {"error": "bad_port"}
    if not ensure_pkg("iperf3", "iperf3"):
        return {"error": "iperf3_not_available"}
    iperf_stop()
    with _iperf_lock:
        p = subprocess.Popen(["timeout", "150", "iperf3", "-s", "-p", str(port)],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        time.sleep(0.8)
        if p.poll() is not None:
            return {"error": "iperf_server_failed", "detail": "port %d may already be in use" % port}
        _iperf["proc"] = p
    return {"ok": True, "port": port}


def iperf_client(host, port, duration, parallel, reverse):
    host = str(host or "").strip()
    if not HOST_RE.match(host):
        return {"error": "bad_target"}
    try:
        port, duration, parallel = int(port), int(duration), int(parallel)
    except (TypeError, ValueError):
        return {"error": "bad_args"}
    duration = max(3, min(60, duration))
    parallel = max(1, min(16, parallel))
    if not 1024 <= port <= 65535:
        return {"error": "bad_port"}
    if not ensure_pkg("iperf3", "iperf3"):
        return {"error": "iperf3_not_available"}
    cmd = ["iperf3", "-c", host, "-p", str(port), "-t", str(duration), "-P", str(parallel), "-J"]
    if reverse:
        cmd.append("-R")
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=duration + 30)
    except subprocess.TimeoutExpired:
        return {"error": "iperf_failed", "detail": "timed out"}
    try:
        j = json.loads(p.stdout)
    except ValueError:
        return {"error": "iperf_failed", "detail": ((p.stdout or "") + (p.stderr or ""))[-300:]}
    if j.get("error"):
        return {"error": "iperf_failed", "detail": str(j["error"])}
    end = j.get("end", {})
    s, r = end.get("sum_sent", {}), end.get("sum_received", {})
    return {"ok": True, "reverse": bool(reverse),
            "sent_mbps": round(s.get("bits_per_second", 0) / 1e6, 2),
            "recv_mbps": round(r.get("bits_per_second", 0) / 1e6, 2),
            "retransmits": s.get("retransmits", 0)}


# ---------------------------------------------------------------- commands
def _prof(a):
    p = str(a.get("prof", ""))
    if not NAME_RE.match(p):
        raise ValueError("bad_name")
    return p


def execute(cmd, args=None):
    """Run one whitelisted command on THIS server. Never executes arbitrary shell."""
    a = args or {}
    try:
        if cmd == "list":
            return run_api(["list"], timeout=30)
        if cmd == "get":
            return run_api(["get", _prof(a)], timeout=30)
        if cmd == "save":
            return run_api(["save", _prof(a)], stdin_data=json.dumps(a.get("body") or {}), timeout=300)
        if cmd in ("start", "stop", "restart", "delete"):
            return run_api([cmd, _prof(a)], timeout=300)
        if cmd == "logs":
            lines = str(a.get("lines", "300"))
            lines = lines if lines.isdigit() and 1 <= int(lines) <= 2000 else "300"
            return run_api(["logs", _prof(a), lines], timeout=30)
        if cmd == "restartcron":
            hours = str(a.get("hours", 6))
            hours = hours if hours.isdigit() else "6"
            return run_api(["restartcron", _prof(a), "on" if a.get("enabled") else "off", hours], timeout=30)
        if cmd == "hc":
            minutes = str(a.get("minutes", 1))
            minutes = minutes if minutes.isdigit() else "1"
            return run_api(["hc", "on" if a.get("enabled") else "off", minutes], timeout=30)
        if cmd == "optimize":
            return run_api(["optimize"], timeout=300)
        if cmd == "bulk":
            act = str(a.get("action", ""))
            if act not in ("start", "stop", "restart"):
                return {"error": "bad_action"}
            return run_api(["bulk", act], timeout=900)
        if cmd == "info":
            return run_api(["info"], timeout=60)
        if cmd == "nodeinfo":
            return run_api(["nodeinfo"], timeout=30)
        if cmd == "selfupdate":
            return run_api(["selfupdate"], timeout=240)
        if cmd == "ping":
            return ping_host(a.get("target"), a.get("count", 3))
        if cmd == "iperf_server":
            return iperf_server(a.get("port", 5201))
        if cmd == "iperf_stop":
            return iperf_stop()
        if cmd == "iperf_client":
            return iperf_client(a.get("host"), a.get("port", 5201), a.get("duration", 8),
                                a.get("parallel", 4), a.get("reverse", False))
    except ValueError as e:
        return {"error": str(e)}
    except Exception as e:  # pragma: no cover
        return {"error": "exec_failed", "detail": str(e)}
    return {"error": "unknown_command"}
ASNODE_EOF
  chmod 644 "$WEBPANEL_DIR/asnode.py"
}

write_webpanel_app(){
  mkdir -p "$WEBPANEL_DIR"
  cat > "$WEBPANEL_DIR/app.py" <<'APP_EOF'
#!/usr/bin/env python3
"""A,S Tunnel — master web panel.

One panel for the whole fleet: this server ("local") plus every node (Iran or
abroad) whose agent has joined with the join key. Nodes connect OUT to the
master; commands are relayed to them through a long-poll queue.
"""
import hashlib
import json
import logging
import os
import re
import secrets
import ssl
import sys
import threading
import time
import uuid
from collections import deque

from flask import Flask, Response, jsonify, request, send_from_directory
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer
from werkzeug.security import check_password_hash

APP_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, APP_DIR)
import asnode  # noqa: E402

ENV = asnode.load_env(os.environ.get("ENV_FILE", "/etc/A,S_manager/webpanel.env"))
PORT = int(ENV.get("PORT") or 8088)
USERNAME = ENV.get("USERNAME", "")
PASSWORD_HASH = ENV.get("PASSWORD_HASH", "")
HTTPS = ENV.get("HTTPS", "false") == "true"
CERT_FILE = ENV.get("CERT_FILE", "")
KEY_FILE = ENV.get("KEY_FILE", "")
PANEL_IP = ENV.get("PANEL_IP", "")
MASTER_ROLE = ENV.get("MASTER_ROLE", "eu") if ENV.get("MASTER_ROLE") in ("eu", "iran") else "eu"
SECRET_KEY = ENV.get("SECRET_KEY") or hashlib.sha256((PASSWORD_HASH or "x").encode()).hexdigest()
STATE_DIR = os.environ.get("STATE_DIR", "/etc/A,S_manager/master")
NODES_FILE = os.path.join(STATE_DIR, "nodes.json")
JOIN_FILE = os.path.join(STATE_DIR, "join.key")
ONLINE_SECS = 15
POLL_HOLD = 20
TOKEN_MAX_AGE = 12 * 3600

app = Flask(__name__, static_folder=None)
logging.getLogger("werkzeug").setLevel(logging.WARNING)
signer = URLSafeTimedSerializer(SECRET_KEY, salt="as-panel")

LOCK = threading.RLock()
COND = threading.Condition(LOCK)
NODES = {}      # node id -> node dict (runtime + persisted fields)
JOBS = {}       # job id  -> job dict
SETTINGS = {}   # network_name, local_name
SPEED_HISTORY = deque(maxlen=20)


# ------------------------------------------------------------ persistence
def _write_private(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def save_registry():
    with LOCK:
        data = {"settings": SETTINGS,
                "nodes": {nid: {k: n[k] for k in ("id", "name", "role", "token_hash", "created")}
                          for nid, n in NODES.items()}}
    _write_private(NODES_FILE, json.dumps(data, indent=2))


def new_node_runtime(base):
    base = dict(base)
    base.update(last_seen=0.0, remote_ip="", hello={}, metrics={}, tunnels=[],
                rtt=deque(maxlen=90), rtt_ms=None, queue=[])
    return base


def load_registry():
    try:
        with open(NODES_FILE, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        data = {}
    SETTINGS.update(data.get("settings") or {})
    for nid, n in (data.get("nodes") or {}).items():
        NODES[nid] = new_node_runtime(n)


def join_key():
    try:
        with open(JOIN_FILE, encoding="utf-8") as f:
            k = f.read().strip()
        if k:
            return k
    except OSError:
        pass
    return regenerate_join_key()


def regenerate_join_key():
    k = secrets.token_urlsafe(24)
    _write_private(JOIN_FILE, k + "\n")
    return k


def cert_fingerprint():
    try:
        if HTTPS and CERT_FILE and os.path.isfile(CERT_FILE):
            with open(CERT_FILE, encoding="utf-8") as f:
                der = ssl.PEM_cert_to_DER_cert(f.read())
            return hashlib.sha256(der).hexdigest()
    except Exception:
        pass
    return ""


def panel_url():
    return "%s://%s:%s" % ("https" if HTTPS else "http", PANEL_IP or asnode.public_ip(), PORT)


def clean_label(s, default=""):
    s = re.sub(r"[^\w .@-]", "", str(s or ""), flags=re.UNICODE).strip()[:40]
    return s or default


def unique_name(name, skip=None):
    taken = {n["name"] for nid, n in NODES.items() if nid != skip}
    taken.add(SETTINGS.get("local_name") or "")
    base, i, cand = name, 2, name
    while cand in taken:
        cand = "%s-%d" % (base, i)
        i += 1
    return cand


# -------------------------------------------------------------- auth
_fails = {}
_fails_lock = threading.Lock()


def pw_stamp():
    return hashlib.sha256((USERNAME + PASSWORD_HASH).encode()).hexdigest()[:16]


def check_token():
    h = request.headers.get("Authorization", "")
    if not h.startswith("Bearer "):
        return False
    try:
        data = signer.loads(h[7:], max_age=TOKEN_MAX_AGE)
    except (BadSignature, SignatureExpired):
        return False
    return data.get("u") == USERNAME and data.get("s") == pw_stamp()


def agent_node():
    n = NODES.get(request.headers.get("X-Node-Id", ""))
    tok = request.headers.get("X-Node-Token", "")
    if not n or not tok:
        return None
    if not secrets.compare_digest(hashlib.sha256(tok.encode()).hexdigest(), n["token_hash"]):
        return None
    return n


@app.before_request
def guard():
    p = request.path
    if not p.startswith("/api/") or p == "/api/login" or p.startswith("/api/agent/"):
        return None
    if not USERNAME or not PASSWORD_HASH or not check_token():
        return jsonify({"error": "unauthorized"}), 401
    return None


@app.after_request
def headers(resp):
    resp.headers["X-Content-Type-Options"] = "nosniff"
    resp.headers["Referrer-Policy"] = "no-referrer"
    if request.path.startswith("/api/") or request.path == "/":
        resp.headers["Cache-Control"] = "no-store"
    return resp


@app.get("/")
def index():
    return send_from_directory(APP_DIR, "index.html")


@app.post("/api/login")
def login():
    ip = request.remote_addr or "?"
    now = time.time()
    with _fails_lock:
        cnt, first = _fails.get(ip, (0, now))
        if now - first > 300:
            cnt, first = 0, now
        if cnt >= 8:
            return jsonify({"error": "too_many_attempts"}), 429
    body = request.get_json(force=True, silent=True) or {}
    ok = (secrets.compare_digest(str(body.get("username", "")), USERNAME)
          and bool(PASSWORD_HASH) and check_password_hash(PASSWORD_HASH, str(body.get("password", ""))))
    if not ok:
        with _fails_lock:
            _fails[ip] = (cnt + 1, first)
        return jsonify({"error": "bad_login"}), 401
    with _fails_lock:
        _fails.pop(ip, None)
    return jsonify({"token": signer.dumps({"u": USERNAME, "s": pw_stamp()}), "username": USERNAME})


@app.get("/api/me")
def me():
    return jsonify({"username": USERNAME})


# ------------------------------------------------------------ node views
_local_cache = {"t": 0.0, "v": []}
_local_lock = threading.Lock()


def local_tunnels(force=False):
    with _local_lock:
        if not force and time.time() - _local_cache["t"] < 3:
            return _local_cache["v"]
    res = asnode.run_api(["list"], timeout=30)
    v = res if isinstance(res, list) else []
    with _local_lock:
        _local_cache.update(t=time.time(), v=v)
    return v


def tunnel_counts(tunnels):
    t = tunnels if isinstance(tunnels, list) else []
    return len(t), sum(1 for x in t if isinstance(x, dict) and x.get("running"))


def local_role():
    r = SETTINGS.get("local_role")
    return r if r in ("eu", "iran") else MASTER_ROLE


def local_view():
    tun = local_tunnels()
    total, running = tunnel_counts(tun)
    return {"id": "local", "is_local": True, "name": SETTINGS.get("local_name") or os.uname().nodename,
            "role": local_role(), "online": True, "last_seen": 0, "remote_ip": "",
            "public_ip": asnode.public_ip(), "hostname": os.uname().nodename,
            "version": asnode.script_version(), "metrics": asnode.metrics(),
            "tunnels": tun, "tunnels_total": total, "tunnels_running": running,
            "rtt_ms": 0.0, "rtt_hist": []}


def node_view(n):
    now = time.time()
    total, running = tunnel_counts(n["tunnels"])
    hello = n.get("hello") or {}
    return {"id": n["id"], "is_local": False, "name": n["name"], "role": n["role"],
            "online": now - n["last_seen"] < ONLINE_SECS,
            "last_seen": round(now - n["last_seen"]) if n["last_seen"] else None,
            "remote_ip": n["remote_ip"], "public_ip": hello.get("public_ip") or n["remote_ip"],
            "hostname": hello.get("hostname", ""), "version": hello.get("version", "?"),
            "metrics": n["metrics"], "tunnels": n["tunnels"], "tunnels_total": total,
            "tunnels_running": running, "rtt_ms": n["rtt_ms"], "rtt_hist": list(n["rtt"])}


def master_view():
    return {"network": SETTINGS.get("network_name") or ENV.get("NETWORK_NAME") or "as-net",
            "version": asnode.script_version(), "url": panel_url(), "role": local_role(),
            "https": HTTPS, "username": USERNAME}


@app.get("/api/nodes")
def api_nodes():
    with LOCK:
        remote = [node_view(n) for n in NODES.values()]
    remote.sort(key=lambda x: x["name"].lower())
    return jsonify({"nodes": [local_view()] + remote, "master": master_view()})


@app.get("/api/master/join")
def api_join():
    return jsonify({"join_key": join_key(), "url": panel_url(), "fingerprint": cert_fingerprint(),
                    "https": HTTPS, "version": asnode.script_version()})


@app.post("/api/master/join/regenerate")
def api_join_regen():
    regenerate_join_key()
    return api_join()


@app.post("/api/master/settings")
def api_settings():
    body = request.get_json(force=True, silent=True) or {}
    if "network_name" in body:
        SETTINGS["network_name"] = clean_label(body["network_name"], "as-net")
    save_registry()
    return jsonify({"ok": True, "master": master_view()})


@app.delete("/api/nodes/<nid>")
def api_remove_node(nid):
    with COND:
        if nid not in NODES:
            return jsonify({"error": "node_not_found"}), 404
        NODES.pop(nid)
        COND.notify_all()
    save_registry()
    return jsonify({"ok": True})


# ------------------------------------------------------- command relay
def run_on_node(nid, cmd, args=None, timeout=60):
    if nid == "local":
        if cmd == "self_update":
            cmd = "selfupdate"
        res = asnode.execute(cmd, args)
        if cmd in ("save", "start", "stop", "restart", "delete", "bulk"):
            local_tunnels(force=True)
        return res
    with LOCK:
        n = NODES.get(nid)
        if not n:
            return {"error": "node_not_found"}
        if time.time() - n["last_seen"] > ONLINE_SECS:
            return {"error": "node_offline"}
        jid = uuid.uuid4().hex[:12]
        job = {"id": jid, "nid": nid, "cmd": cmd, "args": args or {}, "result": None,
               "done": threading.Event(), "created": time.time()}
        JOBS[jid] = job
        n["queue"].append(jid)
        COND.notify_all()
        for old in [k for k, j in JOBS.items() if time.time() - j["created"] > 900]:
            JOBS.pop(old, None)
    if not job["done"].wait(timeout):
        with LOCK:
            JOBS.pop(jid, None)
            n2 = NODES.get(nid)
            if n2 and jid in n2["queue"]:
                n2["queue"].remove(jid)
        return {"error": "node_timeout"}
    with LOCK:
        JOBS.pop(jid, None)
    return job["result"] if job["result"] is not None else {"error": "empty_result"}


def respond(res):
    code = 200
    if isinstance(res, dict) and res.get("error") == "node_not_found":
        code = 404
    return jsonify(res), code


def valid_nid(nid):
    return nid == "local" or nid in NODES


@app.get("/api/n/<nid>/nodeinfo")
def n_nodeinfo(nid):
    return respond(run_on_node(nid, "nodeinfo", timeout=30))


@app.get("/api/n/<nid>/slots")
def n_slots(nid):
    return respond(run_on_node(nid, "list", timeout=40))


@app.get("/api/n/<nid>/slots/<prof>")
def n_slot_get(nid, prof):
    return respond(run_on_node(nid, "get", {"prof": prof}, timeout=40))


@app.post("/api/n/<nid>/slots/<prof>")
def n_slot_save(nid, prof):
    body = request.get_json(force=True, silent=True) or {}
    return respond(run_on_node(nid, "save", {"prof": prof, "body": body}, timeout=330))


@app.post("/api/n/<nid>/slots/<prof>/<action>")
def n_slot_action(nid, prof, action):
    if action not in ("start", "stop", "restart"):
        return jsonify({"error": "bad_action"}), 400
    return respond(run_on_node(nid, action, {"prof": prof}, timeout=330))


@app.delete("/api/n/<nid>/slots/<prof>")
def n_slot_delete(nid, prof):
    return respond(run_on_node(nid, "delete", {"prof": prof}, timeout=120))


@app.get("/api/n/<nid>/slots/<prof>/logs")
def n_slot_logs(nid, prof):
    return respond(run_on_node(nid, "logs", {"prof": prof, "lines": request.args.get("lines", "300")}, timeout=40))


@app.post("/api/n/<nid>/slots/<prof>/restartcron")
def n_slot_restartcron(nid, prof):
    b = request.get_json(force=True, silent=True) or {}
    return respond(run_on_node(nid, "restartcron",
                               {"prof": prof, "enabled": bool(b.get("enabled")), "hours": b.get("hours", 6)}, timeout=40))


@app.post("/api/n/<nid>/healthcheck")
def n_healthcheck(nid):
    b = request.get_json(force=True, silent=True) or {}
    return respond(run_on_node(nid, "hc", {"enabled": bool(b.get("enabled")), "minutes": b.get("minutes", 1)}, timeout=40))


@app.post("/api/n/<nid>/optimize")
def n_optimize(nid):
    return respond(run_on_node(nid, "optimize", timeout=330))


@app.post("/api/n/<nid>/bulk/<action>")
def n_bulk(nid, action):
    if action not in ("start", "stop", "restart"):
        return jsonify({"error": "bad_action"}), 400
    return respond(run_on_node(nid, "bulk", {"action": action}, timeout=930))


@app.post("/api/n/<nid>/update")
def n_update(nid):
    return respond(run_on_node(nid, "self_update", timeout=260))


@app.post("/api/n/<nid>/ping")
def n_ping(nid):
    b = request.get_json(force=True, silent=True) or {}
    return respond(run_on_node(nid, "ping", {"target": b.get("target"), "count": b.get("count", 1)}, timeout=40))


@app.post("/api/n/<nid>/rename")
def n_rename(nid):
    b = request.get_json(force=True, silent=True) or {}
    name = clean_label(b.get("name"))
    role = b.get("role")
    if role not in (None, "eu", "iran"):
        return jsonify({"error": "bad_role"}), 400
    if not name and role is None:
        return jsonify({"error": "bad_name"}), 400
    with LOCK:
        if nid == "local":
            if name:
                SETTINGS["local_name"] = unique_name(name, skip="local")
            if role:
                SETTINGS["local_role"] = role
            name = SETTINGS.get("local_name") or os.uname().nodename
            role = local_role()
        elif nid in NODES:
            if name:
                NODES[nid]["name"] = unique_name(name, skip=nid)
            if role:
                NODES[nid]["role"] = role
            name, role = NODES[nid]["name"], NODES[nid]["role"]
        else:
            return jsonify({"error": "node_not_found"}), 404
    save_registry()
    return jsonify({"ok": True, "name": name, "role": role})


@app.post("/api/update-all")
def update_all():
    with LOCK:
        targets = [nid for nid, n in NODES.items() if time.time() - n["last_seen"] < ONLINE_SECS]
    results = {}

    def work(nid):
        results[nid] = run_on_node(nid, "self_update", timeout=260)

    ts = [threading.Thread(target=work, args=(nid,), daemon=True) for nid in targets]
    for t in ts:
        t.start()
    for t in ts:
        t.join(280)
    return jsonify({"ok": True, "results": results})


# ----------------------------------------------------- link two panel nodes
LINK_METHODS = ("asnative", "backhaul", "rathole", "gre", "frp", "gost", "paqet")
KCP_MODES = ("fast", "normal", "fast2", "fast3")
KCP_BLOCKS = ("aes-128-gcm", "aes", "aes-128", "aes-192", "aes-256", "none")


def _port(v, default=None, lo=1, hi=65535):
    try:
        p = int(str(v).strip())
    except (TypeError, ValueError):
        return default
    return p if lo <= p <= hi else default


def _ports_csv(v):
    out = []
    for x in str(v or "").split(","):
        x = x.strip()
        if not x:
            continue
        if not x.isdigit() or not 1 <= int(x) <= 65535:
            raise ValueError("bad_ports")
        if x not in out:
            out.append(x)
    return ",".join(out)


def _rand_port(avoid):
    while True:
        p = 20000 + secrets.randbelow(40000)
        if str(p) not in avoid:
            return p


def build_link(method, p, sip, cip):
    """Fields for both ends. Server = abroad side ("eu"), client = Iran side.
    The server value may be None when only one end needs configuring (gost)."""
    key = secrets.token_hex(16)  # shared secret, never typed by hand
    fwd = _ports_csv(p.get("forward_ports"))
    fwd_list = fwd.split(",") if fwd else []
    if method == "asnative":
        bridge, sync = _port(p.get("bridge"), 7000), _port(p.get("sync"), 7001)
        if bridge == sync:
            raise ValueError("ports_conflict")
        return ({"IRAN_IP": cip, "BRIDGE": bridge, "SYNC": sync},
                {"BRIDGE": bridge, "SYNC": sync, "AUTO_SYNC": "true"})
    if method == "gre":
        return ({"LOCAL_IP": sip, "PEER_IP": cip}, {"LOCAL_IP": cip, "PEER_IP": sip})
    if method == "gost":
        if not fwd:
            raise ValueError("ports_required")
        proto = p.get("proto") if p.get("proto") in ("tcp", "udp", "grpc") else "tcp"
        return (None, {"DEST_IP": sip, "PORT_MODE": "manual", "PORTS": fwd, "PROTO": proto})
    port = _port(p.get("port")) or _rand_port(fwd_list)
    if str(port) in fwd_list:
        raise ValueError("ports_conflict")
    if method == "backhaul":
        if not fwd:
            raise ValueError("ports_required")
        tr = p.get("transport") if p.get("transport") in ("tcp", "ws", "wss") else "tcp"
        return ({"BH_ROLE": "server", "TOKEN": key, "TRANSPORT": tr, "BIND_PORT": port, "FORWARD_PORTS": fwd},
                {"BH_ROLE": "client", "TOKEN": key, "TRANSPORT": tr, "SERVER_IP": sip, "BIND_PORT": port})
    if method == "rathole":
        if not fwd:
            raise ValueError("ports_required")
        return ({"RT_ROLE": "server", "TOKEN": key, "BIND_PORT": port, "FORWARD_PORTS": fwd},
                {"RT_ROLE": "client", "TOKEN": key, "SERVER_IP": sip, "BIND_PORT": port, "FORWARD_PORTS": fwd})
    if method == "frp":
        if not fwd:
            raise ValueError("ports_required")
        return ({"FRP_ROLE": "server", "TOKEN": key, "BIND_PORT": port},
                {"FRP_ROLE": "client", "TOKEN": key, "SERVER_IP": sip, "BIND_PORT": port, "FORWARD_PORTS": fwd})
    if method == "paqet":
        udp = _ports_csv(p.get("forward_udp_ports"))
        if not fwd and not udp:
            raise ValueError("ports_required")
        mode = p.get("kcp_mode") if p.get("kcp_mode") in KCP_MODES else "fast"
        block = p.get("block") if p.get("block") in KCP_BLOCKS else "aes-128-gcm"
        common = {"SERVER_PORT": port, "SECRET_KEY": key, "KCP_MODE": mode, "BLOCK": block,
                  "CONN": _port(p.get("conn"), 4, 1, 32), "MTU": _port(p.get("mtu"), 1150, 500, 9000)}
        client = dict(common, PQ_ROLE="client", SERVER_IP=sip)
        if fwd:
            client["FORWARD_PORTS"] = fwd
        if udp:
            client["FORWARD_UDP_PORTS"] = udp
        return (dict(common, PQ_ROLE="server"), client)
    raise ValueError("bad_method")


def node_label_ip(nid):
    with LOCK:
        if nid == "local":
            return SETTINGS.get("local_name") or os.uname().nodename, asnode.public_ip()
        n = NODES[nid]
        return n["name"], (n.get("hello") or {}).get("public_ip") or n["remote_ip"]


@app.post("/api/link")
def api_link():
    b = request.get_json(force=True, silent=True) or {}
    name = str(b.get("name", "")).strip().lower()
    method, server, client = str(b.get("method", "")), str(b.get("server", "")), str(b.get("client", ""))
    if not asnode.NAME_RE.match(name):
        return jsonify({"error": "bad_name"}), 400
    if method not in LINK_METHODS:
        return jsonify({"error": "bad_method"}), 400
    if not (valid_nid(server) and valid_nid(client)):
        return jsonify({"error": "node_not_found"}), 404
    if server == client:
        return jsonify({"error": "same_node"}), 400
    sname, sdef = node_label_ip(server)
    cname, cdef = node_label_ip(client)
    sip = str(b.get("server_ip") or sdef or "").strip()
    cip = str(b.get("client_ip") or cdef or "").strip()
    if not asnode.HOST_RE.match(sip) or not asnode.HOST_RE.match(cip):
        return jsonify({"error": "bad_address"}), 400
    try:
        sfields, cfields = build_link(method, b.get("params") or {}, sip, cip)
    except ValueError as e:
        return jsonify({"error": str(e)}), 400

    steps = []

    def apply(side, nid, label, role, fields):
        res = run_on_node(nid, "save", {"prof": name, "body": {"method": method, "role": role, "fields": fields}}, timeout=330)
        res = res if isinstance(res, dict) else {"error": "bad_result"}
        step = {"side": side, "node": label, "node_id": nid, "saved": bool(res.get("ok") or res.get("saved")),
                "running": bool(res.get("ok") or res.get("running")),
                "error": "" if res.get("ok") else str(res.get("log") or res.get("detail") or res.get("error") or "")[-600:]}
        steps.append(step)
        return step

    rolled = False
    if sfields is not None:
        if not apply("server", server, sname, "eu", sfields)["saved"]:
            return jsonify({"ok": False, "saved": False, "steps": steps, "error": "server_failed"})
    if not apply("client", client, cname, "iran", cfields)["saved"] and sfields is not None:
        run_on_node(server, "delete", {"prof": name}, timeout=120)  # never leave a half-configured pair
        rolled = True
    return jsonify({"ok": all(x["running"] for x in steps), "saved": all(x["saved"] for x in steps), "steps": steps,
                    "rolled_back": rolled, "name": name, "server_ip": sip, "client_ip": cip})



# ------------------------------------------------------------- speedtest
@app.post("/api/speedtest")
def speedtest():
    b = request.get_json(force=True, silent=True) or {}
    server, client = str(b.get("server", "")), str(b.get("client", ""))
    try:
        duration = max(3, min(30, int(b.get("duration", 8))))
        parallel = max(1, min(16, int(b.get("parallel", 4))))
        port = int(b.get("port", 5201))
    except (TypeError, ValueError):
        return jsonify({"error": "bad_args"}), 400
    if not (valid_nid(server) and valid_nid(client)):
        return jsonify({"error": "node_not_found"}), 404
    if server == client:
        return jsonify({"error": "same_node"}), 400
    with LOCK:
        sv = local_view() if server == "local" else node_view(NODES[server])
        cl = local_view() if client == "local" else node_view(NODES[client])
    if not sv["online"] or not cl["online"]:
        return jsonify({"ok": False, "error": "node_offline", "steps": []})
    server_ip = sv["public_ip"]
    steps = []

    def step(name, res, ok):
        steps.append({"step": name, "ok": ok, "detail": "" if ok else str(res.get("detail") or res.get("error", ""))})
        return ok

    result = {"server": sv["name"], "client": cl["name"], "server_ip": server_ip, "duration": duration,
              "parallel": parallel, "time": int(time.time())}
    try:
        r = run_on_node(server, "iperf_server", {"port": port}, timeout=300)
        if not step("server_start", r, bool(r.get("ok"))):
            return jsonify({"ok": False, "steps": steps, "error": r.get("error", "failed")})
        up = run_on_node(client, "iperf_client", {"host": server_ip, "port": port, "duration": duration,
                                                  "parallel": parallel, "reverse": False}, timeout=duration + 330)
        if not step("upload", up, bool(up.get("ok"))):
            return jsonify({"ok": False, "steps": steps, "error": up.get("error", "failed"),
                            "hint": "firewall" if up.get("error") == "iperf_failed" else ""})
        down = run_on_node(client, "iperf_client", {"host": server_ip, "port": port, "duration": duration,
                                                    "parallel": parallel, "reverse": True}, timeout=duration + 60)
        step("download", down, bool(down.get("ok")))
        result.update(ok=True, steps=steps, upload_mbps=up.get("sent_mbps"),
                      download_mbps=down.get("recv_mbps") if down.get("ok") else None,
                      retransmits=up.get("retransmits", 0))
        SPEED_HISTORY.appendleft(result)
        return jsonify(result)
    finally:
        run_on_node(server, "iperf_stop", timeout=30)


@app.get("/api/speedtest/history")
def speedtest_history():
    return jsonify({"history": list(SPEED_HISTORY)})


# --------------------------------------------------------- agent endpoints
@app.post("/api/agent/register")
def agent_register():
    b = request.get_json(force=True, silent=True) or {}
    if not secrets.compare_digest(str(b.get("join_key", "")), join_key()):
        time.sleep(1)
        return jsonify({"error": "bad_join_key"}), 403
    role = b.get("role") if b.get("role") in ("eu", "iran") else "iran"
    token = secrets.token_urlsafe(32)
    with LOCK:
        name = unique_name(clean_label(b.get("name"), clean_label(b.get("hostname"), "node")))
        nid = uuid.uuid4().hex[:10]
        NODES[nid] = new_node_runtime({"id": nid, "name": name, "role": role, "created": int(time.time()),
                                       "token_hash": hashlib.sha256(token.encode()).hexdigest()})
        NODES[nid]["remote_ip"] = request.remote_addr or ""
    save_registry()
    return jsonify({"node_id": nid, "node_token": token, "name": name})


@app.post("/api/agent/heartbeat")
def agent_heartbeat():
    n = agent_node()
    if not n:
        return jsonify({"error": "unauthorized"}), 401
    b = request.get_json(force=True, silent=True) or {}
    with LOCK:
        n["last_seen"] = time.time()
        n["remote_ip"] = request.remote_addr or n["remote_ip"]
        if isinstance(b.get("metrics"), dict):
            n["metrics"] = b["metrics"]
        if isinstance(b.get("tunnels"), list):
            n["tunnels"] = b["tunnels"][:200]
        if isinstance(b.get("hello"), dict):
            n["hello"] = {k: str(v)[:80] for k, v in b["hello"].items()}
        rtt = b.get("rtt_ms")
        if isinstance(rtt, (int, float)) and 0 <= rtt < 60000:
            n["rtt_ms"] = float(rtt)
            n["rtt"].append(float(rtt))
        elif rtt is None:
            n["rtt_ms"] = n["rtt_ms"]
    return jsonify({"ok": True, "name": n["name"], "role": n["role"], "time": int(time.time())})


@app.post("/api/agent/poll")
def agent_poll():
    n = agent_node()
    if not n:
        return jsonify({"error": "unauthorized"}), 401
    deadline = time.time() + POLL_HOLD
    jobs = []
    with COND:
        n["last_seen"] = time.time()   # liveness is refreshed once per poll, never while merely waiting
        while True:
            while n["queue"]:
                j = JOBS.get(n["queue"].pop(0))
                if j is not None:
                    jobs.append({"id": j["id"], "cmd": j["cmd"], "args": j["args"]})
            remaining = deadline - time.time()
            if jobs or remaining <= 0 or n["id"] not in NODES:
                break
            COND.wait(timeout=min(1.0, remaining))
    return jsonify({"jobs": jobs})


@app.post("/api/agent/result")
def agent_result():
    n = agent_node()
    if not n:
        return jsonify({"error": "unauthorized"}), 401
    b = request.get_json(force=True, silent=True) or {}
    with LOCK:
        job = JOBS.get(str(b.get("job", "")))
        if job and job["nid"] == n["id"]:
            job["result"] = b.get("result")
            job["done"].set()
    return jsonify({"ok": True})


@app.get("/api/agent/script")
def agent_script():
    n = agent_node()
    if not n:
        return jsonify({"error": "unauthorized"}), 401
    try:
        with open(asnode.INSTALL_PATH, "rb") as f:
            data = f.read()
    except OSError:
        return jsonify({"error": "script_not_installed"}), 500
    resp = Response(data, mimetype="text/plain")
    resp.headers["X-Script-Sha256"] = hashlib.sha256(data).hexdigest()
    return resp


load_registry()

if __name__ == "__main__":
    ssl_ctx = None
    if HTTPS and CERT_FILE and KEY_FILE and os.path.isfile(CERT_FILE) and os.path.isfile(KEY_FILE):
        ssl_ctx = (CERT_FILE, KEY_FILE)
    app.run(host="0.0.0.0", port=PORT, ssl_context=ssl_ctx, threaded=True)
APP_EOF
  chmod 644 "$WEBPANEL_DIR/app.py"
}

write_agent_py(){
  mkdir -p "$WEBPANEL_DIR"
  cat > "$WEBPANEL_DIR/agent.py" <<'AGENT_EOF'
#!/usr/bin/env python3
"""A,S Tunnel — node agent.

Runs on every Iran / abroad server that should appear in the master panel.
It only makes OUTBOUND connections to the master (so Iran servers behind
filtering work too): a heartbeat every few seconds, plus a long-poll that
receives commands. Standard library only — no pip packages needed.

  agent.py register --url URL --key KEY --name NAME --role eu|iran [--fp SHA256]
  agent.py run
  agent.py status
"""
import argparse
import hashlib
import http.client
import json
import os
import socket
import ssl
import subprocess
import sys
import threading
import time
from urllib.parse import urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asnode  # noqa: E402

CFG_PATH = os.environ.get("AGENT_CFG", "/etc/A,S_manager/agent.json")


def log(*a):
    print("[agent]", *a, file=sys.stderr, flush=True)


def load_cfg():
    with open(CFG_PATH, encoding="utf-8") as f:
        return json.load(f)


def save_cfg(cfg):
    os.makedirs(os.path.dirname(CFG_PATH), exist_ok=True)
    tmp = CFG_PATH + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)
    os.replace(tmp, CFG_PATH)


class Master:
    def __init__(self, cfg):
        self.cfg = cfg
        self.seen_fp = ""

    def _conn(self, timeout):
        u = urlparse(self.cfg["master_url"])
        https = u.scheme == "https"
        host = u.hostname
        port = u.port or (443 if https else 80)
        if not https:
            return http.client.HTTPConnection(host, port, timeout=timeout)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        c = http.client.HTTPSConnection(host, port, timeout=timeout, context=ctx)
        c.connect()
        got = hashlib.sha256(c.sock.getpeercert(True)).hexdigest()
        want = (self.cfg.get("fingerprint") or "").replace(":", "").lower()
        if want and got != want:
            c.close()
            raise ssl.SSLError("master certificate fingerprint mismatch")
        self.seen_fp = got
        return c

    def request(self, method, path, body=None, auth=True, timeout=15, raw=False):
        c = self._conn(timeout)
        try:
            headers = {"Content-Type": "application/json", "User-Agent": "A,S-agent"}
            if auth:
                headers["X-Node-Id"] = self.cfg["node_id"]
                headers["X-Node-Token"] = self.cfg["node_token"]
            data = json.dumps(body).encode() if body is not None else None
            c.request(method, path, body=data, headers=headers)
            r = c.getresponse()
            payload = r.read()
            if raw:
                return r.status, payload, {k.lower(): v for k, v in r.getheaders()}
            try:
                j = json.loads(payload.decode("utf-8") or "{}")
            except ValueError:
                j = {"error": "bad_json"}
            return r.status, j
        finally:
            c.close()


# --------------------------------------------------------------- register
def cmd_register(args):
    cfg = {"master_url": args.url.rstrip("/"), "fingerprint": (args.fp or "").replace(":", "").lower(),
           "name": args.name, "role": args.role}
    m = Master(cfg)
    try:
        st, j = m.request("POST", "/api/agent/register",
                          {"join_key": args.key, "name": args.name, "role": args.role,
                           "hostname": socket.gethostname()}, auth=False, timeout=20)
    except Exception as e:
        print(json.dumps({"ok": False, "error": "connect_failed", "detail": str(e)}))
        return 1
    if st != 200 or "node_id" not in j:
        print(json.dumps({"ok": False, "error": j.get("error", "register_failed"), "status": st}))
        return 1
    cfg.update(node_id=j["node_id"], node_token=j["node_token"], name=j.get("name", args.name))
    if not cfg["fingerprint"] and m.seen_fp:
        cfg["fingerprint"] = m.seen_fp  # trust-on-first-use, then pinned
    save_cfg(cfg)
    print(json.dumps({"ok": True, "node_id": cfg["node_id"], "name": cfg["name"],
                      "fingerprint": cfg["fingerprint"]}))
    return 0


# ------------------------------------------------------------- self update
def _sha(b):
    return hashlib.sha256(b).hexdigest()


def self_update(m):
    """Fetch the master's copy of the script, verify it, install it, then refresh services."""
    st, payload, hdrs = m.request("GET", "/api/agent/script", raw=True, timeout=60)
    if st != 200:
        return {"error": "download_failed", "status": st}
    got = _sha(payload)
    want = hdrs.get("x-script-sha256", "")
    if want and want != got:
        return {"error": "checksum_mismatch"}
    text = payload.decode("utf-8", "replace")
    if not text.startswith("#!") or 'APP_NAME="A,S"' not in text[:3000]:
        return {"error": "invalid_script"}
    new_path = asnode.INSTALL_PATH + ".new"
    with open(new_path, "wb") as f:
        f.write(payload)
    os.chmod(new_path, 0o755)
    chk = subprocess.run(["bash", "-n", new_path], capture_output=True)
    if chk.returncode != 0:
        os.remove(new_path)
        return {"error": "syntax_error"}
    new_ver = asnode.script_version(new_path)
    try:
        with open(asnode.INSTALL_PATH, "rb") as f:
            same = _sha(f.read()) == got
    except OSError:
        same = False
    if same:
        os.remove(new_path)
        return {"ok": True, "changed": False, "version": new_ver}
    os.replace(new_path, asnode.INSTALL_PATH)
    return {"ok": True, "changed": True, "version": new_ver, "restart": True}


def schedule_refresh():
    # Detached: the script rewrites the service files and restarts this agent a moment later,
    # after the result has been posted back to the master.
    subprocess.Popen(["/bin/bash", "-c", 'sleep 3; exec "$0" --agent-refresh', asnode.INSTALL_PATH],
                     start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# -------------------------------------------------------------------- loops
def run_job(m, job):
    jid, cmd, args = job.get("id"), job.get("cmd"), job.get("args") or {}
    try:
        res = self_update(m) if cmd == "self_update" else asnode.execute(cmd, args)
    except Exception as e:
        res = {"error": "agent_exception", "detail": str(e)}
    for _ in range(3):
        try:
            st, _j = m.request("POST", "/api/agent/result", {"job": jid, "result": res}, timeout=20)
            if st == 200:
                break
        except Exception:
            time.sleep(1)
    if cmd == "self_update" and isinstance(res, dict) and res.get("restart"):
        schedule_refresh()


def heartbeat_loop(m, stop):
    last_rtt, tun, fails = None, {"t": 0.0, "v": []}, 0
    while not stop.is_set():
        try:
            now = time.time()
            if now - tun["t"] > 5:
                lst = asnode.run_api(["list"], timeout=30)
                tun = {"t": now, "v": lst if isinstance(lst, list) else tun["v"]}
            body = {"metrics": asnode.metrics(), "tunnels": tun["v"], "rtt_ms": last_rtt,
                    "hello": {"hostname": socket.gethostname(), "public_ip": asnode.public_ip(),
                              "version": asnode.script_version()}}
            t0 = time.perf_counter()
            st, j = m.request("POST", "/api/agent/heartbeat", body, timeout=10)
            if st == 200:
                last_rtt = round((time.perf_counter() - t0) * 1000.0, 1)
                fails = 0
            else:
                last_rtt = None
                fails += 1
                log("heartbeat rejected:", st, j.get("error", ""))
        except Exception as e:
            last_rtt = None
            fails += 1
            log("heartbeat failed:", e)
        stop.wait(3 if fails == 0 else min(30, 3 + fails * 2))


def poll_loop(m, stop):
    fails = 0
    while not stop.is_set():
        try:
            st, j = m.request("POST", "/api/agent/poll", {}, timeout=40)
            if st == 200:
                fails = 0
                for job in j.get("jobs", []):
                    threading.Thread(target=run_job, args=(m, job), daemon=True).start()
                continue
            fails += 1
        except Exception:
            fails += 1
        stop.wait(min(30, 2 + fails * 2))


def cmd_run(_args):
    try:
        cfg = load_cfg()
    except Exception as e:
        log("no config — run `register` first:", e)
        return 1
    m = Master(cfg)
    stop = threading.Event()
    log("starting; master:", cfg["master_url"], "node:", cfg.get("name"))
    threads = [threading.Thread(target=heartbeat_loop, args=(m, stop), daemon=True),
               threading.Thread(target=poll_loop, args=(m, stop), daemon=True)]
    for t in threads:
        t.start()
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        stop.set()
    return 0


def cmd_status(_args):
    try:
        cfg = load_cfg()
    except Exception:
        print(json.dumps({"configured": False}))
        return 0
    print(json.dumps({"configured": True, "master_url": cfg.get("master_url"), "name": cfg.get("name"),
                      "role": cfg.get("role"), "node_id": cfg.get("node_id")}))
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("register")
    r.add_argument("--url", required=True)
    r.add_argument("--key", required=True)
    r.add_argument("--name", required=True)
    r.add_argument("--role", choices=["eu", "iran"], required=True)
    r.add_argument("--fp", default="")
    sub.add_parser("run")
    sub.add_parser("status")
    args = ap.parse_args()
    return {"register": cmd_register, "run": cmd_run, "status": cmd_status}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
AGENT_EOF
  chmod 755 "$WEBPANEL_DIR/agent.py"
}

write_webpanel_html(){
  mkdir -p "$WEBPANEL_DIR"
  cat > "$WEBPANEL_DIR/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en" dir="ltr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="dark">
<title>A,S Tunnel Master</title>
<style>
:root{
  --accent:#06b6d4; --accent2:#67e8f9;
  --bg:#061018; --txt:#f2f8fb; --dim:#a6bac4; --faint:#627985;
  --green:#34d399; --red:#fb7185; --amber:#fbbf24; --blue:#38bdf8;
  --mono:ui-monospace,SFMono-Regular,"JetBrains Mono",Menlo,Consolas,monospace;
}
*{box-sizing:border-box}
html,body{margin:0;min-height:100%}
body{
  background-color:var(--bg);
  color:var(--txt);
  font-family:Inter,ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,Tahoma,Arial,sans-serif;
  font-size:14px;
  line-height:1.45;
  background-image:
    radial-gradient(ellipse at 12% 0%, rgba(6,182,212,.23), transparent 38%),
    radial-gradient(ellipse at 94% 12%, rgba(201,151,67,.13), transparent 32%),
    radial-gradient(ellipse at 55% 100%, rgba(6,182,212,.12), transparent 42%),
    linear-gradient(180deg,#071925 0%,#061018 55%,#07111a 100%);
  background-attachment:fixed;
  padding:env(safe-area-inset-top,0) 0 env(safe-area-inset-bottom,0);
}
.hidden{display:none !important}
.mono{font-family:var(--mono);direction:ltr;unicode-bidi:isolate}
.acc{color:var(--accent2)}
.muted{color:var(--dim)}
.wrap{max-width:1240px;margin:0 auto;padding:28px 20px 56px}
.card{
  border:1px solid color-mix(in srgb,var(--accent) 17%,transparent);
  background:linear-gradient(180deg,rgba(255,255,255,.045),rgba(255,255,255,.012));
  border-radius:22px; padding:22px; margin-bottom:18px;
  box-shadow:0 10px 40px rgba(0,0,0,.35);
}
.card-h{display:flex;align-items:center;gap:10px;margin-bottom:6px;flex-wrap:wrap}
.card-h h2{margin:0;font-size:19px;font-weight:700}
.card-h .ico{color:var(--accent2);font-size:18px}
.card p.muted{margin:2px 0 16px}

/* header */
.hdr{display:flex;justify-content:space-between;align-items:center;gap:16px;flex-wrap:wrap;padding:20px 24px}
.brand{display:flex;align-items:center;gap:16px}
.logo{
  width:56px;
  height:56px;
  flex:none;
  overflow:hidden;
  display:grid;
  place-items:center;
  border:1px solid rgba(215,174,96,.72);
  border-radius:17px;
  background:linear-gradient(145deg,#10202a,#111018);
  box-shadow:0 0 22px rgba(6,182,212,.22),0 0 18px rgba(201,151,67,.12)
}
.logo img{
  display:block;
  width:100%;
  height:100%;
  object-fit:cover;
  object-position:center 30%;
}
.ttl{font-size:23px;font-weight:700;display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.badge{font-family:var(--mono);font-size:11px;font-weight:700;letter-spacing:.5px;color:var(--accent2);
  border:1px solid color-mix(in srgb,var(--accent) 45%,transparent);border-radius:8px;padding:3px 8px;
  background:color-mix(in srgb,var(--accent) 12%,transparent)}
.sub{color:var(--dim);margin-top:2px}
.hdr-r{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.pill{display:inline-flex;align-items:center;gap:8px;border-radius:999px;padding:9px 16px;font-size:13px;
  border:1px solid rgba(255,255,255,.12);background:rgba(255,255,255,.03)}
.pill.live{color:var(--green);border-color:color-mix(in srgb,var(--green) 45%,transparent);background:color-mix(in srgb,var(--green) 8%,transparent)}
.dot{width:9px;height:9px;border-radius:50%;background:var(--faint);display:inline-block;flex:none}
.dot.on{background:var(--green);box-shadow:0 0 10px var(--green)}
.dot.off{background:var(--red);box-shadow:0 0 10px var(--red)}
.seg{display:inline-flex;border:1px solid rgba(255,255,255,.12);border-radius:12px;padding:3px;background:rgba(255,255,255,.03)}
.seg button{border:0;background:transparent;color:var(--dim);padding:7px 14px;border-radius:9px;cursor:pointer;font:inherit;font-weight:600}
.seg button.on{background:var(--accent);color:#fff}
.relative{position:relative}
.pop{position:absolute;top:calc(100% + 10px);inset-inline-end:0;z-index:40;padding:14px;border-radius:16px;min-width:230px;
  background:#0d0817;border:1px solid color-mix(in srgb,var(--accent) 30%,transparent);box-shadow:0 18px 50px rgba(0,0,0,.6)}
.pop h4{margin:0 0 10px;font-size:12px;color:var(--dim);font-weight:600;text-transform:uppercase;letter-spacing:.8px}
.swatches{display:grid;grid-template-columns:repeat(4,1fr);gap:10px}
.sw{height:36px;border-radius:11px;cursor:pointer;border:2px solid transparent}
.sw.on{border-color:#fff}

/* buttons */
.btn{display:inline-flex;align-items:center;gap:8px;font:inherit;font-weight:600;cursor:pointer;color:var(--txt);
  border:1px solid rgba(255,255,255,.12);background:rgba(255,255,255,.04);padding:10px 18px;border-radius:13px;
  transition:background .15s,transform .08s,border-color .15s}
.btn:hover{background:rgba(255,255,255,.09)}
.btn:active{transform:scale(.97)}
.btn:disabled{opacity:.45;cursor:not-allowed}
.btn.primary{background:var(--accent);border-color:var(--accent);color:#fff;box-shadow:0 6px 22px color-mix(in srgb,var(--accent) 40%,transparent)}
.btn.primary:hover{background:color-mix(in srgb,var(--accent) 88%,#fff)}
.btn.o-acc{color:var(--accent2);border-color:color-mix(in srgb,var(--accent) 60%,transparent)}
.btn.o-green{color:var(--green);border-color:color-mix(in srgb,var(--green) 45%,transparent);background:color-mix(in srgb,var(--green) 7%,transparent)}
.btn.o-amber{color:var(--amber);border-color:color-mix(in srgb,var(--amber) 45%,transparent);background:color-mix(in srgb,var(--amber) 7%,transparent)}
.btn.o-red{color:var(--red);border-color:color-mix(in srgb,var(--red) 45%,transparent);background:color-mix(in srgb,var(--red) 7%,transparent)}
.btn.ghost{background:rgba(255,255,255,.03)}
.btn.sm{padding:6px 12px;border-radius:10px;font-size:12px}
.btns{display:flex;gap:10px;flex-wrap:wrap}

/* stats */
.stats{display:grid;grid-template-columns:repeat(4,1fr);gap:18px;margin-bottom:18px}
.stat{padding:20px 22px;margin:0;min-height:150px}
.stat .lbl{display:flex;justify-content:space-between;align-items:center;color:var(--txt);font-size:14px;margin-bottom:10px}
.stat .lbl .tag{font-family:var(--mono);font-size:11px;color:var(--accent2);border:1px solid color-mix(in srgb,var(--accent) 50%,transparent);border-radius:6px;padding:2px 7px}
.stat .lbl .si{color:var(--accent2);font-size:16px}
.stat .val{font-family:var(--mono);font-size:30px;font-weight:700;display:flex;align-items:center;justify-content:space-between;gap:8px;direction:ltr}
.stat .val.acc{color:var(--accent2)}
.stat .note{color:var(--dim);margin-top:10px}
.icobtn{width:38px;height:38px;border-radius:11px;display:grid;place-items:center;cursor:pointer;color:var(--txt);
  border:1px solid rgba(255,255,255,.12);background:rgba(255,255,255,.04);font-size:15px;flex:none}
.icobtn:hover{background:rgba(255,255,255,.1)}
.bar-row{display:flex;justify-content:space-between;align-items:baseline;gap:8px;font-size:13px;margin:6px 0 5px}.bar-row>span{white-space:nowrap}.bar-row b{font-size:12px;white-space:nowrap}
.bar{height:6px;border-radius:99px;background:rgba(255,255,255,.08);overflow:hidden}
.bar i{display:block;height:100%;border-radius:99px;background:linear-gradient(90deg,var(--accent),var(--accent2));transition:width .6s}
.bar.blue i{background:linear-gradient(90deg,#0ea5e9,#38bdf8)}
.bar-foot{display:flex;justify-content:space-between;margin-top:12px;padding-top:10px;border-top:1px solid rgba(255,255,255,.06);
  font-size:12px;color:var(--accent2);gap:8px;flex-wrap:wrap}.bar-foot .mono{color:var(--accent2)}

/* node chips + tabs */
.nodebar{display:flex;gap:10px;overflow-x:auto;padding:2px 2px 12px;margin-bottom:6px}
.chip{display:inline-flex;align-items:center;gap:9px;white-space:nowrap;cursor:pointer;font:inherit;color:var(--txt);
  border:1px solid rgba(255,255,255,.1);background:rgba(255,255,255,.03);padding:9px 16px;border-radius:999px}
.chip small{color:var(--dim)}
.chip.sel{border-color:var(--accent);background:color-mix(in srgb,var(--accent) 16%,transparent)}
.tabs{display:flex;gap:6px;overflow-x:auto;padding:8px;margin-bottom:18px;border-radius:20px;
  border:1px solid color-mix(in srgb,var(--accent) 14%,transparent);background:rgba(255,255,255,.02)}
.tab{display:inline-flex;align-items:center;gap:9px;white-space:nowrap;cursor:pointer;font:inherit;font-weight:600;font-size:15px;
  color:var(--txt);border:0;background:transparent;padding:13px 20px;border-radius:15px}
.tab:hover{background:rgba(255,255,255,.05)}
.tab.on{background:var(--accent);color:#fff;box-shadow:0 8px 26px color-mix(in srgb,var(--accent) 40%,transparent)}

/* forms */
label.f{display:block;font-weight:600;font-size:13px;margin:0 0 7px}
label.f small{color:var(--dim);font-weight:400}
input,select,textarea{width:100%;font:inherit;color:var(--txt);background:#040209;border:1px solid rgba(255,255,255,.1);
  border-radius:14px;padding:13px 16px;outline:none;transition:border-color .15s}
input.mono,select.mono{font-family:var(--mono)}
input:focus,select:focus{border-color:var(--accent)}
input[readonly]{color:var(--dim);background:rgba(255,255,255,.02)}
select{appearance:none;background-image:linear-gradient(45deg,transparent 50%,var(--dim) 50%),linear-gradient(135deg,var(--dim) 50%,transparent 50%);
  background-position:calc(100% - 20px) 55%,calc(100% - 14px) 55%;background-size:6px 6px;background-repeat:no-repeat;padding-inline-end:36px}
[dir=rtl] select{background-position:20px 55%,14px 55%}
.grid3{display:grid;grid-template-columns:repeat(3,1fr);gap:18px}
.grid2{display:grid;grid-template-columns:repeat(2,1fr);gap:18px}
.row{display:flex;gap:10px;align-items:center}
.sec-t{display:flex;align-items:center;gap:10px;font-size:17px;font-weight:700;margin:0 0 14px;padding-bottom:12px;border-bottom:1px solid rgba(255,255,255,.06)}
.sec-t .ico{color:var(--accent2)}
.ok-badge{display:inline-flex;align-items:center;gap:7px;font-size:12px;padding:5px 12px;border-radius:999px;
  color:var(--green);border:1px solid color-mix(in srgb,var(--green) 35%,transparent);background:color-mix(in srgb,var(--green) 9%,transparent)}
.ok-badge.bad{color:var(--red);border-color:color-mix(in srgb,var(--red) 35%,transparent);background:color-mix(in srgb,var(--red) 9%,transparent)}
.rb{font-size:11px;padding:3px 9px;border-radius:99px;border:1px solid rgba(255,255,255,.14);color:var(--dim);white-space:nowrap}
.rb.eu{color:#7dd3fc;border-color:rgba(125,211,252,.35)}
.rb.iran{color:#fcd34d;border-color:rgba(252,211,77,.35)}
.switch{position:relative;display:inline-block;width:46px;height:26px;flex:none}
.switch input{opacity:0;width:0;height:0}
.slider{position:absolute;inset:0;cursor:pointer;background:rgba(255,255,255,.14);border-radius:26px;transition:.2s}
.slider:before{content:"";position:absolute;height:20px;width:20px;left:3px;top:3px;background:#fff;border-radius:50%;transition:.2s}
.switch input:checked + .slider{background:var(--accent)}
.switch input:checked + .slider:before{transform:translateX(20px)}
[dir=rtl] .slider:before{left:auto;right:3px}
[dir=rtl] .switch input:checked + .slider:before{transform:translateX(-20px)}

/* tables */
.tblw{overflow-x:auto}
table{width:100%;border-collapse:collapse;min-width:760px}
th{font-size:12px;text-transform:uppercase;letter-spacing:.6px;color:var(--dim);font-weight:600;text-align:start;padding:10px 12px;border-bottom:1px solid rgba(255,255,255,.08)}
td{padding:13px 12px;border-bottom:1px solid rgba(255,255,255,.05);vertical-align:middle}
tr:last-child td{border-bottom:0}
td .nm{font-weight:700}

/* tunnels */
.tgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(290px,1fr));gap:14px}
.tcard{padding:16px 18px;border-radius:18px;cursor:pointer;border:1px solid rgba(255,255,255,.08);background:rgba(255,255,255,.03);transition:transform .15s,border-color .15s}
.tcard:hover{transform:translateY(-2px);border-color:color-mix(in srgb,var(--accent) 55%,transparent)}
.tcard.on{border-color:color-mix(in srgb,var(--green) 40%,transparent)}
.tcard .top{display:flex;justify-content:space-between;align-items:center;gap:10px}
.tcard .nm{font-weight:700;font-size:16px;word-break:break-all}
.tcard .meta{display:flex;gap:8px;flex-wrap:wrap;margin:10px 0 14px;align-items:center}
.empty{padding:30px;text-align:center;color:var(--dim)}

/* speed + ping */
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:14px;margin-top:6px}
.tile{padding:18px;border-radius:18px;border:1px solid rgba(255,255,255,.08);background:rgba(255,255,255,.03)}
.tile .k{color:var(--dim);font-size:12px;text-transform:uppercase;letter-spacing:.6px}
.tile .v{font-family:var(--mono);font-size:28px;font-weight:700;margin-top:6px;direction:ltr}
.tile .v small{font-size:13px;color:var(--dim);font-weight:400}
.steps{margin:14px 0 0;padding:0;list-style:none;font-size:13px}
.steps li{padding:5px 0;display:flex;gap:9px;align-items:center}
canvas{width:100%;height:230px;display:block;border-radius:16px;background:#040209;border:1px solid rgba(255,255,255,.07)}
.note-box{border:1px dashed color-mix(in srgb,var(--amber) 45%,transparent);color:var(--amber);border-radius:14px;padding:11px 14px;font-size:13px;margin-top:14px}
.cmd{font-family:var(--mono);direction:ltr;text-align:left;word-break:break-all;background:#040209;border:1px solid rgba(255,255,255,.1);border-radius:14px;padding:13px 16px;font-size:13px;color:var(--accent2)}

/* modal */
.modal-bg{position:fixed;inset:0;background:rgba(3,1,8,.72);backdrop-filter:blur(6px);display:flex;align-items:center;justify-content:center;z-index:60;padding:16px}
.modal{background:linear-gradient(180deg,#130c22,#0a0514);width:100%;max-width:640px;max-height:92vh;overflow-y:auto;padding:26px;position:relative;margin:0}
.modal h3{margin:0 0 2px;font-size:20px}
.modal .x{position:absolute;top:16px;inset-inline-end:20px;cursor:pointer;font-size:20px;color:var(--dim)}
.mtabs{display:flex;gap:6px;margin:14px 0 16px}
.mtab{cursor:pointer;font:inherit;font-weight:600;color:var(--dim);background:transparent;border:1px solid rgba(255,255,255,.1);padding:8px 16px;border-radius:12px}
.mtab.on{background:color-mix(in srgb,var(--accent) 18%,transparent);color:#fff;border-color:var(--accent)}
.fgrid{display:grid;grid-template-columns:1fr 1fr;gap:14px}
.fgrid .full{grid-column:1/-1}
pre.logbox{white-space:pre-wrap;word-break:break-word;background:#040209;border:1px solid rgba(255,255,255,.08);border-radius:14px;padding:14px;
  font-family:var(--mono);font-size:12px;height:340px;overflow:auto;direction:ltr;text-align:left;margin:0}
.sidebar{display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin-top:14px;padding:11px 14px;border-radius:14px;border:1px solid color-mix(in srgb,var(--accent) 30%,transparent);background:color-mix(in srgb,var(--accent) 8%,transparent)}
.msg{font-size:13px;margin-top:12px;white-space:pre-wrap;color:var(--dim)}
.msg.ok{color:var(--green)} .msg.err{color:var(--red)}
.toast{position:fixed;bottom:26px;left:50%;transform:translateX(-50%) translateY(20px);z-index:100;padding:13px 22px;border-radius:14px;
  font-size:14px;opacity:0;transition:.25s;pointer-events:none;background:#140c24;border:1px solid var(--accent)}
.toast.show{opacity:1;transform:translateX(-50%) translateY(0)}
.toast.err{border-color:var(--red);color:var(--red)} .toast.ok{border-color:var(--green)}

/* gate */
.gate{position:fixed;inset:0;display:grid;place-items:center;padding:18px;z-index:200;background:var(--bg);
  background-image:radial-gradient(800px 500px at 50% -10%,color-mix(in srgb,var(--accent) 22%,transparent),transparent 70%)}
.gate .box{width:100%;max-width:400px;margin:0;padding:34px}
.gate .logo{margin:0 auto 18px}
.gate h1{margin:0;text-align:center;font-size:22px}
.gate p{text-align:center;color:var(--dim);margin:6px 0 22px}
.foot{text-align:center;color:var(--dim);font-size:12px;margin-top:26px;display:flex;flex-direction:column;gap:8px;align-items:center}
.foot a{color:var(--accent2);text-decoration:none;border:1px solid color-mix(in srgb,var(--accent) 35%,transparent);padding:6px 14px;border-radius:999px}

@media (max-width:1000px){.stats{grid-template-columns:repeat(2,1fr)} .grid3{grid-template-columns:1fr 1fr}}
@media (max-width:640px){.stats,.grid3,.grid2,.fgrid{grid-template-columns:1fr} .wrap{padding:16px 12px 40px} .hdr{padding:16px} .tab{padding:11px 14px;font-size:14px}}
</style>
</head>
<body>

<div id="gate" class="gate">
  <div class="card box">
    <div class="logo"><img src="data:image/jpeg;base64,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" alt="A,S logo"></div>
    <h1 data-i="appTitle">A,S Tunnel Master</h1>
    <p data-i="signInSub">Sign in to manage your nodes and tunnels</p>
    <label class="f" data-i="username">Username</label>
    <input id="uIn" type="text" autocomplete="username" autocapitalize="off" spellcheck="false">
    <label class="f" style="margin-top:14px" data-i="password">Password</label>
    <input id="pIn" type="password" autocomplete="current-password">
    <div class="btns" style="margin-top:20px"><button class="btn primary" style="width:100%;justify-content:center" onclick="doLogin()"><span data-i="signIn">Sign in</span></button></div>
    <div id="gErr" class="msg err" style="text-align:center"></div>
    <div class="foot"><a href="https://t.me/Asnejad" target="_blank" rel="noopener">✈ A,S · @Asnejad</a></div>
  </div>
</div>

<div id="app" class="hidden">
<div class="wrap">

  <header class="card hdr">
    <div class="brand">
      <div class="logo"><img src="data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAkGBwgHBgkIBwgKCgkLDRYPDQwMDRsUFRAWIB0iIiAdHx8kKDQsJCYxJx8fLT0tMTU3Ojo6Iys/RD84QzQ5Ojf/2wBDAQoKCg0MDRoPDxo3JR8lNzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzf/wgARCATGBJIDASIAAhEBAxEB/8QAGwAAAgMBAQEAAAAAAAAAAAAAAAEDBAUCBgf/xAAZAQEBAQEBAQAAAAAAAAAAAAAAAQIDBAX/2gAMAwEAAhADEAAAAfZJggAABoG0DaBgDEwAAaAaAAE0AAhoAAAAAAAAAAAAAAAGmABFHNm+fpqgejmAAAAAxMAAwt3P83S91ka/bIBvIAAAAAAAAY1+n5+msB6OYAAAACAATAAAAAAGIAAAABAAAAAAAAAAADAGAAAAIAAAAEACaAEAAAHQAhoQ0AAwAaBtA2gYAxAxMQAACABAAAAAAAAAACGAAAAA0wADz/oMLyddx07np5gGoAAADQMAM/Qi568x6vym15e2kB7vOAAAAmAABzGBp4fpfJ3lA9nAAAAE0FG7hcOm50HbmAUADQADEAAIaaAAAAAAAAAAAGAMAAAAAE0AAgABACAAAAAOmgABDDkYAIYmDTBoG0wABoAAAATQgAAAAAAACtZzOW9JxydMJooYhgA0DADO0aPn3meg8p6uaAfp5AIYANANANM83X0vN/M9fvild+l5ACgOTJ2PNek5bYHXCz9Hzvm6UfYeS9YrA9PIBDEAAUatLY8Xe6B7eAAAAAA0xACBgmgAENDEDAAAAAYwAAAAAABAAIAQAgBAxDAAYdAAACYJMEmCYAAMTGJjEwAAAAAAEmgAAAAAACCczc7QxdnhtgenmADQDAAAIJ+cXye7n0/F6PXCPoeYGg47zsXSA3AAYgyfJ+v8D5PRue0+XaO59BfiuumPZ5WLkS6fs/EeyuZQXTFPzUtX5/p1PRZep7OAB0yAAAFS15zhvP8AZeX9TNAHo5MTAAAAaYgBNKOkmCaoABgAAAADBpgAAAACABAAAIQACGgYA0DEEgAhggATBLpCAAENoGJjExiYAAANAIaEAAAAAIGgKNTV814e/qTnr3cAAAAaBgA0jH8x6vzfy/X7frH2fp+VAWLy/qPHcOntFUsdsdnFE0cvz+X5+xPeteHtSVqPKmpeukp86lmXzMfro9Tzti1Q7TPscxafTbPm/SerzAGsgAByU/J6+Z871ek0Q+h5gCwaBgAADAQAsW4uHS+B35iaAAAYAAADGAAAAAAAgBAAgECGJgAA0AAAEgwQAACGCAEukIaAAABiY2gYAAxDQJgkwQAAACAAMPcpeXpR2/Hew6GB25gA8Ldq89T9+Q9ZXaDecjGsd/J9XnfXeWr+p6eliypMdd8d453H3ySTavHVfTWd5dX8mnD6cx3aq9PP1dnxsterh8yRtUqfXPW1p+Tt+bpv5E2tieP2bWF6Z7qz81t+jl9EfidDpj02HWw8a2YaG3x36ED2+YAAAYAADBBDNi8d87VS5AB3wIAAGAAAAwYANAADQAIE0CAEAJgAxMBDBMYhh2AA0IYJMENADORhyNAAMTGJgANoGhiABNAmCGgTBABFMsvI7FfK8Pp9mB9DzAANBl5XqPBeft7jx+TqY1xo8UvB11qmFB2zuwLH6LdfjU0r6OlS8u5OMu3vMMfqe/Tz8rb9ApcWvuee5budRbJm9anVzkd6/VYZ6Ke58jB7zrpPOS3c/wA28XL9hg56UCKftIbMveLTUtfrn6PP82+h+vzTAbwADEwAAccUs6DZ8PovAe/ziaAAGmAAAAwG0wBAAAIAQJoEAAAwAAAAGADEMOmAACGCTBACYAmCXSORgmAADEwaYxMEwQAgATQAAmCaDN8l7by/zvT6S55H13u4MqZhvZ/mqHHpZybcfPrFJ11jVSvocbzH6Dz8fXGpWPW+feTe48/w1Llzc+rFn1/huumfol35jv6z7Qgl7cevM+lweO5NqtY656EajEQwKZzGTR8TRiU/TZ3j7eWyPSU/N6MCzFX9fPZ4ybXLUy6K93e+X+n9XD1JHJ15D5Y2geFpeZ8Xaf1FK76MAHXCAAAYAAA0waYMAQAACAEIE0AMAYgABiYAAMGIYdAAAAAJghoQ0AAACXSENAADQMAYAwBAAmgABAAAg4OPF2c7w+iG7Pp+brlS3Y+aSSh1U/GX3V7mOHLinzB6ityaWC3sQ4yelqwdJQh2ecXIn0Fm5b0+jKj2ItsrjUg3Kkk6IS1JLT4txpVdvqovRZdj6Hn1cyWbWaVvyMXn7e88hnRrZpaS5dJLeN6X1cMun9FiTwtffxPP2h28mLU9pY+d295+mQ+Usa5vir6fzdLgn9DzgAgAAGAAAwYAAAAAJoE0CATAGAAgBgAAMAYAAANoGAAAAAAIYcjBAAACYcjQAA0DaBiYDBJoEwQAC8/Lo+WNX53pzr0uN5t3M+He9eMLa1MbrnT8+qvHd6tUnzpRaNjNozzPEedoZOpz6PB9H7uN27iXu/HV6rz0o5SKkOksax6/oHy15mbayPH2q0JbktS36F+7hgL0Rp5vn0nmiLVxpemLl+hfrEg36ny/ViVtmPnvE62YNsuprVOkq+jxOO+PocvzTa7crmf6M4b8nxsU+HWDdyLHEey+bey+l59gR35DEAcHeTS2Oe7XQdMAMGmAAAACBNAgAGAMQAAAANDAGAAAAAMTBoGAAAAAMEmCXSENDTDiCzFz108mbGtADvzGgbQMTAAQAheYzTCl78Prl5owYuhv0avp5eq85hR1PX4u89xaUt3y6pzvrFqdeg0/Zww9Ww/Xyzsj1FHy9PEeoyrN1VvZdz1cd+3nTXN4ilpiBoAytXL8vTznsvK+vaEUvVxuZc1KOpMwXktSJctUeyzYqXKip6S56xoPQcebp5Oa2vF2qV0Z3HnbM+55Xas2Pbx2opKvq4eSeRZ8fr7r2ItT0vrvmF3tx+iLz1XeNnylP2GOlnQH15AFgwGAAAAAgECAYDAABDQAwQwBgAA0AAAAIOhA2gYANAxMTECYIaENAAcUNI5a8/rc5fl67xgbPr5zNPpgaBiYcvyedQ5T58npcVg56pq9Mmabc/O4knoa+FO1FUzbM27d93noaIerkxGo0AAGdies8f5esEnMffG1aw9KzV6wua9L1Ut2MTDP0crz7oehwN/TMxdSl0y9LKmOJOs0W953RLHDjrSsxRJpOrZroVPNye4avyPXR2dTQ+hx8vU9lTkyaGvU641K/XUvz6TeoeX00e+YukO60ms8yvqvV+orT9/O2nqDAAYAANAmgQhgwAAAAATAAAYAMQA0AAAAcgDfLG+WMTGJgDAATAQAhoEwQAQTmLj5npaHz/RmbeRldHt35zb9nCysnDlt4V3S8nfJ1NQ81iUUUVOJDG+9GCnJoZk2/wCnHms71/nLfYZHGZ9DzeqlydHeZQAAAA48dYzM2XnvmU7g0CvNFbrcteY9Bc3CB1LRs0uG4dira6SHwfpcmwsdWifL0nZl7XnfQrErHSQxRRmro0L1LzevmeHvDu83O2E6Vb0c79LmOOq0N0uVb0mNYEXpMv5/fzdH0VbHXz0W9menMPUVnWd32HzX3vblfA7chpgwAAAQLjLxrTp86ONcTJ9eaAoABNAwBgAAAAAAAAAAJMAABMGg6EDaBgxMAExDQhoE0AAc9KMuvtYng9FSh6CDy9cO7q92OTOo2aNixoe3jX8/qVMai4sUfB25uz7Pv48nS9vDjK2I+O/FaPT49aF/E3/Xx3O8vQuZQKaGfPnt4Wdc361ohnjcaFQns2Zsu3ZaI+q6fPQdLgr4cHWbLcvx2YnpfMejXPs0tRKuLr8EenBIanXFTNzrsOx5upH3x7OPnecufN0KF7qs3fx9NL5g6prrjuq+ZuVeO/Oxbtbh08nW36nDvm6efx3x9N68p6H1ee2w3gAA5y83UyMvQ8nalvSz9cIH6OaYgAAAAYmAAAAAAAAAAIYgBghoAAAAEdCDp8sbQMABMQAk0AAAh4d/P8fa1HxleHroZa4u6fscb1H0vP1W68+zYtEXzO8U/G36uYw+hwQAk0V8T0OT5uvlblaPpJfU+N1t59ZLmaesgwxfO+s8zm03HLLYjl6rom4LV2G5Y+o2ks0PdSdQoj8t6Xz0s27hSRzrZWlRZhnStJNGVq2vPLXq2u+OrHQ/Rh4W3iRC5IV04cffTF2KWiVyzEXpOoKkwb/MVY4+vm+jGtSVfP26o35dMLWjqejPv5/nmh6ePssrz1nlrju3f83SLY6PoeUA7ZAAQAmADAAAAAAAAAAAQCEAB2NAACYIaAAAAaDp8h0+WDTEAIaENAnmYsNjip8v052cp97t1+rkvoJ3576Hkr2OLPyvS+a+/wBsSSC+n5gChNCTQoZkebwfU+bxpXals9FpYuprMsaq1z5v0tCMeG3UmrsarFy7TtGmszqy91D0k3VaQ7iKRVljxpdCzDcOdTD17LzpyHNmr0XesyyXWu6jimjIfIeqoy43o/L+qijp8yWcZWqihtYfogzLGMT9Vus3Pt15vmevqrtVcOqtuPFlzotK3HnsQbWbmZ7HtyisJ/R8yAoBDQAAAMAAAAABggABAJDQhoYhhKmCAAAQwQ0CYIaBoG+WdHLGACAACLJm7+b3j85ey+XWHYrTtVfTZd31coOe5vJqKjPW570t3ymj9HhsgevgAAALnpHDAh8L7vxuaQol09zz9+zQICyxj2cVZaTml08q6iTuaokkM3IruRcOrkPdPN18gpzcyQaUVys/Vy7hez7Myd1rkRh8aOKvrp/PaaWJ6xRnQU5dPH0Ksal3D9BZXk77qvfqTlHKd6WG/wA2ybtFhHI4xutjM+d3yKWxlefvcrblbpjJ9V5yLq9moJvoeRplIgngAoBgAAMQANAAAhDQgQxDYmwQw7AAAQwQAAAAAAo5Y83orPnbJDL0nQnqAmEFjG476ht4PzPRDNY59JZt+Hjq/Z4u5zzT6s6lG7qHt5Y9beq8NZ+5g19vTEUvs4NBQmhIA856LHjztfvrOlczrtSy1JUsZ9iuvS4IsWKk9Xq3DSKRSkk9Tss91OiZ1QsQ8ck6rMuzVLFTS8Mn6rcJ15n0rPL7OnKtaaflPPLdziLL3aC61iGRJY3AVKujGd1dDKNfSrWaYMGmOtZWLTxt7O+Z6OL+H6b2Y8/m79Lw9qfrfE73u5bPHWX35c62bpZoD64AAAAGJoAEAgEADZy2ADAAADoTAAAYgBDQAAAAAc9EVqOuvPvJ6v1+W+pcejbr5dOHn108pWa9NibuRrnBrdTebXNTq/uR3g+j5xM3OV0jipeOWvOa1jM49NczNT0ckBuJMFk1Y5cTgp5t2SBk3PABGVN3XiLnVOwdtclmXMZPBpzGdoyypnXZZDH606RzaxZS1x3t15y9p5UTd4Uhs28W3W1xkypd6zrpI5YiPrt1DM+ohzLOEeg76CjNFoF/oKGA2mMAiqX4PH0wNOtV5dvR4Gni9scZ+zneLv6rAraHs47crPX5wHSYCYCBDQhpMQ2JsEwAAAAAAAYgbQMTAAAATBDBAAAAAAEdW9W4bzOLUHzPRjd17/qW9Ik5YVTrR6zidr3cQDUQAk0CYJoOILJKAWAM87jez8Xm1aViot/jgF3JyOY4IuXKQ31OTRT10hg1GZFq5XW9ZybyX4uekjmXVseVsVYp7WCzdgydYkrays8p3s4kut1ZdYVrucq3NKJIbGf0XTG0CXzfq6hzHcySL02frHQOhpjaYwArz1uOqWRvZPz/AEU++p+muFXtcNZfqPOb3s5arD2+YaYAgBAUcnnv0VLG3M2PQH0wAagAAAAAAAAAANAADQMTGIG0AAAAhggAADO0MzhtZl/L+b6YvR1tHrzWeR51ev0b30eDA64E0IaEAIEAIAQxA0AvFe18rLhcTVZbfCCTnq6Vp5ujnTz76RUqFA2+MhmosntdIrzEjzoDXkxujZeRIasmN2mr3mzmxc8669MeaD0XmZrRDqQdlznOtpWg2Q8puVZpbxUlsh0cLWJYX2TaFO5QxgwGDAAUElDjqSpZXzu2JuZWv62IXcTj0nisY0fQ+snW+l5Agy42q3la/HrtZlnW56x/Q2325gHbmNAAAAAAAAAAAAHQmJdIQ0AANAxMYgYAAAmCGgytXG8vXhV9jwdpc/rJ1LNsLbt2nc+n5gDeQASYJNCGhJoE0AAIRl+bu082ln3o1n55Zqcd0iWPgjrYx9qsKO7WTlSTqXYYU0blOvVF6PMZJr2jGi2oTAl37xhc+jR5qP1OMZndKFd2fzkibrxbRs2s6SvQS+YkS04tY4jvcnmNE0CrLmXjVmTpoizWnJy1FxY4za3F452hPYMqzlg5XPlMu9NLzPqPNaaeXoU+XStYhm75ilvb2sYuvpHfkhnbmAAAAAAAAAAAAAAAADaBiYJgkwQ0AANAxMYgYgaGLK1cny9OZpc3xdYZqXqPVIqncXnXbdS19LiwN5ABDQgBJoSYJNAAGVq+ZjK56hmqPVfUSvV0aC7tDToHBy471MjRrils5ic2kiLgmXZqaFC56fNg6jOjmV9HMjkOTugU8PZ5lxjUjXO4vxFOC7WHdxdJLugoDU4zpzR1sfmyxdpWjO28P0p006GAwYAAwBMI6l+HzbqYm7m+DvnEFr1WjXh5xqbWxPono49do9PBgAAAAAAAAAAAAAAAAgAA7TBDQNAxMS6CBTrF464WbI6seLeeazRMd265kx6mlmVbXg7XsfVxM21uV7P0uGXXtZ/yvTtXsHd+p5mB1wAAmhACTBIBACGiPyW5g5sNGznrxrUNBI6V6FdGtK0zuuZF50KF01snVqWV4nHEehna5p49qnZZ6qyE8i6Fa4kOulyccd2SurjM/jTRj1PQRL5Wh6vBlxu+km7v+Y9YZfn/AHHlBXLFQ0LmFds19GraptMYAwYNMAAABMinnaFD5Xpy8zXx3SjJFN6Jsex89u+rzSHPXTAwAAAAAAAAAAAAABAAAAw6YCGCTBAA0DAENAARx2DnadfUXHeXzoQcN5diLrzdZMPVx930en5X1X0vNRzdOj8ztW1uYu813lT+rjfIZe2GmqQ0JMEmhACZEYWXJXzqvmXYS7Lw45j6jOtvD0azJ7MSQW6sq+hy9PHsgqzcRY14Qgi4lHaq37Ouo5zuVdCh4skkvPdNroBguewrYfoqEeIhv0ZdL1HmPQmtj7dfU836bwnt4xZn0bFtOmwGAMAYAOCPFtlVy2I1Ty5p6WX830GRtZvLphN2ffj29gPd5GAAAAAAAgYAAAAAAACGAAAB2AAIaAABDQADEDQAAIAEwpZ29h/P78YPoPN+ftP63w+t7efoKvUnkTWHN7+MXM73mrzcJYJmumRNUk0CaEALJ1vLRXoW8+aqWKGui7j7l5j7jrrrhxvZMexZidJr6XJ1Mq5zdCjZl1sjRzicjlLTilqW1xKndflk0/Eh31y66fLOnz0DTFWswnkMX0vmc3W1su0vruUaz4X1/m/RSwXeryHSdNpg0DBgADA4gtLnaMd+j4+veXcg83SCrY45dMYKHtz9M78D6b2efYI++nMEUxMAAAGAAMQAAAAAAAAAdgAmCGgAAAQAAAAAAJoAhylw7OX4PRdwPQee8/WneqbHplu1DLwmrNRvfT8wB0yAAmCTQk0IaEAV/J+k87m1qF7NWvs5WqQdRSnMcnJz3z0d6WZ0W6G/gJvZuhmHPcVw5gIi3Lwjq7DaqbiOBLNiOYk747O3z1T6TG0xiYRSxmF5H23i83RlrW19dNnaVz5bZyNQ0rEE1NpjAGANpgAMAE0QwdReDrR7OfL1yp8nRm6FO7oejNE9fz0x5O36HuzAPQrTCsaXOsx24ONS/wBZ2h1wxmoJoAAABoAAAAEEgmAAACGgBAAAAACGgAK3U6xY8bdoct1MTYyvmeqaxzf9fOeCeHzu9bG2focWB6OYAAAk0IECaEAY+Ro52bQzNCkq0KdwqzQyj5EPnpDQ40LmL6mzJhtcVn6dG9GLNSsrLcguJP1Srk96vdsklj7JOuOzrrlnXXHVdNMYAc9clDxPu/FSmhmast70PjvZWeZ0aegmlNDNQ0DaYwBtMAAABAZNeOt8f1alK/hFLQydO6pbmDsejHpa2de9fC8mdMpgAAAwBgAIAAAAAAAAAAA6ABoGJggBNACAAAQxA0AABx0R5uhqZHxvcvXeH9T7+MnVez47Q9H5P0fsxaYeviCBqHNxrWoQ6cHTXTKTBAjz+dpUM3MrXYlinj7Kk9WYkTQA4AYb3n9Gt7I0q1zlW616XztiC6tiJ10NGC/XVqKY7647TrrhknUfZ31H3XT5Z0Jgmit4z23kZczYx9mIPZ+K9YUbcLs1ZoJ6YMGkdlS1m9A9RNAxAVLWJz1n909b5HrueV3/ADPfnDeou742PMeo749DeZ6vONPUAABiYDAAAE0AAAAAAAAAAdAAADTBNAmCTBJggAABAAAJ8GXkZsvy/Yoytu+rn8z6XGM6SLJ1foT8FL7eHq8qjsc90N2z305oa64SaEAIEYebq5ObXitwywcyxmf1HzZocd8qmiGColiD2HWXo2YkuhjlG1xRlkKthLU1MW71ncmva8609TJ5i4b0mVcsud15SV8FSEXJYKcJc8zq4mbkbPn95a/ocTRTSjmr2bU0E1NpgDK9bRfPWfzoV+OlayKmNekPOT987njrvneetHfxdj5/XH83oZnql3kkzrJ+j+E9V6+PpGHfixMAAaYAAwAAE0AAAAAAAAAIOgBiYAAAAIABDQhoE0AIaAPLXvHcOvUtd+f0WWrPO5Xq/NXmdfG28Tla2ni3/Zn1mtWs+rzdCNZYAk0JNCBGXg+i8tm2+BrBFPWjKikis1DnteQUdJg+e5ahnrdm/lV5kz60U1TzRSxLLxZWvBpQGcu4Ttx9FjVxbp6GxRt3M3DpCz+I5X11YIMrawTO28TUNWtfyT1MEnFm3Lz1TAI5crQxqYZvIAKpcMXIzPVYfh74M9rvz9FYkzMzzddXPfJZuL3n3Qj1NOLmt4vf9vn1WHo5AMAAAGAAIaAAAAAAAQAAAdAA0wAAAABAAmgTBJoEwWX35Lh1g7ub/m7Yfprp7POYm1yniKO1kfP9XpsS/Dy1hWKZ7M7Hrvntvrj6O87Q7+dtFgmhJoSaK3jPb+EzbNjNuyuloUjG56VlyetOr474jp8dj08verzc3cZalihiGnv4GpYnqWos2Ks62eFylGpbprx1w0ls1bK7+nna9zxk6+GV+lJLJJz3VPA2MWKenl369Pk3q8blijrWXOgptMrcWsjzddtB6eQwBLG5a5q2OPmeh5k6l1fJ+i8htW0HL3HrLtj1efipfe84lL1FbydcD0OdnZ16ky9T28AHqAAAACAAAAABNAAAkMQSAADAAAAAEMEAIAQ0LG5y/L2qamtfIpQ9PEAoQFPy/tfN+Ptj73ntfydvMVNrF9eVY4g3PUek+daFn0p+X9J34SJqwQgRWK/kLedz2W6U1mlQvUKyTpJNNDKS8sl465CTRzrFSZ+1gpY6hmXnUzLp3157RslejPGPzq0jMr3+TPerOY93RlNLSztCyribeOVJeXLY6hhKOZZoENqr1XprNDSi1s52rZM06YA8TbzPP0vTZmn0ycmNBM4vm94c3r1HozUqQXcXH85fjnRe35v+7zsDrzGIGAQzEZUO3F5urlyp95vAd8NACaAABA0gaEMQAAAEgAADAAAAAABNACDEtyebpm7PZ1yJrpkAAKktpYvHHevkEPn3m0dOhw66WD6KmvnobdT3c5iDstWMqzHvdz5Pt9eXvTHwd49B5DL95y68+S9N5Xpzn6qzGvVktJ57mbk5l47Ouue145kjjruPo9B5Xez7IZoZl7TUd5WrSsj7LiwT3bCZ02kynbrVq2nhSHoLGPeLtI5TJg9BXXHoa+TGfU2NM8xBuYZ6HQz9VdPTx9m5lAptMKdyjjWbu+JteTvpzxzedzkr0PbM2fm53aa0d3yng60vdYXsPqcOkHXmNAwAaBgDACGZxywoAECGhAIGgAAAAAAYdNAwAaBiYAAACaBNEUjUCaoAEALjsExAnHHnYF18j15u/jSW0Mf1/mO8rWeq3oxdz9OXlrHsRrrmzVnUun7/AOXen6c6tGxV3ivapWTU0crUTLz9zEBtEp0lI5Y4j656JdXI0KxbcTSymLFPyRnS68NlIu9matfsx5dUKV5dmpoZ+hYUrqrCg9HDGBLoQLDTu48ZVCzUr0GtibEvob9S5rLaY04jvzNfO8vos7ta54enedmz9M+g8pQXqyb0U/z+y8vqZXfPu9fyPrvo+QA1GADQMAYAxMAABDQgTQAAmgAAAYgAAAOgBiYNAwAaBiYJgk0AAgBACGgTBByLxs9Txeirb6v89U3u1EgzJ7Xm6+Tj2Mn384denW1NfH1peOsWwSdJT2qd7rzIen050+JqhrauFtFrA9JjpR4kjJJ6d5axJzETaH1yi5lauZZckq2lBEXeK2nZQdCQt9Ve1lRIhbhsGloUL9nVa0qo2IqcaseWi95bUwJcuJy1pbOPqx6e5Utag8nE579T4+nDw7T7fN7xb7wOcjYt51n0STWju+PXVCB6Wa+47PK+6ycX0Y984pfb5gToBgADTBpgAIAQIAABDQAAAAAAxDEHQmAAxMABgA0DAEmgABNAmCTBDjheV6fj70NjYs9M89D9HLlhWRhezzvJ2wsTXPJ3836fEi9vKLVeTG7k3Lvm65s7Xv8ALE0akNa7TDd87snoKViWzzKkjiO1W7LXE3K1+euIOuOgt1CobV7IS6uelVyn3GnQ3ciyLmNr31GyxYpSJtaGJq2XDkrqNojinrxneV3vMS1rUc1X9HM2Y0vPaWb5PREKDj160otTObfnaVHpm41oXdTSfXnvWZx6Htin67s9/m54mes4ud6nM8HfD9f5K91egYevgAAAMAGAJoEAIAAEAAACYAADEAAAwBgA0DABoGADQNNCGgAEAIfELAtaHl60dXpd8IZ0yhoEwQMz8b1HnvF3xsvZyePWvJND3yr9DT6Y45kj68o01XdS7CZ1+p2nodTzu4Zub6fy4IC1NTtrFBbrkbGHScTzUtusGd8nTRF3a87s2YPHofLk5E1llr9mlrYGvZrd1pLJOVyFaXOjF8/dgWVycxc3cXeMfE4OHd61KLnvWxJLcZ96/pc7TsQV+Ounu7nt45uon6uADsABDChjepq+HtBoea3OssjPTyAAGAAIAQAgQwQAhoAaYAAAAAADABpgAMTAAYmAANMEwSaAA5ztIxeeg1EMpAAmCGhDQsDf814+uPp5/uW/IVfdY+XmX3x6efPPXOsxj4rqWvZijW0c2tLZw9A38bV6ufHuWusl7OuRcq3IVpnfAdcOO5q7PR+d3YNTOOnLzqZjjYytLqzy8vSHIuzu9DqCsdc2TKPk5wtLyi1dCtcOeX1F7Uz7kvkbGpq+H0+ft+it8rk6Lzuc0/Pmdu3PZYO97+ErZ6OQAAwTAAAYFbJ34PJ0k7ytbvlMOmQAAQIAQAmgTQAAAAANAxMAAAGADTAAGgYAADEwaBgCGgTBAAmgAENAACYJMK3n9fB+b6NPdjk+hwKN7Is8xzJxnXHLRzHJHXEnAXM68irczrZ6C9h66QeV9xjVgWanUbnPMq04L1aIV0h9cdE3pvKadRReh86gzpXp5khcxfT4dnN7MljauYFittZtpO4OqhnebtC99qeOeX0XNbLtc9aMK0PB2x5NyXtnEq+ojrzVP0fnvP19p3HL9XxphQDEMBMAABgAFeK7W8+7JXsdsgLUAQJoAQ0IAAEDAAAAAAGhgAMTAAGmAANAwAAGIG0DEAAIaBMEACAAAABOGMeGh6Twei6M+h51jbeHL53jvjNXHXNvC6Uka6R1ZpyVW7s5xp6WPcPQy5d+zy+b7jw5p6nnd2XqC7CUOLMMsTFY3zzHp48z1Vnku5YTpAWdvzesZUnqcyq9mSVKfN6AgxL/AJM7sRWVksSVI4s8XTn0mVuHc+dJZokfdMGQYXpM3w9jSxNv0YBnbCGCGAAAADBMBNMrWAyQGgmgQAgBAAAmAmAAAAAAxMAAAGAAAxMABiBgAADQMAAATQACGgAEAAAZuj5vz9IPVZupSA783l6dWPFcizo57CNSFQ8y8RGdc1Yr9WDPu00aujjWT0nn9ixZ4DUoOPUcV7i0q16tFeOaNeOe+Uk9B56evXeU9FFZhdcdw5OA9Q/P+gspxz9kNWbyxVqc2zvakjWvWksR3bi9ASzKLUqzVdKJO+YauOvMdQymLh7uNq+bpIM9nIAAAAAAAaAAE0AIABACAEAIaAAAAAAAAYmAAAAAAADEwaBiBgAADQMTBoGJgACaBMEAIABBz5fch8XbS6a9nEYqADxNL2ni86YnDTVc8SKIl2q5aCxl6DKtnOvGts+V1A8x7rydke/5bUl2a8wUIrcMV+ZYzjuPurvqfGapYzPXYNlB8dQ7dTo1Os0NPwntY7PKemYc1pIyG5XsS71wepxWsZsd62VphX4Zxepyl1xS1Th0MbyddwT9fJgAAAAAAgAAQIAAQACAAQAJoAAAAAABgAAAgYgGgYAADAAAABiBiBgA0DEwaBiAAENAmCCOMfXzNjz9AD08xNAmg8t6niPn3VqnNd8tql0k5565jldKuZ4eiKpr5ZfM/QNi95nVM7K9rkJU2fI6y6kEjipBcgWvxLFZY7qWD0uh5D0CZ1L2PmardcuJHz2qswBvYz2rPOQ61FM3Vr6ZLrZdmrWRsVo7n6VRd9gjrkfcSLWRpyctRzR99MsRXQgYgaAAQAgAAEAAIAAEAIaBAAACBtAxAxA0AAA0waBgAAMQMTAEMQMQN8sYgYgb5YxAxAABl6nGLHMPUQFCYJMEMKngfpPzuXnuLrNkTDldcAhnC75Jo1aXEnILnVKtpb93DvHGH6mnGTrZVavS851wjraUEZz6grQ7qWo9Bo+U3LMXn0nnAkg7Jnx2pNH3GpcwJbN7jLmsk7jhNXvJslxBQwEughhuIU8XZ0AMQN8h0IGIGIAAAAQAAIAAQAgAEACaAAAAAAABAxB0AMTAAGgYgYgYgYgYgYgYgYgb5Do5Do5YxAxAxMAYhghghofifaYUvlOezN7fLtASCahoS8W63Sd5PoKBRtU5rNBQTrekzLESZ2nGvnpNPNudW95XXNPL1ZV81dkzTY6qWD0F7ymkkFT13NeYl0qcLvvsjcrOZH0ics9FjjulxMFdyhH12AmCGHUkITKPo7OGNoGRxE7gZYUUoAACAAAQAgBAAAIaYIAABAAAAAAHQgYgYmAAAA0DEDOQYgYgYgYgYgYmDQMQN8sYmMQMTBoGKqWcrGglzw6lR0RGdIQwQIBBaloW1qU9qpZTmg7LihsDsV+ItV++ly6m1Us70vP2T1FWrrp5O76PzBe6o2yzp4/a+nm81pWWIr3aZ5cRWknDiR9Vz02IYAAACHyJCGkjp8M75OjnpMA5Onyw65CZcdgIGIGhDEAAAAJgIAAEwEMEAAAADEDEDEDEDEDEDEAADQMQMAAAAAAGgYgYANAxMYgYuQ8dq+clmcKli6gjL65liI6RyulbyuuZAQLvlF7rOtLHT161lSSHstdV5Brtw3BIR1NPgoaFavXo9XyV4tY3pdGzyli/nEndGzF/QxZD0cmBfs0DiSgYJgAAAACGgBNAIGIAXBIQondYLBV4i4ZtA35PLaproKAAAAEMENAAAAAAAAJoAAAAAAAAAABMBAxMAAEwAAAGmAgYAAAAAADAAAACDKi9QyeVsZ+1kxUTgXupZAsUw0Oa9iOTvk4574EIGBXPSRoPiSWhXv51kskEhYcUp1y1C74CeEtGdLbrVLay+z0mt424nqK+XaslXfZAp+inJZ6IZjgndGqbRgxHpHgyG2slGsskNbnORoc5Fc3YcScefv2Tz93W5M+lrcmDD6XPM6xd0Ty+w+DangnoAAAEAAAAAAAAAAgaYIAAYhggAABNAAAAMAAAAAAAAAABiBgAADAAA4r0otVq2ZLeoRahDNHELLs1FcE8RG4kTrmyQjlO+s+cn566iFS8HIKmgJ7VLRitnadGoehHckHRY6g6Jlx0dIIUvKJHDDVszOTXlw5U2u8Po2eshm13gcnoV5/s2uM6Qt8RyEfSpmjRi0SF7Fqzzsno+zGu3uyDuZ1H30DQzltCXQZct2jE+Teom5YzdCuhMABNMQ0AAAhiYIAAGIGgAAAABAxDTQAAADQDQMQMAAAAAAABgA0A0DomZHUPOVLN31YO65WXuHjgUUlVLXEUy1q96skV7PkLnfUaurq1SrdpRmmRzRXjtVzkFUmnk6B1BfiMomirhSqI2ckhH0S9wsn6r9E/UPRZjLJQh3ZE8tD7Pk8TD7tngrPtpq8dY9YHmptqmRQW7aZl28HE0sgpE6b5DoTG0xgCGAJgmChm4KGboZ0WtrzewaQFAAJgIABDQAAAAAAAAAAAACAaAAAAAAAAAAAGmAAAAAAAwAACrYxorFeWXPsQWV7i64OMy5XL/PcBDVuVyhMoU0o4LS0oL9ZLMtDTWw62jGVW06dVNKijUhtOMzmeGlNWDa7yrY6OtEZxbiIeZeCM6BHQcgHXXDJpK/RZlrhoWsSVNozEmrzkXrU9GVM+5IHXL7OOpezjrriu3VhjReWq1DJUbDyJDUMzo0lVs010HLaENHGLu8HnZblqLnYUAAmgABMENAAAAAAAAAAAAIAAAAAAAAAAAAAAGCGJgAAAwACuU8exm5tzueArdONXF3CVZ6ukdQTcEEMsRBBc4SlN3yT1++1p2oY009PLmXQpasKYlfSprzrYbNalZmMri/XK8jiLljGZvyYdg0+akworKKpOiJkRP1QjL8EHZxzamKEmnbTI0NKcgtdSWckvRA7KpBwccWOyn1bZX7l5BtAMBgD5YuJA5k4jLBVlJRADRyzknIpQABNAAAACYCAAAAAABDEAAAAAAAAAAAAAAAAANANAMTAAGg5wNTBljg75l2qtyulSK3WXiGaGKOpk3qsvjsqR2K5zz0iM7RGdI4hsRHVrPvGloYOsizdquYNfXz1q2YeE3ZfOTGtVd9cmPf6TznPpIjz5vcrivaExu9iUxpdjsx5tbszJdHspT2u7IJJuyGSVnHbKZyhnPQkIk6rBadRlpVmT8RSC4khJJH2I5zy/To2orQ7XR5x+ihK2jmRm66FipUwjs15xgAmgAAAABDQAAAAAACAAAAAAAAAAAAAAAAAAAAaYAAAABS896Xy0vMEsOb6Ar3rKta9yZVexUWnLDaTu9l3Vt0dFJlcTcrCpOTjntCjl4IZCJLlqjIvoJcDWSWjrcnl63qKJgrQqlfrvku7nl+z1Zi6hN0u7A7Zx13Icdd9EfUnRG5GcdMptAzlHaj5JVCRLydkbl6qJzBE5Ecc9Mj67Zz0qxZpVpYgsWpSOV9Vyzk7cQS88sgVlHE0LO2clgj7GgAABMABAAAAAAAAIaAAAAAAAAAAAAAAABoAYIAYmAAAjDxtPJzqSCeOLO75f0VnUU8RVyPQUjDsV5iLizVW7oYM5v1Or6YUO1UM3m5CsCk5I45+COePo7l4ca+t5O7ZvQ8XLM6nt8Hl63r6S+Y51a0U5JOSxYz+jU7y+zT7zZTUny7FmlJQ7LxU7LDh6JeF0RdT9ld2OiDuV1w+mJiHygYRnbo0o1a2Oyaaa0cTvsO+YanipVIvVorJSk2OzJNhlK5DmGzwuqXcMo7FS0AAACYAAIYIAAABDTAQAAAAAAAAAAAAAAAA0DEDTQNMAjO8+tSlho3M7N7kq9HetkXa9BxYiuYeZeV83zveZi5F32ufHcqp16HzFs9ZDHdszKm1Wlxo9KFaCtRFdTITfcKO7IUdbN4r1vfk7lm5xRspJXsMza23Iee73muE93tMSbWZnSXgqO2FfuTgfUPNWXR4jTMQNiOhZOjuao5GAQ14vQUkSVY669Q3LqVb/AH0LoZ3zBRLVHrQKN+wxSLqgEN58Ea1KjdM7boBoR9cnditZpgAmCYgAAAAABDEwAENDEACGAAIYAAAAAAAAAAANMABYl7Kl5rW8+XunYUZPfcVXHWmPWWPN+ksg5swpDk7PS+TuQOO6l+Fc2K7CnfpPKTHs+vO261+K1xKlTaDzUfp4pfO2NLsry2XZnZnooZfMvVoLH1yJ2RssT0A1O8gNaTEK3e8GyaaqzJKR8FjktFDncsGHdvlRyHJ2oKhowZrixXVYsqhIdQ37RTsWWR99gzmsT1a1ogtzTC6brnpgynmxeqWbpQpegZ4+L2sJh9EJ6IztE5tVrVCYIaAAAAAAAEMAAABAAAAAmgAGAAmAAAAAAAAwAAAw6c1XNkzdChLJ1FIQZ2rRqrZq9F70PnJT20XE9zWU0ZW8x7GmY/VG1LxDdjloQaEdlCw4jRu+fsHo7/l7R6OTGuWXeOZTjrpnHMwU6GxXPO1fRVJcYvwFdPgaXB2Q2qjNbTTy+j6nsx9OQpuOEtrOgjSq1ESqvXW/HmuLVexaMu3pTWVLE3RH12HKICWClCSO3aI5n0HQ6HHQNHJ4zI0NSvpEU8M1MABBzgegrx5z0fnb5sWKs9dgCGgAAAE0NAMQMAABAAAAAIBgAAAAAAAAAAAAMAADFzfSeTzbdG9TWCStLE9eZGfW0adnNqiz0npfCesq/wAS8pXkaKWD6zk8v1ZzJbUffRWjt8LTjvRpTnODRtYdk1bOazateasnouse7ZZ557qGG6jKq7hHnuvRMwLOqEE7KDiGJ466O4XWJSnHLbhi7K/OlOZc2jIUbNl2Ry9AukhriEnip0i3Ss6RS0OpDjtgIgJqldkPeTaM/qS+b7cdKetPHQnSfHYcjPOV7eZHor+NqFt8d0gAAAAQAAxNMAQ0AAAAAAIAYAmAmAAAAAAAAAAA0w8r6nz8udPn6Gbmmhl1P3BJHNe1GZ8V2rY9bGmX6H35H1FzJHLyR9CO86/2eIm9X5pQrzQRyJYo5+SvxY4SO/RjN2LJuE0ymJ7mbHZtw5F8Lk8pyzmulxFEip1jRrV5CLi72tCS2JW7sdkEsrOe2znoARwScx8EkUUB3UsWChpzyEb7AaVdRx0Iljm6I6OgHnvR422ec3PPenNCKWGuLFeeOmlR3FIcdcdGV571PkI2dnzumbFilcoAAAAATQDQAAAAAAAAAAAhiYmAAAAAAAAJgAAAMBYHoMWPL3KTzrbqw2zCs3Mk0eYpiGtcgqlzNAk2vhyHvLnh/S1p8vqyJ98x13H1VPM9C48YesyTM5tcy0+LnBSiuwFTi1ZrN739dPNbGpGOSrTNbjHjl1a1WcjLsxQs2eLH1X4LHPM5F1N0cEiOB8DOOSUjDvnngUNiUqzWOyKXpUCR0quFG9nZ22Qz1US6PE5HDahMDYy9E836vynrC7BNBXMkUkS8dx0Sxdx1HNVF4j3nhy3pZ+pLpXqdywAoAAAAATQAAAAAAAAAIYgGgGAmAAAAAAAAAAANMWbp8ngI7+fjXduk12IYbaYfWtlk8cFoggtwlNyxWS26Ei+o1/C3k9j1jWbNF1Oiy6/RO67rrPvcxk9anBSnk4LPWfCaNXPiW7Wj7jjuaUikndLuGumjzjKXShiuHNvmxY+zoQkHJwLjtCOg5JZCCSUOX0UnxULnGPkR6TzuVfWlv3dFIcS5VFs0tEsN8V3DPCYlurLGF63yfrFtwTV7OJ61qJI5IxdRdliragqbyHrcCKuln6cujZ471AAAAAAEAAAAAAAAAAAACYmAAhgAAAAAAAJgAANAAGR5b3Hic6hJI5eblRJsKheMyvt5ZMVrhUhvQFLqWOzruHpbFmgzVsZEht2PPM3zAZtQ5gaSo9lmPlib6g7XVSS1Yk0ecqI1a1Jk3UU6yz8WU7sFizmVM6SDlHJ0cM7CQ5764rt0KcbUHn6y7dTKji7Xj6qJaGqmbrc4psssFBsJ70Fo5UFipYZYTJ5mqRl+r8r6pbtW1WsrXaN2JY5YiCejoHRxLUNO3FGRq522TsKAAAAAQAAAAAAAAAAgaAYmAACYAAAAAAAAAAAAAAMxvK+38dm1TqKWXmDs7s1w11QuFGtvUBGfeI4L3Jm83Iqglj4S26/a2OoOyZxdkrjZI+HErg4q4qIlqKNhz0znrqVYpLVpKlyzKcz8OyXqDokOQY2R9d1yyZ1I2KmXDLdrRcj4OyMthE5b1mfc0qp1jVKxz6ylvE1O3TquOSLFiGYztDG2SStZrVQz9HLlq+p8p6qLtS3U1K1ylai3FJwZmtl6ZDZglEu0ZO3UuABQAAAJoAAAAAAAEwAEMEAAAxMAQwAAAAAAAAAAAAAAh8V6LyebLGpJYIrHFRzQIsd8OL9rFmLeRrdmbfqRGpXmsmJDuVKyVfgSHpI76iRY6qdFoglOiWUrdWeit3ZmKk1yWynNPKVer3ZnLUkMebURRn7hLZn1zTrUeZbNfnoh4s8kDkkK3U3Bz11dsoW79MuVKFsgoT54a8WwS3I5Kr1pYI5swWySOfKqHZytaJK1mtVLH18bNh9V5j1JZqWqtkE1a0WopOCrbrSlg65Gukcz17AAUAAACaAAABoAAEwAAABMAABDBMAQMAAAAAAAAAAAArHmMPRzs6nXYBBLHMVmOq0pCWitPE01dl3moyOSR1o2vPzmzDRkOx9pJapSl7qn0WpKHNafWOzbMRG4YYbhhcG+sFxtxY/JqcZwW445yFXZjOlvlVZHWSavw156VItw96iZehfplqlms4t3JSKjaplCcvkt+OydxTU64i7hia1XtHfn/QeYNXTo3TutZrGdjbGNL36ny3qqmr2YEzrdW0WuTkiBlvls65aOLFecYFAAAAAIAAAAAAAAAAQMAABDABDEwAAAAAAAAAAADL1caPN1b2fNTdwzRFXuQHEtdVY567itDd4qtNxEX+s2YuKGaG2HXcKLbqSFhw9k00E5JPXkssHMpxxdlrJj3FGEt4MFegDAl22Zdi3HZwRwlmKnAtyvE5OlxzXcd3UMfSt5xfo5Eayw370VL74s6ifBHn2ODvQjuEkq6qOrJDEfCC1br2SDzupQNi3VtndWzWMzH1siWf1Hl/U1LDPXSjYqWiw+ZCr0ui2+eqTTiOeGYYFAAAAmgaAAAAAAAAABAwAAAAEwTTAAAAAAAAAAAAeJt50edzNOCapWKlsIpiKnFqIrTOKrboWCSG0oz49CGq/XMaWuqPZd6pi3e89po9ZgupJk9mr3k9mm6HRp2MWQ2usXs2usmRNVZoaKzITWq5yLiiukMtuezP7vwHNvKqS7+dkh0Xr5SvydWBx0cEkQqvdY5s8Xjq1zKdc91qi46hiCavcLU8fZ53rN2DRs17IVrVUycrUyZbfp/OejslgmiMq5RuE9mnbKkkUpPJHIABzJHIdAUAAAAAIAAAAAAAAAQwAAAAAEwTTATAAAAAAAABoA57qnlZa0+NZj0K5xNx2KG/GZvFuuRxTFQ2owsyU+o0CpMOjp2a8pH7GsnmnuRGQ9AM81LZgL1Ng8e/az14Tv30qfPT6Hwvgu/eNPCye36PHaHouTPtz9EfMyKFPVpy0oCuvJb0koafTsEw5U0hF11WFC6g+lcOrSkH0KnTsV4jglgC9UuliOXJPPeiwPQl2eGcVW1WMbL1MuXU38Tbs7jk5MO3TnltXs7QsqS8MsSRyAAcycdHYFAAAAACAAAAAAAAEDAAAAAAAATAAAAAAAAAAAAB+b2/Gy8X8vXzYrEfNcc3IoJOZSvU1ojEj1qRV5k5pdco7646jvqJk0lbo0LGQVud4TNzrCDeMUTWWVyurJihs8ZLNYzbBafNhC4dWSkFYtUqsUqhvaBnaE3FnS5BtyHEnTOeSA557onLVwLIzuTiQI3xSh7hiKFsnvQWTrzXo/Hj9Bh75amilOa1mqYuffpy6+xka9nfPfBhycktvQoXrIV3EW++OhtMXLRMBQAAAACAAAAAAAAQwQAwAAAAAAAAAAAAAAAAABpmJ5zTz86r3qnEb9GW7ZjX69BduSC2nPZ0VqunwYtPepy5SuQkD6QPljaDp8dHb4Z2ci9dRhIc9ApZkrS3Z6p357CRyOGxwxxSxx37ZSvdR2TQxxkqi6JTqUUjAjfJxz1mhG7Z1aQM57JR81xx1xHNeSqc2IbxNNH2VPJ7uCX97E3ifvns4qWqRi154JdjXydayTnvkxq9ipLq3aN6ziCzWLnUfZ00xc9I7647oAAAABDQAAAAAAAAAAAAAAAAAAAAAAAAAAA0waDxlbpZ1DUt1i1ueV1jezrlhPHX9bzJ6G5428eoeRoEsM/dmXX24ZcKHdjMLnXjXKNHiKPd3opO8yl1emM57ElmRPq9mfPdKj6IEsRUKsujHS6NC1gVj01PDlLa4sqrE1qyCxJ2nLSHychHHROk7IWwOYF2ST8SBw4xxuMjq9BYuRTnYQnnKTDU28vVJ3z0R597OMiPvmXa087RsmjkjMqhfzpde9Rv2KtaqFzrjsfXLBNBLBPQAAAAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAYmB4mK1VzqKvbqxXmiVbmn5jSPQcV7SYGP7queMuXMZfQaPj7ieq6wbhqlOSyblM5OwXRGSkPC23QRomRBG3FiVDfqY3C6NWsRJz1KVu7cpVsWrNlO3anILErs5kXJ0uOTpRQlmvVQdy2COygK6iLE8VkY+RRtHFaSmc3KukSyc9hmafnTJkjmXd0ad1JGgjzNLMMlMl3NDO0bJo++DLy9XJl2dDO0bFUsVi71z0N89DQzieCU6AoAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAA0wAPI0blHOpKOhnxEdwUW4uDf0vNbiX3FPXMXFSKGN6m4eIs+gx1J81GvLiM21kI2K+cy7xW6iXngGuSmuu4idmYqzXZ6p2LcqQSzS2RzAdkVcuKjwXo6UMuhBnzHTmmSKx26JeEdViE574uxLLx3T5cZzw4iKrJyWb9eyddJnPj/SeUHaqaUu1ar2bJEyoMvTyIze45Zra0KGhcyx98GXk6+RLr6WZpWRQroudIDvjsADmTjokAoAAAABDBAAAAAAAAAAAAAAAAAAAAAAMAAAACM8fTkixq3RvclCCSOuubEUR6GY69Xf81uJdr2u7Maj6KnLkSyQy81LcRULHBCpeSPrsOFNIVFe7KM1+cpWLCs5l5CbujGaazIjY4xw0+KLLjz+lsxuZK8tichsSyWR9ddC4KxPBHXLMEV+WWfiWzrrnoUPcZzWlpCt175LLzIAIwcS9RXrXyduNWaGSyZNVWx9XGilNDPNbt2ncuZY+4zMx9bIl279C9ZSnrXCw06XfHUNNAnyWBOgAAAAAAE0AAAAAAB5kAAAAAAAAAAAAAAAAAAgA88gzqeYLM+MDvsCDgCS+EaNgLHGBDCBHyC8sCPkA6CJADthXPID5A5AXlBCABBY2B3KB3IBN2CPkB8gcQAccgs0oJOwOgKj5CIIgJ5wJGA4grC4CO9MFsyAnaCq9AIrygunOCd8AUaILpWASpaAlArnoIYAgK76AAAAEwEAAAAAAAAAH/8QAMBAAAgICAQMCBQQDAQEBAQEAAQIAAwQREhATISAxBRQiMDIVIzNQQEFgQiQ0QyX/2gAIAQEAAQUC/tLP46Duv7rp23U8l+8jd3L/AOzcbXEbz928TBs+9kPwqwlH2wdj/qf4cj7uYNpy7Vw8j7nxByXxF1R9nIt4lRpf+pzpiP3KPuWDkmR5GBb3KPVv0sdLkWDVQ1X9gnQUd3J/5xbPr+7kgT4dZqz7uQur8Kzs5Xqsbln+jJcTQfN+zlNpMHz/AM7ljURuSfcyvx/hyfu540co6OJd3qPQToYriz4h6GYX5GAnPN+zl3cmxF40f85cnNMZtN9y8bqzttT8Pt7uL6eQ5+r4mP2HPJPg+SK7PR8Qs7dHwP6r+uZb2qE/axPhA+n7GTZwrr/dvA0P+dyD27FPJftsNq68qPhNvG302OPm/V8RYDFVvqZPNGbkUz9Wtg+MPP1hpm5j5U+DXVUxbEbr8Uu5X5j6r+GpxxPsX2ixvhNfKz7xIEG/+PyU2MC37pXVrfsZQPIejLJX4h6crKWlbrrMhqaJ8tDi+PlGhw2AGM8NJjVTiyxcjJqjfEsoqGPO63mcfXY9eXZwrv3UmBV2sb71jnIyf+PcbW3dNqnkv28n+XPXT/Cru7jej4gf3KLOdO5yEtzKKplZ72RVew1UqIxWufMRsufPEQZ5i5wgyK2mqmhxUaWYpEalhCkZDPhWQva9ROgH+Yvb/wCjL9vvZVvEYlfFP+Qyk+n4ZbtPVbY2LkIwdeud4mUnJce+zFtX4nj8G+L1R/i7RviGTZEBNXKxD3bJ3WMVS0rpgUJLHVZfcTGtMxLMYRMz4cs/UMGH4hgxs7AMsy8PRzNNTlAzmjh8ZWFtBWFSpxviVlcpy6bQLFPo+J3cK2/Yw/hCc7fu2v20rQ2P/wAjeNMH+XzPVfV3a6bmxLgdibmbkLZcWBrdCWNcFE7EWj6NqkutBbRaJTK6fH0otlsZmcmsmdqdqCkzsztTtzszsztsIOaxMgiVlbJkY0sqIg8FbrUifEnSL8WWP8Xr4i18m7Ot2Pguvlfu5FnJsZdJ/wAjaOVefXtPht3exvVnYwuT4dkmuyyxKlzM57zTVoBJ9CA2Vkm0CPfLMiDk8WuJTF0C76j3bg1BwBDpOdevEBE2DPpE/bgdRDZXO8mzesssFgTuJMe/lLscMLKQIfpI007cNepXZpbDtcLKfFsouS9Pt5dvFaR3m/5O1Nz4c/Yy/V7TMdS/Ky6Y9Sw3LWbcktLLyYncsKfD8pxaOLokqpYxBXUtt6iNeZj4l2Qf0qifpePP0vHh+FURvhVerKWrTAxTlKPhaz9Krn6XVP0yifp2PBg44gxqRBWgnES3DVpysoNii1Xq+pgUZX3PBgqBD1TjMbIfFtqsW1PsuwRb3mJV26v+TyRp8rYsxbe9R6L8ymgZPxOy6bgfUFpjWQsTKPlwy/FaalyPiN+QK6dynGMsdaRfkFpsscOxabV+KY8TNx3isrej4smqfhKcMT7TKGFmO1cPF5dV5tQqeTCJbBZuEAxl3MfIeizHyUvX7GXbtsVe/kf8pkDdWQvKfC7u3adCPkVJLPiSy7KvunbnbnbnanaENYnbhAHTHq21VOhkc1lrMW4EzjqeemhPhuV2ItqsNzc+I7OPQvCnrubHoduKq3jpkYwshJU3qCrjx4nLUW6KfNiBovcpbF+JxHVx6b7OC3tMSns0/wDKWsFre4a8sQLHnZgp3Fxp2k1xrEZFgCw8RLOJLTW5VTuVVcW/1eNxaxDVOzOxBRDQZ2p24e8JzyIXvncyJ3MidzIncyIHunddpztE7+SJRdmWOB9NR2L/AIiabl+LVzH+I03PkVJcuQGx2KiyNX5xPh3zEf4NYI3w/JqAbixbU4o8Fl2OaPi7CL8RoYU5a2PLXFaFi8wa+9f/AMo7BFzsr5iLXEriqqx7axPmIcgsbO4iGxp5hKEbWWOsG2laQKBOfk3eb6NhabBOLTz05anObEOoVEKCGvwE8cIFE7YgXya4qDXbWY542nl80nLuZNQuqNRBZNT64NbASMhIVnqbG+LLK7EtW2iq0X/C2EarTHkkNYM8qVusEq+LOI1j5bZVu5i19qn/AJPJyq8cW2W5LJQTBUqR7lQvfF7lpo+GsYbaMcWM97qUqj3DZtYzg7Rcf6a6xptKtl0V3se2mnHSneg2oDueJoQ1oYcaqHESNhtGotWcGiaMt4rGeJjXvBg2z5CyfIWT5CyfJ6L/ALV6FWaplFh97F42OgaGrx24UiFklp3GEqaypqPi5WUZFV4sqS0ZWE1cFIIdIgCxE5u54VYKd7M+xbkM9g9v+JzfiASVpyiVhY1oEuuiU3XnH+Fqse+jFF2S9sLqI15M4M0FUStRCRNzuATsWObk/cxBrK+Jpq3Hf6xbzsrP2LKxYCCHymnw6jl6N6mxPiQeVt3sfA+k01hnI0Tigx8dhAvE8eZ+WjUajJ4KQVEwpApQ0fFLq5T8Sx7ZdipZGqt3bQ9UoYh738dxqXw8+vJHpZggtyXyWxqFoT+3behZ4BB/wPiGadonGB+MN+5zaw43w5RLL6Mdcj4i9kLhZ3GaIm4lPgVicQI3ulb2SrAi49QDVGqZVOxvT5/7mLQdXYm+STkPsW/y5P121pwTrZkcrLbCln5RE7NtYKPUOKjzB9AjVq8bFnbsSXCOYKIUAgr5NbSBDXGQzCruErJ1eN0U2y1uUPtqYPxOAgjplZlWPLLrs2zDxhjp/cugeMj1mvJBP3N6mbnczXpY58s0UFnptx8IXfELrITuFjFTkVrldU+gRrJXRbbKsFFgAA62V6mRTo47dzC/0n0QWFhsiJ67R+5WvLMhIAfJRUpuFq3YwJx8hlsy6zjkWd6jj+8zypyYrcrPQVBmXWFJ+hGt1FfwrgzhVLMcTG1yf8Ml+KqfpD76fixXkMXOtxYPi1HG74mzhlJPw3H7dX92wDCyoGB7MZqrktH2WIUZ2Y1xH0jucZy2dwCaM4GJUdLVFpmkWO8px7bZTiV1/YyK5SRTktA+hg2cyrlrCe2FckK2/TZ4swxvLnxA6xqsrtEFLXS2Z1URu/jYDFZV5U+1Vv71L8hVatnptbu5Fx3LVDOuHcazg2iFXQ0XKoU9vK7m7Mx+3T2dR/qi+ZY3NVaN5m4HM+F4u/7901LaJVmMkrsSwev4hl9wicSYMcmCoztRaZ2NTsiLWAor1LH1Fc2WU4ldU35+zdxaw+6jm4t7bV5XJsq1hbTc7lPp9OR/J8N8vPibarSutYTQClgntKOVVt6lLqqeMtfUoo5TXKdlEKaHXKt7dWONKxe58XFSgTUv2WDfWVBvas7sp5yyry9WoyanLywiNqceUq1yodWr/v3rjVq8etqynxCyuUZNd46mZ+Xymole5XjbCUABq0UMQp7nktsogAdgsdyxsxCK1PC0HY7/AAuVwfsO6oLvqdPbxq1ua0oS19nJ62ssifQqH0X+/wANXVUvRXqdtxMRXFdNSBKwFt/ae01238CihFDd5UZbksllO5i6HW4nIvcmxqKVpSe0d4ee+QsKfy1+TZQ4JaOmw1ceqaIhitGE+FXsbPuu4QfMcinP+xdA0bxLaIaSDj5pWC2si7Pqrl+VZdEpLSvGiUhZsCMwLZBYBPqCJuAKka36q67Mg1U11B17ZyquDfC7+SZ545dD8kVvXkMMh0ZlhPng2iNRQQgpHJ8chcevm+yBznOcjLO40xU4UTMu+ru4yzDuFz28EXDtrsmVTzCtQrixL6V4hmj49d0pFjpj0drpl2cU/jXHoFKy7IWqG+uxA/FE0sxG3ZrjXV4Tei9avLMZkh0Y1ei9WwwhEQwbVsPJGRV9p2CA5fcleOTAoX+zIDCxDVGUOCm49Qi40rp8pUFjWARrYlDvFqSsXMb7QnjlHbcxsTnAABCNi2qLyxsn4qkqu0mO55KfHoP4kbITx5E/1rbc2ATjkV4+QKZVpk9I5dLCj1DCrny/YZq+5XR/8+ZYZkDwtfEX29qvH+ZZ7ruOTT5s6WvtsWnXR24p3KzPk6tY4NVoBpyMYlbfyHKbDDpZSlksx2SdotL8XirVwrqK2phZHy9qnY9ZOhbmiduy5qaRWP7U+ZahrcDkLKwItY0GRJbfAWtfHxxV0y7YiS1tDWpjY+/S68hl1chvv/D6vIx1SxVtAKsD6fig4tX3GhUygcyPBxrdxb/K2Y9cGfXEtS0em4N2rRpq77KT4dMeqxVz9pd+VYbnkf6cBjcW0Ozx7Q2JkP8ATj19xuhl6FXD2XkY96NlLuUD9/tcLnF1rs3CA7HTIs7dZH0XBnU6eNXGSDxPh+X24+Qiv6CdS7NrSMbcg00yusJ/cWv3LwCF+nTvLLYxYnDo7NcyLhUlakxvpGpRV3G9Vqcwg7Vq6Syg8rGP11GuBvR8RZe2r8oX4vbsTWsdvprWvimq1lKBjXQlPUddzJrrdGOq67mTDR/2c8/tUN+wFXvOsReTIu3uqriVuposOtd6wDQ6ZZNdlNy2QZKVnkdOPpxt8zF0J+QrTgkPiZ7O6tYO5zPA7DKQ8dNxq55WYd61WV3JYIWCi3NQSyyy011ASms2RQFH9vlWcK8euX3R34xWNhuXz8Po52y2xak5G500oJ3KkN7AaHrzOO7K+MWeZgp9Svz9GRTXYXxnplg2Pyp98cDlk3WBZiryNBPUdNzc3LbgigVmPX+z3xvP/CpSKah9dpnhFUsx7aco9fKVDgOhOgbqzY2NU0OLWiZgPccfRjOUUCbExE0susFahu8LfoSzRbYaWpqDydzQIekzXGLsRbsjTc3KVwKBKcff9057rkhUtsCzeyNIrbMxa+1S5CLa5yLKvdzsqptZFCL9jgps+JjTz/WNo5FI89GbUdm42ZTtHTxT7UaNatxlS6Fdg1RfXdNzc5Tc3OUazUvO5Sce5ULY2TeirdkJzfGYtXV4n0rF/dOi3UCGaMazjN7Ng22PtbKyWXLH/wBNvsol1l1zcbA9QIBOgLFc0ntPcwtBLOyAVxvqgEFQuqR/LhjLEBjVcYn1jiBKq2sldS1/3WUxMROK3vqWnzRXGMw07l+9TItN7Km4SEHljTX21+18RpZ1/wB8hyxRYTTaS4aFxCd9M5ENBP0r/JT4f3C19yV1BXsIqdbiIltZjcQKz9O+a8GlgaoN9auprbJPcqdeeHjcu3SCtWH3e3f5Is4t313kZHaldysB03uOodaV7JzcdNcXR8Y/Q2msPl2g0sflk2KAFy241HCrKY4Z63K1znZZExb2i4jqLVmI3E3VxLLKiCtgZYq/UgL3KND+5dwgX6nss4rdb5ReT60pmJV2aci42lK4zcQzanw8qW+yelp0lniclSuvINZx7rLLYxgntMx+UHhf/wCuLYCmtPz4sG1eaWMKkBCJXtgH0yj6SzTJY8am1LRtUU2Yzc68en8diI3m0kZ+xu1Az3ob760FVyHxyi/S0tZdC47s42CnJbQf9tfyHmFdqRwCb4/Et/L0C3fnYpSxgAOrqHD45rh+pLFGhtW/OFfq8q2PcLl/ub252aAGTZFG5QktaYVfcsvt7kSuWHUYxpbQUGJl9z7bryXIrIuVDY3gFC1ZXK2x9+YEayM3It7jXdQ8RkebK3FsYf8A03uBW304rHx7VodihDWWXlLUZnsRhArsuOxBb2qIn+qoyjv6g8vf+1Wh0Kb+A7i8R9QHOXci/deuDRldSHJx+Ih8KvtGOoLFl2TcmQMocNIRSuh6NbCrxa2vUYRaxfTxloldhreq0Wp1Szm/9TyH2rX4JUsyLNQA3WXIEYDirHkwP7aJPxDtEqZ41TxfEtx+Ux8pkb7XxFeNqMQu/IcicytXdEBjfioOtan/AKG544V3U1xrauReswWwO0DXTd03drldOV8Z74bb1ncyILr53bZ3oLaxO9SSCCVUgXJzl++4q2PKkuSutvpofnV8TR93jkuEp7VZ53lVMs2avYc/GaxCY3caA2VzNIL4q+PVassHIOnnBfi99fKONh11Ma802DpY3FMLyf6kqDOBE5OILFnv6rG7lpYKl77nw5CbW833t4rq3K0jEKHaU4/VlDQoRLq+cqvsxzWyuv2PiQ3Tqb8/6b+BVmxDZOYnOfVFXc4JDwA5ATuATurO+gnzKz5pYMkQ5AnzMOSJ30I7qTv6i5KzvIR3EM4K1q1VsGRVPG1TytgtAgtRofMA1L/FLIez9S4+GgD8yFU8qiCRvi2UvOup1WG9TZapOVSul9RGwoly6JPFlPJb04MyR14n4ffyWZtmlwV+j+r1HTY7WpyvSLl6i5NTTupMjLULVZqXXCb5Njp2cfeoibKV+D9IPmVVeoqDLKNzg9DU5K2fY+JfwmPB7jxOYnJjPfryEG9nnOBg7cHZnZDRwUOxtByjKqqjhWtSt6u0WHZInFKw7qItK2O9FiTREFdsHfEN9qgZlZK2oYCCDWjTsT95Y1iMAqGWg7rC6tOk9qbX400uNNy4LUgCjjkBd2qND1t4l67BHjBbaOvNd+bl8KxR6rBbXc3dtrXgn9aQDOEdNxsdTHoInA7O1LTCXnfltxqVOUrqjNqeTKquP2XQPLMYyi3ifS+QRflXF0sEU7m55PQkTlPqM4gQvA4i6IYNDWRP9C0iV5PICuhpxpENIYdhIK0EchY/Mjs7mOeEe5RXWN1DHSsX03OSrCLfakFtNsFDa7DLbrJrIztRcqtpyBhqRoFtSc1BZeYYeMvYxqDt08Rm+gsCtFY19g+YfKsNFLDTb81VL7EN+uUdJRYyJg18m/sWRTLE4jSsXxgxur4zCbtN9VzVpqO00WNdYT7jqriurtn0fEKuNg9n/IvpxC82TOMAhOoYBuFBKJd+2TZWGQAQrNald/GCziO79XKFtTXnW4ao267HdmKOI92rWcLaU3HoBllXCYtzVW5SP3KbLWqLBbXxeQSq0BXvEW9xO+jTtqTuxY4W6pu7ivR/He4WsU2C2oePsnw9wjQLyhp8VN9N3ufpbCH7P2idR8mtZUtjv/S5B1VWPod+AtdrWoq3K01GbU/IovEf4WQvcq9hZyjL58mLAvgLuCajNK6rHhwsiU7UP3HX5cwUPDQ8OO5nylkGPeJwuMKWMDVtu2ZxMCuA9TmNU4IazdyXPKTawhEuTYq+myu36cdEK5eM5bDrtQDwC+o2WgP0XDuGtkytwqlgsU8UUdvKY2ItfED2+zdLPKuIB5rc8t8bj5SwT4c/Kr7FuVTXHzneJj5OQaMaun+nyoDpb23KK9mpOIY6jtMb/FyV4PuD6iR4EB1OUqV41SGIiLK1aZOV2X+btM79pncedwzZ6fTNLNDpp5+9OV4gvyBPnMgT9RtEHxIRM2loLaTNrN6h+oX7ptFmqEv/AG0t5q942bmaGp2hq42U1CsWCoQ1VlWFlDVXBo6FT9Nrg8vt3fgnlbV8t4OIgWrNXV6HlLZh3dvI9Nl9dct+JRmvulGJyNVCV/1OR+beFbycarQJ1LHgGpi/h/hk6GeUdiOIRvr95uVV76BZ9AhtAmO3KfELP/r5MYAemjFrdouHaYcMiNXYk5dPpgZZsTlBY0W153ROdBnDHM7KztXiLdk0z59Gi2Yrz5dYKLFK1eQkKy/QZPrGdSb6ax2KMfNe3IcK5SwqXTzQv2iwEts5xPEsEuHnEO6cry1Tebo3hsLKW5I91aS34jUsty77oqblVLPKsNVnt/VXfyu0rTZ/EWWSs8rLffF/j/w8+zihHmyDfMeAT5b6U5ajP0WYczR/9fGETjK64W4irzCVrSxmyG7QQFSYKSYMaWVrOzFxi0rwPDYhgxLI4srPMQNFtsE+Yh+Vsi4xgfLqiZ6RLa3hl9PJqzaYfEcc0x6+1lZA42B0sWl/FX49NgQ2IJ3lneE787zzlYZwJi16jfl/q6YL+ciA6f8AKq0QTuvOPKcdSrGseVYiJPb+st/lT63Ual1kZttXVxa6Y38X+EToZFndtaWGUexO4dBieSb6iYszhrM6KJviC25Sm5nAtYicVKwVRUAlkWnlO0NogUe81D9IvdY7bmunccQXxLqyVtcTvbnaoeBMqqJnLuvg81CJkaRz5SlDyxlLW9WqVj2xOM0ZxM4mcTOJnExvZfe8RH7dr8TWUlJ8WxZx1KKHulWLXX/X2j6savQsOoxmDTycfld5GP8Axf4Wc5Cr+TmWGYwjjRJ81DYYaPXFM+ID/wCkCAQDQMX3oEYc8k+4WARoqbjeIq66nxMi2NtjxnGampqMJXZFdxBcsrYw2q0GOsGXbREsSxcz2XzXce3TjJwr+4w3PZrZYsLngR/8tTyxpW+phUHIYDQ/r7vzT2veH63ACIh+m0zH/i/wsx/qQaDmWeSq8VPkMJj/AI3+HHXGMzl8gTUMPvUPqpE/Er05RBuMeMRddNQyw7hr3O1DVO3CkKwiPGlD7mNWljZGN2re89UV63i3EDsRLVyFqTguu78Q+84jjxYvh/Ec/wD+cG0W9kXm9aBE/ojORncEDqZsfZss4xvy/Gpvf4enKy0/tp/GzTEO6/8ABsbijHkzGPKhyt6WCY3lcvxYOuP75f8AAgh99w+9AinipOyPEJiDcY8RUPQxnHc4Ttztztw1R6o9eowjCUTHPF8lOaWU86axygeyqV2Aw8ciY13I46fvfeMaW+1ibBchT+U+EV88j+l1udtZwENU04nK6dy4Q5NgnzZnzkbMYxWMr97fwc6XDTjRaN1qP2398KzVn+D8QfVftHlhmKOpmI2m+ILF6CUS/wA4v4oxhn+6F8ZTarX6RvkR9RgH1QdDANwCampqanGFJbV4tTUcSj3UzHPKoL4yk7OQiCxbcYrK25BzuUHY+/ZCeUbYOQvn/dnmfCmPa4ia/qeAhrhRp4nBDDWIy6lUubQsPjAt5VH2UftsPqZSrVZIM3/gZzbvMeP5KjisMMB0XAyMVZrxKT9R802nozSlIn0l252E7n4itdCDzB0J8D6oB69RlmTXLBKfyWYR+ifEK+dXw66EAi2vt2iYylavvO3Fd/QhjjcuEH5flKKxVV/XGtY6y1SsplvmPMN+Fx9h/F/s6MNXkK6QXGLYp+67cEY8ixjmY42/QwwTDs7dmVV2bv8AUr/JPNZ8lzKU5tUPqvfoBxiDk3+hBB0/IqIPsGXLsZC6NX8i+3w8/TLV2tP03UnlXlH9yjzZ9oh97sE7s7wnNZc3KN4Q+7TI9nGmwF5Zf9jdX+3RLPaxojSq5bKk80EQJudsTtidudoTg4ilvt57/S0cy0zHH7XQ9B0rIysfyOie9Psw4x4P20p+lCxY1iH62XxPeL1ZtxRB9px4zBpk/lX2wG08MrG78T8GTnZVVxP3CAYa4dTQ529EOxYNy/3w7hRerB1/sD7Vji9w+m38UMos4Njtugyv8f8AAufuWuY8fzEGk9A6Vua3vUWofdffGOxkH60G33yfKPGhYzeEGgDuD3UQxmiCD7bTOWHxYkxm1cPY+1a6mJ7VL9f32AIT3uMZdVr4Z5fFmNfbQaM+t4HRv7Dnu678bhE99amF/CTK/KffvPGn/Rlhi+bP9H39WJbwbKq7Nswj4yT9afStI+vOb95T4qG4fEXwE8QQtqLB9xpmj6LZUfHs9R2p9gPGPE/L79v4LLPqfI8KX/c35ulY+r6ZpJpYrss79onzeQIudfFz2i5lZi2o39O1gEssLRvpsu/js/JDFHJcMfQ0xm8ffzTqiWSwyn8pZ6R1T/68YjRwjL/5v9Yq7fI+rJ9yDxgirBGMB5EfdMyhtLZj/i0wm3WfxEoie/37zN6FP1W5cb+WWz4XQto+Xpny9U7FU7NU7Nc7FU+Wqny1U+VqnydUGIgg9v6PtloK1nBJk0dsMf2bV8/D6ldvY44+l5R+f3/iB+mWR5VP9WfiPx9WFZwv+JUamIZlDWRMP3Z9uk9yixYWE33Cogg+4Zf+NwmL+Lfj8Ps8n2qHI1DjE/wLG3fc+lxR9OQ2397Wls+D/wD5ol6vb/YZg/Z/8N7/AA46yMheL4x+mz8sf+X7/wAQ/kPtZCIon+rPZfx6mDoJQ/dpFXYuyx+5qYxie8pELAQvNl5WIv37fbIH1Yx+n/WK3G4eRSNWf6r/AB++G82nk1Y4VXNqVn63b9uz8fhNgWrPuZRiUimr+wcckY6R2lNvbyLxzqxT5viNwu9ZYLDk8iu+Pp+IfzNLJroPa72X8fXgkasHIZf4gzG8dBE+ldzfIosAg+/Z7ZP8mPF8ir+an8R/Mfar8fvZL8KR9K0fVZkHimQfpqP1O302v4x2T5HHq0n9lcv12CWDz8Nu7lSft3X+Q/44786fQ9qJHyyStDWxVCD1fEP5GHhhNdBL/as/R68Jv3LCy2Z6ftIJX4RBuKITuMeUrXUWDpv7ze2YP3Kv5Uh8W4z7WzxcJT+PoY6FV6OPsfET5ZtnDWZTbmUfrrEsMJ23winuH+zzCq2EbjeRRcabclgbWO1bxMPKFLAhhuW5VdcfKssldLWGqha/s/EofYzXW+Y/4H10v27Sdq69yutSJkfRios/EPZFOoLILp8xPmYMoRb1MV9zc3N/ZMzh5B1cJb/Jgn6clfrSVfj6XqR4KGSc7VnzLLEyangO/RlXc76l8UfTXe/1M3Jh4lnsfb4coTD/ALJmCi+83ZAs+hT5cea7v2a/qru3LTpq77EnOx4q7lGPuKoUfZ+Jj6B7ahHQy8zHP2cS3lXXYCMhdPmnYHgW2eVg9a2kRMmLbuK0B9G5yhtAnzAhyJmWbjH61lq+MFtNln6apX+PrIBhrMsoRoaLK4Mm9IPiKiZHxOrtY6mwj63tPCnIf6V8kxxHHj4Pk8q/7L4rlTWoFYRfrJHg++DZyW78rl8VvqDZGNjaH2/iP8Cnoejy6V+G9f8A6UlT3GmPb36r/wCW22CCCCahWMOm+qtqVPFME3C0ss1GtM5b6al3vZK28W+cahtPkeaKZX+HVnVPUfMenceogPTufKJOHjFr0+a3jJb6gTEGzYNsKi04PU2DljIX+w+IZnZBmmg2StdqQjlHEwX4tkyz31xem41tTctyfbzh/wDMIIejmW+4919vSsuH0RYpat83boIIIIIBNR1jD01GVmDpa2ox3NQLAsb2sPmyU/gg54yz3xaovt1+Ij9mo8q/XkMvIKI/0DF9s6zz+diaEHiJcqLzffCuxGrat8bMWz+vzcoUJoluEpwrMiUYtVAmXjhZYvIKeL1nlVkD6rIh5Ci9qHxcpMgfayPNG4p6GPH94nqHvw50L7LCJRZ22zKOxYIIIsHRpYIeolZ80eyiGWzUAg6XnStGmMf28TyNaNHmpF9OSvKrGP0+rJyORCTQSFubr9CZjRFgTQopsyHowqqYQDHxa2nZeqPQjyrItxzValq/1eZlLjrtneutnajCVfQRsZFZpsvQzCs5U5amXeyN45blLspxMkX1/ZcbUwGKelnsfeJB6seWLwt/2p2DK9ZFTo9TIYIIDNxjHh6iIPOOIolvgWGb6DplGP0xvbEOrLxxvwTsL7+hhtaW4WegkAX2l4tXFWYLE55DrUBbe/Gu9uTouhUj5NtNK01+h6UePSwnbatqMsN/VZWXxnHbVYbPK61rX05NPdr1Mc9nIvHKu0aNXvuI8x7V3j5fM/Yzru1S3So9LYfeLB6sV+M+IrxuimNFOjdYOC0Y1sOC0KOnTlC0Yw9RKvegeBMiP0EE9pc22sPTGP10nTZw/ewB9KD6vTkrxeo8k6EgB7DaUSXWhZTW+U9hXGx6E0MtgxRedx5XWYeMuNV63rVpZj7iNZQUdXH9Nk5W5XS1hoxUq+zmpwuyJjW92rLT6nGiyz2itFuZRifEwYrq49N79ut7Gync+Yh8y6HosEHpqbTZw54i9PcalJEZWptqy7FiZ4I3jWxsQGPi3Q4eSZ8hdFwmnytQgx6IKaVlbCK0yIwmum5bZoM0ef6xj+7XMvzTgj9lPf05gmI3Q+Jbb3TWuhdYAtVTZViIta3P3shjwqueY9bPMTFTGX7TVho1LIar9/0uRabJVi8oqhR9hrUWZLNcrLsUuabrwHDpNkD/AGRA+pvcpyLaThfEa7/Rl5qUSyy/NuyKFp+Hv7e4ErOxeNQ++oIIOh6/7r1ZUv0mL1yF7tY6q7CC62c7TAtpi0GLSs7aztpFCzQmpdiq8et6zucpa240M4HinixYfrxML+Cv1ZX8VNnFiwC2Wm41Vy19BVbKsrRa0zMjgMauZ9mg/J3wMb5ev7r1q8UaH9FaxsldAX7Ft6VQ5ljHtZFk7N8+WvE/3kCYjdyi6kiXLomA6h8wbEDbmpifFLKYvxLFKZXxgtObO3w7E7CfFLtqfxQ+BKo6c1fw3QdT6MZ/GcnDIEHWt+DX19uxdRFQxaq4K6xP2xDbWAcpRDmT5qwwPY0rVzONghZxBeZ3VaNRWZZjWx8XJi4GS8q+G11zJ1s/kkp/HC32U9vTmHVGzsF7ZUssfQ+vJsrRaa8r4lKdswbgmXbtvglPJ/7JECfZKqT6Mgf/AF3IJQ/Zsf668lIZqVmNT4bxA0HmfToifCwvz1rduu07h/EeGEr6Zaekems8Tkr38VDF6mAd6vyIJszkZszzApMFcVJX4lUE1uWURlYQlhBYwnfed1pff9LtuNKj9GM31r4g9vQSAMzIFpUcpRWNO4UMTc/7WHTmZrXSpeRpGhdb9N5nwoBcL+/ssWtA/Nx+WRXqYt3GX1blicTVoj2NNsennGTiVgO4YTxZ8uy2l4Y8Q7FRgl42vUQ+Oh9GLZpshOzkKfQPBtqFg7M7M7U7InbE4gTxPEHvVBDA0Kgw0iNjTsQ0sJkrqPP90fx4v5p59LsEXLyzYR9RxqpbatYsyNkZPZW57LCle5RTuOZe25Z5HwS/+/chVycg5D8izNZxi2rYbKQJRZtciklnXUP1wSm2W17jrK24wiNKvFbT/TCVnTJKjsMNhxp4Yph6H0DxM4d3GQ7i+jGfi1nKp+7O7O/O9O4dcoIsrg6OsWzUFgm4Y8zD9VkSY/4Y35Vei+9aVyMl7247ONj6ljBRkWbgBc8QBx5GmuO/AO3iuolWxyZxeh8TIXIq/vGYKMrIOS2hK62cp8MJi4NCizHaqHwd81yEhGjw7g/E49u5ZTuOmpUQsCbaGD2aNEaUH6ZlLowxfdfIPv6aLBLaTjWqfSU+bx/M4mdszhOPQRJXB1sr3CrCcnE5WRy+rj5eAeKPwo/Knpdn01y34ha0d2eKfOLRHtCi6+O/KcmiqxlVeo9grFlmpj0WXlcW2qNYJfULa6XbFuqdbU/umYKMnIOS0x8EmIqoOuTjTZrLqHW5NRGat+zTm0vW9L414Mavcsq1KF0vQRo0pMoMWZS7QQ9KzGE1D6VK2oyNU6n0Y1naszKfqE3N9RFMraKfQRCompkHQuM92lH41fnlZXyq2ZF98CQrqMCZi0SywVJffuAcjaEY1pK6479sM8wsE2kAKIa1aWIaGyagw+H39i3+5dgi32PkGnHa2U0JUPVkYweP+0zJsWVcSGZD8ymQhQrKL9gr9PURo0HhqW1K2jjYYcXPRJ7iH1BfmalOiD6MNw9eTWaH5Tc3NzcDStpWfU0y28WGVjxKfwxRs/EByyPCw5AE21hqr5m2+vHS3MNh5FytUSrcFeo9wVdljh/D/SfMengcnH1MHJ/uGYKLnN71YkA0PsZWOLQD9N3kEQiV2mqOFMqdjV6DGEMrMpaDyMxNHqpn+m9VT8GzqthD6KWIJC5VTqa2m5ubgMrMrMB9BjmZb+W+pgIZUPowx5zcn/6WfcXya1lmUEVi1hFcRZVROYrllheV49t0xcNKPsW16l1GpiX91f7VmChueQ1VK1/czU/euChVB5MsKGIn1Qnoei+QwjCVGVN5qaWp3EI0eiGLGEPqw2DC+k0WjrWeLD6Dl1fMV7m+oimVGAzfUmXvoXv5qXqn44fiWnlaiRbFSMzPFQmLSYmO0StaRbbuVpZacX4eEP2nTUtrNTY9wuT+zPgaa8qAo+5ltu22YeF3EtoZCV4wekxPBYRxE8Msx23BM6qDovukMPqpfi16fMUr6MZ9jkaXz6QrD0CI2orxWm5uO0yrIfrdeqDwh4Y84M8WgxMYmVYcWhFlmlF9kxaDk2Vota/cdYynHdWDL/wLfW9dZvyFGgQCL8TUPq3AdhhH8FTKm0VO4w5C+s02dEPRhD6R4OLZM2niw6g6IYWKi9xWQo01ADErJiUTt6nHoZadDKs81LodB71QgtirRqV43ha0EHERrAJZfGtJCBr7flHoFO+3910le8dv+AvPGqz6KvhdPGvpmNxx+p9CmHyLVlf4IZS30zJp7tZBBlR8r7NCPVU2pSRdXYhrfqvgo25n1eBE1EAi6BDTcMMYzKs0FHNhB5hi+9QlGigtrEts3F5QD6rKqyFpna8Yv7eTr/AsTxU3E/3+U31W7sdFCJ0+In9n7CmOuwh0QZS8Vumbj7hinRQ9CIR6sa7icisX1+hTqUWBhkY5ocQOYHMFhi3QPuEyxpk2c3UdANAxIPE0flqcSyDEny6xakWcFMepWHDaldNUeVf+BYmxS/If311n1/D0529fiX4fYBnuLl0VOwhlbRG2PcZ1PacShvA8wiEQj0qdNh2bmdTr01vxnFcil8dq3WmJQJ2FhonHU3My7iFE9pSu40MrWAblA4VhoD6bVmTXp8E7o/we3+5/e2twrsJ44adujr8T9j9lTLByA+kqYjRLIjbl9YsR1Nbo2jSdgiEQiH04zkMmrEvq7Nnow7JYgdSnCLA0JhmTYK05F2WIncJ+kMYiwDQxq+TkQnUVoD6bk+jBOrP+PzG+mlO9kej4iu8c/aUy5IjaixTKmg8j4nT4Exn1B5BjCah9C+JhXeL6hfWwKt1Q8TRaGVxqNUYB0ss0Mq7vNK0LFVCK5irspETmaaxWplsqHQeiwQDhf/x+ZZ+5gV8avRkjlj+o+kfULF4lG0dytpWYyh1tQ02qdSizYMMaH0CVtxbHt2M2jmB6KbOBWwMvPgzJsN7Zt3IymsuUrCK8PuB4rUmUVcBGn5WKOnKK3XW5eNSs8k/41zxUVm60DQ9OZV2bvtsOasupU09pj2xGnxOnkkofTIdjUYQj0D3lFhU0vyXLx+B9FdmoW5Sm7gc8N2JRSbWrRa1Yxoo2UXbU0hOrmYvkw+zHQR4p65C7GI3/AB2W2q8NPXmUd+o+Pto2pYmwRo1tyHtKboDyXKoNLyi3YT2IhEMMMMHnpi2kFTsZWP2j6A0J3KLuMyPh6Xla+0DDNbjNqYw8j2hmSdJhjSb8F9x15QLoLFPQ+QT28j/jcpudla8E9fxHH4Pv7amWrAdFW5jepRduMFsXIw2rntMe+A7EMMPQeIIPBpt8D6plY5pb0a6V2FCQuQlilD7x26Yv5Nl9u8EEGZX1GlOKt7BR6QemUv1VMGT/AItzxXGHOz7DKHXLxzRZ9oQjkHXRRuJ8NASpqtnLcycYNHVkOPkbAbc1CsIhhitPeI5Q03iyeHXJoND9d9arDWd15CXYjw4l8XGu3TiWg2/D1seml6oQdLX9Q9W5uIYdQAD/AIzNYypO2n2cisW1bm/tIZauwYhnvAeMR57i6vcsqKmnI1A83CNxlh8QxT0VuMov5B1F1TKUbfqQlYl8FgM2IbAIbWi3wHf2DPMq9v8AjSoJ+1qWpxu+0s9xauiDFae8B4xGn5B0ltMR2rldwaB57xl3HUr0ree8QlTjX7mRji4MpUwGD0jYgY9WEUPEVj9rf/M/EF4ZUH2klqbjDRUxTPeDaFHB6MJZXuMpWLayyq4NB5jICLKivSt99AdTGypfSl62Y9lfQQTU1NdBBNwRR1O5yM5znOXpB+1sTf8AxvxSjmkH2knuLq9z2gMDQHc1qI83uMI6bj1zypou5RWmuUvom9FH3B0pyGSV3K0eiqyWYM4MkAmpqampqBYB6dTiJr7G5ub9BPoB/wCLYhRdmVcT4P21bpbXNQQGAwjyGm+jLHSeVNV3KVvB9UvxBZPqqZG6q+pXkGLaDDpg1E4ThOM4zjAPu7m+m/Rub9Sn/ib7hUtlpsMP5fbBimallfQQGAwzyIG6FdxkhSV2xLCJVYDLqEyFtpsxmR4D1VyJVdFfcOjOM1NTX3dfY118+kH/AId2CLfcbXm4T5H3AdRW6WJ1BgPTUDTfRq4yRHKRXlOQRAyWrd8Oh51MrdQYlhEW2K39BuA/8KWAnxG3lXrU3CY8R4p+57RG30sr3PboDAehG55WAzcIjLBtSrbldmpTkTVdy2fDRHx8iqB4GB6cotkS2B9/4mxOQ6cpz1Oc7s724+Six/iNYgzS8ot3/wAHuWZEZ5knmv8A5PVhogwN9xfBHS1ZvoPQRPIgaa3GScdQNA0S4iVZUVwYURocWiHDrnyaT5OHHcTVggZxO80F07qzuLOazkJsenc3Nzc3NwuBLcqFMi2V/MVRcwR7qmXumWXWiB7LZ2IuNGr7VlADLV7f8A9qrLbS0tyAJWttsHGsWEFjN9CIPYGBp7/bQ+I/t0EHp1BtYGUwrGXoGgi2kRckxckRchTDeJ353hO7O5OYhIhIjcYYLCILILZ3TO4Zzad0g92HIVY2ckOW7TWRZFxtxKVWcJqNWjT5dBO1O3LaeDLEEza5j+6e/wDeswWNdGsMZxGZrTVjJXHsjN46Gb6D3YQeRsoQ2/tV9Gh9G5v1bYTuTlWZxWcJ5gM3NzlNzcDzuTvTuw2TkZswmcmgdo13Bfn9wZTNO7YZ++8GMTExQItAEFc4noPTqEAh6+BRofqA+h1/vbLYTHaW28ZXW1sGkBaGMdwdDDNxensSOQ8qVffTU1D6U99Row9W5ub9JAMNcKsJztE79gnzJnzInzKz5lZ80s+bWfOLPnEgzK583VPmqYL6jO4kNiRsgzs23SrFWJSogqE7YnCa+4RsFdHyJad2UNtR/d326m4X1LL5VRCYTNyx5uf+oYwhm4h2GESOsIivqA9DCPQIn4sIVmvTvqD6ROCtDVDjiHGhxjDQ8NbwhpxJi0OYuI0GE0GFBiLO2igwVM8rxlSBQIFgH+DZ7E+P/VR0yf3Vtk3yNjBZY7WGmoVwt0ts0FBC63GEaB57wiMIZW2j7hfB1sMsYRWKxW30Ih9FBhE1LPy9W+u5ubm4DFeeDNTiJ2Vny6z5dJ8uggrE0BPEZ1EazcFTvEoVZqa3AP8ADMYT/wBFirUWBh/cXPoXPoey2NyNScYejN4P1OIY0aGVv0YRhCJS2w0qOwyxhCICVKHcIjCHqjai2b6XJ9zc3AenKC0iLfBaJzncneE76x8jc/deLjxUVfQOuprrsTkJyWb+2ygyysozRB5X8f7ZjxDtuD67bPZB1JlhlQ28MMYQjojz3jCGIeLDyE+liNh1hEIisUNZDBljCHpuI0VoDCimGmGsziZr0a6amprqJ4E5LFdZ31EOQIObxKNxa1XprqBAs0JsQ2KIb1hyDOdxnC8z5eyfKtPlTPl3nauED2rFuEBB+wZdRMavQ/t8izctfxjj6bYB1MsMxx9MPQxhCOinU94whlLQyluQZY6QiGUvwbe4wjLNdRZFcQPA03NCcBO1O1O3OE4TtztzhCaxDaIXc9OMCRadyuiIgEAmuoXcCgQsBOc+oztsZ2YKlmh9nQnCDf2Qf7e5+CuY/vWNLZ79Wj+4GhG9BE1NQQ+QRB9JXyKm4sPIZZYkIjRHKSu0NOO41cKzUIhgdhBdBcILhBYJzWdxJ3EnerhyEhyDDZYZ9RnGBIKzBTFoi0xa4FmpqcZxmunvOMAH3N+jcNiiC0GBvWD/AGrNxWyzkSZ7sPCt7nq0/wDfVvsGESo9KbJ7x1liRh1S5liWq00DGqhrMNZnbM7c4ThOM4zhOECThO3O1BVBVBVBXAk4zjNTU1NevXr3NzlqCamuhcCPfHa152ro3dSJkmJkRHDf3WYdUt0H5f8AlhGHQxp//QNAejr6j1M9jvwp0am2IySyqMvoW51iZQgZWgAM4TtidkTsididgTsTsTsiducJ25wgWcZqamoBNejfo8TlORm5ucpyM2Zvrw5EdCwEsyRCLLJXSBNTjOMbHR42IRF5IVsivv0D+0zR+wT4MJlZ2jDpYNQx4v5RDBOMsXifsERD0qfURhCIRLKtx69QrNdRsSu8gpYGE1NTU1NTU1NTjNTU1NQCa+xucuupqcZxnGa6a6a62X6nBni1gQLNeojcNcAgPUf2mQyircMMw22hHQiOOJf2Sansa3gMdeQZSp19lT0R9Su3c1ucY1e49MarUKzU10V2SVZMWwGAj/B2JynKb6ampr7XgR7lWGx7JWmoBNejlOc5zmJvrqb6r/Z5zfWIYZitxsPQy1OQYRB4jCA6iWxHBnENHphUzXrEB6K2pTdPDQrCIa9xsfcehlhWamugYrFvMF8GRBkTvz5mDI8C6Cyc5znOc5ynOcuupqcYB9trVWNkRrS5WrcVIB13C8a2G3UN+yO6ZwtgFyFLgZ79DFMMHv8A2Wf/ADk6nv03qVtyTpqX17C9CIRror6lFgI94yRq4UhHo10HTUB1EyCJXfynhpwmoVlmODHoIhrnCampqagBnHcFcFcCQLOJnCcZxmpqBZwnCcZr7RIEa+NYxjWxa2eV1gQD0M8a2G2Cux4mIogQCampqW0rYBY9LhuQntB/ZEgSzI1MhuXQHUPTCaH0ZFXatHRhD0R9Gi3lNbhSMsKwia6a9J89FJEpviuCPEImpqNSpjY8OPOxOzOzO1BXAk4wCanEzgZwnCcR6NzcNgneE58oN+lrVENxMaNbAr2SukCBfQWjWRn2VoJiVKsHryae6mPaVPuPcQwe39c7BBZZuFo/ke0Jit0xm42w9b07le9FfMIjCET2lVnE02hhCkauFIUhWahE1NQCBJ2oya6LYyxMoiLlCC9YLkM5IZ9M4Azgs4LAqzis4rNLPE2JsTc5TmIbRO6J3YbtQ5U3c0Sq9oMedlZx103DYBDdNs00BGuE0zRaoqTXoZ49kWpmiVhfVuPkqC17ALlRLwZk1CwYluxDP9D2/rSdCywuxQw+DuWrN9B5gOjQ/NCIen+82iJB5hEYQjpVYUNNwYAzxNCGsRqY1JhrM4TjK0gScY9e5ZXr0bnIwMZ3DFyGWfMmfMHQv8i/z3p353jDYTO6YHabaeYYA7RcW1ouJUIK1X0b1GtURr4WdpxnNVjZBMCO8SqBIBB1JjWTTPEqAmvVbkqs422zt6D4PONgWLN3UyjIjftXjyP7DLbjWIxn/qGWJAYra6Yl3bYeQRCJqa2L6zTYjT3jLCsIntEs4xcgwZEW0GBumpwBhpENMCQCamo1e5ZTCmvtiLqDU2JyE7girY0XHJi0oPTuG0CNcYSzQKJyURrxObtBSTFq1Ak16CY9oWcmsiVQD1W3rWN25BRFWBJqamo1YMyMThCe5jYtvJf7DOb90Qz/ANdHjiAxD0wruQhHW+kXV6KMh8GEQiFYRPIi2RWi3GLdBZN9NTjNTU1NRhHrj1wj1bm5ubnOKztK8XJeV4SCLWq+kuBGuhtYz6jPELgQ3Q2MZxdpXTFrgWamuu4XAjXExKdkLqD0swUWZDPErHIJ4Xx6jKq+FtBKMh8f1+d4yFhj+HHRowhgMUxH4PS/NeomVji5QSrK3QiEQrCsKwbEFsD7i2MIlsDwNN+kiMsZI1UNUNcKn0biY97yv4cZXg0LFVV67nIQ2CG2FmM0Z9IhtAjXGc2MCM0SiCqCuBZr0Exn1LL4qvbErCwD0ltR8iMPDZfJsWrgPsWV7N44ZFNnhTuL/XfEViQy/wBgerCMOgbUB3MK7iR0PXIxluj1vSwaA7mpqETUKzU1Fs1Fac53Il0FoitN9dQrCsZIVM7ZMGK7T5CJg0iLWiTU103DYIbJzn1GcdQ2VrGyIbHaaadswVxaoEgE10103Nxnll+puy2VY4EAmvQTLLgs/ctgKJMvm5wE3asaD1mfEPF1bSlvH9dencqDaIO5ePC+wghjCMOitqAzEu7iegR1DrdhlYDqA9NTU1CIRNTyIlsGmnEib8LcREyBBaDA0310JxE8eotC08zQnNFhyBDfYYQ7QVzt7i1QVzhAs1NejcJjNGshdrDXjeQuoB6WfULs54JWL8trJgV6GV+Xw5PAjxfR/uH3nxMfQkxzBF/rs6rt3I0I2GXg0HRowjDoh1MS3tWIwYerJxVtBDVsrzfo1NTUIikrK7p4MI6BiIjmK85w3Q3WSoWma9BM3DGsAhsYzTGduBJxnCBZxgE169xmjPGcmLSWiVgDXpLSy0RUZ4zisWKzipJjrpMj88MarjxYOv8AuN0+ILyorMqbURtxT5/rfinuraKnYddhvoO+hhjLCOitMXJNZR9j1W0Jat+JZTFab9JHoFhWJkCBkaACCG3jFsZ5XjsYiKvXc5QtGtUTukzTtBXAk49NdNTX2dwtDszt7i1QL6mcCF2siVhJsvBXHH0Vyv8AjtP1Yo+iPFgh6H3j+w9sr+JDEMqeD+u+K/jKm6WoGB3UVPUwiHorTHyTXKblsHpE95biU2SzBZYQynoZqahh68iILzK68i2VYaiBAOnKc4bhDkCGx2nBjFpgSAdCempxgHp31303PM4QLAs16XtCxsvnEqLx7EqiBrCBoSz8V90/is/LH/CPBF6mCN7IdrkfxCVyuJ/XfFB+z0rsm9yxA0YGkq2+hhEYdQZTaUNGSHAP2LK1cPjMs4wicYVnGFZwJi4V7yv4Ysrx6qoTC+o1yiNfO8xn1GBIK4qCAdCYbAJzJgEAmpr7fGBZqa9G5belYt+IcolVlxqpVBbkblNeoi9bPxWf/wAT+WP+EeCL7wz/AEOlfvYOSBfNYiCV+/8AW/EBvGPWtujrsPW1ZSzc3DvZjDqplb6lGVA85erfR60ePjTsWb+XeDEgxqlihVhMLQ2RrYX3NbnGBZxgEE3OYEa4TZaKsCwD1H1cZxmpr0bll6oMj4huBLLmx8XU+mpb72tNSalYgn/qWfiI/wDB/wC6fxjwRIegi9Pa2WrxuSCVD+uIBGSnC0z/AFEs6MJbV5R+hE1GHXcDSm8rK7QYtsFk5icxOQgcTmJzELznO4J3IbYbhGvEN02WgEAgEUTU9obAI10awmeYqwCLB9jU1NQLNeksBHyEEfLl2W0+u01UblFEJFYu20VIBEEEXpZ+P+7j+yP5KfaPBF6GL+Y9xLZ7jMXV6jyoi+F/rviFPNCPRXZBCNy6rcqfzNQiEdR0DRbSILzEyIMgTvprvrPmFnzE7xndndncMLHprqOngTugQ3xriZsmCL7DzFEAgHo369eh7VWNmLGy3Me0meTG8xafNdESrUfIAiBtNAJWIJYeKV+0s/HXnJ/jT+Sj8Y/sPdOhin9xvcRvIrmav0p+VY+r+vusFVbN9R9FbwGMNy6qV2dCIRCOoPRdzfXfpEHp9psTuQ2w2TfUQCKIqxVg9Jhm+gUwKB0LgRslBGyzGudoSIXAn1tNBZ5aJXK6ZdfVjg33ZRx6Qos6pBMo+E9pb+P+8uJ/JR+Ms9lidGlZ+tvZeg8PkjdVXvSPH9f8S/iae05T36o8BhG5dTuJZqA7moVjLNdNwHqD9jc3NzlC85Tfo1Api1mJUYqCAePTub3ODGcAIWCw5CiNlRrbDGacpsmamiYEAnvFqiUkzVdQyPiJMrQ2vj1AAeA81B7rBLjyyF9pb7CZPvX/ACUfjLPYSvo/snhh7DwYw8uNrQk9v7DMr7tBhHUN1V4rTUuo5QM1ZV99OMZJqEdNzc39jYnOc5v0anGBYqQLAIJub1C0B68TOKiG1Vhvj3NpnLQmc55M1NQLFQQmBSxSmcFQPkbmTaXKVbmPTqVrqN7Hogg6VHlYntLemR+Vf8mP+Mt9onRvb/aezDTCGf6oGh/YWv20c7YwiGERW6q2olk3Lag0ZGrKWxfM4Rq4VhWa6bm5ynKc5znKb9WpqATU8Tc5zuaneE7hMC2tOzbFq1BoTmIbIxJh0IXhsnkzjNTUAmh04kyumLWqyzLG9M0vt3ESU1xF1BHMPRYJktwoo8KntLIZf+VX8lHtLfYQdLPYiVezwdV9/wCw+IPpbDKz46GEQNxm+q2RXmg0soiu1crtDT3hr5RqSIUhT1iAQIxnZsnZsnZsgx7TBi2wYls+UtnylsGG8+Unylc+WpgStZyAhtncheF53Z3DNsZwJnanEDpqcZ4EJ3FUmJTAgWW5SpD3biEVBdZANmpIixYfYwxYIJ8Rb6aovSyGW/lj+bKvaW+yQdLPYxPeCHp/v+wy7OdjRfCbnv01DPIgbfoV5zEKhoaiClxSV2Bp4nBTDQs+UUwYSRcWoQUViCtJwWcUnFJpZ4mxNibE5TmJzE7gncE7ohuhuhs3C87k7s+oztkwVQVzgIdCFuu9TluKpaJRAirLspEjG24106nhRZsxvJqSIuoogjnofdYOmU3PKrEXo8eWe+L+dX4mWQfkJ/5f2aJBP99P9/1+Q/Cm321stCIfEVuhEIhEDEQNv0bInOeDOPGBzBY07zTvGd4wWmC0wWCcxN6gLTuGd0zuTuGd0zumd0zuGczOZnIzlNzzAhgqgqgWa6M4jPueZ4hIEe7zVj22SvFQQBUl2Utce2y2V1RK4fAMsMUeUWKIOjQz/awdK/ryEi9HlkeYvvV+Mef+hF9mje1cEPUwe39dnn9m32T8j+RhEIgbqRNQiByIHB9Pmbmx6hNQRROAM7M7MNU7U7ZhScZqcTO2YKTBTBUJx6bhaG2Fz05Tc+piuIzyuhK54EtyVSPkPZFrJldUA1CddHMPvWsUQCCOeh6LBMhuFOJ7rF6PLY8xJX7R5/6EWNHlfsPQYPb+u+ImW+1fv/7hhEM3qA9NQiFYRNkQWGB4D11PM2YGnKB4LILRO6sFqwWrBZA82J9M4qZ2lnaSdpZ21nETQniFobIbBGecuup7yvHJiVhZsCW5aLHyLLIte4lUVB0J6NHMURBFEHRj0YxYsE+JNqnD9liwx5dGmLK/aWezfkPZIY/tX7D0GL7f13xMeGG1C8bP/XTUImp7RXm+hEIhHXc5TmZ3J3JzE5CbHr2YLJ3Z3YLtTvwXzvzvzvGd0w2xrYbJsmATU1BW5gxCYqV1Rr1WWZka12ioTK6YEgE3PJmoTGPRBFEHRuhjRPZR0+JvuzF/FYIY8ujzG9q/xln4n3X2r9j7PE9h6V9v67PXljIfFqQmD2EIhE1NQiciIr9OMKwrChnkTlA031303ORnMzuGC0zvTuwWTnOU2Om5sTkJ3IbZ3J3IoZolDmLjzhWs7tSx8uNlMY1rNDFRmldEWvUGum4FntCYx1DFWIsAg6OfMaf7QQdL2534w+hYIY8ujzGH01+0s9j7g+Kp/q2J+K+lfb+uYclTwTLklR2sEIhEPQiFICywPOUGjOInbBhx1MfDMZHSb6bm5vrubm5ucpzM7hneM77Tu3QfNNOxmtF+H5bSv4YYmDSsFKLNGFWjV2mfLWQ4+oURYSIuzKseKij0agWGExmhgERYBB1PRoJX0tPGoe9HhRBDHl0eY48J7R/Y/lvxVBLRE9l9Bi/1+RZ2619wIy7CUlQRFgEZIVhHqBgac4rCKRCFMOJU0OAIcGyfJ2z5G6L8PsMX4bB8Npg+H44gw8YQY2PBTQJwqnGqcaZ+2JyE5znOU5TfXcNmpZfqWWlpxZomPEqCwdddNQw+Yx1DAIiwelvcwxYnT4hZxrT3p9hBDHlsMpiexjez/mPauCWxIvoMX+vzruTI3n3gP1ajL0E1GWMkK/Z3OZgtMXIgyRBkCd5Z3hO5O5O5DbO7O/qd8Q3TvCd2c5yMDGKWir03GePeI924FZzXRFrAm+uproBC0PmMeI94IiwD0mGMelcXpntu6r3p9hBGj+1s/wB1RPYxva0fuSuCWRIPSPf+tvft1WGJ4KHxYsrshG5qagmoVjJGSa+9ucjOZnIzc3N9dwTzFB4osVdTcJhfUZ9w1lomPErAnt03111Y9GIUctxRET0noYY0EQeBGOha3KyqV+w6GWe1sHvT7r0Mv/KV9LPZIP7P4i8PmGVNBMioiV3weZqa6ahWOkZIy/4uoFipFSKk9oTC+obNnizSumBBPaEzc31A6kwwsAGPI/8AqtfQOp6E6h8mtYOmS3GmY8T2HQyz2sie9XuvQzI9xK+jeyweoe39Zlnnd7QxW81NuDzMjGiWlClin0lYyR0hSamv8ALAkWuCuBNTWpuM0d5otEpgTU2BOcLTlA0EAgHU9GOgzcjrcRIBqE9B1PQ+Ixie6iDp8Qb6ZREg6GW+1kq/Kr3XrkwSno3tF9S/1th/cMbwJS+ih6ZOPzh5VmvLleQrTYPUiFIUhSFIUnGa9WumpwgSduCuCuKkCTWiYXhtnItFqn0rGvRY+VPmGnfaLYxgBMVIF9JhbQdy0AiJANRjqflBB6WM9zWIOuY/K6Y8Xq0uPh5V+VMXoZkwSn2h9h7j1L7/ANZZ/LHmop0abPKtuCX44sFtDVlW1K7iJXkxbAZvoRDXO1DVGqnahqnaM7RnaM7JnaMFUFMFMFM7c4CAATcLQ2xrtQ3bgsQT5oCNlsYbXM8mBIK4lUFcVfRvqz6hJYgRUghMOzFEHQwwwxjEEUdbG4ox2w98cQdWl0eVflTF6GZPsJR7dP8A0vq/3/WZQ1fH6H3RvNbxGgj1hpfhR1KRbIlkruiWQNN9dTjOE4ThOE4icRNCeJubhadwRrgI98OQY105mbM0YFipBXFSKkVIFmvSZuWWTy0CxVgm4xgijqehjT/dYg65zaqiflQNehpdGlP5VxeuT7CUdf8A0PV/v+sz/wD9Ijjo0MrsiWRHgPSylLBdgajIyQW6i3Rb4t0FgnOBxOU3NzlO5O5DaJ3hO+IcgQ5UbJJhtMLmbPTU1AsFcCRUgripAuoB6NzcJjWwuTANwLFXoTC03uL6D0JjmJFHo+IPt5V70+3VpdHlHvVB0MyfxEo6H2X3HqMHt/V/Ef8A9Ub2jxfY/SUeVPuCCbnMR60sF/w+PTZXFciCyC2C8zvwXzvwZEa+G6G4zuTnORm/UBAkCRU1AkCeQkA6bhM3OUJ8s4jWTkxgECQLNdCY3mNK1g6nq5hlYg6t4FzcrJQJWNQdWl0eY8qg6GZPsJjdLPZIPUYv9Z8QP/1Cf+T7t7Ce89pW+jW/IKfPvCkbkIuQRA9bi3Dqsj4NlcIZevmbM2fRrrvpqcYE3BXO1AsAmoPfXTlN7hbiTbO5GeG0z6iVSBYFnt13CYTB5Kj0E9CdRzE91EHXKfjX0oiew6vLY8olUHQzJ/FZjdLD4rg9Ri/1md/+oQS4aP8AoflDAdSm3UR9xTCIyyyuMkHNZ3nENvKMqzjOM1NerUCwJFrnbgScdegWCG0Q2zuznOcNghtE57nkwLAsVZqAdSYWjNBslRB1PVj0rWCDrnv1pi+w6vLY8x5VB0MyvxX3xulsr+x/v+qduCWtytiy1dhYfDDzGGoYDqUWSpwYJqFZZXGUjpxEImprrrpxnGduCuBJxE8QvxiuIXhadwzueORhMB1Oc5T3nGBIEE4QLAIOpMLTlC3nySg8DoOh6MYxi+YsHVvAyzt4vvTBB0Mslvu8x5XB0MyvZffF6WfnX1/36DB7f4X63jT9bxp+t40/W8afreNP1vGn63jT9bxp+t40/W8afreNP1vGn63jT9bxp+t40/W8afreNP1vGn63jT9bxp+t40/W8afreNL/AIxj2VHKQn5lIuZWJ8/VpshOTXKYuQohyEhuWd0QXgSrOVIPitUHxiifrGPD8Wx4fieOZ+oUT5+mfPVT52qfO1T5uqfN1T5uqfN0z52mfO0wZ9U/UKp+oVz59J8/XDnJPnUnzqT5xJ82k+brnzaT5tJ82k+brnzlc+drgz6p+oUwfEqZ+qY8/Vcefq1E/VqJ+rUT9Von6pTD8Rqn6hXPn64vxCkRfilIn6tRP1fHn6xjw/GKJ+rUT9VojfE6jP1CqL8ToE/VqJ+r48/WMefrGPH+L0EPlKzfMrFykBT4lSs/VqIPjGPP1nHn6zjxvitBj59Zhy0Mqza1i/FqBB8Zx5+tY0/WMeXfE6XgzK90/FKEn6xjz9Tp5L8XxxP1nHn6zjz9Zx5+s48/WsafrWPP1rHn6zjwfG8YD9bxp+t40/W8afreNP1vGn63jT9bxp+t40/W8afreNP1vGn63jT9bxp+t40/W8afreNP1vGn63jT/8QAKxEAAgIBAgUEAwADAQEAAAAAAAECEQMhMRASIEBBEyJQUTAyYEJwgGFx/9oACAEDAQE/Ae6SuL68b1JKn1x0i383i3oarqi6ZmXnrnpFLpgvPx8Fbrrx/sZVr1r3QHpxnppwxq2ZXr0tcuP49OmZF56luZFa4pX0Y/1JY7PTZGDsnvwxqok3cujHG2ZZW6+Qh7oV1rWI9Hwx78KI4/squikciNSSp9EFyobvrS5VzfE4nTMqp8YvXUlGnwxr2jx2emhIoS4NjTOQ5BKXFxTPSR6bIQ11Mmi64R5mTdv4qauPRD3KmRxcOajnFruaDkj1EeqiM0x5Uj1Uesj1kesRlexvwolGyUa6n7I/F49YklTFFsWL7FGimNMcCKS4McUx4voox7kt+qGT7NzY5xqyWP66MUfJOVv4vHFpFcL4WWUNCmjThZoUjlRyoo5Se5Gr1HiRGMkctkk0RyNCkpDhZ6aFjdk3S+KSsjBR4PIkXKQopdM76OZiyMjNSJSpHqyPUkepLjGceNDhY8bRHJWki1wyJ30Vy796q8jh5XXFNkYUhyoblIUEjXg2kSy/Q5NkJ/ZkXkfTi3Mr61JoWUT0L4ZNOClYyUBQbKUBu++UmiozJQa6IxsiqNSjl4WiWX6G76IztU+rHuZP2/AlZsSy/QsrG7IJN6nIuFmqJb6/AJ0RnY8aew4tEYNijSL+uNEsiiJ2NU66V1Q3Jb/gxKtSc76FJojlT4OIjJF79Si2e1d3jnZZZX2SyfRjXliZkyeFwhLlZk+x9klbJy8LrjNoWRtlDXhjg0+Ki3sLGluSnei7zGvIlfDJLwQjfDJOtOiD/wAWNV0L8yaW34cUdL40ekRxLyOSiiUnLvIq2JeOEnSIx5mVWiJy5V8AlbLSFJPYW/HJPlN+9gqQkIn7nSEq0QjJG/cupd7Cd7lkZWThzcdu25foquMI2xCfu4baDfLueqxZCeO9V0rvU6IPwT9srE7Rlj5Iq3Rk/bt1Oi4s9JEYqI3Ri+xv6G+UbvipNFxluNV8DFklzIxWnXBR5LfdQbvg9RvwhvlG76r+BjuRenBGXbpUGyoxG77PH+wiT8CjRP8Ab8S76Kdi3MuxDYlqNUKLYsX2eyBLI32uLcboivJepLf4RHtFylxHMQ1cRbHgolNIeRvt8W4tWZJVoJakt/iYsiSL0Mk607O0aHKemz05HpyIw5SBJ3IRkVS75/khxnv21sWQU7PB4JqmRGk9xw+vhqOVkY6kBD27rG70PBJWheSUmczOZ/DJtEXZHTgx42u4qzHGhbC4S0f4F8DFaHksk0j1keqvo9SH0Xj+j2Drx2fMyEnYhOpULcyb9+/xJHkiZEVSt90mZN+Y82ZV54qLZou5XB9NV0QVseh4FohyW43fdQ0RLUSpE1aPTOVR3JTb7pdak0Jxe56a8DxyMarUkPhNad1CPngnw8cJNvf4GtL4ptEJt6cPIteGhPHWq7jHCyUlElNsjLlZd6iPJKNjVdK7uOsWuMY2JVsLfhsiU2xNoWX7HGMthxa37WGPzIll+ujFLxwkaoceYaroqu7xv3ElTIxs/wDETnWiIqlwnO+ixZPDHDyuzVR1ZKTlxSs5Psioriyy7JQKNIrvI7k4cxtoiUq0RDHbt8Jy8fApacJC0Gr2Ebk495DHWrG/A9NiMPvhLYlv8BDHWrG0hZE+EkJ0Ncwl4J6d0sbZGCjw2Fw2FJMnC+/jFR1ZLJ9cYZPDKscCNo3Hq+5xxVXwZaEuEpJEpN8IZL3MkL1Xeqof/Ryb6cUvAxobr8j/ADJvY2NWJUXRLL9Dd9EMhOFaru0668W5knWxHKnuSdvuUUWjVmxk1164z8Mkq+Bxqojdvu47nNFDyIWU/b8Kd6Mar4Ceka7x9GKRkVS/Dd9/iVyMjt/AJ0ZNdfiI+2F/BR1jXxGR/wCPwUZcr+HTp9S/il/FV/38v4pfxj/ma/4VX+31/FL+KX83RRRX8RZZf+yV+Wiiiiv9JWX1V/B0V/wZ/8QALxEAAgIBAgQFAwQDAQEAAAAAAQIAAxESIQQgMUATIkFQURAwMhQjQmBSYXCAcf/aAAgBAgEBPwHumOm0f75+JHlzK21Lnnc5sC+98VsAYpyM81q6kInCP/HmMoOty3Lc+MKPX2+1io1Dn4oftGcM2U58FLsQHP1rOd/pxL6UnDLheVD4l2fb2GoYnDvkafjmcZUicI3p9XbHJcvmzFsE8QRmyMROn04k6nCysYXk4h9K7ShNIz7g/wC1dn55x5LiIN/pccYmZkCPd8R7idlgNk/dhdx1i3mLfmbE5inI5GbxLIBjnZtT6B7TxS5TV8Sh9S/VwSNoj6h9OJOLciLdDcPmPZq6QHbePaB0nmsMrqC9YGUTxBPEEbwzHqH8Z5lMS2eMYLBLX8s4dc7891nhrmUJpXfr7SwyMThm0nSeR/I2R6y2/AnmcxeGJg4bHWHSnSF2fpF4cmeARDwxMNOifpid5+kafpDBwc/TSyop1iPjrDn0hf8AylbgRWzzL+/Zn0Htd3kuz8xGyIXURuIHpDYDCVgZYHltp6CBNZ3iBV2EDkQW/MzLukXpzXcL6pEdlODMBhDUR0itiLZ88nE2fwEpTQuPa7yrGNdjYTLGeGxmgzTFSPbjYRdRMat1mWE1tNTQWuJ4x9Z45njmeL8zxiJX0zGzjaC+MVaB8RSDGqBhQpFsxPEbMsuCrmcOhZtZ9qJxLuJzsJ5nlfDQhK4Wd5pUdZ4gH4iFmMrC53lYGPrgQ1IfSHhkMtpNR/1KqtZg4dJ4FfxPBT4+tlVinOIHInixHEFsFgMspzukw2N4+S2JSRp5NWrp3rhuqxLgTg7HnZgBLLCxxFqzFVEhsJ6Q6Vj256RVd4nC/wCUFajpLqMeZZw7525uL/CcMPLztUjdRG4MehjgqdMAYRbCs4d/E+jVYOYu0WzMLgTJeAY76yoPBZZUcNEtVunIzYjtnrMqJ4oE8cQ2mBXeV8KB1gUDpyNVizUvNxP4SgYT7DNpGZu7ReHGPNG4ZTEQIMCWuVXIi36p13mPWZEXpt7Ayhhgyypq5XxGNjFcN0jWAR7hGY+sC5HSbQH4lXDF9zN0bBgbIzynmv3SIMKPscS+TpEop0DkesOMGWcIy7rFtIi2Zh23ErYczOF6wa2/1AMd1xFGncQEiM59YoY9JXwwG7TibMeVZiUcP6t9L6vEH+5w7/xMHZOwRcyisnztz20JZ1ngBFi2/MU43EVwR9SwXrH4kk6UlVRHmfr3nFPtpE9cCKvm3lS7Zl1ugTPrOHoz5jyWpg61isGGeQ/edGsIB6fZ4u3zaRM6hA5WLYDPHHrLOJ+Iuu47Sqla+neOwQZjMScmYCLmVJqaO4rWO5cyinWcnmxjtDByscDMNb2Rqmr6iHGJgrvNWoSnh9e7QAAYHe8TZqOBEHqZYdTYiYqXUZZYXOTAJRYMaeY91jP06ziaNJyJX8GWVmv/AOSi3TAc/QHPatn0njY/IQMD0+tz6FmMxxpribeYxmL7mV1lzBwyYj8OV3WU8R/FuU97YupcR19ZVixNJhBrbEof0jtpXMq/DtiMx+HB3E/drg4ox28SV1gTiSNhOvWV1Fz/AKioFGB9XqR+sC2VdNxEcMNvYb0lDaTOIUMMiVviM3iYHdW1oQSZ0gOgbzOfMZXV4hyYAAMDmwOvsN34wbGb5jjS04fBPK1irNTN0ijHZ8ScVmJ1h33mcyr8B9o99a6hY3ScNLRkmUNAcwsBGvAmbLOkSkLv2vFfhAJ+ZxD1lf4j2Rs+kzbCbYVtMFJ+I4wZQ+DF3JibNNUVHeLSq9vxX4wzh09YxyYn4j2m+vIyJ0aVjrNPmzK6wTnsyG9DM2fENxHUT9Ss/UVzxk+ZdbrM6sIowk9ZUcr9k9qPuW7GVPviGJ027Y1qfSNwwPSPQyw5Eq6xGysMrtKxb1PWAg9PZS2J4qfMssATIj9YPyi7nuuLTTgiUdYp0xhmV1IB0nhr8Twl9IPZWrVusuXRtCcmGVbDMW1T3BYDrOItD7CV/lHbSY35Ss5UfYPsN7DXPTMtXGJUpYYE/Sn5n6d/8oKbR/KabvmDxfXEGfXs/DWXVqUineWrmsND0E4f8PsHtx9qw6nMG4Alw3AnDnT1mrJwO5M04YiVYZdMYYGJwp8uPqXAgLHuTzgg9OS1tKkzETd441NAm2BFUKMDur1y+RKzicR+U4ZsTxBNZbYRK8ewtUrRhanQ5g4o/wAhFvQziDkYmd5UMDM9ZW2e6sf0mMxvKZZuuZXs0IzFUDpzHuw3mx9WRW6y6gJ5gYzkwbz8RiEnO08RkMqvD9xbbpERXcxUCyysOuIux0mAaXxMeWI+OY92502A/WywIJZYWO8KYXJlS+abudotYWMit1j8L6pFuevZ4rBhkdrZfvpSJR6vycTXtqjbjVKmyJsYGxAc8gOe74gZSVtqXMtsCCMxPmMooz5ml7hnx8SsHErTSOQgHrDQVOUi2+jbdm5azypK6lQbfUkDrDd/iMyxrnHSVn+JiNpOIu8xMaYrzM3Y95Z+JiWeGIW1HU0pp1HU0uuCLtK/NtK0AHOQD17MDHPY3nJjeYahKHyMQjMDlThocHpBtFbvLLMwnO8rr1HLdI1gAlr65w66YPYLrvQRa9cehl3EyVORK3yI6aor+GcGE+oibjujYoj2aoz6pXXk5jiWOT5REqzGDpKLvnv3uLnSkrox+X1t4fO6xW0GLYDLEDCAshwYO5utOdIgDesJJ8oiUH1jOFjMW6SqmKoWYzLqCvmSUXZ2PeZxG1XbDYSutUGBy8VWMapUdorwAN3RUA5jAtBprj3wIz9ZXw+OsAxyXUY8yyi7Vsevdsmrrz8YfKBKa8jeWUMN1iDC47knAj8QPSeIzQxE1HMp2OMc9tODqWVvrHsN5124ijAx3dm6meA59IvCn1j8M3pEJQ7wfYdCp1LFOoZHfk43nDjU5Y94OTiq/wCQlDakH2QAO/4lsJiUJpT2B11LicLtlfaLfPcF9icaLQ3s/SULnLn19isr1jEHT2Z11DEAxtyn+lH+lZ/5bn/yif6Uf+14/wCCn+lH/r57/PtZ/pR/rWfpmZmf6TiY7Yf8zP8A76//xAA6EAABAwEFBgQEBgMAAwADAAABAAIRIQMQEiAxIjAyQVFhQFBxkRNggdEjM0JSYqEEgrFyksEUQ/H/2gAIAQEABj8C80K9N9j5ygd/6fOhCLd8e4Rszy03xTn7uR81dp31Ex/vvg0ckO+6DOZQHzUU070qEBzG8lfyJTfTcyg4/Lpa76b4zzCdZH6b6FgOhz2bf25QydU1nfdQnOPy6HoO3oKY/fNcm2gTXZZRPbK48mpz+m7Hf5eNmfpvSmuCaTqKHNh5556FQjZPNDplPdWrsjii/m5Ofue5WHuo+Xg8cigRz3hCc1Osjz0zMbzzvm6QonEO64Avy1+WqiAn43QStlwN7bEctU1ib33L+jU606b+qr8oGyPLTeuag7oUCOeVjs3dbWnRVpl0Wi0Wy4hUtComFicZKCZGkbiBxFYeZTeprv2sbwt1+URaDSUHDnvBdHNtMrj0Ka6eV2qq+fRbGy1VVdVW/ktFULS6l2l4sy6ueSi/9LdE1vdRvsI1Kxcz8oliNk7VuedbNyDm6HIxSsTdOYWImD0Wy0rZaqGEcWqgEriK4jknmqlUU/5IcSqWf9Lh/pcP9L8v+lsBwKhhJCqqql0iiw2m0FId9FQ5Pht1ch1KfaHlvi4ra1NT8pA/RB3I658KwWn5Z/pSL2tZUNu0WmSpWyLtNzotLtFotLqqqpfslVCq1bLTKxP0UDRGNZrvv4hYjqflIrGEJ4m0zyNV/wDj2un6SsT3QFgsqMurfS6iqtFVQtVRVv0v1Wt3K+gXCtCoepbmwoyqcJ1CxMO8wt1KDemvyo9hRY7R2eqL29aLbcSq36rYaXKTDB3RaHYo53aKoqqKiqCG9Sqly5rmv1LZcZRdOiLscAKtoVxuXE5c1oVwL8tqo0LRSyhUPFFLdbqZpbw8wg5p13WIouOpVeI6/Kgd1osXNNfl2nSegWFgwtVbtb5tsR7BRY2CwcDey0VQovxPZiXMKloFskHISOaHfdw4LFZadFWh3GqkGvTcxyapPC35VPaq9UbJ2jtFUgKrwvw2EriwjtdpdotM1AqPUGq2lS/RYH6FUIvwxWUxvQbmckto5YbQKl1VTJIlBtt7qWGc0cyqIDman5VcTpC6lStp7jfoqlaqhC4guSpl1upfouFaXUcQqWrl+aVW0X5pX5pX5pX5pUutSqucqWrlS1KjHRVfiKhFnwtFtMIWHhPdaieqgkEKW3E/EgLYeCpwz6KHiPVUq1bBg9FLSQotmz3C2ZnosOEtNxc5G1f9FjPC35VxOMBYLPg/7f0VKrkFAlx7LE8R63bfstkQqqirfRRiqgbKoXCVwlaZdM+qOJTf8P8ATCbGkVRdjpPCiIGLktLuJy25K2XKQsTDBWH/ACBB6qWOBC22AqbB09isNoCxyh1Qpaui1UWjJQdEWYQY1Nb7/Klau6KX6dLtsrZuizbKxf5DoHRYbBoJ6qTVdXXbIVbq6qtwY2klBoP4nO6t+i4QuFUJWy5cMr/4ocFpdQQO6raBfmhVtAvzFDrSqB6KQZR6zceanJRaXTZPIWH/ACW/UKbN4Kh7ZUt2mf8AFslbQVaqgWEaKXfp3Pwf8fX9TunyX8Owq/r0WJ1XFS5bN2w0+qm3OI9FhYBPQLaMDoFUqGCiqbpdfs6rE/RFWfqmP6poRZ03Ndeqrd8Z/wDrm+JZchVNeddCnjosd0hy03MsJaVFqMYWuE91isXQVgeyVtCigXC0YaqNH9M2JxgL4X+Pp1UDXmfOKarb1VPAfBsPqVJ1XdbRlYW1PRYrep6KCQOwWGwEDqtaqiqumTYbKm1d9AoDApZVvML4lkg8cimWgQ9E/dFR1TWjkMnw2/VCRsHmqVCdZHgfwp98C6oWwVpcGxfTID8TCOih2qtAcmJhgr4f+T/7KRfWruij2av5HU+d7Bg/0VhtBhdvjZWGnN2QNbqVT8S15lROEKTVUupd1uoKdSpftFQMmJn1CxN0VrZc2oFAsd+JqhhFVtbhyaO90lEiq1WzsnkV8O1XxbEw0rFEwv7UBRzCwuEHLUKAhdIW0tVRQVs6q0bqcCnLh4mdCtHT0UWIwjqVidUlYyNt3nkFQ8SOqjiYqGvTdSdF8Ozoz/qpueiotVphb1K/ce+4xDTmiP0vEIhYinIgiDdXMUT0FxW0JCx2BwO/aeaw2ohfFby1RYeitGFYuqjunE6AL4j1s5oCDWbRQBLR2VIKh7SsLmT3X1WEck4gbTqXdCu60qMvx7X/AF8/6t6LFZFYbUT3Wydx8NnCP7v0WmSq2vZSfa4MHNTxO6lRuiBTCUVhWmEhAHnzXYKC0xmPorR1zW9SptIJWigOxt6HVYXVsnc+iLU8N/UtpxlfyUv0URQKdPqoF56lF5Xw7L6ldXdbxhinVYXsAKoFLdSuLTktL6qeV0oB6Bbp8gS2hVRDlLaFRatxBbBr0y/DstOZyQTdpcA3VbR2robqi9xl3RMf0KBHNPnkdzLiAnEaFQeSrQ9UCeNuqnoqoAbIUOeDl+icepudjWqn4pIVcU9VriYdVtclZS6AQv3BbVSj8QqG2oCra+6w6m+BwhCwsVhb9TdVQ1DBVd2InpcX2bvooeK5ouFmTvqrYbK2/bzHusNoPqqVClhgrB/kf+ykPb7qAcTuy6DoMhWtUJbCM3UupRvVQB9V1YVThKNk7Vuid0KG4eS6MOgVdEHBa3YW6rbtFiY7EEJMhUWl1EdlNB1uwQcIU0JThopeYCIYT9VpMaLE6zdhQ+E6AtFQBHCMDwjZP1BopmTdA1Kwjjcv5HU3QdVxIF+nUJz2vlqf3RdftBTZ17KDQ3Sy+FjZxNWLnz3cuMBRYD/ZTalUHmcFSKtUtVVS/aVKKApfQKgX8QqX4rTh6KBdBRYdDogehqrO1HNBvWig8sx9E71WsrZ9rgFspwc2HDmiHH6IOAic1bnBpB5LhXxLNQ8c0ByKDui+HGpQ7Iu5nRSCQEKrFebQ/RfEtOI3ErC6rn81V5RsXHEwiidZ/pciEGjlqtEDftBU2moliBOpyT/+t2qkabiSsNiMR6qbYyf2rv5vA05Kut0kql2FtSpNXXfDbrzuwtUlY3/QZYX8giP1WaIUzDwoLszcLddSjNBdCeV+IPqnMYKHmuGStFLMzvh8SwwWOC/E2mLsU4WjpHJMMaHVeqA/aisT/oEGN1KDXxIWKxdF2HqsZ4RpfBRjQFAWbapr3GYTLQcino2wPKoVKJrRkLl6o4OS2demT4dodnkeiY3Uu6ZaqG7TltmnRQwfVd+vnFNGqVLrx3VeM63d+SxHU3SVjdw8s/dGeF9Cn9AgJiUfVQxyjJE7TbuxWJpUoAalYefNdStptCjg55yXiYTxqE2NUwnUohN9FI6VuxFFy2nQVNk5H4lIugXlxqFHNRT6KZEd0VaRdLliCAvbhGzKA7SjClV4l3vxOEj/AIpY6btowos9oraP0UuXRigecU1KqsLFrcF8Q6N0uxOWN30v/gFG4A1ceSKF2LFELZ1ybQ1RJ4Ot7B3UcmqBVxRxs9CqiI3FUcdpEr8M4gOisAigOycoGqqtkQ3qViw1vj+8kONSth2E9kaYj1X+OF9FVvEpRCryulcSK+iwi+HKuq0umzML8wracTdSpWK09vOp5DS6i7lQLmtUu0U/pGgvwt0UDc4/1BCBqqXBrhKnIS3i5L4dsIuc1AdCrV6xv1KJbWFGh3EuWCACsCs7T9JTWzQqD+miKc/3WN2nIKpgdMtFtUXZFSKqW/UL/HF0lYbCjRzTXujo5VUqcQRDqSi0lbIVTW+RxBYXCnVVqLpYu6qqaKmvXzr4Y+uTEbh+1l2EcA/tQFhasLVG7D2/p1Fx6I4DHdYLQQ//AKq5C4io0QpNxWHqVidpyCBCLbPU63VCkVRAO2KoObdidpdIVja89Cj2WN50oFA4kfjaymWf7inB4jpc3upByYXCi+Gf9SsTaPPJV1RTCR9bsKgL4bKWY1KAC/8AKi2HnEEWWv6dEXEdlFkynZaQpxbSqMLlB5py7KW3awU1p5lQPOpKxHJCn2VdTUrAzh/7dDbiTxbw90Vhj1WwhIy4UK3fBw16qFZsiKL0WMuElTyuJbFF8QiFjs3UN1SoNzWN1xJ4tANKEJjPqV6IhWfTCoKYPqoGgX5ml5HI3V5LFaMpy7LHZ1IVqDqrI9UUSoVEJVOqktIHNBw0WJ1Y5Kgi+HBSNL9hdCoQI1C/lzHnUdLy8qbsR4WLAzhugaXi0sisFpR27hOCPQKAFKAwKSVS4lTOinspQeP1JrXN2m80SiSmfyqqIBgMc1BCcKxyWkKMJXCfZcJ9lgwEAKDUFOJUtNf+oJp7XOP0TnN1K9ea/igRNbo/tRyGi9NQmW1nSaOCtZMLDiJcHJxyapwgn6IFwr0WID6LSMxZe14o5QeIXYm6oObkc0cvKtd1Kk3BvVFjet4srPTmeqpfQLQFRp2KllHL4dv9Duw7qFSk3OMprlUqiN83DERqtaomtVBa4qA0wFw/0tFouS5LkuSrzXJcAVbELasVwEKcVVRwRlRFCqNIA0UNaVpzTnO5JruqbaMmAmP/AHiqfPCKqerk4hkOHNQOeSgmFNqKJgCGfFebM/RYm8QUqV/A63kp58roYVRK1hUzdgu92LonHusIvgXYrT2vqFs1F2G02mf8WJpkbkHugFhePQohNGXRdFUlAhGgRiEa3c1zWhUQuFaLhUYSqByq0rmjtKjgoIGinBCG05srZtJ9VtWYd6LaYW/RUcFooAhP9FZt7LB1RceSccOiBu7XYRovhRMqN2HjkgViGhuhfCdqNLsPVE9fLdJWw4hdVtthcS4woYZJyd4RPVVupdidmquoU2J/1UaO6bgeuWtV0VVS+gWoCq9VJK0K/Cf9CotGxfi/UqiVjZqpC/6qkUTQ6C14Ra0lpVV9linD6rZc131X4lkgqOhdVULYeWrk5YbVpaqOlcNOq2U6EAnHotorYqhjbtK0d0WLtuZvLTyRCwlSg4ahB4VEG+XVVCtpq2TdCi5oXrfS6TrudoLZ2lgtPpOZwJiqw3Ybq30u2lS6NVHM3a1ug1HQqcEeipiQ1Wi0ULoqp7XMxxotnZeg120pY2ql5ntdRxX4zIP7mqLIh7DzQZ8SFA2woe1awuq6LZdiHdS5uErZIIufCrVRyai48k0uo5y1ndRdIWsLEwqLngHZQJ8yqFPJSApux+yl11Lu+8hwlGHGOmX4g0KKm+l/bL0TLTVuhWsynX91iipTGuMOcj21uk634mmJomMdhd/K5jeqd8SjuV2lwjQ6hC3boqUHVHEJCxWBu6+q27M/RRPupYcJ7LaGIJzGuiVDvdCeaLT+pM+IZ3frkovRet09d3VQNo9l8S0oOQ8mN8eIcLqILtfXJstXJQ5hkLDh2VwLhWgX6VRzVS0CGIskc1GNqnEFrdELhU4SuEoEDRD4zBI55Cfoji5LFZyJUtaiHiBfGKVRUOiqpWG1HxGL8MyAm7ESU2f0hDdAqb9luJOCi7Dzbuav9lFk2F+I4hqoK9fJ2jOT4VwzaLQR3VXFbDbgxrZK4QuIBfnL89fnr89fnlfnlfnr89fnhfmhcQu4Sqs/pbTF0XGqOF1EcQ2StmqlvLksQd9EQDULYBK2yqLEHeq24qsIUsqFDqFY7Kh6IWmhbqEI347okXFDoaZtp4UWTJ7lfiWkBbLf9itJPlIyxcfCSViBqeVxvlxotkKpupc70uqb6BVoqGVULRaXcS41xrjXIraswq2a1cFs262bQO+qqxRa2X9KkBTZPukit9TCwWdZq4qGcTVtchVYY2SonaCw2n0KxN15993UqGqFNwT/AEunrcATDxdtPAWxLiv2jspcthv1Uv2j5ZCm8I+FDRzUm6iruH5Yau6xOVKNXe+qoLqKpK2SVRyhzQVzCo9cUr8SzBWmH0U2H+R7raaHjsotGlpWy8XYmgOjksIsxZtU3i0aK9lhOqIOrV636rW7QqjVotbwbyxWl3pdIXG6/TCO62toqnljskc0JRQ8HJRN7uqG4OdlmNMsC6Bm2b9VtMXEWlbLwV+LZyth5YVLH/ECw27MJUsfN7XKQi93JPPLJJv5LkuV2q1UG8OVo7qi7oiL6rZEN6qdT38vci7rdJXxnfRONw8HhGQnIRlb6Z3lRlwty0Vc8HVUK/EbHdfhPlRb2f1WL/GtcJ6KP8plP3BSwyvReoQs/wBTihOvgQ3onO6uRvxv/LH9qB5gVFzbMc1A5XjwblPW+Mhy2br4urc7qTlhvgIcoavxNpq2DhKw2oxNXxP8N3+qNnabNosPNYeTfBj/AMr2WY/UUGjQeSVaqrXdQNcjrQo+FJU3+l83DvlaemYnJN0nXwAQcOSKwnULqFNmYd0X7bUaFYLSjwrW0IqfBmz5TN7rT9vk+l1FR6oQtFVi4FwFbDFJNTe5DuiLy08/BBvXIXZITDu8I1KrdHK6XeAN1bsY0N2Jmq6OCbbfqFHeCm6bw1jac3eWUcuRW01UWuXCdQjeCFD6HwPoL4CAySjGoylBVvroieV3fwZyFYTdIRHUITqfAFyjJhHMwmsHLy/SFte67XFBDocgu2XLaatd6XdESed5d0zQeEr+LqjIb55BUWEXSVJzdvAlOjqgVHRCd3QrQFVF2qgIDLZ+ZOi5yF2tYza3bJVRuwwc8nrn+G7jboi06jIVCACc8onqpOeBvhcRfaHvc5QNBqeu+oocFS83h50WJpkeZEJ18nwjjkGcOahbs/2vCde1vXcRvxld/wCVx8BW+cuyadFD9kqjh5gbje64eAee2QbmHcLtVH6Tpe/1va3oLsRzT4EFBFfXwRuhAIZdVRypalfmLVpW0xpW1ZeyqCFR3k/VRigJsaIQoUXOujwB7742Z426KDrc71veVHhTcLz6eDaESpuCNznvE1ovywvywuALgC4AuALgWi5rmqOd5LtOu4VibpN0q0kVi43DwDRnGcdCvjN/2udcU4983bwBRQuwoojwR/ioU9bgpuP/AJXFjaxqfNCOoR7o+CYO2cbjar1Rb+nkmnqLneiPrl7eCOV3r4InqVFxQvwu5miFnZ6uUfqOvmJFwTXLEEbmu3FSosW4itrXM30zjcQo5jRMNzvRfXJA08GU4XhP9fAuKrlhQmt/XKm01/55m9vVC74btQi29py7RUWYU2pp0UNEZ2emcblsLEOt1oegU3wPCFG8J2cldD0O5Yz63wsPTJ8R3C3TzRvUpzrg5Wdo3RwQuLH8JUjS7WT2Wzsi7qdyw78FBwRZ1UHUJ38qXwM+u/GQO3FQqOK1DvVbdkfoqP8AdUyOPSixu+ilSpyWcdPMyToEX8uSwqtzWO1aaKL4a4qrjdJ0VN009/AYCqrH1Vm1Tu670etwNzTuqrZPutpsFTZvPuqw5fiMIRFkTiKl3CNUANLj3vAu+A7ibp5n8CzP/lfS8Ii+im09t59fAUWqLHcQVeSgeJClBNOYYjE5qrZMLaE3YnWn0UCguhQqJsqlwc2hCwupaDUeY4GcZ/pYnarEVAkrEWOA9FIuhBwuj2QOsFYmHeO34f0uhBzV8eyFDx9vFNTwheMgPMFNPbcRZ/XPiVBJVWx9FQwVLaEc1htKP8vgcZ0WJ9XFS5S7ZYthteqqsbNFIQVbvS6WfUKlHdN2/wBN+9vbJWrTqFs8Dqt8U5vUL6qM8dM+Fml3dYUewRvhmnVfud1KqAqUW0MbVsarDabTVLD5Z1fyCL31cVFmJKxWu07JBUcliCHVTClTdiYYcF/IajdH034T298hsH+rCoePCxeUE8d0UMpGaSobwqTqu6ws05lOw6BQoUlfDZ9SgxmmXoeqqMQWKxMLDa7LvKsFjV3XopecTipfstUMEZu40RaVHI3EIsvmcFp16rBaiHf93NOJ1Bv6pr/3ZJGqFrEtNHhS3ZPZfhvn1W20jwrgggeoTtwDfJX8eSk3dGcyoYOwQn6oxcLKyCwjXmdx3VRI6qOJilp8nwWWnMqGD6qdXddzi5OWJdwpUrENDf1WG3oeqlpnMXYsMJ1qaMbohv8AFzbldZv4X0RboQtZUPaui/DeqAFaALULbe0KryVobqXTu7J/0uOYFYbqqBwqt38BqVhaIAVOFqJRWFnE5U4uZ3mJn9LDaUPkuFtGdeql1G9FDRA3Oq5AC7spF2G6RdRSx0dlhfsvyYW7T+iDT7IsHLJB3hZ1CLTyy/EHGzXuMlCVxFam7aOTS+lCqrTL2TbnjpVNRzhYiaKG8N3ZQOHmUGtFFgZxH+rsIQYwSStrjOu+qFHkeBik1O4rr0UWdmVLpUAAKUQpWFTdOSt2G022rF8SOyLbAQP3FcySsb+Mr4Q+uaN1HNYuTssqnC6ov1XJaha3UVFxLjKo5VF0H+1smFswV+WuHD6rFaOxFGLgnDqEM5UoTOG6miwM05lQKALBYf8AspdVTc+3PoPM6bmSBOVyouykZIKkaZKtrczF9E5yJObFupUjUZvh8/076l+q1VSovChUzSVA4RfC+HZqpj/6oGyzpebmRz+QC52gTrR3O+HaKmlxs3c9L5bla4GCmsfHr18FhOhRbyNRlohbN58XhhcMsuKgUb0uqqXFtgAXc3lS9+K+AoFxsHerfPy51AF0sxooCA5oB6xM0WEo3SOLmpF0i/ELgDkjId221GrNc2F3C6hRY7eUVd9LvZf/ABd1JUC+qpdgbrzVFi1VEHt1CxDXmPPZdosLaWYUKLJsqbV/suFSzaasQ0XdSFIWKzHqFIUKQqqDmnJO7LH8Llh/SeE5qfms8DXcQDiPZbMMClxJUNXdENvoq3Q3iXdU06rZIKhwhyluqxjTmEHs0PncuMBYW0swsLAptqdlDRAyYrMeoXZY23BzdVjs9m05qCIKhyJOl0nNG/8Ag2unI9FgfrllfFZwu18KEwNEuctt1Ol8C6AoC2jDUBZ6XUUDiu+Ja8H/AFQBAu2mypHAsTdFgdwO86xOMBVpZ8gqUb1WyPrnxN4v+qG6cwu10sMFYP8AIEO5OUrA9dt2RvMJ/MbwlQdcps3qP08vAzkA6BVK2RKroqaKJrdRbZVFWiw2SgVKx2//AK5pbw9FibovhWn0PnEu0X8eTVNp7KBuZHGi12oU3xEt6LFZadFB3AvDt4Chb2f+2WQsJRa7Ub+Lwgn4b5dQLDZqTdQKXLZ1W0VsNp1KnV/XcSNOYWJuiwu4x5tJVNFTXrvJHMKmSijcRdVEKDvDZuUcuWSViboviM42/wB7/FeFPQJ7upVaBbIkqpvo1S6puizErFbbR6bumnRB9mp58/NJUmjFA3ru12NxjooeFRTvfiD67wFU15ZcDl2XxWcLt7GW1d/FaX6KuT+I1WFogb3SnRfEZwoOHP5CcUGhADQKCJRdZn6b6Co5ct5C+K3Q65JUHVOsX89EWnUeAKtAtFW7kFrdiOiDeqljz9EMWu+7dFGtmf6+QSijaHV1792MnfkoO8wuRYeWUHmhbN/23cnKU7FotgLWFsyoe5bDjKg6otcm+vgeywO+h+QAxCzHMoNHK8Dqd3GXG3Xe4m8QzYXaFfxOh3OEZ4aCS48lXZXEqyqNVQqUKcx3Fc09vA0VdR5+93ROtTyyM3c5pHCd5C+K365sL1hdngam/EcoGfENQp5FR08FiFOvnznKE0czXIzwJaUWnlvK81h5cssFVX/3KSVidd2Ub0jonN6/KAao5ZZ6HdwpVcvxW8tbo3UFRz5ItdqMk3dWqWulq1vgcIugKBkgLvugflA+yxHV2V47byLoyFp0Kcw8t5C+I3iGfssTLsDfrdTN3vjcg/JxKHdQMxHI6b6DdBu+KNW677GzhP8AWeCi+x1u7KBkhTzyOdfOYs+To6ov+gzx+oaKDvu91VB0X8eRug67qLsTeD/meDosdiYPMLDEZIbv2nr8nQPRBu4+K3hOu8jLChwkKWVbdB3QBWFykcG4pxKHXQL8B0Ui4NF0bkH5MJWI6DclrhIKj9PI+DltCqqDruu6gr+J03EOX4ZkLgXAVJICxl5lRikXTz3dB8mNs26lAbotd4SqkKH7rusKLTqM9FXJRbXyyCRUbx/r4HsqX0Ucs8G6igqRxKHUO9oVtH5jd3r4LtuqaZcL135FVEjqN5X5kFo3Vuu+plkZ4Ot8tywdFRVaF+G76FQ4eNp8ny4wi0bW/ploq5ZC73VUto5YXiDlrdVbPzVPNbbpuO/pu6KH3w73W1VvX5wLjoET4ORmoq5YdopBug+yxWBjssNoC05q/M9UGtyx4Cm8pfVQ8AqbF+HsVVkj+KrT1WuSvh6HLRbTwqSVp8iw1VKhuq75J8DO9qqXVu2mgrgVJC4iqPVIK4SuEqrTfqtVqtd3qos9oqXPI7BfuCi0Eeqo5UlUs1rA7XaLCu6j5EnhbcYyx4+qpfXd636rW7Va3VKpVbDFV0LaJK0vq0KgvxDS8PHL5AqtlVN2GzWJ+05UUnc18TRbQWq18HidoqWZX5aoxawtqb9btM9VTS6Co6Ieew1Vvl1GqG0G9p4uioSuK6oWi5rW/QrQrQrmtStbtCoYyqm1NOl2nyhDb4bqsdrU9Mkb2HeQaLRaLRaXVu0u6C6nyjAU3QFP6r4C9d/23EeI0WmWirQeKBHnUBQNTdAygb2N9I8FXNDarotoytN5qtd5VVuoh5vKkr0unLPgu27p4DVarVUWkLaVBu6BUC1XGvzF+YVS1VHytpqruYKlixHzjCLp65/XeQpzds9VQ77VbI8DqqlaLTc6KnyD38m1VbtVqtVqFxBcSoqNWqqfItfPiSpuGcb6NzWuXRaeTVzUWyFUhaT6XV8+G7nwvVbXlNb6lbNV0VclQtg/RVEedemQXzed/G8otrymGVK2z8hkO55IyRuK76m52StryalB8ixkjrlg56qniKFV8i2aqXbiq2AStLtJUGhVPOPpklA5JGvhKXVzU8iqVshVK2albe5/apNT3VBkrQ9Vgf8A/wBVPNarZQJyluWf0uzSPAUW1udPC0z7IW0VRV3ECq2yqDcfyGiwu1GqkeZyVXLFwykc1B18PQraVcmq1y6LTdaqiowqsNW06bqZKXbShirua7iBU9lJEet1V8Sz4h/ai6fMJyyMoOX4jfrv9N5rm1Wq1vnNsAlbb8KrLvVbLQM1Lqm6GBbR8DDdp3ZTaGB0CizEd1LnElbJW2JCkKRwvr5lHW83zkwnTLBUcuWfp5DRvutp3stM9Fqq30Vdzs7ipX7WKGiTl0XxLHUahT+2qjzEDpeclMmE65Y58lhdqM9FtKnitgEquyO623FxWy0DNTNQKu6hql9c9VhsR9VtnE9V9tw+zOh0UdD5j9N2CFOWnGNCoOo3FFtBUPhKKjPdfiWnsuGfVbIA3FVVUvrvJNAqZ4bUrFbugL4f+MIH7l3O5DhqneYsfvMJzTo7qoePrutpU32i0VXqon1WywDc1N1B4DZUmp3H7WrCyrltlem7aeo8xc3eSF3zQRIWKyqOm6oq3xdXwOt2y1aQqnwEMUvqdxDVitCsNjst6om4ndsd38ykaOv7biFXRSM8ij+qwvEHd1VM9Fs1U2ntuaKp8Ht+ypnjmpdooaJKJfcUUN2e3mVnkg7mDpuIcFI2m7yuSiholbZVBnoFU+MqoZp1UuVKC43G4bt3p5kzLB03MGrVsncTEHsvw3SocI3lGQOpW2cRVKZNVRUotVXxsWYnupfVQKu6LFae15uNwzi43O9Mg8uae99bqr+O5lq77mHBbNRn2QSuHD6r8V8+i2GC/VUu18fLnAKLET3U2p+l2Cx911OQ3FDdkJw7eZHtmqpbpf2zw7dVC2XLS7acuGVQAX67uniKlRYie6l5m6SsLaNzG4obgi/1ueO98+XQdE5ueW6qDruYdoqOv1WvhqKvhtVRarayV3Q3YN09fMsbeJu4pqsLtd5XyqpVFQLaKoqVVbqrDZ1KxWhrlJzDetd5kXFGkTlrfI1UO13Ovktb9VqtkKroVXSqC7vk2jXoqbFnna3qcw3punzBvrupGqh3kFdzRVyUWqq7LVUvl5WGxp3UuruAP2+ClHzIgajLXPDvJ63UurdTLVUvlyiyH1WEGe+6e7qfkUu6KTzywclb6aePo0+y4VUgKrstbqbqSsNkMRWK2d9FhbpunH5GDM9c9FXf0BXCVwFcBXAuFaLkuSq4Kr1UlcKo0Z6byqhm07svxDA/aN6xnU5z5+4+AllFD8uq1K0XAFwhcIWgWg3uuau9htT0C2jA6BUG+A6Zz5843x4DZOfVVK18TW+G1Km02RfHNdAtL671zs58+A6nzaGhfiO+gWy2+lBdXwDj2+RrO4oeN13+uWAtq+lV08JHX5Gs3XHynXPRq23eypdsqpzU8A1vTcDz49q+C03Oq13Gu4oqNK0VSqlUVFrdUz4h57oZx58W9UR0ukeA0Wwtob/RcJ9lSzd7Kli72X5RVYH1X4j/AGXCT6qlmFQXUIVXKrlUql1d1XeuPa4Z2+fE+D1v0Wy5UgrhWiqQFtWiqXLQ+6/LX5TV+W1cDfZcDfZcDfZUa32XLybB13I8+gaC+PLKXV8XHTfR5wTkkKD8kE74ecNZlxMUHyankDj8juzYmKHfIobcPkV/rnluq6KvkFAq308ee3yO713dCq+MqqKnkJKn5Hf67mqliqIVVr4ai18njr8kOyyM1QpYq0VVQ7/VUu18qw7o+fHe1hTZlbTStb9fN5RPyQd7RbSqtmi2ahbQ8Vrkp40fIz753+0Fp4nXx0fJBd0RceeSM1c9fC1+VeC19h91wWvsPuuC19h91wWvsPuuC19h91wWvsPuuC19h91wWvsPuuC19h91wWvsPuuC19h91wWvsPuuC19h91wWvsPuuC19h91wWvsPuuC19h91wWvsPuuC19h91wWvsPuuC19h91wWvsPuuC19h90WtZayewWjlo5aOXC/2UgFc1oVo5c1zXNaOXDaey4LX2C4LX2C4LT2C4bT2C4X+y4X+y4XrheuF64XrRy0cuF64Xrhf7LheqNetHLRy0ctHLRy0ctHLRy0ctHLRy0ctHLRy0cuF64X+y4bT2XBaewXBaewXBaewXDaewXDaewXDaey4bT2XC/2XC9aPXC/2XDaey4LT2C4LT2C4LX2C4LT2C4LT2C4bT2C4X+y4XrhtPZcNp7BcFr7BcFr7BcFr7D7qjbT2CJhy0K0cuF/suG09guC19guC19guC19h91w2nsFo9aOVQ9cNp7BcFr7D7rgtfYfdcFr7BUbaey0cqttPZcFr7BThtPZcFr7BcFr7BcFr7D7rgtfYLgtfYLgtfYfdcFr7D7rgtfYfdcFr7D7rgtfYfdcFr7D7rgtfYfdcFr7D7rgtfYfdcFr7D7rgtvYfdcFr7D7rgtfYfdcFr7D7rgtfYfdcFr7D7rgtfYfdcFr7D7rgtfYfdcFr7D7rgtfYfdcFr7D7rgtfYfdf//EACsQAAICAgIBAwMEAwEBAAAAAAABESExQRBRYSBxgTBQkaGxwdFAYPDx4f/aAAgBAQABPyH7ospfRHLdPrKeuBWhw19bBCR5/wC6eRkZh9ZbaBLv2+smm3SJm519JuFIjQf7VLa9hM/Val6Ml8CGSGsP6rhKyPNbfSShFCjCX+1LCZK0ztGIf1Yx4FkRWrJAel+tompcTj0pc2kSHsCBvSfRU5sIb3if9ddXp/WOAMxLP1khoyUpp9d00jfoYtjMtEWl9J79Fb+yX+uyVZQhRtfVQjlzSeSZtYf1Yt3Q7KRCnMQ/StzYSkSpzb0yF6Bmgl9KQSPPbf66iBrFnRa/qrDqzqJ66gNSblProkW+WCAJnPTM49CbED4bXoRtWoRNkDm9tx9FDrCjlIQhMKv9eZ5dCcCSfqebEI6PBL6r+onKx9clUpwOcNDbEMQCIchsoeGQVdpEEW/Ui2fZmZxwpkq3uFJMJHmtvoMZzdBIeKL66mWSKO3+nodOGhzbvb6hE6YYzT+UVhST6UEdSl6nFproiSM+gewbNwmMUmNmCSb6JFuK5HYE9+vDqXPcrX5JD84122SCT2G/Qn+hQjL+cib7H12B3S3+oTafB8XjCT9OSj+0Ib5IV3vejY2KwXFG3Yj2NOVQscDdBNC/uMmTt+49CxQr0QrKHiDoh7GZFBdMm25jrRmA/aNIZojT9anMpZJDI3SBJIkwq+t8z3hCJi/p/wBQgc1l7DXy2vb1sjzZaGwTg5gubsYrxMjW+QYmdm4llDeNEyo3gVjtv2Ngm+Tv/OYTb8l8KcSJ12QKiwiQ5kTOgksCDCFqgdqZ2H4DPu8J8zQx2KaBNCscIk42WyFT59kLSfYwaJzzEM7vYgonTZ1KwvrJ0DCFFvPwCMf6j1G7GjGQE00msP1Lc2dMv5JDCkMlPDJIJSxrGy/JFXkZNRjYc9EkrQpSTsSkzNEhBZygZqQjOmNwMsYnkrDMhLJ9ExjTEyyw/Ie1kXsTWAm5TIdSbX4KuaEtiCWsoYjuwtJV54jj3CDTNRU3iAdQumt9aUa3/wAH/wBShG1aIv5C0Nj1sCKok3lZocEkDRJ+szMq2NcShEzsjY2oGWAgbhvwSJwEzQpkUQXlDwYlESq3EJ6Q2VSRIKrI6VBtEQJVZQ2phm3EkGjRPR1C/sMyVD7cKglKJwZ+I0RjIQ+QoEIZE6sQgzk9dfUuru8I6Gt/qmR8IZSq/n1tpG6JZHaQ9A2FWdsTtyqJQNqpGSFQ68IiDsNx6UwQLsWMVAyQLRhp92IvagW4fIv/AEn/AFZoNPkQfww4zWiBsmcg3mdoLb+QSMz+RK3fJqL9zE/gMA/gbVDSPY/+V/ExRpdCdk1D4STlkTXZIE0SEMNC4xyfuCQTST9Jgwoa/gZF+T/qiFtQkZSPItRmIfv6XiABS55+o9rvgLMX9sf24QkjSvkKF0vA1pDMrJjoQHmgwZPgkIpGCfyI8Sux5Kfxn7qhbKTxzAvY1ko28/TjwaHjY3sGTCjtL54QrLwQ7IljidiU8im00TgVUu/0VN/uY/zK/wDVZ8s0CHnoT/jc7GTKDyxNPwrEaY9sqH4I7NNvtkg36FILYVtEOjQDjSIORS4PdkzD4RLCZN1XQ9CEQgvKJfISjVdTFZtfIkHSiKkkPHoTzAgy0SnhrnzzQyE8QLP/ALg4YnZOLInh0J4Cb2JqdMyDA0+xlmJ00KhH4kfKePUux/Aad6Qr/VQhxsI0ia/AjxT8FJ7gxMs/qPak2OiXD3GqgOtYXWR5FgRmWQlgLGGNmokikQQ8xKodmN7JtDtgUg6Ai7iVyia/SmJ/KCE23a/cQS5pu0D8Daa8Y/sQ3x7iOr9nGCeDuxjkNofOSwfZ+zoh2dHcvyNEZLk8QzQj6GhCoVH5P1DSmChsx7IRZg7T0Oz5IfFS4IyGDMgJ90E8MypfqaKvAkl9fv8A6q2JI2zaEuWPGLbsRS49w0pIT6hJH9AV0XSyYw01+CjTVwxcX3McWgo7SI7oKbUlzMHZ+Shc2fA2TOVouYiDP4COz8DkTC9M8QzhnjLkxGhBPhVTAfIijUEDaDOF8VPSlKTN4WgeBnR4CB9kPCdlkb7htF/II0/yhlTEzLZ7Ja1EJeDcHtjJka8wO3HEz3iOAP7KCW4xCPNYYpXu6GdbGT2Ob2aEqcxPu/1SMPPhSZPiuCOUCefgKZgkctyNLTeD4MYeUwJ6Nu9IQy2u/oak7ZTQDus2KtFiU09hfIkJWZ9jT4icVWTERbH0CkI6Ib8r+DKEx09mN4BoPyLv2CD37EDFLjUES/0XPlhpI6gT0J9c27CYJ6JIItvJEwuweVRBewm0YnAd7Fji0rpiGmknciep/TiDexEEdyCVy9OxJbiCgkYQI5QIh3UFaS0EfQoa5+ASSJuXFv8A0qZixMHtK9xmLUhVFV2SNx+SJufoIbxRjlFflk2rpGLQTGIUsKTcHgaUJJIVMwjGSRQAclQKkFS7wY2xo6CTIqI39CiI0DGstkbgWkM9H6GiS3Q4JkdsiiA+woGS5DQ3ZGSzsl2K7mu0On10X4obPaHZ8ZjpGgH7UkR52iHQ7dkGnM0aeP6wy1jPDR+NDEpGSxLFHUj/ACLjvvYn0vqCMtl5E2Rle/yP7xZ+Ii0JkQy6a/wHmZ4Weehq0w3YECttwggT/wBOiAEQTPc3yTsybLG1oiVszIcIaykikMB9DvLR3oKMfsfOKiMklldDgiGhjLXIYwJ4TUvRLO+BNNV62hvRJaZYRjUBHKamE7E9bVhoUJLJ2UebG3kYe2o+SKXSESOd5EgY2p3xhv3Ib+Fky5LwOaUGUiuxBQHjpc4Y56ENCBDMEQyewpcwpEKHuBmDLuJk0wnED5Xsr+4pMTTw1ylh+hRcWYboIK7V96M9nslfjg+cbw/qtEluEPYOgI1QpZnPJ15M2RsY8zBomUTrQlpWxDiiGhE4QdmI8spu5RChewxxgg2+9ghSkulzI9mnPyiWLtldDmF2olrxCDMoKnaM6dWuiNSu0Nr6FStqRI1MhLLJ4mWFBPlbaHSzbRhjB3w5Fl1i0tCkOjNPsX8BZJCWWMHCNXYiUJUryR6MCM7oWM0NxYp7ZK8q7KpZRJiA0rIdVzpQI/eUyM02ScD0iP4MLYnLLBFGR8StH7cTKM9wmY2q22IX2jx98hBQs8B6mWPMYRdmfpMLYTLYwtexiEYSeTG0zGzxRA5uROwoH5mNSihbcvAtpNKBqZYzfwRZiLBryhUo9caarYjWZAw6mKVkS+S2U9DyyHC6aEy56XZMHh9Fnx6Xl+DyecPibaGLhgw0Qj7aEJlNfz/BUsmRbQjMHAWM0siac42LFlsMT4DmriMPwJXLGhOfRSrCZ5F2KTfhF0eArlvaZAIZkQC1VoJNddsuISGzeUI1TaSdrY/sU0xBCUyJ1UiGRkVXo/3KShfffchOv2g1KZ8ZLZp0ySpb8euUsjHv7mGjQ3xVKZllIJtotwJINkKmvgb2lRQWmnQ2nC6K728SXRAQ8nX0YlQ8MkJKmRpZ2aJWF2Y3dIWnIHi4RQnsO60LGFfYvRNOQ/QQig/MIEyHvA2x+Iwonxz2ZayYqb9w7LiR0UVgeqUHhyRe8BmcunZYlpYKg2wd0szm+JEPToRvE8EbZkJnny474JqxoXdYtLIpuCxybYRJSNpAnjRjKNDrI+R2MTgHPORxNFBSVSUOwx1/oElv8hKgSlfgGPuDZ+WJn0MkpbheRsneBsTsfoNkwfgxHCMjQFKCRDFsZEN+h5B9stA/A2VCB1PYKuCSUVSuIJ+iMG55FWe0pjuWQJ7UlKNyEiG0KEqEq8Oh83+mOktncknt6FvxT0KpFCUp9DXhulMC4jZTQiNG82BiU8E9E5rPftECFixJIhmH0SB/CSKBaSWD+IQTpYht12LZA64wCqPdi8i/ycNrIl7mw92XzJNoTOodZncCTXEQMIOXLEjp+QquxyZug1cCQ5Q9LoSqTSQw9i+rJHglA4TXBThNfcVvXYs+EFw3ApF1dEWh+EJkyHxahQtgXDFPUiO4Ey36EwbPoili8SJQ/I5oiBD27JWujIG03lvbZLpdhdF945Mj94hq2hMU34Jc+tzVAY/JV2NMki4+Dey6OgK30JyTJ8dwOYajKIAz7nsY2a/I7EdkoTWx1T2G12SO0JLaVMWKIgUJFJDPHlrIllBENiz5LoVo1UDEh3aYkDBbETme9qD2BZbNKmZiJ2O+iRnhtERrku8kQO5P6D82krFmXRqnOUrwNd6WLsDYkE5diovYvhL8lsQ7Ctg8bGYqF4J9CnUQxiYtqQq7IZIp4rSefptqyNsezdepfwW9fgVQpfc4wyi+/wCAwyfQuiErJew+ZEpVEsUz+AniCCe1suTxbJIutsma6UailkgsDvBDYLjTsQphLS4UyxMQlbzehsDo8kKbwUiR05CsfTLrbwZN6a4Ow5PDkmVE2DTJaVNhOQ/BLKxUkv1GRFfAsIWg5BsE8QhzoaWEDUkqxWBBgKOxqMoyfyXkSFo4UjYU4kiqhbqSjNdiIHqCSsHLbEQUThT5MDhoQ4Sl4NGFSjd7EuiTxGhpQ7DaEvKeC0WUiWrgo+MQ1OFNkEqmYJbINxo1wk2dou/5CHDdLJRnxaHrRKoa15PhavXkQtkspT+gpjEktsmP9FkRLbsIL9L+H3ZINO0yRtr4cM12aUiCt9syXYmWgm9xYjZ2y6I1COkP3E6NhNS69Imd8MeyV/IW0IMBR1SSCdNOPcw79ElR1kjZceKbGezOYaFnNUJZqnQdQ2D8i2yLmSi90JkiZJAypJZUh0pEwKnyOiKloEo5viWCAvwBzzC37kxJpmSgYO9ekKqVlXIonl1owREiu8vCKF6/fKppwQ0OGWCxy2kPoQd3pdHdF3sSu6FJq4doptmk2ukVvMkS1tc9mYRAqWcvcog52nsRWmwlTj8HgJveBMZjkkzPpekhJaF5J34bBL2rqwKj5AT1ezfeJjwisBJmf8FMKkOUwyEJbakLQ17HEiy9IMcuQhDvZ7NFYUw79afGwRGin4x0kyxpMxbhkU4hJMSjaVo3PzzA06LInDLEaMgTJTCfaLXYU8NQmWQ6sAvJLqgZXWueJJMXKhu5WSyIFXsOJvEt03t7CcokcJxdsKPDydILBJ/sh9zIEsLXkbWkhJ3Ty+kKVQlzPAzEaErdKGmYfJuzMqqbHYU1NZQjOSRqskuXv2HCGzOGWC3BAySXSJxmlyR8KYtqyJAUzoHbsRVqA5ZIZWBarUSFdDhNEJ5J1H7BdmOgkwLohqi/USEwvvDIuuiFL8iZ6tm3JjytbMAUb/O4YHUv1P0fdDSdmbosNfqCEIoSx9Corpx5K3TJCJ9yLm8mHkgw0SgShJNzxI/RtpkcwoBND8oau8DnvhBNgF/tBHhZ7DHnawkk7sT5GGbZrAjiy4SHuoYmy6WfDMfvgNuCrMwlZpLZ/OrBLeBttkqIFI1LXsJr/wBhcSDIFZLkvkM7EdONmQ4hCEwQllX2TOSsngacK0QC2OOJWt6SLlTW0Ra8FTqEsSiHIQlG9E53djiKhS5Im8r5QzZvsOkhvyJHtdIr0BjQ+xiFH3htJS8IT7cDEttExuYuQVDINYrbpCdpl+42OhMsn2ilmKVIVGsLLED3rEhcJfRgY0wmIqiWW+2S1CyLy0Tko8RoWqoafKFsiJMKEnZOxVoRlNEgZNT+WEKn98sT9kBTSkaXDksILjZ+YWJoMGSOzY/dC4q+/DN9H9CVMyg+xIP5LME2zJwJ/wAWEMJQKHwJfghCnSe2xu5LQk+5IWwsJsgxDdaidMfHuhFwdSNqn+dIapUi2Yr8QLe2EhsdrdJHmYIg+NWmN6ZHZbT9RotpSQOx0qGJf4QJZZa4GlIZ+yHwYZQs+pMHjuKKT2femibnIvPwiA1Nkoi7j9YwjY/LGiS3CRja4eA7ZsNtko5mJWmdv6L4ucShCgySrCCJp1seGaawFRDCmLJksQlFubLKiLIp4dNHsLQ3H5LIMnQHQx4Ks7X6EsQhDDk+0Xu06RIlOgmJNhyumSLoiAmHXiYnvah0ecQeb3RK7rC/5Sle5CrxB4nufshTwSbLoxLXT7FrSW1+wnoORG4cwQKChmlMSrW1t2uiSnYpNkTFpGLkfuMoDjHQWBdWRbWmybBCZDyOe+Y0koRVRkH5qeY2QobZ0hQXY7lXgLZ/MysvgSyo38MlcFCmBGrfU3C2iJ1QmTX8s6AhiFIhL71+JhJm1nvBNBZGWaHDE3MMV7hKMbAwoXLEihUtlB/IzMZouqf1EASmEGBtNkdmasOkc9kADjcYJlkBclGclwlLFaWXQqiNLXFO9sptDtXybHQTgSySyGxXeJuJQgI84ZNk8y73ofkHy10LKmMvMxoEuF1T+iUMPcC2GkghV4yjRJ0cPsrnN/A2KrKp9kQcOQ+9AR5SeUYQ+LbztCFwyShoSfNBKdexXAR+JbBEiICHsMizCbbW6P5yIXH8FxkTVNuGBSAeT2Ql2zF5FHsFsKTwubYEOM/7TJizQCq7PQnC1DlMdRkTrp0k9VJ96IBcCD8E0kbQwR29yKkJ/wDszHu6Uy+xTaSImsaS0SqGkmvGiozpff03QM6HLzMnyqCf5yFqFsmFr2hZaCiNApbnAxrtkmlDavJm0K3lMRYCv6iHpgeyDaVggjNMJIC0p8GRc0jpoSRWjMTt+4qV1lwJFE/uIEvnFAAptZY8sjaQjjPCQ5apUtPAe2qFWRx7MyMR1gVsfYP44SJ3pt8imbkT0ToQyyuyhvHjuMzNJkS2y5G0MGUnBw5ZmES+pT0iHjBUl9uEspwMOEhCmJ1koHoE+YFhoeU2KnTy0/S0YnskT4HMxusq0OYpyJZaYC2di5jZXZiqeV0K+IFplb/ar4p9Ka20PbKA0hJ9jDEoF2Sj+ERzi/OEKhCoF8smpD+aO2RsZaQk4X/MLf4oUPbaSo+kpCTNPsY0Qsk62JDfJ3D9hNScMSVeBxW/aCLTl68E1hUWM6aSodCUuwibs2RheYQQTpk8aMUYH8OGsFdUoOOCW4I4K5Nkk0YIZd4sl2z4FJY+CcQ1eyLv8cgoEmJJ0/4kyAlzQy2eYidV3Qi2a9hvU1kOU9HZQNeiMTZI0xyVYfkdoAb8IEH6qB3RAn4BpJ+Y9xBS2xleysqS2eehBqmJoim6n14EyhEvggdDMGdh6f8A2Cmr3Q94YPKGnRBpNYfCGekO2m/tWsHfeFi69obz8gmklp9vVVo2BCUNWqiTQ8hZIVYHTEGwA1qCT9AQkoVLhVExn3ieSynnplze3YSkmbX0e8kLSYErhI4CspteSEieSqkNW18DZ4d+4pdCY50DepkMSAoZLwNCYoabojuXPsTMsK/sWA64M3pFqy1kg/8A7Nponscwg9y7KiMkYwKiyp0cofdSWRWWE9FoUYGQicCe6xzQ4RPsCTgu+DEzGfQkIckKSg6IMPwJHyrEML840ePUjUxJXkc3y1IkXAlsCZemPExJMCb5Ac1VJJL2N3PrkEQymXA7fEi1OGj5khDTWngkGwXh++QyDXORA7t/hx/ktBV3xF1p0x9NTCf5I0Ve40qX+Ud195aJGSBCJAmzsZRtahncYtQSGUQZsRtZdL0wY0JTHiZ+TrFm98T6oFMsW2kyEJ9MWzIYIiyfgiRSiQ8jZCSCfk+f2GdH+ZmtLMta/AKithWX8pBob+Ym494pkYGtQrKvBkv8gZYkgliCdV9By0uyNV8Po11DOGMYio2ZVORHqTtxv0iFyo9hxNNdm6WjOlQxHJRqa0hb0sYUJ9j2fHsSW1cCqi4z2OgNYEvZiDcpA9FXyIjv2kxSoez8i2a6IcVArx9CzgE7I3qcW12STZkTBViwfVUX4Ht8oRE2l9uwiRx1eBCRP5R+2jMmhOgyM62iTtkuYyLelmiJCawkWzoWsBtsLLE7P7fooo+Qz6F+Rsi12FNelmBFAQmacPJLl2xrSyhQpWzsfBSwJZY70EsdGS0vodNIQ3lwxoizEIi0CEVyXsDu7MHE2pxS8OLOghCwBwz28mOr0hs8yFq1b8AwfkoW42VtjtMXEkdrO1Ib4ZiR4ZWHEN+FMzANTKJVqRsU1OB9Tt0zTaQbSlLtGAOoW7fsoWh2YqJllJEpLCploX7iorsVdHCFEnsf0UhAvkInDULaE5SyW5SeSl9rRHe0QxGUs1iV/Vn7MIx6OU7Eh+QMiZLiYhjqXEIP9sdC08EKgVCUstM9vqQhoXTPh9eiCER2+5ebsmugoUqeRkkI0knxgpkdK7CFhDtuWb3FVxTh2hZKcgfHvGhlNK8MtJXRN34LZufQtEUyfjIg47eBib0KWQIoIjQs8QSa0ZqSe0EqOhTN1kTSaX8xLS1kWWHP4E5NsDJGNroVXk2mSytdiMM6ERx+CBqG0JlKXkL9sBpnOwPFO9ZJsld6IpUddyU1ndjkodEx3W8NdEU+/pP7KEDYrmyRAhM7MkR7ELrA+C8ilDt9NCSyXuXj4RE2D4/s3vyiIMc1k6yGQoSsIUkIUwrImrP+Glr1KHf7kyrWxreNICCDmM2NTSaSWEUtiFStmTfkeUx7ZJrr4k3i2halOsJVJF0Sg5pQZ/OgVlgVUS7aGIfAdCMnTUUy/j6NwI8oLFyDV7IWzOBheSQnaIONOD6FLOS2+0ODFtjRdt3B1FEwp+Rey92QF8B1jfa0JinWiGLhh2R5ntHzhdoUTqiYtFPDY5qzgOtFfSquhiRcPU0VfmCpMJvHRGRlOjGxbdz6DcZows30L9p2yQeVCDN3fZ3/AHeJsGjti4IsSkIlcISf8QyeJWfibuEf/AJQ1aGy7exNbamDyUl0jFLfbGLeBkyamR4CvcZk96IYm7YlbYS24ErpxJ6K0EkmG/JrO+Ty/wAmyWxCd/GZdsY1BO/nDXKPdENhCyj2mso3Ypx04BaI3bGCYmxtFJlimXvwiP7C7OeF6FScXZiQlJeC4DSlPGyU/boy19h0yg3f1LFZhCtiGEs2bHe8hcJ2LSF97RPpTVPCMjTA9lnUqN0IcL5D+0Mv7Q8CFYWTVil8lkMlici2ef8AEQzAkIi6oC7HLIkE5TAqDWbHRCSVAx6i67FEKuE5KWoC8dDVsGukMMvsY2QyGwwrjszgWzKZbOwOsSWP1ieP1Hb/AAC3H4Fhyfg0fmidmXuPHgPLGvYSn6oL4Twk+N4k8D8CWMQtQVENA00PG6we0BREt23IJFXR4H5IdWRUIf8AHJ0IlKVKl9JTQjwrsk78ZJEhDPs9hUKmehDASUuoV0dyhMZCGnsldiD9aKBf0RUJ+AZT+Skr7DBN8GhJJCULpfanlxUi/KihiGSuygJHz/xG5lmL3mYGolkF7MTBbEggSJC/J0EjXZnBISgkuBBLdlMpeRMplhnYklkcPYix0hwa0rkJVYSbG8I/cQpfmGq17kv9w91IXGX4vkw37havghMjv5CLkLwx8/ITfdpCOWPkSv6HKeMn2O1sp9iYNlBDSemTKap4GOtwsTJSbW0yV3ZDJWfJ5iIyinuv4Gn+gfYHoiPJZexty/cyWrJyVGjLLox9hM73Q1OQAvlYskTY0+0SqP1CTS5fuJcvwLa8wW0vJgSSQkLpfbMgVxiIo0oYhbbQ5LJK/wDFshlCWTrDCKLgg4BkMjIOLkU1PMUWRG54UbB7oUiyQbxAk0d1oYVVSxM8EmRXQhkaRkfyNKLntltQ0Fcj5CO/3GtouyWyGsNr5F368nQP2IovIH4rWNaITuDL8TZRrpGJPvwQaT3HFEhR+zzNKh7DPI8mV+iA1i1pCjiPwMnm4DyrlXJ8DHkQHQadisDlNQxvQx72XBZoSWFx5CXpef7egObMsQTLgQ5yaDplT/EYlZ3bEcpd9cm/xsuB35ifjPcwQxM0ln2bGWipR21OhZUxniSkXhwi8SkM8I+JtjKhYqzyOWJDpSloJO5DLL4UlkBNm8Meyv0M9KdCCMw05fYHKc6YCJdC04tsDKoIaA5LJb+rC8jQImrFyy96EfUEQtPBLIiTLVJlBSkQlhfcHlCMSYSI37sR5m1mNiQ/LZRC/wASPf4iZbPClAtikppC8YtPYQbUMkuJPGgsYoryJUB5hpCWgiG5QLvyKEhjaYntGQ8jUsQohntGPaoadcLcbySEk5WSg2Oi8lkNJ2mhLJJJscS3pZHm4ccV5bi2oCLZzsyU7CL606kkETm4VKjMjSH53YIXhEfY5RWSH+Aa9kYBCTDJ+ghlc+hp7uSZntjS7ejqdSIn+DeTOCl6f+Eh/pE82+JyD6sMiiKnyV14PgHB4NmoSe4JW2PApPngs8CmOEi2WxUlkBJ6aPf9DPOJ0JEwSewugj0Pga9HjPCO5cmV5J2b6Ba8XFFyh0Ge9tj3zoJBj5wVjsmGjIXt9dJTHgaMCSodV9AaBolFUkL7M0yUllQH1I3SXsx5R8l0MEC0YyoO5/yRJdED7ZLcjMxZmNKLjSu/Y9miLi/EYL/BgvLjUIG4KXbpDGKnKYpT+xAk98Hjgtt7L/uNJSLpGEpgNSMYv/5JnhvBo9gZE4Qp5D0KnQnD0TPSllmYQ2omMg4digi10FSRHIssQGrNQINm8ogoy+4iTf8AgNmNWThMJmJFMWSeUoUEQiW+5jmFD7S2uYh+BzyIiYBpHER44TQbfQ5+EJ08vih/TG4Titt5Ilfm0JGqf+AhSmiexx3umR/obMuDFJlDmxJ4MUQBEiSJB1I/Loc4byTgCacKRNSWjpyIkUL3EVtibEKQk3giF6IIGJkUMib46VJMdmEWkTQ21XCorA2XWsPOcYvrTDJedSLGwlCZOhFKRTHMRXMJL+3NJ5UjNqTwUxdaQX5l9l2fimIkk6GZ/YYNlEo0LomjpzoV/eRgfgyfqLZaDcqaSBFZLPsG7J4YFke2ayUjsDcWBg0DwND4RkLuGAmCLseTwiNuGATAtYsiDpDbjQg4L1oThIlXXjhkiNEW8E19OCEy6IRgm144X0ZBqjpjykPAuydqaE7UQyuQqM2oaYa2IsMs/GECalJyR9wanJ4DGDMc6Bb5OgNkZZbJXvVi3yzwjXTIZzf02SYX7/Thy1mUXBSQS7C8k8sSRi8gEmIxQzEoepf3oqemNNNi7ARxlIaHLCUTUaQiQyyJPsJRA4Vpjn/IQiC+gy4ShQlnjDoi0/YiTCc0lezMIYtMfVBlEd/4YmhYoiwQ1D2xanRUFhRNs4PwLiDMNfcUll2eB2XngVw4VowRBMrpmCF23/g9YzC4XLoIR4NjGMbh8ENfqJzuIQW/JKBHku9IbKS0Q3l7ETt4IoLLxxk6Oi8EIwQSgipkg4L6LMTYXvkxIu8jyM3sxSRy2Jp0Qs8/4DjwIJIBtkIVsSXCPMtKZl334Ev5fBnP7PmftkkG1hsaWENIhaITBm0eTEP/AIA8IBNmqvgQiFODHwjNi89Ug9mVrkwxz4EReRkkyUHsEt/AM5QTg2xQ0EBtuehJcsiiFyvXgWmd/JMj8E+/E28C/iYlMtho/H+CvBLD9kO0Jt8ShSWYWZJ/AqsoTMoKe1ezEH74WNIeJ7gS/RBx/uj9U9CmpiaeGn9m8m8CFsnUhU69icySxrBEzynRllDHpfkxJH6/4Ea7QRQ3EmZNDRD8mVwyB9CYnB7wbjGohKaNROEyIM9oOCIkIFDSzdsShKUvA6d40KJCF9Tpcjz7QtJkAno/WDb3PdP+CJ91l02WOg6mESXuk3wQSignM6l4NcWrYDaPP/J4PyGx6/I2lH5EhF19kbV8dIT1PuNyhoKQzwEvwMYJObAJNc6o/NmTQ8eav8D3G5HgcuxIfDOfpBm+HV8Nl3ehkiOnh/JfKPdVjRSTSk8xOVUsl1jE5KZEE7hE/wBH5I1yIQvpEn2izglFx/g/TM9xGMod/wDA8NSERiEUwmT9cUTGJk+QmLbcPhI+4Mb+4ms+ic08ccHhVlwUk0jzF6VC+u4DcNhFwzn6Dh8XRhxVztC4KmoQehctb8VVsSfMJLH2JqCVyIIKRuwv/shQgkIQvQvUxJcgH8RjsxXufkIgb0xhPf8AwJuE29Eg90AdYWJfFxjyMCk5sdZFKELyH+4r7tE6tqiJDohOxWZi0KaDudJNwxetVKkvJYXu0Uq949dYCXwS4Ghz9MPhDFy82wn3ow/y4JlAkveE4ceQkqzNY7SyXzR9i0kRsQQuEIX0GZBISUfkECkH2NJLEw6jD9fvxqENA+gt70JgIWb2SVwJiMRsnvB2kvcehSbuVP3JJHE7IR7kRI+xbHf0lu06INLvGVZ7cw/SgpR+UFjNPBHQnj1rdwFxQS4PYm9sYsC9DMTY4Vp5PBLe3Ci1LeIm9j4xI1bYuNCKB0JoQnhMTESL1MWRCFVdrg0/uKeRBLuxp9TRkwsIyIhOcfQll7ke2rBv+RbBbRMIRSWQXhPZynb+6NWV1C+oY/Qt+s+w8AU400duGZAin0LDU22hosuPcrvZCq+Bks7b7bL6PI/o0fvcCyMJWbMR5h16kmx2lk1kEP8AC0Ti7YY1fLQKkhpXZJn+fjt6IVgktC7o3UYEI2EUEExP0SSNmJkkx+BzC1tE8BXsi/rFtc9rI8dfUM0vCoTa67sUyE+qCEsn7c4FLnVBJoadizsWWwrGNbbMY6k0UYSe0mL7kwuESyZThQY7CCODI6iWy/aiLugq1pEA+xJDLomXfk+cRP8A1EAWF9KTrCyWPjNFb4oG1y/S7sUxtrBAKNUIUmMyNe5ZGcPcE7EEEQQPhODBs0BexLwJiJgZa9m2GsQ0SUQNGBF5ZIKSDvD6+jLaSIdHQ/M0YA/A/fohB8ihx4KhVga3RmdjvGOEUPZF2UEaIGtCkvyC3GBUz+4X3OT8gilJZYokWdNCRauYKyWjKNCkmftE6HZAPbEEfm10FX00lX1zFIMDIcFjhi5Q1DLsnDQxtTCMSvyNKdMMv3/sL3kUQQS8EI3wnh7ErRMNwiO0O7JZMVjoXcoyR3gSXqyQHtpmQtPRWOSF6kSQkmxuVE8kQX0TqAlOORO0XDhEo8kHsEngPeBqWQ98ZgUuPwTrbUpo/dBD7it70ySTklrG7QiwGdIa+SGIW/aL8FgEl7CHi4pD7sQehNAqzFvx9SbwNMeHxwGuBhUPPBiyb4yIV9oZI0hpUNC9dCdhPRF5tBExkiYi8kXFkEewmYsQRTEzFhpd4PYeSrDfxNE5gorx6JdAtHtAn6E8z+BMxLMTeyitiJ2Nt3RrK+ybyd6EtTuWyRG1fgJU0Q4FJ0qkISLzYf2/MhdOhtJLA49+kP1709kQR2YhNQiaEMMbIXsNkgIJWggYbDkI8hJL+Q0OZf6awRpxpmJi+FD1w/RgF5RQk1k7dEykq9X3IVtXn8Dj+goX0hiANPAWEPLHwFIglRizJE8MddgF1dC0zIGJeiQ8WTt6puFLGSfm1sqU5eEJGXf7R0J22JI8A20jmXTI3UzohQm0AlhhexayfwOQvKrKLl46EcH+qi5Rft9shCtCSPY6PeB+hyvYNIVKOVOwMYdmBJ6RFitNCdoE4JoooeeGIP7hEydfRpkDe2KSumRsmQ1Q9jPyYYxCNojtKZ49kiWvAoRhXHfwGPDChxJJxaDuFxXn1MrKuDaZC4vBQKIeRqunxP5IEDE9N5ARAp7p+mdEJGnP3CEZeEJXYSIst3WyE2Rc72Q3kJ1wtJr8CFZQm+yPRcNeAJoV37HIVtogEeXT+1T35nQWnMjyR/se2UaPUp68wWBLD0C3r8DGJlt4Jpl+R9Fj4XHuKma2sfRTaYCjaJstNGD5MTLhrhcJZLCSAMJAnKI2eI9dSMqvbGn2J/yAUUq8Q/jzgsYIeeGb0t1EwEoakhbEuVuFkkVQI+MEw8kPXy68mZ16rNe5K3XL0yEjqaYEBKHZvKX7g7ILR2z86cMEp0hZ7CFa/wA30LVqOyMDxAszx7Reh9mfkY7YHFBsWD3mvoxiL+w0TKERPEQQLIxa5RjAalRrFyHBYnQvXiu5EGna9S2iZJYtuDQuh5IgsWbiWQY8jGTw6BbIZcsjShZEFB3RpeHpkm2zrZm4vJYEhYzT/guU/In+6GtHubIH7n7FBfopGv7h/KTFaShDFpaDmNlkQolTxNLMMyBPI1jeIsKUu2L6ikG23uuGSS0JDtP/AFFyjpSOjOBZEKbw/cS82hViHXbb6RScv9NvsPtE0IfYkwefT+yOlLJxz2JkVkfrmIqiNL6DcZYkub6RgTSUnlk4ns82OyBtMzLaEx0JyYhod4hdrJWofBiFM8bwyeWHwbQ0aZdLhGdiDb7Y8oxOBmYoiVAofDj6RMThGTVgkedPHJioj0SiP3nBMswa+eFLfjZsdFbt+4v/ACEt4kTwgusjETPhliz/AEiLSjyN+3wYZJmeOZM7agfnijFeweBCjo2epJZ9CWJw7IcF2L9Jf1EbwJZpDHRQjTILnpzj8ovpiaxrCIBxaLdfWTfrIQtJhfY2bwbZF/wi+hWTfQRAPgeiPLgal7qOofyNtsKGsolr8iZkShjX3L9F6DmoXKIGaJJwtP2aEKlXvaKFdmVij8lAqRsvllAV/glPlCMXF1wpBUPOhbBoXKBOFkeCZNA+Cto8rmyF02u0fNZOwyDGFgbgJiYBMQRYCxED/Qhp/AJDJ7n7rIQp2iHCo6F3/HNCvwxx0wyhonbGBfrRQYagWEfksm7R7U0zCxJ+v6kOtjTA62RBoMIxqKFw0QeXJQXospsjbXOm38Cyps8t7FM2JgirMfcl4ETS5+jKC7NCSWEl8E8QJSFh5LaaZQ2B5EMzQyPBRk0p0L8A3bCtqHkcGKDQvsXiyoxGXYtjpHZDyKkq2N8gli4FaEyk+RECyRwaHy1KaFedydDc5Eo/m3noSZDUNZGYu5nlY27ZD98I2bEzciLBDUYDVLJ7Na0dgNshdwkQRPk2OyGslb4KQRUSEUT0sTIS2KLP5hj+BihANdsXszy+hKYpFl7D+R6U37jJGiw0iBz+Brs8tzf+gMShAugTGXtZOlfA5iOVwlrTHtTQ/kU3THPQ1lGp4F/sR/kGlxMDpbS2JI2AjD6Eco9oGbRezwI9lw9E+JXzcXImeGxEx6G7YBPiCg2hrB4kCdMQVhKIErQtQa9BcChLTENoZWBWhnqBj2OZNwpMRekfIiRJyHHYmG1RxUZ7KBO2ydYf+caXm7eCi8mloUutZH9RCBW99/G4bTK9OG7IBFColor40rnnZdCPxZEGRgSGhh2O0wVGSI7kMTodRj2tJJoVvlwPUETxLthjWT0ihjhHKSULr0nl5RsfR7CEmPK9CBIfLCw+1xrnhOBMZOxMO2xb44jQ7IbQOEWQHUEjcEqexf1ijTmST967GU1roJoFY8gJWe77IzuiTzCFcBpBiQJKL0WJbIiixTkHonIfBiq6UJWPXU/vrG6Eyy/v6oWFglWbb6Gn4Yiydvtsl3dq2L3rPg+B/US5V7oZuEKRcRy9BtCEkLLJhCcwiVxieHvhoVaTRIkxASogTri0cAsBoa4QxTIVDJou/sLyeU4PxJ8oSwcyJggTiRZEl0ItGXDHhoykYmeA3aJaQ6TY8siRGb3Hg2SfgdKXgcvwMZN4GRhJO2S/qyhNh3FLLHOVNDvaLC5EybZUqzIJsvoWkLIXIvyYL7whOo43LrlH9+UhpE/ex/URljp/ICG4cfhbIR8OpCf4PRNM6flLiP6H5GIz1gY3CfqYggp5HN5B2kLdLxHPKwOZsxwzFi3xyipTwvFobgyXilE+kqN4HzB3wMPtEyHwyM12KSK8TTKaH1Q2YhDJCSjiT4YlnSGqENL2L8Yj90xBy3U3oYW+DHChCwfdl6cG5J0BCJv5wwAsmtI0LLET8tljrhy3sV5FogsrIwkQP5Qxnu36DTnfoPY+Gfhiv7y/wgysj5BvC94g13bPrkULshKEabJoT5mCTEZ9HQ6NOMoGFtHSnZnZDY2Me+OQ8bNgkhlZ2eOXweB4cDcBFejrlOvPcGvoSmiTlFhCxB3mz9AQXc6CckQnzI2PRAxnMpsag/cIn3Nkm9Yh1HyByLhyUlOAB00isWSe5X0Jogt7xI5e7HajOiKFeV/YShQsL0QRpqUxjrHz0FbLDk0/3v2+8P7oQSJThg2SRh6iEISS0vo4Xph9lUR+gQ7iydAlj5tKyw0m8tkamSNPhmBJXNrY0a4MW4dMkZhlArCD9CGJNC1rOC/cq9E4bWRlz6fTE1wwnkVibJCy2nwSNjYxEiZkUEIK4QF+fHJLpRUkmW5fApTTxh8kwfyK2PSiIfGL3PKB1IOochK6dz/QxmXD/voFyn8n3ZxbQmmX8Ixae76ilgZDuYYoQ5GrSka0UkykkmEaOE4bgojOGJCVQFtd4HOyLPDNQ2uJfTsvJTWBg3243MKHgzBWksdOaRFOOZISINjfBIk7MmlssSHkwDJ3GOcbRjv3DPyWMfSWkHsjf7zKgi7DBL72ekSSWvRCSShKF0vpRG0l8h+VTKa0IOK4fdHk6IUetWF2JCYX1faSCkJsa96eJh570PSVlGdI4fDyWQ9DKCsb5TsQIYxA4Q3DQGsWUKNcLmBNMT0CkI04eURyn8IKICEnv8PghC4vDGuWxAiuJJdDYkKB0JE8Ojw4wm26kLKxxnwbmhm7Y2al7EDyReYzBJTR19WGcnyF218ocjKT/QX2J08tmJqZfsIWoRCIEk8i0hElLYaXIxjGYMua0vKk+yKaPyBLcDyND5ZCY2TQJUWC8p8laalTIpP8jkx6kE4CfdB5MgJDIEekPiBWJEHBkMYlCV4Lx5YlCIli0ItBadwLhkZVDPtN9LimAkQOmOraCwZf8CuiDO/Xf1kQ6l8h5O3T/wBBSlZdIbynQhC6PbmZdqOGPgx8RMXAVjSGoY0TyjUinLS2GOhrjEGCzxNcrhjZGfeoZ7bLyuMsge4W6KQnRaj+wy4JFlgKIP0BM2dDISCyClCCBB0zwpTJ9xi6CV19zJ1o7hlevkyh/KEjWVBB/VP8EhtUtlD5L/QKZL3Y+TYDEskcxEHyxj4RVHESbkTIIJnHEGOmfPCNZL8jXPRyhUQbkUodXkcptOmhCGSpRkeqCI5uJoEN8ZYssSnDEmMmK2KSSQ+kZfPK8GNyAKh0SeRPu8oohmMADwFkZSDDFAELa8jJ9piVO/8ABLbsrRT9J/f1fFIhxVV7kc4nkfDGMfoEwZELwjY89wGlAxsF/AMSw2iiV6KWvSkRzJUFaiFxhmI/gXgan0MnwPs7GRbEClgQuC4zo7eXkVCV+AdF3CP0CbBAAxbFv0yJEogYZRGNvH+E4o/wd/fvGiFkbLtkqdj0JfqTLh8MY1wyNiRdws2IjIkJCeMoyHsR75Qp4kGuGPAttMaBZIPe2dt6NETmK9+eh7XaeA0IQT0hRoWBuXW+LvCyJQNZufCQ36kGCcPbKr9M+xdEu4sv9QV5blkdptkej5pGXDUkcMfDFRPY0jEwG6ZCzvY4VlXQXJUhoGhTeP0ksTIhlfyboThDIYnxA1aCkpLsqTKFP/kDtZkxgU6y1LPyJWLWDbEAIxk7EgYjIQtZZYygaChCGgXMin4ZBfcf6hI2fArr+j0xleQ3XogoQaGhiHUjI3wl8wxQIWk8FSujGSQbS1exKTQlFlkKIINcMuiOLI5KNotdrghcMT1wLC3EaDoaA9762EopEfT3ZGkNAjYjgPYgRM8hyURi62yFGEJyQTnhwNDW9j22/wBO8LoSDwwhGBY9Pvgb5OCF6Gh8NcJw5QuXY5iX9ItjfexIoZFJ/iElG3T4BpHONDXFPdwh3QlTGtVORL0nPEkCzqceTzC0jXnZF1SZZCn/AO8PZjcBFI/cRbcGyNCzG2IeGEzjaxbvm2Mtq1/p0R3EkuPWIYnY4jZ0NZFy+GR6JEPAqZZGeQXExbkiSyFOTLKGNyiXDBZUfuL5E3EgnI0BUTpgTA7TQxtrCeUMRlbGtnEUzvlFQKMjHdlohfzMq+WYuc8QPkoz6I0LLGooeCsaKqDQ+FlR1/V/6cz4cIQaX0HQH7J8pon0MfMykXyhkyFimciSyMazNEx/NItpRan2JnGqFEEGNIaUM1NEzqZwx0jRM5RkE2H0LhMV8IJ7NEuZLsM64Y/wIV+qLJROhaV3WRaZKfFN+bIBMXFsW0QQRxBniJHHlCUPX+mT7pD3q6ff6McJWiXJbAhCI4fD5oI4ad4RQUzMjtyJFHzIoaGKmo/cYg05hIFIBMLrTI5Ov3lxcp00Ui8zhCYmHxOVjaKgn+DTOjhG4xe4qpPQxofAQAPUyJUt9hIQ8+PQ3yzSI2UmN8H+mMbiKQ/P0l6aleGKU+BBPl8wPktBIZGJpbHNeOx5JoVpJNaShk7FNCVoSGihdojcMSlEzMNYHIc0yPzbw+mKB4CYuYGEsRob883ET5wFOqMRZPiZxxHD4kNyMr/05FR4H9RElpzYmLhj5a4oyOC4nxJxse9ja1DgFMlsN5X0MM76FMw4TTwMnClslTCmxMxHXD7HNTRoVcDCEISHDvCc5KgQ/cUWAdTSYJXqoTjAkf8ArEnjNQyjF6GhcM2MmQRkT5JQtjUL6COmN9k4oNDfSvIpp30MhAmi/sMWiFDyJyNaU7QlxQ+ywVqk8IKuFhBcCQnIrbxxkMRCAQ9ghPo7fotpZPMJX96n/DYlfwiBOZJJ9DQ0PgyshWjgiNgbMMq/gjwUoQYE5Cpkb/0C2QQapX7oTdTRAkaREdYENi4ndo2ETJaZMIIIIK4gjEhctXwQ6IXqUrZI9pElc6xnPMdf6XBAnkgK5KC0nwh+uDBqHaJLSxMhuKYapUZdFWKQ0LfE1sCIvXUvSdDKkRMI06x+4TCYmMamKVZcekRE0JV/iefBFFcBIj6TfJPBPi+EmskenQ/9Jka2wieM8NEp4LydiX0Z4iZIORtERypSDE/ZJSZ4njHJzRj5xPTHGRZDIqXrZFQdCkpMITjjOwSETY4+iQR9J8IILIZYmSORBAwnyzQ/9HeTQMK/ZdcOCIg18P6LRvCWNyThhi4JOHuIHFGINJmxEujbvboxUigdoiQnOWLnJdz5gjBOJp8NRvCcJeyngj/EgjiSeI5kgTL/AEVXaDQduxM0tiNJdFkskhA16H6HxLaUQDIi2RlD9AJiUshnaJyxLxpKw6NZwx72aS4Yvkny/wAA/OEIXE26SDUPyITo6nwlCU9/4Mko8w+8lPYLsNMuLVZOj8mzHhn7X0ONUbzE5Ur/AEJolLwIX7hLZdO3Q08g0DY7QyAYX2d5kfL9bhdGSKggmMKy0JpiSfIKZAdI5By7G5jYjG0mlCDJ+3sN6r2Y27fMdQ0/mEfAdbfoiV/CEbTR5BP04HjcSeJRJHiyyzLsvX+ZFQ/Djhkn/CkyQ/gUkTOmwwsfkXQ/EC+ZNkT+mURDAkpP9B3MvpGWcLoo05Zcp7HsStntnnAKK0cIaFt0IHBG7E0IGhj9WCRB0XcQhhhMpmME+CDHfKcrpnjX0xbGrBDQ4OssbsS3I0tDYCGBKTEOyJMeEdQge0NVGgbG9jA2sWZIn0HsSEvZoD3F6aXgzZ8kjA8D2kzDIJOhKtCW4PARrpEIwV3bIswKgmSmUMaE+/mWDdPljQr22QQksn9hGgRSL0TIxRGeLrIxPIojAUnDGMgx6H1wlMSHwmJiCCfELhpMWa+GLu+6Fol7k+FH0ZU7EJRIsHvJ9k+yBWyu2Q22fOCTsbBkzR5TcFtoQS5QwzD1n3IyQeC8Zvc1RiBiVBJ2mKshlxHXEcIQkod+JIaIPxMVvfYeU332Ds2xGWlnRSEpEjr/AO+PF+DbbwTZGtoYpkLVjESiKOFYiaOmJ8iQPnZUqk8yCOExMQRgTyp1+DKIWGVA7IWc0xE9zC8QRn2j8o+EpzKRdoX/AMgwjfgl2/wJYYTLfkS1A0QXUwYQdMSNEOhFL0QYwSPyYJ4W5MpmSFr4KQeV97gTe7HWhaWydxS3Rb7D04nPBGYWSJQMRuJd8JwILjmwaSUrH/uBDQhJ9Mw0iQnHFwxoaIJFwngkTJJ4JTyR5UocwhrwK6YhoSCWWE1CYyDjG51B4WyLFCDePgrEF5EeTHJPEQiQlzJIn64I4SZbREHbDyafn71LL62yzosCTybLssF7Pgbb3x7NXbDdoIBiuNicOQQp3h8hdjnWPfQUkoXAnKKpcrLxA0NcJsXCRcCC5YsygSCdobHg8BNlBYifgTGvLJjxGBb24paCX2ymCTWLQuJJ4hkEfTSUOhro2LmltGUCtT94uq2e1wJxLwMEQk7HI2yKgz8p6EokM0Mp8hAZXQm0L9AnkSxtCVTQzgTlzyhCFPA1riknhogjmSeCKX4E3pyJjzR1BrZOKE/RBkeyhFdhJFKJuexgEMcQIJCTJcIXHkR4R4JB7Xogh+mBDGXYyQp4YmByRyknZmPu6WtolMGv0XaNjCdEkhQTnQwhr9AnT4JSUUiaLLTyQB/SgZ+shlYgenwbFA6Hwz4tGtg7AkNGhsQUUQI4LgQiQ9jSF1RB4iykG6VsdlQE1WZjAjrhSMjXo7RIIDYCwxnZ0U2YfI2ZEuWESlZDRRTSeUMUjTMI/RHLsRNQShqWZbRUmcT94nSUskMCObLE2iBcNj0UkM3mw40LA36ApQxrEwInIpKpaNQiHnIxSieQlUlHIYgtYGLH5HgiyJZBkmht0NNMfJmSEIbMynwL7fc3sexDeWKR4BmhBo1vAhgyN8OUBs8EF4AS7GIhKpIRxBHMEDdlBptAibkkn1OiH2E5+7Viy4biN9hsOGxskWRdsiF1wlDQ1Y+Sw8coe0ZcUQ4uDjSBtTldFNN9DTEerQ1ZQ+KkGADlgd864b0O9PyP/wCkP/7g0aGgbP7EdI9h7BiLBgc+FC0IWiAQQUhFKhuMDkQ2xDCERzvjHok8CWXw0RoA2poQyfQxl33VWJIextk7H+QUBJmVEPg3+cT4yikofDRBA0IWeYOrNBgTEDrgaNyh5FQhzIz9Qnrgn2Bt0NyQnJ8PaeEXgJ+hN0eAT0LWhK0LWhKIIooLhPLYvAu3pgbQw2ih7kDN4F2FwzLEofuIyYSPmrsSYbafT4iSmTw+HQsfdPkGYDKe4RKEDJURFRwwHaeOOTh0Q4fpIYonExS4Q2B/kalEg3KRE7GhilYoY5h5GGkjRj2mMqGvQ+scmBlHi9wkEvQl6F4iK4qCKK5iOJ4NinriQ+o3bJEhNySZigY1kuuhOLkEak3gdLUsbMS6XCPRisuauwtwDYsQJGMeV90kdrbmLJJp44oMbjYw1DS4wXlyyPZBofLIGNcG4eSXDGFkktEqF4Ia2Bgw0QO2WaFjPyIjTFDIC5qKKKXguR7OUlzJPD8sgiRZHBcSKQgiCglyxckpkyp+AxiO8gtemRGSFaGLiyMaH900CBU50dhcTQhqGif01xbvyWRsFOLJkV5AOBojljGPJXY6tYHvkXBMSJIYXoeAdoRDFOHEweBLcUYgyNCfk0KBQKBLhIj0Ty3GzzEdDZl+FIQQgjljEiCGxvKzeFb7kStLhUBcNogQIdnkEr3xCY4CgZ4eo+51+qM2uCl0wEkaMhEe9DoeQUvlxE5ROIDEsjUkjK2hsNEEEDQ0U4oi1gY1EcJiahi8iHkWFTg1FDFofFBmgTHlGIYdyPEU0JYjAjxRYbktsjgguDEEEcSSTy6y4MBbGRVEMk36DrEsQlwIQ0REQYYnIkOgb+Dw4nLRLHH4Y++AYosw7F4Ow9PuaxLsSJJhKGSdJpi1HQyIGOog2V5ESImEwPxEq7KU8XoBa4aGIKMR3Dm8iBIKRQxQD6cUPKOrM14zobLj7BGeuFPgvQ+B55hN2KOxCJ4jXbEEICQjihEwSXzdEtUTiYi+EC3aukJaRAJCQ2kJWzrJ3Ct9I8aGVpF9C9iJDhqRwpsbp9BU4V0yJDSjDFj7gtljGT5HM1LHZP8AHB9EyZoShoY0ManYuME4kUyWhimCERBOb8fGw1waIFgTEj5IayNZaCOJEuTkshGhlq8o1MHQMWpEw9p7ReJBrgSQeEXieAXQJiHYghCglDQa9iOxoJtmSZIZHEpLgasJZFCpRpkkakUhIXC0jrGxLfwXfwIQUoSBcRy2IjVWOYEMhDATXuCcMsYPt/4SIa8sSuEJMiW0Mk4jR4g6EqEgaIE/EhMyhHDQ3oDZDJ1joQLMoUxnQ/ob1wt5jhXFfZPgbdDX4zMUQmh8QWLHZAojzcDGjxoXSINBLqiNxCPYIjRFUyJ7HrsdujYCMNL8EeYnkRS4b2sLem/cSJRIggjbHWHvQNOW/JOgkl2F5gUhcETBEjUsm5pdCukhLhLlosnx5hDAvkNfT9mdMKSRXGhZRuGLwY/tyGNhDE9aGLkVZp4TdgripyNCURD6ELCQTloi8DQ9GjlMSHoQ2mIfBu0M6EaRrIWyJrKHFGxo8Qp8BjYGo4RJCXgS5kWOWbihQZJg1dB7CK9C2zqI7Dg+CNuxx2S2xxHnBvKE6RvZ5H7UBHLXJm1GPE2kHYnls/XAMZd7CFhEGuNCBiURYE90jV32KHECXEoZR+LhHiojyH5pjHMuNxDE2VtFPrhBbI0IWF9ujEy46goGwkWiJwKSR4Mly2HsXIZDRiKaGB8rY0DUPQHYn1IrtuUKo3AgUMiPORlIVOBS4WXMUuDekOEemSSySZHvIqbG0Yor49Ct+DNiXY/YMY+b8iSWFxJI17N0ODJcAZVMfoNukD2XkXoLQoiRBRALrZIpXYhW7ZCJCIIME29pHbde2e/4ZsdvmgK4aMiuqzsRUMvAiW4atfb5OiHoeqFRo0JRA54GljW0XvQgsGuGJ6XLyNumMhIEn06Kllhfh5KZahTZehTFMTGjPApysy6FPQxPA1cSSSSP0e2WxpDHwaOS1/SwvgCFxI2uzPNCUMKTkZTLMMKXH24ZRaFLRCJVwarh0FFscxyxsxLoUkJCCQlwiQNCHFgJzYzQ/oXQRYKEL0MROnhjN3vyGNswEqeTf29bO+QsD7GExJXGkPinVjiSVhoasa4SKnyHgdlxkRIRPqECXeB6/cQrhI48okSEr0IfDOIeuJ6EBzw2SbhG/Yzul3QZuLwpYOfu4thJ4RBRQi2LD9Hbk2Z3jDBjA2KRkjEbQpPAhaEdCsRzAICFsaWCshOBLhcIQu/GDXXuh3UN/wBBcrvM3seBQ36J51YkC7spIgDa+3VfAxkJOCk+igTMrk2oZMIJc/sNKGhBK+PwwUxIa0YmOAw+C+IzRyqHUsuxTthM1ZLTGxbO2S2JOIHIZ0eMZ0byNZ2dJ9xK9XsjIhfp1IsJFw1QgeMbPAl4hrY/KsZ1o3AnCdnjQtCkR8IFD0MArYkQjS7Z+Td8CEcoQgtkt2D9x7h7Y1paNJQWEYDi5XGzAUEsJUE9/bl7yJXuVDyiAOcUPK9rgws8kxz+CNp+BC+meGhodDDYt0MVtv6ka0On0xbHAww+SsJtloNNWP4GPAJWCmHZhUNwI4SNok0LqITHEEFEiEdJZyRZDymJ5GYksjiUKK0KSwIFwVxJcSPgwbErZHZvyJt+LQiiUEIlzMChGH5Kjz2yTV+oZP1t5bNRB3WUQ0LguVlxgGewIDElDjV9u97omFk5vbhhCTwQMaJUsHlHIgsTXDQ0bJM+5EhKwmx3gBIKXDQ0PgfBaUxOP1Fctwe/EpZZQJYtkWPyToST6LoSXQguZEcXW2Ydjeo8w9kLwELRfQuAuTgS5kbGYCJZKRJsuW+BEkSFA3y2KQtS+iLRa6Ht7I0KXGOi7AgDz7nEEYmHoMoxT88e608EhNEL7eKs1zGLuJaTsUhMSRCQgfGliA6XEKadPhojhCc5Ikn09oc396yiQQniCORoZi2MUNhBBppkFl0Ly/kZyG8FhH4QhwcNkCAvcG4Ga3YWsoQJCCCIFwIUcyN0SNmItMd9CbIUrFJYFxEcSKZZIYwR2Cea+2JiPeiJki9gSGPDvBM/uQe0LjRciZgEZyyCzzqcnDHlp/blv8iZDTKaGpM/CpkohoXiSOIKY2QkgkE5IGuEMUg0+WFlD6ZOC3niJE4MpwaGhYLYi4y/BEyE2rv0BTCpPBKRAaio1DfDG2xtCUsCEQhCJkkxcFrRriRCfPDDdDKT4Fs74UC9BsVy2kiVPf8AAdTy60JYOpCSnshgSBeKb8Zb5iR7AuGBmPh74E/ARAsmz4ZiS/tyXpB0ydopCRaEjSFtvR9C0J9GGIjEBhDsdSRcQRwiSJLUPI8kTg4ahlIxSOREJuGnhHXHYzmeAVUvLsQhWwgsU3ljSG87E+eJAURAhcBJpE+edThjZJPEkjfCm+FFcJGR2QUHklzfNgndfhgtSSgntnubzdmW+B5SGhSSxV7Zb3jBw0DcTzwdo/PFjx02eVWGJl0+DGYvtzmFtIonowa5MiXJJRnD04tmKLzOkgRAS5TF035EtJpikJz6JFwSfrH9Mx9yJ+UkJ/oO6PIk/GCBKIpEqodxlwF0XCkMgPYN5PCldi+FLmRsbmCi3oQRoLk2OOR0a0NnMfgTpOKhKIwBI/8AvnIpUKZYYpZjx7B++Y+MGNXMxkwbhqcLPGirM0VfbjEiWyVREOhBPYTawaGTKJSPD/cT6AmmTImuBITFwMqMJ5kF7YjeBBQHuYxsfBQ4Q1GDTQlIh54TW6G5w9BqO0SijI3QnRlhfLhqSEsQXEkkjGpXpIl5jjNNHfiNV+XxzUh3HRWqhCVL5IKsjt38FpjSIuF5YzIJCA390xmzYazEfBrIoyMBMOhO0ldFkmUuQsC+30t2eVwNCpEtOTUxp2LQzKdxiwEMjHcQmHwwnB1OGOpmRD264CTwiawk4G7A5UPuFW2SHLQ3svfBISYpEEg9shwbAZEnIiCiXnklw3wbMkEFLYk3hC78tpZEcpF+5oY/YUbwIXbJUs7JZWZ3oWklzH7eETkxzPilciQeyhh4yCB4RH6sxcZOPEfG6VV9jiyoaoJOg4FoSp9wQPKWuydzgaYWhFoa4wWwEsSg1vQPFBQ+ZQY5MiI+nQuwmSSJZLJZPoFk3ZEieDIhqsD+xr2N2SLi4b0OnBBYtcSSMQbhbwhrKDAImMmSQksmf3Xiw7mGEydrSF5ISz46ICpOCTo6Jkg8uhZYlwoMIHYkJCXpEBrCsNSQhVTjIZGZox4izPrksy0Qfqy8vuKT8WQlkvA80SsBmGRZFNTwOoBzYmIQYR0joJcKHAmiejsJJEyuZEEvGZ5B9Ru+EITMa0M64BJCAjA2SSeRJqNi6AQEVtIVU5H6nSh/ceKHuHlIsRQXgc0WiW4GlIcUJJpAT3bPbFKhEF5KCzzOmUMXPVjShh9jAa5rXxkMzyWOKJyiiIB2iZ/IlCF9wZ24QvfA0NOaokrLlyJxo0KSVk0A7FKNTgclwM9YnAiigmhMTEyRFDUNVgkSfEECkJmNnHAoQoGh8FsZ5BcCIbwhb4QrLz7iqo+DrDVFBkgpZY+gnM4H8i+R2jKCJhS+DNIUor5LFDb4GBjsHPgqUQB44XyVSkmEMfJqGOP2jGPHCjJE2PciEZdS4MSyGZys/cUt9CU2JE4EJiD93ljST01iR5EOCTX6CmRWhozrIiQbotehTFwTey+yeUhIQQSJRQIIhA1yZ0MT90YZ/kTgNvfCasDHgyjggWFrAx4ccdkFokx/RFk+D2aJNCGX8iPufpDdufoOl+BKLWUdYSESMcViCnZUQhYeS5gZBZYSFHjjwKtMeUZSpD4CSkYmGaZi+4xpl2yVjW04Q1I0ISDqYCRqVxLQ9UUjRFZo+xpC12JslYChoB/RENEEHzwvZ/g+X4GdP8H8YhFL/wCSf+abgf8AvHQfkXQF3HVAu58C3MizL3fCpYECEOY4jVsarA3h5BsNmHAfgUmLtwOwo/tBz18lsG0XiCTmgYmkibGNIdIyYWhR4D8VsXhUOxi0kY8nyZheFPAkuWoolI8JiBR4DtcLcKvuK4awh7PySS9hNINDCieETwixUNWROyKqgmQ2H0EeRFIpIalohtdj3pssO++5igSx+E/80R6CSNLivEeY8hDs8h5jyDJxZELZZIfgecaobaRJoTtEISDVJ8ETkjsa4D1WPB+WhJfC2W6MUmAaM1rwIFhrcCRxMbDlR0KpEYc9jIVeW4EHiI9CsYxODUYGjYwvt/d8QhoGALDScEmlCWOHwScORtCsWJ8ewgLsOG0XS5eDsiexAhUIjs8CPdhLgNMGQqfDAiZ5CPjYW5POLcTEmiQpDWeNayjwiVDaQhgbgQ2RKUuMwB9SLa6FsyMsTUkjtnQcW/Gi6QhIdFexrRNbiiyKOkNLH1wwFHSnob3ISDEZiYM2P1RgGYj4nGK4sOC7FgZmYPt8QRRf2FlF5hypkyQIGYXKMlZ4wT6EMSJC7oTtiIUCXFwJ4FsJJaYG+VqJDRoaV4+Ak1xI8iGhKkQkQFrZ1DmWNvbggsDM2GXESDES8jhlm0+EVRnE5fZuCwlKH2yFFxv55CiB5HFnjjwusz44j4Ys2Mn78bMRvm4GDMXDQuMkY/t8CTyKWJMGJRQIJ88C2NShSXoRWCzYEsS9ifESEwxLGiMOhPRBEgmDGxGhOdxHY7hLkXUeFHgPb4GwlChYY+g3eD3PYcHZMoZfgtXjwhHCUDTtpEyrvA8hOHga8vIkWREdHWeWNRIid8ghMEzNFhMWjAh93Eh2JTfJgNT4/wAjDyNTgaTHgSE9Rg+3+xHHBQB7HSkUZQ+A5EN5XAkY1wSDy0JiCZbEScS7ES7hdxKFAmIXCVhj0rJRkXkdoXmfiK8HxW4W5HzKREFbcnge2WfyeWca6CSIIV5MqUeud+EZUQtC1oShohtgUM5IiOtmXz6CHhD4s5MRQIgXSXw4c2HDA/XGD01PPAx4ri5Zh+3ui5KQyWsoukaRlyrDHWJkWxNMc8DxvQjge5uEnCSeEsn2IiB5RDYm7JkuUJRI9iImoyJOyAiGq2IexpOaIaSIv2Agz+R6xoW8GqX4ID/QBlTHexitiEQ5QhMCIiaL0jsHynZzwQ8SGDCJHotwKheH+0lwC8i1x34lI45Rj+lGpi5LAXGx5+4K22EgTzCCLREUAPPCngQiBDOgYdncIsCf0eMa8LW0eGP7fdCKfoEk8nuPcKGxeYi1+hF/8CbhvsJMv5cAlgI9z9y4QVs9DMM+R/BUSsCGcC6gN+EadZaxPAXWSWEsJWQPI50JhSQ0LjUlWRmw1lN8CcN0NbG4HISWQjxiLe5ma9L2NiD2ONmXjSfgOoLIuRr5LPLD7eh5lqEZvfgphnmM8GBITEJER6PbgYjwZCELJl4LiPwMZF7imQPrfkm0XzwyLeT4Ecv5M873GkfLYqGA/GJPGcyyWAfAjwvwI9iTsiREUyRxF5C8GUgqFj5tCIbSoxwpshJwKA8DtoQpYLjmQCCQhsbEhi1MzEmxIEUjJSpdZMuTE3Mxf0ceS4GhhZmVgxMoJRyXGH3CsZncVKMgWREJQypZEvC9DXM8pkidbPKLjlk6hsrilVCWBrGS1yXZH1ZJrPIL+Bg/ImxwGqMPI6JYqRUSIbGPHDluxqRJhIiMscTwVyNIgyRDN6EeYbdmLNENvgQhsb9AN1QspMQ2VzQQIF9BNbIn5mS4MuQKhKVwzGMOEMY8fbnccQiduTJexTQ98PcCJI0EKosuKciHwgTE+JJ4T5RJLTEnYorETdjbskNk+SWhmKoxYe1gQHAT2d4m5PAnZxLaxHLOgrIxHCCEjpHb4W2nJY1xJaFQsiGGx6yMPZaiCAkIkH0e9wt/PNXHMNbMPuIMTZiLCCay4LBu4YehmzX23Ee7LDOeiZ2RdM8RZRMLJKEFQRZeiBiIINk+jBPC4kkkRJJIhMxxI4gfgWiuHEyThTksgUiiHCEuBwHJlSb4EYJMEkTMtCHhwpQMRgMYw3RY4Fki2IljPCYF4FxcZsw+5cYmzExjSl4MULHG98lwx4+3Wd0qGklCTZGIwyoyWc+1xUSqGK0RfMnoUcRiOF9CeFwlIwceAjfEwlMC1kRo6tHgEDsDlgZsYQyXDE+WG4FzNjPASaER8CATkSWIbGGqPIahW7ch4I+1fCuYCVycexuYTdyeDIaxqUmuBUzAWeWPBj9tlk4HpJhyPgmmTCvIlIoLQ3LEai5RzAtggjgUzxnjPGMGyKDksSYkyHAmEibJsb0JyMm0eEuEoRRAKTMcrJK2NGwFwWx0KUa2OLI9EIkMZLG6FyMY3jg2cDJE5SZQUQ2NjY2VcgohnglBi2OLhiIOLmYIwEYGI3FotwceF6Gw+21WUrEHThHwTZELIxezEHA1r4IY2NsJGQmJFMfBg0YYPAeAXUeMXSIm9DOhnQwRSsmEIoQnMijvE0sLseN4xtWd88DWiLKkWrSISOHksWhuBS8IsIhIREpGZLwQoSFwxYaBiZkj4kuPFaJJtssnIXPEtwYcsOJ+BWPHDDhG+NmPtlZ4YnhoURQ2SqmTpDSI4Qz/AIivYwwOWB2iXsQ2ZlEJjVkSD0Q6EhDmkgUOERC2NCybQVtwDXgkG3ZISEnBE5g8ApaFoUELBJJIw9xKXkcss6CISBwJWJwImBqJMhsiuHCguKpsIxDEQsiHwx45DSOTxz8F2IboQx9TCx9son24UcZCuuK8xQuGmQBQ6X4RjCNh1OEdwt5ZKiSMcCEkSI0REh2IbGrY48iYuoYKhwMDZsjgjIhjIdGoowLWjocDpkkjHuEKxCMTSJXEoxSEIvYpBRGDLHlwPHFSLL41zEI8CwXmYBC4Yf0BxEYEeFJSfD24sfVl9skfpEJwX4qPMCUiKyghoQ8qhw0JmSjGGufgDj8hH9gH9fg8/ATgpvJiMWSXA0b3A3eWNyYkWNk8XwyaGxg3kX8BIlEJFmQDVoadjcMCVSJjI6iZZdjm7KxFEA7wLKEx+Wxa5oiaHiOCzIVZiLhkzoe/w8EseWROCHzube4nFeh2GxrfR2H2yb2TIakUgJIzKQVvBHEZIhBwo5bEbLlShhz5Jt2eBk25ZTQmngh9ifY8h5CX2WyBGCUeJbE7K541uBQ4YRTFQoTA0Q0Wgywi8im/BuEQnwCTPGuSEGLA47HyVihALAh8TshEhYKgw5mfJMueE5VYGNQ98cX78q4ONj9Q8cRMGAzfD5Nf2xpB4ZZcAVhLIaa5KXDEtYokRIjbA1YcEiU2PYELCWagj6EoIHRLLZNjR/ApaF6GkSEKI8koUlMQZXkbwTeyjG45NFDfBC7uCq+BU4KgbSKZIGTiBSkJxHBjpXxuxEWKYc13ELKFhkORj6HuuGHyJS4rmPYXZOR7SRiIRv0Mx9rKZaSOziwsmPG1kVXwyuWwJhBElxrBTBIJKJeEOrntxjTHUSYr2JBtNLg70JRAR7DQLLLpTGnZeGQya9jWMiaJbEhW+Ml46eCXEHG6QTDQZAgnJsYl8UgjYWr5IaRi4+FlRVRgSkRgPRLgw+SqXFGXG5xHsaRgIXoMeDQsn2owYMGPnyxc+fPnz58+fPnz58+XLiRjs/sJivwIX/yDKfjX9jbB/gf2MfkqMagksW/6EM4R8I1AzXwJC+fwP7Id/wDB5G//AIP1G/8Ak/UxH/R5G7+t/Z0/jf2N/wDQv7P/ADF/ZX/Av7H/APMX9n/hr+z/AMNf2JX9C/s/8xf2f+Q/sT/oX9j/AKgv7H/8Nf2f+ev7Jv61/Y3/AFr+z/z1/Y//AJK/s/8ANX9jd/Qv7F/8Jf2f+Yv7P/IR/wCIj/w1/Z/4a/s/8df2bP4F/Yv/AJL+xF3+B/Ylf8n6i/6T9z/tP5P+M/k/7z+T/wAt/Y3/ANT+x9yvwv7L5/QX9ja/4l/Yn3+z+zJfif2Ja/5Pyf8ACfyL/gP3IP8Ayfkf/afuN3/Z+pgvwv7P/NX9mY/E/sSf+z9Rf9B+5/2H8iMEb+f/AGGWgf8Aik2f4F/YqU/jf2L/ALz9xD/g/UX/AGH7jaAxn/Z5GdfiX9mK/Ev7E/6JL+xXf/Z5EeADG5/8H5Fdb3T+xKX6a/sQ/p0/sdn/AAfI5v6R/Ylv/g8n/ZfyI2Wf8H5P+y/ngYxQ4RjeoARB/wCHz58+fPnT58+XPnywYMfPnz//2gAMAwEAAgADAAAAEGKAZJJNCdNNPFSJNMIAAAMEPbARgMPOCAB1PPLJbACQQAAOPPPPOPfAHICAPDEJIHCPPIOEJIADJJFAJJJVDCPaKHGLAAABQAPKCY4kEPLAEOeMPPSE+AAFFPsrPHOOJFeAQELKEGFDOFIeRQIAALLaMBGKZKBbeABPLFFAEK7JELABfuBALLKJAXMJ9O7wBDPHQEQPKKOFKNDAIBcBLEAGBJIZJXMDCECWIEGGGNPDCFPAAAEs/PHANKjhNP1PCJVlkM4B/wDzzxlfwgDyii9pTyACTizznjx2ByDSSwwDFxxSgQRlwjXwyD2gExwnSgSwBTKQj9wBrrGPmEnrzDzxJT2xDWCiUBTzhDTBzyyijhiwgTTzzDwjCzUQDxgRDjRhjwATzkEARZ1QsD+BY4bzOinlRnhTDyBTzxTwTbkBzwAjjTTywTRhhFiDCjB2TBjTiiTQgnQRjxRCRDzdtTiCynoP62o84Bp5Yw3wRC75NrThjzJxBTyhCSSgTmSTBkSTwRBjCAjBiyFQHGBRighCilQhCwb10Pw6M2qme0Jld3zfQg+EaH/eg2yR8wDzwASkiBwFgzFgj0CERDABSxATQmDUAAxBADhQAgCn8nTLWPjz0h3ftSafisN7ON5CGX+sq9FgCzxBxhT2BRACWATkzhgTywTzyyjggQjxySBnB3ig3Z3zgLMp009uEVQuzf8AQwrINlM3cYaqDPEk9xg4o88EwYYIoE8YYM88Ik898wcU0Q62EkA8so74CS8MZgTIM5UTdMYhmU3QtDUEkZOsOSZyzXd6UlE04Yl0gA04YYc04AUEk0sIk8k0s574oAIgKsLsHPBWMc8HlngQIRBOGam0zEQz87XSjHvsnogYc0wEAcgAQAUY8coB8JI4Y4AgskQoGuIlJAYIyxZgihIg4JzL0TAv6bmF4TpoC7o352PuczTE8k884YJ5AUkA884sAMQAYkEkwgIkkUoGMGec5I/ffg6I/AAENfVXQ9J6JQPxbu00DQhzMkvK9cAQ92Z4koABk89884gAwkIAVUIkAIocAEM3dOgM3ooA82YkQ3jtoQjooIaU7DuhYX4jP3QSDqIT3RmTAAYQYE8888oIUwkMcEMAkEoo8kkFAPYQr1nsUsQxXTA7ogQQHXvBH1X36EkEqDrPfHkACoGTpokdoYc88w4ksUYBYMAwEc0soYwco77J4MiO0sgQoDfWH4UElH/wILIkh6gDEEeBMg8AovF6hJXU1kYM48s4UQ48gM9s4MBBAUx4Q4GRZxqmwRz/AHBDGy6MYAoNW+oun+xDk/cNyeJ1naXEDEHuFZZluFPOLIKBANGCAOPOLJDCAO008/ILd7l0NCxG6EOB262GMHMTG8u1UGq/K/xzIjT2xJDHNmCHimwIIPFCOIIQAAABIOPPHMLHKAArcygBiCPGKGBKE7MHJGBLxcD58Jqwlb2CBe272z2DHAClZ2HaKBKJlqnPBJAAABGIGHJPCMPCFTc2HgFJKLBBDGJMDOEGiyRgvuiJX1LEGCcwty2oIBEAKQ3AJ4DzpUjLPPPFFAADNBAIGDMMUZCC1rKAAGDIHFOGK9KGD/B/PcDhohkn1q+8BRfmZ+CqkAX9tEUQz4kAPPPPPAJAADGEGFHLGBDGKQ6jzgAIKBOFOH7H/IAhKtdJQWf8p6+HCHz4mxV5JEHIEMCmNQbABOPPPPNCEHMHNICMLTLYTsf7XIwgAFKOCCNB7KTM2BPMT0VSa0+6s4HL/wCZ40zxRAAAAJTbEUyTyAATgQAD0wCDBgywDShPSggXD8R0VSDkACTDSa/CGgD+JIEE8MDhBxtttgkFTRRRScCXTQlUDAAAxCDQgDBHAARyiRAxwHxylvMnSvLUBwAAdRXJivliXdJZDX9YAwigDephBOAARByCcBn5yYfjz3wRi3xzzQwFCACCiCiBQ8IMuAIgBABSGiZjQnhAA/r0/wDI1fbQ0gYUK4XDEIVUAcAQG/OhGPsXSlQUs8twAMIAAgEgAA0g1CgaQ7AIAsMUs/gYgNRbXA/e36BPTntgUskgczIs5UAQ04xvZG7QhM5YI8908BBMUsIcQEw0MYwrep/3gMaXs4E7Y5ktbbcx9Krog7nLJIAA09Wl0QoeYsIJuzCKMIc48UoUIU00EAg0gVYYQ8Ac4wOAZWXMj08pEnSXHcnBBosoDgO3WprMQhqIz7MgocfTEVe67n0IQo8ggU4Qw4gM0Iw8kok0UkcnYQL/ACnBABADe7Ez0C1wdV8B+ogokAdw6zZ0VVFBkDKBpbxsNPZGFPABGAQABPcFKAFKLFWHGErgiK6B1IpHPOP19hkgy1OjwF1v5Lhld4vD4X0ZCElJCo0j1+yQxwWADBJAAFcBfVOANDMKKINXTyGN17PhzdDHC09Akwy0f1aQJz88h0zzyg4DwwFAviQibHxtJIFUu/GEACHFDPDAFAEPLBBHWVCBJnqzmaopdViGZYt+X802Gw0v54ICB3F0u3AxANGV5JtwULdLFAOXILALHPdPMJELCFPFBJ1AaKNI49vh94sfhSOyg1I/9P4Z+14dw78XVFvMrAEZbKu6Ix/BLfFGOJBFAFPDDPPNCJEJOEHAKKNGKXtTYhBDd4qZmMjbLz560D4w4jczzG237BYInYZAQ1xpg3OFKKAKJKRWUMPJTCNCPELAPCFEGI+JC6MLJ50O9JvMIi9DzxR+S59PMy0ABt1NTUu8EBs9o+zYDHBIEGGAKACAOPPFALELELBJAKN65oRUCDLbXhyBMWzkhOaA0MD0V9uPAIM1Qr9cHuAlKOAIAksBMAKIJBJHKAMMPNKHCNCFKGHCDT8KEINLwrmX7B6PDVO6IQy7fH4p5esxzBXkVzLRdYVMIHIL0JABCCFFPPPLCFDFKFLEPCLAJEKFKNCEPN4R8y1OCcS1DhF3z/E9KBLfCynP0+2+sKBbCNHHMFPehJNBBADAAMPGACMKELENDIDKNEKHDAE93Zt5L37UZSNKBDjQ0+XQxN18fLwxsxHCpcMPDDMIKK+EGGWAIIAHNDDFANCNDAMLEEVKNANQGUnAyy0a4UfLQPwGwl0bEtST2Z7Mx5A0QCs8DDDDNKFBIKKaJAAAEObAMEPGJDEcLCJSABGCKTJ9pAJv1U+QTRFEMJG81WCLoTXwQboBg6tuKXAAAAHAJKHBAPFKAANFICDJNPAMPDTMJOIDaJED3SFND0UES3bVMfD6p3hQQzMuMKLdYNvOFVWidAAEBJOBOHAaIHMDZfCUMaLEMDGJHPKAVKADPH+6EGMNN9wx+3g2aQ+FN0nw7pbKim8Q3PTEJcFLAADeAHAPBRILFfcMcDTNGEIDHDLDHPPLDOIJGOMIBGkyJQztx7xc2o+9IkC0GxWD+TLCMFcIGDIBKGMJMJJJfNEKAPMAADHeMMYADPPPfLWIHKWBOIFAGY/y+7ymWrZ2qEh8u8MJ1piIFAAJBHdDPHZCEOAFCdYEHbIMGYcCAQDBDCMITAIUGZTMLOBPFBNO74E353oatA431AHLDjncELLAhHECAJECZo91OMBBXPPYAFMDTQAACDCACAHKDAALHMVPIlCQHtHx/wCs3RKJpk9/ORQt3O2291XcbpaM/e6dVFngABzzDAAA1DzjAABTDyEEADDzwwHyAA+IIJShbABiN/FltAL4Bief2INPWsPXnbL0N4wQizCIQgkGiAAQlzw1zTASRT3yywwATzzwGyw+vFQAkB8tT26NdSSjQIJaqxFAG96iTg2HYgBAyDggzwmcEFEyRzDlAAADB13TzzH3ygD3jwBD94xBgADsjNhbWyNH6wQxS1B4zzDNuCOZJZwsDMpZDSSQyGABTxjTzywEEEHzjTV3z3zwQjTwBiWSTBIxwvfyeSVBiQxbSCxDQAyCavbN5RSmxzDQSgywSQQgQFTwAgzwEEUz3ShXz01TzxxwhWzTC2j6ogAiJK5QW8jZ8yWVAk2uNYGfKSgBjCAhjzBTd99ezimBTgADTghAD3wijyDCDXz3ygADwkvLGx0RkBDxB3gurs9657kHEtYqxTki9/yABjyg4ajgTCimA1iAgDziAEDTwABACgFTyzDwgSSxcc6tXyBb1gSSS88kmCsYNe5EEN849NhDAyQc3/6ip+e6KFyiwGAHDgARBzwAADiiDHywxSh0Tu+jUQ6ymMX7wxRoqhzFMmAlLJoOHOoq0h4tQHbJu8ajWppu8GhCX3mEUgDQwUEQAAAABD2gwTBPJGSVxch//SkHboXqAPs9Niz9n7NxBRM1kULYItIDB6pM8EdFDXzygBkEB3wBX0AkAAADgALVIPyYRqVGeJ3vmK165Jz7/qYh0OAUvUw74HLMIOqcRDe61D4rkEHTwBR00ECwABwAAEEEEDAACuS8PM8SLuWZVQl4WUoPyCoO+BesVqZJocK7JsMqJJKV1QbhxAnmHzwD3mgRXwEB2BFAEAEAHygpZ2tNfYs4M8BdiidYtp0Ve2eXVx0EYarM+NWvLwOC5WkCuARz/wBM8gAV14hBBBAFJgAAQBJBcg3De/XVN3YQ3kT9C3C4ZRxO6mVhB/bjG226T1t71bSClpU/0mSTySxAAAVIpBAMENsghAAAAA0olX2T7Dbfc3JOqAWV7r4HHYd66larn2HHmQgLUh7usE98oX6S03GoAABE894BBABJgFAAAABgUs4OGjPXjjjaFZ08UgseM93xIHfrTzLGRjUiIddzjjZYdEQHiLMH5gBAA9988IBNcJBIABAAAAxUJ7vfDXarre3sYYQOcJS/EFyrfD3TZHx9a1N55AN6/cQWQ56nuC6ABAU8888IAx98JFBABBAA8s5v7YMzzzSis9zjKGTS2hp/pj1VKDzvK5F/BJY+7E20yGOVaJ6CqlAIU99cogAAgBZQNAABAE9800AbcU+PP50wJ7mo4AkAqGlJ6kJMgB1RVPViknDPmiy8CZGxaGCsIAA998ABANBAxEIBABB890XgXnYzQ8Q7jLbzqpS4WGWe1NwbVpVoSlCRJQmpLzee34mdkxUKi88gUt88AABMABBQpAAAA888Ts8XLQtb4XBUpkoow4APyCX2tdqXjJDXd5Dtr12R6yHhKtupieW888Id8coBBwoAAQoIUMU99c1D+vj/ACAN22Fza9ugAVLYdZwwhO7fy6nxQoFnZXgaupWahpxyvsvfeAHPPLADQAQAAIAHfPfPPWMsPkmp2FKy0wEtATHGEOTRWjmYQp887VwmDwdk8Rp4WYru4zqmtPbAPPfMCMPAQAAAFcBfPPKDC+VKas9k+y5+1/JtFwInbgh3WW89lpWc0c/5TnUUvsaYmo4xvipNfKNPPGXQQAAAQQBAQbfKQCaUMsRwrZibL4xw1VkAc8cxaFC29zXY2R1z7ZzxZWh5dUiiYHqvjfbQQPPOKIQAQQBAQQAIfOIPUwEJp3IVgQQWVEDl1Fw5xYua6baRYPU+mxcX4sEbgUWQpAX+rmrvLPAPPaAQDAAAAAQWbHPKEPdwMAcJsxmSFHAy+d/1NXUccdnB0YUR9ypRTw06g0FaOTOba57usvffKMfXQAMAUUACXPPMAABCyzI2A8Rivx3801y1S/8A9uEyW4nkHlpkpdUHrbRIVBEDc4AWWibobz3w0BSkDTwAEAAAEADzzz0IEH30P94FyED5+DyHyJ4FyDyN+N/x96D7+N5wPz90Nz4Lx/4F6KAAACDwAAEAD//EACQRAAMAAgICAwEBAQEBAAAAAAABERAhIDFAQTBQUWFxgZGh/9oACAEDAQE/EPK/yXOTL9Ly5p/4vKfa9zeyhrlJZVJeSVF46ttt0jv65Fnsa9cniEr/AHmyRRKmEJp/GN6/RZFx1Xt/XwGiLS++TxGf8XNjXB+g5qhmkjYj2xvP0scOz6RI/HNL6naf0Pk8L+CaMLW/wadE76RvoSC0bQnfQ/cNw0iiHbOHalDfPcv+fU6X9NqveVKOjNV6wyKK2Ej0JRF0fqVIY+sNO+xT0Iexb7K12KRs6GnofuGquek9GsXS+pTjpslw2fQKW2SDUS+hHsFApjSzpTRMeNf4D/gTu+yxoTXTF+D2C/ildIift/Vvq/DXnTIf2OghA17EPsSj2qI2dqSVDZFItWeJlVG2FpIVuJHp4jOw1O81d/V2kbER2zZ/TNlIdi/Qp7HF2VhNI6DrF/A/gR+DRjWEf4B6RqUxw2PqjtDpBY1z2OQ+jXr6p7xG895hdPSP9UTY0vYtDb9Do0qNYTf6JfsTFP8ARFmP0H9j+g3d4aSVKsOhKG6Q8F3pj2bzKRKXt+ea/QPS7FzaxCsQ1K0jbPYq/wAFEJK2JHbM2wWSCcW3NyWETh17Ge0WRoSDjNWhPdEoKn2e9DKQaF9jGr87qSC9M7NcGOJTRRtgoNB6Axq+FHE0TOxehdZfBzRCi/xDKU+y6s/ACHQ21pi9GQGbb6Axqsbd6D/aP8URI/I97ZGNmaLtilKjD4JwaIa2NXYhs9j4RWWxdEy5qNQ9ETIG2nzjrR9Pb/8Ag3XfJ66Og+yHpkekP3PqxZjG4P8AEETSXiXXxPCH0ahC0uE89OJa9EMogks6lBDXP5jzJ1x6V6JrRZwV19HbOg74VXoYxox9ZbFKPguKYtb7YRrl2HsWh7HrH0N7piW9sWab8xskJenSO3CsxgJEBGrsbrr4p1bGPCxBwmUj1h8kPgjQIei2O4xSZMV6OmM0XY22r83bPtkNIWIr/wBIQSB/sfAawlhd5awuSGsofCtbRRObQ1J2RDWhOvtCl/o0048NPR+Kp7Nuw27LP+ELXWNbr8Q2a1CEobXUKb/GIC1O+HbDILhsZCEJjRBDeKXNFwspvCuEXZFVJPDJtPGo/Ri7aK9MWREh0b+zfAlN9j3rz17H+Ux7x5S+GlKUmKT5ptGtRQZDV0UA3XX5KaJFd0To8AlYuxjV8qkynyoilzRZp3xmXx2gsG4qNdl8fXofcdZR4a1BPZ6BId3glwmWiEOsQp6PQ1zeRoaBi2osRjGjOgQ99j/0NCtLxUMkRHY20O/4kPgxY7xSlGyieIQhMvMXeP6oSukimqNUaobQauD+mz+V4/YUMkeyQ7/hS5MR38CeWLPfwzcY+oNJP3AxI8NexEf2JX0z+h/I/gIQTTZtBKyh8KWFh4eEP4aJ5Jl+M0hdNnffGSvYxdim7KnSEoP+6M9mpDe9hprvmkPLFmj+JMY+sPmr9n8xjRNGybGHjDfkvRsXDqTDTlEj2fsN3isLh14Hr4ukImxYQ1s30zcIjXfjpug22x6UqPbFqvhMXB494RBsnwLrD+JxT1QqFtY/wG3sU7DcHfVQidvEFFVF1CixV/DoYuL/AHD6w/iQvjTSQuzOg5rRPtH5Kc2WVFaRPQt/2OrLrENf3fBZ98GsPDw/jHwbduEdGhsSmIor0OevylaUxIO59HYFNkdGlXXFdZ98Ws9kIQhOEOwh8dIdMg39hL0PZshqod4eoP8AKe8JpCGtH6juBNpaGnIusvk1MLheCKIQuD1pnpGPKRpEpSqQaZDPweRXX0It4F1EQkDIbSgX/sY0fyH8KHxR74J/My14KSBk4Ok2aszWro6R4y2tsczxSEi9Rbu3mDo9i7uBYf2yh6lwXBCHmlxRiPWHhjzKC+h7iQQg6/tjSXfoY8XXBMnUUUajR2rw1/R/BpvLGiE/tBlaaImoa6N9o0xkdoTtwlns328PCFn3l6xSmyZuKNDHnrEMmNQcvsHAR2/g9t8ybW14bbe3wuEqSRMWmJdmwStFJxjSQZausIfJoT40uHioohnrKV6P7A9QpJ2Iu9hKaGCT6B/YHesdQU9kXhrSo9w3TLFyeXiGh8UsesbqH+wNzS7NIOvzDaWs6HYhddjU783sSC16FxAdA7tDA4g+zDF8f8zOK6x6IsFRofkMa6FoQ1jHYm10dDsQeZS9HYew5r4vt4UHLOCGvgJ4Ynl8vRIkExO0SITYroMavgxaZ/JeX63ZeS7MZoNQaD4PguPXBEHlCwlaQp7GjpFJRNjwkeucgv119DsGWGLvm1hcWhPDEMfBDOgfuHpC1plSND058CkJjR+elXB9TC7+BrC4vsuGilwuDcIuFD4W3bz9p+Gt/MLv4HvC4tVZQ1yb40U1L6g9P3wT5MQ1hcWsoh1yfB7v9OlSET1wTgnyaExrkmNYWWvh3A2m9fTKoxuuvxTXFr7XtyQ0Lg0J46KT8KUpftUFy7Gs3DRR64NfbJYvNOjXGEIdcJ9nBZvOj+BojRs3whOOuN+ihOFO/Bpc6zc36hImbhieb81KaOilL9mxZ6+Zr69I98pjvDE8WcLmlKbNkLBv68srhMMQyjxSlKs6KUpfAv0JlwufWJCwpPuV1wJix3i8pilxMT7NLLwss7wmXmhClZfHnlpcWpi47x2TFKUonmmjRCeNfLXXF8pmDXGmuFLxhMX6hdcGUayni4mYQnCl4QmKXwkPyO3F4a43MxRk4zN+d/QLvk8NcKUpeFIQhS+Ex8kevPgmNE5wmKXEOvjmLyfJHryW+C4hEREROEITD+CENYvND5vyenwTF5XCw2XjCEOsXg+S7H9Uhs2bxPhhMUpfkQ/pNl4QjIyGyEJxCGil534kPz13yhsvJjNlLwFxOML8iH567+CYpSlKUqNEREQ1hvEIQb+ZD+jvwThcXlXhsb+R5XQ8evNTjec4hBCYeIX5kPKHj15q64UpS/FSjeIXwEPg8evOY8waeKUuaUeC0hCEeGhtfO+Dwh+Yh4hsTw0QnCEZWE4NjfyvksPC6H5i4M6FhP4qUuYQg38a4Lgh/QtYT+ClNkIQhMN8evkXBD8tYpS4o+NZWXFLwpS+Gi5Q/A//xAApEQEAAgEEAwACAQUBAQEAAAABABEQICExQTBAUVBhgXGRodHwseHx/9oACAECAQE/EPavPxWtaHkYJa/6/wB9V3uflbB9MotSoI1K1IC2MvpQciAor8cS6Hf+kESzVYh1vKYetYkJQvD9lV+nFyHeobnqcfjzVdxlXOzV++CU5IRPpoFr6hioJ1DcdxBTCdBK80L9zDX61qBbBsv8QqTx/wAYNl6nQn/cxUHFb+qAS48xhU8CO/5Ij7ChxNyEFswNlwTqEFaHMOCUA10XAbv+vxNYOYoXN45kK7vJ1RLW8cCEoiofD2JTLmxETi/M7ZAtrmD/AMKj3XDAOSK5hiqczrP6nib/AMm7+JF13EXq0bP+BAkl6qhNrAVwzqHKlu2BKJzDHQLzDbGfsn7p9GBCrnDNvs4jsgBfGElCAbSvpUC2Wt/iwfqxuc51gYRti+YfgnxjmDXLiAQ4CDdQB4ZVN/SDbizKCUwE/wAEpbOum6zdpgu0De5m+ud5gj+KLUO31Hh50N1X8yjllljBbiCoJbH0qHSf7MV5jLuIPD9ZX3LLugzmBquWLe5zpYXabxnUPph+03RlbeNJHaJO0dfikzbEUASoDuzkt2KcUf4iy1bFtQ2f7HUVy+QgyotyTkBOO2hB5TG+X+oM3LzMFbGHJ2TkpRKeIA2lbVza2NuK/UAQJXdIAGgTrj993kG/yU71liZSXEHnDd92bDsi5N2OqUV2jcqF0Jwn+IMDSLH9ZWnCy9O1D/23jpckGWDUwbV1EKqbCieE4jArgiuoAo94ffn7OQxAd2gDEe6dZiKJO0VcZ5m6STQ0KXE8wgy87LfuVMecMMb4JV1EfRuyvIG2wgqZbNhcAVIk2SyAB+AV5jFnH2LSJ1qf1uWPrGt7IiJaNeZY7J0QdT98IBjStA4LQEqUYESGhw/7+QLnmXosp8hGaYZvEMK1H2py+H+ZQr2UEpgbPab+cRfKpsE9+MASSv7hAF/ECDs8OIiPKYDl50DpqGhw+o73vGahLwBs3+xXR3jcQKhbrydalCd4pZf/AI91TXYgFIMtIW3zG27llyvbr/ehg5jn9yoIORvmoaHHeUnAC/zArYjqY1OiBsjH6jAnMCNkUOsFT+7qA/X33HLj3kYWDmMV8y+RwsbrCABRppwhDDkuDpIahoEYLqIXUG6I6h54/wDv9o7VxDkwHdtK0Ue6vTEvnTGfZep0Qm9cOOPgDhcdZGEdTBwsYZ7iNjhAUwKPZ5m1/hqbocon9EAWYEWerszRUhOfXm1TmFoHME39wgYO9EpRBUVnbhLvpBss0cM3HBpuXLl5S4FYSVmt46BaGEfcS4v3xDS8JIKC/WDYkQtpj9tv7zsEd7sc2gHpJVL4TZ2hY4Rv9iX/ANEsWS+GpUCJgJWLwaF13jX9f5nOwmm5LtO3yPRgUUeyZG/2CrbuOLyjbFOglaNtW9s3y+K5vm8VHbFYuXk0h3nUs5LdCPBBdJm7AeyiU6u/URuuxjtwRtthr0A6Kl5Fly5zCb47wOtgLuy245ivmbV6ZVAFk5BnEw+MTcm76r2H7lDNwHBDVIK/peJYaCOipUqVKiSsjLyZQNtsUeAnV/8AJzy/9/M5Sl/ibV9nNw7vuK8jTafoCb87vr8P9YSgIIXx3+N4XHUMkfC4uETF5NY90TvgUpUhYPp/7YSjkMX3yC9ME7iZcJ+qOwOpsh8hc0PjODBHBrqVKlY+ImL8CWVCPUTk6nILnH6zn43ZVCLgSmMd8sf1KiTjpsmxgFrWwyRw+Rwc4NfaGEDJN4WgxpWEJh7HMGH0vMsJ9gID5BLyYv0le4r+kFFXeldBo683eDwEbJaOVxmfk2Nx0/E2BYI8euTaqBj7EKRWTslu8R0DGdYcHheYwh4WVeiBb+mDsZoOriOAijgRngo3wr0920tjBDclXOVR1GDTf4HKGo+YOfIx8a8QwG+SFAXWnPsiymUc6ZYruXb5GWrLm2bjwf50POsnMMHkHOkS1oH5kE/zBvQYv+9CPtAJ3S7UF3OyWKIkbxfEN7u6XnPWkdNy2XL0XHBp3hKfpN2qf5hNodnB3W07fhL1dw4ML2leyL4Qu5xOC6j3SAiA6nLPUcmOc1pMOXSink2jcJ/soeHyBH7YodISwuO+EOp59gKjmWI2PsO2jJQrTb+wlkJE2MESzyDN6yOKwzqGflztm/PMu0pxR1Lg/ItfhDr7gFG5S2V+oxXLceqjStjrdb8gAUZup5JcBzAr+yuCPtYPDK1La+BwaKlYI5MEM7p8lRFreYrbuxIKE4giTlg/u0G0LJeOn5N+u3+PTW4Dt/1KFy+5FtQ+EigFSJaHMV1GCzuV4ZZWQXZiCO06lBsaHR1m44qbS4OElTiEIZFl+ojXwx2k3URgcpuU3XmCnWJQuBXpAKDQg84Wi5cCfsEGxKtY2ULhK3hVTzhhqHwkZUpjDQtbsrIcS/biNwYlQNiWKOIO57js99ags13htD+UhAhugGmPHNktzJHwjjfJm447xzrEO3EbZ0f5ikuIlc0YVQXH7SW7QN7nuqBbicO7dArYwSS/iKV8QiU5gqAoDBGc+Y0O+O4BwU3sIb/+kBvKQ3x/aL1CPEMoiBSR3q7INPckC2W/5X7KU6duzkwIqKcaR1kcDKlYNXcSRsnBK23MJNt4zcALgBRotv8AOQD7cKotvkACjVT9rDt4ztU+SmwMGh8Vw0OARYDhHvRb77sW1xKM6OtOzg299/gWA9Svh41jjrSRMuL1BFB20E3pFbsm5P8A3yUQTwf3HkEPfACp/LrDx4Bw4vJ8xUGVK0sGmAV4b2vfVxy7Sq/eHjw8xyah0OAvSCKJs9fiLE8HMCsp4DWMTN5dBgxUPD+HUFsbsv8Ax1oS5WoxesYmgbiSsOnm1QIB/DIt+YAB516hlaLl4v8AJcNZpGOgfsqJmvyj4F6RwYrFypX5RfEPgN5WCD57l/grl54layGq5UuWTaUZvC5cuXLl4qVKlH4G4vo1K01KlY3m+ipUrW++us1krQ4rTvN8VKlSvGw918JHBquXLzcvNy81puXN9VSvdXyOi8VpqVi8Vqr8OsOXWwZXiqVKleepWL99yeQZWqpXo3qr3XnBKlRzzK1DipWi5c301K1XL0XipXurk18xJWLyS5eKlSpWm5ei5cuVm9Ny/bXSOXReKwqVE03Ll6KlYuX47xUr23nJg1Xm5ehJWjeBKzeLlypXmd5x7I0GDTWLzcuXmpUrNy5c3lSpXosPY4ax0JK01m70XipXod6mG3sPGedI6KlSpWN5UqXLl3KleGvEamdw9d8DBly5eaxcvFSpxLm7DxXLlajU+2vJHNZuW4vTeTwXhbDwmrqHs8vBeutNStVy81m4amGs9xWu/BWq5eKxWkMOTDDWe9Wi83LJcuUl6Bc3lSpxhm82lytbCMYaz2HjPGbxXg2lSpWSsXis3K8LCMecGGk9h4yab0VKlSpU3ly2Wy8Vm5crysYY70n4S9BKlErFSsIYqV4HQYcGDnT37C601ruXLly2XLl4JcuV5HDDQY79151146lYuV6DDQfgts3ipTpqVKlTiLi6lzeB5mGHBhh7jo5lZuXnaXLly5eipUPQMODDDSeu8wyYfLUrNy5crwOhy4MMMmO/cMJ4azcvRWi5z4HQ4MMOPbZUolSiVKzUolSpUqVKlSpUqVKlStNSvBWhlZSHof/EACoQAQACAgEEAQQCAwEBAQAAAAEAESExQRBRYXEgMIGRobHBQNHh8PFQ/9oACAEBAAE/EK6V9AZf1GJ9Pj/BPVIuZtLfG/oeO8Ifac8RUbEn1lAroLmVbLL1o/yL639c+jfwfixfg/QuDLl/Rfg/5BDp5sSVvsv8n0K+Tixk+5FTs+R47Tz9UbEI2MdV+vHQ+IImgLYWQVp+XHzY/Tv4nyro/Nl9L+FSpUSV9C4PU+jcfg/J+lXU6X02kEdS19uYACaSyX9R96aH1A+UBM2y/wDUdKwEfhf0UTb/AGl0SrH9/ifGjppHwM1pA+Z8r6P0X5EPjcfoXL+V9Kj0evPQl/EfpPRP8SoQ63ObrHqWs2fuPjfyufedx8iBXh2mYD8d8yw1gF36+LKAWRGGx27CxMSbXuj6Kn0KsvFooOwT+Otf4d9L+J9F6PwuMel/D7/Con0eIdL+k9b+F9PXwQ0B+4+soQJh9zGsvzczi/qFaeYzRxHplxreDq+PnRLuoOLpmOj0MuG2vgiL7b7RAwaMfRxppzfU0XGeHxH4vz5+D8zofRfjcvpfxx8MxOldX6J05+bHq9L6V8Gwtbvyf8laqE/f/wC/UuesqMeTFS8MABbyHr6uKw/sIuSGlTuRJ7XopDMvoxDwUvtMB43rZ/EOhFAVqjMyBG29Ri5JH5l/J6KAroyy1u2j0SgpWT8eYfF+D9Yh9K4vyvrv4V0rqxJXyuXf1mc/RI3vXBBwL8sc1876nUA8FJxvFL5iqLP7h8lm6jHEOnM56ol437WRFh4QVrbRiA0FWPJBYXEgEhY/aISzVfylRKl1Em1U+6xY0es7qC7kAv0cOgKD+4q7QH0Z/qAjQg+30To/QvpXwPhX0bj1eqx+skqJ9G5cH6L9PeGFJTR5H/yLkNB9LfQ0tKRImc4Ktg+8Of5lwh1ooNh4YHxuoUODBcrGgFczOsvGGVNQ0ZVL+R/73B4Z/wC9zFhvvFiBcNK82GkrHMHD/CwaaPqI9oJlwg8u/wCIoeBi/EuyVl/f6CAVwGWZzoD+JR9bvavwH6dL5rPeNXIdh2+rUD4V1ej8GMuP0KldK+FRJXV+B9Vj9PV1R6QmQsm3tyfz8zrcuU5ipKFpviMun6y1ECsg9JKSXLl3iUiAz8zZffpfRQLWgiiFNmVjla3giYsD3MzKGd4uwB4lSmx01LgrwEHT2Kl6LjuQVbDzUzDewoMLHGRN+Mrej6+BWWX5hYOfMdNjhV6JfzsXw/PuYoWHLiVCofy//fi/RWi3RGjFCOGotvzPiQh83ovVjFlx+P2+dfCpUSJ87lw+i6j9MeCF/iZBgC+Tkiy2QPzEdI1K6tI8zRkzFE0LhWc9HNcRBiSoDTe4W5IInFQtAG3M7p/MAso7soCvMLF7G0wHp3lXDw7XEqsjjMqbKksQc8zBKhEGV+0UAE75u0yGN8StIfcLXE7Ta57IJtT7QBdqlcI6Fyeo9TpcGwHa7EXkFFelrP0QSaEHo+R8noF9g0groZ77fTX0CEr411Y9Ho/GpXzrrXxYkqV8iEGX8K+CSvpIRHTipY4RX03O+gnlf9uX0v4XVJ4HrzBImtDMcSow+PUn8TdNjY4U7gw9TGQwZfnY7al+G93MOtDGNRnYKqyw6uOhROQ/ZohkVg95tV9wJKtxHk12XDG4aLzLAQIdZPsBDAFO5WHKpen+43+ggefsh/cqVswKoh5B2yoOftLASxf6mCt9pnoIYQVgwwoAMZUCAOSlpI9S2Doj9+lXHox9OIpwzO7UIFZYeVgw+HMPjfQOL/Ie0tiH+ggAAADR0fhXyIfJ6PV6PRY9KldXpUCV0qV1r4sqJH5nwv4p0T4a+WIcL7OI6X6XYzQgJ6+WrTntMfaxXl3PEHMOw0nQtKAbXRM+dVuHwm06MSj08EJXrD6iE8QkLU75GURaBcTiVla1JiN7vUGVHIMohYKKqe4xFCKfuR7iIcJKak+0/phEC38UC/6oNw32migw+gi62+YeD90p52zeR7RBhrvN2FcjKRJcZSovU3TKaox8d6OrllQLPYj4wKMwMAs8jLA+R8tb1KFfYzt7xUXK+OB1el9To9SEPlcY9GMZcelfC+tfOvmxJUfhxD6TGPwfljKw+8ZhbNVRSbE8uNMPhcGFFcjyRmm9OS7QqGXa5fUyr2lMe2VdzwQ4UfLFVAjfmChXAESoB5icrbKazPEC2o5WZmDVq8TBeTmLrUODEd/kixhXvGBsYcC/2jouu5LuymFgGJU0eVwYmI7OZc/wIqYTkjqvLIJgQ2VK2pwRSssebQBRvFsYiTKEFYI9okAu2SUuDAjGiVwDhjo4a8zIJnjTueYd82eS7MYfA+SmwHI+8wa3nOK7feAABgMdHpr6JD6TLly49Q+NdK6V8aldX4VEiR+J0vqfSej8PDp3OJwv2JFS7jo4fz83qBKnQcxLHsWOY1B4AyEwWA4iUQIguHol8L9mK756vzKgwXoDvLLItpXxFQqYDGrvUBGOypEyovBxE5bwZYroG8PHgggtAzlv8weK/LL+Pz/7iT95iScF2VzANvzECUrAu1v/AFP4WYgm192C2vu/3N0+9/3GLfYcVsoe07FvGYP0BiBNcUiT3KjaFoHS9jHi0M90UkK7uM8sMGDGK6olf8cxsg1xGtrMZgoPoQpqKDk8J0v4X1+8cwBv34m06Y7Dgl5PLcnYlfB6nxIQ+D8GMWPwrofAPgda+FRPmkqJ9Eg/P38X4tj5YfPH8y9uWBwkV4vR7DcFh0sC8Uc8SuE+djS8JxkeWGgn3JUw1HbYPcdba0pSeCCsvg6+5gxpKMD8zWwaMHZYPYWIVB3cEsXCQr90YvjNbtggquBkHkISHw6koq68XH+J5207ITfQYIGh3lrFLfrj+YY6X8b6VGaF3IKBZVyeo+IGM4blKNmoXUJBS3sbjrcmEoytbIYGx2hZ52rSdqhA1MzSPiX8DrUO9tvtISd4rheCHxYdT4kPlfVi9alfQqV0PpPySJE+pUr4PzelZP6TMfHunuDcctaEecIAEuS+FaIvkBCJLG8f7mdqe7Fjkqn2l685vl5qIxTFTzKspilUl2LmUzddQmvVon6tOCIE+PMb+wcYyqYbFweT7QFWHcRDDY7b2YAaTgxek/MG/KpkeJQF3MVUifdQUvxFrcL8sdZe0huD0kXwy3sy/WzXtLSrXmbPcZUVnnGD2lKJw/4hxTgYWTSsRBRScwGvTtBJRDkBGUzk64SkCuViZgDRs+8JN/fbGXBhLqFCTH6csK01VRyr/wBiGDa+Xj4PwPhXQh8r6MYy+pA+FQ+ISvoV866pE6sPkfGvo3ArWI+oNijdHuVjm6xwSEgc4wSlp/KEPtBAVXsiSu+GUKy9pi+iH+UCI26iBA+8a9Ce5Q8ogUe1JS7PeBE4OICYY2rLODzd5ZLF+ozRf4j5CftOBv2ilH7JQU/2nK3yEao0axV5r/ULXxrBqYf9co4/VL8n6Zxv6Ia6ZxTL+IKxXdKWBBpZ4H+oCcMuKERw7eAvwQWU4LyRVj6ylI4z3gsU3bfA9IlD+huF0jkLcOs7rxB5YpzEVbQFK+0z/hqDH9H2O3+ZcpaEjArtpmYYy/0wLRuVagQv3r8S1LxFP8QYoehlEMAHjy7ECYlvgOCI3KYJh4S/g9eYTjqdT430YsetQPjUD4VCH0qldH5MqJ8rh0IPyY9anHQLLWrRFQ6vZX/qXImXeBCz4IfUD7plyXLqUmgJ4G4QWStr8BH0peO48ppRzUAX55LhEG3uOh3wELKTsh8aICAUl6AKQldMCjpzAeA1Nt94xpPEGrc7xUp92ECsn2mnSXxBhzFmqAxO6SL7kqRccwIGzMxEFLX3guQ8XO2GHhCoXqWJpyzORQItJebL7iZIqjp1K6nXj3LNAWpmziJEFodmULk4VhJiVXvBCh3UwXQeFzFGE2Mw4qrw4fZFqtfO8sKPZd3R8qeBSfecip5/QypM6pQvhj5u0pCFaYyOjyYiZtW02QVxMX0zIDflO7OVtCPOIPhuO6h9Mh87j0Y/APg9K+ISpXU+jUT6FRJUv6B0rq9XpuYQBn5vz4ltQHjA894gH6wCG+xiCjDbCda9wwzdlw4omVs/dgCCp2B8sSXXtp8E8sSOIXsv2gOBeWIV7vxD71bl2S9RQsTUZ2dhHXxDW8sUU6kZpq2EttWU8RgXDzH2DDTFP9cwCYLpg+JyK0N0fu4Bt3g1/cVv3c5iCneFMugPI5jXwQSgVgdDbCxzc9Rp+CP+xpyH1/2YYHwf9gGsfr/ssFtwd1+ZaGSW7kEKAR/ghKQsq/METF4uMnVG33uU0wy2TM6kE0CPiWW13AIb9u0FEsIc2nV5eyVT7Mf3pDdh3Ys+0do3cyepyptRf/KGKvZHTWe8ZyH8wjVXONEomA/MWJZp7mFJrpfw4vtBajHIPP3hp0A7j36n0VjHqHSvjV/A6nX8y5cuH0KlR+G5UYkr4D8B+L1YoZcVGUIw9f8AUt6C1LVg4nYRwgG1GsFe5lTa7WBFFduse2X7CYAv7sVfFN/PeUsg65oY+pcy+VXjmUQy7pKVbHCUgngIWDKZNbAuogKdytVLZKNeo7mikAqgWSotUIuyCUBd9sxXjfmHQmelQalcoNGxgpYYRzAc47xCdLWkHeVAIMY1htmaEIcvF3tUQnLSN0pK9Zh8XSTzmDhffwd5cvXKzuOLoKrcco4Ge8DsTzAbFwFiWQCi0iTVEmSYkKZgC1KF9iuKf3CNPnFAHMTO/wDVPesGe7i9vbTr7wTHc+JhPBMjZnOnZhMSMrb3JRl3K6XCtncBgEa5E5fBCgbD7/1fVZceoQ6P0A+ifTSJ0r4WWwptq4VCOAlpq5JXzvqx6uBVoJYrf+MQDSugdr5lhoWvEApg1FG1qARGyn7u8phzE3UHxhUlyTOstWUq8FNukHXBHUoO9R4QiCVR5lnf34H3gNLf2/zKbVKtC/mW96ekeITLY5+6PfUIeHMYuxWfi4sLQo3+IkpTavLuMIsBhzXLEsdb62kqLaIdDMr7wwKF+BCEi1CjIlul7EYiWbr+ZfjqrNkpwlnEOz9ypiCrfKCv5PcagKa9ID4MOzOpawrYeGGA2n/43NmfcEzxL2TS1+e+NLKeSXSCzdQXAU2rAEV4IYqvcZdq8TM0cuuPUL/IRA8N4viGrTggA2RpnKZqNQW0qRl3q1EIu1osSXEiC/nJfvAOFRuDywDQZ/qPH1GXF61K+D9S+p0IMGXL+gnR+GIJjVcHf/SKed/6nDC6ix/TYIgjY8nwuEv4sYGDKuiNHNVz4JSTz33glq+J2iNl1be0XAxLVB5WXlRYWF2HtA01y5r3GiXtcxiPxE8tdrAK48sOCAgNI/dxK7/ggtfz4yPIHxo+3MIBegolVBn6Qh2D2jz94kB++O0xbh9O4AGErKkGW67UZNqfSgcn3cPuW2qzkldb6pSGUH+Yxy8j7RNsMuK04j1YgNmUw28KR5yJbJ2YQdmBmTJYhsL/AFAJDxMvuTVM7P6/mIM35J2i5W0tDhg2p4dDvCNS4+LglG+SHyKxHaFThh1s/mFShcuIzlfI5iisjvFyy+0Em/skzj0SRRAmg4hRWqG2SbizsZ7KIoRBySz0iyLu2a9RRO5EX+bjEaU/wSaAfHJh4jkGT2OldT5r0X4BA+FdXpXSvoDLly/qMr5KbS/I9yZ3rBGfaWz2Irx4YUe8YBH4HS+lQwpL0AhY20OH/iYiL5YUq2xtcxJBTvCQPkJgKkU2wRaO2PsZ/MKEHLzMFPlWGwi8f6ouWJ7U8EXO/s5fgjoGA0BiX0uPSoNz4f7Ywf2ZaNQIHnIEBgX2QggWkXxKtkD9iFNxgtrtDVz/AB9wBSrVMvoQISnb/cFzkfdSJLYpSfVy3OchZXEcqOcwVx2jvyyavlQqQaz7AYugsy71hlCLBbiXaaVjaiVVjad2BBv3QF7ah8akYz6R/wAzpWGDojAlSwM1Edbqnol5qth4BGJVpc7fHiOGA0b+9ESU7hCV87Vl36YQOlsWhFBb6eEYUxF7HBACKxRnzfiEEsgAo6ooJ3jCnsPMoLwdrbNVZZxSnaM2p2Yz3QmzRXCPCBQAOofRYy5uED6QdDHzely4MvoQZf0KjK+SCILHZB2JtZfWOrAzSoRIA8VYeyGPx8n2lSuhBlxIqANrxHRjY+Xb1M8LXFeUHtHBgzeiIUAN4imkfEagsvxKUlOjmAJgdHbK0yw9vuUToQI4A0GaF5LjzBTu/LnwS+tKF04IHW/ihisKTxLmO3V1nDEYM7e5sgRmwLtNkYdFCTt2KmTxcol0VOY644rp8l5maGzkxWCc9CDUWgKss9wn8v8AUyjB/pirlEVBtgVoI7HSUrSvUVoG3o/Jn9zLcF3yeIAxRT7d47xtK6KblVqbqX4zGVcpajUpLm33/wDM1EoHGoIv26pcIqXkQegw8J/uJe9Cf5llqWPR7ZRgCxLb7HbobQBuUXIX2jiAlg0IGCgKDmAK2YeIzGam895YKljUYUn2iXIaSALFNKG/cT5VycQWA7h0yqW+iAXABH+oDoJAFaag31PoMWPQIH0qh9UZcGDB+mkr5VGubs8Q8APZq4uDu6oRqPHAlkPuxj7cy4PRGINqoIxU6frBhFUx8L16lpVFhT7USrBbiUVbMqlme0DASy94fQ5zkkpr/wAWpSdXGX/yLVChlAh0OH9uozQIh2YgbBoO4f7homLMfQpbfdS+jmG8qxbjXb/ilAB1r2PcRMyL7Jh8Q13cuhZfZgVdAFWPLAmPFgRSmEaen3iy9nlRXeX8F/7gqJntRhQYRgUo0N0d6ixwhFU9nEWmrKofKNY1Wz5HmcyI/hv8y98uWqcUMxuDA3FGLKgyHuWUhhtPwIu2Tirflg2zdXw+okGaWNdIiYFWjbDTotDxXeOIowOg5WEwWeV85lEGsTyqXj/UfUsKRqy/zKLqsDDLYvuXzUKrzFxCIc/aG6D2imJKB4TZGFlj4iF2J3JxF9ktAQ7S1NtMYhh2MAuZD2HbzBA6HQ+LGMSHHbb+IG974/uAG+/6BhH6B0D6D8xly5fS/op8Xoyxa9HcvR86dMUV6OSbzqFVM8QwD+Yb2Bof3G0uoewfLHL66xH3mGUH8xAldK62QXOFxHYIWd/EX0wUssCyImKSk6uWpZyd3KJQQdt7hsqtn9d4JFRWQo6FpJnP+oTld6+3iNY+VLm3+oPrKL3oIId0+0IBX3PJ8Vq10ZfUC2aE4xzUpMlruEfQoajmBKjmq2RClUKJzAVS8rXtDhCeCFXiW3yTLzZrse0cklVg7QoM3uB5KUVJEps6e0BIyI7LCcD7zfpxLPL2hz+Uua9wbgY+oTAfyvYjbB7qvEWtqFzz/wDneI5BRXQ+6hEAzCa7R14FXay3c6LD48QcN4QKX8vLSsc9pfy31odiWlr+MNhKD+NRsmYGw277epjCo17OzzKzE7CMoni7lHmZxGyXaoi21H2zDZNuNs8iGCAae4pUfYkvHnnki9Z7Crl2bPisMfYHffFVVdzQmpufE90CuSF40FxC9uhD4sWpli4rRBQF4OPslQvc5/zCZs7HwY9alSpX1a+Ny5cGXLg/KujE610eiYKd4xa5bjDTl7oQhXswqF7jCYXP7goswhWH5MV/yCKbFGAysOFvx29xkBS3MxmiN7e7FHrYosWRkNxRTdrfN8QUHGNESAgApIdGwnLtMox7Ix/czBW38JboF700/siQoW3fn8SvvZLgy4S6llo90y9qNJsy7jjGDHqL6OFtkd+yDFN8kOeUWW+0tZApwwBbQHe4Sem0qmWKuSZTDuoWSkzPvCI8atygrolzOtF3eYcpCGb2yk4VNkplEilp4YZZnRIG2WPplEW2v2lU8oOOEcFrjz952xRrV5qULwldCgK0zrHmG5YqALXsQRltA4k5LcY0iDZXSVvXLGzGFe21QdpZEJcsVF6TqcZhc8qWp3LOQ8wkMW3hDcgjaCIe5E7ShD24kgjcXjBAEe71GMLLcEW9OYllhIJ0PfmXwFTy/EDvKBpHTKrqfDbjZKCHQnjuoMDl4ofbtLgxdBjwOp0rrz0qV8Trfz4+B8B6XBly5fxqPR+Qi6FJLOD/AOZKUIcnvFQqKPNdooQ/IgCs/wCELBX9g7sC0tt0eCLGY1eE3DtAIqU32IGlG3um5VkJpHZfnywwUcRiSo3wO+wzBUOcad4bPbXND/qbMG5ZCS5/SkMXKU5d4ZQrqzUTpqEAmpIG2cS92WEzBZV8D/cFGBa7yxd6mZlO0+DzFmMh2EBLHkGYACIdsBG19MM5PfROgLahZhf6xOc5/UMCxttrZDLPQa584XTMG+Ei5iqhkeYiIBPY51MPkH+JxDMQkaoy+oTOhiQgO1gJLQRzfuHtoRttEss7rMxTZ3cDBV1Kbd5fBEicWAi8VCQusGKuL2EL4csAF4bRAoGNbyZShhDqXq3KcQpDjhIMlaDPYISawH9QSXK8y09y1BJhQo5UTiPgwOIrcHZuWw5N8o1ooZZBtYYVYLJy7PiEHAGXR3fErrcXkLlUT0jB4PmZWBjGCCBrNpgl0NvkPxY9GErofVuXK6vxuDLlwYP0GMfjjmFaWFfLzPBLEGOvFoY6+zAwmZTCgFtYXBG+x4gkW3PLKx6lq15gRzbf1A0sDoYpKGy8u/qBQBgOjGMWowMBZf1NGxLpIlxA00OTiUkrOYp9z/oQx0NLeYymTtFSoWhjqzkGtfmCxY7ogjVKfDC4LDBsqqd91lENAfeY2aWKVO/XvGlRohOR9o8QUhXcu24JiQQgCZMQTQPEAbaLu2r8ymFkLsXLQ1Ie25m19EgObDKGgr5MILfJFmPYwhNp9siT82P4niC4oZVlNr4hlaP/AFMOWlQQgQWau6/BJUkS04SMiVCjIwOScMEQTFWV5j31YD5ig5Yx3YGZV2YjtzfiYYNRt3cwiBwNsqLE13hMwTKX77f8gV6LKx6rZdwwMLXCB0AQlBfaOALzI8ZO5fSAnni8n2grwypUcqWhd3Ql+ctYQmpZ+UtB3zmQKj9KoH07lxZcWX8K+dy4MuDB+SfG+jFP1fmXBWGU8+YthhhEBtz8XCgUdoIFKSWFmstzIJuVi9ByuxBXDwuj2lhoDAMzk0c33myF5/pARAoHB8GMYxlcNKMp3htRBdckrjRDVbuJrNopg1y1ftHuS/Yj3gCl79CjFGsjzOyQBVgC8cXFgKpbGoZf5Si7xj9oYy7X3jGzS4DzM7G2puG1wmeY3y7ZiZgV/CSuAnvBOZZkUB3e4S2A6hm6lGGfYPUQmJQ8iQlDsjBEsVHfPCWDMKo4PMsBjbz4gprHOJ9SPjInJ+IpqTtB495go2Lv+yCzEqobDouGjEX0Dsx15xYkifVbtwypcgq8bZYPH9IeoVQcOGJXr8diIVZDsRDeFDxcsiwlcbDKylvYp7RX4Ko3zGE0bRs7RI9YglzBMIxyS+pRaIrO8HmE4R5Tcuzw7J5rK9IwgweW5evHpqHnHflCleAth6sGf7mAAFBgDj5vU6H1FixYvSutSpUqV8bgwZcH4PR+KJaC1e0UnOI/uIg5B2iI2XFlZV+JsYlr5gDkFfdY4Sme1QRp7SZRqyaru+ZuXycfeD6yZY0D8cLcL8+eldWJHosRs82n/wCw4FsHBf8AqJUINJL7p2YDVl8K7st8KiRcxZesl0RAQkrpe0pFNAqs3GkBjFFR+WWS+lqa8RBcew5jUG4mQ7EzpxadsSN5GpcFAUuVV8EA5l+CFDc8kE0N8CMELlW67TjeApTdbuOLTcdm1BRg6mrImDGF7QjN6LEFHd2IwteIHiVaqZbVd07xp2D5L7lBLUYnYQx3cEHdFOYHacEIFr8yvBvRM2y6ky3+Y6cG6642/wBoMkrRrj7sTHtEXaSii4CLfinRf+otVZjXisy+v4IwtKVgpAVOiIXAlLwniNmYA1RmKuWrsoxAanYOo7x4E50f0wVgWfMc1RpmVAY9t2y2D5xMxvd7pU4mDsypfAXEg7mzH2gULk2dH431qV0Jz83rcWLLl9alfKulfEZcGXL6PRj1ZWO3Lg7SgIXqBC35Ny/plJHTF8RLa2qIDsj8EUJhWroJah9Nbv6jEOuwmIloNpFKxCqF57z82MVEClTFzNNByVbk/ML5pIPlOVWhj2fWlb61FZxL0nueYIUEgPJFdLWGxriXgkOm16uKkanDZ6jXuiucG43mhi5Kl9ZHsGXZURPCbHuO0LAZT4PB2lAJirYLlBujvIRU4O4HaDg/m9iKS17McsDlvMr5VEzcARAN1Cd6Y9z+A5mJzovGIqAKs7oalGuN1LDVZ/DflIa2UBZSB2ILSDlctPQnbunbhg3cDQjsQvjdy/XdNMH4TImvJ2ZdG8pXyPMFgwaT9RomZSPwlAvEyHx3lC83UIG8LpFmQbNXBnCWtRwS9CtZlo7zWyA10DzDRhhFV9o6ttj0fcYsv94Z+G3b+8ph25KUw41w9Sl2IV+FjXwCwyoOSp+ZeDays4lvAcUVXpH0U/EMotCXxcGoGgDq9L+D1Pp3LixZcvpUqVKlfSrrcGDLgy+rKlRqodnK9pUfNz/qMnC14IyIqaJQ8rZ9wTaFLZgVrVd1L2ArXEdMqrWr/UekB2mtXeUVurzOGWdp4ikuX056pGWorOei2ASrrJEssDRBQ3qbZpOFcr+0s/MrUr4YNFzKQYthBY3EVEtF3xtjovTC3FcMDA0KqUP5hBo49x1DYKGknEQvF2r28S8qF5APH4glqgay4jnfmchMij1LF4pO1RzwYu1Mc17stdWgOImYr1GKo7MLK6HeY7iuSYcyjR92s/8AIJLbPUZZx39h3lcpH81oGNzMWeEExBKDguK8ggeCeMeS+zEMYQYzDFKauu0zptfZ5JRklfzKXm+AiV0xjvR3iht0W3wkdvuo4pzCQjSfmBXujEFEWl6S7DS/cMI1oxZzfdI1uZmGhjcBWUCBYEpXaIqK6xwHnsyydAE4P9wMGcEdFikjd9nqIXf3RW5YYWAbR9xDTZzq/EwD4WEx9F7JjAYL3gOjA5B/1Kj9OvoL0WXF61KlSutfOpXVPgMJcv4PQKS/yxaIHCJQP4hZfofMJUZcoHeOKlQazq62/qM0oo/0PEEMPMpzrY95aUhUGs7riGfgKrKhAYCkwf8AcCV8WMZUZLRRXmArQKlDWAWJjqrFzmBlmbuJ5iZhK4vcox7NzN9hAEYBZc1/VM0xMP0qDAVLU94yVl2yFfV1rgf/AGG1Qvxk54EpTZgPNwqr7LjP/JgRt7DKU9y7ZeYOWQCyqmLxlXis4h27hmSBhu7NLGaubx/omY+mbDiCDk1TuWy5YlOOMRhaypEQO0ynT4Z2fMdvaSrPphqYEfkhTZYvYhpUn4D/AORhlN6L5nBTXTPdcVKFin+SCSGpK17iqN/0TzOzb7D13jtzQaP7pSzjQ9n4ilq0aHnEJBJSyrU/7KUkoChYahWY/wCJWMYi4wtldQy+uswh45W9CPYwbRX2lugXYr13iMHybY9AgEIKwUk4a3t2hrTTM1uZjyah2hqnlOGcBMf9kuRwdxBK9IezFaweRdmKlyuilrh8mb+VfQWLFiy+gQJUCV8K6VElfOowdIIxmbLMkNdMwZfV7wUnPB8xFlXKzsAm/uh8HMEDGH25gIqGopDz9zVwXoCxKUy/biVEiM3wK1FQRte2RQA9Wh/mXavKOPSJAqzVrPcmNDOizwMuCNjpl3CX0YkeohUZfZcETsbuSL6p892BhgBMqnIjQuYoX4babGZc7lVcqpklpf8AZLJ1AFUVqRmjm84mPm9XAho5If1GTfgH/IIC2yyIX+ysfpKb80f6hlNXkI1wL6IuTK4JXk1LligWEDiULo3GfwCFyRC1QFgumPBYF+k/TPtAmKN2Yitr+d5dZBLaQYcH9hl2RqHgXCF342u01DtL+7KDA4p1cStYUMqSv8ChgVE5FC4g2ACb+yUjLWHAMxWaVFmLJVm/wLgtqpi3rqDsgPrmJzaASnWwooyvEQtHN6ldq7eP3EjIFUcuLhgG2KsSKj0OgwJUJcud9z5IWALtBrPMdT+X5P1DIVkxw7Q8WTHalD3uhJbTHecJLN2FidpdTlc37znIWw+pcWLFl9KgQIEr6FdUlfMJsj3jFK8ZIF+ALBcC7YytEd1cGZ61Mx3jOyy5gU1LEHMQ5TLa5myAP+Y1PNeCWmztK0v/AFMAO5lO6jMDDn/ZAgQNBACV9eXJ94P/AAg9SsH8RIKC7RT/AOhNLMk/XuV1Yx6MPA2g/USlptRzHDC0FJLU2Xv4Ir1VEXmEcB5YFbJwRRFJ3Ztme2U/oaTuy8FsqVEtDGIQS5lv8xGQl5xMYBA4fmCKYKDJCo8QEPKBBUp4g8bmkKKWY5gM95c/xLA1rHhLw2Uv8mWbuLV6Q3Sbo4XviLJZ+D/EEgoZtx/5g8abDPbEs+uoOS48D1FVjVRYpC4bYhdBCVHe4NQ617dtSkN3V2JfUbdF/wBw327kfxHq7oNP4liF9lYSDxDoaJ6tF91jhaG4aEi96zwyIp53FMvmN7rdowF9Wh95RtR25hIpwPDBo4mztA86dlsRTry4IyjWOsIxXkwepXQhAlQleSEAZSpgBqWsia9cxSRExarhPAxW0naikMsagZWWSxUtPnv0jdrR6MTXwr5XFixYvQIHRXQ+I/NJXWvkvIU+I4CDzgyt3cZFrEfcuCr1z/olIDe2MrwneQ7FVuPKYHllZnfUeaVcTEQK35qajbn7pb8kywULG2c9OWZTbeiVyHft9GMSPZA6N88xCBT2Hpgwyrvn/aEmO33/AB3haZ6MZULTKHH+sVF9YuOwq4U2imIMz5Y4bENF8N7ixvCaoXBEUASow2iuqnNWIwna03UHArVoOPzCh4g1OUPf/wCJWPqr9kLIvDD6YjN7MQ2DF5ZT9FHkhkIeZCorXGF8JMDFef5lIM4FpPDAp2A59MNbdjMrtAuPJz9EaoFqemWRUqhXPiZsgUVVJmPAZ4ZUnN5H5h01KXaWiCbPbzACU9jlgJf5OmVcx2NkbUb+zHigLSy/cqWxAcCAluF4PtE/a9g+SNwo1a5zzOAmt/eNxWvdS9Av3Mf4DR5faY2EZMWwg9rgNICS0/UE/gdAhAgSumLTC0yxTksitGoqq8L1OKhjwzQ98e5TV3vHMQDLHnuTOQWPdWSIysf6cMJVd+/gfFly4svpUCBKlfQuXLl/KvjXwCA0Mbz+TJFAjB5SGF+LXjJDpUvExEKqIMkERYbRDqWjxK+tAJUUUNzFICAwtMBASpPxFfB62yvheBsgXFkA4P3ll/wafSwbAiPJGXGCWeyZOFA6mUU9OdQWqMF9q9X4hGh/VKTMHZAMSCRSxlmU+Yg2pDOfFGgQ0TBt2ovJVwZJQOIeal52hqUtZfPYQcGp9kiDwpK6jVrd2xCFn2IAt1YO4Jtu91htB64imhrE/SXZ+6xyivljzWHml3UyOwCUJ6iuh3a3A3ZA1GUckh0PUfUddmM0N3LGMBl8TfdIFA22/eIS6IE2QdAHJKacjCbrfBL9NzNNz8cesSoH769wUDlJLH7waQ5RuriOtVH2jz0DddqjMI0rvO8AD9IpgVQeYMKVezwssnZs1fEu+oQISugqtMvVnDDxsMoFax3iHUpMialaPmumAXrH7sYUK2EBcmPI3xKJ3a/fEQlQ6V8bl9ECCguulQJXSvpXBl/Kon0b6BU0JfcMznCY2CGyx2Soq2dTXBU/JYg7xBz9hoQXYAhaIIB2iEWpd9nr4JGPR6jUbonczB51Rs9Jb0roTVGeI/8AEsh3lKi9gqu0qiC5cswighrEZzK+1HtKm1fuKw+YhjInETQJOn9zd5I8nA0ZmOY8gvmEchjwe0Ctzj1mEpxBmpOSZltpZj2iEw7T+MM8A0GDzL7onYN3eT8S9ybQ8wbSjl48E2lHe4ZJtLGnkLylxSFUytqHrQdCDEHuFmqbCwdiedNEwF+pjpb/AFEBonCneZZniuZXst7y+0p6qLH7hmqs9v2l9dndTGDlNByfeYQxBmxCbVvZVO5CPh9kbv0KjGWyhSpVOlxlg9xXdyLvFJVKeD3AWgBnFCMrAtj0Q6ECED4WAwPQjFu95niASzkS6mf81Mxxw394lR8TuQQFWfghfPzucRYkCHKqO2UwZrYEMXH+zAldbly/g/A6XLgy5fxrrX0R7nFADGa7R6rUHq6blZIJgeWaxhATMmV3J7eldWMfgy4s3K63UG+2/gQuWEubXGfMdOYmCs58RQ5BrzMSTPhvNmyXaYcSnVAe8e4rHrPAZiWm84kodK4ZfxK0TU0w/ePnCFC1WmLYnli8C8soKY1DORz/ABK2qDdaXB3R1ML/AIlhLBDS13xLtgond5ZS4L3L9KFOZf4S7Xolyr3CoyrMQJteLqCS6pimIIWG80uGKKhDQ4jAsj3BTP7ltLKjUEnqV/tUEhvtq/aJ/bm5IAXauW4UqAcky2tJwjkDsSmDn8jQxkApxMfaAwLaxpDMvhX5yPtY7gOzE00c2HvHDTSecTkBUx2xDoQIQ6MYKvcDMzZDFKjiUHJhi3DQwEZFNN/0iaPKSrBHCljHhcfzHPx56EbQO61Dmr+ZjKp6PL6lxj2ptPBAaXNnZV5+dR+dfC5cuDL+dSvkS3yNoAXGYPxGdySAB5GM/vTkRYTbZgYfJjH4PW+lxYmjpw/eI8Jan3jW6GkV5h+xjtrwbitsoBte+iKUNuaPMU+e+6AOUJOHhHbABA/84jGrJ2EulJ5RN0fxHv4p/wCRLS/tc3H7IIfy2Kf5LCrBfdm5+YwzVftY4zPuzQLA+/UTwH2CVMj7DFVL9w2lfkrKIYe5CbKveDZMHWqdy5f72LI9NowLHz7gisI2Mp2YFcW1wneAKDjgMcKyjpfYl5I9gDEjZ5qCDZ0KvuwKd3lIjN8AKViUxm9vzBSvYDP5IYY7nmjKgZ4313hpep+cVLrLAb8S76BAgdDqwZPZIztDUIZ13mpdQH/viCd2Ua4jX3gCdkYyp/8AXC3qBKixSvEbKBzWzwHAMfiOnHnp+oxrcoY+17hwh2K/x86+nUqV0vpcuXLly5fwr4PRR0u0jS8RQFtsrshEYJG02oln357BOvixjGMei/C49E8pCsBgNuS94obGdlEl+OP4jKEw6j5JfZGat+D+5kPW3LoBflgoz0RSZgsLUK+8CUXuLB8JKcWeWcI/UTr7VDJe8KXCqM77R5YEHeXxCy1h5ljAfE1afzCjIfdhFdGPsSwKbyKKP1OYPyKn9wzGPEbfOBp/UEvtAH8R13+ZDNFnJcTPZehMsF+FhjhNnNsP2m/FuA0EeCZeCFzOCe8uHQhKAOD8QKmEm6sIF1sHLfYl25KoZHdhkQ26Cc3eOF9zG9I7P/ZAZANDAgSodDrcunsGJU3PPdAu20Ri+SmUo4TYcuFYXQTZdNkALX7IibCD2GoTZS1YckoMj8xM0Hc3L3wQJ+UQXr4X8xlZV77Yz7QaI0c85YfaGRBoKD6PH06iRPiMuXL+kyhlE7ATAKwQzwDiDbwPENNNzcIYN4xmVL3XxYx6MYxj1ei9HLrP6R95PV6I7U3XDgIKodhi+aQgBwsCG6TvyYy02WBVtltsotm7mfHb+4VBvcsKJc1UG1vmGRQwgiJb7h1DGBaeZlxdgbZbfuIwiG8EoleoKmYNSylIcpZ9yAMgFBHtM1c+JKUk5f8AsvaRvVxgWrzSUwY7KQUAPu1f1MK95QniSJNOnyP6YsciWBB9o4pDXizurjKDy6pDp1xb9IiraFJW2AyII8Ux6bEx5ceyeuYdEOHA13Wrud4AsdrDsS4JHvtSzaN7GYLp9SmmX7/9TFlvkjdftmaUHsgzFIr5g4gNIbSrflcBgntBP7/7wkT4nusQ7v8ASlBBM4B6SmZGgYltX3llV+iE0l8T+I8VPvr8IdIHBRD6VfVSJK+d9bmOr0qDE+B/qITbnPqDhQEotMEu8TRBObntAlvM2e6/J6MYxIx+LGQpWvE7asPYmRCBiQJR34jM6nMplwZgwULe0a/ea2huqZyMM01zBTWuFa8QSwXL7RHaLlPSu8Yio8do9TB+75/EObDULzSwXFoGYuJnmNSGOYuwIGkKP2xOAHaC0TMbAry7QZYXlMRg/YYO2lZctbwoVRW4NxsHmHTDiJogQoO4XCL83/sgu1Nab9QMGe7NeoV0pi5RFAnFGKA01mCNQJbpTHaOjDcTx7iPbB7rBR1J4ZVawQJULra1Y4/ELoey4Up2vyIs/wBEw0fpAOH7Twz7RTa/EDslLo5iUvJTGCJ96jNXhejuGSRX33B1rD95k2oVpCZmTcyoBKbuocfbvKqjebPggAUGD/ErpcIdUiSqlSvhcvpfW+rKgqeS/wBSoeZXqXpeYVK/2TCItF/mMDQ0QlTmGj7fJ6PRjHozmPVycP2ZYbn+BEBmyUVvQeYpjTGBeyE7z/xPFjJpmLiVEZpFU4YrU3xGiP6xAqjlaamUYLzDM6TE5RK/+vvA7H+SWZcS9PEQ71/Ut0aQBMpvxOVVuJhTHB2jlRQ8zIDXc5jC2uCFeJ6dHwwTicvJGqwdPeKcE8sxv2AzH80LgEq4w/uUJHN9nqcFVE28wk7l4ZccRl8JU0NOuGL3Ku9f+ZkZr/0dDoEOtfBmD0Mj5iEpTeY2AUwQGoXZUCv/AKQZdHdMh5jChRKa4A1c/qBDNQaDofE618t/K+tdbl9E6VK+dy5fwuNyRCYGbSzEmWgmrwX8QUZTkNsuxYWRufsP8/NI9WPR6PVGHOnoi/8AL0GkiBuVBCW7nuGgb4l6PI5lmesNys+blwuPU2hlFBGDW8rfiV0buFSbbYiPueo1DwTig6JkUUGp3BFRiZy2x2OCOjnPEVVQu2GBW/8A1yjte2AbmjRLtyjLxL8FDz3jFTsJxp7J+oe8QHEU4lMWAd4MkEc3D7gwVGIiZGJTAl4gtwL3bqz4mjQmy8SyrPKYfBKUFpHDfeK2I+z1Lk+y7FynGCEIdD6IATJuV/4huC2ZBcxnIK/dM+05eQJmhj2vP6gYwwHTn6B87+jXSut9alCTfAYLz+3cXoe8gduhqL95ThlwgPS+lTt8bsO7GuvYXzEIYCGaEN/eOBs24hXfHgt1KFQG5OQ18kjGMY9HrUdeh/zGzWywAowEwsrbnIhxElCO0MMVczRYRSf8ZriHCCNOfUQKgjD5sY9TgZhuxFhX2RmA4jhXMUGCFj1tqx4Jmar5ndFcx7pQ0hsmVgeYva/qgloe5XlmLxNeL+cO0KNIboIl4joLNfpFzUWGP1KxsmFlj2oS8qklehqftNBS3tGRbbylAF58lEGNDOiWJ4NxfsxluOrc+SCCy/zswgQh0Po0LuSpXeNQJWZNRlDP8xn/AHGvdMaSODbCvu+1i0/7LOWvvL6GpUPhf0q6X8klSuly4PSpqFUfsSlJN7R3J7J3DhpT4NxDEniN19nmXI9/8lB+tARn7bGd259faXVOyblYi6zC1hzBRytEBaKLyiGlUoTsSxFuqMvaL5PwY9H4Ig230TzJ3BNysSOck+x0aJBQFJMINkOCwIv8wahBrxKIIVcwCLBLsFQWVbV+5njZiFtAxgmIZecRiRXaWmEBAoLhFLyu7K6j0QXSn2EyAVOWOqYJkxbnUIMEBULyjxBhPEEajAQhElhufjVHH2iurSjDUyskeiKn3wIRJL4nOxiXdafu8xC9Go/JBt7yQqEOp0IfMkrtglQoCoTix1Gci+Yk4tEZfkyGuMRNlpW04MRVm19wdFxD4XLnHyv6JKldCMqJK638OYy2JewZiz3MJkKjhyQOf6s+7jqGyV2j8RfFkUVVOSWuO0sh4hxGkuZ+z1XiO/ch3eyIGMXL+woPmHoae5CSCPJBh1Y9WMY9ahMCIo71LE3DbpuAbF6IPGmfcyf3FDpuY20uGFeJ5s3LoXvT7lyh1CIUzFYYq5Q/MqHwjb2nCBBtZmPtLWCq/hYeoae43VljPEXvnLHkCABNCMtuYUPEpjDZbpqVIYFypXQmAwEsmYDMQCQ0XiUEcSkPEqmBBTSwkLYBd/qZQDcMFX6UIEWorzxMzQAO3QQ+B81hKvgmtZkA5LJHC0J3hcJDaFCksauFeX/UBeDhy1ll38Gcx+F/V9SvlUZUr4vR+BiF0Q7Jcd9gxhbXtR7ga+GPMeGWLdYSr7Y2CQq/fSgsJ+6GcbNyhoHvELs7jZMW2IUdA+hgEs146sejHo9WBoV+8SK2L7y47soULPTH2lp9xtHTcdtIKWGCcI6FmF/tLOyUPqiJOl94yXLjJ4gaC8DLQ+17iUwIQ3UWfY7RcGr+YHbGCZ5eCVINzILHmGrqiE6i3VU1ID+ZTKgxKQhB6biS4gYXEr9ReWhdstFwwLuX+Xb/AIgbktYrW6pi99H3hoQOaX+YfboDrUPhmxdBqL3MFrAe0La92QKz7mI64DlO8EhoiLlSQxmQHEWdogYq4yiCvsMwWa689L+jXzqV9N6PS/opBCCx4ZXu5r5ryR4esxBnzKEvmVBGgiRwA929xgCYkOiMAK/qH5HljThH3Y7/AHUUbV7zLBXtjwIchjHoxjHoxYzDJ9nieDEtlKjcZRlinu6NbikwR2lMJhP5jZAV89mpaQCL3jaThlF2C5jHCEBJtCIzYqhiswv3DstOe8vJsP24/U7QmiPSa3Q5ZU7OEtBwma4Yoix2OUMAdA4zCugwYZ6nEuCXitxe8JLAiIOHMGwwWXd/Eq1iFlHwMVuwQdq4X2+x4gQh05+hrBl2YAih3KgPJkMquiYS2FVN9u4bjibi73w8wZR2iyb18L/y76pHpfS/ncuAzoJLU259ogDSoJDhiYhhKmqh+GCEg4XaKrXyenMYxj1WhXAZiKuH2JLhCICrHTdtahV+oVbeYrxHiM7z9kpY0BefDtNRIH379FVDxAoSo+HKtd2OXtUbBhfYf/IppEUD4BKq8rl9xUGtvMxA3uUgxBJdRgbX6lIvc1jhBgwhD4BamKpF2MpEXgFaaSgZgv8A6piMMp+5YFy5e5gQhCHU618ag4DfaFsmbcS1Z1AR1fUb8AdS/wBpmFt5EAuZqBsztbXrtCgPPyemGDZ9mN7CzxmK9noH/B38n5VGP0E+GGXAZY7lIHvUU+hmggI6zTAapjIdSwWl7O04lfFjGMYyurktKVPYsajtLBlYdDcFE7Edp3zLmV1DULAirMQANzv9U0XzBBgdqjxMWpkV4cSyrvI5fMwg5XGDcC/d/wDsEtxgm8aHaEgC1iAGa1spC75hi1zM2RcIu9UohxHUGEtzCXLg9GC4u7KGimwM8mCCNsoQwGxDLv8A3Yh22b+4xDvAzrVdCEOh1OlQ63Nw3RK0dWs81RCWlVKUTLUftczzLxaBywKj91iFUvcELmJU+5DALP2CA/iEMpDuq/uURK72RAPwZ/Es3jlzP16MqHxz9Z6kv6j30S/DBxCkoVtX7x8bgfDCLgUMpRMebkEGNMRVHh+4a9ZdW8j182MY9HqzMFI/ymslAhKLl13EwNQ328pVCdokEwLlpboXq7yqo96fEthGxwygH3mY90UU7x28DmZM2AfsEOAjcIRZqbdtYQ2igNalqKEIXA0hgTRT1DJBgkJcIQ6ZE+yZUHtLD3EHwGb+OBHX/kxK2ub/AMxBSUP6m57k5h0IQ6EPixYDJm+vBErq0PUI4WZ3MzZqVodRYTxFj3Msxrr3MGIP/EiH8Kf8BATH4pu5cUPTO0XqFf8A2/iLEbu1YKUnaTJVpVu36eul9L+b8H6LdNbjBR6JBav7I7oXxLslWRrMJm+EKnJBdULpreocHKVDKgzAgeroqhH5MY9Hqk9ufw/+wcYQMtLLxzBMvEdwAG40QllENzsjwkSrOI6KPy0o+PBx2jFTSQe1qZZqHEVZaUc5/lMBf1UPcIIQ58RmBpIhVAte0MJgv/SEVQ1UVYiGKKDBhcIMuHQ2SseUxfln4eJaon3GMi7/AMUF7QX7YSPNO4bvw6DCDCHyOjGXS/3Z/wDsZVxc7oK/tAqthLGSLrUdWNT71/IwKzUDeWBo9oiV86gfXqDL+L1fjfV630TMqUWivqyVZzgIhpqAs8X3mMFf9CaDYx0CrzDvtiOh+TGPR6pPTE/xKPsjVZZFggXGv46AtNMpdw7xYI7N7MSuI0hhLJUvKbkioPZ52l7v+hUVEGCCKBZ/FF/8DWLCd/xBvGoDDbFcGju8TK4Lnz/1KKgqChKoWC8ysAgQHoHoQ6HEEHiVw7soI9iMycktHBVlBSkT+IwiqUcwNQrCc9TodCHS+l9GFrQV+0Npyiehr+oJtVoCJXFqiXkbWNc3awLu1JlHtGuXT0tuJb2oLyOoyyw71XiXfSu8qV1qEPq38T4vR6V0XrcvpfUjmzbXuPnbFeIK+WXA0D7IPoQuOSXAwmIgPBqCA1+QSiCOHrfwYmXKiOaYXg+2Z3KNuL8dGc9LqU/8e0uE0MsQQztmS4vun2xFaeEANyrmRmcCGlGMumGZ8zvNPf8AzUbCqkvEeNEPMnQdz9sSwZdzR6WMvn/RHi2/6EHKqAdaZRUHaYQQ6FFzCFQhCX0MFyZLvH4S0wvITPwDFAu6KldFZ/wRlTK0j6x0PlfRi1Dbf2Jx/c7bsDyzHVmf3gnVCAg2gC5AgkU3uWlM/wAImwd8BaqUW2YtH+4GYfQOjHrz9Q6c/B6PW/lfwuYJD0T+FKgHJkqV3dCWAiovmFfqPwmBM9yytkH2YR7a/eGIa63ESv2u38S9ynit+xDC9xOX7cQYY8Co9GPRlffo/iE2vMVVE7hLXUxEiAeJdIJWZzM5Tm5zcdRzEghVTI4mKWJ9mbgKRG0QKFjav5YbF13EQaGiJn+z/gggIoIhLp6YOIDvBg89FQhXCDB66QEl+rcPvaVAHmW44DEI4if4QD8R9nEV/dCBDoorbPI+ILXbHGkPJCeG4dbly4lzhY/Zn/yW99sTQzK2ikSuHa9ywitRweEduBglBloNruS7hD4k56kenH+CfBIx6v0kj2IKfCApQdRi7MICl6F75S6NivfUfsAl7B4Ll1Jd23/1DKpZkg9kO6qWP5e/cuszx/ZDti7d194IUf8AkqBGMej0YfZD+IrDN6qIFTaYFKHKUi5VAV5hqu0GmXc9wtEo9mArQX6hUtVXKbdl2eI/RMLyTjIP5M/xGqnASvLLiZgy7HEIFENm2JhF3DTwlcUJcTTE0wfvBSH3j8sFOkMGDCKQEjzlRrPP1w4D2mGi/dNqyTgZWP7mYhBe+lw6ojtJV+UWHd5s+2pklZw2/NR95XAfuIHkOX7lgF7oZ7lMwLaxBn/qTf7mFa5vLv6h08auCuGVR1lboLK3JmGMtcQKKeYYJ+aXL/MXU+Z/g383oxjH5XLly4tQmiCPYmZoU9gjP8kHxhLh0j4Ka3vvH8S9M8GCZ2s7FCpdV+DZC+PeFhD0zyXiVxp5FMDCl2h1Yxj1oblIAjwhZq67RB1MkC8LGWYn5TiiSs3NhhHUNxLxKA5GGGEq2hSh35QoACvfvONyvxM4prXliaw/1Gu3bO9BiZEYBLI+jUTtUllWDKbCBzlhmXRYjITbB7BN+ZcU3FgEMhUofgRWPMRAxhcBQGIHngR2l9o8vcHoSpVwIMqR/wApb5/aI0g9mY/MxmDhE/DEaQHFT+pk9G8pKpKJZlt/Edgi0d+x3lJhSBoCUYwiPRckC3fECjMM1cYCYlFZY3/EepiWQZf0+Pr3L63Ho9Xo/B+FMF7Flr9T8EUu8wZc5igALe874fwhSxKhWsmj7lTuZRzunqYoA/qDJmvce0bN3nh9oKAFBL+DGMevjO/hhqHNS71UtIm5cqQc4w+Y1ni2PGI7IUxxDaRGdCyAGBzKCYrd3zG6DG705gE0++S6zekXNpVt6GaGtR0FIjlW+jKD2hXOItxlAehgQA5g2qHWqEtZGFUcvFvYIshwjPNg/iYcyb+5l6hSU3VMttolavOZUJqPcgHlhmHSpUpgHkh2X3GyNqwNcRRTlcsdRAFZ1OJTP+WWAtMSjPEUIcZMPQW3aZJkly73wl4iQMm1DsJQaBxB5Me5K6n03/Av4vV+T0xLg1DrHB7+ZfKXa9rKBrtRGW9Ba/aBOXEV94NJpChli/EVm03XiU0UyMd+Lv1LS4yO4xlURvkhbF05XZhD4MY9GMxb/wChG2x0b3LWQt7RjLiYm5dOI+egJjodUg5Q5iDLiGNx9kiLuGlb2RCS79naEWYC5e96v+ZXlVXKzecZdZngISqeYdsSwuYQ6Vlygiyh3G8sGIyZiBWK6mBAGoVu0BZ3mRnqRLiMlX2SXSbEi0OVn8QWI2QeMEISrgltecWKvhfuAlSulSokQqmq5uVj53IWUsu+8JRS59kJsTbMZFcS53bLLdXdyFNDQQI2TznsQQct5QT3NsBk4uM0uP8A11C2Cxar0yz6b9Rl/SZUY9K6PwYmYrD/AGYyS+3dgVUYWIR0GR4IPU4O1YrIHCYjDtT4e8cFhp/ca0RumAYEMRFJR2jd8seoYtAaY+pPK4Me25MyefXQZfRjGMYw3S839kqCOSBfmWFkqpmVAx27hpJhwbJSKDcvTKvMYE6Y1Dmz2CPKLMPuDINqEJ5goFK9pIbVW9N/kf1Dl1dIyeYU3K1ATUIWGmXmDLJQRCWGmoKrxLu4C5lTDcMKNXLPpcRm1jVJQ3kIyeB+p7VH7gBhsGCdG0lAQIQqDcLWCGu5Vnp+RolBlYuaDDsvseImB+QjlyjAMi0NBb8zicoe6iFF4mLyC2+YU7zpHp/3KgtvRfgnhtDFoPHXiBBNwYIS17m0jAYHjOjwwCfmOfYldagSpUqV0foPRZcv6jK61H4Jay4XXll+jrtrwJcA2+MJkHkrliABQYA0S4wDhOkjgLuV3JUHPOJZBU787MHK509yAJtrPqDZ4f0xwXQ0xJ+cVBarGt09zxBgy49GMejicD9Qo7kRqI4DzCHCKobTzAyRYJwwQ0x4isnI8MoEDAYVJR9gYBJtuAr2alSnMr8VU7PNetz1JwVIIKbjcR4zgp2GolcR03HuXmDMmWCoge3RIW+Ze4BjOu8JW4NOZaBMhYrU3/kiqvC1+YiJRcemWBeJeXdhA6Eu44I7mhN0HpjozFtLG27iOYLO/sEdKLMt69SogHNoOfvLz8oBTb+ZZivmGs7uzCGI68ykVvxd6HzDnku7KQJqLHfBcLGnYEYEr/Pt+5GQNAoiOREZUrqR6v0Liy5fU+g9Ho9GM5lxyhrv/wDDBqNZbV4j/fmOCGCjutvuAdcRgDDcf1F0mxHhnErwqctflBIayS4xQV9+J7QwxQJRP1KRYrU+0IK3sX6mFQjGPSpUICGovPlit3Ln7xpAouOYYRzXliBG0e0VTvMugU9NQClWHiVI3T5P/sGCFBm9nUeRCSuEinrgKzWfdiFAszf9UowzWJmMU4FkdWHXiV9jCrAxEy0DMpIgZTQhMUMwlQeZamVt3G6sl6wywVqXG5nRk3LOA2lf8CUjpn3qXeAJc1wxCEOhLHGLT/3uc6Gj7ITENsK1Ylco9vlgWEx+IzgfMQ0/6ECNYUpbTF/3L1s5v2wLWsE/O9iqndWa9viHEU3lX+utdah4j/hG6EECcGT2QCnZs4fEIiHJye5XQ6Mvo9bly5cvovTj6NfN6JUQCoA2vEoUjAuXwS76zk17XmEgHbMek89L63Lgm5jCzagLqvmC20G3dQ8cNpc/bcKs8b9PJGBWXiMFtcjD7cQsrwwuacBk9oRZ+S+jGMWYQs7jxHwVTaL/ALigOcMDAAd46HcYiapzFIWsFVistismG5jkhRId5cg8GVZsH2cwzR3FUcjiUV6hwhfbyfwNTGvMVVOH8SnEDiSwU3VJ+IbkPBlArjsQMnmiGqZEM+7JFT3eyv8AEzrnbAgYfcgWu+WGlAQMyR0QsPKAHlimCTFlaCtssBtWZ+J4Ai3eKRg+GBzDU/MpHb3CshCEqcRkfapUXhIkckBasbWC/n/qNDo7xVbRomR37g8EFwLAfyyoa1rseT/MxEtBNr1bDry5+yZXiLm2+DxDodT4VmJ2GYjRv4H2R6YOoTOSn4Mety5cuXLl/RPkRPihEANq4I6emtx7HiO0i19AyABtgZAHlqJKC4bZQ8lNcqMaZ8MJCpQHiOkpXfFxkcharawe8LBMksf7IzrSAvskEr1lN+4htjw4/KMLGNM3KiwrDD49mMzwPz9lXvlPmWHy1DD7sRFamNzWntHZa4mNKM1BWoM5g1EuCoR7PEc7hlxMgp7zH+1/aAuYsVAMVqmvZkM8HsX+ojCRuLg88s/TcojBPGflM3oj3YHaeiP2ieUGcBFgWvLHQBOJT1BEAHguYCHWW0ReM2GB2HnSI2R7INFKPERxmIZsk7jt9RCtBWFWu8BuReiyezWfcGO49TpxDQ5SizV6Mxxm7PEdWN9/+YYE0JVCafmOnV+Gux5gwC0Vz5fMSENVHTlZRTTbf9sHIUMxYzO3MOkGo4diL1v4nxfg32KYq6Ci23o9WXFiy5f0SX0PoMrrdQce3vePUqiDr+glTXxWMjpLAtleA6VrELAs1S/THoztS37zISxms2KQUicMEA5P2miKSIslNekXj3JNWDhJmdzxHyXdzUxlgwEvvCQ6zKKSBfgjh++ZexAtKj2qLlfFWXo4hc2CtV9wgGkvx7QWdg2XftGC77RFrlRZImwdwkx1tRamkxEuhBUfESm4Ki4CZiVFDvDiHY0tnqE6B5cX/wCYATX1FxiDnmLQXo2k2P2gWZF6Ts9jG6rAjDA2T7xsv7jC9X4iB0cDLMqnEdOSK4B5gxp6EIViDD6Bhk3THm3Bx5cFn2l61vC3FV7CpGK7fpINXdlx9oVTyOBf7hLpVrg+0ovgP7noA/qHKLMfwxgEBAvwsKWdq4QldGCaLoPLcQ1hs/xCRW9cMqoqNxQ5sPeMFpeAInAl4V+VgW00WIsoK02qYGDKCJbbznMyBHcmmsp+YFQl/C+p8DXxWXFixemf8d6UUOkqIQLWrler1eosq0BZ+t4Ee6Jc3gagA+1EeBZCXGaZKZfUWy8wqowyQceHZEAjbTNVtQzrbg2S2hxClbORhG6nsyuq9dku9ps3FNNKmIm6vca5u9XmXptZlXesJUb1LiiYhofFQhNMG2OVzETMi2cksIctwacQVx3iYoqUavHrfqOd75n7IFkYNiOmKN7j+hxHDkUHhgO8BoPvMH90/wB8QXym0GKwfqH2vEUKCXiyMYowGFbG9okqKgzkTAg9MCV+6F0ie4ANwXlpeQ3c9BSXUruGVE0GoaHYhA6mXNatSpAuPPvDdicT+5UdjvECiPuTJF6M92UphabvHeOgBys+f+kC1DtUygrZ/qJjWKEBvdtsxmWwO9su+o/WuLF+uS5cuXL+bHo9Ho9GPR+F1CP2GeXtFBs6DwcH4lmreL7R6fO13IKRXjPEp0H/AKUa9YymoMnwRKcqrsMMLrWEYG4lyw8EQQhVneU6tCkFbjUqaO13gAyi3ArDLjMHZLXdrJ3QMPuVkWXNOIdY2RBHaJHCMQCXARAKm8r7JjDZxARBw51MNU/hp/8As05lwRJR3LsiLR3gwhgf8/p/qF2JSlbtgdkBWCcc/EQtBB9qhluVpUpRcJCcjiB3ErwNyvE3FMvKGk7zWLJnMmRqBc9iJ8PErZ4IwjmBUGDKgpuc8+oiQjBvyYSjauiVVgH6itimRG4eC3mb4IZi+3pO6wIU9E3lbzNSgDLA7e+7wfI7I9/aNsZdnbkgV1IfEl/J6Mej9G+v5lwZfwuXD4vR6PzSVKlQ2YLRjNaH+0wdauAhbtk8xo6rSMUbTkNxZ/27McRYyeSOOxH8MVdT6PeE+DZKAcHD4m3JmNchj6eGbW8gi/gRXybN8eJrpu9lhNywbs+5RizEusREBiPU83HC5gzieJnqhRVxBcqmVqoZxHGlEsYoKyU7gxHDMZEglS48yjT27PuO/wAvBxJLJQkuOVwoVUGoBHAU6jcK1CSy0MKBLs2Q5fSTuSTlQgPZHeDdVKcMVLL2+UJq8QZcgpMuXCkfhvzZUU2jiaEOItHANvPqKhAfcdpedUahC7mYCHdqCLGHOToIDE4l14luC+WO6gVRtmWt88oo5uPvTpiuVsGZD9I6X8GXH64/C+p9N6sfiU09poiRkP8A7ZvdHnvFqz6fuhBGcp/3Hrgd5HkPsA/uV7o33IG7FePCO0DAC9avMSzM57PIdpvHL0S9NjimHJWOYuqd4YjLUXaLs+oqtE0JVZ5ZSwRO4K4Z/JHC2lZajiUppwwpgNxaeGaLxPuESug+IuJffJK84D7eZYFc8McHuEDMLFyoCPiWsQqdbPntv4l5ABpHY9piIhht3Ky0OJpE1CKHEuUOo+gEqWnHNogJQLNfIEAilbY6HfEPtBCkTg2lS3EQhGAZVwSpNcuD2xZGOqX+UXLG1i1Cq0w4bayrxCaae69iKhWBmrr+44xDipWHHEvWstHaLmAVAie9zcyk7ksJW1/Yxf7lWqc8gN/2kOAra4eb7w/prPD2Zr518nq9GMvpf1zodDpfR+knRgPjtI/C7v8AmwUkOALYOUXJufbAYtwIlypRMfF6fkeZjiQ87XZmOklVecesnXA5GYG0DxyHxH5N9nyShpNM8whmEJByzNn2Nu05mbDhuPlBYkTLw2QqlLOFsqIux3LCp4w02cSoeYDVXcU7RK3GDmJiC0ULfv8AgYI9ek4k+0o5wZeLgXUW2b49YaVyfsPvAbQhoJyDErmNGCXuEMuYSC9S4MwJZEVmbIOiXOCek5bQwInGTDCX8qCwcst7ltYEdUX4xO7L4nq4bURg2w8sQsCKW5Rvpy52wWa+29woDVk95Ymdyyn3t4IvB6wTCNtQAIm03/xDxBQKAmUKaEtMyna7P9XxAzvIhymkeF670dBGx1K6V1OlQ+DH5v0yHQ+j66PzTpUqBMHa/wBEdqV/2mGXBt/rvDQ3nuSu/wAGJyfmVbq+AdnzOFkchH4jTaSMBMDMwTLdTHx8G88XGmxauLxMiWsEAm5Vv+oY0UBLBmED74LsgpEQbS0wUGkDOxqAyyCo6WICsnSuvuIKOSK1/EGWXxMXLv0j3gKlNdokSlPJTh+0Le7Y4SWb4mSDCLKiq8nJEqty907PmCWBmFMyXc+6O0ER4cQmcXMxLSL2isazHMqKC5YpZciy/wBShGge6gJS1gTrQ4mXiPzMkLvgQVQHBqKcNnaUKGuQ2sBS/bAZ6/Ux/GGpWVztUQijteYro/llRGaAWrF2jG1AAABQGglQK6ELCpHTLU//AJ94i1fKOzL/ADx/OSn5HwY/N+m/QPjfwfnV9O4hnfwQsYn9wyrSNz+6YcbGAJUrrXSoEaAFv+CwHVsjtQ03a8olr+M4mmESxz2J48x0q2Vfw+I9tNT3i8hiNlx20wpCXcewjlsDvtLfFiWNyjKIoh2HmdsQuINCcRkeZwbg5ZiwyQ7MCYRC0V3lrfAgWmGYFS6hZ3G7kxk783eiflh8nCeOlx3Dzm0S/BGXc8AlxC51DBLW4IDqN5U59QgDRBPaMz71D7lDO8BLBaeYEbydiCAg4dsXiDTyYsRbysxjksMVngyzJAdwscA5iHBvVws97CiFWH0NepvcD4+5Ue1hryRSXu9m1AI6ab494/A6b6sZcfjcvqf5FSokrq9ASA/fggAFvF6O73YDdlvZL618a6LZC3IK8+ZcEWMeYq7ty9hXkhGCicqcusQ0gFRkpgj2Z2JkMwp78S4yoThsgsOJVAj3hHFi/Bg/09QNvqYkvLcRWu6KdMKKlHMMkuqlJhKjFi3Iyp6v6HaXkI6uPxWn1FSu9qGKcpG+x7/1De7E2dmFoWgiVGs4YtipUC55YLPLKxhsuWcxwHsepTxDamHgQAbX4AYqF2v3MrEAOqnjxLKK4DUTsT5SO4srbPRiWl7cMEbRIuCWt/p+5AYxnkPPeAzDoKPxA+N9KhKT/tPyRq1f4IYWOB2X/XwqHQIxjHovS5cvpv658D6adKgvCiLW4KcmTDAtR4P7lSvos5gk8H3OYHmVfCne8viMllsEtfeesQgVMpwYzGBuJjMSZanAjK2GXpmenEqR8I0AbiGuSY6dx9GcE/mXrLvEo3vMMxTAtalq1KnMcEXHEKl4junk9S6gblzfaIDRKRNMMJXuVGlSd0K2VuO1SixlBrn/ADE9DmcKJUowucklrmZG5WS0zKHBjF0bgxGAI6R37szTdJe2Eh7YaUVrruw8SnArEw0LYfpN+IAKT5j5gXeOUAcQSOzouMEsznfBD1JWFL77yoEPpGGD7e8ks/di1UrZIkrrUqXLjGXH/Bz9Gpx8D4MfhWMyjR9RioVoLl0udzxxLCF3ewlGIAOxGyDsFyy5zmAOzAbuYqaIoqhvce5hQJsg0u5iYlbFNzvwEsvZfeABOFwPhCgzOhm7h2lrNFSq205gJq6gChXiPJCWYg8TATTmJns/DDpB6Jo7orIkpuIDVMeMKYfM1XBs4GkgnIoPUHeo1ajkpQGJUIHJmsETEUSg3EDMvCxCJeCYjvMwPPFXcEsKZjsmMK4vxZKYJY0XGoZfQyrCXkiCgH7XLajwuM19+45s0F7ZxPweyBMk4bfJLNVbMMqV1rrUqV13MH/9Mksc9yrvD4hSCNjr4vR6vV+d/C/gfWIdU6Mfi/QqMfTD7jK6NBGY103gMrxKiANNH74mgIOYqIniOo7bmbuIbxzDkzGefGIRk1c/4gMM0FsoqHqD2gr26Ri0wcvOpZ6TYDE2VKmM1FLsvmD9G8QPhwH9wXG1a/AxxBsHZMyoxK2tSnhBm4162BO+j+EU3AqGrh70iJhUaYqamIBOJQIAMDHR3uWwd2ELNEtW+8AASzHiJsZIPalbqZqawRTfsGPPz6iMpj2uqATuHAw1fxjb7K8MfASv7xALaXDVSpUqVKr4VAldK6YH/wD0RDlo5OTt7ldH4PR6MY/5B1v4X1fm/B+NRrLplkE1H7YZOOfsS4s8SP6qGOYjeZkQ4zD2iNRI3xL7X1LnEbDhcSoZayxpggGypQmJfmrxDSOmeOGFQNC5hhDcrVjkxMQmUVsbMkoOnCTC+LfZ2ZSBRSOx7TLPMNkFGI5Ng2RKA0h5EjNWl4Vdvc4LNRaCN9MChGEO4SVLsuozxjlcNupiGRZ543MS4L9rKMckqmxoW0P/ACVaw42hqUvfZBRVd1QfxMKfy5YRQ3qUoaF/cpPAocPEYVq39xiHXVnzEqV9CulfCsR2FaDY94jfzD5+LHo9V6v1Pz0uX0H4nS+l9Rl9Xq/UuPuCRvYQfdf/ACYdGP3m/qHMXMcN5ihjKxmVV3NdKI44Rj7xipgHbCv4R0A2ZIjzm9bdpbKBP+mYNGZgbl5kiWyqVTDGYvMYnhhKYGS4AZTAd+8rMDMbnNw7hWXDldmIqkcHb7kW5sfAO5FUsiw/yijBG7lObcvlh214AvXmZOTMvMZaxK3EMx2ieYZU26/lEF7WaaNXGLyg9aYExKlRwma/ZyRaf7UmSMgtX7LlSpUrpUqV0rrUr4BZ7XAOm+j0emui/XPhf+IkY9X6BMbevccBvo8sqtQfdZdypUY7sPvUSLOGe48yrggslES5hqUAuGKTmOsByTSkZDcKwftATO4bJGrw94ZSVPZwztZplBmziWFxmjuMXBlB0WJzGybVWGJyKRJZA2d0dphKuFVHJuZKT8fmUW8Mg35EDldK0/8AYMLmUg8nzCLXcHRQwd3tGmL48HBFbbqFQK3IYDVfqVNNxmitYVHeO2sDfgS9hQYI8jFZJaCB7QhHIjpxAS2fZf8A7FwYPvdK+FfQr4XHqxj0Yxj/AIo/E+Z9J+d1M6l/aCOkKv2yFNFHaGJcGYLsPssiu0t6BRqUwQRsehWhHl4lFn7nJv6QaEEY+ZxBGsEEM3iX9sjyd4qDFs9agiLGEZLiNiMOYKicx1DDTFkddoCNKVQg8tRsdYf+4iMGZbnCQxEZVMh+H/kga9dd/BlLcBrrAjI0omxX5SMgIGafgEJgK/cpIbYw0EHJhAKoWzf/AAo1DUJ2OWUMm4cTQdSiY6if/wAjNVDN6f8A7CuJXy5+L8HpfTjo9H5105j8a6V0vpf07ly/nfR6p8r6VbKq0/6QlqPfoa/mNROrgFXB6zKMpds4liVKSvVlupkp6AqNKTcVRIqMtTOP9TO6shuMpfuKBgKljvBCrI+61G3ogcCmUSs3HCmUuJsiBmJBzELmOi0LzMIaVTfEbOMK/wDVwe55RRYgC5ZzCmRsyS7bbTiYYLynj1DZ1En01v6hHsQ3jdjAQMeeXvKi/iZFtlcKtgm5VxK+FWfEdqIh+8SktgrpVj2ll7RPBlaGYSukqWV2v41BB5y99a6V8a+g/B6MfqhMfE+d9bly/hcvoS+lfB+L1FyszHufJ45YSAGA8Q6sQRBaKTuQaDZfwjxEm5kblDCogxOGF5iQGGIwIiQTtSMxHEp35Nu8G1xKExnaDYEG/sFOYsepUUP1Mwl5NxHdOxH307GLxUV/aHuR2VAQRxkjK1XzH+rgWQhLRxB1gQnKe4htm16guS7tXclZLas23fNymtrLqDDlbefaHxqOx+wSwZQyS/wIRQIb7TW5VcJVdZhZ01nogAxL94n/AK4x0oouUlsMHtBmJGyvvxFFeYCH+EvR6vwfpcfC/nf0L6X1JcH4V1flRDTm9S6SgUfy/wASgldXoTIX+R2+8EhUgeGIDEsa1MdpQ1GHERExHGZdTuliquksRgM0jH7hTRTsywVH9yzYQPaKRJvi9MyrIYPHTek8jKDx5gIxcgSlmEeLNkqOFhYFJh/Eo6UyJhIUCm+9uz4hlBuDcVVAaHHuIhXSG1UxnMsI6+PvrszPPxCU3MUFQHXxHFF/+KiOddmZSg4IkvxLeXaURrd3lKM6FwwsU/Ep8rgxKDNBeJ/tOh95Me5VGG/JiCNVp6c/K+v36v0Ho/B6XL+B8Lly+t/4dy5fxY9XobqFs1J5WUi0R7efg9fUYvtxPzeoZS7mGUsz3FsiXBxCysZlUx0TWpQih90SBU3yeYbzXZlIuP7m3IC49S/bvrcLsCJ+YvqV7yvKhKouAalwxRzqEyVMLCuI5SUxLIAo9QzYFJyRYK/uerFmcTBcPQsNkIW90InBjnfZi0T/AA+Rhv2HMucJz3RLF0Okuzgs7GEjBYkwiCbBZ4j0TBUv+8eorYL7xpqGMAcEPEfDMhks1KUsus5P/kJUtBORly/pvyY9Hq/DPxPhcuX1Po38L+Fy/hddL+D8EgvgE/MFtvXdSq6sfgTBATtEe4asJ29xIRWQEbSoeJTBEJUdhNkQeSIhXqG3lsitg3DNozhliDr2lexmAnf20ylsTh4gAQmmBGVDE3W42wjGEiKX5NkZ51zBBnDLkAOJemuAFJrEsFlr2vDBxmFu7lGpoVFbfQO7bklYBVjuvEv33nwyps+mWlU7MQJZ3sxo57MEGMlpe01AwwyvLjwSgIryIrtKhKJtmYSqXRFRUNWRwk3dS8S5cuXLly/g/QelR6sX53Lly+l9Llwl9b+hcv43Lly5cuXLly/kZlWq+821Ba7sfnmWwtrkvPclgDlUkKql8u4ynEU1EI5eJYwkVG5hqFUMmZiu0dFNSpguCRvZAKtldw3BgiWZaNlbIqXWhxfcHIjfMPVDrKuAvmVMkD2TO2GBUzbJVqAcaT3O8r1xv8Q/mICEpP7gCXsUGBfiFoJQPuVhnAsZQQuA8ZSOo0I+FAEFTAKzHR+cp+0Ka1KiqJR5gGrhtMRL3LLZcGXLly5cuX0vo/F6uuruPR6PzuXL63HodL6XL6XCLLly5cuXLly+ly+ly5cuXLly+lzehC2fOoypVzLfMDFqH7mCC7xCR1AViCNXDJLInDEzrnjo1h6CmMw6dpTLv8I9Fhz2kESiFYKZkIHLj1Cgp7m4ZVxDBmDbEYXvHRYwDZk1EIcNQVSSX9s/cxJN4PBm+6aitLOjlB0ZNsUw/uclwzsxthU00agJZeng5ggol3MGV2lEccRTtMthLuldp4h63Lly5cvpcuXL+Cy/k9Lj9S+ly+t/C5fwuXL63L+Fy5cuXLly5cuXLl+el9L6VKlSpUJhBAFfsp4wKWzXMWjDLnogO4KjBFSzioaF1ZLwT1FIIkSoolsdHaXrM3BtoZdj8oYaJatZ7zUUrkjoNLjaHcA2tkMEYiwmOpP7yZQuZ2gble7zDKDQy7JoODBdgjAye/EeVbrISypsfMc4p2oPQmiJEmrl6qYWmLQ0rsSgUQLgmUJqtxbqp7IDApzEvUphZuUY17y7ydSX0uXNoqVQlhl9L638biy5fW/8K5cvpcuX8L63Lly5cuXLly+i5cuXLly/o1EjcVY3ANr5/UVxMtsMQe8p0UYsu4otS6JUsQIalSrD9wKoSpVLlMAVtLGI8nePuutrcNbDAWyo4wR2ogBUdJCsaPECUp+ZaBtjdE74X1L6DtDCEMD3h7xVFfDsgNEXZFW2+NgAuv8A8Uxrwvw/eJA6ndmTUPxLKGopMQNA6QKhUQdzfkC4mPSVaJVdE7MplPDLWFA90zzgTvBtJL6U9zvKVaVhR0sW1Lly+l9Lly5cfoMfqXLly5cuXLl9Lly5cuXLly5cuXL6XL6X1uXLly5cvpcuX0qKgHlQiKbAxmHsplmK5gUzBnEb6XTMMXgqNMY2HtCqzKyBuI/csHtxLpThlSllpoUgPJxAFXcB3LmqlN4htESxgAKBvu9RVi3mboPeO2oLHh8MMinTryING4SblLCyg9yU6+SEmauWLLhzElqO/wDqXGhSRFAb6NDdQjNSnpjGAyup0SJPcE10WYvoF3EvTGuyyDOUhUWpgDrUS5S5/EWXLly5cuLLl/Rfnz8L+Fy/PwuXLly5cvrcuX8Lly+ly+l9L6XCXLly5cuPEPut8+ItuXfh9peoURPn1eSBxKTiNVElTBuNMa3G7sj3RLJhVhilhmI3ie0WqbEjlcIg7gwpE8W/xhHMrpCCsovhAToaSOPYeFgIUkEIeliUtTFhPcriK84rz2gEb3BOyWvEdlLGDMtoUKESdzO8sdzvDOFeJ4wEBxAldKlTnriFdRhlRkj4M5swBKIWgKFJ7QBsbJ3SoPQDma/yS5cuXLly+l/G/i/SuX0uXL63Lly5fwvpcuX9G5f0L6X0HsIX/UWmi+AQbbP5ljTlh5IeCwLhoxEgd4xKjLiXDUtjs4HMMM3AVYpmcGeSF5io7ySt3DoMq1uqjDbT+o1L/BAd1BaqWCEO40SOBOs5+0w2HBGLW+7caAxQbllqM34fTxFVYeOXp1BBbvzOcgnD09AqCAQKUEgZYwlSpXQ6M5+FdEmOZRKJXqVH0loNbSVlbrMu+iqlhE949wh1XaS/jv4cS5fyfhfTH1rly/gfRPjfw56X0uX0vR+HMVwlld6mXL1LCmAZRWJGbeOvJMA5lEzKGolESO/HRSRZcTio1C4H1KBNnEU+6GJVBa2CQw2dBKw2Q3WGUYZmEIjo57MAacMPjFLssiZct8YWTdibFvuQnJYcy7T8DJ6Y9Inmv8ty3WLmv9THffJfuFYX0JXYyr5I4lpEKMvMO2Q1hN9pXWvjcuXFjLlneI7yrmJbjTlzS8JQ1YYfekC5EiOQEb6urfCWtUcWP6hrRfKH8QgliDSzPeGdCPwv6DL+hX066XL+fHU/xLjJQG1ljT7/ANTKuL3inksA2+JR4i34YRIaXuVqhsNMMAWtISVGBYkEbiczKMahAtuJGtRfCxbIlESXAvcqM9OuMi9WSYVw+YrJhnMK/uaRPTuIccxW0fqLYWJBawd+YGIXzIrzCrp+YKQ58wff9xcVsR5D+5ZAOxDTi/j/AFHcr6EyZT2aYbh+sxMTV3Uxg/uj/wBoMK7azQyxXWDa/NBtBhfSMXGZ3ElYhuV8SnvFNR3vEjNZcHDyqGlq0aPbFUo6whK1Nh3gaefQ/cRG0FZizQHePgX3SCWNvBFQQv3W4BAE9R6TP8MC6HMs1tOrD/EOn2/y6+nWLdQNEzHXA8NRFgFQ0+4eCVwiN5lY5kBi4ZsMS+k3tcsR7LTxGqwhmInoCFGNwvTCMSNqziEzvFlAFe026KOmLGiklOxqW5h92eSrkHVkxm6Iq0ivFiQGBZHJQZTC8QsuGVLe5oDc2SJ5Icog2oEMxxGs+I7iH4TAxLfDFaMPlja7HMKYmyVV9wCKqI4JGZ4suIUEpvxLGcPEsEPZUVfCMphrHDGUu+BACzssMKEOYE2RlA9iRazQekg9GAwF8QwMPsSksL9Tbx9gZRu8wHk+tf8A+LfQ+iDZnjmOUrIGt69jUsbbH7bYU0e2KgN9OyJVFBqA1paQSVeWPEMbNzidwr6iHjknLtBooxM8Xiy/CMUTE0gZtLMSnXYjH+yJe6m8lrXeFm+hXO3OWWSyKNmGChnJBe83KkADC+4TBLO2E2W/eKZu9MrG2kUchG7Y5a/cu8vzC7Cg+3GqWUMFYLrWULqflM5S/eUNNSjZzEtUg3RgIdx/qLYrusqn8ia7XeDCvuDGRC7tKBwfU3BJQEPt00W4XqIxefMAqPPCDmnDKxOzcRkTCMBua/DxNhuHPg0zfD+Q4lK1x/jcdH48/wCZz8Ba4j7PqLVEGpF6I0GUDu7879SGwh22+WE8wadaKvDiWcwZmRUhTDcR7kMQ5GUlm6XCB5IGK+3DNwdhhJKJKcRNo6wwZcz6RV3phNUwsmxqIYs1BTfVaZgzUExcIEYImS4Fl/dBcdyktj1GVoeY6v3SOYXskoYL8Q/oU55Craj7QXN+0HyoNq0gL00xm/wxxq/889PoNZJaWfghc4a2hUkZ0iAFb2QQBnMM1RgNIMQzglPEMcMMmoFynIQOSFt4gEoWSnTJMtS7z+ZnSGI24/cGWal8NgGVjdT2p/h387+nf0D6wrkOA/giFFmMLCu8a7YgDLDBRt2nvOVTGvEsLSy8MLaWEtS8XAyMQAnT5yZ75jDTsgEm4xhK1d5mNZnqJGCyuJxBEYQMcylKIneG5coR7QSSZcoJUs+DqLSCJ3IN6hTYzuwKblZM3z3gEznzAc5mZ0Qoo++TMhDLEt6/BNJablsZof2hRdfEfAPioGQb2/aA2/URs39pi+DxMKAOBuAUXbeYNQLl7ZhhXdJbVgIVKINdCql9GER10ZUqDUGIZYbJda1Dq/8ACX1bY7fdlYvDBo3gfV5+jfS/hcfqa6H0D5XUtUB+5K+IvbvLRuBNrgxxB9ttNeoFVcR7IDEXy95XNy3wQiuYWnEYcLLrNIdkKpTK25QJwTHduXqYJAwypuoNOJR88n+kBoIxWXLhUlFkuZipzBXsJZkjVRmOCoN4lEz0ViQEu3LxBcRSF9zlnJcp5ilDVSuIHtPHqB0hl6pnxLdwbg9keECdhMmBEOo3iBhEpgGxZbpV2MZvM45mTpAAcSFMmodxABUEIxbvB7XBIPnpqutRJUrpcRNZhsHJVQyxGASzvNdjUhoCzjmKgc/P3/j39W/mfL3QvBHCxQB7lOGoa7Gc/vbLcEXdtEtjGOhW8pcANEYWoXCu4FPeNYWJMnLBGxlvE8cbIuY7bBlCcUZLcJGVKQGZmrgxNjEGsSmUvMviXBLZNwhdZjZaEJQi63KrEsTLccwSPQFDMvtLQcEaY5subJYNkB7gOUfcIpaQBpDzK+sothuFwwWRQRbV5m1M5QYcB8u4GPYmIcBPtMDBHLe5pic8fcVoZ3mU5uBTB2ley+8r2f3l2vyw0m+8w8ypUt0GziDL6N8m4iCuEXy3YdMw2lGa3BKC8j6L8K+L8XodX57+gfMh8EHoEtdlzLjcse4yodSlBlZRLXPabC4gWpJ2uNHuKUkdzhsllzMwNhEKuFxRlyljFKuxBrbuMI6uBYZuKXZHFl8vAKtP7hlA2Rg4iu4KiEVWMsz7iU1cEUhNkSUse05YcKzlEBsijc9JSjRhlfLLcRWWNEtWT9Rt4E9S8yX7mx71gf8AbLR+2A/pNwyzvipiMni2Xj71gQCrxABhUQmWHBmW7TT0JRtOwzmITYGYEyzEOeo76POJwcsJ3X92WNXxNiqA4vv/AOSnqu+IjbJ5Y77CKhllLl3EGeMqtktGAEdjfhmQAt8p6irXcAM1K+N/HmV83/Bfjx8D518C/tWYzByxk5BMBmoARTRMUowlChc+fhLsRctmJiFqba5nijwpDASeoS4uPaZ/jKWHEBqrJZeI5aEsMO4ti3fhhVEb8wy4ibhSNFkyWqSG1Z4R3DfbTLvYxSxIblJHiITkR7eCV6YszLHE8UOxMG5WZgecQXOe2Uwj+UIcfaDPZfM7KOuIaIFFwQDADRE5ZR2ShYGJVVITblhmKmHNRXdtS1miJzA0pXzEaR9QpK7TyngQO5A7Eo76H8x9QbaTiWqC7QXaX0qVExA6ajY77IAs+i/GvovU+FTn/EJXQUTjPB3g5zb3j8lsxngTMlxM2JQRK+0PiQgg4AEcMBskuusVKrQ3DS4kbl+o7rmE8kqEeIoH7+phLhIlS4jGksEqIlqVNMtTLblcNPYW4VdMzAEYydNoqssmDROzP5rJyme4kP55/v2UacA3+JAOfwps19Zl7T+KjNB7ThR8Jbv7tGeIjR+orqcExMKMrrD9pS4Q+EMdTskSB5mrOkAM4IvyQHB+IL0QgO8KgNnpflLgwSVI58oJogLcQNwPLU3IfeVZ1TlIFgrKjBBWSVAdPwer9B+T1v6WPqPz1VNxe86HYjwKDuJ+KlkjEOZFdszlwZjO83EpiCCQ28kGIkRj3x7ZW3EmYOcDiPa3WSWRaPh7lFkEuIiIlxVZlTmUlhE5Ia/sYboeHMDxuA3zm6jnKAch9uhB3PdBd4J3h3XKMAQ/Cj8qjMRrNprUiGk3kbSKgAEM4JU3U7sE4n4JVEcJYcsvsRuWWdGPuKrkhXeBekiShCEBMblhyIXcOWL8x5iclZRuWELsj7zEU/uJUwPoiS7Hp/3MrA/8VBk446ZfQa+8ONkA66B4iS2fE0vc+T9V+J87618ePoHxSgxSR5dKEvZAVOx0DPhmIwUmGIW1xYfcy8LdQSTCRnYbmYG7iRr7yoFcanlDRU7EYXhldWRzKzNeZZW3juJ5SHfH6gbkRAUyuDESZK7kGDU4gqb32QwSfEp1GL2KjuMTkI/RUbNsKMXE3/pB1dwgbMJqp6l7p+IAXUr4/UEdQxtJ2SeKXMHtAdpQ4lckoRizbBa30lYyhEt5lBiTkBLilYFjMBqXaixuKUty7/cxN1CtpNnCCAFAcQQwQ9EEbZAmDbvvARHvsIVAtsi+EMMynvWZk0/+NMpiB+JWG04FGAejsgnXEf8ABetdL/weYfTfNkWI6XcVbjB7EYIXZLCFJqmX4Qksjj4ni4qKuy4qBcw0LzKMVhi2BlACyVrF32ldBc2hx0ry5WX61EdJUPhhqrXDEMemIQuSJMqhuH8Rx1LSncGbhFadpTynbv7wGKPJEdYjceYV53Aq4iKwQO0HtBEY5yVACoQXiGNYJW8Eu6ijLAXKZQS8YmBLeI26gOx4i/GWKaKirKrLO4Ng9oKAkFH7iJWgzAKLeMQN25YlaIjkpAB8WNEbWq8NStpuGBpAeLMBrtM9oX2lsMMwugSbhml4jmGCCGZ78y7LJcv5HzfoX834HzrpXwPgqmEA5WWEM1iKVtuWM5amroszI7iM3bL8TNQfe6DTUTG5YNiFZdwWvT3lK/vHDBuU8RzjjEqPEF9NyxiW0ylOR/CD0Se5xwZsAMJET9QxQS8XHzLNyIicMtNRXpAxLAO7gwh/VQMgfMEsRg7gRsMsB5jXMO2CAlwzjiDz+oGoBBMwQyzJxPvLKlLIJ3BE9I9hxFQKxoomTJAkIqsT1A8SzidmAHO4aGCDKcEatUtr23yZXK728sPtBGDMFTUERLTKcXATI/MG2JohLjq4ZY7MZUwQxaWWpbNfXel//gXLjBXGvzG3Pcy3LtSoSgr7wAJN0s0NEV6HK7MOLRsSMLq7QAJcXZ3GuNMwxYKbJgQiyunaMo6Qi3E5I+EVPLptcssT8DuKexcQ0qyXE2MLIgsAsKQhBCnBMIU+ok5vcTeUieooczzIwJq4vErwr5GY7JKozOyjVLUwwEBsN3DjZArsmHFfmY9zHjcowbvEDhj2rQjyaQfOoCsE9qzvEHSQC1C+WBlVGkusx1mKu2oVwXEDEJglAiwHd1FPmXCNHhXBMCCEYrEAaiKzCOIGdwk7JeInlhZz5FH5gqtDyzFEvllU33b8QxbyDSREAZQU7lB6iDTBikMT7f8A4Vzf10YhJxf/ABKEQgCXmOBaDFOu/wBpkXUWMlrLDJLMMGfJM3aUS7lh5i1umFudSzXucOWxiYNQWx9GEaIxxKLolDmV4iRJjiaHQ24Xt3mEWDiWoY5maD7zbBcc7yNXJTCqJGBqSDbmncgeREqSNeIe6C8MK6gVKwSANRVrNzTWENy9whSQuxQ7SzN61sIPcD3cpdhilFEwwAywPvBaCBIB6mG9yjEbMccXLUrvcWsBMKQOIo3HvMaI4uXXni1ExJ6xAwBUOhiYvEs3iCwlsQApXM9L8NzObe+WG/KlZ+IAAjsqA8EO1ADZiUceBUfPcn9ZT3CHGLYgsFVuoVDH8UVl7kuP0X6Gpn/Cv4vxqeCVFUNEHD6hM8RaXaKyzmK7UVVdrPUvxmLECPiC7LGEa7Dge0YmYBIRzHtB9WaO2yZbMw0FjM2sSkQLlKwZx+ovaV8RtDGOQxUGKag2aHMV0fvBa17iICMID9IuVTFbJFOBg9E+5ngLxDRwi64PUucIV3+sHWkoxnGpp9pVWCGyqBVW/E7Kgzh1EOhOUkCyqBclvmU6A6BIXJBMO0m/ECxrzAiqP1C1moJtgFld5skxDHNpL9Ad2LL7a5eq+25eUvggxWUN1BNQZl0WzYAg5FklvR+w+8XGA+qGvYVn8wdA6AlJVS63UB7RVV5BHt6jUWwPD39QqotwvEj0PEoJ+v8APHxf8Vl/VcUfyMRo9XqHQHuXJzFvjgmWCnJqZLlzXlS6/eZ1EA3EupXcoW+yQ8VJHCSkS3RLxxFNkBsIYR74rQRCrDAcYlRq0vudytwi9tQWJnFWpZuKgODEI3aMKbXFya7S6w2RCxeOIRRd8x6A1wwaymMKFk4R+8scUhF5nidhMAyiwbGEAzdFZIOpAcjAiJChA5eJumUJCph0faI2+yPgUIZUQ9xre4w2wcN+ysADHu2/iVPoQqDRoe6VQA4JQ3EGeJc2L9yzFzGsoMp1+6Wlt3NRu2B4IallASiGGoHaK3VSogsXFWxVoNsTFr47+8EBoJoIHRqCEHVAHLEjPuJdPtVD+IzxeyLhZ+ZgQvDgcPmpl3PZ4e0bHAaGncMo5mFvb6Sy/wD8NEaC2WJ7T2Iio1KCXV0VXQlFWJA8QB0MUzCrIoA2Z9wBqV34lJK7pcY6UA5O8tELIUd5ePibpWzLFw4rnkhYV9wbcLbm3EJwI2/4IC3J6irZctZPxGBrEPG1qCcAYWFVUsOI+RVEVVB8RHENBT7xG0GAQdso6XaB1ZjGgHiGYM+JcKW34lFUWlaYvFb1HWFSWQYQ1l+4rhjto7QA82M5MlsY8Br8wQo+VhokfOD8QuvTZQBNRYVYBN8VlqWxLKEKZEJssd2MKn0lxweGoGED9ECsTLWicbiDLLzJDtaClz8u2UDn3NwxglGoKUEPMQLWgjpXtg9ss231i/LN/XithNRef6IoerWYMAryn9wlVty7IB9VHZHk/UQ3kmQ90VFM/W+k/Sv5X0Po38jqiqqH2msl1RahtTdQiyLAfZAaTHu0u1kXYPHhgloZaalOI0Ame8PgoE8TaR+UdpaCZlOJgUmbU8ULMEyKT3ifjARdrvvGR58RgangxbZ0Q0U/EbZgKq1MOpygQBqaAgl0o2iMsNMviJbBqXKzKXTCwQbnNdMRo1JkFqwwZOzPOYgWJUuV+wC4MPrBMt9o/uZRC5zgtEHiXXQ4YqHMiE4ylqFiGYIDKv3C6KUluMXtFCYPLBC1KIJI1BFBMsCSwWpLV8RjRcM8j56lL7dnbTHUF4mmIYRQ5mLJdG18Exaq4aPLHwYek9sLH9J9oA4gCLGSIRDsSANfEPNX2i3ak7ocn6YaPIYjksliHLAoDt/i18H/ABXPcftYBS5Y7S5lc5juJcZVEV/uEs3OY9RsbCGXZXkiGBkTPiKnmcmI7f8ApEGuoP8AJD2QROWd8mOyP2meB44mABfZqMCz3EoLWMSolu4YWwUI4gJNzEjBcdpm1KzDghhHKFPKMKhLIyk7zHDKxhRKMXC/MbSxzAeEutvBuVCHcrP4hJyga/CFRB2MwkUTDUCXQhrFeGTEqvKV1xBsvuzuSc+D2IrTHlli6nYggcsEIKjU3hBHglFiYC5UsxygJLum7cQw7b2ENAAlOWeCUbgXqDGYkKG7j9S0vR6grObkn+on/wA73YKABFiEqE0gqAgj6dwdso9Bj9scClL1DZYkYA7BuCJZz8Ofk/Rf8q+8TsCSIxzE5GJxuDKX1O/LSpmY1gV0xq2jVJTBMmSWTtplcQF1pmMxv9hE3OpOJgxquXmol+ITxCeJTxFaVyuJBY2+OY4W3FJyMyGkcFpmOIJAJTxMcwRqA3ZAtZiXGEO8EJwR3TAXIy3mVTKEeAsfFnz0hp5C5+5SU7kgWZcVSkVFuKlRlsIixhL4EZ7SJtYRz6ZZWKkJovctx16lGRe7F8A7S0Nj5hkcPUqrgGsJT4QpAiwsoa5JagFmeq/LK2Tv3YIYOmERMVmMlTEYYL8QqLnZ4grJLBl9JnfkZyvLKk4t40QMQiwtHJNmeIVQKc9wYlFWMILdMAEdyjP7S+t9K6P+U/I+NSsxgVv/AHuYV4m5AQ5K5YHv01tmdm9CJYYYgXiDabjaY8mCacwJTkjN0YU4dQK1GYG/D3lnxwMh7iNoZzCdV0/BLeJXqU7JfILuR4B/IlAdPDCt7gVW4hLWHMciguAbJXEQCJMJEcdM7OU8iKGoyxGKv1E3YLypnfUlTr53WfiGBRdkne1NBUWpsEmIMxUQwlsFuX9lPMApEUQKosXzDOZU9pS0JCcGPRj9RS+U4TMGmNwJsmZjFyhuaV7RHOIkUx4gnCQdKXM2zvER89Aa9QTAYlXEO6BUurzBbsIr2cBthzw5vKSrgl0zXtlwEO3CEV2C2AJqKpBbixB6PL0vXuTnOIJ/a+9yik3GaRxBsE5lxnMrpcfo3/mscFL0ojHSUnmUnEWWtxhPYYqMwkg6TZZFFqHFTK7eU22KxiXeCh5mzo0xW9xjydo6N7D+I2A8rcPUcChvAkNywIj8aijCdkDtAJllhSJansOGBYT2bhTZpgvY6YSJGty2WQQVCuSBdJ0o2DHtUt2lfMMEB4I5MwAdFg4jXN9AdxCLTQxtszsKn3jaO+otRBiC+gTIVbHcxPEGhgQJognEA4lHEB4YFa1FzGkEgjioPYlzgVLYx+w+8UP0whgIHaF5dAKmmJWUqEreogc3viRbcBbl/BHlNLqHjtM9cjIX7ylxwwkTNX2ghtY+eGOXCKinEVeXEyEihOdfqaahA5RDd1Lq8nxfo3Ll/wCMdOfjrJxNBmF4YyDiVlJtD+2XZPsRWMsXLToFEXIX14jlbhhcQLEjnoXbmrcQY4lGZiHBm4B4MTEzkw+RmgsJRBmzUV3LjUc81CupyzPhOzFVr7f7Sq6t4iFlMzYDEqAVOG4FapFbLZBNACDepe6DPBwLmb+1s+7KONwXyz9Rq0sC5tnbRM5rlwAvjMRj13Zm5h3L+U41HwiUBf8AEMxUM4hmIAMQ41BI4JgeIg1DGdhJmXFw2YXaPEeGU/8AhYKCnAQ4C8CBUuoATYxXKmoL9mJpA4Bo9xO9yuHoQnIbiMHED30M5yXHZK35qZniKLUGOh5IsRV2QlxhmwnAXEc0xRU3Kx5xHo9L6V8r+L0uHxr/AA2NQ2EmKZoIjB94q7lqCojiXO5UxrmHVEBMahjuaOHmLzVW9QMiFjLE6G8rPMVQBWRGX/iIMVh2NfsIdKc/uExEYp4i+ZZmJipvmOo9kTsygp+8KzY+ZgPvsstYfMAS476S4DcjH5lBWf8Au2GAqc7YtTsSrOIo4hsIfecZXxFqbPLLl0OwzKWPdgDBiVmwKlTEMjbCxgMzvQA6gIg7j3IIRPEOFuc1MLmJbWRQ3VzDrUYzXwSloXMGgESFVxWsUxqZxH5Q7seJTYb9Smh5RVAjvkwCRlg4HKF7GeKlEt8/3n2CgxComZyOI710aI6WcYFq2IxWPEcPd/xFHpm8xBA7w+FfQfnf+MdUjvHGfxLjyS8NLsiQCI8mW6YZERuISX5IOTmXDHUGo6Ea79o6L2OSDSjtyQDiLGDuImyICUmdQ2AR4YrTfnr9QdIXjYvFeBAHYkxai9o410lrUF66dE1WhQD2rr+IxanhK9Sr7Z6DBwZwKiXMQ5hltxFkTiCskL0QeNysK13M1ivmFgEMpq4lvUxIly+BbA2cSrbADBHcMeYjgwusx2i6sqIdwuYBiG0GOCJqMoKFhXlUxF4O0NgIQSjiadSyCGWIzjlaJ2Xlyp94PXs7H2lTXkP57TFgekQaRV4jWC+hhrxgjeUFVc/3ld8IsRZ1iZoItO0eag01Mx5isJYXdfxLk8YheEv4jzruxNkIh5uIi+ej9F+L9E/xas/81LXHEuI1SkCZYdGWtRlOsz/0QeiNwuQl95sjcmIaYsx3S2SlrWzhgbS2/wCoZN3KHUSzbxAb8S5qFtxELQdnIj6jwmSXCg4SoMBXmIW3HGpzqJYguLo6NV5ag0b84z8wONHnQLKVA7/lG9IsUI/mIkMF+JxI8RdrDOIKWEFoJQ5JyoRi7zGoYIqvOKaIN4hzQDiIGERrvUbiGIPf7SyVLmEl+EgK4uPY5lG8QzRBDMACIixZEC0RkId0sHGoDwdyYBLSALcYIhMVjiO9QSpyMpYAGIa+66P4BlbfMVx7o/a/vLZ+0JkQgGC0mmYy6RnqEKyC/viM9y1PDePxEftCJiV+RCp9sx38q+XP+Jf1RQWtepzSttpgrxNNEbNsHIkdX73mQxS5NnaGhqVdAo35lBoQ9woaYojxEFgkRhOMoeNGBygwJBgksQHcw6YgCXswxxUkieh7DU/fCx+fsmCCryYCCPCC3BGvtKy4cQsZfvB6qobi33HwVDeP1EKqYQClQaXRE2sS3sEoICYZaoMrHJhAohSjUvGouMylOaljY3HBhW7uYrMAZckS2ICFYRF1B5gcCBACNVmAFQjdCDgDuxZfRfSHXzjg+0Eo36l+oDcXI209/wDmMFGJUfMDEPsioMxGrtMUPDLeYuDI9zMR8QY7gDSWCbDK3Hc1hcyEMgy+cAZQF6WYRoEkoInMLg5lLW9H+Jn/AB66VDDYIdJFTqs9HUoZyGoyKjtLAhWbgnUVMfs4i1lDYwHvDyEyDZBfcQUnFzOY3EKzTFBO5NkGiKY7kY0F+Yns7ptAYl0uCLEJgi8C1dsyVUFYElPKH3hdsWZEYN63BWlRhyRAiNlxNitzspRpmIuFkcWQg2qJ0lgllPIQptG/MICzMQoFd45gTBTD5jiK+0co3uZOJcDBJqgivEEwV1cFuUGsSmAu5YQ2zQNKo4IKYyCxp50EsVwNDHugbGc0hQRejmVRK/AgN6iiDcQkIFvEd++wZix+Ilk7zEauYGNJ7SgD2japAQcsNV3HiPM90J6QxXFfeKZWDcpkwfuzGF5jPinfKr+i/wCO/RPhfQ81DE3C/PEps4jwMKMwbHg5USNqCXnHa7os9o5gUmLBHtpEVkT7szsgpTH0ydmANwrO8o8xrFnkgaAwo4PWoaZnxHdEizyJcQARlj90W5d2lhtZlHRE15wFtiAN8wawfqVMR6LIGmpUylwCsnxKiYzmcU2ypdqjsjJDBiPTuR604nO4lLNsMSg3L3TKbSVyZY1UpXEvZDOSu7AO6BWNEomfQRUJULaLlyUO8WbVeDctEJBXP3GiORL9yVJne0PVAccRxxf+ww3YE4PBHd3bCq5kxrBCoJBe4w9x7u0dwB65Vlyw+8xXAls1KxDUExkh4mk1xUJA7Q9sEvJ6WuXtcQgjLL1iZypTQ3l9T11v5P8Agb/wD5VVhR3O0E6QGjwii0JOCVwyr2RyzZCQI7GVDrQzJoO/MQ2V00LxL+UlW7x8SlpmMGIm73IXhC4YecxVc5LgTYxTKpBVtixu+gq4RyKJj+CdiAAOdzmJA6VwRQCcyZz9RXLE4vmBuu85EZViD4yCLXcBLWZp1iUdTsiiqJipRs0xFmYL5mZWl2JoFe7KjIKgykCVARdiIsqO6jeEeGMW32hdEfO5bz4HE2VyUrDtQgCBcGxQ7xKoO5U2nXhfLAAR/PlgqnAQWWrqMV5h0IbS5SZyd+rIKFdoyiRAls7Phg+znEdSTRM5mz1KuMGnEta7tlV7I7qVe4ns0YbdBCEtyhspcHqV0r43L6X9G/8AIvrVysy7f1R8o56+0o7D1KWVzsZTYR0GkpLNwS2GZlDRkSUfR78y4bltrSTJovtKtP1EP9Rvm5bzqGkQSxCJWLDshB1BpmCTHqFWYaWC7szboxEM2E77Y7ovuYK4CublpaIXTKpGyvo/eYVz7EykLhgAQ0Fk0ziOIi0zHzC41UqGR941vqTEY0P7m6y+ZfzCJ2x2iBMvEVWxYnZ4XEnN5jVXDxO5elx+qkHwL5g0TujKyhDX3dS9UM1Md7S/6lk/WrcrPSdkx2pmZMO9x6qaIaqO9QBM2X2yrVEjzO8VokrTxKqdoz9cYSRsTSYdoKq7RWK8xpdyNRbHpGBemEppSPWDwhDiAr6D8K+jf0CV/gkE2/zZAbpTyPDGim4CzUeYeufznuFjZMbeIFc3KEkXHR0koc01ASkbgZUiaonZlZSRRhHz17uThNRduYPQFFcsbYZsmgLFXFy7lYFwqXZDlEVEY1HAtUyFhXqEMBU34uFb3JQycwwFkMKNoiirEMX07HGY/uPZPyxKegEM5vl6ue4lafnp6i1f5jtY8QeC3mD2V6isH7sBktICga5qGkNRqflZWvDuomM1dCh6jky838EIBG0EEMQW7sVXFliGeWDEqy0Fy+V2B6IhSVDZURpbTtFb8QDH2jqXSZmCaid0cB3gCvaNUwLM9Kjg9EWkY2eBl2aKUxD/AAF6n07+L9S4hpSV5ZjIKL3LddASCPMVmniDvxM7NwOGEMTug1IjXBuK7IMO2PI7lSozAaSNSi46bGFwiEFIMhAjS/mBbg94DvDUi2y/MylXAzLCMsC85l7QEMazEho+8CBiHDhhBUokTzcocK+Mz8UBf6lShHvqGlR7tjZeJMEp4D7wTIhTVYWlSLFX2zfcExqPlitSoeIk52yviLusQyjA/K3sS6MUg3n8EWj+TKSCtqoI+rGKH7o8XXNGhFFPFwxLF1dww2MEFQE8ScSm+Zm7srqWsEFpP2MO/wA5fbBQOItFwJgpZbIrulx8Er3iKNsI3xcNFiKDrzQkDCEfNshOZrO0XA8xMEoAaYH0H6DD63M4+u6hLsv2ZcAwbz5IQsZdsi1iGI5ne/tACCMTtN0uBWbIaAb8R4JmXM4aEJKpw194Fw9wAtWMvMAxhqxBbrEyCKOSPtH0I1Wn5gW4t9ED/wBECuvyRP8AvSntfdFZPxT/AK5CrH5kewPvES6nuOacNNP3/wCzs/7/APYn9cQq/WH+oLP3kP6nhLuTDFrxcwwNdgmCG2VMVUe3eIcnvCc6uDUkuc8QpZKlfNMa4NHqNkzBRcCCWJhsUEsEHlKi0+UHwKd9EeO0GYPbACjrCfdl7QjQRymB+57jglWVhqGDVJKahszZbFZUuQkrCHNxL7Jegf8Ak9KzBjHOIqJRDvLK92qCvSaogCKzbMaATVRn3ZVUcDhlK4gcQUhnDHR4fm9Wc/4GPrHX7fDBl0ZfUQxIfsEVaw1XvOGWZ7JeCYZQsOskZ7HiY66ezBGG4jVYpFYxssMl8Rt2A4YfX+pgmxTyOIyuG/MdBRJSiGNMt/vpTXd5SuPvSaFx3fwId5vRFa/DAsHXaCe0CYYddIcQlLB2EKlAkJNISE0XNJY9zwztBLVeWNdpH3MJdsTh4jwpN+YYWFm8AiVpMxpZxNW74nIs9pUNCFtC+7FSNjJOeCNqkeZds07xR8Kl/mZSn3fdh6gcvLMTMwRTDRFy5YLkEAFJjJQJRgiHNwWiFxXMtgmFRjGxn3lQa8Q4xxHYxICO3jsPEqCcwUESvDGaqS7KOjxMw7pKqgbHt0D+Toqr95jCsH/Hro9cfXv4UDi32M9qwRdzOAhiUldBQacPJANkt2QLFRx5n/2HArL1z0BLlJDV5mKpNYEYP+GKFC0MpM2Jq0xFmi4ijXuZ5CRw2B6hyQD6S/ccVKYJXJ7iNipUKwF+8a9oxtu1QRQs80G4XMdCkWOEINlYuQaIUl2R4YMZcocpfVmZmghjigTJwO1KgPKWw31DJaCMCwRbMTaxwZGCgHzyoDuzTMmCNuhuVV09z7iBFB28wUpKYBLPi4J2TxLBFvErrG48Bwx5e0V5ggLw4hjETKegstbNuvRAoHOYsZozJRV3KjpUdv4QBRWpxl4KFMxnEsRLJeY8jtComuZgBsjuOD26Lv0dePk/5b8D5Nzvl/qn3sNF6yio92ZsQcxhssY5pgTiJzZEGZjxFzA+JhKH9x6lV5hpaGLvBfaKOLIgYplO4mphkNBmDcAT1MLFpGaWLsBxO4YODdwUoqFpikhjzc1g/iPOfqOVJ0FqHev7Rrq2KQKMsxtYqEiv6glglsA/E4GIy/o8bIcxGk9E26naIKOYjtg45+IoK/8AdmDB58Wx2m0h6JHjZHmxfykFsdltwStkOqiVLlxEry8Q8mI1ndznG4QlEwE5ZVBjaZ0ZljCQBB2VIg9sK/tzOfggxZrNGKoLaUGeZFCtS2I5Io8xhnvMX3Dg9mJxdpb2TSJaJjHSQ5P/AMmHyCEjymOpCODyEZujtm5LEy2xjez/AAgO7IK1uJSlMyolw+0r4jWUhDAZjGyDaQExUAdkU1iDctRDIJORcc8ytThNVjFIk4pftLZtFm4zly7jtApaP3gqd0UMiANI59GB0WU5PxSjR/EBMEVaqAeJyUApdBDN2sFsghVl7wEbW5S615i2O5a0PxDYoP8A6YbEDgl8IJYOuHF542lM1XLMeyYEBUPGII1kwG+eGW54mMcrKRYYFQuSYI0XL7MU9pVcl2XIwwQUIgDQT7XDa5ZUDmBAixHamAisYcD3cKXRcTG8K6Gu7ErFQ2ogXKxgeIoNw2zc4eH5p+N/Cv8AGr6JHqaVfqBQRtQGJkfPQq0lFzNdStDjntCcOHz0m3UILSGMQmiVsIMq0zLED5GcgIjRJay4iYXowbkZk3X3ne/MXmIfcyaYvlIcE2eYIVcJLxfctZ/aBW32i2ipwjRhuDdXLmMku3j3Kn9ERvpH2T5hbOCMrIg+ARuFLwErxveEVBQqoN35YmwjpbvfiXM7zYj9ijsSpv8ASAFR2O5hCVgQDcKnmWqNrcy15Zfs1KEojgYh0T3LELHRCYFwHkmJDQEB1Z98YABW4AAdGkeUe7lBQ0py/wCYr9EWG1U03uWM+0snSMF2jqptmt7RIYsSsvQ3Z/8AhS/i/RUzaf8An6lEd4wq5CNXRHMqnuShRljiUmZnxLsMpzFSbSUOfzB+My5eEEajCpcssMhcw2e4UUZ4Mv3gjBOa2A6ZA8oPlAjebae1SzYM0v2RHeb6sYmFzRC4UzFTZHtIRoRJ3+8Ybgrix4IWEDA6w8qorYfY3M1fPMrViwOnHmXNUO0NhQ7sZb2hcwSx2lMYYIJjO41piPlIjmKYlRLo3H3pWAZ3bLUc2xDk3CDUqmBAzRCrLVmKHKpWLlQS6VdGZmAj9gSlgzUEb/PWKw3MMcVNI++2/uVBHcFyzh7yruj8lFYjqjzL5JHw6DbCP3w0PoP0H6x8T6NdaUbK/Esdu2FXwx2jjklweMQ0WCwqbUruyW3Hkg9NXFu3UrjYj0URhO8xbIEPitqC0VuWDV9iVQYcFkZ0kXtLcj+OmsC9GEfOBj1/mKsKC1b7M76/dBtiv2n77B/qH6Mf6osDfaIhV13BCxJPAf7gVVyH+6g495LDgNXgwWvTgQpsfmOy08z+2kKwkcLPaWNFS1B51iO+fzKSqQwqgrmOqGmBXpEFNsENQ6jcQbCzmGFFojeUoWvUOqKZUEw3BDvBUkaxzcIW6Zk8QVLlhPLAgVqZ6pSoKl2j+WAJy1Cy/M0iw3C2gsEq3YQYRUnmfqR/tGWE8JtIiN3slTJDQwNTZOYMjFde3/5d/Bjqd7Y0NVVMEt7w2G2CDySV2jnEDQdkoTIxM5biJwx5RsyyhyxNVCzKi82MdFVIXqwPcVnRi8iwWrhjaAXl1L58blBbE/EXpPsh/Kw/3EqG/MrrpzWLgj6E/cKf7i+//wAuZp/vK/3HxP8AlNCX2/6i5n8GLcfhz9YEuEPQP6leifeK/wC4pzLtMs1cR3EjULdiVIqWYMOW3cbpYeYq2yCrC4TZYRLZl2ZxMg3R5gAuZeuoJoq4v+4zKOYrKrCTl4j0U+0IwxOJrmVSl9wEDuEOgjNMhLZUigjszO9kfiWY8EqQa10hRN4y0Q5Mzqd4e5ofxNB0BzvtKp5hJemoGwmiBTBHhBuOptEnaisTrXxfovwz9KvpV8SKmvGeXmXV2P6m4JXoxWLURalAMptA3NQ9CPnEZcShpIkFPU2sgjPTKNwTpZq0QLTmzX8wWhfuckfmAe55i2quCRSyaRK8RNiBCgr3KQuHuBXP7gJeyD02lkRhGRRlIIm+LgC7ahbGfNyldoCYoFfUZQbJzLC7oqWJ/OLLWWYmA5IMYECutzA3bLgWO+8FduZzNSkAGlkDE3M9NcsxnMOuRf1H73mYoYhWIwWw1KCZ/Edx89oZbqO9xg1FVuYRg1SETWfslzuEEJZ7JpFVTcy6DQ9IaM4Ca5kKiyIAHuxVbbgFDHguVLsxVeGCrQ10UmkwH0eevH0n6Z0r6Y29Je1jMWVtzO3jGE1EdDWgeBiEISLrGScpkgwvMdQIi5JkdoaajF2Sq3HkXEGoGIMKZJxgkBmJX/rixtgjSxHYTWqpilhhlBxFcNQrClZcRXFsGFK/MJm1bAxWjo5RnDvB7rM4WpSzB2HHiNWW8EeCkTGIgwUDHqMT2tStvKC+VhzMwLTdJBpDJZtJvVmuWXZc8HeOpZiuS3KaxCPAmSj7yrTMBNlSogOFJxGobWCwKvtDJbZUEvDFFjp5ty+xBaV2hcQYuO4qhbAjJZbceJHSZKMoxFC2hOdx0WZXELZ2iGBhuO+hxA2Hv1r4P0DpXWpx8OPg/WOlKjRKr8hGhEEAqGbIM29yCYiUmNwMozKCwiNg6U2MZxWJk1MLRGbqK5lVvmIkHdLgYhZB/KEDFBhhUegiPAxHDM0gUXMHwYmtUckpgUxAK2wppKlgl1MA4HNxTXQxcyhblUjMMWZivIVPHkFl5WchAycy1oGY4W7lE8wQR3WkGAz3jZp6meNeJWDO5XlLYNeCIMES+4MEiozHneIGcwXKpdWybxKStwaQUS5FIoi2q7iPksoBDgilWBYjlRIg9yaugWqlvDK1eVGNhBrDbI5V1EUJBzU26tTHZ8fO/qYmP8gLQ8y3KsrKpABWic9pghm/ME3SwGtw5lSGhpHiIxt8SgU4gbdpVYlWUkMajcEvsSVtR3SROZrKQiZcsmO8KTDDBBSWy0b3E6hdx5UajgxuG4hhou4NLC2bgWcxCFRi1Kl4MoGVt+YRSioVogKsKjYVqIKUUxglmOWJODEwC23DvTccFSyvMtaICA5jCpL4+pE3Y/qIS8vMIHeGstRVfEawxUAEa81UIxeZdlBTauJaofcxNglCLqaxVFbuVb1ND5mIFqMGNCqhqVMXgmTFUHi4EEPBDccsD7lWHMaqBCCMu+LHMUG4zKC3FaPm/wCFX1uPiY/D/ELlLx3iYhFUIDgFS0ZUUI8MG/Mr4BjAeHJuKUs7MJKDCxioCt5gpLhSZ1jNmE0frB8TaDF8Gpk0z0Y3OoLcuwlAuX34hoEBWEW5i4YZziFbhFKIrs1LJVR5BmjdnuPM1NkI8saiCwgVq8wfVjaRcIyBTcHgyyrBbgvNFhcIZRL2aqLDWZYRTyjqkSZEQ6IylRFttmIOu8Mq/Ez7XaBaNd4QiYJjuWGQzK7CxlVlzLsqCFyyhgoqIftHrPAhugi1rGJUAk8YYlDFR4ltsRa0XENmGKhXQ4BlLqgsK5g0Lmb4m04gKVDcyZcYckqS5/w3px/jnPp/iJQxlLLPEsFZmMatwXiLoAQcjdcxBc3Gik4sT6HNQxrXMXFU7LAI5UgLfPTDQCKaonAxr1EVs/UfkQl20oecQhpBoHNDCaSMt0OY+UqURWyE0mCpxhgWBBVNErQVCiNPmXP4RqLQhdj2oDQlQGsPUVzm8wvyUZC8wGhN0oWKkMjUSBCjcdWGKwipiX6XLGVpL2uO0zyrv9TdcwySHcqYlPbNRYuo5G/7gCShqIwIhEyQ3LFa9TL8RALKlWegqYsi74jMV5mtIQCtxYi4mTEXIhNRZhwQiL3FghgehyTVfeZCClTBHiGG8RzeY5ccdA0vn/Av4fn/ACNHuVIxV/4hgR2Yiasop3jkmh+4QWfmb2eYIq41C33JmwWEqd54YCi3si42HuWoOB6RRm7hYlYeZduI9pFKoqJ5xFV0x4l/CcMPxDhA+0q4uA7ILQGfEA6JQ7TivoBA0GL6/mZViMKI4e4kic+ZcsPzOXE2FWb2Yq1CM1EoinxDcsOXfMExVx6HMYUjTskcMQstsSsQig6leM+ENgY61w2ylphmBe2LUssq9TkdsNRkRZJS9YjyziPVHETkWRrzK6CCiVRK1Kf0SisFkTtg5mI8wURYrpVqOrjF/EINnEyCFVMVfTsF+YjA8MSm8kzWNUtJcFCpfMFhBjuaorD4+qdLl9a68f4vJ7IKTm0GplM7xVftDGxuMZN8kZqlDbnLLjM4GKGL8S/Nktxz8R8GzuS+n7LFKsjHwDMVgX7lFxGKBuottj3LDZDQJCNyhq8zN5TemZik3VfvMyJqK5HuEYH3S7VvqcovuC5Uze8uscLqPYE4uJhtEuxTCoWYBTSPQJATUoMeMavFQQy7mDmkZos3aXMPeCWNvlmLOCIECmJY0QDtUu7BCzXFsbUhELj2QyLonhUdcKlI24iFBu5RtRgFlBIUy6xExwc+5jeZP2QY+0qx3F4gZvUZGgmFrAKHcmVHMvpG1mOFZcX8wgNkuj3Ku4TJN3bMB0HGIYnM7TAx4ePjx1fjf1K+jX0RmYYwlYGVtg5e1ykuHfqyDJ6iApww3jGIS3MgorxaYDCPi055iH3JH4YOBqKUL1AQW3lShG4+YQwEhgc+5fv8ot5XEORMuyMDkbYBQI26xnn7x4FRfbL2Wph7y9Qt3KVBzL6xFqiI4kKKwMxKCoNCswOEzKAQjUriBomIjOEy1mkpFRlkMoftHbVR3kSxaSnLEqbckoGIAZn1QbiXQXKsVQDiChqLZHnmCurYnA4iDlMcQrVm5UO0GMN73AjuwC4zjtVKACO4HHxM28THpwGYOJumzgbEZgTMmsObHlgJTuIJ2lLQ3NCe47AhY1HD7nE3GLI+LH6/H1q+gNJPUwRjlL6Zz4llDVs4Y7E04e060y/ZsGcQppq4m0m42UVGsqualLtviktgJPjBnMfRU7k2idhQzvDuI9xFeUDYrC+JgmDmIbiOEvoScBhaS8jBIQl4CQ+NzZpxMQWROV0wx3UYta+8tdT2mYH8wVixN9hRqEutzADiN0XbvEQu2AZqiFxGWLdamlizLFjYQyO99yqEaZXAmMM3BZjEsKeI6YhZOYKwwUsynMFAJrU/iYC0wt1yxlP2QYrBWphZmtkoTLHWmYXDdUGq8w2R0O4yoQ7itp3gGkwJkopRdtTAiKhBcLrDZBiDBdShDz9KutfQPrH0DKeyO44o/UrLniUxTGoS45hC+ZkAxMhjKnUYGw6YQ3sjTFkHFmWlYZxIbzWldRe4Tmx5mRY8RKpEubLiSUrEoEC2ZgIhYMxYuU0Ny4zhjuJRTUrCiLqmYwNsKK5hF8QGcXGlAksggkCyWjt0fcctT94PgQ4TUJmUZK2aExily4AqUmoJpGq3UQaQjEoqcQcz+4CKQSas0sNUZh87gdoIIqMRWpH5EKnjtAju3DB2letQJkxuqxHUCh2xL1Mw7sAVLMENATPHbosUzIrVbmbbMaGZvYGxm2J2RVcY5SoeJgBkY6GF3RhsXx05DcHWEuXTU0l0PfM2fQr/ACSX8K+GkJfu4m5QVHOYurhrRcak2R+5gB4jLWoIiBcQVyhAQsnmChn9xyAIGSCWjEcAXtmWFNJtSjFXJXmLMFwLaMC4CClgaplLUdtozSCEGhjrg1DGgCatJUFVChRVKC4XDQ0ajso2iAuicUlSxuJXaWi7O1zK1fuZ1G5xkHq2KKhBg1HhhmuyDw1ABklLNGagBtgC1cFSckWh0RLFlzLi3mM0hgjqFrMq9S9xGzNBBLTRqNncKUUEpwGJkFQ1XMDeW4KnBDF7TLBoolT7SskYcHtGsDUVkxtFUDSxjvJRJpPKBE5luYsytriFVsmQd52XoAQXZCVXddCxL8IOemxMFHhR2PH1b/zdm7duFClyoUKFChQqUKlSpVqUqVCIChMfpwiUVWf9kA3+p/ubWeoE9jE1BHgP9zRN8h/uEhiHAf7g+bv/ABzGsL2H+4/8Y/3Gs/ZD/cpR/n/YgpnHaIO28dKHdRG3iOU5PzxUOJ4i1XR0RejLJbLJFW22QtzGMXCHJPV6msEvMFw/cytHJy0veR3L5A6YjtQC9SDdeaB62YBEPBMNP/s/MOX/ANnmY4AKACAmAhdfEwdyRRV6jMro1NrMRrfiRwTrmINiDoSPmJ5RmvkpfVe+JRuD2jrkaBGhxCpwjUQJ1SKNHPMVjbDC53ro+6fpWaKcZFLyCVTkXkP9z/4r/cvrniAuanaMlXO7zySgnSMTlnWvvCnRD3k/ljAOvN3EIi67SqZnAGQeJG0NDxZv6qCvIfNlZyZU4k+2TGZ4lM8yMkC2tMufpmgklE0kCuXJmCHb6wlSpUqVClSpWoUKXM2Hw2ChQr//2Q==" alt="A,S logo"></div>
      <div>
        <div class="ttl"><span data-i="appTitle">A,S Tunnel Master</span><span class="badge" data-i="masterBadge">MASTER</span></div>
        <div class="sub"><span data-i="network">Network</span>: <b class="mono acc" id="hNet">—</b> | <span class="mono" id="hVer">v—</span></div>
      </div>
    </div>
    <div class="hdr-r">
      <span class="pill live"><i class="dot on"></i><span class="mono" data-i="masterActive">Master Active</span></span>
      <div class="seg"><button id="lgEn" onclick="setLang('en')">EN</button><button id="lgFa" onclick="setLang('fa')">فارسی</button></div>
      <div class="relative">
        <button class="btn ghost" onclick="togglePal(event)">🎨 <span data-i="palette">Color Palette</span></button>
        <div id="palPop" class="pop hidden"><h4 data-i="accent">Accent color</h4><div class="swatches" id="swatches"></div></div>
      </div>
      <button class="btn ghost" onclick="refreshAll(true)">⟳ <span data-i="refresh">Refresh</span></button>
      <button class="btn o-acc" onclick="logout()">⎋ <span data-i="signOut">Sign Out</span></button>
    </div>
  </header>

  <section class="stats">
    <div class="card stat">
      <div class="lbl"><span data-i="stIp">Node Public IP</span><span class="tag">IP</span></div>
      <div class="val"><span id="stIp">—</span><span class="icobtn" onclick="copyText($('stIp').textContent)" title="copy">⧉</span></div>
      <div class="note"><span data-i="hostname">Hostname</span>: <span class="mono" id="stHost">—</span></div>
      <div class="note" style="margin-top:4px"><span id="stSide"></span></div>
    </div>
    <div class="card stat">
      <div class="lbl"><span data-i="stNodes">Connected Nodes</span><span class="si">👥</span></div>
      <div class="val"><span id="stNodes">0 / 0</span></div>
      <div class="note" data-i="stNodesNote">Active nodes connected to master</div>
    </div>
    <div class="card stat">
      <div class="lbl"><span data-i="stLat">Average Latency</span><span class="si">〜</span></div>
      <div class="val acc"><span id="stLat">—</span></div>
      <div class="note" data-i="stLatNote">Node ⇄ Master, live</div>
    </div>
    <div class="card stat">
      <div class="lbl"><span data-i="stRes">Host Server Resources</span><span class="si">▣</span></div>
      <div class="bar-row"><span data-i="cpu">CPU Usage</span><b class="mono" id="cpuTxt">—</b></div>
      <div class="bar"><i id="cpuBar" style="width:0"></i></div>
      <div class="bar-row"><span data-i="ram">RAM Usage</span><b class="mono" id="ramTxt">—</b></div>
      <div class="bar blue"><i id="ramBar" style="width:0"></i></div>
      <div class="bar-foot"><span><span data-i="uptime">Uptime</span>: <span class="mono" id="upTxt">—</span></span><span><span data-i="load">Load</span>: <span class="mono" id="loadTxt">—</span></span></div>
    </div>
  </section>

  <div class="nodebar" id="nodeBar"></div>

  <nav class="tabs" id="tabs">
    <button class="tab on" data-tab="config" onclick="setTab('config')">⚙ <span data-i="tabConfig">Node & Config</span></button>
    <button class="tab" data-tab="nodes" onclick="setTab('nodes')">👥 <span data-i="tabNodes">Nodes</span></button>
    <button class="tab" data-tab="speed" onclick="setTab('speed')">⚡ <span data-i="tabSpeed">Speedtest (iperf3)</span></button>
    <button class="tab" data-tab="ping" onclick="setTab('ping')">〜 <span data-i="tabPing">Live Ping & Latency</span></button>
    <button class="tab" data-tab="tunnels" onclick="setTab('tunnels')">🔗 <span data-i="tabTunnels">Tunnels Manager</span></button>
  </nav>

  <!-- ===== CONFIG ===== -->
  <div class="pane" id="pane-config">
    <div class="card">
      <div class="card-h"><span class="ico">⚙</span><h2 data-i="cfgTitle">Node & Master Configuration</h2><span class="ok-badge" id="cfgStatus"></span></div>
      <p class="muted" data-i="cfgDesc">Manage this node's identity, tunnels, tuning and updates</p>
      <div class="btns">
        <button class="btn o-acc" onclick="openNew('link')">✨ <span data-i="wizard">Launch Setup Wizard</span></button>
        <button class="btn o-green" onclick="bulk('start')">▶ <span data-i="startAll">Start All</span></button>
        <button class="btn o-amber" onclick="bulk('restart')">⟳ <span data-i="restartAll">Restart All</span></button>
        <button class="btn o-red" onclick="bulk('stop')">■ <span data-i="stopAll">Stop All</span></button>
        <button class="btn ghost" onclick="refreshAll(true)">⟳ <span data-i="refresh">Refresh</span></button>
        <button class="btn primary" onclick="saveConfig()">💾 <span data-i="save">Save Changes</span></button>
      </div>
    </div>

    <div class="card">
      <div class="sec-t"><span class="ico">🛡</span><span data-i="identity">Node Identity</span></div>
      <div class="grid3">
        <div><label class="f"><span data-i="nodeName">Node Name</span> <span class="muted">*</span></label><input id="cfgName" class="mono" maxlength="40"></div>
        <div><label class="f" data-i="netName">Network Name</label><input id="cfgNet" class="mono" maxlength="40"></div>
        <div><label class="f" data-i="side">Side</label><select id="cfgSide"><option value="eu">🌍 Server (Abroad / Kharej)</option><option value="iran">🇮🇷 Client (Iran)</option></select></div>
        <div><label class="f" data-i="hostname">Hostname</label><input id="cfgHost" class="mono" readonly></div>
        <div><label class="f" data-i="publicIp">Public IP</label><div class="row"><input id="cfgIp" class="mono" readonly><span class="icobtn" onclick="copyText($('cfgIp').value)">⧉</span></div></div>
        <div><label class="f" data-i="nodeId">Node ID</label><input id="cfgId" class="mono" readonly></div>
      </div>
    </div>

    <div class="card">
      <div class="sec-t"><span class="ico">🚀</span><span data-i="tuning">Server Tuning & Updates</span></div>
      <div class="grid3">
        <div>
          <label class="f" data-i="optimize">Optimize server</label>
          <p class="muted" style="margin:0 0 10px;font-size:13px" data-i="optimizeDesc">BBR + sysctl hardening for every tunnel</p>
          <button class="btn o-acc" onclick="optimizeNode()">⚡ <span data-i="optimizeBtn">Run optimization</span></button>
        </div>
        <div>
          <label class="f" data-i="health">Health-check cron</label>
          <p class="muted" style="margin:0 0 10px;font-size:13px" data-i="healthDesc">Restart any stopped tunnel automatically</p>
          <div class="row"><label class="switch"><input type="checkbox" id="hcToggle"><span class="slider"></span></label>
            <input id="hcMin" class="mono" style="max-width:100px" type="number" min="1" max="1440" value="1"><span class="muted" data-i="minutes">min</span></div>
        </div>
        <div>
          <label class="f" data-i="scriptUpd">Script version</label>
          <p class="muted" style="margin:0 0 10px;font-size:13px"><span class="mono" id="cfgVer">—</span> <span class="ok-badge hidden" id="cfgVerBadge"></span></p>
          <button class="btn o-acc" onclick="updateNode(S.sel)">⬆ <span data-i="updateBtn">Update script</span></button>
        </div>
      </div>
    </div>
  </div>

  <!-- ===== NODES ===== -->
  <div class="pane hidden" id="pane-nodes">
    <div class="card">
      <div class="card-h"><span class="ico">👥</span><h2 data-i="nodesTitle">Peers & Nodes</h2>
        <button class="btn sm o-acc" style="margin-inline-start:auto" onclick="updateAll()">⬆ <span data-i="updateAll">Update all nodes</span></button></div>
      <p class="muted" data-i="nodesDesc">Every Iran and abroad server connected to this master</p>
      <div class="tblw"><table><thead><tr>
        <th data-i="thNode">Node</th><th data-i="thSide">Side</th><th data-i="thStatus">Status</th><th>IP</th><th>CPU</th><th>RAM</th>
        <th data-i="thTunnels">Tunnels</th><th data-i="thLat">Latency</th><th data-i="thVer">Version</th><th></th></tr></thead>
        <tbody id="nodesBody"></tbody></table></div>
    </div>
    <div class="card">
      <div class="sec-t"><span class="ico">➕</span><span data-i="joinTitle">Connect a new node</span></div>
      <p class="muted" style="margin-top:0" data-i="joinDesc">Run this on the Iran or abroad server (script installed), or use the menu: Master panel & nodes → Connect to a master.</p>
      <div class="grid2">
        <div><label class="f" data-i="masterUrl">Master URL</label><div class="row"><input id="jUrl" class="mono" readonly><span class="icobtn" onclick="copyText($('jUrl').value)">⧉</span></div></div>
        <div><label class="f" data-i="joinKey">Join key</label><div class="row"><input id="jKey" class="mono" type="password" readonly>
          <span class="icobtn" onclick="toggleKey()">👁</span><span class="icobtn" onclick="copyText($('jKey').value)">⧉</span><span class="icobtn" onclick="regenKey()" title="new key">↻</span></div></div>
      </div>
      <div style="margin-top:14px"><label class="f" data-i="fingerprint">TLS fingerprint (SHA-256)</label><div class="row"><input id="jFp" class="mono" readonly><span class="icobtn" onclick="copyText($('jFp').value)">⧉</span></div></div>
      <div style="margin-top:14px"><label class="f" data-i="joinCmd">Join command</label>
        <div class="cmd" id="jCmd"></div>
        <div class="btns" style="margin-top:10px"><button class="btn sm ghost" onclick="copyText($('jCmd').textContent)">⧉ <span data-i="copy">Copy</span></button></div></div>
      <div class="note-box hidden" id="jHttpWarn" data-i="httpWarn">The panel runs over plain HTTP — the join key travels unencrypted. Enable HTTPS in the panel setup.</div>
    </div>
  </div>

  <!-- ===== SPEEDTEST ===== -->
  <div class="pane hidden" id="pane-speed">
    <div class="card">
      <div class="card-h"><span class="ico">⚡</span><h2 data-i="speedTitle">In-Mesh Speedtest (iperf3)</h2></div>
      <p class="muted" data-i="speedDesc">Measures real throughput between two of your servers. iperf3 is installed automatically.</p>
      <div class="grid3">
        <div><label class="f" data-i="spServer">Server node (receives)</label><select id="spServer"></select></div>
        <div><label class="f" data-i="spClient">Client node (sends)</label><select id="spClient"></select></div>
        <div><label class="f" data-i="spPort">iperf3 port</label><input id="spPort" class="mono" type="number" value="5201" min="1024" max="65535"></div>
        <div><label class="f" data-i="spDur">Duration (seconds)</label><input id="spDur" class="mono" type="number" value="8" min="3" max="30"></div>
        <div><label class="f" data-i="spPar">Parallel streams</label><input id="spPar" class="mono" type="number" value="4" min="1" max="16"></div>
        <div style="display:flex;align-items:flex-end"><button class="btn primary" id="spBtn" style="width:100%;justify-content:center" onclick="runSpeed()">▶ <span data-i="spRun">Run speedtest</span></button></div>
      </div>
      <div class="note-box" data-i="spNote">The server node must allow the iperf3 TCP port in its firewall.</div>
      <div id="spOut" class="hidden" style="margin-top:18px">
        <div class="tiles">
          <div class="tile"><div class="k" data-i="upload">Upload</div><div class="v"><span id="spUp">—</span> <small>Mbps</small></div></div>
          <div class="tile"><div class="k" data-i="download">Download</div><div class="v"><span id="spDown">—</span> <small>Mbps</small></div></div>
          <div class="tile"><div class="k" data-i="retrans">Retransmits</div><div class="v" id="spRe">—</div></div>
        </div>
        <ul class="steps" id="spSteps"></ul>
      </div>
    </div>
    <div class="card">
      <div class="sec-t"><span class="ico">🕒</span><span data-i="history">History</span></div>
      <div class="tblw"><table><thead><tr><th data-i="when">When</th><th data-i="spServer">Server</th><th data-i="spClient">Client</th><th data-i="upload">Upload</th><th data-i="download">Download</th></tr></thead><tbody id="spHist"></tbody></table></div>
    </div>
  </div>

  <!-- ===== PING ===== -->
  <div class="pane hidden" id="pane-ping">
    <div class="card">
      <div class="card-h"><span class="ico">〜</span><h2 data-i="pingTitle">Latency to Master</h2></div>
      <p class="muted" data-i="pingDesc">Live round-trip time between each node and this master (updates every few seconds)</p>
      <div class="tblw"><table><thead><tr><th data-i="thNode">Node</th><th data-i="thStatus">Status</th><th data-i="cur">Now</th><th data-i="avg">Avg</th><th data-i="min">Min</th><th data-i="max">Max</th><th data-i="trend">Trend</th></tr></thead><tbody id="latBody"></tbody></table></div>
    </div>
    <div class="card">
      <div class="card-h"><span class="ico">🎯</span><h2 data-i="livePing">Live Ping</h2></div>
      <div class="grid3" style="margin-top:10px">
        <div><label class="f" data-i="pgFrom">From node</label><select id="pgSource"></select></div>
        <div><label class="f" data-i="pgTo">Target</label><select id="pgTarget" onchange="pgTargetChanged()"></select></div>
        <div><label class="f" data-i="pgCustom">Custom host / IP</label><input id="pgCustom" class="mono" placeholder="example.com" disabled></div>
      </div>
      <div class="btns" style="margin:16px 0"><button class="btn primary" id="pgBtn" onclick="togglePing()">▶ <span data-i="pgStart">Start live ping</span></button>
        <button class="btn ghost" onclick="clearPing()">✕ <span data-i="clear">Clear</span></button></div>
      <canvas id="pgCanvas"></canvas>
      <div class="tiles">
        <div class="tile"><div class="k" data-i="cur">Now</div><div class="v"><span id="pgNow">—</span> <small>ms</small></div></div>
        <div class="tile"><div class="k" data-i="avg">Avg</div><div class="v"><span id="pgAvg">—</span> <small>ms</small></div></div>
        <div class="tile"><div class="k" data-i="min">Min</div><div class="v"><span id="pgMin">—</span> <small>ms</small></div></div>
        <div class="tile"><div class="k" data-i="max">Max</div><div class="v"><span id="pgMax">—</span> <small>ms</small></div></div>
        <div class="tile"><div class="k" data-i="loss">Loss</div><div class="v"><span id="pgLoss">—</span> <small>%</small></div></div>
      </div>
    </div>
  </div>

  <!-- ===== TUNNELS ===== -->
  <div class="pane hidden" id="pane-tunnels">
    <div class="card">
      <div class="card-h"><span class="ico">🔗</span><h2 data-i="tunTitle">Tunnels Manager</h2><span class="rb" id="tunNode"></span>
        <span style="margin-inline-start:auto" class="btns"><button class="btn o-acc" onclick="openNew('link')">🔗 <span data-i="addLink">Link panel nodes</span></button><button class="btn primary" onclick="openNew('manual')">✋ <span data-i="addManual">Manual tunnel</span></button></span></div>
      <p class="muted" data-i="tunDesc">Tunnels running on the selected node. Click one to configure, view live logs or schedule restarts.</p>
      <div class="tgrid" id="tunGrid"></div>
    </div>
  </div>

  <div class="foot">
    <a href="https://t.me/Asnejad" target="_blank" rel="noopener">✈ <span data-i="crafted">Crafted by</span> A,S · @Asnejad</a>
    <span data-i="keepPrivate">Keep this URL and your password private</span>
  </div>
</div>
</div>

<!-- tunnel modal -->
<div id="slotModal" class="modal-bg hidden">
  <div class="card modal">
    <span class="x" onclick="closeModal()">✕</span>
    <h3 id="mTitle">Tunnel</h3>
    <div class="muted" id="mSub" style="font-size:13px"></div>
    <div class="mtabs">
      <button class="mtab on" data-mt="config" onclick="mTab('config')">⚙ <span data-i="mCfg">Config</span></button>
      <button class="mtab" data-mt="log" onclick="mTab('log')">📜 <span data-i="mLog">Live log</span></button>
    </div>
    <div id="mConfig">
      <div class="seg hidden" id="modeSeg" style="margin-bottom:16px">
        <button id="mdManual" onclick="setMode('manual')">✋ <span data-i="modeManual">Manual</span></button>
        <button id="mdLink" onclick="setMode('link')">🔗 <span data-i="modeLink">From panel nodes</span></button>
      </div>
      <div class="fgrid">
        <div><label class="f" data-i="tName">Tunnel name</label><input id="nameInput" class="mono" maxlength="32" placeholder="server1"></div>
        <div><label class="f" data-i="protocol">Protocol</label><select id="methodSelect" onchange="onMethodChange()">
          <option value="asnative">A,S Native</option><option value="backhaul">Backhaul</option><option value="rathole">Rathole</option>
          <option value="gre">GRE</option><option value="frp">FRP</option><option value="gost">Gost</option><option value="paqet">Paqet</option></select></div>
      </div>

      <div id="manualBox">
        <div class="sidebar" id="sideBar"><span class="muted" data-i="side">Side</span><b id="sideTxt"></b><span class="muted" id="sideNode"></span></div>
        <input type="hidden" id="roleSelect" value="eu">
        <div id="fieldsBox" style="margin-top:14px"></div>
        <div class="btns" style="margin-top:20px">
          <button class="btn primary" id="saveBtn" onclick="saveSlot()">💾 <span data-i="saveStart">Save & Start</span></button>
          <button class="btn o-green" id="startBtn" onclick="doAction('start')">▶ <span data-i="start">Start</span></button>
          <button class="btn o-red" id="stopBtn" onclick="doAction('stop')">■ <span data-i="stop">Stop</span></button>
          <button class="btn o-amber" id="restartBtn" onclick="doAction('restart')">⟳ <span data-i="restart">Restart</span></button>
          <button class="btn o-red" onclick="deleteSlot()" style="margin-inline-start:auto">🗑 <span data-i="delete">Delete</span></button>
        </div>
      <div style="margin-top:20px;padding-top:16px;border-top:1px solid rgba(255,255,255,.07)">
        <label class="f">⏱ <span data-i="sched">Scheduled restart</span> <small data-i="schedNote">(regardless of status)</small></label>
        <div class="row"><label class="switch"><input type="checkbox" id="rcToggle"><span class="slider"></span></label>
          <input id="rcHours" class="mono" style="max-width:120px" type="number" min="1" placeholder="6"><span class="muted" data-i="hours">hours</span>
          <button class="btn sm ghost" onclick="saveRestartCron()">💾 <span data-i="save2">Save</span></button></div>
      </div>
      </div>
      <div id="linkBox" class="hidden">
        <div class="fgrid" style="margin-top:14px">
          <div><label class="f">🌍 <span data-i="lkServer">Server node (Abroad)</span></label><select id="lkServer" onchange="lkNodeChanged()"></select></div>
          <div><label class="f">🇮🇷 <span data-i="lkClient">Client node (Iran)</span></label><select id="lkClient" onchange="lkNodeChanged()"></select></div>
          <div><label class="f" data-i="lkSIp">Server address</label><input id="lkSIp" class="mono"></div>
          <div><label class="f" data-i="lkCIp">Client address</label><input id="lkCIp" class="mono"></div>
        </div>
        <div id="lkParams" style="margin-top:14px"></div>
        <div class="note-box" id="lkNote" data-i="lkNote" style="border-color:color-mix(in srgb,var(--accent) 45%,transparent);color:var(--accent2)">Keys and ports are generated and shared with both nodes automatically; addresses come from the nodes.</div>
        <div class="btns" style="margin-top:18px"><button class="btn primary" id="lkBtn" onclick="createLink()">🔗 <span data-i="lkCreate">Create on both nodes</span></button></div>
        <ul class="steps" id="lkSteps"></ul>
      </div>
      <div id="mMsg" class="msg"></div>
    </div>
    <div id="mLog" class="hidden">
      <div class="row" style="margin-bottom:12px;flex-wrap:wrap">
        <label class="switch"><input type="checkbox" id="liveToggle" checked onchange="startLive()"><span class="slider"></span></label><span data-i="live">Live</span>
        <select id="logLines" class="mono" style="max-width:130px" onchange="refreshLog(true)"><option>100</option><option selected>300</option><option>1000</option></select>
        <button class="btn sm ghost" onclick="refreshLog(true)">⟳</button><span class="muted mono" id="logStamp" style="font-size:12px"></span>
      </div>
      <pre class="logbox" id="logsBox"></pre>
    </div>
  </div>
</div>

<div id="toast" class="toast"></div>

<script>
/* ============================ i18n ============================ */
const I18N = {
en:{
 appTitle:'A,S Tunnel Master', masterBadge:'MASTER', network:'Network', masterActive:'Master Active', palette:'Color Palette', accent:'Accent color',
 refresh:'Refresh', signOut:'Sign Out', signInSub:'Sign in to manage your nodes and tunnels', username:'Username', password:'Password', signIn:'Sign in',
 badLogin:'Wrong username or password.', tooMany:'Too many attempts — wait a few minutes.', sessionEnd:'Session expired — sign in again.',
 stIp:'Node Public IP', hostname:'Hostname', stNodes:'Connected Nodes', stNodesNote:'Active nodes connected to master', stLat:'Average Latency', stLatNote:'Node ⇄ Master, live',
 stRes:'Host Server Resources', cpu:'CPU Usage', ram:'RAM Usage', uptime:'Uptime', load:'Load',
 tabConfig:'Node & Config', tabNodes:'Nodes', tabSpeed:'Speedtest (iperf3)', tabPing:'Live Ping & Latency', tabTunnels:'Tunnels Manager',
 cfgTitle:'Node & Master Configuration', cfgDesc:"Manage this node's identity, tunnels, tuning and updates", wizard:'Launch Setup Wizard',
 startAll:'Start All', restartAll:'Restart All', stopAll:'Stop All', save:'Save Changes', identity:'Node Identity', nodeName:'Node Name', netName:'Network Name',
 side:'Side', publicIp:'Public IP', nodeId:'Node ID', tuning:'Server Tuning & Updates', optimize:'Optimize server', optimizeDesc:'BBR + sysctl hardening for every tunnel',
 optimizeBtn:'Run optimization', health:'Health-check cron', healthDesc:'Restart any stopped tunnel automatically', minutes:'min', scriptUpd:'Script version', updateBtn:'Update script',
 nodeOnline:'Node Online', nodeOffline:'Node Offline', upToDate:'Up to date', updateAvail:'Update available',
 nodesTitle:'Peers & Nodes', nodesDesc:'Every Iran and abroad server connected to this master', updateAll:'Update all nodes',
 thNode:'Node', thSide:'Side', thStatus:'Status', thTunnels:'Tunnels', thLat:'Latency', thVer:'Version', online:'Online', offline:'Offline', master:'master', manage:'Manage', remove:'Remove', update:'Update',
 joinTitle:'Connect a new node', joinDesc:'Run this on the Iran or abroad server (script installed), or use the menu: Master panel & nodes → Connect to a master.',
 masterUrl:'Master URL', joinKey:'Join key', fingerprint:'TLS fingerprint (SHA-256)', joinCmd:'Join command', copy:'Copy', copied:'Copied ✔',
 httpWarn:'The panel runs over plain HTTP — the join key travels unencrypted. Enable HTTPS in the panel setup.',
 speedTitle:'In-Mesh Speedtest (iperf3)', speedDesc:'Measures real throughput between two of your servers. iperf3 is installed automatically.',
 spServer:'Server node (receives)', spClient:'Client node (sends)', spPort:'iperf3 port', spDur:'Duration (seconds)', spPar:'Parallel streams', spRun:'Run speedtest', spRunning:'Testing…',
 spNote:'The server node must allow the iperf3 TCP port in its firewall.', upload:'Upload', download:'Download', retrans:'Retransmits', history:'History', when:'When',
 pickDiff:'Pick two different nodes.', pickOnline:'Both nodes must be online.',
 stepserver_start:'Start iperf3 server', stepupload:'Upload test', stepdownload:'Download test',
 pingTitle:'Latency to Master', pingDesc:'Live round-trip time between each node and this master (updates every few seconds)',
 cur:'Now', avg:'Avg', min:'Min', max:'Max', trend:'Trend', livePing:'Live Ping', pgFrom:'From node', pgTo:'Target', pgCustom:'Custom host / IP',
 pgStart:'Start live ping', pgStop:'Stop', clear:'Clear', loss:'Loss', custom:'Custom…',
 tunTitle:'Tunnels Manager', addTunnel:'Add tunnel', tunDesc:'Tunnels running on the selected node. Click one to configure, view live logs or schedule restarts.', noTunnels:'No tunnels yet — add one.',
 mCfg:'Config', mLog:'Live log', tName:'Tunnel name', protocol:'Protocol', saveStart:'Save & Start', start:'Start', stop:'Stop', restart:'Restart', delete:'Delete',
 sched:'Scheduled restart', schedNote:'(regardless of status)', hours:'hours', save2:'Save', live:'Live', newTunnel:'New tunnel',
 running:'running', stopped:'stopped', crafted:'Crafted by', keepPrivate:'Keep this URL and your password private',
 savedOk:'Saved ✔', failed:'Failed', nodeOfflineErr:'That node is offline.', timeoutErr:'The node did not answer in time.', removeConfirm:'Remove node "{n}" from the master?',
 deleteConfirm:'Delete "{n}"? This stops it and removes its config, log and schedule.', bulkDone:'Done: {ok} ok, {bad} failed', optimizeDone:'Optimization applied ✔',
 updated:'Updated ✔', updateNoChange:'Already up to date', keyRegen:'New join key generated ✔', regenConfirm:'Generate a new join key? Existing nodes stay connected.',
 enterName:'Enter a tunnel name (letters, digits, - or _).', overwrite:'A tunnel named "{n}" already exists. Overwrite it?',
 savedRunning:'✔ Saved and running', savedNotRunning:'✔ Config saved, but the tunnel is not running:', saveFailed:'✖ Save failed', never:'never', ago:'{s}s ago', sideEu:'🌍 Server (Abroad)', sideIran:'🇮🇷 Client (Iran)',
 modeManual:'Manual', modeLink:'From panel nodes', addLink:'Link panel nodes', addManual:'Manual tunnel',
 lkServer:'Server node (Abroad)', lkClient:'Client node (Iran)', lkSIp:'Server address', lkCIp:'Client address',
 lkNote:'Keys and ports are generated and shared with both nodes automatically; addresses come from the nodes.',
 lkNoteGost:'Gost only configures the client node (Iran): it forwards the ports to the server address.',
 lkCreate:'Create on both nodes', lkNeed:'You need at least two online nodes (this panel counts as one).',
 lkOk:'✔ Tunnel created and running on both nodes', lkPartial:'⚠ Saved on both nodes, but at least one is not running yet:', lkRolled:'The server side was removed again so nothing is left half-configured.',
 e_bad_name:'Use letters, digits, - or _ for the name.', e_bad_ports:'Ports must be numbers between 1 and 65535.', e_ports_required:'Enter at least one port to forward.',
 e_ports_conflict:'The control port must differ from the forwarded ports (and bridge ≠ sync).', e_bad_address:'Check the server / client address.', e_same_node:'Pick two different nodes.',
 e_server_failed:'Could not configure the server node.', e_node_not_found:'Node not found.', e_bad_method:'Unknown protocol.'
},
fa:{
 appTitle:'مستر تانل A,S', masterBadge:'مستر', network:'شبکه', masterActive:'مستر فعال', palette:'پالت رنگ', accent:'رنگ اصلی',
 refresh:'تازه‌سازی', signOut:'خروج', signInSub:'برای مدیریت نودها و تانل‌ها وارد شوید', username:'نام کاربری', password:'رمز عبور', signIn:'ورود',
 badLogin:'نام کاربری یا رمز عبور اشتباه است.', tooMany:'تلاش بیش از حد — چند دقیقه صبر کنید.', sessionEnd:'نشست منقضی شد — دوباره وارد شوید.',
 stIp:'آی‌پی عمومی نود', hostname:'نام میزبان', stNodes:'نودهای متصل', stNodesNote:'نودهای فعال متصل به مستر', stLat:'میانگین تأخیر', stLatNote:'نود ⇄ مستر، زنده',
 stRes:'منابع سرور', cpu:'مصرف پردازنده', ram:'مصرف رم', uptime:'آپتایم', load:'بار',
 tabConfig:'نود و تنظیمات', tabNodes:'نودها', tabSpeed:'تست سرعت (iperf3)', tabPing:'پینگ و تأخیر زنده', tabTunnels:'مدیریت تانل‌ها',
 cfgTitle:'پیکربندی نود و مستر', cfgDesc:'مدیریت هویت نود، تانل‌ها، بهینه‌سازی و به‌روزرسانی', wizard:'راه‌اندازی تانل جدید',
 startAll:'روشن کردن همه', restartAll:'ریستارت همه', stopAll:'توقف همه', save:'ذخیره تغییرات', identity:'هویت نود', nodeName:'نام نود', netName:'نام شبکه',
 side:'سمت', publicIp:'آی‌پی عمومی', nodeId:'شناسه نود', tuning:'بهینه‌سازی و به‌روزرسانی سرور', optimize:'بهینه‌سازی سرور', optimizeDesc:'BBR و سخت‌سازی sysctl برای همه تانل‌ها',
 optimizeBtn:'اجرای بهینه‌سازی', health:'کرون هلث‌چک', healthDesc:'هر تانل متوقف‌شده خودکار دوباره روشن می‌شود', minutes:'دقیقه', scriptUpd:'نسخه اسکریپت', updateBtn:'به‌روزرسانی اسکریپت',
 nodeOnline:'نود آنلاین', nodeOffline:'نود آفلاین', upToDate:'به‌روز', updateAvail:'به‌روزرسانی موجود است',
 nodesTitle:'نودها و همتاها', nodesDesc:'همه سرورهای ایران و خارج که به این مستر وصل‌اند', updateAll:'به‌روزرسانی همه نودها',
 thNode:'نود', thSide:'سمت', thStatus:'وضعیت', thTunnels:'تانل‌ها', thLat:'تأخیر', thVer:'نسخه', online:'آنلاین', offline:'آفلاین', master:'مستر', manage:'مدیریت', remove:'حذف', update:'به‌روزرسانی',
 joinTitle:'اتصال نود جدید', joinDesc:'این را روی سرور ایران یا خارج (با اسکریپت نصب‌شده) اجرا کنید، یا از منو: پنل مستر و نودها ← اتصال به مستر.',
 masterUrl:'آدرس مستر', joinKey:'کلید اتصال', fingerprint:'اثر انگشت TLS (SHA-256)', joinCmd:'دستور اتصال', copy:'کپی', copied:'کپی شد ✔',
 httpWarn:'پنل روی HTTP ساده اجرا می‌شود — کلید اتصال بدون رمزنگاری منتقل می‌شود. هنگام نصب پنل HTTPS را فعال کنید.',
 speedTitle:'تست سرعت بین نودها (iperf3)', speedDesc:'سرعت واقعی بین دو سرور شما را می‌سنجد. iperf3 خودکار نصب می‌شود.',
 spServer:'نود سرور (دریافت‌کننده)', spClient:'نود کلاینت (ارسال‌کننده)', spPort:'پورت iperf3', spDur:'مدت (ثانیه)', spPar:'تعداد جریان موازی', spRun:'شروع تست سرعت', spRunning:'در حال تست…',
 spNote:'نود سرور باید پورت TCP برنامه iperf3 را در فایروال باز بگذارد.', upload:'آپلود', download:'دانلود', retrans:'ارسال مجدد', history:'تاریخچه', when:'زمان',
 pickDiff:'دو نود متفاوت انتخاب کنید.', pickOnline:'هر دو نود باید آنلاین باشند.',
 stepserver_start:'اجرای سرور iperf3', stepupload:'تست آپلود', stepdownload:'تست دانلود',
 pingTitle:'تأخیر تا مستر', pingDesc:'زمان رفت‌وبرگشت زنده بین هر نود و این مستر (هر چند ثانیه به‌روز می‌شود)',
 cur:'اکنون', avg:'میانگین', min:'کمینه', max:'بیشینه', trend:'روند', livePing:'پینگ زنده', pgFrom:'از نود', pgTo:'مقصد', pgCustom:'هاست / آی‌پی دلخواه',
 pgStart:'شروع پینگ زنده', pgStop:'توقف', clear:'پاک کردن', loss:'از دست رفته', custom:'دلخواه…',
 tunTitle:'مدیریت تانل‌ها', addTunnel:'افزودن تانل', tunDesc:'تانل‌های نود انتخاب‌شده. برای تنظیم، لاگ زنده یا ریستارت زمان‌بندی‌شده روی یکی کلیک کنید.', noTunnels:'هنوز تانلی نیست — یکی اضافه کنید.',
 mCfg:'تنظیمات', mLog:'لاگ زنده', tName:'نام تانل', protocol:'پروتکل', saveStart:'ذخیره و اجرا', start:'شروع', stop:'توقف', restart:'ریستارت', delete:'حذف',
 sched:'ریستارت زمان‌بندی‌شده', schedNote:'(بدون توجه به وضعیت)', hours:'ساعت', save2:'ذخیره', live:'زنده', newTunnel:'تانل جدید',
 running:'در حال اجرا', stopped:'متوقف', crafted:'ساخته‌شده توسط', keepPrivate:'این آدرس و رمز عبور را محرمانه نگه دارید',
 savedOk:'ذخیره شد ✔', failed:'ناموفق', nodeOfflineErr:'این نود آفلاین است.', timeoutErr:'نود به موقع پاسخ نداد.', removeConfirm:'نود «{n}» از مستر حذف شود؟',
 deleteConfirm:'«{n}» حذف شود؟ تانل متوقف و تنظیمات، لاگ و زمان‌بندی آن پاک می‌شود.', bulkDone:'انجام شد: {ok} موفق، {bad} ناموفق', optimizeDone:'بهینه‌سازی اعمال شد ✔',
 updated:'به‌روزرسانی شد ✔', updateNoChange:'از قبل به‌روز است', keyRegen:'کلید اتصال جدید ساخته شد ✔', regenConfirm:'کلید اتصال جدید ساخته شود؟ نودهای فعلی متصل می‌مانند.',
 enterName:'یک نام برای تانل وارد کنید (حروف، عدد، - یا _).', overwrite:'تانلی با نام «{n}» وجود دارد. بازنویسی شود؟',
 savedRunning:'✔ ذخیره شد و در حال اجراست', savedNotRunning:'✔ تنظیمات ذخیره شد، ولی تانل اجرا نشده:', saveFailed:'✖ ذخیره ناموفق بود', never:'هرگز', ago:'{s} ثانیه پیش', sideEu:'🌍 سرور (خارج)', sideIran:'🇮🇷 کلاینت (ایران)',
 modeManual:'دستی', modeLink:'از روی نودهای پنل', addLink:'اتصال نودهای پنل', addManual:'تانل دستی',
 lkServer:'نود سرور (خارج)', lkClient:'نود کلاینت (ایران)', lkSIp:'آدرس سرور', lkCIp:'آدرس کلاینت',
 lkNote:'کلیدها و پورت‌ها خودکار ساخته و روی هر دو نود اعمال می‌شود؛ آدرس‌ها از خود نودها می‌آید.',
 lkNoteGost:'Gost فقط نود کلاینت (ایران) را تنظیم می‌کند و پورت‌ها را به آدرس سرور فوروارد می‌کند.',
 lkCreate:'ساخت روی هر دو نود', lkNeed:'حداقل دو نود آنلاین لازم است (خود پنل هم یک نود حساب می‌شود).',
 lkOk:'✔ تانل روی هر دو نود ساخته شد و در حال اجراست', lkPartial:'⚠ روی هر دو نود ذخیره شد، ولی حداقل یکی هنوز اجرا نشده:', lkRolled:'سمت سرور دوباره حذف شد تا چیزی نیمه‌کاره نماند.',
 e_bad_name:'برای نام از حروف، عدد، - یا _ استفاده کنید.', e_bad_ports:'پورت‌ها باید عددی بین ۱ تا ۶۵۵۳۵ باشند.', e_ports_required:'حداقل یک پورت برای فوروارد وارد کنید.',
 e_ports_conflict:'پورت کنترل باید با پورت‌های فوروارد فرق داشته باشد (و bridge با sync).', e_bad_address:'آدرس سرور / کلاینت را بررسی کنید.', e_same_node:'دو نود متفاوت انتخاب کنید.',
 e_server_failed:'نود سرور تنظیم نشد.', e_node_not_found:'نود پیدا نشد.', e_bad_method:'پروتکل ناشناخته.'
}};

let LANG = localStorage.getItem('as_lang') || 'en';
const t = (k, v) => { let s = (I18N[LANG] && I18N[LANG][k]) ?? I18N.en[k] ?? k; if (v) for (const x in v) s = s.replace('{' + x + '}', v[x]); return s; };
const $ = id => document.getElementById(id);
const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

/* ============================ state ============================ */
let TOKEN = localStorage.getItem('as_tok') || '';
const S = {nodes: [], master: null, sel: 'local', tab: 'config', cfgFor: null, hcLoaded: null, joinLoaded: false, timer: null, spKey: '', pgKey: ''};
const sideLabel = r => r === 'eu' ? t('sideEu') : t('sideIran');
const cur = () => S.nodes.find(n => n.id === S.sel) || S.nodes[0];

/* ============================ palette ============================ */
const PALETTES = [['#a855f7','#c084fc'],['#6366f1','#818cf8'],['#3b82f6','#60a5fa'],['#06b6d4','#22d3ee'],
                  ['#10b981','#34d399'],['#f59e0b','#fbbf24'],['#f97316','#fb923c'],['#ec4899','#f472b6']];
function applyPalette(i) {
  const p = PALETTES[i] || PALETTES[0];
  document.documentElement.style.setProperty('--accent', p[0]);
  document.documentElement.style.setProperty('--accent2', p[1]);
  localStorage.setItem('as_pal', i);
  document.querySelectorAll('.sw').forEach((e, k) => e.classList.toggle('on', k === +i));
  if (S.tab === 'ping') drawChart();
}
function buildSwatches() {
  $('swatches').innerHTML = PALETTES.map((p, i) => `<div class="sw" style="background:linear-gradient(135deg,${p[0]},${p[1]})" onclick="applyPalette(${i})"></div>`).join('');
  applyPalette(localStorage.getItem('as_pal') || 0);
}
function togglePal(e) { e.stopPropagation(); $('palPop').classList.toggle('hidden'); }
document.addEventListener('click', e => { if (!e.target.closest('#palPop')) $('palPop').classList.add('hidden'); });

/* ============================ helpers ============================ */
function toast(msg, kind) {
  const el = $('toast'); el.textContent = msg; el.className = 'toast show ' + (kind || '');
  clearTimeout(el._t); el._t = setTimeout(() => el.classList.remove('show'), 2800);
}
function copyText(txt) {
  txt = String(txt || ''); if (!txt || txt === '—') return;
  const done = () => toast(t('copied'), 'ok');
  if (navigator.clipboard && window.isSecureContext) { navigator.clipboard.writeText(txt).then(done, () => fallbackCopy(txt, done)); }
  else fallbackCopy(txt, done);
}
function fallbackCopy(txt, cb) {
  const ta = document.createElement('textarea'); ta.value = txt; ta.style.position = 'fixed'; ta.style.opacity = '0';
  document.body.appendChild(ta); ta.select(); try { document.execCommand('copy'); cb(); } catch (e) {} document.body.removeChild(ta);
}
const fmtBytes = b => { if (!b) return '0 B'; const u = ['B','KB','MB','GB','TB']; let i = 0; while (b >= 1024 && i < 4) { b /= 1024; i++; } return b.toFixed(i > 1 ? 1 : 0) + ' ' + u[i]; };
const fmtUp = s => { s = +s || 0; const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60); return (d ? d + 'd ' : '') + h + 'h ' + m + 'm'; };
const fmtNum = (v, d = 1) => (v == null || isNaN(v)) ? '—' : (+v).toFixed(d);
function errText(r) {
  if (!r) return t('failed');
  if (r.error === 'node_offline') return t('nodeOfflineErr');
  if (r.error === 'node_timeout') return t('timeoutErr');
  if (r.error && I18N.en['e_' + r.error]) return t('e_' + r.error);
  return r.log || r.hint || r.detail || r.error || t('failed');
}

async function api(path, opts = {}) {
  const o = Object.assign({method: 'GET'}, opts);
  o.headers = Object.assign({'Content-Type': 'application/json'}, TOKEN ? {Authorization: 'Bearer ' + TOKEN} : {}, o.headers || {});
  if (o.body && typeof o.body !== 'string') o.body = JSON.stringify(o.body);
  const r = await fetch(path, o);
  let data; try { data = await r.json(); } catch (e) { data = {error: 'bad_json'}; }
  if (r.status === 401 && path !== '/api/login') { showGate(t('sessionEnd')); throw new Error('unauthorized'); }
  data._status = r.status;
  return data;
}
const napi = (p, o) => api('/api/n/' + encodeURIComponent(S.sel) + p, o);

/* ============================ login ============================ */
function showGate(msg) {
  clearInterval(S.timer); S.timer = null; stopLive(); stopPing(true);
  $('gate').classList.remove('hidden'); $('app').classList.add('hidden'); $('gErr').textContent = msg || '';
}
async function doLogin() {
  const username = $('uIn').value.trim(), password = $('pIn').value;
  $('gErr').textContent = '';
  try {
    const r = await api('/api/login', {method: 'POST', body: {username, password}});
    if (r.token) { TOKEN = r.token; localStorage.setItem('as_tok', TOKEN); $('pIn').value = ''; boot(); }
    else $('gErr').textContent = r._status === 429 ? t('tooMany') : t('badLogin');
  } catch (e) { $('gErr').textContent = String(e.message || e); }
}
function logout() { localStorage.removeItem('as_tok'); TOKEN = ''; showGate(''); }

/* ============================ boot / polling ============================ */
async function boot() {
  if (!TOKEN) { showGate(''); return; }
  try {
    await refreshNodes();
  } catch (e) { return; }
  $('gate').classList.add('hidden'); $('app').classList.remove('hidden');
  renderAll(true); loadNodeInfo();
  clearInterval(S.timer);
  S.timer = setInterval(() => { if (!document.hidden) refreshNodes().catch(() => {}); }, 3000);
}
async function refreshNodes() {
  const d = await api('/api/nodes');
  if (!d.nodes) throw new Error('bad');
  S.nodes = d.nodes; S.master = d.master;
  if (!S.nodes.some(n => n.id === S.sel)) S.sel = 'local';
  renderAll(false);
}
async function refreshAll(force) {
  try { await refreshNodes(); if (force) { S.cfgFor = null; renderConfig(true); loadNodeInfo(); if (S.tab === 'nodes') loadJoin(); } } catch (e) {}
}

/* ============================ rendering ============================ */
function renderAll(force) {
  if (!S.master) return;
  $('hNet').textContent = S.master.network; $('hVer').textContent = 'v' + S.master.version;
  renderStats(); renderNodeBar();
  if (S.tab === 'config') renderConfig(force);
  if (S.tab === 'nodes') renderNodes();
  if (S.tab === 'speed') renderSpeedSelects();
  if (S.tab === 'ping') { renderLat(); renderPingSelects(); }
  if (S.tab === 'tunnels') renderTunnels();
}
function renderStats() {
  const n = cur(); if (!n) return;
  $('stIp').textContent = n.public_ip || '—'; $('stHost').textContent = n.hostname || '—'; $('stSide').textContent = sideLabel(n.role);
  const remote = S.nodes.filter(x => !x.is_local), on = remote.filter(x => x.online);
  $('stNodes').textContent = on.length + ' / ' + remote.length;
  const rt = on.filter(x => x.rtt_ms != null).map(x => x.rtt_ms);
  $('stLat').textContent = rt.length ? (rt.reduce((a, b) => a + b, 0) / rt.length).toFixed(1) + ' ms' : '—';
  const m = n.metrics || {};
  $('cpuTxt').textContent = fmtNum(m.cpu) + '%'; $('cpuBar').style.width = Math.min(100, m.cpu || 0) + '%';
  $('ramTxt').textContent = fmtNum(m.ram_pct) + '% (' + ((m.ram_used || 0) / 1073741824).toFixed(1) + '/' + ((m.ram_total || 0) / 1073741824).toFixed(1) + ' GB)';
  $('ramBar').style.width = Math.min(100, m.ram_pct || 0) + '%';
  $('upTxt').textContent = fmtUp(m.uptime); $('loadTxt').textContent = (m.load || []).join(', ') || '—';
}
function renderNodeBar() {
  const key = S.nodes.map(n => n.id + n.name + n.online + n.role).join('|') + S.sel + LANG;
  if (S.barKey === key) return; S.barKey = key;
  $('nodeBar').innerHTML = S.nodes.map(n => `<button class="chip ${n.id === S.sel ? 'sel' : ''}" onclick="selectNode('${esc(n.id)}')">
    <i class="dot ${n.online ? 'on' : 'off'}"></i><b>${esc(n.name)}</b><small>${n.role === 'eu' ? '🌍' : '🇮🇷'}${n.is_local ? ' · ' + t('master') : ''}</small></button>`).join('');
}
function selectNode(id) {
  S.sel = id; S.cfgFor = null; S.barKey = ''; S.hcLoaded = null;
  renderAll(true); loadNodeInfo();
}
function setTab(name) {
  S.tab = name;
  document.querySelectorAll('.tab').forEach(b => b.classList.toggle('on', b.dataset.tab === name));
  document.querySelectorAll('.pane').forEach(p => p.classList.toggle('hidden', p.id !== 'pane-' + name));
  if (name === 'nodes') loadJoin();
  if (name === 'speed') { S.spKey = ''; loadSpeedHistory(); }
  if (name === 'ping') { S.pgKey = ''; setTimeout(drawChart, 30); }
  if (name === 'config') { S.cfgFor = null; loadNodeInfo(); }
  renderAll(true);
}

/* ---- config tab ---- */
function renderConfig(force) {
  const n = cur(); if (!n) return;
  const ok = $('cfgStatus'); ok.className = 'ok-badge' + (n.online ? '' : ' bad');
  ok.innerHTML = `<i class="dot ${n.online ? 'on' : 'off'}"></i>${t(n.online ? 'nodeOnline' : 'nodeOffline')}`;
  if (force || S.cfgFor !== S.sel) $('cfgSide').value = n.role; $('cfgHost').value = n.hostname || ''; $('cfgIp').value = n.public_ip || ''; $('cfgId').value = n.id;
  $('cfgVer').textContent = 'v' + (n.version || '?');
  const vb = $('cfgVerBadge'); const mv = S.master.version;
  if (n.is_local || !n.version || n.version === '?') vb.classList.add('hidden');
  else { vb.classList.remove('hidden'); const same = n.version === mv; vb.className = 'ok-badge' + (same ? '' : ' bad'); vb.textContent = same ? t('upToDate') : t('updateAvail'); }
  if (force || S.cfgFor !== S.sel) { $('cfgName').value = n.name; $('cfgNet').value = S.master.network; S.cfgFor = S.sel; }
}
async function loadNodeInfo() {
  const sel = S.sel;
  try {
    const r = await napi('/nodeinfo');
    if (sel !== S.sel || r.error) return;
    const m = parseInt(r.hc_minutes || '0', 10);
    $('hcToggle').checked = m > 0; $('hcMin').value = m > 0 ? m : 1;
    S.hcLoaded = {enabled: m > 0, minutes: m > 0 ? m : 1};
  } catch (e) {}
}
async function saveConfig() {
  const n = cur(); const name = $('cfgName').value.trim(), net = $('cfgNet').value.trim();
  try {
    const side = $('cfgSide').value;
    if ((name && name !== n.name) || side !== n.role) { const r = await napi('/rename', {method: 'POST', body: {name: name || n.name, role: side}}); if (!r.ok) throw r; }
    if (net && net !== S.master.network) { const r = await api('/api/master/settings', {method: 'POST', body: {network_name: net}}); if (!r.ok) throw r; }
    const enabled = $('hcToggle').checked, minutes = Math.max(1, parseInt($('hcMin').value, 10) || 1);
    const prev = S.hcLoaded;
    if (!prev || prev.enabled !== enabled || (enabled && prev.minutes !== minutes)) {
      const r = await napi('/healthcheck', {method: 'POST', body: {enabled, minutes}});
      if (!r.ok) throw r; S.hcLoaded = {enabled, minutes};
    }
    toast(t('savedOk'), 'ok'); S.cfgFor = null; await refreshNodes(); renderConfig(true);
  } catch (e) { if (e && e.message === 'unauthorized') return; toast(errText(e), 'err'); }
}
async function bulk(action) {
  if (!cur().online) { toast(t('nodeOfflineErr'), 'err'); return; }
  toast('…');
  const r = await napi('/bulk/' + action, {method: 'POST'});
  if (r.ok) toast(t('bulkDone', {ok: r.succeeded, bad: r.failed}), r.failed ? 'err' : 'ok'); else toast(errText(r), 'err');
  refreshNodes();
}
async function optimizeNode() {
  toast('…'); const r = await napi('/optimize', {method: 'POST'});
  toast(r.log !== undefined ? t('optimizeDone') : errText(r), r.log !== undefined ? 'ok' : 'err');
}
async function updateNode(id) {
  toast('…');
  const r = await api('/api/n/' + encodeURIComponent(id) + '/update', {method: 'POST'});
  if (r.ok) toast(r.changed === false ? t('updateNoChange') : t('updated'), 'ok'); else toast(errText(r), 'err');
  setTimeout(() => refreshNodes().catch(() => {}), 6000);
}
async function updateAll() {
  toast('…'); const r = await api('/api/update-all', {method: 'POST'});
  const res = Object.values(r.results || {}); const ok = res.filter(x => x && x.ok).length;
  toast(t('bulkDone', {ok, bad: res.length - ok}), ok === res.length ? 'ok' : 'err');
  setTimeout(() => refreshNodes().catch(() => {}), 6000);
}

/* ---- nodes tab ---- */
function spark(arr, w = 110, h = 26) {
  if (!arr || arr.length < 2) return '<span class="muted">—</span>';
  const mx = Math.max(...arr), mn = Math.min(...arr), rg = Math.max(mx - mn, 1);
  const pts = arr.map((v, i) => (i * w / (arr.length - 1)).toFixed(1) + ',' + (h - 2 - (v - mn) / rg * (h - 4)).toFixed(1)).join(' ');
  return `<svg width="${w}" height="${h}" viewBox="0 0 ${w} ${h}"><polyline fill="none" stroke="var(--accent2)" stroke-width="1.6" points="${pts}"/></svg>`;
}
function renderNodes() {
  $('nodesBody').innerHTML = S.nodes.map(n => {
    const m = n.metrics || {};
    const act = `<button class="btn sm o-acc" onclick="selectNode('${esc(n.id)}');setTab('tunnels')">${t('manage')}</button> ` +
      `<button class="btn sm ghost" onclick="updateNode('${esc(n.id)}')">⬆</button>` +
      (n.is_local ? '' : ` <button class="btn sm o-red" onclick="removeNode('${esc(n.id)}')">✕</button>`);
    return `<tr><td><span class="nm">${esc(n.name)}</span>${n.is_local ? ' <span class="badge">' + t('master') + '</span>' : ''}<div class="muted mono" style="font-size:12px">${esc(n.hostname)}</div></td>
      <td><span class="rb ${n.role}">${sideLabel(n.role)}</span></td>
      <td><i class="dot ${n.online ? 'on' : 'off'}"></i> ${t(n.online ? 'online' : 'offline')}${!n.online && n.last_seen != null ? '<div class="muted" style="font-size:12px">' + t('ago', {s: n.last_seen}) + '</div>' : ''}</td>
      <td class="mono">${esc(n.public_ip || '—')}</td><td class="mono">${n.online ? fmtNum(m.cpu) + '%' : '—'}</td><td class="mono">${n.online ? fmtNum(m.ram_pct) + '%' : '—'}</td>
      <td class="mono">${n.tunnels_running}/${n.tunnels_total}</td><td class="mono">${n.is_local ? '—' : (n.online && n.rtt_ms != null ? fmtNum(n.rtt_ms) + ' ms' : '—')}</td>
      <td class="mono">v${esc(n.version || '?')}</td><td style="white-space:nowrap">${act}</td></tr>`;
  }).join('');
}
async function removeNode(id) {
  const n = S.nodes.find(x => x.id === id); if (!n || !confirm(t('removeConfirm', {n: n.name}))) return;
  const r = await api('/api/nodes/' + encodeURIComponent(id), {method: 'DELETE'});
  if (r.ok) { if (S.sel === id) S.sel = 'local'; toast(t('savedOk'), 'ok'); refreshNodes(); } else toast(errText(r), 'err');
}
async function loadJoin() {
  try {
    const j = await api('/api/master/join'); if (j.error) return;
    S.join = j; $('jUrl').value = j.url; $('jKey').value = j.join_key; $('jFp').value = j.fingerprint || '—';
    const cmd = "sudo A,S-tunnel --join '" + j.url + "' '" + j.join_key + "' 'my-node' iran" + (j.fingerprint ? " '" + j.fingerprint + "'" : '');
    $('jCmd').textContent = cmd; $('jHttpWarn').classList.toggle('hidden', !!j.https);
  } catch (e) {}
}
function toggleKey() { const k = $('jKey'); k.type = k.type === 'password' ? 'text' : 'password'; }
async function regenKey() {
  if (!confirm(t('regenConfirm'))) return;
  const r = await api('/api/master/join/regenerate', {method: 'POST'}); if (r.join_key) { toast(t('keyRegen'), 'ok'); loadJoin(); }
}

/* ---- speedtest tab ---- */
function nodeOpts(onlyOnline) {
  return S.nodes.filter(n => !onlyOnline || n.online).map(n => `<option value="${esc(n.id)}">${esc(n.name)} — ${esc(n.public_ip || '?')}</option>`).join('');
}
function renderSpeedSelects() {
  const key = S.nodes.map(n => n.id + n.name + n.online + n.public_ip).join('|');
  if (key === S.spKey) return; S.spKey = key;
  const ps = $('spServer').value, pc = $('spClient').value;
  $('spServer').innerHTML = nodeOpts(true); $('spClient').innerHTML = nodeOpts(true);
  const ids = S.nodes.filter(n => n.online).map(n => n.id);
  $('spServer').value = ids.includes(ps) ? ps : (ids.find(i => i !== 'local') || ids[0] || '');
  $('spClient').value = ids.includes(pc) ? pc : (ids.includes('local') ? 'local' : (ids[1] || ids[0] || ''));
}
async function loadSpeedHistory() {
  try {
    const r = await api('/api/speedtest/history');
    $('spHist').innerHTML = (r.history || []).map(h => `<tr><td class="mono">${new Date(h.time * 1000).toLocaleTimeString()}</td><td>${esc(h.server)}</td><td>${esc(h.client)}</td>
      <td class="mono">${fmtNum(h.upload_mbps, 1)} Mbps</td><td class="mono">${fmtNum(h.download_mbps, 1)} Mbps</td></tr>`).join('') || `<tr><td colspan="5" class="muted">—</td></tr>`;
  } catch (e) {}
}
async function runSpeed() {
  const server = $('spServer').value, client = $('spClient').value;
  if (!server || !client || server === client) { toast(t('pickDiff'), 'err'); return; }
  const btn = $('spBtn'); btn.disabled = true; btn.querySelector('span').textContent = t('spRunning');
  $('spOut').classList.remove('hidden'); $('spUp').textContent = $('spDown').textContent = $('spRe').textContent = '…'; $('spSteps').innerHTML = '';
  try {
    const r = await api('/api/speedtest', {method: 'POST', body: {server, client, port: +$('spPort').value || 5201, duration: +$('spDur').value || 8, parallel: +$('spPar').value || 4}});
    $('spSteps').innerHTML = (r.steps || []).map(s => `<li>${s.ok ? '✅' : '❌'} ${t('step' + s.step)}${s.detail ? ' — <span class="muted">' + esc(s.detail) + '</span>' : ''}</li>`).join('');
    if (r.ok) { $('spUp').textContent = fmtNum(r.upload_mbps, 1); $('spDown').textContent = fmtNum(r.download_mbps, 1); $('spRe').textContent = r.retransmits ?? 0; }
    else { $('spUp').textContent = $('spDown').textContent = $('spRe').textContent = '—'; toast(errText(r), 'err'); }
    loadSpeedHistory();
  } catch (e) { if (e.message !== 'unauthorized') toast(String(e.message || e), 'err'); }
  btn.disabled = false; btn.querySelector('span').textContent = t('spRun');
}

/* ---- ping tab ---- */
function renderLat() {
  $('latBody').innerHTML = S.nodes.map(n => {
    const h = n.rtt_hist || [];
    const avg = h.length ? h.reduce((a, b) => a + b, 0) / h.length : null;
    return `<tr><td class="nm">${esc(n.name)}</td><td><i class="dot ${n.online ? 'on' : 'off'}"></i> ${t(n.online ? 'online' : 'offline')}</td>
      <td class="mono acc">${n.is_local ? '0.0 ms' : (n.online ? fmtNum(n.rtt_ms) + ' ms' : '—')}</td>
      <td class="mono">${n.is_local ? '—' : fmtNum(avg)}</td><td class="mono">${h.length ? fmtNum(Math.min(...h)) : '—'}</td><td class="mono">${h.length ? fmtNum(Math.max(...h)) : '—'}</td>
      <td>${n.is_local ? '' : spark(h)}</td></tr>`;
  }).join('');
}
function renderPingSelects() {
  const key = S.nodes.map(n => n.id + n.name + n.online + n.public_ip).join('|') + LANG;
  if (key === S.pgKey) return; S.pgKey = key;
  const ps = $('pgSource').value, pt = $('pgTarget').value;
  $('pgSource').innerHTML = nodeOpts(true);
  const ids = S.nodes.filter(n => n.online).map(n => n.id);
  $('pgSource').value = ids.includes(ps) ? ps : (ids[0] || '');
  const nodeT = S.nodes.filter(n => n.public_ip).map(n => `<option value="${esc(n.public_ip)}">${esc(n.name)} (${esc(n.public_ip)})</option>`).join('');
  $('pgTarget').innerHTML = nodeT + '<option value="1.1.1.1">1.1.1.1 (Cloudflare)</option><option value="8.8.8.8">8.8.8.8 (Google)</option><option value="9.9.9.9">9.9.9.9 (Quad9)</option><option value="__custom">' + esc(t('custom')) + '</option>';
  if ([...$('pgTarget').options].some(o => o.value === pt)) $('pgTarget').value = pt;
  pgTargetChanged();
}
function pgTargetChanged() { const c = $('pgTarget').value === '__custom'; $('pgCustom').disabled = !c; if (c) $('pgCustom').focus(); }
const PG = {timer: null, data: [], sent: 0, lost: 0, busy: false};
function pgTarget() { const v = $('pgTarget').value; return v === '__custom' ? $('pgCustom').value.trim() : v; }
async function pingOnce() {
  if (PG.busy) return; const src = $('pgSource').value, target = pgTarget(); if (!src || !target) return;
  PG.busy = true;
  try {
    const r = await api('/api/n/' + encodeURIComponent(src) + '/ping', {method: 'POST', body: {target, count: 1}});
    PG.sent++;
    if (r.ok && r.samples && r.samples.length) PG.data.push(r.samples[0]); else { PG.lost++; PG.data.push(null); if (r.error && r.error !== 'node_timeout') { toast(errText(r), 'err'); stopPing(); } }
    if (PG.data.length > 80) PG.data.shift();
    drawChart(); pingStats();
  } catch (e) { if (e.message === 'unauthorized') stopPing(true); }
  PG.busy = false;
}
function togglePing() { PG.timer ? stopPing() : startPing(); }
function startPing() {
  if (!pgTarget()) { toast(t('pgCustom'), 'err'); return; }
  PG.timer = setInterval(pingOnce, 2000); pingOnce();
  $('pgBtn').innerHTML = '■ <span>' + t('pgStop') + '</span>';
}
function stopPing(silent) { clearInterval(PG.timer); PG.timer = null; const b = $('pgBtn'); if (b) b.innerHTML = '▶ <span>' + t('pgStart') + '</span>'; }
function clearPing() { PG.data = []; PG.sent = PG.lost = 0; drawChart(); pingStats(); }
function pingStats() {
  const v = PG.data.filter(x => x != null);
  $('pgNow').textContent = v.length ? fmtNum(PG.data[PG.data.length - 1]) : '—';
  $('pgAvg').textContent = v.length ? fmtNum(v.reduce((a, b) => a + b, 0) / v.length) : '—';
  $('pgMin').textContent = v.length ? fmtNum(Math.min(...v)) : '—'; $('pgMax').textContent = v.length ? fmtNum(Math.max(...v)) : '—';
  $('pgLoss').textContent = PG.sent ? fmtNum(PG.lost * 100 / PG.sent) : '—';
}
function drawChart() {
  const cv = $('pgCanvas'); if (!cv || cv.offsetWidth === 0) return;
  const dpr = window.devicePixelRatio || 1, W = cv.offsetWidth, H = cv.offsetHeight;
  cv.width = W * dpr; cv.height = H * dpr; const c = cv.getContext('2d'); c.scale(dpr, dpr); c.clearRect(0, 0, W, H);
  const accent = getComputedStyle(document.documentElement).getPropertyValue('--accent2').trim() || '#c084fc';
  const vals = PG.data.filter(x => x != null); const mx = Math.max(10, ...vals) * 1.15, pad = 30;
  c.strokeStyle = 'rgba(255,255,255,.07)'; c.fillStyle = 'rgba(255,255,255,.4)'; c.font = '11px ui-monospace,monospace'; c.lineWidth = 1;
  for (let i = 0; i <= 4; i++) { const y = 10 + (H - 24) * i / 4; c.beginPath(); c.moveTo(pad, y); c.lineTo(W - 8, y); c.stroke(); c.fillText((mx * (1 - i / 4)).toFixed(0), 2, y + 4); }
  if (PG.data.length < 1) return;
  const n = PG.data.length, step = n > 1 ? (W - pad - 12) / (n - 1) : 0;
  const X = i => pad + i * step, Y = v => 10 + (H - 24) * (1 - v / mx);
  c.beginPath(); let started = false;
  PG.data.forEach((v, i) => { if (v == null) { started = false; return; } if (!started) { c.moveTo(X(i), Y(v)); started = true; } else c.lineTo(X(i), Y(v)); });
  c.strokeStyle = accent; c.lineWidth = 2; c.stroke();
  PG.data.forEach((v, i) => { if (v == null) { c.fillStyle = '#fb7185'; c.fillRect(X(i) - 2, H - 14, 4, 8); } else { c.fillStyle = accent; c.beginPath(); c.arc(X(i), Y(v), 2.6, 0, 7); c.fill(); } });
}
window.addEventListener('resize', () => { if (S.tab === 'ping') drawChart(); });

/* ---- tunnels tab ---- */
function renderTunnels() {
  const n = cur(); if (!n) return;
  $('tunNode').textContent = n.name;
  const list = Array.isArray(n.tunnels) ? n.tunnels : [];
  const key = JSON.stringify(list) + n.online + LANG + n.id;
  if (S.tunKey === key) return; S.tunKey = key;
  $('tunGrid').innerHTML = list.length ? list.map(x => `<div class="tcard ${x.running ? 'on' : ''}" onclick="openSlotByName('${esc(x.prof)}')">
    <div class="top"><span class="nm">${esc(x.prof)}</span><i class="dot ${x.running ? 'on' : 'off'}"></i></div>
    <div class="meta"><span class="badge">${esc(x.method)}</span><span class="rb ${esc(x.role)}">${sideLabel(x.role)}</span><span class="muted" style="font-size:12px">${t(x.running ? 'running' : 'stopped')}</span></div>
    <div class="btns" onclick="event.stopPropagation()">
      <button class="btn sm o-green" onclick="quick('${esc(x.prof)}','start')">▶</button>
      <button class="btn sm o-amber" onclick="quick('${esc(x.prof)}','restart')">⟳</button>
      <button class="btn sm o-red" onclick="quick('${esc(x.prof)}','stop')">■</button></div></div>`).join('')
    : `<div class="empty">${t('noTunnels')}</div>`;
}
async function quick(prof, action) {
  toast('…'); const r = await napi('/slots/' + encodeURIComponent(prof) + '/' + action, {method: 'POST'});
  toast(r.ok ? '✔ ' + action : errText(r), r.ok ? 'ok' : 'err'); await reloadTunnels();
}
async function reloadTunnels() {
  const sel = S.sel;
  try { const r = await napi('/slots'); if (sel === S.sel && Array.isArray(r)) { cur().tunnels = r; S.tunKey = ''; renderTunnels(); } } catch (e) {}
}

/* ============================ tunnel modal ============================ */
let CURRENT = null, LIVE_TIMER = null;
const ROLE_KEYS = ['BH_ROLE', 'RT_ROLE', 'FRP_ROLE', 'PQ_ROLE'];
const ROLE_KEY_OF = {backhaul: 'BH_ROLE', rathole: 'RT_ROLE', frp: 'FRP_ROLE', paqet: 'PQ_ROLE'};
const T = (k, l, o = {}) => Object.assign({k, l, t: 'text'}, o);
const SEL = (k, l, opts, o = {}) => Object.assign({k, l, t: 'select', opts}, o);
const KCP_MODES = ['fast', 'normal', 'fast2', 'fast3'], KCP_BLOCKS = ['aes-128-gcm', 'aes', 'aes-128', 'aes-192', 'aes-256', 'none'];
/* Each side only gets the fields that side really uses: eu = Server (abroad), iran = Client (Iran). */
const GRE_FIELDS = [T('LOCAL_IP', 'This server public IP', {full: true}), T('PEER_IP', 'Other side public IP', {full: true})];
const GOST_FIELDS = [T('DEST_IP', 'Destination (abroad) IP', {full: true}), SEL('PORT_MODE', 'Port mode', ['manual', 'range']),
  T('PORTS', 'Ports CSV (manual mode)', {full: true}), T('RANGE_START', 'Range start'), T('RANGE_END', 'Range end'), SEL('PROTO', 'Forward protocol', ['tcp', 'udp', 'grpc'])];
const FIELDS = {
  asnative: {
    eu: [T('IRAN_IP', 'Iran server IP', {full: true}), T('BRIDGE', 'Bridge port', {ph: '7000'}), T('SYNC', 'Sync port', {ph: '7001'})],
    iran: [T('BRIDGE', 'Bridge port', {ph: '7000'}), T('SYNC', 'Sync port', {ph: '7001'}),
      SEL('AUTO_SYNC', 'Auto-sync ports from the abroad side', ['true', 'false']), T('PORTS', 'Manual ports CSV (when auto-sync is false)', {full: true})]},
  backhaul: {
    eu: [T('TOKEN', 'Shared token', {full: true, gen: 1}), SEL('TRANSPORT', 'Transport', ['tcp', 'ws', 'wss']), T('BIND_PORT', 'Control port (listens)'),
      T('FORWARD_PORTS', 'Ports to forward (CSV)', {full: true})],
    iran: [T('TOKEN', 'Shared token', {full: true, gen: 1}), SEL('TRANSPORT', 'Transport', ['tcp', 'ws', 'wss']), T('SERVER_IP', 'Abroad server IP'), T('BIND_PORT', "Control port (of the server)")]},
  rathole: {
    eu: [T('TOKEN', 'Shared token', {full: true, gen: 1}), T('BIND_PORT', 'Control port (listens)'), T('FORWARD_PORTS', 'Ports to expose (CSV)', {full: true})],
    iran: [T('TOKEN', 'Shared token', {full: true, gen: 1}), T('SERVER_IP', 'Abroad server IP'), T('BIND_PORT', 'Control port (of the server)'),
      T('FORWARD_PORTS', 'Local ports to forward (CSV)', {full: true})]},
  frp: {
    eu: [T('TOKEN', 'Shared token', {full: true, gen: 1}), T('BIND_PORT', 'Control port (listens)')],
    iran: [T('TOKEN', 'Shared token', {full: true, gen: 1}), T('SERVER_IP', 'Abroad server IP'), T('BIND_PORT', 'Control port (of the server)'),
      T('FORWARD_PORTS', 'Ports to forward (CSV)', {full: true})]},
  gre: {eu: GRE_FIELDS, iran: GRE_FIELDS},
  gost: {eu: GOST_FIELDS, iran: GOST_FIELDS},
  paqet: {
    eu: [T('SERVER_PORT', 'Tunnel port (listens)', {ph: '8888'}), T('SECRET_KEY', 'Secret key', {full: true, gen: 1}), SEL('KCP_MODE', 'KCP mode', KCP_MODES),
      SEL('BLOCK', 'Encryption', KCP_BLOCKS), T('CONN', 'Connections (1-32)', {ph: '4'}), T('MTU', 'MTU', {ph: '1150'}), T('ROUTER_MAC', 'Router MAC (blank = auto)', {full: true})],
    iran: [T('SERVER_IP', 'Abroad server IP'), T('SERVER_PORT', 'Tunnel port (of the server)', {ph: '8888'}), T('SECRET_KEY', 'Secret key', {full: true, gen: 1}),
      SEL('KCP_MODE', 'KCP mode', KCP_MODES), SEL('BLOCK', 'Encryption', KCP_BLOCKS), T('CONN', 'Connections (1-32)', {ph: '4'}), T('MTU', 'MTU', {ph: '1150'}),
      T('FORWARD_PORTS', 'TCP ports to forward (CSV)', {full: true}), T('FORWARD_UDP_PORTS', 'UDP ports to forward (CSV)', {full: true}),
      T('SOCKS5_PORT', 'SOCKS5 port'), T('SOCKS5_USER', 'SOCKS5 user'), T('SOCKS5_PASS', 'SOCKS5 password'), T('ROUTER_MAC', 'Router MAC (blank = auto)', {full: true})]}
};
/* Parameters asked when linking two panel nodes — keys/IPs are filled in automatically. */
const LINK_PARAMS = {
  asnative: [T('bridge', 'Bridge port', {v: '7000'}), T('sync', 'Sync port', {v: '7001'})],
  backhaul: [T('port', 'Control port', {rand: 1}), SEL('transport', 'Transport', ['tcp', 'ws', 'wss']), T('forward_ports', 'Ports to forward (CSV)', {full: true, ph: '443,8080'})],
  rathole: [T('port', 'Control port', {rand: 1}), T('forward_ports', 'Ports to expose (CSV)', {full: true, ph: '443,8080'})],
  frp: [T('port', 'Control port', {rand: 1}), T('forward_ports', 'Ports to forward (CSV)', {full: true, ph: '443,8080'})],
  gre: [],
  gost: [T('forward_ports', 'Ports to forward (CSV)', {full: true, ph: '443,8080'}), SEL('proto', 'Forward protocol', ['tcp', 'udp', 'grpc'])],
  paqet: [T('port', 'Tunnel port', {rand: 1}), SEL('kcp_mode', 'KCP mode', KCP_MODES), SEL('block', 'Encryption', KCP_BLOCKS),
    T('forward_ports', 'TCP ports to forward (CSV)', {full: true, ph: '443,8080'}), T('forward_udp_ports', 'UDP ports to forward (CSV)', {full: true})]
};
const cleanName = v => (v || '').toLowerCase().replace(/[^a-z0-9_-]/g, '').slice(0, 32);
const randHex = n => Array.from(crypto.getRandomValues(new Uint8Array(n)), b => b.toString(16).padStart(2, '0')).join('');
const randPort = () => 20000 + Math.floor(Math.random() * 40000);
function genInto(id) { $(id).value = randHex(16); }

function openNew(mode) { openSlot(null, mode || 'manual'); }
function openSlotByName(prof) { openSlot((cur().tunnels || []).find(x => x.prof === prof) || null); }
function setRole(role) { $('roleSelect').value = role === 'iran' ? 'iran' : 'eu'; paintSide(); }
function paintSide() { $('sideTxt').textContent = sideLabel($('roleSelect').value); $('sideNode').textContent = '· ' + (cur() ? cur().name : ''); }
function openSlot(existing, mode) {
  CURRENT = {prof: existing ? existing.prof : '', isNew: !existing, mode: existing ? 'manual' : (mode || 'manual')};
  $('mTitle').textContent = existing ? existing.prof : t('newTunnel');
  $('modeSeg').classList.toggle('hidden', !!existing);
  paintStatus(existing ? !!existing.running : false, !!existing);
  setMsg('', ''); $('lkSteps').innerHTML = ''; mTab('config');
  const nm = $('nameInput'); nm.value = existing ? existing.prof : ''; nm.disabled = !!existing;
  $('methodSelect').value = existing ? existing.method : 'asnative';
  setRole(existing ? existing.role : (cur().role || 'eu'));
  $('rcToggle').checked = false; $('rcHours').value = '';
  setMode(CURRENT.mode);
  const target = S.sel;
  if (existing) {
    napi('/slots/' + encodeURIComponent(existing.prof)).then(d => {
      if (target !== S.sel || !CURRENT || CURRENT.prof !== existing.prof) return;
      if (d.role) { setRole(d.role); renderFields(); }
      if (d.fields) fillFields(d.fields);
      if (d.restart_hours) { $('rcToggle').checked = true; $('rcHours').value = d.restart_hours; }
    }).catch(() => {});
  }
  $('slotModal').classList.remove('hidden');
}
function closeModal() { stopLive(); $('slotModal').classList.add('hidden'); CURRENT = null; }
function setMode(mode) {
  if (!CURRENT) return; CURRENT.mode = mode;
  $('mdManual').classList.toggle('on', mode === 'manual'); $('mdLink').classList.toggle('on', mode === 'link');
  $('manualBox').classList.toggle('hidden', mode !== 'manual'); $('linkBox').classList.toggle('hidden', mode !== 'link');
  setMsg('', '');
  if (mode === 'manual') renderFields(); else initLink();
}
function onMethodChange() { if (!CURRENT) return; if (CURRENT.mode === 'link') renderLinkParams(); else renderFields(); }
function fieldDefsFor() { const m = $('methodSelect').value, role = $('roleSelect').value; return (FIELDS[m] || {})[role] || []; }
function inputHtml(f, prefix) {
  const id = prefix + f.k;
  if (f.t === 'select') return '<select class="mono" id="' + id + '">' + f.opts.map(o => '<option value="' + o + '">' + o + '</option>').join('') + '</select>';
  const inp = '<input class="mono" id="' + id + '" type="text" placeholder="' + esc(f.ph || '') + '">';
  return f.gen ? '<div class="row">' + inp + '<span class="icobtn" title="generate" onclick="genInto(\'' + id + '\')">↻</span></div>' : inp;
}
function renderFields() {
  const box = $('fieldsBox'); box.innerHTML = '<div class="fgrid"></div>'; const grid = box.firstChild;
  fieldDefsFor().forEach(f => {
    const w = document.createElement('div'); if (f.full) w.className = 'full';
    w.innerHTML = '<label class="f">' + esc(f.l) + '</label>' + inputHtml(f, 'f_'); grid.appendChild(w);
  });
}
/* ---- link two nodes from the panel ---- */
function onlineNodes() { return S.nodes.filter(n => n.online); }
function initLink() {
  const nodes = onlineNodes(), opts = n => '<option value="' + esc(n.id) + '">' + esc(n.name) + ' — ' + esc(n.public_ip || '?') + '</option>';
  const sv = nodes.find(n => n.role === 'eu') || nodes[0], cl = nodes.find(n => n.role === 'iran' && (!sv || n.id !== sv.id)) || nodes.find(n => !sv || n.id !== sv.id);
  $('lkServer').innerHTML = nodes.map(opts).join(''); $('lkClient').innerHTML = nodes.map(opts).join('');
  if (sv) $('lkServer').value = sv.id; if (cl) $('lkClient').value = cl.id;
  lkNodeChanged(); renderLinkParams();
  $('lkBtn').disabled = nodes.length < 2; if (nodes.length < 2) setMsg(t('lkNeed'), 'err');
}
function lkNodeChanged() {
  const sv = S.nodes.find(n => n.id === $('lkServer').value), cl = S.nodes.find(n => n.id === $('lkClient').value);
  $('lkSIp').value = sv ? (sv.public_ip || '') : ''; $('lkCIp').value = cl ? (cl.public_ip || '') : '';
}
function renderLinkParams() {
  const m = $('methodSelect').value, box = $('lkParams'); box.innerHTML = '<div class="fgrid"></div>'; const grid = box.firstChild;
  (LINK_PARAMS[m] || []).forEach(f => {
    const w = document.createElement('div'); if (f.full) w.className = 'full';
    w.innerHTML = '<label class="f">' + esc(f.l) + '</label>' + inputHtml(f, 'lk_'); grid.appendChild(w);
    const el = $('lk_' + f.k); if (el && f.rand) el.value = randPort(); else if (el && f.v) el.value = f.v;
  });
  $('lkNote').textContent = t(m === 'gost' ? 'lkNoteGost' : 'lkNote');
}
function linkParams() {
  const out = {}; (LINK_PARAMS[$('methodSelect').value] || []).forEach(f => { const el = $('lk_' + f.k); if (el && el.value.trim() !== '') out[f.k] = el.value.trim(); });
  return out;
}
async function createLink() {
  const name = cleanName($('nameInput').value), server = $('lkServer').value, client = $('lkClient').value, method = $('methodSelect').value;
  if (!name) { setMsg(t('enterName'), 'err'); return; }
  if (!server || !client || server === client) { setMsg(t('pickDiff'), 'err'); return; }
  const has = id => ((S.nodes.find(n => n.id === id) || {}).tunnels || []).some(x => x.prof === name);
  if ((has(server) || has(client)) && !confirm(t('overwrite', {n: name}))) return;
  const btn = $('lkBtn'); btn.disabled = true; setMsg('⏳ …', ''); $('lkSteps').innerHTML = '';
  try {
    const r = await api('/api/link', {method: 'POST', body: {name, method, server, client, server_ip: $('lkSIp').value.trim(), client_ip: $('lkCIp').value.trim(), params: linkParams()}});
    $('lkSteps').innerHTML = (r.steps || []).map(s => '<li>' + (s.running ? '✅' : (s.saved ? '⚠️' : '❌')) + ' ' + (s.side === 'server' ? t('sideEu') : t('sideIran')) + ' — <b>' + esc(s.node) + '</b>'
      + (s.error ? '<br><span class="muted mono" style="font-size:12px">' + esc(s.error) + '</span>' : '') + '</li>').join('');
    if (r.ok) { setMsg(t('lkOk'), 'ok'); toast(t('lkOk'), 'ok'); }
    else if (r.saved) { setMsg(t('lkPartial'), 'err'); toast(t('lkPartial'), 'err'); }
    else { setMsg((r.rolled_back ? t('lkRolled') + '\n' : '') + errText(r), 'err'); toast(t('failed'), 'err'); }
    await refreshNodes(); reloadTunnels();
  } catch (e) { if (e.message !== 'unauthorized') setMsg('✖ ' + e.message, 'err'); }
  finally { btn.disabled = false; }
}
function fillFields(fields) { Object.keys(fields).forEach(k => { const el = $('f_' + k); if (el) el.value = fields[k]; }); }
function collectFields() {
  const out = {}; fieldDefsFor().forEach(f => { const el = $('f_' + f.k); if (el && el.value !== '') out[f.k] = el.value; });
  const rk = ROLE_KEY_OF[$('methodSelect').value]; if (rk) out[rk] = $('roleSelect').value === 'eu' ? 'server' : 'client';
  return out;
}
function setMsg(text, kind) { const el = $('mMsg'); el.textContent = text || ''; el.className = 'msg ' + (kind || ''); }
function setBusy(on, label) {
  ['saveBtn', 'startBtn', 'stopBtn', 'restartBtn'].forEach(id => { $(id).disabled = on; });
  const sb = $('saveBtn'), sp = sb.querySelector('span');
  if (on && label) { sb.dataset.l = sp.textContent; sp.textContent = '⏳ ' + label; }
  if (!on && sb.dataset.l) { sp.textContent = sb.dataset.l; delete sb.dataset.l; }
}
function paintStatus(running, known) { $('mSub').textContent = known === false ? t('newTunnel') : (running ? '🟢 ' + t('running') : '🔴 ' + t('stopped')); }
async function refreshSlotState() {
  await reloadTunnels();
  if (!CURRENT || !CURRENT.prof) return null;
  const d = await napi('/slots/' + encodeURIComponent(CURRENT.prof));
  if (d && !d.error) { paintStatus(!!d.running); return d; } return null;
}
async function saveSlot() {
  const method = $('methodSelect').value, role = $('roleSelect').value, fields = collectFields();
  if (CURRENT.isNew) {
    const nm = cleanName($('nameInput').value);
    if (!nm) { setMsg(t('enterName'), 'err'); return; }
    if ((cur().tunnels || []).some(x => x.prof === nm) && !confirm(t('overwrite', {n: nm}))) return;
    CURRENT.prof = nm; CURRENT.isNew = false; $('nameInput').value = nm; $('nameInput').disabled = true; $('mTitle').textContent = nm;
  }
  setBusy(true, t('saveStart')); setMsg('…', '');
  try {
    const res = await napi('/slots/' + encodeURIComponent(CURRENT.prof), {method: 'POST', body: {method, role, fields}});
    await refreshSlotState();
    const tm = new Date().toLocaleTimeString();
    if (res.ok) { setMsg(t('savedRunning') + '  (' + tm + ')', 'ok'); toast(t('savedOk'), 'ok'); }
    else if (res.saved) { setMsg(t('savedNotRunning') + '\n' + errText(res), 'err'); toast(t('savedNotRunning'), 'err'); }
    else { setMsg(t('saveFailed') + '\n' + errText(res), 'err'); toast(t('saveFailed'), 'err'); }
  } catch (e) { if (e.message !== 'unauthorized') setMsg('✖ ' + e.message, 'err'); }
  finally { setBusy(false); }
}
async function doAction(action) {
  if (!CURRENT || !CURRENT.prof) return;
  setBusy(true); setMsg(action + '…', '');
  try {
    const res = await napi('/slots/' + encodeURIComponent(CURRENT.prof) + '/' + action, {method: 'POST'});
    await refreshSlotState();
    if (res.ok) { setMsg('✔ ' + action, 'ok'); toast('✔ ' + action, 'ok'); } else { setMsg('✖ ' + action + '\n' + errText(res), 'err'); toast(action + ' ✖', 'err'); }
  } catch (e) { if (e.message !== 'unauthorized') setMsg('✖ ' + e.message, 'err'); }
  finally { setBusy(false); }
}
async function deleteSlot() {
  if (!CURRENT || !CURRENT.prof || !confirm(t('deleteConfirm', {n: CURRENT.prof}))) return;
  const res = await napi('/slots/' + encodeURIComponent(CURRENT.prof), {method: 'DELETE'});
  if (res.ok) { toast('✔', 'ok'); closeModal(); reloadTunnels(); } else toast(errText(res), 'err');
}
async function saveRestartCron() {
  if (!CURRENT || !CURRENT.prof) { setMsg(t('enterName'), 'err'); return; }
  const enabled = $('rcToggle').checked, hours = $('rcHours').value || '6';
  const res = await napi('/slots/' + encodeURIComponent(CURRENT.prof) + '/restartcron', {method: 'POST', body: {enabled, hours}});
  if (res.ok) { setMsg('✔ ' + (enabled ? hours + 'h' : 'off'), 'ok'); toast(t('savedOk'), 'ok'); } else { setMsg(errText(res), 'err'); toast(t('failed'), 'err'); }
}
function mTab(name) {
  document.querySelectorAll('.mtab').forEach(b => b.classList.toggle('on', b.dataset.mt === name));
  $('mConfig').classList.toggle('hidden', name !== 'config'); $('mLog').classList.toggle('hidden', name !== 'log');
  if (name === 'log') { refreshLog(true); startLive(); } else stopLive();
}
function startLive() { stopLive(); if ($('liveToggle').checked) LIVE_TIMER = setInterval(() => refreshLog(false), 2500); }
function stopLive() { if (LIVE_TIMER) { clearInterval(LIVE_TIMER); LIVE_TIMER = null; } }
async function refreshLog(force) {
  if (!CURRENT || !CURRENT.prof) { $('logsBox').textContent = ''; return; }
  const box = $('logsBox'), prof = CURRENT.prof;
  try {
    const res = await napi('/slots/' + encodeURIComponent(prof) + '/logs?lines=' + $('logLines').value);
    if (!CURRENT || CURRENT.prof !== prof) return;
    const near = box.scrollHeight - box.scrollTop - box.clientHeight < 60;
    box.textContent = res.logs || errText(res) || '…';
    if (force || near) box.scrollTop = box.scrollHeight;
    if (typeof res.running === 'boolean') paintStatus(res.running);
    $('logStamp').textContent = new Date().toLocaleTimeString();
  } catch (e) {}
}

/* ============================ language ============================ */
function applyLang() {
  document.documentElement.lang = LANG; document.documentElement.dir = LANG === 'fa' ? 'rtl' : 'ltr';
  document.querySelectorAll('[data-i]').forEach(e => { e.textContent = t(e.dataset.i); });
  $('lgEn').classList.toggle('on', LANG === 'en'); $('lgFa').classList.toggle('on', LANG === 'fa');
  document.title = t('appTitle');
  S.barKey = ''; S.tunKey = ''; S.spKey = ''; S.pgKey = '';
  if (PG.timer) $('pgBtn').innerHTML = '■ <span>' + t('pgStop') + '</span>';
  if ($('app').classList.contains('hidden') === false) { renderAll(true); if (S.join) loadJoin(); }
}
function setLang(l) { LANG = l; localStorage.setItem('as_lang', l); applyLang(); }

/* ============================ init ============================ */
$('pIn').addEventListener('keydown', e => { if (e.key === 'Enter') doLogin(); });
$('uIn').addEventListener('keydown', e => { if (e.key === 'Enter') $('pIn').focus(); });
buildSwatches(); applyLang(); boot();
</script>
</body>
</html>
HTMLEOF
  chmod 644 "$WEBPANEL_DIR/index.html"
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

# ======================= Master panel + node agent =======================
# One master panel (run it on the abroad server) shows and controls every node.
# Nodes (Iran or abroad) run a tiny agent that connects OUT to the master.

wp_q(){ printf "'%s'" "${1//\'/}"; }

# Every value is single-quoted: PASSWORD_HASH contains '$', which would otherwise be
# re-interpreted the next time this file is `source`d (and crash under `set -u`).
write_webpanel_env(){
  local panel_ip https port username phash cert key network role secret
  panel_ip="$1"; https="$2"; port="$3"; username="$4"; phash="$5"; cert="$6"; key="$7"
  network="$8"; role="$9"; secret="${10}"
  mkdir -p "$BASE"
  {
    printf 'PANEL_IP=%s\n' "$(wp_q "$panel_ip")"
    printf 'HTTPS=%s\n' "$(wp_q "$https")"
    printf 'PORT=%s\n' "$(wp_q "$port")"
    printf 'USERNAME=%s\n' "$(wp_q "$username")"
    printf 'PASSWORD_HASH=%s\n' "$(wp_q "$phash")"
    printf 'CERT_FILE=%s\n' "$(wp_q "$cert")"
    printf 'KEY_FILE=%s\n' "$(wp_q "$key")"
    printf 'NETWORK_NAME=%s\n' "$(wp_q "$network")"
    printf 'MASTER_ROLE=%s\n' "$(wp_q "$role")"
    printf 'SECRET_KEY=%s\n' "$(wp_q "$secret")"
  } > "$WEBPANEL_ENV"
  chmod 600 "$WEBPANEL_ENV"
}

wp_get(){
  [[ -f "$WEBPANEL_ENV" ]] || { echo ""; return 0; }
  ( set +u; source "$WEBPANEL_ENV" >/dev/null 2>&1 || true; printf '%s' "${!1:-}" )
}

wp_update(){
  local k v pip https port user ph cert key net role sec
  k="$1"; v="$2"
  pip="$(wp_get PANEL_IP)"; https="$(wp_get HTTPS)"; port="$(wp_get PORT)"; user="$(wp_get USERNAME)"
  ph="$(wp_get PASSWORD_HASH)"; cert="$(wp_get CERT_FILE)"; key="$(wp_get KEY_FILE)"
  net="$(wp_get NETWORK_NAME)"; role="$(wp_get MASTER_ROLE)"; sec="$(wp_get SECRET_KEY)"
  case "$k" in
    PANEL_IP) pip="$v" ;; HTTPS) https="$v" ;; PORT) port="$v" ;; USERNAME) user="$v" ;;
    PASSWORD_HASH) ph="$v" ;; CERT_FILE) cert="$v" ;; KEY_FILE) key="$v" ;;
    NETWORK_NAME) net="$v" ;; MASTER_ROLE) role="$v" ;; SECRET_KEY) sec="$v" ;;
  esac
  write_webpanel_env "$pip" "$https" "$port" "$user" "$ph" "$cert" "$key" "$net" "$role" "$sec"
}

gen_secret(){ head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 48; }
port_in_use(){ ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"; }

make_selfsigned_cert(){
  local ip dir
  ip="$1"; dir="$WEBPANEL_DIR/certs"
  mkdir -p "$dir"
  have openssl || apt_try_install openssl
  openssl req -x509 -newkey rsa:2048 -keyout "$dir/key.pem" -out "$dir/cert.pem" \
    -days 3650 -nodes -subj "/CN=${ip:-A,S-tunnel}" >/dev/null 2>&1
  chmod 600 "$dir/key.pem" 2>/dev/null || true
  echo "$dir/cert.pem|$dir/key.pem"
}

cert_fingerprint(){
  local c
  c="$(wp_get CERT_FILE)"
  if [[ -n "$c" && -f "$c" ]]; then
    openssl x509 -in "$c" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f'
  fi
}

# Asks for the panel login. Sets PU (username), PP (password), PP_GENERATED.
prompt_panel_credentials(){
  local u p p2
  PP_GENERATED=0
  while true; do
    read -r -p "Panel username (3-32 chars: letters, digits . _ -): " u < /dev/tty
    if [[ "$u" =~ ^[A-Za-z0-9._-]{3,32}$ ]]; then break; fi
    echo -e "${CLR_RED}Invalid username.${CLR_RESET}" > "$TTY_OUT"
  done
  while true; do
    read -r -s -p "Panel password (min 8 chars, Enter = generate one): " p < /dev/tty
    echo "" > "$TTY_OUT"
    if [[ -z "$p" ]]; then p="$(gen_password)"; PP_GENERATED=1; break; fi
    if [[ ${#p} -lt 8 ]]; then echo -e "${CLR_RED}Too short (min 8 characters).${CLR_RESET}" > "$TTY_OUT"; continue; fi
    read -r -s -p "Repeat password: " p2 < /dev/tty
    echo "" > "$TTY_OUT"
    if [[ "$p" == "$p2" ]]; then break; fi
    echo -e "${CLR_RED}Passwords do not match.${CLR_RESET}" > "$TTY_OUT"
  done
  PU="$u"; PP="$p"
}

ensure_flask(){
  have python3 || apt_try_install python3
  if ! python3 -c "import flask, werkzeug, itsdangerous" >/dev/null 2>&1; then
    echo "[*] Installing Flask..." > "$TTY_OUT"
    apt_try_install python3-flask
    if ! python3 -c "import flask, werkzeug, itsdangerous" >/dev/null 2>&1; then
      have pip3 || apt_try_install python3-pip
      pip3 install --break-system-packages flask >/dev/null 2>&1 || pip3 install flask >/dev/null 2>&1 || true
    fi
  fi
  python3 -c "import flask, werkzeug, itsdangerous" >/dev/null 2>&1
}

write_webpanel_unit(){
  rm -f "/etc/systemd/system/A,S-webpanel.service" 2>/dev/null || true
  cat > "$WEBPANEL_SERVICE" <<EOF
[Unit]
Description=A,S Tunnel Master Web Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=ENV_FILE=$WEBPANEL_ENV
Environment=STATE_DIR=$MASTER_DIR
Environment=INSTALL_PATH=$INSTALL_PATH
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/env python3 "$WEBPANEL_DIR/app.py"
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
}

write_agent_unit(){
  cat > "$AGENT_SERVICE" <<EOF
[Unit]
Description=A,S Tunnel Node Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=AGENT_CFG=$AGENT_CFG
Environment=INSTALL_PATH=$INSTALL_PATH
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/env python3 "$WEBPANEL_DIR/agent.py" run
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

panel_join_summary(){
  local scheme ip port key fp
  scheme="http"; [[ "$(wp_get HTTPS)" == "true" ]] && scheme="https"
  ip="$(wp_get PANEL_IP)"; port="$(wp_get PORT)"
  key="$(cat "$MASTER_DIR/join.key" 2>/dev/null || true)"
  fp="$(cert_fingerprint || true)"
  echo -e "${CLR_YELLOW}${CLR_BOLD}Connect a node (Iran or abroad):${CLR_RESET}" > "$TTY_OUT"
  echo -e "  Master URL : ${CLR_CYAN}${scheme}://${ip}:${port}${CLR_RESET}" > "$TTY_OUT"
  echo -e "  Join key   : ${CLR_YELLOW}${key}${CLR_RESET}" > "$TTY_OUT"
  [[ -n "$fp" ]] && echo -e "  Fingerprint: ${CLR_DIM}${fp}${CLR_RESET}" > "$TTY_OUT"
  echo -e "  On the node: ${CLR_DIM}sudo A,S-tunnel --join '${scheme}://${ip}:${port}' '${key}' 'node-name' iran${fp:+ '$fp'}${CLR_RESET}" > "$TTY_OUT"
  echo -e "  ${CLR_DIM}(or menu → Master panel & nodes → Connect to a master)${CLR_RESET}" > "$TTY_OUT"
}

install_webpanel(){
  local user pass generated keep phash net net_in side detected ip_in panel_ip https https_in
  local port_def port port_in cert_file key_file pair secret scheme i
  echo "" > "$TTY_OUT"
  echo -e "${CLR_CYAN}${CLR_BOLD}━━ Master web panel setup ━━${CLR_RESET}" > "$TTY_OUT"
  echo -e "${CLR_DIM}Install this on the ABROAD server. Iran and abroad nodes connect to it and are managed from one dashboard.${CLR_RESET}" > "$TTY_OUT"
  echo "" > "$TTY_OUT"

  # 1) Login first.
  keep="n"; generated=0; pass=""; phash=""
  if [[ -f "$WEBPANEL_ENV" ]]; then
    read -r -p "A panel is already configured. Keep the current username/password? (y/n): " keep < /dev/tty
  fi
  if [[ "${keep,,}" == "y" && -f "$WEBPANEL_ENV" ]]; then
    user="$(wp_get USERNAME)"; phash="$(wp_get PASSWORD_HASH)"
  else
    prompt_panel_credentials
    user="$PU"; pass="$PP"; generated="$PP_GENERATED"
  fi

  # 2) Network name + which side the master itself is on.
  net="$(wp_get NETWORK_NAME)"; net="${net:-as-net}"
  read -r -p "Network name (Enter = ${net}): " net_in < /dev/tty
  net_in="$(printf '%s' "$net_in" | tr -cd 'A-Za-z0-9 ._-' | cut -c1-40)"
  net="${net_in:-$net}"
  echo -e "${CLR_DIM}Which side is THIS server?${CLR_RESET}" > "$TTY_OUT"
  side="$(pick_side)"

  # 3) Address / HTTPS / port.
  detected="$(get_public_ip)"
  read -r -p "Panel IP (Enter = ${detected:-auto}): " ip_in < /dev/tty
  panel_ip="${ip_in:-${detected:-$(wp_get PANEL_IP)}}"
  https="$(wp_get HTTPS)"
  read -r -p "Enable HTTPS with a self-signed certificate? Recommended (y/n, default y): " https_in < /dev/tty
  if [[ "${https_in,,}" == "n" ]]; then https="false"; else https="true"; fi
  port_def="$(wp_get PORT)"; port_def="${port_def:-$(gen_port)}"
  while true; do
    read -r -p "Panel port (Enter = ${port_def}): " port_in < /dev/tty
    port="${port_in:-$port_def}"
    if [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1024 && "$port" -le 65535 ]]; then
      if port_in_use "$port" && [[ "$port" != "$(wp_get PORT)" ]]; then
        echo -e "${CLR_RED}Port ${port} is already in use.${CLR_RESET}" > "$TTY_OUT"; continue
      fi
      break
    fi
    echo -e "${CLR_RED}Enter a port between 1024 and 65535.${CLR_RESET}" > "$TTY_OUT"
  done

  # 4) Everything below needs no more questions.
  if [[ ! -f "$INSTALL_PATH" ]]; then
    echo "[*] Installing the script system-wide first (the panel calls it)..." > "$TTY_OUT"
    install_script || true
  fi
  ensure_flask || { echo -e "${CLR_RED}[-] Could not install Flask (needs internet). Aborting.${CLR_RESET}" > "$TTY_OUT"; return 1; }
  if [[ -z "$phash" ]]; then
    phash="$(hash_password "$pass")"
    [[ -n "$phash" ]] || { echo -e "${CLR_RED}[-] Password hashing failed.${CLR_RESET}" > "$TTY_OUT"; return 1; }
  fi

  cert_file=""; key_file=""
  if [[ "$https" == "true" ]]; then
    cert_file="$(wp_get CERT_FILE)"; key_file="$(wp_get KEY_FILE)"
    if [[ ! -f "$cert_file" || ! -f "$key_file" ]]; then
      pair="$(make_selfsigned_cert "$panel_ip")"
      cert_file="${pair%|*}"; key_file="${pair#*|}"
    fi
  fi
  secret="$(wp_get SECRET_KEY)"; secret="${secret:-$(gen_secret)}"

  mkdir -p "$MASTER_DIR"; chmod 700 "$MASTER_DIR"
  if [[ ! -s "$MASTER_DIR/join.key" ]]; then
    gen_strong_token > "$MASTER_DIR/join.key"; chmod 600 "$MASTER_DIR/join.key"
  fi
  write_webpanel_env "$panel_ip" "$https" "$port" "$user" "$phash" "$cert_file" "$key_file" "$net" "$side" "$secret"
  write_webpanel_core; write_webpanel_app; write_webpanel_html
  write_webpanel_unit
  systemctl daemon-reload
  systemctl enable "$WEBPANEL_UNIT" >/dev/null 2>&1 || true
  systemctl restart "$WEBPANEL_UNIT" || true
  echo "$VERSION" > "$DEPLOY_STAMP"

  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if port_in_use "$port"; then break; fi
    sleep 0.5
  done
  if ! port_in_use "$port"; then
    echo -e "${CLR_RED}[-] The panel did not start. Last log lines:${CLR_RESET}" > "$TTY_OUT"
    journalctl -u "$WEBPANEL_UNIT" -n 15 --no-pager > "$TTY_OUT" 2>&1 || true
    return 1
  fi

  scheme="http"; [[ "$https" == "true" ]] && scheme="https"
  echo "" > "$TTY_OUT"
  echo -e "${CLR_GREEN}${CLR_BOLD}[+] Master panel is running.${CLR_RESET}" > "$TTY_OUT"
  echo -e "  URL      : ${CLR_CYAN}${scheme}://${panel_ip}:${port}/${CLR_RESET}" > "$TTY_OUT"
  echo -e "  Username : ${CLR_YELLOW}${user}${CLR_RESET}" > "$TTY_OUT"
  if [[ "$generated" == "1" ]]; then
    echo -e "  Password : ${CLR_YELLOW}${pass}${CLR_RESET}  ${CLR_DIM}(generated — write it down)${CLR_RESET}" > "$TTY_OUT"
  elif [[ -n "$pass" ]]; then
    echo -e "  Password : ${CLR_DIM}the one you just typed${CLR_RESET}" > "$TTY_OUT"
  fi
  [[ "$https" == "true" ]] && echo -e "  ${CLR_DIM}Self-signed certificate: the browser warns once — that's expected.${CLR_RESET}" > "$TTY_OUT"
  echo "" > "$TTY_OUT"
  panel_join_summary
  echo "" > "$TTY_OUT"
  echo -e "${CLR_DIM}Open port ${port}/tcp in the firewall of this server. Treat the panel like root access.${CLR_RESET}" > "$TTY_OUT"
}

need_panel(){
  if [[ ! -f "$WEBPANEL_ENV" ]]; then echo "[-] Master panel is not installed yet." > "$TTY_OUT"; return 1; fi
}

change_webpanel_credentials(){
  need_panel || return 0
  local phash
  echo -e "${CLR_DIM}Current username: $(wp_get USERNAME)${CLR_RESET}" > "$TTY_OUT"
  prompt_panel_credentials
  ensure_flask || { echo "[-] Flask is missing." > "$TTY_OUT"; return 1; }
  phash="$(hash_password "$PP")"
  [[ -n "$phash" ]] || { echo "[-] Password hashing failed." > "$TTY_OUT"; return 1; }
  wp_update USERNAME "$PU"
  wp_update PASSWORD_HASH "$phash"
  systemctl restart "$WEBPANEL_UNIT" >/dev/null 2>&1 || true
  echo -e "${CLR_GREEN}[+] Credentials updated — everyone is signed out.${CLR_RESET}" > "$TTY_OUT"
  echo -e "  Username: ${CLR_YELLOW}${PU}${CLR_RESET}" > "$TTY_OUT"
  [[ "$PP_GENERATED" == "1" ]] && echo -e "  Password: ${CLR_YELLOW}${PP}${CLR_RESET} ${CLR_DIM}(generated)${CLR_RESET}" > "$TTY_OUT"
}

reset_webpanel_credentials(){
  need_panel || return 0
  local u p phash
  u="$(gen_username)"; p="$(gen_password)"
  ensure_flask || { echo "[-] Flask is missing." > "$TTY_OUT"; return 1; }
  phash="$(hash_password "$p")"
  [[ -n "$phash" ]] || { echo "[-] Password hashing failed." > "$TTY_OUT"; return 1; }
  wp_update USERNAME "$u"
  wp_update PASSWORD_HASH "$phash"
  systemctl restart "$WEBPANEL_UNIT" >/dev/null 2>&1 || true
  echo -e "${CLR_GREEN}[+] Credentials reset.${CLR_RESET}" > "$TTY_OUT"
  echo -e "  Username: ${CLR_YELLOW}${u}${CLR_RESET}" > "$TTY_OUT"
  echo -e "  Password: ${CLR_YELLOW}${p}${CLR_RESET}" > "$TTY_OUT"
}

regen_join_key(){
  need_panel || return 0
  mkdir -p "$MASTER_DIR"; chmod 700 "$MASTER_DIR"
  gen_strong_token > "$MASTER_DIR/join.key"; chmod 600 "$MASTER_DIR/join.key"
  echo -e "${CLR_GREEN}[+] New join key created. Nodes that already joined stay connected.${CLR_RESET}" > "$TTY_OUT"
  panel_join_summary
}

show_webpanel_info(){
  need_panel || return 0
  local active scheme nodes
  active="inactive"; if systemctl is-active --quiet "$WEBPANEL_UNIT" 2>/dev/null; then active="active"; fi
  scheme="http"; [[ "$(wp_get HTTPS)" == "true" ]] && scheme="https"
  nodes="$(grep -c '"token_hash"' "$MASTER_DIR/nodes.json" 2>/dev/null || true)"
  echo -e "Status    : ${active}" > "$TTY_OUT"
  echo -e "URL       : ${scheme}://$(wp_get PANEL_IP):$(wp_get PORT)/" > "$TTY_OUT"
  echo -e "Username  : $(wp_get USERNAME)   ${CLR_DIM}(password is stored hashed — use 'Change' if forgotten)${CLR_RESET}" > "$TTY_OUT"
  echo -e "Network   : $(wp_get NETWORK_NAME)   Side: $(role_badge "$(wp_get MASTER_ROLE)")" > "$TTY_OUT"
  echo -e "Nodes     : ${nodes:-0} connected so far" > "$TTY_OUT"
  echo "" > "$TTY_OUT"
  panel_join_summary
}

disable_webpanel(){
  systemctl stop "$WEBPANEL_UNIT" >/dev/null 2>&1 || true
  systemctl disable "$WEBPANEL_UNIT" >/dev/null 2>&1 || true
  echo "[+] Master panel stopped and disabled (config and nodes kept)." > "$TTY_OUT"
}

uninstall_webpanel(){
  local c d
  read -r -p "Remove the master panel completely (service, files, credentials, node list)? (y/n): " c < /dev/tty
  [[ "${c,,}" == "y" ]] || { echo "Cancelled." > "$TTY_OUT"; return 0; }
  systemctl stop "$WEBPANEL_UNIT" >/dev/null 2>&1 || true
  systemctl disable "$WEBPANEL_UNIT" >/dev/null 2>&1 || true
  rm -f "$WEBPANEL_SERVICE" "/etc/systemd/system/A,S-webpanel.service" 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -f "$WEBPANEL_DIR/app.py" "$WEBPANEL_DIR/index.html" "$WEBPANEL_ENV" 2>/dev/null || true
  rm -rf "$WEBPANEL_DIR/certs" "$MASTER_DIR" 2>/dev/null || true
  if [[ ! -f "$AGENT_SERVICE" ]]; then rm -rf "$WEBPANEL_DIR" 2>/dev/null || true; fi
  echo "[+] Master panel removed." > "$TTY_OUT"
}

# ----------------------------- node agent -----------------------------
normalize_role(){
  case "${1,,}" in eu|abroad|server|kharej|foreign) echo "eu" ;; *) echo "iran" ;; esac
}

join_master(){
  local url key name role fp out ok
  url="${1%/}"; key="$2"; name="$3"; role="$(normalize_role "$4")"; fp="${5//[: ]/}"
  if [[ ! "$url" =~ ^https?://[^/[:space:]]+$ ]]; then
    echo -e "${CLR_RED}[-] Master URL must look like https://IP:PORT${CLR_RESET}" > "$TTY_OUT"; return 1
  fi
  if [[ -z "$key" ]]; then echo -e "${CLR_RED}[-] The join key is required.${CLR_RESET}" > "$TTY_OUT"; return 1; fi
  name="$(printf '%s' "$name" | tr -cd 'A-Za-z0-9 ._-' | cut -c1-40)"; name="${name:-node}"
  have python3 || apt_try_install python3
  if [[ ! -f "$INSTALL_PATH" ]]; then install_script || true; fi
  write_webpanel_core; write_agent_py
  local args
  args=(register --url "$url" --key "$key" --name "$name" --role "$role")
  if [[ -n "$fp" ]]; then args+=(--fp "$fp"); fi
  ok=0
  out="$(AGENT_CFG="$AGENT_CFG" INSTALL_PATH="$INSTALL_PATH" python3 "$WEBPANEL_DIR/agent.py" "${args[@]}" 2>&1)" || ok=$?
  if [[ $ok -ne 0 ]] || ! grep -q '"ok": true' <<<"$out"; then
    echo -e "${CLR_RED}[-] Could not join the master:${CLR_RESET} $out" > "$TTY_OUT"
    echo -e "${CLR_DIM}Check the URL/port is reachable from this server (firewall) and the join key is current.${CLR_RESET}" > "$TTY_OUT"
    return 1
  fi
  write_agent_unit
  systemctl daemon-reload
  systemctl enable "$AGENT_UNIT" >/dev/null 2>&1 || true
  systemctl restart "$AGENT_UNIT" || true
  echo "$VERSION" > "$DEPLOY_STAMP"
  echo -e "${CLR_GREEN}${CLR_BOLD}[+] Connected to the master as '${name}' ($(role_badge "$role")).${CLR_RESET}" > "$TTY_OUT"
  echo -e "${CLR_DIM}It should show as online in the master panel within a few seconds.${CLR_RESET}" > "$TTY_OUT"
}

connect_master(){
  local url key name role fp
  echo "" > "$TTY_OUT"
  echo -e "${CLR_CYAN}${CLR_BOLD}━━ Connect this server to a master ━━${CLR_RESET}" > "$TTY_OUT"
  echo -e "${CLR_DIM}Get the URL and join key from the master panel (Nodes tab) or its CLI menu.${CLR_RESET}" > "$TTY_OUT"
  read -r -p "Master URL (e.g. https://1.2.3.4:34567): " url < /dev/tty
  read -r -p "Join key: " key < /dev/tty
  read -r -p "Node name (Enter = $(hostname)): " name < /dev/tty
  name="${name:-$(hostname)}"
  echo -e "${CLR_DIM}Which side is THIS server?${CLR_RESET}" > "$TTY_OUT"
  role="$(pick_side)"
  read -r -p "Master TLS fingerprint (Enter = trust on first use): " fp < /dev/tty
  join_master "$url" "$key" "$name" "$role" "$fp"
}

agent_status(){
  if [[ ! -f "$AGENT_CFG" ]]; then echo "[i] This server is not connected to a master." > "$TTY_OUT"; return 0; fi
  local active
  active="inactive"; if systemctl is-active --quiet "$AGENT_UNIT" 2>/dev/null; then active="active"; fi
  echo -e "Agent service: ${active}" > "$TTY_OUT"
  python3 "$WEBPANEL_DIR/agent.py" status 2>/dev/null > "$TTY_OUT" || true
  journalctl -u "$AGENT_UNIT" -n 5 --no-pager 2>/dev/null > "$TTY_OUT" || true
}

disconnect_agent(){
  local c
  read -r -p "Disconnect this server from its master? (y/n): " c < /dev/tty
  [[ "${c,,}" == "y" ]] || { echo "Cancelled." > "$TTY_OUT"; return 0; }
  systemctl stop "$AGENT_UNIT" >/dev/null 2>&1 || true
  systemctl disable "$AGENT_UNIT" >/dev/null 2>&1 || true
  rm -f "$AGENT_SERVICE" "$AGENT_CFG" "$WEBPANEL_DIR/agent.py" 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  if [[ ! -f "$WEBPANEL_SERVICE" ]]; then rm -rf "$WEBPANEL_DIR" 2>/dev/null || true; fi
  echo "[+] Disconnected. (Remove the node in the master panel to forget it there.)" > "$TTY_OUT"
}

# Rewrites the panel/agent files from THIS script and restarts the services, so an
# updated script always updates the dashboard and every agent that runs from it.
refresh_services(){
  local did
  did=0
  if [[ -f "$WEBPANEL_SERVICE" ]]; then
    if [[ -f "$WEBPANEL_ENV" ]]; then
      [[ -n "$(wp_get SECRET_KEY)" ]] || wp_update SECRET_KEY "$(gen_secret)"
      [[ -n "$(wp_get NETWORK_NAME)" ]] || wp_update NETWORK_NAME "as-net"
      [[ -n "$(wp_get MASTER_ROLE)" ]] || wp_update MASTER_ROLE "eu"
    fi
    mkdir -p "$MASTER_DIR"; chmod 700 "$MASTER_DIR"
    write_webpanel_core; write_webpanel_app; write_webpanel_html; write_webpanel_unit
    did=1
  fi
  if [[ -f "$AGENT_SERVICE" ]]; then
    write_webpanel_core; write_agent_py; write_agent_unit
    did=1
  fi
  if [[ $did -eq 1 ]]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [[ -f "$WEBPANEL_SERVICE" ]]; then systemctl --no-block restart "$WEBPANEL_UNIT" >/dev/null 2>&1 || true; fi
    if [[ -f "$AGENT_SERVICE" ]]; then systemctl --no-block restart "$AGENT_UNIT" >/dev/null 2>&1 || true; fi
  fi
  mkdir -p "$BASE"
  echo "$VERSION" > "$DEPLOY_STAMP"
}

webpanel_menu(){
  local c ms as mcol acol
  while true; do
    ms="not installed"; mcol="${CLR_DIM}"
    if [[ -f "$WEBPANEL_SERVICE" ]]; then
      if systemctl is-active --quiet "$WEBPANEL_UNIT" 2>/dev/null; then ms="running"; mcol="${CLR_GREEN}"; else ms="stopped"; mcol="${CLR_RED}"; fi
    fi
    as="not connected"; acol="${CLR_DIM}"
    if [[ -f "$AGENT_SERVICE" ]]; then
      if systemctl is-active --quiet "$AGENT_UNIT" 2>/dev/null; then as="connected"; acol="${CLR_GREEN}"; else as="stopped"; acol="${CLR_RED}"; fi
    fi
    echo "" > "$TTY_OUT"
    echo -e "${CLR_CYAN}╔═════════════════════════════════════════════════╗${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_CYAN}║${CLR_RESET}  ${CLR_BOLD}🌐 Master panel & nodes${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_CYAN}╠═════════════════════════════════════════════════╣${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET} ${CLR_YELLOW}${CLR_BOLD}MASTER${CLR_RESET}  ${CLR_DIM}(abroad server)${CLR_RESET}  ${mcol}● ${ms}${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}   ${CLR_CYAN}1${CLR_RESET}) Install / reconfigure master panel" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}   ${CLR_CYAN}2${CLR_RESET}) Panel info  ${CLR_DIM}(URL · user · join key)${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}   ${CLR_CYAN}3${CLR_RESET}) Change username / password" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}   ${CLR_CYAN}4${CLR_RESET}) Reset to random credentials" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}   ${CLR_CYAN}5${CLR_RESET}) New join key for nodes" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}   ${CLR_CYAN}6${CLR_RESET}) Disable panel" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}   ${CLR_RED}7${CLR_RESET}) Uninstall panel" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET} ${CLR_YELLOW}${CLR_BOLD}NODE${CLR_RESET}  ${CLR_DIM}(Iran or abroad)${CLR_RESET}  ${acol}● ${as}${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}   ${CLR_CYAN}8${CLR_RESET}) Connect this server to a master" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}   ${CLR_CYAN}9${CLR_RESET}) Agent status" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}   ${CLR_RED}10${CLR_RESET}) Disconnect from master" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}   ${CLR_DIM}0) ↩ Back${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_CYAN}╚═════════════════════════════════════════════════╝${CLR_RESET}" > "$TTY_OUT"
    read -r -p "Select: " c < /dev/tty
    case "$c" in
      1) install_webpanel || true; pause ;;
      2) show_webpanel_info || true; pause ;;
      3) change_webpanel_credentials || true; pause ;;
      4) reset_webpanel_credentials || true; pause ;;
      5) regen_join_key || true; pause ;;
      6) disable_webpanel || true; pause ;;
      7) uninstall_webpanel || true; pause ;;
      8) connect_master || true; pause ;;
      9) agent_status || true; pause ;;
      10) disconnect_agent || true; pause ;;
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

manage_tunnels_menu(){
  local profiles n i p st role
  while true; do
    profiles=()
    while IFS= read -r n; do [[ -n "$n" ]] && profiles+=("$n"); done < <(list_profiles)
    if [[ ${#profiles[@]} -eq 0 ]]; then
      echo -e "${CLR_DIM}No tunnels yet — use “Add new tunnel” first.${CLR_RESET}" > "$TTY_OUT"
      pause
      return 0
    fi
    echo "" > "$TTY_OUT"
    echo -e "${CLR_DIM}┌───────────────────────────────────────────────────────────┐${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_BOLD}Your tunnels${CLR_RESET}  ${CLR_DIM}(● on  ● off)${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}├───────────────────────────────────────────────────────────┤${CLR_RESET}" > "$TTY_OUT"
    i=1
    for p in "${profiles[@]}"; do
      st="${CLR_RED}●${CLR_RESET}"; if is_running "$p" 2>/dev/null; then st="${CLR_GREEN}●${CLR_RESET}"; fi
      role="$(role_badge "$(get_role "$p")")"
      printf "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}%2s${CLR_RESET}) %b %-20s ${CLR_DIM}[%s]${CLR_RESET}  %s\n" \
        "$i" "$st" "$p" "$(get_method "$p")" "$role" > "$TTY_OUT"
      i=$((i+1))
    done
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_DIM}0) ↩ Back${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}└───────────────────────────────────────────────────────────┘${CLR_RESET}" > "$TTY_OUT"
    read -r -p "Select tunnel: " n < /dev/tty
    [[ "$n" == "0" ]] && return 0
    if [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -ge 1 ]] && [[ "$n" -le "${#profiles[@]}" ]]; then
      manage_slot_menu "${profiles[$((n-1))]}" || true
    else
      echo "Invalid." > "$TTY_OUT"
    fi
  done
}

manage_slot_menu(){
  local prof="$1"
  while true; do
    local st="${CLR_RED}● OFF${CLR_RESET}"; is_running "$prof" 2>/dev/null && st="${CLR_GREEN}● ON${CLR_RESET}"
    local rc; rc="$(get_slot_restart_hours "$prof")"
    local rc_label="${CLR_DIM}off${CLR_RESET}"; [[ -n "$rc" ]] && rc_label="${CLR_GREEN}every ${rc}h${CLR_RESET}"
    echo "" > "$TTY_OUT"
    echo -e "${CLR_DIM}┌───────────────────────────────────────────┐${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_YELLOW}${CLR_BOLD}${prof}${CLR_RESET}  ${CLR_DIM}[$(get_method "$prof")]${CLR_RESET}  $(role_badge "$(get_role "$prof")")  ${st}" > "$TTY_OUT"
    echo -e "${CLR_DIM}├───────────────────────────────────────────┤${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}1${CLR_RESET}) 📄 Show profile" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}2${CLR_RESET}) ▶️  Start" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}3${CLR_RESET}) ⏹  Stop" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}4${CLR_RESET}) 🔁 Restart" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}5${CLR_RESET}) 📊 Status" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}6${CLR_RESET}) 📜 Live log  ${CLR_DIM}(Ctrl+C to exit)${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}8${CLR_RESET}) ⏱  Scheduled restart  ${CLR_DIM}(${rc_label}${CLR_DIM})${CLR_RESET}" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}9${CLR_RESET}) ✏️  Change config" > "$TTY_OUT"
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_RED}7${CLR_RESET}) 🗑  Delete tunnel" > "$TTY_OUT"
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
valid_prof(){ [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]]; }

api_list(){
  echo "["
  local first=1 prof m running role
  while IFS= read -r prof; do
    [[ -n "$prof" ]] || continue
    m="$(get_method "$prof")"; role="$(get_role "$prof")"
    running=false; if is_running "$prof" 2>/dev/null; then running=true; fi
    [[ $first -eq 1 ]] || echo ","
    first=0
    printf '{%s,%s,%s,"running":%s}' "$(api_json_field prof "$prof")" "$(api_json_field role "$role")" \
      "$(api_json_field method "$m")" "$running"
  done < <(list_profiles)
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
  printf '{%s,%s,%s,"running":%s,%s,"fields":{' "$(api_json_field prof "$prof")" "$(api_json_field method "$m")" "$(api_json_field role "$(get_role "$prof")")" "$running" "$(api_json_field restart_hours "$rc")"
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
  valid_prof "$prof" || { echo '{"error":"bad_slot"}'; return 1; }
  local body; body="$(cat)"
  local method; method="$(printf '%s' "$body" | jq -r '.method // empty' 2>/dev/null)"
  [[ -n "$method" ]] || { echo '{"error":"missing_method"}'; return 1; }
  role="$(printf '%s' "$body" | jq -r '.role // empty' 2>/dev/null)"
  [[ "$role" == "eu" || "$role" == "iran" ]] || role="iran"

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


api_bulk(){
  local action fn prof total ok fail
  action="$1"
  case "$action" in
    start) fn="run_slot" ;; stop) fn="stop_slot" ;; restart) fn="restart_slot" ;;
    *) echo '{"error":"bad_action"}'; return 1 ;;
  esac
  total=0; ok=0; fail=0
  while IFS= read -r prof; do
    [[ -n "$prof" ]] || continue
    total=$((total+1))
    if "$fn" "$prof" >/dev/null 2>&1; then ok=$((ok+1)); else fail=$((fail+1)); fi
  done < <(list_profiles)
  printf '{"ok":true,"total":%s,"succeeded":%s,"failed":%s}\n' "$total" "$ok" "$fail"
}

api_nodeinfo(){
  local hc panel agent
  hc="$(crontab -l 2>/dev/null | grep -F "$HC_CRON_TAG" | sed -n 's#^\*/\([0-9]\+\) .*#\1#p' | head -n1 || true)"
  panel=false; [[ -f "$WEBPANEL_SERVICE" ]] && panel=true
  agent=false; [[ -f "$AGENT_SERVICE" ]] && agent=true
  printf '{%s,%s,"panel":%s,"agent":%s}\n' "$(api_json_field version "$VERSION")" "$(api_json_field hc_minutes "$hc")" "$panel" "$agent"
}

# Updates THIS script from its source URL, then refreshes the panel/agent files (detached,
# because the restart would otherwise kill the very process serving this request).
api_selfupdate(){
  local log ok
  ok=0
  log="$(update_script 2>&1)" || ok=$?
  if [[ $ok -eq 0 ]]; then
    ( sleep 3; exec "$INSTALL_PATH" --refresh-services ) >/dev/null 2>&1 < /dev/null &
    disown 2>/dev/null || true
    printf '{"ok":true,"log":%s}\n' "$(json_str "$log")"
  else
    printf '{"ok":false,"log":%s}\n' "$(json_str "$log")"
  fi
}

# ===================== Main =====================
need_root
ensure

case "${1:-}" in
  --join)
    shift
    join_master "${1:-}" "${2:-}" "${3:-$(hostname)}" "${4:-iran}" "${5:-}"
    exit $?
    ;;
  --refresh-services|--agent-refresh|--panel-refresh)
    refresh_services
    exit 0
    ;;
esac

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
    bulk)     api_bulk "${1:-}" ;;
    nodeinfo) api_nodeinfo ;;
    selfupdate) api_selfupdate ;;
    *) echo '{"error":"unknown_command"}' ;;
  esac
  exit 0
fi

# Internal entry point used by the cron health-check (see install_healthcheck_script).
if [[ "${1:-}" == "--healthcheck" ]]; then
  while IFS= read -r prof; do
    [[ -n "$prof" ]] || continue
    is_running "$prof" || run_slot "$prof" >/dev/null 2>&1 || true
  done < <(list_profiles)
  exit 0
fi

# One command is enough: first run installs itself system-wide, then goes
# straight into the menu (no separate "sudo A,S-tunnel" step needed).
if ! is_installed; then
  install_script >/dev/null 2>&1 || true
fi

# Running a newer copy (e.g. `bash <(curl ...)`) upgrades the installed one, and a script
# update always redeploys the dashboard / agent so they never lag behind the CLI.
if is_installed && [[ "$(readlink -f "$0" 2>/dev/null || echo "$0")" != "$(readlink -f "$INSTALL_PATH" 2>/dev/null)" ]]; then
  _iv="$(grep -m1 '^VERSION=' "$INSTALL_PATH" 2>/dev/null | cut -d'"' -f2 || true)"
  if [[ -n "$_iv" && "$_iv" != "$VERSION" && "$(printf '%s\n%s\n' "$_iv" "$VERSION" | sort -V | tail -n1)" == "$VERSION" ]]; then
    install_script >/dev/null 2>&1 || true
  fi
fi
if [[ "$(cat "$DEPLOY_STAMP" 2>/dev/null || true)" != "$VERSION" ]]; then
  refresh_services >/dev/null 2>&1 || true
fi

while true; do
  clear || true
  print_banner

  tcount="$(list_profiles | wc -l | tr -d ' ')"
  ron=0
  while IFS= read -r _p; do
    [[ -n "$_p" ]] && is_running "$_p" 2>/dev/null && ron=$((ron+1))
  done < <(list_profiles)
  B="${CLR_DIM}│${CLR_RESET}"
  echo -e "${CLR_CYAN}╔════════════════════════════════════════════════════╗${CLR_RESET}"
  echo -e "${CLR_CYAN}║${CLR_RESET}  ${CLR_BOLD}${CLR_WHITE}🚀 A,S Tunnel Manager${CLR_RESET}   ${CLR_DIM}${tcount} tunnel(s) · ${CLR_GREEN}${ron} running${CLR_RESET}"
  echo -e "${CLR_CYAN}╠════════════════════════════════════════════════════╣${CLR_RESET}"
  echo -e "${B} ${CLR_YELLOW}${CLR_BOLD}TUNNELS${CLR_RESET}"
  echo -e "${B}   ${CLR_CYAN}1${CLR_RESET}) ➕ Add new tunnel   ${CLR_DIM}(name + Server/Client)${CLR_RESET}"
  echo -e "${B}   ${CLR_CYAN}2${CLR_RESET}) 🎛  Manage tunnels   ${CLR_DIM}(start · stop · logs · config)${CLR_RESET}"
  echo -e "${B}"
  echo -e "${B} ${CLR_YELLOW}${CLR_BOLD}RELIABILITY & SPEED${CLR_RESET}"
  echo -e "${B}   ${CLR_CYAN}3${CLR_RESET}) ✅ Enable health-check cron"
  echo -e "${B}   ${CLR_CYAN}4${CLR_RESET}) ❌ Disable health-check cron"
  echo -e "${B}   ${CLR_CYAN}8${CLR_RESET}) ⚡ Optimize server   ${CLR_DIM}(BBR + sysctl hardening)${CLR_RESET}"
  echo -e "${B}"
  echo -e "${B} ${CLR_YELLOW}${CLR_BOLD}WEB & SCRIPT${CLR_RESET}"
  echo -e "${B}   ${CLR_CYAN}9${CLR_RESET}) 🌐 Master panel & nodes ${CLR_DIM}(web)${CLR_RESET}"
  echo -e "${B}   ${CLR_CYAN}5${CLR_RESET}) 📦 Install script   ${CLR_DIM}(system-wide)${CLR_RESET}"
  echo -e "${B}   ${CLR_CYAN}6${CLR_RESET}) 🔄 Update script"
  echo -e "${B}   ${CLR_CYAN}7${CLR_RESET}) 🗑  Uninstall script"
  echo -e "${B}"
  echo -e "${B}   ${CLR_RED}${CLR_BOLD}0${CLR_RESET}) 🚪 Exit"
  echo -e "${CLR_CYAN}╚════════════════════════════════════════════════════╝${CLR_RESET}"

  read -r -p "Select: " c < /dev/tty
  case "$c" in
    1) prof="$(prompt_tunnel_name)"; edit_profile "$prof" || true; pause ;;
    2) manage_tunnels_menu || true ;;
    3) enable_cron_healthcheck || true; pause ;;
    4) disable_cron_healthcheck || true; pause ;;
    5) install_script || true; pause ;;
    6) update_script || true; refresh_services || true; pause ;;
    7) uninstall_script || true; pause ;;
    8) optimize_server || true; pause ;;
    9) webpanel_menu || true ;;
    0) exit 0 ;;
    *) echo "Invalid."; sleep 1 ;;
  esac
done
