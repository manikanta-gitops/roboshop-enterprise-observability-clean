# ---------------------------------------------------------------------------
# Build stage: gosu
#
# The official mongo image ships a PREBUILT gosu 1.19 binary (compiled upstream
# with Go 1.24.6). Trivy reports 22 HIGH/CRITICAL findings against that binary
# because its embedded Go 1.24.6 standard library carries fixed stdlib CVEs
# (incl. CVE-2025-68121). gosu is REQUIRED by the official docker-entrypoint.sh
# for privilege drop from root to the mongodb user ("exec gosu mongodb ...").
#
# Fix: rebuild the exact same upstream source at the pinned tag (1.19) using a
# current patched Go toolchain (1.25.13, which fixes all the reported stdlib
# CVEs) as a fully static CGO-disabled binary. No third-party binaries are used.
#
# gosu 1.19 pins golang.org/x/sys v0.1.0, which has one advisory
# (GO-2026-5024 / CVE-2026-39824, fixed in x/sys 0.44.0). The bump is limited
# to that transitive dependency (x/sys is 0.x API-compatible) so the rebuilt
# binary embeds no vulnerable module versions either.
# ---------------------------------------------------------------------------
FROM golang:1.25.13-bookworm AS gosu-builder
ARG GOSU_VERSION=1.19
ARG XSYS_VERSION=0.44.0
RUN git clone --depth 1 --branch "$GOSU_VERSION" \
        https://github.com/tianon/gosu.git /gosu \
    && cd /gosu \
    && go get golang.org/x/sys@v${XSYS_VERSION} \
    && go mod tidy \
    && CGO_ENABLED=0 go build -trimpath -ldflags '-d -w' -o /out/gosu .

# ---------------------------------------------------------------------------
# Build stage: js-yaml
#
# The official mongo image installs js-yaml 3.13.1 from the npm registry solely
# to support the entrypoint's YAML config parsing (_parse_config, used when a
# --config file is supplied). 3.13.1 has 2 HIGH advisories:
#   - CVE-2026-59869      fixed in 3.15.0 / 4.3.0
#   - GHSA-5p4m-2wfm-xmqj fixed in 3.15.1 / 4.x
# 3.15.1 is the smallest single version fixing both, so we upgrade (not remove)
# to keep the official entrypoint fully functional. The tarball sha256 is pinned
# and verified, matching upstream's JSYAML_CHECKSUM pattern. We extract exactly
# the two files the official image extracts (dist/js-yaml.js + package.json),
# preserving the /opt/js-yaml layout and the /js-yaml.js symlink.
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS jsyaml-builder
ARG JSYAML_VERSION=3.15.1
ARG JSYAML_CHECKSUM=df86a37e0f5aa855ae32098dcc1d4c5712e43ea515d69fa3e6d51b8f5901c86e
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && mkdir -p /opt/js-yaml \
    && curl -fsSL -o /opt/js-yaml/js-yaml.tgz \
        "https://registry.npmjs.org/js-yaml/-/js-yaml-${JSYAML_VERSION}.tgz" \
    && echo "${JSYAML_CHECKSUM}  /opt/js-yaml/js-yaml.tgz" | sha256sum -c - \
    && tar -xz --strip-components=1 -f /opt/js-yaml/js-yaml.tgz -C /opt/js-yaml \
        package/dist/js-yaml.js package/package.json \
    && rm /opt/js-yaml/js-yaml.tgz \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Final runtime image
# ---------------------------------------------------------------------------
FROM mongo:7.0.40

# The official image bundles Go-built database CLI tools (bsondump, mongodump,
# mongorestore, mongoexport, mongoimport, mongofiles, mongostat, mongotop)
# that this application never uses. Each is a self-contained, statically linked
# Go 1.25.9 binary for which Trivy reports HIGH/CRITICAL Go stdlib CVEs.
#
# The official docker-entrypoint.sh and this deployment require only:
#   - mongod      (server, C++)
#   - mongosh     (shell, used by entrypoint to run /docker-entrypoint-initdb.d/*.js)
#   - gosu        (privilege drop in entrypoint)
#   - jq, js-yaml (entrypoint config parsing)
# None of the removed tools are referenced by the entrypoint, charts, scripts,
# backups (AWS Backup EBS snapshots), or health checks (TCP probes).
RUN rm -f \
    /usr/bin/bsondump \
    /usr/bin/mongodump \
    /usr/bin/mongorestore \
    /usr/bin/mongoexport \
    /usr/bin/mongoimport \
    /usr/bin/mongofiles \
    /usr/bin/mongostat \
    /usr/bin/mongotop

# Replace the upstream prebuilt gosu (built with Go 1.24.6, 22 reported
# HIGH/CRITICAL stdlib CVEs) with the patched rebuild of the SAME version 1.19
# from the gosu-builder stage. exec permissions are preserved by COPY.
COPY --from=gosu-builder /out/gosu /usr/local/bin/gosu

# Upgrade js-yaml from the vulnerable 3.13.1 to the fixed 3.15.1, overwriting
# the files in place so the official entrypoint's /js-yaml.js symlink keeps
# resolving correctly.
COPY --from=jsyaml-builder /opt/js-yaml/package.json /opt/js-yaml/package.json
COPY --from=jsyaml-builder /opt/js-yaml/dist/js-yaml.js /opt/js-yaml/dist/js-yaml.js

COPY *.js /docker-entrypoint-initdb.d/
