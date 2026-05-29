"""Emit Chaos Mesh NetworkChaos manifests, one per resolved pair.

Targets pods via the arena.node label that 1-launch_cluster.sh stamps
onto every kind node (and that callers are expected to propagate to
their app pods via the same label, see examples/probes.yaml).

Bandwidth and latency get separate NetworkChaos resources because Chaos
Mesh treats `bandwidth` and `delay` as different `action` values and a
single resource can only carry one action. The `loss` action is the
same — also emitted as its own resource when set.

`jitter` is folded into the delay resource as Chaos Mesh expects.
"""

from __future__ import annotations

from typing import Dict, List, Optional

import yaml

from ..model import Metric
from ..resolver import ResolvedLink


CHAOS_NAMESPACE = "arena-net"


def _name(prefix: str, src_label: str, dst_label: str) -> str:
    raw = f"{prefix}-{src_label}-to-{dst_label}"
    # K8s metadata.name must be ≤253 chars, [a-z0-9.-], start+end alnum.
    return raw.lower().replace("_", "-")


def _selector(label: str) -> Dict:
    return {
        "namespaces": [CHAOS_NAMESPACE],
        "labelSelectors": {"arena.node": label},
    }


def _bw_limit_bytes(rate: str) -> int:
    # Crude conversion → bytes for the `limit` (queue depth) field. Chaos
    # Mesh uses tc's tbf, which needs the limit in bytes. We set ~1s of
    # rate as the limit so bursts of up to one second can pass through.
    r = rate.lower()
    units = {"bit": 1 / 8, "kbit": 125, "mbit": 125_000, "gbit": 125_000_000}
    for u, factor in sorted(units.items(), key=lambda x: -len(x[0])):
        if r.endswith(u):
            n = float(r[: -len(u)])
            return max(int(n * factor), 4096)
    return 1_000_000  # fallback, 1 MB queue


def _delay_resource(link: ResolvedLink, metric: Metric) -> Optional[Dict]:
    lat = metric.get("latency")
    if not lat:
        return None
    spec = {
        "action": "delay",
        "mode": "all",
        "selector": _selector(link.src.label),
        "direction": "to",
        "target": {"mode": "all", "selector": _selector(link.dst.label)},
        "delay": {"latency": lat},
    }
    if "jitter" in metric:
        spec["delay"]["jitter"] = metric["jitter"]
    return {
        "apiVersion": "chaos-mesh.org/v1alpha1",
        "kind": "NetworkChaos",
        "metadata": {
            "name": _name("delay", link.src.label, link.dst.label),
            "namespace": CHAOS_NAMESPACE,
        },
        "spec": spec,
    }


def _bandwidth_resource(link: ResolvedLink, metric: Metric) -> Optional[Dict]:
    bw = metric.get("bw")
    if not bw:
        return None
    return {
        "apiVersion": "chaos-mesh.org/v1alpha1",
        "kind": "NetworkChaos",
        "metadata": {
            "name": _name("bw", link.src.label, link.dst.label),
            "namespace": CHAOS_NAMESPACE,
        },
        "spec": {
            "action": "bandwidth",
            "mode": "all",
            "selector": _selector(link.src.label),
            "direction": "to",
            "target": {"mode": "all", "selector": _selector(link.dst.label)},
            "bandwidth": {
                "rate": bw,
                "limit": _bw_limit_bytes(bw),
                "buffer": 10000,
            },
        },
    }


def _loss_resource(link: ResolvedLink, metric: Metric) -> Optional[Dict]:
    loss = metric.get("loss")
    if not loss:
        return None
    # Chaos Mesh expects a percentage as a string like "1" for 1%.
    pct = str(loss).rstrip("%")
    if pct in ("0", "0.0"):
        return None
    return {
        "apiVersion": "chaos-mesh.org/v1alpha1",
        "kind": "NetworkChaos",
        "metadata": {
            "name": _name("loss", link.src.label, link.dst.label),
            "namespace": CHAOS_NAMESPACE,
        },
        "spec": {
            "action": "loss",
            "mode": "all",
            "selector": _selector(link.src.label),
            "direction": "to",
            "target": {"mode": "all", "selector": _selector(link.dst.label)},
            "loss": {"loss": pct, "correlation": "25"},
        },
    }


def emit(links: List[ResolvedLink]) -> List[Dict]:
    out: List[Dict] = []
    for L in links:
        for r in (
            _delay_resource(L, L.metric),
            _bandwidth_resource(L, L.metric),
            _loss_resource(L, L.metric),
        ):
            if r is not None:
                out.append(r)
    return out


def dump(links: List[ResolvedLink]) -> str:
    """Multi-document YAML string with one NetworkChaos per document."""
    docs = emit(links)
    return "---\n" + "---\n".join(yaml.safe_dump(d, sort_keys=False) for d in docs)
