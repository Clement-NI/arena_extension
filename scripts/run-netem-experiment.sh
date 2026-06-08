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
echo "Inspection : tc qdisc inside probe-iot"
SRC=$(kubectl get pods -n $NS -l app=probe-iot -o jsonpath='{.items[0].metadata.name}')
NODE=$(kubectl get pod -n $NS $SRC -o jsonpath='{.spec.nodeName}')
CID=$(kubectl get pod -n $NS $SRC -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|containerd://||')
PID=$(docker exec $NODE crictl inspect $CID | python3 -c "import json,sys; print(json.load(sys.stdin)['info']['pid'])")
docker exec $NODE nsenter -t $PID -n tc qdisc show dev eth0 \
  | tee "$LOG_DIR/qdisc-iot.txt" \
  | sed 's/^/    /'

# ─── 6. Run pairwise tests ───────────────────────────────────────
step "6. Pairwise measurements"

declare -A IP
for app in probe-iot probe-edge probe-cloud; do
  IP[$app]=$(kubectl get pod -n $NS -l app=$app -o jsonpath='{.items[0].status.podIP}')
done

declare -A POD
for app in probe-iot probe-edge probe-cloud; do
  POD[$app]=$(kubectl get pods -n $NS -l app=$app -o jsonpath='{.items[0].metadata.name}')
done

run_ping() {
  local from=$1 to=$2 expected_rtt=$3
  local result
  result=$(kubectl exec -n $NS "${POD[probe-$from]}" -- ping -c 30 -i 0.1 "${IP[probe-$to]}" 2>&1 | tail -2)
  echo "  $from → $to (RTT attendu $expected_rtt ms)"
  echo "$result" | sed 's/^/    /'
}

run_ping iot   edge   "4"     # exception 2ms × 2
run_ping iot   cloud  "60"    # inter-region 30ms × 2
run_ping edge  iot    "4"
run_ping edge  cloud  "60"
run_ping cloud iot    "60"
run_ping cloud edge   "60"

# ─── 7. Bandwidth check (UDP since TCP can't handle loss+delay) ──
step "7. Bandwidth check (UDP, intra-region attendu ~100Mbit, inter ~50Mbit)"
echo "iot → edge (exception 1Gbit, no loss) :"
kubectl exec -n $NS "${POD[probe-iot]}" -- \
  iperf3 -c "${IP[probe-edge]}" -u -b 1.2G -t 5 -f m 2>&1 | tail -3 | sed 's/^/    /' || true

echo ""
echo "iot → cloud (inter-region, 50Mbit cap, 2% loss) :"
kubectl exec -n $NS "${POD[probe-iot]}" -- \
  iperf3 -c "${IP[probe-cloud]}" -u -b 100M -t 5 -f m 2>&1 | tail -3 | sed 's/^/    /' || true

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
