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
            publish_configs   (validated nodes.json -> arena_testbed/, via tool)
                |
                v
            launch_arena      (arena_testbed/0,1,2 — only if user asked to launch)
                |
                v
            generate_chaos    (tools/topology -> chaos.yaml; kubectl apply if asked)
                |
                v
            summarize         (report FIRST)
                |-- spec.clean was asked upfront --> clean_cluster -> report_final -> END
                v
            ask_next          (interrupt(): adjust the network / clean / done?)
                |-- "adjust"   -> dynamic_scenario -> ask_next   (loop until done)
                |-- "clean"    -> clean_cluster -> report_final -> END
                '-- "done"     -> END

            dynamic_scenario: runtime chaos adjustments on the LIVE cluster —
            "IoT-3 failed" (partition), "edge-1 to cloud-2 200ms" (link
            override), "iot <-> cloud 100ms" (region pair), "reset" (back to
            the initial network). The cluster itself never changes here; the
            dynamic layers are recompiled through the same tools and applied
            with diff-delete + kubectl apply --server-side.

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
import re
import subprocess
from pathlib import Path

from dotenv import load_dotenv
from langchain.chat_models import init_chat_model
from ai_agent.system_prompts.system_prompt import ADJUST_PROMPT, EXTRACT_PROMPT
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage
from langgraph.graph import END
from langgraph.types import interrupt

from ai_agent.configurations.setting import (
    DEFAULT_MODEL,
    generation_max_retries,
    max_retries,
    max_token,
    model_time_out,
    streaming,
    temperature,
)
from ai_agent.utils.states import (
    ArenaWorkflowState,
    DynamicScenario,
    NextAction,
    ScenarioSpec,
)

# The registered agent tools are the single generation/I-O layer for config
# artifacts: the chatbot's LLM calls them via function-calling, the workflow
# nodes call the same tools directly with .invoke().
from ai_agent.utils.agent_tools.correction_tool import validate_topology
from ai_agent.utils.agent_tools.generation_tool import (
    compile_topology,
    generate_config_files,
    patch_topology,
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

# validation-failure loops back to a fresh LLM extraction; keep this small —
# it is NOT the transport retry count (that's max_retries on the LLM call).
MAX_GENERATION_RETRIES = generation_max_retries


LAUNCH_SCRIPTS = ["0-set_environments.sh", "1-launch_cluster.sh", "2-set_frameworks.sh"]
CLEAN_SCRIPT = "3b-clean-multihost.sh"

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
    try:
        spec: ScenarioSpec = llm.with_structured_output(ScenarioSpec).invoke(
            [SystemMessage(sys_prompt)] + list(state["messages"])
        )
    except Exception as e:
        # Weak models sometimes emit unparseable output (YAML fences, comments,
        # "..." ellipses) instead of the structured object — don't crash the
        # graph, ask the user to restate compactly (tier counts parse best).
        msg = (
            "I couldn't parse the scenario from the model's answer "
            f"({type(e).__name__}: {str(e)[:150]}...).\n"
            "Please restate it compactly, e.g.: "
            "'IoT x34, Edge x33, Cloud x33, Cloud-1 is the control plane, "
            "30ms/100Mbit between edge and cloud'."
        )
        return {"info_complete": False, "messages": [AIMessage(content=msg)]}
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
    data = json.loads(Path(state["nodes_json_path"]).read_text(encoding="utf-8"))
    cps = [n for h in data.get("hosts", []) for n in h.get("nodes", [])
           if n.get("role") == "control-plane"]
    if len(cps) != 1:
        return {"validation_error": f"exactly one control-plane required, found {len(cps)}",
                "generation_retries": state.get("generation_retries", 0) + 1}
    return {"validation_error": None}


def after_validate(state: ArenaWorkflowState) -> str:
    # Routers must stay side-effect free (they are re-runnable and their work
    # is not checkpointed) — the actual write happens in publish_configs.
    if not state.get("validation_error"):
        return "publish_configs"
    if state.get("generation_retries", 0) <= MAX_GENERATION_RETRIES:
        return "read_scenario"
    return "summarize"


# ---------------------------------------------------------------------------
# 2c. publish the validated config to the testbed (via the registered tool)
# ---------------------------------------------------------------------------

def publish_configs(state: ArenaWorkflowState) -> dict:
    """Copy the validated nodes.json to arena_testbed/nodes.json.

    The launch scripts (1-launch_cluster.sh) read arena_testbed/nodes.json, so
    the validated config is published there through write_config_file — even
    when launch is skipped, the user can then run the scripts manually.
    """
    content = Path(state["nodes_json_path"]).read_text(encoding="utf-8")
    result = write_config_file.invoke({"path": str(TESTBED_DIR / "nodes.json"),
                                       "content": content})
    return {"publish_log": result}


# ---------------------------------------------------------------------------
# 3. launch arena with scripts 0, 1, 2
# ---------------------------------------------------------------------------

def launch_arena(state: ArenaWorkflowState) -> dict:
    spec = ScenarioSpec(**state["scenario"])
    if not spec.launch:
        return {"launch_ok": None,
                "launch_log": "skipped (user did not ask to launch)"}

    # arena_testbed/nodes.json was already published by publish_configs
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

    # remember the applied resource names so dynamic_scenario can diff-delete
    result = {"chaos_yaml_path": str(chaos_path),
              "chaos_resource_names": sorted(_chaos_names(chaos_text))}
    if spec.apply_chaos and state.get("launch_ok"):
        try:
            # All NetworkChaos resources live in the arena-net namespace (see
            # tools/topology/emitters/chaosmesh.CHAOS_NAMESPACE); nothing else
            # creates it in the workflow path, so ensure it exists first.

            subprocess.run(["kubectl", "create", "namespace", "arena-net"],
                               capture_output=True, text=True, timeout=60)
            # kubectl submits the resources one by one; big clusters emit
            # thousands (N workers -> N*(N-1) NetworkChaos), so scale the
            # timeout with the resource count instead of a fixed 120s.
            # --server-side is faster and avoids huge last-applied annotations.
            n_res = chaos_text.count("kind: NetworkChaos")
            apply_timeout = min(3600, 300 + n_res // 2)
            r = subprocess.run(
                ["kubectl", "apply", "--server-side", "-f", str(chaos_path)],
                capture_output=True, text=True, timeout=apply_timeout,
            )
            result["chaos_apply_ok"] = r.returncode == 0
            result["chaos_log"] = (f"[{n_res} NetworkChaos, timeout {apply_timeout}s] "
                                   f"{_tail(r.stdout + r.stderr)}")
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
             f"- chaos.yaml    : {state.get('chaos_yaml_path')}",
             f"- published to  : arena_testbed/nodes.json"
             f" ({state.get('publish_log') or 'not published'})"]
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
        "Anything else? You can describe a runtime event to adjust the injected "
        "network (e.g. 'IoT-3 failed', 'edge-1 to cloud-2 now 200ms', 'reset'), "
        "say 'clean' to tear the cluster down, or 'done' to finish."
    ))
    try:
        verdict: NextAction = _get_llm(model).with_structured_output(NextAction).invoke(
            [SystemMessage("Classify the user's reply after an Arena testbed run. "
                           "'clean' = tear the cluster down now; 'adjust' = they describe "
                           "a change to the network scenario (a node failed or recovered, "
                           "a link degraded, reset the network); 'done' = nothing else."),
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
            action = "adjust"

    out = {"next_action": action}
    if action == "adjust":
        # keep the event description in the conversation for dynamic_scenario
        out["messages"] = [HumanMessage(content=answer)]
    elif action == "done":
        out["messages"] = [AIMessage(content="OK — leaving everything as it is. Bye!")]
    return out


def after_ask(state: ArenaWorkflowState) -> str:
    return {"clean": "clean_cluster",
            "adjust": "dynamic_scenario",
            "done": END}[state.get("next_action") or "done"]


# ---------------------------------------------------------------------------
# 5c. dynamic scenario — adjust the injected network on the LIVE cluster,
#     looping back to ask_next until the user is done. The cluster itself
#     never changes here; only exceptions / region-pair overrides do.
# ---------------------------------------------------------------------------

def _chaos_names(chaos_text: str) -> set:
    """Resource names in a chaosmesh manifest (for diff-deleting on re-apply)."""
    return set(re.findall(r"^\s*name: (\S+)$", chaos_text, re.M))


def _chaos_docs(chaos_text: str) -> dict:
    """Split a multi-doc chaosmesh manifest into {resource_name: doc_text}."""
    docs = {}
    for chunk in re.split(r"^---\s*$", chaos_text, flags=re.M):
        if not chunk.strip():
            continue
        m = re.search(r"^\s*name: (\S+)$", chunk, re.M)
        if m:
            docs[m.group(1)] = chunk.strip()
    return docs


def _testbed_workers(state: ArenaWorkflowState) -> list:
    """Worker node names from the generated nodes.json (for fail_node expansion)."""
    data = json.loads(Path(state["nodes_json_path"]).read_text(encoding="utf-8"))
    return [n["name"] for h in data.get("hosts", []) for n in h.get("nodes", [])
            if n.get("role") == "worker"]


def _apply_patches(patches, exceptions: list, overrides: list, workers: list) -> str:
    """Fold ChaosPatch objects into the dynamic layers (pure function).
    Returns a short human-readable summary of what changed."""
    notes = []
    for p in patches:
        if p.action == "reset_all":
            exceptions.clear()
            overrides.clear()
            notes.append("reset to the initial network")
        elif p.action == "fail_node":
            exceptions[:] = [e for e in exceptions
                             if p.node not in (e.get("from"), e.get("to"))]
            exceptions.extend({"from": p.node, "to": w, "partition": "true",
                               "comment": "dynamic: node failure"}
                              for w in workers if w != p.node)
            notes.append(f"{p.node} partitioned from all nodes")
        elif p.action == "restore_node":
            before = len(exceptions)
            exceptions[:] = [e for e in exceptions
                             if p.node not in (e.get("from"), e.get("to"))]
            notes.append(f"{p.node} restored ({before - len(exceptions)} rules removed)")
        elif p.action == "set_link":
            exceptions[:] = [e for e in exceptions
                             if {e.get("from"), e.get("to")} != {p.src, p.dst}]
            entry = {"from": p.src, "to": p.dst, "comment": "dynamic: link override"}
            for k in ("latency", "bw", "loss", "jitter"):
                if getattr(p, k):
                    entry[k] = getattr(p, k)
            exceptions.append(entry)
            notes.append(f"link {p.src} <-> {p.dst} overridden")
        elif p.action == "set_region_pair":
            overrides[:] = [o for o in overrides
                            if {o.get("from"), o.get("to")} != {p.src.lower(), p.dst.lower()}]
            entry = {"from": p.src.lower(), "to": p.dst.lower()}
            for k in ("latency", "bw", "loss", "jitter"):
                if getattr(p, k):
                    entry[k] = getattr(p, k)
            overrides.append(entry)
            notes.append(f"region pair {p.src} <-> {p.dst} overridden")
    return "; ".join(notes)


def dynamic_scenario(state: ArenaWorkflowState, model=None) -> dict:
    event = next((m.content for m in reversed(state["messages"])
                  if getattr(m, "type", "") == "human"), "")
    workers = _testbed_workers(state)

    # 1. one small LLM call: sentence -> patches
    try:
        parsed: DynamicScenario = _get_llm(model).with_structured_output(DynamicScenario).invoke(
            [SystemMessage(ADJUST_PROMPT +
                           f"\nKnown worker nodes ({len(workers)}): "
                           f"{', '.join(workers[:40])}{'...' if len(workers) > 40 else ''}"),
             HumanMessage(event)]
        )
    except Exception as e:
        return {"messages": [AIMessage(content=
            f"I couldn't parse that adjustment ({type(e).__name__}). Try e.g. "
            "'IoT-3 failed' or 'edge-1 to cloud-2: 200ms, 5% loss'.")]}
    if not parsed.patches:
        q = parsed.question or ("Which node or link should change? E.g. "
                                "'IoT-3 failed' or 'iot <-> cloud now 100ms'.")
        return {"messages": [AIMessage(content=q)]}

    # 2. fold the patches into the dynamic layers (work on copies: only commit
    #    when validation passes)
    exceptions = list(state.get("active_exceptions") or [])
    overrides = list(state.get("region_overrides") or [])
    changed = _apply_patches(parsed.patches, exceptions, overrides, workers)

    # 3. rewrite topology.yaml, validate, recompile
    patch_topology.invoke({"topology_yaml_path": state["topology_yaml_path"],
                           "exceptions": exceptions, "region_pairs": overrides})
    verdict = validate_topology.invoke({"topology_yaml_path": state["topology_yaml_path"],
                                        "nodes_json_path": state["nodes_json_path"]})
    if not verdict.startswith("OK"):
        # roll the file back to the last committed dynamic layers
        patch_topology.invoke({"topology_yaml_path": state["topology_yaml_path"],
                               "exceptions": list(state.get("active_exceptions") or []),
                               "region_pairs": list(state.get("region_overrides") or [])})
        return {"messages": [AIMessage(content=f"That change is invalid: {verdict}\n"
                                               "Nothing was applied — please rephrase.")]}

    chaos_text = compile_topology.invoke({"topology_yaml_path": state["topology_yaml_path"],
                                          "nodes_json_path": state["nodes_json_path"],
                                          "fmt": "chaosmesh"})
    if chaos_text.startswith("ERROR:"):
        return {"messages": [AIMessage(content=f"Recompile failed: {chaos_text[:300]}")]}

    # 4. per-resource delta: only the rules whose content actually changed are
    #    sent to the cluster — NOT the whole manifest (at 100 nodes that would
    #    re-submit ~10k resources for a single-link tweak). Vanished resources
    #    (restore/reset) still need explicit deletion: apply never deletes.
    chaos_path = OUT_DIR / "chaos.yaml"
    old_docs = (_chaos_docs(chaos_path.read_text(encoding="utf-8"))
                if chaos_path.exists() else {})
    write_config_file.invoke({"path": str(chaos_path), "content": chaos_text})

    new_docs = _chaos_docs(chaos_text)
    delta = {name: doc for name, doc in new_docs.items()
             if old_docs.get(name) != doc}
    gone = sorted(set(old_docs) - set(new_docs))

    apply_note = "cluster not launched — rules written to chaos.yaml only"
    if state.get("launch_ok"):
        try:
            for i in range(0, len(gone), 200):
                subprocess.run(["kubectl", "delete", "networkchaos", "-n", "arena-net",
                                "--ignore-not-found", *gone[i:i + 200]],
                               capture_output=True, text=True, timeout=600)
            if delta:
                delta_path = OUT_DIR / "chaos-delta.yaml"
                delta_path.write_text("---\n" + "\n---\n".join(delta.values()) + "\n", encoding="utf-8")
                r = subprocess.run(
                    ["kubectl", "apply", "--server-side", "-f", str(delta_path)],
                    capture_output=True, text=True,
                    timeout=min(3600, 300 + len(delta) // 2))
                apply_note = (f"applied delta OK ({len(delta)} changed/new, "
                              f"{len(gone)} removed, {len(new_docs)} total)"
                              if r.returncode == 0 else
                              f"delta apply FAILED: {_tail(r.stdout + r.stderr, 300)}")
            else:
                apply_note = (f"no rule content changed "
                              f"({len(gone)} removed, {len(new_docs)} total)")
        except Exception as e:
            apply_note = f"kubectl failed: {e}"

    return {"active_exceptions": exceptions,
            "region_overrides": overrides,
            "chaos_resource_names": sorted(new_docs),
            "messages": [AIMessage(content=f"Adjustment done: {changed}.\n{apply_note}")]}


# ---------------------------------------------------------------------------
# 6. clean / tear down the cluster (script 3)
# ---------------------------------------------------------------------------
# Reached only when the user wants it: either spec.clean was set upfront,
# or they answered "clean" at the ask_next gate — so no extra gate here.

def _worker_hosts(state: ArenaWorkflowState) -> list:
    """Non-default docker contexts of the testbed — 3b-clean-multihost.sh
    takes them as arguments to also clean the remote machines. Prefer the
    scenario; fall back to the published arena_testbed/nodes.json."""
    try:
        spec = ScenarioSpec(**(state.get("scenario") or {}))
        workers = [h.context for h in spec.hosts if h.context != "default"]
        if workers:
            return workers
    except Exception:
        pass
    try:
        data = json.loads((TESTBED_DIR / "nodes.json").read_text(encoding="utf-8"))
        return [h.get("context") for h in data.get("hosts", [])
                if h.get("context") and h.get("context") != "default"]
    except Exception:
        return []


def clean_cluster(state: ArenaWorkflowState) -> dict:
    workers = _worker_hosts(state)
    cmd = ["bash", CLEAN_SCRIPT, *workers]
    try:
        r = subprocess.run(
            cmd, cwd=TESTBED_DIR,
            capture_output=True, text=True, timeout=900,
        )
        return {"clean_ok": r.returncode == 0,
                "clean_log": f"$ {' '.join(cmd)} (exit {r.returncode})\n"
                             f"{_tail(r.stdout + r.stderr)}"}
    except Exception as e:                       # bash missing, timeout…
        return {"clean_ok": False, "clean_log": f"$ {' '.join(cmd)} FAILED: {e}"}


# ---------------------------------------------------------------------------
# 6b. final report after cleaning
# ---------------------------------------------------------------------------

def report_final(state: ArenaWorkflowState) -> dict:
    if state.get("clean_ok") is True:
        text = "Cluster cleaned successfully (3b-clean-multihost.sh OK)."
    elif state.get("clean_ok") is False:
        text = f"Cluster clean FAILED:\n{_tail(state.get('clean_log', ''), 600)}"
    else:
        text = "Cluster clean skipped."
    return {"messages": [AIMessage(content=text)]}
