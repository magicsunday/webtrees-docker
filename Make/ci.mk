# =============================================================================
# CI test aggregate
#
# `make ci-test` bundles every static-analysis + unit-test check that should
# pass before a commit lands. Mirrors the `composer ci:test` discipline of the
# chart-module repos: one local command, green here means green in CI.
#
# Sub-targets stay individually invocable for fast iteration. New checks land
# here (not as separate workflows) so the aggregate stays the single source of
# truth.
#
# Heavy lifting runs in ephemeral docker containers (linters, type-checkers,
# language toolchains) — no Python / Node / PHP install needed on the host.
# A handful of targets and the bundled shell scripts still drive those
# containers with host-side bash + git + GNU coreutils; `ci-prereqs` is the
# canonical, verified list and docs/developing.md renders the same set as
# a user-facing table. Edit both surfaces together when adding a new tool.
# =============================================================================

.PHONY: ci-test ci-prereqs ci-pytest ci-ruff ci-mypy ci-vulture ci-cpd ci-entrypoint ci-nginx-config ci-yamllint ci-hadolint ci-shellcheck ci-alpine-lockstep ci-readme-badge-lockstep ci-healthcheck-lockstep ci-port-default-lockstep ci-lockstep-tests

# Naming note: documentation and tracking issues call this aggregate
# `ci:test` (mirrors composer-script convention). Makefile targets cannot
# contain `:` in their names, so the recipe is `ci-test`; both are
# interchangeable in conversation.
ci-test: ci-prereqs ci-pytest ci-ruff ci-mypy ci-vulture ci-cpd ci-yamllint ci-hadolint ci-shellcheck ci-alpine-lockstep ci-readme-badge-lockstep ci-healthcheck-lockstep ci-port-default-lockstep ci-lockstep-tests ci-entrypoint ci-nginx-config ## Runs every local CI check (pytest + lint + lockstep + entrypoint + nginx-config tests).
	echo -e "${FGREEN}✓ All ci-test checks passed${FRESET}"

ci-prereqs: .logo ## Verifies the host-side tools the ci-test pipeline, make help, and the bundled shell scripts shell out to.
	echo -e "${FBLUE}▶ host toolchain check${FRESET}"
	# Fail-fast diagnostic so a missing coreutil surfaces at the start of
	# ci-test with a clear pointer, not as a cryptic "command not found"
	# mid-pipeline. When a new ci-* recipe (or a script invoked from one)
	# starts shelling out to a tool not yet on this list, extend both the
	# loop below AND the table in docs/developing.md in lockstep.
	missing=""; \
		for tool in docker bash git cat grep sed find xargs sort head tail wc tr printf cp mkdir mktemp column; do \
			command -v "$$tool" >/dev/null 2>&1 || missing="$$missing $$tool"; \
		done; \
		if [ -n "$$missing" ]; then \
			echo "::error::missing required host tools:$$missing" >&2; \
			echo "::error::install via your distro package manager (Debian/Ubuntu: 'apt install coreutils bsdmainutils git'; macOS: 'brew install coreutils git')." >&2; \
			exit 1; \
		fi

ci-pytest: .logo ## Runs the installer Python test suite via python:3.13-slim.
	echo -e "${FBLUE}▶ pytest (installer)${FRESET}"
	# `apt-get install make` brings GNU make into the throwaway
	# container so the Makefile-render tests
	# (test_render_makefile_parses_under_make_n +
	# test_render_makefile_switch_flips_env) actually exercise the
	# rendered Makefile instead of skipping. ~5MB extra image bytes,
	# transparent under the pip-cache volume reuse.
	#
	# The repo root is bind-mounted read-only at /repo so the
	# mariadb-pin lockstep test (test_mariadb_pin_lockstep) can
	# verify the four shipped compose sites agree on `mariadb:X.Y`;
	# WT_REPO_ROOT carries the path so the test resolves it without
	# depending on relative pathlib walks from the installer/ cwd.
	docker run --rm \
		-v "$(PWD):/repo:ro" \
		-v "$(PWD)/installer:/app" \
		-v webtrees-ci-pip-cache:/root/.cache/pip \
		-w /app \
		-e WT_REPO_ROOT=/repo \
		--entrypoint sh \
		python:3.13-slim \
		-c "apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends make >/dev/null && pip install -q -e '.[test]' >/dev/null 2>&1 && pytest -q"

# All four ci-{ruff,mypy,vulture,cpd} targets share the same install
# step against the installer's `.[static]` optional-deps. The targets
# are intentionally separate (rather than a single ci-static aggregate)
# so a developer iterating on one check can run it without paying for
# the others.
ci-ruff: .logo ## Lints the installer Python package with ruff.
	echo -e "${FBLUE}▶ ruff${FRESET}"
	docker run --rm \
		-v "$(PWD)/installer:/app" \
		-v webtrees-ci-pip-cache:/root/.cache/pip \
		-w /app \
		--entrypoint sh \
		python:3.13-slim \
		-c "pip install -q -e '.[static]' >/dev/null 2>&1 && ruff check webtrees_installer"

ci-mypy: .logo ## Type-checks the installer Python package with mypy --strict.
	echo -e "${FBLUE}▶ mypy --strict${FRESET}"
	docker run --rm \
		-v "$(PWD)/installer:/app" \
		-v webtrees-ci-pip-cache:/root/.cache/pip \
		-w /app \
		--entrypoint sh \
		python:3.13-slim \
		-c "pip install -q -e '.[static]' >/dev/null 2>&1 && mypy webtrees_installer"

ci-vulture: .logo ## Scans the installer Python package for dead code (vulture).
	echo -e "${FBLUE}▶ vulture${FRESET}"
	# --min-confidence 80 trims trivial false positives (e.g. constants
	# referenced via reflection / template lookup) while still surfacing
	# unused functions/imports/variables that the codebase no longer needs.
	docker run --rm \
		-v "$(PWD)/installer:/app" \
		-v webtrees-ci-pip-cache:/root/.cache/pip \
		-w /app \
		--entrypoint sh \
		python:3.13-slim \
		-c "pip install -q -e '.[static]' >/dev/null 2>&1 && vulture webtrees_installer --min-confidence 80"

ci-cpd: .logo ## Copy-paste detection for the installer Python package (pylint duplicate-code).
	echo -e "${FBLUE}▶ cpd (pylint duplicate-code)${FRESET}"
	# pylint's `duplicate-code` checker is the de-facto standalone CPD
	# for Python; disabling everything else gives us narrow CPD without
	# pulling in a second tool. Threshold lives in pyproject.toml
	# (min-similarity-lines).
	docker run --rm \
		-v "$(PWD)/installer:/app" \
		-v webtrees-ci-pip-cache:/root/.cache/pip \
		-w /app \
		--entrypoint sh \
		python:3.13-slim \
		-c "pip install -q -e '.[static]' >/dev/null 2>&1 && pylint webtrees_installer"

# Resolve the rolling-`latest` image tag (e.g. `2.2.6-php8.5`) from the
# version manifest. Containerised so the aggregate honours the "docker only"
# contract of this file — no jq / python / yq host install required.
LATEST_PHP_TAG = $$(docker run --rm -v "$(PWD)/dev:/d:ro" -w /d ghcr.io/jqlang/jq:latest \
	-r '.[] | select(.tags | index("latest")) | "\(.webtrees)-php\(.php)"' versions.json)

# Runs on the host: the script spawns ephemeral docker containers and
# volumes directly via the docker CLI. Wrapping it in buildbox would
# require docker-in-docker and add nothing.
#
# Also consumed by `test-entrypoint` in Make/test.mk — rename this target
# (or change its contract) only in lockstep with that delegation.
ci-entrypoint: .logo ## Runs the docker-entrypoint.sh state-machine tests.
	echo -e "${FBLUE}▶ entrypoint integration tests${FRESET}"
	# Pin TEST_IMAGE: the script's default `:8.5` tag does not exist in the
	# registry — we publish `2.2.6-php8.5` etc. Resolve the canonical tag
	# from dev/versions.json (the row carrying the rolling `latest` bundle).
	# Pre-pull so test-entrypoint.sh's "Image not found locally" guard does
	# not trip on a fresh runner that has never built/pulled the image.
	IMAGE="ghcr.io/magicsunday/webtrees-php:$(LATEST_PHP_TAG)"; \
		docker pull "$$IMAGE" >/dev/null || { \
			echo "::error::docker pull failed for $$IMAGE" >&2; \
			exit 1; \
		}; \
		TEST_IMAGE="$$IMAGE" ./tests/test-entrypoint.sh

ci-nginx-config: .logo ## Runs the nginx config syntax + trust-gate regression tests.
	echo -e "${FBLUE}▶ nginx config tests${FRESET}"
	# Asserts rootfs/etc/nginx/ parses cleanly under the project's own
	# nginx image, plus regression guards on the X-Forwarded-Proto trust
	# gate (default.conf reads $$xfp_https, trust-proxy-map.conf carries
	# the expected CIDR set with LAN ranges out of default trust).
	NGINX_IMAGE="ghcr.io/magicsunday/webtrees-nginx:1.28-r1"; \
		docker pull "$$NGINX_IMAGE" >/dev/null || { \
			echo "::error::docker pull failed for $$NGINX_IMAGE" >&2; \
			exit 1; \
		}; \
		TEST_NGINX_IMAGE="$$NGINX_IMAGE" ./tests/test-nginx-config.sh; \
		echo -e "${FBLUE}▶ trust-proxy-extra entrypoint tests${FRESET}"; \
		TEST_NGINX_IMAGE="$$NGINX_IMAGE" ./tests/test-trust-proxy-extra.sh

ci-yamllint: .logo ## Lints workflow + compose YAML files.
	echo -e "${FBLUE}▶ yamllint${FRESET}"
	# line-length stays a warning (not error): GHA `run: |` blocks routinely
	# contain long inline strings (PR/issue body literals, multi-flag gh
	# commands) that read cleaner on one line than as line-continuations.
	docker run --rm \
		-v "$(PWD):/work" \
		-w /work \
		cytopia/yamllint:latest \
		-d "{extends: default, rules: {line-length: {max: 200, level: warning}, document-start: disable, truthy: {check-keys: false}, comments: {min-spaces-from-content: 1}}}" \
		.github/workflows/ compose.yaml compose.pma.yaml compose.traefik.yaml compose.publish.yaml compose.development.yaml

ci-alpine-lockstep: .logo ## Asserts every `alpine:` reference matches the central pin.
	echo -e "${FBLUE}▶ alpine lockstep${FRESET}"
	# Single-source-of-truth check: ALPINE_BASE_IMAGE in
	# webtrees_installer/_alpine.py is canonical. Every literal
	# `alpine:X.Y[.Z]` reference in live code, runtime configs, docs
	# and Make/scripts must match it. A partial bump that updates the
	# constant but forgets one consumer (or vice versa) trips this check.
	#
	# Scoped to surfaces that ship to the operator. Excluded:
	#   * `docs/superpowers/` — historical specs/plans, frozen point-in-time records.
	#   * Dockerfile variant tags (`php:8.5-fpm-alpine`, `nginx:1.30-alpine`)
	#     — follow their parent image's release cadence; out of scope.
	#
	# Shape assertion on the pin itself: `alpine:X.Y` (no patch). Pin
	# policy is enforced here, not just on convention. A future maintainer
	# adding a patch suffix (X.Y.Z) would fail this check loudly.
	# The parser script handles canonical/Final[str]/indented/single-quoted
	# variants of the assignment so a benign reformat of _alpine.py doesn't
	# break this recipe; tests/test-lockstep.sh exercises the failure paths.
	pinned=$$(./scripts/parse-alpine-pin.sh) || exit 1; \
		echo "  canonical pin: $$pinned"; \
		echo "$$pinned" | grep -qE '^alpine:[0-9]+\.[0-9]+$$' || { \
			echo "::error::ALPINE_BASE_IMAGE='$$pinned' violates the minor-only pin policy (expected 'alpine:X.Y')" >&2; \
			exit 1; \
		}; \
		drifted=$$(find installer/webtrees_installer Make docs Dockerfile installer/Dockerfile templates -type f \
				\( -name '*.py' -o -name '*.j2' -o -name '*.md' -o -name '*.mk' -o -name '*.sh' -o -name 'Dockerfile*' -o -name 'compose.yaml' \) \
				-not -path 'docs/superpowers/*' \
				-print0 2>/dev/null \
			| xargs -0 grep -hEo 'alpine:[0-9]+\.[0-9]+(\.[0-9]+)?' 2>/dev/null \
			| sort -u | grep -vFx "$$pinned" || true); \
		if [ -n "$$drifted" ]; then \
			echo "::error::Alpine pin drift detected — these references diverge from ALPINE_BASE_IMAGE='$$pinned':" >&2; \
			echo "$$drifted" >&2; \
			exit 1; \
		fi

ci-shellcheck: .logo ## Lints every tracked shell script.
	echo -e "${FBLUE}▶ shellcheck${FRESET}"
	# File set is derived from a shebang scan of every tracked file:
	# anything with a `#!/…sh|bash|dash|ksh` shebang (incl. env-prefixed
	# variants) gets linted — the four shells shellcheck actually supports.
	# Self-extending: a new launcher added anywhere is picked up
	# automatically, no Makefile edit needed.
	#
	# `xargs -d '\n' docker run …` feeds the file list as newline-
	# delimited args, so paths with spaces survive the hand-off.
	#
	# -x follows `source …` directives so common helpers
	# (scripts/configuration) get analysed in the context of every caller
	# that sources them.
	files=$$(git ls-files -z | xargs -0 grep -lE '^#!.*\b(bash|sh|dash|ksh)\b' 2>/dev/null | sort); \
		[ -n "$$files" ] || { echo "::error::ci-shellcheck found no shell scripts to lint" >&2; exit 1; }; \
		printf '%s\n' "$$files" | xargs -d '\n' docker run --rm \
			-v "$(PWD):/work" \
			-w /work \
			koalaman/shellcheck:stable \
			-x

ci-readme-badge-lockstep: .logo ## Asserts the README webtrees badge tracks dev/versions.json row 0.
	echo -e "${FBLUE}▶ README badge lockstep${FRESET}"
	# The README's webtrees badge uses shields.io's `dynamic/json` endpoint
	# with JSONPath `$$[0].webtrees`. Shields.io's JSONPath subset rejects
	# predicate filters, so we cannot scope the badge to the row tagged
	# `latest`. Instead we enforce the invariant here: row 0 must be the
	# row that carries the `latest` tag, so the badge always reads the
	# canonical version. The check-versions.yml auto-bump renderer is in
	# lockstep with this: it partitions latest-tagged rows to the front
	# of the array before writing.
	#
	# Two-stage check so parse errors don't masquerade as drift:
	#   1. `jq empty` validates the file is parseable JSON.
	#   2. `jq -e <predicate>` flips exit status on the actual invariant.
	docker run --rm \
		-v "$(PWD)/dev:/d:ro" \
		-w /d \
		ghcr.io/jqlang/jq:latest \
		empty versions.json >/dev/null 2>&1 || { \
			echo "::error::dev/versions.json is not parseable JSON" >&2; \
			exit 1; \
		}
	docker run --rm \
		-v "$(PWD)/dev:/d:ro" \
		-w /d \
		ghcr.io/jqlang/jq:latest \
		-e '.[0].tags | index("latest") != null' versions.json >/dev/null || { \
			echo "::error::dev/versions.json row 0 must carry the \"latest\" tag — the README shields.io badge reads \$$[0].webtrees verbatim." >&2; \
			exit 1; \
		}
	# Pin the README side of the invariant too: if someone edits the
	# badge URL to a different JSONPath (e.g. `$$[*].webtrees`), the
	# json-side check still passes but the badge silently regresses.
	# `query=%24%5B0%5D.webtrees` is the URL-encoded form of `$$[0].webtrees`.
	grep -q 'query=%24%5B0%5D.webtrees' README.md || { \
		echo "::error::README.md webtrees badge no longer queries \$$[0].webtrees — update either the badge or ci-readme-badge-lockstep so both ends stay in sync." >&2; \
		exit 1; \
	}

ci-port-default-lockstep: .logo ## Asserts _DEFAULT_PORT / _FALLBACK_PORT mirrors agree across every documented site.
	echo -e "${FBLUE}▶ port-default lockstep${FRESET}"
	# Source of truth: installer/webtrees_installer/flow.py:_DEFAULT_PORT
	# and _FALLBACK_PORT. The mirror block at flow.py:74-82 documents
	# every file that must carry the same literal; this target enforces
	# the discipline programmatically (mirrors ci-alpine-lockstep).
	#
	# Drift has happened before — docs/env-vars.md briefly fell back to
	# `80` during the 28k-band introduction and stayed there until a
	# retrospective audit caught it. With this check on every commit,
	# the next bump moves all sites or trips the failure-path test.
	pair=$$(./scripts/parse-port-defaults.sh) || exit 1; \
		default_port=$${pair%:*}; \
		fallback_port=$${pair#*:}; \
		echo "  canonical default: $$default_port, fallback: $$fallback_port"; \
		default_sites="compose.publish.yaml install upgrade switch README.md docs/customizing.md docs/developing.md docs/env-vars.md templates/portainer/compose.yaml"; \
		fallback_sites="README.md"; \
		missing=""; \
		for f in $$default_sites; do \
			grep -qFw "$$default_port" "$$f" 2>/dev/null \
				|| missing="$$missing $$f(default)"; \
		done; \
		for f in $$fallback_sites; do \
			grep -qFw "$$fallback_port" "$$f" 2>/dev/null \
				|| missing="$$missing $$f(fallback)"; \
		done; \
		if [ -n "$$missing" ]; then \
			echo "::error::Port-default lockstep drift — these sites do not carry the canonical value:$$missing" >&2; \
			exit 1; \
		fi

ci-healthcheck-lockstep: .logo ## Asserts root compose.yaml's nginx start_period mirrors the installer templates.
	echo -e "${FBLUE}▶ healthcheck lockstep${FRESET}"
	# The nginx healthcheck stanza ships in three places: the dev-stack
	# root compose.yaml and the two wizard-rendered installer templates
	# (compose.standalone.j2 + compose.traefik.j2). They must all agree
	# on start_period; a drift means dev-stack operators get a different
	# bootstrap-tolerance window than wizard-rendered production stacks.
	# The two installer templates are already pinned via test_render_*
	# (parametrised over both proxy modes); this check covers the root.
	#
	# yq parses YAML structurally so the three start_periods on the db /
	# phpfpm / nginx healthchecks do not collide — we always pull
	# services.nginx.healthcheck.start_period. mikefarah/yq runs in a
	# throwaway container so the host needs no yq install.
	#
	# The two .j2 templates use sed because Jinja braces (`{% if %}`)
	# break a pure YAML parser. The `sed -n '/nginx:/,$p' | head -1`
	# pattern assumes nginx is the LAST service in both templates so
	# `head -1` reliably lands on nginx's start_period. If a future
	# template appends a service after nginx, tighten the sed range to
	# `/^    nginx:/,/^    [a-z][a-z_-]*:$/` and re-run ci-lockstep-tests
	# (test-lockstep.sh's drift fixtures pin both templates and would
	# trip if the extracted value silently regresses).
	root_value=$$(docker run --rm -v "$(PWD):/work" -w /work \
			mikefarah/yq:latest \
			'.services.nginx.healthcheck.start_period' compose.yaml); \
		portainer_value=$$(docker run --rm -v "$(PWD):/work" -w /work \
			mikefarah/yq:latest \
			'.services.nginx.healthcheck.start_period' templates/portainer/compose.yaml); \
		standalone_value=$$(sed -n '/^    nginx:/,$$p' \
			installer/webtrees_installer/templates/compose.standalone.j2 \
			| grep -E '^[[:space:]]+start_period:' \
			| head -1 | awk '{print $$2}'); \
		traefik_value=$$(sed -n '/^    nginx:/,$$p' \
			installer/webtrees_installer/templates/compose.traefik.j2 \
			| grep -E '^[[:space:]]+start_period:' \
			| head -1 | awk '{print $$2}'); \
		if [ -z "$$root_value" ] || [ "$$root_value" = "null" ] \
			|| [ -z "$$portainer_value" ] || [ "$$portainer_value" = "null" ] \
			|| [ -z "$$standalone_value" ] || [ -z "$$traefik_value" ]; then \
			echo "::error::healthcheck start_period not found (root='$$root_value', portainer='$$portainer_value', standalone='$$standalone_value', traefik='$$traefik_value')" >&2; \
			exit 1; \
		fi; \
		if [ "$$root_value" != "$$standalone_value" ] || [ "$$root_value" != "$$traefik_value" ] || [ "$$root_value" != "$$portainer_value" ]; then \
			echo "::error::nginx healthcheck start_period drift — compose.yaml='$$root_value' vs portainer='$$portainer_value' vs standalone='$$standalone_value' vs traefik='$$traefik_value'" >&2; \
			exit 1; \
		fi; \
		echo "  canonical start_period: $$root_value"

ci-lockstep-tests: .logo ## Failure-path tests for the ci-*-lockstep drift checks.
	echo -e "${FBLUE}▶ lockstep failure-path tests${FRESET}"
	# Each ci-*-lockstep target only proves itself on the happy path; if a
	# future edit weakens the regex / predicate (e.g. fattens the alpine
	# shape check, drops the row-0 invariant), the lockstep silently passes.
	# This harness mutates a throwaway git worktree to inject the violation
	# the lockstep is supposed to catch and asserts the recipe still fails
	# with the documented error annotation.
	./tests/test-lockstep.sh

ci-hadolint: .logo ## Lints the Dockerfiles.
	echo -e "${FBLUE}▶ hadolint (Dockerfile)${FRESET}"
	# Failure threshold: warning. Any new DL/SC finding above info level
	# fails CI. Existing exemptions live as inline `# hadolint ignore=…`
	# directives with a rationale comment above each one.
	docker run --rm -i hadolint/hadolint:latest hadolint --failure-threshold warning - < Dockerfile
	echo -e "${FBLUE}▶ hadolint (installer/Dockerfile)${FRESET}"
	docker run --rm -i hadolint/hadolint:latest hadolint --failure-threshold warning - < installer/Dockerfile
