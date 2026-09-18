#!/bin/sh
set -eu

# =============================================================================
# Script:       publish.sh
# Author:       Andrew J. Moore
# Date:         2026-09-18
# Revision:     r3
#
# Description:
#   Publish previously built canonical Caddy release artifacts.
#
#   Artifact classes:
#     image
#       Publish the existing multi-platform OCI archive to GHCR as:
#         ghcr.io/gesandrewmoore/caddy:<VERSION>
#         ghcr.io/gesandrewmoore/caddy:latest
#
#     binary
#       Publish standalone binary packages to GitHub Release v<VERSION>.
#
#       Canonical packages:
#         caddy-<VERSION>-linux-amd64.tar.gz
#         caddy-<VERSION>-linux-arm64.tar.gz
#         caddy-<VERSION>-windows-amd64.zip
#
#   This script never rebuilds artifacts.
#
# Publication policy:
#   - Working tree must be clean.
#   - origin refs are fetched before publication.
#   - Image publication keeps the existing origin/main ancestry warning with
#     an explicit [y/N] override.
#   - Binary publication also warns when HEAD is not contained in origin/main.
#   - Creating a new GitHub Release additionally requires the current commit to
#     exist on at least one fetched origin branch or tag. This cannot be
#     overridden because GitHub cannot target an unpushed commit.
#   - Updating assets on an existing GitHub Release does not require the current
#     commit to be pushed, though the normal origin/main warning still applies.
#
# Authentication:
#   GHCR_PAT_OP_REF points to a 1Password item containing:
#     username
#     credential
#
#   GITHUB_PAT_OP_REF may point to a separate item using the same convention.
#   If omitted, GHCR_PAT_OP_REF is reused.
#
# Usage:
#   ./scripts/publish.sh --target image
#   ./scripts/publish.sh --target binary
#   ./scripts/publish.sh --target binary --os linux
#   ./scripts/publish.sh --target binary --os linux --arch arm64
#   ./scripts/publish.sh --target binary --os windows --arch amd64
# =============================================================================

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$REPO_DIR/dist"

CADDY_RELEASE_API="https://api.github.com/repos/caddyserver/caddy/releases/latest"

IMAGE_REPO="ghcr.io/gesandrewmoore/caddy"
GITHUB_REPO="gesandrewmoore/caddy"
GHCR_REGISTRY="ghcr.io"

TARGET=""
OS=""
ARCH=""

usage() {
    cat <<'EOF'
Usage:
  publish.sh --target image
  publish.sh --target binary [--os <os> [--arch <arch>]]

Targets:
  image
    Publish the existing multi-platform OCI archive to GHCR as <VERSION> and
    latest.

  binary
    Publish standalone binary packages to GitHub Release v<VERSION>.

    With no --os/--arch:
      Publishes all canonical binary packages:
        linux/amd64
        linux/arm64
        windows/amd64

    --os linux:
      Publishes both Linux packages unless --arch restricts it.

    --os windows:
      Publishes windows/amd64.

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

fetch_origin_refs() {
    echo "Fetching origin refs..."
    git -C "$REPO_DIR" fetch --quiet --prune --tags origin \
        '+refs/heads/*:refs/remotes/origin/*'
}

head_in_origin_main() {
    git -C "$REPO_DIR" merge-base --is-ancestor "$GIT_COMMIT" origin/main >/dev/null 2>&1
}

head_exists_on_origin() {
    if git -C "$REPO_DIR" branch -r --contains "$GIT_COMMIT" |
        grep -q '^[[:space:]]*origin/'; then
        return 0
    fi

    if git -C "$REPO_DIR" tag --contains "$GIT_COMMIT" |
        grep -q .; then
        return 0
    fi

    return 1
}

warn_if_not_origin_main() {
    if head_in_origin_main; then
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

github_item_ref() {
    REF="${GITHUB_PAT_OP_REF:-${GHCR_PAT_OP_REF:-}}"

    if [ -z "$REF" ]; then
        echo "Error: GITHUB_PAT_OP_REF or GHCR_PAT_OP_REF is required for GitHub Release publication." >&2
        exit 1
    fi

    printf '%s' "$REF"
}

binary_artifact_path() {
    BINARY_OS="$1"
    BINARY_ARCH="$2"

    case "$BINARY_OS/$BINARY_ARCH" in
        linux/amd64|linux/arm64)
            printf '%s/caddy-%s-linux-%s.tar.gz' "$DIST_DIR" "$CADDY_VERSION" "$BINARY_ARCH"
            ;;
        windows/amd64)
            printf '%s/caddy-%s-windows-amd64.zip' "$DIST_DIR" "$CADDY_VERSION"
            ;;
        *)
            echo "Error: unsupported binary platform: $BINARY_OS/$BINARY_ARCH" >&2
            exit 1
            ;;
    esac
}

append_binary_artifact() {
    PATH_TO_ADD="$(binary_artifact_path "$1" "$2")"

    if [ ! -f "$PATH_TO_ADD" ]; then
        echo "Error: binary release artifact not found:" >&2
        echo "  $PATH_TO_ADD" >&2
        exit 1
    fi

    if [ -z "${BINARY_ARTIFACTS:-}" ]; then
        BINARY_ARTIFACTS="$PATH_TO_ADD"
    else
        BINARY_ARTIFACTS="$BINARY_ARTIFACTS
$PATH_TO_ADD"
    fi
}

select_binary_artifacts() {
    BINARY_ARTIFACTS=""

    if [ -z "$OS" ]; then
        append_binary_artifact linux amd64
        append_binary_artifact linux arm64
        append_binary_artifact windows amd64
        return
    fi

    case "$OS" in
        linux)
            if [ -n "$ARCH" ]; then
                append_binary_artifact linux "$ARCH"
            else
                append_binary_artifact linux amd64
                append_binary_artifact linux arm64
            fi
            ;;
        windows)
            if [ -n "$ARCH" ] && [ "$ARCH" != "amd64" ]; then
                echo "Error: Windows binary publication currently supports amd64 only." >&2
                exit 1
            fi
            append_binary_artifact windows amd64
            ;;
    esac
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

publish_binaries() {
    select_binary_artifacts

    ITEM_REF="$(github_item_ref)"
    GITHUB_PAT="$(read_op_item_field "$ITEM_REF" "credential" "GitHub PAT 1Password item")"
    RELEASE_TAG="v${CADDY_VERSION}"

    RELEASE_EXISTS=0
    if GH_TOKEN="$GITHUB_PAT" gh release view "$RELEASE_TAG" \
        --repo "$GITHUB_REPO" >/dev/null 2>&1; then
        RELEASE_EXISTS=1
    fi

    if [ "$RELEASE_EXISTS" -eq 0 ] && ! head_exists_on_origin; then
        echo "Error: cannot create GitHub Release $RELEASE_TAG because the current" >&2
        echo "commit is not present on any fetched origin branch or tag." >&2
        echo >&2
        echo "  Current branch: $GIT_BRANCH" >&2
        echo "  Current commit: $GIT_SHORT" >&2
        echo >&2
        echo "Push the commit to GitHub, then retry." >&2
        exit 1
    fi

    echo
    echo "Publishing release binary artifacts..."
    echo "  GitHub repo:    $GITHUB_REPO"
    echo "  Release tag:    $RELEASE_TAG"
    echo "  Git branch:     $GIT_BRANCH"
    echo "  Git commit:     $GIT_SHORT"
    echo "  Artifacts:"
    printf '%s\n' "$BINARY_ARTIFACTS" | while IFS= read -r FILE; do
        echo "    $(basename "$FILE")"
    done
    echo

    if [ "$RELEASE_EXISTS" -eq 1 ]; then
        echo "GitHub Release already exists; replacing matching assets..."
        echo

        printf '%s\n' "$BINARY_ARTIFACTS" | while IFS= read -r FILE; do
            GH_TOKEN="$GITHUB_PAT" gh release upload "$RELEASE_TAG" \
                "$FILE" \
                --repo "$GITHUB_REPO" \
                --clobber
        done
    else
        echo "Creating GitHub Release..."
        echo

        # shellcheck disable=SC2086
        GH_TOKEN="$GITHUB_PAT" gh release create "$RELEASE_TAG" \
            $(printf '%s\n' "$BINARY_ARTIFACTS") \
            --repo "$GITHUB_REPO" \
            --target "$GIT_COMMIT" \
            --title "Caddy ${CADDY_VERSION}" \
            --notes "Custom Caddy ${CADDY_VERSION} build with the GES standard plugin set." \
            --latest
    fi

    unset GITHUB_PAT

    echo
    echo "Release binary publication complete:"
    echo "  GitHub Release: $RELEASE_TAG"
}

# -----------------------------------------------------------------------------
# Arguments
# -----------------------------------------------------------------------------

while [ "$#" -gt 0 ]; do
    case "$1" in
        --target)
            [ "$#" -ge 2 ] || { echo "Error: --target requires a value." >&2; exit 1; }
            TARGET="$2"
            shift 2
            ;;
        --os)
            [ "$#" -ge 2 ] || { echo "Error: --os requires a value." >&2; exit 1; }
            OS="$2"
            shift 2
            ;;
        --arch)
            [ "$#" -ge 2 ] || { echo "Error: --arch requires a value." >&2; exit 1; }
            ARCH="$2"
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
    image|binary)
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

if [ -n "$OS" ]; then
    case "$OS" in
        linux|windows)
            ;;
        *)
            echo "Error: unsupported OS: $OS" >&2
            exit 1
            ;;
    esac
fi

if [ -n "$ARCH" ]; then
    case "$ARCH" in
        amd64|arm64)
            ;;
        *)
            echo "Error: unsupported architecture: $ARCH" >&2
            exit 1
            ;;
    esac
fi

if [ "$TARGET" = "image" ] && { [ -n "$OS" ] || [ -n "$ARCH" ]; }; then
    echo "Error: --os/--arch are only valid with --target binary." >&2
    exit 1
fi

if [ "$TARGET" = "binary" ] && [ -n "$ARCH" ] && [ -z "$OS" ]; then
    echo "Error: --arch with --target binary requires --os." >&2
    exit 1
fi

if [ "$TARGET" = "binary" ] && [ "$OS" = "windows" ] && [ "$ARCH" = "arm64" ]; then
    echo "Error: Windows binary publication currently supports amd64 only." >&2
    exit 1
fi

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
    binary)
        require_command gh
        ;;
esac

git_metadata
require_clean_tree
fetch_origin_refs
warn_if_not_origin_main

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
    binary)
        publish_binaries
        ;;
esac
