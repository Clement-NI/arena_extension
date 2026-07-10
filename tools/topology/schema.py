"""Parse + validate topology.yaml and nodes.json into a Topology model.

No external schema library: we want one dependency (PyYAML) and clear
error messages. Each `_load_*` helper raises ValueError with a path-style
location ("region_pairs[2]: ...") so the user knows exactly which field
to fix.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List, Tuple

import yaml

from .model import (
    Defaults,
    Exception_,
    Metric,
    METRIC_KEYS,
    Node,
    Region,
    RegionPair,
    Topology,
)


# ---------------------------------------------------------------------
# nodes.json (arena's existing config) → list of Node
# ---------------------------------------------------------------------


def load_nodes_from_arena(nodes_json_path: Path) -> Dict[str, Node]:
    """Discover Arena nodes from arena_testbed/nodes.json.

    Each entry in hosts[].nodes[] becomes a Node with the same dual-label
    scheme that 1-launch_cluster.sh emits (arena.tier + arena.node).
    """
    data = json.loads(nodes_json_path.read_text(encoding="utf-8"))
    hosts = data.get("hosts") or []
    out: Dict[str, Node] = {}
    for h_idx, h in enumerate(hosts):
        for n_idx, n in enumerate(h.get("nodes") or []):
            name = n.get("name")
            role = n.get("role")
            if not name or not role:
                raise ValueError(
                    f"hosts[{h_idx}].nodes[{n_idx}]: missing name or role"
                )
            tier = n.get("tier") or name.split("-")[0]
            label = name.lower()
            if name in out:
                raise ValueError(f"duplicate node name: {name}")
            out[name] = Node(name=name, label=label, tier=tier, role=role)
    if not out:
        raise ValueError(
            f"{nodes_json_path}: no nodes discovered (check hosts[].nodes[])"
        )
    return out


# ---------------------------------------------------------------------
# topology.yaml → Topology
# ---------------------------------------------------------------------


def _require(obj: Dict[str, Any], key: str, ctx: str):
    if key not in obj:
        raise ValueError(f"{ctx}: missing required key '{key}'")
    return obj[key]


def _check_metric(obj: Dict[str, Any], ctx: str) -> Metric:
    out: Metric = {}
    for k, v in obj.items():
        if k in ("from", "to", "comment"):
            continue
        if k not in METRIC_KEYS:
            raise ValueError(
                f"{ctx}: unknown metric key '{k}' (allowed: {sorted(METRIC_KEYS)})"
            )
        out[k] = str(v)
    return out


def _load_defaults(obj: Any) -> Defaults:
    if obj is None:
        return Defaults()
    if not isinstance(obj, dict):
        raise ValueError("defaults: must be a mapping")
    intra = _check_metric(obj.get("intra-region") or {}, "defaults.intra-region")
    inter = _check_metric(obj.get("inter-region") or {}, "defaults.inter-region")
    return Defaults(intra_region=intra, inter_region=inter)


def _load_regions(obj: Any, known_nodes: set) -> Dict[str, Region]:
    if obj is None:
        return {}
    if not isinstance(obj, dict):
        raise ValueError("regions: must be a mapping {name: {members: [...]}}")
    seen_members: Dict[str, str] = {}
    out: Dict[str, Region] = {}
    for name, body in obj.items():
        ctx = f"regions.{name}"
        if not isinstance(body, dict):
            raise ValueError(f"{ctx}: must be a mapping")
        members = body.get("members") or []
        if not isinstance(members, list):
            raise ValueError(f"{ctx}.members: must be a list")
        for m in members:
            if m not in known_nodes:
                raise ValueError(
                    f"{ctx}.members: unknown node '{m}' "
                    f"(known: {sorted(known_nodes)})"
                )
            if m in seen_members:
                raise ValueError(
                    f"{ctx}.members: node '{m}' already in region "
                    f"'{seen_members[m]}'"
                )
            seen_members[m] = name
        out[name] = Region(name=name, members=list(members))
    return out


def _load_region_pairs(obj: Any, known_regions: set) -> List[RegionPair]:
    if obj is None:
        return []
    if not isinstance(obj, list):
        raise ValueError("region_pairs: must be a list")
    out: List[RegionPair] = []
    for i, item in enumerate(obj):
        ctx = f"region_pairs[{i}]"
        if not isinstance(item, dict):
            raise ValueError(f"{ctx}: must be a mapping")
        src = _require(item, "from", ctx)
        dst = _require(item, "to", ctx)
        for r in (src, dst):
            if r not in known_regions:
                raise ValueError(
                    f"{ctx}: unknown region '{r}' "
                    f"(known: {sorted(known_regions)})"
                )
        metric = _check_metric(item, ctx)
        out.append(RegionPair(src=src, dst=dst, metric=metric))
    return out


def _load_exceptions(obj: Any, known_nodes: set) -> List[Exception_]:
    if obj is None:
        return []
    if not isinstance(obj, list):
        raise ValueError("exceptions: must be a list")
    out: List[Exception_] = []
    for i, item in enumerate(obj):
        ctx = f"exceptions[{i}]"
        if not isinstance(item, dict):
            raise ValueError(f"{ctx}: must be a mapping")
        src = _require(item, "from", ctx)
        dst = _require(item, "to", ctx)
        for n in (src, dst):
            if n not in known_nodes:
                raise ValueError(
                    f"{ctx}: unknown node '{n}' (known: {sorted(known_nodes)})"
                )
        metric = _check_metric(item, ctx)
        out.append(
            Exception_(
                src=src, dst=dst, metric=metric, comment=str(item.get("comment", ""))
            )
        )
    return out


def load_topology(topo_yaml: Path, nodes_json: Path) -> Topology:
    """Build a Topology from a topology.yaml + arena nodes.json."""
    nodes = load_nodes_from_arena(nodes_json)
    raw = yaml.safe_load(topo_yaml.read_text(encoding="utf-8")) or {}
    if not isinstance(raw, dict):
        raise ValueError(f"{topo_yaml}: must be a YAML mapping at the top level")

    version = str(raw.get("version", "1"))
    if version != "1":
        raise ValueError(f"unsupported topology version '{version}' (expected '1')")

    regions = _load_regions(raw.get("regions"), set(nodes.keys()))
    defaults = _load_defaults(raw.get("defaults"))
    region_pairs = _load_region_pairs(raw.get("region_pairs"), set(regions.keys()))
    exceptions = _load_exceptions(raw.get("exceptions"), set(nodes.keys()))
    symmetric = bool(raw.get("symmetric", True))

    return Topology(
        version=version,
        nodes=nodes,
        regions=regions,
        defaults=defaults,
        region_pairs=region_pairs,
        exceptions=exceptions,
        symmetric=symmetric,
    )
