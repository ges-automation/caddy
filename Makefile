# =============================================================================
# Makefile
# Author:       Andrew J. Moore
# Date:         2026-09-21
# Revision:     r4
#
# Description:
#   Front-end for the Caddy build and publication workflow.
#
#   The shell scripts remain the implementation layer; this Makefile only
#   exposes the standard repository actions that this project supports.
#
# Common usage:
#
#   make
#   make package
#       Create all canonical standalone binary packages locally.
#
#   make image
#       Build the canonical multi-platform OCI image archive locally.
#
#   make package VERSION=master
#   make image VERSION=master
#       Create development artifacts from an upstream Caddy ref.
#
#   make image-push
#       Publish the canonical image to GHCR.
#
#   make release
#       Publish canonical binary packages to a GitHub Release.
#
#   make clean
#       Remove dist/, local images belonging to this build workflow, and
#       Docker Buildx build cache.
# =============================================================================

.DEFAULT_GOAL := package

BUILD_SCRIPT   := ./scripts/build.sh
PUBLISH_SCRIPT := ./scripts/publish.sh

OS_ARG      = $(if $(strip $(OS)),--os $(OS),)
ARCH_ARG    = $(if $(strip $(ARCH)),--arch $(ARCH),)
DEV_ARGS    = $(if $(strip $(VERSION)),--dev --version "$(VERSION)",)

.PHONY: package image image-push release clean help

# -----------------------------------------------------------------------------
# Local artifacts
# -----------------------------------------------------------------------------

package:
	$(BUILD_SCRIPT) --target binary $(OS_ARG) $(ARCH_ARG) $(DEV_ARGS)

image:
	$(BUILD_SCRIPT) --target image $(ARCH_ARG) $(DEV_ARGS)

# -----------------------------------------------------------------------------
# External publication
# -----------------------------------------------------------------------------

image-push:
	@test -z "$(strip $(VERSION))" || { \
		echo "Error: VERSION is not valid for image-push; only canonical images are published."; \
		exit 1; \
	}
	$(PUBLISH_SCRIPT) --target image

release:
	@test -z "$(strip $(VERSION))" || { \
		echo "Error: VERSION is not valid for release; only canonical packages are published."; \
		exit 1; \
	}
	$(PUBLISH_SCRIPT) --target binary $(OS_ARG) $(ARCH_ARG)

# -----------------------------------------------------------------------------
# Housekeeping
# -----------------------------------------------------------------------------

clean:
	rm -rf dist
	@images="$$(docker image ls --format '{{.Repository}}:{{.Tag}}' | \
		grep -E '^(caddy:.*-dev|ghcr\.io/ges-automation/caddy:)' || true)"; \
	if [ -n "$$images" ]; then \
		echo "Removing local Caddy build images:"; \
		printf '%s\n' "$$images"; \
		printf '%s\n' "$$images" | xargs -r docker image rm; \
	else \
		echo "No local Caddy build images to remove."; \
	fi
	@echo "Clearing Docker Buildx build cache..."
	docker buildx prune --all --force

help:
	@printf '%s\n' \
		'' \
		'Local artifact targets:' \
		'  make / make package       Create all standalone binary packages' \
		'  make package [OS=linux|windows] [ARCH=amd64|arm64]' \
		'  make image                Build the multi-platform OCI image archive' \
		'' \
		'Development builds:' \
		'  make package VERSION=<ref> [OS=linux|windows] [ARCH=amd64|arm64]' \
		'  make image VERSION=<ref> [ARCH=amd64|arm64]' \
		'' \
		'External publication targets:' \
		'  make image-push           Push the canonical image to GHCR' \
		'  make release [OS=linux|windows] [ARCH=amd64|arm64]' \
		'                             Publish packages to a GitHub Release' \
		'' \
		'Housekeeping:' \
		'  make clean                Remove dist/, local Caddy images, and build cache' \
		'  make help' \
		''
