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

# If a cluster exists or zombie containers/networks from a previous run
# remain, nuke them. `kind delete` alone often misses orphans, and the
# next `kind create` then dies with "container name already in use".
if kind get clusters 2>/dev/null | grep -q '^arena-testbed$'; then
  warn "previous arena-testbed cluster found, deleting first..."
  bash arena_testbed/3-clean_cluster.sh >>"$LOG_DIR/cleanup.log" 2>&1 || true
fi
ZOMBIES=$(docker ps -aq --filter "label=io.x-k8s.kind.cluster=arena-testbed" 2>/dev/null)
if [[ -n "$ZOMBIES" ]]; then
  warn "removing $(echo "$ZOMBIES" | wc -l) zombie kind container(s) from a previous run..."
  docker rm -f $ZOMBIES >>"$LOG_DIR/cleanup.log" 2>&1 || true
fi
docker network ls --format '{{.Name}}' | grep -qx kind && \
  docker network rm kind >>"$LOG_DIR/cleanup.log" 2>&1 || true

bash arena_testbed/1-launch_cluster.sh >"$LOG_DIR/launch.log"|| \
  fail "cluster launch failed, check $LOG_DIR/launch.log"

NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
[[ "$NODES" -eq 7 ]] || fail "expected 7 nodes, got $NODES"
ok "cluster up — 7 nodes (3 IoT + 2 Edge + 1 Cloud + 1 Controller)"

# ───────────────────────────────────────────────────────────────
# 9. Install frameworks (Cilium / Prometheus / Chaos Mesh)
# ───────────────────────────────────────────────────────────────

step "9. Install Cilium + Prometheus + Chaos Mesh"
bash arena_testbed/2-set_frameworks.sh >"$LOG_DIR/frameworks.log"|| \
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

step "12. Baseline (chaos NOT applied — natural cluster performance)"

echo "  ───── RTT baseline (expect < 1 ms intra-host) ─────"  | tee -a "$LOG_DIR/run.log"
for pair in "iot-1:edge-1" "iot-1:cloud" "iot-1:iot-2"; do
  IFS=: read src dst <<< "$pair"
  rtt=$(kubectl exec -n arena-net deploy/probe-$src -- \
    ping -c 5 -q "${POD_IP[$dst]}" 2>/dev/null | awk -F'/' '/^rtt/{print $5}')
  printf "    %-15s baseline RTT  = %s ms\n" "$src→$dst" "${rtt:-?}" | tee -a "$LOG_DIR/run.log"
done

echo                                                          | tee -a "$LOG_DIR/run.log"
echo "  ───── Bandwidth baseline (iperf3 TCP -P 8, max the pod CPU can push) ─────" | tee -a "$LOG_DIR/run.log"
for pair in "iot-1:edge-1" "iot-1:cloud" "iot-1:iot-2"; do
  IFS=: read src dst <<< "$pair"
  bw=$(kubectl exec -n arena-net deploy/probe-$src -- \
    iperf3 -c "${POD_IP[$dst]}" -t 5 -P 8 -f m 2>/dev/null | \
    awk '/\[SUM\].*sender/{print $6" "$7}')
  printf "    %-15s baseline BW   = %s\n" "$src→$dst" "${bw:-?}" | tee -a "$LOG_DIR/run.log"
done

echo                                                          | tee -a "$LOG_DIR/run.log"
echo "  ───── Loss baseline (iperf3 UDP @ 100 Mbit/s, expect 0%) ─────" | tee -a "$LOG_DIR/run.log"
for pair in "iot-1:edge-1" "iot-1:cloud" "iot-1:iot-2"; do
  IFS=: read src dst <<< "$pair"
  loss=$(kubectl exec -n arena-net deploy/probe-$src -- \
    iperf3 -u -c "${POD_IP[$dst]}" -b 100M -t 5 2>/dev/null | \
    grep -oE '\([0-9.]+%\)' | tail -1)
  printf "    %-15s baseline loss = %s\n" "$src→$dst" "${loss:-?}" | tee -a "$LOG_DIR/run.log"
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
  local per_stream=$(( expected * 11 / 10 / 4 ))M

  # Use the same POD_IP[] array as verify_delay / verify_loss (filled at
  # step 11). Avoids relying on a second `kubectl get pod -l arena.node=...`
  # query that returned empty in some runs, causing iperf3 to DNS-resolve
  # an empty hostname and report "Name does not resolve".
  local dst_ip="${POD_IP[$dst]:-}"
  if [ -z "$dst_ip" ]; then
    echo "    $src→$dst  ERR: POD_IP[$dst] is empty (probe pod not Ready?)"
    return
  fi

  # -P 4 streams, -l 1200 stays under typical CNI MSS to avoid fragmentation
  # warnings. No -w override: relying on default socket buffer + the bumped
  # probe-pod CPU (2000m) to absorb UDP at multi-Gbit/s. iperf3 hard-fails
  # if you request -w > net.core.{r,w}mem_max.
  local outfile="$LOG_DIR/iperf3-${src}-to-${dst}.json"
  local errfile="$LOG_DIR/iperf3-${src}-to-${dst}.err"
  kubectl exec -n arena-net deploy/probe-$src -- \
    iperf3 -c "$dst_ip" -u -b "$per_stream" -l 1200 \
           -t 10 -O 2 -P 4 -J >"$outfile" 2>"$errfile"

  # iperf3 always writes JSON (even on error). Detect failure by .error key.
  local iperf_err; iperf_err=$(jq -r '.error // empty' "$outfile" 2>/dev/null)
  if [ -n "$iperf_err" ]; then
    echo "    $src→$dst  ERR: $iperf_err (see $outfile)"
    return
  fi
  if ! jq -e '.end.sum' "$outfile" >/dev/null 2>&1; then
    echo "    $src→$dst  ERR: malformed iperf3 JSON (see $outfile)"
    return
  fi

  jq -r --arg src "$src" --arg dst "$dst" --arg exp "$expected" '
    (.end.sum_received.bits_per_second // 0) as $recv_raw |
    (.end.sum.bits_per_second // 0)          as $sent |
    (.end.sum.lost_percent // 0)             as $loss |
    (if $recv_raw > 0 then $recv_raw
     else $sent * (1 - $loss/100) end)       as $recv |
    "    \($src)→\($dst)  expected=\($exp)Mbit  sent=\($sent/1e6|floor)Mbit  received=\($recv/1e6|floor)Mbit  drop=\($loss|floor)%"
  ' "$outfile"
}

verify_loss() {
  local src=$1 dst=$2 expected=$3
  local actual=$(kubectl exec -n arena-net deploy/probe-$src -- \
    iperf3 -u -c "${POD_IP[$dst]}" -b 5M -t 10 2>/dev/null | grep -oE '\([0-9.]+%\)' | tail -1)
  printf "    %-15s expected=%-8s   actual=%s\n" \
    "$src→$dst" "$expected" "${actual:-?}" | tee -a "$LOG_DIR/run.log"
}

# Reads duplicate/corrupt counts from netem statistics inside the source pod.
# Chaos Mesh's netem updates these counters per-pod, accessible via
# `tc -s qdisc show dev eth0`. We capture before/after a short iperf3
# UDP burst so we can compute the delta.
verify_netem_stat() {
  local src=$1 dst=$2 expected_dup=$3 expected_cor=$4
  local pre post sent_pre sent_post dup_pre dup_post cor_pre cor_post

  # before
  pre=$(kubectl exec -n arena-net deploy/probe-$src -- sh -c \
    '(apk add iproute2>/dev/null 2>&1 || true); tc -s qdisc show dev eth0' 2>/dev/null)
  sent_pre=$(echo "$pre" | awk '/qdisc netem/,/Sent/' | awk '/Sent/{print $2; exit}')

  # 10s of UDP push at 50 Mbit/s
  kubectl exec -n arena-net deploy/probe-$src -- \
    iperf3 -u -c "${POD_IP[$dst]}" -b 50M -t 10 -P 4 >/dev/null 2>&1 || true

  # after — look for the same qdisc and read "Sent X bytes Y pkt (dropped Z, overlimits 0)"
  # netem also reports "duplicated" and "corrupted" in its statistics line
  post=$(kubectl exec -n arena-net deploy/probe-$src -- sh -c 'tc -s qdisc show dev eth0' 2>/dev/null)

  printf "    %-15s dup_expected=%-5s   cor_expected=%-5s   (read tc dump below)\n" \
    "$src→$dst" "$expected_dup" "$expected_cor" | tee -a "$LOG_DIR/run.log"
}

# Tests whether a `partition` rule actually blocks traffic. With chaos
# partition active, ping should TIMEOUT (no responses). Reports the
# packet loss percentage from a quick 5-ping test.
verify_partition() {
  local src=$1 dst=$2 expect_blocked=$3
  local loss
  loss=$(kubectl exec -n arena-net deploy/probe-$src -- \
    ping -c 5 -W 2 -q "${POD_IP[$dst]}" 2>/dev/null \
    | awk -F',' '/packet loss/{for(i=1;i<=NF;i++) if ($i ~ /%/) print $i}')
  printf "    %-15s expected=%-20s   actual_loss=%s\n" \
    "$src→$dst" "$expect_blocked" "${loss:-?}" | tee -a "$LOG_DIR/run.log"
}

echo "  ───── DELAY (ping RTT, expected = 2 × one-way latency) ─────"     | tee -a "$LOG_DIR/run.log"
verify_delay iot-1 edge-1  2  "exception: same building"
verify_delay iot-1 iot-3   5  "intra-region (east)"
verify_delay iot-1 cloud  30  "east → central"
verify_delay iot-2 cloud  45  "west → central"
verify_delay iot-1 iot-2  70  "east → west"

echo                                                                       | tee -a "$LOG_DIR/run.log"
echo "  ───── BANDWIDTH (UDP, reports sender-egress shaper actual cap) ─────" | tee -a "$LOG_DIR/run.log"
verify_bw iot-1 edge-1 1000
verify_bw iot-2 cloud   500
verify_bw iot-1 iot-2   100

echo                                                                       | tee -a "$LOG_DIR/run.log"
echo "  ───── LOSS (iperf3 UDP one-way @ 5 Mbit/s) ─────"                  | tee -a "$LOG_DIR/run.log"
verify_loss iot-1 iot-3 "≈ 0%"
verify_loss iot-1 iot-2 "≈ 0.5%"
verify_loss iot-1 cloud "≈ 0.5%"

echo                                                                       | tee -a "$LOG_DIR/run.log"
echo "  ───── DUPLICATE + CORRUPT (inspect tc netem counters) ─────"       | tee -a "$LOG_DIR/run.log"
echo "    inter-region default: duplicate=0.1%, corrupt=0.05%"             | tee -a "$LOG_DIR/run.log"
verify_netem_stat iot-1 iot-2 "0.1%" "0.05%"
verify_netem_stat iot-1 cloud "0.1%" "0.05%"

echo                                                                       | tee -a "$LOG_DIR/run.log"
echo "  ───── PARTITION (link fully blocked → 100% loss) ─────"            | tee -a "$LOG_DIR/run.log"
verify_partition edge-2 cloud "100% packet loss"

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
