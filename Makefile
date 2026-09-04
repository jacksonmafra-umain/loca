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

# Whichever codesigning identity this machine has. Override to pick another:
#   make app SIGN_ID="Apple Development: you (XXXXXXXXXX)"
# List them with: security find-identity -v -p codesigning
SIGN_ID ?= $(shell security find-identity -v -p codesigning | head -1 | sed -E 's/.*"(.*)"/\1/')

.DEFAULT_GOAL := app

.PHONY: help
help:
	@echo "make test              run the LocaCore test suite"
	@echo "make build             compile both executables"
	@echo "make app               assemble and sign $(APP)"
	@echo "make install           copy the app to /Applications and launch it"
	@echo "make run               launch the app from $(BUILD_DIR)"
	@echo "make reinstall-helper  bootout and reload the helper after a rebuild"
	@echo "make identity          show the signing identity that will be used"
	@echo "make clean             remove $(BUILD_DIR) and .build"

.PHONY: identity
identity:
	@echo "SIGN_ID = $(SIGN_ID)"

.PHONY: test
test:
	swift test

.PHONY: build
build:
	swift build -c $(CONFIG) --product $(APP_BINARY)
	swift build -c $(CONFIG) --product $(HELPER_NAME)

# The layout SMAppService expects: both executables in Contents/MacOS, and the
# daemon's plist in Contents/Library/LaunchDaemons.
.PHONY: app
app: build
	@if [ -z "$(SIGN_ID)" ]; then \
		echo "error: no codesigning identity found."; \
		echo "       Install an Apple Development certificate, or pass SIGN_ID=..."; \
		exit 1; \
	fi
	rm -rf "$(APP)"
	mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources" "$(CONTENTS)/Library/LaunchDaemons"
	cp "$(SWIFT_BIN)/$(APP_BINARY)" "$(CONTENTS)/MacOS/$(APP_BINARY)"
	cp "$(SWIFT_BIN)/$(HELPER_NAME)" "$(CONTENTS)/MacOS/$(HELPER_NAME)"
	cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	cp Resources/$(HELPER_LABEL).plist "$(CONTENTS)/Library/LaunchDaemons/$(HELPER_LABEL).plist"
	printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	plutil -lint "$(CONTENTS)/Info.plist"
	plutil -lint "$(CONTENTS)/Library/LaunchDaemons/$(HELPER_LABEL).plist"
	@# The helper is signed first: the app's signature has to cover the already
	@# signed nested binary, or the bundle seal does not verify.
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

.PHONY: clean
clean:
	rm -rf "$(BUILD_DIR)" .build
