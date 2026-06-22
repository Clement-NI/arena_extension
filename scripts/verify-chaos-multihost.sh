#!/usr/bin/env bash
# verify-chaos-multihost.sh — prove Chaos Mesh shapes a CROSS-HOST link.
#
# Deploys two iperf3 probe pods on TWO DIFFERENT physical hosts (picked from
# the arena.host node labels), measures the natural baseline (RTT / bandwidth /
# loss), then injects ONE NetworkChaos (netem: delay + rate + loss) on
# src -> dst, re-measures, and prints an A/B comparison with PASS/FAIL.
#
# This is the end-to-end check that Chaos Mesh's chaos-daemon actually installs
# tc rules on the pod veth even when traffic crosses the Swarm overlay between
# physical machines.
#
# Usage:
#   ./verify-chaos-multihost.sh
#
# Tunables (env):
#   DELAY=50ms JITTER=5ms RATE=100mbit LOSS=5 DURATION=10
#   PROBE_IMAGE=mirror.gcr.io/library/alpine:3.19

set -uo pipefail

NS=arena-net
SRC=chaos-src
DST=chaos-dst
DELAY="${DELAY:-50ms}"
JITTER="${JITTER:-5ms}"
RATE="${RATE:-100mbit}"          # chaos-mesh rate string (bits/s)
LOSS="${LOSS:-5}"                # percent
DURATION="${DURATION:-10}"
IMG="${PROBE_IMAGE:-mirror.gcr.io/library/alpine:3.19}"

if [[ -t 1 ]]; then G=$'\e[1;32m'; B=$'\e[1;34m'; Y=$'\e[1;33m'; R=$'\e[1;31m'; X=$'\e[0m'
else G=""; B=""; Y=""; R=""; X=""; fi
step() { echo; echo "${B}═══ $* ═══${X}"; }
ok()   { echo "${G}  ✓${X} $*"; }
warn() { echo "${Y}[WARN]${X} $*"; }
fail() { echo "${R}[ERR]${X} $*"; exit 1; }

# ─── 1. preflight: chaos-mesh + two distinct worker hosts ──────────────
step "1. Preflight"
command -v kubectl >/dev/null || fail "kubectl missing"
kubectl get ns chaos-mesh >/dev/null 2>&1 || fail "chaos-mesh not installed (run 2-set_frameworks.sh)"
mapfile -t HOSTS < <(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
  -o jsonpath='{range .items[*]}{.metadata.labels.arena\.host}{"\n"}{end}' | grep -v '^$' | sort -u)
[[ "${#HOSTS[@]}" -ge 2 ]] || fail "need >=2 distinct worker hosts (arena.host), found ${#HOSTS[@]}: ${HOSTS[*]:-none}"
HOST_A="${HOSTS[0]}"; HOST_B="${HOSTS[1]}"
ok "cross-host pair: src on '$HOST_A'  ->  dst on '$HOST_B'"

# ─── 2. deploy two iperf3 probes, one per host ─────────────────────────
step "2. Deploy probes ($SRC on $HOST_A, $DST on $HOST_B)"
init='apk add --no-cache iperf3 iproute2 iputils >/dev/null 2>&1; iperf3 -s -p 5201 & sleep infinity'
for pair in "$SRC:$HOST_A" "$DST:$HOST_B"; do
  IFS=: read -r name host <<< "$pair"
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Namespace
metadata: { name: $NS }
---
apiVersion: v1
kind: Pod
metadata:
  name: $name
  namespace: $NS
  labels: { app: $name, arena.node: $name }
spec:
  nodeSelector: { arena.host: "$host" }
  tolerations:
  - { key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule }
  containers:
  - name: probe
    image: $IMG
    command: ["sh","-c","$init"]
    resources: { requests: { cpu: 100m, memory: 128Mi }, limits: { cpu: "2", memory: 512Mi } }
EOF
done
kubectl wait --for=condition=Ready pod/$SRC pod/$DST -n $NS --timeout=180s >/dev/null \
  || fail "probes not Ready"
SRC_IP=$(kubectl get pod $SRC -n $NS -o jsonpath='{.status.podIP}')
DST_IP=$(kubectl get pod $DST -n $NS -o jsonpath='{.status.podIP}')
SRC_NODE=$(kubectl get pod $SRC -n $NS -o jsonpath='{.spec.nodeName}')
DST_NODE=$(kubectl get pod $DST -n $NS -o jsonpath='{.spec.nodeName}')
[[ -n "$SRC_IP" && -n "$DST_IP" ]] || fail "could not get probe IPs"
ok "$SRC=$SRC_IP ($SRC_NODE)   $DST=$DST_IP ($DST_NODE)"

# measurement helpers (src -> dst)
m_rtt()  { kubectl exec -n $NS $SRC -- ping -c 10 -q "$DST_IP" 2>/dev/null | awk -F'/' '/^rtt/{print $5}'; }
m_bw()   { kubectl exec -n $NS $SRC -- iperf3 -c "$DST_IP" -t "$DURATION" -P 4 -f m 2>/dev/null | awk '/\[SUM\].*sender/{print $6}'; }
m_loss() { kubectl exec -n $NS $SRC -- iperf3 -u -c "$DST_IP" -b 50M -t "$DURATION" 2>/dev/null | grep -oE '\([0-9.]+%\)' | tail -1 | tr -d '()%'; }

# ─── 3. baseline (no chaos) ────────────────────────────────────────────
step "3. Baseline (no chaos)"
B_RTT=$(m_rtt); ok "RTT  = ${B_RTT:-?} ms"
B_BW=$(m_bw);   ok "BW   = ${B_BW:-?} Mbit/s"
B_LOSS=$(m_loss); ok "loss = ${B_LOSS:-?} %"

# ─── 4. inject NetworkChaos (delay + rate + loss) ──────────────────────
step "4. Inject NetworkChaos (delay=$DELAY jitter=$JITTER rate=$RATE loss=$LOSS%)"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata: { name: verify-chaos, namespace: $NS }
spec:
  action: netem
  mode: all
  selector: { namespaces: [$NS], labelSelectors: { arena.node: $SRC } }
  direction: to
  target:
    mode: all
    selector: { namespaces: [$NS], labelSelectors: { arena.node: $DST } }
  delay: { latency: "$DELAY", jitter: "$JITTER" }
  loss:  { loss: "$LOSS", correlation: "0" }
  rate:  { rate: "$RATE" }
EOF
ok "applied — waiting 30s for chaos-daemon to install tc rules..."
sleep 30
PHASE=$(kubectl get networkchaos -n $NS verify-chaos -o jsonpath='{.status.experiment.containerRecords[0].phase}' 2>/dev/null)
[[ "$PHASE" == "Injected" ]] && ok "chaos Injected" || warn "phase=$PHASE (continuing)"

# ─── 5. shaped measurement ─────────────────────────────────────────────
step "5. Shaped (chaos active)"
S_RTT=$(m_rtt);  ok "RTT  = ${S_RTT:-?} ms"
S_BW=$(m_bw);    ok "BW   = ${S_BW:-?} Mbit/s"
S_LOSS=$(m_loss); ok "loss = ${S_LOSS:-?} %"

# ─── 6. A/B comparison + PASS/FAIL ─────────────────────────────────────
step "6. Result — does Chaos Mesh work on this cross-host link?"
exp_rtt=$(awk -v d="${DELAY%ms}" 'BEGIN{printf "%.0f", d*2}')
exp_bw=${RATE%mbit}
printf "  %-10s %-14s %-14s %s\n" "metric" "baseline" "shaped" "expected"
printf "  %-10s %-14s %-14s ~%s ms\n"   "RTT"  "${B_RTT:-?} ms"   "${S_RTT:-?} ms"   "$exp_rtt"
printf "  %-10s %-14s %-14s ~%s Mbit\n" "BW"   "${B_BW:-?} Mbit"  "${S_BW:-?} Mbit"  "$exp_bw"
printf "  %-10s %-14s %-14s ~%s %%\n"   "loss" "${B_LOSS:-?} %"   "${S_LOSS:-?} %"   "$LOSS"

pass=0; total=0
chk() { # name measured expected_lo expected_hi
  total=$((total+1))
  awk -v m="$2" -v lo="$3" -v hi="$4" 'BEGIN{exit !(m+0>=lo && m+0<=hi)}' 2>/dev/null \
    && { ok "$1 in range [$3,$4]"; pass=$((pass+1)); } \
    || warn "$1 = $2 (expected $3..$4)"
}
echo
[[ -n "$S_RTT"  ]] && chk "delay"     "$S_RTT"  "$(awk -v e="$exp_rtt" 'BEGIN{print e*0.7}')" "$(awk -v e="$exp_rtt" 'BEGIN{print e*1.6}')"
[[ -n "$S_BW"   ]] && chk "bandwidth" "$S_BW"   "1" "$(awk -v e="$exp_bw" 'BEGIN{print e*1.3}')"
[[ -n "$S_LOSS" ]] && chk "loss"      "$S_LOSS" "$(awk -v l="$LOSS" 'BEGIN{print l*0.4}')" "$(awk -v l="$LOSS" 'BEGIN{print l*3}')"
echo
if [[ "$pass" -eq "$total" && "$total" -gt 0 ]]; then
  echo "${G}  PASS — Chaos Mesh is shaping the cross-host link ($pass/$total).${X}"
else
  echo "${Y}  PARTIAL — $pass/$total checks in range (see above).${X}"
fi

# ─── 7. cleanup ────────────────────────────────────────────────────────
step "7. Cleanup"
read -rp "  delete the chaos + probe pods now? [Y/n] " ans
if [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]]; then
  kubectl delete networkchaos verify-chaos -n $NS --ignore-not-found >/dev/null 2>&1
  kubectl delete pod $SRC $DST -n $NS --ignore-not-found >/dev/null 2>&1
  ok "deleted"
else
  ok "kept — clean up later: kubectl delete networkchaos verify-chaos pod/$SRC pod/$DST -n $NS"
fi
