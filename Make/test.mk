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
	#
	# TEST_IMAGE: the script's default `:8.5` tag does not exist in the
	# registry (we publish `2.2.6-php8.5` etc). $(LATEST_PHP_TAG) — defined
	# in Make/ci.mk — resolves the rolling-`latest` row from dev/versions.json.
	TEST_IMAGE="ghcr.io/magicsunday/webtrees/php:$(LATEST_PHP_TAG)" ./tests/test-entrypoint.sh
