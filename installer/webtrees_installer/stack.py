"""Bring the generated compose stack up and wait for nginx health."""

from __future__ import annotations

import subprocess
import time
from pathlib import Path


class StackError(RuntimeError):
    """Raised when `docker compose up` fails or nginx never reports healthy."""


def bring_up(
    *,
    work_dir: Path,
    timeout_s: float = 120.0,
    poll_interval_s: float = 2.0,
) -> None:
    """Run `docker compose up -d` and block until nginx is healthy."""
    up = _compose(["compose", "up", "-d"], cwd=work_dir)
    if up.returncode != 0:
        raise StackError(
            f"docker compose up failed: {up.stderr.strip() or up.stdout.strip()}"
        )

    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        inspect = _compose(
            [
                "compose", "ps", "--format",
                "{{.Health}}",
                "nginx",
            ],
            cwd=work_dir,
        )
        status = (inspect.stdout or "").strip().lower()
        if status == "healthy":
            return
        time.sleep(poll_interval_s)

    logs = _compose(["compose", "logs", "--tail=200"], cwd=work_dir)
    raise StackError(
        "nginx did not become healthy within "
        f"{timeout_s:.0f}s. Last logs:\n{logs.stdout}"
    )


def _compose(args: list[str], *, cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["docker", *args],
        cwd=cwd,
        capture_output=True,
        text=True,
        check=False,
    )
