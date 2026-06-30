'''
This is cli for our ai agent.
Here we start the ai agent and interact with him using stream in a loop
In agent_body/ai_chatbot we've initialiez the agent
Here our main function will trigger it and make us enter the cli

We can add futhermore the UI with Streamlit Cloud etc
'''

from __future__ import annotations

import uuid

from langchain_core.messages import HumanMessage
from ai_agent.ai_chatbot import build_agent


def run() -> None:
    """Start an interactive REPL with the Arena agent.

    Conversation memory is kept in-process via an InMemorySaver keyed on a
    single thread id, so the agent remembers earlier turns within this session.
    """
    agent = build_agent()
    config = {"configurable": {"thread_id": str(uuid.uuid4())}}

    print("Arena AI agent ready. Describe a scenario, or type 'exit' to quit.\n")
    while True:
        try:
            user_input = input("you> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break

        if not user_input:
            continue
        if user_input.lower() in {"exit", "quit", "q"}:
            break

        # stream_mode="values" yields the full state after each step; we print
        # the latest message so tool calls and answers show up as they happen.
        for state in agent.stream(
            {"messages": [HumanMessage(content=user_input)]},
            config,
            stream_mode="values",
        ):
            state["messages"][-1].pretty_print()

    print("bye.")


def main() -> None:
    run()


if __name__ == "__main__":
    main()
