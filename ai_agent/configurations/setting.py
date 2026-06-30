import os

# Optional: override the default model (provider-prefixed id).
#  anthropic:claude-opus-4-8   openai:gpt-4.1   openai:gpt-5
#  anthropic:claude-opus-4-8 google_genai:gemini-3.5-flash
DEFAULT_MODEL = "google_genai:gemini-3.5-flash"

## Setting of the LLM
temperature = 0.5
model_time_out  = 600
max_token = 25000
streaming = True
max_retries = 10


