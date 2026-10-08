#!/bin/sh
# Runs a command as `node`, the Gateway's user. `railway ssh` opens a root
# shell; tool logins run as root would leave files the agent can't read.
# Usage: as-node gog auth list
if [ "$(id -u)" = 0 ]; then
  exec setpriv --reuid=node --regid=node --init-groups -- "$@"
fi
exec "$@"
