# syntax=docker/dockerfile:1

# =============================================================================
# GES Caddy build
#
# This Dockerfile is intentionally generic:
#   - CADDY_REF selects the Caddy source to compile (tag, branch, commit, latest).
#   - CADDY_BUILDER_VERSION selects the official Caddy builder image/toolchain.
#   - CADDY_RUNTIME_VERSION selects the official Linux runtime image.
#   - TARGETOS / TARGETARCH are supplied automatically by Docker Buildx.
#
# The build stage always runs on BUILDPLATFORM, allowing Go/xcaddy to
# cross-compile without executing the target-architecture binary.
# =============================================================================

ARG CADDY_BUILDER_VERSION=latest
ARG CADDY_RUNTIME_VERSION=latest

# -----------------------------------------------------------------------------
# Cross-compilation stage
# -----------------------------------------------------------------------------

FROM --platform=$BUILDPLATFORM caddy:${CADDY_BUILDER_VERSION}-builder AS builder

ARG CADDY_REF=latest
ARG TARGETOS
ARG TARGETARCH

RUN set -eux; \
    mkdir -p /out; \
    CGO_ENABLED=0 \
    GOOS="${TARGETOS}" \
    GOARCH="${TARGETARCH}" \
    xcaddy build "${CADDY_REF}" \
        --output /out/caddy \
        --with github.com/caddy-dns/cloudflare \
        --with github.com/WeidiDeng/caddy-cloudflare-ip \
        --with github.com/fvbommel/caddy-combine-ip-ranges \
        --with github.com/caddy-dns/route53 \
        --with github.com/porech/caddy-maxmind-geolocation \
        --with github.com/caddyserver/ntlm-transport; \
    go version -m /out/caddy

# -----------------------------------------------------------------------------
# Binary artifact target
#
# Used by build scripts to export a cross-compiled standalone Caddy binary.
# For Windows builds, the build script renames the exported file to caddy.exe.
# -----------------------------------------------------------------------------

FROM scratch AS binary

COPY --from=builder /out/caddy /caddy

# -----------------------------------------------------------------------------
# Linux container image target
#
# Buildx automatically selects the runtime image matching TARGETPLATFORM.
# The Caddy binary itself was cross-compiled natively in the builder stage.
# No target-architecture RUN instructions are used, so QEMU is not required.
# -----------------------------------------------------------------------------

FROM caddy:${CADDY_RUNTIME_VERSION} AS image

COPY --from=builder /out/caddy /usr/bin/caddy
