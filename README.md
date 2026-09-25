

# 🚀 A,S Tunnel

High-Performance Reverse TCP Tunnel Manager  
Multi-Slot • AutoSync • Health Check • BBR Optimization • Multi Port-Forward

---

<p align="center">
  <b>Lightweight • Stable • Production Ready</b>
</p>

---

# 📌 Overview

A,S Tunnel is a reverse TCP tunneling system designed to connect two servers:

- 🇮🇷 IR (Iran Server)
- 🌍 EU (Outside Server)

It supports multi-slot configuration, automatic port synchronization, system optimization, and multiple port-forwarding methods.

---

# 🧠 Architecture

```
Client → IR Server ⇄ EU Server
             │
        Bridge Port (Main Tunnel)
             │
         Sync Port (AutoSync)
```

### 🔹 Bridge Port
Main persistent TCP tunnel connection between IR and EU.

### 🔹 Sync Port
Used for automatic port synchronization between servers.

---

# 🛠 Features

| Feature | Description |
|----------|------------|
| Reverse TCP Tunnel | Persistent IR ⇄ EU connection |
| Multi-Slot (1–10) | Store up to 10 independent tunnel configs |
| AutoSync | Automatic port creation & synchronization |
| Cron Health Check | Automatic restart if tunnel stops |
| BBR Optimization | Network performance tuning |
| Multi Port Forward | iptables, nftables, HAProxy, socat |
| systemd Integration | Auto-start on reboot |
| Performance Tuning | ENV-based tuning |
| Thread Control | Worker pool limitation |
| Metrics (Optional) | Connection & traffic stats |

---

# 📦 Installation Guide

---

# 🟢 Step 1 — Setup IR Server

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ariansaeedi56-prog/A-S-tunnel/main/install.sh)
```

After completing all installation and configuration steps, run the following command to open the Tunnel Manager:

```bash
sudo A,S-tunnel


### 1️⃣ Install Dependencies

Select:

```
5) Install / Complete Setup
```

---

### 2️⃣ Create Tunnel

```
1) Create Tunnel
2) IRAN Server
```

---

### 3️⃣ Select Slot (1–10)

Each slot represents a saved configuration.

---

### 4️⃣ Enter Bridge Port

Default:

```
7000
```

Must match on both servers.

---

### 5️⃣ Enter Sync Port

Default:

```
7001
```

Must match on both servers.

---

### 6️⃣ Enable AutoSync?

```
y  → Enable
n  → Disable
```

---

### 7️⃣ Enter Config Port

Enter your desired service port.

Press Enter to finish.

---

# 🔵 Step 2 — Setup EU Server

Repeat same process:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ariansaeedi56-prog/A-S-tunnel/main/install.sh)
```

After completing all installation and configuration steps, run the following command to open the Tunnel Manager:

```bash
sudo A,S-tunnel

Select:

```
5) Install / Complete Setup
1) Create Tunnel
2) EU Server
```

- Choose same Slot
- Enter IR Server IP
- Enter same Bridge Port
- Enter same Sync Port

Press Enter to finish.

---

# ▶️ Start Tunnel

## On IR:

```
2) Manage Tunnel
→ Select IR
→ Select Slot
→ 2) Start
→ 5) Status
```

Status must show:

```
Running
```

## On EU:

Repeat same steps.

---

# 🎉 Tunnel Connected Successfully

---

# ⚙ Optional Enhancements

---

## 🚀 Enable BBR Optimization

```
9) Optimize Server
```

Enables:

- BBR congestion control
- fq queue discipline
- sysctl performance tuning

---

## 🕒 Enable Health Check (Cron)

```
3) Enable Cron
```

Choose interval in minutes.

Auto-restarts tunnel if stopped.

---

# 🔄 Port Forward Methods

Available methods:

1. iptables (DNAT)
2. nftables
3. HAProxy (Layer 4)
4. socat relay

Each method supports:
- Add rule
- Remove rule
- Show rules

---

# ⚡ Performance Tuning (Advanced)

You can configure environment variables:

```bash
export USER_WORKERS=128
export AUTO_SOCKBUF=1
export BUF_COPY_BYTES=262144
export METRICS_PORT=9109
```

---

# 🔐 Security Recommendations

- Only open required ports
- Use firewall rules carefully
- Keep Bridge & Sync ports protected
- Monitor active connections
- Enable failover if using multiple EU servers

---

# 🛠 Troubleshooting

Check service:

```bash
systemctl status A,S
```

Check listening ports:

```bash
ss -lntp
```

Test connectivity:

```bash
nc -zv IR_IP 7000
```

---

# 📊 Recommended Production Setup

- Enable BBR
- Enable Cron HealthCheck
- Use HAProxy for managed forwarding
- Use AutoSync
- Monitor logs regularly

---

# ❓ FAQ

### Q: Bridge & Sync ports must match?
Yes, both servers must use identical values.

### Q: Can I run multiple tunnels?
Yes, use different slots.

### Q: What if tunnel stops?
Enable Cron HealthCheck.

### Q: Does it survive reboot?
Yes (systemd integration).

---



# 📌 Final Notes

Any configuration change must be applied identically on both servers.

Restart tunnel after changes.

---

# ❤️ Maintained by A,S

TEL: @Asnejad 


DONATE : 0xAb27580238c98290e291fF11C78061469A69406f 
USDT BNB
