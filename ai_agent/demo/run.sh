#!/bin/bash
#
# Script de déploiement de bout en bout : Arena + topologie de démo
# À exécuter sur une vraie machine Debian 11 / Ubuntu 22.04 (pas dans un sandbox)
#
# Étapes :
#   1. Vérifier que Arena est démarré (kind + Cilium + Prometheus + ChaosMesh)
#   2. Régénérer les YAML à partir de topology.yaml
#   3. Vérifier les YAML avec kubectl --dry-run
#   4. Déployer
#   5. Attendre que les pods soient Ready
#   6. Tester la connectivité et les contraintes réseau
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

log_info()  { echo -e "\033[1;34m[INFO]\033[0m  $1"; }
log_ok()    { echo -e "\033[1;32m[OK]\033[0m    $1"; }
log_warn()  { echo -e "\033[1;33m[WARN]\033[0m  $1"; }
log_error() { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

# ── 1. Vérifier Arena ──────────────────────────────────────────
log_info "Vérification du cluster Arena..."
kubectl cluster-info >/dev/null 2>&1 || log_error "Cluster K8s injoignable. Lancez d'abord arena_testbed/1-launch_cluster.sh"

# Vérifier les labels des nœuds (IoT/Edge/Cloud)
for tier in IoT Edge Cloud; do
  kubectl get nodes -l testbed-role=$tier --no-headers 2>/dev/null | grep -q . \
    || log_warn "Aucun nœud avec label testbed-role=$tier"
done

# Vérifier ChaosMesh installé
kubectl get crd networkchaos.chaos-mesh.org >/dev/null 2>&1 \
  || log_error "ChaosMesh non installé. Lancez d'abord arena_testbed/2-set_frameworks.sh"

log_ok "Arena est prêt"

# ── 2. Régénérer les YAML ──────────────────────────────────────
log_info "Génération des YAML à partir de topology.yaml..."
python3 generator.py topology.yaml network_profiles.yaml

# ── 3. Validation dry-run ──────────────────────────────────────
log_info "Validation kubectl --dry-run..."
kubectl apply --dry-run=server -f output/deployments.yaml >/dev/null \
  || log_error "Validation deployments.yaml échouée"
kubectl apply --dry-run=server -f output/network-chaos.yaml >/dev/null \
  || log_error "Validation network-chaos.yaml échouée"
log_ok "YAML validés"

# ── 4. Déployer ────────────────────────────────────────────────
log_info "Déploiement des applications..."
kubectl apply -f output/deployments.yaml

log_info "Attente du Ready de tous les pods (timeout 300s)..."
kubectl wait --for=condition=Ready pods --all -n default --timeout=300s \
  || log_error "Pods pas Ready dans les temps"
log_ok "Tous les pods sont Ready"

log_info "Application des règles ChaosMesh (simulation réseau)..."
kubectl apply -f output/network-chaos.yaml
sleep 5
log_ok "ChaosMesh actif"

# ── 5. Tests de connectivité ───────────────────────────────────
log_info "État du déploiement :"
kubectl get pods -o wide
echo
kubectl get networkchaos
echo

log_info "Test de connectivité sensor → processor (latence attendue ~10ms) :"
SENSOR_POD=$(kubectl get pods -l app=sensor -o jsonpath='{.items[0].metadata.name}')
kubectl exec "$SENSOR_POD" -- ping -c 5 processor 2>/dev/null \
  | tail -3 || log_warn "Test ping échoué (image alpine n'a peut-être pas ping)"

log_info "Test sensor → storage (devrait être bloqué ou indirect) :"
kubectl exec "$SENSOR_POD" -- ping -c 3 storage 2>/dev/null \
  | tail -2 || true

# ── 6. Récap ───────────────────────────────────────────────────
echo
log_ok "Déploiement terminé"
echo
echo "Pour nettoyer :"
echo "  kubectl delete -f output/network-chaos.yaml"
echo "  kubectl delete -f output/deployments.yaml"
echo
echo "Pour voir les métriques :"
echo "  kubectl -n monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090"
echo "  puis ouvrir http://localhost:9090"
