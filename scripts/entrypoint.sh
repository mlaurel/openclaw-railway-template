#!/bin/sh
# Prepares the Railway volume, brings up Tailscale, then runs the official
# OpenClaw startup as `node`.
#
# Railway mounts volumes owned by root, so this script starts as root, validates
# the environment, makes the state directories writable by `node`, writes a
# baseline config on first boot only, starts tailscaled and the health relay
# (scripts/sidecar.mjs), logs Tailscale in on first boot, and then replaces
# itself (exec) with the stock image entrypoint running unprivileged. It never
# deletes or rewrites existing state.
set -eu

fail() {
  printf 'openclaw-railway: %s\n' "$*" >&2
  exit 64
}

as_node() {
  setpriv --reuid=node --regid=node --init-groups -- "$@"
}

[ "$(id -u)" = 0 ] || fail "the entrypoint must start as root so it can prepare the volume; it drops to the node user itself. Remove any RAILWAY_RUN_UID or --user override."

gateway_token="${OPENCLAW_GATEWAY_TOKEN:-}"
[ -n "$gateway_token" ] || fail "OPENCLAW_GATEWAY_TOKEN is not set. Generate one with 'openssl rand -hex 32' and set it as a Railway variable on this service."
[ "${#gateway_token}" -ge 32 ] || fail "OPENCLAW_GATEWAY_TOKEN must be at least 32 characters. Generate one with 'openssl rand -hex 32'."

# The relay listens on PORT (8080 unless set); the Gateway has its own loopback
# port, and both can't bind the same number.
if [ "${PORT:-8080}" = "$OPENCLAW_GATEWAY_PORT" ]; then
  fail "PORT is ${PORT:-8080}, the Gateway's own loopback port. Delete the PORT variable (Railway then uses 8080 for the health check relay)."
fi

# The name shown in OpenClaw's machine picker (see the Dockerfile's display-name
# patch): the Tailscale machine name unless set explicitly.
export OPENCLAW_MACHINE_DISPLAY_NAME="${OPENCLAW_MACHINE_DISPLAY_NAME:-$TS_HOSTNAME}"

# For this repository's integration tests only: run without Tailscale, so CI
# can exercise the Gateway with no tailnet. The Gateway is then unreachable
# from outside the container.
without_tailscale="${OPENCLAW_RAILWAY_TEST_WITHOUT_TAILSCALE:-}"

state_directory="$OPENCLAW_HOME/.openclaw"
config_file="$state_directory/openclaw.json"

if ! mountpoint -q "$OPENCLAW_HOME"; then
  printf 'openclaw-railway: warning: %s is not a mounted volume; all OpenClaw state will be lost when this container is replaced.\n' "$OPENCLAW_HOME" >&2
fi

install -d -o node -g node -m 700 "$state_directory" "$HOME" "$TS_STATE_DIR"
install -d -o node -g node -m 755 "$(dirname "$TS_SOCKET")"
chown node:node "$OPENCLAW_HOME"
# A root shell (for example `railway ssh` without the wrappers) can leave
# root-owned files behind, which locks the Gateway and its tools out of them.
find "$state_directory" "$HOME" "$TS_STATE_DIR" -xdev ! -user node -exec chown -h node:node {} +

if [ ! -e "$config_file" ] && [ ! -L "$config_file" ]; then
  install -o node -g node -m 600 /etc/openclaw-railway/openclaw.seed.json "$config_file"
  echo "openclaw-railway: created $config_file from the baseline config"
fi

# Volumes from before Tailscale moved into this container have a config for a
# LAN-bound Gateway behind a separate Tailscale service. Refuse to start rather
# than rewrite it; the fix is four commands.
layout_problem="$(node -e '
  const config = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  const gateway = config.gateway ?? {};
  if (gateway.bind !== "loopback" || gateway.tailscale?.mode !== "serve" || "publicOrigin" in gateway
      || config.plugins?.entries?.["device-pair"]?.config?.publicUrl !== undefined) console.log("old");
' "$config_file" 2>/dev/null || true)"
if [ "$layout_problem" = old ]; then
  fail "$config_file is set up for the previous layout (a separate tailscale service). Migrate it once from a shell on this volume, then redeploy: openclaw config set gateway.bind loopback && openclaw config set gateway.tailscale.mode serve && openclaw config unset gateway.publicOrigin && openclaw config unset plugins.entries.device-pair. See documentation/UPGRADING.md."
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

# tailscaled and the health relay. Neither needs the auth key or the Gateway
# token, so neither gets them.
# (setpriv directly, not as_node: a backgrounded function leaves a root shell.)
setpriv --reuid=node --regid=node --init-groups -- \
  env -u TS_AUTHKEY -u OPENCLAW_GATEWAY_TOKEN node /usr/local/lib/openclaw-railway/sidecar.mjs &

if [ -z "$without_tailscale" ]; then
  backend_state() {
    as_node tailscale status --json 2>/dev/null | node -e '
      let input = "";
      process.stdin.on("data", (chunk) => (input += chunk)).on("end", () => {
        try { console.log(JSON.parse(input).BackendState); } catch { console.log("Unavailable"); }
      });'
  }
  # Wait for tailscaled to load its state; it briefly reports NoState/Starting.
  attempt=0
  while :; do
    state="$(backend_state)"
    case "$state" in
      Running | NeedsLogin | NeedsMachineAuth | Stopped) break ;;
    esac
    attempt=$((attempt + 1))
    [ "$attempt" -le 60 ] || fail "tailscaled did not become ready (state: $state)."
    sleep 0.5
  done

  # TS_AUTHKEY is used once: on first boot, or after the node was removed from
  # the tailnet. Afterwards the node key on the volume logs Tailscale in.
  if [ "$state" != Running ]; then
    [ -n "${TS_AUTHKEY:-}" ] || fail "Tailscale is not logged in (state: $state) and TS_AUTHKEY is not set. Generate an auth key in the Tailscale admin console (Settings > Keys) and set it as TS_AUTHKEY on this service."
    # Pass the key in a file, not on the command line, where `ps` would show it.
    key_file="$(mktemp)"
    printf '%s' "$TS_AUTHKEY" > "$key_file"
    chown node:node "$key_file"
    chmod 600 "$key_file"
    if ! as_node tailscale up --auth-key="file:$key_file" --hostname="$TS_HOSTNAME" --timeout=120s; then
      rm -f "$key_file"
      fail "Tailscale login failed; see the error above. An auth key is single-use unless created as reusable, and it expires."
    fi
    rm -f "$key_file"
    echo "openclaw-railway: logged in to Tailscale as $TS_HOSTNAME"
  fi
fi
unset TS_AUTHKEY

exec setpriv --reuid=node --regid=node --init-groups -- "$@"
