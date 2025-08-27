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

# =============================================================================
# TARGETS
# =============================================================================

#### Build & Deployment

.PHONY: build push

build: .logo ## Builds/Updates the used docker images.
	$(DOCKER_LOGIN_COMMAND)
	# Add --no-cache to force rebuild
	$(COMPOSE_BIN) build --pull

push: .logo ## Pushes the docker images to the configured docker server.
	$(DOCKER_LOGIN_COMMAND)
	$(COMPOSE_BIN) push
