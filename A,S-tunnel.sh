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


def local_view():
    tun = local_tunnels()
    total, running = tunnel_counts(tun)
    return {"id": "local", "is_local": True, "name": SETTINGS.get("local_name") or os.uname().nodename,
            "role": MASTER_ROLE, "online": True, "last_seen": 0, "remote_ip": "",
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
            "version": asnode.script_version(), "url": panel_url(), "role": MASTER_ROLE,
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
    if not name:
        return jsonify({"error": "bad_name"}), 400
    with LOCK:
        if nid == "local":
            SETTINGS["local_name"] = unique_name(name, skip="local")
            name = SETTINGS["local_name"]
        elif nid in NODES:
            NODES[nid]["name"] = unique_name(name, skip=nid)
            name = NODES[nid]["name"]
        else:
            return jsonify({"error": "node_not_found"}), 404
    save_registry()
    return jsonify({"ok": True, "name": name})


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
  --accent:#a855f7; --accent2:#c084fc;
  --bg:#06030d; --txt:#f5f2fc; --dim:#a69dbd; --faint:#6f6788;
  --green:#34d399; --red:#fb7185; --amber:#fbbf24; --blue:#38bdf8;
  --mono:ui-monospace,SFMono-Regular,"JetBrains Mono",Menlo,Consolas,monospace;
}
*{box-sizing:border-box}
html,body{margin:0;min-height:100%}
body{
  background:var(--bg); color:var(--txt);
  font-family:Inter,ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,Tahoma,Arial,sans-serif;
  font-size:14px; line-height:1.45;
  background-image:
    radial-gradient(900px 480px at 12% -8%, color-mix(in srgb,var(--accent) 16%,transparent), transparent 70%),
    radial-gradient(800px 460px at 100% 105%, color-mix(in srgb,var(--accent) 10%,transparent), transparent 70%);
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
.logo{width:56px;height:56px;border-radius:16px;display:grid;place-items:center;
  border:1px solid color-mix(in srgb,var(--accent) 35%,transparent);
  background:radial-gradient(circle at 30% 20%,color-mix(in srgb,var(--accent) 30%,#0b0618),#0b0618)}
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
    <div class="logo"><svg width="30" height="30" viewBox="0 0 32 32" fill="none" stroke="#c084fc" stroke-width="1.8"><circle cx="6" cy="6" r="2.6"/><circle cx="26" cy="6" r="2.6"/><circle cx="6" cy="26" r="2.6"/><circle cx="26" cy="26" r="2.6"/><circle cx="16" cy="16" r="3"/><path d="M8 8l5.5 5.5M24 8l-5.5 5.5M8 24l5.5-5.5M24 24l-5.5-5.5"/></svg></div>
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
      <div class="logo"><svg width="30" height="30" viewBox="0 0 32 32" fill="none" stroke="#c084fc" stroke-width="1.8"><circle cx="6" cy="6" r="2.6"/><circle cx="26" cy="6" r="2.6"/><circle cx="6" cy="26" r="2.6"/><circle cx="26" cy="26" r="2.6"/><circle cx="16" cy="16" r="3"/><path d="M8 8l5.5 5.5M24 8l-5.5 5.5M8 24l5.5-5.5M24 24l-5.5-5.5"/></svg></div>
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
        <button class="btn o-acc" onclick="openNew()">✨ <span data-i="wizard">Launch Setup Wizard</span></button>
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
        <div><label class="f" data-i="side">Side</label><input id="cfgSide" readonly></div>
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
        <button class="btn primary" style="margin-inline-start:auto" onclick="openNew()">➕ <span data-i="addTunnel">Add tunnel</span></button></div>
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
      <div class="fgrid">
        <div class="full"><label class="f" data-i="tName">Tunnel name</label><input id="nameInput" class="mono" maxlength="32" placeholder="server1"></div>
        <div><label class="f" data-i="side">Side</label><select id="roleSelect" onchange="renderFields()">
          <option value="eu">🌍 Server (Abroad / Kharej)</option><option value="iran">🇮🇷 Client (Iran)</option></select></div>
        <div><label class="f" data-i="protocol">Protocol</label><select id="methodSelect" onchange="renderFields()">
          <option value="asnative">A,S Native</option><option value="backhaul">Backhaul</option><option value="rathole">Rathole</option>
          <option value="gre">GRE</option><option value="frp">FRP</option><option value="gost">Gost</option><option value="paqet">Paqet</option></select></div>
      </div>
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
 savedRunning:'✔ Saved and running', savedNotRunning:'✔ Config saved, but the tunnel is not running:', saveFailed:'✖ Save failed', never:'never', ago:'{s}s ago', sideEu:'🌍 Server (Abroad)', sideIran:'🇮🇷 Client (Iran)'
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
 savedRunning:'✔ ذخیره شد و در حال اجراست', savedNotRunning:'✔ تنظیمات ذخیره شد، ولی تانل اجرا نشده:', saveFailed:'✖ ذخیره ناموفق بود', never:'هرگز', ago:'{s} ثانیه پیش', sideEu:'🌍 سرور (خارج)', sideIran:'🇮🇷 کلاینت (ایران)'
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
  $('cfgSide').value = sideLabel(n.role); $('cfgHost').value = n.hostname || ''; $('cfgIp').value = n.public_ip || ''; $('cfgId').value = n.id;
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
    if (name && name !== n.name) { const r = await napi('/rename', {method: 'POST', body: {name}}); if (!r.ok) throw r; }
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
const FIELD_DEFS = {
  asnative_eu: [{k:'IRAN_IP',l:'Iran IP',t:'text'},{k:'BRIDGE',l:'Bridge port',t:'text',ph:'7000'},{k:'SYNC',l:'Sync port',t:'text',ph:'7001'}],
  asnative_iran: [{k:'BRIDGE',l:'Bridge port',t:'text',ph:'7000'},{k:'SYNC',l:'Sync port',t:'text',ph:'7001'},
    {k:'AUTO_SYNC',l:'Auto-sync ports?',t:'select',opts:['true','false']},{k:'PORTS',l:'Manual ports (CSV, if auto-sync=false)',t:'text',full:true}],
  backhaul: [{k:'TOKEN',l:'Shared token',t:'text',full:true},{k:'TRANSPORT',l:'Transport',t:'select',opts:['tcp','ws','wss']},{k:'BIND_PORT',l:'Control port',t:'text'},
    {k:'SERVER_IP',l:'Server IP (client only)',t:'text'},{k:'FORWARD_PORTS',l:'Forward ports CSV (server only)',t:'text',full:true}],
  rathole: [{k:'TOKEN',l:'Shared token',t:'text',full:true},{k:'BIND_PORT',l:'Control port',t:'text'},{k:'SERVER_IP',l:'Server IP (client only)',t:'text'},
    {k:'FORWARD_PORTS',l:'Forward ports CSV',t:'text',full:true}],
  gre: [{k:'LOCAL_IP',l:'This host public IP',t:'text',full:true},{k:'PEER_IP',l:'Peer public IP',t:'text',full:true}],
  frp: [{k:'TOKEN',l:'Shared token',t:'text',full:true},{k:'BIND_PORT',l:'Control port',t:'text'},{k:'SERVER_IP',l:'Server IP (client only)',t:'text'},
    {k:'FORWARD_PORTS',l:'Forward ports CSV (client only)',t:'text',full:true}],
  paqet: [{k:'SERVER_PORT',l:'Tunnel port',t:'text',ph:'8888'},{k:'SECRET_KEY',l:'Secret key (same on both sides)',t:'text',full:true},
    {k:'SERVER_IP',l:'Server IP (client only)',t:'text',full:true},{k:'KCP_MODE',l:'KCP mode',t:'select',opts:['fast','normal','fast2','fast3']},
    {k:'BLOCK',l:'Encryption',t:'select',opts:['aes-128-gcm','aes','aes-128','aes-192','aes-256','none']},{k:'CONN',l:'Connections (1-32)',t:'text',ph:'4'},
    {k:'MTU',l:'MTU',t:'text',ph:'1150'},{k:'FORWARD_PORTS',l:'TCP ports to forward (client)',t:'text',full:true},
    {k:'FORWARD_UDP_PORTS',l:'UDP ports to forward (client)',t:'text',full:true},{k:'SOCKS5_PORT',l:'SOCKS5 port (client)',t:'text'},
    {k:'SOCKS5_USER',l:'SOCKS5 user',t:'text'},{k:'SOCKS5_PASS',l:'SOCKS5 password',t:'text'},{k:'ROUTER_MAC',l:'Router MAC (blank = auto)',t:'text',full:true}],
  gost: [{k:'DEST_IP',l:'Destination (Kharej) IP',t:'text',full:true},{k:'PORT_MODE',l:'Port mode',t:'select',opts:['manual','range']},
    {k:'PORTS',l:'Ports CSV (if manual)',t:'text',full:true},{k:'RANGE_START',l:'Range start (if range)',t:'text'},{k:'RANGE_END',l:'Range end (if range)',t:'text'},
    {k:'PROTO',l:'Forward protocol',t:'select',opts:['tcp','udp','grpc']}]
};
const cleanName = v => (v || '').toLowerCase().replace(/[^a-z0-9_-]/g, '').slice(0, 32);

function openNew() { openSlot(null); }
function openSlotByName(prof) { openSlot((cur().tunnels || []).find(x => x.prof === prof) || null); }
function openSlot(existing) {
  CURRENT = {prof: existing ? existing.prof : '', isNew: !existing};
  $('mTitle').textContent = existing ? existing.prof : t('newTunnel') + ' — ' + cur().name;
  paintStatus(existing ? !!existing.running : false, !!existing);
  setMsg('', ''); mTab('config');
  const nm = $('nameInput'); nm.value = existing ? existing.prof : ''; nm.disabled = !!existing;
  $('roleSelect').value = existing ? existing.role : (cur().role || 'eu');
  $('methodSelect').value = existing ? existing.method : 'asnative';
  renderFields(); $('rcToggle').checked = false; $('rcHours').value = '';
  const target = S.sel;
  if (existing) {
    napi('/slots/' + encodeURIComponent(existing.prof)).then(d => {
      if (target !== S.sel || !CURRENT || CURRENT.prof !== existing.prof) return;
      if (d.role) { $('roleSelect').value = d.role; renderFields(); }
      if (d.fields) fillFields(d.fields);
      if (d.restart_hours) { $('rcToggle').checked = true; $('rcHours').value = d.restart_hours; }
    }).catch(() => {});
  }
  $('slotModal').classList.remove('hidden');
}
function closeModal() { stopLive(); $('slotModal').classList.add('hidden'); CURRENT = null; }
function fieldDefsFor() {
  const m = $('methodSelect').value, role = $('roleSelect').value;
  return ((m === 'asnative') ? FIELD_DEFS['asnative_' + role] : FIELD_DEFS[m]).filter(f => !ROLE_KEYS.includes(f.k));
}
function renderFields() {
  const box = $('fieldsBox'); box.innerHTML = '<div class="fgrid"></div>'; const grid = box.firstChild;
  fieldDefsFor().forEach(f => {
    const w = document.createElement('div'); if (f.full) w.className = 'full';
    w.innerHTML = '<label class="f">' + esc(f.l) + '</label>' + (f.t === 'select'
      ? '<select class="mono" id="f_' + f.k + '">' + f.opts.map(o => '<option value="' + o + '">' + o + '</option>').join('') + '</select>'
      : '<input class="mono" id="f_' + f.k + '" type="text" placeholder="' + esc(f.ph || '') + '">');
    grid.appendChild(w);
  });
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
