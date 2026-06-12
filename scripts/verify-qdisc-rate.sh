#!/usr/bin/env bash
# verify-qdisc-rate.sh — ground-truth bandwidth verification via kernel counters
#
# Bypasses chaos-mesh AND iperf3. For each (src, dst) pair in the topology:
#   1. Install netem (delay, rate, loss) directly on src pod's eth0 root.
#   2. Push dd | nc from src → dst at MAX speed (no app-side rate limit) so
#      the shaper is the bottleneck.
#   3. Sample `tc -s qdisc show` byte counter at T0 and T+DURATION on src,
#      compute (ΔBytes × 8) / Δt = enforced rate in bit/s.
#   4. Compare against the configured rate, report PASS/FAIL.
#   5. Remove the netem qdisc (clean state for next pair).
#
# The measurement is the SHAPER's actual byte output — immune to iperf3's
# userspace syscall limit, receiver kernel buffer overflow, TCP backoff,
# CNI quirks, etc. If this number matches the configured rate, the netem
# mechanism enforces the rate correctly. Period.
#
# Usage:
#   ./scripts/verify-qdisc-rate.sh [-t topology.yaml] [-n nodes.json]
#                                  [-T 10]          # tolerance %
#                                  [-d 10]          # seconds per pair

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

# '100Mbit' / '1Gbit' / '5Mbit' / '100kbit' → integer Mbit (floor)
_bw_to_mbit() {
  local bw="${1,,}"
  case "$bw" in
    *gbit) echo $(( ${bw%gbit} * 1000 )) ;;
    *mbit) echo "${bw%mbit}" ;;
    *kbit) echo $(( ${bw%kbit} / 1000 )) ;;
    *)     echo 0 ;;
  esac
}

# Resolve src pod → (node_container, host_pid) for nsenter
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

_qdisc_bytes() {
  local node=$1 pid=$2
  docker exec "$node" nsenter -t "$pid" -n tc -s qdisc show dev eth0 \
    | awk '/Sent/{print $2; exit}'
}

# Trap cleanup — never leave a stale qdisc or nc listener if user Ctrl-C's
declare -a INSTALLED_QDISCS=()
cleanup() {
  echo
  echo "Cleaning up …"
  for entry in "${INSTALLED_QDISCS[@]}"; do
    local n p
    n=${entry%%|*}; p=${entry##*|}
    docker exec "$n" nsenter -t "$p" -n tc qdisc del dev eth0 root 2>/dev/null || true
  done
  kubectl exec -n $NS deploy/probe-iot-1 -- pkill -f "nc -l" 2>/dev/null || true
  for d in iot-2 iot-3 edge-1 edge-2 cloud; do
    kubectl exec -n $NS "deploy/probe-$d" -- pkill -f "nc -l" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

verify_qdisc() {
  local src=$1 dst=$2 cfg_mbit=$3 cfg_lat=$4 cfg_loss=$5
  [[ "$cfg_mbit" -le 0 ]] && return

  _load_pod_ns "$src"
  local node=${NS_NODE[$src]} pid=${NS_PID[$src]}
  local dst_ip
  dst_ip=$(kubectl get pod -n $NS -l app=probe-$dst -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
  if [[ -z "$dst_ip" ]]; then
    printf "  %-22s  ERR: dst pod IP not found\n" "$src→$dst"
    return
  fi

  # Install netem with configured params (replace any existing root qdisc)
  docker exec "$node" nsenter -t "$pid" -n tc qdisc del dev eth0 root 2>/dev/null || true
  local opts="delay $cfg_lat rate ${cfg_mbit}mbit limit 10000"
  if [[ -n "$cfg_loss" && "$cfg_loss" != "0" && "$cfg_loss" != "0.0" ]]; then
    opts="$opts loss ${cfg_loss}%"
  fi
  if ! docker exec "$node" nsenter -t "$pid" -n tc qdisc add dev eth0 root netem $opts 2>/dev/null; then
    printf "  %-22s  ERR: tc qdisc add failed (opts: %s)\n" "$src→$dst" "$opts"
    return
  fi
  INSTALLED_QDISCS+=("$node|$pid")

  # Sink on dst pod
  kubectl exec -n $NS deploy/probe-$dst -- sh -c \
    "pkill -f 'nc -l' 2>/dev/null; sleep 0.3; (nc -l -p $PORT > /dev/null 2>&1 &)" \
    2>/dev/null
  sleep 0.5

  # T0 → push max → T1
  local b0 b1
  b0=$(_qdisc_bytes "$node" "$pid")

  kubectl exec -n $NS deploy/probe-$src -- timeout "$DURATION" sh -c \
    "dd if=/dev/zero bs=1M 2>/dev/null | nc -w 2 $dst_ip $PORT" \
    >/dev/null 2>&1 &
  local push_pid=$!
  sleep "$DURATION"
  b1=$(_qdisc_bytes "$node" "$pid")
  wait $push_pid 2>/dev/null || true

  # Compute rate in Mbit/s
  local delta=$((b1 - b0))
  local measured=$(( delta * 8 / DURATION / 1000000 ))

  # Cleanup this pair's qdisc immediately
  docker exec "$node" nsenter -t "$pid" -n tc qdisc del dev eth0 root 2>/dev/null || true

  # Compare
  local diff=$(( cfg_mbit > measured ? cfg_mbit - measured : measured - cfg_mbit ))
  local pct=$(( diff * 100 / cfg_mbit ))
  local status="OK"
  [ "$pct" -gt "$TOLERANCE" ] && status="FAIL"

  printf "  %-22s  configured=%5dMbit  measured=%5dMbit  diff=%3d%%  %s\n" \
    "$src→$dst" "$cfg_mbit" "$measured" "$pct" "$status"
}

MATRIX=$(python3 -m tools.topology.cli -t "$TOPO" -n "$NODES" preview)

echo "═══ QDISC-LEVEL BANDWIDTH (kernel tc -s counter; tolerance ±${TOLERANCE}%) ═══"
echo "    bypasses chaos-mesh + iperf3 ; per-pair test = ${DURATION}s"
echo

echo "$MATRIX" | tail -n +2 | while IFS=, read -r src dst latency bw loss jitter layers; do
  [[ -z "$src" || "$src" == "$dst" ]] && continue
  cfg_mbit=$(_bw_to_mbit "$bw")
  [[ "$cfg_mbit" -le 0 ]] && continue
  verify_qdisc "${src,,}" "${dst,,}" "$cfg_mbit" "$latency" "$loss"
done

echo
echo "All clean."
