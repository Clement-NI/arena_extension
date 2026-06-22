"""Data model for an Arena topology spec.

A topology is: a set of named nodes (discovered from nodes.json) grouped
into regions, plus three layers of rules from broadest to narrowest:

    defaults             intra-region / inter-region fallback
    region_pairs         per (src_region, dst_region) override
    exceptions           per (src_node,   dst_node)   override

Each rule is a partial metric dict. Supported keys:

    latency      one-way delay (e.g. "20ms")
    jitter       delay variation (e.g. "5ms", requires latency)
    bw           bandwidth shaper (e.g. "100Mbit", "1Gbit")
    loss         random packet loss percentage (e.g. "0.5")
    duplicate    packet duplication percentage (e.g. "1")
    corrupt      packet corruption percentage (e.g. "0.1")
    partition    "true" to fully block the link (separate Chaos action)
    correlation  correlation factor for delay (0-100, optional)

delay/loss/duplicate/corrupt/bandwidth share one composite NetworkChaos
with action: netem. partition is emitted as its own resource with
action: partition.

Missing fields are inherited from the next-broader layer at resolve time.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set, Tuple


METRIC_KEYS = (
    "latency", "bw", "loss", "jitter",
    "duplicate", "corrupt", "partition", "correlation",
)


@dataclass(frozen=True)
class Node:
    """A Kubernetes node in the testbed."""

    name: str            # canonical name as in nodes.json, e.g. "IoT-1"
    label: str           # lowercased name used as arena.node label, e.g. "iot-1"
    tier: str            # tier name, e.g. "IoT"
    role: str            # "worker" or "control-plane"


@dataclass
class Region:
    name: str
    members: List[str] = field(default_factory=list)  # canonical node names


Metric = Dict[str, str]  # any subset of METRIC_KEYS → string value


@dataclass
class Defaults:
    intra_region: Metric = field(default_factory=dict)
    inter_region: Metric = field(default_factory=dict)


@dataclass
class RegionPair:
    src: str
    dst: str
    metric: Metric


@dataclass
class Exception_:
    src: str       # node canonical name
    dst: str       # node canonical name
    metric: Metric
    comment: str = ""


@dataclass
class Topology:
    version: str = "1"
    nodes: Dict[str, Node] = field(default_factory=dict)
    regions: Dict[str, Region] = field(default_factory=dict)
    defaults: Defaults = field(default_factory=Defaults)
    region_pairs: List[RegionPair] = field(default_factory=list)
    exceptions: List[Exception_] = field(default_factory=list)
    symmetric: bool = True

    # ---- helpers ---------------------------------------------------

    def region_of(self, node_name: str) -> Optional[str]:
        for r in self.regions.values():
            if node_name in r.members:
                return r.name
        return None

    def all_node_names(self) -> Set[str]:
        return set(self.nodes.keys())

    def workers(self) -> List[Node]:
        return [n for n in self.nodes.values() if n.role == "worker"]
