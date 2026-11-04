#!/usr/bin/env bash
# Refuses a bench run on a host that cannot hold it: too little memory or disk, a load
# above the processors, or another bench run going on. Prints the host's state, then
# either "preflight: ok" (exit 0) or "preflight: refused: <reason>" (exit 3). Never
# stops nor removes anything.
#
#   bench/lib/preflight.sh <axis>
#   BENCH_MIN_FREE_GB=8 bench/lib/preflight.sh security
#
# Thresholds per axis (memory available, disk free, in GB), from §12 of the design;
# BENCH_MIN_FREE_GB raises the memory one, never lowers it below 6.
set -uo pipefail
axis=${1:?usage: preflight.sh <axis>}
case "$axis" in
  security) mem=5 disk=5 ;;
  correctness) mem=6 disk=2 ;;
  perf) mem=6 disk=2 ;;
  resilience) mem=5 disk=5 ;;
  compat) mem=5 disk=3 ;;
  *) echo "preflight: unknown axis $axis"; exit 2 ;;
esac
floor=${BENCH_MIN_FREE_GB:-6}
[ "$floor" -lt 6 ] && floor=6
[ "$mem" -lt "$floor" ] && mem=$floor

avail_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
avail_gb=$(( avail_kb / 1048576 ))
disk_gb=$(df -Pk / | awk 'NR == 2 {print int($4 / 1048576)}')
load1=$(cut -d' ' -f1 /proc/loadavg)
cpus=$(nproc)
echo "preflight: $axis: memory available ${avail_gb} GB (needs $mem), disk free ${disk_gb} GB (needs $disk), load $load1 on $cpus processors"
free -g | sed 's/^/  /'

refuse() { echo "preflight: refused: $1"; exit 3; }
[ "$avail_gb" -ge "$mem" ] || refuse "memory available ${avail_gb} GB, under $mem GB"
[ "$disk_gb" -ge "$disk" ] || refuse "disk free ${disk_gb} GB, under $disk GB"
awk -v l="$load1" -v c="$cpus" 'BEGIN {exit !(l < c)}' || refuse "load $load1, not under $cpus processors"
others=$(docker ps --format '{{.Label "com.docker.compose.project"}}' | grep '^akko-bench-' | sort -u | grep -vx "${BENCH_OWN_PROJECT:-}" || true)
[ -z "$others" ] || refuse "another bench run is going on: $(echo $others)"
echo "preflight: ok"
