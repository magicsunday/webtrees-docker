composer-update:
	@echo -e "\033[0;34m[+] Updates your dependencies to the latest version according to composer.json\033[0m"
	@./scripts/composer-update

composer-install:
	@echo -e "\033[0;34m[+] Installs the project dependencies from the composer.lock file if present\033[0m"
	@./scripts/composer-install

apply-config:
	@echo -e "\033[0;34m[+] Re-apply webtrees configuration\033[0m"
	@./scripts/apply-config
