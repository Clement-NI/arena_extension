#!/usr/bin/env bash
# e2e-test.sh — full end-to-end smoke test of the topology pipeline.
#
# Run on the manager host AFTER 0-set_environments.sh has completed and
# `kind` is on PATH. Captures everything to /tmp/arena-e2e-<timestamp>/
# so you can paste any failure back to me without scrolling.

set -uo pipefail

TS=$(date +%Y%m%d-%H%M%S)
LOG_DIR=/tmp/arena-e2e-${TS}
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_DIR/run.log") 2>&1

REPO_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
NODES_JSON="${NODES_JSON:-$REPO_ROOT/examples/nodes-3tier-multi.json}"
TOPO_YAML="${TOPO_YAML:-$REPO_ROOT/examples/topology.yaml}"

step()  { echo; echo "═══════════ $* ═══════════"; }
ok()    { echo "  ✓ $*"; }
fail()  { echo "  ✗ $*"; echo "logs in $LOG_DIR"; exit 1; }

cd "$REPO_ROOT"

# ─── 0. preflight ───────────────────────────────────────────────────
step "0. preflight"
command -v docker  >/dev/null || fail "docker missing"
command -v kind    >/dev/null || fail "kind missing"
command -v kubectl >/dev/null || fail "kubectl missing"
command -v jq      >/dev/null || fail "jq missing"
command -v python3 >/dev/null || fail "python3 missing"
python3 -c "import yaml" 2>/dev/null || fail "pyyaml missing (pip3 install pyyaml)"

kind --help 2>&1 | grep -q -- '--multihost' || fail "kind has no --multihost flag (rebuild from fork)"

CGROUP=$(stat -fc %T /sys/fs/cgroup)
[[ "$CGROUP" == "cgroup2fs" ]] || fail "host is on cgroup v1 ($CGROUP). kind nodes will die at boot. Reboot with systemd.unified_cgroup_hierarchy=1 or use a different machine."

ok "all binaries present; cgroup=$CGROUP"

# ─── 1. capacity check ─────────────────────────────────────────────
step "1. capacity check"
CPU=$(docker info --format '{{.NCPU}}')
MEM_GIB=$(docker info --format '{{.MemTotal}}' | awk '{printf "%.2f", $1/1024/1024/1024}')
SUM_CPU=$(jq '[.hosts[].nodes[].cpu | tonumber] | add' "$NODES_JSON")
SUM_MEM_GIB=$(jq '[.hosts[].nodes[].memory | sub("Gi";"") | tonumber] | add' "$NODES_JSON")
ok "host: ${CPU} CPU / ${MEM_GIB} GiB"
ok "asks: ${SUM_CPU} CPU / ${SUM_MEM_GIB} GiB"
awk "BEGIN { exit !(${SUM_CPU} <= ${CPU} && ${SUM_MEM_GIB} <= ${MEM_GIB}) }" \
  || fail "$NODES_JSON asks more than the host has — pick a smaller config"

# ─── 2. preview the topology ───────────────────────────────────────
step "2. topology preview"
python3 -m tools.topology.cli -t "$TOPO_YAML" -n "$NODES_JSON" preview > "$LOG_DIR/matrix.csv"
LINKS=$(($(wc -l < "$LOG_DIR/matrix.csv") - 1))
ok "$LINKS resolved links (matrix.csv saved)"
python3 -m tools.topology.cli -t "$TOPO_YAML" -n "$NODES_JSON" stats

# ─── 3. launch cluster ─────────────────────────────────────────────
step "3. launch cluster"
cp "$NODES_JSON" arena_testbed/nodes.json
( cd arena_testbed && ./1-launch_cluster.sh ) || {
  kind export logs "$LOG_DIR/kind-logs" 2>/dev/null || true
  fail "cluster bring-up failed"
}
kubectl get nodes -o wide > "$LOG_DIR/nodes.txt"
ok "$(grep -c worker "$LOG_DIR/nodes.txt") workers + 1 control-plane up"

# ─── 4. install frameworks ─────────────────────────────────────────
step "4. install Cilium / Prometheus / Chaos Mesh"
( cd arena_testbed && ./2-set_frameworks.sh ) > "$LOG_DIR/frameworks.log" 2>&1 || {
  fail "frameworks install failed; check $LOG_DIR/frameworks.log"
}
kubectl wait --for=condition=Ready node --all --timeout=300s || fail "nodes not Ready"
ok "all nodes Ready, chaos-mesh + prometheus up"

# ─── 5. deploy probes ──────────────────────────────────────────────
step "5. deploy iperf3 probes"
python3 -m tools.topology.cli -t "$TOPO_YAML" -n "$NODES_JSON" \
  compile -f probes -o "$LOG_DIR/probes.yaml"
kubectl apply -f "$LOG_DIR/probes.yaml"
kubectl wait --for=condition=Ready pod -l app -n arena-net --timeout=180s \
  || fail "probes did not become Ready"
ok "$(kubectl get pods -n arena-net --no-headers | wc -l) probes Ready"

# ─── 6. measure baseline (no chaos applied) ────────────────────────
step "6. baseline ping (no chaos)"
"$REPO_ROOT/scripts/verify-topology.sh" -t "$TOPO_YAML" -n "$NODES_JSON" -c 5 -T 100000 \
  > "$LOG_DIR/baseline.txt" 2>&1 || true
tail -5 "$LOG_DIR/baseline.txt"
ok "baseline captured (most pairs should show < 1ms BEFORE chaos)"

# ─── 7. apply topology ─────────────────────────────────────────────
step "7. apply NetworkChaos topology"
python3 -m tools.topology.cli -t "$TOPO_YAML" -n "$NODES_JSON" \
  compile -f chaosmesh -o "$LOG_DIR/chaos.yaml"
NCHAOS=$(grep -c "^kind: NetworkChaos" "$LOG_DIR/chaos.yaml")
kubectl apply -f "$LOG_DIR/chaos.yaml"
sleep 15
ok "$NCHAOS NetworkChaos resources applied; waiting 15s for tc rules to settle"

# ─── 8. verify the injection ───────────────────────────────────────
step "8. verify injected topology"
"$REPO_ROOT/scripts/verify-topology.sh" -t "$TOPO_YAML" -n "$NODES_JSON" -c 20 -T 25 \
  > "$LOG_DIR/verify.txt" 2>&1
cat "$LOG_DIR/verify.txt"
FAILS=$(grep -c FAIL "$LOG_DIR/verify.txt" || true)
if [[ "$FAILS" -gt 0 ]]; then
  echo
  echo "  $FAILS link(s) outside the 25% tolerance — see $LOG_DIR/verify.txt"
  echo "  (this can happen for low-latency intra-region pairs where netem"
  echo "   resolution is coarse; check absolute values are roughly right.)"
fi

# ─── 9. summary ────────────────────────────────────────────────────
step "DONE — logs in $LOG_DIR"
ls -la "$LOG_DIR"
echo
echo "Send me $LOG_DIR/run.log + $LOG_DIR/verify.txt if anything looks wrong."
