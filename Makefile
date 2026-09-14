# SPDX-License-Identifier: Apache-2.0
.DEFAULT_GOAL := help
SHELL := /bin/bash
PKG := Packages/ScreenSculptKit

.PHONY: help bootstrap generate test test-fast build run clean doctor

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

doctor: ## Check the toolchain is usable
	@echo "Xcode:    $$(xcodebuild -version 2>&1 | head -1)"
	@echo "Swift:    $$(swift --version 2>&1 | head -1)"
	@echo "xcodegen: $$(xcodegen --version 2>&1 || echo 'NOT INSTALLED - brew install xcodegen')"

bootstrap: ## Install tools and generate the Xcode project
	@command -v xcodegen >/dev/null || brew install xcodegen
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

clean: ## Remove build output
	rm -rf build .build DerivedData ScreenSculpt.xcodeproj
	swift package --package-path $(PKG) reset 2>/dev/null || true
