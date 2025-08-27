SHELL = /bin/bash

.SILENT:

# Do not print "Entering directory ..."
MAKEFLAGS += --no-print-directory

.PHONY: no_targets__ *
	no_targets__:

.DEFAULT_GOAL := help

# Docker Compose detection
COMPOSE_BIN := $(shell \
	if command -v docker >/dev/null 2>&1; then \
		if docker compose version >/dev/null 2>&1; then \
			echo "docker compose"; \
		elif command -v docker-compose >/dev/null 2>&1; then \
			echo "docker-compose"; \
		else \
			echo "echo 'Error: No Docker Compose found' && exit 1"; \
		fi; \
	else \
		echo "echo 'Error: Docker not found' && exit 1"; \
	fi)

# Verify Docker Compose is available
.PHONY: check-docker

check-docker:
	@$(COMPOSE_BIN) --version >/dev/null 2>&1 || (echo "Docker Compose not available" && exit 1)

COMPOSE_BUILD_BASE := $(COMPOSE_BIN) run --rm -e COMPOSER_AUTH
COMPOSE_BUILD      := $(COMPOSE_BUILD_BASE) buildbox
COMPOSE_BUILD_ROOT := $(COMPOSE_BUILD_BASE) buildbox-root

# Includes
-include .env
-include Make/*.mk
-include Make/**/*.mk

# Argument fix workaround
%:
	@:
