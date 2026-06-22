"""Three-layer rule resolution.

Given (src_node, dst_node), the effective metric is built by merging:

    1. defaults.intra_region OR defaults.inter_region   (broadest fallback)
    2. region_pairs[(src.region, dst.region)]            (region-pair rule)
    3. exceptions[(src.name,    dst.name)]               (most specific)

Each layer is partial; fields fall through to the next-broader layer
when missing. A node with no region falls back to inter_region rules.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional, Tuple

from .model import Metric, Node, Topology


@dataclass
class ResolvedLink:
    src: Node
    dst: Node
    metric: Metric
    layers: Tuple[str, ...]  # which layers contributed, for debugging


def _merge(base: Metric, override: Metric) -> Metric:
    out = dict(base)
    out.update(override)
    return out


def _region_pair_metric(topo: Topology, sr: Optional[str], dr: Optional[str]) -> Metric:
    if sr is None or dr is None:
        return {}
    for rp in topo.region_pairs:
        if rp.src == sr and rp.dst == dr:
            return rp.metric
    # symmetric: also look up the reverse direction
    if topo.symmetric:
        for rp in topo.region_pairs:
            if rp.src == dr and rp.dst == sr:
                return rp.metric
    return {}


def _exception_metric(topo: Topology, sn: str, dn: str) -> Metric:
    for e in topo.exceptions:
        if e.src == sn and e.dst == dn:
            return e.metric
    if topo.symmetric:
        for e in topo.exceptions:
            if e.src == dn and e.dst == sn:
                return e.metric
    return {}


def resolve(topo: Topology, src: Node, dst: Node) -> ResolvedLink:
    """Build the effective rule for an ordered pair of nodes."""
    sr = topo.region_of(src.name)
    dr = topo.region_of(dst.name)

    same_region = sr is not None and sr == dr
    default = topo.defaults.intra_region if same_region else topo.defaults.inter_region

    region_pair = _region_pair_metric(topo, sr, dr)
    exception = _exception_metric(topo, src.name, dst.name)

    metric = _merge(_merge(default, region_pair), exception)

    layers = []
    if default:
        layers.append("default")
    if region_pair:
        layers.append("region_pair")
    if exception:
        layers.append("exception")

    return ResolvedLink(src=src, dst=dst, metric=metric, layers=tuple(layers))


def all_pairs(topo: Topology) -> Tuple[Tuple[Node, Node], ...]:
    """All ordered worker-to-worker pairs (src != dst).

    Control-plane nodes are excluded — we don't shape K8s control traffic.
    When `symmetric: true` we still emit both directions so the user can
    later flip a single pair to asymmetric by adding an exception that
    overrides one direction only.
    """
    workers = topo.workers()
    out = []
    for a in workers:
        for b in workers:
            if a.name == b.name:
                continue
            out.append((a, b))
    return tuple(out)
