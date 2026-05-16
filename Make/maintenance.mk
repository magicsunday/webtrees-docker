# Base-image bump targets.
#
# Each `bump-<image>` target turns a check-<image>.yml tracking issue
# into a deterministic worktree mutation: update the canonical pin,
# sync the mirror sites the lockstep test enforces, then leave the
# operator to review release notes + open a PR. The lockstep tests
# (`make ci-pytest ci-lockstep-tests`) are the safety net for any
# mirror this tooling does not know about yet.
#
# Bumpers run inside a python:3.13-slim container — mirrors the
# ci-ruff / ci-mypy pattern so the operator does not need a local
# python3 on the host. Only the standard library is used; no pip
# install is required.
#
# `--user $$(id -u):$$(id -g)` makes container-side mutations inherit
# the operator's UID/GID. Without it, dev/nginx-version.json + every
# sed'd mirror site would land owned by root:root on the NAS host,
# blocking `git add` without sudo. Pattern lifted from
# scripts/render-portainer-templates.sh.
#
# See docs/maintenance.md for the per-image procedure (release-note
# review focus, smoke-matrix steps, post-merge image pull).

.PHONY: bump-nginx bump-mariadb

# `$(CURDIR)` (Makefile directory) instead of `$(PWD)` (caller's
# shell pwd) so the bind mount tracks the repo root regardless of
# where the operator ran make from.
_BUMP_DOCKER = docker run --rm --user "$$(id -u):$$(id -g)" \
	-v "$(CURDIR):/app" -w /app python:3.13-slim

# Make-parse-time validation: `$(value VAR)` returns the raw
# unexpanded text. Pure-shell metacharacters (backtick, semicolon,
# pipe, ampersand, redirect, quote, escape) are caught here before
# the value lands in a recipe-shell context.
#
# Out of scope — GNU Make 4.4+ evaluates command-line `$(shell …)` /
# `:=` / `::=` / `!=` / `CURDIR=` assignments at parse time, before
# any directive in this file runs. No in-Makefile guard can defeat
# those. Documented in docs/maintenance.md's trust model.
#
# Parentheses inside $(findstring …) are tokens to Make's parser, so
# they are passed via the _LPAREN / _RPAREN variables.
_LPAREN := (
_RPAREN := )

# Whitelist guard: the raw text must NOT contain any of
#   ` $ ; | & ( ) < > ' " \
# which together cover POSIX shell command substitution, command
# chaining, redirection, quoting, and escape sequences. `$(value)`
# returns the raw unexpanded text — `$(call …)` would re-trigger
# Make's `$(shell …)` evaluation on the raw value under Make 4.4.1
# (verified empirically: $(call _unsafe-chars,$(value VERSION)) lets
# the payload fire), so each findstring inlines `$(value VERSION)`
# directly without going through a macro indirection.
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

bump-nginx: .logo ## Bump dev/nginx-version.json + sync 5 mirror sites. Args: VERSION=1.31 [CONFIG_REVISION=1]
	@if [ -z "$(VERSION)" ]; then \
		echo "::error::bump-nginx requires VERSION=X.Y (e.g. VERSION=1.31)" >&2; \
		exit 2; \
	fi
	@case "$(VERSION)" in *[!0-9.]* | *..* ) \
		echo "::error::VERSION must be X.Y digits (got: $(VERSION))" >&2; exit 2;; esac
	@case "$(CONFIG_REVISION)" in *[!0-9]* ) \
		echo "::error::CONFIG_REVISION must be a non-negative integer (got: $(CONFIG_REVISION))" >&2; exit 2;; esac
	$(_BUMP_DOCKER) python3 scripts/bump-nginx.py \
		$(if $(CONFIG_REVISION),--config-revision $(CONFIG_REVISION)) \
		"$(VERSION)"

bump-mariadb: .logo ## Bump mariadb pin across all 4 shipped compose sites. Args: VERSION=11.9
	@if [ -z "$(VERSION)" ]; then \
		echo "::error::bump-mariadb requires VERSION=X.Y (e.g. VERSION=11.9)" >&2; \
		exit 2; \
	fi
	@case "$(VERSION)" in *[!0-9.]* | *..* ) \
		echo "::error::VERSION must be X.Y digits (got: $(VERSION))" >&2; exit 2;; esac
	$(_BUMP_DOCKER) python3 scripts/bump-mariadb.py "$(VERSION)"
