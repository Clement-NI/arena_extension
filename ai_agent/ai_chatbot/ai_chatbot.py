'''Here is the enterance of my ai agent. We shall create(initiate) an agent here with any LLM that can be declared
And we start this to launch the dialogue

With create_agent, we can initialize an agent with a default LLM like openai 5.5. And we can add futhermore the
InMemory checkpoint, the system prompt, etc

Here we can allow user to fill in their preferred LLM

The middleware is also very important. We can add humain-in-the-loop here.'''

from __future__ import annotations

import os
from typing import Optional, Union

from langchain.agents import create_agent
from langchain.chat_models import init_chat_model
from langchain.agents.middleware import HumanInTheLoopMiddleware

from ai_agent.system_prompts.system_prompt import SYSTEM_PROMPT
from ai_agent.utils.tools import ALL_TOOLS

from ai_agent.configurations.setting import DEFAULT_MODEL,temperature,streaming,model_time_out,max_token,max_retries
from langgraph.checkpoint.memory import InMemorySaver
from dotenv import load_dotenv

## load from the .env the environment variables.
## This module lives in ai_agent/ai_chatbot/, so the .env is one level up (ai_agent/.env).
load_dotenv(os.path.join(os.path.dirname(__file__), "..", ".env"))
## initialize and build the model with model.
def build_agent(
    model: Optional[Union[str, object]] = None,
    checkpointer: Optional[object] = InMemorySaver(),
    human_in_the_loop: bool = False,
):

    model_use = model or DEFAULT_MODEL
    if isinstance(model_use, str):
        llm = init_chat_model(
            model_use,
            temperature= temperature,
            timeout=model_time_out,
            max_tokens=max_token,
            streaming= streaming,
            max_retries=max_retries,
        )
    else:
        # Already a constructed chat model object — use it directly.
        llm = model_use

    middleware = []
    if human_in_the_loop:
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


