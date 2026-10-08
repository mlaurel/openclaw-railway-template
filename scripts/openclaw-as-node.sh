#!/bin/sh
# `railway ssh` opens a root shell. Run the OpenClaw CLI as `node` so anything it
# writes to the state volume stays readable by the Gateway.
if [ "$(id -u)" = 0 ]; then
  exec setpriv --reuid=node --regid=node --init-groups -- env HOME=/home/node /usr/local/bin/openclaw "$@"
fi
exec /usr/local/bin/openclaw "$@"
