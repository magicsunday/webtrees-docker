# =============================================================================
# TARGETS
# =============================================================================

#### Tests

.PHONY: test test-entrypoint

test: test-entrypoint ## Runs all local test suites.

# Delegates to ci-entrypoint to avoid drifting between two near-identical
# pull-then-run recipes — both used to share the LATEST_PHP_TAG pin and the
# pre-pull guard. Single source of truth lives in Make/ci.mk; this target
# stays as the historical entry point for `make test`.
test-entrypoint: ci-entrypoint ## Runs the docker-entrypoint.sh state-machine tests (delegates to ci-entrypoint).
