# OpenClaw on Railway

A minimal Railway deployment of the [OpenClaw](https://openclaw.ai) Gateway,
reachable only through Tailscale.

- **OpenClaw 2026.9.8**, the official image pinned by digest. One `FROM` line is
  the only version reference.
- **The Gateway is the process.** No setup server, reverse proxy, or supervisor.
  A 45-line entrypoint prepares the volume and drops root before OpenClaw's
  own startup runs.
- **Private by default.** No Railway domain. A separate Tailscale service
  forwards raw TCP from your tailnet to the Gateway over Railway's private
  network, so no forwarded headers exist to trust or spoof, and OpenClaw's
  proxy-attribution check stays fully on.
- **All state on one volume** at `/data/.openclaw`, migrated by OpenClaw's own
  Doctor on every start.

```text
Mac app / browser / phone ──Tailscale──► tailscale service ──private network──► openclaw service ──► /data volume
                                         (raw TCP :443/:18789)                   (Gateway :18789)
```

## Deploy

[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) takes a fork to a working Gateway in
12 steps: create the project, set the Gateway token, onboard a model provider,
join your tailnet, pair the Mac app, connect Telegram, audit.

## Documentation

| | |
| --- | --- |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Design, access options compared, why proxy attribution can't fail, what Railway owns |
| [DEPLOYMENT.md](docs/DEPLOYMENT.md) | Step-by-step deployment and onboarding; publishing as a Railway template |
| [CONFIGURATION.md](docs/CONFIGURATION.md) | Every variable and setting, build-time vs runtime, what lives on the volume |
| [TAILSCALE.md](docs/TAILSCALE.md) | Access policy, auth keys, tags, key expiry, rotation |
| [DESKTOP.md](docs/DESKTOP.md) | Connecting and pairing the macOS app |
| [SECURITY.md](docs/SECURITY.md) | Infrastructure controls, the security audit, recommended agent policy |
| [UPGRADING.md](docs/UPGRADING.md) | Upgrades, backups, rollbacks |
| [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Symptoms and fixes |
| [ACCEPTANCE_CRITERIA.md](docs/ACCEPTANCE_CRITERIA.md) | What is verified, what still needs a live deployment |

## Repository

```text
Dockerfile                     OpenClaw image: official base + entrypoint + seed config
scripts/entrypoint.sh          Volume preparation, environment checks, privilege drop
scripts/openclaw-as-node.sh    Runs the CLI as `node` from root `railway ssh` shells
config/openclaw.seed.json      Baseline config, written on first boot only
tailscale/Dockerfile           Official Tailscale image + Serve config
tailscale/serve.json           Raw TCP forwards to openclaw.railway.internal:18789
.railway/railway.ts            Railway Infrastructure as Code: two services, two volumes
.env.example                   Runtime variables for both services (documentation only)
tests/                         Image integration tests, IaC tests, Serve config check
.github/                       CI and Dependabot
```

## Test

```bash
npm ci
npm run typecheck && npm run test:railway-config
sh tests/serve-config.test.sh     # Docker
sh tests/image.test.sh            # Docker; builds and exercises both images
```
