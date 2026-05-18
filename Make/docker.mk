# =============================================================================
# Variables
# =============================================================================

# Build project URL
ifeq (${ENFORCE_HTTPS},TRUE)
	PROJECT_URL:= "https://${DEV_DOMAIN}"
else
	PROJECT_URL:= "http://${DEV_DOMAIN}"
endif

# =============================================================================
# TARGETS
# =============================================================================

#### Docker & Environment

.PHONY: up down down-volumes restart status config logs bash bash-root

up: .logo ## Starts all defined docker containers.
	${COMPOSE_BIN} up -d
	@echo ""
	@echo -e "\033[0;32m ✔\033[0m Docker containers for ${COMPOSE_PROJECT_NAME} ... successfully STARTED"
	@echo -e "\033[0;32m ✔\033[0m Project can be reached at ${FYELLOW}${PROJECT_URL}${FRESET}"

down: .logo ## Stops and removes containers. Named volumes (database, media, app) survive — use `make down-volumes` to wipe them.
	${COMPOSE_BIN} down
	@echo ""
	@echo -e "\033[0;32m ✔\033[0m Docker containers for ${COMPOSE_PROJECT_NAME} ... successfully STOPPED"

down-volumes: .logo ## Stops containers AND removes named volumes — wipes the database. Irreversible.
	${COMPOSE_BIN} down -v
	@echo ""
	@echo -e "\033[0;33m ⚠\033[0m Docker containers AND named volumes for ${COMPOSE_PROJECT_NAME} removed."

restart: .logo ## Restarts the application.
	${COMPOSE_BIN} restart

status: .logo ## Shows the status of the running containers.
	${COMPOSE_BIN} ps

config: .logo ## Prints the effective Docker Compose configuration (after merges).
	${COMPOSE_BIN} config

logs: .logo ## Shows the logs of the started containers.
	${COMPOSE_BIN} logs -f --tail=100

bash: .logo ## Opens a bash within the build box as the configured user.
	${COMPOSE_BUILD} bash

bash-root: .logo ## Opens a bash within the build box as root user.
	${COMPOSE_BUILD_ROOT} bash
