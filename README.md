# Arena

Arena is a Kubernetes-based testbed for evaluating applications across the computing continuum environments. Arena emulates heterogeneous computing nodes using Docker containers and leverages Kubernetes for testbed orchestration. It integrates the Chaos Mesh framework to simulate network characteristics and Prometheus with Grafana tools for monitoring and visualization.

This repository contains the Arena setup scripts and experiment code used in the paper.

## Repository Layout
- `arena/arena-testbed`: Contains scripts for deploying an Arena instance on a single host.
- `arena/experiments/experiments1`: Contains scripts used to validate the emulation fidelity between containers and VMs.
- `arena/experiments/experiments2`: Contains scripts used to validate the network chaos injection mechanism.


## Quick Start for launching an Arean testbed

Prerequisites: `git` and `Debian 11` operating system

```bash
git clone https://github.com/satrai-lab/arena)
chmod -R +x arena/
cd arena/arena_testbed
./0-set_environments.sh
./1-launch_cluster.sh
./2-set_frameworks.sh
```

To remove the Arena testbed, run:
```bash
./3-clean_cluster.sh
```

To modify the number or specifications of nodes, edit the `nodes.json` file as shown below:
```json
{
  "cluster_name": "arena-testbed",
  "nodes": [
    {
      "name": "IoT",
      "role": "worker",
      "cpu": "1",
      "memory": "2Gi"
    },
    {
      "name": "Edge",
      "role": "worker",
      "cpu": "2",
      "memory": "4Gi"
    },
    {
      "name": "Cloud",
      "role": "worker",
      "cpu": "8",
      "memory": "16Gi"
    },
    {
      "name": "Controller",
      "role": "control-plane",
      "cpu": "8",
      "memory": "16Gi"
    }
  ]
}
```

You can deploy your application using the `kubectl` command, as shown below:

```
kubectl apply -f ./arena/experiments/experiments1/run_exps/kubernetes-manifests.yaml
```