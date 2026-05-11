# =============================================================================
# TARGETS
# =============================================================================

#### Production-Mode Test (isolated stack, runs alongside dev)

.PHONY: prod-up prod-down prod-config prod-logs prod-status

PROD_ENV := .env.prod-test

prod-up: .logo ## Starts an isolated production-mode stack (use `make prod-down` to remove).
	@test -f $(PROD_ENV) || { \
		echo "Missing $(PROD_ENV). Copy the template:"; \
		echo "    cp $(PROD_ENV).dist $(PROD_ENV)"; \
		exit 1; \
	}
	$(COMPOSE_BIN) --env-file $(PROD_ENV) up -d

prod-down: .logo ## Stops the production-mode stack and removes its volumes.
	@test -f $(PROD_ENV) || exit 0
	$(COMPOSE_BIN) --env-file $(PROD_ENV) down -v

prod-config: .logo ## Prints the effective Compose configuration for the production-mode stack.
	@test -f $(PROD_ENV) || { echo "Missing $(PROD_ENV) — run `make prod-up` for instructions"; exit 1; }
	$(COMPOSE_BIN) --env-file $(PROD_ENV) config

prod-logs: .logo ## Tails logs of the production-mode stack.
	@test -f $(PROD_ENV) || { echo "Missing $(PROD_ENV)"; exit 1; }
	$(COMPOSE_BIN) --env-file $(PROD_ENV) logs -f

prod-status: .logo ## Shows the running production-mode containers.
	@test -f $(PROD_ENV) || { echo "Missing $(PROD_ENV)"; exit 1; }
	$(COMPOSE_BIN) --env-file $(PROD_ENV) ps

#### Module Management (end-users)

.PHONY: modules-shell

modules-shell: .logo ## Opens a shell in the running phpfpm container, in modules_v4/ when it exists.
	$(COMPOSE_BIN) exec phpfpm sh -c '\
		MODULES=/var/www/html/vendor/fisharebest/webtrees/modules_v4; \
		if [ -d "$$MODULES" ]; then \
			cd "$$MODULES"; \
		else \
			echo "modules_v4/ not found at $$MODULES — falling back to /var/www/html"; \
			cd /var/www/html; \
		fi; \
		exec sh'
