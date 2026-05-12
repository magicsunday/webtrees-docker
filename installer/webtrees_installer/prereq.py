"""Runtime prerequisite checks for the installer wizard."""

from __future__ import annotations

import subprocess
from pathlib import Path


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
    except subprocess.CalledProcessError as exc:
        raise PrereqError(
            "Docker daemon is not reachable. Confirm the socket points at a "
            "running engine and the invoking user has permission "
            f"(stderr: {exc.stderr!s})"
        ) from exc

    if "Docker Compose version v2" not in version and not version.startswith("v2"):
        # `docker compose version` prints e.g. 'Docker Compose version v2.29.7'.
        # The legacy v1 standalone binary prints 'docker-compose version 1.x'.
        raise PrereqError(
            f"Compose v2 required. Got: {version!r}. Update Docker Engine "
            "to a version that ships the compose plugin."
        )


def _compose_version() -> str:
    """Return `docker compose version --short` or raise CalledProcessError."""
    result = subprocess.run(
        ["docker", "compose", "version"],
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout.strip()
