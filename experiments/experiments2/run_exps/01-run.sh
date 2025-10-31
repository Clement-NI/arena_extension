#!/bin/bash
set -e

NAMESPACE="default"

log_info()  { echo -e "\033[1;34m[INFO]\033[0m $1"; }
log_error() { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

echo "Please select a number to use:"
echo "0) 0"
echo "1) 1"
echo "2) 2"
echo "5) 5"
echo "10) 10"
read -p "Enter option (0/1/2/5/10): " choice

case $choice in
  0) number=0 ;;
  1) number=1 ;;
  2) number=2 ;;
  5) number=5 ;;
  10) number=10 ;;
  *) log_error "Invalid option. Please enter 0, 1, 2, 5, or 10." ;;
esac

# Execution ID (used only to identify the scp target path)
read -p "Which run is this? (For scp target path, e.g., enter 7): " run_id
[[ -z "$run_id" || ! "$run_id" =~ ^[0-9]+$ ]] && log_error "Please enter a number."

log_info "Selected number: $number"
log_info "Execution ID (for scp path): $run_id"
log_info "========== Starting Execution =========="

log_info "Deploying microservices-demo to Kubernetes..."
kubectl apply -f yaml/

log_info "Waiting for all pods to be ready..."
kubectl wait --for=condition=Ready pods --all --timeout=300s -n "$NAMESPACE"

sleep 30

log_info "Port-forwarding Elasticsearch service..."
nohup kubectl -n "$NAMESPACE" port-forward svc/elastic-service 9200:9200 > /tmp/pf-elastic.log 2>&1 &

sleep 5

if [[ "$number" -eq 0 ]]; then
  log_info "Option 0 selected - skipping network rule installation."
else
  log_info "Applying network rules (logstash, file: net_logstash_elasticsearch-${number}.yaml)..."
  kubectl apply -f "./network/net_logstash_elasticsearch-${number}.yaml"
fi

sleep 5

log_info "Running network test..."
python3 network_test.py

sleep 30

# log_info "Copying results to remote server..."
# scp -o StrictHostKeyChecking=no es_throughput_10min.csv \
#   "chuang@172.16.207.100:/home/chuang/es_throughput_10min-${number}-${run_id}.csv"

log_info "Execution completed"
log_info "============================="