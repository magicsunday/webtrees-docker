"""Bring the generated compose stack up and wait for nginx health."""

from __future__ import annotations

import time
from pathlib import Path

# Test-patch seam kept as a thin alias so existing test patches on
# ``webtrees_installer.stack._compose`` keep working. New call sites
# import `run_docker` from `webtrees_installer._docker` directly.
from webtrees_installer._docker import run_docker as _compose
from webtrees_installer._progress import ProgressReporter


class StackError(RuntimeError):
    """Raised when `docker compose up` fails or nginx never reports healthy."""


def bring_up(
    *,
    work_dir: Path,
    timeout_s: float = 120.0,
    poll_interval_s: float = 2.0,
    progress: ProgressReporter | None = None,
) -> None:
    """Run `docker compose up -d` and block until nginx is healthy.

    Polls ``docker compose ps --format {{.Health}} nginx`` every
    ``poll_interval_s`` seconds. The first poll is preceded by a sleep so
    the container has time to register a health state instead of the
    guaranteed-empty first read.

    When ``progress`` is provided, ``ProgressReporter.tick()`` is called
    on every poll iteration so the operator sees periodic "Ns elapsed"
    output during the health-wait. The reporter's heartbeat throttle
    governs how often a line actually prints.

    Raises:
        StackError: when ``docker compose up -d`` fails (with the stderr/
            stdout blob) or when nginx is still not healthy after
            ``timeout_s`` seconds (with the ``compose logs --tail=200``
            output appended for diagnosis).
    """
    up = _compose(["compose", "up", "-d"], cwd=work_dir)
    if up.returncode != 0:
        raise StackError(
            f"docker compose up failed: {up.stderr.strip() or up.stdout.strip()}"
        )

    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        # tick() first so the heartbeat throttle observes accumulated
        # stage age, not the post-sleep wall. With defaults
        # (poll_interval_s=2, ProgressReporter heartbeat_s=5) the first
        # visible elapsed line lands at iteration ⌈5/2⌉+1 ≈ 4 s into
        # the stage — well inside the issue's 10 s acceptance floor
        # regardless of how slow `compose ps` is on a cold daemon.
        if progress is not None:
            progress.tick()
        time.sleep(poll_interval_s)
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

    logs = _compose(["compose", "logs", "--tail=200"], cwd=work_dir)
    tail = logs.stdout.strip() or logs.stderr.strip() or "(no output)"
    raise StackError(
        "nginx did not become healthy within "
        f"{timeout_s:.0f}s. Last logs:\n{tail}"
    )


