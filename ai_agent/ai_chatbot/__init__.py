"""ai_chatbot package.

Re-export build_agent so callers can do `from ai_agent.ai_chatbot import build_agent`
even though the implementation lives in the ai_chatbot.ai_chatbot submodule.
"""

from ai_agent.ai_chatbot.ai_chatbot import build_agent

__all__ = ["build_agent"]
