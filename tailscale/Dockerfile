# syntax=docker/dockerfile:1.28.0@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b
# check=skip=SecretsUsedInArgOrEnv
# (TS_AUTH_ONCE is a boolean, not a credential; that lint only matches its name.)

# The official Tailscale container, pinned by tag and digest. Railway builds this
# service with tailscale/ as its root directory, so paths are relative to it.
FROM tailscale/tailscale:v1.102.5@sha256:c507f3a2a6ab1cabd8d809b98edeb41edbd5c3fb6ad9632ffd098b4c7d0b4065

# containerboot only reads the Serve config from a file, and Railway cannot
# mount files into a service, so the config is baked into this image.
COPY serve.json /etc/tailscale/serve.json

# Userspace networking needs no /dev/net/tun or NET_ADMIN. State lives on the
# service's Railway volume so the node keeps its identity across deploys, and
# TS_AUTH_ONCE skips re-authentication when that state already exists. The
# health endpoint uses 8080, the PORT Railway injects by default.
ENV TS_SERVE_CONFIG=/etc/tailscale/serve.json \
    TS_STATE_DIR=/var/lib/tailscale \
    TS_USERSPACE=true \
    TS_AUTH_ONCE=true \
    TS_HOSTNAME=openclaw \
    TS_ENABLE_HEALTH_CHECK=true \
    TS_LOCAL_ADDR_PORT=[::]:8080
