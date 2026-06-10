#!/usr/bin/env bash
# run-experiment.sh — full Arena topology experiment, end-to-end.
#
# From a bare Debian/Ubuntu host with root access, this script:
#   1. installs docker, Go, kubectl, helm, python deps
#   2. builds the Arena-flavoured kind fork from source
#   3. clones the arena_extension repo + checks out the right branch
#   4. brings up the 7-node kind cluster (3 IoT + 2 Edge + Cloud + Controller)
#   5. installs Cilium / Prometheus / Chaos Mesh
#   6. deploys 6 iperf3 probe pods (one per worker)
#   7. measures the baseline RTT (no chaos yet)
#   8. compiles topology.yaml → 30 NetworkChaos + applies
#   9. verifies delay (ping), bandwidth (iperf3 TCP), loss (iperf3 UDP)
#
# Everything that produces output goes under /tmp/arena-experiment-<ts>/,
# so a failed run can be triaged from the saved logs.
#
# Usage:
#   sudo ./scripts/run-experiment.sh             # full run with defaults
#
# Environment overrides:
#   ARENA_DIR=...                                # where to clone arena (default ~/arena_extension)
#   ARENA_BRANCH=...                             # branch to use (default arena-multihost-yaml-pinning)
#   NODES_JSON=...                               # alternate nodes.json (default examples/nodes-3tier-multi.json)
#   TOPO_YAML=...                                # alternate topology.yaml (default examples/topology.yaml)
#   SKIP_INSTALL=1                               # skip steps 1-3 if everything is already there

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
LOG_DIR=/tmp/arena-experiment-${TS}
mkdir -p "$LOG_DIR"

# ───────────────────────────────────────────────────────────────
# Logging helpers
# ───────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  RED=$'\e[1;31m'; GREEN=$'\e[1;32m'; YELLOW=$'\e[1;33m'; BLUE=$'\e[1;34m'; RESET=$'\e[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

step()  { echo;       echo "${BLUE}═════════════════ $* ═════════════════${RESET}" | tee -a "$LOG_DIR/run.log"; }
log()   { echo "${BLUE}[INFO]${RESET}  $*"  | tee -a "$LOG_DIR/run.log"; }
ok()    { echo "${GREEN}  ✓${RESET}      $*" | tee -a "$LOG_DIR/run.log"; }
warn()  { echo "${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOG_DIR/run.log"; }
err()   { echo "${RED}[ERR]${RESET}   $*"   | tee -a "$LOG_DIR/run.log"; }
fail()  { err "$1"; err "logs in $LOG_DIR"; exit 1; }

# ───────────────────────────────────────────────────────────────
# 1. Preflight
# ───────────────────────────────────────────────────────────────

step "1. Preflight"
[[ $(id -u) -eq 0 ]] || fail "must run as root (sudo)"
CGROUP=$(stat -fc %T /sys/fs/cgroup)
[[ "$CGROUP" == "cgroup2fs" ]] || fail "host is on $CGROUP — need cgroup v2 (reboot with systemd.unified_cgroup_hierarchy=1)"

# Kernel limits: 7 kind nodes × kubelet + containerd + many file watchers
# easily exhaust the default fs.inotify limits. Bump them or kubelet on
# some workers will die with "inotify_init: too many open files".
sysctl -w fs.inotify.max_user_instances=8192   >/dev/null
sysctl -w fs.inotify.max_user_watches=524288   >/dev/null
sysctl -w fs.file-max=2097152                  >/dev/null
cat <<EOF > /etc/sysctl.d/99-arena-inotify.conf
fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=524288
fs.file-max=2097152
EOF
ok "root, cgroup v2 ($CGROUP), inotify limits bumped (8192 instances, 524288 watches)"

# ───────────────────────────────────────────────────────────────
# 2. Base packages (docker, jq, python3-yaml, build tools)
# ───────────────────────────────────────────────────────────────

if [[ "${SKIP_INSTALL:-0}" != "1" ]]; then
  step "2. Install base packages"
  apt-get update -qq >>"$LOG_DIR/apt.log" 2>&1
  apt-get install -y -qq docker.io jq python3-yaml curl wget git net-tools >>"$LOG_DIR/apt.log" 2>&1 || \
    fail "apt-get install failed, see $LOG_DIR/apt.log"
  systemctl start docker 2>/dev/null || service docker start 2>/dev/null || true
  docker info >/dev/null 2>&1 || fail "docker daemon not running"
  ok "docker $(docker --version | awk '{print $3}' | tr -d ','), jq, python3-yaml"
fi

# ───────────────────────────────────────────────────────────────
# 3. Go (clean install — avoids stale GOROOT issues)
# ───────────────────────────────────────────────────────────────

if [[ "${SKIP_INSTALL:-0}" != "1" ]]; then
  step "3. Install Go ${GO_VERSION}"
  need_go=1
  if [[ -x /usr/local/go/bin/go ]]; then
    cur=$(/usr/local/go/bin/go version | awk '{print $3}' | sed 's/^go//')
    if [[ "$(printf '%s\n%s\n' "$GO_VERSION" "$cur" | sort -V | head -1)" == "$GO_VERSION" ]]; then
      need_go=0
      ok "Go $cur already installed (≥ $GO_VERSION)"
    fi
  fi
  if [[ "$need_go" == 1 ]]; then
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tgz
    rm /tmp/go.tgz
    ok "Go $GO_VERSION installed"
  fi
fi
# These two unsets fix the Grid'5000 "GOROOT=/root/go1.24.7" trap
unset GOROOT GOTOOLCHAIN
export PATH=/usr/local/go/bin:$PATH
hash -r 2>/dev/null || true

# ───────────────────────────────────────────────────────────────
# 4. kubectl
# ───────────────────────────────────────────────────────────────

if [[ "${SKIP_INSTALL:-0}" != "1" ]]; then
  step "4. Install kubectl ${KUBECTL_VERSION}"
  if ! command -v kubectl >/dev/null; then
    curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    chmod +x kubectl && mv kubectl /usr/local/bin/
  fi
  ok "kubectl $(kubectl version --client 2>&1 | head -1 | awk '{print $3}')"
fi

# ───────────────────────────────────────────────────────────────
# 5. Helm
# ───────────────────────────────────────────────────────────────

if [[ "${SKIP_INSTALL:-0}" != "1" ]]; then
  step "5. Install Helm ${HELM_VERSION}"
  if ! command -v helm >/dev/null; then
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | tar xz -C /tmp
    mv /tmp/linux-amd64/helm /usr/local/bin/
    rm -rf /tmp/linux-amd64
  fi
  ok "helm $(helm version --short 2>/dev/null)"
fi

# ───────────────────────────────────────────────────────────────
# 6. Build kind from Arena fork
# ───────────────────────────────────────────────────────────────

step "6. Build kind from fork ($KIND_REPO)"
if [[ ! -d "$KIND_SRC/.git" ]]; then
  mkdir -p "$(dirname "$KIND_SRC")"
  git clone "$KIND_REPO" "$KIND_SRC" >>"$LOG_DIR/kind-clone.log" 2>&1
fi
git -C "$KIND_SRC" fetch origin >>"$LOG_DIR/kind-fetch.log" 2>&1
git -C "$KIND_SRC" checkout "$KIND_BRANCH" >>"$LOG_DIR/kind-fetch.log" 2>&1
git -C "$KIND_SRC" pull --ff-only origin "$KIND_BRANCH" >>"$LOG_DIR/kind-fetch.log" 2>&1 || true

need_build=1
if command -v kind >/dev/null && kind --help 2>&1 | grep -q -- '--multihost'; then
  need_build=0
  ok "kind already supports --multihost ($(kind --version))"
fi
if [[ "$need_build" == 1 ]]; then
  log "compiling kind from $KIND_SRC..."
  ( cd "$KIND_SRC" && /usr/local/go/bin/go clean -cache >/dev/null 2>&1; \
    /usr/local/go/bin/go build -o /tmp/kind . ) >>"$LOG_DIR/kind-build.log" 2>&1 || \
    fail "kind build failed, see $LOG_DIR/kind-build.log"
  install -m 0755 /tmp/kind /usr/local/bin/kind
  rm -f /tmp/kind
  ok "kind built and installed ($(kind --version))"
fi
kind --help 2>&1 | grep -q -- '--multihost' || fail "installed kind missing --multihost — rebuild from fork"

# ───────────────────────────────────────────────────────────────
# 7. Clone arena
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

NODES_JSON="${NODES_JSON:-$ARENA_DIR/examples/nodes-3tier-multi.json}"
TOPO_YAML="${TOPO_YAML:-$ARENA_DIR/examples/topology.yaml}"
[[ -f "$NODES_JSON" ]] || fail "$NODES_JSON not found"
[[ -f "$TOPO_YAML"  ]] || fail "$TOPO_YAML not found"

# ───────────────────────────────────────────────────────────────
# 8. Launch the 7-node cluster
# ───────────────────────────────────────────────────────────────

step "8. Launch kind cluster"
SUM_CPU=$(jq '[.hosts[].nodes[].cpu | tonumber] | add' "$NODES_JSON")
HOST_CPU=$(docker info --format '{{.NCPU}}')
[[ "$SUM_CPU" -le "$HOST_CPU" ]] || fail "nodes.json asks $SUM_CPU CPU but host has $HOST_CPU — scale it down"
ok "capacity OK: ${SUM_CPU}/${HOST_CPU} CPU requested"

cp "$NODES_JSON" arena_testbed/nodes.json

# If a cluster already exists from a previous run, delete it for a fresh launch
if kind get clusters 2>/dev/null | grep -q '^arena-testbed$'; then
  warn "previous arena-testbed cluster found, deleting first..."
  bash arena_testbed/3-clean_cluster.sh >>"$LOG_DIR/cleanup.log" 2>&1 || true
fi

bash arena_testbed/1-launch_cluster.sh >"$LOG_DIR/launch.log" 2>&1 || \
  fail "cluster launch failed, check $LOG_DIR/launch.log"

NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
[[ "$NODES" -eq 7 ]] || fail "expected 7 nodes, got $NODES"
ok "cluster up — 7 nodes (3 IoT + 2 Edge + 1 Cloud + 1 Controller)"

# ───────────────────────────────────────────────────────────────
# 9. Install frameworks (Cilium / Prometheus / Chaos Mesh)
# ───────────────────────────────────────────────────────────────

step "9. Install Cilium + Prometheus + Chaos Mesh"
bash arena_testbed/2-set_frameworks.sh >"$LOG_DIR/frameworks.log" 2>&1 || \
  fail "framework install failed, see $LOG_DIR/frameworks.log"

kubectl wait --for=condition=Ready node --all --timeout=300s >>"$LOG_DIR/wait-nodes.log" 2>&1 || \
  fail "some nodes did not become Ready"

CHAOS_READY=$(kubectl -n chaos-mesh get pods --no-headers 2>/dev/null | grep -c Running)
[[ "$CHAOS_READY" -gt 0 ]] || fail "no chaos-mesh pods Running"
ok "all 7 nodes Ready, $CHAOS_READY chaos-mesh pods Running"

# ───────────────────────────────────────────────────────────────
# 10. Pre-pull probe image (avoids Docker Hub rate-limit later)
# ───────────────────────────────────────────────────────────────

step "10. Pre-pull probe image"
docker pull "$PROBE_IMAGE" >>"$LOG_DIR/image-pull.log" 2>&1
kind load docker-image "$PROBE_IMAGE" --name arena-testbed >>"$LOG_DIR/image-pull.log" 2>&1 || \
  warn "kind load failed — probes will pull individually (may be slow)"
ok "$PROBE_IMAGE pre-loaded into all kind nodes"

# ───────────────────────────────────────────────────────────────
# 11. Deploy probes
# ───────────────────────────────────────────────────────────────

step "11. Deploy iperf3 probes"
python3 -m tools.topology.cli -t "$TOPO_YAML" -n "$NODES_JSON" \
  compile -f probes -o "$LOG_DIR/probes.yaml" 2>>"$LOG_DIR/topo.log" || \
  fail "probes.yaml generation failed"

kubectl apply -f "$LOG_DIR/probes.yaml" >"$LOG_DIR/probes-apply.log" 2>&1
kubectl wait --for=condition=Ready pod -l app -n arena-net --timeout=300s \
  >>"$LOG_DIR/wait-probes.log" 2>&1 || \
  fail "probes did not become Ready (see $LOG_DIR/wait-probes.log)"
NP=$(kubectl get pods -n arena-net --no-headers | wc -l)
ok "$NP probes Ready (1 per worker node)"

# Cache pod IPs (used by ping / iperf3 — bypass services since arena's Cilium
# kube-proxy replacement isn't always wired up out of the box).
declare -A POD_IP
for t in iot-1 iot-2 iot-3 edge-1 edge-2 cloud; do
  ip=$(kubectl get pod -n arena-net -l app=probe-$t -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
  [[ -n "$ip" ]] || fail "no IP for probe-$t"
  POD_IP[$t]=$ip
done

# ───────────────────────────────────────────────────────────────
# 12. Baseline (no chaos applied yet)
# ───────────────────────────────────────────────────────────────

step "12. Baseline RTT (chaos NOT applied)"
for pair in "iot-1:edge-1" "iot-1:cloud" "iot-1:iot-2"; do
  IFS=: read src dst <<< "$pair"
  rtt=$(kubectl exec -n arena-net deploy/probe-$src -- \
    ping -c 5 -q "${POD_IP[$dst]}" 2>/dev/null | awk -F'/' '/^rtt/{print $5}')
  printf "    %-15s baseline RTT = %s ms\n" "$src→$dst" "${rtt:-?}" | tee -a "$LOG_DIR/run.log"
done

# ───────────────────────────────────────────────────────────────
# 13. Compile + apply NetworkChaos topology
# ───────────────────────────────────────────────────────────────

step "13. Apply NetworkChaos topology"
python3 -m tools.topology.cli -t "$TOPO_YAML" -n "$NODES_JSON" \
  compile -f chaosmesh -o "$LOG_DIR/chaos.yaml" 2>>"$LOG_DIR/topo.log" || \
  fail "chaos.yaml generation failed"

NCHAOS=$(grep -c "^kind: NetworkChaos" "$LOG_DIR/chaos.yaml")
kubectl apply -f "$LOG_DIR/chaos.yaml" >"$LOG_DIR/chaos-apply.log" 2>&1
ok "$NCHAOS NetworkChaos applied — waiting 60s for chaos-daemon to install tc rules..."
sleep 60

INJECTED=$(kubectl get networkchaos -n arena-net -o json 2>/dev/null | \
  jq '[.items[] | select(.status.experiment.containerRecords[0].phase == "Injected")] | length')
if [[ "$INJECTED" -lt "$NCHAOS" ]]; then
  warn "only $INJECTED/$NCHAOS rules in Injected state; continuing anyway"
else
  ok "all $INJECTED/$NCHAOS rules Injected"
fi

# ───────────────────────────────────────────────────────────────
# 14. Verify chaos: delay (ping) + bandwidth (iperf3 TCP) + loss (iperf3 UDP)
# ───────────────────────────────────────────────────────────────

step "14. Verify chaos injection"

verify_delay() {
  local src=$1 dst=$2 expected_oneway=$3 layer=$4
  local actual=$(kubectl exec -n arena-net deploy/probe-$src -- \
    ping -c 10 -q "${POD_IP[$dst]}" 2>/dev/null | awk -F'/' '/^rtt/{print $5}')
  local expected_rtt=$(awk -v e="$expected_oneway" 'BEGIN{printf "%.0f", e*2}')
  printf "    %-15s [%s]  expected_RTT=%4s ms   actual=%6s ms\n" \
    "$src→$dst" "$layer" "$expected_rtt" "${actual:-?}" | tee -a "$LOG_DIR/run.log"
}

verify_bw() {
  local src=$1 dst=$2 expected=$3
  # -P 8: 8 parallel TCP streams (one stream cannot fill a high-BDP pipe;
  # a single TCP at 90ms RTT tops out at ~10 Mbit/s regardless of the
  # actual shaper limit). 8 streams ≈ 8× more throughput → realistic.
  local actual=$(kubectl exec -n arena-net deploy/probe-$src -- \
    iperf3 -c "${POD_IP[$dst]}" -t 8 -P 8 -f m 2>/dev/null | \
    awk '/\[SUM\].*sender/{print $6" "$7}')
  printf "    %-15s expected=%-12s   actual=%s\n" \
    "$src→$dst" "$expected" "${actual:-?}" | tee -a "$LOG_DIR/run.log"
}

verify_loss() {
  local src=$1 dst=$2 expected=$3
  local actual=$(kubectl exec -n arena-net deploy/probe-$src -- \
    iperf3 -u -c "${POD_IP[$dst]}" -b 5M -t 10 2>/dev/null | grep -oE '\([0-9.]+%\)' | tail -1)
  printf "    %-15s expected=%-8s   actual=%s\n" \
    "$src→$dst" "$expected" "${actual:-?}" | tee -a "$LOG_DIR/run.log"
}

echo "  ───── DELAY (ping RTT, expected = 2 × one-way latency) ─────"     | tee -a "$LOG_DIR/run.log"
verify_delay iot-1 edge-1  2  "exception: same building"
verify_delay iot-1 iot-3   5  "intra-region (east)"
verify_delay iot-1 cloud  30  "east → central"
verify_delay iot-2 cloud  45  "west → central"
verify_delay iot-1 iot-2  70  "east → west"

echo                                                                       | tee -a "$LOG_DIR/run.log"
echo "  ───── BANDWIDTH (iperf3 TCP, may be lower than declared due to TCP BDP) ─────" | tee -a "$LOG_DIR/run.log"
verify_bw iot-1 edge-1 "≈ 1 Gbit/s"
verify_bw iot-2 cloud  "≈ 500 Mbit/s"
verify_bw iot-1 iot-2  "≈ 100 Mbit/s"

echo                                                                       | tee -a "$LOG_DIR/run.log"
echo "  ───── LOSS (iperf3 UDP one-way @ 5 Mbit/s) ─────"                  | tee -a "$LOG_DIR/run.log"
verify_loss iot-1 iot-3 "≈ 0%"
verify_loss iot-1 iot-2 "≈ 0.5%"
verify_loss iot-1 cloud "≈ 0.5%"

# ───────────────────────────────────────────────────────────────
# Summary
# ───────────────────────────────────────────────────────────────

step "DONE — full log in $LOG_DIR"
echo
log "next: tweak $TOPO_YAML, then re-run from step 13 only:"
log "    python3 -m tools.topology.cli -t $TOPO_YAML -n $NODES_JSON compile -f chaosmesh -o /tmp/chaos.yaml"
log "    kubectl apply -f /tmp/chaos.yaml"
echo
log "tear down with:    bash $ARENA_DIR/arena_testbed/3-clean_cluster.sh"
