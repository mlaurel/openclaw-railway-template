# Configuration

Where each setting lives, and why. Nothing here is a secret except where noted.
Secrets go in Railway variables (sealed), never in this repository.

For a copyable list of the runtime variables, see [`.env.example`](../.env.example).

## Build time (baked into the images)

| Setting | Where | Value |
| --- | --- | --- |
| OpenClaw version | `Dockerfile` `FROM` line | `ghcr.io/openclaw/openclaw:2026.9.8@sha256:d0de…` — the only version pin |
| `HOME` | `Dockerfile` | `/data/home`, on the volume, so tool logins and settings under `~` persist. See [TOOLS.md](TOOLS.md). |
| Skill tools | `Dockerfile`, `tools/package.json` | `gog`, `claude`, `codex`, `jq`, `tmux`, ImageMagick as a pinned baseline; see [TOOLS.md](TOOLS.md). |
| Homebrew | `Dockerfile` (seed), `/data/linuxbrew` | Homebrew 7.0.8 seeded onto the volume on first boot, then self-updating. `/home/linuxbrew/.linuxbrew` is a symlink to it. |
| `PATH`, `NPM_CONFIG_PREFIX` | `Dockerfile` | `openclaw`/`brew` wrappers, then `~/.local/bin`, then Homebrew, then the image. `npm install -g` writes to `~/.local` on the volume. |
| GitHub CLI | `Dockerfile` `RUN` step | `gh` 2.102.0, checksum-verified. Needed for **Settings → Profile → GitHub connections**; OpenClaw stores each connection under `/data/.openclaw/credentials/github/`, so connections persist. |
| Tailscale version | `tailscale/Dockerfile` `FROM` line | `tailscale/tailscale:v1.102.5@sha256:c507…` |
| `OPENCLAW_HOME` | `Dockerfile` | `/data` → state at `/data/.openclaw` |
| `OPENCLAW_GATEWAY_PORT` | `Dockerfile` | `8080`, the `PORT` Railway injects when a service sets none |
| `OPENCLAW_SUPERVISOR_MODE` | `Dockerfile` | `external` — Railway owns the process lifecycle; OpenClaw refuses self-update and service installs, and restarts by exiting cleanly |
| `OPENCLAW_NO_AUTO_UPDATE` | `Dockerfile` | `1` |
| Gateway bind and auth mode | `Dockerfile` `CMD` | `gateway --bind lan --auth token` (pinned so no config edit can undo them) |
| Baseline OpenClaw config | `config/openclaw.seed.json` | Copied to `/data/.openclaw/openclaw.json` on first boot only |
| Tailscale defaults | `tailscale/Dockerfile` | `TS_USERSPACE=true`, `TS_STATE_DIR=/var/lib/tailscale`, `TS_AUTH_ONCE=true`, `TS_SERVE_CONFIG=/etc/tailscale/serve.json`, `TS_HOSTNAME=openclaw`, `TS_ENABLE_HEALTH_CHECK=true`, `TS_LOCAL_ADDR_PORT=[::]:8080` (Railway's default `PORT`) |
| Tailscale Serve routes | `tailscale/serve.json` | tailnet `:443` (TLS terminated) and `:18789` → `openclaw.railway.internal:8080`, raw TCP |

The Dockerfiles declare no `ARG`s. Railway passes service variables to builds
only as matching build arguments, so no variable can reach an image layer
(`tests/image.test.sh` checks this).

There is no `PORT` variable on either service. Railway injects `PORT=8080` into
any service that doesn't set one, and both containers listen there (the Gateway,
and containerboot's health endpoint). The entrypoint refuses to start if a
`PORT` variable points anywhere else.

## Railway variables: `openclaw` service

| Variable | Required | Secret | Purpose |
| --- | --- | --- | --- |
| `OPENCLAW_PUBLIC_ORIGIN` | yes | no | `https://openclaw.<your-tailnet>.ts.net`. The baseline config sets `gateway.publicOrigin` (the browser-origin allowlist) and the mobile pairing URL from it. The entrypoint refuses to start if it is missing or not a `https://….ts.net` address. |
| `OPENCLAW_GATEWAY_TOKEN` | yes | **yes** | Gateway authentication secret, ≥ 32 characters. Generate with `openssl rand -hex 32`. |
| Provider key, e.g. `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY` | for the provider you choose | **yes** | Model credential. Onboarding stores an env reference to it, not the value. |
| `GOG_KEYRING_PASSWORD` | for the gog skill | **yes** | Password for `gog`'s token file on the volume. See [TOOLS.md](TOOLS.md#google-gog). |
| `TELEGRAM_BOT_TOKEN` | for Telegram | **yes** | Bot token from @BotFather. Its presence enables Telegram (DM pairing, allowlisted groups). |

## Railway variables: `tailscale` service

| Variable | Required | Secret | Purpose |
| --- | --- | --- | --- |
| `TS_AUTHKEY` | no | **yes** | One-off, tagged, pre-approved auth key, used only for the first login. Omit it to log in once through the URL printed in the deploy logs. See [TAILSCALE.md](TAILSCALE.md). |
| `TS_HOSTNAME` | no | no | Overrides the MagicDNS name (default `openclaw`). |

Every variable on a service managed by `.railway/railway.ts` must also appear in
that file — secrets as `preserve()` — or `railway config plan` will propose
deleting it. See [DEPLOYMENT.md](DEPLOYMENT.md#keeping-variables-in-sync).

## How environment variables and `openclaw.json` interact

- OpenClaw reads `/data/.openclaw/openclaw.json`. Not every setting has an
  environment variable; use the config file (`openclaw config set …`) for
  everything not listed above.
- Process environment wins over `$OPENCLAW_STATE_DIR/.env` and the config `env`
  block. Railway variables are process environment.
- The baseline config refers to the Gateway token as an env SecretRef
  (`{ "source": "env", "provider": "default", "id": "OPENCLAW_GATEWAY_TOKEN" }`).
  If the variable is missing, auth fails closed; there is no fallback.
- Onboarding with `--secret-input-mode ref` stores provider keys the same way.
  Verified for this template: after onboarding with `ANTHROPIC_API_KEY` and
  adding Telegram with `--use-env`, neither secret value appears anywhere under
  `/data/.openclaw`.
- Command-line flags beat config: the `CMD` pins `--bind lan --auth token`, so
  onboarding or a config edit cannot make the Gateway loopback-only (which would
  break Railway's health check and Tailscale) or unauthenticated.

## What lives on the volume

`OPENCLAW_HOME=/data` relocates every OpenClaw path default, so all durable state
is under `/data/.openclaw` (observed layout after onboarding):

```text
/data/.openclaw/
├── openclaw.json (+ .bak, .last-good)  Gateway, channel, agent, and tool config
├── state/openclaw.sqlite               shared state: device pairing, secrets store, provider auth
├── agents/<agentId>/                   per-agent SQLite (sessions, auth profiles), agent identity
├── workspace/                          default agent workspace: memory files, AGENTS.md, SOUL.md, …
├── plugin-skills/, media/, cache/      installed skills, media, caches
└── tmp/, migration/                    OpenClaw-managed working files
```

OAuth tokens (for OAuth-based providers) are stored in SQLite on this volume in
plaintext. Treat the volume and its backups as credentials.

`HOME` is `/data/home` and Homebrew is `/data/linuxbrew`, both on the volume, so
command-line tools keep their logins, settings, and updates across redeploys. Not persisted: `/tmp`, including
OpenClaw's rolling file log (`/tmp/openclaw/openclaw-<date>.log`; the same
output goes to stdout and Railway's logs).

## Don't set a Start Command

Leave Railway's **Start Command** empty. The image's `CMD` is the stock
foreground Gateway invocation, which OpenClaw's entrypoint recognizes and runs
Doctor migrations before. A different command (even `openclaw gateway`, which
resolves to the CLI wrapper) skips Doctor. The one sanctioned override is
`sleep infinity` for [maintenance](TROUBLESHOOTING.md#exit-code-78).
