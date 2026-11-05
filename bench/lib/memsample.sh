#!/usr/bin/env bash
# Samples the memory of a compose project's containers, and the host's available
# memory, until it is killed: one line per container and per sample,
#   <epoch>\t<container>\t<usage / limit>      as docker stats prints it
#   <epoch>\t__host__\t<MemAvailable in kB>
# bench/lib/record.py reads the peaks from it. Started in the background by
# bench/run.sh around each suite; tests/load.sh starts it the same way.
#
#   bench/lib/memsample.sh <compose project> <out.tsv> [interval in seconds, default 5]
set -uo pipefail
project=${1:?usage: memsample.sh <project> <out.tsv> [interval]}
out=${2:?usage: memsample.sh <project> <out.tsv> [interval]}
interval=${3:-5}
while :; do
  now=$(date +%s)
  printf '%s\t__host__\t%s\n' "$now" "$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)" >> "$out"
  ids=$(docker ps -q --filter "label=com.docker.compose.project=$project")
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086
    docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}' $ids 2>/dev/null | sed "s/^/$now\t/" >> "$out"
  fi
  sleep "$interval"
done
