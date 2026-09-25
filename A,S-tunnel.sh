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

WEBPANEL_DIR="/opt/A,S/webpanel"
WEBPANEL_ENV="$BASE/webpanel.env"
WEBPANEL_SERVICE="/etc/systemd/system/A,S-webpanel.service"

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

install_gost(){
  [[ -x "$BIN_DIR/gost" ]] && return 0
  echo "[*] Installing Gost..." > /dev/tty
  local arch; arch="$(detect_arch)"
  local url; url="$(gh_latest_asset_url "go-gost/gost" "linux_${arch}\\.tar\\.gz$")"
  [[ -n "$url" ]] || { echo "[-] Could not find a Gost release asset for linux_${arch}." > /dev/tty; return 1; }
  local tmp; tmp="$(mktemp -d)"
  fetch_url_to "$url" "$tmp/gost.tar.gz" || { rm -rf "$tmp"; return 1; }
  tar -xzf "$tmp/gost.tar.gz" -C "$tmp" 2>/dev/null || true
  find "$tmp" -maxdepth 2 -type f -iname "gost" -exec cp {} "$BIN_DIR/gost" \; 2>/dev/null || true
  chmod +x "$BIN_DIR/gost" 2>/dev/null || true
  rm -rf "$tmp"
  [[ -x "$BIN_DIR/gost" ]] || { echo "[-] Gost install failed." > /dev/tty; return 1; }
  echo "[+] Gost installed at $BIN_DIR/gost" > /dev/tty
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
  echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}6${CLR_RESET}) Gost         ${CLR_DIM}per-port IPv4/IPv6 forwarder${CLR_RESET}" > /dev/tty
  echo -e "${CLR_DIM}└───────────────────────────────────────────────────┘${CLR_RESET}" > /dev/tty
  read -r -p "Select [1-6]: " m < /dev/tty
  case "$m" in
    1) edit_profile_asnative "$prof" "$f" "$role" ;;
    2) edit_profile_backhaul "$prof" "$f" "$role" ;;
    3) edit_profile_rathole  "$prof" "$f" "$role" ;;
    4) edit_profile_gre      "$prof" "$f" "$role" ;;
    5) edit_profile_frp      "$prof" "$f" "$role" ;;
    6) edit_profile_gost     "$prof" "$f" "$role" ;;
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

edit_profile_gost(){
  local prof="$1" f="$2" role="$3"
  read -r -p "Destination (Kharej) IP — where traffic gets forwarded to: " DEST_IP < /dev/tty
  echo "1) Manual ports (comma separated)" > /dev/tty
  echo "2) Port range" > /dev/tty
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
  echo "1) tcp   2) udp   3) grpc" > /dev/tty
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
  echo "[+] Saved $f" > /dev/tty
}
edit_profile_gre(){
  local prof="$1" f="$2" role="$3"
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

gost_port_list(){
  local prof="$1" f="$CONF/${prof}.env"
  # shellcheck disable=SC1090
  source "$f"
  if [[ "${PORT_MODE:-manual}" == "range" ]]; then
    seq "$RANGE_START" "$RANGE_END"
  else
    csv_ports_to_array "$PORTS"
  fi
}

run_gost_slot(){
  local prof="$1" f="$CONF/${prof}.env"
  # shellcheck disable=SC1090
  source "$f"
  install_gost || return 1
  local args="" n=0 p
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    args+=" -L=${PROTO}://:${p}/[${DEST_IP}]:${p}"
    n=$((n+1))
  done < <(gost_port_list "$prof")
  [[ -n "$args" ]] || { echo "[-] No ports to forward." > /dev/tty; return 1; }
  local s; s="$(session_name "$prof")"
  screen -S "$s" -X quit >/dev/null 2>&1 || true
  screen -dmS "$s" bash -lc "'$BIN_DIR/gost'$args"
  echo "[+] Started: $s (gost, ${n} port(s) -> ${DEST_IP})" > /dev/tty
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
    gost)     run_gost_slot "$prof" ;;
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

write_webpanel_app(){
  cat > "$WEBPANEL_DIR/app.py" <<'PYEOF'
#!/usr/bin/env python3
import json, os, secrets, subprocess
from flask import Flask, request, jsonify, send_from_directory

APP_DIR = os.path.dirname(os.path.abspath(__file__))
INSTALL_PATH = os.environ.get("INSTALL_PATH", "/usr/local/bin/A,S-tunnel")
TOKEN = os.environ.get("TOKEN", "")
PORT = int(os.environ.get("PORT", "8088"))

app = Flask(__name__, static_folder=None)


def run_api(args, stdin_data=None):
    if not os.path.isfile(INSTALL_PATH):
        return {"error": "script_not_installed"}, 500
    cmd = [INSTALL_PATH, "--api"] + args
    try:
        p = subprocess.run(cmd, input=stdin_data, capture_output=True, text=True, timeout=60)
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
    if not TOKEN:
        return True
    supplied = request.headers.get("X-API-Key", "") or request.args.get("token", "")
    return secrets.compare_digest(supplied, TOKEN)


@app.before_request
def guard():
    if request.path.startswith("/api/") and not check_auth():
        return jsonify({"error": "unauthorized"}), 401


@app.get("/")
def index():
    return send_from_directory(APP_DIR, "index.html")


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
    data, code = run_api(["logs", prof])
    return jsonify(data), code


@app.post("/api/healthcheck")
def healthcheck():
    body = request.get_json(force=True, silent=True) or {}
    minutes = str(body.get("minutes", 1))
    data, code = run_api(["hc", "on" if body.get("enabled") else "off", minutes])
    return jsonify(data), code


@app.post("/api/optimize")
def optimize():
    data, code = run_api(["optimize"])
    return jsonify(data), code


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)
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
      radial-gradient(circle at 85% 80%, rgba(166,130,255,0.18), transparent 40%);
  }
  .wrap{position:relative; z-index:1; max-width:1100px; margin:0 auto; padding:20px 16px 60px}
  .glass{
    background:var(--glass); backdrop-filter:blur(18px); -webkit-backdrop-filter:blur(18px);
    border:1px solid var(--glass-brd); border-radius:18px;
    box-shadow:0 8px 32px rgba(0,0,0,0.35);
  }
  header.glass{padding:16px 20px; display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:10px; margin-bottom:18px}
  header h1{font-size:18px; margin:0; font-weight:700; letter-spacing:.3px}
  header .sub{font-size:12px; color:var(--dim); margin-top:2px}
  .pill{display:inline-flex; align-items:center; gap:6px; padding:5px 12px; border-radius:999px; font-size:12px; background:rgba(255,255,255,0.08); border:1px solid var(--glass-brd)}
  .dot{width:8px; height:8px; border-radius:50%}
  .dot.on{background:var(--green); box-shadow:0 0 8px var(--green)}
  .dot.off{background:var(--red); box-shadow:0 0 8px var(--red)}
  .dot.empty{background:rgba(255,255,255,0.25)}
  .cols{display:grid; grid-template-columns:1fr 1fr; gap:18px}
  @media (max-width:760px){.cols{grid-template-columns:1fr}}
  .col h2{font-size:14px; text-transform:uppercase; letter-spacing:1px; color:var(--dim); margin:0 0 10px 4px}
  .slot{
    padding:14px 16px; margin-bottom:10px; border-radius:14px; cursor:pointer;
    display:flex; justify-content:space-between; align-items:center; gap:10px;
    transition:transform .15s ease, background .15s ease;
  }
  .slot:hover{transform:translateY(-2px); background:rgba(255,255,255,0.11)}
  .slot .name{font-weight:600; font-size:14px}
  .slot .meta{font-size:11px; color:var(--dim); margin-top:2px}
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
  .gate .box{width:100%; max-width:360px; padding:28px}
  .footer-note{text-align:center; color:var(--dim); font-size:11px; margin-top:28px}
  .switch{position:relative; display:inline-block; width:42px; height:24px}
  .switch input{opacity:0; width:0; height:0}
  .slider{position:absolute; cursor:pointer; inset:0; background:rgba(255,255,255,0.15); border-radius:24px; transition:.2s}
  .slider:before{content:""; position:absolute; height:18px; width:18px; left:3px; top:3px; background:#fff; border-radius:50%; transition:.2s}
  input:checked + .slider{background:linear-gradient(135deg,var(--accent),var(--accent2))}
  input:checked + .slider:before{transform:translateX(18px)}
</style>
</head>
<body>

<div id="gate" class="gate">
  <div class="box glass">
    <h3 style="margin-top:0">🔐 A,S Tunnel Panel</h3>
    <p style="color:var(--dim); font-size:13px">Enter your access token to continue.</p>
    <input id="tokenInput" type="password" placeholder="Access token">
    <div class="btnrow"><button class="primary" style="width:100%" onclick="submitToken()">Unlock</button></div>
    <div id="gateError" style="color:var(--red); font-size:12px; margin-top:10px"></div>
  </div>
</div>

<div class="wrap hidden" id="app">
  <header class="glass">
    <div>
      <h1>🚀 A,S Tunnel</h1>
      <div class="sub" id="infoLine">loading…</div>
    </div>
    <div style="display:flex; gap:8px; align-items:center; flex-wrap:wrap">
      <span class="pill">🕒 Health check
        <label class="switch"><input type="checkbox" id="hcToggle" onchange="toggleHC()"><span class="slider"></span></label>
      </span>
      <button class="ghost" onclick="runOptimize()">🚀 Optimize</button>
      <button class="ghost" onclick="loadSlots()">⟳ Refresh</button>
    </div>
  </header>

  <div class="cols">
    <div class="col">
      <h2>🌍 EU</h2>
      <div id="euList"></div>
    </div>
    <div class="col">
      <h2>🇮🇷 IRAN</h2>
      <div id="iranList"></div>
    </div>
  </div>

  <div class="footer-note">A,S Tunnel Web Panel · keep this URL and token private</div>
</div>

<!-- Slot config modal -->
<div id="slotModal" class="modal-bg hidden">
  <div class="modal glass" style="position:relative">
    <span class="close" onclick="closeModal('slotModal')">✕</span>
    <h3 id="modalTitle">Slot</h3>
    <div class="sub" id="modalSub" style="color:var(--dim); font-size:12px; margin-bottom:6px"></div>

    <label>Protocol</label>
    <select id="methodSelect" onchange="renderFields()">
      <option value="asnative">A,S Native</option>
      <option value="backhaul">Backhaul</option>
      <option value="rathole">Rathole</option>
      <option value="gre">GRE</option>
      <option value="frp">FRP</option>
      <option value="gost">Gost</option>
    </select>

    <div id="fieldsBox"></div>

    <div class="btnrow">
      <button class="primary" onclick="saveSlot()">💾 Save & Start</button>
      <button onclick="doAction('start')">▶ Start</button>
      <button onclick="doAction('stop')">⏹ Stop</button>
      <button onclick="doAction('restart')">🔁 Restart</button>
    </div>
    <div class="btnrow">
      <button onclick="showLogs()">📜 Logs</button>
      <button class="danger" onclick="deleteSlot()">🗑 Delete</button>
    </div>
    <div id="slotMsg" style="font-size:12px; margin-top:10px; color:var(--dim)"></div>
  </div>
</div>

<!-- Logs modal -->
<div id="logsModal" class="modal-bg hidden">
  <div class="modal glass" style="position:relative">
    <span class="close" onclick="closeModal('logsModal')">✕</span>
    <h3>📜 Logs</h3>
    <pre class="logbox" id="logsBox">…</pre>
    <div class="btnrow"><button onclick="showLogs()">⟳ Refresh</button></div>
  </div>
</div>

<div id="toast" class="toast glass"></div>

<script>
let TOKEN = localStorage.getItem('as_token') || '';
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
  opts.headers = Object.assign({'Content-Type':'application/json','X-API-Key':TOKEN}, opts.headers||{});
  return fetch(path, opts).then(async r=>{
    const data = await r.json().catch(()=>({error:'bad_json'}));
    if(r.status===401){ showGate('Invalid or expired token.'); throw new Error('unauthorized'); }
    return data;
  });
}

function showGate(err){
  document.getElementById('gate').classList.remove('hidden');
  document.getElementById('app').classList.add('hidden');
  document.getElementById('gateError').textContent = err || '';
}
function submitToken(){
  TOKEN = document.getElementById('tokenInput').value.trim();
  localStorage.setItem('as_token', TOKEN);
  boot();
}

function toast(msg, isErr){
  const el = document.getElementById('toast');
  el.textContent = msg;
  el.style.background = isErr ? 'rgba(255,92,122,0.25)' : 'rgba(61,220,132,0.22)';
  el.classList.add('show');
  clearTimeout(el._t);
  el._t = setTimeout(()=>el.classList.remove('show'), 2600);
}

function closeModal(id){ document.getElementById(id).classList.add('hidden'); }

async function boot(){
  if(!TOKEN){ showGate(''); return; }
  try{
    const info = await api('/api/info');
    if(info.error){ showGate('Invalid token or server error.'); return; }
    document.getElementById('gate').classList.add('hidden');
    document.getElementById('app').classList.remove('hidden');
    document.getElementById('infoLine').textContent =
      `v${info.version || '?'} · ${info.location || 'Unknown'} · ${info.datacenter || 'Unknown'}`;
    loadSlots();
  }catch(e){ /* gate already shown */ }
}

async function loadSlots(){
  const data = await api('/api/slots');
  if(!Array.isArray(data)) return;
  SLOTS = data;
  renderList('eu'); renderList('iran');
}

function slotFor(role,i){ return SLOTS.find(s=>s.role===role && s.slot===i); }

function renderList(role){
  const box = document.getElementById(role+'List');
  box.innerHTML = '';
  for(let i=1;i<=10;i++){
    const s = slotFor(role,i);
    const div = document.createElement('div');
    div.className = 'slot glass';
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
  document.getElementById('modalSub').textContent = existing ? (existing.running ? '🟢 running' : '🔴 stopped') : 'new slot';
  document.getElementById('slotMsg').textContent = '';
  const sel = document.getElementById('methodSelect');
  sel.value = existing ? existing.method : 'asnative';
  renderFields(existing ? null : null);
  if(existing){
    api('/api/slots/'+CURRENT.prof).then(d=>{
      if(d.fields){ fillFields(d.fields); }
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

async function saveSlot(){
  const method = document.getElementById('methodSelect').value;
  const fields = collectFields();
  document.getElementById('slotMsg').textContent = 'Saving & starting…';
  const res = await api('/api/slots/'+CURRENT.prof, {method:'POST', body: JSON.stringify({method, fields})});
  if(res.ok){
    toast('Saved & started ✔');
    document.getElementById('slotMsg').textContent = 'Started successfully.';
    loadSlots();
  } else {
    toast('Save failed', true);
    document.getElementById('slotMsg').textContent = (res.log || res.error || 'Unknown error');
  }
}

async function doAction(action){
  const res = await api(`/api/slots/${CURRENT.prof}/${action}`, {method:'POST'});
  if(res.ok){ toast(action+' ok ✔'); loadSlots(); }
  else { toast(action+' failed', true); document.getElementById('slotMsg').textContent = res.log || res.error || ''; }
}

async function deleteSlot(){
  if(!confirm('Delete '+CURRENT.prof+'? This stops it and removes its config.')) return;
  const res = await api('/api/slots/'+CURRENT.prof, {method:'DELETE'});
  if(res.ok){ toast('Deleted'); closeModal('slotModal'); loadSlots(); }
  else { toast('Delete failed', true); }
}

async function showLogs(){
  document.getElementById('logsModal').classList.remove('hidden');
  document.getElementById('logsBox').textContent = 'Loading…';
  const res = await api('/api/slots/'+CURRENT.prof+'/logs');
  document.getElementById('logsBox').textContent = res.logs || res.error || '(empty)';
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

document.getElementById('tokenInput').addEventListener('keydown', e=>{ if(e.key==='Enter') submitToken(); });
boot();
</script>
</body>
</html>
HTMLEOF
}

install_webpanel(){
  echo "" > /dev/tty
  echo "[*] Setting up Web Panel..." > /dev/tty
  have python3 || apt_try_install python3
  python3 -c "import flask" >/dev/null 2>&1 || { pip3 install --break-system-packages flask >/dev/null 2>&1 || apt_try_install python3-flask; }

  mkdir -p "$WEBPANEL_DIR"

  local PORT="" TOKEN="" port token
  if [[ -f "$WEBPANEL_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$WEBPANEL_ENV"
  fi
  read -r -p "Panel port (default ${PORT:-8088}): " port < /dev/tty
  port="${port:-${PORT:-8088}}"
  if [[ -z "${TOKEN:-}" ]]; then
    token="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  else
    read -r -p "Keep existing access token? (y/n): " keep < /dev/tty
    if [[ "${keep,,}" == "n" ]]; then
      token="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    else
      token="$TOKEN"
    fi
  fi

  cat > "$WEBPANEL_ENV" <<EOF
PORT=$port
TOKEN=$token
EOF

  write_webpanel_app
  write_webpanel_html

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
  systemctl enable "A,S-webpanel" >/dev/null 2>&1 || true
  systemctl restart "A,S-webpanel"

  local ip; ip="$(get_public_ip)"
  echo "" > /dev/tty
  echo -e "${CLR_GREEN}[+] Web panel is running.${CLR_RESET}" > /dev/tty
  echo -e "URL:   ${CLR_CYAN}http://${ip:-<server-ip>}:${port}/${CLR_RESET}" > /dev/tty
  echo -e "Token: ${CLR_YELLOW}${token}${CLR_RESET}" > /dev/tty
  echo -e "${CLR_DIM}Keep this URL/token private — it's equivalent to root access. Restrict the port with a firewall where possible.${CLR_RESET}" > /dev/tty
}

disable_webpanel(){
  systemctl stop "A,S-webpanel" >/dev/null 2>&1 || true
  systemctl disable "A,S-webpanel" >/dev/null 2>&1 || true
  echo "[+] Web panel stopped and disabled (config kept)." > /dev/tty
}

show_webpanel_info(){
  if [[ ! -f "$WEBPANEL_ENV" ]]; then echo "[-] Web panel not installed yet." > /dev/tty; return; fi
  local PORT="" TOKEN=""
  # shellcheck disable=SC1090
  source "$WEBPANEL_ENV"
  local ip; ip="$(get_public_ip)"
  local active="inactive"
  systemctl is-active --quiet "A,S-webpanel" && active="active"
  echo -e "Status: ${active}" > /dev/tty
  echo -e "URL:    http://${ip:-<server-ip>}:${PORT}/" > /dev/tty
  echo -e "Token:  ${TOKEN}" > /dev/tty
}

webpanel_menu(){
  while true; do
    echo "" > /dev/tty
    echo -e "${CLR_DIM}┌───────────────────────────────────────┐${CLR_RESET}" > /dev/tty
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_BOLD}🌐 Web Panel${CLR_RESET}" > /dev/tty
    echo -e "${CLR_DIM}├───────────────────────────────────────┤${CLR_RESET}" > /dev/tty
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}1${CLR_RESET}) Install / Reconfigure" > /dev/tty
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}2${CLR_RESET}) Disable" > /dev/tty
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_CYAN}3${CLR_RESET}) Show URL & Token" > /dev/tty
    echo -e "${CLR_DIM}│${CLR_RESET}  ${CLR_DIM}0) Back${CLR_RESET}" > /dev/tty
    echo -e "${CLR_DIM}└───────────────────────────────────────┘${CLR_RESET}" > /dev/tty
    read -r -p "Select: " c < /dev/tty
    case "$c" in
      1) install_webpanel; pause ;;
      2) disable_webpanel; pause ;;
      3) show_webpanel_info; pause ;;
      0) return ;;
      *) echo "Invalid." > /dev/tty ;;
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
  local prof="$1" f="$CONF/${prof}.env"
  valid_prof "$prof" || { echo '{"error":"bad_slot"}'; return 1; }
  [[ -f "$f" ]] || { echo '{"error":"not_found"}'; return 1; }
  local m; m="$(get_method "$prof")"
  local running=false; is_running "$prof" 2>/dev/null && running=true
  printf '{%s,%s,"running":%s,"fields":{' "$(api_json_field prof "$prof")" "$(api_json_field method "$m")" "$running"
  local first=1 line k v
  while IFS='=' read -r k v; do
    [[ -n "$k" ]] || continue
    [[ "$k" == "METHOD" || "$k" == "ROLE" ]] && continue
    [[ $first -eq 1 ]] || printf ','
    first=0
    printf '%s' "$(api_json_field "$k" "$v")"
  done < "$f"
  echo "}}"
}

api_save(){
  local prof="$1" f="$CONF/${prof}.env" role="${prof%%[0-9]*}"
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

  local log; log="$(run_slot "$prof" 2>&1)"; local ok=$?
  if [[ $ok -eq 0 ]]; then echo '{"ok":true}'; else printf '{"ok":false,"log":%s}\n' "$(json_str "$log")"; fi
}

api_simple(){
  local action="$1" prof="$2"
  valid_prof "$prof" || { echo '{"error":"bad_slot"}'; return 1; }
  [[ -f "$CONF/${prof}.env" ]] || { echo '{"error":"not_found"}'; return 1; }
  local log; log="$("${action}_slot" "$prof" 2>&1)"; local ok=$?
  if [[ $ok -eq 0 ]]; then echo '{"ok":true}'; else printf '{"ok":false,"log":%s}\n' "$(json_str "$log")"; fi
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
  local prof="$1" m
  valid_prof "$prof" || { echo '{"error":"bad_slot"}'; return 1; }
  m="$(get_method "$prof")"
  local out
  if [[ "$m" == "gre" ]]; then
    out="$(ip -s link show "gre${prof}" 2>&1 || true)"
  else
    local s tmpf; s="$(session_name "$prof")"; tmpf="$(mktemp)"
    screen -S "$s" -X hardcopy "$tmpf" >/dev/null 2>&1 || true
    out="$(cat "$tmpf" 2>/dev/null || true)"
    rm -f "$tmpf"
  fi
  printf '{"logs":%s}\n' "$(json_str "$out")"
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
    logs)     api_logs "${1:-}" ;;
    hc)       api_hc "${1:-off}" "${2:-1}" ;;
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
    1) role="$(pick_role)"; prof="$(pick_slot "$role")"; edit_profile "$prof"; pause ;;
    2) role="$(pick_role)"; prof="$(pick_slot "$role")"; manage_slot_menu "$prof" ;;
    3) enable_cron_healthcheck; pause ;;
    4) disable_cron_healthcheck; pause ;;
    5) install_script; pause ;;
    6) update_script; pause ;;
    7) uninstall_script; pause ;;
    8) optimize_server; pause ;;
    9) webpanel_menu ;;
    0) exit 0 ;;
    *) echo "Invalid."; sleep 1 ;;
  esac
done
