#!/bin/sh
# Decodes tailscale/serve.json strictly against the ServeConfig type from the
# exact Tailscale release pinned in tailscale/Dockerfile. Requires Docker.
set -eu

cd "$(dirname "$0")/.."

tailscale_version="$(sed -n 's|^FROM tailscale/tailscale:\(v[0-9.]*\)@sha256:.*|\1|p' tailscale/Dockerfile)"
[ -n "$tailscale_version" ] || { echo "could not read the Tailscale version from tailscale/Dockerfile" >&2; exit 1; }

docker run --rm \
  -v "$PWD/tests/serve-config:/source:ro" \
  -v "$PWD/tailscale/serve.json:/serve.json:ro" \
  golang:1.26-alpine@sha256:8ac98ca534ac3f51e1f420a1dd2c15e74c75cfa0f23f3ad27eb5d7236c349a0c \
  sh -euc "
    cp -r /source /check && cd /check
    go mod init serve-config-check >/dev/null 2>&1
    go get tailscale.com@$tailscale_version >/dev/null 2>&1
    go mod tidy >/dev/null 2>&1
    go run . /serve.json
  "
