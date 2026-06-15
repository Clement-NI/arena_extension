#!/usr/bin/env bash
# run-experiment-multihost.sh — full Arena experiment across MULTIPLE hosts.
#
# This is the multi-host sibling of run-experiment.sh. It drives the
# Arena kind fork's Swarm-overlay mode (`--multihost --bootstrap-swarm`)
# so that IoT / Edge / Cloud nodes live on different physical machines,
# then verifies the things that only matter once traffic crosses a
# machine boundary:
#
#   A. Swarm + overlay are up and every declared host joined.
#   B. Every probe pod landed on the physical host nodes.json asked for
#      (checked via the arena.host label).
#   C. Cross-host pods can reach each other over the overlay (pre-chaos).
#   D. intra-host vs inter-host baseline (overlay/VXLAN overhead) so the
#      shaped numbers have the right reference point.
#   E. Chaos (latency / bandwidth / loss) takes effect on a CROSS-HOST
#      link — proving chaos-daemon shapes the pod veth even when packets
#      egress the machine over VXLAN.
#
# Run from the SWARM MANAGER host (the one holding hosts[0] / the
# control-plane). Remote hosts must already be reachable as docker
# contexts — bootstrap them first with the fork's helper:
#
#   bash /opt/kind_extension_for_arena/scripts/setup-multihost.sh \
#        edge-host-1 iot-host-1
#
# Usage:
#   sudo ./scripts/run-experiment-multihost.sh
#
# Environment overrides:
#   ARENA_DIR / ARENA_BRANCH / ARENA_REPO    # as in run-experiment.sh
#   KIND_REPO / KIND_BRANCH / KIND_SRC       # as in run-experiment.sh
#   NODES_JSON=...    # default examples/nodes-multihost.json
#   TOPO_YAML=...     # default examples/topology-multihost.yaml
#   SKIP_INSTALL=1    # skip toolchain install (steps 2-5) if already present
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

TS=$(date +%Y%m%d-%H%M%S)
LOG_DIR=/tmp/arena-experiment-mh-${TS}
mkdir -p "$LOG_DIR"

# ───────────────────────────────────────────────────────────────
# Logging helpers
# ───────────────────────────────────────────────────────────────
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
# 2-5. Toolchain (docker / Go / kubectl / helm) — same as single-host
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
# 7. Fetch arena + resolve config
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

NODES_JSON="${NODES_JSON:-$ARENA_DIR/examples/nodes-multihost.json}"
TOPO_YAML="${TOPO_YAML:-$ARENA_DIR/examples/topology-multihost.yaml}"
[[ -f "$NODES_JSON" ]] || fail "$NODES_JSON not found"
[[ -f "$TOPO_YAML"  ]] || fail "$TOPO_YAML not found"

# ───────────────────────────────────────────────────────────────
# 8. Multi-host preflight: hosts, docker contexts, per-host capacity
# ───────────────────────────────────────────────────────────────
step "8. Multi-host preflight"
HOSTS_LEN=$(jq '.hosts | length' "$NODES_JSON")
[[ "$HOSTS_LEN" -ge 2 ]] || fail "$NODES_JSON has $HOSTS_LEN host(s) — use run-experiment.sh for single-host"
CP_HOST_IDX=$(jq '[.hosts[] | [.nodes[].role]] | map(any(. == "control-plane")) | index(true)' "$NODES_JSON")
[[ "$CP_HOST_IDX" == "0" ]] || fail "control-plane must live on hosts[0] (the Swarm manager); found on host index $CP_HOST_IDX"
TOTAL_NODES=$(jq '[.hosts[].nodes[]] | length' "$NODES_JSON")
log "$HOSTS_LEN hosts, $TOTAL_NODES kube nodes declared"

# Each remote host (context != default) must be reachable as a docker context.
while read -r ctx; do
  [[ -z "$ctx" || "$ctx" == "default" ]] && continue
  docker context inspect "$ctx" >/dev/null 2>&1 \
    || fail "docker context '$ctx' missing — bootstrap with: bash $KIND_SRC/scripts/setup-multihost.sh <hosts...>"
  docker --context "$ctx" info >/dev/null 2>&1 \
    || fail "docker context '$ctx' unreachable — check SSH (root@) and that docker runs on that host"
  ok "context '$ctx' reachable"
done < <(jq -r '.hosts[].context' "$NODES_JSON")

# Per-host capacity check (NOT a global sum — each node must fit on ITS host).
BAD=0
while read -r ctx host_cpu sum_cpu; do
  if [[ -z "$host_cpu" || "$host_cpu" == "null" || "$host_cpu" == '""' ]]; then
    if [[ "$ctx" == "default" ]]; then host_cpu=$(docker info --format '{{.NCPU}}')
    else host_cpu=$(docker --context "$ctx" info --format '{{.NCPU}}' 2>/dev/null); fi
  fi
  if [[ -n "$host_cpu" && "$sum_cpu" -gt "$host_cpu" ]]; then
    warn "host '$ctx' oversubscribed: nodes want ${sum_cpu} CPU but host has ${host_cpu}"
    BAD=1
  else
    ok "host '$ctx' capacity OK: ${sum_cpu}/${host_cpu} CPU"
  fi
done < <(jq -r '.hosts[] | "\(.context) \(.cpu // "null") \([.nodes[].cpu | tonumber] | add)"' "$NODES_JSON")
[[ "$BAD" == 0 ]] || fail "fix oversubscribed host(s) in $NODES_JSON"

# ───────────────────────────────────────────────────────────────
# 9. Launch the multi-host cluster (Swarm overlay)
# ───────────────────────────────────────────────────────────────
if [[ "${SKIP_LAUNCH:-0}" != "1" ]]; then
  step "9. Launch multi-host kind cluster"
  cp "$NODES_JSON" arena_testbed/nodes.json
  if kind get clusters 2>/dev/null | grep -q '^arena-testbed$'; then
    warn "previous arena-testbed cluster found, deleting first..."
    bash arena_testbed/3-clean_cluster.sh >>"$LOG_DIR/cleanup.log" 2>&1 || true
  fi
  bash arena_testbed/1-launch_cluster.sh >"$LOG_DIR/launch.log" \
    || fail "cluster launch failed (see $LOG_DIR/launch.log)"

  step "9b. Install Cilium + Prometheus + Chaos Mesh"
  bash arena_testbed/2-set_frameworks.sh >"$LOG_DIR/frameworks.log" \
    || fail "framework install failed (see $LOG_DIR/frameworks.log)"
else
  step "9. SKIP_LAUNCH=1 — reusing running cluster"
  kubectl config use-context "kind-arena-testbed" >/dev/null 2>&1 || true
fi

kubectl wait --for=condition=Ready node --all --timeout=300s >>"$LOG_DIR/wait-nodes.log" 2>&1 \
  || fail "some nodes did not become Ready"
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
# Expected mapping straight from nodes.json: "<arena.node> <context>"
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
# 10-11. Pre-pull image + deploy probes
# ───────────────────────────────────────────────────────────────
step "10. Pre-pull probe image"
docker pull "$PROBE_IMAGE" >>"$LOG_DIR/image-pull.log" 2>&1
kind load docker-image "$PROBE_IMAGE" --name arena-testbed >>"$LOG_DIR/image-pull.log" 2>&1 \
  || warn "kind load failed — probes will pull individually"
ok "$PROBE_IMAGE pre-loaded"

step "11. Deploy probes"
python3 -m tools.topology.cli -t "$TOPO_YAML" -n "$NODES_JSON" \
  compile -f probes -o "$LOG_DIR/probes.yaml" 2>>"$LOG_DIR/topo.log" \
  || fail "probes.yaml generation failed"
kubectl apply -f "$LOG_DIR/probes.yaml" >"$LOG_DIR/probes-apply.log" 2>&1
kubectl wait --for=condition=Ready pod -l app -n arena-net --timeout=300s >>"$LOG_DIR/wait-probes.log" 2>&1 \
  || fail "probes not Ready (see $LOG_DIR/wait-probes.log)"

# Build label→IP and label→host maps for the worker probes.
WORKERS=$(jq -r '.hosts[].nodes[] | select(.role=="worker") | .name | ascii_downcase' "$NODES_JSON")
declare -A POD_IP POD_HOST
for t in $WORKERS; do
  POD_IP[$t]=$(kubectl get pod -n arena-net -l arena.node="$t" -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
  nodename=$(kubectl get pod -n arena-net -l arena.node="$t" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
  POD_HOST[$t]=$(kubectl get node "$nodename" -o jsonpath='{.metadata.labels.arena\.host}' 2>/dev/null)
  [[ -n "${POD_IP[$t]}" ]] || fail "no IP for probe-$t"
done
ok "$(echo "$WORKERS" | wc -w) probes Ready with IPs + host map"

# Helper: ping RTT (max field), bandwidth (TCP -P 8 SUM), loss (UDP)
rtt_of()  { kubectl exec -n arena-net deploy/probe-"$1" -- ping -c 5 -q "${POD_IP[$2]}" 2>/dev/null | awk -F'/' '/^rtt/{print $5}'; }
bw_of()   { kubectl exec -n arena-net deploy/probe-"$1" -- iperf3 -c "${POD_IP[$2]}" -t 5 -P 8 -f m 2>/dev/null | awk '/\[SUM\].*sender/{print $6" "$7}'; }
loss_of() { kubectl exec -n arena-net deploy/probe-"$1" -- iperf3 -u -c "${POD_IP[$2]}" -b "${3:-50M}" -t 5 2>/dev/null | grep -oE '\([0-9.]+%\)' | tail -1; }

# Pick one intra-host pair and one inter-host pair automatically.
INTRA_SRC=""; INTRA_DST=""; INTER_SRC=""; INTER_DST=""
for a in $WORKERS; do for b in $WORKERS; do
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
    || warn "cross-host loss=$loss — overlay/VXLAN may be degraded"
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
# 12. Apply NetworkChaos topology
# ───────────────────────────────────────────────────────────────
step "12. Apply NetworkChaos topology"
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
  printf "    DELAY      RTT (shaped) = %s ms   (expect ≫ baseline)\n"  "$(rtt_of "$INTER_SRC" "$INTER_DST")"  | tee -a "$LOG_DIR/run.log"
  printf "    BANDWIDTH  BW  (shaped) = %s       (expect ≈ topology bw)\n" "$(bw_of "$INTER_SRC" "$INTER_DST")"  | tee -a "$LOG_DIR/run.log"
  printf "    LOSS       UDP loss     = %s\n"                            "$(loss_of "$INTER_SRC" "$INTER_DST" 5M)" | tee -a "$LOG_DIR/run.log"
  log "if these moved vs section D, chaos-daemon is shaping the pod veth even across the overlay"
else
  warn "no inter-host pair — cannot verify cross-host chaos"
fi

# ───────────────────────────────────────────────────────────────
# Summary
# ───────────────────────────────────────────────────────────────
step "DONE — full log in $LOG_DIR"
log "compare section D (baseline) vs section E (shaped) for the cross-host link"
log "tear down with:  bash $ARENA_DIR/arena_testbed/3-clean_cluster.sh"
