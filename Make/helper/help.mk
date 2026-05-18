# =============================================================================
# TARGETS
# =============================================================================

.PHONY: help

# `make help` extracts `## docstrings` from every loaded .mk file and
# `#### ` section headers, then renders them as a colour-aligned
# index. The actual rendering lives in scripts/lib/render-make-help.sh
# — see that file's header for the column-split design (TAB delimiter
# so `#` chars in descriptions survive, awk-based blank-line
# re-injection between sections).
help: .logo
	@FYELLOW='$(FYELLOW)' FGREEN='$(FGREEN)' FRESET='$(FRESET)' \
		./scripts/lib/render-make-help.sh $(filter-out %.env, $(MAKEFILE_LIST))
