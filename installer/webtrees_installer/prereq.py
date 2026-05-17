"""Runtime prerequisite checks for the installer wizard."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from typing import IO


COMPOSE_VERSION_TIMEOUT_S = 10
NETWORK_INSPECT_TIMEOUT_S = 10


class PrereqError(RuntimeError):
    """Raised when a runtime prerequisite is not satisfied."""


def check_traefik_network(*, network: str) -> None:
    """Verify the Traefik docker network exists on this host.

    Renders compose.yaml with `networks: <name>: external: true`, so
    `docker compose up` only succeeds when the network already exists.
    Without this check, the wizard's `Stack ready ✓` banner lies: the
    rendered Traefik labels are inert without a router on that network,
    and the operator's browser sees a generic 404 (issue #131).

    Raises PrereqError when the network is missing or the daemon
    can't be reached. Container-existence is NOT verified here — the
    installer can't know whether the operator runs Traefik via compose,
    raw `docker run`, k3s, or systemd-managed binary; the warning
    surface is the post-install banner cross-reference.
    """
    try:
        subprocess.run(
            ["docker", "network", "inspect", network],
            capture_output=True,
            text=True,
            check=True,
            timeout=NETWORK_INSPECT_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired as exc:
        raise PrereqError(
            f"Docker daemon did not respond within {NETWORK_INSPECT_TIMEOUT_S}s "
            f"while inspecting network '{network}'."
        ) from exc
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or "").strip()
        raise PrereqError(
            f"Traefik network '{network}' does not exist on this host. "
            f"Either pass --traefik-network <real-name> for the network "
            f"your Traefik instance is on, or create it first: "
            f"`docker network create {network}` "
            f"(then start your Traefik container attached to it). "
            f"docker stderr: {stderr or '<empty>'}"
        ) from exc


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
    # Banner format observed on Compose 2.20–2.29; revisit when Compose 3
    # ships in case the leading "v" or the "v2" prefix changes.
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


def confirm_overwrite(
    *,
    work_dir: Path,
    interactive: bool,
    force: bool = False,
    stdin: IO[str] | None = None,
    stdout: IO[str] | None = None,
) -> bool:
    """Check /work for existing compose.yaml / .env and confirm overwrite.

    Returns True if the wizard may proceed with writing, False otherwise.
    Raises PrereqError in non-interactive mode when a conflict exists and
    --force was not passed.
    """
    conflicts = [
        name for name in ("compose.yaml", ".env") if (work_dir / name).exists()
    ]
    if not conflicts:
        return True
    if not interactive:
        if force:
            return True
        raise PrereqError(
            f"{', '.join(conflicts)} already exist in {work_dir}; "
            "pass --force to overwrite."
        )

    stdin = stdin or sys.stdin
    stdout = stdout or sys.stdout
    print(
        f"{', '.join(conflicts)} already exist in {work_dir}.",
        file=stdout,
    )
    print("Overwrite? [y/N] ", end="", file=stdout, flush=True)
    reply = stdin.readline().strip().lower()
    return reply in {"y", "yes"}
