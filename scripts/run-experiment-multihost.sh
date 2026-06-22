#!/usr/bin/env bash
# run-experiment-multihost.sh — full Arena experiment across MULTIPLE hosts.
#
# Multi-host sibling of run-experiment.sh. Drives the Arena kind fork's
# Swarm-overlay mode (`--multihost --bootstrap-swarm`) so IoT / Edge / Cloud
# nodes live on different physical machines, then verifies the things that only
# matter once traffic crosses a machine boundary:
#
#   A. Swarm + overlay are up and every declared host joined.
#   B. Every probe pod landed on the physical host nodes.json asked for
#      (checked via the arena.host label).
#   C. Cross-host pods can reach each other over the overlay (pre-chaos).
#   D. intra-host vs inter-host baseline (overlay/VXLAN overhead) so the
#      shaped numbers have the right reference point.
#   E. Chaos (latency / bandwidth / loss) takes effect on a CROSS-HOST link.
#
# This aligns with the current Arena multi-host config conventions:
#   - 1-launch_cluster.sh publishes the apiserver on the manager's public IP
#     (networking.apiServerAddress), so kubectl works without a 127.0.0.1 hack.
#   - 2-set_frameworks.sh installs Cilium with k8sServiceHost = nodes.json
#     hosts[0].addr for multi-host — so nodes.json MUST carry the REAL manager
#     IP. This script generates nodes.json with detected IPs to guarantee that.
#   - the SAME docker version must run on every host or the Swarm overlay does
#     not forward cross-host traffic — this script checks that up front.
#
# Run from the SWARM MANAGER host. The worker hosts must already exist as
# docker contexts (bootstrap once with arena_testbed/0b-setup-multihost.sh).
#
# Usage:
#   sudo ./scripts/run-experiment-multihost.sh
#
# Environment overrides:
#   ARENA_DIR / ARENA_BRANCH / ARENA_REPO    # as in run-experiment.sh
#   KIND_REPO / KIND_BRANCH / KIND_SRC       # as in run-experiment.sh
#   NODES_JSON=...    # use THIS nodes.json verbatim instead of auto-generating
#   TOPO_YAML=...     # default examples/topology-multihost.yaml
#   WORKERS="ctx1 ctx2"   # worker docker contexts (default: all non-default)
#   SKIP_INSTALL=1    # skip toolchain install if already present
#   SKIP_LAUNCH=1     # reuse a running cluster; jump straight to probes+verify

set -uo pipefail

# ───────────────────────────────────────────────────────────────
# Configuration
# ───────────────────────────────────────────────────────────────
ARENA_REPO="${ARENA_REPO:-https://github.com/Clement-NI/arena_extension.git}"
ARENA_BRANCH="${ARENA_BRANCH:-arena-multihost-yaml-pinning}"
ARENA_DIR="${ARENA_DIR:-$HOME/arena_extension}"

KIND_REPO="${KIND_REPO:-https://github.com/Clement-NI/kind_extension_for_arena.git}"
KIND_BRANCH="${KIND_BRANCH:-main}"
KIND_SRC="${KIND_SRC:-/opt/kind_extension_for_arena}"

GO_VERSION="${GO_VERSION:-1.26.3}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.33.2}"
HELM_VERSION="${HELM_VERSION:-v3.17.4}"
PROBE_IMAGE="${PROBE_IMAGE:-mirror.gcr.io/library/alpine:3.19}"
CLUSTER=arena-testbed

TS=$(date +%Y%m%d-%H%M%S)
LOG_DIR=/tmp/arena-experiment-mh-${TS}
mkdir -p "$LOG_DIR"

if [[ -t 1 ]]; then
  RED=$'\e[1;31m'; GREEN=$'\e[1;32m'; YELLOW=$'\e[1;33m'; BLUE=$'\e[1;34m'; RESET=$'\e[0m'
else RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""; fi
step()  { echo; echo "${BLUE}═════════════════ $* ═════════════════${RESET}" | tee -a "$LOG_DIR/run.log"; }
log()   { echo "${BLUE}[INFO]${RESET}  $*"  | tee -a "$LOG_DIR/run.log"; }
ok()    { echo "${GREEN}  ✓${RESET}      $*" | tee -a "$LOG_DIR/run.log"; }
warn()  { echo "${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOG_DIR/run.log"; }
err()   { echo "${RED}[ERR]${RESET}   $*"   | tee -a "$LOG_DIR/run.log"; }
fail()  { err "$1"; err "logs in $LOG_DIR"; exit 1; }

# ───────────────────────────────────────────────────────────────
# 1. Preflight (host + kernel)
# ───────────────────────────────────────────────────────────────
step "1. Preflight"
[[ $(id -u) -eq 0 ]] || fail "must run as root (sudo)"
CGROUP=$(stat -fc %T /sys/fs/cgroup)
[[ "$CGROUP" == "cgroup2fs" ]] || fail "host is on $CGROUP — need cgroup v2"
sysctl -w fs.inotify.max_user_instances=8192 >/dev/null
sysctl -w fs.inotify.max_user_watches=524288 >/dev/null
sysctl -w fs.file-max=2097152                >/dev/null
command -v jq >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq jq >/dev/null 2>&1; }
ok "root, cgroup v2, inotify limits bumped"

# ───────────────────────────────────────────────────────────────
# 2-5. Toolchain (docker / Go / kubectl / helm)
# ───────────────────────────────────────────────────────────────
if [[ "${SKIP_INSTALL:-0}" != "1" ]]; then
  step "2-5. Install toolchain"
  apt-get update -qq >>"$LOG_DIR/apt.log" 2>&1
  apt-get install -y -qq docker.io jq python3-yaml curl wget git net-tools >>"$LOG_DIR/apt.log" 2>&1 \
    || fail "apt install failed (see $LOG_DIR/apt.log)"
  systemctl start docker 2>/dev/null || service docker start 2>/dev/null || true
  docker info >/dev/null 2>&1 || fail "docker daemon not running"
  if [[ ! -x /usr/local/go/bin/go ]]; then
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz
    rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz && rm /tmp/go.tgz
  fi
  command -v kubectl >/dev/null || {
    curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    chmod +x kubectl && mv kubectl /usr/local/bin/; }
  command -v helm >/dev/null || {
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | tar xz -C /tmp
    mv /tmp/linux-amd64/helm /usr/local/bin/ && rm -rf /tmp/linux-amd64; }
  ok "docker / Go / kubectl / helm ready"
fi
unset GOROOT GOTOOLCHAIN
export PATH=/usr/local/go/bin:$PATH
hash -r 2>/dev/null || true

# ───────────────────────────────────────────────────────────────
# 6. Build kind from fork (must support --multihost)
# ───────────────────────────────────────────────────────────────
step "6. Build kind from fork"
if [[ ! -d "$KIND_SRC/.git" ]]; then
  mkdir -p "$(dirname "$KIND_SRC")"
  git clone "$KIND_REPO" "$KIND_SRC" >>"$LOG_DIR/kind-clone.log" 2>&1
fi
git -C "$KIND_SRC" fetch origin >>"$LOG_DIR/kind-fetch.log" 2>&1
git -C "$KIND_SRC" checkout "$KIND_BRANCH" >>"$LOG_DIR/kind-fetch.log" 2>&1
git -C "$KIND_SRC" pull --ff-only origin "$KIND_BRANCH" >>"$LOG_DIR/kind-fetch.log" 2>&1 || true
if ! { command -v kind >/dev/null && kind --help 2>&1 | grep -q -- '--multihost'; }; then
  ( cd "$KIND_SRC" && /usr/local/go/bin/go build -o /tmp/kind . ) >>"$LOG_DIR/kind-build.log" 2>&1 \
    || fail "kind build failed (see $LOG_DIR/kind-build.log)"
  install -m 0755 /tmp/kind /usr/local/bin/kind && rm -f /tmp/kind
fi
kind --help 2>&1 | grep -q -- '--multihost' || fail "installed kind missing --multihost — rebuild from fork"
ok "kind supports --multihost ($(kind --version))"

# ───────────────────────────────────────────────────────────────
# 7. Fetch arena
# ───────────────────────────────────────────────────────────────
step "7. Fetch arena_extension"
if [[ ! -d "$ARENA_DIR/.git" ]]; then
  git clone "$ARENA_REPO" "$ARENA_DIR" >>"$LOG_DIR/arena-clone.log" 2>&1
fi
git -C "$ARENA_DIR" fetch origin >>"$LOG_DIR/arena-fetch.log" 2>&1
git -C "$ARENA_DIR" checkout "$ARENA_BRANCH" >>"$LOG_DIR/arena-fetch.log" 2>&1
git -C "$ARENA_DIR" pull --ff-only origin "$ARENA_BRANCH" >>"$LOG_DIR/arena-fetch.log" 2>&1 || true
cd "$ARENA_DIR"
ok "arena at $ARENA_DIR (branch $(git rev-parse --abbrev-ref HEAD))"
TOPO_YAML="${TOPO_YAML:-$ARENA_DIR/examples/topology-multihost.yaml}"
[[ -f "$TOPO_YAML" ]] || fail "$TOPO_YAML not found"

# ───────────────────────────────────────────────────────────────
# 8. Generate nodes.json with REAL IPs (manager + worker contexts)
# ───────────────────────────────────────────────────────────────
# 2-set_frameworks.sh reads hosts[0].addr for Cilium's k8sServiceHost and
# 1-launch publishes the apiserver there, so the manager IP must be real (not a
# placeholder). We detect it here. Worker contexts come from $WORKERS or every
# non-default docker context. Layout: manager=Controller+Cloud, then Edge then
# IoT (matches examples/topology-multihost.yaml node names).
step "8. Generate nodes.json (real IPs)"
NODES_JSON_OUT="$ARENA_DIR/arena_testbed/nodes.json"
if [[ -n "${NODES_JSON:-}" ]]; then
  [[ -f "$NODES_JSON" ]] || fail "NODES_JSON=$NODES_JSON not found"
  cp "$NODES_JSON" "$NODES_JSON_OUT"
  ok "using provided NODES_JSON ($NODES_JSON)"
else
  MGR_IP=$(hostname -I | awk '{print $1}')
  [[ -n "$MGR_IP" ]] || fail "could not detect manager IP (hostname -I)"
  if [[ -n "${WORKERS:-}" ]]; then read -r -a WCTX <<< "$WORKERS"
  else mapfile -t WCTX < <(docker context ls --format '{{.Name}}' | grep -v '^default$' | sort); fi
  [[ "${#WCTX[@]}" -eq 2 ]] || fail "need exactly 2 worker docker contexts (got ${#WCTX[@]}: ${WCTX[*]:-none}). Set WORKERS=\"ctx1 ctx2\" or NODES_JSON=<file>."
  W0="${WCTX[0]}"; W1="${WCTX[1]}"
  W0_IP=$(ssh -o BatchMode=yes -o ConnectTimeout=5 root@"$W0" "hostname -I | awk '{print \$1}'" 2>/dev/null) \
    || fail "ssh root@$W0 failed (context/host not reachable)"
  W1_IP=$(ssh -o BatchMode=yes -o ConnectTimeout=5 root@"$W1" "hostname -I | awk '{print \$1}'" 2>/dev/null) \
    || fail "ssh root@$W1 failed (context/host not reachable)"
  cat > "$NODES_JSON_OUT" <<JSON
{
  "cluster_name": "$CLUSTER",
  "hosts": [
    { "context": "default", "addr": "$MGR_IP", "ssh": "",
      "nodes": [
        { "name": "Controller", "tier": "Controller", "role": "control-plane", "cpu": "4", "memory": "8Gi" },
        { "name": "Cloud", "tier": "Cloud", "role": "worker", "cpu": "8", "memory": "16Gi" }
      ]},
    { "context": "$W0", "addr": "$W0_IP", "ssh": "ssh://root@$W0",
      "nodes": [
        { "name": "Edge-1", "tier": "Edge", "role": "worker", "cpu": "2", "memory": "4Gi" },
        { "name": "Edge-2", "tier": "Edge", "role": "worker", "cpu": "2", "memory": "4Gi" }
      ]},
    { "context": "$W1", "addr": "$W1_IP", "ssh": "ssh://root@$W1",
      "nodes": [
        { "name": "IoT-1", "tier": "IoT", "role": "worker", "cpu": "1", "memory": "2Gi" },
        { "name": "IoT-2", "tier": "IoT", "role": "worker", "cpu": "1", "memory": "2Gi" },
        { "name": "IoT-3", "tier": "IoT", "role": "worker", "cpu": "1", "memory": "2Gi" }
      ]}
  ]
}
JSON
  ok "manager=$MGR_IP  $W0=$W0_IP  $W1=$W1_IP"
fi
NODES_JSON="$NODES_JSON_OUT"
jq '.hosts[] | {context, addr, nodes: [.nodes[].name]}' "$NODES_JSON" | tee -a "$LOG_DIR/run.log"

# ───────────────────────────────────────────────────────────────
# 9. Multi-host preflight: hosts, contexts, docker-version, capacity
# ───────────────────────────────────────────────────────────────
step "9. Multi-host preflight"
HOSTS_LEN=$(jq '.hosts | length' "$NODES_JSON")
[[ "$HOSTS_LEN" -ge 2 ]] || fail "nodes.json has $HOSTS_LEN host(s) — use run-experiment.sh for single-host"
CP_HOST_IDX=$(jq '[.hosts[] | [.nodes[].role]] | map(any(. == "control-plane")) | index(true)' "$NODES_JSON")
[[ "$CP_HOST_IDX" == "0" ]] || fail "control-plane must live on hosts[0] (the Swarm manager); found on host index $CP_HOST_IDX"
TOTAL_NODES=$(jq '[.hosts[].nodes[]] | length' "$NODES_JSON")
log "$HOSTS_LEN hosts, $TOTAL_NODES kube nodes declared"

# 9a. every remote host must be a reachable docker context
while read -r ctx; do
  [[ -z "$ctx" || "$ctx" == "default" ]] && continue
  docker context inspect "$ctx" >/dev/null 2>&1 \
    || fail "docker context '$ctx' missing — bootstrap with: bash arena_testbed/0b-setup-multihost.sh <hosts...>"
  docker --context "$ctx" info >/dev/null 2>&1 \
    || fail "docker context '$ctx' unreachable — check SSH (root@) and that docker runs there"
  ok "context '$ctx' reachable"
done < <(jq -r '.hosts[].context' "$NODES_JSON")

# 9b. docker version MUST match across hosts (mismatched versions break the
#     Swarm overlay data plane cross-host — our #1 multi-host failure mode)
LOCAL_DVER=$(docker version --format '{{.Server.Version}}')
DMISMATCH=0
printf "    %-16s %s\n" "default" "$LOCAL_DVER" | tee -a "$LOG_DIR/run.log"
while read -r ctx; do
  [[ "$ctx" == "default" ]] && continue
  v=$(docker --context "$ctx" version --format '{{.Server.Version}}' 2>/dev/null)
  printf "    %-16s %s\n" "$ctx" "${v:-UNREACHABLE}" | tee -a "$LOG_DIR/run.log"
  [[ "$v" == "$LOCAL_DVER" ]] || DMISMATCH=1
done < <(jq -r '.hosts[].context' "$NODES_JSON")
[[ "$DMISMATCH" == 0 ]] \
  && ok "docker version consistent across all hosts ($LOCAL_DVER)" \
  || fail "docker version MISMATCH across hosts — align them (same version everywhere) or the cross-host overlay will not forward"

# 9c. per-host capacity (each node must fit on ITS host, not a global sum)
BAD=0
while read -r ctx host_cpu sum_cpu; do
  if [[ -z "$host_cpu" || "$host_cpu" == "null" || "$host_cpu" == '""' ]]; then
    if [[ "$ctx" == "default" ]]; then host_cpu=$(docker info --format '{{.NCPU}}')
    else host_cpu=$(docker --context "$ctx" info --format '{{.NCPU}}' 2>/dev/null); fi
  fi
  if [[ -n "$host_cpu" && "$sum_cpu" -gt "$host_cpu" ]]; then
    warn "host '$ctx' oversubscribed: nodes want ${sum_cpu} CPU but host has ${host_cpu}"; BAD=1
  else
    ok "host '$ctx' capacity OK: ${sum_cpu}/${host_cpu} CPU"
  fi
done < <(jq -r '.hosts[] | "\(.context) \(.cpu // "null") \([.nodes[].cpu | tonumber] | add)"' "$NODES_JSON")
[[ "$BAD" == 0 ]] || fail "fix oversubscribed host(s) in nodes.json"

# ───────────────────────────────────────────────────────────────
# 10. Launch the multi-host cluster + frameworks
# ───────────────────────────────────────────────────────────────
mapfile -t WORKER_CTX < <(jq -r '.hosts[].context' "$NODES_JSON" | grep -v '^default$')
if [[ "${SKIP_LAUNCH:-0}" != "1" ]]; then
  step "10. Launch multi-host kind cluster"
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER}$"; then
    warn "previous $CLUSTER cluster found, cleaning first..."
    bash arena_testbed/3b-clean-multihost.sh "${WORKER_CTX[@]}" >>"$LOG_DIR/cleanup.log" 2>&1 || true
  fi
  bash arena_testbed/1-launch_cluster.sh >"$LOG_DIR/launch.log" 2>&1 \
    || fail "cluster launch failed (see $LOG_DIR/launch.log)"
  grep -E "apiserver published|Placement plan" "$LOG_DIR/launch.log" | sed 's/^/    /' | tee -a "$LOG_DIR/run.log" || true

  step "10b. Install Cilium + Prometheus + Chaos Mesh"
  bash arena_testbed/2-set_frameworks.sh >"$LOG_DIR/frameworks.log" 2>&1 \
    || warn "framework install returned non-zero (Prometheus --wait may have timed out; see $LOG_DIR/frameworks.log)"
  grep -E "k8sServiceHost" "$LOG_DIR/frameworks.log" | sed 's/^/    /' | tee -a "$LOG_DIR/run.log" || true
else
  step "10. SKIP_LAUNCH=1 — reusing running cluster"
  kubectl config use-context "kind-${CLUSTER}" >/dev/null 2>&1 || true
fi

# 10c. kubeconfig sanity. With apiServerAddress injected the kind kubeconfig
#      points at the manager IP:6443 and works directly; if not, rebuild it.
if ! kubectl get nodes >/dev/null 2>&1; then
  warn "kubectl not reaching apiserver — rebuilding kubeconfig from control-plane"
  CP=$(docker ps --filter "label=io.x-k8s.kind.cluster=${CLUSTER}" --filter "name=control-plane" --format '{{.Names}}' | head -1)
  PORT=$(docker port "$CP" 6443 | awk -F: '{print $NF}' | head -1)
  mkdir -p ~/.kube
  docker exec "$CP" cat /etc/kubernetes/admin.conf > ~/.kube/config 2>/dev/null
  sed -i "s#server: https://.*#server: https://127.0.0.1:$PORT#" ~/.kube/config
fi

kubectl wait --for=condition=Ready node --all --timeout=300s >>"$LOG_DIR/wait-nodes.log" 2>&1 \
  || fail "some nodes did not become Ready (see $LOG_DIR/wait-nodes.log)"
NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
[[ "$NODES" -eq "$TOTAL_NODES" ]] || fail "expected $TOTAL_NODES nodes, got $NODES"
ok "cluster up — $NODES nodes Ready"

# ═══════════════════════════════════════════════════════════════
# VERIFICATION A — Swarm + overlay
# ═══════════════════════════════════════════════════════════════
step "A. Swarm + overlay health"
SWARM_NODES=$(docker node ls --format '{{.Hostname}} {{.Status}} {{.ManagerStatus}}' 2>>"$LOG_DIR/swarm.log")
if [[ -z "$SWARM_NODES" ]]; then
  warn "docker node ls returned nothing — not a Swarm manager? (single-bridge fallback?)"
else
  echo "$SWARM_NODES" | sed 's/^/      /' | tee -a "$LOG_DIR/run.log"
  SWARM_COUNT=$(echo "$SWARM_NODES" | grep -c -i "ready")
  [[ "$SWARM_COUNT" -ge "$HOSTS_LEN" ]] \
    && ok "$SWARM_COUNT/$HOSTS_LEN Swarm hosts Ready" \
    || warn "only $SWARM_COUNT/$HOSTS_LEN Swarm hosts Ready"
fi
OVERLAY=$(docker network ls --filter driver=overlay --format '{{.Name}}' | tr '\n' ' ')
[[ -n "$OVERLAY" ]] && ok "overlay network(s): $OVERLAY" || warn "no overlay network found"

# ═══════════════════════════════════════════════════════════════
# VERIFICATION B — node → physical host placement
# ═══════════════════════════════════════════════════════════════
step "B. Node placement (kube node → physical host)"
declare -A EXPECT_HOST
while read -r node ctx; do EXPECT_HOST[$node]="$ctx"; done < <(
  jq -r '.hosts[] | .context as $c | .nodes[] | select(.role=="worker")
         | "\(.name | ascii_downcase) \($c)"' "$NODES_JSON")
PLACE_BAD=0
for node in "${!EXPECT_HOST[@]}"; do
  actual=$(kubectl get nodes -l arena.node="$node" \
           -o jsonpath='{.items[0].metadata.labels.arena\.host}' 2>/dev/null)
  if [[ "$actual" == "${EXPECT_HOST[$node]}" ]]; then
    printf "    %-10s on host %-14s ${GREEN}✓${RESET}\n" "$node" "$actual" | tee -a "$LOG_DIR/run.log"
  else
    printf "    %-10s expected %-14s got %-14s ${RED}✗${RESET}\n" \
      "$node" "${EXPECT_HOST[$node]}" "${actual:-<none>}" | tee -a "$LOG_DIR/run.log"
    PLACE_BAD=1
  fi
done
[[ "$PLACE_BAD" == 0 ]] && ok "all workers landed on their declared hosts" \
  || warn "placement mismatch — check arena.host labels / kind config"

# ───────────────────────────────────────────────────────────────
# 11. Pre-pull image + deploy probes
# ───────────────────────────────────────────────────────────────
step "11. Pre-pull probe image"
docker pull "$PROBE_IMAGE" >>"$LOG_DIR/image-pull.log" 2>&1
kind load docker-image "$PROBE_IMAGE" --name "$CLUSTER" >>"$LOG_DIR/image-pull.log" 2>&1 \
  || warn "kind load failed — probes will pull individually"
ok "$PROBE_IMAGE pre-loaded"

step "12. Deploy probes"
python3 -m tools.topology.cli -t "$TOPO_YAML" -n "$NODES_JSON" \
  compile -f probes -o "$LOG_DIR/probes.yaml" 2>>"$LOG_DIR/topo.log" \
  || fail "probes.yaml generation failed"
kubectl apply -f "$LOG_DIR/probes.yaml" >"$LOG_DIR/probes-apply.log" 2>&1
kubectl wait --for=condition=Ready pod -l app -n arena-net --timeout=300s >>"$LOG_DIR/wait-probes.log" 2>&1 \
  || fail "probes not Ready (see $LOG_DIR/wait-probes.log)"

# label→IP and label→host maps for worker probes
WORKERS_LBL=$(jq -r '.hosts[].nodes[] | select(.role=="worker") | .name | ascii_downcase' "$NODES_JSON")
declare -A POD_IP POD_HOST
for t in $WORKERS_LBL; do
  POD_IP[$t]=$(kubectl get pod -n arena-net -l arena.node="$t" -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
  nodename=$(kubectl get pod -n arena-net -l arena.node="$t" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
  POD_HOST[$t]=$(kubectl get node "$nodename" -o jsonpath='{.metadata.labels.arena\.host}' 2>/dev/null)
  [[ -n "${POD_IP[$t]}" ]] || fail "no IP for probe-$t"
done
ok "$(echo "$WORKERS_LBL" | wc -w) probes Ready with IPs + host map"

rtt_of()  { kubectl exec -n arena-net deploy/probe-"$1" -- ping -c 5 -q "${POD_IP[$2]}" 2>/dev/null | awk -F'/' '/^rtt/{print $5}'; }
bw_of()   { kubectl exec -n arena-net deploy/probe-"$1" -- iperf3 -c "${POD_IP[$2]}" -t 5 -P 8 -f m 2>/dev/null | awk '/\[SUM\].*sender/{print $6" "$7}'; }
loss_of() { kubectl exec -n arena-net deploy/probe-"$1" -- iperf3 -u -c "${POD_IP[$2]}" -b "${3:-50M}" -t 5 2>/dev/null | grep -oE '\([0-9.]+%\)' | tail -1; }

# pick one intra-host and one inter-host pair automatically
INTRA_SRC=""; INTRA_DST=""; INTER_SRC=""; INTER_DST=""
for a in $WORKERS_LBL; do for b in $WORKERS_LBL; do
  [[ "$a" == "$b" ]] && continue
  if [[ -z "$INTRA_SRC" && "${POD_HOST[$a]}" == "${POD_HOST[$b]}" ]]; then INTRA_SRC=$a; INTRA_DST=$b; fi
  if [[ -z "$INTER_SRC" && "${POD_HOST[$a]}" != "${POD_HOST[$b]}" ]]; then INTER_SRC=$a; INTER_DST=$b; fi
done; done
log "intra-host pair: ${INTRA_SRC:-none}→${INTRA_DST:-none}   inter-host pair: ${INTER_SRC:-none}→${INTER_DST:-none}"

# ═══════════════════════════════════════════════════════════════
# VERIFICATION C — cross-host reachability (pre-chaos)
# ═══════════════════════════════════════════════════════════════
step "C. Cross-host reachability over the overlay (no chaos yet)"
if [[ -n "$INTER_SRC" ]]; then
  loss=$(kubectl exec -n arena-net deploy/probe-"$INTER_SRC" -- \
    ping -c 5 -W 2 -q "${POD_IP[$INTER_DST]}" 2>/dev/null \
    | awk -F',' '/packet loss/{for(i=1;i<=NF;i++) if ($i ~ /%/) print $i}')
  printf "    %s→%s  (host %s→%s)  packet loss = %s\n" \
    "$INTER_SRC" "$INTER_DST" "${POD_HOST[$INTER_SRC]}" "${POD_HOST[$INTER_DST]}" "${loss:-?}" | tee -a "$LOG_DIR/run.log"
  [[ "$loss" == "0%" ]] && ok "overlay carries cross-host pod traffic" \
    || warn "cross-host loss=$loss — overlay/VXLAN may be degraded (check docker versions match)"
else
  warn "no inter-host pair found — is this really multi-host?"
fi

# ═══════════════════════════════════════════════════════════════
# VERIFICATION D — intra-host vs inter-host BASELINE (no chaos)
# ═══════════════════════════════════════════════════════════════
step "D. Baseline: intra-host vs inter-host (overlay overhead, NO chaos)"
echo "  ───── RTT / Bandwidth (baseline) ─────" | tee -a "$LOG_DIR/run.log"
if [[ -n "$INTRA_SRC" ]]; then
  printf "    intra-host  %s→%s   RTT=%s ms   BW=%s\n" \
    "$INTRA_SRC" "$INTRA_DST" "$(rtt_of "$INTRA_SRC" "$INTRA_DST")" "$(bw_of "$INTRA_SRC" "$INTRA_DST")" | tee -a "$LOG_DIR/run.log"
fi
if [[ -n "$INTER_SRC" ]]; then
  printf "    inter-host  %s→%s   RTT=%s ms   BW=%s\n" \
    "$INTER_SRC" "$INTER_DST" "$(rtt_of "$INTER_SRC" "$INTER_DST")" "$(bw_of "$INTER_SRC" "$INTER_DST")" | tee -a "$LOG_DIR/run.log"
fi
log "expect inter-host RTT/BW worse than intra-host (real VXLAN hop between machines)"

# ───────────────────────────────────────────────────────────────
# 13. Apply NetworkChaos topology
# ───────────────────────────────────────────────────────────────
step "13. Apply NetworkChaos topology"
python3 -m tools.topology.cli -t "$TOPO_YAML" -n "$NODES_JSON" \
  compile -f chaosmesh -o "$LOG_DIR/chaos.yaml" 2>>"$LOG_DIR/topo.log" \
  || fail "chaos.yaml generation failed"
NCHAOS=$(grep -c "^kind: NetworkChaos" "$LOG_DIR/chaos.yaml")
kubectl apply -f "$LOG_DIR/chaos.yaml" >"$LOG_DIR/chaos-apply.log" 2>&1
ok "$NCHAOS NetworkChaos applied — waiting 60s for chaos-daemon to install tc rules..."
sleep 60
INJECTED=$(kubectl get networkchaos -n arena-net -o json 2>/dev/null \
  | jq '[.items[] | select(.status.experiment.containerRecords[0].phase == "Injected")] | length')
[[ "$INJECTED" -ge "$NCHAOS" ]] && ok "all $INJECTED/$NCHAOS rules Injected" \
  || warn "only $INJECTED/$NCHAOS rules Injected; continuing"

# ═══════════════════════════════════════════════════════════════
# VERIFICATION E — chaos takes effect ACROSS a host boundary
# ═══════════════════════════════════════════════════════════════
step "E. Chaos on a CROSS-HOST link (delay / bandwidth / loss)"
if [[ -n "$INTER_SRC" ]]; then
  H="(host ${POD_HOST[$INTER_SRC]}→${POD_HOST[$INTER_DST]})"
  echo "  ───── verifying $INTER_SRC→$INTER_DST $H ─────" | tee -a "$LOG_DIR/run.log"
  printf "    DELAY      RTT (shaped) = %s ms   (expect ≫ baseline)\n"   "$(rtt_of "$INTER_SRC" "$INTER_DST")"   | tee -a "$LOG_DIR/run.log"
  printf "    BANDWIDTH  BW  (shaped) = %s       (expect ≈ topology bw)\n" "$(bw_of "$INTER_SRC" "$INTER_DST")"  | tee -a "$LOG_DIR/run.log"
  printf "    LOSS       UDP loss     = %s\n"                             "$(loss_of "$INTER_SRC" "$INTER_DST" 5M)" | tee -a "$LOG_DIR/run.log"
  log "if these moved vs section D, chaos-daemon is shaping the pod veth even across the overlay"
else
  warn "no inter-host pair — cannot verify cross-host chaos"
fi

# ───────────────────────────────────────────────────────────────
# Summary
# ───────────────────────────────────────────────────────────────
step "DONE — full log in $LOG_DIR"
log "compare section D (baseline) vs section E (shaped) for the cross-host link"
log "tear down with:  bash $ARENA_DIR/arena_testbed/3b-clean-multihost.sh ${WORKER_CTX[*]}"
