**Ai agent for Arena + 

This is our ai agent for Arena. This agent is added to improve the performance 
of Arena based on kind(multi-host version) and K8S cluster. 

It can take the prompt and generate the scenario in real world that we expect. Then 
it will generate the configuration files like .json and .yaml or other configuration files for the 
applications that run in pods. 

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

## More informations
You can go to the `arena_plus_user_manuel.md` to get more informations for ai agent of arena deployed and executed 
in Grid'5000.
