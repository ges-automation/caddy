#!/bin/sh
set -eu

# =============================================================================
# Script:       build.sh
# Author:       Andrew J. Moore
# Date:         2026-09-18
# Revision:     r4
#
# Description:
#   Shared Caddy artifact builder for release and development workflows.
#
#   Supported targets:
#     image
#       Release: builds the canonical linux/amd64 + linux/arm64 image and
#       exports it as a multi-platform OCI archive under dist/.
#
#       Dev: builds linux/amd64 + linux/arm64 by default and loads the
#       multi-platform image into the local Docker image store. --arch may be
#       used to restrict the build to one architecture.
#
#     windows
#       Builds a standalone Windows Caddy executable, packages it as an
#       upstream-style ZIP archive, and writes it under dist/.
#
#   Release builds:
#     - Automatically discover the latest stable upstream Caddy release.
#     - Resolve the stable tag to its exact upstream commit before compiling.
#     - Require a clean Git working tree.
#     - Produce artifacts suitable for later publication by publish.sh.
#
#   Development builds:
#     - Require --version <ref>.
#     - Resolve that upstream Caddy ref to an exact commit before compiling.
#     - Allow a dirty local working tree because artifacts are local-only.
#     - Use the passed VERSION as the visible artifact identifier, normalized
#       for Docker/file naming, with a "-dev" suffix.
#     - Store the exact resolved upstream Caddy commit as provenance metadata.
#
# Naming:
#   Stable image:
#     caddy:<VERSION>
#
#   Dev image:
#     caddy:<VERSION>-dev
#
#   Stable Windows archive:
#     caddy-<VERSION>-windows-<ARCH>.zip
#
#   Dev Windows archive:
#     caddy-<VERSION>-dev-windows-<ARCH>.zip
#
#   Windows archives contain:
#     caddy.exe
#
# Usage:
#   ./scripts/build.sh --target image
#   ./scripts/build.sh --target windows
#
#   ./scripts/build.sh --target image --dev --version master
#   ./scripts/build.sh --target image --dev --version v2.11.4 --arch arm64
#   ./scripts/build.sh --target windows --dev --version master --arch amd64
# =============================================================================

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$REPO_DIR/dist"

CADDY_GIT_URL="https://github.com/caddyserver/caddy.git"
CADDY_RELEASE_API="https://api.github.com/repos/caddyserver/caddy/releases/latest"
SOURCE_URL="https://github.com/gesandrewmoore/caddy"
IMAGE_REPO="ghcr.io/gesandrewmoore/caddy"
LOCAL_IMAGE_REPO="caddy"

TARGET=""
MODE="release"
REQUESTED_VERSION=""
ARCH=""

usage() {
    cat <<'EOF'
Usage:
  build.sh --target image [--dev --version <ref> [--arch <arch>]]
  build.sh --target windows [--dev --version <ref> [--arch <arch>]]

Targets:
  image       Build a Linux container image.
  windows     Build a standalone Windows executable ZIP archive.

Release mode (default):
  Automatically builds the latest stable Caddy release.

  image:
    Builds linux/amd64 + linux/arm64 and exports a multi-platform OCI archive.

  windows:
    Builds windows/amd64 and creates:
      caddy-<VERSION>-windows-amd64.zip

Development mode:
  --dev                   Build a local development artifact.
  --version <ref>         Required. May be a branch, tag, or full 40-character
                          Caddy commit SHA.
  --arch <arch>           Optional architecture restriction.

  dev image:
    Without --arch, builds and loads linux/amd64 + linux/arm64 under one tag.
    With --arch, builds only the requested architecture.

  dev windows:
    Defaults to amd64 when --arch is omitted.

  Dev artifact names use the requested ref as their visible VERSION identifier,
  normalized for safe Docker/file naming, with "-dev" appended.

Examples:
  ./scripts/build.sh --target image
  ./scripts/build.sh --target windows
  ./scripts/build.sh --target image --dev --version master
  ./scripts/build.sh --target image --dev --version v2.11.4 --arch arm64
  ./scripts/build.sh --target windows --dev --version master --arch amd64
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
            -H "User-Agent: gesandrewmoore-caddy-build" \
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

    CADDY_REF="$RELEASE_TAG"
    CADDY_VERSION="${RELEASE_TAG#v}"
}

resolve_release_ref() {
    resolve_dev_ref "$CADDY_REF"

    CADDY_RELEASE_COMMIT="$CADDY_COMMIT"
    CADDY_RELEASE_COMMIT_SHORT="$CADDY_COMMIT_SHORT"
}

resolve_dev_ref() {
    REF="$1"

    case "$REF" in
        *[!0-9a-fA-F]*)
            ;;
        *)
            if [ "${#REF}" -eq 40 ]; then
                CADDY_COMMIT="$(printf '%s' "$REF" | tr 'A-F' 'a-f')"
                CADDY_COMMIT_SHORT="$(printf '%s' "$CADDY_COMMIT" | cut -c1-7)"
                return
            fi
            ;;
    esac

    REMOTE_REFS="$(
        git ls-remote "$CADDY_GIT_URL" \
            "refs/heads/$REF" \
            "refs/tags/$REF" \
            "refs/tags/$REF^{}"
    )"

    CADDY_COMMIT="$(
        printf '%s\n' "$REMOTE_REFS" |
            awk '$2 ~ /\^\{\}$/ { print $1; exit }'
    )"

    if [ -z "$CADDY_COMMIT" ]; then
        CADDY_COMMIT="$(
            printf '%s\n' "$REMOTE_REFS" |
                awk '$2 ~ /^refs\/heads\// { print $1; exit }'
        )"
    fi

    if [ -z "$CADDY_COMMIT" ]; then
        CADDY_COMMIT="$(
            printf '%s\n' "$REMOTE_REFS" |
                awk '$2 ~ /^refs\/tags\// { print $1; exit }'
        )"
    fi

    if [ -z "$CADDY_COMMIT" ]; then
        echo "Error: unable to resolve Caddy ref: $REF" >&2
        echo "Use a branch, tag, or full 40-character Caddy commit SHA." >&2
        exit 1
    fi

    CADDY_COMMIT_SHORT="$(printf '%s' "$CADDY_COMMIT" | cut -c1-7)"
}

normalize_version_for_name() {
    VERSION="$1"

    case "$VERSION" in
        *[!0-9a-fA-F]*)
            ;;
        *)
            if [ "${#VERSION}" -eq 40 ]; then
                VERSION="$(printf '%s' "$VERSION" | cut -c1-7)"
            fi
            ;;
    esac

    printf '%s' "$VERSION" |
        sed 's/^v//' |
        sed 's/[^A-Za-z0-9_.-]/-/g'
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

require_clean_release_tree() {
    if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
        echo "Error: release builds require a clean Git working tree." >&2
        echo
        git -C "$REPO_DIR" status --short >&2
        exit 1
    fi
}

build_release_image() {
    OUTPUT="$DIST_DIR/caddy-${CADDY_VERSION}-linux-multiarch.oci.tar"
    VERSION_IMAGE="${IMAGE_REPO}:${CADDY_VERSION}"
    BUILD_CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    rm -f "$OUTPUT"

    echo
    echo "Building release Linux image..."
    echo "  Caddy ref:     $CADDY_REF"
    echo "  Resolved SHA:  $CADDY_RELEASE_COMMIT_SHORT"
    echo "  Version:       $CADDY_VERSION"
    echo "  Platforms:     linux/amd64,linux/arm64"
    echo "  Image name:    $VERSION_IMAGE"
    echo "  OCI archive:   $OUTPUT"
    echo "  Git branch:    $GIT_BRANCH"
    echo "  Git commit:    $GIT_SHORT"
    echo

    docker buildx build \
        --target image \
        --platform "linux/amd64,linux/arm64" \
        --build-arg "CADDY_REF=$CADDY_RELEASE_COMMIT" \
        --build-arg "CADDY_BUILDER_VERSION=$CADDY_VERSION" \
        --build-arg "CADDY_RUNTIME_VERSION=$CADDY_VERSION" \
        --label "org.opencontainers.image.title=GES Caddy" \
        --label "org.opencontainers.image.description=Custom Caddy build with the GES standard plugin set" \
        --label "org.opencontainers.image.source=$SOURCE_URL" \
        --label "org.opencontainers.image.version=$CADDY_VERSION" \
        --label "org.opencontainers.image.revision=$GIT_COMMIT" \
        --label "org.opencontainers.image.created=$BUILD_CREATED" \
        --label "io.ges.build.branch=$GIT_BRANCH" \
        --label "io.ges.build.caddy-ref=$CADDY_REF" \
        --label "io.ges.build.caddy-revision=$CADDY_RELEASE_COMMIT" \
        --tag "$VERSION_IMAGE" \
        --output "type=oci,dest=$OUTPUT" \
        "$REPO_DIR"

    echo
    echo "Release image build complete:"
    echo "  $OUTPUT"
}

build_release_windows() {
    ARCH="amd64"
    TMP_DIR="$(mktemp -d)"
    ARCHIVE_NAME="caddy-${CADDY_VERSION}-windows-${ARCH}.zip"
    OUTPUT="$DIST_DIR/$ARCHIVE_NAME"

    cleanup_tmp() {
        rm -rf "$TMP_DIR"
    }
    trap cleanup_tmp EXIT INT TERM

    rm -f "$OUTPUT"

    echo
    echo "Building release Windows executable..."
    echo "  Caddy ref:     $CADDY_REF"
    echo "  Resolved SHA:  $CADDY_RELEASE_COMMIT_SHORT"
    echo "  Version:       $CADDY_VERSION"
    echo "  Platform:      windows/$ARCH"
    echo "  Archive:       $OUTPUT"
    echo "  Contents:      caddy.exe"
    echo "  Git branch:    $GIT_BRANCH"
    echo "  Git commit:    $GIT_SHORT"
    echo

    docker buildx build \
        --target binary \
        --platform "windows/$ARCH" \
        --build-arg "CADDY_REF=$CADDY_RELEASE_COMMIT" \
        --build-arg "CADDY_BUILDER_VERSION=$CADDY_VERSION" \
        --build-arg "CADDY_RUNTIME_VERSION=$CADDY_VERSION" \
        --output "type=local,dest=$TMP_DIR/export" \
        "$REPO_DIR"

    if [ ! -f "$TMP_DIR/export/caddy" ]; then
        echo "Error: expected binary was not exported to $TMP_DIR/export/caddy" >&2
        exit 1
    fi

    mkdir -p "$TMP_DIR/archive"
    mv "$TMP_DIR/export/caddy" "$TMP_DIR/archive/caddy.exe"

    (
        cd "$TMP_DIR/archive"
        zip -q "$OUTPUT" caddy.exe
    )

    echo
    echo "Release Windows build complete:"
    echo "  $OUTPUT"
}

prepare_dev() {
    DEV_VERSION_BASE="$(normalize_version_for_name "$REQUESTED_VERSION")"

    if [ -z "$DEV_VERSION_BASE" ]; then
        echo "Error: --version does not produce a usable artifact identifier." >&2
        exit 1
    fi

    DEV_VERSION="${DEV_VERSION_BASE}-dev"

    echo "Resolving upstream Caddy ref: $REQUESTED_VERSION"
    resolve_dev_ref "$REQUESTED_VERSION"

    echo "Checking latest stable Caddy release for builder/runtime base..."
    discover_latest_stable
    TOOLCHAIN_VERSION="$CADDY_VERSION"
}

build_dev_image() {
    prepare_dev

    if [ -n "$ARCH" ]; then
        PLATFORMS="linux/$ARCH"
    else
        PLATFORMS="linux/amd64,linux/arm64"
    fi

    LOCAL_IMAGE="${LOCAL_IMAGE_REPO}:${DEV_VERSION}"
    BUILD_CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    echo
    echo "Building development Linux image..."
    echo "  Requested ref: $REQUESTED_VERSION"
    echo "  Resolved SHA:  $CADDY_COMMIT_SHORT"
    echo "  Platforms:     $PLATFORMS"
    echo "  Local image:   $LOCAL_IMAGE"
    echo "  Base version:  $TOOLCHAIN_VERSION"
    echo "  Git branch:    $GIT_BRANCH"
    echo "  Git commit:    $GIT_SHORT"

    if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
        echo "  Git state:     dirty (allowed for local dev builds)"
    else
        echo "  Git state:     clean"
    fi
    echo

    docker buildx build \
        --target image \
        --platform "$PLATFORMS" \
        --build-arg "CADDY_REF=$CADDY_COMMIT" \
        --build-arg "CADDY_BUILDER_VERSION=$TOOLCHAIN_VERSION" \
        --build-arg "CADDY_RUNTIME_VERSION=$TOOLCHAIN_VERSION" \
        --label "org.opencontainers.image.title=GES Caddy Development Build" \
        --label "org.opencontainers.image.description=Development Caddy build with the GES standard plugin set" \
        --label "org.opencontainers.image.source=$SOURCE_URL" \
        --label "org.opencontainers.image.version=$DEV_VERSION" \
        --label "org.opencontainers.image.revision=$GIT_COMMIT" \
        --label "org.opencontainers.image.created=$BUILD_CREATED" \
        --label "io.ges.build.branch=$GIT_BRANCH" \
        --label "io.ges.build.caddy-ref=$REQUESTED_VERSION" \
        --label "io.ges.build.caddy-revision=$CADDY_COMMIT" \
        --tag "$LOCAL_IMAGE" \
        --load \
        "$REPO_DIR"

    echo
    echo "Development image build complete:"
    echo "  $LOCAL_IMAGE"
    echo "  Platforms: $PLATFORMS"
}

build_dev_windows() {
    [ -n "$ARCH" ] || ARCH="amd64"

    prepare_dev

    TMP_DIR="$(mktemp -d)"
    ARCHIVE_NAME="caddy-${DEV_VERSION}-windows-${ARCH}.zip"
    OUTPUT="$DIST_DIR/$ARCHIVE_NAME"

    cleanup_tmp() {
        rm -rf "$TMP_DIR"
    }
    trap cleanup_tmp EXIT INT TERM

    rm -f "$OUTPUT"

    echo
    echo "Building development Windows executable..."
    echo "  Requested ref: $REQUESTED_VERSION"
    echo "  Resolved SHA:  $CADDY_COMMIT_SHORT"
    echo "  Platform:      windows/$ARCH"
    echo "  Archive:       $OUTPUT"
    echo "  Contents:      caddy.exe"
    echo "  Base version:  $TOOLCHAIN_VERSION"
    echo "  Git branch:    $GIT_BRANCH"
    echo "  Git commit:    $GIT_SHORT"

    if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
        echo "  Git state:     dirty (allowed for local dev builds)"
    else
        echo "  Git state:     clean"
    fi
    echo

    docker buildx build \
        --target binary \
        --platform "windows/$ARCH" \
        --build-arg "CADDY_REF=$CADDY_COMMIT" \
        --build-arg "CADDY_BUILDER_VERSION=$TOOLCHAIN_VERSION" \
        --build-arg "CADDY_RUNTIME_VERSION=$TOOLCHAIN_VERSION" \
        --output "type=local,dest=$TMP_DIR/export" \
        "$REPO_DIR"

    if [ ! -f "$TMP_DIR/export/caddy" ]; then
        echo "Error: expected binary was not exported to $TMP_DIR/export/caddy" >&2
        exit 1
    fi

    mkdir -p "$TMP_DIR/archive"
    mv "$TMP_DIR/export/caddy" "$TMP_DIR/archive/caddy.exe"

    (
        cd "$TMP_DIR/archive"
        zip -q "$OUTPUT" caddy.exe
    )

    echo
    echo "Development Windows build complete:"
    echo "  $OUTPUT"
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
        --dev)
            MODE="dev"
            shift
            ;;
        --version)
            if [ "$#" -lt 2 ]; then
                echo "Error: --version requires a value." >&2
                exit 1
            fi
            REQUESTED_VERSION="$2"
            shift 2
            ;;
        --arch)
            if [ "$#" -lt 2 ]; then
                echo "Error: --arch requires a value." >&2
                exit 1
            fi
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

if [ "$MODE" = "release" ]; then
    if [ -n "$REQUESTED_VERSION" ]; then
        echo "Error: --version is only valid with --dev." >&2
        exit 1
    fi

    if [ -n "$ARCH" ]; then
        echo "Error: --arch is only valid with --dev." >&2
        exit 1
    fi
else
    if [ -z "$REQUESTED_VERSION" ]; then
        echo "Error: --version is required with --dev." >&2
        exit 1
    fi

    if [ -n "$ARCH" ]; then
        case "$ARCH" in
            amd64|arm64)
                ;;
            *)
                echo "Error: unsupported architecture: $ARCH" >&2
                echo "Supported architectures: amd64, arm64" >&2
                exit 1
                ;;
        esac
    fi
fi

# -----------------------------------------------------------------------------
# Prerequisites and repository metadata
# -----------------------------------------------------------------------------

require_command git
require_command docker
require_command curl
require_command grep
require_command sed
require_command awk
require_command cut
require_command tr

if [ "$TARGET" = "windows" ]; then
    require_command zip
fi

if ! docker buildx version >/dev/null 2>&1; then
    echo "Error: Docker Buildx is not available." >&2
    exit 1
fi

if [ ! -f "$REPO_DIR/Dockerfile" ]; then
    echo "Error: Dockerfile not found at $REPO_DIR/Dockerfile" >&2
    exit 1
fi

mkdir -p "$DIST_DIR"

git_metadata

# -----------------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------------

if [ "$MODE" = "release" ]; then
    require_clean_release_tree

    echo "Checking latest stable Caddy release..."
    discover_latest_stable

    echo "Resolving stable Caddy tag to exact upstream commit..."
    resolve_release_ref

    case "$TARGET" in
        image)
            build_release_image
            ;;
        windows)
            build_release_windows
            ;;
    esac
else
    case "$TARGET" in
        image)
            build_dev_image
            ;;
        windows)
            build_dev_windows
            ;;
    esac
fi
