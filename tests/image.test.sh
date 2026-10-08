#!/bin/sh
# Integration tests for the OpenClaw and Tailscale images. Requires Docker.
#
#   sh tests/image.test.sh               # build both images, then test them
#   SKIP_BUILD=1 sh tests/image.test.sh  # test images that are already built
#
# Containers run on a private Docker network. A second container stands in for
# the Tailscale relay: a non-loopback peer that sends no forwarded headers,
# which is what Tailscale's TCP forwarding presents to the Gateway.
#
# Conditions passed to check() are single-quoted on purpose: check() evals them
# later, so ShellCheck cannot see where their variables are used.
# shellcheck disable=SC2016,SC2034
set -eu

cd "$(dirname "$0")/.."

image="${IMAGE:-openclaw-railway:test}"
tailscale_image="${TAILSCALE_IMAGE:-openclaw-railway-tailscale:test}"
token="test-token-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
public_origin="https://openclaw.example-tailnet.ts.net"
run_id="openclaw-test-$$"
network="$run_id-network"
gateway="$run_id-gateway"
node_host="$run_id-node"
tailscale="$run_id-tailscale"
failures=0

log() { printf '\n== %s\n' "$*"; }
pass() { printf '  ok   %s\n' "$*"; }
fail() {
  printf '  FAIL %s\n' "$*"
  failures=$((failures + 1))
}
# check <description> <shell condition>: the condition is evaluated in this shell.
check() {
  if eval "$2" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi
}

cleanup() {
  docker rm -f "$gateway" "$node_host" "$tailscale" >/dev/null 2>&1 || true
  docker volume rm -f "$run_id-state" "$run_id-node-state" "$run_id-tailscale-state" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

start_gateway() {
  docker run -d --name "$gateway" --network "$network" -v "$run_id-state:/data" \
    -e PORT=8080 -e OPENCLAW_GATEWAY_TOKEN="$token" -e OPENCLAW_PUBLIC_ORIGIN="$public_origin" "$image" >/dev/null
}

gateway_address() {
  docker inspect -f "{{(index .NetworkSettings.Networks \"$network\").IPAddress}}" "$gateway"
}

# Prints the HTTP status of a GET made from another container on the network.
# Extra arguments are name=value request headers.
remote_status() {
  path="$1"
  shift
  docker run --rm --network "$network" --entrypoint node "$image" -e '
    const [url, ...pairs] = process.argv.slice(1);
    const headers = Object.fromEntries(pairs.map((pair) => pair.split(/=(.*)/s).slice(0, 2)));
    fetch(url, { headers }).then((response) => console.log(response.status), () => console.log("unreachable"));
  ' "http://$(gateway_address):8080$path" "$@"
}

wait_for_startup() {
  attempt=0
  while [ "$attempt" -lt 60 ]; do
    [ "$(remote_status /startupz 2>/dev/null || true)" = 200 ] && return 0
    attempt=$((attempt + 1))
    sleep 2
  done
  docker logs "$gateway" 2>&1 | tail -30
  return 1
}

# Runs the OpenClaw CLI the way an operator does after `railway ssh`: as root,
# through the wrapper that drops to the node user.
gateway_cli() {
  docker exec "$gateway" openclaw "$@"
}

root_owned_state() {
  docker exec "$gateway" find /data -user root
}

if [ "${SKIP_BUILD:-0}" != 1 ]; then
  log "build"
  docker build -q -t "$image" . >/dev/null
  docker build -q -t "$tailscale_image" tailscale >/dev/null
  pass "both images build"
fi

docker network create "$network" >/dev/null

log "version"
pinned_version="$(sed -n 's|^FROM ghcr.io/openclaw/openclaw:\([^@]*\)@sha256:.*|\1|p' Dockerfile)"
installed_version="$(docker run --rm --entrypoint node "$image" /app/openclaw.mjs --version | sed -n 's/^OpenClaw \([^ ]*\).*/\1/p')"
check "installed OpenClaw ($installed_version) matches the Dockerfile pin ($pinned_version)" \
  '[ -n "$pinned_version" ] && [ "$pinned_version" = "$installed_version" ]'

log "bundled tools"
check "the GitHub CLI is installed for GitHub connections and runs as node" \
  'docker run --rm --user node --entrypoint gh "$image" --version | grep -E "^gh version [0-9]"'
for tool_check in "gog --version" "jq --version" "tmux -V" "codex --version" "claude --version"; do
  check "$tool_check runs as node" 'docker run --rm --user node --entrypoint sh "$image" -c "$tool_check"'
done

log "no secrets in the images"
for candidate in "$image" "$tailscale_image"; do
  check "$candidate has no credentials in its environment" \
    '! docker image inspect -f "{{range .Config.Env}}{{println .}}{{end}}" "$candidate" | grep -Ei "^[A-Z_]*(TOKEN|SECRET|PASSWORD|AUTHKEY|AUTH_KEY|API_KEY)="'
  check "$candidate has no credentials in its build history" \
    '! docker history --no-trunc --format "{{.CreatedBy}}" "$candidate" | grep -Ei "tskey-|sk-ant-|sk-proj-|GATEWAY_TOKEN="'
done
check "Dockerfiles declare no build args, so Railway variables never reach image layers" \
  '! grep -n "^ARG" Dockerfile tailscale/Dockerfile'

log "environment validation"
expect_refusal() {
  description="$1"
  expected_message="$2"
  shift 2
  set +e
  output="$(docker run --rm "$@" "$image" 2>&1)"
  status=$?
  set -e
  check "$description" '[ "$status" = 64 ] && printf "%s" "$output" | grep -F "$expected_message"'
}
expect_refusal "refuses to start without OPENCLAW_GATEWAY_TOKEN" "OPENCLAW_GATEWAY_TOKEN is not set"
expect_refusal "refuses a short gateway token" "at least 32 characters" -e OPENCLAW_GATEWAY_TOKEN=short
expect_refusal "refuses to start without OPENCLAW_PUBLIC_ORIGIN" "OPENCLAW_PUBLIC_ORIGIN is not set" \
  -e OPENCLAW_GATEWAY_TOKEN="$token"
expect_refusal "refuses an OPENCLAW_PUBLIC_ORIGIN that isn't a tailnet HTTPS address" "must be the Gateway's tailnet HTTPS address" \
  -e OPENCLAW_GATEWAY_TOKEN="$token" -e OPENCLAW_PUBLIC_ORIGIN=openclaw.example-tailnet.ts.net
expect_refusal "refuses a PORT that would point Railway's health check elsewhere" "Delete the PORT variable" \
  -e OPENCLAW_GATEWAY_TOKEN="$token" -e OPENCLAW_PUBLIC_ORIGIN="$public_origin" -e PORT=18789
expect_refusal "refuses to start as a non-root user it cannot prepare the volume with" "must start as root" \
  --user node -e OPENCLAW_GATEWAY_TOKEN="$token" -e OPENCLAW_PUBLIC_ORIGIN="$public_origin"

log "first boot on an empty volume"
start_gateway
check "/startupz returns 200" 'wait_for_startup'
check "the baseline config is written on first boot" \
  'docker logs "$gateway" 2>&1 | grep -F "created /data/.openclaw/openclaw.json from the baseline config"'
check "the config is in local mode with an env-referenced token" \
  '[ "$(gateway_cli config get gateway.mode)" = local ] && docker exec "$gateway" grep -q OPENCLAW_GATEWAY_TOKEN /data/.openclaw/openclaw.json'
check "the state directory is owned by node with mode 700" \
  '[ "$(docker exec "$gateway" stat -c "%U %a" /data/.openclaw)" = "node 700" ]'
check "nothing under /data is owned by root" '[ -z "$(root_owned_state)" ]'
check "tini is PID 1" 'docker exec "$gateway" ps -o args= -p 1 | grep -E "^tini "'
check "every container process runs as uid 1000 (node)" \
  '[ -z "$(docker top "$gateway" -eo pid,uid | tail -n +2 | awk "\$2 != 1000")" ]'
check "the gateway token does not appear in any process arguments" \
  '! docker top "$gateway" -eo pid,args | grep -F "$token"'

log "updatable tools layer"
check "Homebrew is seeded onto the volume on first boot" \
  'docker logs "$gateway" 2>&1 | grep -F "created /data/linuxbrew from the image" && docker exec "$gateway" test -x /data/linuxbrew/bin/brew'
check "brew runs from a root shell (as node) with the standard prefix" \
  '[ "$(docker exec "$gateway" brew --prefix)" = /home/linuxbrew/.linuxbrew ]'
check "npm install -g targets the volume" \
  '[ "$(docker exec "$gateway" as-node npm config get prefix)" = /data/home/.local ]'
docker exec "$gateway" as-node sh -c 'mkdir -p "$HOME/.local/bin" && for tool in gog openclaw; do printf "#!/bin/sh\necho volume-copy\n" > "$HOME/.local/bin/$tool"; chmod +x "$HOME/.local/bin/$tool"; done'
check "a tool on the volume takes precedence over the image's copy" \
  '[ "$(docker exec "$gateway" as-node sh -c "command -v gog")" = /data/home/.local/bin/gog ]'
check "the OpenClaw CLI can't be shadowed from the volume" \
  '[ "$(docker exec "$gateway" as-node sh -c "command -v openclaw")" = /usr/local/sbin/openclaw ]'
docker exec "$gateway" as-node rm -f /data/home/.local/bin/gog /data/home/.local/bin/openclaw

log "security audit"
# Prints "<severity> <checkId>" for every critical or warning finding.
audit_problems() {
  gateway_cli security audit --json 2>/dev/null | docker run --rm -i --entrypoint node "$image" -e '
    let input = "";
    process.stdin.on("data", (chunk) => (input += chunk));
    process.stdin.on("end", () => {
      for (const finding of JSON.parse(input).findings) {
        if (finding.severity !== "info") console.log(`${finding.severity} ${finding.checkId}`);
      }
    });'
}
check "a fresh deployment passes the security audit with no warnings or critical findings" \
  '[ -z "$(audit_problems)" ]'
check "gateway.publicOrigin comes from OPENCLAW_PUBLIC_ORIGIN" \
  'docker exec "$gateway" grep -F "\${OPENCLAW_PUBLIC_ORIGIN}" /data/.openclaw/openclaw.json'
check "mobile pairing QR advertises the tailnet wss:// address with full access" \
  'docker exec "$gateway" openclaw qr --json | node -e "
    let input = \"\";
    process.stdin.on(\"data\", (chunk) => (input += chunk)).on(\"end\", () => {
      const setup = JSON.parse(input.slice(input.indexOf(\"{\")));
      process.exit(setup.gatewayUrl.startsWith(\"wss://\") && setup.gatewayUrl.endsWith(\".ts.net\") && setup.access === \"full\" ? 0 : 1);
    });"'

log "health checks"
check "/healthz returns 200" '[ "$(remote_status /healthz)" = 200 ]'
check "/startupz accepts Railway's healthcheck.railway.app Host header" \
  '[ "$(remote_status /startupz host=healthcheck.railway.app)" = 200 ]'
check "/readyz returns 200 with no channels configured" '[ "$(remote_status /readyz)" = 200 ]'

log "authentication and proxy attribution from a remote peer"
check "an unauthenticated request is rejected (401)" \
  '[ "$(remote_status /control-ui-config.json)" = 401 ]'
check "a wrong token is rejected (401)" \
  '[ "$(remote_status /control-ui-config.json "authorization=Bearer wrong-token-000000000000000000000000")" = 401 ]'
check "the token from a header-free remote peer is accepted (200)" \
  '[ "$(remote_status /control-ui-config.json "authorization=Bearer $token")" = 200 ]'
check "a spoofed X-Forwarded-For is rejected by proxy attribution (403)" \
  '[ "$(remote_status /control-ui-config.json "authorization=Bearer $token" x-forwarded-for=100.64.0.9)" = 403 ]'
check "spoofed Tailscale identity headers are rejected (403)" \
  '[ "$(remote_status /control-ui-config.json "authorization=Bearer $token" tailscale-user-login=someone@example.com)" = 403 ]'

log "device pairing from a remote node"
docker run -d --name "$node_host" --network "$network" -v "$run_id-node-state:/home/node/.openclaw" \
  -e OPENCLAW_GATEWAY_TOKEN="$token" --entrypoint node "$image" \
  /app/openclaw.mjs node run --host "$(gateway_address)" --port 8080 --no-tls --display-name pairing-test >/dev/null
pending_request_id() {
  gateway_cli devices list --json 2>/dev/null | docker run --rm -i --entrypoint node "$image" -e '
    let input = "";
    process.stdin.on("data", (chunk) => (input += chunk));
    process.stdin.on("end", () => console.log(JSON.parse(input).pending?.[0]?.requestId ?? ""));'
}
request_id=""
attempt=0
while [ -z "$request_id" ] && [ "$attempt" -lt 30 ]; do
  sleep 2
  attempt=$((attempt + 1))
  request_id="$(pending_request_id || true)"
done
check "the remote node waits for approval instead of being auto-approved" '[ -n "$request_id" ]'
check "an operator approves the request from inside the container" 'gateway_cli devices approve "$request_id"'
attempt=0
until docker logs "$node_host" 2>&1 | grep -F "node host gateway connected" >/dev/null || [ "$attempt" -ge 30 ]; do
  sleep 2
  attempt=$((attempt + 1))
done
check "the approved node connects" 'docker logs "$node_host" 2>&1 | grep -F "node host gateway connected"'

log "state survives a restart"
# /proc/1/environ belongs to node, so read it as node.
check "HOME is on the volume for the Gateway" \
  'docker exec "$gateway" as-node sh -c "tr \"\\0\" \"\\n\" < /proc/1/environ" | grep -x HOME=/data/home'
check "HOME is on the volume in a root shell too" '[ "$(docker exec "$gateway" sh -c "echo \$HOME")" = /data/home ]'
docker exec "$gateway" as-node sh -c 'echo kept > "$HOME/persist-check"'
gateway_cli config set gateway.controlUi.communityInvite false >/dev/null 2>&1
check "a config change made from a root shell leaves no root-owned files" '[ -z "$(root_owned_state)" ]'
docker exec "$gateway" touch /data/.openclaw/written-by-root /data/home/written-by-root
start_time="$(date +%s)"
docker stop -t 60 "$gateway" >/dev/null
stop_seconds=$(($(date +%s) - start_time))
check "SIGTERM stops the Gateway cleanly (exit 0)" '[ "$(docker inspect -f "{{.State.ExitCode}}" "$gateway")" = 0 ]'
check "graceful stop finished in ${stop_seconds}s" '[ "$stop_seconds" -lt 30 ]'
docker start "$gateway" >/dev/null
check "the Gateway starts again on the same volume" 'wait_for_startup'
check "the config change persisted" '[ "$(gateway_cli config get gateway.controlUi.communityInvite)" = false ]'
check "the baseline config was not reapplied" \
  '[ "$(docker logs "$gateway" 2>&1 | grep -c "from the baseline config")" = 1 ]'
check "OpenClaw did not detect a clobbered config" \
  '! docker exec "$gateway" sh -c "ls /data/.openclaw | grep clobbered"'
check "root-owned files are handed back to node on restart" \
  '[ "$(docker exec "$gateway" stat -c %U /data/.openclaw/written-by-root)" = node ] && [ "$(docker exec "$gateway" stat -c %U /data/home/written-by-root)" = node ]'
check "Homebrew survives a restart and isn't seeded again" \
  'docker exec "$gateway" brew --version && [ "$(docker logs "$gateway" 2>&1 | grep -c "created /data/linuxbrew")" = 1 ]'
check "files in HOME survive a restart" \
  '[ "$(docker exec "$gateway" cat /data/home/persist-check)" = kept ]'
check "the paired node is still paired after the restart" \
  'gateway_cli devices list --json | grep -F pairing-test'

log "crash handling"
docker exec "$gateway" pkill -KILL -f openclaw-gateway || true
attempt=0
until [ "$(docker inspect -f '{{.State.Running}}' "$gateway")" = false ] || [ "$attempt" -ge 15 ]; do
  sleep 1
  attempt=$((attempt + 1))
done
check "the container exits when the Gateway dies, so Railway's restart policy applies" \
  '[ "$(docker inspect -f "{{.State.Running}}" "$gateway")" = false ]'
check "the crash exit code is non-zero" '[ "$(docker inspect -f "{{.State.ExitCode}}" "$gateway")" != 0 ]'
docker start "$gateway" >/dev/null
check "the Gateway recovers after a crash" 'wait_for_startup'

log "tailscale image"
tailscale_environment="$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$tailscale_image")"
for setting in TS_USERSPACE=true TS_STATE_DIR=/var/lib/tailscale TS_AUTH_ONCE=true \
  TS_SERVE_CONFIG=/etc/tailscale/serve.json TS_ENABLE_HEALTH_CHECK=true TS_DEBUG_MTU=1236; do
  check "defaults to $setting" 'printf "%s\n" "$tailscale_environment" | grep -qx "$setting"'
done
docker run -d --name "$tailscale" --network "$network" -v "$run_id-tailscale-state:/var/lib/tailscale" "$tailscale_image" >/dev/null
sleep 10
check "containerboot runs without NET_ADMIN or a TUN device" \
  '[ "$(docker inspect -f "{{.State.Running}}" "$tailscale")" = true ]'
check "/healthz is unhealthy until the node joins a tailnet" \
  '! docker exec "$tailscale" wget -qO- http://127.0.0.1:8080/healthz'

printf '\n'
if [ "$failures" -gt 0 ]; then
  printf '%s check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
