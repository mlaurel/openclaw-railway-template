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

# jq and tmux for the trello and tmux skills, from Debian stable. Not pinned to
# exact versions: a Debian security update removes the previous version from the
# mirror, so an exact pin would eventually break every build.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends jq tmux \
 && rm -rf /var/lib/apt/lists/* \
 && jq --version \
 && tmux -V

# gog, the Google Workspace CLI for the gog skill. Pinned release, verified
# against the project's published checksums.
RUN set -eu; \
    gog_version=0.43.0; \
    architecture="$(dpkg --print-architecture)"; \
    case "$architecture" in \
      amd64) checksum=a16d4b8b917e36b96b09b30ecb7a5049d06ff1e88b856a101eec12b86b33fe05 ;; \
      arm64) checksum=f66e3c9ab7664b7633d57d2d5303e0db75deb4045e1b32c3493c0d8ba68a70f7 ;; \
      *) echo "no gog checksum for $architecture" >&2; exit 1 ;; \
    esac; \
    archive="/tmp/gogcli_${gog_version}_linux_${architecture}.tar.gz"; \
    curl -fsSL -o "$archive" "https://github.com/steipete/gogcli/releases/download/v${gog_version}/gogcli_${gog_version}_linux_${architecture}.tar.gz"; \
    printf '%s  %s\n' "$checksum" "$archive" > /tmp/gog.sha256; \
    sha256sum -c /tmp/gog.sha256; \
    mkdir /tmp/gogcli; \
    tar -xzf "$archive" -C /tmp/gogcli; \
    install -m 0755 /tmp/gogcli/gog /usr/local/bin/gog; \
    rm -rf /tmp/gogcli /tmp/gog.sha256 "$archive"; \
    gog --version

# Codex CLI for the coding-agent skill. The base image already ships
# @openai/codex for OpenClaw's Codex runtime, so link that copy onto PATH; it
# follows OpenClaw's own pin on every upgrade. (`set --` word-splits the find
# result on purpose, to check there is exactly one match.)
# hadolint ignore=SC2086
RUN set -eu; \
    codex_script="$(find /app/node_modules/.pnpm -path '*/@openai+codex@*/node_modules/@openai/codex/bin/codex.js' -print)"; \
    set -- $codex_script; \
    [ "$#" = 1 ] || { echo "expected exactly one bundled Codex CLI, found: $codex_script" >&2; exit 1; }; \
    ln -s "$codex_script" /usr/local/bin/codex; \
    codex --version

# Claude Code for the coding-agent skill, pinned in tools/package-lock.json
# (Dependabot proposes updates). Its postinstall script copies the native binary
# for this architecture into place; tools/package.json approves only that
# package's install script (npm 12 blocks dependency scripts by default).
COPY tools/package.json tools/package-lock.json /opt/tools/
RUN npm ci --prefix /opt/tools --omit=dev --no-audit --no-fund \
 && ln -s /opt/tools/node_modules/.bin/claude /usr/local/bin/claude \
 && claude --version

COPY config/openclaw.seed.json /etc/openclaw-railway/openclaw.seed.json
COPY scripts/entrypoint.sh /usr/local/bin/openclaw-railway-entrypoint
# `railway ssh` opens a root shell. `as-node <command>` runs a command as the
# Gateway's user, so tool logins (for example `as-node gog auth add …`) don't
# leave root-owned files the agent can't read. The openclaw wrapper shadows
# /usr/local/bin/openclaw on PATH and does the same automatically.
COPY scripts/as-node.sh /usr/local/bin/as-node
COPY scripts/openclaw-as-node.sh /usr/local/sbin/openclaw

RUN chmod 0444 /etc/openclaw-railway/openclaw.seed.json \
 && chmod 0555 /usr/local/bin/openclaw-railway-entrypoint /usr/local/bin/as-node /usr/local/sbin/openclaw \
 && node /app/openclaw.mjs --version

# HOME is on the volume, so tool logins and settings kept under ~ (gog's Google
# tokens, Claude Code and Codex sessions, anything installed to ~/.local) survive
# redeploys. DISABLE_AUTOUPDATER keeps Claude Code at the pinned version.
ENV HOME=/data/home \
    PATH=/data/home/.local/bin:$PATH \
    DISABLE_AUTOUPDATER=1

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
