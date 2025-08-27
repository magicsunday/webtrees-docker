# @see https://gist.github.com/rsperl/d2dfe88a520968fbc1f49db0a29345b9/

# =============================================================================
# Variables
# =============================================================================

# Define standard colors
ifneq ($(TERM),)
	FBOLD         := $(shell tput bold)
	FDIM          := $(shell tput dim)
	FRESET        := $(shell tput sgr0)

	FBLACK        := $(shell tput setaf 0)
	FRED          := $(shell tput setaf 1)
	FGREEN        := $(shell tput setaf 2)
	FYELLOW       := $(shell tput setaf 3)
	FBLUE         := $(shell tput setaf 4)
	FPURPLE       := $(shell tput setaf 5)
	FCYAN         := $(shell tput setaf 6)
	FWHITE        := $(shell tput setaf 7)
else
	FBOLD         := ""
	FDIM          := ""
	FRESET        := ""

	FBLACK        := ""
	FRED          := ""
	FGREEN        := ""
	FYELLOW       := ""
	FBLUE         := ""
	FPURPLE       := ""
	FCYAN         := ""
	FWHITE        := ""
	FRESET        := ""
endif

# =============================================================================
# TARGETS
# =============================================================================

.PHONY: colors

colors: .logo
	@echo "${FBLACK}BLACK${FRESET}"
	@echo "${FRED}RED${FRESET}"
	@echo "${FGREEN}GREEN${FRESET}"
	@echo "${FYELLOW}YELLOW${FRESET}"
	@echo "${FBLUE}BLUE${FRESET}"
	@echo "${FPURPLE}PURPLE${FRESET}"
	@echo "${FCYAN}CYAN${FRESET}"
	@echo "${FWHITE}WHITE${FRESET}"
	@echo "${FBOLD}BOLD${FRESET}"
	@echo "${FDIM}DIM${FRESET}"
