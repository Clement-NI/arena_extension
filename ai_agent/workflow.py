'''
Graph assembly for the Arena orchestration workflow.

The node functions and routers live in ai_agent/utils/nodes.py; this module
only wires them into a StateGraph and compiles it. Entry points:

    build_workflow(model=None, checkpointer=None)
        Compile the graph. `model` overrides the extraction LLM (a provider-
        prefixed string or an already-built chat model / stub for tests);
        `checkpointer` enables pause/resume (interrupt) and multi-turn memory.

    make_workflow_graph()
        Factory used by `langgraph dev` (see ai_agent/langgraph.json) — the
        langgraph runtime supplies its own persistence, so no checkpointer.
'''

from __future__ import annotations

from functools import partial

from langgraph.graph import END, START, StateGraph

from ai_agent.utils.nodes import (
    after_ask,
    after_read,
    after_summarize,
    after_validate,
    ask_next,
    clean_cluster,
    generate_chaos,
    generate_configs,
    launch_arena,
    read_scenario,
    report_final,
    summarize,
    validate_configs,
)
from ai_agent.utils.states import ArenaWorkflowState


def build_workflow(model=None, checkpointer=None):
    """Compile the orchestration graph. `model` overrides the extraction LLM."""
    g = StateGraph(ArenaWorkflowState)

    # the two LLM-using nodes get the model injected; the rest are deterministic
    g.add_node("read_scenario", partial(read_scenario, model=model))
    g.add_node("generate_configs", generate_configs)
    g.add_node("validate_configs", validate_configs)
    g.add_node("launch_arena", launch_arena)
    g.add_node("generate_chaos", generate_chaos)
    g.add_node("summarize", summarize)
    g.add_node("ask_next", partial(ask_next, model=model))
    g.add_node("clean_cluster", clean_cluster)
    g.add_node("report_final", report_final)

    g.add_edge(START, "read_scenario")
    g.add_conditional_edges("read_scenario", after_read,
                            {"generate_configs": "generate_configs", END: END})
    g.add_edge("generate_configs", "validate_configs")
    g.add_conditional_edges("validate_configs", after_validate,
                            {"launch_arena": "launch_arena",
                             "read_scenario": "read_scenario",
                             "summarize": "summarize"})
    g.add_edge("launch_arena", "generate_chaos")
    g.add_edge("generate_chaos", "summarize")
    # summarize FIRST, then ask the user whether to clean / do something else
    g.add_conditional_edges("summarize", after_summarize,
                            {"clean_cluster": "clean_cluster",
                             "ask_next": "ask_next", END: END})
    g.add_conditional_edges("ask_next", after_ask,
                            {"clean_cluster": "clean_cluster",
                             "read_scenario": "read_scenario", END: END})
    g.add_edge("clean_cluster", "report_final")
    g.add_edge("report_final", END)

    return g.compile(checkpointer=checkpointer)


def make_workflow_graph():
    """Factory for `langgraph dev` (the runtime supplies persistence)."""
    return build_workflow(checkpointer=None)
