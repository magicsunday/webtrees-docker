"""Standalone-mode flow orchestrator."""

from __future__ import annotations

import os
import re
import shlex
import subprocess
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import IO

from webtrees_installer._alpine import ALPINE_BASE_IMAGE
from webtrees_installer._docker import run_docker
from webtrees_installer.demo import generate_tree
from webtrees_installer._cli_resolve import resolve_enforce_https
from webtrees_installer.gedcom import serialize
from webtrees_installer.ports import PortStatus, probe_port
from webtrees_installer.prereq import (
    PrereqError,
    check_prerequisites,
    confirm_overwrite,
)
from webtrees_installer.prompts import (
    TRAEFIK_TLS_INCOMPAT_REASON,
    Choice,
    PromptError,
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

    # Tristate, mirrors admin_bootstrap above: None = operator didn't
    # pass --no-https; True/False = explicit choice. Resolved to a
    # concrete bool by run_standalone before render time.
    enforce_https: bool | None

    pretty_urls: bool

    force: bool
    no_up: bool


# Default + fallback ports live in the 28k range (out of the
# 80/8080 drive-by-scan band) to reduce bot traffic on a fresh
# install. Operators still override via `--port`.
#
# Mirrors (keep in lockstep when bumping — run `grep -rn 2808`
# across the repo to catch any new sites for either port):
#   - compose.publish.yaml      `${APP_PORT:-28080}`
#   - switch                    `env_value APP_PORT 28080`
#   - upgrade                   `--port 28080` (no-arg default)
#   - install                   `--port 28080` (usage comment)
#   - README.md                 quickstart + upgrade examples
#                               (default), troubleshooting (fallback)
#   - docs/customizing.md       APP_PORT row
#   - docs/developing.md        render-only smoke example
#   - docs/env-vars.md          APP_PORT default cell
_DEFAULT_PORT = 28080
_FALLBACK_PORT = 28081

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

    _handle_surviving_volumes(
        work_dir=work_dir,
        interactive=args.interactive,
        stdin=stdin,
        stdout=stdout,
    )

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

    # Second-layer guard for the --no-https + traefik combo: cli.py's
    # _validate_mode_compatibility only fires when the operator passes
    # both flags non-interactively. If proxy_mode comes from this prompt
    # (operator passed only --no-https), the CLI check sees
    # args.proxy_mode is None and skips the rejection — and we would
    # otherwise render the inconsistent stack (websecure router + TLS
    # labels but ENFORCE_HTTPS=FALSE at the app layer).
    if proxy_mode == "traefik" and args.enforce_https is False:
        raise PromptError(
            "--no-https is incompatible with proxy mode 'traefik': "
            f"{TRAEFIK_TLS_INCOMPAT_REASON}. "
            "Drop --no-https for Traefik, or pick standalone at the proxy prompt."
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

    # Resolve the tristate via the shared helper. The standalone flow
    # doesn't read an existing .env (env_value=None), so resolution
    # collapses to "explicit CLI value, else the wizard default of True".
    enforce_https = resolve_enforce_https(
        cli_value=args.enforce_https,
        env_value=None,
    )

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
        enforce_https=enforce_https,
        pretty_urls=args.pretty_urls,
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
        enforce_https=enforce_https,
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
    """Ask for the port, probe it, fall back to ``_FALLBACK_PORT`` if busy, warn on probe failure."""
    requested = ask_text(
        "Host port for the webtrees UI",
        default=str(_DEFAULT_PORT),
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


def _compose_project_name(work_dir: Path) -> str:
    """Mirror docker compose v2's project-name derivation: honour
    `COMPOSE_PROJECT_NAME` if set, else lowercase the cwd basename and
    strip every char that isn't `[a-z0-9_-]`. Raises `PrereqError` when
    `work_dir` is the in-container mount point `/work` and the env var
    is unset — refuses to silently mismatch the secrets volume.

    Used to align the wizard's pre-seeded secrets volume with the volume
    compose actually mounts at runtime — a custom derivation would land
    in a different bucket whenever the cwd had uppercase letters or
    special chars.

    The wizard runs inside the installer container with cwd `/work`, so
    its idea of "cwd basename" is the mount point — not the user's
    install directory. The launchers therefore export
    `COMPOSE_PROJECT_NAME` derived from the host's cwd before invoking
    the wizard; this helper honours that env var first so the pre-seed
    volume and the runtime compose stack agree on the project name even
    when the host path differs from the in-container mount, includes
    symlink hops, or contains characters compose strips. `.resolve()` is
    deliberately NOT called on `work_dir`: compose v2 derives its name
    from the logical (PWD) cwd basename, not the realpath, and the
    bash launchers use `basename "$(pwd)"` for the same reason — keep
    the three derivations symmetrical.
    """
    env_name = os.environ.get("COMPOSE_PROJECT_NAME")
    if env_name:
        normalized = re.sub(r"[^a-z0-9_-]", "", env_name.lower())
        if not normalized:
            raise PrereqError(
                f"compose project name derived from COMPOSE_PROJECT_NAME={env_name!r} "
                "is empty after normalisation; pick an alphanumeric value"
            )
        return normalized

    # Without COMPOSE_PROJECT_NAME, work_dir.name is the only signal — but
    # inside the installer container that name is "work" (the in-container
    # mount point of `-v <hostdir>:/work`). Pre-seeding the secrets volume
    # as `work_secrets` while compose-up on the host mounts
    # `<hostdir>_secrets` silently mismatches: the operator-facing banner
    # shows the installer-generated password but the running stack uses
    # whatever the init container random-generated when the empty volume
    # turned up. Refuse to guess — force the caller (the bundled `install`
    # launcher, CI, or a manual `docker run`) to pass the env var.
    if work_dir.name == "work":
        raise PrereqError(
            "COMPOSE_PROJECT_NAME is not set and work_dir is the in-container "
            "mount point `/work`. Without the env var the installer cannot "
            "derive the same project name compose will use on the host, so "
            "the secrets volume would be mismatched. Re-run with "
            "`-e COMPOSE_PROJECT_NAME=<your-project-name>` (the bundled "
            "`install` launcher does this for you)."
        )

    normalized = re.sub(r"[^a-z0-9_-]", "", work_dir.name.lower())
    if not normalized:
        raise PrereqError(
            f"compose project name derived from {work_dir.name!r} is empty "
            "after normalisation; set COMPOSE_PROJECT_NAME to an "
            "alphanumeric value or rename your install directory"
        )
    return normalized


def _extract_subprocess_detail(exc: Exception) -> str:
    """Render a one-line diagnostic for both subprocess failure classes.

    ``CalledProcessError`` carries the child's stderr; ``OSError``
    (binary missing, exec bit dropped, socket EACCES at connect)
    carries ``strerror`` plus a ``filename``. Either way the caller
    wants the most-specific available detail folded into the
    PrereqError message without branching at every wrap site.

    Defensive about the stderr attribute's type: a future wrap site
    that drops ``text=True`` (or hands a custom wrapper a non-string
    stderr) would otherwise leak a ``b'...'`` literal into the
    operator-facing message, or escape ``AttributeError`` past the
    PrereqError translation when ``.strip()`` is called on a non-str.
    """
    stderr_raw = getattr(exc, "stderr", None)
    if isinstance(stderr_raw, bytes):
        stderr = stderr_raw.decode("utf-8", errors="replace").strip()
    elif isinstance(stderr_raw, str):
        stderr = stderr_raw.strip()
    else:
        stderr = ""
    if stderr:
        return stderr
    # OSError / its subclasses: prefer strerror (+ filename when set).
    strerror_raw = getattr(exc, "strerror", None)
    strerror = strerror_raw if isinstance(strerror_raw, str) else ""
    if strerror:
        filename = getattr(exc, "filename", None)
        return f"{strerror} ({filename})" if filename else strerror
    # Last resort: str(exc) usually carries enough context even for
    # exotic subclasses without stderr/strerror attributes.
    return str(exc) or "<no detail>"


def _list_surviving_volumes(work_dir: Path) -> list[str]:
    """Return docker volumes named `<project>_*` that already exist
    on the daemon.

    These survive `rm -rf <work_dir>` because they live in the docker
    namespace, not on the filesystem the user deleted. On the next
    `compose up` they are silently re-mounted with their stale data —
    the installer's freshly-generated admin password would then never
    match the running stack.

    When the project name cannot be derived (cwd is `/work` and
    COMPOSE_PROJECT_NAME is unset — typical for the `--no-admin
    --no-up` CI smoke cells that never materialise a secrets volume)
    we cannot scope the scan, so report "nothing surviving" rather
    than aborting an otherwise-valid run.
    """
    try:
        project = _compose_project_name(work_dir)
    except PrereqError:
        return []
    try:
        result = subprocess.run(
            [
                "docker", "volume", "ls",
                "--filter", f"name=^{project}_",
                "--format", "{{.Name}}",
            ],
            check=True, capture_output=True, text=True,
        )
    except (subprocess.CalledProcessError, OSError) as exc:
        # Catch both classes of failure:
        #   * CalledProcessError — docker ran but returned non-zero
        #     (daemon down, permission denied on the socket, filter
        #     syntax reshaped on a future CLI version).
        #   * OSError (incl. FileNotFoundError / PermissionError) —
        #     subprocess never executed docker at all (binary missing
        #     from PATH, exec bit dropped). Surface both as PrereqError
        #     so cli.py's _run_with_exit_codes translates them into a
        #     clean exit 2 with the underlying detail instead of a bare
        #     Python traceback.
        raise PrereqError(
            f"failed to list docker volumes for project '{project}':"
            f" {_extract_subprocess_detail(exc)}"
        ) from exc
    return [name for name in result.stdout.splitlines() if name.strip()]


def _wipe_volumes(volumes: list[str]) -> None:
    """Force-remove the named docker volumes one at a time.

    No-op on an empty list. Iterates per-volume so a single
    held-by-sibling-stack volume cannot trip the whole wipe and leave
    the operator with a partial-wipe state: every volume gets its own
    `docker volume rm -f` invocation. Successes proceed; failures are
    collected and surfaced as a single PrereqError at the end so the
    operator can see exactly which volumes still need manual cleanup.
    """
    if not volumes:
        return

    failures: list[tuple[str, str]] = []
    for volume in volumes:
        try:
            subprocess.run(
                ["docker", "volume", "rm", "-f", volume],
                check=True, capture_output=True, text=True,
            )
        except (subprocess.CalledProcessError, OSError) as exc:
            # Common case: the volume is still mounted by another stack
            # sharing the project-name prefix. Daemon-down / docker-
            # missing also lands here. Record and keep going.
            failures.append((volume, _extract_subprocess_detail(exc)))

    if failures:
        lines = [f"  - {name}: {detail}" for name, detail in failures]
        raise PrereqError(
            "failed to remove the following docker volumes "
            "(other volumes in the same batch may have succeeded; "
            "run `docker compose -p <project> down -v` to release "
            "any remaining mounts, then re-run the installer):\n"
            + "\n".join(lines)
        )


def _handle_surviving_volumes(
    *,
    work_dir: Path,
    interactive: bool,
    stdin: IO[str] | None,
    stdout: IO[str] | None,
) -> None:
    """Detect docker volumes left behind by an earlier install at the
    same project name and let the operator deal with them. In
    interactive mode the operator is prompted (default: keep, because
    wiping data is irreversible). In non-interactive mode the
    volumes are preserved and a loud warning is printed — automating
    a destructive default would let a stray CI run torch user data.
    """
    surviving = _list_surviving_volumes(work_dir)
    if not surviving:
        return

    project = _compose_project_name(work_dir)
    volume_list = ", ".join(surviving)
    volume_args = " ".join(surviving)
    # `compose down` first because docker volume rm refuses to delete a
    # volume that is still mounted by a running container.
    cleanup_lines = (
        f"    docker compose -p {project} down",
        f"    docker volume rm {volume_args}",
    )

    if interactive:
        wipe = ask_yesno(
            f"Existing docker volumes from a previous install were detected: "
            f"{volume_list}. These will be re-mounted on the next `compose up` "
            "and the install banner's admin password may not match the data "
            "they carry. Wipe them now? (irreversible)",
            default=False,
            stdin=stdin,
            stdout=stdout,
        )
        if wipe:
            _wipe_volumes(surviving)
            if stdout:
                print(f"Wiped {len(surviving)} stale volume(s).", file=stdout)
        else:
            if stdout:
                print(
                    "Keeping existing volumes — admin password from the "
                    "banner below may not match the running stack. To start "
                    "clean later, run (irreversible):",
                    file=stdout,
                )
                for line in cleanup_lines:
                    print(line, file=stdout)
        return

    # Non-interactive: never auto-delete data. Loud warning + ready-to-paste
    # cleanup commands so the operator does not have to assemble the volume
    # list by hand.
    if stdout:
        print(file=stdout)
        print(
            f"WARNING: existing docker volumes from a previous install at "
            f"this project name were detected: {volume_list}. They will be "
            "re-mounted on the next `compose up`, so the install banner's "
            "admin password may not match the running stack.",
            file=stdout,
        )
        print(
            "To start clean (data loss — irreversible), run:",
            file=stdout,
        )
        for line in cleanup_lines:
            print(line, file=stdout)
        print(file=stdout)


def _write_admin_password_secret(*, work_dir: Path, password: str) -> None:
    """Pre-seed the secrets volume with the wizard's admin password.

    The init container's command checks `[ -s "/secrets/wt_admin_password" ]`
    and only generates a fresh password if the file is empty. By creating the
    project-scoped volume (`<project>_secrets`, where `<project>` mirrors
    compose's own project-name derivation) up-front and writing the password
    through an ephemeral alpine container, the init step finds the file
    already populated and leaves it alone — which means the password the
    wizard shows in the banner is the one the bootstrap hook will use.
    """
    volume = f"{_compose_project_name(work_dir)}_secrets"

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
                ALPINE_BASE_IMAGE,
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


def _print_banner(
    *,
    stdout: IO[str] | None,
    work_dir: Path,
    proxy_mode: str,
    app_port: int | None,
    domain: str | None,
    admin_user: str | None,
    admin_password: str | None,
    enforce_https: bool,
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
        scheme = "https" if enforce_https else "http"
        print(f"Webtrees URL: {scheme}://localhost:{app_port}/", file=stdout)
    else:
        print(f"Webtrees URL: https://{domain}/", file=stdout)

    if enforce_https and proxy_mode == "standalone":
        print(file=stdout)
        print(
            "NOTE: ENFORCE_HTTPS=TRUE. nginx will redirect plain HTTP to "
            "HTTPS — point a TLS-terminating reverse proxy (Caddy, "
            "nginx-on-host, Cloudflare tunnel, …) at the published port, "
            "or re-run with --no-https for a plaintext local install.",
            file=stdout,
        )

    if admin_user is not None:
        # GitHub Actions log redaction: emit ::add-mask:: so the password is
        # rewritten to *** in any subsequent log capture (the smoke job's
        # installer stdout is publicly visible). Harmless outside GHA — the
        # directive is just a normal line that the runner consumes.
        if admin_password is not None and os.environ.get("GITHUB_ACTIONS") == "true":
            print(f"::add-mask::{admin_password}", file=stdout)

        print(file=stdout)
        print("WARNING: the box below contains a cleartext password — redact before sharing.", file=stdout)
        print("╔══════════════════════════════════════════════════════════════╗", file=stdout)
        print("║                 webtrees admin credentials                   ║", file=stdout)
        print("╠══════════════════════════════════════════════════════════════╣", file=stdout)
        print(f"║  user:      {admin_user:<48} ║", file=stdout)
        print(f"║  password:  {admin_password:<48} ║", file=stdout)
        print("╚══════════════════════════════════════════════════════════════╝", file=stdout)
        print(
            "The password is autogenerated and not saved to disk — copy it "
            "now. Rotate after first login (Control panel → Users).",
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
