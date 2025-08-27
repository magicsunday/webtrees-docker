# =============================================================================
# Variables
# =============================================================================

COMPOSE_BUILD_COMPOSER := $(COMPOSE_BIN) run --rm -e COMPOSER_AUTH -e COMPOSER_MEMORY_LIMIT=-1 buildbox

# =============================================================================
# TARGETS
# =============================================================================

#### Application Setup & Maintenance

.PHONY: install composer-install composer-update update-languages apply-config cache-clear info

install: .logo ## Installs the application initially.
	@$(COMPOSE_BUILD_ROOT) ./scripts/set-permissions.sh
	@${COMPOSE_BUILD} ./scripts/install-application.sh

composer-install: .logo ## Installs the packages with the locked versions and references.
	@$(COMPOSE_BUILD_ROOT) ./scripts/set-permissions.sh
	@${COMPOSE_BUILD_COMPOSER} ./scripts/composer-install.sh

composer-update: .logo ## Triggers an update of the composer packages.
	@$(COMPOSE_BUILD_ROOT) ./scripts/set-permissions.sh
	@${COMPOSE_BUILD_COMPOSER} ./scripts/composer-update.sh

update-languages: .logo ## Updates the language files of webtrees.
	@$(COMPOSE_BUILD) ./scripts/update-languages.sh

apply-config: .logo ## Re-applies the webtrees configuration to an already installed application.
	@${COMPOSE_BUILD} ./scripts/apply-config.sh

cache-clear: .logo ## Clears the webtrees cache directory.
	@${COMPOSE_BUILD_ROOT} ./scripts/cache-clear.sh

info: .logo ## Prints out project information
	@echo -e "\n${FBOLD}:: Project information${FRESET}\n"
	@echo -e "  ${FGREEN}Project name:${FRESET}\t\t${COMPOSE_PROJECT_NAME}"
	@echo -e "  ${FGREEN}Developer domain:${FRESET}\thttps://${DEV_DOMAIN}"
	@echo -e "  ${FGREEN}Repository origin:${FRESET}\t$$(git remote get-url origin)"
	@echo -e "  ${FGREEN}Current branch:${FRESET}\t$$(git branch --show-current)"
	@latest=$$(git rev-list --tags --max-count=1 2>/dev/null); \
[ -n "$$latest" ] && tag=$$(git describe --tags $$latest 2>/dev/null) || tag="-"; \
echo -e "  ${FGREEN}Latest tag:${FRESET}\t\t$$tag"

	@echo -e "\n${FBOLD}:: Repository statistics${FRESET}\n"
	@echo -e "  ${FGREEN}Last commit message:${FRESET}\t$$(git log -1 --pretty=format:"%B")"
	@echo -e "  ${FGREEN}Last commit date:${FRESET}\t$$(git log -1 --pretty=format:"%cd")"
	@echo -e "  ${FGREEN}Last commit author:${FRESET}\t$$(git log -1 --pretty=format:"%an") <$$(git log -1 --pretty=format:"%ae")>"
	@echo -e "  ${FGREEN}Last commit id:${FRESET}\t$$(git log -1 --pretty=format:"%H")"
	@echo -e "  ${FGREEN}Count branches:${FRESET}\t$$(git branch -r | wc -l)"
	@echo -e "  ${FGREEN}Count tags:${FRESET}\t\t$$(git tag | wc -l)"
	@echo -e "  ${FGREEN}Count commits:${FRESET}\t$$(git rev-list --count HEAD)"

	@echo -e "\n${FBOLD}:: User information${FRESET}\n"
	@echo -e "  ${FGREEN}User name (whoami):${FRESET}\t$$(whoami)"
	@echo -e "  ${FGREEN}LOCAL_USER_NAME:${FRESET}\t${LOCAL_USER_NAME}"
	@echo -e "  ${FGREEN}LOCAL_USER_ID:${FRESET}\t${LOCAL_USER_ID}"
	@echo -e "  ${FGREEN}LOCAL_GROUP_NAME:${FRESET}\t${LOCAL_GROUP_NAME}"
	@echo -e "  ${FGREEN}LOCAL_GROUP_ID:${FRESET}\t${LOCAL_GROUP_ID}"
