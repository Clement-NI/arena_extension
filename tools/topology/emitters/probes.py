"""Emit one Deployment + Service per worker node.

Each probe pod gets the same arena.tier / arena.node labels its host
node carries, so Chaos Mesh selectors written against arena.node match
both the pod and the placement intent. Pinned via nodeSelector to its
target node by name (Arena's testbed-role label).

The probe image (networkstatic/iperf3) runs iperf3 server + sleep; the
verify script reuses it as both server and client.
"""

from __future__ import annotations

from typing import Dict, List

import yaml

from ..model import Topology

PROBE_IMAGE = "networkstatic/iperf3"
PROBE_NAMESPACE = "arena-net"


def _ns() -> Dict:
    return {
        "apiVersion": "v1",
        "kind": "Namespace",
        "metadata": {"name": PROBE_NAMESPACE},
    }


def _deploy(name: str, label: str, tier: str, node_name: str) -> Dict:
    return {
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {
            "name": f"probe-{label}",
            "namespace": PROBE_NAMESPACE,
        },
        "spec": {
            "replicas": 1,
            "selector": {"matchLabels": {"app": f"probe-{label}"}},
            "template": {
                "metadata": {
                    "labels": {
                        "app": f"probe-{label}",
                        "arena.tier": tier,
                        "arena.node": label,
                    }
                },
                "spec": {
                    "nodeSelector": {"testbed-role": node_name},
                    "tolerations": [
                        {
                            "key": "node-role.kubernetes.io/control-plane",
                            "operator": "Exists",
                            "effect": "NoSchedule",
                        }
                    ],
                    "containers": [
                        {
                            "name": "probe",
                            "image": PROBE_IMAGE,
                            "command": [
                                "sh",
                                "-c",
                                "iperf3 -s -p 5201 & sleep infinity",
                            ],
                            "ports": [{"containerPort": 5201}],
                        }
                    ],
                },
            },
        },
    }


def _svc(label: str) -> Dict:
    return {
        "apiVersion": "v1",
        "kind": "Service",
        "metadata": {
            "name": f"probe-{label}",
            "namespace": PROBE_NAMESPACE,
        },
        "spec": {
            "selector": {"app": f"probe-{label}"},
            "ports": [{"port": 5201, "targetPort": 5201}],
        },
    }


def emit(topo: Topology) -> List[Dict]:
    out: List[Dict] = [_ns()]
    for n in topo.workers():
        out.append(_deploy(n.name, n.label, n.tier, n.name))
        out.append(_svc(n.label))
    return out


def dump(topo: Topology) -> str:
    docs = emit(topo)
    return "---\n" + "---\n".join(yaml.safe_dump(d, sort_keys=False) for d in docs)
