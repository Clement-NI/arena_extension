import os

# Optional: override the default model (provider-prefixed id).
#  anthropic:claude-opus-4-8   openai:gpt-4.1   openai:gpt-5
#  google_genai:gemini-3.5-flash
#  ollama:gemma4:31b-cloud

DEFAULT_MODEL = "ollama:gemma4:31b-cloud"

## Setting of the LLM
temperature = 0.5
model_time_out  = 600
max_token = 25000
streaming = True
max_retries = 10          # transport-level retries of one LLM call (429s etc.)

## Setting of the workflow
# how many times a failed validation loops back to re-extraction before giving
# up — each loop is a fresh LLM call, so keep this small.
generation_max_retries = 3


