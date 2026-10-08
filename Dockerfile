# syntax=docker/dockerfile:1.28.0@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b

# The OpenClaw release this template deploys. This line is the single source of
# truth for the version: an upgrade changes the tag and digest together and
# nothing else. See docs/UPGRADING.md.
FROM ghcr.io/openclaw/openclaw:2026.9.8@sha256:d0ded1dd76939b2bf4d67ef2d13247b8b160aa5666331d4a0b0e58811182cbb8

# Railway mounts volumes owned by root, so the container starts as root only
# long enough for scripts/entrypoint.sh to prepare /data. The entrypoint then
# drops to the image's unprivileged `node` user before OpenClaw runs.
# hadolint ignore=DL3002,DL3066
USER root

# The Gateway listens on 8080, the PORT Railway injects when a service sets
# none, so Railway's health check reaches it with no PORT variable.
# OPENCLAW_HOME relocates every OpenClaw path default (state, config, agents,
# credentials, workspace) under the Railway volume: /data/.openclaw.
# OPENCLAW_SUPERVISOR_MODE=external tells OpenClaw that Railway owns the process
# lifecycle, which refuses in-place self-updates and service installs.
ENV OPENCLAW_HOME=/data \
    OPENCLAW_GATEWAY_PORT=8080 \
    OPENCLAW_SUPERVISOR_MODE=external \
    OPENCLAW_NO_AUTO_UPDATE=1

# GitHub CLI, which OpenClaw drives for Settings > Profile > GitHub connections
# (device sign-in). OpenClaw keeps each connection's credentials under the state
# directory, so they persist on the volume. Pinned release, verified against the
# checksums GitHub publishes with it; shell variables, not ARGs, so no Railway
# variable can reach the build.
RUN set -eu; \
    gh_version=2.102.0; \
    architecture="$(dpkg --print-architecture)"; \
    case "$architecture" in \
      amd64) checksum=bb766f710eef8ede859c18578c72c327597cd4c8a85b06001b1f3843c6019386 ;; \
      arm64) checksum=7862c86c72f43df3a2d93ddde6f473285b4e2af61b494849846827e513ef6484 ;; \
      *) echo "no GitHub CLI checksum for $architecture" >&2; exit 1 ;; \
    esac; \
    archive="/tmp/gh_${gh_version}_linux_${architecture}.tar.gz"; \
    curl -fsSL -o "$archive" "https://github.com/cli/cli/releases/download/v${gh_version}/gh_${gh_version}_linux_${architecture}.tar.gz"; \
    printf '%s  %s\n' "$checksum" "$archive" > /tmp/gh.sha256; \
    sha256sum -c /tmp/gh.sha256; \
    tar -xzf "$archive" -C /tmp; \
    install -m 0755 "/tmp/gh_${gh_version}_linux_${architecture}/bin/gh" /usr/local/bin/gh; \
    rm -rf /tmp/gh*; \
    gh --version

COPY config/openclaw.seed.json /etc/openclaw-railway/openclaw.seed.json
COPY scripts/entrypoint.sh /usr/local/bin/openclaw-railway-entrypoint
# Shadows /usr/local/bin/openclaw on PATH so a root `railway ssh` shell runs the
# CLI as `node` and cannot leave root-owned files in the state directory.
COPY scripts/openclaw-as-node.sh /usr/local/sbin/openclaw

RUN chmod 0444 /etc/openclaw-railway/openclaw.seed.json \
 && chmod 0555 /usr/local/bin/openclaw-railway-entrypoint /usr/local/sbin/openclaw \
 && node /app/openclaw.mjs --version

# Replaces the base image's HEALTHCHECK, which would run OpenClaw code as root.
# Railway ignores Docker health checks; this one is for local `docker run`.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD ["node", "-e", "fetch(`http://127.0.0.1:${process.env.OPENCLAW_GATEWAY_PORT}/healthz`).then((response) => process.exit(response.ok ? 0 : 1), () => process.exit(1))"]

EXPOSE 8080

# After the entrypoint drops privileges, this is the stock image's own startup:
# tini (PID 1) -> docker-entrypoint.mjs (runs Doctor migrations) -> Gateway.
ENTRYPOINT ["openclaw-railway-entrypoint", "tini", "-s", "--", "node", "/app/docker-entrypoint.mjs"]
# --bind and --auth pin the network-facing settings so a later config edit or
# onboarding run cannot make the Gateway unreachable or unauthenticated.
CMD ["node", "openclaw.mjs", "gateway", "--bind", "lan", "--auth", "token"]
