#!/bin/bash
set -e

# ───────────────────────────────────────────────────────────────
# arena Testbed Setup Script (multi-host kind, YAML host pinning)
# ───────────────────────────────────────────────────────────────

echo ""
echo " █████╗ ██████╗ ███████╗███╗   ██╗ █████╗ "
echo "██╔══██╗██╔══██╗██╔════╝████╗  ██║██╔══██╗"
echo "███████║██████╔╝█████╗  ██╔██╗ ██║███████║"
echo "██╔══██║██╔══██╗██╔══╝  ██║╚██╗██║██╔══██║"
echo "██║  ██║██║  ██║███████╗██║ ╚████║██║  ██║"
echo "╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═══╝╚═╝  ╚═╝"
echo ""

log_info()  { echo -e "\033[1;34m[INFO]\033[0m $1"; }
log_warn()  { echo -e "\033[1;33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

# ───────────────────────────────────────────────────────────────
# Preflight
# ───────────────────────────────────────────────────────────────

command -v docker >/dev/null 2>&1 || log_error "Docker is not installed. Run ./0-set_environments.sh first."
docker info >/dev/null 2>&1       || log_error "Docker is not running."
command -v kind >/dev/null 2>&1   || log_error "kind is not installed. Run ./0-set_environments.sh first."
command -v jq >/dev/null 2>&1     || log_error "jq is not installed."

kind --help 2>&1 | grep -q -- '--multihost' \
  || log_error "Installed kind does not support --multihost. Rebuild from the Arena fork."

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
CONFIG_FILE="${SCRIPT_DIR}/nodes.json"
TEMPLATE_FILE="${SCRIPT_DIR}/kind-cluster-template.json"
OUTPUT_FILE="${SCRIPT_DIR}/kind-cluster-config.json"

[[ -f "$CONFIG_FILE"   ]] || log_error "$CONFIG_FILE not found"
[[ -f "$TEMPLATE_FILE" ]] || log_error "$TEMPLATE_FILE not found"

HOSTS_LEN=$(jq '.hosts | length' "$CONFIG_FILE")
[[ "$HOSTS_LEN" -ge 1 ]] || log_error "nodes.json has no .hosts[] entries"

# Exactly one control-plane across the whole topology
CP_COUNT=$(jq '[.hosts[].nodes[] | select(.role == "control-plane")] | length' "$CONFIG_FILE")
[[ "$CP_COUNT" -eq 1 ]] || log_error "nodes.json must contain exactly one control-plane node (found $CP_COUNT)"

# ───────────────────────────────────────────────────────────────
# Resolve per-host capacity (for system-reserved math)
# ───────────────────────────────────────────────────────────────
# Hosts that omit cpu/memory fall back to this machine's docker info
# totals. Fine when every host is identical to the local machine; for a
# heterogeneous fleet, set hosts[].cpu / hosts[].memory explicitly.

LOCAL_NCPU=$(docker info --format '{{.NCPU}}')
LOCAL_MEM_BYTES=$(docker info --format '{{.MemTotal}}')
LOCAL_MEM_GIB=$(awk "BEGIN {printf \"%.2f\", $LOCAL_MEM_BYTES / (1024*1024*1024)}" | sed 's/,/./')

log_info "Local docker daemon: ${LOCAL_NCPU} CPU / ${LOCAL_MEM_GIB} GiB (fallback for hosts without cpu/memory)"

# ───────────────────────────────────────────────────────────────
# Build the kind config: hosts[].nodes[] with per-node kubeadm patches
# ───────────────────────────────────────────────────────────────

HOSTS_BUILT=$(jq --argjson lcpu "$LOCAL_NCPU" --argjson lmem "$LOCAL_MEM_GIB" '
  [.hosts[] |
    ((if (.cpu // "" | tostring | test("^[0-9.]+$"))
        then (.cpu | tonumber)
        else $lcpu end) as $host_cpu |
     (if (.memory // "" | tostring | test("Gi$"))
        then (.memory | sub("Gi"; "") | tonumber)
      elif (.memory // "" | tostring | test("Mi$"))
        then (.memory | sub("Mi"; "") | tonumber / 1024)
      else $lmem end) as $host_mem_gib |
     {
       context: .context,
       addr: .addr,
       nodes: [.nodes[] |
         (if (.cpu | tostring | test("^[0-9.]+$")) then (.cpu | tonumber) else 0 end) as $node_cpu |
         (if (.memory | test("Gi$")) then (.memory | sub("Gi"; "") | tonumber * 1024)
          elif (.memory | test("Mi$")) then (.memory | sub("Mi"; "") | tonumber)
          else 0 end) as $node_mem_mib |
         ($host_cpu - $node_cpu)              as $cpu_reserved |
         (($host_mem_gib * 1024) - $node_mem_mib) as $mem_reserved |
         {
           role: .role,
           image: "kindest/node:v1.33.2",
           labels: {
             "testbed-role": .name,
             "arena.host": .context
           },
           kubeadmConfigPatches: [
             "apiVersion: kubeadm.k8s.io/v1beta3\nkind: \"" +
             (if .role == "control-plane" then "Init" else "Join" end) +
             "Configuration\"\nnodeRegistration:\n  kubeletExtraArgs:\n    system-reserved: \"cpu=" +
             ($cpu_reserved | tostring) + ",memory=" + ($mem_reserved | tostring) +
             "Mi\"\n    eviction-hard: \"memory.available<100Mi,nodefs.available<5%,nodefs.inodesFree<3%\""
           ]
         }
       ]
     })
  ]' "$CONFIG_FILE")

# Refuse negative reserved values (node asks for more than its host has)
NEG=$(echo "$HOSTS_BUILT" | jq '[.[].nodes[] | select((.kubeadmConfigPatches[0] | test("cpu=-")) or (.kubeadmConfigPatches[0] | test("memory=-")))] | length')
if [[ "$NEG" != "0" ]]; then
  log_error "A node requests more CPU/memory than its parent host has. Check hosts[].cpu/memory vs nodes[].cpu/memory in nodes.json."
fi

# The "arena.host" label inside .labels has to be set per host, not via the
# jq closure above (which would freeze the parent .context). Patch it now:
HOSTS_BUILT=$(echo "$HOSTS_BUILT" | jq '
  map(.context as $ctx | .nodes |= map(.labels."arena.host" = $ctx))
')

# Inject into the cluster template
jq --argjson hosts "$HOSTS_BUILT" '.hosts = ($hosts | map({context, addr, nodes}))' "$TEMPLATE_FILE" > "$OUTPUT_FILE"
log_info "Kind config written to $OUTPUT_FILE"

# Display the placement plan
log_info "Placement plan:"
jq -r '.hosts[] | "  \(.context) (\(.addr)): \(.nodes | map(.labels."testbed-role") | join(", "))"' "$OUTPUT_FILE"

# ───────────────────────────────────────────────────────────────
# Create the cluster
# ───────────────────────────────────────────────────────────────
# With the YAML hosts: block, kind's swarm provider derives its host list
# from the config itself — we do NOT need --hosts on the CLI. We still
# pass --multihost (to select the swarm provider) and --bootstrap-swarm
# (to let kind run docker swarm init / join automatically).

KIND_CLUSTER_NAME=$(jq -r '.cluster_name' "$CONFIG_FILE")

if kind get clusters | grep -q "${KIND_CLUSTER_NAME}"; then
  log_warn "Cluster '${KIND_CLUSTER_NAME}' already exists. Deleting first..."
  kind --multihost delete cluster --name "$KIND_CLUSTER_NAME" || \
    kind delete cluster --name "$KIND_CLUSTER_NAME"
fi

log_info "Creating cluster '${KIND_CLUSTER_NAME}' across ${HOSTS_LEN} host(s)..."
kind --multihost --bootstrap-swarm create cluster \
  --name "$KIND_CLUSTER_NAME" \
  --config "$OUTPUT_FILE" \
  || log_error "kind cluster creation failed"

kubectl config use-context "kind-${KIND_CLUSTER_NAME}" || log_error "Failed to set kubectl context"

log_info "Cluster up. Run ./2-set_frameworks.sh to install Cilium / Prometheus / Chaos Mesh."
