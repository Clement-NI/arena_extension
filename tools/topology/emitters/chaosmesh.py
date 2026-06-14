"""Emit Chaos Mesh NetworkChaos manifests, one per resolved pair.

Targets pods via the arena.node label that 1-launch_cluster.sh stamps
onto every kind node (and that callers are expected to propagate to
their app pods via the same label, see examples/probes.yaml).

For each resolved link, up to TWO NetworkChaos resources are emitted:

  1. A composite `action: netem` resource bundling delay / loss /
     bandwidth (`rate`) / duplicate / corrupt — anything netem can do
     in one go. Per Chaos Mesh docs, `action: bandwidth` (tbf-backed) is
     mutually exclusive with netem fields, so bandwidth is routed
     through netem's built-in `rate`.

  2. A separate `action: partition` resource when partition: "true" is
     set on the rule. partition fully blocks traffic in the given
     direction and is its own Chaos Mesh action, not a netem feature.

Notes on units:
- Topology YAML expresses bandwidth in bits/s units (e.g. "100Mbit").
- We emit Chaos Mesh `rate.rate` in bits/s units (`mbit`/`gbit`/`kbit`),
  which match the topology DSL unambiguously and are accepted by tc /
  chaos-mesh directly. No bytes/s conversion needed.
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

    Always emits in bits/s units (`mbit`/`gbit`/`kbit`), matching the
    topology DSL and tc semantics unambiguously. No bytes/s conversion.

    Examples:
        "100Mbit" → "100mbit"   (exact, no rounding loss)
        "500Mbit" → "500mbit"   (exact)
        "1Gbit"   → "1gbit"     (exact)
        "10Gbit"  → "10gbit"    (exact)

    Chaos Mesh validates rate.rate via strconv.ParseUint so we MUST emit
    an integer. We pick the largest unit (gbit > mbit > kbit > bit) where
    the value is still an integer ≥ 1.
    """
    bits_per_sec = _parse_bits_per_sec(bw)
    for unit, divisor in (("gbit", 1e9), ("mbit", 1e6), ("kbit", 1e3), ("bit", 1)):
        value = bits_per_sec / divisor
        if value >= 1 and value == int(value):
            return f"{int(value)}{unit}"
    return f"{max(int(round(bits_per_sec)), 1)}bit"


def _nonzero_pct(v) -> Optional[str]:
    """Normalize a percentage value (str/num). Return string % or None if 0/empty."""
    if v is None:
        return None
    s = str(v).rstrip("%").strip()
    if s == "" or s in ("0", "0.0"):
        return None
    return s


def _is_true(v) -> bool:
    return str(v).strip().lower() in ("true", "1", "yes", "on")


def _has_netem(metric: Metric) -> bool:
    return bool(
        metric.get("latency")
        or _nonzero_pct(metric.get("loss"))
        or _nonzero_pct(metric.get("duplicate"))
        or _nonzero_pct(metric.get("corrupt"))
        or metric.get("bw")
    )


def _base_spec(link: ResolvedLink, action: str) -> Dict:
    return {
        "action": action,
        "mode": "all",
        "selector": _selector(link.src.label),
        "direction": "to",
        "target": {"mode": "all", "selector": _selector(link.dst.label)},
    }


def _netem_resource(link: ResolvedLink, metric: Metric) -> Optional[Dict]:
    """Composite netem: delay + loss + bandwidth + duplicate + corrupt."""
    if not _has_netem(metric):
        return None

    spec = _base_spec(link, "netem")
    corr = str(metric.get("correlation", "0"))

    if metric.get("latency"):
        delay_block: Dict[str, str] = {"latency": metric["latency"]}
        if metric.get("jitter"):
            delay_block["jitter"] = metric["jitter"]
        if "correlation" in metric:
            delay_block["correlation"] = corr
        spec["delay"] = delay_block

    if (loss := _nonzero_pct(metric.get("loss"))) is not None:
        spec["loss"] = {"loss": loss, "correlation": corr}

    if (dup := _nonzero_pct(metric.get("duplicate"))) is not None:
        spec["duplicate"] = {"duplicate": dup, "correlation": corr}

    if (cor := _nonzero_pct(metric.get("corrupt"))) is not None:
        spec["corrupt"] = {"corrupt": cor, "correlation": corr}

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


def _partition_resource(link: ResolvedLink, metric: Metric) -> Optional[Dict]:
    """Separate NetworkChaos with action=partition: blocks all traffic on link."""
    if not _is_true(metric.get("partition")):
        return None
    return {
        "apiVersion": "chaos-mesh.org/v1alpha1",
        "kind": "NetworkChaos",
        "metadata": {
            "name": _name("partition", link.src.label, link.dst.label),
            "namespace": CHAOS_NAMESPACE,
        },
        "spec": _base_spec(link, "partition"),
    }


def emit(links: List[ResolvedLink]) -> List[Dict]:
    """Up to 2 NetworkChaos per pair: netem (composite) + partition (separate)."""
    out: List[Dict] = []
    for L in links:
        for r in (_netem_resource(L, L.metric),
                  _partition_resource(L, L.metric)):
            if r is not None:
                out.append(r)
    return out


def dump(links: List[ResolvedLink]) -> str:
    """Multi-document YAML string with one NetworkChaos per document."""
    docs = emit(links)
    return "---\n" + "---\n".join(yaml.safe_dump(d, sort_keys=False) for d in docs)
