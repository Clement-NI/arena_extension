"""Walk every node pair, ask the resolver, hand off to emitters.

The compiler itself emits no output format — it produces a flat list of
ResolvedLink objects. Each emitter consumes that list independently, so
adding a new output format (Mermaid diagram, Prometheus rules, etc.)
never touches the resolution logic.
"""

from __future__ import annotations

from typing import List

from .model import Topology
from .resolver import ResolvedLink, all_pairs, resolve


def compile(topo: Topology) -> List[ResolvedLink]:
    pairs = all_pairs(topo)
    out: List[ResolvedLink] = []
    for src, dst in pairs:
        link = resolve(topo, src, dst)
        # Skip pairs that have no rule at all (no default and no override).
        if not link.metric:
            continue
        out.append(link)
    return out


def stats(links: List[ResolvedLink]) -> dict:
    by_layer = {}
    for L in links:
        key = "+".join(L.layers) or "(none)"
        by_layer[key] = by_layer.get(key, 0) + 1
    return {"total": len(links), "by_layer": by_layer}
