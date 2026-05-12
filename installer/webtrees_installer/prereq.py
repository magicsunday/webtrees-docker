"""Runtime prerequisite checks for the installer wizard."""

from __future__ import annotations

import subprocess
from pathlib import Path


COMPOSE_VERSION_TIMEOUT_S = 10


class PrereqError(RuntimeError):
    """Raised when a runtime prerequisite is not satisfied."""


def check_prerequisites(
    *,
    work_dir: Path = Path("/work"),
    docker_sock: Path = Path("/var/run/docker.sock"),
) -> None:
    """Verify mounts and Compose v2 reachability. Raises PrereqError on failure."""
    if not work_dir.is_dir():
        raise PrereqError(
            f"{work_dir} is not mounted. Pass `-v \"$PWD:/work\"` to docker run."
        )
    if not docker_sock.exists():
        raise PrereqError(
            f"{docker_sock} is not bind-mounted. "
            "Pass `-v /var/run/docker.sock:/var/run/docker.sock` to docker run."
        )

    try:
        version = _compose_version()
    except subprocess.TimeoutExpired as exc:
        raise PrereqError(
            f"Docker daemon did not respond within {COMPOSE_VERSION_TIMEOUT_S}s. "
            "Confirm the socket points at a running engine and the daemon is not stuck."
        ) from exc
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or "").strip() or "<no stderr>"
        raise PrereqError(
            "Docker daemon is not reachable. Confirm the socket points at a "
            "running engine and the invoking user has permission "
            f"(stderr: {stderr})"
        ) from exc

    # `docker compose version` prints e.g. 'Docker Compose version v2.29.7'.
    # The legacy v1 standalone binary prints 'docker-compose version 1.x'
    # and `docker compose` would not exist at all in that environment, so
    # this rejects the v1 case along with any unexpected stranger format.
    if not version.startswith("Docker Compose version v2"):
        raise PrereqError(
            f"Compose v2 required. Got: {version!r}. Update Docker Engine "
            "to a version that ships the compose plugin."
        )


def _compose_version() -> str:
    """Return the trimmed stdout of `docker compose version`.

    Raises subprocess.CalledProcessError on non-zero exit (caller surfaces
    the daemon-unreachable hint) and subprocess.TimeoutExpired when the
    daemon hangs without responding (caller surfaces the timeout hint).
    """
    result = subprocess.run(
        ["docker", "compose", "version"],
        capture_output=True,
        text=True,
        check=True,
        timeout=COMPOSE_VERSION_TIMEOUT_S,
    )
    return result.stdout.strip()
