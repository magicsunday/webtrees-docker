# =============================================================================
# Variables
# =============================================================================

COMPOSE_BUILD_COMPOSER := $(COMPOSE_BIN) run --rm -e COMPOSER_AUTH -e COMPOSER_MEMORY_LIMIT=-1 buildbox

# =============================================================================
# TARGETS
# =============================================================================

#### Tools

.PHONY: composer-install composer-update

composer-install: .logo ## Installs the packages with the locked versions and references.
	@$(COMPOSE_BUILD_ROOT) ./scripts/set-permissions.sh
	@${COMPOSE_BUILD_COMPOSER} ./scripts/composer-install.sh

composer-update: .logo ## Triggers an update of the composer packages.
	@$(COMPOSE_BUILD_ROOT) ./scripts/set-permissions.sh
	@${COMPOSE_BUILD_COMPOSER} ./scripts/composer-update.sh
