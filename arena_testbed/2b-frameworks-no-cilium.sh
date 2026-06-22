#!/usr/bin/env bash
# 2b-frameworks-no-cilium.sh — install Prometheus + Chaos Mesh WITHOUT Cilium.
#
# Use this instead of 2-set_frameworks.sh when the cluster uses kind's
# built-in CNI (kindnet) rather than Cilium — i.e. when the kind config has
# `disableDefaultCNI: false`. kindnet is installed automatically at cluster
# creation, so we must NOT also install Cilium (the two conflict).
#
# This is 2-set_frameworks.sh minus the Cilium block: it keeps the coredns /
# local-path tweaks and installs Prometheus + Chaos Mesh with the same
# control-plane pinning.
#
# Prereqs:
#   - cluster already up and nodes Ready (kindnet provides the CNI)
#   - kubeconfig working (kubectl get nodes lists the nodes)
#
# Usage:
#   ./2b-frameworks-no-cilium.sh
#
# Note: only Chaos Mesh is strictly required for the Arena NetworkChaos
# experiments. Prometheus is optional (monitoring); skip it by setting
# SKIP_PROMETHEUS=1.

set -uo pipefail

# ── 1. coredns / local-path: pin coredns to the control-plane (as in 2-set) ──
kubectl -n kube-system patch deploy coredns --type=merge -p '{
  "spec":{"template":{"spec":{
    "nodeSelector":{"node-role.kubernetes.io/control-plane":""},
    "tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]
  }}}}'
kubectl delete deployment local-path-provisioner -n local-path-storage 2>/dev/null || true

# ── 2. Prometheus (kube-prometheus-stack), components pinned to control-plane ──
if [[ "${SKIP_PROMETHEUS:-0}" != "1" ]]; then
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo update
  helm install prometheus prometheus-community/kube-prometheus-stack \
    --version 75.18.1 -n monitoring --create-namespace --wait \
    --set grafana.enabled=true --set alertmanager.enabled=false \
    --set prometheus.prometheusSpec.scrapeInterval='5s' \
    --set prometheus.prometheusSpec.enableAdminAPI=true \
    --set 'prometheus.prometheusSpec.nodeSelector.node-role\.kubernetes\.io/control-plane'='' \
    --set 'prometheus.prometheusSpec.tolerations[0].key=node-role.kubernetes.io/control-plane' \
    --set 'prometheus.prometheusSpec.tolerations[0].operator=Exists' \
    --set 'prometheus.prometheusSpec.tolerations[0].effect=NoSchedule' \
    --set 'prometheusOperator.nodeSelector.node-role\.kubernetes\.io/control-plane'='' \
    --set 'prometheusOperator.tolerations[0].key=node-role.kubernetes.io/control-plane' \
    --set 'prometheusOperator.tolerations[0].operator=Exists' \
    --set 'prometheusOperator.tolerations[0].effect=NoSchedule' \
    --set 'kube-state-metrics.nodeSelector.node-role\.kubernetes\.io/control-plane'='' \
    --set 'kube-state-metrics.tolerations[0].key=node-role.kubernetes.io/control-plane' \
    --set 'kube-state-metrics.tolerations[0].operator=Exists' \
    --set 'kube-state-metrics.tolerations[0].effect=NoSchedule' \
    --set 'grafana.nodeSelector.node-role\.kubernetes\.io/control-plane'='' \
    --set 'grafana.tolerations[0].key=node-role.kubernetes.io/control-plane' \
    --set 'grafana.tolerations[0].operator=Exists' \
    --set 'grafana.tolerations[0].effect=NoSchedule' \
    || echo "[WARN] prometheus install failed (non-fatal); retry later with: helm -n monitoring uninstall prometheus && re-run"
fi

# ── 3. Chaos Mesh (containerd runtime), components pinned to control-plane ──
#      Required for the Arena NetworkChaos experiments.
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm repo update
kubectl create ns chaos-mesh 2>/dev/null || true
helm install chaos-mesh chaos-mesh/chaos-mesh -n chaos-mesh --version 2.8.0 \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
  --set controllerManager.replicaCount=1 \
  --set 'controllerManager.nodeSelector.node-role\.kubernetes\.io/control-plane'='' \
  --set 'controllerManager.tolerations[0].key=node-role.kubernetes.io/control-plane' \
  --set 'controllerManager.tolerations[0].operator=Exists' \
  --set 'controllerManager.tolerations[0].effect=NoSchedule' \
  --set 'dashboard.nodeSelector.node-role\.kubernetes\.io/control-plane'='' \
  --set 'dashboard.tolerations[0].key=node-role.kubernetes.io/control-plane' \
  --set 'dashboard.tolerations[0].operator=Exists' \
  --set 'dashboard.tolerations[0].effect=NoSchedule' \
  --set 'dnsServer.nodeSelector.node-role\.kubernetes\.io/control-plane'='' \
  --set 'dnsServer.tolerations[0].key=node-role.kubernetes.io/control-plane' \
  --set 'dnsServer.tolerations[0].operator=Exists' \
  --set 'dnsServer.tolerations[0].effect=NoSchedule'

echo
echo "Done. Verify:"
echo "  kubectl -n chaos-mesh get pods"
echo "  kubectl -n monitoring get pods"
