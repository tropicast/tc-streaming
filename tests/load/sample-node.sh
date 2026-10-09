#!/usr/bin/env bash
# Sample the streaming node every N seconds during a load test (#12).
# Run on the node as ops (uses sudo for docker stats):
#   ssh ops@<node> 'bash -s 10' < tests/load/sample-node.sh > node.csv
# Columns: time, cpu busy %, memory available MB, tx Mbit/s, tcp sockets,
#          icecast cpu %, icecast mem, caddy cpu %, caddy mem,
#          tx packets/s, Caddy TCP segments out/s, Caddy TCP retransmits/s (#37)
# Listener connections end in Caddy's network namespace, so the TCP
# counters come from the Caddy container, not the host.
set -euo pipefail
interval=${1:-10}
iface=$(ip route show default | awk '{print $5; exit}')

cpu_counters() { awk '/^cpu /{idle=$5+$6; total=0; for (i=2; i<=NF; i++) total+=$i; print idle, total}' /proc/stat; }
tx_bytes() { cat "/sys/class/net/$iface/statistics/tx_bytes"; }
tx_packets() { cat "/sys/class/net/$iface/statistics/tx_packets"; }
caddy=$(sudo docker ps --format '{{.Names}}' | awk '/caddy-1/ { print; exit }')
# OutSegs and RetransSegs from the Tcp line of /proc/net/snmp.
tcp_counters() { sudo docker exec "$caddy" awk '/^Tcp:/ { getline; print $12, $13 }' /proc/net/snmp; }
rate() { awk -v d="$1" -v s="$interval" 'BEGIN { printf "%.0f", d / s }'; }

echo "time,cpu_busy_pct,mem_avail_mb,tx_mbps,tcp_sockets,icecast_cpu,icecast_mem,caddy_cpu,caddy_mem,tx_pps,out_segs_ps,retrans_ps"
read -r idle0 total0 < <(cpu_counters)
tx0=$(tx_bytes)
pk0=$(tx_packets)
read -r seg0 rtx0 < <(tcp_counters)
while sleep "$interval"; do
    read -r idle1 total1 < <(cpu_counters)
    tx1=$(tx_bytes)
    pk1=$(tx_packets)
    read -r seg1 rtx1 < <(tcp_counters)
    busy=$(awk -v i="$((idle1 - idle0))" -v t="$((total1 - total0))" 'BEGIN { printf "%.1f", t ? 100 * (1 - i / t) : 0 }')
    mbps=$(awk -v b="$((tx1 - tx0))" -v s="$interval" 'BEGIN { printf "%.1f", b * 8 / s / 1e6 }')
    mem=$(awk '/MemAvailable/ { printf "%d", $2 / 1024 }' /proc/meminfo)
    sockets=$(awk 'NR > 1' /proc/net/tcp /proc/net/tcp6 | wc -l)
    docker_stats=$(sudo docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}}' |
        awk '/icecast-1/ { ic = $2 "," $3 } /caddy-1/ { ca = $2 "," $3 } END { print ic "," ca }')
    tcp="$(rate $((pk1 - pk0))),$(rate $((seg1 - seg0))),$(rate $((rtx1 - rtx0)))"
    echo "$(date -u +%FT%TZ),$busy,$mem,$mbps,$sockets,$docker_stats,$tcp"
    idle0=$idle1 total0=$total1 tx0=$tx1 pk0=$pk1 seg0=$seg1 rtx0=$rtx1
done
