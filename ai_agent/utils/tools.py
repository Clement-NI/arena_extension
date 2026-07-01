'''
Here is the entrance of all of the tools for our ai agent.
We have now : correction_tool and generation_tool
'''

from ai_agent import write_config_file, compile_topology
from ai_agent import validate_topology

# The full tool belt handed to create_agent(). Order is informational only.
ALL_TOOLS = [
    write_config_file,   # generation: write nodes.json / topology.yaml to disk
    compile_topology,    # generation: nodes.json + topology.yaml -> NetworkChaos / matrix
    validate_topology,   # correction: validate and surface fixable errors
]
