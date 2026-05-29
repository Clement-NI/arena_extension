#!/usr/bin/env bash
# verify-topology.sh — ping every worker→worker pair, compare to the
# expected latency in the topology.yaml, report PASS/FAIL per link.
#
# Run AFTER `arena-topo compile -f probes -o probes.yaml && kubectl apply
# -f probes.yaml` AND after applying the NetworkChaos manifests.
#
# Usage:
#   ./scripts/verify-topology.sh [-t topology.yaml] [-n nodes.json] [-c 20]
#     -c   ping count per pair (default 20)
#     -T   tolerance percent for latency (default 20)

set -euo pipefail

TOPO=examples/topology.yaml
NODES=arena_testbed/nodes.json
PINGS=20
TOLERANCE=20

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t) TOPO="$2"; shift 2 ;;
    -n) NODES="$2"; shift 2 ;;
    -c) PINGS="$2"; shift 2 ;;
    -T) TOLERANCE="$2"; shift 2 ;;
    *)  echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

NS=arena-net

# Pull the expected matrix from arena-topo so we don't reimplement
# rule resolution here.
MATRIX=$(python3 -m tools.topology.cli -t "$TOPO" -n "$NODES" preview)

# CSV columns: from,to,latency,bw,loss,jitter,layers
echo "$MATRIX" | tail -n +2 | while IFS=, read -r src dst latency bw loss jitter layers; do
  [[ -z "$latency" ]] && continue

  src_lc=$(echo "$src" | tr '[:upper:]' '[:lower:]')
  dst_lc=$(echo "$dst" | tr '[:upper:]' '[:lower:]')

  expected_ms=$(echo "$latency" | sed 's/ms//')
  service="probe-${dst_lc}.${NS}.svc.cluster.local"
  pod_selector="-n ${NS} -l app=probe-${src_lc}"

  # ping <count> times, parse the avg from the rtt line.
  actual_ms=$(kubectl exec ${pod_selector} -- \
      ping -q -c "$PINGS" -i 0.2 "$service" 2>/dev/null \
      | awk -F'/' '/rtt/ {print $5}')

  if [[ -z "$actual_ms" ]]; then
    printf "  %-12s -> %-12s  FAIL (ping failed)\n" "$src" "$dst"
    continue
  fi

  diff_pct=$(awk -v a="$actual_ms" -v e="$expected_ms" \
    'BEGIN { if (e == 0) e = 0.0001; d = (a - e) / e * 100; if (d < 0) d = -d; printf "%.1f", d }')

  status="OK"
  if (( $(awk -v d="$diff_pct" -v t="$TOLERANCE" 'BEGIN { print (d > t) }') )); then
    status="FAIL"
  fi

  printf "  %-12s -> %-12s  expected=%6sms  actual=%7sms  diff=%5s%%  %s\n" \
      "$src" "$dst" "$expected_ms" "$actual_ms" "$diff_pct" "$status"
done
