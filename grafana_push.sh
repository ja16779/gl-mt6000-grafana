#!/bin/sh
# Push router metrics to Grafana Cloud every 60s
INFLUX_URL="https://YOUR_INFLUX_HOST.grafana.net/api/v1/push/influx/write"
INFLUX_USER="YOUR_INFLUX_USER"
INFLUX_TOKEN="YOUR_INFLUX_TOKEN"
HOST="YOUR_HOSTNAME"

push_metrics() {
    # System metrics
    UPTIME=$(awk '{print int($1)}' /proc/uptime)
    LOAD=$(awk '{print $1}' /proc/loadavg)
    TEMP=$(awk '{print int($1/1000)}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)
    MEM_TOTAL=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    MEM_FREE=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    MEM_PCT=$(( (MEM_TOTAL - MEM_FREE) * 100 / MEM_TOTAL ))
    CONNS=$(wc -l < /proc/net/nf_conntrack 2>/dev/null || echo 0)

    # Process count and file descriptors
    PROC_COUNT=$(ps | wc -l)
    fd_line=$(cat /proc/sys/fs/file-nr)
    FD_OPEN=$(echo "$fd_line" | awk '{print $1}')
    FD_MAX=$(echo "$fd_line" | awk '{print $3}')

    # Top 5 memory processes (aggregated by name, VSZ in KB)
    TOP_MEM=$(ps -w | awk 'NR>1 && $3>0{
      cmd=$5; gsub(/:.*/,"",cmd); gsub(/[\[\]\{\}]/,"",cmd)
      if(cmd~/^\//) {n=split(cmd,a,"/"); cmd=a[n]}
      mem[cmd]+=$3
    } END{
      n=0; for(c in mem){arr[n]=mem[c] SUBSEP c; n++}
      for(i=0;i<n-1;i++) for(j=i+1;j<n;j++){
        split(arr[i],ai,SUBSEP); split(arr[j],aj,SUBSEP)
        if(aj[1]+0>ai[1]+0){t=arr[i];arr[i]=arr[j];arr[j]=t}
      }
      for(i=0;i<5&&i<n;i++){
        split(arr[i],a,SUBSEP)
        printf "router_top_mem,host='"$HOST"',proc=%s vsz_kb=%di\n",a[2],a[1]
      }
    }')

    # CPU per core
    CPU_PREV="/tmp/gf_cpu_prev.stat"
    CPU_NOW="/tmp/gf_cpu_now.stat"
    awk '/^cpu[0-9]/{print $1,$2,$3,$4,$5,$6,$7,$8}' /proc/stat > "$CPU_NOW"
    CPU_LINE=""
    if [ -f "$CPU_PREV" ]; then
        CPU_LINE=$(awk 'NR==FNR{p[$1]=$2" "$3" "$4" "$5" "$6" "$7" "$8;next}
        $1 in p{
            split(p[$1],a," ");
            t1=a[1]+a[2]+a[3]+a[4]+a[5]+a[6]+a[7];i1=a[4];
            t2=$2+$3+$4+$5+$6+$7+$8;i2=$5;
            dt=t2-t1;di=i2-i1;
            if(dt>0)pct=int((dt-di)*100/dt);else pct=0;
            printf "router_cpu,host=%s,core=%s usage=%d\n","'$HOST'",$1,pct
        }' "$CPU_PREV" "$CPU_NOW")
    fi
    mv "$CPU_NOW" "$CPU_PREV"

    # WiFi clients
    WIFI_2G=0; WIFI_5G=0
    for iface in wlan0 wlan0-1 wlan1 wlan1-1; do
        cnt=$(iwinfo $iface assoclist 2>/dev/null | grep -c dBm)
        case $iface in wlan0|wlan0-1) WIFI_2G=$((WIFI_2G+cnt));; wlan1|wlan1-1) WIFI_5G=$((WIFI_5G+cnt));; esac
    done
    WIFI_TOTAL=$((WIFI_2G+WIFI_5G))
    DHCP_IOT=$(grep -c '192.168.8.' /tmp/dhcp.leases 2>/dev/null || echo 0)
    DHCP_LAN=$(grep -c '192.168.10.' /tmp/dhcp.leases 2>/dev/null || echo 0)

    # Traffic counters
    rx_wan=$(cat /sys/class/net/eth1/statistics/rx_bytes 2>/dev/null || echo 0)
    tx_wan=$(cat /sys/class/net/eth1/statistics/tx_bytes 2>/dev/null || echo 0)
    rx_wan2=$(cat /sys/class/net/lan5/statistics/rx_bytes 2>/dev/null || echo 0)
    tx_wan2=$(cat /sys/class/net/lan5/statistics/tx_bytes 2>/dev/null || echo 0)
    rx_lan=$(cat /sys/class/net/br-lan/statistics/rx_bytes 2>/dev/null || echo 0)
    tx_lan=$(cat /sys/class/net/br-lan/statistics/tx_bytes 2>/dev/null || echo 0)
    rx_iot=$(cat /sys/class/net/br-lan.8/statistics/rx_bytes 2>/dev/null || echo 0)
    tx_iot=$(cat /sys/class/net/br-lan.8/statistics/tx_bytes 2>/dev/null || echo 0)

    # WAN status
    mwan_out=$(mwan3 status 2>/dev/null)
    wan_up=$(echo "$mwan_out" | grep 'interface wan ' | grep -q online && echo 1 || echo 0)
    wan2_up=$(echo "$mwan_out" | grep 'interface secondwan ' | grep -q online && echo 1 || echo 0)

    # Ping latency + packet loss (5 pings)
    ping_wan_out=$(ping -c5 -W1 -I eth1 8.8.8.8 2>/dev/null)
    ping_wan=$(echo "$ping_wan_out" | awk -F'[/ ]' '/avg/{for(i=1;i<=NF;i++)if($i~/^[0-9]+\.[0-9]+$/){print $i;exit}}')
    loss_wan=$(echo "$ping_wan_out" | awk -F'[% ]' '/packet loss/{for(i=1;i<=NF;i++)if($i+0==$i && $i>=0)last=$i; print last}')
    ping_wan2_out=$(ping -c5 -W1 -I lan5 8.8.8.8 2>/dev/null)
    ping_wan2=$(echo "$ping_wan2_out" | awk -F'[/ ]' '/avg/{for(i=1;i<=NF;i++)if($i~/^[0-9]+\.[0-9]+$/){print $i;exit}}')
    loss_wan2=$(echo "$ping_wan2_out" | awk -F'[% ]' '/packet loss/{for(i=1;i<=NF;i++)if($i+0==$i && $i>=0)last=$i; print last}')
    [ -z "$ping_wan" ] && ping_wan=0
    [ -z "$ping_wan2" ] && ping_wan2=0
    [ -z "$loss_wan" ] && loss_wan=100
    [ -z "$loss_wan2" ] && loss_wan2=100

    # Conntrack usage
    ct_cur=$(wc -l < /proc/net/nf_conntrack 2>/dev/null || echo 0)
    ct_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 1)
    ct_pct=$(( ct_cur * 100 / ct_max ))

    # WAN public IPs
    wan_ip=$(curl -s --max-time 5 --interface eth1 ifconfig.me 2>/dev/null || echo "0.0.0.0")
    wan2_ip=$(curl -s --max-time 5 --interface lan5 ifconfig.me 2>/dev/null || echo "0.0.0.0")

    # Per-client bandwidth (top 10 by bytes from conntrack)
    CLIENT_LINES=$(awk '{
      src=""; b=0
      for(i=1;i<=NF;i++){
        if($i~/^src=192\.168\./){split($i,a,"="); src=a[2]}
        if($i~/^bytes=/){split($i,a,"="); b+=a[2]}
      }
      if(src!="" && src!="192.168.1.1" && src!="192.168.100.4") tot[src]+=b
    } END {
      n=0; for(ip in tot){arr[n]=tot[ip] SUBSEP ip; n++}
      for(i=0;i<n-1;i++) for(j=i+1;j<n;j++){
        split(arr[i],ai,SUBSEP); split(arr[j],aj,SUBSEP)
        if(aj[1]+0>ai[1]+0){t=arr[i];arr[i]=arr[j];arr[j]=t}
      }
      for(i=0;i<n&&i<10;i++){
        split(arr[i],a,SUBSEP)
        printf "router_client_bw,host='"$HOST"',ip=%s bytes=%di\n",a[2],a[1]
      }
    }' /proc/net/nf_conntrack 2>/dev/null)

    # Storage
    stor_root_pct=$(df / 2>/dev/null | awk 'NR==2{print int($3*100/$2)}')
    stor_usb_pct=$(df /tmp/mountd/disk2_part1 2>/dev/null | awk 'NR==2{print int($3*100/$2)}')
    [ -z "$stor_root_pct" ] && stor_root_pct=0
    [ -z "$stor_usb_pct" ] && stor_usb_pct=0

    # SQM drops (legacy)
    sqm1_drop=$(tc -s qdisc show dev eth1 2>/dev/null | sed -n 's/.*dropped \([0-9]*\).*/\1/p' | head -1)
    sqm2_drop=$(tc -s qdisc show dev lan5 2>/dev/null | sed -n 's/.*dropped \([0-9]*\).*/\1/p' | head -1)
    [ -z "$sqm1_drop" ] && sqm1_drop=0
    [ -z "$sqm2_drop" ] && sqm2_drop=0

    # SQM queue depth (CAKE detailed stats)
    parse_sqm() {
        local dev=$1 iface=$2
        local out=$(tc -s qdisc show dev $dev 2>/dev/null)
        local bl_b=$(echo "$out" | awk '/qdisc cake/{f=1} f && /backlog/{print $2; exit}' | sed 's/b$//')
        local bl_p=$(echo "$out" | awk '/qdisc cake/{f=1} f && /backlog/{print $3; exit}' | sed 's/p$//')
        local mem=$(echo "$out" | awk '/memory used:/{split($3,a,"b"); print a[1]; exit}')
        local cap=$(echo "$out" | awk '/capacity estimate:/{print $3; exit}' | sed 's/Mbit//')
        local pk_bulk=$(echo "$out" | awk '/pk_delay/{print $2; exit}' | sed 's/[a-z]*$//')
        local pk_be=$(echo "$out" | awk '/pk_delay/{print $3; exit}' | sed 's/[a-z]*$//')
        local pk_video=$(echo "$out" | awk '/pk_delay/{print $4; exit}' | sed 's/[a-z]*$//')
        local pk_voice=$(echo "$out" | awk '/pk_delay/{print $5; exit}' | sed 's/[a-z]*$//')
        local dr_bulk=$(echo "$out" | awk '/^  drops/{print $2; exit}')
        local dr_be=$(echo "$out" | awk '/^  drops/{print $3; exit}')
        local dr_video=$(echo "$out" | awk '/^  drops/{print $4; exit}')
        local dr_voice=$(echo "$out" | awk '/^  drops/{print $5; exit}')
        [ -z "$bl_b" ] && bl_b=0; [ -z "$bl_p" ] && bl_p=0
        [ -z "$mem" ] && mem=0; [ -z "$cap" ] && cap=0
        [ -z "$pk_bulk" ] && pk_bulk=0; [ -z "$pk_be" ] && pk_be=0
        [ -z "$pk_video" ] && pk_video=0; [ -z "$pk_voice" ] && pk_voice=0
        [ -z "$dr_bulk" ] && dr_bulk=0; [ -z "$dr_be" ] && dr_be=0
        [ -z "$dr_video" ] && dr_video=0; [ -z "$dr_voice" ] && dr_voice=0
        echo "router_sqm_queue,host=$HOST,iface=$iface backlog_bytes=${bl_b}i,backlog_pkts=${bl_p}i,mem_used=${mem}i,capacity=$cap"
        echo "router_sqm_delay,host=$HOST,iface=$iface,tin=bulk pk_delay=$pk_bulk"
        echo "router_sqm_delay,host=$HOST,iface=$iface,tin=besteffort pk_delay=$pk_be"
        echo "router_sqm_delay,host=$HOST,iface=$iface,tin=video pk_delay=$pk_video"
        echo "router_sqm_delay,host=$HOST,iface=$iface,tin=voice pk_delay=$pk_voice"
        echo "router_sqm_drops,host=$HOST,iface=$iface,tin=bulk drops=${dr_bulk}i"
        echo "router_sqm_drops,host=$HOST,iface=$iface,tin=besteffort drops=${dr_be}i"
        echo "router_sqm_drops,host=$HOST,iface=$iface,tin=video drops=${dr_video}i"
        echo "router_sqm_drops,host=$HOST,iface=$iface,tin=voice drops=${dr_voice}i"
    }
    SQM_LINES=$(parse_sqm eth1 wan; parse_sqm lan5 wan2)

    # WiFi noise
    noise_2g=$(iwinfo wlan0 info 2>/dev/null | grep -o 'Noise: -[0-9]*' | awk '{print $2}')
    noise_5g=$(iwinfo wlan1 info 2>/dev/null | grep -o 'Noise: -[0-9]*' | awk '{print $2}')
    [ -z "$noise_2g" ] && noise_2g=0
    [ -z "$noise_5g" ] && noise_5g=0

    # WiFi signal strength (avg RSSI per band)
    rssi_2g=$(iwinfo wlan0 assoclist 2>/dev/null | awk '/dBm/{match($0,/-[0-9]+ dBm/); val=substr($0,RSTART,RLENGTH-4); sum+=val; n++} END{if(n>0)print int(sum/n); else print 0}')
    rssi_5g=$(iwinfo wlan1 assoclist 2>/dev/null | awk '/dBm/{match($0,/-[0-9]+ dBm/); val=substr($0,RSTART,RLENGTH-4); sum+=val; n++} END{if(n>0)print int(sum/n); else print 0}')
    [ -z "$rssi_2g" ] && rssi_2g=0
    [ -z "$rssi_5g" ] && rssi_5g=0

    # WiFi TX/RX rates (avg per band in Mbit/s)
    rx_rate_2g=$(iwinfo wlan0 assoclist 2>/dev/null | awk '/RX:/{rx+=$2; nr++} END{if(nr>0)printf "%.1f",rx/nr; else print 0}')
    tx_rate_2g=$(iwinfo wlan0 assoclist 2>/dev/null | awk '/TX:/{tx+=$2; nt++} END{if(nt>0)printf "%.1f",tx/nt; else print 0}')
    rx_rate_5g=$(iwinfo wlan1 assoclist 2>/dev/null | awk '/RX:/{rx+=$2; nr++} END{if(nr>0)printf "%.1f",rx/nr; else print 0}')
    tx_rate_5g=$(iwinfo wlan1 assoclist 2>/dev/null | awk '/TX:/{tx+=$2; nt++} END{if(nt>0)printf "%.1f",tx/nt; else print 0}')

    # WiFi channel utilization (busy/active %)
    survey_2g=$(iw dev wlan0 survey dump 2>/dev/null)
    act_2g=$(echo "$survey_2g" | awk '/\[in use\]/{f=1} f && /active time/{print $4; exit}')
    busy_2g=$(echo "$survey_2g" | awk '/\[in use\]/{f=1} f && /busy time/{print $4; exit}')
    chan_util_2g=$([ -n "$act_2g" ] && [ "$act_2g" -gt 0 ] 2>/dev/null && awk "BEGIN{printf \"%d\", $busy_2g/$act_2g*100}" || echo 0)
    survey_5g=$(iw dev wlan1 survey dump 2>/dev/null)
    act_5g=$(echo "$survey_5g" | awk '/\[in use\]/{f=1} f && /active time/{print $4; exit}')
    busy_5g=$(echo "$survey_5g" | awk '/\[in use\]/{f=1} f && /busy time/{print $4; exit}')
    chan_util_5g=$([ -n "$act_5g" ] && [ "$act_5g" -gt 0 ] 2>/dev/null && awk "BEGIN{printf \"%d\", $busy_5g/$act_5g*100}" || echo 0)
    [ -z "$chan_util_2g" ] && chan_util_2g=0
    [ -z "$chan_util_5g" ] && chan_util_5g=0

    # DNS stats
    dns_total=$(grep -c 'query\[A\]' /tmp/dnsmasq.log 2>/dev/null || echo 0)
    dns_blocked=$(grep -c 'NXDOMAIN\|/etc/adblock' /tmp/dnsmasq.log 2>/dev/null || echo 0)
    # Build payload
    METRICS="router_system,host=$HOST uptime=${UPTIME}i,load=$LOAD,temp=${TEMP}i,mem_pct=${MEM_PCT}i,connections=${CONNS}i
router_storage,host=$HOST root_pct=${stor_root_pct}i,usb_pct=${stor_usb_pct}i
router_clients,host=$HOST wifi_total=${WIFI_TOTAL}i,wifi_2g=${WIFI_2G}i,wifi_5g=${WIFI_5G}i,dhcp_iot=${DHCP_IOT}i,dhcp_lan=${DHCP_LAN}i
router_traffic,host=$HOST,iface=wan rx=${rx_wan}i,tx=${tx_wan}i
router_traffic,host=$HOST,iface=wan2 rx=${rx_wan2}i,tx=${tx_wan2}i
router_traffic,host=$HOST,iface=lan rx=${rx_lan}i,tx=${tx_lan}i
router_traffic,host=$HOST,iface=iot rx=${rx_iot}i,tx=${tx_iot}i
router_wan,host=$HOST,iface=wan,pub_ip=$wan_ip status=${wan_up}i,ping=$ping_wan,loss=${loss_wan}i
router_wan,host=$HOST,iface=wan2,pub_ip=$wan2_ip status=${wan2_up}i,ping=$ping_wan2,loss=${loss_wan2}i
router_conntrack,host=$HOST current=${ct_cur}i,max=${ct_max}i,pct=${ct_pct}i
router_sqm,host=$HOST,iface=wan drops=${sqm1_drop}i
router_sqm,host=$HOST,iface=wan2 drops=${sqm2_drop}i
router_wifi,host=$HOST,band=2.4G noise=${noise_2g}i,rssi=${rssi_2g}i,chan_util=${chan_util_2g}i,rx_rate=$rx_rate_2g,tx_rate=$tx_rate_2g
router_wifi,host=$HOST,band=5G noise=${noise_5g}i,rssi=${rssi_5g}i,chan_util=${chan_util_5g}i,rx_rate=$rx_rate_5g,tx_rate=$tx_rate_5g
router_dns,host=$HOST total=${dns_total}i,blocked=${dns_blocked}i
router_procs,host=$HOST count=${PROC_COUNT}i,fd_open=${FD_OPEN}i,fd_max=${FD_MAX}i"

    if [ -n "$CPU_LINE" ]; then
        METRICS="$METRICS
$CPU_LINE"
    fi

    if [ -n "$CLIENT_LINES" ]; then
        METRICS="$METRICS
$CLIENT_LINES"
    fi

    if [ -n "$SQM_LINES" ]; then
        METRICS="$METRICS
$SQM_LINES"
    fi

    if [ -n "$TOP_MEM" ]; then
        METRICS="$METRICS
$TOP_MEM"
    fi

    curl -s -X POST "$INFLUX_URL" -u "$INFLUX_USER:$INFLUX_TOKEN" --data-binary "$METRICS" --max-time 10 2>/dev/null
}

while true; do
    push_metrics
    sleep 60
done
