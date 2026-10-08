#!/bin/sh
# Prepares the Railway volume, then runs the official OpenClaw startup as `node`.
#
# Railway mounts volumes owned by root, so this script starts as root, validates
# the environment, makes the state directory writable by `node`, writes a
# baseline config on first boot only, and then replaces itself (exec) with the
# stock image entrypoint running unprivileged. It never deletes or rewrites
# existing state.
set -eu

fail() {
  printf 'openclaw-railway: %s\n' "$*" >&2
  exit 64
}

[ "$(id -u)" = 0 ] || fail "the entrypoint must start as root so it can prepare the volume; it drops to the node user itself. Remove any RAILWAY_RUN_UID or --user override."

gateway_token="${OPENCLAW_GATEWAY_TOKEN:-}"
[ -n "$gateway_token" ] || fail "OPENCLAW_GATEWAY_TOKEN is not set. Generate one with 'openssl rand -hex 32' and set it as a Railway variable on this service."
[ "${#gateway_token}" -ge 32 ] || fail "OPENCLAW_GATEWAY_TOKEN must be at least 32 characters. Generate one with 'openssl rand -hex 32'."

# The baseline config reads gateway.publicOrigin from this variable; OpenClaw
# refuses to start with an invalid origin, so fail here with a clearer message.
# The Railway template builds it as https://openclaw.${{TAILNET_DNS_NAME}}, so
# a mistyped tailnet name shows up here too.
public_origin="${OPENCLAW_PUBLIC_ORIGIN:-}"
origin_hint="for example https://openclaw.tail1234.ts.net. If you deployed the Railway template, check TAILNET_DNS_NAME: it is your tailnet's DNS name from the Tailscale admin console's DNS page, such as tail1234.ts.net, with no https:// and no machine name"
[ -n "$public_origin" ] || fail "OPENCLAW_PUBLIC_ORIGIN is not set. Set it to the Gateway's tailnet address, $origin_hint"
origin_host="${public_origin#https://}"
invalid_origin="OPENCLAW_PUBLIC_ORIGIN must be the Gateway's tailnet HTTPS address (got: $public_origin), $origin_hint"
[ "$origin_host" != "$public_origin" ] || fail "$invalid_origin"
case "$origin_host" in
  */* | *@* | *" "*) fail "$invalid_origin" ;;
  *.ts.net | *.ts.net:*) ;;
  *) fail "$invalid_origin" ;;
esac

if [ -n "${PORT:-}" ] && [ "$PORT" != "$OPENCLAW_GATEWAY_PORT" ]; then
  fail "PORT is $PORT but the Gateway listens on $OPENCLAW_GATEWAY_PORT, so Railway's health check would miss it. Delete the PORT variable (Railway then uses $OPENCLAW_GATEWAY_PORT) or set it to $OPENCLAW_GATEWAY_PORT."
fi

state_directory="$OPENCLAW_HOME/.openclaw"
config_file="$state_directory/openclaw.json"

if ! mountpoint -q "$OPENCLAW_HOME"; then
  printf 'openclaw-railway: warning: %s is not a mounted volume; all OpenClaw state will be lost when this container is replaced.\n' "$OPENCLAW_HOME" >&2
fi

install -d -o node -g node -m 700 "$state_directory" "$HOME"
chown node:node "$OPENCLAW_HOME"
# A root shell (for example `railway ssh` without the wrappers) can leave
# root-owned files behind, which locks the Gateway and its tools out of them.
find "$state_directory" "$HOME" -xdev ! -user node -exec chown -h node:node {} +

if [ ! -e "$config_file" ] && [ ! -L "$config_file" ]; then
  install -o node -g node -m 600 /etc/openclaw-railway/openclaw.seed.json "$config_file"
  echo "openclaw-railway: created $config_file from the baseline config"
fi

# Homebrew lives on the volume (/home/linuxbrew/.linuxbrew is a symlink here).
# Copy the image's seed on first boot only; afterwards Homebrew and what it
# installs belong to the volume. Not swept by the ownership repair above: the
# brew wrapper always runs as node, and the prefix holds many files.
homebrew_directory=/data/linuxbrew
if [ ! -e "$homebrew_directory" ] && [ ! -L "$homebrew_directory" ]; then
  cp -a /opt/homebrew-seed "$homebrew_directory"
  echo "openclaw-railway: created $homebrew_directory from the image's Homebrew"
fi

exec setpriv --reuid=node --regid=node --init-groups -- "$@"
