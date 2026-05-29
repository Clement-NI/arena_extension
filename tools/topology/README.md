# arena-topo

Region-based topology compiler for Arena. Reads:

- `arena_testbed/nodes.json` — discovers the K8s nodes
- a `topology.yaml` — declares regions and rules

And emits one of:

| format    | output                              |
|-----------|-------------------------------------|
| chaosmesh | NetworkChaos manifests (one per pair, per metric) |
| probes    | iperf3 Deployment + Service per worker node |
| csv       | resolved (src,dst,latency,bw,loss) matrix |
| mermaid   | a topology graph for the README     |

## Rule resolution

For every ordered pair of worker nodes, the effective rule is built by
merging three layers, most specific wins:

1. `exceptions[(src, dst)]`
2. `region_pairs[(src.region, dst.region)]`
3. `defaults.intra-region` or `defaults.inter-region`

Each layer is a partial dict — fields missing at one layer fall through
to the next.

## Quick start

```bash
# Discover nodes + load topology, print the resolved CSV matrix
python3 -m tools.topology.cli \
  -t examples/topology.yaml \
  -n examples/nodes-3tier-multi.json \
  preview

# Generate NetworkChaos manifests
python3 -m tools.topology.cli \
  -t examples/topology.yaml \
  -n examples/nodes-3tier-multi.json \
  compile -f chaosmesh -o topology-chaos.yaml

# Generate probe deployments (one per worker)
python3 -m tools.topology.cli \
  -t examples/topology.yaml \
  -n examples/nodes-3tier-multi.json \
  compile -f probes -o probes.yaml

# Apply both and verify
kubectl apply -f probes.yaml
kubectl wait --for=condition=Ready pod -l app -n arena-net --timeout=120s
kubectl apply -f topology-chaos.yaml
./scripts/verify-topology.sh -t examples/topology.yaml
```

## Extending

| You want to…                       | Touch this                                       |
|------------------------------------|--------------------------------------------------|
| add a new metric (e.g. duplicate)  | `emitters/chaosmesh.py` (+ `model.METRIC_KEYS`)  |
| support a new output format        | new file under `emitters/`, register in `cli.py` |
| change rule priority               | `resolver.py` only                               |
| load rules from a CSV instead      | add a plugin that builds a `Topology` directly   |
| compute latency from coordinates   | same: pre-fill `region_pairs` from a function    |

Core data model: `model.py`. Everything else is interchangeable.
