
'''
LangGraph nodes for the Arena orchestration workflow.

    START -> read_scenario --(missing info: ask user)--> END (graph pauses)
                |
                v (spec complete)
            generate_configs  (deterministic: spec -> nodes.json + topology.yaml)
                |
                v
            validate_configs --(error, retry<2)--> read_scenario
                |
                v (ok)
            launch_arena      (arena_testbed/0,1,2 — only if user asked to launch)
                |
                v
            generate_chaos    (tools/topology -> chaos.yaml; kubectl apply if asked)
                |
                v
            summarize -> END

Design rule: the LLM is used ONCE, in read_scenario, to extract a structured
ScenarioSpec. Every artifact (nodes.json, topology.yaml, chaos.yaml) is composed
by plain Python from that spec and checked by Arena's own loader — the model
never writes config text, so it cannot hallucinate fields.
'''

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path
from typing import Optional

import yaml
from dotenv import load_dotenv
from langchain.chat_models import init_chat_model
from ai_agent.system_prompts.system_prompt import EXTRACT_PROMPT
from langchain_core.messages import AIMessage, SystemMessage
from langgraph.graph import END, START, StateGraph

from ai_agent.configurations.setting import (
    DEFAULT_MODEL,
    max_retries,
    max_token,
    model_time_out,
    streaming,
    temperature,
)
from ai_agent.utils.states import ArenaWorkflowState, ScenarioSpec

from tools.topology.compiler import compile as compile_links
from tools.topology.emitters import chaosmesh
from tools.topology.schema import load_topology


# ---------------------------------------------------------------------------
# Paths (computed from this file so they don't depend on the cwd)
# ---------------------------------------------------------------------------

_PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent   # utils -> ai_agent -> root
OUT_DIR = _PROJECT_ROOT / "ai_agent" / "out"
TESTBED_DIR = _PROJECT_ROOT / "arena_testbed"

# API keys live in ai_agent/.env (gitignored); load them for standalone use too.
load_dotenv(_PROJECT_ROOT / "ai_agent" / ".env")

MAX_GENERATION_RETRIES = max_retries
# Launch = scripts 0/1/2 only. Cleaning is a SEPARATE node (clean_cluster):
# putting 3-clean here would tear the cluster down right after launching it.
LAUNCH_SCRIPTS = ["0-set_environments.sh", "1-launch_cluster.sh", "2-set_frameworks.sh"]
CLEAN_SCRIPT = "3-clean_cluster.sh"

_EXTRACT_PROMPT = EXTRACT_PROMPT

def _get_llm(model=None):
    """Build the extraction LLM lazily so importing this module needs no API key."""
    if model is not None and not isinstance(model, str):
        return model
    return init_chat_model(
        model or DEFAULT_MODEL,
        temperature=temperature,
        timeout=model_time_out,
        max_tokens=max_token,
        streaming=streaming,
        max_retries=max_retries,
    )


# ---------------------------------------------------------------------------
# Deterministic composition: ScenarioSpec -> config files
# ---------------------------------------------------------------------------

def _compose_nodes_json(spec: ScenarioSpec) -> dict:
    return {
        "cluster_name": spec.cluster_name,
        "hosts": [
            {
                "context": "default",
                "addr": "127.0.0.1",
                "ssh": "",
                "nodes": [
                    {"name": n.name, "tier": n.tier, "role": n.role,
                     "cpu": n.cpu, "memory": n.memory}
                    for n in spec.nodes
                ],
            }
        ],
    }


def _compose_topology_yaml(spec: ScenarioSpec) -> dict:
    # regions = lowercased tiers, members = worker nodes of that tier
    regions: dict = {}
    for n in spec.nodes:
        if n.role != "worker":
            continue
        regions.setdefault(n.tier.lower(), {"members": []})["members"].append(n.name)

    region_pairs = []
    for r in spec.rules:
        pair = {"from": r.from_region.lower(), "to": r.to_region.lower()}
        for key, val in (("latency", r.latency), ("bw", r.bw),
                         ("loss", r.loss), ("jitter", r.jitter)):
            if val:
                pair[key] = val
        if len(pair) > 2:            # at least one metric set
            region_pairs.append(pair)

    return {
        "version": "1",
        "symmetric": True,
        "regions": regions,
        "defaults": {
            "intra-region": {"latency": spec.default_intra_latency,
                             "bw": spec.default_intra_bw},
            "inter-region": {"latency": spec.default_inter_latency,
                             "bw": spec.default_inter_bw},
        },
        "region_pairs": region_pairs,
        "exceptions": [],
    }


def _tail(text: str, n: int = 1500) -> str:
    return text[-n:] if text and len(text) > n else (text or "")


# ---------------------------------------------------------------------------
# Workflow factory — nodes are closures so tests can inject a stub LLM
# ---------------------------------------------------------------------------

def build_workflow(model=None, checkpointer=None):
    """Compile the orchestration graph. `model` overrides the extraction LLM."""

    # -- 1. read the scenario, make sure of the information -----------------
    def read_scenario(state: ArenaWorkflowState) -> dict:
        llm = _get_llm(model)
        sys_prompt = _EXTRACT_PROMPT
        if state.get("validation_error"):
            sys_prompt += (
                "\nYour previous spec failed Arena validation with:\n"
                f"  {state['validation_error']}\n"
                "Fix the spec accordingly."
            )
        spec: ScenarioSpec = llm.with_structured_output(ScenarioSpec).invoke(
            [SystemMessage(sys_prompt)] + list(state["messages"])
        )
        if not spec.complete:
            q = spec.question or "Could you give more details about the nodes per tier?"
            return {"info_complete": False, "scenario": spec.model_dump(),
                    "messages": [AIMessage(content=q)]}
        return {"info_complete": True, "scenario": spec.model_dump()}

    def after_read(state: ArenaWorkflowState) -> str:
        return "generate_configs" if state.get("info_complete") else END

    # -- 2. generate nodes.json + topology.yaml (deterministic) -------------
    def generate_configs(state: ArenaWorkflowState) -> dict:
        spec = ScenarioSpec(**state["scenario"])
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        nodes_path = OUT_DIR / "nodes.json"
        topo_path = OUT_DIR / "topology.yaml"
        nodes_path.write_text(json.dumps(_compose_nodes_json(spec), indent=2))
        topo_path.write_text(yaml.safe_dump(_compose_topology_yaml(spec), sort_keys=False))
        return {"nodes_json_path": str(nodes_path), "topology_yaml_path": str(topo_path)}

    # -- 2b. validate with Arena's own loader --------------------------------
    def validate_configs(state: ArenaWorkflowState) -> dict:
        try:
            topo = load_topology(Path(state["topology_yaml_path"]),
                                 Path(state["nodes_json_path"]))
            cps = [n for n in topo.nodes.values() if n.role == "control-plane"]
            if len(cps) != 1:
                raise ValueError(f"exactly one control-plane required, found {len(cps)}")
            return {"validation_error": None}
        except Exception as e:
            return {"validation_error": str(e),
                    "generation_retries": state.get("generation_retries", 0) + 1}

    def after_validate(state: ArenaWorkflowState) -> str:
        if not state.get("validation_error"):
            return "launch_arena"
        if state.get("generation_retries", 0) <= MAX_GENERATION_RETRIES:
            return "read_scenario"
        return "summarize"

    # -- 3. launch arena with scripts 0, 1, 2 --------------------------------
    def launch_arena(state: ArenaWorkflowState) -> dict:
        spec = ScenarioSpec(**state["scenario"])
        if not spec.launch:
            return {"launch_ok": None,
                    "launch_log": "skipped (user did not ask to launch)"}

        # the launch scripts read arena_testbed/nodes.json
        shutil.copy(state["nodes_json_path"], TESTBED_DIR / "nodes.json")
        logs = []
        for script in LAUNCH_SCRIPTS:
            try:
                r = subprocess.run(
                    ["bash", script], cwd=TESTBED_DIR,
                    capture_output=True, text=True, timeout=1800,
                )
                logs.append(f"$ {script} (exit {r.returncode})\n{_tail(r.stdout + r.stderr)}")
                if r.returncode != 0:
                    return {"launch_ok": False, "launch_log": "\n\n".join(logs)}
            except Exception as e:                      # bash/docker missing, timeout…
                logs.append(f"$ {script} FAILED: {e}")
                return {"launch_ok": False, "launch_log": "\n\n".join(logs)}
        return {"launch_ok": True, "launch_log": "\n\n".join(logs)}

    # -- 4. generate chaos.yaml (and kubectl apply if asked) -----------------
    def generate_chaos(state: ArenaWorkflowState) -> dict:
        spec = ScenarioSpec(**state["scenario"])
        topo = load_topology(Path(state["topology_yaml_path"]),
                             Path(state["nodes_json_path"]))
        chaos_path = OUT_DIR / "chaos.yaml"
        chaos_path.write_text(chaosmesh.dump(compile_links(topo)))

        result = {"chaos_yaml_path": str(chaos_path)}
        if spec.apply_chaos and state.get("launch_ok"):
            try:
                r = subprocess.run(
                    ["kubectl", "apply", "-f", str(chaos_path)],
                    capture_output=True, text=True, timeout=120,
                )
                result["chaos_apply_ok"] = r.returncode == 0
                result["chaos_log"] = _tail(r.stdout + r.stderr)
            except Exception as e:
                result["chaos_apply_ok"] = False
                result["chaos_log"] = f"kubectl failed: {e}"
        else:
            result["chaos_apply_ok"] = None
            result["chaos_log"] = "skipped (not requested or cluster not launched)"
        return result

    # -- 5. clean / tear down the cluster (script 3, only when asked) ---------
    def clean_cluster(state: ArenaWorkflowState) -> dict:
        spec = ScenarioSpec(**state["scenario"])
        if not spec.clean:
            return {"clean_ok": None,
                    "clean_log": "skipped (user did not ask to clean)"}
        try:
            r = subprocess.run(
                ["bash", CLEAN_SCRIPT], cwd=TESTBED_DIR,
                capture_output=True, text=True, timeout=900,
            )
            return {"clean_ok": r.returncode == 0,
                    "clean_log": f"$ {CLEAN_SCRIPT} (exit {r.returncode})\n"
                                 f"{_tail(r.stdout + r.stderr)}"}
        except Exception as e:                       # bash missing, timeout…
            return {"clean_ok": False, "clean_log": f"$ {CLEAN_SCRIPT} FAILED: {e}"}

    # -- 5. summarize ---------------------------------------------------------
    def summarize(state: ArenaWorkflowState) -> dict:
        if state.get("validation_error"):
            text = (f"I could not produce a valid configuration after "
                    f"{state.get('generation_retries', 0)} attempts.\n"
                    f"Last error: {state['validation_error']}")
            return {"messages": [AIMessage(content=text)]}

        lines = ["Workflow finished.",
                 f"- nodes.json    : {state.get('nodes_json_path')}",
                 f"- topology.yaml : {state.get('topology_yaml_path')}",
                 f"- chaos.yaml    : {state.get('chaos_yaml_path')}"]
        if state.get("launch_ok") is True:
            lines.append("- arena launch  : OK (scripts 0/1/2 completed)")
        elif state.get("launch_ok") is False:
            lines.append(f"- arena launch  : FAILED\n{_tail(state.get('launch_log', ''), 600)}")
        else:
            lines.append("- arena launch  : skipped")
        if state.get("chaos_apply_ok") is True:
            lines.append("- kubectl apply : OK")
        elif state.get("chaos_apply_ok") is False:
            lines.append(f"- kubectl apply : FAILED\n{_tail(state.get('chaos_log', ''), 400)}")
        else:
            lines.append("- kubectl apply : skipped")
        if state.get("clean_ok") is True:
            lines.append("- cluster clean : OK")
        elif state.get("clean_ok") is False:
            lines.append(f"- cluster clean : FAILED\n{_tail(state.get('clean_log', ''), 400)}")
        else:
            lines.append("- cluster clean : skipped")
        return {"messages": [AIMessage(content="\n".join(lines))]}

    # -- graph wiring ---------------------------------------------------------
    g = StateGraph(ArenaWorkflowState)
    g.add_node("read_scenario", read_scenario)
    g.add_node("generate_configs", generate_configs)
    g.add_node("validate_configs", validate_configs)
    g.add_node("launch_arena", launch_arena)
    g.add_node("generate_chaos", generate_chaos)
    g.add_node("clean_cluster", clean_cluster)
    g.add_node("summarize", summarize)

    g.add_edge(START, "read_scenario")
    g.add_conditional_edges("read_scenario", after_read,
                            {"generate_configs": "generate_configs", END: END})
    g.add_edge("generate_configs", "validate_configs")
    g.add_conditional_edges("validate_configs", after_validate,
                            {"launch_arena": "launch_arena",
                             "read_scenario": "read_scenario",
                             "summarize": "summarize"})
    g.add_edge("launch_arena", "generate_chaos")
    g.add_edge("generate_chaos", "clean_cluster")
    g.add_edge("clean_cluster", "summarize")
    g.add_edge("summarize", END)

    return g.compile(checkpointer=checkpointer)


def make_workflow_graph():
    """Factory for `langgraph dev` (the runtime supplies persistence)."""
    return build_workflow(checkpointer=None)
