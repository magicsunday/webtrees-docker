# Out-of-the-Box Self-Host Phase 2b — Dev-Flow Migration + Demo-Tree Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `scripts/setup.sh` + the dev-mode Make targets with a `webtrees-installer --mode dev` flow, add a deterministic GEDCOM demo-tree generator that the standalone flow can run on `--demo`, and rewrite the README so a Self-Hoster lands on a one-liner that just works.

**Architecture:** The dev-flow shares the wizard skeleton from Phase 2a (`prereq`, `prompts`, `render`, `flow`) but emits only `.env` (no fresh `compose.yaml` — the dev stack already uses the repo's `compose.yaml` + overlays). A new `gedcom` package generates GEDCOM 5.5.1 files in Python; the standalone-flow's `--demo` branch writes the file into `/work/demo.ged` and, when the stack is also brought up, copies it into the phpfpm container and runs `php index.php tree-import`. `scripts/setup.sh` and `Make/modes.mk` are deleted in a hard cut — the wizard is the only setup path going forward.

**Tech Stack:** Python 3.12, Jinja2 (env template), pytest (tests), `secrets`/`random.Random` for deterministic GEDCOM generation, docker CLI + Docker Compose v2 (orchestration). No new external dependencies — `gedcom-faker`/`python-gedcom` were rejected during brainstorming in favour of a ~150 LOC eigenbau serializer.

**Out of scope for 2b:** `docs/developing.md` and `docs/customizing.md` (Phase 3). `compose.dev.j2` Jinja template (the dev-flow uses the existing repo files; no fresh compose.yaml gets rendered). Anything in Cluster B/C (SQLite variant, Docker-Hub mirror, nightly builds, multiple `latest-*` tag tracks).

---

## File map

**New files:**
- `installer/webtrees_installer/templates/env.dev.j2` — `.env` template for the dev flow (full superset of the standalone env: COMPOSE_FILE chain, MARIADB_*, LOCAL_USER_*, USE_EXISTING_DB, ports, PHP tuning, etc.).
- `installer/webtrees_installer/dev_flow.py` — `DevArgs` dataclass + `run_dev(args, *, stdin, stdout) -> int`.
- `installer/webtrees_installer/gedcom.py` — `Person`/`Family` dataclasses + `GedcomDocument` builder + `serialize(doc)` returning a GEDCOM-5.5.1 string.
- `installer/webtrees_installer/demo.py` — Name pools, deterministic tree generator (`generate_tree(seed: int, population: int) -> GedcomDocument`), GEDCOM-export helper, `import_into_stack(work_dir, tree_name)` that runs `docker compose cp` + `tree-import` via the docker CLI.
- `installer/webtrees_installer/data/given_names.json` — Public-domain first-name pool (50 male + 50 female).
- `installer/webtrees_installer/data/surnames.json` — Public-domain last-name pool (100 surnames).
- `installer/tests/test_dev_flow.py`
- `installer/tests/test_gedcom.py`
- `installer/tests/test_demo.py`
- `README.md` — Phase 2b rewrites this in place (replaces the dev-centric content with a Self-Host quickstart that points the user at the `install` wrapper).

**Modified files:**
- `installer/webtrees_installer/flow.py` — extends `StandaloneArgs` with `demo: bool` field; extends `run_standalone` so that when admin-bootstrap and `--demo` are both active, a GEDCOM file is written into `/work/demo.ged` (and imported when `no_up=False`).
- `installer/webtrees_installer/cli.py` — adds `--mode {standalone,dev}` toggle, `--demo` flag, all dev-flow flags (`--mariadb-root-password`, `--mariadb-database`, `--mariadb-user`, `--mariadb-password`, `--use-existing-db`, `--use-external-db`, `--external-db-host`, `--dev-domain`).
- `installer/pyproject.toml` — `package-data` glob extended to include `data/*.json` so the bundled name pools ship with the wheel.
- `.github/workflows/build.yml` — smoke-test matrix gains a third edition `demo` that asserts the wizard writes `demo.ged` into `/work` even without bringing the stack up.

**Deleted files:**
- `scripts/setup.sh`
- `Make/modes.mk`

---

## Conventions for this plan

- All Python work runs in `python:3.12-alpine` containers per the project's "host has no Python" memory.
- `git -C /volume2/docker/webtrees` for every git invocation (bash cwd does not persist).
- Commit messages: capitalised verb, no `feat:`/`fix:` prefix, no `Co-Authored-By` trailer.
- Imports: PEP 585 (`from collections.abc import Iterable`, lowercase `list`/`dict`).
- After each task: run the test suite, dispatch the spec-compliance reviewer + code-quality reviewer, commit only when both approve.

---

## Task 1: Dev-flow .env template + DevArgs scaffold

**Files:**
- Create: `installer/webtrees_installer/templates/env.dev.j2`
- Create: `installer/webtrees_installer/dev_flow.py`
- Create: `installer/tests/test_dev_flow.py`

### Goal

A `DevArgs` dataclass and a `render_dev_env(args, target_dir)` function that produces a valid `.env` for the dev stack. The compose chain is assembled by the renderer based on `proxy_mode` and `use_external_db`. No prompts yet (Task 3); just the data structures and the renderer.

### Steps

- [ ] **Step 1.1: Create `installer/webtrees_installer/templates/env.dev.j2`:**

```ini
# Generated by webtrees-installer {{ installer_version }} on {{ generated_at }} (--mode dev).
# Edit at will; the wizard does not read this file on subsequent runs.

ENVIRONMENT=development
COMPOSE_PROJECT_NAME=webtrees

# Webtrees release + image tags
PHP_VERSION={{ php_version }}
WEBTREES_VERSION={{ webtrees_version }}
WEBTREES_NGINX_VERSION={{ nginx_tag }}
DOCKER_SERVER=ghcr.io/magicsunday

# Compose file chain assembled by the dev-flow wizard.
COMPOSE_FILE={{ compose_file_chain }}

# Reverse-proxy mode + dev domain
ENFORCE_HTTPS={% if proxy_mode == "traefik" %}TRUE{% else %}FALSE{% endif %}
DEV_DOMAIN={{ dev_domain }}

# Database
MARIADB_HOST={{ mariadb_host }}
MARIADB_PORT=3306
MARIADB_DATABASE={{ mariadb_database }}
MARIADB_USER={{ mariadb_user }}
MARIADB_PASSWORD={{ mariadb_password }}
MARIADB_ROOT_PASSWORD={{ mariadb_root_password }}
USE_EXISTING_DB={{ '1' if use_existing_db else '0' }}

# Local user (buildbox + media ownership)
LOCAL_USER_ID={{ local_user_id }}
LOCAL_USER_NAME={{ local_user_name }}
LOCAL_GROUP_ID=82
LOCAL_GROUP_NAME=www-data

# Application directories
APP_DIR=./app
MEDIA_DIR=./persistent/media
{%- if proxy_mode == "standalone" %}

# Host ports
APP_PORT={{ app_port }}
PMA_PORT={{ pma_port }}
{%- endif %}

# PHP tuning (defaults match .env.dist)
PHP_MAX_EXECUTION_TIME=30
PHP_MAX_INPUT_VARS=1000
PHP_MEMORY_LIMIT=256M
PHP_POST_MAX_SIZE=128M
PHP_UPLOAD_MAX_FILESIZE=128M

# Webtrees app
WEBTREES_TABLE_PREFIX=wt_
WEBTREES_REWRITE_URLS=0

# phpMyAdmin
UPLOAD_LIMIT=32M
```

- [ ] **Step 1.2: Write the failing test `installer/tests/test_dev_flow.py`:**

```python
"""Tests for the dev-flow renderer."""

from __future__ import annotations

from datetime import datetime
from pathlib import Path

import pytest

from webtrees_installer.dev_flow import DevArgs, build_compose_chain, render_dev_env
from webtrees_installer.versions import Catalog, PhpEntry


@pytest.fixture
def catalog() -> Catalog:
    return Catalog(
        php_entries=(PhpEntry(webtrees="2.2.6", php="8.5", tags=("latest",)),),
        nginx_tag="1.28-r1",
        installer_version="0.1.0",
    )


def _args(**overrides) -> DevArgs:
    defaults = dict(
        work_dir=None,
        interactive=False,
        proxy_mode="standalone",
        dev_domain="webtrees.localhost:50010",
        app_port=50010,
        pma_port=50011,
        mariadb_host="db",
        mariadb_database="webtrees",
        mariadb_user="webtrees",
        mariadb_password="devpw",
        mariadb_root_password="rootpw",
        use_existing_db=False,
        use_external_db=False,
        local_user_id=1000,
        local_user_name="dev",
        force=True,
    )
    defaults.update(overrides)
    return DevArgs(**defaults)


def test_build_compose_chain_standalone() -> None:
    assert (
        build_compose_chain(proxy_mode="standalone", use_external_db=False)
        == "compose.yaml:compose.pma.yaml:compose.development.yaml:compose.publish.yaml"
    )


def test_build_compose_chain_traefik() -> None:
    assert (
        build_compose_chain(proxy_mode="traefik", use_external_db=False)
        == "compose.yaml:compose.pma.yaml:compose.development.yaml:compose.traefik.yaml"
    )


def test_build_compose_chain_standalone_with_external_db() -> None:
    assert (
        build_compose_chain(proxy_mode="standalone", use_external_db=True)
        == "compose.yaml:compose.pma.yaml:compose.development.yaml:compose.publish.yaml:compose.external.yaml"
    )


def test_render_dev_env_writes_full_env(tmp_path: Path, catalog: Catalog) -> None:
    args = _args(work_dir=tmp_path)
    render_dev_env(args, catalog=catalog, target_dir=tmp_path,
                   generated_at=datetime(2026, 5, 12, 12, 0, 0))

    env = (tmp_path / ".env").read_text()
    assert "ENVIRONMENT=development" in env
    assert "COMPOSE_PROJECT_NAME=webtrees" in env
    assert "PHP_VERSION=8.5" in env
    assert "WEBTREES_VERSION=2.2.6" in env
    assert "WEBTREES_NGINX_VERSION=1.28-r1" in env
    assert "MARIADB_PASSWORD=devpw" in env
    assert "MARIADB_ROOT_PASSWORD=rootpw" in env
    assert "USE_EXISTING_DB=0" in env
    assert "LOCAL_USER_ID=1000" in env
    assert "APP_PORT=50010" in env
    assert "PMA_PORT=50011" in env
    assert "compose.publish.yaml" in env
    assert "compose.traefik.yaml" not in env
    assert "ENFORCE_HTTPS=FALSE" in env


def test_render_dev_env_traefik_drops_app_port(tmp_path: Path, catalog: Catalog) -> None:
    args = _args(work_dir=tmp_path, proxy_mode="traefik",
                 dev_domain="webtrees.example.org", app_port=None, pma_port=None)
    render_dev_env(args, catalog=catalog, target_dir=tmp_path,
                   generated_at=datetime(2026, 5, 12, 12, 0, 0))

    env = (tmp_path / ".env").read_text()
    assert "compose.traefik.yaml" in env
    assert "compose.publish.yaml" not in env
    assert "APP_PORT" not in env
    assert "PMA_PORT" not in env
    assert "ENFORCE_HTTPS=TRUE" in env


def test_render_dev_env_external_db_appends_compose_file(tmp_path: Path, catalog: Catalog) -> None:
    args = _args(work_dir=tmp_path, use_external_db=True, mariadb_host="external-db.local")
    render_dev_env(args, catalog=catalog, target_dir=tmp_path,
                   generated_at=datetime(2026, 5, 12, 12, 0, 0))

    env = (tmp_path / ".env").read_text()
    assert "compose.external.yaml" in env
    assert "MARIADB_HOST=external-db.local" in env


def test_render_dev_env_rejects_traefik_without_domain(tmp_path: Path, catalog: Catalog) -> None:
    """Traefik mode demands a non-empty dev_domain."""
    args = _args(work_dir=tmp_path, proxy_mode="traefik", dev_domain="",
                 app_port=None, pma_port=None)
    with pytest.raises(ValueError, match="dev_domain"):
        render_dev_env(args, catalog=catalog, target_dir=tmp_path,
                       generated_at=datetime(2026, 5, 12, 12, 0, 0))
```

- [ ] **Step 1.3: Run the failing test (expect ImportError on `webtrees_installer.dev_flow`):**

```bash
docker run --rm -v /volume2/docker/webtrees/installer:/installer -w /installer python:3.12-alpine \
    sh -c "pip install -e .[test] >/dev/null 2>&1 && pytest tests/test_dev_flow.py -v"
```

- [ ] **Step 1.4: Implement `installer/webtrees_installer/dev_flow.py`:**

```python
"""Dev-flow .env renderer.

The dev flow does NOT render a fresh compose.yaml — the developer stays
on the repo's compose.yaml + overlays. The wizard only emits a `.env`
that selects the right COMPOSE_FILE chain and carries DB / user / port
values so `make up` succeeds without further editing.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from jinja2 import Environment, PackageLoader, StrictUndefined

from webtrees_installer.versions import Catalog


@dataclass(frozen=True)
class DevArgs:
    """All inputs the dev flow needs from the CLI layer."""

    work_dir: Path | None
    interactive: bool

    proxy_mode: str
    dev_domain: str

    app_port: int | None
    pma_port: int | None

    mariadb_host: str
    mariadb_database: str
    mariadb_user: str
    mariadb_password: str
    mariadb_root_password: str
    use_existing_db: bool
    use_external_db: bool

    local_user_id: int
    local_user_name: str

    force: bool


def build_compose_chain(*, proxy_mode: str, use_external_db: bool) -> str:
    """Return the COMPOSE_FILE colon-chain for the chosen dev flavour."""
    chain = ["compose.yaml", "compose.pma.yaml", "compose.development.yaml"]
    if proxy_mode == "standalone":
        chain.append("compose.publish.yaml")
    elif proxy_mode == "traefik":
        chain.append("compose.traefik.yaml")
    else:
        raise ValueError(f"proxy_mode must be 'standalone' or 'traefik', got {proxy_mode!r}")
    if use_external_db:
        chain.append("compose.external.yaml")
    return ":".join(chain)


def render_dev_env(
    args: DevArgs,
    *,
    catalog: Catalog,
    target_dir: Path,
    generated_at: datetime,
) -> None:
    """Render env.dev.j2 into target_dir/.env."""
    _validate(args)

    php_entry = catalog.default_php_entry
    context = {
        "installer_version": catalog.installer_version,
        "generated_at": generated_at.isoformat(),
        "compose_file_chain": build_compose_chain(
            proxy_mode=args.proxy_mode, use_external_db=args.use_external_db,
        ),
        "proxy_mode": args.proxy_mode,
        "dev_domain": args.dev_domain,
        "app_port": args.app_port,
        "pma_port": args.pma_port,
        "php_version": php_entry.php,
        "webtrees_version": php_entry.webtrees,
        "nginx_tag": catalog.nginx_tag,
        "mariadb_host": args.mariadb_host,
        "mariadb_database": args.mariadb_database,
        "mariadb_user": args.mariadb_user,
        "mariadb_password": args.mariadb_password,
        "mariadb_root_password": args.mariadb_root_password,
        "use_existing_db": args.use_existing_db,
        "local_user_id": args.local_user_id,
        "local_user_name": args.local_user_name,
    }

    env_jinja = Environment(
        loader=PackageLoader("webtrees_installer", "templates"),
        undefined=StrictUndefined,
        keep_trailing_newline=True,
    )
    rendered = env_jinja.get_template("env.dev.j2").render(**context)

    target_dir.mkdir(parents=True, exist_ok=True)
    (target_dir / ".env").write_text(rendered)


def _validate(args: DevArgs) -> None:
    if args.proxy_mode not in {"standalone", "traefik"}:
        raise ValueError(
            f"proxy_mode must be 'standalone' or 'traefik', got {args.proxy_mode!r}"
        )
    if args.proxy_mode == "traefik" and not args.dev_domain:
        raise ValueError("traefik proxy_mode requires non-empty dev_domain")
    if args.proxy_mode == "standalone" and (args.app_port is None or args.pma_port is None):
        raise ValueError("standalone proxy_mode requires app_port and pma_port")
    if args.use_external_db and not args.mariadb_host:
        raise ValueError("use_external_db=True requires mariadb_host")
```

- [ ] **Step 1.5: Re-run the test, expect 6 passed:**

```bash
docker run --rm -v /volume2/docker/webtrees/installer:/installer -w /installer python:3.12-alpine \
    sh -c "pip install -e .[test] >/dev/null 2>&1 && pytest tests/test_dev_flow.py -v"
```

- [ ] **Step 1.6: Commit:**

```bash
git -C /volume2/docker/webtrees add installer/webtrees_installer/dev_flow.py \
    installer/webtrees_installer/templates/env.dev.j2 \
    installer/tests/test_dev_flow.py
git -C /volume2/docker/webtrees commit -m "$(cat <<'EOF'
Add dev-flow .env renderer

DevArgs carries every value the dev `.env` needs and render_dev_env
writes the file via a new env.dev.j2 template. The compose-file chain
is assembled by build_compose_chain so standalone + traefik and the
optional external-db overlay are wired in one place. No prompts yet;
later tasks layer on the interactive collector and the docker pull +
composer install orchestration.
EOF
)"
```

### Acceptance criteria

- `pytest installer/tests/test_dev_flow.py -v` passes 6 tests.
- The dev `.env` includes COMPOSE_FILE chain, MARIADB_*, LOCAL_USER_*, ports (in standalone), all PHP-tuning defaults.
- Traefik mode rejects empty `dev_domain` via `ValueError`.

---

## Task 2: Dev-flow prompts module

**Files:**
- Modify: `installer/webtrees_installer/dev_flow.py` (add `collect_dev_inputs`)
- Modify: `installer/tests/test_dev_flow.py` (add 4 prompt-collection tests)

### Goal

A `collect_dev_inputs(args, *, stdin, stdout, host_info)` helper that drives prompts for every `DevArgs` field that the CLI doesn't already supply. Mirrors `scripts/setup.sh`'s interactive_setup flow but in Python via the existing `ask_*` helpers.

### Steps

- [ ] **Step 2.1: Append failing tests to `installer/tests/test_dev_flow.py`:**

```python
from io import StringIO
from unittest.mock import patch

from webtrees_installer.dev_flow import collect_dev_inputs, HostInfo


_HOST = HostInfo(uid=1000, username="dev", primary_ip="192.168.1.50")


def test_collect_dev_inputs_standalone_default_path() -> None:
    """All defaults accepted via empty stdin lines → returns a populated DevArgs."""
    # Order of prompts: traefik? → app_port → pma_port → dev_domain → use_existing_db
    # → use_external_db → mariadb_root_password → mariadb_database → mariadb_user
    # → mariadb_password
    stdin = StringIO("\n" * 16)  # 16 newlines covers every prompt with the default
    stdout = StringIO()
    args = collect_dev_inputs(
        work_dir=Path("/work"), force=False,
        existing={},
        host_info=_HOST,
        stdin=stdin, stdout=stdout,
    )
    assert args.proxy_mode == "standalone"
    assert args.app_port == 50010
    assert args.pma_port == 50011
    assert args.dev_domain == "192.168.1.50:50010"
    assert args.use_existing_db is False
    assert args.use_external_db is False
    assert args.mariadb_host == "db"
    assert args.local_user_id == 1000
    assert args.local_user_name == "dev"


def test_collect_dev_inputs_traefik_uses_dev_domain() -> None:
    """traefik branch skips port prompts and uses dev_domain only."""
    # Prompts after traefik=Y: dev_domain → use_existing → use_external → 4× db creds.
    stdin = StringIO("y\nwebtrees.example.com\n\n\nrootpw\nwt\nwt_user\nwt_pw\n")
    stdout = StringIO()
    args = collect_dev_inputs(
        work_dir=Path("/work"), force=False,
        existing={},
        host_info=_HOST,
        stdin=stdin, stdout=stdout,
    )
    assert args.proxy_mode == "traefik"
    assert args.dev_domain == "webtrees.example.com"
    assert args.app_port is None
    assert args.pma_port is None
    assert args.mariadb_root_password == "rootpw"
    assert args.mariadb_user == "wt_user"


def test_collect_dev_inputs_external_db_asks_host() -> None:
    """use_external_db=Y triggers the mariadb_host prompt."""
    # Standalone, defaults for ports + domain, default no on existing-db,
    # YES on external-db, host=external-db.local, then 4× db creds.
    stdin = StringIO(
        "\n"                            # traefik? N
        "\n\n\n"                        # app/pma/dev_domain defaults
        "\n"                            # use_existing_db default N
        "y\n"                           # use_external_db Y
        "external-db.local\n"           # mariadb_host
        "rootpw\nwt\nwt_user\nwt_pw\n"  # creds
    )
    stdout = StringIO()
    args = collect_dev_inputs(
        work_dir=Path("/work"), force=False,
        existing={},
        host_info=_HOST,
        stdin=stdin, stdout=stdout,
    )
    assert args.use_external_db is True
    assert args.mariadb_host == "external-db.local"


def test_collect_dev_inputs_uses_existing_env_values() -> None:
    """If a previous .env exists, its values become the defaults."""
    existing = {
        "APP_PORT": "55555",
        "MARIADB_PASSWORD": "old-secret",
        "MARIADB_USER": "old_user",
    }
    stdin = StringIO("\n" * 16)
    stdout = StringIO()
    args = collect_dev_inputs(
        work_dir=Path("/work"), force=False,
        existing=existing,
        host_info=_HOST,
        stdin=stdin, stdout=stdout,
    )
    assert args.app_port == 55555
    assert args.mariadb_password == "old-secret"
    assert args.mariadb_user == "old_user"
```

- [ ] **Step 2.2: Run, confirm ImportError on `HostInfo` and `collect_dev_inputs`:**

```bash
docker run --rm -v /volume2/docker/webtrees/installer:/installer -w /installer python:3.12-alpine \
    sh -c "pip install -e .[test] >/dev/null 2>&1 && pytest tests/test_dev_flow.py -v"
```

- [ ] **Step 2.3: Append to `installer/webtrees_installer/dev_flow.py`:**

```python
from typing import IO

from webtrees_installer.prompts import ask_text, ask_yesno


@dataclass(frozen=True)
class HostInfo:
    """Host-side facts the dev flow needs (UID, username, server IP)."""
    uid: int
    username: str
    primary_ip: str


def collect_dev_inputs(
    *,
    work_dir: Path,
    force: bool,
    existing: dict[str, str],
    host_info: HostInfo,
    stdin: IO[str] | None = None,
    stdout: IO[str] | None = None,
) -> DevArgs:
    """Drive the dev-flow prompts. `existing` carries values from a previous .env."""

    use_traefik = ask_yesno(
        "Is a Traefik reverse proxy available?",
        default=False,
        stdin=stdin, stdout=stdout,
    )
    proxy_mode = "traefik" if use_traefik else "standalone"

    app_port: int | None = None
    pma_port: int | None = None
    if proxy_mode == "standalone":
        app_port_default = int(existing.get("APP_PORT", "50010") or "50010")
        pma_port_default = int(existing.get("PMA_PORT", "50011") or "50011")
        app_port = int(ask_text(
            "Host port for Webtrees (maps to container 80)",
            default=str(app_port_default),
            stdin=stdin, stdout=stdout,
        ))
        pma_port = int(ask_text(
            "Host port for phpMyAdmin (maps to container 80)",
            default=str(pma_port_default),
            stdin=stdin, stdout=stdout,
        ))
        default_domain = existing.get("DEV_DOMAIN") or f"{host_info.primary_ip}:{app_port}"
    else:
        default_domain = existing.get("DEV_DOMAIN") or "webtrees.example.org"

    dev_domain = ask_text(
        "Domain under which the dev system should be reachable",
        default=default_domain,
        stdin=stdin, stdout=stdout,
    )

    use_existing_db = ask_yesno(
        "Use an existing, already-initialised database?",
        default=False,
        stdin=stdin, stdout=stdout,
    )
    use_external_db = ask_yesno(
        "Use an external database?",
        default=False,
        stdin=stdin, stdout=stdout,
    )

    if use_external_db:
        mariadb_host = ask_text(
            "External MariaDB host (network name or DNS)",
            default=existing.get("MARIADB_HOST", "external-db.local") or "external-db.local",
            stdin=stdin, stdout=stdout,
        )
    else:
        mariadb_host = "db"

    mariadb_root_password = ask_text(
        "MariaDB root password",
        default=existing.get("MARIADB_ROOT_PASSWORD", "") or None,
        stdin=stdin, stdout=stdout,
    )
    mariadb_database = ask_text(
        "MariaDB database name",
        default=existing.get("MARIADB_DATABASE", "webtrees") or "webtrees",
        stdin=stdin, stdout=stdout,
    )
    mariadb_user = ask_text(
        "MariaDB username",
        default=existing.get("MARIADB_USER", "webtrees") or "webtrees",
        stdin=stdin, stdout=stdout,
    )
    mariadb_password = ask_text(
        "MariaDB user password",
        default=existing.get("MARIADB_PASSWORD", "") or None,
        stdin=stdin, stdout=stdout,
    )

    return DevArgs(
        work_dir=work_dir,
        interactive=True,
        proxy_mode=proxy_mode,
        dev_domain=dev_domain,
        app_port=app_port,
        pma_port=pma_port,
        mariadb_host=mariadb_host,
        mariadb_database=mariadb_database,
        mariadb_user=mariadb_user,
        mariadb_password=mariadb_password,
        mariadb_root_password=mariadb_root_password,
        use_existing_db=use_existing_db,
        use_external_db=use_external_db,
        local_user_id=host_info.uid,
        local_user_name=host_info.username,
        force=force,
    )
```

- [ ] **Step 2.4: Re-run, expect 10 passed in test_dev_flow.py:**

```bash
docker run --rm -v /volume2/docker/webtrees/installer:/installer -w /installer python:3.12-alpine \
    sh -c "pip install -e .[test] >/dev/null 2>&1 && pytest tests/test_dev_flow.py -v"
```

- [ ] **Step 2.5: Commit:**

```bash
git -C /volume2/docker/webtrees add installer/webtrees_installer/dev_flow.py \
    installer/tests/test_dev_flow.py
git -C /volume2/docker/webtrees commit -m "$(cat <<'EOF'
Collect the dev-flow prompts in one place

collect_dev_inputs walks the standalone-vs-traefik branch, then the
existing-/external-db forks, and finishes with the four MariaDB
credentials. Defaults come from an existing .env (the orchestrator
will parse one if it finds it) and fall back to the .env.dist values.
HostInfo carries the host UID, username and primary IP so the IP
fallback for the dev-domain default has no host-side dependency
inside the wizard module.
EOF
)"
```

### Acceptance criteria

- `pytest installer/tests/test_dev_flow.py -v` passes 10 tests.
- `collect_dev_inputs` returns a fully-populated `DevArgs` for both standalone and traefik branches.
- Pre-existing `.env` values become the prompt defaults.

---

## Task 3: Dev-flow orchestrator

**Files:**
- Modify: `installer/webtrees_installer/dev_flow.py` (add `run_dev` + `_detect_host_info` + `_pull_images` + `_run_composer_install`)
- Modify: `installer/tests/test_dev_flow.py` (add 4 orchestrator tests with mocked subprocess)

### Goal

A `run_dev(args, *, stdin, stdout) -> int` function that chains: prereq → confirm-overwrite → collect-inputs (skipped on `--non-interactive`) → render dev `.env` → mkdir `persistent/database` + `persistent/media` + `app/` → `docker compose pull` → `docker compose run --rm buildbox ./scripts/install-application.sh`. Returns 0 on success, 1 on user-cancel, 2 on PrereqError/PromptError, 4 on pull/install failure.

### Steps

- [ ] **Step 3.1: Append failing tests:**

```python
from unittest.mock import call


_LIVE_CATALOG = Catalog(
    php_entries=(PhpEntry(webtrees="2.2.6", php="8.5", tags=("latest",)),),
    nginx_tag="1.28-r1",
    installer_version="0.1.0",
)


@pytest.fixture(autouse=True)
def silence_dev_runtime(tmp_path_factory, monkeypatch):
    """Stub the host-facing bits so dev-flow tests stay hermetic."""
    fake_manifest = tmp_path_factory.mktemp("manifest")
    monkeypatch.setenv("WEBTREES_INSTALLER_MANIFEST_DIR", str(fake_manifest))
    with patch("webtrees_installer.dev_flow.check_prerequisites"), \
         patch("webtrees_installer.dev_flow.load_catalog", return_value=_LIVE_CATALOG), \
         patch("webtrees_installer.dev_flow._detect_host_info",
               return_value=HostInfo(uid=1000, username="dev", primary_ip="10.0.0.5")), \
         patch("webtrees_installer.dev_flow._compose") as compose_mock:
        compose_mock.return_value = __import__("subprocess").CompletedProcess(
            args=[], returncode=0, stdout="", stderr=""
        )
        yield compose_mock


def test_run_dev_non_interactive_writes_env_and_pulls(tmp_path: Path) -> None:
    from webtrees_installer.dev_flow import run_dev
    args = _args(work_dir=tmp_path)

    exit_code = run_dev(args, stdin=StringIO(), stdout=StringIO())

    assert exit_code == 0
    assert (tmp_path / ".env").is_file()
    assert (tmp_path / "persistent" / "database").is_dir()
    assert (tmp_path / "persistent" / "media").is_dir()
    assert (tmp_path / "app").is_dir()


def test_run_dev_invokes_compose_pull_and_install(tmp_path: Path) -> None:
    from webtrees_installer.dev_flow import run_dev
    args = _args(work_dir=tmp_path)

    # Reach into the autouse fixture's compose mock.
    with patch("webtrees_installer.dev_flow._compose") as compose_mock:
        import subprocess as _sp
        compose_mock.return_value = _sp.CompletedProcess(
            args=[], returncode=0, stdout="", stderr=""
        )
        run_dev(args, stdin=StringIO(), stdout=StringIO())

    invocations = [c.args[0] for c in compose_mock.call_args_list]
    assert ["compose", "pull"] in invocations
    assert any(
        inv[:3] == ["compose", "run", "--rm"] and "buildbox" in inv
        for inv in invocations
    )


def test_run_dev_fails_cleanly_when_compose_pull_breaks(tmp_path: Path) -> None:
    from webtrees_installer.dev_flow import run_dev
    args = _args(work_dir=tmp_path)
    with patch("webtrees_installer.dev_flow._compose") as compose_mock:
        import subprocess as _sp
        compose_mock.return_value = _sp.CompletedProcess(
            args=[], returncode=1, stdout="", stderr="pull error",
        )
        exit_code = run_dev(args, stdin=StringIO(), stdout=StringIO())

    assert exit_code == 4


def test_run_dev_aborts_on_existing_files_without_force(tmp_path: Path) -> None:
    from webtrees_installer.dev_flow import run_dev
    (tmp_path / ".env").write_text("X=1")
    args = _args(work_dir=tmp_path, force=False)
    from webtrees_installer.prereq import PrereqError
    with pytest.raises(PrereqError):
        run_dev(args, stdin=StringIO(), stdout=StringIO())
```

- [ ] **Step 3.2: Run, confirm failures (NameError / AttributeError on `run_dev`).**

- [ ] **Step 3.3: Implement `run_dev` and helpers in `installer/webtrees_installer/dev_flow.py`.** Append:

```python
import os
import socket
import subprocess
from datetime import datetime, timezone

from webtrees_installer.prereq import PrereqError, check_prerequisites, confirm_overwrite
from webtrees_installer.versions import load_catalog


_DEFAULT_MANIFEST_DIR = Path("/opt/installer/versions")


def _resolve_manifest_dir() -> Path:
    env_value = os.environ.get("WEBTREES_INSTALLER_MANIFEST_DIR")
    if env_value:
        return Path(env_value)
    if _DEFAULT_MANIFEST_DIR.is_dir():
        return _DEFAULT_MANIFEST_DIR
    raise PrereqError(
        "WEBTREES_INSTALLER_MANIFEST_DIR is not set and the bundled image "
        f"manifest directory {_DEFAULT_MANIFEST_DIR} is missing."
    )


def run_dev(
    args: DevArgs,
    *,
    stdin: IO[str] | None = None,
    stdout: IO[str] | None = None,
) -> int:
    """Drive the dev-flow end to end. Returns process exit code."""
    work_dir = args.work_dir or Path("/work")

    check_prerequisites(work_dir=work_dir)

    if not confirm_overwrite(
        work_dir=work_dir,
        interactive=args.interactive,
        force=args.force,
        stdin=stdin, stdout=stdout,
    ):
        if stdout:
            print("Aborted (existing files preserved).", file=stdout)
        return 1

    if args.interactive:
        host_info = _detect_host_info()
        existing = _parse_env(work_dir / ".env")
        args = collect_dev_inputs(
            work_dir=work_dir, force=args.force,
            existing=existing,
            host_info=host_info,
            stdin=stdin, stdout=stdout,
        )

    catalog = load_catalog(_resolve_manifest_dir())
    render_dev_env(
        args, catalog=catalog, target_dir=work_dir,
        generated_at=datetime.now(tz=timezone.utc),
    )

    for relative in ("persistent/database", "persistent/media", "app"):
        (work_dir / relative).mkdir(parents=True, exist_ok=True)

    pull = _compose(["compose", "pull"], cwd=work_dir)
    if pull.returncode != 0:
        if stdout:
            print(f"error: docker compose pull failed: {pull.stderr.strip()}",
                  file=stdout)
        return 4

    install = _compose(
        ["compose", "run", "--rm", "-e", "COMPOSER_AUTH", "buildbox",
         "./scripts/install-application.sh"],
        cwd=work_dir,
    )
    if install.returncode != 0:
        if stdout:
            print(f"error: composer install failed: {install.stderr.strip()}",
                  file=stdout)
        return 4

    if stdout:
        _print_dev_banner(stdout=stdout, args=args)
    return 0


def _detect_host_info() -> HostInfo:
    """Read UID, username and primary IPv4 once for the prompt defaults."""
    try:
        uid = os.geteuid()
    except AttributeError:
        uid = 0
    username = os.environ.get("USER") or os.environ.get("LOGNAME") or "developer"
    primary_ip = "127.0.0.1"
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.connect(("1.1.1.1", 80))
            primary_ip = sock.getsockname()[0]
        finally:
            sock.close()
    except OSError:
        pass
    return HostInfo(uid=uid, username=username, primary_ip=primary_ip)


def _parse_env(path: Path) -> dict[str, str]:
    """Best-effort .env reader for prompt defaults."""
    if not path.is_file():
        return {}
    out: dict[str, str] = {}
    for line in path.read_text().splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        out[key.strip()] = value.strip()
    return out


def _compose(args: list[str], *, cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["docker", *args],
        cwd=cwd,
        capture_output=True,
        text=True,
        check=False,
    )


def _print_dev_banner(*, stdout: IO[str], args: DevArgs) -> None:
    bar = "-" * 60
    print(bar, file=stdout)
    print("Webtrees dev environment ready.", file=stdout)
    print(bar, file=stdout)
    if args.proxy_mode == "standalone":
        print(f"Webtrees URL: http://{args.dev_domain}/", file=stdout)
        print(f"phpMyAdmin URL: http://{args.dev_domain.split(':')[0]}:{args.pma_port}/",
              file=stdout)
    else:
        print(f"Webtrees URL: https://{args.dev_domain}/", file=stdout)
    print(file=stdout)
    print("Next: make up", file=stdout)
    print(bar, file=stdout)
```

- [ ] **Step 3.4: Re-run, expect 14 passed in test_dev_flow.py.**

- [ ] **Step 3.5: Commit:**

```bash
git -C /volume2/docker/webtrees add installer/webtrees_installer/dev_flow.py \
    installer/tests/test_dev_flow.py
git -C /volume2/docker/webtrees commit -m "$(cat <<'EOF'
Wire the dev-flow orchestrator end to end

run_dev chains prereq → confirm_overwrite → collect_dev_inputs → render
the dev .env → mkdir the persistent + app dirs → docker compose pull →
docker compose run --rm buildbox install. The flow exits 1 on user-
cancel, 4 on pull/install failure, and 0 on success. _detect_host_info
captures UID/username/primary-IP once so the prompt defaults stay
deterministic. _parse_env feeds an existing .env's values back into
the prompts so re-running the wizard on a populated repo is idempotent.
EOF
)"
```

### Acceptance criteria

- `pytest installer/tests/test_dev_flow.py -v` passes 14 tests.
- Failed `docker compose pull` surfaces as exit 4 with the captured stderr.
- Existing files without `--force` raise `PrereqError`.

---

## Task 4: CLI `--mode` + dev-flow flag wiring

**Files:**
- Modify: `installer/webtrees_installer/cli.py`
- Modify: `installer/tests/test_cli.py`

### Goal

The CLI's `--mode {standalone,dev}` chooses the flow. Every dev-flow prompt has a matching CLI flag so `--non-interactive` works for CI smoke-tests.

### Steps

- [ ] **Step 4.1: Append failing test to `installer/tests/test_cli.py`:**

```python
def test_parser_carries_dev_mode_and_dev_flags():
    parser = build_parser()
    args = parser.parse_args(
        [
            "--mode", "dev",
            "--non-interactive",
            "--force",
            "--proxy", "standalone",
            "--port", "50010",
            "--pma-port", "50011",
            "--dev-domain", "webtrees.localhost:50010",
            "--mariadb-root-password", "rootpw",
            "--mariadb-database", "wt",
            "--mariadb-user", "wt_user",
            "--mariadb-password", "wt_pw",
        ]
    )
    assert args.mode == "dev"
    assert args.app_port == 50010
    assert args.pma_port == 50011
    assert args.dev_domain == "webtrees.localhost:50010"
    assert args.mariadb_root_password == "rootpw"
```

- [ ] **Step 4.2: Run, confirm failure.**

- [ ] **Step 4.3: Update `installer/webtrees_installer/cli.py`.** Add `--mode` and the new dev-only flags to `build_parser` (insert before the existing `--admin-user` block):

```python
    parser.add_argument(
        "--mode",
        choices=["standalone", "dev"],
        default="standalone",
        help="Wizard mode: write a self-host compose.yaml (standalone) or "
             "configure the cloned repo for development (dev).",
    )
    parser.add_argument(
        "--pma-port",
        type=int,
        help="Host port for phpMyAdmin (dev mode, standalone proxy).",
    )
    parser.add_argument(
        "--dev-domain",
        help="Dev-domain string (dev mode); defaults to IP:APP_PORT in standalone.",
    )
    parser.add_argument(
        "--mariadb-root-password",
        help="MariaDB root password (dev mode).",
    )
    parser.add_argument(
        "--mariadb-database",
        help="MariaDB database name (dev mode).",
    )
    parser.add_argument(
        "--mariadb-user",
        help="MariaDB application user (dev mode).",
    )
    parser.add_argument(
        "--mariadb-password",
        help="MariaDB user password (dev mode).",
    )
    parser.add_argument(
        "--use-existing-db",
        action="store_true",
        help="Skip the schema init step in dev mode.",
    )
    parser.add_argument(
        "--use-external-db",
        action="store_true",
        help="Skip the bundled db service in dev mode and write compose.external.yaml into the chain.",
    )
    parser.add_argument(
        "--external-db-host",
        help="External MariaDB host (dev mode + --use-external-db).",
    )
```

Then dispatch on mode in `main()`. Replace the existing dispatch block (`try: return run_standalone(...)`) with:

```python
    if args.mode == "dev":
        from webtrees_installer.dev_flow import DevArgs, run_dev

        dev_args = DevArgs(
            work_dir=args.work_dir,
            interactive=not args.non_interactive,
            proxy_mode=args.proxy_mode or "standalone",
            dev_domain=args.dev_domain or "",
            app_port=args.app_port,
            pma_port=args.pma_port,
            mariadb_host=args.external_db_host or "db",
            mariadb_database=args.mariadb_database or "webtrees",
            mariadb_user=args.mariadb_user or "webtrees",
            mariadb_password=args.mariadb_password or "",
            mariadb_root_password=args.mariadb_root_password or "",
            use_existing_db=args.use_existing_db,
            use_external_db=args.use_external_db,
            local_user_id=0,
            local_user_name="",
            force=args.force,
        )
        try:
            return run_dev(dev_args, stdin=sys.stdin, stdout=sys.stdout)
        except StackError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 3
        except (PrereqError, PromptError) as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2

    # standalone (default)
    flow_args = StandaloneArgs(...)
    try:
        return run_standalone(flow_args, stdin=sys.stdin, stdout=sys.stdout)
    ...
```

(The dev flow's `_detect_host_info` fills `local_user_id` + `local_user_name` when `interactive=True`. For `--non-interactive`, the CLI should still detect them — keep the call inside `run_dev` so both paths share it.)

In `run_dev` (Task 3), add this at the top before the `if args.interactive` block:

```python
    if args.local_user_id == 0 and args.local_user_name == "":
        host_info = _detect_host_info()
        args = dataclasses.replace(
            args,
            local_user_id=host_info.uid,
            local_user_name=host_info.username,
        )
```

And add `import dataclasses` at the top of dev_flow.py.

- [ ] **Step 4.4: Re-run, expect all CLI + dev_flow tests passing.**

- [ ] **Step 4.5: Commit:**

```bash
git -C /volume2/docker/webtrees add installer/webtrees_installer/cli.py \
    installer/webtrees_installer/dev_flow.py \
    installer/tests/test_cli.py
git -C /volume2/docker/webtrees commit -m "$(cat <<'EOF'
Add --mode dev plus the dev-flow flag matrix to the CLI

The CLI now branches on --mode {standalone,dev}; the dev branch
constructs DevArgs from the flag set and calls run_dev with the same
exit-code convention (2 for PrereqError/PromptError, 3 for StackError,
4 for pull/install failure). run_dev falls back to _detect_host_info
when the CLI did not populate local_user_id/local_user_name, which
keeps the CI smoke-test invocations short.
EOF
)"
```

### Acceptance criteria

- `pytest installer/tests/test_cli.py -v` passes.
- `python -m webtrees_installer --help` lists `--mode`, `--pma-port`, `--dev-domain`, `--mariadb-*`, `--use-existing-db`, `--use-external-db`, `--external-db-host`.

---

## Task 5: GEDCOM 5.5.1 serializer

**Files:**
- Create: `installer/webtrees_installer/gedcom.py`
- Create: `installer/tests/test_gedcom.py`

### Goal

A self-contained GEDCOM 5.5.1 serializer (~150 LOC). No external dependencies. Output is byte-identical for a given input — required for the deterministic demo-tree generator (Task 6).

### Steps

- [ ] **Step 5.1: Write failing tests:**

```python
"""Tests for the GEDCOM 5.5.1 serializer."""

from webtrees_installer.gedcom import (
    Family,
    GedcomDocument,
    Person,
    Sex,
    serialize,
)


def test_serialize_minimal_document_has_header_and_trailer() -> None:
    doc = GedcomDocument(people=[], families=[])
    out = serialize(doc, submitter="Test")
    lines = out.splitlines()
    assert lines[0] == "0 HEAD"
    assert "1 GEDC" in out
    assert "2 VERS 5.5.1" in out
    assert "2 FORM LINEAGE-LINKED" in out
    assert lines[-1] == "0 TRLR"


def test_serialize_person_record() -> None:
    p = Person(
        xref="I1", given_name="Anna", surname="Müller", sex=Sex.FEMALE,
        birth_year=1880, death_year=1955, parents_xref=None, spouse_xref=None,
    )
    out = serialize(GedcomDocument(people=[p], families=[]), submitter="Test")
    assert "0 @I1@ INDI" in out
    assert "1 NAME Anna /Müller/" in out
    assert "1 SEX F" in out
    assert "1 BIRT" in out
    assert "2 DATE 1880" in out
    assert "1 DEAT" in out
    assert "2 DATE 1955" in out


def test_serialize_family_record() -> None:
    husband = Person(xref="I1", given_name="John", surname="Doe", sex=Sex.MALE,
                     birth_year=1900, death_year=None,
                     parents_xref=None, spouse_xref="F1")
    wife = Person(xref="I2", given_name="Jane", surname="Doe", sex=Sex.FEMALE,
                  birth_year=1902, death_year=None,
                  parents_xref=None, spouse_xref="F1")
    child = Person(xref="I3", given_name="Alice", surname="Doe", sex=Sex.FEMALE,
                   birth_year=1925, death_year=None,
                   parents_xref="F1", spouse_xref=None)
    fam = Family(xref="F1", husband_xref="I1", wife_xref="I2",
                 marriage_year=1924, children_xrefs=["I3"])
    out = serialize(GedcomDocument(people=[husband, wife, child], families=[fam]),
                    submitter="Test")
    assert "0 @F1@ FAM" in out
    assert "1 HUSB @I1@" in out
    assert "1 WIFE @I2@" in out
    assert "1 MARR" in out
    assert "2 DATE 1924" in out
    assert "1 CHIL @I3@" in out


def test_serialize_is_deterministic() -> None:
    """Two serializations of the same doc are byte-identical."""
    p = Person(xref="I1", given_name="X", surname="Y", sex=Sex.MALE,
               birth_year=1900, death_year=None,
               parents_xref=None, spouse_xref=None)
    doc = GedcomDocument(people=[p], families=[])
    assert serialize(doc, submitter="Test") == serialize(doc, submitter="Test")
```

- [ ] **Step 5.2: Run, confirm ImportError.**

- [ ] **Step 5.3: Implement `installer/webtrees_installer/gedcom.py`:**

```python
"""GEDCOM 5.5.1 serializer (write-only, eigenbau)."""

from __future__ import annotations

import enum
from dataclasses import dataclass, field


class Sex(enum.Enum):
    MALE = "M"
    FEMALE = "F"


@dataclass(frozen=True)
class Person:
    xref: str
    given_name: str
    surname: str
    sex: Sex
    birth_year: int
    death_year: int | None
    parents_xref: str | None
    spouse_xref: str | None


@dataclass(frozen=True)
class Family:
    xref: str
    husband_xref: str
    wife_xref: str
    marriage_year: int
    children_xrefs: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class GedcomDocument:
    people: list[Person]
    families: list[Family]


def serialize(doc: GedcomDocument, *, submitter: str) -> str:
    """Render a GedcomDocument as a GEDCOM 5.5.1 string with CRLF line endings."""
    lines: list[str] = []
    lines.extend(_render_header(submitter=submitter))
    for person in doc.people:
        lines.extend(_render_person(person))
    for family in doc.families:
        lines.extend(_render_family(family))
    lines.append("0 @SUBM1@ SUBM")
    lines.append(f"1 NAME {submitter}")
    lines.append("0 TRLR")
    return "\n".join(lines) + "\n"


def _render_header(*, submitter: str) -> list[str]:
    return [
        "0 HEAD",
        "1 SOUR webtrees-installer",
        "2 NAME Webtrees Installer Demo Generator",
        "2 VERS 0.1.0",
        "1 GEDC",
        "2 VERS 5.5.1",
        "2 FORM LINEAGE-LINKED",
        "1 CHAR UTF-8",
        "1 SUBM @SUBM1@",
    ]


def _render_person(person: Person) -> list[str]:
    out = [
        f"0 @{person.xref}@ INDI",
        f"1 NAME {person.given_name} /{person.surname}/",
        f"1 SEX {person.sex.value}",
        "1 BIRT",
        f"2 DATE {person.birth_year}",
    ]
    if person.death_year is not None:
        out.append("1 DEAT")
        out.append(f"2 DATE {person.death_year}")
    if person.parents_xref is not None:
        out.append(f"1 FAMC @{person.parents_xref}@")
    if person.spouse_xref is not None:
        out.append(f"1 FAMS @{person.spouse_xref}@")
    return out


def _render_family(family: Family) -> list[str]:
    out = [
        f"0 @{family.xref}@ FAM",
        f"1 HUSB @{family.husband_xref}@",
        f"1 WIFE @{family.wife_xref}@",
        "1 MARR",
        f"2 DATE {family.marriage_year}",
    ]
    for child_xref in family.children_xrefs:
        out.append(f"1 CHIL @{child_xref}@")
    return out
```

- [ ] **Step 5.4: Re-run, expect 4 passed.**

- [ ] **Step 5.5: Commit:**

```bash
git -C /volume2/docker/webtrees add installer/webtrees_installer/gedcom.py \
    installer/tests/test_gedcom.py
git -C /volume2/docker/webtrees commit -m "$(cat <<'EOF'
Add a minimal GEDCOM 5.5.1 serializer

Person and Family frozen dataclasses describe the only fields the
demo-tree generator needs; GedcomDocument groups them, serialize()
emits the canonical HEAD/INDI/FAM/TRLR record order with a hard-coded
SUBM placeholder. Output is deterministic — same input bytes-equal
same output — which the next task's seedable generator relies on.
EOF
)"
```

### Acceptance criteria

- `pytest installer/tests/test_gedcom.py -v` passes 4 tests.
- Serializer has no external dependencies beyond `dataclasses` + `enum`.

---

## Task 6: Deterministic demo-tree generator

**Files:**
- Create: `installer/webtrees_installer/data/given_names.json`
- Create: `installer/webtrees_installer/data/surnames.json`
- Create: `installer/webtrees_installer/demo.py`
- Create: `installer/tests/test_demo.py`
- Modify: `installer/pyproject.toml` (extend `package-data`)

### Goal

A deterministic generator that takes `(seed, generations)` and returns a `GedcomDocument` covering ~150-250 people across 7 generations. Same inputs → byte-identical GEDCOM output.

### Steps

- [ ] **Step 6.1: Create the data files.** Pure data, no code review needed — public-domain Common Name lists.

`installer/webtrees_installer/data/given_names.json`:

```json
{
    "male": [
        "James", "John", "Robert", "Michael", "William", "David", "Richard",
        "Joseph", "Thomas", "Charles", "Christopher", "Daniel", "Matthew",
        "Anthony", "Donald", "Mark", "Paul", "Steven", "Andrew", "Kenneth",
        "George", "Joshua", "Kevin", "Brian", "Edward", "Ronald", "Timothy",
        "Jason", "Jeffrey", "Ryan", "Jacob", "Gary", "Nicholas", "Eric",
        "Jonathan", "Stephen", "Larry", "Justin", "Scott", "Brandon",
        "Frank", "Benjamin", "Gregory", "Samuel", "Raymond", "Patrick",
        "Alexander", "Jack", "Dennis", "Jerry"
    ],
    "female": [
        "Mary", "Patricia", "Jennifer", "Linda", "Elizabeth", "Barbara",
        "Susan", "Jessica", "Sarah", "Karen", "Lisa", "Nancy", "Betty",
        "Helen", "Sandra", "Donna", "Carol", "Ruth", "Sharon", "Michelle",
        "Laura", "Sarah", "Kimberly", "Deborah", "Dorothy", "Lisa", "Nancy",
        "Karen", "Margaret", "Susan", "Dorothy", "Lisa", "Nancy", "Karen",
        "Betty", "Helen", "Sandra", "Donna", "Carol", "Ruth", "Sharon",
        "Michelle", "Laura", "Sarah", "Kimberly", "Deborah", "Amy", "Angela",
        "Ashley", "Brenda"
    ]
}
```

(Note: some names repeat — that mirrors real-world distributions and avoids pretending the pool is unique.)

`installer/webtrees_installer/data/surnames.json`:

```json
{
    "surnames": [
        "Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller",
        "Davis", "Rodriguez", "Martinez", "Hernandez", "Lopez", "Gonzalez",
        "Wilson", "Anderson", "Thomas", "Taylor", "Moore", "Jackson",
        "Martin", "Lee", "Perez", "Thompson", "White", "Harris", "Sanchez",
        "Clark", "Ramirez", "Lewis", "Robinson", "Walker", "Young", "Allen",
        "King", "Wright", "Scott", "Torres", "Nguyen", "Hill", "Flores",
        "Green", "Adams", "Nelson", "Baker", "Hall", "Rivera", "Campbell",
        "Mitchell", "Carter", "Roberts", "Gomez", "Phillips", "Evans",
        "Turner", "Diaz", "Parker", "Cruz", "Edwards", "Collins", "Reyes",
        "Stewart", "Morris", "Morales", "Murphy", "Cook", "Rogers", "Gutierrez",
        "Ortiz", "Morgan", "Cooper", "Peterson", "Bailey", "Reed", "Kelly",
        "Howard", "Ramos", "Kim", "Cox", "Ward", "Richardson", "Watson",
        "Brooks", "Chavez", "Wood", "James", "Bennett", "Gray", "Mendoza",
        "Ruiz", "Hughes", "Price", "Alvarez", "Castillo", "Sanders", "Patel",
        "Myers", "Long", "Ross", "Foster", "Jimenez", "Powell"
    ]
}
```

- [ ] **Step 6.2: Extend `installer/pyproject.toml`** to include the data glob:

```toml
[tool.setuptools.package-data]
webtrees_installer = ["templates/*.j2", "data/*.json"]
```

- [ ] **Step 6.3: Write failing tests `installer/tests/test_demo.py`:**

```python
"""Tests for the deterministic demo-tree generator."""

from __future__ import annotations

from webtrees_installer.demo import GENERATIONS_DEFAULT, generate_tree
from webtrees_installer.gedcom import Sex, serialize


def test_generate_tree_deterministic() -> None:
    """Same seed yields byte-identical GEDCOM output."""
    a = serialize(generate_tree(seed=42), submitter="Test")
    b = serialize(generate_tree(seed=42), submitter="Test")
    assert a == b


def test_generate_tree_different_seeds_diverge() -> None:
    """Different seeds produce different first names somewhere in the tree."""
    a = serialize(generate_tree(seed=1), submitter="Test")
    b = serialize(generate_tree(seed=2), submitter="Test")
    assert a != b


def test_generate_tree_root_couple_dates() -> None:
    """Root pair sits in generation 0 with birth year ~1850."""
    doc = generate_tree(seed=42)
    root_husband = doc.people[0]
    root_wife = doc.people[1]
    assert 1830 <= root_husband.birth_year <= 1870
    assert 1830 <= root_wife.birth_year <= 1870
    assert root_husband.sex is Sex.MALE
    assert root_wife.sex is Sex.FEMALE


def test_generate_tree_population_within_bounds() -> None:
    """7 generations with the default fertility settings produce 100-400 people."""
    doc = generate_tree(seed=42, generations=GENERATIONS_DEFAULT)
    assert 100 <= len(doc.people) <= 400
    assert 30 <= len(doc.families) <= 150
```

- [ ] **Step 6.4: Run, confirm failure.**

- [ ] **Step 6.5: Implement `installer/webtrees_installer/demo.py`:**

```python
"""Deterministic demo-tree generator.

Uses random.Random(seed) so the same seed yields the same tree (and
therefore the same GEDCOM bytes) on every host. The algorithm walks a
binary-ish descent: a root couple in generation 0, then 2-4 children
per couple over `generations` generations; ~80 % of adult children
marry a synthetic spouse drawn from the same name pools.
"""

from __future__ import annotations

import json
import random
from importlib import resources

from webtrees_installer.gedcom import Family, GedcomDocument, Person, Sex


GENERATIONS_DEFAULT = 7
ROOT_BIRTH_YEAR_DEFAULT = 1850
GENERATION_GAP_YEARS = 28


def generate_tree(
    *,
    seed: int,
    generations: int = GENERATIONS_DEFAULT,
    root_birth_year: int = ROOT_BIRTH_YEAR_DEFAULT,
) -> GedcomDocument:
    rng = random.Random(seed)
    pools = _load_pools()

    people: list[Person] = []
    families: list[Family] = []

    def new_person(
        *, sex: Sex, surname: str, birth_year: int,
        parents_xref: str | None,
    ) -> Person:
        xref = f"I{len(people) + 1}"
        pool = pools["male"] if sex is Sex.MALE else pools["female"]
        given = rng.choice(pool)
        death_year = (
            None if rng.random() < 0.3
            else birth_year + rng.randint(50, 95)
        )
        person = Person(
            xref=xref, given_name=given, surname=surname, sex=sex,
            birth_year=birth_year, death_year=death_year,
            parents_xref=parents_xref, spouse_xref=None,
        )
        people.append(person)
        return person

    def new_family(*, husband: Person, wife: Person, marriage_year: int) -> Family:
        xref = f"F{len(families) + 1}"
        family = Family(
            xref=xref,
            husband_xref=husband.xref,
            wife_xref=wife.xref,
            marriage_year=marriage_year,
            children_xrefs=[],
        )
        families.append(family)
        return family

    # Root couple.
    root_surname = rng.choice(pools["surnames"])
    root_husband = new_person(
        sex=Sex.MALE, surname=root_surname, birth_year=root_birth_year,
        parents_xref=None,
    )
    root_wife = new_person(
        sex=Sex.FEMALE, surname=rng.choice(pools["surnames"]),
        birth_year=root_birth_year + rng.randint(-3, 3), parents_xref=None,
    )
    root_family = new_family(
        husband=root_husband, wife=root_wife,
        marriage_year=root_birth_year + 24,
    )

    # Mutate root_husband / root_wife to point at root_family.
    _link_spouse(people, root_husband.xref, root_family.xref)
    _link_spouse(people, root_wife.xref, root_family.xref)

    queue: list[tuple[Family, int]] = [(root_family, 0)]
    while queue:
        family, gen = queue.pop(0)
        if gen + 1 >= generations:
            continue
        child_count = rng.randint(2, 4)
        child_birth = family.marriage_year + 1
        for _ in range(child_count):
            child_birth += rng.randint(1, 4)
            sex = Sex.MALE if rng.random() < 0.51 else Sex.FEMALE
            husband_record = _find_person(people, family.husband_xref)
            child = new_person(
                sex=sex, surname=husband_record.surname,
                birth_year=child_birth, parents_xref=family.xref,
            )
            _append_child(families, family.xref, child.xref)

            # ~80 % marry a synthetic spouse.
            if rng.random() < 0.8 and child_birth + 22 < root_birth_year + generations * GENERATION_GAP_YEARS:
                if child.sex is Sex.MALE:
                    spouse = new_person(
                        sex=Sex.FEMALE,
                        surname=rng.choice(pools["surnames"]),
                        birth_year=child.birth_year + rng.randint(-3, 3),
                        parents_xref=None,
                    )
                    husband, wife = child, spouse
                else:
                    spouse = new_person(
                        sex=Sex.MALE,
                        surname=rng.choice(pools["surnames"]),
                        birth_year=child.birth_year + rng.randint(-3, 3),
                        parents_xref=None,
                    )
                    husband, wife = spouse, child

                family_marriage = child.birth_year + 24
                sub_family = new_family(
                    husband=husband, wife=wife,
                    marriage_year=family_marriage,
                )
                _link_spouse(people, husband.xref, sub_family.xref)
                _link_spouse(people, wife.xref, sub_family.xref)
                queue.append((sub_family, gen + 1))

    return GedcomDocument(people=people, families=families)


def _load_pools() -> dict[str, list[str]]:
    given = json.loads(
        resources.files("webtrees_installer.data").joinpath("given_names.json").read_text(),
    )
    surnames = json.loads(
        resources.files("webtrees_installer.data").joinpath("surnames.json").read_text(),
    )
    return {
        "male": given["male"],
        "female": given["female"],
        "surnames": surnames["surnames"],
    }


def _find_person(people: list[Person], xref: str) -> Person:
    for person in people:
        if person.xref == xref:
            return person
    raise KeyError(xref)


def _link_spouse(people: list[Person], xref: str, family_xref: str) -> None:
    for idx, person in enumerate(people):
        if person.xref == xref:
            people[idx] = Person(
                xref=person.xref, given_name=person.given_name,
                surname=person.surname, sex=person.sex,
                birth_year=person.birth_year, death_year=person.death_year,
                parents_xref=person.parents_xref, spouse_xref=family_xref,
            )
            return
    raise KeyError(xref)


def _append_child(families: list[Family], xref: str, child_xref: str) -> None:
    for idx, family in enumerate(families):
        if family.xref == xref:
            families[idx] = Family(
                xref=family.xref,
                husband_xref=family.husband_xref,
                wife_xref=family.wife_xref,
                marriage_year=family.marriage_year,
                children_xrefs=[*family.children_xrefs, child_xref],
            )
            return
    raise KeyError(xref)
```

- [ ] **Step 6.6: Re-run, expect 4 passed in test_demo.py.**

- [ ] **Step 6.7: Commit:**

```bash
git -C /volume2/docker/webtrees add installer/webtrees_installer/demo.py \
    installer/webtrees_installer/data \
    installer/tests/test_demo.py \
    installer/pyproject.toml
git -C /volume2/docker/webtrees commit -m "$(cat <<'EOF'
Generate the demo tree with a seedable RNG

generate_tree seeds random.Random and walks the descent breadth-first
from a root couple. Each marriage produces 2-4 children, ~80 % of
whom marry a synthetic spouse drawn from the same JSON name pools.
A 7-generation default yields 100-400 people / 30-150 families,
verified by the bounds test. The tree object is then handed to the
GEDCOM serializer from Task 5, which means the same seed always
produces the same demo.ged bytes on every host.
EOF
)"
```

### Acceptance criteria

- `pytest installer/tests/test_demo.py -v` passes 4 tests.
- Same seed → byte-identical GEDCOM output (the determinism test verifies this).

---

## Task 7: Demo-tree wiring into the standalone flow

**Files:**
- Modify: `installer/webtrees_installer/flow.py` (add `demo` to `StandaloneArgs`, write demo.ged in `run_standalone`, optionally compose-exec import)
- Modify: `installer/webtrees_installer/cli.py` (add `--demo` flag + a `--demo-seed` knob for repeatable test runs)
- Modify: `installer/tests/test_flow.py` (3 new tests)
- Modify: `installer/tests/test_cli.py` (1 new test)

### Goal

`--edition full --demo` writes `/work/demo.ged` always. When `--no-up` is NOT set, the wizard also runs `docker compose cp demo.ged phpfpm:/tmp/demo.ged` + `tree --create demo` + `tree-import demo /tmp/demo.ged` once the stack is healthy. When `--no-up` IS set, the wizard prints a one-line hint pointing at the commands.

### Steps

- [ ] **Step 7.1: Add to `StandaloneArgs` in `flow.py`:**

```python
    demo: bool
    demo_seed: int
```

(Insert before `force`.)

- [ ] **Step 7.2: Append a `_write_demo_gedcom` helper and a `_import_demo_tree` helper at the bottom of `flow.py`:**

```python
def _write_demo_gedcom(*, work_dir: Path, seed: int) -> Path:
    """Generate the demo GEDCOM and write it next to compose.yaml."""
    from webtrees_installer.demo import generate_tree
    from webtrees_installer.gedcom import serialize
    doc = generate_tree(seed=seed)
    out = work_dir / "demo.ged"
    out.write_text(serialize(doc, submitter="webtrees-installer demo"))
    return out


def _import_demo_tree(*, work_dir: Path, gedcom_path: Path) -> None:
    """Copy the GEDCOM into the phpfpm container and run tree-import.

    Mirrors the spec's Demo-Tree import flow:
        docker compose cp demo.ged phpfpm:/tmp/demo.ged
        docker compose exec phpfpm sh -c "php /var/www/html/index.php tree --create demo"
        docker compose exec phpfpm sh -c "... tree-import demo /tmp/demo.ged"
    """
    import_steps = [
        ["compose", "cp", str(gedcom_path), "phpfpm:/tmp/demo.ged"],
        ["compose", "exec", "-T", "phpfpm", "su", "www-data", "-s", "/bin/sh", "-c",
         "php /var/www/html/index.php tree --create demo"],
        ["compose", "exec", "-T", "phpfpm", "su", "www-data", "-s", "/bin/sh", "-c",
         "php /var/www/html/index.php tree-import demo /tmp/demo.ged"],
    ]
    for step in import_steps:
        result = subprocess.run(
            ["docker", *step],
            cwd=work_dir, capture_output=True, text=True, check=False,
        )
        if result.returncode != 0:
            raise StackError(
                f"demo-tree import step failed: docker {' '.join(step)}\n"
                f"{result.stderr.strip() or result.stdout.strip()}"
            )
```

(`from webtrees_installer.stack import StackError` is already imported in flow.py.)

- [ ] **Step 7.3: Wire the demo branch into `run_standalone`.** After `render_files(...)` and before `_print_banner`:

```python
    demo_gedcom: Path | None = None
    if args.demo:
        demo_gedcom = _write_demo_gedcom(work_dir=work_dir, seed=args.demo_seed)
        if stdout:
            print(f"Demo GEDCOM written to {demo_gedcom}", file=stdout)
```

And after `bring_up(work_dir=work_dir)`, but only if `args.demo and demo_gedcom`:

```python
    if not args.no_up:
        bring_up(work_dir=work_dir)
        if demo_gedcom is not None:
            _import_demo_tree(work_dir=work_dir, gedcom_path=demo_gedcom)
            if stdout:
                print("Demo tree imported into the `demo` tree.", file=stdout)
```

- [ ] **Step 7.4: Add `--demo` and `--demo-seed` to CLI:**

```python
    parser.add_argument(
        "--demo",
        action="store_true",
        help="Generate a 7-generation synthetic family tree and (when the stack is up) import it.",
    )
    parser.add_argument(
        "--demo-seed",
        type=int,
        default=42,
        help="RNG seed for the demo tree (default: 42; same seed → same tree).",
    )
```

Update the CLI's `StandaloneArgs(...)` construction to pass `demo=args.demo, demo_seed=args.demo_seed`. Update the dev-flow side too — `DevArgs` does not gain demo (dev users do not need the demo).

- [ ] **Step 7.5: Append tests to `installer/tests/test_flow.py`:**

```python
def test_run_standalone_writes_demo_gedcom_when_demo_set(tmp_path: Path) -> None:
    """--demo true → demo.ged is written next to compose.yaml."""
    args = _args(work_dir=tmp_path, demo=True, demo_seed=42)
    with patch("webtrees_installer.flow.probe_port", return_value=PortStatus.FREE):
        exit_code = run_standalone(args, stdin=StringIO(), stdout=StringIO())

    assert exit_code == 0
    gedcom = tmp_path / "demo.ged"
    assert gedcom.is_file()
    content = gedcom.read_text()
    assert content.startswith("0 HEAD")
    assert "2 VERS 5.5.1" in content


def test_run_standalone_skips_demo_when_demo_unset(tmp_path: Path) -> None:
    args = _args(work_dir=tmp_path, demo=False, demo_seed=42)
    with patch("webtrees_installer.flow.probe_port", return_value=PortStatus.FREE):
        run_standalone(args, stdin=StringIO(), stdout=StringIO())

    assert not (tmp_path / "demo.ged").exists()


def test_run_standalone_imports_demo_when_not_no_up(tmp_path: Path) -> None:
    """no_up=False + --demo → wizard calls _import_demo_tree."""
    args = _args(work_dir=tmp_path, demo=True, demo_seed=42, no_up=False)
    with patch("webtrees_installer.flow.probe_port", return_value=PortStatus.FREE), \
         patch("webtrees_installer.flow.bring_up"), \
         patch("webtrees_installer.flow._import_demo_tree") as import_mock:
        run_standalone(args, stdin=StringIO(), stdout=StringIO())

    import_mock.assert_called_once()
```

The autouse fixture's `_args` helper needs `demo=False, demo_seed=42` added to its defaults so the other tests keep passing.

- [ ] **Step 7.6: Add `test_parser_carries_demo_flags` to `installer/tests/test_cli.py`:**

```python
def test_parser_carries_demo_flags():
    parser = build_parser()
    args = parser.parse_args([
        "--non-interactive", "--no-admin", "--edition", "full",
        "--proxy", "standalone", "--port", "8080", "--demo", "--demo-seed", "7",
    ])
    assert args.demo is True
    assert args.demo_seed == 7
```

- [ ] **Step 7.7: Run, expect the full suite green.**

- [ ] **Step 7.8: Commit:**

```bash
git -C /volume2/docker/webtrees add installer/webtrees_installer/flow.py \
    installer/webtrees_installer/cli.py installer/tests/test_flow.py \
    installer/tests/test_cli.py
git -C /volume2/docker/webtrees commit -m "$(cat <<'EOF'
Generate and import the demo tree in the standalone flow

--demo writes /work/demo.ged via the eigenbau GEDCOM generator. When
the stack is also brought up (no --no-up), the wizard runs `compose
cp demo.ged phpfpm:/tmp/demo.ged` + `tree --create demo` + `tree-
import demo /tmp/demo.ged`. --no-up still emits the GEDCOM so CI can
assert the file exists without standing up the stack. --demo-seed
exposes the RNG seed (default 42) for repeatable test runs.
EOF
)"
```

### Acceptance criteria

- `pytest installer/tests/ -v` passes the full suite.
- `--demo` writes `demo.ged` regardless of `--no-up`; the import is skipped only when `--no-up` is set.
- `--demo-seed` accepts an integer and threads it through to the generator.

---

## Task 8: Hard-cut deletion of obsolete files

**Files:**
- Delete: `scripts/setup.sh`
- Delete: `Make/modes.mk`

### Goal

Remove the bash + make targets the wizard now subsumes. No back-compat. Update any references that point at the deleted files.

### Steps

- [ ] **Step 8.1: Identify references:**

```bash
grep -rn "scripts/setup.sh\|enable-dev-mode\|disable-dev-mode\|dev-mode-status" \
    /volume2/docker/webtrees \
    --include="*.md" --include="*.sh" --include="*.mk" --include="Makefile" \
    --include="*.yml" --include="*.yaml" 2>/dev/null \
  | grep -v "^/volume2/docker/webtrees/docs/superpowers/" \
  | grep -v "^/volume2/docker/webtrees/Make/modes.mk:" \
  | grep -v "^/volume2/docker/webtrees/scripts/setup.sh:"
```

Expected: a handful of README hits + a Make/modes.mk error-message reference inside `enable-dev-mode` ("run scripts/setup.sh first"). The README will be rewritten in Task 9; the modes.mk reference goes away with the file.

- [ ] **Step 8.2: Delete the files:**

```bash
git -C /volume2/docker/webtrees rm scripts/setup.sh Make/modes.mk
```

- [ ] **Step 8.3: Sanity-check the Makefile still loads** — `make help` should run cleanly inside the buildbox:

```bash
docker run --rm -v /volume2/docker/webtrees:/repo -w /repo alpine:3.20 \
    sh -c "apk add --no-cache make >/dev/null && make -n no_targets__"
```

Expected: exit 0, no "missing file" errors.

- [ ] **Step 8.4: Commit:**

```bash
git -C /volume2/docker/webtrees commit -m "$(cat <<'EOF'
Retire scripts/setup.sh and Make/modes.mk

The wizard's --mode dev replaces every prompt scripts/setup.sh asked
and writes the same `.env` the make targets toggled. enable-dev-mode,
disable-dev-mode and dev-mode-status are no longer reachable from the
shipped Make includes. Self-hosters and module developers all enter
through `docker run … webtrees-installer …` now, with no parallel
path to maintain.
EOF
)"
```

### Acceptance criteria

- `scripts/setup.sh` and `Make/modes.mk` are gone from `main`.
- `make` still loads (no broken includes, no broken references).

---

## Task 9: README rewrite

**Files:**
- Rewrite: `README.md`

### Goal

A Self-Hoster lands on the README and finds a one-liner that works. Existing developer-facing content moves to a `docs/developing.md` slot Phase 3 will fill — for Phase 2b just leave a `## For module developers` sub-section pointing at the `--mode dev` wizard with a 6-line invocation example.

### Steps

- [ ] **Step 9.1: Rewrite `README.md`. Target ~120 lines. Required sections:**

```markdown
# Webtrees Self-Host

Docker images and a wizard for running [webtrees](https://www.webtrees.net/)
without writing your own compose file.

## Quickstart

```bash
curl -fsSL https://raw.githubusercontent.com/magicsunday/webtrees-docker/main/install \
  | bash -s -- --edition full --proxy standalone --port 8080
```

(Or with admin auto-create: append `--admin-user admin --admin-email me@example.org`.)

The wizard writes `compose.yaml` + `.env` into the current directory and
brings the stack up via `docker compose up -d`. Visit `http://localhost:8080/`.

## Editions

| Edition | Image | Contains |
|---|---|---|
| Core | `webtrees/php` | Plain webtrees release |
| Full (default) | `webtrees/php-full` | + Magic-Sunday charts |
| Full + Demo | same as Full | + a 7-generation synthetic family tree imported on first boot |

`--edition core` / `full` selects between the first two; add `--demo`
to also seed the demo tree.

## Modes

| Mode | Flag | When to use |
|---|---|---|
| Standalone | `--proxy standalone --port <N>` | Single host, no reverse proxy. nginx publishes the chosen port. |
| Traefik | `--proxy traefik --domain <fqdn>` | nginx joins the `traefik` external network and answers under your Traefik router. |

## What the wizard writes

- `compose.yaml` — services, named volumes, healthchecks.
- `.env` — image tags + (standalone) the host port override.
- `.webtrees-admin-password` — only when `--admin-user` is set; mode 0600.

Subsequent `docker compose pull && up -d` re-uses the same files.

## Customising

See [`docs/customizing.md`](docs/customizing.md) for `compose.override.yaml`
patterns: extra PHP limits, custom nginx snippets, an external database,
bringing in your own webtrees modules. (Docs pending — Phase 3.)

## Updating to a new webtrees release

```bash
docker compose down
docker volume rm webtrees_app
curl -fsSL https://raw.githubusercontent.com/magicsunday/webtrees-docker/main/install \
  | bash -s -- --edition full --proxy standalone --port 8080 --force
docker compose pull
docker compose up -d
```

`webtrees_database` and `webtrees_media` survive the upgrade; the
`webtrees_app` volume is re-seeded on first boot.

## Backup

- DB: `docker compose exec db mariadb-dump --all-databases --single-transaction > backup.sql`.
- Media: `docker run --rm -v webtrees_media:/m -v "$PWD":/host alpine tar -C /m -czf /host/media.tar.gz .`.

## Troubleshooting

- **Port already in use** — the wizard probes the requested port and falls back to 8080 automatically.
- **`docker compose pull` fails** — confirm GHCR is reachable (`docker pull ghcr.io/magicsunday/webtrees/nginx:1.28-r1`) and re-run.
- **Admin login fails** — the password lives in `.webtrees-admin-password` and was printed once when the wizard finished.

## For module developers

Module developers run the wizard in `--mode dev` against a `git clone`
of this repo:

```bash
git clone https://github.com/magicsunday/webtrees-docker.git
cd webtrees-docker
docker run --rm -it \
  -v "$PWD:/work" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  ghcr.io/magicsunday/webtrees/installer:latest --mode dev
```

The dev flow writes a `.env` with the compose chain that bind-mounts
`./app` into phpfpm and brings in buildbox + xdebug + phpMyAdmin.

## License

MIT — see [LICENSE](LICENSE).
```

- [ ] **Step 9.2: Verify the README renders cleanly with `gh-markdown-cli` or any local lint:**

```bash
docker run --rm -v /volume2/docker/webtrees:/repo -w /repo node:20-alpine \
    sh -c "npx --yes markdownlint-cli2 README.md" 2>&1 | tail -10
```

Expected: no errors, or only `MD033` (inline HTML) / `MD041` (first-line h1) which are stylistic — fix as needed.

- [ ] **Step 9.3: Commit:**

```bash
git -C /volume2/docker/webtrees add README.md
git -C /volume2/docker/webtrees commit -m "$(cat <<'EOF'
Rewrite the README around the wizard quickstart

The previous README was a `git clone + scripts/setup.sh + make
enable-dev-mode + make up` walkthrough aimed at module developers.
The new top section is a one-liner aimed at self-hosters; the
existing developer-facing material survives as a six-line
`--mode dev` invocation at the bottom and points at docs/developing.md
(Phase 3 will fill that file).
EOF
)"
```

### Acceptance criteria

- `README.md` opens with the `curl | bash` one-liner.
- Both editions, both proxy modes, and the demo-tree variant are documented.
- The dev-mode invocation is short (≤6 lines).

---

## Task 10: CI smoke-test gains a demo edition

**Files:**
- Modify: `.github/workflows/build.yml`

### Goal

The smoke-test matrix grows a third edition `demo` that drives `--edition full --demo --no-up` and asserts the wizard wrote `demo.ged` (without bringing the stack up — the demo-import path can't be exercised in CI without a slow stack-up + DB ready wait, deferred to local E2E).

### Steps

- [ ] **Step 10.1: Update the smoke-test matrix.** Replace the edition line with:

```yaml
                edition: [core, full, demo]
```

And in the "Run installer (non-interactive)" step, branch on edition. Replace the existing step body with:

```yaml
              run: |
                  set -euo pipefail
                  mkdir -p "${SMOKE_DIR}"
                  if [ "${EDITION}" = "demo" ]; then
                      docker run --rm \
                          -v "${SMOKE_DIR}:/work" \
                          -v /var/run/docker.sock:/var/run/docker.sock \
                          "ghcr.io/magicsunday/webtrees/installer:${INSTALLER_TAG}" \
                          --non-interactive --force --no-up --no-admin \
                          --edition full --demo --demo-seed 42 \
                          --proxy standalone --port "${SMOKE_PORT}"
                      test -f "${SMOKE_DIR}/demo.ged"
                      head -5 "${SMOKE_DIR}/demo.ged"
                      grep -q "^2 VERS 5.5.1$" "${SMOKE_DIR}/demo.ged"
                      echo "demo edition: demo.ged emitted (skip stack-up)"
                      exit 0
                  fi
                  docker run --rm \
                      -v "${SMOKE_DIR}:/work" \
                      -v /var/run/docker.sock:/var/run/docker.sock \
                      "ghcr.io/magicsunday/webtrees/installer:${INSTALLER_TAG}" \
                      --non-interactive --force --no-up --no-admin \
                      --edition "${EDITION}" --proxy standalone --port "${SMOKE_PORT}"
```

(`exit 0` for the demo edition skips the subsequent stack-up + probe + teardown steps.)

The four follow-up steps (`Up stack`, `Wait for nginx healthy`, `Probe HTTP`, `Tear down`) keep their existing bodies but gain a guard at the top of each `run:`:

```yaml
              run: |
                  if [ "${EDITION:-${{ matrix.edition }}}" = "demo" ]; then
                      echo "demo edition: stack-up step skipped"
                      exit 0
                  fi
                  set -euo pipefail
                  ...
```

(Pass `EDITION` via job env at the smoke-test job level so all steps see it.)

- [ ] **Step 10.2: Local lint:**

```bash
docker run --rm -v /volume2/docker/webtrees:/repo -w /repo rhysd/actionlint:latest \
    .github/workflows/build.yml
```

Expected: no new errors compared to the pre-existing SC2129 (which Task 11 of Phase 2a left in place).

- [ ] **Step 10.3: Commit:**

```bash
git -C /volume2/docker/webtrees add .github/workflows/build.yml
git -C /volume2/docker/webtrees commit -m "$(cat <<'EOF'
Add the demo edition to the smoke-test matrix

The third edition cell runs the installer with --edition full --demo
--demo-seed 42 --no-up and asserts that demo.ged exists and carries
the GEDCOM 5.5.1 header. Subsequent stack-up / probe / teardown
steps short-circuit on the demo edition so CI does not have to wait
out the import — local E2E (Task 12) covers that path.
EOF
)"
```

### Acceptance criteria

- The smoke-test matrix produces `core`, `full`, `demo` cells.
- The demo cell asserts the GEDCOM header without bringing the stack up.

---

## Task 11: E2E local verification + spec sync

**Files:**
- Read-only verification of the dev-flow + demo-flow
- Modify: `docs/superpowers/specs/2026-05-11-out-of-the-box-self-host-design.md` if drift surfaces

### Goal

Build the installer locally, drive `--mode dev` against an isolated `/tmp` directory + a throw-away clone of the repo, verify the resulting `.env` matches the dev stack's expectations, then exercise `--mode standalone --demo` and confirm `demo.ged` is valid GEDCOM. Confirm the user's live dev stack stays untouched throughout.

### Steps

- [ ] **Step 11.1: Build the installer image locally:**

```bash
docker build -f installer/Dockerfile -t webtrees-installer:phase2b /volume2/docker/webtrees
docker run --rm webtrees-installer:phase2b --version
```

Expected: `webtrees-installer 0.1.0`.

- [ ] **Step 11.2: Test 1 — dev-flow non-interactive render-only.** Clone the repo into a temp dir, run the wizard, inspect the rendered `.env`:

```bash
TMPCLONE=$(mktemp -d /tmp/wt-phase2b-XXXXXX)
git clone /volume2/docker/webtrees "$TMPCLONE/repo"
docker run --rm \
    -v "$TMPCLONE/repo:/work" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    webtrees-installer:phase2b \
    --mode dev --non-interactive --force \
    --proxy standalone --port 50010 --pma-port 50011 \
    --dev-domain webtrees.localhost:50010 \
    --mariadb-root-password rootpw \
    --mariadb-database webtrees \
    --mariadb-user webtrees --mariadb-password devpw
cat "$TMPCLONE/repo/.env" | head -30
```

Verify:
- `ENVIRONMENT=development`.
- `COMPOSE_FILE=compose.yaml:compose.pma.yaml:compose.development.yaml:compose.publish.yaml`.
- `MARIADB_PASSWORD=devpw`, `MARIADB_ROOT_PASSWORD=rootpw`.
- `APP_PORT=50010`, `PMA_PORT=50011`, `DEV_DOMAIN=webtrees.localhost:50010`.
- `LOCAL_USER_ID` is non-zero (host UID detected).

- [ ] **Step 11.3: Test 2 — demo-tree generation, no stack-up.** Use `--mode standalone --demo --no-up`:

```bash
WORK=$(mktemp -d /tmp/wt-phase2b-demo-XXXXXX)
docker run --rm \
    -v "$WORK:/work" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    webtrees-installer:phase2b \
    --non-interactive --force --no-up --no-admin \
    --edition full --demo --demo-seed 42 \
    --proxy standalone --port 50010
test -f "$WORK/demo.ged"
head -3 "$WORK/demo.ged"
grep -c "^0 @I" "$WORK/demo.ged"  # count INDI records
```

Verify:
- `demo.ged` exists.
- File starts with `0 HEAD`.
- INDI record count is between 100 and 400.

- [ ] **Step 11.4: Test 3 — determinism.** Run the same command twice in different temp dirs and `diff` the GEDCOM files:

```bash
W1=$(mktemp -d /tmp/wt-phase2b-det-1-XXXXXX)
W2=$(mktemp -d /tmp/wt-phase2b-det-2-XXXXXX)
for W in "$W1" "$W2"; do
    docker run --rm -v "$W:/work" -v /var/run/docker.sock:/var/run/docker.sock \
        webtrees-installer:phase2b \
        --non-interactive --force --no-up --no-admin \
        --edition full --demo --demo-seed 42 \
        --proxy standalone --port 50010 >/dev/null
done
diff "$W1/demo.ged" "$W2/demo.ged" && echo "BYTE-IDENTICAL"
```

Expected: `BYTE-IDENTICAL` (the `diff` exits 0, no output).

- [ ] **Step 11.5: Cleanup:**

```bash
docker rmi webtrees-installer:phase2b
rm -rf /tmp/wt-phase2b-* 
```

- [ ] **Step 11.6: Verify live dev stack untouched:**

```bash
docker compose -p webtrees ps
```

Expected: same four containers, same uptime ± seconds.

- [ ] **Step 11.7: Spec sync.** Re-read `/volume2/docker/webtrees/docs/superpowers/specs/2026-05-11-out-of-the-box-self-host-design.md` sections "Wizard-Flow → Dev-Flow", "Demo-Tree", "Migration". Compare to the shipped behaviour. Common drift points to fix:

- Dev-flow's prompt order or default values.
- Demo-tree generator: spec says "Anzahl Personen (default 200)" — implementation does not expose a population knob (only `--demo-seed`). Either add `--demo-population` or update the spec.
- Spec's `make install` reference still refers to a make target that survives (it is invoked by `run_dev`).
- Migration: spec lists `dev-mode-status`, `enable-dev-mode`, `disable-dev-mode` as removed make targets — confirm they are gone.

If the spec drifts, fix it. If it does not, record "no drift" in your report.

- [ ] **Step 11.8: Final commit (if spec drifted):**

```bash
git -C /volume2/docker/webtrees add docs/superpowers/specs/
git -C /volume2/docker/webtrees commit -m "$(cat <<'EOF'
Sync the spec with the shipped Phase 2b wizard

[List the specific deltas you fixed.]
EOF
)"
```

If no drift surfaces, skip this commit and note "no drift".

### Acceptance criteria

- Tests 1, 2, 3 all pass.
- The dev stack at `/volume2/docker/webtrees` is unchanged.
- The spec describes the wizard as it actually behaves.

---

## Self-Review checklist

After all 11 tasks merge:

1. **Spec coverage:** Every "Wizard-Flow → Dev-Flow" and "Demo-Tree" bullet maps to a task above. Confirmed.
2. **Placeholder scan:** No `TBD`, `TODO`, `implement later`, or `similar to Task N` left in the plan. Confirmed.
3. **Type consistency:** `DevArgs`, `StandaloneArgs`, `HostInfo`, `GedcomDocument`, `Person`, `Family`, `Sex` defined exactly once each; every consumer references them by the same name. Confirmed.
4. **No back-compat:** `scripts/setup.sh` + `Make/modes.mk` deletions land in Task 8 with no migration stubs or symlinks left behind.
