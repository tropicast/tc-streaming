#!/usr/bin/env bash
# Sample the streaming node every N seconds during a load test (#12).
# Run on the node as ops (uses sudo for docker stats):
#   ssh ops@<node> 'bash -s 10' < tests/load/sample-node.sh > node.csv
# Columns: time, cpu busy %, memory available MB, tx Mbit/s, tcp sockets,
#          icecast cpu %, icecast mem, caddy cpu %, caddy mem
set -euo pipefail
interval=${1:-10}
iface=$(ip route show default | awk '{print $5; exit}')

cpu_counters() { awk '/^cpu /{idle=$5+$6; total=0; for (i=2; i<=NF; i++) total+=$i; print idle, total}' /proc/stat; }
tx_bytes() { cat "/sys/class/net/$iface/statistics/tx_bytes"; }

echo "time,cpu_busy_pct,mem_avail_mb,tx_mbps,tcp_sockets,icecast_cpu,icecast_mem,caddy_cpu,caddy_mem"
read -r idle0 total0 < <(cpu_counters)
tx0=$(tx_bytes)
while sleep "$interval"; do
    read -r idle1 total1 < <(cpu_counters)
    tx1=$(tx_bytes)
    busy=$(awk -v i="$((idle1 - idle0))" -v t="$((total1 - total0))" 'BEGIN { printf "%.1f", t ? 100 * (1 - i / t) : 0 }')
    mbps=$(awk -v b="$((tx1 - tx0))" -v s="$interval" 'BEGIN { printf "%.1f", b * 8 / s / 1e6 }')
    mem=$(awk '/MemAvailable/ { printf "%d", $2 / 1024 }' /proc/meminfo)
    sockets=$(awk 'NR > 1' /proc/net/tcp /proc/net/tcp6 | wc -l)
    docker_stats=$(sudo docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}}' |
        awk '/icecast-1/ { ic = $2 "," $3 } /caddy-1/ { ca = $2 "," $3 } END { print ic "," ca }')
    echo "$(date -u +%FT%TZ),$busy,$mem,$mbps,$sockets,$docker_stats"
    idle0=$idle1 total0=$total1 tx0=$tx1
done
