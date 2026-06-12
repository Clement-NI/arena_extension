#!/usr/bin/env bash
# verify-qdisc-rate.sh — measure whether chaos-mesh actually enforces
# the configured bandwidth, by reading the kernel byte counter on the
# qdisc that chaos-mesh installed on each src pod's eth0.
#
# What this verifies
# ──────────────────
# For every (src, dst, configured_rate) pair in the resolved matrix:
#
#   1. Saturate the link: dd /dev/zero | nc dst:19999 — pushes faster
#      than any reasonable shaper, forcing the qdisc to become the
#      bottleneck.
#   2. Sample `tc -s qdisc show dev eth0` byte counter on src at T0
#      and T+DURATION. (ΔBytes × 8) / Δt = the rate that ACTUALLY
#      passed through whatever shaper chaos-mesh installed.
#   3. Compare to the topology-configured rate within ±TOLERANCE %.
#
# Interpretation
# ──────────────
#   measured ≈ configured  → chaos-mesh's netem IS enforcing the cap. ✓
#   measured ≫ configured  → chaos-mesh's qdisc is not in effect
#                            (likely `noqueue` on root, see header banner).
#   measured ≪ configured  → some other bottleneck (CPU, sink CPU, etc).
#
# This script does NOT install or modify any qdisc. It is purely an
# observer of whatever state chaos-mesh has left the pod in.
#
# Usage:
#   ./scripts/verify-qdisc-rate.sh [-t topology.yaml] [-n nodes.json]
#                                  [-T 10]   # tolerance %
#                                  [-d 10]   # seconds per pair

set -euo pipefail

TOPO=examples/topology.yaml
NODES=arena_testbed/nodes.json
TOLERANCE=10
DURATION=10
NS=arena-net
PORT=19999

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t) TOPO="$2"; shift 2 ;;
    -n) NODES="$2"; shift 2 ;;
    -T) TOLERANCE="$2"; shift 2 ;;
    -d) DURATION="$2"; shift 2 ;;
    *)  echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

_bw_to_mbit() {
  local bw="${1,,}"
  case "$bw" in
    *gbit) echo $(( ${bw%gbit} * 1000 )) ;;
    *mbit) echo "${bw%mbit}" ;;
    *kbit) echo $(( ${bw%kbit} / 1000 )) ;;
    *)     echo 0 ;;
  esac
}

declare -A NS_NODE NS_PID
_load_pod_ns() {
  local label=$1
  [[ -n "${NS_NODE[$label]:-}" ]] && return
  local pod node cid pid
  pod=$(kubectl get pod -n $NS -l app=probe-$label -o jsonpath='{.items[0].metadata.name}')
  node=$(kubectl get pod -n $NS "$pod" -o jsonpath='{.spec.nodeName}')
  cid=$(kubectl get pod -n $NS "$pod" -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|.*://||')
  pid=$(docker exec "$node" crictl inspect "$cid" | jq -r '.info.pid')
  NS_NODE[$label]="$node"
  NS_PID[$label]="$pid"
}

# Read total bytes sent on eth0 from /sys/class/net stats (covers all qdiscs).
# Falls back to root qdisc Sent counter if /sys not readable.
_iface_tx_bytes() {
  local node=$1 pid=$2
  docker exec "$node" nsenter -t "$pid" -n cat /sys/class/net/eth0/statistics/tx_bytes 2>/dev/null \
    || docker exec "$node" nsenter -t "$pid" -n tc -s qdisc show dev eth0 \
       | awk '/Sent/{print $2; exit}'
}

# Dump the qdisc tree once at startup so the user sees what chaos-mesh did.
_show_qdisc_state() {
  local label=$1
  local node=${NS_NODE[$label]} pid=${NS_PID[$label]}
  echo "--- $label eth0 qdisc state ---"
  docker exec "$node" nsenter -t "$pid" -n tc qdisc show dev eth0 | sed 's/^/    /'
}

# Trap: only kills nc listeners — never touches qdiscs (the whole point
# is to observe chaos-mesh's qdisc state untouched).
cleanup() {
  for d in iot-1 iot-2 iot-3 edge-1 edge-2 cloud; do
    kubectl exec -n $NS "deploy/probe-$d" -- pkill -f "nc -l" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

measure_pair() {
  local src=$1 dst=$2 cfg_mbit=$3
  [[ "$cfg_mbit" -le 0 ]] && return

  _load_pod_ns "$src"
  local node=${NS_NODE[$src]} pid=${NS_PID[$src]}

  local dst_ip
  dst_ip=$(kubectl get pod -n $NS -l app=probe-$dst -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
  if [[ -z "$dst_ip" ]]; then
    printf "  %-22s  ERR: dst pod IP not found\n" "$src→$dst"
    return
  fi

  # Sink on dst (busybox nc + alpine), kill any stale listener first
  kubectl exec -n $NS "deploy/probe-$dst" -- sh -c \
    "pkill -f 'nc -l' 2>/dev/null; sleep 0.3; (nc -l -p $PORT > /dev/null 2>&1 &)" \
    2>/dev/null
  sleep 0.5

  # Sample bytes, saturate, sample again
  local b0 b1
  b0=$(_iface_tx_bytes "$node" "$pid")

  kubectl exec -n $NS "deploy/probe-$src" -- timeout "$DURATION" sh -c \
    "dd if=/dev/zero bs=1M 2>/dev/null | nc -w 2 $dst_ip $PORT" \
    >/dev/null 2>&1 &
  local push_pid=$!
  sleep "$DURATION"
  b1=$(_iface_tx_bytes "$node" "$pid")
  wait $push_pid 2>/dev/null || true

  local delta=$((b1 - b0))
  local measured=$(( delta * 8 / DURATION / 1000000 ))

  local diff=$(( cfg_mbit > measured ? cfg_mbit - measured : measured - cfg_mbit ))
  local pct=$(( cfg_mbit > 0 ? diff * 100 / cfg_mbit : 100 ))
  local status="OK"
  [ "$pct" -gt "$TOLERANCE" ] && status="FAIL"

  printf "  %-22s  configured=%5dMbit  measured=%5dMbit  diff=%3d%%  %s\n" \
    "$src→$dst" "$cfg_mbit" "$measured" "$pct" "$status"
}

MATRIX=$(python3 -m tools.topology.cli -t "$TOPO" -n "$NODES" preview)

echo "═══ CHAOS-MESH BANDWIDTH ENFORCEMENT (observe-only; tolerance ±${TOLERANCE}%) ═══"
echo "    reads kernel eth0 tx_bytes on each src pod;"
echo "    pushes dd|nc at wire speed so the shaper is the bottleneck;"
echo "    does NOT install or modify any qdisc — pure observer of chaos-mesh state."
echo

# Show current qdisc state on every src pod once (informative for diagnosis)
echo "── current qdisc state (per src pod) ──"
for src in iot-1 iot-2 iot-3 edge-1 edge-2 cloud; do
  _load_pod_ns "$src" 2>/dev/null || continue
  _show_qdisc_state "$src"
done
echo

echo "── per-pair measurement ──"
echo "$MATRIX" | tail -n +2 | while IFS=, read -r src dst latency bw loss jitter layers; do
  [[ -z "$src" || "$src" == "$dst" ]] && continue
  cfg_mbit=$(_bw_to_mbit "$bw")
  [[ "$cfg_mbit" -le 0 ]] && continue
  measure_pair "${src,,}" "${dst,,}" "$cfg_mbit"
done

echo
echo "Done. If most rows FAIL with measured ≫ configured, chaos-mesh did"
echo "not install netem (check the qdisc state block above — root will be"
echo "'noqueue' on broken pods). If measured ≈ configured, the shaper is"
echo "enforcing the rate correctly."
