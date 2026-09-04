# Loca — build, sign, install.
#
# There is no Xcode project on purpose. Assembling the bundle here keeps every
# step readable and runnable from a shell, and leaves nothing in a binary
# project file that cannot be reviewed in a diff.

SHELL := /bin/bash

APP_NAME    := Loca
BUNDLE_ID   := dev.loca
HELPER_NAME := LocaHelper
APP_BINARY  := LocaApp
HELPER_LABEL := dev.loca.helper

CONFIG    := release
BUILD_DIR := build
APP       := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS  := $(APP)/Contents
SWIFT_BIN := .build/$(CONFIG)

# Caddy is pinned by version and by checksum, and not committed. Pinning both
# means a third party's build is byte-identical to ours, and a tampered or
# truncated download is refused rather than signed into the bundle.
CADDY_VERSION := 2.11.4
CADDY_SHA256_arm64 := 9efb0af2d6cf09cfb5053c0e51721b9b3d4956d346234f39368d943d25a3c9a7
CADDY_SHA256_amd64 := 34bc9e5cceee8d67844ef51da624f5b79e8d070f27236e050c3f0066a2dba534

VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG := $(BUILD_DIR)/$(APP_NAME)-$(VERSION).dmg
DMG_STAGING := $(BUILD_DIR)/dmg

# The keychain profile `notarytool` stores credentials under. Create it once:
#   xcrun notarytool store-credentials loca-notary \
#     --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific>
NOTARY_PROFILE ?= loca-notary

CADDY_ARCH := $(if $(filter arm64,$(shell uname -m)),arm64,amd64)
CADDY_SHA256 := $(CADDY_SHA256_$(CADDY_ARCH))
CADDY_TARBALL := caddy_$(CADDY_VERSION)_mac_$(CADDY_ARCH).tar.gz
CADDY_URL := https://github.com/caddyserver/caddy/releases/download/v$(CADDY_VERSION)/$(CADDY_TARBALL)
VENDOR_DIR := vendor
CADDY := $(VENDOR_DIR)/caddy

# Whichever codesigning identity this machine has. Override to pick another:
#   make app SIGN_ID="Apple Development: you (XXXXXXXXXX)"
# List them with: security find-identity -v -p codesigning
SIGN_ID ?= $(shell security find-identity -v -p codesigning | head -1 | sed -E 's/.*"(.*)"/\1/')

.DEFAULT_GOAL := app

.PHONY: help
help:
	@echo "make test              run the LocaCore test suite"
	@echo "make check             test plus a release build — what CI runs"
	@echo "make vendor-caddy      download and verify Caddy $(CADDY_VERSION) into $(CADDY)"
	@echo "make build             compile both executables"
	@echo "make app               assemble and sign $(APP)"
	@echo "make install           copy the app to /Applications and launch it"
	@echo "make run               launch the app from $(BUILD_DIR)"
	@echo "make dmg               package $(APP_NAME)-$(VERSION).dmg"
	@echo "make notarize          submit the DMG to Apple and staple the ticket"
	@echo "make release           vendor, check, and package in one go"
	@echo "make signing-report    what this machine's certificate allows"
	@echo "make reinstall-helper  bootout and reload the helper after a rebuild"
	@echo "make uninstall         reverse everything Loca installed"
	@echo "make identity          show the signing identity that will be used"
	@echo "make clean             remove $(BUILD_DIR) and .build"

.PHONY: identity
identity:
	@echo "SIGN_ID = $(SIGN_ID)"

.PHONY: test
test:
	swift test

# The tarball is checksummed on download and deleted afterwards, so an
# unexpected binary is refused before it can be signed into the bundle rather
# than after. An existing vendor/caddy is left alone; `make revendor-caddy`
# forces a fresh download.
$(CADDY):
	@mkdir -p "$(VENDOR_DIR)"
	@echo "downloading $(CADDY_TARBALL)"
	@curl -fsSL -o "$(VENDOR_DIR)/$(CADDY_TARBALL)" "$(CADDY_URL)"
	@echo "$(CADDY_SHA256)  $(VENDOR_DIR)/$(CADDY_TARBALL)" | shasum -a 256 -c - \
		|| { echo "error: checksum mismatch for $(CADDY_TARBALL); refusing it"; \
		     rm -f "$(VENDOR_DIR)/$(CADDY_TARBALL)"; exit 1; }
	@tar -xzf "$(VENDOR_DIR)/$(CADDY_TARBALL)" -C "$(VENDOR_DIR)" caddy
	@rm -f "$(VENDOR_DIR)/$(CADDY_TARBALL)"
	@chmod +x "$(CADDY)"

.PHONY: vendor-caddy
vendor-caddy: $(CADDY)
	@"$(CADDY)" version

.PHONY: revendor-caddy
revendor-caddy:
	rm -f "$(CADDY)"
	$(MAKE) vendor-caddy

.PHONY: build
build:
	swift build -c $(CONFIG) --product $(APP_BINARY)
	swift build -c $(CONFIG) --product $(HELPER_NAME)

# Exactly what CI runs. Worth having as one command: `swift test` builds in
# debug, and the concurrency checker rejects things in a release build that it
# waves through in a debug one — which is how a CI failure first got past a
# green local test run.
.PHONY: check
check: test build
	@echo "test and release build both clean"

# The layout SMAppService expects: both executables in Contents/MacOS, and the
# daemon's plist in Contents/Library/LaunchDaemons.
.PHONY: app
app: build $(CADDY)
	@if [ -z "$(SIGN_ID)" ]; then \
		echo "error: no codesigning identity found."; \
		echo "       Install an Apple Development certificate, or pass SIGN_ID=..."; \
		exit 1; \
	fi
	rm -rf "$(APP)"
	mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources" "$(CONTENTS)/Library/LaunchDaemons"
	cp "$(SWIFT_BIN)/$(APP_BINARY)" "$(CONTENTS)/MacOS/$(APP_BINARY)"
	cp "$(SWIFT_BIN)/$(HELPER_NAME)" "$(CONTENTS)/MacOS/$(HELPER_NAME)"
	cp "$(CADDY)" "$(CONTENTS)/Resources/caddy"
	cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	cp Resources/$(HELPER_LABEL).plist "$(CONTENTS)/Library/LaunchDaemons/$(HELPER_LABEL).plist"
	printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	plutil -lint "$(CONTENTS)/Info.plist"
	plutil -lint "$(CONTENTS)/Library/LaunchDaemons/$(HELPER_LABEL).plist"
	@# Every nested Mach-O is signed before the app. An unsigned binary inside a
	@# signed bundle invalidates the outer signature, and Caddy arrives unsigned.
	codesign --force --options runtime --timestamp=none \
		--sign "$(SIGN_ID)" "$(CONTENTS)/Resources/caddy"
	codesign --force --options runtime --timestamp=none \
		--identifier "$(HELPER_LABEL)" \
		--sign "$(SIGN_ID)" "$(CONTENTS)/MacOS/$(HELPER_NAME)"
	codesign --force --options runtime --timestamp=none \
		--identifier "$(BUNDLE_ID)" \
		--entitlements Resources/LocaApp.entitlements \
		--sign "$(SIGN_ID)" "$(APP)"
	codesign --verify --deep --strict --verbose=2 "$(APP)"
	@echo "built $(APP)"

.PHONY: run
run: app
	open "$(APP)"

# MARK: - Distribution
#
# Everything below works today except notarization, which needs a "Developer ID
# Application" certificate — a paid Apple Developer Program membership. A build
# signed with an "Apple Development" certificate runs on the machine that built
# it and is refused by Gatekeeper anywhere else, so a DMG made from one is for
# your own machines, not for handing out.

.PHONY: signing-report
signing-report:
	@echo "identity:      $(SIGN_ID)"
	@if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then \
		echo "distribution:  Developer ID found — notarization is possible"; \
	else \
		echo "distribution:  NOT possible — no 'Developer ID Application' certificate."; \
		echo "               An 'Apple Development' certificate signs a build that runs"; \
		echo "               here and is refused by Gatekeeper on any other Mac."; \
		echo "               Getting one needs a paid Apple Developer Program membership."; \
	fi

$(DMG): app
	rm -rf "$(DMG_STAGING)" "$(DMG)"
	mkdir -p "$(DMG_STAGING)"
	cp -R "$(APP)" "$(DMG_STAGING)/"
	@# The conventional drag-to-install layout: the app beside a shortcut to
	@# where it has to end up. Loca genuinely requires /Applications —
	@# SMAppService will not register a root daemon from a user-writable
	@# folder — so this is not decoration.
	ln -s /Applications "$(DMG_STAGING)/Applications"
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$(DMG_STAGING)" \
		-ov -format UDZO "$(DMG)"
	rm -rf "$(DMG_STAGING)"
	@echo "built $(DMG)"

.PHONY: dmg
dmg: $(DMG)
	@$(MAKE) --no-print-directory signing-report

# Submits the DMG to Apple and staples the ticket to it, so it opens on a Mac
# that has never seen it before without a Gatekeeper warning.
.PHONY: notarize
notarize: dmg
	@if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then \
		echo "error: notarization needs a 'Developer ID Application' certificate."; \
		echo "       This machine has none, so Apple would reject the submission."; \
		echo "       See the Distribution page in the wiki."; \
		exit 1; \
	fi
	@if ! xcrun notarytool history --keychain-profile "$(NOTARY_PROFILE)" >/dev/null 2>&1; then \
		echo "error: no notarytool credentials under the profile '$(NOTARY_PROFILE)'."; \
		echo "       Store them once with:"; \
		echo "         xcrun notarytool store-credentials $(NOTARY_PROFILE) \\"; \
		echo "           --apple-id <you@example.com> --team-id <TEAMID> \\"; \
		echo "           --password <app-specific-password>"; \
		exit 1; \
	fi
	xcrun notarytool submit "$(DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(DMG)"
	xcrun stapler validate "$(DMG)"
	@echo "notarized and stapled $(DMG)"

# What a release actually is, in one command.
.PHONY: release
release: vendor-caddy check dmg
	@echo ""
	@echo "release candidate: $(DMG)"
	@echo "run 'make notarize' before handing it to anyone else."

.PHONY: install
install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP)" /Applications/
	open "/Applications/$(APP_NAME).app"

# After changing helper code, launchd keeps running the old copy until it is
# booted out. This is the shortest path back to a fresh one.
.PHONY: reinstall-helper
reinstall-helper: app
	-sudo launchctl bootout system/$(HELPER_LABEL) 2>/dev/null
	@echo "helper booted out. Relaunch the app and re-register it to load the new build."

# Reverses everything Loca installed, and nothing else. Project folders, the
# saved domain list, and the runner logs are left alone — see the app's own
# output for what stays and why.
.PHONY: uninstall
uninstall:
	@if [ -x "/Applications/$(APP_NAME).app/Contents/MacOS/$(APP_BINARY)" ]; then \
		"/Applications/$(APP_NAME).app/Contents/MacOS/$(APP_BINARY)" --uninstall; \
	elif [ -x "$(CONTENTS)/MacOS/$(APP_BINARY)" ]; then \
		"$(CONTENTS)/MacOS/$(APP_BINARY)" --uninstall; \
	else \
		echo "error: no built or installed app to uninstall from."; \
		echo "       Run 'make app' first, or remove /Applications/$(APP_NAME).app by hand."; \
		exit 1; \
	fi
	@echo ""
	@echo "The app itself is still in /Applications. Drag it to the Trash to finish."

.PHONY: clean
clean:
	rm -rf "$(BUILD_DIR)" .build
