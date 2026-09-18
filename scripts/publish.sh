#!/bin/sh
set -eu

# =============================================================================
# Script:       publish.sh
# Author:       Andrew J. Moore
# Date:         2026-09-18
# Revision:     r2
#
# Description:
#   Publish previously built canonical Caddy release artifacts.
#
#   This script does not rebuild anything.
#
#   Targets:
#     image
#       Publishes the existing multi-platform OCI archive to GHCR as:
#
#         ghcr.io/gesandrewmoore/caddy:<VERSION>
#         ghcr.io/gesandrewmoore/caddy:latest
#
#       The complete OCI image index, including linux/amd64 and linux/arm64,
#       is copied from the existing archive with skopeo.
#
#     windows
#       Publishes the existing Windows ZIP archive to the GitHub Release:
#
#         v<VERSION>
#
#       If the release already exists, the asset is replaced in place.
#
#   Stable publication policy:
#     - The working tree must be clean.
#     - origin/main is fetched before publishing.
#     - If the current commit is not contained in origin/main, publication
#       requires an explicit [y/N] confirmation.
#     - The latest stable upstream Caddy release determines VERSION.
#     - Required build artifacts must already exist under dist/.
#
# Authentication:
#   GHCR:
#     GHCR_PAT_OP_REF must point to a 1Password item, not an individual field.
#     The item must contain:
#
#       username
#       credential
#
#     The credential must have permission to publish to GHCR.
#
#   GitHub Releases:
#     GITHUB_PAT_OP_REF may point to a separate 1Password item with the same
#     username/credential field convention. If omitted, GHCR_PAT_OP_REF is
#     reused. The credential must have sufficient GitHub repository
#     permissions to create releases and upload assets.
#
# Optional environment:
#   GHCR_PAT_OP_REF     Required for image publication; 1Password item ref
#   GITHUB_PAT_OP_REF   Optional; defaults to GHCR_PAT_OP_REF
#
# Usage:
#   ./scripts/publish.sh --target image
#   ./scripts/publish.sh --target windows
# =============================================================================

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$REPO_DIR/dist"

CADDY_RELEASE_API="https://api.github.com/repos/caddyserver/caddy/releases/latest"

IMAGE_REPO="ghcr.io/gesandrewmoore/caddy"
GITHUB_REPO="gesandrewmoore/caddy"
GHCR_REGISTRY="ghcr.io"

TARGET=""

usage() {
    cat <<'EOF'
Usage:
  publish.sh --target image
  publish.sh --target windows

Targets:
  image       Publish the existing multi-platform OCI archive to GHCR as
              <VERSION> and latest.

  windows     Publish the existing Windows ZIP to GitHub Release v<VERSION>.
              If that release already exists, replace the asset in place.

This script publishes existing artifacts only. It never rebuilds them.
EOF
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: required command not found: $1" >&2
        exit 1
    fi
}

discover_latest_stable() {
    RELEASE_JSON="$(
        curl -fsSL \
            -H "Accept: application/vnd.github+json" \
            -H "User-Agent: gesandrewmoore-caddy-publish" \
            "$CADDY_RELEASE_API"
    )"

    RELEASE_TAG="$(
        printf '%s\n' "$RELEASE_JSON" |
            grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' |
            head -n 1 |
            sed 's/^.*"tag_name"[[:space:]]*:[[:space:]]*"//; s/"$//'
    )"

    if [ -z "$RELEASE_TAG" ]; then
        echo "Error: unable to determine latest stable Caddy release." >&2
        exit 1
    fi

    if ! printf '%s\n' "$RELEASE_TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo "Error: unexpected stable Caddy release tag: $RELEASE_TAG" >&2
        exit 1
    fi

    CADDY_VERSION="${RELEASE_TAG#v}"
}

git_metadata() {
    if ! git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "Error: $REPO_DIR is not a Git repository." >&2
        exit 1
    fi

    GIT_COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD)"
    GIT_SHORT="$(git -C "$REPO_DIR" rev-parse --short=7 HEAD)"
    GIT_BRANCH="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)"

    if [ "$GIT_BRANCH" = "HEAD" ]; then
        GIT_BRANCH="detached"
    fi
}

require_clean_tree() {
    if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
        echo "Error: publication requires a clean Git working tree." >&2
        echo
        git -C "$REPO_DIR" status --short >&2
        exit 1
    fi
}

check_origin_main() {
    echo "Fetching origin/main..."
    git -C "$REPO_DIR" fetch --quiet origin main

    if git -C "$REPO_DIR" merge-base --is-ancestor "$GIT_COMMIT" origin/main; then
        return
    fi

    echo
    echo "NOTICE: current commit is not contained in origin/main."
    echo
    echo "  Current branch: $GIT_BRANCH"
    echo "  Current commit: $GIT_SHORT"
    echo "  origin/main:    $(git -C "$REPO_DIR" rev-parse --short=7 origin/main)"
    echo
    echo "This may mean the current commit has not been pushed or merged."
    printf "Continue publishing anyway? [y/N] "

    read -r ANSWER
    case "$ANSWER" in
        y|Y|yes|YES|Yes)
            ;;
        *)
            echo "Publication cancelled."
            exit 1
            ;;
    esac
}

read_op_item_field() {
    ITEM_REF="$1"
    FIELD="$2"
    LABEL="$3"

    if [ -z "$ITEM_REF" ]; then
        echo "Error: $LABEL is not set." >&2
        exit 1
    fi

    VALUE="$(op read "${ITEM_REF}/${FIELD}")"

    if [ -z "$VALUE" ]; then
        echo "Error: 1Password returned an empty ${FIELD} field for $LABEL." >&2
        exit 1
    fi

    printf '%s' "$VALUE"
}

publish_image() {
    ARTIFACT="$DIST_DIR/caddy-${CADDY_VERSION}-linux-multiarch.oci.tar"

    if [ ! -f "$ARTIFACT" ]; then
        echo "Error: release image artifact not found:" >&2
        echo "  $ARTIFACT" >&2
        echo >&2
        echo "Build it first with:" >&2
        echo "  ./scripts/build.sh --target image" >&2
        exit 1
    fi

    if [ -z "${GHCR_PAT_OP_REF:-}" ]; then
        echo "Error: GHCR_PAT_OP_REF is required to publish the image." >&2
        exit 1
    fi

    TMP_DIR="$(mktemp -d)"
    AUTH_FILE="$TMP_DIR/auth.json"
    VERSION_DIGEST_FILE="$TMP_DIR/version.digest"
    LATEST_DIGEST_FILE="$TMP_DIR/latest.digest"

    cleanup_tmp() {
        rm -rf "$TMP_DIR"
    }
    trap cleanup_tmp EXIT INT TERM

    GHCR_USERNAME="$(read_op_item_field "$GHCR_PAT_OP_REF" "username" "GHCR_PAT_OP_REF")"
    GHCR_PAT="$(read_op_item_field "$GHCR_PAT_OP_REF" "credential" "GHCR_PAT_OP_REF")"

    printf '%s' "$GHCR_PAT" |
        skopeo login \
            --authfile "$AUTH_FILE" \
            --username "$GHCR_USERNAME" \
            --password-stdin \
            "$GHCR_REGISTRY" >/dev/null

    unset GHCR_PAT

    VERSION_IMAGE="${IMAGE_REPO}:${CADDY_VERSION}"
    LATEST_IMAGE="${IMAGE_REPO}:latest"

    echo
    echo "Publishing release Linux image..."
    echo "  Artifact:       $ARTIFACT"
    echo "  Version tag:    $VERSION_IMAGE"
    echo "  Latest tag:     $LATEST_IMAGE"
    echo "  Git branch:     $GIT_BRANCH"
    echo "  Git commit:     $GIT_SHORT"
    echo

    skopeo copy \
        --all \
        --preserve-digests \
        --authfile "$AUTH_FILE" \
        --digestfile "$VERSION_DIGEST_FILE" \
        "oci-archive:$ARTIFACT" \
        "docker://$VERSION_IMAGE"

    VERSION_DIGEST="$(cat "$VERSION_DIGEST_FILE")"

    echo
    echo "Promoting version image to latest..."
    echo

    skopeo copy \
        --all \
        --preserve-digests \
        --authfile "$AUTH_FILE" \
        --digestfile "$LATEST_DIGEST_FILE" \
        "docker://$VERSION_IMAGE" \
        "docker://$LATEST_IMAGE"

    LATEST_DIGEST="$(cat "$LATEST_DIGEST_FILE")"

    if [ "$VERSION_DIGEST" != "$LATEST_DIGEST" ]; then
        echo "Error: version and latest manifest digests differ after publication." >&2
        echo "  Version: $VERSION_DIGEST" >&2
        echo "  Latest:  $LATEST_DIGEST" >&2
        exit 1
    fi

    echo
    echo "Release image publication complete:"
    echo "  $VERSION_IMAGE"
    echo "  $LATEST_IMAGE"
    echo "  Digest: $VERSION_DIGEST"
}

publish_windows() {
    ARTIFACT="$DIST_DIR/caddy-${CADDY_VERSION}-windows-amd64.zip"
    RELEASE_TAG="v${CADDY_VERSION}"

    if [ ! -f "$ARTIFACT" ]; then
        echo "Error: Windows release artifact not found:" >&2
        echo "  $ARTIFACT" >&2
        echo >&2
        echo "Build it first with:" >&2
        echo "  ./scripts/build.sh --target windows" >&2
        exit 1
    fi

    GITHUB_ITEM_REF="${GITHUB_PAT_OP_REF:-${GHCR_PAT_OP_REF:-}}"

    if [ -z "$GITHUB_ITEM_REF" ]; then
        echo "Error: GITHUB_PAT_OP_REF or GHCR_PAT_OP_REF is required to publish the GitHub Release." >&2
        exit 1
    fi

    GITHUB_PAT="$(read_op_item_field "$GITHUB_ITEM_REF" "credential" "GitHub PAT 1Password item")"

    echo
    echo "Publishing release Windows artifact..."
    echo "  Artifact:       $ARTIFACT"
    echo "  GitHub repo:    $GITHUB_REPO"
    echo "  Release tag:    $RELEASE_TAG"
    echo "  Git branch:     $GIT_BRANCH"
    echo "  Git commit:     $GIT_SHORT"
    echo

    if GH_TOKEN="$GITHUB_PAT" gh release view "$RELEASE_TAG" \
        --repo "$GITHUB_REPO" >/dev/null 2>&1; then

        echo "GitHub Release already exists; replacing matching asset..."
        echo

        GH_TOKEN="$GITHUB_PAT" gh release upload "$RELEASE_TAG" \
            "$ARTIFACT" \
            --repo "$GITHUB_REPO" \
            --clobber
    else
        echo "Creating GitHub Release..."
        echo

        GH_TOKEN="$GITHUB_PAT" gh release create "$RELEASE_TAG" \
            "$ARTIFACT" \
            --repo "$GITHUB_REPO" \
            --target "$GIT_COMMIT" \
            --title "Caddy ${CADDY_VERSION}" \
            --notes "Custom Caddy ${CADDY_VERSION} build with the GES standard plugin set." \
            --latest
    fi

    unset GITHUB_PAT

    echo
    echo "Release Windows publication complete:"
    echo "  GitHub Release: $RELEASE_TAG"
    echo "  Asset:          $(basename "$ARTIFACT")"
}

# -----------------------------------------------------------------------------
# Arguments
# -----------------------------------------------------------------------------

while [ "$#" -gt 0 ]; do
    case "$1" in
        --target)
            if [ "$#" -lt 2 ]; then
                echo "Error: --target requires a value." >&2
                exit 1
            fi
            TARGET="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown argument: $1" >&2
            echo
            usage >&2
            exit 1
            ;;
    esac
done

case "$TARGET" in
    image|windows)
        ;;
    "")
        echo "Error: --target is required." >&2
        echo
        usage >&2
        exit 1
        ;;
    *)
        echo "Error: unsupported target: $TARGET" >&2
        exit 1
        ;;
esac

# -----------------------------------------------------------------------------
# Prerequisites and repository state
# -----------------------------------------------------------------------------

require_command git
require_command curl
require_command grep
require_command sed
require_command op

case "$TARGET" in
    image)
        require_command skopeo
        ;;
    windows)
        require_command gh
        ;;
esac

git_metadata
require_clean_tree
check_origin_main

echo
echo "Checking latest stable Caddy release..."
discover_latest_stable

# -----------------------------------------------------------------------------
# Publish
# -----------------------------------------------------------------------------

case "$TARGET" in
    image)
        publish_image
        ;;
    windows)
        publish_windows
        ;;
esac
