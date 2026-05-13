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

.PHONY: ci-test ci-pytest ci-entrypoint ci-yamllint ci-hadolint

# Naming note: documentation and tracking issues call this aggregate
# `ci:test` (mirrors composer-script convention). Makefile targets cannot
# contain `:` in their names, so the recipe is `ci-test`; both are
# interchangeable in conversation.
ci-test: ci-pytest ci-yamllint ci-hadolint ci-entrypoint ## Runs every local CI check (pytest + lint + entrypoint tests).
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

ci-entrypoint: .logo ## Runs the docker-entrypoint.sh state-machine tests.
	echo -e "${FBLUE}▶ entrypoint integration tests${FRESET}"
	# Pin TEST_IMAGE: the script's default `:8.5` tag does not exist in the
	# registry — we publish `2.2.6-php8.5` etc. Resolve the canonical tag
	# from dev/versions.json (the row carrying the rolling `latest` bundle).
	TEST_IMAGE="ghcr.io/magicsunday/webtrees/php:$(LATEST_PHP_TAG)" ./tests/test-entrypoint.sh

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

ci-hadolint: .logo ## Lints the Dockerfiles.
	echo -e "${FBLUE}▶ hadolint (Dockerfile)${FRESET}"
	# Failure threshold: error. Warnings/info stay visible but do not fail
	# the build — cleanup tracked in issue #62 (DL4006 SHELL pipefail,
	# DL3018 apk-version-pin, SC2016 quote-expansion). Tighten the
	# threshold once that issue lands.
	docker run --rm -i hadolint/hadolint:latest hadolint --failure-threshold error - < Dockerfile
	echo -e "${FBLUE}▶ hadolint (installer/Dockerfile)${FRESET}"
	docker run --rm -i hadolint/hadolint:latest hadolint --failure-threshold error - < installer/Dockerfile
