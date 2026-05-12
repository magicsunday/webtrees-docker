"""Standalone-mode flow orchestrator."""

from __future__ import annotations

import os
import shlex
import subprocess
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import IO

from webtrees_installer._docker import run_docker
from webtrees_installer.demo import generate_tree
from webtrees_installer.gedcom import serialize
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
from webtrees_installer.stack import StackError, bring_up
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

    demo: bool
    demo_seed: int

    force: bool
    no_up: bool


_FALLBACK_PORT = 8080
_PROJECT_NAME = "webtrees"

# Test-patch seam: existing tests patch
# ``webtrees_installer.flow._resolve_manifest_dir``. The thin alias keeps
# that patch path working while the implementation lives in
# ``webtrees_installer.versions``. Tests that want to override the
# bake-location patch ``webtrees_installer.versions.DEFAULT_MANIFEST_DIR``
# directly — a flow-level alias on the constant would silently no-op
# because resolve_manifest_dir reads versions.DEFAULT_MANIFEST_DIR.
from webtrees_installer.versions import (  # noqa: E402
    resolve_manifest_dir as _resolve_manifest_dir,
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

    catalog = load_catalog(_resolve_manifest_dir())
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
    render_files(input_model=render_input, target_dir=work_dir)

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

    demo_gedcom: Path | None = None
    if args.demo:
        demo_gedcom = _write_demo_gedcom(work_dir=work_dir, seed=args.demo_seed)
        if stdout:
            print(f"Demo GEDCOM written to {demo_gedcom}", file=stdout)

    if not args.no_up:
        # bring_up may raise StackError; let it bubble. The CLI layer
        # catches it and returns exit code 3 so the error goes through
        # the same stderr channel as PrereqError / PromptError.
        bring_up(work_dir=work_dir)
        if demo_gedcom is not None:
            _import_demo_tree(work_dir=work_dir, gedcom_path=demo_gedcom)
            if stdout:
                print("Demo tree imported into the `demo` tree.", file=stdout)

    return 0


def _resolve_port(
    args: StandaloneArgs,
    *,
    stdin: IO[str] | None,
    stdout: IO[str] | None,
) -> int:
    """Ask for the port, probe it, fall back to 8080 if busy, warn on probe failure."""
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

    if port == _FALLBACK_PORT:
        raise PrereqError(
            f"port {port} is in use; pass --port to pick a free one"
        )

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
    volume = f"{_PROJECT_NAME}_secrets"

    subprocess.run(
        ["docker", "volume", "create", volume],
        check=True, capture_output=True, text=True,
    )
    try:
        subprocess.run(
            [
                "docker", "run", "--rm", "-i",
                "--pull=missing", "--quiet",
                "-v", f"{volume}:/secrets",
                "alpine:3.20",
                "sh", "-ec",
                "umask 077 && cat > /secrets/wt_admin_password && chmod 444 /secrets/wt_admin_password",
            ],
            input=password,
            check=True, capture_output=True, text=True,
        )
    except subprocess.CalledProcessError as exc:
        # Pre-seeding into the volume failed; the volume itself was either
        # just created or already existed but is now in an indeterminate
        # state (alpine may have partially written the file). Drop it so
        # the next run starts clean, then re-raise as PrereqError so the
        # CLI surfaces a clean message instead of a Python traceback.
        subprocess.run(
            ["docker", "volume", "rm", "-f", volume],
            check=False, capture_output=True, text=True,
        )
        stderr = (exc.stderr or "").strip() or "<no stderr>"
        raise PrereqError(
            f"failed to pre-seed admin password into {volume}: {stderr}"
        ) from exc

    _write_secret_file(work_dir / ".webtrees-admin-password", password)


def _write_secret_file(path: Path, password: str) -> None:
    """Write the admin password to `path` with 0600 from the first byte.

    `Path.write_text` followed by `chmod` opens the file with the process
    umask (typically 0022 → 0644) and leaves a syscall window during which
    a concurrent reader could see the secret. `os.open` with the explicit
    permission mask closes that window. If anything between `os.open` and
    `os.fdopen` raises, the raw fd is closed explicitly so we never leak.
    """
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        fp = os.fdopen(fd, "w")
    except Exception:
        os.close(fd)
        raise
    with fp:
        fp.write(password + "\n")


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


def _write_demo_gedcom(*, work_dir: Path, seed: int) -> Path:
    """Generate the demo GEDCOM and write it next to compose.yaml."""
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
        result = run_docker(step, cwd=work_dir)
        if result.returncode != 0:
            # `shlex.join` keeps the quoting intact so a user copy-pasting
            # the failing command runs exactly what the wizard tried,
            # rather than a flattened bag of tokens.
            raise StackError(
                f"demo-tree import step failed: {shlex.join(['docker', *step])}\n"
                f"{result.stderr.strip() or result.stdout.strip()}"
            )
