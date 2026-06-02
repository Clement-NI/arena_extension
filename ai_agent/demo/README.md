# Démo : déploiement Arena à partir d'une topologie

Cette démo montre le flux **manuel** (sans LLM) : à partir d'un `topology.yaml`,
générer tous les YAML Kubernetes + Chaos Mesh, et les déployer sur un cluster Arena.

C'est exactement ce que la **Tâche B** de notre AI agent fait.

## Contenu

```
demo/
├── topology.yaml           ← La topologie (entrée)
├── network_profiles.yaml   ← Bibliothèque de profils réseau
├── generator.py            ← Traducteur Python (Jinja2)
├── templates/              ← Modèles Jinja2 pour K8s + ChaosMesh
│   ├── deployment.yaml.j2
│   ├── service.yaml.j2
│   ├── chaos_delay.yaml.j2
│   ├── chaos_bandwidth.yaml.j2
│   └── chaos_loss.yaml.j2
├── output/                 ← YAML générés (régénérables)
│   ├── deployments.yaml
│   └── network-chaos.yaml
├── run.sh                  ← Script de déploiement de bout en bout
└── README.md
```

## Scénario de démo

Un pipeline « ville intelligente » :

```
3× capteurs IoT    →    1× processeur Edge    →    1× stockage Cloud
                    │                          │
                  5G urbain                fibre datacenter
                  (10ms, 200Mbps)          (1ms, 10Gbps)
```

## Prérequis (sur une vraie machine)

Avant de lancer cette démo, **Arena doit être démarré**. Depuis la racine du dépôt :

```bash
cd arena_testbed/
./0-set_environments.sh    # installe Docker, Helm
./1-launch_cluster.sh      # crée le cluster kind avec IoT/Edge/Cloud
./2-set_frameworks.sh      # installe Cilium, Prometheus, ChaosMesh
```

Et installer les deps Python :

```bash
pip install jinja2 pyyaml
```

## Usage

### Étape 1 : régénérer les YAML à partir de topology.yaml

```bash
cd ai_agent/demo
python3 generator.py topology.yaml network_profiles.yaml
```

Sortie :

```
✅ Generated 3 nodes, 2 links
   → output/deployments.yaml
   → output/network-chaos.yaml
```

### Étape 2 : déployer

```bash
./run.sh
```

Le script va :

1. Vérifier que le cluster Arena est prêt
2. Régénérer les YAML
3. Valider via `kubectl --dry-run`
4. Appliquer les Deployments
5. Attendre que tous les pods soient Ready
6. Appliquer les règles ChaosMesh
7. Tester la connectivité

### Étape 3 : observer

```bash
# Voir les pods
kubectl get pods -o wide

# Voir les règles de chaos actives
kubectl get networkchaos

# Accéder à Prometheus
kubectl -n monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090
# → http://localhost:9090
```

### Étape 4 : nettoyer

```bash
kubectl delete -f output/network-chaos.yaml
kubectl delete -f output/deployments.yaml
```

## Modifier la topologie

Éditez `topology.yaml`, par exemple pour ajouter un nœud :

```yaml
nodes:
  - name: analytics
    placement: Cloud
    image: nginx:alpine
    replicas: 1
    resources:
      cpu: "500m"
      memory: "1Gi"

links:
  - from: storage
    to: analytics
    network: fiber_datacenter
```

Puis relancez `./run.sh`.

## Ajouter un nouveau profil réseau

Éditez `network_profiles.yaml` :

```yaml
5G_indoor:
  latency: "8ms"
  bandwidth: "300mbps"
  loss: "0.05%"
```

Puis utilisez-le dans `topology.yaml` :

```yaml
links:
  - from: sensor
    to: processor
    network: 5G_indoor
```

## Notes techniques

- **Le label `testbed-role: IoT/Edge/Cloud`** des nœuds Arena est utilisé par
  `nodeSelector` pour cibler le bon tier. Ce label est posé automatiquement par
  `arena_testbed/1-launch_cluster.sh`.

- **Les règles ChaosMesh utilisent `selector + target + direction: to`** pour
  appliquer les contraintes uniquement sur la liaison voulue. C'est la
  fonctionnalité « per-link » du paper Arena §V.

- **Les ressources `cpu` et `memory`** sont définies par nœud applicatif. Le
  validateur (Tâche C de l'agent) vérifie qu'elles tiennent dans la capacité
  Arena (cf. `arena_testbed/nodes.json`).
