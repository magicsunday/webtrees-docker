# Base-image bump targets.
#
# Each `bump-<image>` target turns a check-<image>.yml tracking issue
# into a deterministic worktree mutation: update the canonical pin,
# sync the mirror sites the lockstep test enforces, then leave the
# operator to review release notes + open a PR. The lockstep tests
# (`make ci-pytest ci-lockstep-tests`) are the safety net for any
# mirror this tooling does not know about yet.
#
# Trust model: GNU Make 4.4+ evaluates command-line `$(shell …)` /
# `:=` / `::=` / `!=` / `CURDIR=` assignments at parse time, before
# any directive in this file runs. No in-Makefile guard can defeat
# those, so operators receiving a `make bump-…` invocation from an
# untrusted source (chat, README, gist) should invoke the underlying
# script directly:
#
#   ./scripts/bump-nginx.sh 1.32
#   ./scripts/bump-mariadb.sh 11.9
#
# The script-form does not go through Make's command-line parser at
# all and is robust against the hostile-paste class. The Make targets
# below remain as a convenience wrapper for the trusted-local case;
# they delegate to the same scripts, so behaviour is identical.
#
# See docs/maintenance.md for the per-image procedure (release-note
# review focus, smoke-matrix steps, post-merge image pull) and the
# trust-model section.

.PHONY: bump-nginx bump-mariadb

# Pure-shell metacharacters in VERSION / CONFIG_REVISION are caught at
# Make parse time before the value reaches the recipe shell. The
# Make 4.4+ assignment-operator class (`:=`, `::=`, `!=`, `CURDIR=`)
# cannot be defeated from inside the Makefile — operators with
# hostile-paste exposure must use `./scripts/bump-*.sh` instead.
#
# Parentheses inside $(findstring …) are tokens to Make's parser, so
# they are passed via the _LPAREN / _RPAREN variables.
_LPAREN := (
_RPAREN := )

ifdef VERSION
ifneq ($(strip $(or \
		$(findstring `,$(value VERSION)), \
		$(findstring $$,$(value VERSION)), \
		$(findstring ;,$(value VERSION)), \
		$(findstring |,$(value VERSION)), \
		$(findstring &,$(value VERSION)), \
		$(findstring $(_LPAREN),$(value VERSION)), \
		$(findstring $(_RPAREN),$(value VERSION)), \
		$(findstring <,$(value VERSION)), \
		$(findstring >,$(value VERSION)), \
		$(findstring ',$(value VERSION)), \
		$(findstring ",$(value VERSION)), \
		$(findstring \,$(value VERSION)))),)
$(error VERSION contains shell metacharacters; only digits and dots allowed: e.g. VERSION=1.31)
endif
endif
ifdef CONFIG_REVISION
ifneq ($(strip $(or \
		$(findstring `,$(value CONFIG_REVISION)), \
		$(findstring $$,$(value CONFIG_REVISION)), \
		$(findstring ;,$(value CONFIG_REVISION)), \
		$(findstring |,$(value CONFIG_REVISION)), \
		$(findstring &,$(value CONFIG_REVISION)), \
		$(findstring $(_LPAREN),$(value CONFIG_REVISION)), \
		$(findstring $(_RPAREN),$(value CONFIG_REVISION)), \
		$(findstring <,$(value CONFIG_REVISION)), \
		$(findstring >,$(value CONFIG_REVISION)), \
		$(findstring ',$(value CONFIG_REVISION)), \
		$(findstring ",$(value CONFIG_REVISION)), \
		$(findstring \,$(value CONFIG_REVISION)))),)
$(error CONFIG_REVISION contains shell metacharacters; only digits allowed)
endif
endif

bump-nginx: .logo ## Bump dev/nginx-version.json + sync 5 mirror sites. Args: VERSION=1.32 [CONFIG_REVISION=1]
	@if [ -z "$(VERSION)" ]; then \
		echo "::error::bump-nginx requires VERSION=X.Y (e.g. VERSION=1.32)" >&2; \
		exit 2; \
	fi
	@case "$(VERSION)" in *[!0-9.]* | *..* ) \
		echo "::error::VERSION must be X.Y digits (got: $(VERSION))" >&2; exit 2;; esac
	@case "$(CONFIG_REVISION)" in *[!0-9]* ) \
		echo "::error::CONFIG_REVISION must be a non-negative integer (got: $(CONFIG_REVISION))" >&2; exit 2;; esac
	./scripts/bump-nginx.sh \
		$(if $(CONFIG_REVISION),--config-revision $(CONFIG_REVISION)) \
		"$(VERSION)"

bump-mariadb: .logo ## Bump mariadb pin across all 4 shipped compose sites. Args: VERSION=11.9
	@if [ -z "$(VERSION)" ]; then \
		echo "::error::bump-mariadb requires VERSION=X.Y (e.g. VERSION=11.9)" >&2; \
		exit 2; \
	fi
	@case "$(VERSION)" in *[!0-9.]* | *..* ) \
		echo "::error::VERSION must be X.Y digits (got: $(VERSION))" >&2; exit 2;; esac
	./scripts/bump-mariadb.sh "$(VERSION)"
