# =============================================================================
# CI test aggregate
#
# `make ci-test` bundles every static-analysis + unit-test check that should
# pass before a commit lands. One local command, green here means green in CI.
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

#### CI & Lint

# ci-test runs serially: the python sub-targets (ci-pytest / ci-ruff /
# ci-mypy / ci-vulture / ci-cpd) share the `webtrees-ci-pip-cache`
# volume and race on `pip install -e .` writes under `make -jN`.
.NOTPARALLEL: ci-test

.PHONY: ci-test ci-prereqs ci-pytest ci-ruff ci-mypy ci-vulture ci-cpd ci-entrypoint ci-nginx-config ci-yamllint ci-hadolint ci-shellcheck ci-alpine-lockstep ci-images-lockstep ci-readme-badge-lockstep ci-php-versions-lockstep ci-nginx-tag-derivation-lockstep ci-php-digests-lockstep ci-versions-latest-semver-max-lockstep ci-env-dist-pins-lockstep ci-dockerfile-arg-defaults-lockstep ci-composer-patches-lockstep ci-patches-apply-lockstep ci-portainer-templates-lockstep ci-healthcheck-lockstep ci-port-default-lockstep ci-tls-verify-lockstep ci-diy-env-vars-lockstep ci-notify-needs-lockstep ci-cron-poll-perms-lockstep ci-lockstep-tests ci-shared-scripts-tests ci-host-lan-ip-detect-tests

# Naming note: documentation and tracking issues call this aggregate
# `ci:test`. Makefile targets cannot contain `:` in their names, so the
# recipe is `ci-test`; both are interchangeable in conversation.
ci-test: ci-prereqs ci-pytest ci-ruff ci-mypy ci-vulture ci-cpd ci-yamllint ci-hadolint ci-shellcheck ci-alpine-lockstep ci-images-lockstep ci-readme-badge-lockstep ci-php-versions-lockstep ci-nginx-tag-derivation-lockstep ci-php-digests-lockstep ci-versions-latest-semver-max-lockstep ci-env-dist-pins-lockstep ci-dockerfile-arg-defaults-lockstep ci-composer-patches-lockstep ci-patches-apply-lockstep ci-portainer-templates-lockstep ci-healthcheck-lockstep ci-port-default-lockstep ci-tls-verify-lockstep ci-diy-env-vars-lockstep ci-notify-needs-lockstep ci-cron-poll-perms-lockstep ci-lockstep-tests ci-shared-scripts-tests ci-host-lan-ip-detect-tests ci-entrypoint ci-nginx-config ## Runs every local CI check (pytest + lint + lockstep + entrypoint + nginx-config tests).
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
		fi; \
		docker info >/dev/null 2>&1 || { \
			echo "::error::docker CLI is on PATH but the daemon is unreachable. Start dockerd (or fix DOCKER_HOST)." >&2; \
			exit 1; \
		}

ci-pytest: .logo ## Runs the installer Python test suite in a throwaway Python container.
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
	$(CI_RUN_PYTHON_WITH_REPO) \
		-c "apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends make >/dev/null && pip install -q -e '.[test]' >/dev/null 2>&1 && pytest -q"

# All four ci-{ruff,mypy,vulture,cpd} targets share the same install
# step against the installer's `.[static]` optional-deps. The targets
# are intentionally separate (rather than a single ci-static aggregate)
# so a developer iterating on one check can run it without paying for
# the others.
ci-ruff: .logo ## Lints the installer Python package with ruff.
	echo -e "${FBLUE}▶ ruff${FRESET}"
	$(CI_RUN_PYTHON) \
		-c "pip install -q -e '.[static]' >/dev/null 2>&1 && ruff check webtrees_installer"

ci-mypy: .logo ## Type-checks the installer Python package with mypy --strict.
	echo -e "${FBLUE}▶ mypy --strict${FRESET}"
	$(CI_RUN_PYTHON) \
		-c "pip install -q -e '.[static]' >/dev/null 2>&1 && mypy webtrees_installer"

ci-vulture: .logo ## Scans the installer Python package for dead code (vulture).
	echo -e "${FBLUE}▶ vulture${FRESET}"
	# --min-confidence 80 trims trivial false positives (e.g. constants
	# referenced via reflection / template lookup) while still surfacing
	# unused functions/imports/variables that the codebase no longer needs.
	$(CI_RUN_PYTHON) \
		-c "pip install -q -e '.[static]' >/dev/null 2>&1 && vulture webtrees_installer --min-confidence 80"

ci-cpd: .logo ## Copy-paste detection for the installer Python package (pylint duplicate-code).
	echo -e "${FBLUE}▶ cpd (pylint duplicate-code)${FRESET}"
	# pylint's `duplicate-code` checker is the de-facto standalone CPD
	# for Python; disabling everything else gives us narrow CPD without
	# pulling in a second tool. Threshold lives in pyproject.toml
	# (min-similarity-lines).
	$(CI_RUN_PYTHON) \
		-c "pip install -q -e '.[static]' >/dev/null 2>&1 && pylint webtrees_installer"

# Resolve the rolling-`latest` image tag (e.g. `2.2.6-php8.5`) from the
# version manifest. Containerised so the aggregate honours the "docker only"
# contract of this file — no jq / python / yq host install required.
LATEST_PHP_TAG = $$($(CI_RUN_JQ) \
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
		./scripts/lib/pull-or-fail.sh "$$IMAGE" && \
		TEST_IMAGE="$$IMAGE" ./tests/test-entrypoint.sh

ci-nginx-config: .logo ## Runs the nginx config syntax + trust-gate regression tests.
	echo -e "${FBLUE}▶ nginx config tests${FRESET}"
	# Asserts rootfs/etc/nginx/ parses cleanly under the project's own
	# nginx image, plus regression guards on the X-Forwarded-Proto trust
	# gate (default.conf reads $$xfp_https, trust-proxy-map.conf carries
	# the expected CIDR set with LAN ranges out of default trust).
	NGINX_IMAGE="ghcr.io/magicsunday/webtrees-nginx:1.30-r1"; \
		./scripts/lib/pull-or-fail.sh "$$NGINX_IMAGE" && \
		TEST_NGINX_IMAGE="$$NGINX_IMAGE" ./tests/test-nginx-config.sh && \
		echo -e "${FBLUE}▶ trust-proxy-extra entrypoint tests${FRESET}" && \
		TEST_NGINX_IMAGE="$$NGINX_IMAGE" ./tests/test-trust-proxy-extra.sh

ci-yamllint: .logo ## Lints workflow + compose YAML files.
	echo -e "${FBLUE}▶ yamllint${FRESET}"
	# line-length stays a warning (not error): GHA `run: |` blocks routinely
	# contain long inline strings (PR/issue body literals, multi-flag gh
	# commands) that read cleaner on one line than as line-continuations.
	$(CI_RUN_YAMLLINT) \
		-d "{extends: default, rules: {line-length: {max: 200, level: warning}, document-start: disable, truthy: {check-keys: false}, comments: {min-spaces-from-content: 1}}}" \
		.github/workflows/ compose.yaml compose.pma.yaml compose.traefik.yaml compose.publish.yaml compose.development.yaml

# $(call lockstep,<label>,<script>) — the recipe every ci-*-lockstep
# target shares: a blue banner line then the checker invocation against
# the repo root. Defined once here (its only call site) so a banner-style
# change is a one-line edit instead of touching all 16 targets, and a new
# lockstep is a single $(call) line. Each target keeps its own name, help
# text and .logo dependency; only the label and script name vary.
define lockstep
echo -e "${FBLUE}▶ $(1)${FRESET}"
./scripts/lockstep/$(2) "$(CURDIR)"
endef

ci-alpine-lockstep: .logo ## Asserts every `alpine:` reference matches the central pin.
	$(call lockstep,alpine lockstep,check-alpine-pin.sh)

ci-images-lockstep: .logo ## Asserts Make/images.mk and scripts/lib/images.env carry the same CI_IMAGE_* pin set.
	$(call lockstep,ci-image-pin lockstep,check-ci-images.sh)

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
		printf '%s\n' "$$files" | xargs -d '\n' $(CI_RUN_SHELLCHK) -x

ci-readme-badge-lockstep: .logo ## Asserts README webtrees/PHP badge values cover every unique entry in dev/versions.json.
	$(call lockstep,README badge lockstep,check-readme-badges.sh)

ci-php-versions-lockstep: .logo ## Asserts dev/versions.json has exactly one row per supported PHP minor per webtrees minor.
	$(call lockstep,PHP versions lockstep,check-php-versions.sh)

ci-nginx-tag-derivation-lockstep: .logo ## Asserts dev/nginx-version.json .tag equals `<nginx_base>-r<config_revision>`.
	$(call lockstep,nginx tag derivation lockstep,check-nginx-tag-derivation.sh)

ci-php-digests-lockstep: .logo ## Asserts dev/php_digests.lock key set matches dev/php-versions.json .supported.
	$(call lockstep,php digests lockstep,check-php-digests-lockstep.sh)

ci-versions-latest-semver-max-lockstep: .logo ## Asserts dev/versions.json 'latest' tag sits on the semver-max webtrees row.
	$(call lockstep,versions 'latest' semver-max lockstep,check-versions-latest-semver-max.sh)

ci-env-dist-pins-lockstep: .logo ## Asserts .env.dist WEBTREES_VERSION / WEBTREES_NGINX_VERSION / NGINX_CONFIG_REVISION / PHP_VERSION mirror dev/.
	$(call lockstep,.env.dist pins lockstep,check-env-dist-pins.sh)

ci-dockerfile-arg-defaults-lockstep: .logo ## Asserts every `ARG <key>=<default>` in Dockerfile matches .env.dist's mirror of dev/.
	$(call lockstep,Dockerfile ARG defaults lockstep,check-dockerfile-arg-defaults.sh)

ci-composer-patches-lockstep: .logo ## Asserts setup/composer-core.json and composer-full.json carry identical extra.patches blocks.
	$(call lockstep,composer patches lockstep,check-composer-patches-lockstep.sh)

ci-patches-apply-lockstep: .logo ## Asserts setup/patches/*.patch applies cleanly to every webtrees version in dev/versions.json.
	$(call lockstep,patches apply lockstep,check-patches-apply.sh)

ci-portainer-templates-lockstep: .logo ## Asserts templates/portainer/{compose.yaml,.env.example} mirror a fresh render of the installer Jinja sources.
	$(call lockstep,portainer templates lockstep,check-portainer-templates.sh)

ci-port-default-lockstep: .logo ## Asserts _DEFAULT_PORT / _FALLBACK_PORT mirrors agree across every documented site.
	$(call lockstep,port-default lockstep,check-port-defaults.sh)

ci-healthcheck-lockstep: .logo ## Asserts root compose.yaml's nginx start_period mirrors the installer templates.
	$(call lockstep,healthcheck lockstep,check-healthcheck-start-period.sh)

ci-tls-verify-lockstep: .logo ## Asserts no TLS-verify bypass flags appear in executable repo files; deny-list and rationale in scripts/lockstep/check-tls-verify.sh.
	$(call lockstep,TLS-verify lockstep,check-tls-verify.sh)

ci-diy-env-vars-lockstep: .logo ## Asserts every env var named in docs/diy.md also appears in docs/env-vars.md.
	$(call lockstep,DIY env-vars lockstep,check-diy-env-vars.sh)

ci-notify-needs-lockstep: .logo ## Asserts build.yml's notify-on-failure needs: covers every other top-level job.
	$(call lockstep,notify needs lockstep,check-notify-needs.sh)

ci-cron-poll-perms-lockstep: .logo ## Asserts every cron-docker-hub-poll.yml caller grants the top-level permissions its jobs require.
	$(call lockstep,cron-poll caller perms lockstep,check-cron-poll-caller-perms.sh)

ci-host-lan-ip-detect-tests: .logo ## Regression tests for install's HOST_LAN_IP detection block.
	echo -e "${FBLUE}▶ host-lan-ip-detect tests${FRESET}"
	./tests/test-host-lan-ip-detect.sh

ci-lockstep-tests: .logo ## Failure-path tests for the ci-*-lockstep drift checks.
	echo -e "${FBLUE}▶ lockstep failure-path tests${FRESET}"
	# Each ci-*-lockstep target only proves itself on the happy path; if a
	# future edit weakens the regex / predicate (e.g. fattens the alpine
	# shape check, drops the row-0 invariant), the lockstep silently passes.
	# This harness mutates a throwaway git worktree to inject the violation
	# the lockstep is supposed to catch and asserts the recipe still fails
	# with the documented error annotation.
	./tests/test-lockstep.sh

ci-shared-scripts-tests: .logo ## Failure-path tests for the workflow-shared scripts under scripts/.
	echo -e "${FBLUE}▶ shared-script failure-path tests${FRESET}"
	# The four workflow-extracted scripts (check-docker-hub-minor.sh,
	# file-bump-issue.sh, probe-php-digests.sh,
	# batch-bump-webtrees-versions.sh) carry defensive branches that only
	# fire under specific Docker Hub / gh-CLI / docker-buildx failure
	# modes. This harness mocks curl/gh/docker/git via a PATH-shimmed stub
	# directory and asserts each branch emits the documented annotation
	# and exit code. Without it, a future refactor removing `|| true`
	# after grep, the `// empty` jq guard, a `[ -n ... ] || exit 1`
	# self-test, or the ALLOW_MISSING_PIN downgrade would ship green.
	./tests/test-shared-scripts.sh

ci-hadolint: .logo ## Lints the Dockerfiles.
	echo -e "${FBLUE}▶ hadolint (Dockerfile)${FRESET}"
	# Failure threshold: warning. Any new DL/SC finding above info level
	# fails CI. Existing exemptions live as inline `# hadolint ignore=…`
	# directives with a rationale comment above each one.
	$(CI_RUN_HADOLINT) hadolint --failure-threshold warning - < Dockerfile
	echo -e "${FBLUE}▶ hadolint (installer/Dockerfile)${FRESET}"
	$(CI_RUN_HADOLINT) hadolint --failure-threshold warning - < installer/Dockerfile
