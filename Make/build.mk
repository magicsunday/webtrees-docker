# =============================================================================
# TARGETS
# =============================================================================

#### Build & Deployment

.PHONY: build

build: .logo ## Builds/Updates the used docker images.
	$(COMPOSE_BIN) build --pull \
		--build-arg BUILD_DATE=$$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
		--build-arg VCS_REF=$$(git rev-parse --short HEAD)
