#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# run-netem-experiment.sh
#
# Expérience de bout en bout : topologie 3 nœuds (IoT/Edge/Cloud)
# avec delay + bandwidth + loss appliqués simultanément via
# l'action `netem` composite de Chaos Mesh (1 CRD par paire).
#
# Prérequis :
#   - Cluster Arena up (kind fork single-host)
#   - Cilium + Prometheus + Chaos Mesh installés (./2-set_frameworks.sh)
#   - Nœuds K8s labellés testbed-role={IoT,Edge,Cloud,Controller}
# ─────────────────────────────────────────────────────────────────

set -euo pipefail

NS=arena-net
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR=/tmp/arena-netem-$(date +%Y%m%d-%H%M%S)
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_DIR/run.log") 2>&1

# ─── Paramètres modifiables ──────────────────────────────────────
TOPO_FILE="${TOPO_FILE:-/tmp/topology-netem.yaml}"
NODES_FILE="${NODES_FILE:-$REPO_ROOT/arena_testbed/nodes.json}"
PROBE_IMAGE="${PROBE_IMAGE:-networkstatic/iperf3}"

# Default topology (overridable via TOPO_FILE)
if [[ ! -f "$TOPO_FILE" ]]; then
  cat > "$TOPO_FILE" <<'EOF'
version: "1"
regions:
  edge_zone:  { members: [IoT, Edge] }
  cloud_zone: { members: [Cloud] }
defaults:
  intra-region:
    latency: 5ms
    bw: 100Mbit
    loss: "1"
  inter-region:
    latency: 50ms
    bw: 50Mbit
    loss: "3"
region_pairs:
  - { from: edge_zone, to: cloud_zone, latency: 30ms, bw: 100Mbit, loss: "2" }
exceptions:
  - { from: IoT, to: Edge, latency: 2ms, bw: 1Gbit, loss: "0" }
symmetric: true
EOF
fi

# ─── Helpers ─────────────────────────────────────────────────────
step() { echo; echo "═══════════ $* ═══════════"; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠ $*"; }
fail() { echo "  ✗ $*"; echo "logs in $LOG_DIR"; exit 1; }

# ─── 0. Préflight ────────────────────────────────────────────────
step "0. Préflight"
command -v kubectl >/dev/null  || fail "kubectl missing"
command -v docker  >/dev/null  || fail "docker missing"
kubectl cluster-info >/dev/null 2>&1 || fail "cluster injoignable"
kubectl get crd networkchaos.chaos-mesh.org >/dev/null 2>&1 || fail "Chaos Mesh non installé"
kubectl get nodes -l testbed-role >/dev/null 2>&1 || warn "Aucun nœud avec testbed-role label"
ok "prérequis OK"

# ─── 1. Topologie + génération YAML ──────────────────────────────
step "1. Topologie + compile"
echo "Topology source : $TOPO_FILE"
echo "─────────────────"
cat "$TOPO_FILE"
echo "─────────────────"

echo ""
echo "Resolved matrix :"
cd "$REPO_ROOT"
python3 -m tools.topology.cli -t "$TOPO_FILE" -n "$NODES_FILE" preview \
  | tee "$LOG_DIR/matrix.csv"

echo ""
echo "Compiling probes + chaos ..."
python3 -m tools.topology.cli -t "$TOPO_FILE" -n "$NODES_FILE" \
  compile -f probes -o "$LOG_DIR/probes.yaml"
python3 -m tools.topology.cli -t "$TOPO_FILE" -n "$NODES_FILE" \
  compile -f chaosmesh -o "$LOG_DIR/chaos.yaml"
N_CHAOS=$(grep -c '^kind: NetworkChaos' "$LOG_DIR/chaos.yaml")
ok "$N_CHAOS NetworkChaos generated (one per pair, composite netem)"

# ─── 2. Nettoyer l'état précédent ────────────────────────────────
step "2. Reset"
kubectl delete networkchaos --all -n $NS 2>/dev/null || true
kubectl delete namespace $NS --ignore-not-found 2>/dev/null
ok "namespace cleaned"

# ─── 3. Deploy probes ────────────────────────────────────────────
step "3. Deploy probes"
kubectl apply -f "$LOG_DIR/probes.yaml"
kubectl wait --for=condition=Ready pod -l app -n $NS --timeout=180s
ok "$(kubectl get pods -n $NS --no-headers | wc -l) probes Ready"

# ─── 4. Install ping inside probes ───────────────────────────────
step "4. Install ping + tc in probes"
for pod in $(kubectl get pods -n $NS -o jsonpath='{.items[*].metadata.name}'); do
  kubectl exec -n $NS $pod -- sh -c \
    'apt-get update -qq && apt-get install -y -qq iputils-ping iproute2' \
    >/dev/null 2>&1 || true
  kubectl exec -n $NS $pod -- which ping >/dev/null && ok "$pod ping ready"
done

# ─── 5. Apply NetworkChaos (composite netem per pair) ────────────
step "5. Apply NetworkChaos"
echo "Applying composite netem (delay + loss + rate per pair)..."
kubectl apply -f "$LOG_DIR/chaos.yaml"
sleep 25
ok "chaos applied"

echo ""
echo "NetworkChaos status :"
kubectl get networkchaos -n $NS

echo ""
echo "Inspection : tc qdisc inside a probe pod (first IoT-tier we find)"
SRC=$(kubectl get pods -n $NS -l arena.tier=IoT -o jsonpath='{.items[0].metadata.name}' 2>/dev/null \
      || kubectl get pods -n $NS -o jsonpath='{.items[0].metadata.name}')
NODE=$(kubectl get pod -n $NS $SRC -o jsonpath='{.spec.nodeName}')
CID=$(kubectl get pod -n $NS $SRC -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|containerd://||')
PID=$(docker exec $NODE crictl inspect $CID | python3 -c "import json,sys; print(json.load(sys.stdin)['info']['pid'])")
docker exec $NODE nsenter -t $PID -n tc qdisc show dev eth0 \
  | tee "$LOG_DIR/qdisc-iot.txt" \
  | sed 's/^/    /'

# ─── 6. Run pairwise tests ───────────────────────────────────────
step "6. Pairwise measurements"

# Discover one probe per tier dynamically (works for both single-instance
# and multi-instance topologies)
declare -A POD IP TIER_NAME
for tier in IoT Edge Cloud; do
  POD[$tier]=$(kubectl get pods -n $NS -l arena.tier=$tier -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  IP[$tier]=$(kubectl get pod -n $NS -l arena.tier=$tier -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)
  TIER_NAME[$tier]=$(kubectl get pod -n $NS -l arena.tier=$tier -o jsonpath='{.items[0].metadata.labels.arena\.node}' 2>/dev/null || true)
  echo "  $tier tier → ${POD[$tier]} (${TIER_NAME[$tier]} @ ${IP[$tier]})"
done

run_ping() {
  local from_tier=$1 to_tier=$2
  if [[ -z "${POD[$from_tier]:-}" || -z "${IP[$to_tier]:-}" ]]; then
    echo "  (skip $from_tier → $to_tier : tier missing)"
    return
  fi
  echo "  ${TIER_NAME[$from_tier]} → ${TIER_NAME[$to_tier]}"
  kubectl exec -n $NS "${POD[$from_tier]}" -- ping -c 30 -i 0.1 "${IP[$to_tier]}" 2>&1 \
    | tail -2 | sed 's/^/    /'
}

run_ping IoT   Edge
run_ping IoT   Cloud
run_ping Edge  IoT
run_ping Edge  Cloud
run_ping Cloud IoT
run_ping Cloud Edge

# ─── 7. Bandwidth check (UDP, sender-egress shaping verification) ──
step "7. Bandwidth check (UDP)"

# Helper: resolve a probe pod's IP from its arena.node label
_pod_ip() {
  kubectl get pod -n $NS -l "arena.node=$1" \
    -o jsonpath='{.items[0].status.podIP}' 2>/dev/null
}

# Helper: '100Mbit' / '1Gbit' / '500kbit' → integer Mbit (rounded down)
_bw_to_mbit() {
  local bw="$1"
  case "${bw,,}" in
    *gbit) echo $(( ${bw%[Gg]bit} * 1000 )) ;;
    *mbit) echo "${bw%[Mm]bit}" ;;
    *kbit) echo $(( ${bw%[Kk]bit} / 1000 )) ;;
    *)     echo 0 ;;
  esac
}

# verify_bw_udp <src_label> <dst_label> <configured_mbit>
#
# Pushes UDP at 1.1× configured rate (split across 4 streams) and reports
# what the sender's egress netem qdisc actually let through. Per Chaos Mesh
# design, all shaping is applied on the sender pod's egress, so the
# receiver-side throughput == the sender's enforced rate cap.
verify_bw_udp() {
  local src=$1 dst=$2 cfg=$3
  [[ -z "$cfg" || "$cfg" -eq 0 ]] && return

  local per_stream=$(( cfg * 11 / 10 / 4 ))M
  local dst_ip; dst_ip=$(_pod_ip "$dst")
  if [[ -z "$dst_ip" ]]; then
    printf "    %-22s ERR: arena.node=%s not found\n" "$src→$dst" "$dst"
    return
  fi

  local json
  json=$(kubectl exec -n $NS "deploy/probe-$src" -- \
    iperf3 -c "$dst_ip" -u -b "$per_stream" -l 1400 -w 16M -t 10 -O 2 -P 4 -J 2>/dev/null)
  if [[ -z "$json" ]]; then
    printf "    %-22s ERR: iperf3 no output\n" "$src→$dst"
    return
  fi

  echo "$json" | jq -r --arg src "$src" --arg dst "$dst" --arg cfg "$cfg" '
    (.end.sum_received.bits_per_second
     // (.end.sum.bits_per_second * (1 - .end.sum.lost_percent/100))) as $shaped |
    (.end.sum.bits_per_second) as $pushed |
    "    \($src)→\($dst)   configured=\($cfg)Mbit   sender_egress_actual=\($shaped/1e6|floor)Mbit   (pushed=\($pushed/1e6|floor)Mbit, drop=\(.end.sum.lost_percent|floor)%)"
  '
}

# Iterate every pair in matrix.csv and verify (skip self + zero-bw rows)
echo "Reading configured rates from matrix.csv → testing every (src, dst) pair..."
echo ""
{
  tail -n +2 "$LOG_DIR/matrix.csv" | while IFS=, read -r src dst latency bw loss jitter layers; do
    [[ -z "$src" || "$src" == "$dst" ]] && continue
    cfg_mbit=$(_bw_to_mbit "$bw")
    [[ "$cfg_mbit" -le 0 ]] && continue
    # arena.node labels are lowercase
    verify_bw_udp "${src,,}" "${dst,,}" "$cfg_mbit"
  done
} | tee "$LOG_DIR/bandwidth-udp.txt"

# ─── 8. Summary ──────────────────────────────────────────────────
step "DONE"
echo "Logs in $LOG_DIR"
ls -la "$LOG_DIR"
echo ""
echo "Files of interest :"
echo "  $LOG_DIR/run.log        — full execution log"
echo "  $LOG_DIR/matrix.csv     — resolved topology matrix"
echo "  $LOG_DIR/chaos.yaml     — generated NetworkChaos manifests"
echo "  $LOG_DIR/qdisc-iot.txt  — tc qdisc state in probe-iot"
echo "  $LOG_DIR/bandwidth-udp.txt — per-pair UDP shaper verification"
