#!/usr/bin/env bash
set -euo pipefail

REPO="https://raw.githubusercontent.com/ariansaeedi56-prog/A-S-tunnel/main"
MANAGER_URL="$REPO/A,S-tunnel.sh"
PY_URL="$REPO/A,S.py"

BIN="/usr/local/bin/A,S-tunnel"
PY_DST="/opt/A,S/A,S.py"

MODE="${1:-minimal}"   # minimal | full

err() { echo "[!] $*" >&2; exit 1; }
info() { echo "[*] $*"; }
ok() { echo "[+] $*"; }

# root check
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  err "Please run as root: sudo bash install.sh"
fi

export DEBIAN_FRONTEND=noninteractive

info "Updating package lists..."
apt-get update -y >/dev/null 2>&1 || apt-get update >/dev/null 2>&1

# Minimal deps: run manager + core safely
BASE_DEPS=(curl ca-certificates python3 iproute2 screen)

# Full deps: features you added (cron/iptables/nft/haproxy/socat/ss)
FULL_DEPS=(cron iptables nftables haproxy socat)

info "Installing dependencies ($MODE)..."
if [[ "$MODE" == "full" ]]; then
  apt-get install -y "${BASE_DEPS[@]}" "${FULL_DEPS[@]}" >/dev/null 2>&1 || \
  apt-get install -y "${BASE_DEPS[@]}" "${FULL_DEPS[@]}"
else
  apt-get install -y "${BASE_DEPS[@]}" >/dev/null 2>&1 || \
  apt-get install -y "${BASE_DEPS[@]}"
fi

tmp_dir="$(mktemp -d)"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

info "Downloading manager..."
curl -fsSL "$MANAGER_URL" -o "$tmp_dir/A,S-tunnel" || err "Failed to download manager"

info "Downloading tunnel core..."
curl -fsSL "$PY_URL" -o "$tmp_dir/A,S.py" || err "Failed to download tunnel core (A,S.py)"

# sanity check: non-empty files
[[ -s "$tmp_dir/A,S-tunnel" ]] || err "Downloaded manager is empty"
[[ -s "$tmp_dir/A,S.py" ]] || err "Downloaded core is empty"

install -m 0755 "$tmp_dir/A,S-tunnel" "$BIN"
mkdir -p "$(dirname "$PY_DST")"
install -m 0755 "$tmp_dir/A,S.py" "$PY_DST"

echo ""
ok "Installation completed!"
echo ""
echo "Manager installed at: $BIN"
echo "Tunnel core installed at: $PY_DST"
echo ""
echo "Run it with:"
echo "sudo A,S-tunnel"
echo ""
echo "Tip:"
echo " - Minimal install: sudo bash install.sh"
echo " - Full install (all features deps): sudo bash install.sh full"
