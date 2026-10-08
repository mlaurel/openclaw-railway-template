# Deployment

Two ways to deploy:

- **Railway template**: one click plus two variables. Follow
  [QUICKSTART.md](QUICKSTART.md). Use this unless you need to change the code.
- **From your fork, with Infrastructure as Code**: this page. Use it when you
  maintain your own fork (`.railway/railway.ts` then describes the project).

Both end at the same place: a Gateway reachable only through your tailnet, with
the macOS app paired and, optionally, Telegram. Everything on this page was run
against a live Railway project on 2026-10-08 except where marked.

## Prerequisites

- A Railway account on a paid plan (volumes larger than 0.5 GB). Public forks
  build without the Railway GitHub app; private forks need it.
- [Railway CLI](https://docs.railway.com/cli) **5.42.1 or newer** (`brew install railway`),
  logged in with `railway login`, plus an SSH key registered with Railway:
  `railway ssh keys add --key ~/.ssh/id_ed25519.pub`. Railway publishes no
  host-key fingerprints for `ssh.railway.com` and rotates keys across hosts, so
  the first connection is trust-on-first-use: accept the prompt once in an
  interactive terminal.
- Node.js 24+ (to evaluate `.railway/railway.ts`).
- A Tailscale tailnet with MagicDNS and
  [HTTPS certificates](https://tailscale.com/kb/1153/enabling-https) enabled.
  Note its DNS name (admin console → **DNS**), for example `tail1234.ts.net`.

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
`region` constant) before the first apply; region IDs are in
[Railway's regions docs](https://docs.railway.com/deployments/regions). Moving
later means migrating the volumes: `railway config apply` reports a volume
region change but does not move the volume. Change the services' region instead
(dashboard → service → Settings → Region), and each volume migrates with its
service on the next deploy, with downtime proportional to its size. Then update
the region in `railway.ts` so plans stay clean.

## 2. Create both services and their volumes

Point `.railway/railway.ts` at your fork: edit `sourceRepository` in the file
(it then travels with your fork), or export the variable for this shell:

```bash
export OPENCLAW_RAILWAY_REPOSITORY=<you>/<your-fork>
railway config plan
railway config apply
```

The plan shows two services (`openclaw`, `tailscale`), two volumes
(`openclaw-state` at `/data`, `tailscale-state` at `/var/lib/tailscale`), and no
domains.

Railway builds both services immediately. Both first deploys fail, as expected:
`openclaw` refuses to start until step 3 sets its variables, and `tailscale` has
no auth key until step 7. With no key, `tailscale` prints a login URL in its
deploy logs and fails its 300-second health check.

<details>
<summary>Dashboard equivalent (no CLI)</summary>

Create two services from your GitHub fork, named exactly `openclaw` and
`tailscale` (the Tailscale config forwards to `openclaw.railway.internal`). Then:

| Setting | `openclaw` | `tailscale` |
| --- | --- | --- |
| Root directory | (repository root) | `tailscale` |
| Builder | Dockerfile | Dockerfile |
| Volume mount path | `/data` | `/var/lib/tailscale` |
| Region | same for both services | same for both services |
| Healthcheck path / timeout | `/startupz` / 600 s | `/healthz` / 300 s |
| Restart policy | Always | Always |
| Replicas | 1 | 1 |
| Draining seconds | 330 | default |
| `PORT` variable | **none** (Railway's default, 8080, is what both listen on) | **none** |
| Public networking | none | none |

</details>

## 3. Configure the Gateway

Two variables. The token authenticates every client; the origin is the address
you'll reach the Gateway at, which OpenClaw also uses as its browser-origin
allowlist (the entrypoint refuses to start without it).

On macOS, generate the token straight into your Keychain and pipe it to Railway,
so it never appears on screen or in your shell history:

```bash
security add-generic-password -U -a openclaw-railway -s openclaw-railway-gateway-token -w "$(openssl rand -hex 32)"
security find-generic-password -s openclaw-railway-gateway-token -w | tr -d '\n' | \
  railway variable set OPENCLAW_GATEWAY_TOKEN --stdin --service openclaw --skip-deploys
railway variable set OPENCLAW_PUBLIC_ORIGIN=https://openclaw.<your-tailnet>.ts.net --service openclaw
```

(Elsewhere: `openssl rand -hex 32 | tee /dev/tty | tr -d '\n' | railway variable set OPENCLAW_GATEWAY_TOKEN --stdin --service openclaw`,
and save the printed value in a password manager.) Seal the token in the
dashboard (Variables → ⋯ → Seal) if you don't need to read it back.

The second command deploys. Watch it:

```bash
railway logs --service openclaw
```

Expect `openclaw-railway: created /data/.openclaw/openclaw.json from the baseline config`,
Doctor output, then `[gateway] http server listening`. Railway marks the deploy
healthy once `/startupz` returns 200 (≈3 minutes the first time, mostly pulling
the base image).

## 4. Choose an AI provider

Set the provider's key. Copy it to the clipboard first:

```bash
pbpaste | tr -d '\n' | railway variable set ANTHROPIC_API_KEY --stdin --service openclaw
```

`ANTHROPIC_API_KEY` is already declared in `.railway/railway.ts`. For another
provider ([list](https://docs.openclaw.ai/providers)), set its variable and add it
to the file as `preserve()` ([why](#keeping-variables-in-sync)).

## 5. Initialize the default agent

Run OpenClaw's non-interactive onboarding inside the running container. Inside
`railway ssh` you're root; the image's `openclaw` command drops to the `node`
user for you, and the session sees the service's variables.

```bash
railway ssh --service openclaw -- openclaw onboard --non-interactive --accept-risk --skip-health \
  --mode local --auth-choice apiKey --secret-input-mode ref \
  --gateway-auth token --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN \
  --gateway-bind lan --skip-channels --no-install-daemon
```

This creates the `main` agent, its workspace under `/data/.openclaw/workspace`,
and an auth profile that *references* `ANTHROPIC_API_KEY` rather than copying it.
For other providers replace `--auth-choice apiKey` (see `openclaw onboard --help`
and [OpenClaw's automation guide](https://docs.openclaw.ai/start/wizard-cli-automation)).

## 6. Confirm the restart

Onboarding changes `gateway.port`, which needs a restart. Because Railway is the
supervisor (`OPENCLAW_SUPERVISOR_MODE=external`), the Gateway exits cleanly and
Railway's `ALWAYS` restart policy starts it again (observed: back in ≈30 s).
Then check that the agent answers:

```bash
railway ssh --service openclaw -- openclaw health
railway ssh --service openclaw -- openclaw agent --agent main --message "Reply with exactly: OK"
```

`openclaw models status --probe` refuses to run while the Gateway holds the
state; the agent message tests the same credential end to end.

## 7. Connect Tailscale

Create an auth key ([TAILSCALE.md](TAILSCALE.md#2-authenticate-the-node)), copy
it, then:

```bash
pbpaste | tr -d '\n' | railway variable set TS_AUTHKEY --stdin --service tailscale
```

After the deploy, a machine named `openclaw` appears in your tailnet. From any
tailnet device:

```bash
curl -fsS https://openclaw.<your-tailnet>.ts.net/healthz        # {"ok":true,"status":"live"}
curl -fsS http://openclaw.<your-tailnet>.ts.net:18789/healthz   # same, without TLS
```

If you didn't tag the key, the machine belongs to your user: disable its key
expiry in the admin console, or it leaves the tailnet after 180 days.

## 8. Connect the macOS app

```bash
security find-generic-password -s openclaw-railway-gateway-token -w | tr -d '\n' | \
  /Applications/OpenClaw.app/Contents/MacOS/openclaw-mac primary set \
    --direct-url wss://openclaw.<your-tailnet>.ts.net --token-stdin
```

`primary set` replaces the app's current primary connection (undo with
`openclaw-mac primary set --local`). To keep your current primary and add this
Gateway alongside it, use `openclaw-mac gateway add Railway --url https://openclaw.<your-tailnet>.ts.net --token-stdin`.
Details and the in-app route: [DESKTOP.md](DESKTOP.md).

## 9. Approve device pairing

The first connection from each device stays pending until you approve it:

```bash
railway ssh --service openclaw -- openclaw devices list
railway ssh --service openclaw -- openclaw devices approve <requestId>
```

The Mac app files two requests, for the operator role and the node role;
approve both. It then asks for its **node capability surface**, the commands
the agent may run on your Mac, including `system.run`. The app can approve
this request itself from its approval panel, so decide deliberately what you
allow ([SECURITY.md](SECURITY.md#local-node-permissions-the-mac)); from the CLI
it's `openclaw nodes pending` / `openclaw nodes approve <id>`.

Pairing is stored in `/data/.openclaw/state/openclaw.sqlite` and survives
redeploys.

## 10. Connect Telegram

1. Create a bot with [@BotFather](https://t.me/BotFather) and copy its token.
2. Store it, and add `TELEGRAM_BOT_TOKEN: preserve()` to `.railway/railway.ts`:

   ```bash
   pbpaste | tr -d '\n' | railway variable set TELEGRAM_BOT_TOKEN --stdin --service openclaw
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

**(live-unverified:** Telegram has been tested locally with a dummy token, not
with a real bot on Railway.)

## 11. Run the security audit

```bash
railway ssh --service openclaw -- openclaw security audit --deep
```

Expected: 0 critical, and one warning, `gateway.probe_failed`, which the deep
probe reports on every 2026.9.8 install ([why](SECURITY.md#security-audit)).

## 12. Verify the deployment

| Check | Command | Expected |
| --- | --- | --- |
| Version | `railway ssh --service openclaw -- openclaw --version` | `OpenClaw 2026.9.8` |
| Gateway health | `railway ssh --service openclaw -- openclaw health` | OK |
| Deep readiness | `curl -fsS https://openclaw.<tailnet>.ts.net/readyz` (tailnet device) | `{"ready":true}` |
| No public exposure | Railway dashboard → each service → Settings → Networking | no domains, no TCP proxy |
| Auth enforced | `curl -s -o /dev/null -w '%{http_code}' https://openclaw.<tailnet>.ts.net/control-ui-config.json` | `401` |
| Desktop | `openclaw-mac status --json` | primary `connected` |
| Telegram | DM the bot | agent reply |
| Persistence | `railway redeploy --service openclaw --yes`, then repeat the Desktop check | still paired, no re-approval |
| Tailscale persistence | `railway redeploy --service tailscale --yes` | same machine and IP, no new key used |

## Keeping variables in sync

`.railway/railway.ts` describes the whole project. A variable that exists on a
service but not in that file shows up in `railway config plan` as a deletion.
Plans mark deletions as destructive, and a non-interactive apply refuses them
without `--confirm-destructive`, but an interactive apply will remove the
variable if you confirm. So:

- Declare every variable you add to a service in `railway.ts`. Use `preserve()`
  for secrets so the value stays in Railway and never enters the repository.
- Read the plan before every apply.
- Never use `ctx.randomString()` for secrets: it's a SHA-256 of the environment
  name and a label, so anyone can derive it.

## Backups

Turn on scheduled volume backups for both services in the dashboard (service →
**Backups** → Daily and Weekly). See [UPGRADING.md](UPGRADING.md#5-back-up) for
on-demand backups and restores.

## Maintaining the Railway template

The published template is generated from a separate source project, not from a
live deployment, so no real secret can reach it. Railway's `templateGenerate`
keeps service names, sources (including root directories), health-check paths,
restart policy, volume mount paths, and template *functions* such as
`${{secret(64, "abcdef0123456789")}}`. It **drops literal variable values** and
marks every variable required. That is why both services listen on Railway's
default port instead of taking a `PORT` variable. To regenerate:

1. In a project whose services mirror `.railway/railway.ts`, set
   `OPENCLAW_GATEWAY_TOKEN` to `${{ secret(64, "abcdef0123456789") }}` and
   placeholder values for `OPENCLAW_PUBLIC_ORIGIN` and `TS_AUTHKEY`.
2. `railway api 'mutation($p: String!) { templateGenerate(input: { projectId: $p }) { id code serializedConfig } }' --variables '{"p":"<project-id>"}'`
3. Inspect `serializedConfig`: no secret values, both volumes, `rootDirectory: "tailscale"`.
4. Deploy it into a scratch project (`railway deploy -t <code> -v …`) and wait
   for `openclaw` to turn healthy before publishing.
