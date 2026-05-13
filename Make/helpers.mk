# =============================================================================
# TARGETS
# =============================================================================

#### Helpers

.PHONY: check-compose fix-permissions os-detect

check-compose: .logo ## Checks if docker and compose are available.
	@$(COMPOSE_BIN) --version >/dev/null 2>&1 || (echo 'Error: Docker Compose not available' && exit 1)
	@echo -e "${FGREEN}Docker and Compose detected.${FRESET}"

fix-permissions: .logo ## Fixes the permissions for the application.
	@$(COMPOSE_BUILD_ROOT) ./scripts/set-permissions.sh

os-detect: .logo ## Prints basic OS/shell info for troubleshooting.
	@echo -e "Shell: $(SHELL)"
	@uname -a 2>/dev/null || echo "uname not available"
