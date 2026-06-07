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


def run_docker(
    args: list[str],
    *,
    cwd: Path | None = None,
    check: bool = False,
    timeout: float | None = None,
    input: str | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run ``docker <args>`` and return the CompletedProcess.

    ``capture_output=True`` and text mode are always on so callers can
    echo stdout/stderr to the user as ``str``. The remaining behaviour is
    parameterised so every docker shell-out in the package routes through
    here instead of open-coding ``subprocess.run(["docker", …])``:

    ``cwd``      Directory to run in (``None`` = the current process cwd,
                 for daemon-scope commands like ``volume ls`` that need no
                 project dir).
    ``check``    ``True`` raises ``CalledProcessError`` on a non-zero exit;
                 the default ``False`` returns it so the caller can branch
                 on ``returncode`` + ``stderr``.
    ``timeout``  Seconds before a wedged daemon raises ``TimeoutExpired``.
    ``input``    String fed to the command's stdin (e.g. a secret piped
                 into a ``docker run -i`` helper).
    """
    return subprocess.run(
        ["docker", *args],
        cwd=cwd,
        capture_output=True,
        text=True,
        check=check,
        timeout=timeout,
        input=input,
    )
