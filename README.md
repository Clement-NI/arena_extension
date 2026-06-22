# Arena

Arena is a Kubernetes-based testbed for evaluating applications across the computing continuum environments. Arena emulates heterogeneous computing nodes using Docker containers and leverages Kubernetes for testbed orchestration. It integrates the Chaos Mesh framework to simulate network characteristics and Prometheus with Grafana tools for monitoring and visualization.

This repository contains the Arena setup scripts and experiment code used in the paper.

## Repository Layout
- `arena_testbed/`: scripts for deploying an Arena instance (single- or multi-host).
- `experiments/experiments1`: validates the emulation fidelity between containers and VMs.
- `experiments/experiments2`: validates the network chaos injection mechanism.
- `tools/topology/`: region-based topology compiler. Reads a `topology.yaml` declaring regions + per-region-pair rules + per-node-pair exceptions, emits NetworkChaos / probe deployments / CSV / Mermaid. See `tools/topology/README.md`.
- `examples/`: sample `nodes.json` (3-tier with multiple instances per tier) and matching `topology.yaml`.

## Node labels

`1-launch_cluster.sh` stamps four labels on every kind node:

| label             | example      | use it as                                  |
|-------------------|--------------|--------------------------------------------|
| `testbed-role`    | `IoT-1`      | unique node selector (backwards-compatible) |
| `arena.tier`      | `IoT`        | "any node of this tier" workloads          |
| `arena.node`      | `iot-1`      | per-instance Chaos Mesh targeting          |
| `arena.host`      | `iot-host-1` | which physical host this kind node runs on |

`arena.tier` defaults to the part before the first dash of the node name; override it explicitly with a `"tier"` field in `nodes.json` if your naming scheme differs.


## Quick Start for launching an Arena testbed

Arena now drives a **multi-host kind** cluster built from the
[`Clement-NI/kind_extension_for_arena`](https://github.com/Clement-NI/kind_extension_for_arena)
fork. Each IoT/Edge/Cloud node lives on a docker context you choose — the
placement is declared explicitly in `nodes.json`, not derived from a
round-robin.

Prerequisites:
- `git`, Debian 11, Docker reachable on the manager host.
- For multi-host runs: SSH access (key auth, `root@<host>`) from the
  manager to every worker host. You can also use the fork's
  `scripts/setup-multihost.sh` or `arena_testbed/0b-setup-multihost.sh` to propagate the SSH key and create the
  docker contexts in one go.

```bash
git clone https://github.com/Clement-NI/arena_extension
chmod -R +x arena_extension/
cd arena_extension/arena_testbed

# Builds kind from the fork; tells you how to bootstrap SSH/contexts
./0-set_environments.sh
# If you wanna start arena in multi-host mode, you can use this script to generate the docker context
./0b-setup-multihost.sh

# If you have remote hosts in nodes.json, run from this machine:
#   bash /opt/kind_extension_for_arena/scripts/setup-multihost.sh \
#        worker-host-1 worker-host-2 ...

./1-launch_cluster.sh      # writes kind-cluster-config.json and creates the cluster
./2-set_frameworks.sh
```

Teardown:
```bash
./3-clean_cluster.sh
```

### Configuring `nodes.json`

Each entry in `hosts[]` declares one physical machine **and the
Kubernetes nodes that run on it**. There is no top-level `nodes:` list;
that placement is intentional.

```json
MGR_IP=$(hostname -I | awk '{print $1}')
mapfile -t W < <(docker context ls --format '{{.Name}}' | grep -v '^default$')
echo "manager=$MGR_IP  worker1=${W[0]}  worker2=${W[1]}"
W0_IP=$(ssh root@${W[0]} "hostname -I | awk '{print \$1}'")
W1_IP=$(ssh root@${W[1]} "hostname -I | awk '{print \$1}'")
echo "${W[0]}=$W0_IP   ${W[1]}=$W1_IP"

{
  "cluster_name": "arena-testbed",
  "hosts": [
    { "context": "default", "addr": "$MGR_IP", "ssh": "",
      "nodes": [
        { "name": "Controller", "tier": "Controller", "role": "control-plane", "cpu": "4", "memory": "8Gi" },
        { "name": "Cloud", "tier": "Cloud", "role": "worker", "cpu": "8", "memory": "16Gi" }
      ]},
    { "context": "${W[0]}", "addr": "$W0_IP", "ssh": "ssh://root@${W[0]}",
      "nodes": [
        { "name": "Edge-1", "tier": "Edge", "role": "worker", "cpu": "2", "memory": "4Gi" },
        { "name": "Edge-2", "tier": "Edge", "role": "worker", "cpu": "2", "memory": "4Gi" }
      ]},
    { "context": "${W[1]}", "addr": "$W1_IP", "ssh": "ssh://root@${W[1]}",
      "nodes": [
        { "name": "IoT-1", "tier": "IoT", "role": "worker", "cpu": "1", "memory": "2Gi" },
        { "name": "IoT-2", "tier": "IoT", "role": "worker", "cpu": "1", "memory": "2Gi" },
        { "name": "IoT-3", "tier": "IoT", "role": "worker", "cpu": "1", "memory": "2Gi" }
      ]}
  ]
}
```

Field reference:

| Field | Purpose |
|---|---|
| `hosts[].context` | docker context name on the manager. Use `"default"` for the local daemon. |
| `hosts[].addr`    | externally-reachable IP/host of that machine (kubeconfig + Swarm join). |
| `hosts[].ssh`     | `ssh://user@host` URL used by `setup-multihost.sh` to create the docker context. Leave empty for `default`. |
| `hosts[].cpu`, `.memory` | total capacity of this machine, used to compute per-node `system-reserved`. Optional — falls back to the local daemon's totals when omitted. |
| `hosts[].nodes[]` | the K8s nodes scheduled on this host. Exactly one must be `control-plane`, and it lives on `hosts[0]` (the Swarm manager). |
| `nodes[].name`    | becomes the `testbed-role` label; use as `nodeSelector: testbed-role=IoT`. Shared names = multiple nodes of the same logical role. |

For a single-host run, keep one host with `context: "default"` and all
your nodes nested inside it — no SSH, no addresses, nothing else to
configure.

You can deploy your application using the `kubectl` command, as shown below:

```
kubectl apply -f ./arena/experiments/experiments1/run_exps/kubernetes-manifests.yaml
```