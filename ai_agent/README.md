**Ai agent for Arena + 

This is our ai agent for Arena. This agent is added to improve the performance 
of Arena based on kind(multi-host version) and K8S cluster. 

It can take the prompt and generate the scenario in real world that we expect. Then 
it will generate the configuration files like .json and .yaml or other configuration files for the 
applications that run in pods. 

The entrance is cli and the agent is initialized in `ai_chatbot.py`.

## Layout

| path | role |
|------|------|
| `ai_chatbot.py` | `build_agent()` — initializes the LangGraph agent (LLM + tools + system prompt + optional human-in-the-loop). |
| `cli/cli.py` | interactive REPL that streams the dialogue. |
| `system_prompts/system_prompt.py` | `SYSTEM_PROMPT` directing the model to generate `nodes.json` + `topology.yaml` via tools, not free-hand YAML. |
| `utils/tools.py` | `ALL_TOOLS` registry handed to the agent. |
| `utils/agent_tools/generation_tool.py` | `write_config_file`, `compile_topology` — write configs and run Arena's real `tools/topology` compiler. |
| `utils/agent_tools/correction_tool.py` | `validate_topology` — validate via Arena's loader, returning fixable path-style errors. |

The agent only **generates the two human inputs** (`nodes.json`, `topology.yaml`)
and then calls the existing `tools/topology` compiler to produce NetworkChaos /
probe manifests — it never hand-writes Chaos Mesh YAML, which avoids
hallucinated fields.

## Quick start

```bash
# from the repo root (so `tools.topology` and `ai_agent` are importable)
pip install -r ai_agent/requirements.txt

cp ai_agent/.env.example ai_agent/.env
# edit ai_agent/.env: set ANTHROPIC_API_KEY (or OPENAI_API_KEY) and,
# optionally, ARENA_AGENT_MODEL (default: anthropic:claude-opus-4-8)

python -m ai_agent.cli.cli
```

Pick a different LLM by setting `ARENA_AGENT_MODEL` (e.g. `openai:gpt-4.1`) or by
passing `build_agent(model="...")`. To require human approval before any file is
written, use `build_agent(human_in_the_loop=True)`.

