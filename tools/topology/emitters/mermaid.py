"""Emit a Mermaid graph of the topology for the README / paper.

Edges are labeled with latency; thicker edges = higher bandwidth (very
crude: just a textual hint, not a real style attribute). Useful as a
sanity check that what you wrote in topology.yaml is what you meant.
"""

from __future__ import annotations

from typing import Dict, List

from ..resolver import ResolvedLink


def _node_id(name: str) -> str:
    return name.replace("-", "_")


def dump(links: List[ResolvedLink]) -> str:
    seen_nodes: Dict[str, str] = {}
    for L in links:
        seen_nodes[L.src.name] = L.src.tier
        seen_nodes[L.dst.name] = L.dst.tier

    out = ["graph LR"]
    for name, tier in sorted(seen_nodes.items()):
        out.append(f"  {_node_id(name)}[{name}<br/>{tier}]")

    for L in links:
        lat = L.metric.get("latency", "?")
        bw = L.metric.get("bw", "")
        label = lat + (f" / {bw}" if bw else "")
        out.append(f"  {_node_id(L.src.name)} -- {label} --> {_node_id(L.dst.name)}")

    return "\n".join(out) + "\n"
