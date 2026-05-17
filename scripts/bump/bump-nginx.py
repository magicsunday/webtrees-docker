#!/usr/bin/env python3
"""Bump the canonical nginx pin in dev/nginx-version.json + sync mirrors.

Used to action a `check-nginx.yml` tracking issue (or any operator-
driven nginx minor bump). One-shot tooling — the lockstep test
`test_nginx_tag_lockstep` is the safety net that catches drift if a
future mirror site is added but this script is not updated.

Behaviour:
  1. Read dev/nginx-version.json to learn the current pin.
  2. Refuse if (new minor, config_revision) matches the current
     pin exactly — idempotency check. A different minor with the
     same `config_revision` is a normal bump.
  3. Write the new canonical: `nginx_base`, `config_revision`
     (defaults to 1; pass `--config-revision N` to override —
     typically only useful for a same-minor nginx.conf revision),
     `tag=<base>-r<revision>`. The new minor must be even (nginx's
     stable line); odd minors are mainline and policy-rejected.
     See docs/maintenance.md → Stable-only policy.
  4. sed-replace every `webtrees-nginx:<OLD_TAG>` literal in the five
     mirror sites enforced by `test_nginx_tag_lockstep._TAG_SITES`.
  5. Print a next-steps reminder (review release notes, smoke matrix,
     PR open).

Exit codes:
  0 — bump applied; mirrors in sync.
  1 — input validation failed (same minor, missing canonical, missing
      mirror site, malformed argv).
  2 — usage error.
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

_CANONICAL = pathlib.Path("dev/nginx-version.json")

_MIRROR_SITES: tuple[str, ...] = (
    "Make/ci.mk",
    "tests/test-nginx-config.sh",
    "tests/test-trust-proxy-extra.sh",
    "templates/portainer/compose.yaml",
    "README.md",
)

_MINOR_RE = re.compile(r"^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$")
_TAG_RE = re.compile(r"webtrees-nginx:([0-9]+\.[0-9]+-r[0-9]+)")


def _resolve_new_tag(new_minor: str, config_revision: int) -> str:
    """Return the canonical tag string for the new pin."""
    return f"{new_minor}-r{config_revision}"


def _read_canonical(root: pathlib.Path) -> tuple[str, int, str]:
    """Return (nginx_base, config_revision, tag) from dev/nginx-version.json."""
    raw = json.loads((root / _CANONICAL).read_text(encoding="utf-8"))
    return raw["nginx_base"], int(raw["config_revision"]), raw["tag"]


def _write_canonical(root: pathlib.Path, base: str, revision: int, tag: str) -> None:
    """Write the canonical pin JSON in the format the file already uses."""
    body = {
        "nginx_base": base,
        "config_revision": revision,
        "tag": tag,
    }
    (root / _CANONICAL).write_text(
        json.dumps(body, indent=4) + "\n", encoding="utf-8"
    )


def _replace_in_mirror(path: pathlib.Path, old_tag: str, new_tag: str) -> int:
    """Replace every `webtrees-nginx:OLD_TAG` literal with `:NEW_TAG`.

    Returns the number of substitutions made. A mirror with zero hits
    is a structural drift indicator (the file no longer pins nginx in
    the expected form) — caller fails loud.
    """
    text = path.read_text(encoding="utf-8")
    # Negative lookahead `(?![-\w])` instead of `\b` so a future
    # `-debug`-suffixed tag (`1.30-r1-debug`) does NOT match — `\b`
    # would treat the hyphen as a word boundary and silently corrupt
    # the suffix. The tag shape is bare `X.Y-rN`; the right-context
    # guard expresses that intent explicitly.
    new_text, n = re.subn(
        rf"webtrees-nginx:{re.escape(old_tag)}(?![-\w])",
        f"webtrees-nginx:{new_tag}",
        text,
    )
    if n > 0:
        path.write_text(new_text, encoding="utf-8")
    return n


def bump(root: pathlib.Path, new_minor: str, config_revision: int = 1) -> int:
    """Apply the bump under `root`; return a CLI exit code."""
    if not _MINOR_RE.fullmatch(new_minor):
        print(
            f"::error::new minor {new_minor!r} must match X.Y "
            f"(e.g. '1.30'); patch-pins like 1.30.1 are policy-rejected",
            file=sys.stderr,
        )
        return 1
    # nginx publishes even-numbered minors on the stable line (1.26,
    # 1.28, 1.30, …) and odd minors on mainline (1.27, 1.29, 1.31, …).
    # This project pins stable only; an odd-minor bump would route
    # mainline (experimental) code into production. See
    # docs/maintenance.md → "Stable-only policy" for the rationale.
    new_parts = tuple(int(p) for p in new_minor.split("."))
    if new_parts[1] % 2 != 0:
        print(
            f"::error::new minor {new_minor!r} is mainline "
            f"(odd-numbered minor); project pins stable only "
            f"(even-numbered: 1.26, 1.28, 1.30, …). "
            f"See docs/maintenance.md → Stable-only policy.",
            file=sys.stderr,
        )
        return 1

    canonical_path = root / _CANONICAL
    if not canonical_path.is_file():
        print(
            f"::error::canonical file missing: {canonical_path}",
            file=sys.stderr,
        )
        return 1

    try:
        current_base, current_rev, current_tag = _read_canonical(root)
    except (json.JSONDecodeError, KeyError, ValueError) as exc:
        print(
            f"::error::canonical malformed at {_CANONICAL}: "
            f"{type(exc).__name__}: {exc}. "
            f"Restore a clean `{{\"nginx_base\":\"X.Y\","
            f"\"config_revision\":N,\"tag\":\"X.Y-rN\"}}` JSON file "
            f"before bumping.",
            file=sys.stderr,
        )
        return 1

    # Sanity-check the CURRENT pin too: a regression / bad merge could
    # leave canonical on an odd (mainline) minor, in which case the
    # mirror sync below would diagnose "missing literal" and misdirect
    # the operator to fix the mirrors. Fail loud on the actual root
    # cause instead.
    if not _MINOR_RE.fullmatch(current_base):
        print(
            f"::error::canonical nginx_base={current_base!r} is "
            f"malformed; restore a clean X.Y stable pin before bumping",
            file=sys.stderr,
        )
        return 1
    current_parts = tuple(int(p) for p in current_base.split("."))
    if current_parts[1] % 2 != 0:
        print(
            f"::error::canonical nginx_base={current_base!r} is "
            f"on the mainline (odd-minor) branch — the canonical is "
            f"in a policy-violating state. Restore the previous stable "
            f"minor in dev/nginx-version.json before bumping forward.",
            file=sys.stderr,
        )
        return 1

    if new_minor == current_base and config_revision == current_rev:
        print(
            f"::error::pin already at {current_tag}; pass "
            f"--config-revision <N> to bump the config-revision "
            f"counter only, or supply a different minor",
            file=sys.stderr,
        )
        return 1

    # Monotonic-bump guard: refuse to downgrade silently. A genuine
    # rollback (e.g. reverting a bad stable release or backing out a
    # nginx.conf revision) must be done by editing
    # dev/nginx-version.json by hand so the choice is explicit in
    # the commit history. The comparison includes config_revision so
    # a same-minor revision rollback (r3 → r1) is also rejected.
    if (new_parts, config_revision) < (current_parts, current_rev):
        print(
            f"::error::new pin {new_minor}-r{config_revision} is "
            f"older than the current pin {current_tag}; this tool "
            f"refuses to downgrade silently. Edit dev/nginx-version.json "
            f"by hand if a rollback is genuinely intended.",
            file=sys.stderr,
        )
        return 1

    new_tag = _resolve_new_tag(new_minor, config_revision)
    _write_canonical(root, new_minor, config_revision, new_tag)

    drift: list[str] = []
    for relative in _MIRROR_SITES:
        mirror = root / relative
        if not mirror.is_file():
            drift.append(f"missing: {relative}")
            continue
        hits = _replace_in_mirror(mirror, current_tag, new_tag)
        if hits == 0:
            drift.append(f"no `webtrees-nginx:{current_tag}` literal in {relative}")

    if drift:
        print("::error::mirror sync failed; canonical was updated but:", file=sys.stderr)
        for row in drift:
            print(f"  - {row}", file=sys.stderr)
        print(
            "Fix the mirrors manually or revert dev/nginx-version.json. "
            "Run `make ci-pytest` to see the exact drift the lockstep "
            "test reports.",
            file=sys.stderr,
        )
        return 1

    print(f"Bumped nginx pin {current_tag} -> {new_tag}")
    print(f"  canonical: {_CANONICAL}")
    for relative in _MIRROR_SITES:
        print(f"  mirror:    {relative}")
    print()
    print("Next steps:")
    print(f"  1. Review release notes for nginx {new_minor}.")
    print("  2. Run `make ci-pytest ci-lockstep-tests ci-nginx-config`.")
    print("  3. Open a PR; `build.yml` will rebuild the nginx image stage.")
    print("  4. After merge, pull the new image on the live host:")
    print(f"     docker pull ghcr.io/magicsunday/webtrees-nginx:{new_tag}")
    return 0


def main() -> int:
    """Parse argv, dispatch the bump, return a CLI exit code."""
    argv = sys.argv[1:]
    config_revision = 1
    while argv and argv[0].startswith("--"):
        flag = argv.pop(0)
        if flag == "--config-revision":
            if not argv:
                print("::error::--config-revision needs an integer", file=sys.stderr)
                return 2
            try:
                config_revision = int(argv.pop(0))
            except ValueError:
                print("::error::--config-revision must be an integer", file=sys.stderr)
                return 2
            if config_revision < 1:
                print(
                    "::error::--config-revision must be a positive integer "
                    "(>= 1); negative or zero values produce malformed "
                    "tag shapes like `1.32-r-5` that the lockstep test "
                    "would mis-diagnose as a mirror drift.",
                    file=sys.stderr,
                )
                return 2
        else:
            print(f"::error::unknown flag {flag!r}", file=sys.stderr)
            return 2

    if len(argv) != 1:
        print(
            f"usage: {sys.argv[0]} [--config-revision N] <new-minor>\n"
            f"  e.g. {sys.argv[0]} 1.32\n"
            f"       {sys.argv[0]} --config-revision 2 1.30\n"
            f"  flags must precede the positional <new-minor>\n"
            f"  <new-minor> must be even (stable line); see "
            f"docs/maintenance.md",
            file=sys.stderr,
        )
        return 2
    return bump(pathlib.Path.cwd(), argv[0], config_revision=config_revision)


if __name__ == "__main__":
    sys.exit(main())
