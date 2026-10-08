# Tailscale

The `tailscale` service is the only way into the Gateway. It joins your tailnet
as a tagged machine named `openclaw` and forwards two ports to the Gateway over
Railway's private network:

| Tailnet address | Transport | Forwarded to |
| --- | --- | --- |
| `wss://openclaw.<tailnet>.ts.net` (port 443) | TLS terminated by Tailscale with the tailnet's Let's Encrypt certificate | `openclaw.railway.internal:18789` |
| `ws://openclaw.<tailnet>.ts.net:18789` | plaintext inside WireGuard | `openclaw.railway.internal:18789` |

Both are raw TCP forwards (`TCPForward` in `tailscale/serve.json`), not HTTP
proxies, so no forwarded headers reach the Gateway
([why that matters](ARCHITECTURE.md#why-the-proxy-attribution-error-cannot-recur)).
Use the `wss://` address; the `ws://` port is a fallback for tailnets without
HTTPS certificates. OpenClaw clients accept plaintext `ws://` to `.ts.net` hosts.

## Variables (verified against containerboot v1.102.5)

| Variable | Set in | Value | Effect |
| --- | --- | --- | --- |
| `TS_USERSPACE` | image | `true` | Userspace networking: no `/dev/net/tun`, no `NET_ADMIN`. Serve still works because tailscaled accepts tailnet connections itself. |
| `TS_STATE_DIR` | image | `/var/lib/tailscale` | Node key and identity, on the service's Railway volume. |
| `TS_AUTH_ONCE` | image | `true` | Logs in only when not already logged in, so a restart never consumes a key. |
| `TS_SERVE_CONFIG` | image | `/etc/tailscale/serve.json` | Applied after login; `${TS_CERT_DOMAIN}` becomes the node's MagicDNS name. Containerboot watches the file, but it is baked into the image, so changes ship as a redeploy. |
| `TS_HOSTNAME` | image (override in Railway) | `openclaw` | MagicDNS name. If the name is taken, Tailscale appends a suffix such as `openclaw-1`. |
| `TS_ENABLE_HEALTH_CHECK`, `TS_LOCAL_ADDR_PORT` | image | `true`, `[::]:9002` | `/healthz` returns 200 once the node has a tailnet IP, 503 before. Railway's health check uses it. |
| `TS_AUTHKEY` | Railway (secret) | `tskey-auth-…` | First login only. |
| `TS_ACCEPT_DNS` | default (`false`) | — | Keeps Railway's resolver, which `openclaw.railway.internal` depends on. |

Railway can't mount files into a service, which is why `serve.json` is part of
the image and the `tailscale` service builds from this repository instead of
using the bare `tailscale/tailscale` image.

## 1. Prepare the tailnet

In the [admin console](https://login.tailscale.com/admin):

1. **DNS**: enable MagicDNS and **HTTPS Certificates**.
2. **Access controls**: add a tag owner and a grant that lets only you reach the
   Gateway. Replace `you@example.com`:

   ```jsonc
   {
     "tagOwners": {
       "tag:openclaw": ["autogroup:admin"],
     },
     "grants": [
       // Only the operator's devices may reach the Gateway, and only its two ports.
       { "src": ["you@example.com"], "dst": ["tag:openclaw"], "ip": ["tcp:443", "tcp:18789"] },
     ],
     "tests": [
       { "src": "you@example.com", "accept": ["tag:openclaw:443", "tag:openclaw:18789"] },
     ],
   }
   ```

   Merge this into your existing policy. If the policy still contains the
   default allow-all rule (`"src": ["*"], "dst": ["*:*"]` or the grants
   equivalent), every tailnet member can reach the Gateway; narrow it. The
   `openclaw` node gets no grants of its own, so it cannot open connections to
   anything else on your tailnet even if the Gateway is compromised.

## 2. Authenticate the node

Pick one.

### Option A: one-off tagged auth key (recommended)

**Settings → Keys → Generate auth key**:

- Reusable: **off**. The key is used once; afterwards the identity lives on the
  `tailscale-state` volume.
- Expiration: 1 day. It only needs to last until the first deploy.
- Ephemeral: **off**. An ephemeral node would be removed when it disconnects
  (for example during a redeploy).
- Pre-approved: **on** if your tailnet requires device approval.
- Tags: `tag:openclaw`.

```bash
read -rs auth_key && printf '%s' "$auth_key" | railway variable set TS_AUTHKEY --stdin --service tailscale; unset auth_key
```

Tagged nodes have key expiry disabled by default, so the node stays logged in.
After it joins you can delete `TS_AUTHKEY` from the service (and from
`.railway/railway.ts`); a consumed one-off key is useless anyway.

### Option B: no auth key

Leave `TS_AUTHKEY` unset. On first start, containerboot prints a login URL
(observed: `To authenticate, visit: https://login.tailscale.com/a/…`):

```bash
railway logs --service tailscale
```

Open it within the 5-minute health-check window and log in. Then in the admin
console, on the `openclaw` machine: **Edit ACL tags** → `tag:openclaw`, and
**Disable key expiry** if it isn't tagged. Anyone who can read the service's
logs during that window could claim the node, so prefer option A when other
people have access to the Railway project.

### Option C: OAuth client (not tested here)

Containerboot v1.102.5 also accepts `TS_CLIENT_ID` and `TS_CLIENT_SECRET` (an
OAuth client with the `auth_keys` scope) and generates its own key. Keys minted
this way must carry tags, so also set `TS_EXTRA_ARGS=--advertise-tags=tag:openclaw`.
These are mutually exclusive with `TS_AUTHKEY`. Use this only if you rebuild
nodes often; with persistent state, A is simpler.

## 3. Verify

From a tailnet device allowed by the policy:

```bash
tailscale ping openclaw
curl -fsS https://openclaw.<tailnet>.ts.net/healthz   # {"ok":true,"status":"live"}
```

The first HTTPS request can take a few seconds while Tailscale issues the
certificate. From a device the policy does not allow, the same `curl` should
time out.

## Operations

- **Redeploys and restarts** keep the same node, address, and certificate:
  state is on the volume and `TS_AUTH_ONCE` skips login.
- **Re-keying the node.** Generate a new key (option A), set `TS_AUTHKEY`,
  remove the old `openclaw` machine in the admin console, and redeploy. With
  the old identity revoked, containerboot is no longer logged in and uses the new
  key. **(live-unverified)**
- **Node key expiry.** Tagged nodes don't expire by default. If you used option B
  and didn't tag the node, disable key expiry or it will drop off the tailnet
  after the tailnet's expiry period (180 days by default).
- **Never enable Funnel** for this node. `tests/serve-config.test.sh` fails CI
  if `serve.json` enables Funnel or switches to HTTP proxying.
- **Upgrading Tailscale.** Dependabot proposes new `tailscale/tailscale` tags for
  `tailscale/Dockerfile`; CI re-checks `serve.json` against the new release's
  types.
