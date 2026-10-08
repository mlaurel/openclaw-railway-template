# Deployment

From a fork of this repository to a working, private OpenClaw Gateway that the
macOS app and Telegram can use. Every step is a command you can paste.

Steps marked **(live-unverified)** have not yet been run against a real Railway
project or tailnet; see [ACCEPTANCE_CRITERIA.md](ACCEPTANCE_CRITERIA.md).

## Prerequisites

- A Railway account on a paid plan (volumes larger than 0.5 GB), with the
  Railway GitHub app allowed to read your fork.
- [Railway CLI](https://docs.railway.com/cli) **5.42.1 or newer** (tested help
  output from 5.63.4), logged in with `railway login`, and an SSH key registered
  with Railway: `railway ssh keys add --key ~/.ssh/id_ed25519.pub`. Railway
  publishes no host-key fingerprints for `ssh.railway.com` and rotates keys
  across hosts, so the first connection is trust-on-first-use: accept the prompt
  once in an interactive terminal, or add a scanned key to `known_hosts` yourself.
- Node.js 24+ (to evaluate `.railway/railway.ts`).
- A Tailscale tailnet where you can edit the access policy, with
  [HTTPS certificates enabled](https://tailscale.com/kb/1153/enabling-https).
- `openssl`.

## 1. Create the Railway project

```bash
git clone https://github.com/<you>/<your-fork>.git openclaw-railway
cd openclaw-railway
npm ci
railway init --name openclaw
```

`railway init` creates a project with a new `production` environment. New
environments resolve private DNS to both IPv4 and IPv6, which this template
requires; **do not reuse an environment created before 2025-10-16**
([why](ARCHITECTURE.md#requirements-and-limits)).

**Choose the region now.** `.railway/railway.ts` places both services and both
volumes in `us-west2` unless you set `OPENCLAW_RAILWAY_REGION` (or edit the
`region` constant) before the first apply; region IDs are listed in
[Railway's regions docs](https://docs.railway.com/deployments/regions). Moving
later means migrating the volumes: `railway config apply` reports a volume
region change but does not move the volume. Change the services' region instead
(dashboard → service → Settings → Region), and each volume migrates with its
service on the next deploy, with downtime proportional to its size. Then update
the region in `railway.ts` so plans stay clean.

## 2. Create both services and their volumes

Point `.railway/railway.ts` at your fork: edit `sourceRepository` in the file
(recommended, since it then travels with your fork), or export the variable for
this shell:

```bash
export OPENCLAW_RAILWAY_REPOSITORY=<you>/<your-fork>
railway config plan
railway config apply
```

The plan should show two services (`openclaw`, `tailscale`) and two volumes
(`openclaw-state` at `/data`, `tailscale-state` at `/var/lib/tailscale`), and no
domains. **(live-unverified)**

Railway builds both services immediately. The `openclaw` deployment fails until
step 3 (the entrypoint refuses to start without a Gateway token), and `tailscale`
stays unhealthy until step 7. Both failures are expected.

<details>
<summary>Dashboard equivalent (no CLI)</summary>

Create two services from your GitHub fork, named exactly `openclaw` and
`tailscale` (the Tailscale config forwards to `openclaw.railway.internal`). Then:

| Setting | `openclaw` | `tailscale` |
| --- | --- | --- |
| Builder / Dockerfile path | Dockerfile / `Dockerfile` | Dockerfile / `tailscale/Dockerfile` |
| Volume mount path | `/data` | `/var/lib/tailscale` |
| Healthcheck path / timeout | `/startupz` / 600 s | `/healthz` / 300 s |
| Restart policy | Always | Always |
| Replicas | 1 | 1 |
| Draining seconds | 330 | default |
| Variable `PORT` | `18789` | `9002` |
| Public networking | none | none |

</details>

## 3. Configure Gateway authentication

Generate a token and pipe it straight to Railway, so it never lands in shell
history or process arguments. The token is printed once: save it in your
password manager, because the macOS app needs it in step 8.

```bash
openssl rand -hex 32 | tee /dev/tty | tr -d '\n' | railway variable set OPENCLAW_GATEWAY_TOKEN --stdin --service openclaw
```

Seal it in the dashboard (Variables → ⋯ → Seal) so it can never be read back.
Setting the variable triggers a deploy. Wait for it:

```bash
railway logs --service openclaw
```

Expect `openclaw-railway: created /data/.openclaw/openclaw.json from the baseline config`,
Doctor output, then `[gateway] http server listening`. Railway marks the deploy
healthy when `/startupz` returns 200.

## 4. Choose an AI provider

Each `railway variable set` triggers a deploy of that service unless you pass
`--skip-deploys`. Set the provider's key the same way. Anthropic shown; any provider in
[OpenClaw's provider list](https://docs.openclaw.ai/providers) works:

```bash
read -rs provider_key && printf '%s' "$provider_key" | railway variable set ANTHROPIC_API_KEY --stdin --service openclaw; unset provider_key
```

(`read -rs` waits for you to paste the key without echoing it.) Seal it too.

Add it to `.railway/railway.ts` so future applies keep it
([why](#keeping-variables-in-sync)):

```ts
env: {
  PORT: "18789",
  OPENCLAW_GATEWAY_TOKEN: preserve(),
  ANTHROPIC_API_KEY: preserve(),
},
```

## 5. Initialize the default agent

Run OpenClaw's non-interactive onboarding inside the running container. Inside
`railway ssh` you are root; the image's `openclaw` command drops to the `node`
user for you.

```bash
railway ssh --service openclaw -- openclaw onboard --non-interactive --accept-risk --skip-health \
  --mode local --auth-choice apiKey --secret-input-mode ref \
  --gateway-auth token --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN \
  --gateway-bind lan --skip-channels --no-install-daemon
```

This creates the `main` agent, its workspace under `/data/.openclaw/workspace`,
and an auth profile that *references* `ANTHROPIC_API_KEY` rather than copying it.
For other providers replace `--auth-choice apiKey` (see
`openclaw onboard --help` and [OpenClaw's automation guide](https://docs.openclaw.ai/start/wizard-cli-automation)).
Verified locally: the command keeps the seeded hardening settings and leaves no
plaintext key on the volume.

## 6. Start the Gateway

Onboarding changes `gateway.port`, which needs a restart. Because Railway is the
supervisor (`OPENCLAW_SUPERVISOR_MODE=external`), the Gateway exits cleanly and
Railway's `ALWAYS` restart policy starts it again. Nothing to do but confirm:

```bash
railway ssh --service openclaw -- openclaw health
railway ssh --service openclaw -- openclaw models status
```

## 7. Configure Tailscale

Follow [TAILSCALE.md](TAILSCALE.md) to add the `tag:openclaw` access policy and
create a one-off auth key, then:

```bash
read -rs auth_key && printf '%s' "$auth_key" | railway variable set TS_AUTHKEY --stdin --service tailscale; unset auth_key
```

`TS_AUTHKEY: preserve()` is already declared in `.railway/railway.ts`. After the
deploy, the `tailscale` service turns healthy and a machine named `openclaw`
appears in the Tailscale admin console. **(live-unverified)**

Check the route from any tailnet device:

```bash
curl -fsS https://openclaw.<tailnet>.ts.net/healthz      # {"ok":true,"status":"live"}
curl -fsS http://openclaw.<tailnet>.ts.net:18789/healthz
```

Then tell the Gateway its private browser origin. This is required: until it is
set, `openclaw security audit` reports the critical finding
`gateway.control_ui.allowed_origins_required`, because the Gateway listens on a
non-loopback address without a browser-origin allowlist. It also makes
dashboard links OpenClaw generates point at the tailnet address.

```bash
railway ssh --service openclaw -- openclaw config set gateway.publicOrigin https://openclaw.<tailnet>.ts.net
```

## 8. Connect the macOS app

See [DESKTOP.md](DESKTOP.md). In short: **Connection… → Connection → Remote
(another host) → Gateway address** `wss://openclaw.<tailnet>.ts.net`, paste the
Gateway token, **Save connection**.

## 9. Approve device pairing

The first connection from each device stays pending until you approve it:

```bash
railway ssh --service openclaw -- openclaw devices list
railway ssh --service openclaw -- openclaw devices approve <requestId>
```

The Mac app asks for the operator role and the node role (for Mac
capabilities); approve every pending request from it. Then approve the node's
command surface:

```bash
railway ssh --service openclaw -- openclaw nodes pending
railway ssh --service openclaw -- openclaw nodes approve <nodeRequestId>
```

Pairing is stored in `/data/.openclaw/state/openclaw.sqlite` and survives
redeploys (verified locally across restarts).

## 10. Connect Telegram

1. Create a bot with [@BotFather](https://t.me/BotFather) and copy its token.
2. Store it and add `TELEGRAM_BOT_TOKEN: preserve()` to `.railway/railway.ts`:

   ```bash
   read -rs bot_token && printf '%s' "$bot_token" | railway variable set TELEGRAM_BOT_TOKEN --stdin --service openclaw; unset bot_token
   ```

   On the next start, OpenClaw enables Telegram with `dmPolicy: "pairing"` and
   `groupPolicy: "allowlist"`, reading the token from the environment (verified
   locally; the token is never written to the volume).
3. DM your bot. It replies with a pairing code and your numeric Telegram user ID.
4. Approve the code. The first approved pairing also becomes the command owner:

   ```bash
   railway ssh --service openclaw -- openclaw pairing approve telegram <CODE>
   ```

5. Lock DMs to yourself (recommended; see [SECURITY.md](SECURITY.md#telegram)):

   ```bash
   railway ssh --service openclaw -- openclaw config set channels.telegram.allowFrom '["<your-user-id>"]'
   railway ssh --service openclaw -- openclaw config set channels.telegram.dmPolicy allowlist
   ```

## 11. Run the security audit

```bash
railway ssh --service openclaw -- openclaw security audit --deep
```

Triage findings with [SECURITY.md](SECURITY.md#security-audit).

## 12. Verify the deployment

| Check | Command | Expected |
| --- | --- | --- |
| Version | `railway ssh --service openclaw -- openclaw --version` | `OpenClaw 2026.9.8` |
| Gateway health | `railway ssh --service openclaw -- openclaw health` | OK |
| Deep readiness | `curl -fsS https://openclaw.<tailnet>.ts.net/readyz` (tailnet device) | `{"ready":true}` |
| No public exposure | Railway dashboard → each service → Settings → Networking | no domains, no TCP proxy |
| Auth enforced | `curl -s -o /dev/null -w '%{http_code}' https://openclaw.<tailnet>.ts.net/control-ui-config.json` | `401` |
| Desktop | Mac app → Connection → **Test** | connected |
| Telegram | DM the bot | agent reply |
| Persistence | `railway redeploy --service openclaw --yes`, then repeat the Desktop and Telegram checks | still paired, no re-approval |
| Tailscale persistence | `railway redeploy --service tailscale --yes` | same machine in the admin console, no new auth key used |

## Keeping variables in sync

`.railway/railway.ts` describes the whole project. A variable that exists on a
service but not in that file shows up in `railway config plan` as a deletion.
Plans mark deletions as destructive, and a non-interactive apply refuses them
without `--confirm-destructive`, but an interactive apply will remove the
variable if you confirm. So:

- Declare every variable you add to a service in `railway.ts`. Use `preserve()`
  for secrets so the value stays in Railway and never enters the repository.
- Read the plan before every apply.
- Never use `ctx.randomString()` for secrets: it is a SHA-256 of the
  environment name and a label, so anyone can derive it.

## Backups

Turn on scheduled volume backups for both services in the dashboard (service →
**Backups** → Daily and Weekly). See [UPGRADING.md](UPGRADING.md#5-back-up) for
on-demand backups and restores.

## Publishing as a Railway template

Do this only when you intend to publish. Railway templates are composed in the
dashboard, not from this repository's files:

1. Deploy the project as above and confirm it works.
2. Project **Settings → Generate Template from Project**, or compose one by hand
   with the settings in the [dashboard table](#2-create-both-services-and-their-volumes).
3. In the template's variables, mark `OPENCLAW_GATEWAY_TOKEN` required with the
   description "Gateway secret, at least 32 characters" and default
   `${{secret(64, "abcdef0123456789")}}` (Railway generates a 64-character hex
   value per deployment). Mark `TS_AUTHKEY` optional. Leave provider keys and
   `TELEGRAM_BOT_TOKEN` out; users add them during onboarding.
4. Keep both volumes, keep public networking off, and keep the service names
   `openclaw` and `tailscale`.
5. Link the template's README to this repository's docs. Template users still run
   onboarding (step 5) and pairing (step 9) themselves; they are one-time,
   per-deployment decisions.
