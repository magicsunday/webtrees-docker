# =============================================================================
# TARGETS
# =============================================================================

#### Tests

.PHONY: test test-entrypoint

test: test-entrypoint ## Runs all local test suites.

# Thin alias for `make ci-entrypoint`. Single source of the
# pull-then-run logic lives in Make/ci.mk.
test-entrypoint: ci-entrypoint ## Runs the docker-entrypoint.sh state-machine tests.
