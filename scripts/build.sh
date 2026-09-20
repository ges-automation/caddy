#!/bin/sh
set -eu

# =============================================================================
# Script:       build.sh
# Author:       Andrew J. Moore
# Date:         2026-09-18
# Revision:     r5
#
# Description:
#   Shared Caddy artifact builder for release and development workflows.
#
#   Artifact classes:
#     image
#       OCI/container image.
#
#     binary
#       Standalone Caddy executable package.
#
#   Canonical release artifacts:
#     image:
#       caddy-<VERSION>-linux-multiarch.oci.tar
#
#     binary:
#       caddy-<VERSION>-linux-amd64.tar.gz
#       caddy-<VERSION>-linux-arm64.tar.gz
#       caddy-<VERSION>-windows-amd64.zip
#
#   Development artifacts use the same naming with "-dev" after VERSION.
#
#   Release builds:
#     - Automatically discover the latest stable upstream Caddy release.
#     - Resolve the stable tag to its exact upstream commit before compiling.
#     - Require a clean Git working tree.
#
#   Development builds:
#     - Require --version <ref>.
#     - Resolve that upstream Caddy ref to an exact commit before compiling.
#     - Allow a dirty local working tree.
#     - Use the requested ref as the visible version identifier, normalized for
#       safe Docker/file naming, with "-dev" appended.
#
# Usage:
#   ./scripts/build.sh --target image
#   ./scripts/build.sh --target binary
#   ./scripts/build.sh --target binary --os linux --arch amd64
#   ./scripts/build.sh --target binary --os linux --arch arm64
#   ./scripts/build.sh --target binary --os windows --arch amd64
#
#   ./scripts/build.sh --target image --dev --version master
#   ./scripts/build.sh --target binary --dev --version master
#   ./scripts/build.sh --target binary --dev --version master --os linux --arch arm64
# =============================================================================

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$REPO_DIR/dist"

CADDY_GIT_URL="https://github.com/caddyserver/caddy.git"
CADDY_RELEASE_API="https://api.github.com/repos/caddyserver/caddy/releases/latest"
SOURCE_URL="https://github.com/ges-automation/caddy"
IMAGE_REPO="ghcr.io/ges-automation/caddy"
LOCAL_IMAGE_REPO="caddy"

TARGET=""
MODE="release"
REQUESTED_VERSION=""
ARCH=""
OS=""

usage() {
    cat <<'EOF'
Usage:
  build.sh --target image [--dev --version <ref> [--arch <arch>]]
  build.sh --target binary [--os <os> [--arch <arch>]] [--dev --version <ref>]

Targets:
  image
    Build a Linux container image.

    Release:
      Builds linux/amd64 + linux/arm64 and exports a multi-platform OCI archive.

    Development:
      Builds and loads linux/amd64 + linux/arm64 under one local tag by default.
      --arch may restrict the dev image build to amd64 or arm64.

  binary
    Build standalone executable packages.

    With no --os/--arch:
      Builds all canonical binary packages:
        linux/amd64
        linux/arm64
        windows/amd64

    --os linux:
      Builds linux/amd64 + linux/arm64 unless --arch restricts it.

    --os windows:
      Builds windows/amd64. Windows arm64 is not currently supported.

    Package formats:
      Linux:   caddy-<VERSION>-linux-<ARCH>.tar.gz containing caddy
      Windows: caddy-<VERSION>-windows-amd64.zip containing caddy.exe

Development mode:
  --dev
  --version <ref>         Required with --dev. Branch, tag, or full 40-char SHA.
  --arch <arch>           Optional architecture restriction.
  --os <os>               Optional binary OS restriction: linux or windows.

Examples:
  ./scripts/build.sh --target image
  ./scripts/build.sh --target binary
  ./scripts/build.sh --target binary --os linux --arch arm64
  ./scripts/build.sh --target image --dev --version master
  ./scripts/build.sh --target binary --dev --version master
  ./scripts/build.sh --target binary --dev --version v2.11.4 --os windows --arch amd64
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
            -H "User-Agent: ges-automation-caddy-build" \
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

resolve_ref() {
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

prepare_release() {
    echo "Checking latest stable Caddy release..."
    discover_latest_stable

    echo "Resolving stable Caddy tag to exact upstream commit..."
    resolve_ref "$CADDY_REF"

    BUILD_VERSION="$CADDY_VERSION"
    BUILD_CADDY_REF="$CADDY_REF"
    BUILD_CADDY_COMMIT="$CADDY_COMMIT"
    BUILD_CADDY_COMMIT_SHORT="$CADDY_COMMIT_SHORT"
    TOOLCHAIN_VERSION="$CADDY_VERSION"
}

prepare_dev() {
    DEV_VERSION_BASE="$(normalize_version_for_name "$REQUESTED_VERSION")"

    if [ -z "$DEV_VERSION_BASE" ]; then
        echo "Error: --version does not produce a usable artifact identifier." >&2
        exit 1
    fi

    BUILD_VERSION="${DEV_VERSION_BASE}-dev"

    echo "Resolving upstream Caddy ref: $REQUESTED_VERSION"
    resolve_ref "$REQUESTED_VERSION"

    BUILD_CADDY_REF="$REQUESTED_VERSION"
    BUILD_CADDY_COMMIT="$CADDY_COMMIT"
    BUILD_CADDY_COMMIT_SHORT="$CADDY_COMMIT_SHORT"

    echo "Checking latest stable Caddy release for builder/runtime base..."
    discover_latest_stable
    TOOLCHAIN_VERSION="$CADDY_VERSION"
}

build_release_image() {
    OUTPUT="$DIST_DIR/caddy-${BUILD_VERSION}-linux-multiarch.oci.tar"
    VERSION_IMAGE="${IMAGE_REPO}:${BUILD_VERSION}"
    BUILD_CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    rm -f "$OUTPUT"

    echo
    echo "Building release Linux image..."
    echo "  Caddy ref:     $BUILD_CADDY_REF"
    echo "  Resolved SHA:  $BUILD_CADDY_COMMIT_SHORT"
    echo "  Version:       $BUILD_VERSION"
    echo "  Platforms:     linux/amd64,linux/arm64"
    echo "  Image name:    $VERSION_IMAGE"
    echo "  OCI archive:   $OUTPUT"
    echo "  Git branch:    $GIT_BRANCH"
    echo "  Git commit:    $GIT_SHORT"
    echo

    docker buildx build \
        --target image \
        --platform "linux/amd64,linux/arm64" \
        --build-arg "CADDY_REF=$BUILD_CADDY_COMMIT" \
        --build-arg "CADDY_BUILDER_VERSION=$TOOLCHAIN_VERSION" \
        --build-arg "CADDY_RUNTIME_VERSION=$TOOLCHAIN_VERSION" \
        --label "org.opencontainers.image.title=GES Caddy" \
        --label "org.opencontainers.image.description=Custom Caddy build with the GES standard plugin set" \
        --label "org.opencontainers.image.source=$SOURCE_URL" \
        --label "org.opencontainers.image.version=$BUILD_VERSION" \
        --label "org.opencontainers.image.revision=$GIT_COMMIT" \
        --label "org.opencontainers.image.created=$BUILD_CREATED" \
        --label "io.ges.build.branch=$GIT_BRANCH" \
        --label "io.ges.build.caddy-ref=$BUILD_CADDY_REF" \
        --label "io.ges.build.caddy-revision=$BUILD_CADDY_COMMIT" \
        --tag "$VERSION_IMAGE" \
        --output "type=oci,dest=$OUTPUT" \
        "$REPO_DIR"

    echo
    echo "Release image build complete:"
    echo "  $OUTPUT"
}

build_dev_image() {
    if [ -n "$ARCH" ]; then
        PLATFORMS="linux/$ARCH"
    else
        PLATFORMS="linux/amd64,linux/arm64"
    fi

    LOCAL_IMAGE="${LOCAL_IMAGE_REPO}:${BUILD_VERSION}"
    BUILD_CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    echo
    echo "Building development Linux image..."
    echo "  Requested ref: $BUILD_CADDY_REF"
    echo "  Resolved SHA:  $BUILD_CADDY_COMMIT_SHORT"
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
        --build-arg "CADDY_REF=$BUILD_CADDY_COMMIT" \
        --build-arg "CADDY_BUILDER_VERSION=$TOOLCHAIN_VERSION" \
        --build-arg "CADDY_RUNTIME_VERSION=$TOOLCHAIN_VERSION" \
        --label "org.opencontainers.image.title=GES Caddy Development Build" \
        --label "org.opencontainers.image.description=Development Caddy build with the GES standard plugin set" \
        --label "org.opencontainers.image.source=$SOURCE_URL" \
        --label "org.opencontainers.image.version=$BUILD_VERSION" \
        --label "org.opencontainers.image.revision=$GIT_COMMIT" \
        --label "org.opencontainers.image.created=$BUILD_CREATED" \
        --label "io.ges.build.branch=$GIT_BRANCH" \
        --label "io.ges.build.caddy-ref=$BUILD_CADDY_REF" \
        --label "io.ges.build.caddy-revision=$BUILD_CADDY_COMMIT" \
        --tag "$LOCAL_IMAGE" \
        --load \
        "$REPO_DIR"

    echo
    echo "Development image build complete:"
    echo "  $LOCAL_IMAGE"
    echo "  Platforms: $PLATFORMS"
}

build_binary_one() {
    BINARY_OS="$1"
    BINARY_ARCH="$2"

    case "$BINARY_OS/$BINARY_ARCH" in
        linux/amd64|linux/arm64|windows/amd64)
            ;;
        *)
            echo "Error: unsupported binary platform: $BINARY_OS/$BINARY_ARCH" >&2
            exit 1
            ;;
    esac

    TMP_DIR="$(mktemp -d)"

    cleanup_binary_tmp() {
        rm -rf "$TMP_DIR"
    }
    trap cleanup_binary_tmp EXIT INT TERM

    if [ "$BINARY_OS" = "windows" ]; then
        ARCHIVE_NAME="caddy-${BUILD_VERSION}-windows-${BINARY_ARCH}.zip"
        INTERNAL_NAME="caddy.exe"
    else
        ARCHIVE_NAME="caddy-${BUILD_VERSION}-linux-${BINARY_ARCH}.tar.gz"
        INTERNAL_NAME="caddy"
    fi

    OUTPUT="$DIST_DIR/$ARCHIVE_NAME"
    rm -f "$OUTPUT"

    echo
    echo "Building standalone Caddy binary..."
    echo "  Caddy ref:     $BUILD_CADDY_REF"
    echo "  Resolved SHA:  $BUILD_CADDY_COMMIT_SHORT"
    echo "  Version:       $BUILD_VERSION"
    echo "  Platform:      $BINARY_OS/$BINARY_ARCH"
    echo "  Archive:       $OUTPUT"
    echo "  Contents:      $INTERNAL_NAME"
    echo "  Base version:  $TOOLCHAIN_VERSION"
    echo "  Git branch:    $GIT_BRANCH"
    echo "  Git commit:    $GIT_SHORT"

    if [ "$MODE" = "dev" ]; then
        if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
            echo "  Git state:     dirty (allowed for local dev builds)"
        else
            echo "  Git state:     clean"
        fi
    fi
    echo

    docker buildx build \
        --target binary \
        --platform "$BINARY_OS/$BINARY_ARCH" \
        --build-arg "CADDY_REF=$BUILD_CADDY_COMMIT" \
        --build-arg "CADDY_BUILDER_VERSION=$TOOLCHAIN_VERSION" \
        --build-arg "CADDY_RUNTIME_VERSION=$TOOLCHAIN_VERSION" \
        --output "type=local,dest=$TMP_DIR/export" \
        "$REPO_DIR"

    if [ ! -f "$TMP_DIR/export/caddy" ]; then
        echo "Error: expected binary was not exported to $TMP_DIR/export/caddy" >&2
        exit 1
    fi

    mkdir -p "$TMP_DIR/archive"
    mv "$TMP_DIR/export/caddy" "$TMP_DIR/archive/$INTERNAL_NAME"

    if [ "$BINARY_OS" = "windows" ]; then
        (
            cd "$TMP_DIR/archive"
            zip -q "$OUTPUT" "$INTERNAL_NAME"
        )
    else
        tar -C "$TMP_DIR/archive" -czf "$OUTPUT" "$INTERNAL_NAME"
    fi

    echo
    echo "Binary build complete:"
    echo "  $OUTPUT"

    trap - EXIT INT TERM
    cleanup_binary_tmp
}

build_selected_binaries() {
    if [ -z "$OS" ]; then
        build_binary_one linux amd64
        build_binary_one linux arm64
        build_binary_one windows amd64
        return
    fi

    case "$OS" in
        linux)
            if [ -n "$ARCH" ]; then
                build_binary_one linux "$ARCH"
            else
                build_binary_one linux amd64
                build_binary_one linux arm64
            fi
            ;;
        windows)
            if [ -n "$ARCH" ] && [ "$ARCH" != "amd64" ]; then
                echo "Error: Windows binary builds currently support amd64 only." >&2
                exit 1
            fi
            build_binary_one windows amd64
            ;;
    esac
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
        --dev)
            MODE="dev"
            shift
            ;;
        --version)
            [ "$#" -ge 2 ] || { echo "Error: --version requires a value." >&2; exit 1; }
            REQUESTED_VERSION="$2"
            shift 2
            ;;
        --arch)
            [ "$#" -ge 2 ] || { echo "Error: --arch requires a value." >&2; exit 1; }
            ARCH="$2"
            shift 2
            ;;
        --os)
            [ "$#" -ge 2 ] || { echo "Error: --os requires a value." >&2; exit 1; }
            OS="$2"
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

if [ -n "$OS" ]; then
    case "$OS" in
        linux|windows)
            ;;
        *)
            echo "Error: unsupported OS: $OS" >&2
            echo "Supported OS values: linux, windows" >&2
            exit 1
            ;;
    esac
fi

if [ "$TARGET" = "image" ] && [ -n "$OS" ]; then
    echo "Error: --os is only valid with --target binary." >&2
    exit 1
fi

if [ "$TARGET" = "binary" ] && [ -n "$ARCH" ] && [ -z "$OS" ]; then
    echo "Error: --arch with --target binary requires --os." >&2
    exit 1
fi

if [ "$TARGET" = "binary" ] && [ "$OS" = "windows" ] && [ "$ARCH" = "arm64" ]; then
    echo "Error: Windows binary builds currently support amd64 only." >&2
    exit 1
fi

if [ "$MODE" = "release" ]; then
    if [ -n "$REQUESTED_VERSION" ]; then
        echo "Error: --version is only valid with --dev." >&2
        exit 1
    fi
else
    if [ -z "$REQUESTED_VERSION" ]; then
        echo "Error: --version is required with --dev." >&2
        exit 1
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

if [ "$TARGET" = "binary" ]; then
    require_command tar
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
# Prepare source/version
# -----------------------------------------------------------------------------

if [ "$MODE" = "release" ]; then
    require_clean_release_tree
    prepare_release
else
    prepare_dev
fi

# -----------------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------------

case "$TARGET" in
    image)
        if [ "$MODE" = "release" ]; then
            build_release_image
        else
            build_dev_image
        fi
        ;;
    binary)
        build_selected_binaries
        ;;
esac
