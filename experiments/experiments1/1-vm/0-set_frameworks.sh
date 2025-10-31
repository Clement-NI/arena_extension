sudo rm -f $(which kubectl)
curl -LO "https://dl.k8s.io/release/v1.33.2/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/bin/

helm repo add cilium https://helm.cilium.io/
helm repo update

helm install cilium cilium/cilium \
  --version 1.17.6 \
  --namespace kube-system \
  --set operator.replicas=1 \
  --set operator.nodeSelector."node-role\.kubernetes\.io/control-plane"="" \
  --set operator.tolerations[0].key=node-role.kubernetes.io/control-plane \
  --set operator.tolerations[0].operator=Exists \
  --set operator.tolerations[0].effect=NoSchedule \
  --set operator.tolerations[1].key=node.kubernetes.io/not-ready \
  --set operator.tolerations[1].operator=Exists \
  --set operator.tolerations[1].effect=NoSchedule \
  --set operator.tolerations[2].key=node.kubernetes.io/unreachable \
  --set operator.tolerations[2].operator=Exists \
  --set operator.tolerations[2].effect=NoExecute

echo "wait 30 secs"
for i in $(seq 30 -1 1); do
    # show countdown in English
    echo -ne "\rCountdown: $i seconds"
    sleep 1
done

kubectl -n kube-system patch deploy coredns --type=merge -p '{
  "spec": { "template": { "spec": {
    "nodeSelector": { "node-role.kubernetes.io/control-plane": "" },
    "tolerations": [
      { "key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule" }
    ]
  } } }
}'

kubectl delete deployment local-path-provisioner -n local-path-storage 

echo "wait 30 secs"
for i in $(seq 30 -1 1); do
    # show countdown in English
    echo -ne "\rCountdown: $i seconds"
    sleep 1
done

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install prometheus prometheus-community/kube-prometheus-stack \
  --version 75.18.1 \
  -n monitoring --create-namespace \
  --wait \
  --set grafana.enabled=true \
  --set alertmanager.enabled=false \
  --set prometheus.prometheusSpec.scrapeInterval='5s' \
  --set prometheus.prometheusSpec.enableAdminAPI=true \
  \
  --set 'prometheus.prometheusSpec.nodeSelector.node-role\.kubernetes\.io/control-plane'='' \
  --set 'prometheus.prometheusSpec.tolerations[0].key=node-role.kubernetes.io/control-plane' \
  --set 'prometheus.prometheusSpec.tolerations[0].operator=Exists' \
  --set 'prometheus.prometheusSpec.tolerations[0].effect=NoSchedule' \
  \
  --set 'prometheusOperator.nodeSelector.node-role\.kubernetes\.io/control-plane'='' \
  --set 'prometheusOperator.tolerations[0].key=node-role.kubernetes.io/control-plane' \
  --set 'prometheusOperator.tolerations[0].operator=Exists' \
  --set 'prometheusOperator.tolerations[0].effect=NoSchedule' \
  \
  --set 'kube-state-metrics.nodeSelector.node-role\.kubernetes\.io/control-plane'='' \
  --set 'kube-state-metrics.tolerations[0].key=node-role.kubernetes.io/control-plane' \
  --set 'kube-state-metrics.tolerations[0].operator=Exists' \
  --set 'kube-state-metrics.tolerations[0].effect=NoSchedule' \
  \
  --set 'grafana.nodeSelector.node-role\.kubernetes\.io/control-plane'='' \
  --set 'grafana.tolerations[0].key=node-role.kubernetes.io/control-plane' \
  --set 'grafana.tolerations[0].operator=Exists' \
  --set 'grafana.tolerations[0].effect=NoSchedule'

echo "wait 30 secs"
for i in $(seq 30 -1 1); do
    # show countdown in English
    echo -ne "\rCountdown: $i seconds"
    sleep 1
done

helm repo add chaos-mesh https://charts.chaos-mesh.org
kubectl create ns chaos-mesh

helm install chaos-mesh chaos-mesh/chaos-mesh \
  -n chaos-mesh \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
  --set controllerManager.replicaCount=1 \
  \
  --set 'controllerManager.nodeSelector.node-role\.kubernetes\.io/control-plane'='' \
  --set 'controllerManager.tolerations[0].key=node-role.kubernetes.io/control-plane' \
  --set 'controllerManager.tolerations[0].operator=Exists' \
  --set 'controllerManager.tolerations[0].effect=NoSchedule' \
  \
  --set 'dashboard.nodeSelector.node-role\.kubernetes\.io/control-plane'='' \
  --set 'dashboard.tolerations[0].key=node-role.kubernetes.io/control-plane' \
  --set 'dashboard.tolerations[0].operator=Exists' \
  --set 'dashboard.tolerations[0].effect=NoSchedule' \
  \
  --set 'dnsServer.nodeSelector.node-role\.kubernetes\.io/control-plane'='' \
  --set 'dnsServer.tolerations[0].key=node-role.kubernetes.io/control-plane' \
  --set 'dnsServer.tolerations[0].operator=Exists' \
  --set 'dnsServer.tolerations[0].effect=NoSchedule' \
  \
  --version 2.8.0

echo "wait 30 secs"
for i in $(seq 30 -1 1); do
    # show countdown in English
    echo -ne "\rCountdown: $i seconds"
    sleep 1
done

nohup kubectl -n monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 > /tmp/port-forward.log 2>&1 &