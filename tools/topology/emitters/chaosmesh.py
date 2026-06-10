"""Emit Chaos Mesh NetworkChaos manifests, one per resolved pair.

Targets pods via the arena.node label that 1-launch_cluster.sh stamps
onto every kind node (and that callers are expected to propagate to
their app pods via the same label, see examples/probes.yaml).

We use `action: netem` (composite) when latency / loss / bandwidth need
to coexist on the same pair. Per Chaos Mesh docs, `action: bandwidth`
(tbf-backed) is *mutually exclusive* with any netem field, so we route
all three through netem's built-in `rate` for bandwidth shaping.

Notes on units:
- Topology YAML expresses bandwidth in bits/s units (e.g. "100Mbit").
- We emit Chaos Mesh `rate.rate` in bytes/s units (`mbps`/`gbps`) to
  match the canonical Arena NetworkChaos format. Conversion:
  100 Mbit/s → 12 mbps.
"""

from __future__ import annotations

from typing import Dict, List, Optional, Tuple

import yaml

from ..model import Metric
from ..resolver import ResolvedLink


CHAOS_NAMESPACE = "arena-net"


def _name(prefix: str, src_label: str, dst_label: str) -> str:
    raw = f"{prefix}-{src_label}-to-{dst_label}"
    return raw.lower().replace("_", "-")


def _selector(label: str) -> Dict:
    return {
        "namespaces": [CHAOS_NAMESPACE],
        "labelSelectors": {"arena.node": label},
    }


def _parse_bits_per_sec(rate: str) -> float:
    """Parse a topology-style rate string like '100Mbit' or '1Gbit' into bits/s."""
    r = rate.strip().lower()
    units = {
        "gbit": 1e9, "gbps": 1e9 * 8,        # Gbps assumed = gigabytes
        "mbit": 1e6, "mbps": 1e6 * 8,
        "kbit": 1e3, "kbps": 1e3 * 8,
        "bit": 1,    "bps":  8,
    }
    for u, bits_per_unit in sorted(units.items(), key=lambda x: -len(x[0])):
        if r.endswith(u):
            n = float(r[: -len(u)])
            return n * bits_per_unit
    # Last resort: assume bare number means Mbit
    return float(r) * 1e6


def _to_chaos_rate(bw: str) -> str:
    """Convert '100Mbit' (topology) → integer Chaos Mesh rate string.

    Always emits with the `mbps` suffix (megabytes/s), rounded to the
    nearest integer. Matches the canonical Arena NetworkChaos format
    (e.g. "10mbps", "125mbps"). For sub-1 MB/s rates we fall back to
    `kbps`.

    Examples:
        "100Mbit" →  "12mbps"   (100/8 = 12.5 → 12, ~4% rounding loss)
        "500Mbit" →  "62mbps"   (500/8 = 62.5 → 62, ~0.8% rounding loss)
        "1Gbit"   → "125mbps"   (exact)
        "100kbit" →  "12kbps"   (sub-MB falls back to kbps)

    Chaos Mesh validates rate.rate via strconv.ParseUint so we MUST emit
    an integer.
    """
    bytes_per_sec = _parse_bits_per_sec(bw) / 8
    mbps = bytes_per_sec / 1e6
    if mbps >= 1:
        return f"{int(round(mbps))}mbps"
    kbps = bytes_per_sec / 1e3
    if kbps >= 1:
        return f"{int(round(kbps))}kbps"
    return f"{max(int(round(bytes_per_sec)), 1)}bps"


def _has_any(metric: Metric) -> bool:
    return bool(metric.get("latency") or metric.get("loss") or metric.get("bw"))


def _netem_resource(link: ResolvedLink, metric: Metric) -> Optional[Dict]:
    """One composite NetworkChaos with action=netem combining delay+loss+rate."""
    if not _has_any(metric):
        return None

    spec: Dict = {
        "action": "netem",
        "mode": "all",
        "selector": _selector(link.src.label),
        "direction": "to",
        "target": {"mode": "all", "selector": _selector(link.dst.label)},
    }

    if metric.get("latency"):
        delay_block: Dict[str, str] = {"latency": metric["latency"]}
        if metric.get("jitter"):
            delay_block["jitter"] = metric["jitter"]
        spec["delay"] = delay_block

    loss = metric.get("loss")
    if loss is not None and str(loss).rstrip("%") not in ("0", "0.0", ""):
        spec["loss"] = {"loss": str(loss).rstrip("%"), "correlation": "0"}

    if metric.get("bw"):
        spec["rate"] = {"rate": _to_chaos_rate(metric["bw"])}

    return {
        "apiVersion": "chaos-mesh.org/v1alpha1",
        "kind": "NetworkChaos",
        "metadata": {
            "name": _name("netem", link.src.label, link.dst.label),
            "namespace": CHAOS_NAMESPACE,
        },
        "spec": spec,
    }


def emit(links: List[ResolvedLink]) -> List[Dict]:
    """One composite NetworkChaos per (src, dst) pair (vs. previous 3-per-pair)."""
    out: List[Dict] = []
    for L in links:
        r = _netem_resource(L, L.metric)
        if r is not None:
            out.append(r)
    return out


def dump(links: List[ResolvedLink]) -> str:
    """Multi-document YAML string with one NetworkChaos per document."""
    docs = emit(links)
    return "---\n" + "---\n".join(yaml.safe_dump(d, sort_keys=False) for d in docs)
