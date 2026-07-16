"""Convenience entry point so you can launch the agent by running this file
directly, e.g.  `python ai_agent/terminal.py`  — no `python -m` required.

The rest of the codebase uses absolute imports rooted at the project
directory (ai_agent.*, tools.*), which only resolve when the project root is
on sys.path. Running a script file only puts the script's own folder there, so
we add the project root explicitly before importing.
"""

import os
import sys

# ai_agent/terminal.py -> dirname = ai_agent/ -> dirname again = project root
_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

from cli.cli import run

def main():
    run()


if __name__ == '__main__':
    main()
