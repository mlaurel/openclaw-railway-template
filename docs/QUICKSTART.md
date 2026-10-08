# Quickstart

From nothing to the macOS app talking to a private OpenClaw Gateway on Railway.
About 15 minutes, most of it waiting for the first build.

You need:

- A Railway account on a paid plan, and the [Railway CLI](https://docs.railway.com/cli)
  (`brew install railway`, then `railway login`).
- A Tailscale tailnet with **MagicDNS** and
  [**HTTPS certificates**](https://tailscale.com/kb/1153/enabling-https) turned on.
  Note your tailnet's DNS name (admin console → **DNS**), for example
  `tail1234.ts.net`.
- A model provider API key (Anthropic is shown below).

## 1. Get a Tailscale auth key

Admin console → **Settings → Keys → Generate auth key**: not reusable, not
ephemeral, 1-day expiry. If your access policy defines `tag:openclaw`
([TAILSCALE.md](TAILSCALE.md#1-prepare-the-tailnet)), add that tag; tagged
machines never expire and get only the access your policy grants them.

## 2. Deploy the template

Click **Deploy on Railway** in the [README](../README.md) and fill in:

| Variable | Value |
| --- | --- |
| `OPENCLAW_PUBLIC_ORIGIN` | `https://openclaw.<your-tailnet>.ts.net` |
| `TS_AUTHKEY` | the key from step 1 |

The Gateway token (`OPENCLAW_GATEWAY_TOKEN`) is generated for you. Wait for both
services to turn green (≈4 minutes; the first build pulls a large image). A
machine named `openclaw` then appears in your tailnet.

If the name is already taken, Tailscale calls it `openclaw-1`; set
`OPENCLAW_PUBLIC_ORIGIN` to match.

## 3. Link the CLI and open SSH

From any directory:

```bash
railway link                                     # pick the new project
railway ssh keys add --key ~/.ssh/id_ed25519.pub # once per machine
railway ssh --service openclaw -- openclaw health
```

The first `railway ssh` asks you to trust `ssh.railway.com`'s host key. Railway
doesn't publish fingerprints, so accept it on first use.

## 4. Add your model provider and onboard

Copy your Anthropic key, then:

```bash
pbpaste | tr -d '\n' | railway variable set ANTHROPIC_API_KEY --stdin --service openclaw
```

When that deploy is green:

```bash
railway ssh --service openclaw -- openclaw onboard --non-interactive --accept-risk --skip-health \
  --mode local --auth-choice apiKey --secret-input-mode ref \
  --gateway-auth token --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN \
  --gateway-bind lan --skip-channels --no-install-daemon
```

The Gateway restarts itself once to apply the result. Check that the agent
answers:

```bash
railway ssh --service openclaw -- openclaw agent --agent main --message "Reply with exactly: OK"
```

For another provider, set its key variable instead (for example
`OPENAI_API_KEY`) and change `--auth-choice`; see `openclaw onboard --help`.

## 5. Connect the macOS app

Keep the Gateway token in your Keychain, then point the app at the Gateway:

```bash
railway variable list --service openclaw --json | jq -j .OPENCLAW_GATEWAY_TOKEN | \
  security add-generic-password -U -a openclaw-railway -s openclaw-railway-gateway-token -w "$(cat)"
security find-generic-password -s openclaw-railway-gateway-token -w | tr -d '\n' | \
  /Applications/OpenClaw.app/Contents/MacOS/openclaw-mac primary set \
    --direct-url wss://openclaw.<your-tailnet>.ts.net --token-stdin
```

`primary set` replaces the app's current primary connection. To add the Gateway
alongside it instead, use `openclaw-mac gateway add Railway --url https://openclaw.<your-tailnet>.ts.net --token-stdin`.
In the app you can also do it by hand: **Connection… → Remote (another host)**.

## 6. Approve the Mac

```bash
railway ssh --service openclaw -- openclaw devices list
railway ssh --service openclaw -- openclaw devices approve <requestId>   # each pending request from your Mac
```

The app connects within a few seconds. It may then ask you to approve its own
node capabilities, which let the agent run commands on your Mac, including
shell commands. Review them before approving; see
[SECURITY.md](SECURITY.md#local-node-permissions-the-mac).

## 7. Finish

- **Tailscale:** if you didn't tag the machine, disable key expiry on `openclaw`
  in the admin console, or it leaves your tailnet after 180 days.
- **Telegram (optional):** see [DEPLOYMENT.md](DEPLOYMENT.md#10-connect-telegram).
- **Backups:** each service → **Backups** → Daily.
- **Audit:** `railway ssh --service openclaw -- openclaw security audit` should
  report 0 critical and 0 warnings.

Something wrong? [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
