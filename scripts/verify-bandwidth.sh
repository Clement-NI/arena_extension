#!/usr/bin/env bash
# verify-bandwidth.sh — for every worker→worker pair in the topology,
# push 1.1× the configured UDP rate across 4 parallel streams and report
# the sender-egress throughput that the netem qdisc actually let through.
#
# Per Chaos Mesh's design, all shaping is applied at the sender pod's
# egress, so the receiver-side bitrate == the shaper's enforced cap.
#
# Run AFTER probes are deployed AND NetworkChaos manifests applied
# (typically right after run-experiment.sh's step 13, or any time
# the chaos is in place).
#
# Usage:
#   ./scripts/verify-bandwidth.sh [-t topology.yaml] [-n nodes.json] [-T 15]
#     -T   tolerance percent for shaper rate (default 15)
#     -o   output directory for per-pair iperf3 JSON (default /tmp/arena-verify-bw-<ts>)

set -euo pipefail

TOPO=examples/topology.yaml
NODES=arena_testbed/nodes.json
TOLERANCE=15
OUT_DIR=/tmp/arena-verify-bw-$(date +%Y%m%d-%H%M%S)

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t) TOPO="$2"; shift 2 ;;
    -n) NODES="$2"; shift 2 ;;
    -T) TOLERANCE="$2"; shift 2 ;;
    -o) OUT_DIR="$2"; shift 2 ;;
    *)  echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

NS=arena-net
mkdir -p "$OUT_DIR"
echo "Logs → $OUT_DIR"
echo

# '100Mbit' / '1Gbit' / '500kbit' → integer Mbit (rounded down)
_bw_to_mbit() {
  local bw="${1,,}"
  case "$bw" in
    *gbit) echo $(( ${bw%gbit} * 1000 )) ;;
    *mbit) echo "${bw%mbit}" ;;
    *kbit) echo $(( ${bw%kbit} / 1000 )) ;;
    *)     echo 0 ;;
  esac
}

# Cache pod IPs once (probes use app=probe-<lowercase-label>)
declare -A POD_IP
for pod in $(kubectl get pods -n "$NS" -l app -o jsonpath='{.items[*].metadata.labels.app}'); do
  label=${pod#probe-}
  POD_IP[$label]=$(kubectl get pod -n "$NS" -l "app=$pod" \
                    -o jsonpath='{.items[0].status.podIP}')
done

verify_bw() {
  local src=$1 dst=$2 cfg=$3 cfg_loss=$4   # cfg_loss as string, e.g. "0", "0.5"
  [[ "$cfg" -le 0 ]] && return

  local dst_ip="${POD_IP[$dst]:-}"
  if [ -z "$dst_ip" ]; then
    printf "  %-22s  ERR: POD_IP[%s] empty (probe pod not Ready?)\n" "$src→$dst" "$dst"
    return
  fi

  local outfile="$OUT_DIR/iperf3-${src}-to-${dst}.json"
  local errfile="$OUT_DIR/iperf3-${src}-to-${dst}.err"
  local proto

  # 0% loss → TCP can saturate shaper (gives near wire-speed via kernel
  # pacing + GSO). Lossy links → must use UDP (TCP is Mathis-bounded at
  # ~MSS/(RTT·√p), produces numbers far below the shaper cap).
  if [[ "${cfg_loss:-0}" == "0" || "${cfg_loss:-0}" == "0.0" || -z "$cfg_loss" ]]; then
    proto=TCP
    kubectl exec -n "$NS" "deploy/probe-$src" -- \
      iperf3 -c "$dst_ip" -t 10 -O 2 -P 8 -J \
        >"$outfile" 2>"$errfile" || true
  else
    proto=UDP
    local per_stream parallel
    if [ "$cfg" -ge 500 ]; then
      parallel=8; per_stream=$(( cfg * 11 / 10 / 8 ))M
    else
      parallel=4; per_stream=$(( cfg * 11 / 10 / 4 ))M
    fi
    kubectl exec -n "$NS" "deploy/probe-$src" -- \
      iperf3 -c "$dst_ip" -u -b "$per_stream" -l 1200 \
             -t 10 -O 2 -P "$parallel" -J >"$outfile" 2>"$errfile" || true
  fi

  local iperf_err; iperf_err=$(jq -r '.error // empty' "$outfile" 2>/dev/null)
  if [ -n "$iperf_err" ]; then
    printf "  %-22s [%s] ERR: %s\n" "$src→$dst" "$proto" "$iperf_err"
    return
  fi
  if ! jq -e '.end.sum_received // .end.sum' "$outfile" >/dev/null 2>&1; then
    printf "  %-22s [%s] ERR: malformed iperf3 JSON (see %s)\n" "$src→$dst" "$proto" "$outfile"
    return
  fi

  jq -r --arg src "$src" --arg dst "$dst" --arg cfg "$cfg" \
        --arg tol "$TOLERANCE" --arg proto "$proto" '
    (.end.sum_received.bits_per_second // 0) as $recv_raw |
    (.end.sum.bits_per_second // 0)          as $sent |
    (.end.sum.lost_percent // 0)             as $loss |
    (if $recv_raw > 0 then $recv_raw
     else $sent * (1 - $loss/100) end)       as $shaped |
    ($shaped/1e6) as $shaped_mbit |
    (($cfg|tonumber) - $shaped_mbit) as $delta |
    (if $delta < 0 then -$delta else $delta end / ($cfg|tonumber) * 100) as $diff_pct |
    (if $diff_pct <= ($tol|tonumber) then "OK" else "FAIL" end) as $status |
    "  \($src)→\($dst) [\($proto)]  configured=\($cfg)Mbit  shaper_actual=\($shaped_mbit|floor)Mbit  pushed=\($sent/1e6|floor)Mbit  drop=\($loss|floor)%  diff=\($diff_pct*10|floor/10)%  \($status)"
  ' "$outfile"
}

# Drive every pair from the resolved topology matrix
MATRIX=$(python3 -m tools.topology.cli -t "$TOPO" -n "$NODES" preview)

echo "═══ BANDWIDTH (TCP for 0% loss / UDP for lossy; sender-egress shaper cap; tolerance ±${TOLERANCE}%) ═══"
echo "$MATRIX" | tail -n +2 | while IFS=, read -r src dst latency bw loss jitter layers; do
  [[ -z "$src" || "$src" == "$dst" ]] && continue
  cfg_mbit=$(_bw_to_mbit "$bw")
  [[ "$cfg_mbit" -le 0 ]] && continue
  verify_bw "${src,,}" "${dst,,}" "$cfg_mbit" "$loss"
done

echo
echo "Per-pair JSON saved to $OUT_DIR"
