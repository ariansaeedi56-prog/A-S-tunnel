<p align="center"><b>In the name of God</b></p>

# 🚀 A,S Tunnel

[English](#english) | [فارسی](#فارسی) | [Русский](#русский) | [中文](#中文)

**Multi-Protocol Tunnel Manager for IR ⇄ EU Servers**
Named Tunnels • Multi-Protocol • Master Web Panel • AutoSync • Health Check • BBR Optimization

---

<p align="center">
  <b>Lightweight • Stable • Production Ready</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-4.0.5-cyan">
  <img src="https://img.shields.io/badge/protocols-7-brightgreen">
  <img src="https://img.shields.io/badge/tunnels-unlimited-blue">
  <img src="https://img.shields.io/badge/license-Proprietary-red">
</p>

---

## English

### 🖥 Web Panel Screenshots

<p align="center"><img src="images/panel-overview.png" alt="A,S Tunnel web panel overview" width="100%"></p>

<p align="center"><img src="images/tunnels-manager.png" alt="Tunnel manager panel" width="68%">&nbsp;&nbsp;<img src="images/color-palette.png" alt="Panel accent color palette" width="28%"></p>

Screenshots show sample panel data; the public IP and hostname are hidden.

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
2. Choose this host's location: **Abroad (Kharej)** or **Iran**
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

The Iran host listens for connections; the abroad host initiates the connection. No external binary — runs on the bundled `A,S.py` core.

---

### 2️⃣ Backhaul

In this setup, the protocol **server runs on the Iran host** and the **client runs abroad**.

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

In this setup, the protocol **server runs on the Iran host** and the **client runs abroad**.

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
| **Tunnels Manager** | Add / edit / start / stop / delete tunnels of the selected node, **live logs**, scheduled restart. New tunnels can be created **✋ Manually** on the selected node, or **🔗 From panel nodes**. Endpoint locations depend on the protocol: A,S Native, Backhaul and Rathole use an Iran server with an abroad client; other paired methods use the abroad server and Iran client where applicable. The panel fills shared keys, ports and addresses automatically, and rolls back the server profile if the client setup fails |

> **Fields follow the host location.** Set each node as *Abroad* or *Iran* in Node & Config. The tunnel form shows the fields for that location and protocol; the protocol server/client role is handled separately.

Also: stat cards (public IP, connected nodes, average latency, CPU / RAM / uptime / load of the selected node), **EN / فارسی** switch (RTL), **color palette**, refresh and sign-out. Everything updates live (every ~3 s).

### Staying up to date

- **Update nodes from the master:** the *Update* button (or *Update all nodes*) sends the master's script to the node, which verifies it (`bash -n` + checksum), installs it and restarts its agent. No GitHub access needed on the node.
- The panel and agent files are embedded in the script and **re-deployed automatically** whenever the script version changes (menu start, *Update script*, or a fresh `bash <(curl …)`).

### Security notes

- Login uses a signed, HttpOnly browser cookie that lasts up to 30 days; it is bound to the browser / app / OS user-agent, signing out clears it, and changing the password invalidates it. The saved-session check avoids showing the login form during a normal page refresh. The password is stored **hashed**; 8 failed logins lock an IP for 5 minutes.
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

## © Copyright & License

**A,S Tunnel is maintained by A,S (@Asnejad; GitHub: [ariansaeedi56-prog](https://github.com/ariansaeedi56-prog)). All rights reserved.**

You may run an unmodified official release on servers you own or are authorized to administer. Copying, modifying for redistribution, removing attribution, rebranding, sublicensing, selling, or redistributing this project requires prior written permission. See [LICENSE](LICENSE). Third-party components remain subject to their own licenses.

## ❤️ Maintained by A,S

**TEL:** [@Asnejad](https://t.me/Asnejad)

**DONATE:** `0xAb27580238c98290e291fF11C78061469A69406f`
USDT · BNB
---

<p align="center"><b>بسم الله الرحمن الرحيم</b></p>

## فارسی

# 🚀 تونل A,S

**مدیر چندپروتکلی تانل برای سرورهای ایران ⇄ خارج**
تانل‌های نام‌گذاری‌شده • چندپروتکلی • پنل وب مستر • همگام‌سازی خودکار • بررسی سلامت • بهینه‌سازی BBR

---

## 📌 معرفی

**A,S Tunnel** یک مدیر یکپارچه برای اتصال دو سرور است:

- 🇮🇷 **ایران** — سرور داخل ایران
- 🌍 **خارج** — سرور خارج از ایران

برای هر تانل می‌توانی پروتکل مناسب را جداگانه انتخاب کنی. اسکریپت نصب، پیکربندی، اجرا، توقف، بررسی سلامت و راه‌اندازی دوبارهٔ خودکار را از یک منو مدیریت می‌کند.

---

## 🧩 پروتکل‌های پشتیبانی‌شده

| شماره | پروتکل | نوع | کاربرد |
|---|---|---|---|
| 1 | **A,S Native** | TCP معکوس با اتصال‌های تجمیع‌شده | بدون وابستگی خارجی و همگام‌سازی خودکار پورت‌ها |
| 2 | **Backhaul** | تانل چندگانهٔ TCP / WS / WSS | سرعت بالا و انتخاب نوع انتقال |
| 3 | **Rathole** | تانل سبک برای عبور از NAT | سربار کم و مناسب سرویس‌های متعدد |
| 4 | **GRE** | تانل IP در سطح کرنل | ارتباط مستقیم IP بدون برنامهٔ کاربری |
| 5 | **FRP** | پراکسی معکوس | ابزار پرکاربرد با انواع پراکسی |
| 6 | **Gost** | فوروارد پورت IPv4/IPv6 با TCP/UDP/GRPC | فوروارد سادهٔ یک‌به‌یک و بازه‌های بزرگ پورت |

هر تانل تنظیمات و پروتکل خودش را دارد؛ مثلاً A,S Native با نام office و Backhaul با نام bh-main می‌توانند هم‌زمان اجرا شوند.

---

## 🧠 ساختار ارتباط

~~~
کاربر → سرور ایران ⇄ سرور خارج
                 │
           پروتکل انتخابی
 (A,S Native / Backhaul / Rathole / GRE / FRP / Gost)
~~~

هر تانل مستقل است. پروتکل را انتخاب کن و به پرسش‌های راه‌انداز پاسخ بده؛ تانل پس از ذخیرهٔ تنظیمات خودکار اجرا می‌شود.

---

## 🛠 امکانات

| ویژگی | توضیح |
|---|---|
| 🔀 چندپروتکلی | انتخاب A,S Native، Backhaul، Rathole، GRE، FRP، Gost یا Paqet برای هر تانل |
| 🏷 نام‌گذاری تانل | ساخت هر تعداد تانل با نام جداگانه |
| ⚡ اجرای خودکار | تانل بلافاصله پس از ذخیرهٔ تنظیمات اجرا می‌شود |
| 🔄 همگام‌سازی خودکار | ساخت و همگام‌سازی خودکار پورت‌ها در A,S Native |
| 🕒 بررسی سلامت | راه‌اندازی دوبارهٔ خودکار تانل متوقف‌شده |
| 🚀 بهینه‌سازی BBR | کنترل ازدحام و تنظیمات شبکهٔ sysctl |
| 📦 نصب خودکار | دریافت باینری رسمی Backhaul، Rathole، FRP و Gost از GitHub Releases |
| 🖥 systemd و cron | بررسی سلامت پس از راه‌اندازی مجدد سرور |
| 📊 وضعیت زنده | نمایش وضعیت و پروتکل تانل‌ها در منو |

---

## 📦 نصب

### 🟢 مرحلهٔ ۱ — نصب روی سرور ایران

~~~
bash <(curl -Ls https://raw.githubusercontent.com/ariansaeedi56-prog/A-S-tunnel/main/install.sh)
~~~

این دستور برنامه را نصب می‌کند و بلافاصله منو را باز می‌کند. دفعات بعد اجرا کن:

~~~
sudo A,S-tunnel
~~~

### 🔵 مرحلهٔ ۲ — نصب روی سرور خارج

همین دستور نصب را روی سرور خارج هم اجرا کن:

~~~
bash <(curl -Ls https://raw.githubusercontent.com/ariansaeedi56-prog/A-S-tunnel/main/install.sh)
~~~

---

## 🎬 ساخت تانل

از منوی اصلی گزینهٔ زیر را انتخاب کن:

~~~
1) ➕ Add new tunnel
~~~

1. برای تانل یک نام وارد کن؛ حروف، عدد، خط تیره و زیرخط مجاز است.
2. محل این سرور را انتخاب کن: **خارج** یا **ایران**.
3. پروتکل را انتخاب کن.
4. به پرسش‌های راه‌انداز پروتکل پاسخ بده.
5. تانل پس از ذخیره خودکار اجرا می‌شود.

این مراحل را روی سرور مقابل هم با نقش و مقادیر هماهنگ انجام بده؛ هر جا لازم است توکن، پورت و کلید باید یکسان باشند.

### 1️⃣ A,S Native

| فیلد | سرور خارج | سرور ایران |
|---|---|---|
| IP ایران | لازم | — |
| پورت Bridge | مثلاً 7000 | همان مقدار |
| پورت Sync | مثلاً 7001 | همان مقدار |
| همگام‌سازی خودکار | — | y یا n |
| پورت‌های دستی | — | فقط اگر همگام‌سازی خاموش باشد |

سرور ایران به اتصال‌ها گوش می‌دهد و سرور خارج اتصال را آغاز می‌کند. باینری خارجی لازم نیست؛ این پروتکل از هستهٔ همراه A,S.py استفاده می‌کند.

### 2️⃣ Backhaul

در این چیدمان، **سرور پروتکل روی سرور ایران** و **کلاینت روی سرور خارج** اجرا می‌شود.

| فیلد | نقش سرور | نقش کلاینت |
|---|---|---|
| توکن | راز مشترک | همان مقدار |
| نوع انتقال | tcp / ws / wss | همان مقدار |
| پورت Bind | پورت کنترل | — |
| IP سرور | — | وارد شود |
| پورت‌های فوروارد | وارد شود | — |

باینری از انتشارهای Musixal/Backhaul دریافت می‌شود.

### 3️⃣ Rathole

در این چیدمان، **سرور پروتکل روی سرور ایران** و **کلاینت روی سرور خارج** اجرا می‌شود.

| فیلد | نقش سرور | نقش کلاینت |
|---|---|---|
| توکن | راز مشترک | همان مقدار |
| پورت Bind | پورت کنترل | — |
| IP سرور | — | وارد شود |
| پورت‌های فوروارد | پورت‌های عمومی هر سرویس | همان پورت‌ها برای فوروارد محلی |

باینری از انتشارهای rapiz1/rathole دریافت می‌شود.

### 4️⃣ GRE

| فیلد | دو طرف |
|---|---|
| IP عمومی این سرور | لازم |
| IP عمومی همتا | لازم |
| IP تانل | خودکار؛ 10.10.10.1 و 10.10.10.2 |

این تانل در کرنل اجرا می‌شود و به برنامه یا باینری اضافه نیاز ندارد. برای مسیردهی انتخابی پورت‌ها می‌توان از iptables استفاده کرد.

### 5️⃣ FRP

| فیلد | سرور frps | کلاینت frpc |
|---|---|---|
| توکن | راز مشترک | همان مقدار |
| پورت Bind | وارد شود | پورت سرور |
| IP سرور | — | وارد شود |
| پورت‌های فوروارد | — | وارد شود |

باینری‌ها از انتشارهای fatedier/frp دریافت می‌شوند.

### 6️⃣ Gost

| فیلد | مقدار |
|---|---|
| IP مقصد خارج | سروری که ترافیک به آن فرستاده می‌شود |
| پورت‌ها | فهرست دستی یا بازه؛ مثلاً 54 تا 65000 |
| پروتکل | tcp / udp / grpc |

Gost یک‌طرفه است و در سمت دیگر تنظیم متناظر لازم ندارد. باینری از انتشارهای go-gost/gost دریافت می‌شود.

---

## 🌐 پنل مستر و نودها

یک داشبورد وب برای همهٔ سرورها داشته باش. پنل مستر را روی سرور خارج نصب کن؛ سپس سرورهای ایران و خارج را به‌عنوان نود به آن متصل و از همان صفحه مدیریت کن.

~~~
نود ایران ──┐                   ┌── نود خارج
نود ایران ──┼── اتصال خروجی ──► │ پنل مستر روی خارج
نود ایران ──┘                   └── مدیریت از مرورگر
~~~

نودها فقط اتصال خروجی به مستر برقرار می‌کنند؛ بنابراین نودهای ایران هم بدون بازکردن پورت ورودی اضافی قابل مدیریت هستند.

### 1) نصب پنل مستر روی سرور خارج

از منو برو به:

~~~
9) Master panel & nodes → 1) Install / reconfigure master panel
~~~

نصاب ابتدا نام کاربری و رمز عبور را می‌گیرد؛ رمز مخفی وارد و تأیید می‌شود یا با Enter رمز تصادفی ساخته می‌شود. سپس نام شبکه، محل سرور، IP پنل، HTTPS و پورت را تنظیم می‌کنی. در پایان URL، کلید اتصال و اثر انگشت TLS نمایش داده می‌شوند.

### 2) اتصال هر نود

روی سرور ایران یا خارج، از منو استفاده کن یا دستور زیر را اجرا کن:

~~~
sudo A,S-tunnel --join 'https://MASTER_IP:PORT' 'JOIN_KEY' 'node-name' iran 'TLS_FINGERPRINT'
~~~

اثر انگشت، گواهی مستر را پین می‌کند. پس از اتصال، نود در چند ثانیه در پنل دیده می‌شود.

### 3) امکانات داشبورد

| بخش | امکانات |
|---|---|
| **نود و تنظیمات** | تغییر هویت، نام، اجرا و توقف تانل‌ها، بهینه‌سازی BBR، بررسی سلامت و به‌روزرسانی |
| **نودها** | وضعیت آنلاین، IP، CPU، RAM، تانل‌ها، تأخیر و نسخه؛ به‌روزرسانی تکی یا همهٔ نودها |
| **تست سرعت** | سنجش سرعت واقعی بین دو نود با iperf3 و مشاهدهٔ تاریخچه |
| **پینگ و تأخیر زنده** | RTT نود تا مستر و پینگ از نود به مقصد دلخواه |
| **مدیریت تانل‌ها** | ساخت، ویرایش، اجرا، توقف، حذف، مشاهدهٔ لاگ زنده و زمان‌بندی راه‌اندازی مجدد |

برای ساخت تانل از پنل می‌توانی آن را دستی روی نود انتخاب‌شده بسازی یا دو نود پنل را به هم وصل کنی. سمت سرور پروتکل به روش وابسته است: در A,S Native، Backhaul و Rathole سرور ایران و کلاینت خارج است؛ در روش‌های جفت‌شدهٔ دیگر، هرجا کاربرد داشته باشد سرور خارج و کلاینت ایران است. پنل کلیدها، پورت‌ها و IPها را بین دو نود اعمال می‌کند و اگر تنظیم کلاینت شکست بخورد، پروفایل سرور را برمی‌گرداند.

محل نود را در بخش نود و تنظیمات مشخص کن. فرم هر پروتکل فیلدهای متناسب با محل نود را نشان می‌دهد و نقش سرور/کلاینت را جداگانه مدیریت می‌کند.

پنل آمار IP عمومی، نودهای متصل، میانگین تأخیر، CPU، RAM، آپتایم و بار را هم نشان می‌دهد. زبان فارسی و انگلیسی، پالت رنگ، تازه‌سازی و خروج در دسترس است و اطلاعات هر چند ثانیه به‌روز می‌شوند.

### به‌روزرسانی

- از گزینهٔ Update یا Update all nodes در پنل مستر، اسکریپت به نودها فرستاده، با bash -n و checksum بررسی و نصب می‌شود؛ سپس agent راه‌اندازی مجدد می‌شود.
- فایل‌های پنل و agent داخل اسکریپت هستند و با تغییر نسخهٔ اسکریپت دوباره نصب می‌شوند.

### نکات امنیتی

- ورود از کوکی امضاشده و HttpOnly با اعتبار تا ۳۰ روز استفاده می‌کند. کوکی به مشخصات مرورگر/اپ/سیستم‌عامل متصل است؛ خروج، کوکی را پاک می‌کند و تغییر رمز، نشست قبلی را بی‌اعتبار می‌کند.
- رمز عبور به‌صورت هش ذخیره می‌شود و پس از ۸ ورود ناموفق، IP برای ۵ دقیقه محدود می‌شود.
- نودها با توکن جداگانه احراز هویت می‌شوند و فقط فرمان‌های مجاز و مشخص را اجرا می‌کنند.
- HTTPS را فعال کن، دسترسی به پورت پنل را محدود نگه دار و پنل را دسترسی سطح root در نظر بگیر.

---

## 🎛 مدیریت تانل

از منوی اصلی:

~~~
2) 🎛 Manage tunnel
~~~

برای هر تانل می‌توانی پروفایل را ببینی، اجرا، توقف یا راه‌اندازی مجدد کنی، وضعیت و لاگ را بررسی یا تانل را حذف کنی. فهرست تانل‌ها وضعیت روشن/خاموش و پروتکل هر مورد را نشان می‌دهد.

---

## 🕒 بررسی سلامت

از منو گزینهٔ فعال‌کردن cron health-check را انتخاب و بازه را برحسب دقیقه تنظیم کن. اگر تانلی متوقف شود، با پروتکل خودش دوباره اجرا می‌شود. هر زمان خواستی می‌توانی بررسی سلامت را خاموش کنی.

---

## 🚀 بهینه‌سازی سرور

از منو گزینهٔ Optimize server را انتخاب کن. در صورت پشتیبانی کرنل، این موارد فعال می‌شوند:

- کنترل ازدحام BBR
- صف fq
- تنظیمات پایدار شبکه در sysctl

---

## 🔧 مدیریت اسکریپت

از منو می‌توانی اسکریپت را روی سیستم نصب کنی، آن را از GitHub به‌روزرسانی یا اسکریپت و cron health-check را حذف کنی.

---

## 🛠 عیب‌یابی

مشاهدهٔ نشست‌های screen:

~~~
screen -ls
~~~

بررسی پورت‌های در حال گوش‌دادن:

~~~
ss -lntp
~~~

بررسی ارتباط بین دو سرور:

~~~
nc -zv IR_IP <bridge_or_control_port>
~~~

بررسی رابط GRE:

~~~
ip -s link show gre<tunnel_name>
~~~

---

## 📊 پیشنهاد برای استفادهٔ پایدار

- بهینه‌سازی BBR و بررسی سلامت را فعال کن.
- پروتکل را متناسب با نوع ترافیک انتخاب کن.
- توکن و پورت‌های دو سمت را یکسان وارد کن.
- وضعیت تانل‌ها را مرتب بررسی کن.

---

## ❓ پرسش‌های متداول

**آیا دو سمت باید از یک پروتکل استفاده کنند؟**
بله؛ دو سمت تانل باید پروتکل هماهنگ داشته باشند، به‌جز Gost که یک‌طرفه است.

**می‌توان چند تانل را هم‌زمان اجرا کرد؟**
بله؛ هر تعداد تانل نام‌گذاری‌شده با پروتکل‌های مختلف قابل ساخت است.

**اگر تانل متوقف شود چه کنم؟**
Cron Health Check را فعال کن تا تانل را دوباره اجرا کند.

**پس از راه‌اندازی مجدد سرور هم کار می‌کند؟**
بله؛ بررسی سلامت cron برای این کار در نظر گرفته شده است.

**اگر نصب باینری یک پروتکل شکست خورد چه کنم؟**
نصاب آخرین انتشار مخزن رسمی آن پروتکل را دریافت می‌کند. اگر نام فایل انتشار عوض شده، نصب را دوباره انجام بده و بخش Releases مخزن مربوط را بررسی کن.

---

## 📌 نکته‌های پایانی

تنظیمات هر دو سمت باید هماهنگ باشد؛ از جمله توکن و پورت‌های متناظر. بعد از تغییر تنظیمات، تانل را راه‌اندازی مجدد کن یا پروفایل را دوباره ذخیره کن تا اجرا شود.

---

## © حق نشر و مجوز

**A,S Tunnel با مدیریت A,S (@Asnejad؛ GitHub: [ariansaeedi56-prog](https://github.com/ariansaeedi56-prog)) منتشر می‌شود. همهٔ حقوق محفوظ است.**

می‌توانی نسخهٔ رسمی و بدون تغییر را روی سرورهایی که مالکشان هستی یا اجازهٔ مدیریتشان را داری اجرا کنی. کپی، تغییر برای بازنشر، حذف نام سازنده، تغییر برند، فروش یا توزیع مجدد بدون اجازهٔ کتبی مجاز نیست. جزئیات در [LICENSE](LICENSE) آمده است. اجزای متعلق به اشخاص ثالث تابع مجوز خودشان هستند.

## ❤️ نگهداری پروژه

**تلگرام:** [@Asnejad](https://t.me/Asnejad)

**حمایت مالی:** 0xAb27580238c98290e291fF11C78061469A69406f  
USDT · BNB
---

## Русский

# 🚀 A,S Tunnel

**Мультипротокольный менеджер туннелей для серверов в Иране и за рубежом**
Именованные туннели • Несколько протоколов • Веб-панель мастера • Автосинхронизация • Контроль работоспособности • Оптимизация BBR

---

## 📌 Обзор

**A,S Tunnel** — единый менеджер для соединения двух серверов: в Иране и за его пределами. Для каждого туннеля можно отдельно выбрать протокол. Скрипт устанавливает и настраивает туннели, запускает и останавливает их, проверяет состояние и автоматически перезапускает остановленные службы.

---

## 🧩 Поддерживаемые протоколы

| № | Протокол | Тип | Назначение |
|---|---|---|---|
| 1 | **A,S Native** | Обратный TCP с пулом соединений | Без внешних зависимостей, автоматическая синхронизация портов |
| 2 | **Backhaul** | Мультиплексированный TCP / WS / WSS | Высокая пропускная способность и выбор транспорта |
| 3 | **Rathole** | Лёгкий туннель для обхода NAT | Низкая нагрузка, несколько сервисов |
| 4 | **GRE** | IP-туннель на уровне ядра | Прямая IP-связь без пользовательского демона |
| 5 | **FRP** | Обратный прокси | Проверенное решение с разными типами прокси |
| 6 | **Gost** | Пересылка IPv4/IPv6-портов через TCP/UDP/GRPC | Простая пересылка портов один к одному и большие диапазоны |

Каждому туннелю назначаются собственные имя и протокол. Например, A,S Native office, Backhaul bh-main и Gost fwd1 могут работать одновременно.

---

## 🧠 Схема соединения

~~~
Клиент → сервер в Иране ⇄ сервер за рубежом
                 │
          выбранный протокол
~~~

Каждый туннель независим. Выберите протокол и ответьте на вопросы мастера настройки; после сохранения туннель запускается автоматически.

---

## 🛠 Возможности

| Функция | Описание |
|---|---|
| 🔀 Несколько протоколов | A,S Native, Backhaul, Rathole, GRE, FRP, Gost или Paqet для каждого туннеля |
| 🏷 Именованные туннели | Создание любого количества туннелей с отдельными именами |
| ⚡ Автозапуск | Запуск сразу после сохранения конфигурации |
| 🔄 AutoSync | Автоматическое создание и синхронизация портов A,S Native |
| 🕒 Проверка состояния | Автоматический перезапуск остановленных туннелей |
| 🚀 Оптимизация BBR | Контроль перегрузки и сетевые настройки sysctl |
| 📦 Автоустановка | Официальные бинарные файлы Backhaul, Rathole, FRP и Gost из GitHub Releases |
| 🖥 systemd и cron | Проверка состояния после перезагрузки |
| 📊 Статус в реальном времени | Состояние и протокол каждого туннеля в меню |

---

## 📦 Установка

### 🟢 Шаг 1 — сервер в Иране

~~~
bash <(curl -Ls https://raw.githubusercontent.com/ariansaeedi56-prog/A-S-tunnel/main/install.sh)
~~~

Команда установит программу и сразу откроет меню. При следующих запусках используйте:

~~~
sudo A,S-tunnel
~~~

### 🔵 Шаг 2 — сервер за рубежом

Выполните ту же команду установки на зарубежном сервере:

~~~
bash <(curl -Ls https://raw.githubusercontent.com/ariansaeedi56-prog/A-S-tunnel/main/install.sh)
~~~

---

## 🎬 Создание туннеля

В главном меню выберите Add new tunnel. Введите имя, укажите расположение сервера (за рубежом или Иран), выберите протокол и ответьте на вопросы мастера. Затем повторите настройку на втором сервере с соответствующими параметрами. Там, где требуется, токен, порты и ключи должны совпадать.

### 1️⃣ A,S Native

| Параметр | Зарубежный сервер | Сервер в Иране |
|---|---|---|
| IP Ирана | Обязательно | — |
| Bridge-порт | Например, 7000 | То же значение |
| Sync-порт | Например, 7001 | То же значение |
| AutoSync | — | y или n |
| Ручные порты | — | Только если AutoSync выключен |

Сервер в Иране принимает соединения, зарубежный сервер подключается к нему. Внешний бинарный файл не нужен: используется встроенное ядро A,S.py.

### 2️⃣ Backhaul

В этой конфигурации **сервер протокола работает в Иране**, а **клиент — за рубежом**.

| Параметр | Сервер | Клиент |
|---|---|---|
| Токен | Общий секрет | То же значение |
| Транспорт | tcp / ws / wss | То же значение |
| Bind-порт | Порт управления | — |
| IP сервера | — | Указать |
| Пересылаемые порты | Указать | — |

Бинарный файл загружается из релизов Musixal/Backhaul.

### 3️⃣ Rathole

Сервер протокола работает в Иране, клиент — за рубежом. Используйте общий токен и порт управления; на клиенте укажите IP сервера, а порты для пересылки задайте на сервере и клиенте.

Бинарный файл загружается из релизов rapiz1/rathole.

### 4️⃣ GRE

Укажите публичные IP обоих серверов. IP туннеля назначаются автоматически: 10.10.10.1 и 10.10.10.2. GRE работает в ядре и не требует дополнительного демона или бинарного файла. Для выборочной маршрутизации портов можно использовать iptables.

### 5️⃣ FRP

Настройте общий токен, Bind-порт на сервере frps и IP сервера и пересылаемые порты на клиенте frpc. Бинарные файлы загружаются из релизов fatedier/frp.

### 6️⃣ Gost

Gost пересылает указанные TCP/UDP/GRPC-порты на IP назначения за рубежом. Можно задать список портов или диапазон. Это односторонний пересылатель, поэтому парная настройка на другом конце не требуется. Бинарный файл загружается из go-gost/gost.

---

## 🌐 Панель мастера и узлы

Установите панель мастера на зарубежном сервере. Серверы в Иране и за рубежом подключаются к ней как узлы и управляются с одной страницы. Узлы создают только исходящие подключения к мастеру, поэтому для них не нужно открывать дополнительные входящие порты.

### Установка и подключение

В меню выберите 9 → Master panel & nodes → Install / reconfigure master panel. Укажите имя пользователя и пароль, имя сети, расположение сервера, IP панели, HTTPS и порт. Сохраните URL панели, ключ подключения и TLS fingerprint.

На каждом узле выберите Connect to a master или выполните:

~~~
sudo A,S-tunnel --join 'https://MASTER_IP:PORT' 'JOIN_KEY' 'node-name' iran 'TLS_FINGERPRINT'
~~~

Fingerprint закрепляет сертификат мастера. После подключения узел появляется в панели через несколько секунд.

### Возможности панели

- Настройка узлов, запуск и остановка туннелей, оптимизация BBR и проверка состояния.
- Сведения об узлах: онлайн-статус, IP, CPU, RAM, туннели, задержка и версия; обновление одного или всех узлов.
- Тест скорости iperf3 между узлами и график пинга.
- Создание, изменение, запуск, остановка и удаление туннелей; живые журналы и плановый перезапуск.
- Для A,S Native, Backhaul и Rathole серверная роль находится в Иране, клиентская — за рубежом. Для других парных методов направление зависит от протокола.
- Панель автоматически передаёт ключи, порты и адреса. При ошибке настройки клиента профиль сервера откатывается.

Интерфейс показывает публичный IP, число подключённых узлов, задержку, CPU, RAM, время работы и нагрузку. Доступны английский и персидский языки, цветовая палитра, обновление и выход; данные обновляются каждые несколько секунд.

### Обновление

Кнопки Update и Update all nodes отправляют скрипт с мастера узлам. Скрипт проверяется командой bash -n и контрольной суммой, устанавливается, затем агент перезапускается. Файлы панели и агента встроены в скрипт и повторно развёртываются при смене версии.

### Безопасность

- Подписанная HttpOnly-cookie действует до 30 дней и привязана к User-Agent браузера, приложения и ОС. Выход удаляет cookie, смена пароля аннулирует старую сессию.
- Пароль хранится в виде хэша. После 8 неудачных попыток входа IP блокируется на 5 минут.
- Узлы используют собственные токены и выполняют только команды из фиксированного списка.
- Используйте HTTPS и ограничивайте доступ к порту панели; относитесь к панели как к доступу root.

---

## 🎛 Управление туннелями

В меню Manage tunnel можно показать профиль, запустить, остановить или перезапустить туннель, посмотреть статус и журналы либо удалить его. В списке отображаются состояние, протокол и сторона туннеля.

## 🕒 Проверка состояния

Включите cron health-check и задайте интервал в минутах. Остановленный туннель автоматически запускается снова с помощью своего протокола. Проверку можно отключить в любое время.

## 🚀 Оптимизация сервера

Пункт Optimize server включает, если это поддерживает ядро:

- BBR
- дисциплину очереди fq
- постоянные сетевые настройки sysctl

## 🔧 Управление скриптом

Из меню можно установить скрипт в систему, обновить его с GitHub или удалить вместе с cron health-check.

## 🛠 Диагностика

Список screen-сессий:

~~~
screen -ls
~~~

Прослушиваемые порты:

~~~
ss -lntp
~~~

Проверка связи между серверами:

~~~
nc -zv IR_IP <bridge_or_control_port>
~~~

Интерфейс GRE:

~~~
ip -s link show gre<tunnel_name>
~~~

## 📊 Рекомендации для стабильной работы

Включите BBR и cron health-check, выберите протокол по типу трафика, используйте одинаковые токены и порты на обеих сторонах и регулярно проверяйте состояние туннелей.

## ❓ Частые вопросы

**Нужно ли использовать одинаковый протокол на обоих серверах?**  
Да, стороны туннеля должны использовать совместимые настройки. Исключение — односторонний Gost.

**Можно ли запускать несколько туннелей одновременно?**  
Да, можно создавать любое количество именованных туннелей с разными протоколами.

**Что делать, если туннель остановился?**  
Включите Cron Health Check.

**Переживёт ли настройка перезагрузку?**  
Да, для этого используется cron health-check.

**Что делать, если бинарный файл протокола не устанавливается?**  
Установщик получает последний релиз официального проекта. Проверьте раздел Releases, если имя файла изменилось.

## 📌 Примечания

Изменения конфигурации должны совпадать на обоих серверах. После изменения перезапустите туннель или сохраните профиль повторно.

## © Авторские права и лицензия

**A,S Tunnel поддерживается A,S (@Asnejad; GitHub: [ariansaeedi56-prog](https://github.com/ariansaeedi56-prog)). Все права защищены.**

Разрешается запускать неизменённую официальную версию на серверах, которыми вы владеете или управляете на законных основаниях. Копирование, изменение для распространения, удаление атрибуции, смена бренда, продажа и распространение без письменного разрешения запрещены. Подробности — в [LICENSE](LICENSE). Компоненты третьих сторон регулируются собственными лицензиями.

## ❤️ Контакты

**Telegram:** [@Asnejad](https://t.me/Asnejad)

**Поддержать:** 0xAb27580238c98290e291fF11C78061469A69406f  
USDT · BNB
---

## 中文

# 🚀 A,S Tunnel

**面向伊朗与境外服务器的多协议隧道管理器**
命名隧道 • 多协议 • 主控 Web 面板 • 自动同步 • 健康检查 • BBR 优化

---

## 📌 项目介绍

**A,S Tunnel** 是用于连接两台服务器的统一管理工具：一台位于伊朗，另一台位于境外。每条隧道都可以单独选择协议。脚本负责安装、配置、启动、停止、健康检查，并自动重启已停止的隧道。

---

## 🧩 支持的隧道协议

| 编号 | 协议 | 类型 | 适用场景 |
|---|---|---|---|
| 1 | **A,S Native** | 内置连接池的反向 TCP | 无外部依赖，端口自动同步 |
| 2 | **Backhaul** | TCP / WS / WSS 多路复用隧道 | 高吞吐量和灵活传输方式 |
| 3 | **Rathole** | 轻量 NAT 穿透隧道 | 低开销，适合多个小型服务 |
| 4 | **GRE** | 内核级 IP 隧道 | 原生 IP 连接，无用户态守护进程 |
| 5 | **FRP** | 快速反向代理 | 成熟方案，支持多种代理类型 |
| 6 | **Gost** | IPv4/IPv6 TCP、UDP、GRPC 端口转发 | 简单的一对一转发和大范围端口 |

每条隧道都有独立的名称和协议。例如，A,S Native office、Backhaul bh-main 和 Gost fwd1 可以同时运行。

---

## 🧠 连接结构

~~~
客户端 → 伊朗服务器 ⇄ 境外服务器
                 │
              所选协议
~~~

每条隧道相互独立。选择协议并完成向导，保存配置后隧道会自动启动。

---

## 🛠 功能

| 功能 | 说明 |
|---|---|
| 🔀 多协议 | 每条隧道可选 A,S Native、Backhaul、Rathole、GRE、FRP、Gost 或 Paqet |
| 🏷 命名隧道 | 创建任意数量的独立命名隧道 |
| ⚡ 自动启动 | 保存配置后立即启动 |
| 🔄 AutoSync | A,S Native 自动创建并同步端口 |
| 🕒 Cron 健康检查 | 自动重启已停止的隧道 |
| 🚀 BBR 优化 | 拥塞控制和 sysctl 网络调优 |
| 📦 自动安装 | 从 GitHub Releases 获取 Backhaul、Rathole、FRP 和 Gost 官方二进制文件 |
| 🖥 systemd/cron | 重启后继续进行健康检查 |
| 📊 实时状态 | 在菜单中查看隧道状态和协议 |

---

## 📦 安装

### 🟢 第一步 — 伊朗服务器

~~~
bash <(curl -Ls https://raw.githubusercontent.com/ariansaeedi56-prog/A-S-tunnel/main/install.sh)
~~~

该命令会安装程序并立即打开菜单。之后可运行：

~~~
sudo A,S-tunnel
~~~

### 🔵 第二步 — 境外服务器

在境外服务器上也运行相同的安装命令：

~~~
bash <(curl -Ls https://raw.githubusercontent.com/ariansaeedi56-prog/A-S-tunnel/main/install.sh)
~~~

---

## 🎬 创建隧道

在主菜单选择 Add new tunnel，输入隧道名称，选择服务器位置（境外或伊朗）和协议，然后完成向导。在另一台服务器上设置相匹配的参数。需要共享的令牌、端口和密钥必须保持一致。

### 1️⃣ A,S Native

| 参数 | 境外服务器 | 伊朗服务器 |
|---|---|---|
| 伊朗 IP | 必填 | — |
| Bridge 端口 | 例如 7000 | 相同值 |
| Sync 端口 | 例如 7001 | 相同值 |
| AutoSync | — | y 或 n |
| 手动端口 | — | 仅在关闭 AutoSync 时填写 |

伊朗服务器监听连接，境外服务器发起连接。无需外部二进制文件，使用内置 A,S.py 核心。

### 2️⃣ Backhaul

此配置中，**协议服务器运行在伊朗服务器**，**客户端运行在境外服务器**。两端使用相同令牌和传输方式；服务器设置 Bind 控制端口及转发端口，客户端设置服务器 IP。

二进制文件从 Musixal/Backhaul Releases 自动下载。

### 3️⃣ Rathole

此配置中，协议服务器位于伊朗，客户端位于境外。两端使用相同令牌和控制端口；客户端填写服务器 IP，服务器和客户端配置对应的转发端口。

二进制文件从 rapiz1/rathole Releases 自动下载。

### 4️⃣ GRE

填写两台服务器的公网 IP。隧道 IP 自动分配为 10.10.10.1 和 10.10.10.2。GRE 在内核中运行，无需额外守护进程或二进制文件。可使用 iptables 进行选择性端口路由。

### 5️⃣ FRP

配置共享令牌、frps 服务器的 Bind 端口，以及 frpc 客户端的服务器 IP 和转发端口。二进制文件从 fatedier/frp Releases 自动下载。

### 6️⃣ Gost

Gost 将指定的 TCP/UDP/GRPC 端口转发到境外目标 IP。端口可手动列出，也可设置范围。它是单向转发器，另一端不需要配对配置。二进制文件从 go-gost/gost Releases 下载。

---

## 🌐 主控面板与节点

将主控面板安装在境外服务器上。伊朗和境外服务器都可以作为节点连接到面板，并从同一页面管理。节点只向主控建立出站连接，因此无需在节点上额外开放入站端口。

### 安装与连接

在菜单中选择 9 → Master panel & nodes → Install / reconfigure master panel。设置用户名、密码、网络名称、服务器位置、面板 IP、HTTPS 和端口。安装完成后保存面板 URL、加入密钥和 TLS 指纹。

在每个节点上选择 Connect to a master，或执行：

~~~
sudo A,S-tunnel --join 'https://MASTER_IP:PORT' 'JOIN_KEY' 'node-name' iran 'TLS_FINGERPRINT'
~~~

TLS 指纹用于固定主控证书。节点通常会在几秒内显示在面板中。

### 面板功能

- 管理节点、启动或停止隧道、运行 BBR 优化和健康检查。
- 查看节点在线状态、IP、CPU、RAM、隧道、延迟和版本；更新单个或全部节点。
- 使用 iperf3 测试节点间速度，并查看实时 Ping 图表。
- 创建、编辑、启动、停止和删除隧道；查看实时日志并安排重启。
- A,S Native、Backhaul 和 Rathole 的协议服务器位于伊朗，客户端位于境外；其他配对方式的方向依协议而定。
- 面板自动同步密钥、端口和地址；客户端配置失败时会回滚服务器配置。

仪表板还显示公网 IP、节点数量、平均延迟、CPU、RAM、运行时间和负载。支持英语和波斯语、颜色面板、刷新和退出，数据每隔几秒更新。

### 更新

在主控面板点击 Update 或 Update all nodes，可将脚本发送到节点。脚本会通过 bash -n 和校验和检查，安装后重启 agent。面板与 agent 文件嵌入在脚本中，脚本版本变化时会重新部署。

### 安全说明

- 登录使用签名的 HttpOnly Cookie，有效期最长 30 天，并绑定浏览器/应用/操作系统的 User-Agent。退出会清除 Cookie，更改密码会使旧会话失效。
- 密码以哈希形式保存。连续 8 次登录失败后，该 IP 会被限制 5 分钟。
- 节点使用独立令牌认证，只能执行固定白名单中的命令。
- 请启用 HTTPS、限制面板端口的访问，并将面板视为 root 权限入口。

---

## 🎛 管理隧道

在 Manage tunnel 菜单中，可以查看配置、启动、停止或重启隧道，查看状态和日志，或删除隧道。隧道列表会显示运行状态、协议和所在端。

## 🕒 健康检查

启用 cron health-check 并设置分钟间隔。检测到隧道停止时，会使用其协议自动重新启动。可随时关闭此功能。

## 🚀 服务器优化

在内核支持时，Optimize server 会启用：

- BBR 拥塞控制
- fq 队列规则
- 持久化 sysctl 网络设置

## 🔧 脚本管理

可以从菜单将脚本安装到系统、从 GitHub 更新，或卸载脚本与 cron 健康检查。

## 🛠 故障排查

查看 screen 会话：

~~~
screen -ls
~~~

查看监听端口：

~~~
ss -lntp
~~~

测试两台服务器的连通性：

~~~
nc -zv IR_IP <bridge_or_control_port>
~~~

检查 GRE 接口：

~~~
ip -s link show gre<tunnel_name>
~~~

## 📊 稳定运行建议

启用 BBR 和 cron 健康检查；根据流量选择协议；两端使用相同的令牌和对应端口；定期检查隧道状态。

## ❓ 常见问题

**两台服务器必须使用相同协议吗？**  
是的，隧道两端需要匹配的协议设置。Gost 是单向转发的例外。

**可以同时运行多个隧道吗？**  
可以，能够创建任意数量、名称和协议各自独立的隧道。

**隧道停止时怎么办？**  
启用 Cron Health Check 以自动重启。

**服务器重启后还能工作吗？**  
可以，cron 健康检查会在重启后继续运行。

**协议二进制文件安装失败怎么办？**  
安装器会获取该项目的最新官方 Release。如果上游更改了文件名，请检查其 Releases 页面。

## 📌 最后说明

两台服务器上的相关配置必须匹配，例如令牌和端口。修改后请重启隧道，或重新保存配置。

## © 版权与许可

**A,S Tunnel 由 A,S (@Asnejad；GitHub：[ariansaeedi56-prog](https://github.com/ariansaeedi56-prog)) 维护。版权所有。**

你可以在自己拥有或获授权管理的服务器上运行未经修改的官方版本。未经书面许可，不得复制、修改后重新分发、删除署名、改换品牌、销售或重新发布本项目。详情请查看 [LICENSE](LICENSE)。第三方组件遵循其各自的许可证。

## ❤️ 项目维护

**Telegram：** [@Asnejad](https://t.me/Asnejad)

**支持项目：** 0xAb27580238c98290e291fF11C78061469A69406f  
USDT · BNB
