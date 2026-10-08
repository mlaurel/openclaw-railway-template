# Architecture

Two Railway services in one project environment, no public ingress.

```text
  macOS app / browser / phone / CLI          (your tailnet devices)
                 │
                 │  WireGuard (Tailscale)
                 │  wss://openclaw.<tailnet>.ts.net        (TLS at Tailscale, port 443)
                 │  ws://openclaw.<tailnet>.ts.net:18789   (fallback, no TLS)
                 ▼
 ┌─────────────────────── Railway project environment ───────────────────────┐
 │                                                                           │
 │  tailscale service                         openclaw service               │
 │  tailscale/tailscale:v1.102.5              ghcr.io/openclaw/openclaw:2026.9.8
 │  containerboot, userspace networking       openclaw gateway --bind lan    │
 │  Serve: raw TCP forward ───────────────►   :18789 (WebSocket + HTTP)      │
 │         private network                    token auth + device pairing   │
 │         openclaw.railway.internal:18789                                   │
 │  volume: /var/lib/tailscale                volume: /data                  │
 │          (node identity)                           └── .openclaw/ (all state)
 └───────────────────────────────────────────────────────────────────────────┘
                                                  │ outbound only
                                                  ▼
                                      model providers, Telegram Bot API
```

Neither service has a Railway domain or TCP proxy. The Gateway is reachable
only on Railway's private network, and only the Tailscale service forwards to it.

## The OpenClaw service

The image is the official OpenClaw image plus three small files:

- `scripts/entrypoint.sh` (45 lines, mostly comments and error messages) runs as root, validates the environment,
  prepares the volume, writes `config/openclaw.seed.json` on first boot only, and
  `exec`s into the stock startup as the unprivileged `node` user.
- `scripts/openclaw-as-node.sh` makes `openclaw` typed in a root `railway ssh`
  shell run as `node`, so operator commands cannot leave root-owned state.
- `config/openclaw.seed.json` is the baseline config (below).

After the privilege drop, the process tree is exactly the stock image:

```text
PID 1  tini -s --                 (signal forwarding, zombie reaping; uid 1000)
       └─ node docker-entrypoint.mjs   runs `openclaw doctor --fix` (state migrations)
          └─ execve → openclaw-gateway  the only long-running process
```

There is no setup web server, reverse proxy, or process supervisor. Railway is
the supervisor.

### Startup sequence

1. Entrypoint (root): refuse to start unless `OPENCLAW_GATEWAY_TOKEN` is set and
   ≥ 32 characters, and `PORT` (if set) equals `18789`. Warn if `/data` is not a
   mount.
2. Create `/data/.openclaw` (mode 700) owned by `node`; hand back to `node` any
   file under it owned by someone else.
3. If `openclaw.json` does not exist, copy the seed. Existing config is never
   touched; OpenClaw's own clobber protection is never triggered.
4. `exec setpriv` → `node` user → `tini` → OpenClaw's `docker-entrypoint.mjs`,
   which runs Doctor migrations under exclusive state ownership, then `execve`s
   the Gateway.
5. `/startupz` turns 200 when the Gateway admits traffic (≈15 s on an empty
   volume in local tests).

### Why a seed config

The Gateway refuses to start when `gateway.mode` is missing (exit 78, "Treat this
as suspicious or clobbered config"), and Doctor's auto-created config doesn't
set it. A container that exits on first boot can't be reached with `railway ssh`
for onboarding. Non-interactive onboarding needs a model provider choice, so it
can't run unattended at first boot either. A one-time seed is the smallest fix
that keeps OpenClaw's clobbered-config safety check enabled; the alternative,
`gateway --allow-unconfigured`, would disable that check permanently.

The seed contains only infrastructure settings:

| Key | Value | Why |
| --- | --- | --- |
| `gateway.mode` | `local` | Required to start. |
| `gateway.bind` | `lan` | Informs Doctor and diagnostics; the `CMD` flag is authoritative. |
| `gateway.auth` | token, env SecretRef `OPENCLAW_GATEWAY_TOKEN` | Token never written to disk. |
| `gateway.auth.rateLimit` | 10 failures / 60 s, 5-minute lockout | OpenClaw's audit warns when a non-loopback Gateway has none. Every tailnet client shares the Tailscale service's IP, so a lockout applies to all of them. |
| `gateway.tailscale.mode` | `off` | OpenClaw's managed Tailscale needs a local `tailscale` daemon; this topology uses a separate service. |
| `gateway.terminal.enabled` | `false` | The operator terminal is a host shell inheriting the Gateway environment (including secrets). Enable it deliberately if you want it. |
| `gateway.nodes.pairing.sshVerify` | `false` | Disables SSH-verified node auto-approval; every device is approved by hand. |

`gateway.publicOrigin` is the one security setting the seed cannot contain,
because it is your tailnet's address; deployment step 7 sets it. Agent-level
policy (tools, channel allowlists) is the operator's choice; see
[SECURITY.md](SECURITY.md).

## Private access: options considered

| Option | Verdict | Why |
| --- | --- | --- |
| **Tailscale service, Serve in raw TCP mode** (chosen) | ✅ | Official image, userspace networking (no `NET_ADMIN`, no TUN), separate service. Forwards bytes without adding headers, so the Gateway sees a header-free private peer and needs no `trustedProxies`. TLS on :443 uses the tailnet's real certificate, so `wss://` works with normal system trust. |
| Tailscale Serve as an HTTP reverse proxy (`https:443 → http://openclaw…`) | ❌ | Adds `X-Forwarded-*` and `Tailscale-User-*` headers. The Gateway rejects those unless the sender is in `gateway.trustedProxies`, and the Tailscale container's Railway private IP changes with each deploy, so the trust range would have to cover the whole private network. Tailscale identity auth (`allowTailscale`) also needs `tailscale whois` on the Gateway host. This reproduces the original failure. |
| `tailscaled` inside the OpenClaw container (`gateway.bind: tailnet` or `gateway.tailscale.mode: serve`) | ❌ | Two long-running processes in one container (needs a supervisor), and kernel networking needs `NET_ADMIN`/TUN, which Railway doesn't grant. In userspace mode there is no tailnet interface for the Gateway to bind. |
| Tailscale subnet router for Railway's private network | ❌ | Exposes every service in the environment to the tailnet, and `*.railway.internal` names don't resolve from tailnet clients. |
| SSH tunnel through Railway SSH (`ssh -L` via `ssh.railway.com`) | Fallback | No extra service, but every client needs a Railway account, a registered SSH key, and a running tunnel. Kept as a break-glass path; see [DESKTOP.md](DESKTOP.md#fallback-railway-ssh-tunnel). |
| Railway public domain + token (the previous template) | ❌ | Public exposure of the Gateway. |

## Why the proxy-attribution error cannot recur

The error came from `src/gateway/ingress-attribution.ts`. In 2026.9.8 (read from
the shipped `dist/ingress-attribution-*.mjs`), every request is classified as:

1. **direct-local**: loopback peer, no `X-Forwarded-*`/`Forwarded`/`X-Real-IP`
   and no `Tailscale-*` headers.
2. **trusted-proxy**: peer address in `gateway.trustedProxies`; the client IP
   is taken from the forwarded headers.
3. **unattributable proxy** → rejected with *"Proxy client attribution is
   required…"*: any peer that sends forwarded or Tailscale headers but is not a
   trusted proxy.
4. **direct-remote**: a non-loopback peer with none of those headers,
   attributed to its socket address.

The old wrapper's in-container proxy sent forwarded headers from loopback, so its
requests fell into case 3. Tailscale Serve's `TCPForward` (verified in Tailscale
v1.102.5 `ipn/ipnlocal/serve.go`) copies bytes and sends no PROXY protocol
header. The Gateway therefore sees case 4: a private-network peer with no
forwarded claims at all. `gateway.trustedProxies` stays empty; nothing is
trusted that could be spoofed.

The image tests reproduce both sides from a second container on a Docker
network:

| Request from a non-loopback peer | Result |
| --- | --- |
| no token / wrong token | 401 |
| token, no proxy headers (what Tailscale TCP forwarding presents) | **200** |
| token + `X-Forwarded-For` | **403** "Proxy client attribution is required" |
| token + `Tailscale-User-Login` | 403 |

What this costs: the Gateway attributes every tailnet client to the Tailscale
service's private IP, so failed-auth rate limiting is shared across your tailnet
devices, and logs show that IP rather than the device's tailnet address. Device
identity, pairing, and token checks are unaffected.

## Authentication model

Two independent layers, both enforced by the Gateway:

1. **Shared token**: every WebSocket `connect` and authenticated HTTP request
   must present `OPENCLAW_GATEWAY_TOKEN`. `--auth token` is pinned in the `CMD`.
2. **Device pairing**: each client (browser profile, Mac app, phone, node host)
   signs the connect challenge with its own Ed25519 key. A new device from a
   non-loopback address stays pending until an operator runs
   `openclaw devices approve <requestId>`. Only direct loopback connections
   (the CLI inside the container) are auto-approved. A connection without
   device identity gets no operator scopes. Verified: a remote client using only
   the token can call `health` but is refused `config.get` (`missing scope:
   operator.read`).

Tailscale adds a third, network-level layer: only tailnet devices your access
policy allows can reach the service at all.

## Health, restarts, and what Railway owns

| Concern | Owner | Mechanism |
| --- | --- | --- |
| Deploy health gate | Railway | `GET /startupz` on `$PORT` (Host `healthcheck.railway.app`), timeout 600 s. 200 once the Gateway admits traffic; ignores channel health. |
| Restart on exit | Railway | `restartPolicyType: ALWAYS`. Required: in external-supervisor mode a config change that needs a restart makes the Gateway exit 0 ("full process restart (supervisor restart)"), observed after onboarding. |
| Graceful stop | Railway + container | Railway sends SIGTERM, then SIGKILL after `drainingSeconds: 330` (OpenClaw's own stop budget). `tini` forwards the signal; the Gateway drains and exits 0 (≈60 ms when idle). |
| Crash recovery | Railway | A killed Gateway ends `tini`, the container exits non-zero, Railway restarts it. |
| State migrations | Container | OpenClaw's entrypoint runs `doctor --fix` before every Gateway start. |
| Single writer | Railway + OpenClaw | One replica. Railway never runs two deployments with the same volume; OpenClaw 2026.9.8 also enforces single-owner Gateway startup. |
| Post-deploy liveness | **Nobody, by default** | Railway checks health only during a deploy. A Gateway that is running but wedged is not restarted automatically. Monitor `/readyz` from a tailnet device if you need this. |

Because only one deployment may hold the volume, every redeploy has a short
outage: Railway stops the old container before starting the new one. A failed
health check therefore means the service is down, not rolled back. `/startupz`
was chosen over `/readyz` for that reason: with an invalid Telegram token,
`/readyz` returns 503 while `/startupz` returns 200 (observed), and a `/readyz`
gate would fail every deploy until the channel was fixed.

## The Tailscale service

The official image with `tailscale/serve.json` baked in (containerboot reads Serve
config only from a file, and Railway can't mount files into a service). It runs as
root inside its container, the image default, with no added capabilities. It
listens on the tailnet (443, 18789) and on `[::]:9002` for Railway's health check,
and has no Railway domain.

- Identity persists on its volume (`TS_STATE_DIR=/var/lib/tailscale`), and
  `TS_AUTH_ONCE=true` skips re-login when that state exists. Redeploys keep the
  same node and MagicDNS name.
- `/healthz` is 200 once the node has a tailnet IP. It doesn't check the
  Gateway; the forward is lazy, so the two services can start in any order.
- `openclaw.railway.internal` is hard-coded in `serve.json`, so the Gateway
  service must be named `openclaw`.

## Requirements and limits

- **Railway environment created after 2025-10-16.** OpenClaw can bind only IPv4
  (`lan` = `0.0.0.0`; `custom` takes one IPv4 address). Older ("legacy") Railway
  environments resolve `*.railway.internal` to IPv6 only, and the Tailscale
  forward would not connect. There is no OpenClaw-side workaround.
- **One Gateway instance.** OpenClaw does not cluster, and Railway volumes can't
  be shared between replicas.
- **Image size.** The official image is ≈5 GB uncompressed. The first build on
  Railway pulls it; later builds reuse cached layers.
- **Resources.** Idle memory is ≈0.9 GB in local tests. Plan on 2 GB memory and
  1 vCPU minimum; more for browser automation or heavy agent fleets. Start with a
  5 GB volume and watch `/data` growth (media, SQLite, workspace).
