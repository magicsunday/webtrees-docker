default:
	@cat Make/help.txt

COMPOSE_BIN := $(if $(shell docker compose version 2>/dev/null | grep -E "v[2-9].*"), docker compose, docker-compose)

-include .env

ifeq ($(IN_CONTAINER),TRUE)
	USE_CONTAINER:= FALSE
endif

ifeq ($(USE_CONTAINER),TRUE)
	include Make/Makefile.env
else
	include Make/Makefile.app
endif
