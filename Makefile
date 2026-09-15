# SPDX-License-Identifier: Apache-2.0
.DEFAULT_GOAL := help
SHELL := /bin/bash
PKG := Packages/ScreenSculptKit

.PHONY: help bootstrap generate test test-fast build run dmg cert install clean doctor

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

doctor: ## Check the toolchain is usable
	@echo "Xcode:    $$(xcodebuild -version 2>&1 | head -1)"
	@echo "Swift:    $$(swift --version 2>&1 | head -1)"
	@echo "xcodegen: $$(xcodegen --version 2>&1 || echo 'NOT INSTALLED - brew install xcodegen')"

bootstrap: ## Install tools, create the signing cert, generate the Xcode project
	@command -v xcodegen >/dev/null || brew install xcodegen
	@./scripts/make-signing-cert.sh
	@$(MAKE) generate

generate: ## Regenerate ScreenSculpt.xcodeproj from project.yml
	xcodegen generate

test: ## Run the package test suite (headless, no window server, no TCC)
	swift test --package-path $(PKG)

test-fast: ## Run only the geometry suite
	swift test --package-path $(PKG) --filter SSGeometryTests

build: generate ## Build the app (Debug)
	xcodebuild build -project ScreenSculpt.xcodeproj -scheme ScreenSculpt \
	  -configuration Debug -destination 'platform=macOS' | \
	  grep -vE '^\s*$$' | tail -20

run: build ## Build and launch
	open build/Debug/ScreenSculpt.app 2>/dev/null || \
	  open "$$(xcodebuild -project ScreenSculpt.xcodeproj -scheme ScreenSculpt \
	    -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $$2}' | \
	    head -1)/ScreenSculpt.app"

cert: ## Create the self-signed signing cert (once) so permissions survive rebuilds
	./scripts/make-signing-cert.sh

install: dmg ## Build and install into /Applications, then relaunch
	@pkill -x ScreenSculpt 2>/dev/null || true
	@sleep 1
	@hdiutil attach -nobrowse -quiet \
	  "build/ScreenSculpt-$$(awk -F' *= *' '/^MARKETING_VERSION/{print $$2; exit}' \
	  Config/Version.xcconfig | tr -d ' ').dmg" -mountpoint /tmp/ssmount
	@rm -rf /Applications/ScreenSculpt.app
	@cp -R /tmp/ssmount/ScreenSculpt.app /Applications/
	@hdiutil detach -quiet /tmp/ssmount
	# Remove every other copy of the bundle. macOS records a permission grant
	# against one *copy* of an app, so a second bundle with the same identifier
	# gets its own entry — and the Privacy list shows both as plain
	# "ScreenSculpt" with no path. Granting Accessibility to the wrong one is
	# indistinguishable from granting it to the right one and being ignored.
	# Xcode recreates these on the next build; nothing is lost.
	@rm -rf build/*/ScreenSculpt.app 2>/dev/null || true
	@rm -rf "$$HOME"/Library/Developer/Xcode/DerivedData/ScreenSculpt-*/Build/Products/*/ScreenSculpt.app \
	  2>/dev/null || true
	@echo "installed to /Applications"
	@open /Applications/ScreenSculpt.app

dmg: ## Build a distributable .dmg (Release, universal, ad-hoc signed)
	@mkdir -p build
	./scripts/make-dmg.sh

clean: ## Remove build output
	rm -rf build .build DerivedData ScreenSculpt.xcodeproj
	swift package --package-path $(PKG) reset 2>/dev/null || true
