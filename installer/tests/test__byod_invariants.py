"""Tests for the shared BYOD cross-flag invariants.

The three install layers (flow / render / dev_flow) used to enforce the
same `use_external_db AND not <host>` rule with three different exception
classes, field names, and wordings. `_byod_invariants` is the single
source of truth for the predicates and the canonical reuse-volumes
conflict ordering; the deliberate CLI-flag-vs-field wording difference
survives as the injected `Naming` vocabulary. Each function returns the
finished message, or `None` when the invariant holds, so a caller only
wraps it in its own exception type.

These tests pin the exact messages both vocabularies produce so a
refactor that drifts the wording — the very thing the module exists to
prevent — fails loudly.
"""

from __future__ import annotations

from webtrees_installer._byod_invariants import (
    CLI_FLAGS,
    FIELD_NAMES,
    external_db_db_data_path_conflict_error,
    external_db_host_error,
    external_db_password_file_error,
    reuse_volumes_conflict_error,
)


class TestExternalDbHostError:
    def test_holds_when_external_db_off(self) -> None:
        assert external_db_host_error(
            use_external_db=False, host="", naming=FIELD_NAMES
        ) is None

    def test_holds_when_host_present(self) -> None:
        assert external_db_host_error(
            use_external_db=True, host="db.internal", naming=FIELD_NAMES
        ) is None

    def test_cli_wording_on_empty_host(self) -> None:
        assert external_db_host_error(
            use_external_db=True, host="", naming=CLI_FLAGS
        ) == "--use-external-db requires --external-db-host <hostname-or-ip>"

    def test_field_wording_on_empty_host(self) -> None:
        assert external_db_host_error(
            use_external_db=True, host="", naming=FIELD_NAMES
        ) == "use_external_db=True requires external_db_host"

    def test_none_host_is_treated_as_missing(self) -> None:
        assert external_db_host_error(
            use_external_db=True, host=None, naming=FIELD_NAMES
        ) == "use_external_db=True requires external_db_host"


class TestExternalDbPasswordFileError:
    def test_holds_when_external_db_off(self) -> None:
        assert external_db_password_file_error(
            use_external_db=False, password_file="", naming=CLI_FLAGS
        ) is None

    def test_holds_when_password_file_present(self) -> None:
        assert external_db_password_file_error(
            use_external_db=True, password_file="/run/secrets/db", naming=CLI_FLAGS
        ) is None

    def test_cli_wording_on_empty_password_file(self) -> None:
        assert external_db_password_file_error(
            use_external_db=True, password_file="", naming=CLI_FLAGS
        ) == (
            "--use-external-db requires --external-db-password-file <path>; "
            "the file gets bind-mounted into phpfpm read-only"
        )

    def test_field_wording_on_empty_password_file(self) -> None:
        assert external_db_password_file_error(
            use_external_db=True, password_file="", naming=FIELD_NAMES
        ) == "use_external_db=True requires external_db_password_file"


class TestReuseVolumesConflictError:
    def test_holds_when_no_conflict_active(self) -> None:
        assert reuse_volumes_conflict_error(
            use_external_db=False,
            db_data_path=False,
            media_path=False,
            naming=FIELD_NAMES,
        ) is None

    def test_cli_wording_lists_every_active_conflict_in_order(self) -> None:
        assert reuse_volumes_conflict_error(
            use_external_db=True,
            db_data_path=True,
            media_path=True,
            naming=CLI_FLAGS,
        ) == (
            "--reuse-volumes is incompatible with "
            "--use-external-db, --db-data-path, --media-path; "
            "pick exactly one BYOD pattern per install."
        )

    def test_field_wording_lists_every_active_conflict_in_order(self) -> None:
        assert reuse_volumes_conflict_error(
            use_external_db=True,
            db_data_path=True,
            media_path=True,
            naming=FIELD_NAMES,
        ) == (
            "reuse_volumes_project is incompatible with "
            "use_external_db, db_data_path, media_path; "
            "pick exactly one BYOD pattern per install."
        )

    def test_single_active_conflict_only_names_that_one(self) -> None:
        assert reuse_volumes_conflict_error(
            use_external_db=False,
            db_data_path=True,
            media_path=False,
            naming=CLI_FLAGS,
        ) == (
            "--reuse-volumes is incompatible with --db-data-path; "
            "pick exactly one BYOD pattern per install."
        )

    def test_first_flag_alone_maps_to_its_own_label(self) -> None:
        assert reuse_volumes_conflict_error(
            use_external_db=True,
            db_data_path=False,
            media_path=False,
            naming=CLI_FLAGS,
        ) == (
            "--reuse-volumes is incompatible with --use-external-db; "
            "pick exactly one BYOD pattern per install."
        )

    def test_last_flag_alone_maps_to_its_own_label(self) -> None:
        assert reuse_volumes_conflict_error(
            use_external_db=False,
            db_data_path=False,
            media_path=True,
            naming=CLI_FLAGS,
        ) == (
            "--reuse-volumes is incompatible with --media-path; "
            "pick exactly one BYOD pattern per install."
        )

    def test_gapped_pair_keeps_canonical_order_not_input_order(self) -> None:
        # use_external_db + media_path active, db_data_path skipped: proves
        # the join emits "first, third" by canonical field order rather
        # than echoing the order flags happened to be passed.
        assert reuse_volumes_conflict_error(
            use_external_db=True,
            db_data_path=False,
            media_path=True,
            naming=CLI_FLAGS,
        ) == (
            "--reuse-volumes is incompatible with "
            "--use-external-db, --media-path; "
            "pick exactly one BYOD pattern per install."
        )

    def test_field_wording_single_active_conflict(self) -> None:
        assert reuse_volumes_conflict_error(
            use_external_db=False,
            db_data_path=True,
            media_path=False,
            naming=FIELD_NAMES,
        ) == (
            "reuse_volumes_project is incompatible with db_data_path; "
            "pick exactly one BYOD pattern per install."
        )


class TestExternalDbDbDataPathConflictError:
    def test_holds_when_external_db_off(self) -> None:
        assert external_db_db_data_path_conflict_error(
            use_external_db=False, db_data_path=True, naming=CLI_FLAGS
        ) is None

    def test_holds_when_db_data_path_absent(self) -> None:
        assert external_db_db_data_path_conflict_error(
            use_external_db=True, db_data_path=False, naming=CLI_FLAGS
        ) is None

    def test_cli_wording_on_conflict(self) -> None:
        assert external_db_db_data_path_conflict_error(
            use_external_db=True, db_data_path=True, naming=CLI_FLAGS
        ) == (
            "--use-external-db is incompatible with --db-data-path: "
            "the bundled db service is dropped, so there is nowhere to "
            "bind-mount the path. Drop --db-data-path and point phpfpm at "
            "your existing DB via --external-db-host."
        )

    def test_field_wording_on_conflict(self) -> None:
        assert external_db_db_data_path_conflict_error(
            use_external_db=True, db_data_path=True, naming=FIELD_NAMES
        ) == (
            "use_external_db is incompatible with db_data_path: "
            "the bundled db service is dropped, so there is nowhere to "
            "bind-mount the path. Drop --db-data-path and point phpfpm at "
            "your existing DB via --external-db-host."
        )
