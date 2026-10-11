APP_NAME := FocusGlass
APP      := build/$(APP_NAME).app
INSTALLED := /Applications/$(APP_NAME).app

.DEFAULT_GOAL := help
.PHONY: help build app install run stop restart dev clean uninstall icon preview notch

help: ## Zobrazí tuto nápovědu
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36mmake %-10s\033[0m %s\n", $$1, $$2}'

build: ## Zkompiluje (debug) a ukáže chyby
	swift build

app: ## Sestaví build/FocusGlass.app (release)
	./scripts/build-app.sh

install: ## Sestaví, nainstaluje do /Applications a spustí
	./scripts/build-app.sh --install

run: ## Spustí nainstalovanou aplikaci
	open "$(INSTALLED)"

stop: ## Ukončí běžící aplikaci
	-pkill -x $(APP_NAME)

restart: stop run ## Restartuje aplikaci

dev: app ## Sestaví a spustí lokální build bez instalace
	-pkill -x $(APP_NAME)
	open "$(APP)"

clean: ## Smaže build artefakty
	rm -rf .build build

uninstall: stop ## Odebere aplikaci z /Applications
	rm -rf "$(INSTALLED)"

icon: ## Přegeneruje ikonu (Resources/AppIcon.icns)
	./scripts/make-icon.sh

preview: app ## Spustí lokální build rovnou s cvičením očí
	-pkill -x $(APP_NAME)
	open "$(APP)" --args --eye-break

notch: app ## Spustí lokální build s rozbaleným notchem
	-pkill -x $(APP_NAME)
	open "$(APP)" --args --notch-open
