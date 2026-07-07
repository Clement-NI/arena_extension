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
    6. clean_cluster     tears the cluster down with 3-clean_cluster.sh
                         (only when the user explicitly asked to clean).
    7. summarize         final report appended to messages.
'''

from __future__ import annotations

from typing import List, Literal, NotRequired, Optional

from langgraph.graph import MessagesState, StateGraph
from pydantic import BaseModel, Field, model_validator
from typing_extensions import TypedDict


# ---------------------------------------------------------------------------
# Minimal scratch state (kept for experiments in Studio; the real workflow
# below uses ArenaWorkflowState).
# ---------------------------------------------------------------------------

class State(TypedDict):
    messages: list
    summary: NotRequired[str]


builder = StateGraph(State)


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


class TierGroup(BaseModel):
    """Many identical nodes declared as tier + count (preferred for big
    clusters — the model outputs 3 lines instead of enumerating 100 nodes;
    names are auto-generated as Tier-1..Tier-N by the workflow)."""

    tier: str = Field(description="Tier name, e.g. 'IoT', 'Edge', 'Cloud'")
    count: int = Field(ge=1, description="How many nodes of this tier")
    cpu: str = Field(default="2", description="CPU per node, e.g. '1'")
    memory: str = Field(default="4Gi", description="Memory per node, e.g. '2Gi'")


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

    nodes: List[NodeSpec] = Field(default_factory=list,
                                  description="Explicitly named nodes (small/irregular clusters only)")
    tier_groups: List[TierGroup] = Field(default_factory=list,
                                         description="PREFERRED for many similar nodes: tier + count "
                                                     "(names auto-generated Tier-1..Tier-N). Do not also "
                                                     "repeat these nodes in `nodes`.")
    control_plane: str = Field(default="",
                               description="Name of the control-plane node, e.g. 'Cloud-1'. "
                                           "Required with tier_groups; defaults to the first node.")
    rules: List[LinkRule] = Field(default_factory=list, description="Inter-region network rules the user asked for")
    default_intra_latency: str = Field(default="1ms", description="Default latency inside a region")
    default_intra_bw: str = Field(default="1Gbit")
    default_inter_latency: str = Field(default="20ms", description="Default latency between regions")
    default_inter_bw: str = Field(default="100Mbit")
    launch: bool = Field(default=False, description="True only if the user explicitly asked to launch/deploy the cluster")
    apply_chaos: bool = Field(default=False, description="True only if the user explicitly asked to apply the chaos with kubectl")
    clean: bool = Field(default=False, description="True only if the user explicitly asked to clean/tear down the cluster at the end")

    @model_validator(mode="after")
    def _complete_requires_nodes(self):
        """Weak models sometimes return complete=true with an empty node list
        (nodes has a default, so plain schema validation lets it through).
        Downgrade that to an incomplete spec with a clarifying question, so the
        workflow asks the user instead of generating an empty nodes.json and
        burning validation retries."""
        if self.complete and not self.nodes and not self.tier_groups:
            self.complete = False
            if not self.question:
                self.question = (
                    "I couldn't extract any nodes from your request. How many "
                    "nodes do you want per tier (IoT / Edge / Cloud), and which "
                    "node should be the control-plane?")
        return self

    def expanded_nodes(self) -> List[NodeSpec]:
        """Explicit nodes + tier_groups expanded to concrete NodeSpecs, with
        exactly one control-plane marked (by `control_plane` name, falling back
        to the first node when none matches)."""
        out = [n.model_copy() for n in self.nodes]
        for g in self.tier_groups:
            for i in range(1, g.count + 1):
                out.append(NodeSpec(name=f"{g.tier}-{i}", tier=g.tier,
                                    role="worker", cpu=g.cpu, memory=g.memory))
        if not any(n.role == "control-plane" for n in out) and out:
            cp = self.control_plane.strip().lower()
            target = next((n for n in out if n.name.lower() == cp), out[0])
            target.role = "control-plane"
        return out


class NextAction(BaseModel):
    """Classification of the user's answer after the summary."""

    action: Literal["clean", "continue", "done"] = Field(
        description="'clean' = tear the cluster down; 'continue' = the user wants "
                    "another operation (new/changed scenario); 'done' = nothing else")


# ---------------------------------------------------------------------------
# Graph state
# ---------------------------------------------------------------------------

class ArenaWorkflowState(MessagesState):
    """Carried across scenario -> configs -> launch -> chaos -> clean."""

    # step 1 — scenario understanding
    scenario: Optional[dict]            # ScenarioSpec.model_dump()
    info_complete: bool                 # False -> a question was asked, graph paused

    # step 2 — config generation
    nodes_json_path: Optional[str]
    topology_yaml_path: Optional[str]

    # step 2b — validation / retry loop
    validation_error: Optional[str]
    generation_retries: int

    # step 2c — publish validated config to arena_testbed/
    publish_log: Optional[str]

    # step 3 — arena launch (scripts 0, 1, 2)
    launch_ok: Optional[bool]
    launch_log: Optional[str]

    # step 4 — chaos
    chaos_yaml_path: Optional[str]
    chaos_apply_ok: Optional[bool]
    chaos_log: Optional[str]

    # step 5 — post-summary decision (clean / continue / done)
    next_action: Optional[str]

    # step 6 — cluster teardown (script 3)
    clean_ok: Optional[bool]
    clean_log: Optional[str]
