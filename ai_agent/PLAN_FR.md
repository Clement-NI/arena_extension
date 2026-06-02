# Arena AI Agent — Plan du projet

> **Objectif** : Construire un flux de travail piloté par LLM sur le banc d'essai Arena pour transformer des descriptions d'applications en langage naturel en configurations Kubernetes + Chaos Mesh déployables, avec évaluation automatique via Prometheus.
>
> **Article associé** : Huang et al., *« Arena: A Kubernetes-based Testbed for Evaluating Application Deployment across the Computing Continuum »*, IEEE ICC 2026.
>
> **Ce plan répond au §V de l'article Arena**, qui appelle à *« un cadre de modélisation réseau conscient de la topologie permettant aux utilisateurs de spécifier des topologies au niveau applicatif »*.

---

## 1. Architecture : un seul flux, cinq tâches

```
   Langage naturel de l'utilisateur
            ↓
   [Tâche A] Compréhension NL (LLM, Ollama)
            ↓
   topology.yaml (schéma partagé — le contrat)
            ↓
   [Tâche B] Traduction YAML (Python + Jinja2)
            ↓
   YAML K8s + Chaos Mesh
            ↓
   [Tâche C] Validation multi-couches (schéma + dry-run + ressources)
            ↓ (succès)               ↓ (échec → retour à Tâche A, max 3 tentatives)
   [Tâche D] Déploiement (kubectl + vérification de santé)
            ↓
   Cluster Arena exécute l'expérience
            ↓
   [Tâche E] Évaluation (Prometheus → CSV → graphiques)
```

**Principe de conception** : le LLM gère la compréhension (son point fort) ; le code déterministe gère la génération précise et la validation. `topology.yaml` est le contrat entre les deux.

---

## 2. Les cinq tâches

| Tâche | Nom | Implémentation | Entrée | Sortie |
|---|---|---|---|---|
| **A** | Compréhension du langage naturel | LLM (Ollama) | Langage naturel utilisateur | `topology.yaml` |
| **B** | Traduction YAML | Python + Jinja2 | `topology.yaml` + `network_profiles.yaml` | Deployment + Service + NetworkChaos YAML |
| **C** | Validation multi-couches | JSON Schema + kubectl dry-run + calcul des ressources | YAML généré | Rapport de validation (pass/fail + détails) |
| **D** | Déploiement | Client Python `kubernetes` | YAML validé | État du cluster + rapport de santé |
| **E** | Évaluation et visualisation | Python + matplotlib | CSV Prometheus | Graphiques comparatifs, rapport statistique |

**Tâche A** est pilotée par LLM ; **B/C/D/E** sont du code déterministe.

---

## 3. Produit intermédiaire clé : `topology.yaml`

C'est le **contrat principal** du flux de travail, qui définit l'interface entre A et B.

```yaml
nodes:                              # Nœuds de topologie applicative
  - name: camera
    placement: IoT                  # correspond au label de nœud Arena
    image: camera-mock:latest
    replicas: 3
    resources:
      cpu: "200m"
      memory: "256Mi"

  - name: transcoder
    placement: Edge
    image: my-transcoder:latest

  - name: storage
    placement: Cloud
    image: minio/minio:latest

links:                              # Liens entre applications
  - from: camera
    to: transcoder
    network: 4G_suburban            # référence un profil réseau prédéfini

  - from: transcoder
    to: storage
    network: fiber_datacenter
```

Le fichier `network_profiles.yaml` associé (bibliothèque de scénarios) :

```yaml
4G_suburban:    { latency: "40ms", jitter: "10ms", bandwidth: "20mbps", loss: "0.5%" }
5G_urban:       { latency: "10ms", jitter: "2ms",  bandwidth: "200mbps", loss: "0.1%" }
wifi_indoor:    { latency: "5ms",                  bandwidth: "100mbps", loss: "0.3%" }
fiber_datacenter: { latency: "1ms",                bandwidth: "10gbps",  loss: "0%" }
satellite:      { latency: "600ms",                bandwidth: "5mbps",   loss: "2%" }
lossy_wireless: { latency: "20ms",                 bandwidth: "10mbps",  loss: "5%" }
```

---

## 4. Deux phases (séquence privilégiée)

### Phase 1 — LLM + Arena de base (semaines 1-4)

**Objectif** : prouver que le LLM peut piloter un déploiement de bout en bout d'applications Arena standard. Pas encore de Chaos Mesh / simulation réseau.

| Semaine | À construire | Livrable |
|---|---|---|
| **S1** | Définir le schéma `topology.yaml` (simplifié — pas encore de `links`, uniquement `nodes`). Écrire les templates Jinja2 pour Deployment + Service K8s. Traducteur de base. | `python generator.py topology.yaml` produit du YAML K8s valide |
| **S2** | Validateur : JSON Schema + `kubectl apply --dry-run` + vérification de la somme des ressources contre `nodes.json`. | `validation_report.json` |
| **S3** | Frontend LLM (Ollama). System prompt, 10 exemples few-shot, sortie JSON imposée via `format`, boucle d'auto-correction (jusqu'à 3 tentatives en cas d'échec de validation). | `python agent.py "Déployer une app web 3-tier"` → topology.yaml |
| **S4** | Déployeur (`kubectl apply` + attendre Ready) + évaluateur simple (taux de réussite du déploiement, temps avant Ready). Exécuter sur 5 prompts de test. | **🎯 Jalon 1** : succès de bout en bout sur 5 prompts |

**Évaluation de la phase 1** :
- Le LLM a-t-il produit une topologie conforme au schéma ? (objectif ≥ 80 %)
- Le YAML a-t-il passé le dry-run ? (objectif ≥ 90 %)
- Tous les pods ont-ils atteint Ready ? (objectif ≥ 70 %)
- Combien de tours d'auto-correction nécessaires ? (objectif moyenne ≤ 1,5)

---

### Phase 2 — Simulation de topologie réseau (semaines 5-8)

**Objectif** : étendre la phase 1 pour gérer la topologie réseau — liens entre services avec conditions réseau réalistes (latence, bande passante, perte de paquets). C'est la contribution nouvelle.

| Semaine | À construire | Livrable |
|---|---|---|
| **S5** | Étendre le schéma avec `links` et `network_profiles`. Ajouter 6-8 profils prédéfinis (`4G_suburban`, `5G_urban`, `wifi_indoor`, `fiber_datacenter`, `satellite`, `lossy_wireless`). Templates Chaos Mesh (delay/bandwidth/loss). | Le traducteur émet aussi les CRD `NetworkChaos` |
| **S6** | Vérification de santé : sonde par lien via `kubectl exec` pour mesurer latence/bande passante réelles vs le profil déclaré. | `link_fidelity_report.csv` |
| **S7** | Mettre à jour prompts et exemples few-shot pour apprendre au LLM les liens et profils. Refaire l'auto-correction avec le schéma enrichi. | L'agent gère « 5G entre A et B, fibre entre B et C » |
| **S8** | Exécuter 10 prompts de scénarios réels. Reproduire l'Expérience 2 de l'article Arena (limitation de bande passante Logstash). | **🎯 Jalon 2** : Figure 5 de l'article reproduite + évaluation 10 scénarios |

**Évaluation de la phase 2** :
- Reproduire les chiffres de la Figure 5 (5.7, 11.3, 27.7, 41.7, 41.9 docs/s, erreur < 10 %)
- Taux de succès de bout en bout sur 10 scénarios
- Fidélité réseau (mesuré vs déclaré, erreur < 15 %)
- Notation par experts des topologies générées (échelle 1-5)

---

## 5. Structure du projet

```
ai_agent/
├── PLAN.md
├── README.md
├── requirements.txt
├── schemas/                       # Tâches A & C partagent
│   ├── topology_schema.json
│   └── profile_schema.json
├── profiles/
│   └── network_profiles.yaml      # Bibliothèque de scénarios réseau
├── nl_understanding/              # Tâche A
│   ├── prompts/
│   │   ├── system_prompt.md
│   │   ├── examples.md
│   │   └── network_knowledge.md
│   ├── llm_client.py              # Client Ollama
│   ├── tools.py                   # Outils pour le LLM
│   └── chat.py                    # Dialogue multi-tours
├── yaml_translator/               # Tâche B
│   ├── templates/                 # Jinja2
│   │   ├── deployment.yaml.j2
│   │   ├── service.yaml.j2
│   │   ├── chaos_delay.yaml.j2
│   │   ├── chaos_bandwidth.yaml.j2
│   │   └── chaos_loss.yaml.j2
│   └── generator.py
├── validator/                     # Tâche C
│   ├── schema_validator.py
│   ├── resource_validator.py
│   └── dry_run_validator.py
├── deployer/                      # Tâche D
│   ├── deploy.py
│   ├── health_check.py
│   └── cleanup.py
├── evaluator/                     # Tâche E
│   ├── prometheus_client.py
│   ├── analyzer.py
│   └── plot.py
├── scenarios/                     # 10 scénarios d'évaluation
│   ├── smart_city.txt
│   ├── industrial_iot.txt
│   └── ...
└── main.py                        # Orchestre A→B→C→D→E
```

---

## 6. Tableau complet des indicateurs d'évaluation

| Indicateur | Phase mesurée | Méthode | Objectif |
|---|---|---|---|
| **Taux de conformité au schéma** | Tâche A | Proportion de YAML générés conformes du premier coup | > 80 % |
| **Taux de succès bout-en-bout** | A→B→C→D | Proportion de pipelines complets aboutissant au déploiement | > 70 % |
| **Tours d'auto-correction** | Boucle interne Tâche A | Nombre moyen de tentatives LLM avant YAML valide | moyenne < 1,5 |
| **Fidélité réseau** | Tâche D vérif. santé | Erreur entre latence/débit mesurés et profil déclaré | < 15 % |
| **Erreur de reproduction** | Jalon 1 | Différence avec la Figure 5 originale | < 10 % |
| **Qualité de la topologie** | Jalon 2 | Note d'expert 1-5 | moyenne > 3,5 |

---

## 7. Risques et atténuations

| Risque | Impact | Atténuation |
|---|---|---|
| Le LLM produit des noms de champs erronés (ex. « latency » écrit « delay_ms ») | Échec tâche A | Paramètre `format` Ollama + boucle d'auto-correction |
| L'empilement de plusieurs règles ChaosMesh donne un effet imprévu | Faible fidélité tâche D | Vérification de santé dans la tâche D |
| Ressources insuffisantes → pods en Pending | Échec tâche D | Vérification préalable des sommes dans la tâche C |
| Limites cgroup du bac à sable (déjà constatées) | Impossible de tester localement | Utiliser machine réelle / VM cloud |
| Description utilisateur ambiguë | Le LLM devine mal | Mécanisme de questions de clarification |

---

## 8. Stack technique

| Usage | Choix |
|---|---|
| Langage | Python 3.10+ |
| LLM | **Ollama (`qwen2.5-coder:14b` recommandé)** |
| Sortie structurée | Paramètre Ollama `format` avec JSON Schema (fonctionnalité clé !) |
| Templates | Jinja2 |
| Validation schéma | jsonschema |
| Client K8s | client Python `kubernetes` + `kubectl` |
| Métriques | API HTTP Prometheus |
| Tracés | matplotlib / seaborn |
| Tests | pytest |

**Conseils Ollama qui comptent** :
- Température 0,1–0,3 pour une sortie déterministe
- 10–15 exemples few-shot (plus que ce dont Claude a besoin)
- Boucle d'auto-correction jusqu'à 3 tours (les modèles locaux sont moins fiables que les modèles frontières)
- Utiliser `format=schema` pour imposer le JSON au niveau du sampling — fonctionnalité décisive

---

## 9. Pourquoi Ollama colle au récit d'Arena

Toute l'histoire d'Arena est **le continuum de calcul (IoT/Edge/Cloud)** — les appareils en périphérie sont à ressources limitées, ne peuvent pas dépendre du cloud. Si votre agent ne fonctionne qu'avec une API LLM cloud, vous contredisez ce message. **Un LLM local via Ollama correspond au thème déployable en périphérie d'Arena** — vous pouvez en faire un argument scientifique, pas un compromis technique.

> *« Notre agent fonctionne entièrement en local grâce à un LLM embarqué, ce qui correspond à l'accent mis par Arena sur une infrastructure déployable en périphérie. »*

---

## 10. Livrables finaux (après 8 semaines)

- [ ] Dépôt fonctionnel avec les 5 modules de tâches (`ai_agent/`)
- [ ] README + enregistrement de démo
- [ ] **Résultat phase 1** : tableau de succès du déploiement LLM sur 5 scénarios
- [ ] **Résultat phase 2** : Figure 5 de l'article Arena reproduite
- [ ] **Résultat phase 2** : évaluation 10 scénarios avec notes d'experts
- [ ] Brouillon d'article court de 1–2 pages (soumission workshop ou extension full paper)

---

## 11. Déclaration de contribution scientifique (brouillon)

> Ce travail étend le banc d'essai Arena en introduisant un flux de travail de déploiement conscient de la topologie, piloté par LLM, de bout en bout. Le système est composé de cinq tâches — compréhension du langage naturel (LLM), traduction YAML (code déterministe), validation multi-couches, déploiement automatique et évaluation — qui transforment automatiquement des descriptions d'applications en langage naturel en configurations complètes de déploiement Kubernetes et de simulation réseau Chaos Mesh. **Les expériences montrent que sur 10 scénarios du continuum de calcul, le taux de succès de déploiement bout-en-bout atteint X %, économisant Y % de temps de conception par rapport à la configuration manuelle, et reproduit fidèlement les résultats de limitation de bande passante de l'Expérience 2 de l'article Arena (erreur < 10 %).**

---

## Annexe A : exemple de `topology.yaml`

```yaml
nodes:
  - name: camera
    placement: IoT
    image: camera-mock:latest
    replicas: 3
    resources:
      cpu: "200m"
      memory: "256Mi"

  - name: transcoder
    placement: Edge
    image: my-transcoder:latest

  - name: storage
    placement: Cloud
    image: minio/minio:latest

links:
  - from: camera
    to: transcoder
    network: 4G_suburban

  - from: transcoder
    to: storage
    network: fiber_datacenter
```

## Annexe B : exemple de `network_profiles.yaml`

```yaml
4G_suburban:
  latency: "40ms"
  jitter: "10ms"
  bandwidth: "20mbps"
  loss: "0.5%"

5G_urban:
  latency: "10ms"
  jitter: "2ms"
  bandwidth: "200mbps"
  loss: "0.1%"

wifi_indoor:
  latency: "5ms"
  bandwidth: "100mbps"
  loss: "0.3%"

fiber_datacenter:
  latency: "1ms"
  bandwidth: "10gbps"
  loss: "0%"

satellite:
  latency: "600ms"
  bandwidth: "5mbps"
  loss: "2%"

lossy_wireless:
  latency: "20ms"
  bandwidth: "10mbps"
  loss: "5%"
```
