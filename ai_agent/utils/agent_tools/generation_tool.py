'''
This is our generation tool. It servers as a generator of node.json, kind-cluster-template.json and the topology.yaml
as we describe in the prompt
It should detect what we need and what we lack and ask us how to do.
'''

from __future__ import annotations

import json
from pathlib import Path
from typing import Union

import yaml
from langchain_core.tools import tool

from tools.topology.compiler import compile as _compile
from tools.topology.emitters import chaosmesh as _chaosmesh
from tools.topology.emitters import csv as _csv
from tools.topology.schema import load_topology


# Canonical output directory = <project>/ai_agent/out/, computed from THIS file's
# location so it never depends on the current working directory or on whatever
# path prefix the model guesses.
#   generation_tool.py -> agent_tools -> utils -> ai_agent
_AI_AGENT_DIR = Path(__file__).resolve().parent.parent.parent
OUT_DIR = _AI_AGENT_DIR / "out"


def _resolve_out(path: str) -> Path:
    """Anchor any model-supplied path to <project>/ai_agent/out/<filename>.

    Weak/local models often prepend stray prefixes like
    'arena_extension/ai_agent/out/', which would create nested folders relative
    to the current directory. We keep only the file name and pin it to the
    canonical out dir, so files always land in the same place and the
    validate/compile tools can find them again.
    """
    return OUT_DIR / Path(path).name


@tool
def write_config_file(path: str, content: Union[str, dict, list]) -> str:
    """Write generated Arena configuration to disk.

    Use this for nodes.json and topology.yaml once you have composed their full
    contents. The agent composes the text; this tool persists it so the result
    is auditable rather than buried in chat. Parent directories are created.

    Args:
        path: destination, e.g. "ai_agent/out/nodes.json".
        content: the file contents. Preferably a ready-to-write string, but a
            dict/list is also accepted and will be serialized (JSON for .json,
            YAML for .yaml/.yml).

    Returns:
        A confirmation string with the path and byte count.
    """
    # Many models (especially local/Ollama ones) pass structured content as a
    # dict/list instead of a serialized string. Normalize it so the tool call
    # doesn't fail schema validation and the file still gets written.
    p = _resolve_out(path)
    if not isinstance(content, str):
        if p.suffix.lower() in (".yaml", ".yml"):
            content = yaml.safe_dump(content, sort_keys=False)
        else:
            content = json.dumps(content, indent=2)

    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content)
    return f"wrote {p} ({len(content)} bytes)"


@tool
def compile_topology(topology_yaml_path: str, nodes_json_path: str, fmt: str = "csv") -> str:
    """Compile topology.yaml + nodes.json into Arena output via the real compiler.

    This is the deterministic, hallucination-proof step: it runs Arena's own
    topology compiler instead of letting the model write Chaos Mesh YAML.

    Args:
        topology_yaml_path: path to the topology.yaml. (default : "arena_extension/ai_agent/out/nodes.json")
        nodes_json_path: path to the nodes.json.
        fmt: "csv" for the resolved (src,dst,latency,bw,loss) matrix preview, or
            "chaosmesh" for the NetworkChaos manifests.

    Returns:
        The compiled output, or an error string starting with "ERROR:".
    """
    try:
        topo = load_topology(_resolve_out(topology_yaml_path), _resolve_out(nodes_json_path))
        links = _compile(topo)
    except Exception as e:  # surfaced back to the model so it can self-correct
        return f"ERROR: {e}"

    if fmt == "chaosmesh":
        return _chaosmesh.dump(links)
    if fmt == "csv":
        return _csv.dump(links)
    return f"ERROR: unknown format '{fmt}' (use 'csv' or 'chaosmesh')"
