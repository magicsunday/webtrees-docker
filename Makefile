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

# Auto-detect GitHub token for Composer API authentication (avoids rate limiting)
GITHUB_TOKEN ?= $(shell command -v gh >/dev/null 2>&1 && gh auth token 2>/dev/null)

ifdef GITHUB_TOKEN
    export COMPOSER_AUTH := {"github-oauth":{"github.com":"$(GITHUB_TOKEN)"}}
endif

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
