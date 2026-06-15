#!/usr/bin/env bash
# test-rate-cap.sh — A/B bandwidth-cap experiment for a single link.
#
# Two-phase controlled experiment on SRC → DST:
#
#   Phase A (baseline): NO chaos. Saturate the link with iperf3 TCP -P 8
#                       to discover the natural ceiling ("打满" — how much
#                       the pod/kernel can actually push).
#
#   Phase B (shaped):   Apply ONE Chaos Mesh NetworkChaos (action: netem,
#                       rate=RATE, default 500Mbit), re-saturate, and read
#                       the shaper's true egress from the tc qdisc Sent
#                       counter (ground truth) alongside iperf3 receiver
#                       throughput.
#
# Finally prints an A/B comparison so you can see baseline vs. the cap.
#
# Usage:
#   ./scripts/test-rate-cap.sh [SRC] [DST] [RATE] [DURATION_SEC]
#
# Defaults:
#   SRC=iot-1  DST=cloud  RATE=500Mbit  DURATION_SEC=10
#
# Prereq: probes already deployed in namespace arena-net
#         (run-experiment.sh steps 1-11), e.g. probe-iot-1, probe-cloud.

set -uo pipefail

SRC="${1:-iot-1}"
DST="${2:-cloud}"
RATE="${3:-500Mbit}"
DURATION="${4:-10}"
NS="arena-net"
STREAMS=8                       # parallel TCP streams to saturate the link
CHAOS_NAME="rate-cap-$SRC-to-$DST"

# ─── color helpers (match the rest of scripts/) ────────────────
if [[ -t 1 ]]; then
  G=$'\e[1;32m'; B=$'\e[1;34m'; Y=$'\e[1;33m'; R=$'\e[1;31m'; X=$'\e[0m'
else G=""; B=""; Y=""; R=""; X=""; fi
step()  { echo; echo "${B}═══ $* ═══${X}"; }
ok()    { echo "${G}  ✓${X}  $*"; }
warn()  { echo "${Y}[WARN]${X}  $*"; }
fail()  { echo "${R}[ERR]${X}  $*"; exit 1; }

# saturate SRC→DST_IP with TCP -P $STREAMS, print "<value> <unit>" (sender SUM)
saturate_tcp() {
  kubectl exec -n "$NS" deploy/probe-"$SRC" -- \
    iperf3 -c "$DST_IP" -t "$DURATION" -P "$STREAMS" -f m 2>/dev/null \
    | awk '/\[SUM\].*sender/{print $6" "$7}'
}

# ─── 1. preflight ──────────────────────────────────────────────
step "1. Preflight"
command -v kubectl >/dev/null || fail "kubectl missing"
kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace $NS not found — deploy probes first"
for t in "$SRC" "$DST"; do
  kubectl get deploy -n "$NS" "probe-$t" >/dev/null 2>&1 \
    || fail "probe-$t missing — deploy probes via run-experiment.sh (steps 1-11)"
done
DST_IP=$(kubectl get pod -n "$NS" -l app=probe-"$DST" -o jsonpath='{.items[0].status.podIP}')
[[ -n "$DST_IP" ]] || fail "could not resolve probe-$DST pod IP"
ok "src=$SRC  dst=$DST ($DST_IP)  cap=$RATE  duration=${DURATION}s  streams=$STREAMS"

# Make sure no leftover chaos from a previous run skews the baseline.
kubectl delete networkchaos -n "$NS" "$CHAOS_NAME" --ignore-not-found=true >/dev/null 2>&1

# ─── 2. Phase A — baseline (NO chaos, saturate) ────────────────
step "2. Phase A — BASELINE (no chaos, saturate with iperf3 TCP -P $STREAMS)"
BASELINE_BW=$(saturate_tcp)
ok "baseline saturated throughput = ${G}${BASELINE_BW:-?}${X}"

# ─── 3. compute chaos-mesh rate string ─────────────────────────
# topology/chaos-mesh express bandwidth in bits/s ("500Mbit" → "500mbit").
step "3. Compute chaos-mesh rate"
RAW_NUM=$(echo "$RATE" | sed -E 's/[^0-9.]//g')
RAW_UNIT=$(echo "$RATE" | sed -E 's/[0-9.]//g' | tr '[:upper:]' '[:lower:]')
case "$RAW_UNIT" in
  gbit) BITS=$(awk "BEGIN{print $RAW_NUM*1e9}") ;;
  mbit) BITS=$(awk "BEGIN{print $RAW_NUM*1e6}") ;;
  kbit) BITS=$(awk "BEGIN{print $RAW_NUM*1e3}") ;;
  *)    fail "unknown RATE unit: '$RAW_UNIT' (use Mbit/Gbit/Kbit)" ;;
esac
BITS=$(awk "BEGIN{printf \"%.0f\", $BITS}")
if   (( BITS >= 1000000000 )) && (( BITS % 1000000000 == 0 )); then CHAOS_RATE="$((BITS/1000000000))gbit"
elif (( BITS >= 1000000    )) && (( BITS % 1000000    == 0 )); then CHAOS_RATE="$((BITS/1000000))mbit"
elif (( BITS >= 1000       )) && (( BITS % 1000       == 0 )); then CHAOS_RATE="$((BITS/1000))kbit"
else CHAOS_RATE="${BITS}bit"; fi
ok "$RATE → $CHAOS_RATE (= ${BITS} bit/s)"

# ─── 4. Phase B setup — apply rate cap ─────────────────────────
step "4. Phase B — apply NetworkChaos (action: netem, rate=$CHAOS_RATE)"
cat <<EOF | kubectl apply -f -
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: $CHAOS_NAME
  namespace: $NS
spec:
  action: netem
  mode: all
  selector:
    namespaces: [$NS]
    labelSelectors:
      arena.node: $SRC
  direction: to
  target:
    mode: all
    selector:
      namespaces: [$NS]
      labelSelectors:
        arena.node: $DST
  rate:
    rate: $CHAOS_RATE
EOF
ok "applied — waiting 30 s for chaos-daemon to install tc rules..."
sleep 30
PHASE=$(kubectl get networkchaos -n "$NS" "$CHAOS_NAME" -o json 2>/dev/null \
  | jq -r '.status.experiment.containerRecords[0].phase // "?"' 2>/dev/null)
[[ "$PHASE" == "Injected" ]] && ok "chaos Injected" || warn "phase=$PHASE (continuing anyway)"

# ─── 5. Phase B measure — saturate against the cap ─────────────
step "5. Phase B — SHAPED (saturate against ${CHAOS_RATE} cap)"
SHAPED_BW=$(saturate_tcp)
ok "shaped receiver throughput (iperf3 sender SUM) = ${G}${SHAPED_BW:-?}${X}"

# tc Sent counter = ground truth of what the shaper actually released.
# Match OUR netem qdisc by the rate string we configured.
QDISC_BYTES=$(kubectl exec -n "$NS" deploy/probe-"$SRC" -- sh -c \
  "(apk add iproute2 >/dev/null 2>&1 || true); tc -s qdisc show dev eth0" 2>/dev/null \
  | awk -v r="$CHAOS_RATE" '
      BEGIN { IGNORECASE = 1 }
      /qdisc netem/ && index(tolower($0), tolower(r)) > 0 { in_target=1; next }
      /^qdisc / { in_target=0 }
      in_target && /Sent/ && /bytes/ { gsub(",", "", $2); print $2; exit }
  ')
if [[ -n "$QDISC_BYTES" && "$QDISC_BYTES" -gt 0 ]]; then
  SHAPER_OUT_MBIT=$(awk -v b="$QDISC_BYTES" -v d="$DURATION" \
    'BEGIN{printf "%.2f", (b*8)/(d*1000000)}')
else
  SHAPER_OUT_MBIT="?"
fi
ok "shaper egress (tc Sent, ground truth) = ${G}${SHAPER_OUT_MBIT} Mbit/s${X}"

# ─── 6. A/B comparison ─────────────────────────────────────────
step "6. Results — A/B comparison"
printf "    %-32s ${G}%s${X}\n" "Phase A baseline (no cap):"      "${BASELINE_BW:-?}"
printf "    %-32s ${G}%s${X}\n" "Phase B cap configured:"         "$RATE"
printf "    %-32s ${G}%s${X}\n" "Phase B iperf3 throughput:"      "${SHAPED_BW:-?}"
printf "    %-32s ${G}%s${X}\n" "Phase B shaper egress (tc):"     "${SHAPER_OUT_MBIT} Mbit/s"

# ─── 7. cleanup ────────────────────────────────────────────────
step "7. Cleanup"
read -rp "  delete NetworkChaos '$CHAOS_NAME' now? [Y/n] " ans
if [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]]; then
  kubectl delete networkchaos -n "$NS" "$CHAOS_NAME" --ignore-not-found=true
  ok "deleted"
else
  ok "kept — delete manually: kubectl delete networkchaos -n $NS $CHAOS_NAME"
fi

echo
echo "${B}DONE${X}"
