'''
Here is the enterance of my ai agent. We shall create(initiate) an agent here with any LLM that can be declared
And we start this to launch the dialogue

With create_agent, we can initialize an agent with a default LLM like openai 5.5. And we can add futhermore the
InMemory checkpoint, the system prompt, etc

Here we can allow user to fill in their preferred LLM

The middleware is also very important. We can add humain-in-the-loop here.

'''

from __future__ import annotations

import os
from typing import Optional, Union

from dotenv import load_dotenv
from langchain.agents import create_agent
from langchain.chat_models import init_chat_model

from ai_agent.system_prompts.system_prompt import SYSTEM_PROMPT
from ai_agent.utils.tools import ALL_TOOLS

# Load ai_agent/.env (API keys, ARENA_AGENT_MODEL, ...) into the environment.
load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))

# Default LLM. Override with the ARENA_AGENT_MODEL env var or by passing
# `model=...` to build_agent(). The string is a provider-prefixed model id
# understood by langchain's init_chat_model, e.g.:
#   "anthropic:claude-opus-4-8"   "openai:gpt-4.1"   "openai:gpt-5"
DEFAULT_MODEL = os.getenv("ARENA_AGENT_MODEL", "anthropic:claude-opus-4-8")


def build_agent(
    model: Optional[Union[str, object]] = None,
    *,
    checkpointer: Optional[object] = None,
    human_in_the_loop: bool = False,
):
    """Initialise the Arena AI agent.

    Args:
        model: a provider-prefixed model id (e.g. "anthropic:claude-opus-4-8")
            or an already-built LangChain chat model. Defaults to DEFAULT_MODEL.
        checkpointer: a LangGraph checkpointer for conversation memory. The CLI
            passes an InMemorySaver; leave None when running under `langgraph dev`
            (the platform supplies persistence) or for a stateless single call.
        human_in_the_loop: when True, pause for human approval before the agent
            writes any configuration file to disk.

    Returns:
        A compiled LangGraph agent. Drive it with `.invoke(...)` / `.stream(...)`.
    """
    model_id = model or DEFAULT_MODEL
    llm = init_chat_model(model_id) if isinstance(model_id, str) else model_id

    middleware = []
    if human_in_the_loop:
        # Imported lazily so the agent still builds on older langchain installs.
        from langchain.agents.middleware import HumanInTheLoopMiddleware

        middleware.append(
            HumanInTheLoopMiddleware(
                # Approve disk writes; read-only tools (validate/compile) run freely.
                interrupt_on={"write_config_file": True},
            )
        )

    return create_agent(
        model=llm,
        tools=ALL_TOOLS,
        system_prompt=SYSTEM_PROMPT,
        checkpointer=checkpointer,
        middleware=middleware,
    )


# A module-level instance so `langgraph dev` / langgraph.json can import a graph
# directly. The CLI builds its own agent with an InMemorySaver attached.
agent = build_agent()
