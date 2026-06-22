#!/bin/bash

# Cleans up the Arena testbed by deleting the multi-host kind cluster.

set -e

log_info()  { echo -e "\nINFO: $1"; }
log_error() { echo -e "\nERROR: $1"; exit 1; }

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
CONFIG_FILE="${SCRIPT_DIR}/nodes.json"

[[ -f "$CONFIG_FILE" ]] || log_error "$CONFIG_FILE not found"

KIND_CLUSTER_NAME=$(jq -r '.cluster_name' "$CONFIG_FILE")

# Stop the Prometheus port-forward leaked by 2-set_frameworks.sh
pkill -f "kubectl.*port-forward.*prometheus" 2>/dev/null || true

log_info "Checking if Kind cluster '${KIND_CLUSTER_NAME}' exists..."
if kind get clusters | grep -q "${KIND_CLUSTER_NAME}"; then
  log_info "Deleting Kind cluster '${KIND_CLUSTER_NAME}'..."
  kind --multihost delete cluster --name "$KIND_CLUSTER_NAME" \
    || kind delete cluster --name "$KIND_CLUSTER_NAME"
  log_info "Kind cluster '${KIND_CLUSTER_NAME}' deleted successfully."
else
  log_info "Kind cluster '${KIND_CLUSTER_NAME}' does not exist. Nothing to clean up."
fi

log_info "--- Arena Testbed Cleanup Complete! ---"
