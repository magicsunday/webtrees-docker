# =============================================================================
# Variables
# =============================================================================

DOCKER_LOGIN_COMMAND :=

# Add username
ifneq "$(DOCKER_USERNAME)" ""
	DOCKER_LOGIN_COMMAND := docker login $(DOCKER_SERVER) -u $(DOCKER_USERNAME)

	# Add password via stdin when provided (avoid leaking in process list)
	ifneq "$(DOCKER_PASSWORD)" ""
		DOCKER_LOGIN_COMMAND := echo "$(DOCKER_PASSWORD)" | docker login $(DOCKER_SERVER) -u $(DOCKER_USERNAME) --password-stdin
	endif
endif

# Build project URL
ifeq (${ENFORCE_HTTPS},TRUE)
	PROJECT_URL:= "https://${DEV_DOMAIN}"
else
	PROJECT_URL:= "http://${DEV_DOMAIN}"
endif

# =============================================================================
# TARGETS
# =============================================================================

#### Docker

.PHONY: bash bash-root build compose-config down logs push restart status up

bash: .logo ## Opens a bash within the build box as the configured user.
	${COMPOSE_BUILD} bash

bash-root: .logo ## Opens a bash within the build box as root user.
	${COMPOSE_BUILD_ROOT} bash

build: .logo ## Builds/Updates the used docker images.
	$(DOCKER_LOGIN_COMMAND)
	# Add --no-cache to force rebuild
	$(COMPOSE_BIN) build --pull

compose-config: .logo ## Prints the effective Docker Compose configuration (after merges).
	${COMPOSE_BIN} config

down: .logo ## Stops and removes all docker containers started with `make up`.
	${COMPOSE_BIN} down -v
	@echo ""
	@echo -e "\033[0;32m ✔\033[0m Docker containers for ${COMPOSE_PROJECT_NAME} ... successfully STOPPED"

logs: .logo ## Shows the logs of the started containers.
	${COMPOSE_BIN} logs -f --tail=100

push: .logo ## Pushes the docker images to the configured docker server.
	$(DOCKER_LOGIN_COMMAND)
	$(COMPOSE_BIN) push

restart: .logo ## Restarts the application.
	${COMPOSE_BIN} restart

status: .logo ## Shows the status of the running containers.
	${COMPOSE_BIN} ps

up: .logo ## Starts all defined docker containers.
	${COMPOSE_BIN} up -d
	@echo ""
	@echo -e "\033[0;32m ✔\033[0m Docker containers for ${COMPOSE_PROJECT_NAME} ... successfully STARTED"
	@echo -e "\033[0;32m ✔\033[0m Project can be reached at ${PROJECT_URL}"
