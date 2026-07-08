'''
This is our generation tool. It servers as a generator of node.json, kind-cluster-template.json and the topology.yaml
as we describe in the prompt
It should detect what we need and what we lack and ask us how to do.
'''

from __future__ import annotations

import json
from pathlib import Path
from typing import Union

import yaml
from langchain_core.tools import tool

from ai_agent.utils.states import HostSpec, ScenarioSpec
from tools.topology.compiler import compile as _compile
from tools.topology.emitters import chaosmesh as _chaosmesh
from tools.topology.emitters import csv as _csv
from tools.topology.schema import load_topology


# ---------------------------------------------------------------------------
# ScenarioSpec -> config content (the actual "generation" this tool is named
# after). Used by generate_config_files below and, through it, by both the
# chatbot and the workflow.
# ---------------------------------------------------------------------------

def _compose_nodes_json(spec: ScenarioSpec) -> dict:
    all_nodes = [{"name": n.name, "tier": n.tier, "role": n.role,
                  "cpu": n.cpu, "memory": n.memory}
                 for n in spec.expanded_nodes()]

    # single host (default) unless the spec declares machines
    hosts = spec.hosts or [HostSpec(context="default", addr="127.0.0.1")]

    # deterministic placement: the control-plane lives on the first host
    # (Arena requirement), workers round-robin across all hosts
    buckets: list = [[] for _ in hosts]
    workers = [n for n in all_nodes if n["role"] != "control-plane"]
    for cp in (n for n in all_nodes if n["role"] == "control-plane"):
        buckets[0].append(cp)
    for i, n in enumerate(workers):
        buckets[i % len(hosts)].append(n)

    return {
        "cluster_name": spec.cluster_name,
        "hosts": [
            {
                "context": h.context,
                "addr": h.addr or ("127.0.0.1" if h.context == "default" else ""),
                "nodes": bucket,
            }
            for h, bucket in zip(hosts, buckets)
        ],
    }


def _compose_topology_yaml(spec: ScenarioSpec) -> dict:
    # regions = lowercased tiers, members = worker nodes of that tier
    regions: dict = {}
    for n in spec.expanded_nodes():
        if n.role != "worker":
            continue
        regions.setdefault(n.tier.lower(), {"members": []})["members"].append(n.name)

    region_pairs = []
    for r in spec.rules:
        pair = {"from": r.from_region.lower(), "to": r.to_region.lower()}
        for key, val in (("latency", r.latency), ("bw", r.bw),
                         ("loss", r.loss), ("jitter", r.jitter)):
            if val:
                pair[key] = val
        if len(pair) > 2:            # at least one metric set
            region_pairs.append(pair)

    return {
        "version": "1",
        "symmetric": True,
        "regions": regions,
        "defaults": {
            "intra-region": {"latency": spec.default_intra_latency,
                             "bw": spec.default_intra_bw},
            "inter-region": {"latency": spec.default_inter_latency,
                             "bw": spec.default_inter_bw},
        },
        "region_pairs": region_pairs,
        "exceptions": [],
    }


def _write(path: str, content: Union[str, dict, list]) -> str:
    """Serialize (JSON for .json, YAML for .yaml/.yml) and write to disk."""
    if not isinstance(content, str):
        if str(path).lower().endswith((".yaml", ".yml")):
            content = yaml.safe_dump(content, sort_keys=False)
        else:
            content = json.dumps(content, indent=2)
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content)
    return f"wrote {p} ({len(content)} bytes)"


@tool
def generate_config_files(scenario: ScenarioSpec,
                          nodes_json_path: str = "ai_agent/out/nodes.json",
                          topology_yaml_path: str = "ai_agent/out/topology.yaml") -> str:
    """Generate nodes.json and topology.yaml from a structured ScenarioSpec.

    This is the generation step itself: it composes both Arena input files from
    the spec (cluster nodes, regions derived from tiers, default and per-pair
    network rules) and writes them to disk. Prefer this over hand-writing the
    file contents — the composition is deterministic and cannot hallucinate
    fields.

    Args:
        scenario: the structured scenario (nodes, rules, defaults, flags).
        nodes_json_path: where to write nodes.json.
        topology_yaml_path: where to write topology.yaml.

    Returns:
        A confirmation string listing both written files.
    """
    spec = scenario if isinstance(scenario, ScenarioSpec) else ScenarioSpec(**scenario)
    r1 = _write(nodes_json_path, _compose_nodes_json(spec))
    r2 = _write(topology_yaml_path, _compose_topology_yaml(spec))
    return f"{r1}; {r2}"


@tool
def write_config_file(path: str, content: Union[str, dict, list]) -> str:
    """Write generated Arena configuration to disk.

    Use this for nodes.json and topology.yaml once you have composed their full
    contents. The agent composes the text; this tool persists it so the result
    is auditable rather than buried in chat. Parent directories are created.

    Args:
        path: destination, e.g. "out/nodes.json".
        content: the file contents. Preferably a ready-to-write string, but a
            dict/list is also accepted and will be serialized (JSON for .json,
            YAML for .yaml/.yml).

    Returns:
        A confirmation string with the path and byte count.
    """
    # Many models (especially local/Ollama ones) pass structured content as a
    # dict/list instead of a serialized string; _write normalizes that.
    return _write(path, content)


@tool
def compile_topology(topology_yaml_path: str, nodes_json_path: str, fmt: str = "csv") -> str:
    """Compile topology.yaml + nodes.json into Arena output via the real compiler.

    This is the deterministic, hallucination-proof step: it runs Arena's own
    topology compiler instead of letting the model write Chaos Mesh YAML.

    Args:
        topology_yaml_path: path to the topology.yaml. (default : "arena_extension/ai_agent/out/nodes.json")
        nodes_json_path: path to the nodes.json.
        fmt: "csv" for the resolved (src,dst,latency,bw,loss) matrix preview, or
            "chaosmesh" for the NetworkChaos manifests.

    Returns:
        The compiled output, or an error string starting with "ERROR:".
    """
    try:
        topo = load_topology(Path(topology_yaml_path), Path(nodes_json_path))
        links = _compile(topo)
    except Exception as e:  # surfaced back to the model so it can self-correct
        return f"ERROR: {e}"

    if fmt == "chaosmesh":
        return _chaosmesh.dump(links)
    if fmt == "csv":
        return _csv.dump(links)
    return f"ERROR: unknown format '{fmt}' (use 'csv' or 'chaosmesh')"
