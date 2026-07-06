'''
State schema for the Arena orchestration workflow.

One state object is carried through the whole flow:

    1. read_scenario     LLM extracts a structured ScenarioSpec from the chat;
                         if information is missing it asks and the graph pauses.
    2. generate_configs  deterministic Python composes nodes.json + topology.yaml
                         from the spec (no LLM -> no hallucinated fields).
    3. validate_configs  Arena's own loader checks the pair; errors loop back.
    4. launch_arena      runs arena_testbed/0,1,2 scripts (only when requested).
    5. generate_chaos    compiles chaos.yaml with tools/topology and optionally
                         applies it with kubectl.
    6. summarize         final report appended to messages.
'''

from __future__ import annotations

from typing import List, Optional

from langgraph.graph import MessagesState
from pydantic import BaseModel, Field


# ---------------------------------------------------------------------------
# Structured spec the LLM must fill in step 1 (the ONLY LLM output we trust,
# and it is still validated by Arena's loader afterwards).
# ---------------------------------------------------------------------------

class NodeSpec(BaseModel):
    """One Kubernetes node of the testbed."""

    name: str = Field(description="Unique node name, e.g. 'IoT-1', 'Cloud-1'")
    tier: str = Field(description="Tier name, e.g. 'IoT', 'Edge', 'Cloud', 'Controller'")
    role: str = Field(default="worker", description="'worker' or 'control-plane' (exactly one node)")
    cpu: str = Field(default="2", description="CPU count as string, e.g. '4'")
    memory: str = Field(default="4Gi", description="Memory, e.g. '8Gi'")


class LinkRule(BaseModel):
    """Network rule between two regions (regions are lowercased tier names)."""

    from_region: str = Field(description="Source region, lowercased tier, e.g. 'edge'")
    to_region: str = Field(description="Destination region, e.g. 'cloud'")
    latency: str = Field(default="", description="One-way delay, e.g. '30ms' (empty = unset)")
    bw: str = Field(default="", description="Bandwidth, e.g. '100Mbit' (empty = unset)")
    loss: str = Field(default="", description="Packet loss %, e.g. '0.5' (empty = unset)")
    jitter: str = Field(default="", description="Delay variation, e.g. '5ms' (empty = unset)")


class ScenarioSpec(BaseModel):
    """Everything the workflow needs, extracted from the conversation."""

    complete: bool = Field(description="True only if enough information was given to build the cluster")
    question: str = Field(default="", description="If not complete: ONE concise clarifying question for the user")
    cluster_name: str = Field(default="arena-testbed")
    nodes: List[NodeSpec] = Field(default_factory=list, description="All nodes incl. exactly one control-plane")
    rules: List[LinkRule] = Field(default_factory=list, description="Inter-region network rules the user asked for")
    default_intra_latency: str = Field(default="1ms", description="Default latency inside a region")
    default_intra_bw: str = Field(default="1Gbit")
    default_inter_latency: str = Field(default="20ms", description="Default latency between regions")
    default_inter_bw: str = Field(default="100Mbit")
    launch: bool = Field(default=False, description="True only if the user explicitly asked to launch/deploy the cluster")
    apply_chaos: bool = Field(default=False, description="True only if the user explicitly asked to apply the chaos with kubectl")


# ---------------------------------------------------------------------------
# Graph state
# ---------------------------------------------------------------------------

class ArenaWorkflowState(MessagesState):
    """Carried across scenario -> configs -> launch -> chaos."""

    # step 1 — scenario understanding
    scenario: Optional[dict]            # ScenarioSpec.model_dump()
    info_complete: bool                 # False -> a question was asked, graph paused

    # step 2 — config generation
    nodes_json_path: Optional[str]
    topology_yaml_path: Optional[str]

    # step 2b — validation / retry loop
    validation_error: Optional[str]
    generation_retries: int

    # step 3 — arena launch (scripts 0, 1, 2)
    launch_ok: Optional[bool]
    launch_log: Optional[str]

    # step 4 — chaos
    chaos_yaml_path: Optional[str]
    chaos_apply_ok: Optional[bool]
    chaos_log: Optional[str]
