#!/bin/sh
set -eu

# =============================================================================
# Script:       publish-image.sh
# Author:       Andrew J. Moore
# Date:         2026-09-18
# Revision:     r1
#
# Description:
#   Builds and publishes the canonical stable GES Caddy container image.
#
#   The script:
#     - Requires a clean Git working tree.
#     - Warns if the current commit is not contained in origin/main.
#     - Detects the latest stable upstream Caddy release automatically.
#     - Builds linux/amd64 and linux/arm64 images with Docker Buildx.
#     - Publishes both the upstream-version tag and the moving "latest" tag.
#     - Records Git revision and branch information as image metadata.
#     - Uses a temporary Docker configuration for GHCR authentication.
#     - Verifies both published tags and required platforms after publishing.
#
# Published image tags:
#   ghcr.io/gesandrewmoore/caddy:<CADDY_VERSION>
#   ghcr.io/gesandrewmoore/caddy:latest
#
# Environment:
#   GHCR_PAT_OP_REF
#     1Password item reference containing:
#       username   GitHub/GHCR username
#       credential GitHub PAT with package write access
#
#     Example:
#       op://<vault-id>/<item-id>
#
# Notes:
#   Stable version tags are intentionally allowed to be republished. This makes
#   it possible to correct the plugin configuration for an existing upstream
#   Caddy version. The "latest" tag is reserved for stable releases.
# =============================================================================

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

IMAGE_REPO="ghcr.io/gesandrewmoore/caddy"
SOURCE_URL="https://github.com/gesandrewmoore/caddy"
CADDY_RELEASE_API="https://api.github.com/repos/caddyserver/caddy/releases/latest"
PLATFORMS="linux/amd64,linux/arm64"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: required command not found: $1" >&2
        exit 1
    fi
}

ensure_op_session() {
    if op whoami >/dev/null 2>&1; then
        return
    fi

    echo "Signing in to 1Password..."
    eval "$(op signin)"
}

save_op_reference() {
    PROFILE_FILE="$HOME/.profile"

    if [ -f "$PROFILE_FILE" ]; then
        sed -i '/^[[:space:]]*export[[:space:]]\+GHCR_PAT_OP_REF=/d' "$PROFILE_FILE"
    fi

    printf "\nexport GHCR_PAT_OP_REF='%s'\n" "$GHCR_PAT_OP_REF" >> "$PROFILE_FILE"
    echo "Saved GHCR_PAT_OP_REF to $PROFILE_FILE"
}

confirm_unpublished_commit() {
    echo
    echo "NOTICE: current commit is not contained in origin/main."
    echo
    echo "Current branch: $GIT_BRANCH"
    echo "Current commit:"
    echo "  short: $GIT_SHORT"
    echo "  full:  $GIT_COMMIT"
    echo
    echo "This build can still be published, but the exact Dockerfile/configuration"
    echo "has not been merged into origin/main."
    echo
    printf "Continue publishing? [y/N] "
    read ANSWER

    case "$ANSWER" in
        y|Y)
            ;;
        *)
            echo "Publish cancelled."
            exit 0
            ;;
    esac
}

verify_manifest() {
    IMAGE="$1"

    echo "Verifying published image: $IMAGE" >&2

    MANIFEST_OUTPUT="$(docker buildx imagetools inspect "$IMAGE")"

    if ! printf '%s\n' "$MANIFEST_OUTPUT" | grep -q 'Platform:[[:space:]]*linux/amd64'; then
        echo "Error: published image is missing linux/amd64: $IMAGE" >&2
        exit 1
    fi

    if ! printf '%s\n' "$MANIFEST_OUTPUT" | grep -q 'Platform:[[:space:]]*linux/arm64'; then
        echo "Error: published image is missing linux/arm64: $IMAGE" >&2
        exit 1
    fi

    printf '%s\n' "$MANIFEST_OUTPUT" |
        awk '/^Digest:/ { print $2; exit }'
}

cleanup() {
    unset GHCR_PAT 2>/dev/null || true

    if [ -n "${DOCKER_CONFIG_DIR:-}" ] && [ -d "$DOCKER_CONFIG_DIR" ]; then
        rm -rf "$DOCKER_CONFIG_DIR"
    fi
}

trap cleanup EXIT INT TERM

# -----------------------------------------------------------------------------
# Prerequisites
# -----------------------------------------------------------------------------

require_command git
require_command docker
require_command curl
require_command grep
require_command sed
require_command awk
require_command op

if ! docker buildx version >/dev/null 2>&1; then
    echo "Error: Docker Buildx is not available." >&2
    exit 1
fi

if [ ! -f "$REPO_DIR/Dockerfile" ]; then
    echo "Error: Dockerfile not found at $REPO_DIR/Dockerfile" >&2
    exit 1
fi

if ! git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Error: $REPO_DIR is not a Git repository." >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Validate Git state
# -----------------------------------------------------------------------------

if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
    echo "Error: repository has uncommitted or untracked changes." >&2
    echo >&2
    git -C "$REPO_DIR" status --short >&2
    exit 1
fi

GIT_COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD)"
GIT_SHORT="$(git -C "$REPO_DIR" rev-parse --short=7 HEAD)"
GIT_BRANCH="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)"

if [ "$GIT_BRANCH" = "HEAD" ]; then
    GIT_BRANCH="detached"
fi

if ! git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1; then
    echo "Error: Git remote 'origin' is not configured." >&2
    exit 1
fi

echo "Checking origin/main..."
if ! git -C "$REPO_DIR" fetch --quiet origin main; then
    echo "Error: unable to fetch origin/main." >&2
    exit 1
fi

if ! git -C "$REPO_DIR" merge-base --is-ancestor HEAD origin/main; then
    confirm_unpublished_commit
fi

# -----------------------------------------------------------------------------
# Discover the latest stable upstream Caddy release
# -----------------------------------------------------------------------------

echo "Checking latest stable Caddy release..."

RELEASE_JSON="$(
    curl -fsSL \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: gesandrewmoore-caddy-build" \
        "$CADDY_RELEASE_API"
)"

CADDY_TAG="$(
    printf '%s\n' "$RELEASE_JSON" |
        grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' |
        head -n 1 |
        sed 's/^.*"tag_name"[[:space:]]*:[[:space:]]*"//; s/"$//'
)"

if [ -z "$CADDY_TAG" ]; then
    echo "Error: unable to determine latest stable Caddy release." >&2
    exit 1
fi

if ! printf '%s\n' "$CADDY_TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Error: unexpected Caddy release tag: $CADDY_TAG" >&2
    exit 1
fi

CADDY_VERSION="${CADDY_TAG#v}"

VERSION_IMAGE="${IMAGE_REPO}:${CADDY_VERSION}"
LATEST_IMAGE="${IMAGE_REPO}:latest"
BUILD_CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# -----------------------------------------------------------------------------
# Validate Buildx platform support
# -----------------------------------------------------------------------------

echo "Checking Docker Buildx platform support..."

BUILDER_INFO="$(docker buildx inspect --bootstrap)"

if ! printf '%s\n' "$BUILDER_INFO" | grep -q 'linux/amd64'; then
    echo "Error: current Buildx builder does not advertise linux/amd64 support." >&2
    exit 1
fi

if ! printf '%s\n' "$BUILDER_INFO" | grep -q 'linux/arm64'; then
    echo "Error: current Buildx builder does not advertise linux/arm64 support." >&2
    echo "Configure an ARM64-capable Buildx builder or binfmt/QEMU support first." >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Display release information
# -----------------------------------------------------------------------------

echo
echo "Caddy image release"
echo "-------------------"
echo "Caddy version:  $CADDY_VERSION"
echo "Platforms:      $PLATFORMS"
echo "Git branch:     $GIT_BRANCH"
echo "Git commit:     $GIT_SHORT"
echo "Version tag:    $VERSION_IMAGE"
echo "Latest tag:     $LATEST_IMAGE"
echo

# -----------------------------------------------------------------------------
# Configure 1Password and GHCR authentication
# -----------------------------------------------------------------------------

if [ -z "${GHCR_PAT_OP_REF:-}" ]; then
    printf "1Password GHCR credential item reference: "
    read GHCR_PAT_OP_REF

    if [ -z "$GHCR_PAT_OP_REF" ]; then
        echo "Error: GHCR_PAT_OP_REF cannot be empty." >&2
        exit 1
    fi

    printf "Save GHCR_PAT_OP_REF to ~/.profile? [Y/n] "
    read SAVE_REF

    case "$SAVE_REF" in
        n|N)
            ;;
        *)
            save_op_reference
            ;;
    esac
fi

ensure_op_session

echo "Reading GHCR credentials from 1Password..."

GHCR_USERNAME="$(op read "${GHCR_PAT_OP_REF}/username")"
GHCR_PAT="$(op read "${GHCR_PAT_OP_REF}/credential")"

if [ -z "$GHCR_USERNAME" ] || [ -z "$GHCR_PAT" ]; then
    echo "Error: unable to read GHCR credentials from 1Password." >&2
    exit 1
fi

DOCKER_CONFIG_DIR="$(mktemp -d)"
export DOCKER_CONFIG="$DOCKER_CONFIG_DIR"

printf '%s' "$GHCR_PAT" |
    docker login ghcr.io \
        --username "$GHCR_USERNAME" \
        --password-stdin

unset GHCR_PAT

# -----------------------------------------------------------------------------
# Build and publish the canonical stable image
# -----------------------------------------------------------------------------

echo
echo "Building and publishing Caddy $CADDY_VERSION..."

docker buildx build \
    --platform "$PLATFORMS" \
    --build-arg "CADDY_VERSION=$CADDY_VERSION" \
    --label "org.opencontainers.image.title=GES Caddy" \
    --label "org.opencontainers.image.description=Custom Caddy build with the GES standard plugin set" \
    --label "org.opencontainers.image.source=$SOURCE_URL" \
    --label "org.opencontainers.image.version=$CADDY_VERSION" \
    --label "org.opencontainers.image.revision=$GIT_COMMIT" \
    --label "org.opencontainers.image.created=$BUILD_CREATED" \
    --label "io.ges.build.branch=$GIT_BRANCH" \
    --tag "$VERSION_IMAGE" \
    --tag "$LATEST_IMAGE" \
    --push \
    "$REPO_DIR"

# -----------------------------------------------------------------------------
# Verify publication
# -----------------------------------------------------------------------------

echo
VERSION_DIGEST="$(verify_manifest "$VERSION_IMAGE")"
LATEST_DIGEST="$(verify_manifest "$LATEST_IMAGE")"

if [ -z "$VERSION_DIGEST" ] || [ -z "$LATEST_DIGEST" ]; then
    echo "Error: unable to determine published manifest digest." >&2
    exit 1
fi

if [ "$VERSION_DIGEST" != "$LATEST_DIGEST" ]; then
    echo "Error: version and latest tags do not reference the same manifest." >&2
    echo "Version digest: $VERSION_DIGEST" >&2
    echo "Latest digest:  $LATEST_DIGEST" >&2
    exit 1
fi

echo
echo "Publish complete."
echo
echo "Published:"
echo "  $VERSION_IMAGE"
echo "  $LATEST_IMAGE"
echo
echo "Platforms:"
echo "  linux/amd64"
echo "  linux/arm64"
echo
echo "Manifest digest:"
echo "  $VERSION_DIGEST"
