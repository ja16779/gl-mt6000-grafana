# GL-MT6000 Grafana Monitoring

Push metrics from a GL-iNet MT6000 (Flint 2) OpenWrt router to Grafana Cloud via InfluxDB line protocol.

## Overview

A lightweight shell script (`grafana_push.sh`) that runs on the router and pushes system, network, WiFi, DNS, and QoS metrics to Grafana Cloud every 60 seconds. Includes a pre-built Grafana dashboard with 44 panels organized in 6 sections.

## Dashboard Sections

### Sistema
- Uptime, RAM Usage, Temperature, CPU Load, Connections
- CPU per core (4 gauges + history)
- Storage (root + USB)
- RAM and Temperature history
- Process count, Top 5 memory processes, File descriptors

### WAN / Conectividad
- WAN Status (Online/Offline) with public IPs
- Ping latency and packet loss % per WAN
- Conntrack usage (current vs max)
- Traffic counters per interface (WAN1, WAN2, LAN, IOT)

### Clientes
- WiFi clients per band (2.4G / 5G) - bar gauge
- DHCP clients per network (IOT / LAN) - bar gauge
- Top 10 client bandwidth from conntrack

### WiFi
- Signal strength (avg RSSI per band)
- Channel utilization %
- TX/RX link rate (Mbit/s)
- Client count history
- Noise floor

### DNS
- Total queries and blocked (adblock/NXDOMAIN)

### QoS / SQM (CAKE)
- Queue backlog (packets + bytes)
- Memory usage per WAN
- Capacity estimate
- Peak delay per traffic class (Bulk, Best Effort, Video, Voice)
- Drops per traffic class

## Metrics Collected

| Metric | Fields |
|---|---|
| `router_system` | uptime, load, temp, mem_pct, connections |
| `router_storage` | root_pct, usb_pct |
| `router_procs` | count, fd_open, fd_max |
| `router_top_mem` | vsz_kb (per process, top 5) |
| `router_cpu` | usage (per core) |
| `router_clients` | wifi_total, wifi_2g, wifi_5g, dhcp_iot, dhcp_lan |
| `router_traffic` | rx, tx (per interface) |
| `router_wan` | status, ping, loss (per WAN, with pub_ip tag) |
| `router_conntrack` | current, max, pct |
| `router_wifi` | noise, rssi, chan_util, rx_rate, tx_rate (per band) |
| `router_dns` | total, blocked |
| `router_sqm` | drops (per WAN) |
| `router_sqm_queue` | backlog_bytes, backlog_pkts, mem_used, capacity |
| `router_sqm_delay` | pk_delay (per traffic class) |
| `router_sqm_drops` | drops (per traffic class) |
| `router_client_bw` | bytes (per client IP, top 10) |

## Requirements

- GL-iNet MT6000 or similar OpenWrt router (24.x)
- BusyBox ash/awk
- `curl`, `iwinfo`, `iw`, `tc`, `mwan3`
- Grafana Cloud account with InfluxDB push endpoint

## Installation

### 1. Configure the script

Edit `grafana_push.sh` and replace the placeholders:

```sh
INFLUX_URL="https://YOUR_INFLUX_HOST.grafana.net/api/v1/push/influx/write"
INFLUX_USER="YOUR_INFLUX_USER"
INFLUX_TOKEN="YOUR_INFLUX_TOKEN"
HOST="YOUR_HOSTNAME"
```

### 2. Upload to router

```sh
scp grafana_push.sh root@192.168.8.1:/usr/bin/grafana_push.sh
ssh root@192.168.8.1 'chmod +x /usr/bin/grafana_push.sh'
```

### 3. Auto-start on boot

Add to `/etc/rc.local` (before `exit 0`):

```sh
/usr/bin/grafana_push.sh &
```

### 4. Import dashboard

1. Go to your Grafana instance
2. Dashboards > Import
3. Upload `dashboard.json`
4. Select your Prometheus data source (the one connected to your Grafana Cloud metrics)

## Adapting to Other Routers

The script assumes:
- WAN interfaces: `eth1` (WAN1), `lan5` (WAN2)
- LAN bridge: `br-lan`
- IOT VLAN: `br-lan.8`
- WiFi: `wlan0` (2.4G), `wlan1` (5G)
- SQM: CAKE qdisc on WAN interfaces
- Dual WAN with `mwan3`

Adjust interface names and network ranges in the script to match your setup.

## License

MIT
