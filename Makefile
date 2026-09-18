# =============================================================================
# Makefile
# Author:       Andrew J. Moore
# Date:         2026-09-18
# Revision:     r1
#
# Description:
#   Front-end for the Caddy build and publication workflow.
#
#   The shell scripts remain the implementation layer; this Makefile only
#   orchestrates them.
#
# Common usage:
#
#   make
#   make release
#       Build and publish the complete canonical release.
#
#   make build
#       Build the canonical image and all canonical binary packages.
#
#   make publish
#       Publish already-built canonical image and binary packages.
#
#   make image
#   make binary
#   make binary OS=linux
#   make binary OS=linux ARCH=arm64
#
#   make publish-image
#   make publish-binary
#   make publish-binary OS=linux ARCH=amd64
#
#   make dev VERSION=master
#   make dev-image VERSION=master
#   make dev-binary VERSION=master
#   make dev-binary VERSION=master OS=linux ARCH=arm64
# =============================================================================

.DEFAULT_GOAL := release

BUILD_SCRIPT   := ./scripts/build.sh
PUBLISH_SCRIPT := ./scripts/publish.sh

OS_ARG      = $(if $(strip $(OS)),--os $(OS),)
ARCH_ARG    = $(if $(strip $(ARCH)),--arch $(ARCH),)
VERSION_ARG = $(if $(strip $(VERSION)),--version $(VERSION),)

.PHONY: \
	release build publish \
	image binary \
	publish-image publish-binary \
	dev dev-image dev-binary \
	clean help \
	require-version

# -----------------------------------------------------------------------------
# Canonical release
# -----------------------------------------------------------------------------

release:
	$(MAKE) build
	$(MAKE) publish

build:
	$(MAKE) image
	$(MAKE) binary

publish:
	$(MAKE) publish-image
	$(MAKE) publish-binary

# -----------------------------------------------------------------------------
# Release builds
# -----------------------------------------------------------------------------

image:
	$(BUILD_SCRIPT) --target image

binary:
	$(BUILD_SCRIPT) --target binary $(OS_ARG) $(ARCH_ARG)

# -----------------------------------------------------------------------------
# Release publication
# -----------------------------------------------------------------------------

publish-image:
	$(PUBLISH_SCRIPT) --target image

publish-binary:
	$(PUBLISH_SCRIPT) --target binary $(OS_ARG) $(ARCH_ARG)

# -----------------------------------------------------------------------------
# Development builds
# -----------------------------------------------------------------------------

dev: require-version
	$(MAKE) dev-image VERSION="$(VERSION)"
	$(MAKE) dev-binary VERSION="$(VERSION)"

dev-image: require-version
	$(BUILD_SCRIPT) --target image --dev --version "$(VERSION)" $(ARCH_ARG)

dev-binary: require-version
	$(BUILD_SCRIPT) --target binary --dev --version "$(VERSION)" $(OS_ARG) $(ARCH_ARG)

require-version:
	@test -n "$(strip $(VERSION))" || { \
		echo "Error: VERSION is required for development builds."; \
		echo "Example: make dev-image VERSION=master"; \
		exit 1; \
	}

# -----------------------------------------------------------------------------
# Housekeeping
# -----------------------------------------------------------------------------

clean:
	rm -rf dist

help:
	@printf '%s\n' \
		'' \
		'Canonical release:' \
		'  make / make release       Build and publish everything' \
		'  make build                Build image + all binaries' \
		'  make publish              Publish existing image + binaries' \
		'' \
		'Release build targets:' \
		'  make image' \
		'  make binary [OS=linux|windows] [ARCH=amd64|arm64]' \
		'' \
		'Release publish targets:' \
		'  make publish-image' \
		'  make publish-binary [OS=linux|windows] [ARCH=amd64|arm64]' \
		'' \
		'Development targets:' \
		'  make dev VERSION=<ref>' \
		'  make dev-image VERSION=<ref> [ARCH=amd64|arm64]' \
		'  make dev-binary VERSION=<ref> [OS=linux|windows] [ARCH=amd64|arm64]' \
		'' \
		'Housekeeping:' \
		'  make clean' \
		'  make help' \
		''
