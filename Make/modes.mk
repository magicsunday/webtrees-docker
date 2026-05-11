# =============================================================================
# TARGETS
# =============================================================================

#### Dev Mode Toggle

.PHONY: enable-dev-mode disable-dev-mode dev-mode-status

ENV_FILE := .env

enable-dev-mode: .logo ## Adds compose.development.yaml to COMPOSE_FILE (buildbox, xdebug, browserless, bind-mount).
	@test -f $(ENV_FILE) || { echo "Missing $(ENV_FILE) — run scripts/setup.sh first"; exit 1; }
	@if grep -qE "^COMPOSE_FILE=.*compose\.development\.yaml" $(ENV_FILE); then \
		echo "Dev mode already enabled."; \
	else \
		sed -i 's|^COMPOSE_FILE=\(.*\)$$|COMPOSE_FILE=\1:compose.development.yaml|' $(ENV_FILE); \
		echo "Dev mode enabled. Run 'make up' (or 'make restart') to apply."; \
	fi

disable-dev-mode: .logo ## Removes compose.development.yaml from COMPOSE_FILE.
	@test -f $(ENV_FILE) || { echo "Missing $(ENV_FILE) — run scripts/setup.sh first"; exit 1; }
	@if grep -qE "^COMPOSE_FILE=.*compose\.development\.yaml" $(ENV_FILE); then \
		sed -i \
			-e 's|:compose\.development\.yaml||g' \
			-e 's|compose\.development\.yaml:||g' \
			-e 's|=compose\.development\.yaml$$|=|' \
			$(ENV_FILE); \
		echo "Dev mode disabled. Run 'make up' (or 'make restart') to apply."; \
	else \
		echo "Dev mode already disabled."; \
	fi

dev-mode-status: .logo ## Shows whether dev mode is currently enabled in .env.
	@test -f $(ENV_FILE) || { echo "Missing $(ENV_FILE)"; exit 1; }
	@if grep -qE "^COMPOSE_FILE=.*compose\.development\.yaml" $(ENV_FILE); then \
		echo "Dev mode: ON  (compose.development.yaml is in COMPOSE_FILE chain)"; \
	else \
		echo "Dev mode: OFF (compose.development.yaml NOT in COMPOSE_FILE chain)"; \
	fi

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
