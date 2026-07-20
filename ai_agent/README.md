# Ai agent for Arena + 

This is our ai agent for Arena. This agent is added to improve the performance 
of Arena based on kind(multi-host version) and K8S cluster. 

It can take the prompt and generate the scenario in real world that we expect. Then 
it will generate the configuration files like .json and .yaml or other configuration files for the 
applications that run in pods. 

To make sure that you have put the api keys for `LangSmith` and for the LLM that you need in ai_agent/.env. 
Like "LANGSMITH_API_KEY= dhewuocihe0v"

## Layout

| path | role |
|------|------|
| `utils/tools.py` | `ALL_TOOLS` registry handed to the agent. |
| `utils/agent_tools/generation_tool.py` | `write_config_file`, `compile_topology` — write configs and run Arena's real `tools/topology` compiler. |
| `utils/agent_tools/correction_tool.py` | `validate_topology` — validate via Arena's loader, returning fixable path-style errors. |

The agent only **generates the two human inputs** (`nodes.json`, `topology.yaml`)
and then calls the existing `tools/topology` compiler to produce NetworkChaos /
probe manifests — it never hand-writes Chaos Mesh YAML, which avoids
hallucinated fields.

## Quick start

```bash
# install the necessary
pip install -r ai_agent/requirements.txt

langgraph dev
```

Pick a different LLM by setting `DEFAULT_MODEL` (e.g. `openai:gpt-4.1`) in configurations/setting.py

## Usage of AI Agent 
You can use AI agent to create a arena cluster (single or multi host) or to read the actual arena cluster deployed in the host. The prompt that you can input is in ai_agent/prompts. 

You can also change the chaos network configuration (modification of delay, bandwidth, loss or partition) when the agent ask you the next action to do (in the noeud of "ask_next"). You can also clean the cluster here or just end the process of ai agent.

For more informations, you can look up ai_agent/system_prompts.

## Design 
LangGraph nodes for the Arena orchestration workflow.

The graph itself is assembled in ai_agent/utils/workflow.py; this module only
holds the node functions and their routers:

    START -> route_entry --("existing")--> read_cluster --> ask_next
                |  (unclear: interrupt "new or existing?")      (adjust loop)
                v ("new")
            read_scenario --(missing info: ask user)--> END (graph pauses)
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

For more informations, please consult the official doc of LangGraph : 
`https://docs.langchain.com/oss/python/langgraph/overview`

## More informations
You can go to the `arena_plus_user_manuel.md` to get more informations for ai agent of arena deployed and executed 
in Grid'5000.
