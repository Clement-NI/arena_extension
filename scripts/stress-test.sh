#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# stress-test.sh
#
# Two stress tests on a single Arena host :
#   TEST 1 : maximum number of worker nodes (kind containers) before
#            the host becomes unstable (eviction, OOM, disk-full).
#   TEST 2 : maximum number of NetworkChaos rules applicable on a
#            given working cluster.
#
# Logs everything in /tmp/arena-stress-<timestamp>/.
# ─────────────────────────────────────────────────────────────────

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR=/tmp/arena-stress-$(date +%Y%m%d-%H%M%S)
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_DIR/run.log") 2>&1

# ─── Helpers ─────────────────────────────────────────────────────
log()  { echo "[$(date +%H:%M:%S)] $*"; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠ $*"; }
fail() { echo "  ✗ $*"; }

snapshot() {
  # Capture cluster + host state at the current moment
  local tag=$1
  log "snapshot: $tag"
  df -h / >> "$LOG_DIR/disk-${tag}.txt"
  free -h >> "$LOG_DIR/mem-${tag}.txt"
  kubectl get nodes -o wide >> "$LOG_DIR/nodes-${tag}.txt" 2>&1 || true
  kubectl get pods -A -o wide >> "$LOG_DIR/pods-${tag}.txt" 2>&1 || true
  kubectl get networkchaos -A >> "$LOG_DIR/chaos-${tag}.txt" 2>&1 || true
}

# ─────────────────────────────────────────────────────────────────
# TEST 1 — maximum workers per host
# ─────────────────────────────────────────────────────────────────
test_max_workers() {
  log "TEST 1 : maximum workers per host"
  echo ""

  local results="$LOG_DIR/workers-results.csv"
  echo "n_workers,host_disk_used_pct,nodes_ready,pods_failed,verdict" > "$results"

  # Try progressively larger cluster sizes
  for N in 5 10 15 20 25; do
    log "  trying N=$N workers"

    # Teardown previous attempt
    (cd "$REPO_ROOT/arena_testbed" && ./3-clean_cluster.sh >/dev/null 2>&1) || true

    # Build nodes.json with N workers (mix of tiers)
    python3 - "$N" > "$REPO_ROOT/arena_testbed/nodes.json" <<'PY'
import json, sys
n = int(sys.argv[1])
nodes = [
    {"name": "Controller", "tier": "Controller", "role": "control-plane",
     "cpu": "4", "memory": "8Gi"}
]
for i in range(1, n+1):
    tier = ["IoT", "Edge", "Cloud"][(i-1) % 3]
    cpu = {"IoT":"1","Edge":"2","Cloud":"2"}[tier]
    mem = {"IoT":"1Gi","Edge":"2Gi","Cloud":"4Gi"}[tier]
    nodes.append({
        "name": f"{tier}-{(i-1)//3+1}",
        "tier": tier, "role": "worker",
        "cpu": cpu, "memory": mem,
    })
print(json.dumps({
    "cluster_name": "arena-testbed",
    "hosts": [{"context": "default", "addr": "127.0.0.1", "nodes": nodes}]
}, indent=2))
PY

    # Try to bring up
    if ! (cd "$REPO_ROOT/arena_testbed" && timeout 300 ./1-launch_cluster.sh); then
      warn "  N=$N : cluster failed to come up"
      echo "$N,,,,LAUNCH_FAILED" >> "$results"
      break
    fi
    snapshot "n${N}-start"

    sleep 30
    READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready ")
    FAILED=$(kubectl get pods -A --no-headers 2>/dev/null | grep -cE "Evicted|Error|CrashLoopBackOff")
    DISK=$(df / | awk 'NR==2{print $5}' | tr -d '%')
    if [[ "$READY" -lt $((N+1)) ]] || [[ "$FAILED" -gt 5 ]]; then
      warn "  N=$N : unstable ($READY Ready, $FAILED failed pods, disk ${DISK}%)"
      echo "$N,$DISK,$READY,$FAILED,UNSTABLE" >> "$results"
      break
    else
      ok "  N=$N : stable ($READY Ready, disk ${DISK}%)"
      echo "$N,$DISK,$READY,$FAILED,OK" >> "$results"
    fi
  done

  echo ""
  log "TEST 1 results :"
  column -t -s, "$results"
}

# ─────────────────────────────────────────────────────────────────
# TEST 2 — maximum NetworkChaos rules
# ─────────────────────────────────────────────────────────────────
test_max_chaos() {
  log "TEST 2 : maximum NetworkChaos rules on a fixed cluster"
  echo ""

  # Assume a cluster is already up; if not, bring up the 9-node one
  if ! kubectl cluster-info >/dev/null 2>&1; then
    cp "$REPO_ROOT/examples/nodes-9.json" "$REPO_ROOT/arena_testbed/nodes.json"
    (cd "$REPO_ROOT/arena_testbed" && ./1-launch_cluster.sh && ./2-set_frameworks.sh)
    kubectl wait --for=condition=Ready node --all --timeout=300s
  fi

  local results="$LOG_DIR/chaos-results.csv"
  echo "n_rules,n_injected,n_pending,verdict" > "$results"

  # Deploy probes for the 9-node topology if not already there
  kubectl get ns arena-net >/dev/null 2>&1 || \
    python3 -m tools.topology.cli \
      -t "$REPO_ROOT/examples/topology-9node.yaml" \
      -n "$REPO_ROOT/examples/nodes-9.json" \
      compile -f probes -o /tmp/probes-stress.yaml
  kubectl apply -f /tmp/probes-stress.yaml >/dev/null 2>&1 || true
  kubectl wait --for=condition=Ready pod -l app -n arena-net --timeout=180s

  # Progressively apply more rules
  for COUNT in 10 30 60 100 150 200; do
    log "  trying $COUNT NetworkChaos rules"
    kubectl delete networkchaos --all -n arena-net >/dev/null 2>&1 || true
    sleep 5

    # Generate $COUNT identical NetworkChaos resources
    python3 - "$COUNT" > /tmp/chaos-stress.yaml <<'PY'
import sys
n = int(sys.argv[1])
print()
for i in range(n):
    print(f"""---
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: stress-{i:04d}
  namespace: arena-net
spec:
  action: netem
  mode: all
  selector:
    namespaces: [arena-net]
    labelSelectors: {{ arena.tier: IoT }}
  direction: to
  target:
    mode: all
    selector:
      namespaces: [arena-net]
      labelSelectors: {{ arena.tier: Edge }}
  delay: {{ latency: "{(i%50)+1}ms" }}
""")
PY

    kubectl apply -f /tmp/chaos-stress.yaml >/dev/null 2>&1
    sleep 30

    INJECTED=$(kubectl get networkchaos -n arena-net -o json 2>/dev/null | \
      python3 -c "import json,sys; d=json.load(sys.stdin); print(sum(1 for i in d['items'] if any(c['type']=='AllInjected' and c['status']=='True' for c in i.get('status',{}).get('conditions',[]))))")
    PENDING=$(( COUNT - INJECTED ))

    if [[ "$PENDING" -gt $((COUNT/10)) ]]; then
      warn "  $COUNT rules : only $INJECTED injected, $PENDING pending — ceiling"
      echo "$COUNT,$INJECTED,$PENDING,CEILING" >> "$results"
      break
    else
      ok "  $COUNT rules : $INJECTED injected"
      echo "$COUNT,$INJECTED,$PENDING,OK" >> "$results"
    fi
  done

  echo ""
  log "TEST 2 results :"
  column -t -s, "$results"
}

# ─── Run ─────────────────────────────────────────────────────────
case "${1:-both}" in
  workers) test_max_workers ;;
  chaos)   test_max_chaos ;;
  both)    test_max_workers; echo; test_max_chaos ;;
  *)       echo "usage: $0 [workers|chaos|both]"; exit 2 ;;
esac

echo ""
log "DONE. Logs : $LOG_DIR"
