"""Command-line interface for the topology tool.

Subcommands:

    preview   topology.yaml + nodes.json → human-readable matrix
    compile   topology.yaml + nodes.json → NetworkChaos / CSV / Mermaid / probes
    stats     summary of how many rules came from which layer
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .compiler import compile as compile_topology
from .compiler import stats as topo_stats
from .emitters import chaosmesh, csv as csv_emitter, mermaid, probes
from .schema import load_topology


DEFAULTS_NODES = "arena_testbed/nodes.json"
DEFAULTS_TOPO = "examples/topology.yaml"


def _resolve(path_arg: str, fallback: str) -> Path:
    p = Path(path_arg or fallback)
    if not p.is_file():
        sys.exit(f"error: file not found: {p}")
    return p


def cmd_preview(args):
    topo = load_topology(_resolve(args.topology, DEFAULTS_TOPO),
                         _resolve(args.nodes, DEFAULTS_NODES))
    links = compile_topology(topo)
    print(csv_emitter.dump(links))


def cmd_compile(args):
    topo = load_topology(_resolve(args.topology, DEFAULTS_TOPO),
                         _resolve(args.nodes, DEFAULTS_NODES))
    links = compile_topology(topo)
    fmt = args.format
    if fmt == "chaosmesh":
        out = chaosmesh.dump(links)
    elif fmt == "csv":
        out = csv_emitter.dump(links)
    elif fmt == "mermaid":
        out = mermaid.dump(links)
    elif fmt == "probes":
        out = probes.dump(topo)
    else:
        sys.exit(f"error: unknown format {fmt}")
    if args.output:
        Path(args.output).write_text(out)
        print(f"wrote {args.output}", file=sys.stderr)
    else:
        print(out, end="")


def cmd_stats(args):
    topo = load_topology(_resolve(args.topology, DEFAULTS_TOPO),
                         _resolve(args.nodes, DEFAULTS_NODES))
    links = compile_topology(topo)
    s = topo_stats(links)
    print(f"total resolved pairs: {s['total']}")
    print("by source layer combination:")
    for k, v in sorted(s["by_layer"].items()):
        print(f"  {v:4d}  {k}")


def main(argv=None):
    p = argparse.ArgumentParser(prog="arena-topo", description=__doc__)
    p.add_argument("-t", "--topology", default="",
                   help=f"topology.yaml path (default: {DEFAULTS_TOPO})")
    p.add_argument("-n", "--nodes", default="",
                   help=f"nodes.json path (default: {DEFAULTS_NODES})")

    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("preview", help="print resolved matrix as CSV")
    sp.set_defaults(func=cmd_preview)

    sp = sub.add_parser("compile", help="generate output for the chosen emitter")
    sp.add_argument("-f", "--format", required=True,
                    choices=["chaosmesh", "csv", "mermaid", "probes"])
    sp.add_argument("-o", "--output", default="",
                    help="write to file instead of stdout")
    sp.set_defaults(func=cmd_compile)

    sp = sub.add_parser("stats", help="show how many rules came from which layer")
    sp.set_defaults(func=cmd_stats)

    args = p.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
