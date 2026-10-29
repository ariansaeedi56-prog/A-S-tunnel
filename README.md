# 🚀 A,S Tunnel

**Multi-Protocol Tunnel Manager for IR ⇄ EU Servers**
Named Tunnels • Multi-Protocol • Master Web Panel • AutoSync • Health Check • BBR Optimization

---

<p align="center">
  <b>Lightweight • Stable • Production Ready</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-4.0.0-cyan">
  <img src="https://img.shields.io/badge/protocols-7-brightgreen">
  <img src="https://img.shields.io/badge/tunnels-unlimited-blue">
  <img src="https://img.shields.io/badge/license-MIT-lightgrey">
</p>

---

## 📌 Overview

**A,S Tunnel** is a unified tunnel manager that connects two servers:

- 🇮🇷 **IR** — Iran server
- 🌍 **EU** — Foreign / outside server

Instead of locking you into one tunneling technology, A,S Tunnel lets you pick — **per tunnel** — whichever protocol fits your situation, then handles installation, configuration, starting, stopping, health-checking, and auto-restart for you, all from one menu.

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

Each tunnel remembers its own protocol, so you can run **A,S Native as `office`**, **Backhaul as `bh-main`**, **Gost as `fwd1`**, etc. — all at once, all managed from the same menu.

---

## 🧠 Architecture

```
Client → IR Server ⇄ EU Server
             │
     Protocol of your choice
   (A,S Native / Backhaul / Rathole
        / GRE / FRP / Gost)
```

Every tunnel is independent: pick a protocol, answer a short wizard, and the tunnel **starts automatically** — no extra "start" step needed.

---

## 🛠 Features

| Feature | Description |
|---------|--------------|
| 🔀 Multi-Protocol | Choose A,S Native / Backhaul / Rathole / GRE / FRP / Gost / Paqet per tunnel |
| 🏷 Named tunnels | Create as many tunnels as you like, each with its own name |
| ⚡ Auto-Start | Tunnel starts immediately after you save its config |
| 🔄 AutoSync | Automatic port creation & synchronization (A,S Native) |
| 🕒 Cron Health Check | Auto-restarts any stopped tunnel, any protocol |
| 🚀 BBR Optimization | Congestion control + sysctl network tuning |
| 📦 Auto-Install | Official binaries for Backhaul / Rathole / FRP / Gost fetched straight from GitHub Releases |
| 🖥 systemd/cron Integration | Health check survives reboot via cron |
| 📊 Live Status | See which tunnels are running, and with which protocol, right in the menu |

---

## 📦 Installation

### 🟢 Step 1 — Setup IR Server

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ariansaeedi56-prog/A-S-tunnel/main/install.sh)
```

That single command installs everything **and opens the menu right away**. Next time just run `sudo A,S-tunnel`.

### 🔵 Step 2 — Setup EU Server

Run the **same** install command on the EU server too:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ariansaeedi56-prog/A-S-tunnel/main/install.sh)
```

---

## 🎬 Creating a Tunnel

From the main menu:

```
1) ➕ Add new tunnel
```

1. Type a **name** for the tunnel (e.g. `server1`) — letters, digits, `-` and `_`
2. Choose the side: **Server (Abroad / Kharej)** or **Client (Iran)**
3. Choose a protocol (**1–7**, see table above)
4. Answer the protocol's short wizard
5. ✅ Done — the tunnel **starts automatically** and its status is shown right away

Repeat on the **other server** with the matching side and values (same token / ports / key where required).

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

### 4️⃣ GRE

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

## 🌐 Master Panel & Nodes

One web dashboard for **all** your servers. Put the **master panel on the abroad server**; every Iran or abroad server then joins it as a **node** and is managed from the same page.

```
 Iran node ──┐                       ┌── abroad node
 Iran node ──┼──► (outbound only) ──►│ MASTER panel (abroad)  ◄── you, in the browser
 Iran node ──┘                       └── …
```

Nodes only make **outbound** connections to the master (heartbeat + long-poll), so Iran servers behind filtering work fine, and nothing extra has to be opened on the nodes.

### 1) Install the master (abroad server)

`menu → 9) Master panel & nodes → 1) Install / reconfigure master panel`

The installer asks **first** for your **username and password** (password hidden + confirmed, or press Enter to generate one), then the network name, which side this server is, panel IP, HTTPS (self-signed, recommended) and port (random by default). It prints the URL, the **join key** and the TLS fingerprint.

### 2) Connect each node (Iran or abroad)

On the node, either use the menu (`9 → 8) Connect to a master`) or run one command:

```bash
sudo A,S-tunnel --join 'https://MASTER_IP:PORT' 'JOIN_KEY' 'node-name' iran 'TLS_FINGERPRINT'
```

The fingerprint pins the master's certificate (leave it out to trust on first use). The node then appears in the panel within seconds.

### 3) What the dashboard gives you

| Tab | What it does |
|-----|--------------|
| **Node & Config** | Node identity, rename, start / restart / stop **all** tunnels, BBR optimization, health-check cron, update script |
| **Nodes** | Every node: side, online/offline, IP, CPU, RAM, tunnels, latency, version · update one / all nodes · remove · join info |
| **Speedtest (iperf3)** | Real throughput between any two nodes (upload + download), history |
| **Live Ping & Latency** | Live node ⇄ master RTT with trends + live ping from any node to any target with a chart |
| **Tunnels Manager** | Add / edit / start / stop / delete tunnels of the selected node, **live logs**, scheduled restart. New tunnels can be created **✋ Manually** on the selected node, or **🔗 From panel nodes**: pick a *Server (Abroad)* node and a *Client (Iran)* node (the master itself counts as a node) and the panel configures both ends at once — shared key/token, ports and IPs are filled in automatically, and the server side is rolled back if the client side fails |

> **Fields follow the side.** A node is either *Server (Abroad)* or *Client (Iran)* (changeable in Node & Config). The tunnel form only shows the options that belong to that side — no mixed "client only / server only" fields.

Also: stat cards (public IP, connected nodes, average latency, CPU / RAM / uptime / load of the selected node), **EN / فارسی** switch (RTL), **color palette**, refresh and sign-out. Everything updates live (every ~3 s).

### Staying up to date

- **Update nodes from the master:** the *Update* button (or *Update all nodes*) sends the master's script to the node, which verifies it (`bash -n` + checksum), installs it and restarts its agent. No GitHub access needed on the node.
- The panel and agent files are embedded in the script and **re-deployed automatically** whenever the script version changes (menu start, *Update script*, or a fresh `bash <(curl …)`).

### Security notes

- Login uses signed, expiring session tokens; the password is stored **hashed**; 8 failed logins lock an IP for 5 minutes. Changing the password signs everybody out.
- Nodes authenticate with their own token (issued once with the join key) and only execute a fixed **whitelist** of commands — never arbitrary shell.
- Use HTTPS, open the panel port only to what you need, and treat the panel like root access.
- Menu options in `9`: show info, change username/password, reset to random, new join key, disable, uninstall, agent status, disconnect.

---

## 🎛 Managing a Tunnel

```
2) 🎛 Manage tunnel
```

For any tunnel you get:

```
1) 📄 Show profile
2) ▶️  Start
3) ⏹  Stop
4) 🔁 Restart
5) 📊 Status
6) 📜 Logs
7) 🗑  Delete tunnel
```

The tunnel list shows live status at a glance (🟢 running, 🔴 stopped) with the protocol and side next to each name.

---

## 🕒 Health Check (Cron)

```
3) ✅ Enable cron health-check
```

Pick an interval in minutes — any tunnel found stopped is automatically restarted with its own protocol, no matter which one it uses.

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

Check a tunnel's screen session directly:

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
ip -s link show gre<tunnel_name>
```

---

## 📊 Recommended Production Setup

- Enable BBR optimization
- Enable Cron Health Check
- Pick the protocol that matches your traffic pattern (Gost for simple 1:1 forwarding, Backhaul/Rathole/FRP for multiplexed tunneling, A,S Native when you want zero external dependencies)
- Keep tokens/ports identical on both sides
- Monitor tunnel status regularly from the main menu

---

## ❓ FAQ

**Q: Do I have to use the same protocol on both servers?**
Yes — a protocol pairs two matching sides (except Gost, which is one-sided).

**Q: Can I run multiple tunnels at once?**
Yes — create as many named tunnels as you like, each with its own protocol if you like.

**Q: What if a tunnel stops?**
Enable Cron Health Check — it restarts any tunnel regardless of protocol.

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
