# macOS desktop app

The OpenClaw macOS app connects to this Gateway in **Remote direct (ws/wss)**
mode over Tailscale. No SSH and no CLI on the Mac are required.

## What the app connects to

The app talks to the Gateway's **WebSocket endpoint**, the same port that
serves the browser dashboard. Loading the dashboard in a browser does not prove
the app can connect; the app's own **Test** button does (it authenticates and
calls the Gateway `health` RPC).

| | Value |
| --- | --- |
| URL | `wss://openclaw.<tailnet>.ts.net` (port 443, Tailscale TLS) |
| Fallback URL | `ws://openclaw.<tailnet>.ts.net:18789` (plaintext inside WireGuard; OpenClaw allows `ws://` for `.ts.net` hosts) |
| Credential | Gateway token (`OPENCLAW_GATEWAY_TOKEN`) |
| Then | one-time device pairing approval on the Gateway |

TLS on 443 uses the tailnet's publicly trusted certificate, so the app trusts it
through normal macOS trust and records a first-use pin. For `*.ts.net` Serve
endpoints the app replaces a stale stored pin automatically after certificate
rotation. No `gateway.remote.tlsFingerprint` is needed.

## Connect

Prerequisites: the Mac is on your tailnet and allowed by the policy in
[TAILSCALE.md](TAILSCALE.md), and `curl -fsS https://openclaw.<tailnet>.ts.net/healthz`
succeeds from it.

### In the app

1. Menu bar → **Connection…** → **Connection** tab.
2. Under **OpenClaw runs**, choose **Remote (another host)** (or **Change
   connection…** if one exists).
3. Choose **Gateway address or setup code** and enter
   `wss://openclaw.<tailnet>.ts.net`.
4. Enter the **Gateway token**.
5. **Save connection**, then **Test**. The first test reports that pairing is
   required; that's expected.

### Or from Terminal

The app bundles `openclaw-mac`, which reads secrets only from a file or stdin:

```bash
read -rs gateway_token && printf '%s' "$gateway_token" | \
  /Applications/OpenClaw.app/Contents/MacOS/openclaw-mac primary set \
    --direct-url wss://openclaw.<tailnet>.ts.net --token-stdin; unset gateway_token
/Applications/OpenClaw.app/Contents/MacOS/openclaw-mac status --json
```

## Approve pairing

The app asks for two roles: **operator** (dashboard, chat, control) and **node**
(Mac capabilities such as notifications and screen tools). The Gateway treats
tailnet connections as remote, so nothing is auto-approved; only direct
loopback connections are. Approve every pending request from the Mac:

```bash
railway ssh --service openclaw -- openclaw devices list
railway ssh --service openclaw -- openclaw devices approve <requestId>
```

Leave the app open; it retries and connects once approved. Then comes a
separate, second layer: the node's **command surface**, the commands the agent
may run on this Mac, including `system.run` (shell). The app can approve this
request itself from its approval panel (observed on a live deployment), so
decide deliberately; see [SECURITY.md](SECURITY.md#local-node-permissions-the-mac).
From the CLI:

```bash
railway ssh --service openclaw -- openclaw nodes pending
railway ssh --service openclaw -- openclaw nodes approve <nodeRequestId>
```

Check `Requested` against `Approved` in `devices list` before approving, so you
grant what you meant to. Pairing records live in the Gateway's state database on
the volume and survive redeploys. Revoke a device with
`openclaw devices revoke --device <id> --role <role>`.

## Verify

- **Connection → Test** succeeds.
- The menu bar shows the remote Gateway as connected, and the device section
  shows the Mac as `paired · connected`.
- `railway ssh --service openclaw -- openclaw nodes status` lists the Mac.
- After `railway redeploy --service openclaw --yes`, the app reconnects on its
  own without new pairing requests.

Verified on a live Railway deployment (2026-10-08) with the macOS app 2026.9.8,
connected as primary over `wss://`.

## Browser dashboard

Open `https://openclaw.<tailnet>.ts.net/` on a tailnet device and sign in with
the Gateway token. Each browser profile is a separate device: approve it with
`openclaw devices list` / `approve` as above. Private windows forget their
device identity and need approval every time.

## Phone (iOS and Android)

With the phone on your tailnet, generate a pairing code and scan it in the
OpenClaw app:

```bash
railway ssh --service openclaw -- openclaw qr
```

The code advertises `wss://openclaw.<tailnet>.ts.net` with full access. Add
`--limited` to withhold administrative access from the phone. The code holds a
short-lived bootstrap token, so don't post it anywhere. Approve the device with
`openclaw devices list` / `approve` if it stays pending.

## Fallback: Railway SSH tunnel

If Tailscale is unavailable, forward the Gateway port through Railway's SSH
gateway. It needs a Railway account with access to the project and an SSH key
registered with Railway.

1. In the dashboard, open the `openclaw` service, press ⌘K, and choose **Copy
   Service Instance ID** (the service has no domain, so the instance ID is the
   SSH user).
2. Keep a tunnel open:

   ```bash
   ssh -N -L 18789:127.0.0.1:8080 <service-instance-id>@ssh.railway.com
   ```

3. Point the app at `ws://127.0.0.1:18789` with the Gateway token.

Through the tunnel, the Gateway sees a **loopback** client, so device pairing
is auto-approved. That's equivalent to the access the tunnel already grants:
anyone who can open it has a root shell in the container. **(live-unverified)**
