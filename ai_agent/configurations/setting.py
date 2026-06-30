import os

# Optional: override the default model (provider-prefixed id).
#  anthropic:claude-opus-4-8   openai:gpt-4.1   openai:gpt-5
# ARENA_AGENT_MODEL=anthropic:claude-opus-4-8
DEFAULT_MODEL = "anthropic:claude-sonnet-4-6"

## Setting of the LLM
temperature = 0.5
model_time_out  = 600
max_token = 25000
streaming = True


