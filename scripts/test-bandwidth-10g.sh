#!/usr/bin/env bash
# test-bandwidth-10g.sh — single-pair bandwidth experiment.
#
# Applies ONE NetworkChaos with a 10 Gbit/s shaper on iot-1 → cloud,
# then runs iperf3 UDP from iot-1 to cloud for 5 minutes (or user-set
# duration). Reports sender-egress (= what the shaper let through)
# and receiver throughput.
#
# Usage:
#   ./scripts/test-bandwidth-10g.sh [SRC] [DST] [RATE] [DURATION_SEC]
#
# Defaults:
#   SRC=iot-1  DST=cloud  RATE=10000Mbit  DURATION_SEC=300

set -uo pipefail

SRC="${1:-iot-1}"
DST="${2:-cloud}"
RATE="${3:-10000Mbit}"
DURATION="${4:-300}"
NS="arena-net"

# ─── color helpers ─────────────────────────────────────────────
if [[ -t 1 ]]; then
  G=$'\e[1;32m'; B=$'\e[1;34m'; Y=$'\e[1;33m'; R=$'\e[1;31m'; X=$'\e[0m'
else G=""; B=""; Y=""; R=""; X=""; fi
step()  { echo; echo "${B}═══ $* ═══${X}"; }
ok()    { echo "${G}  ✓${X}  $*"; }
warn()  { echo "${Y}[WARN]${X}  $*"; }
fail()  { echo "${R}[ERR]${X}  $*"; exit 1; }

# ─── 1. preflight ──────────────────────────────────────────────
step "1. Preflight"
command -v kubectl >/dev/null || fail "kubectl missing"
kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace $NS not found — run probes first"
for t in "$SRC" "$DST"; do
  kubectl get deploy -n "$NS" "probe-$t" >/dev/null 2>&1 \
    || fail "probe-$t missing — deploy probes via run-experiment.sh"
done
SRC_IP=$(kubectl get pod -n "$NS" -l app=probe-"$SRC" -o jsonpath='{.items[0].status.podIP}')
DST_IP=$(kubectl get pod -n "$NS" -l app=probe-"$DST" -o jsonpath='{.items[0].status.podIP}')
[[ -n "$SRC_IP" && -n "$DST_IP" ]] || fail "could not resolve probe pod IPs"
ok "src=$SRC ($SRC_IP) dst=$DST ($DST_IP) rate=$RATE duration=${DURATION}s"

# ─── 2. remove any existing chaos for this pair ───────────────
step "2. Clear conflicting NetworkChaos for $SRC → $DST"
CONFLICT="netem-$SRC-to-$DST bw-test-$SRC-to-$DST"
for name in $CONFLICT; do
  kubectl delete networkchaos -n "$NS" "$name" --ignore-not-found=true >/dev/null 2>&1
done
ok "cleared"

# ─── 3. compute rate in mbit for chaos-mesh ───────────────────
# topology uses bits/s ("100Mbit"); we emit chaos-mesh `rate.rate` in
# bits/s ("mbit"/"gbit"), matching the DSL one-to-one.
step "3. Compute chaos-mesh rate"
# parse RATE: "10000Mbit" → 10_000 Mbit/s
RAW_NUM=$(echo "$RATE" | sed -E 's/[^0-9.]//g')
RAW_UNIT=$(echo "$RATE" | sed -E 's/[0-9.]//g' | tr '[:upper:]' '[:lower:]')
case "$RAW_UNIT" in
  gbit) BITS=$(awk "BEGIN{print $RAW_NUM*1e9}") ;;
  mbit) BITS=$(awk "BEGIN{print $RAW_NUM*1e6}") ;;
  kbit) BITS=$(awk "BEGIN{print $RAW_NUM*1e3}") ;;
  *)    fail "unknown RATE unit: $RAW_UNIT (use Mbit/Gbit)" ;;
esac
BITS=$(awk "BEGIN{printf \"%.0f\", $BITS}")
# pick largest unit where value is integer ≥ 1
if (( BITS >= 1000000000 )) && (( BITS % 1000000000 == 0 )); then
  CHAOS_RATE="$((BITS/1000000000))gbit"
elif (( BITS >= 1000000 )) && (( BITS % 1000000 == 0 )); then
  CHAOS_RATE="$((BITS/1000000))mbit"
elif (( BITS >= 1000 )) && (( BITS % 1000 == 0 )); then
  CHAOS_RATE="$((BITS/1000))kbit"
else
  CHAOS_RATE="${BITS}bit"
fi
ok "$RATE → $CHAOS_RATE (= ${BITS} bit/s)"

# ─── 4. apply NetworkChaos ─────────────────────────────────────
step "4. Apply NetworkChaos (action: netem, rate=$CHAOS_RATE)"
cat <<EOF | kubectl apply -f -
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: bw-test-$SRC-to-$DST
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

# Verify injection status
PHASE=$(kubectl get networkchaos -n "$NS" "bw-test-$SRC-to-$DST" -o json 2>/dev/null \
  | jq -r '.status.experiment.containerRecords[0].phase // "?"')
[[ "$PHASE" == "Injected" ]] && ok "chaos Injected" \
  || warn "phase=$PHASE (continuing anyway)"

# ─── 5. dump tc rule from inside the source pod ───────────────
step "5. Confirm tc qdisc on $SRC pod"
kubectl exec -n "$NS" deploy/probe-"$SRC" -- sh -c \
  '(apk add iproute2 >/dev/null 2>&1 || true); tc qdisc show dev eth0' 2>/dev/null \
  | head -10 || warn "could not dump tc qdisc"

# ─── 6. run iperf3 UDP for DURATION seconds ───────────────────
step "6. iperf3 UDP -P 8 -t $DURATION (target $RATE)"
# Try to push slightly more than the shaper to confirm it caps
PUSH_BIT=$(awk "BEGIN{printf \"%.0f\", $BITS*1.1}")
PUSH_MBIT=$(awk "BEGIN{printf \"%.0f\", $PUSH_BIT/1e6}")
echo "    pushing ${PUSH_MBIT}M (= 110% of $RATE) for ${DURATION}s..."

OUT=$(kubectl exec -n "$NS" deploy/probe-"$SRC" -- \
  iperf3 -u -c "$DST_IP" -b "${PUSH_MBIT}M" -P 8 -t "$DURATION" -f m 2>&1) \
  || warn "iperf3 returned non-zero"

# ─── 7. parse + report ─────────────────────────────────────────
step "7. Results"
SUM_SENT=$(echo "$OUT" | awk '/\[SUM\].*sender/{print $6" "$7}')
SUM_RECV=$(echo "$OUT" | awk '/\[SUM\].*receiver/{print $6" "$7}')
SUM_LOSS=$(echo "$OUT" | awk '/\[SUM\].*receiver/' | grep -oE '\([0-9.]+%\)' | tail -1)

# Read the actual qdisc Sent counter — the ground truth of what the shaper released.
# Match the rate we configured ($CHAOS_RATE) to find OUR netem qdisc among many.
QDISC_BYTES=$(kubectl exec -n "$NS" deploy/probe-"$SRC" -- sh -c \
  "(apk add iproute2 >/dev/null 2>&1 || true); tc -s qdisc show dev eth0" 2>/dev/null \
  | awk -v r="$CHAOS_RATE" '
      /qdisc netem/ && index($0, r) > 0 { in_target=1; next }
      /qdisc / && !/qdisc netem/ { in_target=0 }
      in_target && /Sent.*bytes/ { gsub(",", "", $2); print $2; exit }
  ')
if [[ -n "$QDISC_BYTES" && "$QDISC_BYTES" -gt 0 ]]; then
  SHAPER_OUT_MBIT=$(awk -v b="$QDISC_BYTES" -v d="$DURATION" \
    'BEGIN{printf "%.1f", (b*8)/(d*1000000)}')
else
  SHAPER_OUT_MBIT="?"
fi

echo
printf "  Expected shaper      : ${G}%-15s${X}\n" "$RATE"
printf "  iperf3 sender push   : ${G}%-15s${X}  (app-layer rate, NOT shaper egress)\n" "$SUM_SENT"
printf "  ${G}Shaper egress (tc Sent)${X}: ${G}%-15s${X}  ← ground truth of what shaper released\n" "${SHAPER_OUT_MBIT} Mbit/s"
printf "  Receiver ingress     : ${G}%-15s${X}\n" "$SUM_RECV"
printf "  UDP loss (receiver)  : ${G}%-15s${X}\n" "${SUM_LOSS:-?}"

# tc final counters (full dump for forensic)
echo
echo "  ${B}tc qdisc full dump (source pod):${X}"
kubectl exec -n "$NS" deploy/probe-"$SRC" -- sh -c \
  '(apk add iproute2 >/dev/null 2>&1 || true); tc -s qdisc show dev eth0 2>/dev/null | head -30' \
  | sed 's/^/    /' || true

# ─── 8. cleanup ────────────────────────────────────────────────
step "8. Cleanup NetworkChaos"
read -rp "  delete 'bw-test-$SRC-to-$DST' NetworkChaos now? [Y/n] " ans
[[ -z "$ans" || "$ans" =~ ^[Yy]$ ]] && {
  kubectl delete networkchaos -n "$NS" "bw-test-$SRC-to-$DST" --ignore-not-found=true
  ok "deleted"
} || ok "kept — delete manually with: kubectl delete networkchaos -n $NS bw-test-$SRC-to-$DST"

echo
echo "${B}DONE${X}"
