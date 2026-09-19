# GES Caddy

Custom [Caddy](https://caddyserver.com/) builds used by GES Automation Technology.

This repository does **not** fork or vendor the Caddy source tree. Instead, it defines a repeatable build and publication workflow around upstream Caddy using `xcaddy` and the GES standard plugin set.

The build host compiles Caddy once, produces reusable multi-platform container images and standalone binaries, and publishes those artifacts for deployment elsewhere.

## Included modules

The current GES build includes:

- `github.com/caddy-dns/cloudflare`
- `github.com/WeidiDeng/caddy-cloudflare-ip`
- `github.com/fvbommel/caddy-combine-ip-ranges`
- `github.com/caddy-dns/route53`
- `github.com/porech/caddy-maxmind-geolocation`
- `github.com/caddyserver/ntlm-transport`

## Build model

All compilation happens inside Docker.

The build host does **not** need a native Go or `xcaddy` installation. Docker Buildx runs the official Caddy builder image on the host architecture and cross-compiles Caddy for the requested target OS and architecture.

The workflow produces two artifact classes:

- **image** — OCI/container image
- **binary** — standalone executable package

The scripts are the implementation layer. The Makefile is the normal front-end.

Current workflow revisions documented here:

```text
Makefile:           r3
scripts/build.sh:   r5
scripts/publish.sh: r4
```

## Canonical release artifacts

A stable release produces:

```text
dist/
├── caddy-<VERSION>-linux-multiarch.oci.tar
├── caddy-<VERSION>-linux-amd64.tar.gz
├── caddy-<VERSION>-linux-arm64.tar.gz
└── caddy-<VERSION>-windows-amd64.zip
```

Archive contents are intentionally simple:

```text
Linux tar.gz:
  caddy

Windows zip:
  caddy.exe
```

The platform, architecture, and Caddy version are carried by the archive filename.

The published container image uses:

```text
ghcr.io/gesandrewmoore/caddy:<VERSION>
ghcr.io/gesandrewmoore/caddy:latest
```

Both `linux/amd64` and `linux/arm64` are contained in the same multi-platform image index.

## Stable version selection

Stable builds automatically discover the latest normal upstream Caddy release.

The upstream release tag is then resolved to its exact Git commit before compilation. This provides an immutable compiler input and allows release and development builds of the same Caddy source to share BuildKit cache.

For example:

```text
Upstream release:  v2.11.4
Resolved commit:   e2eee6a...
Artifact version:  2.11.4
```

## Development builds

Development builds accept an upstream Caddy:

- branch
- tag
- full 40-character commit SHA

Examples:

```bash
make dev-image VERSION=master
make dev-image VERSION=v2.11.4
make dev-binary VERSION=master
make dev-binary VERSION=master OS=linux ARCH=arm64
```

Development artifacts use the requested ref as their visible version identifier, normalized for safe Docker and filename use, with `-dev` appended.

Examples:

```text
caddy:master-dev
caddy:2.11.4-dev

caddy-master-dev-linux-amd64.tar.gz
caddy-master-dev-linux-arm64.tar.gz
caddy-master-dev-windows-amd64.zip
```

For a full SHA, the visible development identifier is shortened to seven characters.

Development image builds default to both:

```text
linux/amd64
linux/arm64
```

under one local multi-platform tag.

An individual architecture can be requested with `ARCH=`.

## Requirements

The build host requires:

- Git
- Docker Engine
- Docker Buildx
- `curl`
- `make`
- `tar`
- `zip`

Publication additionally requires:

- `skopeo` for GHCR image publication
- GitHub CLI (`gh`) for GitHub Release publication
- 1Password CLI (`op`) for credential retrieval and interactive sign-in when required

On Debian:

```bash
apt update
apt install -y git curl make tar zip skopeo gh
```

Docker and the 1Password CLI are installed separately.

## Authentication

Before publication, `publish.sh` verifies that the 1Password CLI is authenticated:

```bash
op whoami
```

If no active 1Password CLI session exists, the script starts an interactive sign-in:

```bash
eval "$(op signin)"
```

This matches the publication workflow used by the GES Dex build project.

### GitHub Container Registry

`GHCR_PAT_OP_REF` points to a **1Password item**, not to an individual field.

The item must contain:

```text
username
credential
```

Example:

```bash
export GHCR_PAT_OP_REF='op://Employee/GitHub - labbuild01 GHCR PAT'
```

The scripts internally read:

```text
<item>/username
<item>/credential
```

The credential must have the GitHub permissions required for GHCR publication.

### GitHub Releases

`GITHUB_PAT_OP_REF` may point to a separate 1Password item using the same field convention.

If it is not set, `GHCR_PAT_OP_REF` is reused.

Example:

```bash
export GITHUB_PAT_OP_REF='op://Employee/GitHub - labbuild01 Release PAT'
```

The token must have permission to create releases and upload release assets to this repository.

## Make workflow

### Complete canonical release

```bash
make
```

or:

```bash
make release
```

This performs:

```text
build
  image
  binaries

publish
  image
  binaries
```

### Build everything without publishing

```bash
make build
```

### Publish already-built artifacts

```bash
make publish
```

`make publish` does not rebuild artifacts.

### Container image

Build:

```bash
make image
```

Publish:

```bash
make publish-image
```

### Standalone binaries

Build all canonical binaries:

```bash
make binary
```

Build selected binaries:

```bash
make binary OS=linux
make binary OS=linux ARCH=amd64
make binary OS=linux ARCH=arm64
make binary OS=windows ARCH=amd64
```

Publish all canonical binary packages:

```bash
make publish-binary
```

Publish selected binary packages:

```bash
make publish-binary OS=linux
make publish-binary OS=linux ARCH=arm64
make publish-binary OS=windows ARCH=amd64
```

### Development builds

Build the complete development set:

```bash
make dev VERSION=master
```

Build only the development image:

```bash
make dev-image VERSION=master
```

Build a development image for a single architecture:

```bash
make dev-image VERSION=master ARCH=arm64
```

Build all development binaries:

```bash
make dev-binary VERSION=master
```

Build a selected development binary:

```bash
make dev-binary VERSION=master OS=linux ARCH=arm64
```

### Help

```bash
make help
```

### Clean local artifacts and build cache

```bash
make clean
```

This removes:

- the local `dist/` directory
- local development images matching `caddy:*-dev`
- local images matching `ghcr.io/gesandrewmoore/caddy:*`
- the full Docker Buildx build cache via:

```bash
docker buildx prune --all --force
```

Upstream base images such as `caddy:<VERSION>` and `caddy:<VERSION>-builder` are intentionally left alone.

## Direct script usage

The shell scripts may also be used directly without Make.

### Build image

Stable:

```bash
./scripts/build.sh --target image
```

Development:

```bash
./scripts/build.sh \
  --target image \
  --dev \
  --version master
```

Development, single architecture:

```bash
./scripts/build.sh \
  --target image \
  --dev \
  --version master \
  --arch arm64
```

### Build binaries

All canonical binaries:

```bash
./scripts/build.sh --target binary
```

Specific platform:

```bash
./scripts/build.sh \
  --target binary \
  --os linux \
  --arch amd64
```

Development:

```bash
./scripts/build.sh \
  --target binary \
  --dev \
  --version master \
  --os windows \
  --arch amd64
```

### Publish image

```bash
./scripts/publish.sh --target image
```

### Publish binaries

All canonical binaries:

```bash
./scripts/publish.sh --target binary
```

Specific platform:

```bash
./scripts/publish.sh \
  --target binary \
  --os linux \
  --arch arm64
```

## Publication safeguards

Stable publication requires a clean Git working tree.

Before publishing, the script fetches the current `origin` refs.

If the current commit is not contained in `origin/main`, publication displays a notice and requires an explicit confirmation.

For **new GitHub Releases**, the current commit must also exist on at least one fetched `origin` branch or tag. This is a hard requirement because GitHub cannot create a release targeting a commit that has not been pushed.

Existing GitHub Releases may have matching binary assets replaced after the normal publication warning.

This supports intentionally republishing the same upstream Caddy version when the GES plugin set changes.

## GHCR publication

Container publication uses the already-built OCI archive.

The image is **not rebuilt** during publication.

`skopeo copy --all` copies the complete OCI index to:

```text
ghcr.io/gesandrewmoore/caddy:<VERSION>
```

The exact same image is then promoted to:

```text
ghcr.io/gesandrewmoore/caddy:latest
```

The publication script verifies that both tags resolve to the same top-level manifest digest.

## GitHub Release publication

Standalone binary packages are published to:

```text
v<VERSION>
```

For example:

```text
v2.11.4
```

A canonical release contains:

```text
caddy-2.11.4-linux-amd64.tar.gz
caddy-2.11.4-linux-arm64.tar.gz
caddy-2.11.4-windows-amd64.zip
```

If the release already exists, matching assets are replaced rather than creating another release.

## Build cache

The Dockerfile cross-compiles Caddy using:

```text
CGO_ENABLED=0
GOOS=<target OS>
GOARCH=<target architecture>
```

The builder itself runs on the build host architecture.

This allows Linux ARM64 and Windows AMD64 artifacts to be produced from an AMD64 Linux build host without a native Go installation or target-platform build machine.

Because both stable and development builds resolve Caddy to an exact upstream commit, BuildKit can reuse expensive `xcaddy` compilation layers when the source and plugin set have not changed.

## Repository layout

```text
.
├── Dockerfile
├── Makefile
├── README.md
├── LICENSE
├── .gitignore
└── scripts/
    ├── build.sh
    └── publish.sh
```

## License

The build definitions and supporting scripts in this repository are licensed under the terms in [LICENSE](LICENSE).

Caddy and all included third-party modules remain subject to their respective upstream licenses.
