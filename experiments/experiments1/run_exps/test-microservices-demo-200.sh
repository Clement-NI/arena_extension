#!/usr/bin/env bash
set -euo pipefail

# ========= Config you can edit =========
# Prometheus (use localhost:9090 when port-forwarding)
PROM_URL="${PROM_URL:-http://localhost:9090}"

# One wait/query window used for ALL loads (seconds)
WINDOW_SEC=600

# Load profiles
LOW_USERS=200;    LOW_RATE=200

# NEW: how many times to run each load
TEST_TIMES=1



# Timeouts
NEW_POD_TIMEOUT=180   # wait for new pod to appear
READY_TIMEOUT=120     # wait for new pod to be Ready


# ---- PromQL set (use [WIN] as window placeholder) ----
KEYS=( "node_cpu" "pod_cpu" "node_mem" "pod_mem" )
QUERIES=(
  '( sum by (node) ( rate(container_cpu_usage_seconds_total{container!="", image!=""}[WIN]) * on (namespace,pod) group_left(node) kube_pod_info ) / on (node) kube_node_status_allocatable{resource="cpu", unit="core"} ) * 100'
  '1000 * sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{container!="", image!=""}[WIN]))'
  '100 * ( sum by (node) ( container_memory_working_set_bytes{container!="", image!=""} * on (namespace,pod) group_left(node) kube_pod_info ) / on (node) kube_node_status_allocatable{resource="memory", unit="byte"} )'
  'sum by (namespace, pod) ( avg_over_time(container_memory_usage_bytes{container!="", image!=""}[WIN])) / (1024 * 1024)'
)

RUN_ID=$(date +%Y%m%d-%H%M%S)
# ======================================

# ---- deps ----
for b in kubectl curl jq; do command -v "$b" >/dev/null || { echo "Missing $b" >&2; exit 1; }; done

DEPLOY="loadgenerator"
LABEL="app=${DEPLOY}"

# ---- preflight: Prometheus reachability ----
if ! curl -sf --max-time 2 "${PROM_URL}/-/ready" >/dev/null 2>&1; then
  if [[ "$PROM_URL" =~ ^http://(localhost|127\.0\.0\.1):9090/?$ ]]; then
    >&2 echo "Prometheus not reachable at ${PROM_URL}."
    >&2 echo "Be sure you have port-forward running in another terminal:"
    >&2 echo "  kubectl -n monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090"
  else
    >&2 echo "Prometheus not reachable at ${PROM_URL}. Check NodePort/IP or set PROM_URL to localhost and port-forward."
  fi
  exit 1
fi

mkdir -p results

run_one_load() {
  local label="$1" users="$2" rate="$3" first_run="$4"  # first_run: "first" | "repeat"

  echo
  echo "=== LOAD: ${label} (USERS=${users} RATE=${rate} WINDOW=${WINDOW_SEC}s) [${first_run}] ==="

  local POD

  if [[ "$first_run" == "first" ]]; then
    # capture newest current pod (may be empty if first ever run)
    local OLD_POD
    OLD_POD="$(kubectl get pods -l "$LABEL" --sort-by=.metadata.creationTimestamp \
      -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
    echo "Old pod: ${OLD_POD:-<none>}"

    # update env (auto-rollout if values changed)
    kubectl set env deployment/"$DEPLOY" USERS="$users" RATE="$rate" >/dev/null

    # wait for a new pod name
    echo "Waiting for a new pod to be created..."
    local start NEW_POD
    start=$(date +%s)
    NEW_POD=""
    while true; do
      NEW_POD="$(kubectl get pods -l "$LABEL" --sort-by=.metadata.creationTimestamp \
        -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
      if [[ -n "${NEW_POD:-}" && "${NEW_POD}" != "${OLD_POD:-}" ]]; then
        echo "New pod: $NEW_POD"
        break
      fi
      (( $(date +%s) - start > NEW_POD_TIMEOUT )) && { echo "Timed out waiting for a new pod (did USERS/RATE change?)."; exit 1; }
      sleep 2
    done
    POD="$NEW_POD"
  else
    # repeat run: reuse the newest existing pod (no env change, no rollout)
    POD="$(kubectl get pods -l "$LABEL" --sort-by=.metadata.creationTimestamp \
      -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
    if [[ -z "${POD:-}" ]]; then
      echo "No loadgenerator pod found to reuse." >&2
      exit 1
    fi
    echo "Reusing pod: $POD"
  fi

  # wait Ready
  kubectl wait --for=condition=Ready "pod/${POD}" --timeout="${READY_TIMEOUT}s"

  # show effective env
  echo "Effective env in ${POD}:"
  kubectl exec "$POD" -- sh -lc 'env | egrep "^(USERS|RATE|FRONTEND_ADDR)=" || true'

  # let it run for the window, then query Prometheus
  echo "Pod Ready. Waiting ${WINDOW_SEC}s before Prometheus query..."
  sleep "$WINDOW_SEC"
  local END_TS
  END_TS=$(date +%s)

  # ---- Run all QUERIES and save per-query, per-load ----
  for idx in "${!KEYS[@]}"; do
    key="${KEYS[$idx]}"
    promql="${QUERIES[$idx]}"

    # inject window
    q="${promql//\[WIN]/[${WINDOW_SEC}s]}"

    echo "Query [${key}] at ${PROM_URL} (t=${END_TS}, window=${WINDOW_SEC}s)..."
    RESP=$(command curl -s -G "${PROM_URL}/api/v1/query" \
      --data-urlencode "query=${q}" \
      --data-urlencode "time=${END_TS}")

    if ! echo "$RESP" | jq -e '.status=="success"' >/dev/null 2>&1; then
      echo "Prometheus query failed for '${key}' (load='${label}'):" >&2
      echo "$RESP" >&2
      exit 1
    fi

    # prepare folder: results/<load>/<key>/
    TS=$(date +%Y%m%d-%H%M%S)
    OUTDIR="results/${label}/${key}"
    mkdir -p "$OUTDIR"
    OUTFILE="${OUTDIR}/${key}_${WINDOW_SEC}s_${TS}.csv"

    # write CSV with a generic header that covers node/pod cases
    echo "metric,instance,node,namespace,pod,container,mode,value" > "$OUTFILE"
    echo "$RESP" | jq -r '
      .data.result[]? as $s
      | [
          ($s.metric.__name__ // ""),
          ($s.metric.instance // ""),
          ($s.metric.node // ""),
          ($s.metric.namespace // ""),
          ($s.metric.pod // ""),
          ($s.metric.container // ""),
          ($s.metric.mode // ""),
          ($s.value[1])
        ]
      | @csv
    ' >> "$OUTFILE"

    # record this file in a manifest for this run so we aggregate only these later
    echo "$OUTFILE" >> "${OUTDIR}/run_${RUN_ID}.list"

    echo "Saved: $OUTFILE"

    # also snapshot pods status (per query)
    PODS_FILE="${OUTDIR}/pods_${WINDOW_SEC}s_${TS}.txt"
    kubectl get pods -A -o wide > "$PODS_FILE"
    echo "Saved pods snapshot: $PODS_FILE"

  done


}



# NEW: run the same load N times (handles identical USERS/RATE by forcing a restart if needed)
run_load_n_times() {
  local label="$1" users="$2" rate="$3" times="$4"
  for i in $(seq 1 "$times"); do
    echo
    echo "--- ${label}: run ${i}/${times} ---"
    if (( i == 1 )); then
      run_one_load "$label" "$users" "$rate" "first"
    else
      run_one_load "$label" "$users" "$rate" "repeat"
    fi
  done
}


# Aggregate per-query for a load, optionally trimming min/max when TEST_TIMES > 6.
aggregate_for_label() {
  local label="$1"
  local do_trim="no"
  (( TEST_TIMES > 6 )) && do_trim="yes"

  for idx in "${!KEYS[@]}"; do
    local key="${KEYS[$idx]}"
    local outdir="results/${label}/${key}"
    local manifest="${outdir}/run_${RUN_ID}.list"
    local outfile="${outdir}/${key}_avg_${WINDOW_SEC}s_${RUN_ID}.csv"

    if [[ ! -s "$manifest" ]]; then
      echo "[info] No files to aggregate for ${label}/${key} (manifest missing or empty)."
      continue
    fi

    # Average per time series (group by first 7 columns). If do_trim=yes and count>6, drop 1 min and 1 max.
    awk -F, -v trim="$do_trim" '
      BEGIN { OFS="," }
      FNR==1 { next } # skip each file header
      {
        key = $1 OFS $2 OFS $3 OFS $4 OFS $5 OFS $6 OFS $7
        gsub(/"/, "", key)
        val = $8
        gsub(/"/, "", val)
        val += 0
        cnt[key] += 1
        sum[key] += val
        if (!(key in min) || val < min[key]) min[key] = val
        if (!(key in max) || val > max[key]) max[key] = val
      }
      END {
        print "metric,instance,node,namespace,pod,container,mode,avg_value"
        for (k in cnt) {
          c = cnt[k]; s = sum[k]
          if (trim=="yes" && c>6) { s -= min[k]; s -= max[k]; c -= 2 }
          if (c>0) printf "%s,%.10f\n", k, s/c
        }
      }
    ' $(cat "$manifest") > "$outfile"

    echo "Saved average: $outfile"
  done
}

# ---- run all loads ----
	
run_load_n_times low    "$LOW_USERS"    "$LOW_RATE"    "$TEST_TIMES"
aggregate_for_label low

echo
echo "All loads complete. CSVs are in ./results/"