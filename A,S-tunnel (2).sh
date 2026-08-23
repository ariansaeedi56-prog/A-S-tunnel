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
MAX=10

HC_SCRIPT="/usr/local/bin/A,S-health-check"
HC_CRON_TAG="# A,STunnelHealthCheck"

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
  local url="$1" out="$2"
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
  local repo="$1" pattern="$2"
  have jq || apt_try_install jq
  curl -fsSL -H "Accept: application/vnd.github+json" -H "User-Agent: A,S-tunnel" \
    "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
    | jq -r --arg p "$pattern" '.assets[]? | select(.name|test($p)) | .browser_download_url' \
    | head -n1
}

install_backhaul(){
  [[ -x "$BIN_DIR/backhaul" ]] && return 0
  echo "[*] Installing Backhaul..." > /dev/tty
  local arch; arch="$(detect_arch)"
  local url; url="$(gh_latest_asset_url "Musixal/Backhaul" "linux_${arch}\\.tar\\.gz$")"
  [[ -n "$url" ]] || { echo "[-] Could not find a Backhaul release asset for linux_${arch}." > /dev/tty; return 1; }
  local tmp; tmp="$(mktemp -d)"
  fetch_url_to "$url" "$tmp/bh.tar.gz" || { rm -rf "$tmp"; return 1; }
  tar -xzf "$tmp/bh.tar.gz" -C "$tmp" 2>/dev/null || true
  find "$tmp" -maxdepth 2 -type f -iname "backhaul*" ! -name "*.toml" ! -name "*.md" -exec cp {} "$BIN_DIR/backhaul" \; 2>/dev/null || true
  chmod +x "$BIN_DIR/backhaul" 2>/dev/null || true
  rm -rf "$tmp"
  [[ -x "$BIN_DIR/backhaul" ]] || { echo "[-] Backhaul install failed." > /dev/tty; return 1; }
  echo "[+] Backhaul installed at $BIN_DIR/backhaul" > /dev/tty
}

install_rathole(){
  [[ -x "$BIN_DIR/rathole" ]] && return 0
  echo "[*] Installing Rathole..." > /dev/tty
  local arch; arch="$(detect_arch)"
  local archname="x86_64"; [[ "$arch" == "arm64" ]] && archname="aarch64"
  local url="" suf ext
  for suf in "unknown-linux-musl" "unknown-linux-gnu"; do
    for ext in "zip" "tar\\.gz"; do
      url="$(gh_latest_asset_url "rapiz1/rathole" "${archname}-${suf}\\.${ext}$")"
      [[ -n "$url" ]] && break 2
    done
  done
  [[ -n "$url" ]] || { echo "[-] Could not find a rathole release asset for ${archname}." > /dev/tty; return 1; }
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
  [[ -x "$BIN_DIR/rathole" ]] || { echo "[-] Rathole install failed." > /dev/tty; return 1; }
  echo "[+] Rathole installed at $BIN_DIR/rathole" > /dev/tty
}

install_frp(){
  [[ -x "$BIN_DIR/frps" && -x "$BIN_DIR/frpc" ]] && return 0
  echo "[*] Installing FRP..." > /dev/tty
  local arch; arch="$(detect_arch)"
  local url; url="$(gh_latest_asset_url "fatedier/frp" "linux_${arch}\\.tar\\.gz$")"
  [[ -n "$url" ]] || { echo "[-] Could not find an FRP release asset for linux_${arch}." > /dev/tty; return 1; }
  local tmp; tmp="$(mktemp -d)"
  fetch_url_to "$url" "$tmp/frp.tar.gz" || { rm -rf "$tmp"; return 1; }
  tar -xzf "$tmp/frp.tar.gz" -C "$tmp" --strip-components=1 2>/dev/null || true
  [[ -f "$tmp/frps" && -f "$tmp/frpc" ]] || { echo "[-] FRP archive layout unexpected." > /dev/tty; rm -rf "$tmp"; return 1; }
  cp "$tmp/frps" "$BIN_DIR/frps"; cp "$tmp/frpc" "$BIN_DIR/frpc"
  chmod +x "$BIN_DIR/frps" "$BIN_DIR/frpc"
  rm -rf "$tmp"
  [[ -x "$BIN_DIR/frps" && -x "$BIN_DIR/frpc" ]] || { echo "[-] FRP install failed." > /dev/tty; return 1; }
  echo "[+] FRP installed at $BIN_DIR/frps, $BIN_DIR/frpc" > /dev/tty
}

is_installed(){ [[ -x "$INSTALL_PATH" ]]; }

ensure(){
  mkdir -p "$CONF"
  mkdir -p "$BIN_DIR"
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
    echo "[*] Python core not found. Downloading: $PY_URL" > /dev/tty
    fetch_url_to "$PY_URL" "$PY"
    chmod +x "$PY" || true
  fi
  [[ -f "$PY" ]] || { echo "Missing python file: $PY"; exit 1; }
}

install_script(){
  echo "[*] Installing to: $INSTALL_PATH" > /dev/tty
  mkdir -p "$(dirname "$INSTALL_PATH")"

  # If executed from a file path, copy it. Otherwise download from SELF_URL.
  if [[ -f "$0" ]] && [[ "$0" != "bash" ]] && [[ "$0" != "/dev/fd/"* ]]; then
    cp -f "$0" "$INSTALL_PATH"
  else
    fetch_url_to "$SELF_URL" "$INSTALL_PATH"
  fi
  chmod +x "$INSTALL_PATH"
  echo "[+] Installed. Run: sudo A,S-tunnel" > /dev/tty
}

update_script(){
  echo "[*] Updating from: $SELF_URL" > /dev/tty
  local tmp; tmp="$(mktemp)"
  fetch_url_to "$SELF_URL" "$tmp"

  if ! head -n 1 "$tmp" | grep -q "bash"; then
    echo "[-] Update failed: invalid file downloaded." > /dev/tty
    rm -f "$tmp"
    return 1
  fi
  chmod +x "$tmp"

  if is_installed; then
    mv -f "$tmp" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    echo "[+] Updated. Run again: sudo A,S-tunnel" > /dev/tty
  else
    mv -f "$tmp" "./${SCRIPT_FILENAME}"
    chmod +x "./${SCRIPT_FILENAME}"
    echo "[+] Updated file saved locally: ./${SCRIPT_FILENAME}" > /dev/tty
  fi
}

disable_cron_healthcheck(){
  local tmp; tmp="$(mktemp)"
  (crontab -l 2>/dev/null || true) | grep -vF "${HC_CRON_TAG}" >"$tmp" || true
  crontab "$tmp" || true
  rm -f "$tmp"
  echo "[+] Cron disabled." > /dev/tty
}

optimize_server(){
  echo "" > /dev/tty
  echo "[*] Optimizing network settings and enabling BBR if supported..." > /dev/tty

  # Ensure tools that are commonly missing on minimal images
  have sysctl  || apt_try_install procps
  have modprobe || apt_try_install kmod
  have ss || apt_try_install iproute2

  # Cron is optional but health-check uses crontab
  have crontab || apt_try_install cron

  # Try loading BBR module (no hard fail)
  modprobe tcp_bbr >/dev/null 2>&1 || true

  if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
    echo "[+] BBR is available." > /dev/tty

    # Apply runtime settings
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true

    # Persist settings (idempotent, separate file)
    local conf="/etc/sysctl.d/99-A,S-tunnel.conf"
    cat > "$conf" <<'EOF'
# A,S Tunnel - network tuning
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# Socket buffer ceilings (reasonable defaults)
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
EOF

    sysctl --system >/dev/null 2>&1 || sysctl -p >/dev/null 2>&1 || true

    echo "[+] Applied sysctl tuning." > /dev/tty
    echo "[i] tcp_congestion_control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" > /dev/tty
    echo "[i] default_qdisc:         $(sysctl -n net.core.default_qdisc 2>/dev/null)" > /dev/tty
  else
    echo "[!] BBR is NOT available on this kernel." > /dev/tty
    echo "[i] Available: $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo unknown)" > /dev/tty
    echo "[i] Hint: upgrade kernel to use BBR." > /dev/tty
  fi
}

uninstall_script(){
  disable_cron_healthcheck >/dev/null 2>&1 || true
  rm -f "$HC_SCRIPT" >/dev/null 2>&1 || true
  rm -f "$INSTALL_PATH" >/dev/null 2>&1 || true
  echo "[+] Uninstalled: $INSTALL_PATH" > /dev/tty
}

# Info (best-effort)
get_public_ip(){ curl -fsSL --max-time 3 https://api.ipify.org 2>/dev/null || true; }
get_ipinfo_field(){
  local field="$1" ip="$2"
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
    echo "" > /dev/tty
    echo -e "${CLR_DIM}┌───────────────────────────┐${CLR_RESET}" > /dev/tty
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_BOLD}Which side is this?${CLR_RESET}     ${CLR_DIM}│${CLR_RESET}" > /dev/tty
    echo -e "${CLR_DIM}├───────────────────────────┤${CLR_RESET}" > /dev/tty
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}1${CLR_RESET}) 🌍  EU (foreign)         ${CLR_DIM}│${CLR_RESET}" > /dev/tty
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}2${CLR_RESET}) 🇮🇷  IRAN                ${CLR_DIM}│${CLR_RESET}" > /dev/tty
    echo -e "${CLR_DIM}└───────────────────────────┘${CLR_RESET}" > /dev/tty
    read -r -p "Select: " x < /dev/tty
    if [[ "$x" == "1" ]]; then echo "eu"; return 0; fi
    if [[ "$x" == "2" ]]; then echo "iran"; return 0; fi
    echo -e "${CLR_RED}Invalid.${CLR_RESET}" > /dev/tty
  done
}
slot_status(){
  local role="$1" i="$2" prof="${role}${i}"
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
  local role="$1" title="EU"; [[ "$role" == "iran" ]] && title="IRAN"
  echo "" > /dev/tty
  echo -e "${CLR_DIM}┌───────────────────────────────────────┐${CLR_RESET}" > /dev/tty
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_BOLD}${title} slots${CLR_RESET}  ${CLR_DIM}(● on  ● off  ○ empty)${CLR_RESET}   ${CLR_DIM}│${CLR_RESET}" > /dev/tty
  echo -e "${CLR_DIM}├───────────────────────────────────────┤${CLR_RESET}" > /dev/tty
  for i in $(seq 1 "$MAX"); do
    printf "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}%2s${CLR_RESET}) %-6s  %b\n" "$i" "${role}${i}" "$(slot_status "$role" "$i")" > /dev/tty
  done
  echo -e "${CLR_DIM}└───────────────────────────────────────┘${CLR_RESET}" > /dev/tty
  read -r -p "Slot number: " slot < /dev/tty
  [[ "$slot" =~ ^[0-9]+$ ]] && [[ "$slot" -ge 1 ]] && [[ "$slot" -le "$MAX" ]] || { echo "Invalid"; exit 1; }
  echo "${role}${slot}"
}

# ===================== Tunnel method selection =====================

edit_profile(){
  local prof="$1" f="$CONF/${prof}.env" role="${prof%%[0-9]*}"
  echo "" > /dev/tty
  echo -e "${CLR_DIM}┌───────────────────────────────────────────────────┐${CLR_RESET}" > /dev/tty
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_YELLOW}${CLR_BOLD}⚙  Configuring: ${prof}${CLR_RESET}" > /dev/tty
  echo -e "${CLR_DIM}├───────────────────────────────────────────────────┤${CLR_RESET}" > /dev/tty
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}1${CLR_RESET}) A,S native   ${CLR_DIM}packet reverse tunnel (built-in)${CLR_RESET}" > /dev/tty
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}2${CLR_RESET}) Backhaul     ${CLR_DIM}TCP/WS/WSS multiplexed tunnel${CLR_RESET}" > /dev/tty
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}3${CLR_RESET}) Rathole      ${CLR_DIM}lightweight NAT-traversal tunnel${CLR_RESET}" > /dev/tty
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}4${CLR_RESET}) GRE          ${CLR_DIM}kernel-level IP tunnel${CLR_RESET}" > /dev/tty
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}5${CLR_RESET}) FRP          ${CLR_DIM}fast reverse proxy${CLR_RESET}" > /dev/tty
  echo -e "${CLR_DIM}└───────────────────────────────────────────────────┘${CLR_RESET}" > /dev/tty
  read -r -p "Select [1-5]: " m < /dev/tty
  case "$m" in
    1) edit_profile_asnative "$prof" "$f" "$role" ;;
    2) edit_profile_backhaul "$prof" "$f" "$role" ;;
    3) edit_profile_rathole  "$prof" "$f" "$role" ;;
    4) edit_profile_gre      "$prof" "$f" "$role" ;;
    5) edit_profile_frp      "$prof" "$f" "$role" ;;
    *) echo "Invalid." > /dev/tty; return 1 ;;
  esac

  if [[ -f "$f" ]]; then
    echo "" > /dev/tty
    echo -e "${CLR_CYAN}▶ Starting tunnel...${CLR_RESET}" > /dev/tty
    run_slot "$prof"
    echo "" > /dev/tty
    status_slot "$prof"
  fi
}

edit_profile_asnative(){
  local prof="$1" f="$2" role="$3"
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
  echo "[+] Saved $f" > /dev/tty
}

# Backhaul docs: the box you want to run in listening ("server") mode opens
# the control port + forwarded ports; the other box ("client") dials out to
# it. Ask explicitly rather than guessing from eu/iran, since either box can
# play either role depending on your firewall situation.
edit_profile_backhaul(){
  local prof="$1" f="$2" role="$3"
  echo "1) Server (listens; opens the control port + forwarded ports)" > /dev/tty
  echo "2) Client (dials out to the Server)" > /dev/tty
  read -r -p "This profile is: " bhr < /dev/tty
  read -r -p "Shared token (same on both sides): " TOKEN < /dev/tty
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
  echo "[+] Saved $f" > /dev/tty
}

edit_profile_rathole(){
  local prof="$1" f="$2" role="$3"
  echo "1) Server (public side, exposes the ports)" > /dev/tty
  echo "2) Client (behind NAT/filtering, forwards local services out)" > /dev/tty
  read -r -p "This profile is: " rtr < /dev/tty
  read -r -p "Shared token (same on both sides): " TOKEN < /dev/tty
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
  echo "[+] Saved $f" > /dev/tty
}

edit_profile_frp(){
  local prof="$1" f="$2" role="$3"
  echo "1) Server (frps, public side)" > /dev/tty
  echo "2) Client (frpc, dials out to the Server)" > /dev/tty
  read -r -p "This profile is: " fr < /dev/tty
  read -r -p "Shared token (same on both sides): " TOKEN < /dev/tty
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
  echo "[+] Saved $f" > /dev/tty
}

edit_profile_gre(){
  local prof="$1" f="$2" role="$3"
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
  echo "[+] Saved $f (GRE tunnel IP: $SELF_TUN_IP <-> $PEER_TUN_IP)" > /dev/tty
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
  local prof="$1" f="$CONF/${prof}.env" cfg="$CONF/${prof}.toml"
  # shellcheck disable=SC1090
  source "$f"
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
  local prof="$1" f="$CONF/${prof}.env" cfg="$CONF/${prof}.toml"
  # shellcheck disable=SC1090
  source "$f"
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
  local prof="$1" f="$CONF/${prof}.env" cfg="$CONF/${prof}.toml"
  # shellcheck disable=SC1090
  source "$f"
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

# ===================== Runtime control (per method) =====================

session_name(){ echo "A,S_$1"; }

get_method(){
  local prof="$1" f="$CONF/${prof}.env"
  [[ -f "$f" ]] || { echo "asnative"; return; }
  local m; m="$(grep -m1 '^METHOD=' "$f" | cut -d= -f2-)"
  echo "${m:-asnative}"
}

run_slot_asnative(){
  local prof="$1" f="$CONF/${prof}.env"
  # shellcheck disable=SC1090
  source "$f"
  local s; s="$(session_name "$prof")"
  screen -S "$s" -X quit >/dev/null 2>&1 || true

  if [[ "$ROLE" == "eu" ]]; then
    screen -dmS "$s" bash -lc "ulimit -Hn ${ULIMIT_NOFILE:-1048576} >/dev/null 2>&1 || true; ulimit -Sn ${ULIMIT_NOFILE:-1048576} >/dev/null 2>&1 || true; printf '1\n%s\n%s\n%s\n' '$IRAN_IP' '$BRIDGE' '$SYNC' | PAHLAVI_POOL=\"${PAHLAVI_POOL:-0}\" python3 '$PY'"
  else
    if [[ "${AUTO_SYNC:-true}" == "true" ]]; then
      screen -dmS "$s" bash -lc "ulimit -Hn ${ULIMIT_NOFILE:-1048576} >/dev/null 2>&1 || true; ulimit -Sn ${ULIMIT_NOFILE:-1048576} >/dev/null 2>&1 || true; printf '2\n%s\n%s\ny\n' '$BRIDGE' '$SYNC' | PAHLAVI_POOL=\"${PAHLAVI_POOL:-0}\" python3 '$PY'"
    else
      screen -dmS "$s" bash -lc "ulimit -Hn ${ULIMIT_NOFILE:-1048576} >/dev/null 2>&1 || true; ulimit -Sn ${ULIMIT_NOFILE:-1048576} >/dev/null 2>&1 || true; printf '2\n%s\n%s\nn\n%s\n' '$BRIDGE' '$SYNC' '${PORTS:-}' | PAHLAVI_POOL=\"${PAHLAVI_POOL:-0}\" python3 '$PY'"
    fi
  fi
  echo "[+] Started: $s (A,S native)" > /dev/tty
}

run_backhaul_slot(){
  local prof="$1"
  install_backhaul || return 1
  write_backhaul_config "$prof"
  local s; s="$(session_name "$prof")"
  screen -S "$s" -X quit >/dev/null 2>&1 || true
  screen -dmS "$s" bash -lc "'$BIN_DIR/backhaul' -c '$CONF/${prof}.toml'"
  echo "[+] Started: $s (backhaul)" > /dev/tty
}

run_rathole_slot(){
  local prof="$1" f="$CONF/${prof}.env"
  # shellcheck disable=SC1090
  source "$f"
  install_rathole || return 1
  write_rathole_config "$prof"
  local s flag; s="$(session_name "$prof")"
  [[ "$RT_ROLE" == "server" ]] && flag="--server" || flag="--client"
  screen -S "$s" -X quit >/dev/null 2>&1 || true
  screen -dmS "$s" bash -lc "'$BIN_DIR/rathole' $flag '$CONF/${prof}.toml'"
  echo "[+] Started: $s (rathole)" > /dev/tty
}

run_frp_slot(){
  local prof="$1" f="$CONF/${prof}.env"
  # shellcheck disable=SC1090
  source "$f"
  install_frp || return 1
  write_frp_config "$prof"
  local s bin; s="$(session_name "$prof")"
  [[ "$FRP_ROLE" == "server" ]] && bin="frps" || bin="frpc"
  screen -S "$s" -X quit >/dev/null 2>&1 || true
  screen -dmS "$s" bash -lc "'$BIN_DIR/$bin' -c '$CONF/${prof}.toml'"
  echo "[+] Started: $s (frp $FRP_ROLE)" > /dev/tty
}

run_gre_slot(){
  local prof="$1" f="$CONF/${prof}.env"
  # shellcheck disable=SC1090
  source "$f"
  local ifname="gre${prof}"
  ip link show "$ifname" >/dev/null 2>&1 && ip link del "$ifname" >/dev/null 2>&1 || true
  ip tunnel add "$ifname" mode gre remote "$PEER_IP" local "$LOCAL_IP" ttl 255
  ip link set "$ifname" up
  ip addr add "${SELF_TUN_IP}/30" dev "$ifname" 2>/dev/null || true
  echo "[+] GRE up: $ifname  ${SELF_TUN_IP} <-> ${PEER_TUN_IP}" > /dev/tty
  echo "[i] You can now route/NAT specific ports across this tunnel with iptables as needed." > /dev/tty
}
stop_gre_slot(){
  local prof="$1" ifname="gre${prof}"
  ip link del "$ifname" >/dev/null 2>&1 || true
  echo "[+] GRE down: $ifname" > /dev/tty
}
status_gre_slot(){
  local prof="$1" ifname="gre${prof}"
  if ip link show "$ifname" >/dev/null 2>&1; then
    echo -e "Profile: $prof | Method: gre | Interface: $ifname | Running: ${CLR_GREEN}ON${CLR_RESET}" > /dev/tty
  else
    echo -e "Profile: $prof | Method: gre | Running: ${CLR_RED}OFF${CLR_RESET}" > /dev/tty
  fi
}

is_running(){
  local prof="$1" m; m="$(get_method "$prof")"
  if [[ "$m" == "gre" ]]; then
    ip link show "gre${prof}" >/dev/null 2>&1
  else
    local s; s="$(session_name "$prof")"
    screen -ls 2>/dev/null | grep -q "\.${s}[[:space:]]"
  fi
}

run_slot(){
  local prof="$1" f="$CONF/${prof}.env"
  [[ -f "$f" ]] || { echo "Profile not found: $prof" > /dev/tty; return 1; }
  local m; m="$(get_method "$prof")"
  case "$m" in
    asnative) run_slot_asnative "$prof" ;;
    backhaul) run_backhaul_slot "$prof" ;;
    rathole)  run_rathole_slot "$prof" ;;
    frp)      run_frp_slot "$prof" ;;
    gre)      run_gre_slot "$prof" ;;
    *) echo "[-] Unknown method: $m" > /dev/tty; return 1 ;;
  esac
}

stop_slot(){
  local prof="$1" m; m="$(get_method "$prof")"
  if [[ "$m" == "gre" ]]; then
    stop_gre_slot "$prof"
  else
    local s; s="$(session_name "$prof")"
    screen -S "$s" -X quit >/dev/null 2>&1 || true
    echo "[+] Stopped: $s" > /dev/tty
  fi
}
restart_slot(){ local prof="$1"; stop_slot "$prof" >/dev/null 2>&1 || true; sleep 0.5; run_slot "$prof"; }
status_slot(){
  local prof="$1" f="$CONF/${prof}.env"
  [[ -f "$f" ]] || { echo "Profile not found: $prof" > /dev/tty; return 1; }
  local m; m="$(get_method "$prof")"
  if [[ "$m" == "gre" ]]; then
    status_gre_slot "$prof"
  else
    local st="${CLR_RED}OFF${CLR_RESET}"
    if is_running "$prof"; then st="${CLR_GREEN}ON${CLR_RESET}"; fi
    echo -e "Profile: $prof | Method: $m | Running: $st" > /dev/tty
  fi
}
delete_slot(){
  local prof="$1" f="$CONF/${prof}.env"
  stop_slot "$prof" >/dev/null 2>&1 || true
  rm -f "$CONF/${prof}.toml" >/dev/null 2>&1 || true
  if [[ -f "$f" ]]; then rm -f "$f"; echo "[+] Deleted: $f" > /dev/tty; else echo "[-] Not found: $f" > /dev/tty; fi
}
logs_slot(){
  local prof="$1" m; m="$(get_method "$prof")"
  if [[ "$m" == "gre" ]]; then
    echo "[i] GRE has no logs/screen session. Interface stats:" > /dev/tty
    ip -s link show "gre${prof}" 2>/dev/null > /dev/tty || echo "[-] Interface not up." > /dev/tty
  else
    local s; s="$(session_name "$prof")"
    echo "[i] Attach: $s (Ctrl+A then D)" > /dev/tty
    screen -r "$s" || true
  fi
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

  echo "" > /dev/tty
  read -r -p "Enter interval in minutes (default: 1): " interval < /dev/tty || true
  interval=${interval:-1}

  if ! [[ "$interval" =~ ^[0-9]+$ ]]; then
    echo "[!] Invalid number. Using default 1 minute." > /dev/tty
    interval=1
  fi
  if [ "$interval" -lt 1 ]; then interval=1; fi

  local line="*/$interval * * * * ${HC_SCRIPT} >/dev/null 2>&1 ${HC_CRON_TAG}"
  local tmp; tmp="$(mktemp)"
  (crontab -l 2>/dev/null || true) | grep -vF "${HC_CRON_TAG}" >"$tmp" || true
  echo "$line" >>"$tmp"
  crontab "$tmp"
  rm -f "$tmp"
  echo "[+] Cron enabled (every $interval minute(s))." > /dev/tty
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
    echo "" > /dev/tty
    echo -e "${CLR_DIM}┌───────────────────────────────────────────┐${CLR_RESET}" > /dev/tty
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_YELLOW}${CLR_BOLD}${prof}${CLR_RESET}  ${CLR_DIM}[$(get_method "$prof")]${CLR_RESET}  ${st}" > /dev/tty
    echo -e "${CLR_DIM}├───────────────────────────────────────────┤${CLR_RESET}" > /dev/tty
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}1${CLR_RESET}) 📄 Show profile" > /dev/tty
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}2${CLR_RESET}) ▶️  Start" > /dev/tty
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}3${CLR_RESET}) ⏹  Stop" > /dev/tty
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}4${CLR_RESET}) 🔁 Restart" > /dev/tty
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}5${CLR_RESET}) 📊 Status" > /dev/tty
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}6${CLR_RESET}) 📜 Logs" > /dev/tty
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_RED}7${CLR_RESET}) 🗑  Delete slot" > /dev/tty
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_DIM}0) ↩ Back${CLR_RESET}" > /dev/tty
    echo -e "${CLR_DIM}└───────────────────────────────────────────┘${CLR_RESET}" > /dev/tty
    read -r -p "Select: " c < /dev/tty
    case "$c" in
      1) cat "$CONF/${prof}.env" 2>/dev/null > /dev/tty || echo "Profile not found." > /dev/tty; pause ;;
      2) run_slot "$prof"; pause ;;
      3) stop_slot "$prof"; pause ;;
      4) restart_slot "$prof"; pause ;;
      5) status_slot "$prof"; pause ;;
      6) logs_slot "$prof" ;;
      7) delete_slot "$prof"; pause ;;
      0) return ;;
      *) echo "Invalid." > /dev/tty ;;
    esac
  done
}

# ===================== Main =====================
need_root
ensure

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
    1) role="$(pick_role)"; prof="$(pick_slot "$role")"; edit_profile "$prof"; pause ;;
    2) role="$(pick_role)"; prof="$(pick_slot "$role")"; manage_slot_menu "$prof" ;;
    3) enable_cron_healthcheck; pause ;;
    4) disable_cron_healthcheck; pause ;;
    5) install_script; pause ;;
    6) update_script; pause ;;
    7) uninstall_script; pause ;;
    8) optimize_server; pause ;;
    0) exit 0 ;;
    *) echo "Invalid."; sleep 1 ;;
  esac
done
