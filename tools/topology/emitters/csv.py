"""Emit a latency matrix as CSV — handy for `preview` and for plots."""

from __future__ import annotations

import csv
import io
from typing import List

from ..resolver import ResolvedLink


def dump(links: List[ResolvedLink]) -> str:
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["from", "to", "latency", "bw", "loss", "jitter", "layers"])
    for L in links:
        w.writerow(
            [
                L.src.name,
                L.dst.name,
                L.metric.get("latency", ""),
                L.metric.get("bw", ""),
                L.metric.get("loss", ""),
                L.metric.get("jitter", ""),
                "+".join(L.layers),
            ]
        )
    return buf.getvalue()
