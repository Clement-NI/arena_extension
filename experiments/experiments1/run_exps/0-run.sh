#!/bin/bash
set -e

NAMESPACE="default"

log_info()  { echo -e "\033[1;34m[INFO]\033[0m $1"; }
log_error() { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

echo "Please choose a number to use:"
echo "0) 1"
echo "1) 100"
echo "2) 200"
read -p "Enter option (0/1/2): " choice

case $choice in
  0) number=1 ;;
  1) number=100 ;;
  2) number=200 ;;
  *) log_error "Invalid option. Please enter 1, 2, or 3." ;;
esac

# # Execution ID (used only for identifying scp target path)
# read -p "Which run is this? (For scp target path, e.g., enter 7): " run_id
# [[ -z "$run_id" || ! "$run_id" =~ ^[0-9]+$ ]] && log_error "Please enter a number."

log_info "Selected number: $number"
# log_info "Execution ID (for scp path): $run_id"
log_info "========== Starting Execution =========="

log_info "Deploying microservices-demo to Kubernetes..."
kubectl apply -f kubernetes-manifests.yaml

log_info "Waiting for all pods to be ready..."
kubectl wait --for=condition=Ready pods --all -n "$NAMESPACE" --timeout=300s

sleep 30

bash "./test-microservices-demo-$number.sh"

# sleep 30
# log_info "Copying results to remote server..."
# scp -o StrictHostKeyChecking=no -r ./results \
#   "chuang@172.16.207.100:/home/chuang/arena_results-docker-${number}-run${run_id}"

sleep 30

kubectl delete -f kubernetes-manifests.yaml

sleep 60

log_info "Execution completed"
log_info "============================="