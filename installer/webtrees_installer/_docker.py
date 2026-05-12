"""Shared docker-CLI invocation helper.

Both the stack-up flow (`stack.bring_up`) and the dev orchestrator
(`dev_flow.run_dev`) shell out to the docker CLI in the same shape:
return the CompletedProcess without raising on non-zero exit so the
caller can branch on returncode + stderr. Centralising the wrapper
keeps the failure-handling convention identical across flows and
collapses the next compose call site (Task 7's demo-tree import)
into a one-import change.
"""

from __future__ import annotations

import subprocess
from pathlib import Path


def run_docker(args: list[str], *, cwd: Path) -> subprocess.CompletedProcess[str]:
    """Run ``docker <args>`` in ``cwd`` and return the CompletedProcess.

    ``capture_output=True`` so callers can echo stderr to the user;
    ``check=False`` so a non-zero exit is a normal return value rather
    than a Python exception. Text mode so stdout/stderr are ``str``.
    """
    return subprocess.run(
        ["docker", *args],
        cwd=cwd,
        capture_output=True,
        text=True,
        check=False,
    )
