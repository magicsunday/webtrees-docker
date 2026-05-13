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
# Tools are pulled on first use as ephemeral docker containers; no host-side
# prerequisites beyond `docker` itself.
# =============================================================================

.PHONY: ci-test ci-pytest ci-entrypoint ci-yamllint ci-hadolint ci-shellcheck ci-alpine-lockstep

# Naming note: documentation and tracking issues call this aggregate
# `ci:test` (mirrors composer-script convention). Makefile targets cannot
# contain `:` in their names, so the recipe is `ci-test`; both are
# interchangeable in conversation.
ci-test: ci-pytest ci-yamllint ci-hadolint ci-shellcheck ci-alpine-lockstep ci-entrypoint ## Runs every local CI check (pytest + lint + entrypoint tests).
	echo -e "${FGREEN}✓ All ci-test checks passed${FRESET}"

ci-pytest: .logo ## Runs the installer Python test suite via python:3.13-slim.
	echo -e "${FBLUE}▶ pytest (installer)${FRESET}"
	docker run --rm \
		-v "$(PWD)/installer:/app" \
		-w /app \
		--entrypoint sh \
		python:3.13-slim \
		-c "pip install -q -e '.[test]' >/dev/null 2>&1 && pytest -q"

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
	IMAGE="ghcr.io/magicsunday/webtrees/php:$(LATEST_PHP_TAG)"; \
		docker pull "$$IMAGE" >/dev/null || { \
			echo "::error::docker pull failed for $$IMAGE" >&2; \
			exit 1; \
		}; \
		TEST_IMAGE="$$IMAGE" ./tests/test-entrypoint.sh

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
	#   * Dockerfile variant tags (`php:8.5-fpm-alpine`, `nginx:1.28-alpine`)
	#     — follow their parent image's release cadence; out of scope.
	#
	# Shape assertion on the pin itself: `alpine:X.Y` (no patch). Pin
	# policy is enforced here, not just on convention. A future maintainer
	# adding a patch suffix (X.Y.Z) would fail this check loudly.
	pinned=$$(grep -E '^ALPINE_BASE_IMAGE\s*=' installer/webtrees_installer/_alpine.py | sed -E 's/^[^"]*"([^"]+)".*/\1/'); \
		[ -n "$$pinned" ] || { echo "::error::Could not parse ALPINE_BASE_IMAGE from _alpine.py" >&2; exit 1; }; \
		echo "  canonical pin: $$pinned"; \
		echo "$$pinned" | grep -qE '^alpine:[0-9]+\.[0-9]+$$' || { \
			echo "::error::ALPINE_BASE_IMAGE='$$pinned' violates the minor-only pin policy (expected 'alpine:X.Y')" >&2; \
			exit 1; \
		}; \
		drifted=$$(find installer/webtrees_installer Make docs Dockerfile installer/Dockerfile -type f \
				\( -name '*.py' -o -name '*.j2' -o -name '*.md' -o -name '*.mk' -o -name '*.sh' -o -name 'Dockerfile*' \) \
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

ci-hadolint: .logo ## Lints the Dockerfiles.
	echo -e "${FBLUE}▶ hadolint (Dockerfile)${FRESET}"
	# Failure threshold: warning. Any new DL/SC finding above info level
	# fails CI. Existing exemptions live as inline `# hadolint ignore=…`
	# directives with a rationale comment above each one.
	docker run --rm -i hadolint/hadolint:latest hadolint --failure-threshold warning - < Dockerfile
	echo -e "${FBLUE}▶ hadolint (installer/Dockerfile)${FRESET}"
	docker run --rm -i hadolint/hadolint:latest hadolint --failure-threshold warning - < installer/Dockerfile
