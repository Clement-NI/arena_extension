#!/bin/bash

# This script cleans up the arena Testbed by deleting the Kind cluster.

# --- Configuration Variables ---
KIND_CLUSTER_NAME="arena-testbed"

# --- Helper Functions ---
log_info() {
    echo -e "\nINFO: $1"
}

log_error() {
    echo -e "\nERROR: $1"
    exit 1
}

# --- Main Script Logic ---
log_info "Checking if Kind cluster '${KIND_CLUSTER_NAME}' exists..."

if kind get clusters | grep -q "${KIND_CLUSTER_NAME}"; then
    log_info "Deleting Kind cluster '${KIND_CLUSTER_NAME}'..."
    kind delete cluster --name "${KIND_CLUSTER_NAME}" || log_error "Failed to delete Kind cluster."
    log_info "Kind cluster '${KIND_CLUSTER_NAME}' deleted successfully."
else
    log_info "Kind cluster '${KIND_CLUSTER_NAME}' does not exist. Nothing to clean up."
fi

log_info "\n--- arena Testbed Cleanup Complete! ---"