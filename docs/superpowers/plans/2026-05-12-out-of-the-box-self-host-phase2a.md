# Out-of-the-Box Self-Host Phase 2a — Installer-Image + Standalone-Wizard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a containerised Python wizard (`webtrees-installer`) that asks a self-hoster a handful of questions and emits a working `compose.yaml` + `.env` for the standalone-or-Traefik Core/Full edition, optionally bringing the stack up.

**Architecture:** Single Python package `webtrees_installer/` baked into an Alpine + Python 3.12 image, distributed via GHCR. Entry point is `python -m webtrees_installer`. Compose layouts are Jinja2 templates rendered against a typed input model. Stack interactions (port-check, compose up, healthcheck wait) go through `subprocess` and `docker` CLI calls — no Docker SDK dependency. Non-interactive mode mirrors every prompt as a `--flag` for CI consumption.

**Tech Stack:** Python 3.12, Jinja2 (templating), pytest (tests), argparse (CLI), `python:3.12-alpine` (image base), Docker CLI + Docker Compose v2 (orchestration).

**Out of scope for 2a:** Dev-flow migration (replaces `scripts/setup.sh` + `make enable-dev-mode/disable-dev-mode/dev-mode-status` — Phase 2b), demo-tree generator (Phase 2b), admin-bootstrap E2E test (Phase 2b once dev-flow stabilises).

---

## File map

**New files:**
- `install` — Bash one-liner wrapper at repo root (`curl|bash`-able).
- `dev/installer-version.json` — Single-source-of-truth tag manifest, mirrors `dev/nginx-version.json`.
- `installer/Dockerfile` — Alpine + Python 3.12 + package install.
- `installer/pyproject.toml` — Project metadata, dependency on Jinja2, pytest dev-dep, console-script entry.
- `installer/webtrees_installer/__init__.py` — Package marker, version export.
- `installer/webtrees_installer/__main__.py` — `python -m webtrees_installer` entry → `cli.main()`.
- `installer/webtrees_installer/cli.py` — argparse wiring, `--non-interactive` flag matrix.
- `installer/webtrees_installer/versions.py` — Loads `versions.json`/`nginx-version.json`/`installer-version.json` (baked into image at `/usr/local/share/webtrees-installer/`).
- `installer/webtrees_installer/prereq.py` — Docker socket / `/work` / Compose-v2 sanity checks with actionable error messages.
- `installer/webtrees_installer/prompts.py` — Text / choice / yesno prompt helpers with `--non-interactive` short-circuit.
- `installer/webtrees_installer/ports.py` — Live port-conflict check via short-lived Alpine container.
- `installer/webtrees_installer/render.py` — Loads Jinja env, renders templates to strings, writes to `/work` atomically.
- `installer/webtrees_installer/secrets.py` — `openssl rand`-equivalent (Python `secrets` module), admin-password generation + post-run reveal.
- `installer/webtrees_installer/stack.py` — `docker compose up -d` + healthcheck wait.
- `installer/webtrees_installer/flow.py` — Standalone-flow orchestrator (prereq → choice → prompt → write → up).
- `installer/webtrees_installer/templates/compose.standalone.j2` — Compose with `ports:` on nginx.
- `installer/webtrees_installer/templates/compose.traefik.j2` — Compose with Traefik labels on nginx.
- `installer/webtrees_installer/templates/env.j2` — `.env` with `WEBTREES_VERSION`, `COMPOSE_PROJECT_NAME`, optional admin / port vars.
- `installer/tests/__init__.py`
- `installer/tests/conftest.py` — Shared fixtures: tmp `/work` dir, fake CLI-runner.
- `installer/tests/test_cli.py`
- `installer/tests/test_versions.py`
- `installer/tests/test_prompts.py`
- `installer/tests/test_render.py`
- `installer/tests/test_secrets.py`

**Modified files:**
- `.github/workflows/build.yml` — Adds `build-installer` job + reworks `smoke-test` to invoke the installer image instead of inlining `.env`.
- `compose.yaml` — Untouched.

---

## Conventions for this plan

- Run all installer-related commands inside the buildbox or a one-shot Docker container. The host has **no Python interpreter** ([NAS Hardware] memory).
- Tests run via `docker run --rm -v "$PWD/installer:/installer" -w /installer python:3.12-alpine sh -c "pip install -e .[test] && pytest -v"`. The plan provides a `installer/Makefile` later for ergonomics, but the bare `docker run` is the source of truth.
- Commit messages use a capitalised verb, no `feat:`/`fix:` prefix, no `Co-Authored-By` ([Commit message style], [No Co-Authored-By]).
- After each task: run the test suite, run a code-reviewer agent on the diff, commit ([Commit per finished task], [Review per finished task]).
- Use `git -C /volume2/docker/webtrees` for all git operations; bash cwd does not persist across Bash invocations ([pwd before every git]).

---

## Task 1: Installer image skeleton + bash wrapper + version manifest

**Files:**
- Create: `installer/pyproject.toml`
- Create: `installer/webtrees_installer/__init__.py`
- Create: `installer/webtrees_installer/__main__.py`
- Create: `installer/webtrees_installer/cli.py`
- Create: `installer/Dockerfile`
- Create: `installer/tests/__init__.py`
- Create: `installer/tests/conftest.py`
- Create: `installer/tests/test_cli.py`
- Create: `dev/installer-version.json`
- Create: `install` (repo root)

### Goal

Buildable installer image with a stub CLI that prints its version when invoked. Establishes the testing infrastructure, the Docker-Hub-style invocation, and the bash wrapper for `curl|bash`.

### Steps

- [ ] **Step 1.1: Create `installer/pyproject.toml`**

```toml
[build-system]
requires = ["setuptools>=68"]
build-backend = "setuptools.build_meta"

[project]
name = "webtrees-installer"
version = "0.1.0"
description = "Out-of-the-box installer wizard for self-hosted webtrees"
readme = "README.md"
requires-python = ">=3.12"
license = { text = "MIT" }
dependencies = [
    "Jinja2>=3.1,<4",
]

[project.optional-dependencies]
test = [
    "pytest>=8.0",
    "pytest-cov>=5.0",
]

[project.scripts]
webtrees-installer = "webtrees_installer.cli:main"

[tool.setuptools.packages.find]
include = ["webtrees_installer*"]

[tool.setuptools.package-data]
webtrees_installer = ["templates/*.j2"]

[tool.pytest.ini_options]
testpaths = ["tests"]
addopts = "-ra"
```

Also stub a one-line README:

```bash
echo "Webtrees self-host installer. See repo root README.md." > installer/README.md
```

- [ ] **Step 1.2: Create the package marker**

`installer/webtrees_installer/__init__.py`:

```python
"""Webtrees self-host installer."""

__version__ = "0.1.0"
```

- [ ] **Step 1.3: Create the entry point**

`installer/webtrees_installer/__main__.py`:

```python
"""Allow `python -m webtrees_installer` invocation."""

from webtrees_installer.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 1.4: Write the failing test for `--version`**

`installer/tests/test_cli.py`:

```python
"""CLI smoke tests."""

from webtrees_installer import __version__
from webtrees_installer.cli import main


def test_version_flag_prints_version(capsys):
    """--version prints the package version and exits 0."""
    exit_code = main(["--version"])
    captured = capsys.readouterr()

    assert exit_code == 0
    assert __version__ in captured.out
```

`installer/tests/__init__.py`:

```python
```

`installer/tests/conftest.py`:

```python
"""Shared pytest fixtures."""
```

- [ ] **Step 1.5: Run the test, confirm it fails**

```bash
docker run --rm -v "$PWD/installer:/installer" -w /installer python:3.12-alpine \
    sh -c "pip install -e .[test] >/dev/null && pytest tests/test_cli.py -v"
```

Expected: ImportError / ModuleNotFoundError on `webtrees_installer.cli` (cli.py does not yet exist).

- [ ] **Step 1.6: Implement the minimal CLI**

`installer/webtrees_installer/cli.py`:

```python
"""Command-line entry point for webtrees-installer."""

from __future__ import annotations

import argparse
from typing import Sequence

from webtrees_installer import __version__


def build_parser() -> argparse.ArgumentParser:
    """Return the top-level argument parser."""
    parser = argparse.ArgumentParser(
        prog="webtrees-installer",
        description="Wizard for setting up a self-hosted webtrees stack.",
    )
    parser.add_argument(
        "--version",
        action="version",
        version=f"webtrees-installer {__version__}",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """CLI entry point. Returns the process exit code."""
    parser = build_parser()
    parser.parse_args(argv)
    return 0
```

- [ ] **Step 1.7: Re-run the test, confirm it passes**

```bash
docker run --rm -v "$PWD/installer:/installer" -w /installer python:3.12-alpine \
    sh -c "pip install -e .[test] >/dev/null && pytest tests/test_cli.py -v"
```

Expected: `test_version_flag_prints_version PASSED`.

- [ ] **Step 1.8: Create the installer Dockerfile**

`installer/Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1.7

FROM python:3.12-alpine AS installer

LABEL org.opencontainers.image.source="https://github.com/magicsunday/webtrees-docker"
LABEL org.opencontainers.image.description="Wizard for setting up a self-hosted webtrees stack"
LABEL org.opencontainers.image.licenses="MIT"

# docker CLI client is required so the wizard can invoke `docker compose up`
# and port-conflict probes from inside the container. docker-compose-plugin
# pulls the v2 plugin alongside the static CLI.
RUN apk add --no-cache docker-cli docker-cli-compose

WORKDIR /opt/installer

COPY pyproject.toml README.md ./
COPY webtrees_installer ./webtrees_installer

RUN pip install --no-cache-dir .

# Mount points the wizard expects at runtime. /work is the user's host
# directory where compose.yaml + .env get written; /var/run/docker.sock is
# the daemon endpoint the embedded docker CLI talks to.
VOLUME ["/work"]
WORKDIR /work

ENTRYPOINT ["python", "-m", "webtrees_installer"]
```

- [ ] **Step 1.9: Create `dev/installer-version.json`**

`dev/installer-version.json`:

```json
{
    "version": "0.1.0",
    "tag": "0.1.0"
}
```

The `version` field is parsed by the build job; `tag` is what becomes the image tag (`ghcr.io/magicsunday/webtrees/installer:0.1.0`).

- [ ] **Step 1.10: Create the bash wrapper `install`**

`install` (mode 0755):

```bash
#!/usr/bin/env bash
# Webtrees self-host installer launcher.
#
# Usage: curl -fsSL https://raw.githubusercontent.com/magicsunday/webtrees-docker/main/install | bash
#
# Mounts the current directory as /work inside the installer image and exposes
# the docker socket so the wizard can probe ports and bring the stack up.

set -o errexit -o nounset -o pipefail

INSTALLER_IMAGE="${INSTALLER_IMAGE:-ghcr.io/magicsunday/webtrees/installer:latest}"

if ! command -v docker >/dev/null 2>&1; then
    echo "docker is not on PATH. Install Docker Engine first: https://docs.docker.com/engine/install/" >&2
    exit 1
fi

exec docker run --rm -it \
    -v "$PWD:/work" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    "$INSTALLER_IMAGE" "$@"
```

```bash
chmod +x install
```

- [ ] **Step 1.11: Build the image locally to verify the Dockerfile**

```bash
docker build -t webtrees-installer:local installer
docker run --rm webtrees-installer:local --version
```

Expected: `webtrees-installer 0.1.0`.

Then drop the local tag:

```bash
docker rmi webtrees-installer:local
```

- [ ] **Step 1.12: Commit**

```bash
git -C /volume2/docker/webtrees add \
    installer/ \
    dev/installer-version.json \
    install
git -C /volume2/docker/webtrees commit -m "$(cat <<'EOF'
Add webtrees-installer image skeleton

Introduce installer/ as a self-contained Python package with a Jinja2
runtime dependency, packaged into an Alpine + Python 3.12 image and
fronted by a bash wrapper that mounts the CWD and docker socket. The
CLI currently only honours --version; subsequent tasks layer on
prerequisite checks, prompts, template rendering, and the standalone
flow.
EOF
)"
```

### Acceptance criteria

- `docker build -t test installer/ && docker run --rm test --version` prints `webtrees-installer 0.1.0`.
- `pytest installer/tests/test_cli.py -v` reports one pass.
- The `install` wrapper is executable and references `ghcr.io/magicsunday/webtrees/installer:latest`.

---

## Task 2: Versions loader

**Files:**
- Modify: `installer/Dockerfile` (bake the version manifests into the image)
- Create: `installer/webtrees_installer/versions.py`
- Create: `installer/tests/test_versions.py`

### Goal

`versions.load_catalog()` returns the bundled image catalog (`versions.json` + `nginx-version.json` + `installer-version.json`) so the wizard can pick the right tags without runtime network calls.

### Steps

- [ ] **Step 2.1: Write the failing test**

`installer/tests/test_versions.py`:

```python
"""Tests for the versions loader."""

import json
from pathlib import Path

import pytest

from webtrees_installer.versions import Catalog, load_catalog


def test_load_catalog_reads_all_three_manifests(tmp_path: Path) -> None:
    """load_catalog() merges the three manifest files into a Catalog object."""
    (tmp_path / "versions.json").write_text(json.dumps([
        {"webtrees": "2.2.6", "php": "8.5", "tags": ["latest"]},
        {"webtrees": "2.2.6", "php": "8.4"},
    ]))
    (tmp_path / "nginx-version.json").write_text(json.dumps({
        "nginx_base": "1.28",
        "config_revision": 1,
        "tag": "1.28-r1",
    }))
    (tmp_path / "installer-version.json").write_text(json.dumps({
        "version": "0.1.0",
        "tag": "0.1.0",
    }))

    catalog = load_catalog(tmp_path)

    assert isinstance(catalog, Catalog)
    assert catalog.default_php_entry.webtrees == "2.2.6"
    assert catalog.default_php_entry.php == "8.5"
    assert catalog.nginx_tag == "1.28-r1"
    assert catalog.installer_version == "0.1.0"


def test_default_php_entry_prefers_latest_tag(tmp_path: Path) -> None:
    """Entry tagged 'latest' wins regardless of position in the array."""
    (tmp_path / "versions.json").write_text(json.dumps([
        {"webtrees": "2.2.5", "php": "8.4"},
        {"webtrees": "2.2.6", "php": "8.5", "tags": ["latest"]},
    ]))
    (tmp_path / "nginx-version.json").write_text(json.dumps({
        "nginx_base": "1.28", "config_revision": 1, "tag": "1.28-r1",
    }))
    (tmp_path / "installer-version.json").write_text(json.dumps({
        "version": "0.1.0", "tag": "0.1.0",
    }))

    catalog = load_catalog(tmp_path)

    assert catalog.default_php_entry.webtrees == "2.2.6"


def test_load_catalog_raises_on_missing_manifest(tmp_path: Path) -> None:
    """Missing versions.json raises FileNotFoundError with a clear message."""
    with pytest.raises(FileNotFoundError, match="versions.json"):
        load_catalog(tmp_path)
```

- [ ] **Step 2.2: Run and confirm failure**

```bash
docker run --rm -v "$PWD/installer:/installer" -w /installer python:3.12-alpine \
    sh -c "pip install -e .[test] >/dev/null && pytest tests/test_versions.py -v"
```

Expected: ImportError on `webtrees_installer.versions`.

- [ ] **Step 2.3: Implement `versions.py`**

`installer/webtrees_installer/versions.py`:

```python
"""Load the bundled image catalog (versions.json + nginx + installer)."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


@dataclass(frozen=True)
class PhpEntry:
    """One row from versions.json: a webtrees release pinned to a PHP version."""

    webtrees: str
    php: str
    tags: tuple[str, ...] = ()


@dataclass(frozen=True)
class Catalog:
    """Resolved tag catalog the wizard renders into compose templates."""

    php_entries: tuple[PhpEntry, ...]
    nginx_tag: str
    installer_version: str

    @property
    def default_php_entry(self) -> PhpEntry:
        """Return the entry tagged 'latest', or the first if none is tagged."""
        for entry in self.php_entries:
            if "latest" in entry.tags:
                return entry
        return self.php_entries[0]


def load_catalog(manifest_dir: Path) -> Catalog:
    """Read the three JSON manifests from manifest_dir and build a Catalog."""
    php_entries = _load_php_entries(manifest_dir / "versions.json")
    nginx_tag = _load_nginx_tag(manifest_dir / "nginx-version.json")
    installer_version = _load_installer_version(
        manifest_dir / "installer-version.json"
    )
    return Catalog(
        php_entries=php_entries,
        nginx_tag=nginx_tag,
        installer_version=installer_version,
    )


def _load_php_entries(path: Path) -> tuple[PhpEntry, ...]:
    if not path.exists():
        raise FileNotFoundError(f"Missing manifest: {path.name}")
    rows: Iterable[dict] = json.loads(path.read_text())
    return tuple(
        PhpEntry(
            webtrees=row["webtrees"],
            php=row["php"],
            tags=tuple(row.get("tags", [])),
        )
        for row in rows
    )


def _load_nginx_tag(path: Path) -> str:
    if not path.exists():
        raise FileNotFoundError(f"Missing manifest: {path.name}")
    data = json.loads(path.read_text())
    return data["tag"]


def _load_installer_version(path: Path) -> str:
    if not path.exists():
        raise FileNotFoundError(f"Missing manifest: {path.name}")
    data = json.loads(path.read_text())
    return data["version"]
```

- [ ] **Step 2.4: Re-run, confirm pass**

```bash
docker run --rm -v "$PWD/installer:/installer" -w /installer python:3.12-alpine \
    sh -c "pip install -e .[test] >/dev/null && pytest tests/test_versions.py -v"
```

Expected: 3 passed.

- [ ] **Step 2.5: Bake the manifests into the image**

Modify `installer/Dockerfile` to copy the manifest directory in:

```dockerfile
# Before COPY webtrees_installer
COPY versions /opt/installer/versions
```

And add a `versions/` directory at `installer/` build context that the Dockerfile copies from. Since the build context is `installer/` and the manifests live at `dev/*.json` in repo root, we have two options:

1. **Option chosen:** change the build context to repo root, point `-f installer/Dockerfile`, copy `dev/*.json` into `/opt/installer/versions/`.

Update `installer/Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1.7

FROM python:3.12-alpine AS installer

LABEL org.opencontainers.image.source="https://github.com/magicsunday/webtrees-docker"
LABEL org.opencontainers.image.description="Wizard for setting up a self-hosted webtrees stack"
LABEL org.opencontainers.image.licenses="MIT"

RUN apk add --no-cache docker-cli docker-cli-compose

WORKDIR /opt/installer

COPY installer/pyproject.toml installer/README.md ./
COPY installer/webtrees_installer ./webtrees_installer
COPY dev/versions.json dev/nginx-version.json dev/installer-version.json ./versions/

RUN pip install --no-cache-dir .

ENV WEBTREES_INSTALLER_MANIFEST_DIR=/opt/installer/versions

VOLUME ["/work"]
WORKDIR /work

ENTRYPOINT ["python", "-m", "webtrees_installer"]
```

- [ ] **Step 2.6: Rebuild and smoke-test inside the image**

```bash
docker build -f installer/Dockerfile -t webtrees-installer:local .
docker run --rm webtrees-installer:local --version
docker run --rm --entrypoint python webtrees-installer:local -c \
    "from pathlib import Path; from webtrees_installer.versions import load_catalog; \
     c = load_catalog(Path('/opt/installer/versions')); \
     print(c.default_php_entry, c.nginx_tag)"
docker rmi webtrees-installer:local
```

Expected: prints the default `PhpEntry(...)` and the nginx tag from `dev/*.json`.

- [ ] **Step 2.7: Commit**

```bash
git -C /volume2/docker/webtrees add installer/webtrees_installer/versions.py \
    installer/tests/test_versions.py installer/Dockerfile
git -C /volume2/docker/webtrees commit -m "$(cat <<'EOF'
Bake the image catalog into webtrees-installer

versions.py loads versions.json + nginx-version.json + installer-version.json
from a manifest directory baked into the image at /opt/installer/versions.
default_php_entry picks the row tagged 'latest', falling back to first.
The Dockerfile build context is now the repo root so dev/*.json is in
scope; pyproject.toml + webtrees_installer/ are pulled in under installer/.
EOF
)"
```

### Acceptance criteria

- `pytest installer/tests/test_versions.py -v` passes 3 tests.
- The built image bundles `versions.json`, `nginx-version.json`, `installer-version.json` under `/opt/installer/versions`.
- `load_catalog(...)` resolves the `latest`-tagged PHP entry as default.

---

## Task 3: Prerequisite checks

**Files:**
- Create: `installer/webtrees_installer/prereq.py`
- Create: `installer/tests/test_prereq.py`

### Goal

A `check_prerequisites()` function verifies the runtime mounts (`/work` and the Docker socket), checks that Compose v2 is reachable, and raises a `PrereqError` with an actionable hint when one fails.

### Steps

- [ ] **Step 3.1: Write the failing tests**

`installer/tests/test_prereq.py`:

```python
"""Tests for the runtime prerequisite checks."""

from __future__ import annotations

import subprocess
from pathlib import Path
from unittest.mock import patch

import pytest

from webtrees_installer.prereq import PrereqError, check_prerequisites


def test_check_prerequisites_ok(tmp_path: Path) -> None:
    """All probes pass → no exception, no return value."""
    sock = tmp_path / "docker.sock"
    sock.touch()

    with patch(
        "webtrees_installer.prereq._compose_version",
        return_value="v2.29.7",
    ):
        check_prerequisites(work_dir=tmp_path, docker_sock=sock)


def test_check_prerequisites_missing_work(tmp_path: Path) -> None:
    """Missing /work raises with a `docker run -v` hint."""
    sock = tmp_path / "docker.sock"
    sock.touch()

    with pytest.raises(PrereqError, match=r"-v.*:/work"):
        check_prerequisites(
            work_dir=tmp_path / "does-not-exist",
            docker_sock=sock,
        )


def test_check_prerequisites_missing_socket(tmp_path: Path) -> None:
    """Missing /var/run/docker.sock raises with the bind-mount hint."""
    with pytest.raises(PrereqError, match=r"/var/run/docker.sock"):
        check_prerequisites(
            work_dir=tmp_path,
            docker_sock=tmp_path / "absent.sock",
        )


def test_check_prerequisites_compose_v1(tmp_path: Path) -> None:
    """Compose v1 reports `docker-compose version 1.x` → wizard rejects it."""
    sock = tmp_path / "docker.sock"
    sock.touch()

    with patch(
        "webtrees_installer.prereq._compose_version",
        return_value="docker-compose version 1.29.2",
    ):
        with pytest.raises(PrereqError, match="Compose v2"):
            check_prerequisites(work_dir=tmp_path, docker_sock=sock)


def test_check_prerequisites_docker_daemon_down(tmp_path: Path) -> None:
    """docker compose version errors → daemon-not-reachable hint."""
    sock = tmp_path / "docker.sock"
    sock.touch()

    with patch(
        "webtrees_installer.prereq._compose_version",
        side_effect=subprocess.CalledProcessError(1, ["docker"], stderr="Cannot connect"),
    ):
        with pytest.raises(PrereqError, match="daemon"):
            check_prerequisites(work_dir=tmp_path, docker_sock=sock)
```

- [ ] **Step 3.2: Run and confirm failure**

```bash
docker run --rm -v "$PWD/installer:/installer" -w /installer python:3.12-alpine \
    sh -c "pip install -e .[test] >/dev/null && pytest tests/test_prereq.py -v"
```

Expected: ImportError on `webtrees_installer.prereq`.

- [ ] **Step 3.3: Implement `prereq.py`**

`installer/webtrees_installer/prereq.py`:

```python
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
```

- [ ] **Step 3.4: Re-run and confirm pass**

```bash
docker run --rm -v "$PWD/installer:/installer" -w /installer python:3.12-alpine \
    sh -c "pip install -e .[test] >/dev/null && pytest tests/test_prereq.py -v"
```

Expected: 5 passed.

- [ ] **Step 3.5: Commit**

```bash
git -C /volume2/docker/webtrees add installer/webtrees_installer/prereq.py \
    installer/tests/test_prereq.py
git -C /volume2/docker/webtrees commit -m "$(cat <<'EOF'
Validate /work, the docker socket and Compose v2 before prompting

check_prerequisites refuses to continue without the runtime mounts the
wizard depends on, and rejects Compose v1 (no `secrets:` short-form,
no `condition: service_completed_successfully`) before any prompt is
shown. Each failure carries the exact docker-run flag or upgrade hint
the user needs to recover.
EOF
)"
```

### Acceptance criteria

- `pytest installer/tests/test_prereq.py -v` passes 5 tests.
- Each `PrereqError` message contains either a `docker run -v` snippet or a "Compose v2" / "daemon" keyword that the test regexes match.

---

## Task 4: Existing-file guard

**Files:**
- Modify: `installer/webtrees_installer/prereq.py` (add `confirm_overwrite`)
- Modify: `installer/tests/test_prereq.py`

### Goal

When `compose.yaml` or `.env` already exists in `/work`, the wizard prompts before overwriting. Non-interactive callers must opt in with `--force` (introduced here as a parameter; the CLI flag wire-up happens in Task 9).

### Steps

- [ ] **Step 4.1: Append the failing tests**

Add to `installer/tests/test_prereq.py`:

```python
from io import StringIO

from webtrees_installer.prereq import (
    PrereqError,
    check_prerequisites,
    confirm_overwrite,
)


def test_confirm_overwrite_no_conflict(tmp_path: Path) -> None:
    """Clean /work → no prompt, returns True."""
    assert confirm_overwrite(work_dir=tmp_path, interactive=True) is True


def test_confirm_overwrite_prompts_when_compose_exists(tmp_path: Path) -> None:
    """compose.yaml present + user replies 'n' → returns False."""
    (tmp_path / "compose.yaml").write_text("# existing")
    answer = confirm_overwrite(
        work_dir=tmp_path,
        interactive=True,
        stdin=StringIO("n\n"),
        stdout=StringIO(),
    )
    assert answer is False


def test_confirm_overwrite_prompts_when_compose_exists_yes(tmp_path: Path) -> None:
    """compose.yaml present + user replies 'y' → returns True."""
    (tmp_path / "compose.yaml").write_text("# existing")
    answer = confirm_overwrite(
        work_dir=tmp_path,
        interactive=True,
        stdin=StringIO("y\n"),
        stdout=StringIO(),
    )
    assert answer is True


def test_confirm_overwrite_noninteractive_without_force(tmp_path: Path) -> None:
    """Non-interactive + conflict + no force flag → PrereqError."""
    (tmp_path / "compose.yaml").write_text("# existing")
    with pytest.raises(PrereqError, match=r"--force"):
        confirm_overwrite(work_dir=tmp_path, interactive=False, force=False)


def test_confirm_overwrite_noninteractive_with_force(tmp_path: Path) -> None:
    """Non-interactive + force=True → returns True regardless of files."""
    (tmp_path / "compose.yaml").write_text("# existing")
    (tmp_path / ".env").write_text("X=1")
    assert confirm_overwrite(work_dir=tmp_path, interactive=False, force=True) is True
```

- [ ] **Step 4.2: Run, confirm failure**

```bash
docker run --rm -v "$PWD/installer:/installer" -w /installer python:3.12-alpine \
    sh -c "pip install -e .[test] >/dev/null && pytest tests/test_prereq.py -v"
```

Expected: ImportError on `confirm_overwrite`.

- [ ] **Step 4.3: Implement `confirm_overwrite` in `prereq.py`**

Append to `installer/webtrees_installer/prereq.py`:

```python
import sys
from typing import IO


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
            "Refusing to overwrite "
            + ", ".join(conflicts)
            + " in non-interactive mode without --force."
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
```

- [ ] **Step 4.4: Re-run, confirm pass**

```bash
docker run --rm -v "$PWD/installer:/installer" -w /installer python:3.12-alpine \
    sh -c "pip install -e .[test] >/dev/null && pytest tests/test_prereq.py -v"
```

Expected: 10 passed (5 original + 5 new).

- [ ] **Step 4.5: Commit**

```bash
git -C /volume2/docker/webtrees add installer/webtrees_installer/prereq.py \
    installer/tests/test_prereq.py
git -C /volume2/docker/webtrees commit -m "$(cat <<'EOF'
Guard pre-existing compose.yaml and .env from clobbering

confirm_overwrite() detects collisions in /work and either prompts the
user (default N to err on the side of preserving their files) or
demands --force when running non-interactively. The function takes
stdin/stdout overrides so tests can drive it without subprocess plumbing.
EOF
)"
```

### Acceptance criteria

- `pytest installer/tests/test_prereq.py -v` passes 10 tests.
- The CLI does not yet honour `--force` (Task 9 wires it up).

---

## Task 5: Port-conflict check via Alpine container

**Files:**
- Create: `installer/webtrees_installer/ports.py`
- Create: `installer/tests/test_ports.py`

### Goal

Before suggesting a host port for nginx, the wizard tries to bind it via a short-lived Alpine container and returns one of `FREE`, `IN_USE`, or `CHECK_FAILED`. The orchestrator (Task 9) loops on `IN_USE` and downgrades to a warning on `CHECK_FAILED` per the spec.

### Steps

- [ ] **Step 5.1: Write the failing tests**

`installer/tests/test_ports.py`:

```python
"""Tests for live port-conflict detection."""

from __future__ import annotations

import subprocess
from unittest.mock import patch

import pytest

from webtrees_installer.ports import PortStatus, probe_port


def test_probe_port_free() -> None:
    """docker run exits 0 → PortStatus.FREE."""
    with patch("webtrees_installer.ports._run_docker_probe") as run:
        run.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout="", stderr=""
        )
        assert probe_port(8080) == PortStatus.FREE


def test_probe_port_in_use() -> None:
    """docker run exits non-zero with 'address already in use' → IN_USE."""
    with patch("webtrees_installer.ports._run_docker_probe") as run:
        run.return_value = subprocess.CompletedProcess(
            args=[],
            returncode=125,
            stdout="",
            stderr="bind: address already in use",
        )
        assert probe_port(8080) == PortStatus.IN_USE


def test_probe_port_check_failed_on_unrelated_error() -> None:
    """Unexpected docker error → CHECK_FAILED (caller downgrades to warn)."""
    with patch("webtrees_installer.ports._run_docker_probe") as run:
        run.return_value = subprocess.CompletedProcess(
            args=[],
            returncode=1,
            stdout="",
            stderr="docker: permission denied",
        )
        assert probe_port(8080) == PortStatus.CHECK_FAILED


def test_probe_port_check_failed_on_subprocess_error() -> None:
    """docker CLI itself missing / hangs → CHECK_FAILED."""
    with patch("webtrees_installer.ports._run_docker_probe") as run:
        run.side_effect = FileNotFoundError("docker not on PATH")
        assert probe_port(8080) == PortStatus.CHECK_FAILED


@pytest.mark.parametrize("invalid", [0, -1, 65536, 99999])
def test_probe_port_rejects_invalid_port(invalid: int) -> None:
    """Out-of-range ports raise ValueError before invoking docker."""
    with pytest.raises(ValueError, match="port"):
        probe_port(invalid)
```

- [ ] **Step 5.2: Run, confirm failure**

```bash
docker run --rm -v "$PWD/installer:/installer" -w /installer python:3.12-alpine \
    sh -c "pip install -e .[test] >/dev/null && pytest tests/test_ports.py -v"
```

Expected: ImportError on `webtrees_installer.ports`.

- [ ] **Step 5.3: Implement `ports.py`**

`installer/webtrees_installer/ports.py`:

```python
"""Live port-conflict probe via a short-lived Alpine container."""

from __future__ import annotations

import enum
import subprocess


class PortStatus(enum.Enum):
    """Result of a probe_port() call."""

    FREE = "free"
    IN_USE = "in_use"
    CHECK_FAILED = "check_failed"


def probe_port(port: int) -> PortStatus:
    """Try to bind `port` on the host. Return whether it's free, taken or unprobeable."""
    if not 1 <= port <= 65535:
        raise ValueError(f"port out of range: {port}")

    try:
        result = _run_docker_probe(port)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return PortStatus.CHECK_FAILED

    if result.returncode == 0:
        return PortStatus.FREE
    if "address already in use" in (result.stderr or "").lower():
        return PortStatus.IN_USE
    return PortStatus.CHECK_FAILED


def _run_docker_probe(port: int) -> subprocess.CompletedProcess[str]:
    """Spin up an alpine container that exits immediately while holding the port."""
    return subprocess.run(
        [
            "docker", "run", "--rm",
            "-p", f"{port}:1",
            "alpine:3.20",
            "true",
        ],
        capture_output=True,
        text=True,
        timeout=20,
    )
```

- [ ] **Step 5.4: Re-run, confirm pass**

```bash
docker run --rm -v "$PWD/installer:/installer" -w /installer python:3.12-alpine \
    sh -c "pip install -e .[test] >/dev/null && pytest tests/test_ports.py -v"
```

Expected: 7 passed (3 status cases + 1 subprocess-error case + 4 parametrised invalid ports).

- [ ] **Step 5.5: Commit**

```bash
git -C /volume2/docker/webtrees add installer/webtrees_installer/ports.py \
    installer/tests/test_ports.py
git -C /volume2/docker/webtrees commit -m "$(cat <<'EOF'
Probe host ports via an ephemeral alpine container

probe_port() spins up `alpine:3.20 true` with the requested port
forwarded; if docker rejects with 'address already in use' the wizard
knows to suggest another port. Permission errors or a missing docker
CLI fold into CHECK_FAILED so callers can downgrade to a warning
instead of blocking on hostile sandbox conditions.
EOF
)"
```

### Acceptance criteria

- `pytest installer/tests/test_ports.py -v` passes 7 tests.
- `probe_port(8080)` returns a `PortStatus` value without raising for any docker outcome short of an explicit `ValueError` on out-of-range input.

---

## Task 6: Prompt library

**Files:**
- Create: `installer/webtrees_installer/prompts.py`
- Create: `installer/tests/test_prompts.py`

### Goal

Helpers that drive the wizard's user interaction: `ask_text(question, default)`, `ask_choice(question, options, default)`, `ask_yesno(question, default)`. Each helper accepts an optional `value` argument that short-circuits the prompt — that's how the non-interactive layer (Task 9) feeds CLI flags through the same code path.

### Steps

- [ ] **Step 6.1: Write the failing tests**

`installer/tests/test_prompts.py`:

```python
"""Tests for the prompt library."""

from __future__ import annotations

from io import StringIO

import pytest

from webtrees_installer.prompts import (
    Choice,
    PromptError,
    ask_choice,
    ask_text,
    ask_yesno,
)


def test_ask_text_uses_default_on_empty_input() -> None:
    answer = ask_text(
        "Domain",
        default="webtrees.example.org",
        stdin=StringIO("\n"),
        stdout=StringIO(),
    )
    assert answer == "webtrees.example.org"


def test_ask_text_uses_input_when_provided() -> None:
    answer = ask_text(
        "Domain",
        default="webtrees.example.org",
        stdin=StringIO("foo.local\n"),
        stdout=StringIO(),
    )
    assert answer == "foo.local"


def test_ask_text_short_circuits_on_value() -> None:
    """`value` argument bypasses stdin entirely (non-interactive plumbing)."""
    answer = ask_text("Domain", default="x", value="from-flag", stdin=None, stdout=None)
    assert answer == "from-flag"


def test_ask_text_required_rejects_empty() -> None:
    """No default + empty input → PromptError."""
    with pytest.raises(PromptError, match="required"):
        ask_text(
            "Domain",
            default=None,
            stdin=StringIO("\n"),
            stdout=StringIO(),
        )


def test_ask_choice_returns_label_for_index_input() -> None:
    choices = [
        Choice("core", "Core (plain Webtrees)"),
        Choice("full", "Full (with Magic Sunday charts)"),
    ]
    answer = ask_choice(
        "Edition",
        choices=choices,
        default="full",
        stdin=StringIO("1\n"),
        stdout=StringIO(),
    )
    assert answer == "core"


def test_ask_choice_uses_default_on_empty_input() -> None:
    choices = [Choice("core", "Core"), Choice("full", "Full")]
    answer = ask_choice(
        "Edition",
        choices=choices,
        default="full",
        stdin=StringIO("\n"),
        stdout=StringIO(),
    )
    assert answer == "full"


def test_ask_choice_short_circuits_on_value() -> None:
    choices = [Choice("core", "Core"), Choice("full", "Full")]
    answer = ask_choice(
        "Edition",
        choices=choices,
        default="full",
        value="core",
        stdin=None,
        stdout=None,
    )
    assert answer == "core"


def test_ask_choice_rejects_unknown_value() -> None:
    choices = [Choice("core", "Core"), Choice("full", "Full")]
    with pytest.raises(PromptError, match="invalid"):
        ask_choice(
            "Edition", choices=choices, default="full", value="demo",
            stdin=None, stdout=None,
        )


def test_ask_yesno_default_yes_on_empty() -> None:
    assert ask_yesno(
        "Bootstrap?", default=True,
        stdin=StringIO("\n"), stdout=StringIO(),
    ) is True


def test_ask_yesno_default_no_on_empty() -> None:
    assert ask_yesno(
        "Bootstrap?", default=False,
        stdin=StringIO("\n"), stdout=StringIO(),
    ) is False


@pytest.mark.parametrize("inp,want", [("y", True), ("Y", True), ("yes", True),
                                       ("n", False), ("N", False), ("no", False)])
def test_ask_yesno_parses_explicit_answers(inp: str, want: bool) -> None:
    assert ask_yesno(
        "Bootstrap?", default=True,
        stdin=StringIO(f"{inp}\n"), stdout=StringIO(),
    ) is want
```

- [ ] **Step 6.2: Run, confirm failure**

```bash
docker run --rm -v "$PWD/installer:/installer" -w /installer python:3.12-alpine \
    sh -c "pip install -e .[test] >/dev/null && pytest tests/test_prompts.py -v"
```

Expected: ImportError on `webtrees_installer.prompts`.

- [ ] **Step 6.3: Implement `prompts.py`**

`installer/webtrees_installer/prompts.py`:

```python
"""Interactive prompt helpers with non-interactive overrides."""

from __future__ import annotations

import sys
from dataclasses import dataclass
from typing import IO, Sequence


class PromptError(ValueError):
    """Raised when prompt input is missing or unparseable in non-interactive mode."""


@dataclass(frozen=True)
class Choice:
    """One option in a multiple-choice prompt."""

    value: str
    label: str


def ask_text(
    question: str,
    *,
    default: str | None,
    value: str | None = None,
    stdin: IO[str] | None = None,
    stdout: IO[str] | None = None,
) -> str:
    """Read a free-form string answer. `value` overrides the prompt entirely."""
    if value is not None:
        if not value:
            raise PromptError(f"{question}: required")
        return value

    stdin = stdin or sys.stdin
    stdout = stdout or sys.stdout

    suffix = f" [{default}]" if default is not None else ""
    print(f"{question}{suffix}: ", end="", file=stdout, flush=True)
    reply = stdin.readline().strip()

    if reply:
        return reply
    if default is not None:
        return default
    raise PromptError(f"{question}: required")


def ask_choice(
    question: str,
    *,
    choices: Sequence[Choice],
    default: str,
    value: str | None = None,
    stdin: IO[str] | None = None,
    stdout: IO[str] | None = None,
) -> str:
    """Read one selection from `choices` by 1-based index. Returns the value."""
    valid = {c.value for c in choices}
    if default not in valid:
        raise PromptError(f"default {default!r} is not in choices")

    if value is not None:
        if value not in valid:
            raise PromptError(f"{question}: invalid value {value!r}")
        return value

    stdin = stdin or sys.stdin
    stdout = stdout or sys.stdout

    print(question, file=stdout)
    for i, choice in enumerate(choices, start=1):
        marker = " (default)" if choice.value == default else ""
        print(f"  {i}) {choice.label}{marker}", file=stdout)
    print("Choice: ", end="", file=stdout, flush=True)
    reply = stdin.readline().strip()

    if not reply:
        return default
    try:
        idx = int(reply)
    except ValueError as exc:
        raise PromptError(f"{question}: not a number: {reply!r}") from exc
    if not 1 <= idx <= len(choices):
        raise PromptError(f"{question}: out of range: {idx}")
    return choices[idx - 1].value


def ask_yesno(
    question: str,
    *,
    default: bool,
    value: bool | None = None,
    stdin: IO[str] | None = None,
    stdout: IO[str] | None = None,
) -> bool:
    """Read a y/n answer. Empty input returns `default`."""
    if value is not None:
        return value

    stdin = stdin or sys.stdin
    stdout = stdout or sys.stdout

    hint = "[Y/n]" if default else "[y/N]"
    print(f"{question} {hint}: ", end="", file=stdout, flush=True)
    reply = stdin.readline().strip().lower()

    if not reply:
        return default
    if reply in {"y", "yes"}:
        return True
    if reply in {"n", "no"}:
        return False
    raise PromptError(f"{question}: unparseable answer {reply!r}")
```

- [ ] **Step 6.4: Re-run, confirm pass**

```bash
docker run --rm -v "$PWD/installer:/installer" -w /installer python:3.12-alpine \
    sh -c "pip install -e .[test] >/dev/null && pytest tests/test_prompts.py -v"
```

Expected: 15 passed.

- [ ] **Step 6.5: Commit**

```bash
git -C /volume2/docker/webtrees add installer/webtrees_installer/prompts.py \
    installer/tests/test_prompts.py
git -C /volume2/docker/webtrees commit -m "$(cat <<'EOF'
Add prompt helpers with non-interactive short-circuit

ask_text / ask_choice / ask_yesno read free-form, indexed-choice, and
y-or-n answers respectively. Each helper accepts a `value` argument
that bypasses stdin entirely — that is the bridge non-interactive
callers (the CLI flag-matrix in a later task) use to inject answers
through the same code path the interactive flow walks.
EOF
)"
```

### Acceptance criteria

- `pytest installer/tests/test_prompts.py -v` passes 15 tests.
- Every helper accepts a `value` overrride that bypasses stdin.

---

## Task 7: Jinja templates

**Files:**
- Create: `installer/webtrees_installer/templates/compose.standalone.j2`
- Create: `installer/webtrees_installer/templates/compose.traefik.j2`
- Create: `installer/webtrees_installer/templates/env.j2`

### Goal

Three Jinja2 templates that render to the actual compose / env files the wizard ships. Modelled exactly on the spec's "Compose-Templates" section, parametrised over the wizard's input model (edition, proxy mode, port/domain, admin opts, image tags).

### Steps

- [ ] **Step 7.1: Create the standalone compose template**

`installer/webtrees_installer/templates/compose.standalone.j2`:

```yaml
{# Standalone (no reverse proxy) compose layout. -#}
name: webtrees

volumes:
    secrets:
    database:
    app:
    media:

services:
    init:
        image: alpine:3.20
        restart: "no"
        volumes:
            - secrets:/secrets
        command:
            - sh
            - -ec
            - |
                umask 077
                apk add --no-cache openssl >/dev/null
                for name in mariadb_root_password mariadb_password{% if admin_bootstrap %} wt_admin_password{% endif %}; do
                  [ -s "/secrets/$name" ] || openssl rand -hex 24 > "/secrets/$name"
                done
                chmod 444 /secrets/*

    db:
        image: mariadb:11.7
        depends_on:
            init:
                condition: service_completed_successfully
        restart: unless-stopped
        environment:
            MARIADB_ROOT_PASSWORD_FILE: /secrets/mariadb_root_password
            MARIADB_USER: webtrees
            MARIADB_PASSWORD_FILE: /secrets/mariadb_password
            MARIADB_DATABASE: webtrees
        volumes:
            - secrets:/secrets:ro
            - database:/var/lib/mysql
        healthcheck:
            test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
            interval: 10s
            timeout: 5s
            retries: 5
            start_period: 10s

    phpfpm:
        image: ghcr.io/magicsunday/webtrees/php{% if edition == "full" %}-full{% endif %}:{{ webtrees_version }}-php{{ php_version }}
        depends_on:
            db:
                condition: service_healthy
        restart: unless-stopped
        environment:
            ENVIRONMENT: production
            ENFORCE_HTTPS: "FALSE"
            WEBTREES_VERSION: "{{ webtrees_version }}"
            WEBTREES_AUTO_SEED: "true"
            MARIADB_HOST: db
            MARIADB_USER: webtrees
            MARIADB_PASSWORD_FILE: /secrets/mariadb_password
            MARIADB_DATABASE: webtrees
{%- if admin_bootstrap %}
            WT_ADMIN_USER: "{{ admin_user }}"
            WT_ADMIN_EMAIL: "{{ admin_email }}"
            WT_ADMIN_PASSWORD_FILE: /secrets/wt_admin_password
{%- endif %}
        healthcheck:
            test: ["CMD-SHELL", "pgrep php-fpm > /dev/null || exit 1"]
            interval: 5s
            timeout: 3s
            retries: 3
            start_period: 5s
        volumes:
            - secrets:/secrets:ro
            - app:/var/www/html
            - media:/var/www/html/data/media

    nginx:
        image: ghcr.io/magicsunday/webtrees/nginx:{{ nginx_tag }}
        depends_on:
            phpfpm:
                condition: service_healthy
        restart: unless-stopped
        environment:
            ENFORCE_HTTPS: "FALSE"
        ports:
            - "${APP_PORT:-{{ app_port }}}:80"
        healthcheck:
            test: ["CMD-SHELL", "curl -sf http://localhost/ -o /dev/null || exit 1"]
            interval: 10s
            timeout: 5s
            retries: 3
            start_period: 5s
        volumes:
            - app:/var/www/html:ro
            - media:/var/www/html/data/media:ro
```

- [ ] **Step 7.2: Create the Traefik compose template**

`installer/webtrees_installer/templates/compose.traefik.j2`:

```yaml
{# Traefik (reverse-proxy) compose layout. -#}
name: webtrees

volumes:
    secrets:
    database:
    app:
    media:

networks:
    default:
    traefik:
        external: true

services:
    init:
        image: alpine:3.20
        restart: "no"
        volumes:
            - secrets:/secrets
        command:
            - sh
            - -ec
            - |
                umask 077
                apk add --no-cache openssl >/dev/null
                for name in mariadb_root_password mariadb_password{% if admin_bootstrap %} wt_admin_password{% endif %}; do
                  [ -s "/secrets/$name" ] || openssl rand -hex 24 > "/secrets/$name"
                done
                chmod 444 /secrets/*

    db:
        image: mariadb:11.7
        depends_on:
            init:
                condition: service_completed_successfully
        restart: unless-stopped
        environment:
            MARIADB_ROOT_PASSWORD_FILE: /secrets/mariadb_root_password
            MARIADB_USER: webtrees
            MARIADB_PASSWORD_FILE: /secrets/mariadb_password
            MARIADB_DATABASE: webtrees
        volumes:
            - secrets:/secrets:ro
            - database:/var/lib/mysql
        healthcheck:
            test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
            interval: 10s
            timeout: 5s
            retries: 5
            start_period: 10s

    phpfpm:
        image: ghcr.io/magicsunday/webtrees/php{% if edition == "full" %}-full{% endif %}:{{ webtrees_version }}-php{{ php_version }}
        depends_on:
            db:
                condition: service_healthy
        restart: unless-stopped
        environment:
            ENVIRONMENT: production
            ENFORCE_HTTPS: "TRUE"
            WEBTREES_VERSION: "{{ webtrees_version }}"
            WEBTREES_AUTO_SEED: "true"
            MARIADB_HOST: db
            MARIADB_USER: webtrees
            MARIADB_PASSWORD_FILE: /secrets/mariadb_password
            MARIADB_DATABASE: webtrees
{%- if admin_bootstrap %}
            WT_ADMIN_USER: "{{ admin_user }}"
            WT_ADMIN_EMAIL: "{{ admin_email }}"
            WT_ADMIN_PASSWORD_FILE: /secrets/wt_admin_password
{%- endif %}
        healthcheck:
            test: ["CMD-SHELL", "pgrep php-fpm > /dev/null || exit 1"]
            interval: 5s
            timeout: 3s
            retries: 3
            start_period: 5s
        volumes:
            - secrets:/secrets:ro
            - app:/var/www/html
            - media:/var/www/html/data/media

    nginx:
        image: ghcr.io/magicsunday/webtrees/nginx:{{ nginx_tag }}
        depends_on:
            phpfpm:
                condition: service_healthy
        restart: unless-stopped
        environment:
            ENFORCE_HTTPS: "TRUE"
        networks:
            - default
            - traefik
        labels:
            traefik.enable: "true"
            traefik.docker.network: "traefik"
            traefik.http.routers.webtrees.rule: "Host(`{{ domain }}`)"
            traefik.http.routers.webtrees.entrypoints: "websecure"
            traefik.http.routers.webtrees.tls: "true"
            traefik.http.services.webtrees.loadbalancer.server.port: "80"
        healthcheck:
            test: ["CMD-SHELL", "curl -sf http://localhost/ -o /dev/null || exit 1"]
            interval: 10s
            timeout: 5s
            retries: 3
            start_period: 5s
        volumes:
            - app:/var/www/html:ro
            - media:/var/www/html/data/media:ro
```

- [ ] **Step 7.3: Create the `.env` template**

`installer/webtrees_installer/templates/env.j2`:

```ini
# Generated by webtrees-installer {{ installer_version }} on {{ generated_at }}.
# Edit at will; the wizard does not read this file on subsequent runs.

COMPOSE_PROJECT_NAME=webtrees
WEBTREES_VERSION={{ webtrees_version }}
PHP_VERSION={{ php_version }}
WEBTREES_NGINX_VERSION={{ nginx_tag }}
{% if proxy_mode == "standalone" %}
# Override the host port if you need to publish on a different port.
APP_PORT={{ app_port }}
{% endif %}
```

- [ ] **Step 7.4: Sanity-check the templates render**

No tests yet — that's Task 8. For now just verify the templates parse:

```bash
docker run --rm -v "$PWD/installer:/installer" -w /installer python:3.12-alpine \
    sh -c "pip install Jinja2 >/dev/null && python -c \"
from jinja2 import Environment, FileSystemLoader
env = Environment(loader=FileSystemLoader('webtrees_installer/templates'), keep_trailing_newline=True)
for name in ('compose.standalone.j2', 'compose.traefik.j2', 'env.j2'):
    env.get_template(name)
    print(name, 'ok')
\""
```

Expected: three "ok" lines, no exception.

- [ ] **Step 7.5: Commit**

```bash
git -C /volume2/docker/webtrees add installer/webtrees_installer/templates/
git -C /volume2/docker/webtrees commit -m "$(cat <<'EOF'
Add Jinja2 templates for compose.yaml and .env

Three templates feed the wizard's standalone and Traefik flows: the
standalone variant publishes nginx on ${APP_PORT}, the Traefik variant
wires the external traefik network plus per-router labels. Both share
the secrets-init service and the admin-bootstrap block which becomes
optional via the admin_bootstrap context flag. env.j2 produces a
minimal .env carrying the image tags plus APP_PORT for standalone.
EOF
)"
```

### Acceptance criteria

- `jinja2.Environment` can parse all three templates without raising.
- Standalone template publishes `${APP_PORT:-<port>}:80` on nginx.
- Traefik template declares the external `traefik` network and labels the nginx service.

---

## Task 8: Template renderer

**Files:**
- Create: `installer/webtrees_installer/render.py`
- Create: `installer/tests/test_render.py`

### Goal

A `render_files(input_model, catalog, target_dir)` function turns a typed input model into the rendered files in `/work`. Tests render the matrix of editions × proxy modes × admin bootstrap on/off and assert structural invariants.

### Steps

- [ ] **Step 8.1: Write the failing tests**

`installer/tests/test_render.py`:

```python
"""Tests for the template renderer."""

from __future__ import annotations

from datetime import datetime
from pathlib import Path

import pytest
import yaml

from webtrees_installer.render import (
    RenderInput,
    render_files,
)
from webtrees_installer.versions import Catalog, PhpEntry


@pytest.fixture
def catalog() -> Catalog:
    return Catalog(
        php_entries=(
            PhpEntry(webtrees="2.2.6", php="8.5", tags=("latest",)),
            PhpEntry(webtrees="2.2.6", php="8.4"),
        ),
        nginx_tag="1.28-r1",
        installer_version="0.1.0",
    )


@pytest.fixture
def standalone_core(catalog: Catalog) -> RenderInput:
    return RenderInput(
        edition="core",
        proxy_mode="standalone",
        app_port=8080,
        domain=None,
        admin_bootstrap=False,
        admin_user=None,
        admin_email=None,
        catalog=catalog,
        generated_at=datetime(2026, 5, 12, 12, 0, 0),
    )


def test_render_standalone_core(tmp_path: Path, standalone_core: RenderInput) -> None:
    render_files(standalone_core, target_dir=tmp_path)

    compose = yaml.safe_load((tmp_path / "compose.yaml").read_text())
    env = (tmp_path / ".env").read_text()

    assert compose["name"] == "webtrees"
    phpfpm = compose["services"]["phpfpm"]
    assert "php-full" not in phpfpm["image"]
    assert phpfpm["image"].endswith(":2.2.6-php8.5")
    assert "WT_ADMIN_USER" not in phpfpm["environment"]

    nginx_ports = compose["services"]["nginx"]["ports"]
    assert any("8080" in p for p in nginx_ports)

    assert "APP_PORT=8080" in env
    assert "COMPOSE_PROJECT_NAME=webtrees" in env


def test_render_standalone_full_with_admin(tmp_path: Path, catalog: Catalog) -> None:
    inp = RenderInput(
        edition="full",
        proxy_mode="standalone",
        app_port=80,
        domain=None,
        admin_bootstrap=True,
        admin_user="admin",
        admin_email="admin@example.org",
        catalog=catalog,
        generated_at=datetime(2026, 5, 12, 12, 0, 0),
    )
    render_files(inp, target_dir=tmp_path)
    compose = yaml.safe_load((tmp_path / "compose.yaml").read_text())

    phpfpm = compose["services"]["phpfpm"]
    assert "/php-full:" in phpfpm["image"]
    assert phpfpm["environment"]["WT_ADMIN_USER"] == "admin"
    assert phpfpm["environment"]["WT_ADMIN_EMAIL"] == "admin@example.org"
    assert (
        phpfpm["environment"]["WT_ADMIN_PASSWORD_FILE"]
        == "/secrets/wt_admin_password"
    )


def test_render_traefik(tmp_path: Path, catalog: Catalog) -> None:
    inp = RenderInput(
        edition="core",
        proxy_mode="traefik",
        app_port=None,
        domain="webtrees.example.com",
        admin_bootstrap=False,
        admin_user=None,
        admin_email=None,
        catalog=catalog,
        generated_at=datetime(2026, 5, 12, 12, 0, 0),
    )
    render_files(inp, target_dir=tmp_path)
    compose = yaml.safe_load((tmp_path / "compose.yaml").read_text())
    env = (tmp_path / ".env").read_text()

    assert "traefik" in compose["networks"]
    assert compose["networks"]["traefik"]["external"] is True

    nginx = compose["services"]["nginx"]
    assert "ports" not in nginx
    labels = nginx["labels"]
    assert (
        labels["traefik.http.routers.webtrees.rule"]
        == "Host(`webtrees.example.com`)"
    )
    assert "APP_PORT" not in env


def test_render_rejects_invalid_proxy_mode(tmp_path: Path, catalog: Catalog) -> None:
    inp = RenderInput(
        edition="core",
        proxy_mode="nope",
        app_port=8080,
        domain=None,
        admin_bootstrap=False,
        admin_user=None,
        admin_email=None,
        catalog=catalog,
        generated_at=datetime(2026, 5, 12, 12, 0, 0),
    )
    with pytest.raises(ValueError, match="proxy_mode"):
        render_files(inp, target_dir=tmp_path)


def test_render_rejects_admin_without_credentials(tmp_path: Path, catalog: Catalog) -> None:
    inp = RenderInput(
        edition="core",
        proxy_mode="standalone",
        app_port=8080,
        domain=None,
        admin_bootstrap=True,
        admin_user=None,
        admin_email=None,
        catalog=catalog,
        generated_at=datetime(2026, 5, 12, 12, 0, 0),
    )
    with pytest.raises(ValueError, match="admin_user"):
        render_files(inp, target_dir=tmp_path)
```

Add PyYAML to dev deps so the test can parse the output. Update `installer/pyproject.toml`:

```toml
[project.optional-dependencies]
test = [
    "pytest>=8.0",
    "pytest-cov>=5.0",
    "PyYAML>=6.0",
]
```

- [ ] **Step 8.2: Run, confirm failure**

```bash
docker run --rm -v "$PWD/installer:/installer" -w /installer python:3.12-alpine \
    sh -c "pip install -e .[test] >/dev/null && pytest tests/test_render.py -v"
```

Expected: ImportError on `webtrees_installer.render`.

- [ ] **Step 8.3: Implement `render.py`**

`installer/webtrees_installer/render.py`:

```python
"""Render Jinja2 templates into compose.yaml + .env."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from jinja2 import Environment, PackageLoader, StrictUndefined

from webtrees_installer.versions import Catalog


@dataclass(frozen=True)
class RenderInput:
    """All values the templates need."""

    edition: str
    proxy_mode: str
    app_port: int | None
    domain: str | None
    admin_bootstrap: bool
    admin_user: str | None
    admin_email: str | None
    catalog: Catalog
    generated_at: datetime


_VALID_EDITIONS = {"core", "full"}
_VALID_PROXY_MODES = {"standalone", "traefik"}


def render_files(input_model: RenderInput, *, target_dir: Path) -> None:
    """Write compose.yaml + .env into target_dir based on input_model."""
    _validate(input_model)

    env_jinja = Environment(
        loader=PackageLoader("webtrees_installer", "templates"),
        undefined=StrictUndefined,
        keep_trailing_newline=True,
        trim_blocks=False,
        lstrip_blocks=False,
    )

    php_entry = input_model.catalog.default_php_entry
    context = {
        "edition": input_model.edition,
        "proxy_mode": input_model.proxy_mode,
        "app_port": input_model.app_port,
        "domain": input_model.domain,
        "admin_bootstrap": input_model.admin_bootstrap,
        "admin_user": input_model.admin_user,
        "admin_email": input_model.admin_email,
        "webtrees_version": php_entry.webtrees,
        "php_version": php_entry.php,
        "nginx_tag": input_model.catalog.nginx_tag,
        "installer_version": input_model.catalog.installer_version,
        "generated_at": input_model.generated_at.isoformat(),
    }

    compose_template = (
        "compose.standalone.j2"
        if input_model.proxy_mode == "standalone"
        else "compose.traefik.j2"
    )

    compose_text = env_jinja.get_template(compose_template).render(**context)
    env_text = env_jinja.get_template("env.j2").render(**context)

    (target_dir / "compose.yaml").write_text(compose_text)
    (target_dir / ".env").write_text(env_text)


def _validate(input_model: RenderInput) -> None:
    if input_model.edition not in _VALID_EDITIONS:
        raise ValueError(
            f"edition must be one of {_VALID_EDITIONS}, got {input_model.edition!r}"
        )
    if input_model.proxy_mode not in _VALID_PROXY_MODES:
        raise ValueError(
            f"proxy_mode must be one of {_VALID_PROXY_MODES}, "
            f"got {input_model.proxy_mode!r}"
        )
    if input_model.proxy_mode == "standalone" and input_model.app_port is None:
        raise ValueError("standalone proxy_mode requires app_port")
    if input_model.proxy_mode == "traefik" and not input_model.domain:
        raise ValueError("traefik proxy_mode requires domain")
    if input_model.admin_bootstrap and not input_model.admin_user:
        raise ValueError("admin_bootstrap=True requires admin_user")
    if input_model.admin_bootstrap and not input_model.admin_email:
        raise ValueError("admin_bootstrap=True requires admin_email")
```

- [ ] **Step 8.4: Re-run, confirm pass**

```bash
docker run --rm -v "$PWD/installer:/installer" -w /installer python:3.12-alpine \
    sh -c "pip install -e .[test] >/dev/null && pytest tests/test_render.py -v"
```

Expected: 5 passed.

- [ ] **Step 8.5: Commit**

```bash
git -C /volume2/docker/webtrees add installer/webtrees_installer/render.py \
    installer/tests/test_render.py installer/pyproject.toml
git -C /volume2/docker/webtrees commit -m "$(cat <<'EOF'
Render compose.yaml + .env from the input model

render_files() validates the RenderInput (edition, proxy mode, admin
toggles), pulls the default PhpEntry from the bundled catalog, and
fills the right Jinja template. StrictUndefined makes any forgotten
variable surface as an exception instead of an empty string in the
shipped compose.yaml.
EOF
)"
```

### Acceptance criteria

- `pytest installer/tests/test_render.py -v` passes 5 tests.
- Rendered standalone compose has `ports: ["${APP_PORT:-...}:80"]` on nginx.
- Rendered Traefik compose has the external `traefik` network and the Host-label rule.

---

## Task 9: Standalone-flow orchestrator + secrets helper

**Files:**
- Create: `installer/webtrees_installer/secrets.py`
- Create: `installer/webtrees_installer/flow.py`
- Modify: `installer/webtrees_installer/cli.py` (wire up flow + non-interactive flags)
- Create: `installer/tests/test_secrets.py`
- Create: `installer/tests/test_flow.py`
- Modify: `installer/tests/test_cli.py`

### Goal

A `flow.run_standalone(args)` function chains prereq checks, all prompts, the renderer, and the (optional) `docker compose up`. The CLI exposes every prompt as a flag for non-interactive use. After this task the wizard is end-to-end functional except for the stack-up wait, which Task 10 layers on.

### Steps

- [ ] **Step 9.1: Write failing tests for the secrets helper**

`installer/tests/test_secrets.py`:

```python
"""Tests for the secrets helper."""

from webtrees_installer.secrets import generate_password


def test_generate_password_is_random() -> None:
    """Two consecutive calls produce distinct values."""
    assert generate_password() != generate_password()


def test_generate_password_length() -> None:
    """Default length is 24 hex chars = 96 bits of entropy."""
    assert len(generate_password()) == 24


def test_generate_password_custom_length() -> None:
    assert len(generate_password(length=32)) == 32
```

- [ ] **Step 9.2: Run, confirm failure**

```bash
docker run --rm -v "$PWD/installer:/installer" -w /installer python:3.12-alpine \
    sh -c "pip install -e .[test] >/dev/null && pytest tests/test_secrets.py -v"
```

Expected: ImportError.

- [ ] **Step 9.3: Implement `secrets.py`**

`installer/webtrees_installer/secrets.py`:

```python
"""Random password generation for the admin reveal banner."""

from __future__ import annotations

import secrets


def generate_password(*, length: int = 24) -> str:
    """Return a hex string of `length` characters (length * 4 bits of entropy)."""
    if length <= 0 or length % 2 != 0:
        raise ValueError("length must be an even positive integer")
    return secrets.token_hex(length // 2)
```

- [ ] **Step 9.4: Re-run, confirm pass**

```bash
docker run --rm -v "$PWD/installer:/installer" -w /installer python:3.12-alpine \
    sh -c "pip install -e .[test] >/dev/null && pytest tests/test_secrets.py -v"
```

Expected: 3 passed.

- [ ] **Step 9.5: Write failing tests for the flow orchestrator**

`installer/tests/test_flow.py`:

```python
"""Tests for the standalone-flow orchestrator."""

from __future__ import annotations

from io import StringIO
from pathlib import Path
from unittest.mock import patch

import pytest
import yaml

from webtrees_installer.flow import StandaloneArgs, run_standalone


@pytest.fixture(autouse=True)
def silence_prereq_and_docker() -> None:
    """Flow tests stub the prereq check and the docker volume pre-seed."""
    with patch("webtrees_installer.flow.check_prerequisites"), \
         patch("webtrees_installer.flow._write_admin_password_secret") as ws:
        # Forward to a lightweight version that only drops the /work file,
        # skipping the docker volume create + ephemeral container.
        def fake(*, work_dir: Path, password: str) -> None:
            (work_dir / ".webtrees-admin-password").write_text(password + "\n")
        ws.side_effect = fake
        yield


def _args(**overrides) -> StandaloneArgs:
    """Build a StandaloneArgs with non-interactive defaults that exercise the happy path."""
    defaults = dict(
        work_dir=None,  # filled by tests with tmp_path
        interactive=False,
        edition="full",
        proxy_mode="standalone",
        app_port=8080,
        domain=None,
        admin_bootstrap=True,
        admin_user="admin",
        admin_email="admin@example.org",
        force=True,
        no_up=True,
    )
    defaults.update(overrides)
    return StandaloneArgs(**defaults)


def test_run_standalone_writes_compose_and_env(tmp_path: Path) -> None:
    args = _args(work_dir=tmp_path)
    with patch("webtrees_installer.flow.probe_port") as probe:
        probe.return_value = __import__(
            "webtrees_installer.ports", fromlist=["PortStatus"]
        ).PortStatus.FREE
        exit_code = run_standalone(args, stdin=StringIO(), stdout=StringIO())

    assert exit_code == 0
    assert (tmp_path / "compose.yaml").is_file()
    assert (tmp_path / ".env").is_file()

    compose = yaml.safe_load((tmp_path / "compose.yaml").read_text())
    assert "/php-full:" in compose["services"]["phpfpm"]["image"]


def test_run_standalone_reveals_admin_password(tmp_path: Path) -> None:
    args = _args(work_dir=tmp_path)
    out = StringIO()
    with patch("webtrees_installer.flow.probe_port") as probe:
        probe.return_value = __import__(
            "webtrees_installer.ports", fromlist=["PortStatus"]
        ).PortStatus.FREE
        run_standalone(args, stdin=StringIO(), stdout=out)

    body = out.getvalue()
    # The banner mentions the admin user and a hex token of length 24.
    assert "admin" in body
    import re
    assert re.search(r"[0-9a-f]{24}", body), body


def test_run_standalone_writes_admin_password_to_secrets_init(tmp_path: Path) -> None:
    """The generated password is fed into compose.yaml via /secrets/wt_admin_password,
    so the wizard reveals it once and the init service is unchanged across runs."""
    args = _args(work_dir=tmp_path)
    with patch("webtrees_installer.flow.probe_port") as probe:
        probe.return_value = __import__(
            "webtrees_installer.ports", fromlist=["PortStatus"]
        ).PortStatus.FREE
        run_standalone(args, stdin=StringIO(), stdout=StringIO())

    compose_text = (tmp_path / "compose.yaml").read_text()
    assert "/secrets/wt_admin_password" in compose_text
    assert "WT_ADMIN_PASSWORD_FILE" in compose_text


def test_run_standalone_aborts_on_existing_file_without_force(tmp_path: Path) -> None:
    (tmp_path / "compose.yaml").write_text("# existing")
    args = _args(work_dir=tmp_path, force=False)

    from webtrees_installer.prereq import PrereqError
    with pytest.raises(PrereqError):
        run_standalone(args, stdin=StringIO(), stdout=StringIO())


def test_run_standalone_port_in_use_falls_back_to_8080(tmp_path: Path) -> None:
    """Non-interactive flow: port 80 IN_USE → wizard reports + bumps to 8080."""
    args = _args(work_dir=tmp_path, app_port=80)
    from webtrees_installer.ports import PortStatus

    side_effects = iter([PortStatus.IN_USE, PortStatus.FREE])
    with patch("webtrees_installer.flow.probe_port", side_effect=lambda p: next(side_effects)):
        out = StringIO()
        exit_code = run_standalone(args, stdin=StringIO(), stdout=out)

    assert exit_code == 0
    compose_text = (tmp_path / "compose.yaml").read_text()
    assert "8080:80" in compose_text
    assert "8080" in (tmp_path / ".env").read_text()
```

- [ ] **Step 9.6: Run, confirm failure**

```bash
docker run --rm -v "$PWD/installer:/installer" -w /installer python:3.12-alpine \
    sh -c "pip install -e .[test] >/dev/null && pytest tests/test_flow.py -v"
```

Expected: ImportError on `webtrees_installer.flow`.

- [ ] **Step 9.7: Implement `flow.py`**

`installer/webtrees_installer/flow.py`:

```python
"""Standalone-mode flow orchestrator."""

from __future__ import annotations

import os
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import IO

from webtrees_installer.ports import PortStatus, probe_port
from webtrees_installer.prereq import (
    PrereqError,
    check_prerequisites,
    confirm_overwrite,
)
from webtrees_installer.prompts import (
    Choice,
    ask_choice,
    ask_text,
    ask_yesno,
)
from webtrees_installer.render import RenderInput, render_files
from webtrees_installer.secrets import generate_password
from webtrees_installer.versions import load_catalog


@dataclass(frozen=True)
class StandaloneArgs:
    """All inputs the standalone flow needs from the CLI layer."""

    work_dir: Path | None
    interactive: bool

    edition: str | None
    proxy_mode: str | None
    app_port: int | None
    domain: str | None
    admin_bootstrap: bool | None
    admin_user: str | None
    admin_email: str | None

    force: bool
    no_up: bool


_FALLBACK_PORT = 8080
_MANIFEST_DIR = Path(
    os.environ.get("WEBTREES_INSTALLER_MANIFEST_DIR", "/opt/installer/versions")
)


def run_standalone(
    args: StandaloneArgs,
    *,
    stdin: IO[str] | None = None,
    stdout: IO[str] | None = None,
) -> int:
    """Drive the standalone-flow end to end. Returns process exit code."""
    work_dir = args.work_dir or Path("/work")

    check_prerequisites(work_dir=work_dir)

    if not confirm_overwrite(
        work_dir=work_dir,
        interactive=args.interactive,
        force=args.force,
        stdin=stdin,
        stdout=stdout,
    ):
        if stdout:
            print("Aborted (existing files preserved).", file=stdout)
        return 1

    edition = ask_choice(
        "Which edition?",
        choices=[
            Choice("core", "Core (plain webtrees)"),
            Choice("full", "Full (with Magic Sunday charts)"),
        ],
        default="full",
        value=args.edition,
        stdin=stdin,
        stdout=stdout,
    )

    proxy_mode = ask_choice(
        "Reverse-proxy mode?",
        choices=[
            Choice("standalone", "Standalone (no proxy)"),
            Choice("traefik", "Behind Traefik"),
        ],
        default="standalone",
        value=args.proxy_mode,
        stdin=stdin,
        stdout=stdout,
    )

    app_port: int | None = None
    domain: str | None = None
    if proxy_mode == "standalone":
        app_port = _resolve_port(args, stdin=stdin, stdout=stdout)
    else:
        domain = ask_text(
            "Public domain (e.g. webtrees.example.org)",
            default=None,
            value=args.domain,
            stdin=stdin,
            stdout=stdout,
        )

    admin_bootstrap = ask_yesno(
        "Create an admin user automatically?",
        default=True,
        value=args.admin_bootstrap,
        stdin=stdin,
        stdout=stdout,
    )
    admin_user: str | None = None
    admin_email: str | None = None
    admin_password: str | None = None
    if admin_bootstrap:
        admin_user = ask_text(
            "Admin username",
            default="admin",
            value=args.admin_user,
            stdin=stdin,
            stdout=stdout,
        )
        admin_email = ask_text(
            "Admin email",
            default="admin@example.org",
            value=args.admin_email,
            stdin=stdin,
            stdout=stdout,
        )
        admin_password = generate_password()

    catalog = load_catalog(_MANIFEST_DIR)
    render_input = RenderInput(
        edition=edition,
        proxy_mode=proxy_mode,
        app_port=app_port,
        domain=domain,
        admin_bootstrap=admin_bootstrap,
        admin_user=admin_user,
        admin_email=admin_email,
        catalog=catalog,
        generated_at=datetime.now(tz=timezone.utc),
    )
    render_files(render_input, target_dir=work_dir)

    if admin_password is not None:
        _write_admin_password_secret(work_dir=work_dir, password=admin_password)

    _print_banner(
        stdout=stdout,
        work_dir=work_dir,
        proxy_mode=proxy_mode,
        app_port=app_port,
        domain=domain,
        admin_user=admin_user,
        admin_password=admin_password,
        no_up=args.no_up,
    )

    return 0


def _resolve_port(
    args: StandaloneArgs,
    *,
    stdin: IO[str] | None,
    stdout: IO[str] | None,
) -> int:
    """Ask for the port, probe it, fall back to 8080 if busy, downgrade to warn if probe fails."""
    requested = ask_text(
        "Host port for the webtrees UI",
        default="80",
        value=str(args.app_port) if args.app_port is not None else None,
        stdin=stdin,
        stdout=stdout,
    )
    try:
        port = int(requested)
    except ValueError as exc:
        raise PrereqError(f"port must be numeric: {requested!r}") from exc

    status = probe_port(port)
    if status is PortStatus.FREE:
        return port
    if status is PortStatus.CHECK_FAILED:
        if stdout:
            print(
                f"Warning: could not probe port {port}; proceeding regardless.",
                file=stdout,
            )
        return port

    # IN_USE → fall back to 8080 if free, else error out.
    if stdout:
        print(
            f"Port {port} is in use; trying {_FALLBACK_PORT} instead.",
            file=stdout,
        )
    fallback_status = probe_port(_FALLBACK_PORT)
    if fallback_status is PortStatus.FREE:
        return _FALLBACK_PORT
    raise PrereqError(
        f"port {port} is in use and fallback {_FALLBACK_PORT} is too; "
        "pass --port to pick a free one"
    )


def _write_admin_password_secret(*, work_dir: Path, password: str) -> None:
    """Pre-seed the secrets volume with the wizard's admin password.

    The init container's command checks `[ -s "/secrets/wt_admin_password" ]`
    and only generates a fresh password if the file is empty. By creating the
    project-scoped volume (`webtrees_secrets`) up-front and writing the
    password through an ephemeral alpine container, the init step finds the
    file already populated and leaves it alone — which means the password the
    wizard shows in the banner is the one the bootstrap hook will use.
    """
    project = _project_name(work_dir)
    volume = f"{project}_secrets"

    # Create the volume (idempotent — `docker volume create X` succeeds even if X exists).
    subprocess.run(
        ["docker", "volume", "create", volume],
        check=True, capture_output=True, text=True,
    )

    # Write the password via an ephemeral alpine. `tee` from stdin avoids
    # quoting issues that arise when embedding the hex string in an inline sh -c.
    subprocess.run(
        [
            "docker", "run", "--rm", "-i",
            "-v", f"{volume}:/secrets",
            "alpine:3.20",
            "sh", "-ec",
            "umask 077 && cat > /secrets/wt_admin_password && chmod 444 /secrets/wt_admin_password",
        ],
        input=password,
        check=True, capture_output=True, text=True,
    )

    # Keep a copy in /work for the user's reference. The banner already prints
    # the password once, but a file is forgiving for users who scroll past.
    secret_file = work_dir / ".webtrees-admin-password"
    secret_file.write_text(password + "\n")
    try:
        secret_file.chmod(0o600)
    except OSError:
        pass


def _project_name(work_dir: Path) -> str:
    """Mirror the COMPOSE_PROJECT_NAME the wizard writes into .env.

    Compose v2 derives the project name from .env when present; the rendered
    .env always sets COMPOSE_PROJECT_NAME=webtrees, so the secrets volume is
    `webtrees_secrets` regardless of work_dir's basename.
    """
    return "webtrees"


def _print_banner(
    *,
    stdout: IO[str] | None,
    work_dir: Path,
    proxy_mode: str,
    app_port: int | None,
    domain: str | None,
    admin_user: str | None,
    admin_password: str | None,
    no_up: bool,
) -> None:
    if stdout is None:
        return

    bar = "-" * 60
    print(bar, file=stdout)
    print("Webtrees install ready.", file=stdout)
    print(bar, file=stdout)
    print(f"Wrote: {work_dir / 'compose.yaml'}", file=stdout)
    print(f"Wrote: {work_dir / '.env'}", file=stdout)

    if proxy_mode == "standalone":
        print(f"Webtrees URL: http://localhost:{app_port}/", file=stdout)
    else:
        print(f"Webtrees URL: https://{domain}/", file=stdout)

    if admin_user is not None:
        print(file=stdout)
        print(f"Admin user:     {admin_user}", file=stdout)
        print(f"Admin password: {admin_password}", file=stdout)
        print(
            "(Password saved to .webtrees-admin-password for reference; "
            "remove the file after first login.)",
            file=stdout,
        )

    print(file=stdout)
    if no_up:
        print("Next: docker compose up -d", file=stdout)
    else:
        print("Starting the stack now (docker compose up -d).", file=stdout)
    print(bar, file=stdout)
```

- [ ] **Step 9.8: Wire the flow into the CLI**

Replace `installer/webtrees_installer/cli.py`:

```python
"""Command-line entry point for webtrees-installer."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Sequence

from webtrees_installer import __version__
from webtrees_installer.flow import StandaloneArgs, run_standalone
from webtrees_installer.prereq import PrereqError
from webtrees_installer.prompts import PromptError


def build_parser() -> argparse.ArgumentParser:
    """Return the top-level argument parser."""
    parser = argparse.ArgumentParser(
        prog="webtrees-installer",
        description="Wizard for setting up a self-hosted webtrees stack.",
    )
    parser.add_argument(
        "--version", action="version", version=f"webtrees-installer {__version__}",
    )
    parser.add_argument(
        "--non-interactive",
        action="store_true",
        help="Skip prompts; every required answer must be passed as a flag.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite existing compose.yaml / .env without prompting.",
    )
    parser.add_argument(
        "--work-dir",
        type=Path,
        default=Path("/work"),
        help="Target directory for the generated files (default: /work).",
    )
    parser.add_argument(
        "--edition",
        choices=["core", "full"],
        help="Image edition to write into compose.yaml.",
    )
    parser.add_argument(
        "--proxy",
        choices=["standalone", "traefik"],
        dest="proxy_mode",
        help="Reverse-proxy mode (default: standalone).",
    )
    parser.add_argument(
        "--port",
        type=int,
        dest="app_port",
        help="Host port for nginx (standalone mode only).",
    )
    parser.add_argument(
        "--domain",
        help="Public domain (Traefik mode only).",
    )
    parser.add_argument(
        "--admin-user",
        help="Username for the headless admin-bootstrap.",
    )
    parser.add_argument(
        "--admin-email",
        help="Email for the headless admin-bootstrap.",
    )
    parser.add_argument(
        "--no-admin",
        action="store_true",
        help="Skip the admin-bootstrap; rely on the browser setup wizard.",
    )
    parser.add_argument(
        "--no-up",
        action="store_true",
        help="Write files but do not run `docker compose up -d`.",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """CLI entry point. Returns the process exit code."""
    parser = build_parser()
    args = parser.parse_args(argv)

    admin_bootstrap: bool | None
    if args.no_admin:
        admin_bootstrap = False
    elif args.admin_user is not None:
        admin_bootstrap = True
    else:
        admin_bootstrap = None  # ask

    flow_args = StandaloneArgs(
        work_dir=args.work_dir,
        interactive=not args.non_interactive,
        edition=args.edition,
        proxy_mode=args.proxy_mode,
        app_port=args.app_port,
        domain=args.domain,
        admin_bootstrap=admin_bootstrap,
        admin_user=args.admin_user,
        admin_email=args.admin_email,
        force=args.force,
        no_up=args.no_up,
    )

    try:
        return run_standalone(flow_args)
    except (PrereqError, PromptError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
```

- [ ] **Step 9.9: Update test_cli.py for the expanded surface**

Replace `installer/tests/test_cli.py`:

```python
"""CLI smoke tests."""

from webtrees_installer import __version__
from webtrees_installer.cli import build_parser, main


def test_version_flag_prints_version(capsys):
    """--version prints the package version and exits 0."""
    exit_code = main(["--version"])
    captured = capsys.readouterr()

    assert exit_code == 0
    assert __version__ in captured.out


def test_parser_carries_all_non_interactive_flags():
    """Every non-interactive flag is present so the smoke-test CI job can drive it."""
    parser = build_parser()
    args = parser.parse_args(
        [
            "--non-interactive",
            "--force",
            "--no-up",
            "--no-admin",
            "--edition", "core",
            "--proxy", "standalone",
            "--port", "8080",
        ]
    )
    assert args.non_interactive is True
    assert args.force is True
    assert args.no_up is True
    assert args.no_admin is True
    assert args.edition == "core"
    assert args.proxy_mode == "standalone"
    assert args.app_port == 8080
```

- [ ] **Step 9.10: Run, confirm pass**

```bash
docker run --rm -v "$PWD/installer:/installer" -w /installer python:3.12-alpine \
    sh -c "pip install -e .[test] >/dev/null && pytest tests/ -v"
```

Expected: all tests pass (flow tests pick up the orchestrator end-to-end).

- [ ] **Step 9.11: Commit**

```bash
git -C /volume2/docker/webtrees add installer/
git -C /volume2/docker/webtrees commit -m "$(cat <<'EOF'
Wire the standalone flow end to end

flow.run_standalone() drives prereq checks, prompts, port probing,
template rendering, and the password reveal in one pass. Every prompt
accepts a non-interactive override via the matching CLI flag, so the
smoke-test in CI can call the installer without a TTY. Existing files
are guarded behind --force; port collisions fall back to 8080, and an
unprobable port downgrades to a warning per spec.
EOF
)"
```

### Acceptance criteria

- `pytest installer/tests/ -v` passes every test in the suite.
- `docker run --rm -v "$PWD:/work" webtrees-installer:local --non-interactive --force --no-up --edition core --proxy standalone --port 8080 --no-admin` succeeds and writes valid YAML.

---

## Task 10: Stack-up + healthcheck wait

**Files:**
- Create: `installer/webtrees_installer/stack.py`
- Create: `installer/tests/test_stack.py`
- Modify: `installer/webtrees_installer/flow.py` (call `stack.bring_up` when `no_up=False`)

### Goal

When `--no-up` is **not** set, the wizard calls `docker compose up -d` in `/work` and waits for the nginx healthcheck to report `healthy` with a 120-second timeout. On timeout it dumps `docker compose logs --tail=200` and returns exit code 3.

### Steps

- [ ] **Step 10.1: Write failing tests**

`installer/tests/test_stack.py`:

```python
"""Tests for stack.py — docker compose up + healthcheck wait."""

from __future__ import annotations

import subprocess
from pathlib import Path
from unittest.mock import patch

import pytest

from webtrees_installer.stack import StackError, bring_up


def _completed(stdout: str = "", returncode: int = 0) -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess(
        args=[], returncode=returncode, stdout=stdout, stderr=""
    )


def test_bring_up_calls_compose_up(tmp_path: Path) -> None:
    """bring_up issues `docker compose up -d` in work_dir."""
    with patch("webtrees_installer.stack._compose") as compose:
        compose.side_effect = [
            _completed(),                       # up -d
            _completed(stdout="healthy\n"),     # inspect health
        ]
        bring_up(work_dir=tmp_path, timeout_s=10, poll_interval_s=0.01)

    first_call = compose.call_args_list[0]
    assert first_call.args[0] == ["compose", "up", "-d"]
    assert first_call.kwargs["cwd"] == tmp_path


def test_bring_up_waits_until_healthy(tmp_path: Path) -> None:
    """Polling sees 'starting' twice then 'healthy' — returns normally."""
    with patch("webtrees_installer.stack._compose") as compose:
        compose.side_effect = [
            _completed(),                        # up -d
            _completed(stdout="starting\n"),     # inspect 1
            _completed(stdout="starting\n"),     # inspect 2
            _completed(stdout="healthy\n"),      # inspect 3
        ]
        bring_up(work_dir=tmp_path, timeout_s=10, poll_interval_s=0.01)


def test_bring_up_times_out(tmp_path: Path) -> None:
    """All polls return 'starting' → StackError."""
    with patch("webtrees_installer.stack._compose") as compose:
        compose.return_value = _completed(stdout="starting\n")
        with pytest.raises(StackError, match="not become healthy"):
            bring_up(work_dir=tmp_path, timeout_s=0.05, poll_interval_s=0.01)


def test_bring_up_propagates_compose_failure(tmp_path: Path) -> None:
    """`docker compose up -d` failing → StackError with the stderr blob."""
    with patch("webtrees_installer.stack._compose") as compose:
        compose.return_value = subprocess.CompletedProcess(
            args=[], returncode=1, stdout="", stderr="image pull failed",
        )
        with pytest.raises(StackError, match="image pull failed"):
            bring_up(work_dir=tmp_path, timeout_s=10, poll_interval_s=0.01)
```

- [ ] **Step 10.2: Run, confirm failure**

```bash
docker run --rm -v "$PWD/installer:/installer" -w /installer python:3.12-alpine \
    sh -c "pip install -e .[test] >/dev/null && pytest tests/test_stack.py -v"
```

Expected: ImportError on `webtrees_installer.stack`.

- [ ] **Step 10.3: Implement `stack.py`**

`installer/webtrees_installer/stack.py`:

```python
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
```

- [ ] **Step 10.4: Re-run stack tests, confirm pass**

```bash
docker run --rm -v "$PWD/installer:/installer" -w /installer python:3.12-alpine \
    sh -c "pip install -e .[test] >/dev/null && pytest tests/test_stack.py -v"
```

Expected: 4 passed.

- [ ] **Step 10.5: Wire `bring_up` into `flow.py`**

In `installer/webtrees_installer/flow.py`, modify `run_standalone` to call `bring_up` when `args.no_up` is False. Add at top of file:

```python
from webtrees_installer.stack import StackError, bring_up
```

Replace the section after `_print_banner(...)` with:

```python
    _print_banner(
        stdout=stdout,
        work_dir=work_dir,
        proxy_mode=proxy_mode,
        app_port=app_port,
        domain=domain,
        admin_user=admin_user,
        admin_password=admin_password,
        no_up=args.no_up,
    )

    if not args.no_up:
        try:
            bring_up(work_dir=work_dir)
        except StackError as exc:
            if stdout:
                print(f"error: {exc}", file=stdout)
            return 3

    return 0
```

- [ ] **Step 10.6: Add an integration test that exercises the wiring**

Append to `installer/tests/test_flow.py`:

```python
def test_run_standalone_invokes_bring_up_when_not_no_up(tmp_path: Path) -> None:
    """no_up=False → flow calls stack.bring_up."""
    args = _args(work_dir=tmp_path, no_up=False)
    from webtrees_installer.ports import PortStatus
    with patch("webtrees_installer.flow.probe_port", return_value=PortStatus.FREE), \
         patch("webtrees_installer.flow.bring_up") as bring_up_mock:
        exit_code = run_standalone(args, stdin=StringIO(), stdout=StringIO())

    assert exit_code == 0
    bring_up_mock.assert_called_once()
    assert bring_up_mock.call_args.kwargs["work_dir"] == tmp_path
```

- [ ] **Step 10.7: Run full suite, confirm pass**

```bash
docker run --rm -v "$PWD/installer:/installer" -w /installer python:3.12-alpine \
    sh -c "pip install -e .[test] >/dev/null && pytest tests/ -v"
```

Expected: every test passes.

- [ ] **Step 10.8: Commit**

```bash
git -C /volume2/docker/webtrees add installer/webtrees_installer/stack.py \
    installer/webtrees_installer/flow.py installer/tests/test_stack.py \
    installer/tests/test_flow.py
git -C /volume2/docker/webtrees commit -m "$(cat <<'EOF'
Bring the stack up and wait for nginx health

bring_up() runs `docker compose up -d` from the generated /work
directory and polls `docker compose ps --format {{.Health}} nginx`
every two seconds. On timeout it dumps `compose logs --tail=200` so
the user has something to chew on without a separate command. The
flow respects --no-up for CI smoke-tests where the assertion is in a
separate step.
EOF
)"
```

### Acceptance criteria

- `pytest installer/tests/ -v` passes the full suite.
- `bring_up` raises `StackError` with the captured logs on timeout.
- The flow skips the stack-up call when `no_up=True`.

---

## Task 11: CI — build-installer job + smoke-test rewrite

**Files:**
- Modify: `.github/workflows/build.yml`

### Goal

The build workflow learns to publish `ghcr.io/magicsunday/webtrees/installer:<tag>` and the smoke-test job switches from inlining `.env` by hand to invoking the installer (the same way a real user would).

### Steps

- [ ] **Step 11.1: Inspect the current workflow**

Read `.github/workflows/build.yml` end-to-end. Identify the `matrix` job's outputs (currently `php_entries`, `nginx_tag`, `nginx_config_revision`) and the smoke-test's existing structure.

- [ ] **Step 11.2: Extend the matrix job to emit the installer tag**

In the `matrix` job's run-step, after computing `nginx_tag`, add:

```yaml
              installer_tag=$(jq -r .tag dev/installer-version.json)
              echo "installer_tag=${installer_tag}" >> "$GITHUB_OUTPUT"
```

And in the `outputs:` block add:

```yaml
              installer_tag: ${{ steps.collect.outputs.installer_tag }}
```

- [ ] **Step 11.3: Add the `build-installer` job**

Place after `build-nginx`:

```yaml
    build-installer:
        name: installer ${{ needs.matrix.outputs.installer_tag }}
        needs: matrix
        runs-on: ubuntu-latest
        permissions:
            contents: read
            packages: write
        steps:
            - uses: actions/checkout@v4

            - uses: docker/setup-qemu-action@v3
            - uses: docker/setup-buildx-action@v3

            - uses: docker/login-action@v3
              with:
                  registry: ghcr.io
                  username: ${{ github.actor }}
                  password: ${{ secrets.GITHUB_TOKEN }}

            - name: Build and push
              uses: docker/build-push-action@v5
              with:
                  context: .
                  file: installer/Dockerfile
                  platforms: linux/amd64,linux/arm64
                  push: true
                  tags: |
                      ghcr.io/magicsunday/webtrees/installer:${{ needs.matrix.outputs.installer_tag }}
                      ghcr.io/magicsunday/webtrees/installer:latest
                  cache-from: type=gha,scope=installer
                  cache-to: type=gha,scope=installer,mode=max
```

- [ ] **Step 11.4: Make the smoke-test depend on the installer**

Adjust the `smoke-test` job header:

```yaml
    smoke-test:
        name: smoke ${{ matrix.edition }} ${{ matrix.entry.webtrees }}-${{ matrix.entry.php }}
        needs: [matrix, build-php, build-php-full, build-nginx, build-installer]
```

- [ ] **Step 11.5: Replace the smoke-test's "Prepare .env" step with an installer invocation**

Drop the heredoc `.env` block and the optional `compose.override.yaml`. Replace those steps with:

```yaml
            - name: Run installer (non-interactive)
              env:
                  EDITION: ${{ matrix.edition }}
                  INSTALLER_TAG: ${{ needs.matrix.outputs.installer_tag }}
              run: |
                  set -euo pipefail
                  mkdir -p /tmp/smoke
                  docker run --rm \
                      -v /tmp/smoke:/work \
                      -v /var/run/docker.sock:/var/run/docker.sock \
                      "ghcr.io/magicsunday/webtrees/installer:${INSTALLER_TAG}" \
                      --non-interactive \
                      --force \
                      --no-up \
                      --no-admin \
                      --edition "${EDITION}" \
                      --proxy standalone \
                      --port 18080

            - name: Up stack
              working-directory: /tmp/smoke
              run: docker compose up -d
```

Then update the subsequent steps to use `working-directory: /tmp/smoke`:

```yaml
            - name: Wait for nginx healthy
              working-directory: /tmp/smoke
              run: |
                  set -euo pipefail
                  for i in $(seq 1 60); do
                      health=$(docker inspect --format='{{.State.Health.Status}}' "$(docker compose ps -q nginx)" 2>/dev/null || echo starting)
                      if [ "$health" = "healthy" ]; then
                          echo "nginx healthy after ${i}s"
                          exit 0
                      fi
                      sleep 1
                  done
                  echo "::error::nginx did not become healthy within 60s"
                  docker compose logs --tail=200
                  exit 1

            - name: Probe HTTP
              working-directory: /tmp/smoke
              run: |
                  set -euo pipefail
                  body=$(curl -fsSL http://localhost:18080/)
                  echo "$body" | head -50
                  echo "$body" | grep -qi "webtrees" || {
                      echo "::error::response body does not mention 'webtrees'"
                      exit 1
                  }

            - name: Tear down
              if: always()
              working-directory: /tmp/smoke
              run: docker compose down -v
```

- [ ] **Step 11.6: Local lint of the workflow file**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest
```

Expected: no errors.

If actionlint is unavailable, fall back to `python -c "import yaml; yaml.safe_load(open('.github/workflows/build.yml'))"` inside an Alpine container.

- [ ] **Step 11.7: Commit**

```bash
git -C /volume2/docker/webtrees add .github/workflows/build.yml
git -C /volume2/docker/webtrees commit -m "$(cat <<'EOF'
Build the installer image in CI and have the smoke-test use it

A new build-installer job pushes the installer image alongside the
existing php / php-full / nginx jobs. The smoke-test stops hand-rolling
its .env file and instead drives the wizard non-interactively against
a temp /tmp/smoke directory, exercising the same code path real users
hit and surfacing regressions in flow.py before they leak to release.
EOF
)"
```

### Acceptance criteria

- `actionlint .github/workflows/build.yml` (or PyYAML parse) reports no errors.
- The workflow has a new `build-installer` job and the smoke-test no longer hand-writes `.env`.

---

## Task 12: E2E local verification + spec/plan sync

**Files:**
- Read-only verification first
- Modify: `docs/superpowers/specs/2026-05-11-out-of-the-box-self-host-design.md` (sync if implementation drifted)

### Goal

Build the installer image locally, drive it against an isolated /tmp work directory, bring the stack up, hit the URL, and verify both editions render an HTTP 200 with "webtrees" in the body. Then sync the spec to reflect any deltas. The user's live dev stack at `/volume2/docker/webtrees` must remain untouched.

### Steps

- [ ] **Step 12.1: Build the installer locally**

```bash
docker build -f installer/Dockerfile -t webtrees-installer:phase2a /volume2/docker/webtrees
docker run --rm webtrees-installer:phase2a --version
```

Expected: `webtrees-installer 0.1.0`.

- [ ] **Step 12.2: Run the wizard non-interactively against an isolated /work**

```bash
WORK=$(mktemp -d /tmp/wt-phase2a-XXXXXX)
docker run --rm \
    -v "$WORK:/work" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    webtrees-installer:phase2a \
    --non-interactive \
    --force \
    --no-up \
    --no-admin \
    --edition core \
    --proxy standalone \
    --port 18890
ls -la "$WORK"
cat "$WORK/compose.yaml" | head -30
cat "$WORK/.env"
```

Expected: `compose.yaml` and `.env` exist; the compose `phpfpm.image` is `ghcr.io/magicsunday/webtrees/php:<wt>-php<x>` (no `-full`); `.env` carries `APP_PORT=18890`.

- [ ] **Step 12.3: Bring the isolated stack up + smoke-probe**

```bash
cd "$WORK"
COMPOSE_PROJECT_NAME=wtphase2a docker compose up -d
for i in $(seq 1 60); do
    health=$(docker inspect --format='{{.State.Health.Status}}' "$(COMPOSE_PROJECT_NAME=wtphase2a docker compose ps -q nginx)" 2>/dev/null || echo starting)
    [ "$health" = "healthy" ] && { echo "healthy after ${i}s"; break; }
    sleep 1
done
curl -fsSL http://localhost:18890/ | head -10
COMPOSE_PROJECT_NAME=wtphase2a docker compose down -v
```

Expected: 200 OK with HTML mentioning "webtrees".

- [ ] **Step 12.4: Repeat for the full edition**

```bash
docker run --rm \
    -v "$WORK:/work" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    webtrees-installer:phase2a \
    --non-interactive \
    --force \
    --no-up \
    --no-admin \
    --edition full \
    --proxy standalone \
    --port 18890
grep -q "/php-full:" "$WORK/compose.yaml" || { echo "FAIL: full image not rendered"; exit 1; }
cd "$WORK"
COMPOSE_PROJECT_NAME=wtphase2a docker compose up -d
for i in $(seq 1 60); do
    health=$(docker inspect --format='{{.State.Health.Status}}' "$(COMPOSE_PROJECT_NAME=wtphase2a docker compose ps -q nginx)" 2>/dev/null || echo starting)
    [ "$health" = "healthy" ] && break
    sleep 1
done
curl -fsSL http://localhost:18890/ | head -10
COMPOSE_PROJECT_NAME=wtphase2a docker compose down -v
```

Expected: 200 OK; image tag contains `/php-full:`.

- [ ] **Step 12.5: Exercise the admin-bootstrap path**

```bash
docker run --rm \
    -v "$WORK:/work" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    webtrees-installer:phase2a \
    --non-interactive \
    --force \
    --no-up \
    --edition full \
    --proxy standalone \
    --port 18890 \
    --admin-user testadmin \
    --admin-email test@example.org
grep -q "WT_ADMIN_USER" "$WORK/compose.yaml" || { echo "FAIL: admin env var missing"; exit 1; }
test -f "$WORK/.webtrees-admin-password"
echo "admin password reference: $(cat "$WORK/.webtrees-admin-password")"
```

Expected: WT_ADMIN_USER present in compose.yaml; `.webtrees-admin-password` file exists with a hex string.

- [ ] **Step 12.6: Teardown + cleanup**

```bash
docker rmi webtrees-installer:phase2a
rm -rf "$WORK"
```

Verify the live stack is still up:

```bash
docker -C /volume2/docker/webtrees compose ps
```

Expected: original four containers still up + healthy.

- [ ] **Step 12.7: Sync the spec if anything drifted**

Re-read `docs/superpowers/specs/2026-05-11-out-of-the-box-self-host-design.md` Sections "Compose-Templates" and "Wizard-Flow". Note any details that the implementation diverged from (e.g. exact CLI flag spellings, fallback port, banner copy) and update the spec to match the code. The implementation is the source of truth at this point.

- [ ] **Step 12.8: Final commit**

```bash
git -C /volume2/docker/webtrees add docs/superpowers/specs/
git -C /volume2/docker/webtrees diff --cached --stat
git -C /volume2/docker/webtrees commit -m "$(cat <<'EOF'
Sync the Phase 2a spec with the shipped wizard

Update flag spellings, the standalone fallback port and the
banner-copy snippets to reflect what flow.run_standalone actually
emits. The Compose-Templates section already matched.
EOF
)"
```

If the spec has no drift, skip this commit and just record "no drift" in your final report.

### Acceptance criteria

- Core and Full editions both serve HTTP 200 from `curl http://localhost:18890/`.
- The admin-bootstrap wiring lands `WT_ADMIN_USER` + `WT_ADMIN_PASSWORD_FILE` in the rendered compose.yaml.
- The user's live dev stack at `/volume2/docker/webtrees` is unchanged (same uptime, same containers).
- The spec is in lockstep with the shipped wizard.

---

## Self-Review checklist

After all 12 tasks merge, walk this:

1. **Spec coverage:** Every "Wizard-Flow → Standalone-Flow" bullet maps to a step in Task 9 except demo-tree generation (out of scope, Phase 2b).
2. **Placeholder scan:** Search the plan for "TBD", "TODO", "later". None should remain.
3. **Type consistency:** `PortStatus`, `Choice`, `RenderInput`, `StandaloneArgs` are defined exactly once each, and every consumer references them by the same name.
4. **Sub-skill applies:** TDD discipline ([Test-driven development] superpower) applies to every behavioural module — flow.py, render.py, prompts.py, prereq.py, ports.py, stack.py, secrets.py. Templates (Jinja files) get covered by render.py's tests.
