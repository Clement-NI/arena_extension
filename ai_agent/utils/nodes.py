'''
LangGraph nodes for the Arena orchestration workflow.

The graph itself is assembled in ai_agent/utils/workflow.py; this module only
holds the node functions and their routers:

    START -> read_scenario --(missing info: ask user)--> END (graph pauses)
                |
                v (spec complete)
            generate_configs  (deterministic: spec -> nodes.json + topology.yaml)
                |
                v
            validate_configs --(error, retry)--> read_scenario
                |
                v (ok)
            launch_arena      (arena_testbed/0,1,2 — only if user asked to launch)
                |
                v
            generate_chaos    (tools/topology -> chaos.yaml; kubectl apply if asked)
                |
                v
            summarize         (report FIRST)
                |-- spec.clean was asked upfront --> clean_cluster -> report_final -> END
                v
            ask_next          (interrupt(): "clean it, or something else?")
                |-- "clean"    -> clean_cluster -> report_final -> END
                |-- "continue" -> read_scenario  (answer becomes the next message)
                '-- "done"     -> END

Design rule: the LLM is used ONCE, in read_scenario, to extract a structured
ScenarioSpec — the model never writes config text, so it cannot hallucinate
fields. Everything after that goes through the SAME registered agent tools the
chatbot uses, invoked directly by the nodes with .invoke():
generate_config_files (spec -> nodes.json + topology.yaml), validate_topology,
compile_topology (+ write_config_file for chaos.yaml).

The two LLM-using nodes (read_scenario, ask_next) take an optional `model`
parameter; workflow.py binds it with functools.partial so tests can inject a
stub model.
'''

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

from dotenv import load_dotenv
from langchain.chat_models import init_chat_model
from ai_agent.system_prompts.system_prompt import EXTRACT_PROMPT
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage
from langgraph.graph import END
from langgraph.types import interrupt

from ai_agent.configurations.setting import (
    DEFAULT_MODEL,
    max_retries,
    max_token,
    model_time_out,
    streaming,
    temperature,
)
from ai_agent.utils.states import ArenaWorkflowState, NextAction, ScenarioSpec

# The registered agent tools are the single generation/I-O layer for config
# artifacts: the chatbot's LLM calls them via function-calling, the workflow
# nodes call the same tools directly with .invoke().
from ai_agent.utils.agent_tools.correction_tool import validate_topology
from ai_agent.utils.agent_tools.generation_tool import (
    compile_topology,
    generate_config_files,
    write_config_file,
)


# ---------------------------------------------------------------------------
# Paths (computed from this file so they don't depend on the cwd)
# ---------------------------------------------------------------------------

_PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent   # utils -> ai_agent -> root
OUT_DIR = _PROJECT_ROOT / "ai_agent" / "out"
TESTBED_DIR = _PROJECT_ROOT / "arena_testbed"

# API keys live in ai_agent/.env (gitignored); load them for standalone use too.
load_dotenv(_PROJECT_ROOT / "ai_agent" / ".env")

MAX_GENERATION_RETRIES = max_retries


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



def _tail(text: str, n: int = 1500) -> str:
    return text[-n:] if text and len(text) > n else (text or "")


# ---------------------------------------------------------------------------
# 1. read the scenario, make sure of the information
# ---------------------------------------------------------------------------

def read_scenario(state: ArenaWorkflowState, model=None) -> dict:
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


# ---------------------------------------------------------------------------
# 2. generate nodes.json + topology.yaml (deterministic)
# ---------------------------------------------------------------------------

def generate_configs(state: ArenaWorkflowState) -> dict:
    nodes_path = OUT_DIR / "nodes.json"
    topo_path = OUT_DIR / "topology.yaml"
    # the registered generation tool owns the whole spec -> files step
    generate_config_files.invoke({"scenario": state["scenario"],
                                  "nodes_json_path": str(nodes_path),
                                  "topology_yaml_path": str(topo_path)})
    return {"nodes_json_path": str(nodes_path), "topology_yaml_path": str(topo_path)}


# ---------------------------------------------------------------------------
# 2b. validate with Arena's own loader
# ---------------------------------------------------------------------------

def validate_configs(state: ArenaWorkflowState) -> dict:
    verdict = validate_topology.invoke({
        "topology_yaml_path": state["topology_yaml_path"],
        "nodes_json_path": state["nodes_json_path"],
    })
    if not verdict.startswith("OK"):
        return {"validation_error": verdict,
                "generation_retries": state.get("generation_retries", 0) + 1}

    # extra guard the tool doesn't cover: exactly one control-plane node
    data = json.loads(Path(state["nodes_json_path"]).read_text())
    cps = [n for h in data.get("hosts", []) for n in h.get("nodes", [])
           if n.get("role") == "control-plane"]
    if len(cps) != 1:
        return {"validation_error": f"exactly one control-plane required, found {len(cps)}",
                "generation_retries": state.get("generation_retries", 0) + 1}
    return {"validation_error": None}


def after_validate(state: ArenaWorkflowState) -> str:
    if not state.get("validation_error"):
        # write_config_file.invoke()
        return "launch_arena"
    if state.get("generation_retries", 0) <= MAX_GENERATION_RETRIES:
        return "read_scenario"
    return "summarize"


# ---------------------------------------------------------------------------
# 3. launch arena with scripts 0, 1, 2
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# 4. generate chaos.yaml (and kubectl apply if asked)
# ---------------------------------------------------------------------------

def generate_chaos(state: ArenaWorkflowState) -> dict:
    spec = ScenarioSpec(**state["scenario"])
    chaos_text = compile_topology.invoke({
        "topology_yaml_path": state["topology_yaml_path"],
        "nodes_json_path": state["nodes_json_path"],
        "fmt": "chaosmesh",
    })
    if chaos_text.startswith("ERROR:"):
        return {"chaos_yaml_path": None, "chaos_apply_ok": False,
                "chaos_log": chaos_text}
    chaos_path = OUT_DIR / "chaos.yaml"
    write_config_file.invoke({"path": str(chaos_path), "content": chaos_text})

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


# ---------------------------------------------------------------------------
# 5. summarize (report FIRST, before deciding on teardown)
# ---------------------------------------------------------------------------

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
    return {"messages": [AIMessage(content="\n".join(lines))]}


def after_summarize(state: ArenaWorkflowState) -> str:
    if state.get("validation_error"):
        return END                       # failure already reported
    spec = ScenarioSpec(**state["scenario"])
    if spec.clean:
        return "clean_cluster"           # user asked upfront — no need to ask
    return "ask_next"


# ---------------------------------------------------------------------------
# 5b. pause and ask the user what to do next
# ---------------------------------------------------------------------------

def ask_next(state: ArenaWorkflowState, model=None) -> dict:
    answer = str(interrupt(
        "The workflow finished (summary above). Should I clean the cluster "
        "(tear it down), or would you like to do something else?"
    ))
    try:
        verdict: NextAction = _get_llm(model).with_structured_output(NextAction).invoke(
            [SystemMessage("Classify the user's reply after an Arena testbed run. "
                           "'clean' = tear the cluster down now; 'continue' = they want "
                           "another operation or a changed scenario; 'done' = nothing else."),
             HumanMessage(answer)]
        )
        action = verdict.action
    except Exception:                    # weak model / no key: keyword fallback
        low = answer.lower()
        if any(k in low for k in ("clean", "tear", "delete", "清", "删")):
            action = "clean"
        elif any(k in low for k in ("no", "done", "nothing", "stop", "不用", "没有")):
            action = "done"
        else:
            action = "continue"

    out = {"next_action": action}
    if action == "continue":
        # feed the answer back into the conversation so read_scenario sees it
        out["messages"] = [HumanMessage(content=answer)]
    elif action == "done":
        out["messages"] = [AIMessage(content="OK — leaving everything as it is. Bye!")]
    return out


def after_ask(state: ArenaWorkflowState) -> str:
    return {"clean": "clean_cluster",
            "continue": "read_scenario",
            "done": END}[state.get("next_action") or "done"]


# ---------------------------------------------------------------------------
# 6. clean / tear down the cluster (script 3)
# ---------------------------------------------------------------------------
# Reached only when the user wants it: either spec.clean was set upfront,
# or they answered "clean" at the ask_next gate — so no extra gate here.

def clean_cluster(state: ArenaWorkflowState) -> dict:
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


# ---------------------------------------------------------------------------
# 6b. final report after cleaning
# ---------------------------------------------------------------------------

def report_final(state: ArenaWorkflowState) -> dict:
    if state.get("clean_ok") is True:
        text = "Cluster cleaned successfully (3-clean_cluster.sh OK)."
    elif state.get("clean_ok") is False:
        text = f"Cluster clean FAILED:\n{_tail(state.get('clean_log', ''), 600)}"
    else:
        text = "Cluster clean skipped."
    return {"messages": [AIMessage(content=text)]}
