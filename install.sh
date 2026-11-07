#!/usr/bin/env bash
# Copyright (c) 2026 A,S Tunnel (@Asnejad; GitHub: ariansaeedi56-prog). All rights reserved.
# See LICENSE for permitted use and restrictions.
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

# Keep unattended installs compatible with the previous behavior, while letting
# interactive users skip apt-get update when the package indexes are recent.
UPDATE_PACKAGE_LISTS="${AS_UPDATE_PACKAGE_LISTS:-yes}"
if [[ -z "${AS_UPDATE_PACKAGE_LISTS:-}" && -r /dev/tty ]]; then
  if ! read -r -p "[*] Update package lists before installing? [Y/n]: " UPDATE_PACKAGE_LISTS < /dev/tty; then
    UPDATE_PACKAGE_LISTS="yes"
  fi
fi

case "${UPDATE_PACKAGE_LISTS,,}" in
  ""|y|yes|1)
    info "Updating package lists (best effort)..."
    if ! apt-get update -y; then
      echo "[!] apt-get update failed; continuing with existing package indexes." >&2
    fi
    ;;
  n|no|0)
    info "Skipping package list update as requested."
    ;;
  *)
    err "Invalid AS_UPDATE_PACKAGE_LISTS value. Use yes or no."
    ;;
esac

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

# Refresh generated panel/agent files when updating an existing installation.
if [[ -f /etc/systemd/system/AS-webpanel.service || -f /etc/systemd/system/AS-agent.service ]]; then
  info "Refreshing installed web panel and agent..."
  "$BIN" --refresh-services || err "Manager was updated, but panel refresh failed"
fi

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
