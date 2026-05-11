# =============================================================================
# TARGETS
# =============================================================================

#### Tests

.PHONY: test test-entrypoint

test: test-entrypoint ## Runs all local test suites.

test-entrypoint: .logo ## Runs the docker-entrypoint.sh state-machine tests.
	# Runs on the host: the script spawns ephemeral docker containers and
	# volumes directly via the docker CLI. Wrapping it in buildbox would
	# require docker-in-docker and add nothing.
	./tests/test-entrypoint.sh
