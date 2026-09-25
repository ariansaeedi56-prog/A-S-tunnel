# 🚀 A,S Tunnel

**Multi-Protocol Tunnel Manager for IR ⇄ EU Servers**
Multi-Slot • Multi-Protocol • AutoSync • Health Check • BBR Optimization

---

<p align="center">
  <b>Lightweight • Stable • Production Ready</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-3.0.0-cyan">
  <img src="https://img.shields.io/badge/protocols-6-brightgreen">
  <img src="https://img.shields.io/badge/slots-1--10-blue">
  <img src="https://img.shields.io/badge/license-MIT-lightgrey">
</p>

---

## 📌 Overview

**A,S Tunnel** is a unified tunnel manager that connects two servers:

- 🇮🇷 **IR** — Iran server
- 🌍 **EU** — Foreign / outside server

Instead of locking you into one tunneling technology, A,S Tunnel lets you pick — **per slot** — whichever protocol fits your situation, then handles installation, configuration, starting, stopping, health-checking, and auto-restart for you, all from one menu.

---

## 🧩 Supported Tunnel Protocols

| # | Protocol | Type | Best for |
|---|----------|------|----------|
| 1 | **A,S Native** | Reverse TCP (built-in, pooled connections) | Zero external dependency, dynamic auto-synced ports |
| 2 | **Backhaul** | TCP / WS / WSS multiplexed tunnel | High throughput, transport flexibility |
| 3 | **Rathole** | Lightweight NAT-traversal tunnel | Low overhead, many small services |
| 4 | **GRE** | Kernel-level IP tunnel | Raw IP-level connectivity, no userspace daemon |
| 5 | **FRP** | Fast reverse proxy | Battle-tested, widely used, rich proxy types |
| 6 | **Gost** | Per-port IPv4/IPv6 forwarder (tcp/udp/grpc) | Simple 1:1 port forwarding, huge port ranges |

Each slot remembers its own protocol, so you can run **A,S Native on slot `iran1`**, **Backhaul on `iran2`**, **Gost on `eu3`**, etc. — all at once, all managed from the same menu.

---

## 🧠 Architecture

```
Client → IR Server ⇄ EU Server
             │
     Protocol of your choice
   (A,S Native / Backhaul / Rathole
        / GRE / FRP / Gost)
```

Every slot is independent: pick a protocol, answer a short wizard, and the tunnel **starts automatically** — no extra "start" step needed.

---

## 🛠 Features

| Feature | Description |
|---------|--------------|
| 🔀 Multi-Protocol | Choose A,S Native / Backhaul / Rathole / GRE / FRP / Gost per slot |
| 🎛 Multi-Slot (1–10) | Store up to 10 independent tunnel configs per side |
| ⚡ Auto-Start | Tunnel starts immediately after you save its config |
| 🔄 AutoSync | Automatic port creation & synchronization (A,S Native) |
| 🕒 Cron Health Check | Auto-restarts any stopped tunnel, any protocol |
| 🚀 BBR Optimization | Congestion control + sysctl network tuning |
| 📦 Auto-Install | Official binaries for Backhaul / Rathole / FRP / Gost fetched straight from GitHub Releases |
| 🖥 systemd/cron Integration | Health check survives reboot via cron |
| 📊 Live Status | See which slots are running, and with which protocol, right in the menu |

---

## 📦 Installation

### 🟢 Step 1 — Setup IR Server

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ariansaeedi56-prog/A-S-tunnel/main/install.sh)
```

Once setup finishes, open the manager any time with:

```bash
sudo A,S-tunnel
```

### 🔵 Step 2 — Setup EU Server

Run the **same** install command on the EU server too:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ariansaeedi56-prog/A-S-tunnel/main/install.sh)
```

---

## 🎬 Creating a Tunnel

From the main menu:

```
1) 🛠 Create/Update profile
```

1. Choose the side: **EU** or **IRAN**
2. Choose a slot (**1–10**)
3. Choose a protocol (**1–6**, see table above)
4. Answer the protocol's short wizard
5. ✅ Done — the tunnel **starts automatically** and its status is shown right away

Repeat on the **other server** with matching values (same token/port where required).

---

### 1️⃣ A,S Native

| Field | EU side | IRAN side |
|---|---|---|
| Iran IP | ✅ required | — |
| Bridge port | ✅ (e.g. `7000`) | ✅ same value |
| Sync port | ✅ (e.g. `7001`) | ✅ same value |
| AutoSync | — | `y`/`n` |
| Manual ports | — | only if AutoSync = `n` |

No external binary — runs on the bundled `A,S.py` core.

---

### 2️⃣ Backhaul

| Field | Server role | Client role |
|---|---|---|
| Token | ✅ shared secret | ✅ same value |
| Transport | `tcp` / `ws` / `wss` | same value |
| Bind port | ✅ control port | — |
| Server IP | — | ✅ |
| Forward ports (CSV) | ✅ | — |

Binary is auto-downloaded from `Musixal/Backhaul` releases.

---

### 3️⃣ Rathole

| Field | Server role | Client role |
|---|---|---|
| Token | ✅ shared secret | ✅ same value |
| Bind port | ✅ control port | — |
| Server IP | — | ✅ |
| Forward ports (CSV) | ✅ (public, per-service) | ✅ same ports (local forward) |

Binary is auto-downloaded from `rapiz1/rathole` releases.

---

### 4️⃣ GRE (just iran use it)

| Field | Both sides |
|---|---|
| This host's public IP | ✅ |
| Peer public IP | ✅ |
| Tunnel IP | assigned automatically (`10.10.10.1` ↔ `10.10.10.2`) |

Pure kernel tunnel — no daemon, no extra binary. Combine with `iptables` for selective port routing.

---

### 5️⃣ FRP

| Field | Server (frps) | Client (frpc) |
|---|---|---|
| Token | ✅ shared secret | ✅ same value |
| Bind port | ✅ | ✅ (server's port) |
| Server IP | — | ✅ |
| Forward ports (CSV) | — | ✅ |

Binaries auto-downloaded from `fatedier/frp` releases.

---

### 6️⃣ Gost

| Field | Value |
|---|---|
| Destination (Kharej) IP | the server traffic gets forwarded to |
| Ports | manual CSV **or** a full range (e.g. `54,65000`) |
| Protocol | `tcp` / `udp` / `grpc` |

One-sided per-port forwarder — no matching config needed on the other end. Binary auto-downloaded from `go-gost/gost` releases.

---

## 🎛 Managing a Tunnel

```
2) 🎛 Manage tunnel
```

For any slot you get:

```
1) 📄 Show profile
2) ▶️  Start
3) ⏹  Stop
4) 🔁 Restart
5) 📊 Status
6) 📜 Logs
7) 🗑  Delete slot
```

Slot lists show live status at a glance: 🟢 running, 🔴 stopped, ⚪ empty — with the active protocol shown next to each.

---

## 🕒 Health Check (Cron)

```
3) ✅ Enable cron health-check
```

Pick an interval in minutes — any slot found stopped is automatically restarted with its own protocol, no matter which one it uses.

Disable any time with:

```
4) ❌ Disable cron health-check
```

---

## 🚀 Server Optimization

```
8) 🚀 Optimize server
```

Enables, when supported by the kernel:

- BBR congestion control
- `fq` queue discipline
- Persistent sysctl network tuning

---

## 🔧 Script Management

```
5) 📦 Install script     — install system-wide as `A,S-tunnel`
6) 🔄 Update script      — self-update from GitHub
7) 🗑  Uninstall script  — remove binary + cron health check
```

---

## 🛠 Troubleshooting

Check a slot's screen session directly:

```bash
screen -ls
```

Check listening ports:

```bash
ss -lntp
```

Test connectivity between servers:

```bash
nc -zv IR_IP <bridge_or_control_port>
```

For GRE, check the interface:

```bash
ip -s link show gre<slot_name>
```

---

## 📊 Recommended Production Setup

- Enable BBR optimization
- Enable Cron Health Check
- Pick the protocol that matches your traffic pattern (Gost for simple 1:1 forwarding, Backhaul/Rathole/FRP for multiplexed tunneling, A,S Native when you want zero external dependencies)
- Keep tokens/ports identical on both sides
- Monitor slot status regularly from the main menu

---

## ❓ FAQ

**Q: Do I have to use the same protocol on both servers?**
Yes — a protocol pairs two matching sides (except Gost, which is one-sided).

**Q: Can I run multiple tunnels at once?**
Yes — use different slots (1–10), each with its own protocol if you like.

**Q: What if a tunnel stops?**
Enable Cron Health Check — it restarts any slot regardless of protocol.

**Q: Does it survive reboot?**
Yes, via the cron-based health check.

**Q: What if a protocol's binary fails to install?**
Its installer pulls the latest release from the official GitHub repo. If the asset naming changed upstream, re-run the install — check that repo's Releases page if it still fails.

---

## 📌 Final Notes

Any configuration change must be applied identically on both servers (matching token/ports).
Restart the tunnel after changes — or just re-save the profile, since saving auto-starts it.

---

## ❤️ Maintained by A,S

**TEL:** [@Asnejad](https://t.me/Asnejad)

**DONATE:** `0xAb27580238c98290e291fF11C78061469A69406f`
USDT · BNB
