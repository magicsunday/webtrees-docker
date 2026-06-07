"""Single source of truth for the BYOD (bring-your-own-database/-volumes)
cross-flag invariants shared across the install layers.

Three layers enforce the same rules: ``flow`` (operator-facing, raises
``PromptError`` worded in CLI flags), ``render`` (programmatic, raises
``ValueError`` worded in dataclass field names), and ``dev_flow`` (same
field wording as ``render``). Before this module each layer carried its
own copy of the predicate, so a field rename or a fourth caller inherited
whichever copy the developer found first.

Each function owns one predicate (and ``reuse_volumes_conflict_error`` the
canonical conflict ordering) and returns the finished message, or ``None``
when the invariant holds. The
deliberate CLI-flag-vs-field wording difference lives in the injected
``Naming`` vocabulary rather than in duplicated branches, so the caller
only wraps the message in its own exception type.

Underscore prefix follows the existing convention (`_alpine`, `_docker`,
`_cli_resolve`): implementation detail, not a public surface.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Naming:
    """Caller-side vocabulary for the BYOD invariant messages.

    ``flow`` speaks CLI flags (operator-facing, exit-code-2 PromptError);
    ``render`` and ``dev_flow`` speak dataclass field names (programmatic
    callers that bypass the CLI). The conflict labels are tracked
    separately from ``require_subject`` because ``render`` words the host
    invariant as ``use_external_db=True`` yet lists the reuse-volumes
    conflict as the bare ``use_external_db``.
    """

    require_subject: str
    host_object: str
    password_file_object: str
    reuse_subject: str
    conflict_use_external_db: str
    conflict_db_data_path: str
    conflict_media_path: str


CLI_FLAGS = Naming(
    require_subject="--use-external-db",
    host_object="--external-db-host <hostname-or-ip>",
    password_file_object=(
        "--external-db-password-file <path>; "
        "the file gets bind-mounted into phpfpm read-only"
    ),
    reuse_subject="--reuse-volumes",
    conflict_use_external_db="--use-external-db",
    conflict_db_data_path="--db-data-path",
    conflict_media_path="--media-path",
)

FIELD_NAMES = Naming(
    require_subject="use_external_db=True",
    host_object="external_db_host",
    password_file_object="external_db_password_file",
    reuse_subject="reuse_volumes_project",
    conflict_use_external_db="use_external_db",
    conflict_db_data_path="db_data_path",
    conflict_media_path="media_path",
)


def external_db_host_error(
    *, use_external_db: bool, host: str | None, naming: Naming
) -> str | None:
    """Return the host-required message when external-db is on without a host.

    External-db installs have no bundled ``db:`` service, so an empty host
    leaves ``MARIADB_HOST`` unresolved. Returns ``None`` when the invariant
    holds (external-db off, or a host is present).
    """
    if use_external_db and not host:
        return f"{naming.require_subject} requires {naming.host_object}"
    return None


def external_db_password_file_error(
    *, use_external_db: bool, password_file: str | None, naming: Naming
) -> str | None:
    """Return the password-file-required message when external-db is on
    without a password-file path.

    The file is bind-mounted into phpfpm read-only; an external-db install
    cannot authenticate without it. Returns ``None`` when the invariant
    holds.
    """
    if use_external_db and not password_file:
        return f"{naming.require_subject} requires {naming.password_file_object}"
    return None


def external_db_db_data_path_conflict_error(
    *, use_external_db: bool, db_data_path: bool, naming: Naming
) -> str | None:
    """Return the incompatibility message when external-db is combined
    with a ``--db-data-path`` bind-mount.

    ``--db-data-path`` bind-mounts the bundled ``db:`` service's
    /var/lib/mysql; with external-db there is no bundled ``db:`` service to
    mount into, so the two are mutually exclusive. The conflict labels
    carry the per-caller vocabulary (flags vs field names). Returns
    ``None`` when the invariant holds.
    """
    if use_external_db and db_data_path:
        # The remedy flags (--db-data-path / --external-db-host) are
        # intentionally CLI-worded in BOTH vocabularies: they name the
        # actionable fix the operator types regardless of which layer
        # raised, so they are not routed through the Naming vocabulary.
        # The "Drop --db-data-path and …" lead-in tells the operator which
        # of the two conflicting flags to remove — keep both halves.
        return (
            f"{naming.conflict_use_external_db} is incompatible with "
            f"{naming.conflict_db_data_path}: the bundled db service is "
            f"dropped, so there is nowhere to bind-mount the path. Drop "
            f"--db-data-path and point phpfpm at your existing DB via "
            f"--external-db-host."
        )
    return None


def reuse_volumes_conflict_error(
    *,
    use_external_db: bool,
    db_data_path: bool,
    media_path: bool,
    naming: Naming,
) -> str | None:
    """Return the mutual-exclusion message when ``--reuse-volumes`` is
    combined with another BYOD pattern.

    The reuse-volumes shortcut references an existing compose project's
    named volumes via ``external: true``; mixing it with any of the three
    BYOD flags produces a compose file compose itself rejects. The caller
    is expected to invoke this only when reuse-volumes is active. Returns
    ``None`` when no conflicting flag is set.
    """
    conflicts = (
        (naming.conflict_use_external_db, use_external_db),
        (naming.conflict_db_data_path, db_data_path),
        (naming.conflict_media_path, media_path),
    )
    active = [label for label, flag in conflicts if flag]
    if not active:
        return None
    return (
        f"{naming.reuse_subject} is incompatible with "
        f"{', '.join(active)}; "
        f"pick exactly one BYOD pattern per install."
    )
