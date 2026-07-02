# Sensible defaults
.ONESHELL:
SHELL := bash
.SHELLFLAGS := -e -u -c -o pipefail
.DELETE_ON_ERROR:
MAKEFLAGS += --warn-undefined-variables
MAKEFLAGS += --no-builtin-rules

# Derived values (DO NOT TOUCH).
CURRENT_MAKEFILE_PATH := $(abspath $(lastword $(MAKEFILE_LIST)))
CURRENT_MAKEFILE_DIR := $(patsubst %/,%,$(dir $(CURRENT_MAKEFILE_PATH)))
PROJECT_WORKSPACE := $(CURRENT_MAKEFILE_DIR)/supacode.xcworkspace
APP_SCHEME := supacode
PROJECT_CONFIG_PATH := Configurations/Project.xcconfig
TUIST_GENERATION_STAMP_DIR := $(CURRENT_MAKEFILE_DIR)/.build/.tuist-generated-stamps
TUIST_INSTALL_STAMP := $(TUIST_GENERATION_STAMP_DIR)/.installed
TUIST_DEVELOPMENT_GENERATION_STAMP := $(TUIST_GENERATION_STAMP_DIR)/development
TUIST_SOURCE_GENERATION_STAMP := $(TUIST_GENERATION_STAMP_DIR)/none
TUIST_RELEASE_GENERATION_STAMP := $(TUIST_GENERATION_STAMP_DIR)/development-release
TUIST_GENERATION_INPUTS := Project.swift Workspace.swift Tuist.swift Tuist/Package.swift $(wildcard Tuist/Package.resolved) $(PROJECT_CONFIG_PATH) mise.toml scripts/build-ghostty.sh scripts/build-zmx.sh
TUIST_GENERATE_CACHE_PROFILE ?= development
TUIST_CACHE_CONFIGURATION ?= Debug
VERSION ?=
BUILD ?=
TITLE ?=
BODY ?=
# Export so headline markdown reaches the script without a shell re-parse of quotes/backticks.
export VERSION BUILD TITLE BODY
XCODEBUILD_FLAGS ?=
SUPACODE_SKIP_PREFLIGHT ?=

# Export a Zig-linkable Xcode per build recipe (no global xcode-select -s). Plain
# assignment so a missing Xcode aborts the recipe under -e.
SELECT_DEVELOPER_DIR = DEVELOPER_DIR="$$(./scripts/select-developer-dir.sh)"; export DEVELOPER_DIR

.DEFAULT_GOAL := help
.PHONY: doctor preflight build-ghostty-xcframework build-zmx generate-project generate-project-sources inspect-dependencies warm-cache build-app run-app install-dev-build archive export-archive dist-personal release-personal format lint check test bump-version bump-and-release log-stream

ifdef CI
TUIST_INSTALL_FLAGS := --force-resolved-versions
SUPACODE_SKIP_PREFLIGHT := 1
else
TUIST_INSTALL_FLAGS :=
endif

help:  # Display this help.
	@-+echo "Run make with one of the following targets:"
	@-+echo
	@-+grep -Eh "^[a-z-]+:.*#" "$(CURRENT_MAKEFILE_PATH)" | sed -E 's/^(.*:)(.*#+)(.*)/  \1 @@@ \3 /' | column -t -s "@@@"

generate-project: $(TUIST_GENERATION_STAMP_DIR)/$(TUIST_GENERATE_CACHE_PROFILE) # Resolve packages and generate Xcode workspace

generate-project-sources: $(TUIST_SOURCE_GENERATION_STAMP) # Resolve packages and generate a source-only Xcode workspace

$(TUIST_INSTALL_STAMP): $(TUIST_GENERATION_INPUTS) | preflight
	mkdir -p "$(TUIST_GENERATION_STAMP_DIR)"
	mise exec -- tuist install $(TUIST_INSTALL_FLAGS)
	touch "$@"

$(TUIST_GENERATION_STAMP_DIR)/%: $(TUIST_GENERATION_INPUTS) $(TUIST_INSTALL_STAMP)
	mkdir -p "$(TUIST_GENERATION_STAMP_DIR)"
	find "$(TUIST_GENERATION_STAMP_DIR)" -mindepth 1 -maxdepth 1 ! -name '.installed' -delete
	rm -rf supacode.xcodeproj supacode.xcworkspace
	for path in "$${HOME}/Library/Developer/Xcode/DerivedData"/supacode-*; do \
		[ -e "$$path" ] || continue; \
		rm -rf "$$path"; \
	done
	mise exec -- tuist generate --no-open --cache-profile "$*"
	touch "$@"

# Consumes the warmed Release binary cache, so archive compiles only the app shell.
$(TUIST_RELEASE_GENERATION_STAMP): $(TUIST_GENERATION_INPUTS) $(TUIST_INSTALL_STAMP)
	mkdir -p "$(TUIST_GENERATION_STAMP_DIR)"
	find "$(TUIST_GENERATION_STAMP_DIR)" -mindepth 1 -maxdepth 1 ! -name '.installed' -delete
	rm -rf supacode.xcodeproj supacode.xcworkspace
	for path in "$${HOME}/Library/Developer/Xcode/DerivedData"/supacode-*; do \
		[ -e "$$path" ] || continue; \
		rm -rf "$$path"; \
	done
	mise exec -- tuist generate --no-open --cache-profile development --configuration Release
	touch "$@"

doctor: # Diagnose build prerequisites and print the fix for each failure
	@./scripts/doctor.sh

# Order-only preflight on the install stamp, so every build flow fails fast with
# doctor's actionable message before tuist / xcodebuild / zig run. Never forces a
# rebuild. Skipped when SUPACODE_SKIP_PREFLIGHT is set (CI sets it above).
preflight:
	@[ -n "$(SUPACODE_SKIP_PREFLIGHT)" ] || ./scripts/doctor.sh --quiet

build-ghostty-xcframework: | preflight # Build ghostty framework
	./scripts/build-ghostty.sh

build-zmx: | preflight # Build bundled zmx binary from ThirdParty/zmx submodule
	./scripts/build-zmx.sh

inspect-dependencies: $(TUIST_INSTALL_STAMP) # Check for implicit Tuist dependencies
	mise exec -- tuist inspect dependencies --only implicit

warm-cache: $(TUIST_INSTALL_STAMP) # Warm the full Tuist cacheable graph
	mise exec -- tuist cache warm --configuration $(TUIST_CACHE_CONFIGURATION)

build-app: $(TUIST_DEVELOPMENT_GENERATION_STAMP) # Build the macOS app (Debug)
	$(SELECT_DEVELOPER_DIR); \
	bash -o pipefail -c 'xcodebuild -workspace "$(PROJECT_WORKSPACE)" -scheme "$(APP_SCHEME)" -configuration Debug build -skipMacroValidation $(XCODEBUILD_FLAGS) 2>&1 | { mise exec -- xcbeautify --disable-logging || cat; }'

run-app: build-app # Build then launch (Debug) with log streaming
	@$(SELECT_DEVELOPER_DIR); \
	settings="$$(xcodebuild -workspace "$(PROJECT_WORKSPACE)" -scheme "$(APP_SCHEME)" -configuration Debug -showBuildSettings -json 2>/dev/null)"; \
	build_dir="$$(echo "$$settings" | jq -r '.[0].buildSettings.BUILT_PRODUCTS_DIR')"; \
	product="$$(echo "$$settings" | jq -r '.[0].buildSettings.FULL_PRODUCT_NAME')"; \
	exec_name="$$(echo "$$settings" | jq -r '.[0].buildSettings.EXECUTABLE_NAME')"; \
	"$$build_dir/$$product/Contents/MacOS/$$exec_name"

install-dev-build: build-app # install dev build to /Applications
	@$(SELECT_DEVELOPER_DIR); \
	settings="$$(xcodebuild -workspace "$(PROJECT_WORKSPACE)" -scheme "$(APP_SCHEME)" -configuration Debug -showBuildSettings -json 2>/dev/null)"; \
	build_dir="$$(echo "$$settings" | jq -r '.[0].buildSettings.BUILT_PRODUCTS_DIR')"; \
	product="$$(echo "$$settings" | jq -r '.[0].buildSettings.FULL_PRODUCT_NAME')"; \
	src="$$build_dir/$$product"; \
	dst="/Applications/$$product"; \
	if [ ! -d "$$src" ]; then \
		echo "app not found: $$src"; \
		exit 1; \
	fi; \
	echo "copying $$src -> $$dst"; \
	rm -rf "$$dst"; \
	ditto "$$src" "$$dst"; \
	echo "installed $$dst"

archive: $(TUIST_RELEASE_GENERATION_STAMP) # Archive Release build for distribution
	mkdir -p build
	$(SELECT_DEVELOPER_DIR); \
	bash -o pipefail -c 'xcodebuild -workspace "$(PROJECT_WORKSPACE)" -scheme "$(APP_SCHEME)" -configuration Release -destination "generic/platform=macOS" -archivePath build/supacode.xcarchive archive CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$$APPLE_TEAM_ID" CODE_SIGN_IDENTITY="$$DEVELOPER_ID_IDENTITY_SHA" OTHER_CODE_SIGN_FLAGS="--timestamp" -skipMacroValidation $(XCODEBUILD_FLAGS) 2>&1 | { mise exec -- xcbeautify --quiet --disable-logging || cat; }'

export-archive: # Export xarchive
	$(SELECT_DEVELOPER_DIR); \
	bash -o pipefail -c 'xcodebuild -exportArchive -archivePath build/supacode.xcarchive -exportPath build/export -exportOptionsPlist build/ExportOptions.plist 2>&1 | { mise exec -- xcbeautify --quiet --disable-logging || cat; }'

# Personal-fork distribution channel. Info.plist points SUFeedURL/SUPublicEDKey at the
# rolling "personal" GitHub release on the fork, so every build updates from our own
# Sparkle feed instead of the official one. The build number is the commit count, which
# is monotonic across upstream merges — Sparkle only offers an update after a new commit.
PERSONAL_RELEASE_TAG := personal
# Explicit -R: in a fork clone with an upstream remote, bare gh resolves to the parent repo.
PERSONAL_REPO := sspross/supacode
PERSONAL_DOWNLOAD_URL := https://github.com/$(PERSONAL_REPO)/releases/download/$(PERSONAL_RELEASE_TAG)/
PERSONAL_SPARKLE_KEY := $(HOME)/.config/supacode-personal/sparkle_eddsa_private.key
SPARKLE_BIN := Tuist/.build/artifacts/sparkle/Sparkle/bin

dist-personal: $(TUIST_RELEASE_GENERATION_STAMP) # Build Release for the personal Sparkle channel and zip it
	$(SELECT_DEVELOPER_DIR); \
	build_num="$$(git rev-list --count HEAD)"; export build_num; \
	bash -o pipefail -c 'xcodebuild -workspace "$(PROJECT_WORKSPACE)" -scheme "$(APP_SCHEME)" -configuration Release build CURRENT_PROJECT_VERSION="$$build_num" -skipMacroValidation $(XCODEBUILD_FLAGS) 2>&1 | { mise exec -- xcbeautify --disable-logging || cat; }'; \
	settings="$$(xcodebuild -workspace "$(PROJECT_WORKSPACE)" -scheme "$(APP_SCHEME)" -configuration Release -showBuildSettings -json 2>/dev/null)"; \
	build_dir="$$(echo "$$settings" | jq -r '.[0].buildSettings.BUILT_PRODUCTS_DIR')"; \
	product="$$(echo "$$settings" | jq -r '.[0].buildSettings.FULL_PRODUCT_NAME')"; \
	src="$$build_dir/$$product"; \
	version="$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$$src/Contents/Info.plist")"; \
	rm -rf dist; \
	mkdir -p dist; \
	zip_path="dist/supacode-personal-$$version-$$build_num.zip"; \
	ditto -c -k --keepParent "$$src" "$$zip_path"; \
	echo "created $$zip_path"

release-personal: dist-personal # Publish the personal build + Sparkle appcast to the rolling GitHub release
	@if [ ! -f "$(PERSONAL_SPARKLE_KEY)" ]; then \
		echo "missing Sparkle private key: $(PERSONAL_SPARKLE_KEY)"; \
		echo "restore it with: $(SPARKLE_BIN)/generate_keys --account supacode-personal -x $(PERSONAL_SPARKLE_KEY)"; \
		exit 1; \
	fi
	$(SPARKLE_BIN)/generate_appcast --ed-key-file "$(PERSONAL_SPARKLE_KEY)" --download-url-prefix "$(PERSONAL_DOWNLOAD_URL)" -o dist/appcast.xml dist
	gh release view -R "$(PERSONAL_REPO)" "$(PERSONAL_RELEASE_TAG)" >/dev/null 2>&1 || { \
		git tag -f "$(PERSONAL_RELEASE_TAG)"; \
		git push origin "$(PERSONAL_RELEASE_TAG)"; \
		gh release create -R "$(PERSONAL_REPO)" "$(PERSONAL_RELEASE_TAG)" --verify-tag --prerelease --title "Personal builds" \
			--notes "Rolling personal-build channel for the customcode fork. Installed apps update via appcast.xml here."; \
	}
	gh release upload -R "$(PERSONAL_REPO)" "$(PERSONAL_RELEASE_TAG)" dist/supacode-personal-*.zip dist/appcast.xml --clobber
	@echo "published: https://github.com/sspross/supacode/releases/tag/$(PERSONAL_RELEASE_TAG)"

test: $(TUIST_DEVELOPMENT_GENERATION_STAMP) # Run all tests
	@$(SELECT_DEVELOPER_DIR); \
	if [ -t 1 ]; then \
		bash -o pipefail -c 'xcodebuild test -workspace "$(PROJECT_WORKSPACE)" -scheme "$(APP_SCHEME)" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation -parallel-testing-enabled NO 2>&1 | { mise exec -- xcbeautify --disable-logging || cat; }'; \
	else \
		xcodebuild test -workspace "$(PROJECT_WORKSPACE)" -scheme "$(APP_SCHEME)" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation -parallel-testing-enabled NO; \
	fi

format: # Format code with swift-format (mise-pinned for reproducibility).
	mise exec -- swift-format --parallel --in-place --recursive --configuration ./.swift-format.json supacode supacode-cli supacodeTests SupacodeSettingsShared SupacodeSettingsFeature

lint: # Lint code with swiftlint
	mise exec -- swiftlint lint --quiet --config .swiftlint.yml

check: format lint # Format and lint

log-stream: # Stream logs from the app via log stream
	log stream --predicate 'subsystem == "app.supabit.supacode"' --style compact --color always

bump-version: # Bump app version (usage: make bump-version VERSION=x.y.z [BUILD=123] [TITLE=… BODY=…])
	@./scripts/bump-version.sh

# main.yml detects the tag at HEAD and cuts the release, prepending its headline.
bump-and-release: bump-version # Bump version and push tags to trigger the release (usage: make bump-and-release VERSION=x.y.z [TITLE=… BODY=…])
	git push --follow-tags
