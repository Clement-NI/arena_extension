"""Emit one Deployment + Service per worker node.

Probe pods are lightweight Alpine containers (~5 MB base image) that
install iperf3 + ping + tc at startup via apk (~20 MB extra). Total
disk footprint per pod : ~25 MB compressed.

Resource limits are enforced on every probe so a probe pod cannot
balloon and cause node eviction under disk/memory pressure :
  - CPU      :  50m request, 200m limit
  - memory   :  32Mi request, 128Mi limit
  - storage  :  100Mi ephemeral-storage limit

The container runs an iperf3 server on port 5201 + sleep infinity, so
the verify script can reuse it as both server and client.

Labels propagated on every pod (matched by Chaos Mesh selectors):
  - app          : probe-<label>
  - arena.tier   : IoT | Edge | Cloud
  - arena.node   : lowercase label (e.g. iot-1)
"""

from __future__ import annotations

from typing import Dict, List

import yaml

from ..model import Topology

PROBE_IMAGE = "alpine:3.19"
PROBE_NAMESPACE = "arena-net"
PROBE_INIT = (
    "apk add --no-cache iperf3 iproute2 iputils >/dev/null 2>&1; "
    "iperf3 -s -p 5201 & "
    "sleep infinity"
)


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
                            "command": ["sh", "-c", PROBE_INIT],
                            "ports": [{"containerPort": 5201}],
                            "resources": {
                                "requests": {
                                    "cpu": "50m",
                                    "memory": "64Mi",
                                    "ephemeral-storage": "100Mi",
                                },
                                "limits": {
                                    "cpu": "500m",
                                    "memory": "256Mi",
                                    "ephemeral-storage": "200Mi",
                                },
                            },
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
