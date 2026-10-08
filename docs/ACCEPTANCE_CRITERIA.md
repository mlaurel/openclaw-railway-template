# Acceptance criteria

Status as of 2026-10-08. Statuses:

- **Verified**: checked on this machine by a repeatable test or command, cited.
- **Live validation required**: depends on a real Railway project, tailnet,
  Mac app, or Telegram bot, none of which has been exercised yet. The local
  evidence that exists is listed.
- **Failed**: none.

Local test suites: `sh tests/image.test.sh` (52 checks, all passing, ≈75 s),
`npm run test:railway-config` (6 tests), `npm run typecheck`,
`sh tests/serve-config.test.sh`, ShellCheck, Hadolint, and actionlint. A
mutation run (rate limit removed from the seed, ownership repair removed from
the entrypoint) failed exactly the three related checks.

**Tailscale end-to-end test (2026-10-08).** The real images ran on a Docker
network that stood in for Railway's private network: the Gateway container had
the network alias `openclaw.railway.internal`, so the committed `serve.json` was
used unchanged. The Tailscale container joined a real tailnet with an auth key
(as `openclaw-e2e-test`), and a Mac on that tailnet was the client. Results:

- Both routes served `/healthz` from the Mac:
  `https://openclaw-e2e-test.<tailnet>.ts.net` (Let's Encrypt certificate for the
  MagicDNS name, verified by macOS trust) and `http://…:18789`.
- Over the tailnet: 401 without a token or with a wrong one, 200 with the token,
  and 403 when the client itself added `X-Forwarded-For`. Raw TCP forwarding
  passes such headers through, and the Gateway rejects them. The Gateway
  attributed traffic to the Tailscale container's private IP.
- A headless node connected over `wss://…:443`, waited in `devices list`, and
  connected once approved.
- The Tailscale container was deleted and recreated **without** `TS_AUTHKEY`,
  and the Gateway was restarted. The node came back with the same name and
  tailnet IP and no login URL (`authURL=false`). The paired node reconnected
  with 0 pending requests.

| # | Criterion | Status | Evidence |
| --- | --- | --- | --- |
| 1 | OpenClaw is explicitly pinned | Verified | `Dockerfile` `FROM ghcr.io/openclaw/openclaw:2026.9.8@sha256:d0de…`; test "installed OpenClaw (2026.9.8) matches the Dockerfile pin". Pinned to **2026.9.8**, not the brief's 2026.9.7, at the owner's direction (2026.9.8 is the current `latest`, a reliability-only hotfix). |
| 2 | The Gateway is the primary application process | Verified | Process tree: `tini` (PID 1) → `openclaw-gateway`, both uid 1000; the entrypoint `exec`s away. Tests "tini is PID 1", "every container process runs as uid 1000". |
| 3 | No custom setup HTTP server | Verified | Repository contains no server code; onboarding is OpenClaw's own CLI ([DEPLOYMENT.md](DEPLOYMENT.md) step 5, run locally). |
| 4 | No unnecessary reverse proxy | Verified | The only hop is Tailscale Serve raw TCP forwarding; `tests/serve-config.test.sh` fails if `serve.json` defines HTTP handlers. |
| 5 | No custom process supervisor | Verified | Only upstream `tini`; restarts are Railway's. External-supervisor mode confirmed: the Gateway exits 0 for restarts ("full process restart (supervisor restart)"). |
| 6 | Railway manages container restarts | Verified (live) | Live: after onboarding changed `gateway.port`, the Gateway exited cleanly ("full process restart (supervisor restart)") and Railway restarted it, listening again 28 s later. Config: `restartPolicyType: "ALWAYS"`. Crash restart (`pkill -KILL`) verified locally; not yet repeated live. |
| 7 | Persistent configuration survives redeployment | Verified (live) | Live: state on the `openclaw-state` volume survived a redeploy *and* a volume migration from `europe-west4` to `us-west2`; the baseline config was not rewritten. Pairing persistence verified locally and over a real tailnet. |
| 8 | Gateway authentication is enforced | Verified | `--auth token` pinned; 401 without or with a wrong token from a remote peer; entrypoint refuses missing or short tokens; token-only clients without device identity get no operator scopes. |
| 9 | The Gateway is not publicly exposed by default | Verified (config) / live check pending | `.railway/railway.ts` declares no domains or TCP proxies (tested); `serve.json` has no Funnel (tested). Confirm in the Railway dashboard after deploy. |
| 10 | Tailscale provides authenticated private access | Verified (live) | Live: the `tailscale` service joined the tailnet; from a tailnet Mac, `https://openclaw.<tailnet>.ts.net` (Let's Encrypt, trusted) and `:18789` reached the Gateway over Railway's private network; 401 without token, 200 with, 403 with a client-added `X-Forwarded-For`. Gateway logs show the peer as the Tailscale service's private IPv4 with `fwd=n/a`. |
| 11 | Tailscale configuration survives restarts | Verified (live) | Live: the `tailscale` service was rebuilt and redeployed (new root directory and health port) and came back as the same machine with the same tailnet IP, without a new key. Locally: recreated without `TS_AUTHKEY`, same identity. |
| 12 | Proxy attribution is handled securely | Verified | Header-free remote peer with token → 200; same request plus `X-Forwarded-For` or `Tailscale-User-Login` → 403 "Proxy client attribution is required". Repeated through real Tailscale Serve from a tailnet device. `trustedProxies` stays empty. [ARCHITECTURE.md](ARCHITECTURE.md#why-the-proxy-attribution-error-cannot-recur) |
| 13 | The macOS desktop app can connect | Verified (live) | `openclaw-mac primary set --direct-url wss://openclaw.<tailnet>.ts.net --token-stdin`; after pairing approval the app reports `connected` (Gateway 2026.9.8) and uses chat, sessions, and models over the connection. |
| 14 | Desktop device pairing works | Verified (live) | The Mac filed separate operator and node pairing requests from the Tailscale service's private IP; both stayed pending until `openclaw devices approve` over `railway ssh`, then connected. The node capability surface is a separate approval. |
| 15 | Telegram integration works | Live validation required | Tested with a dummy token: `TELEGRAM_BOT_TOKEN` enables Telegram with `dmPolicy: pairing` / `groupPolicy: allowlist`, the token never lands on the volume, `channels add --use-env` works, and a bad token makes `/readyz` 503 while `/startupz` stays 200. A real bot DM not yet tried. |
| 16 | Railway health checks reflect actual Gateway availability | Verified (live) | Railway marked every Gateway deploy SUCCESS only after `/startupz` returned 200 (including after migration). A token-less first deploy never became healthy and was replaced. `/startupz` ignores channel failures by design. |
| 17 | Security auditing is documented | Verified (live) | [SECURITY.md](SECURITY.md#security-audit). A fresh deployment audits clean (0 critical, 0 warn) because `gateway.publicOrigin` comes from `OPENCLAW_PUBLIC_ORIGIN`; tested in `tests/image.test.sh` and on Railway. `--deep` adds upstream `gateway.probe_failed`, also seen on the unmodified official image. |
| 18 | Docker builds are reproducible | Verified | Base images and BuildKit frontend pinned by digest; no package installs at build or run time; npm lockfile; GitHub Actions pinned to commit SHAs. |
| 19 | Version upgrades require one authoritative version change | Verified | The `FROM` line is the only reference; the test derives the expected version from it. Dependabot updates tag and digest together. |
| 20 | CI validates the deployment configuration | Verified | `.github/workflows/ci.yml` passed on GitHub on the first push (run 37742254091: static checks and image build/test both green) and on every push since. actionlint clean. |
| 21 | Backup and rollback procedures are documented | Verified (docs) / restore live pending | [UPGRADING.md](UPGRADING.md). `openclaw backup create --verify` tested against a running Gateway. Railway backup restore not exercised. |
| 22 | The repository can be deployed from GitHub to Railway | Verified (live) | `railway config plan` / `apply` with `.railway/railway.ts` created both services and volumes from `stevekinney/openclaw-railway-template@main`; both images built on Railway; the Gateway answered a real agent message through Anthropic. |
| 23 | Suitable for a reusable public Railway template | Verified (live) | MIT licensed, public repository. The template is generated from a sanitized source project, contains no secrets, generates the Gateway token, asks only for `OPENCLAW_PUBLIC_ORIGIN` and `TS_AUTHKEY`, and deployed into a fresh project with `openclaw` healthy. See [DEPLOYMENT.md](DEPLOYMENT.md#maintaining-the-railway-template). |

## Live deployment (2026-10-08)

Project `openclaw`, environment `production`, region `us-west2`. Done so far:

- Steps 1–3 of the plan below: plan showed exactly two services and two volumes
  with no domains; the Gateway deploy turned healthy (≈200 s, mostly pulling the
  base image). The volume mounted root-owned and the entrypoint prepared it
  without errors.
- Step 2: `railway ssh` reaches the domainless service once an SSH key is
  registered and `ssh.railway.com`'s host key is trusted. SSH sessions run as
  root and **do** receive the service's Railway variables.
- Step 3: onboarding with Anthropic succeeded; the Gateway restarted itself
  through Railway; `openclaw agent --message` returned a model reply.
- Found and fixed in `railway.ts`: undeclared volume region/size produced
  destructive-looking plans, and `apply` cannot move a volume's region; the
  service region must change instead (see TROUBLESHOOTING.md).

- Step 4: Tailscale on Railway joined the tailnet and served both routes; the
  live security audit after setting `gateway.publicOrigin`: 0 critical, 0 warn
  (`--deep` adds only the known upstream `gateway.probe_failed`).
- Step 5: the macOS app connected as primary over `wss://` and was paired.

- Tailscale persistence: the `tailscale` service was rebuilt and redeployed and
  kept its machine name and tailnet IP.
- Template: generated from a separate source project and deployed into a fresh
  project; `openclaw` turned healthy with a generated token and no `PORT`
  variable.

- Performance: Railway's 1316-byte network MTU dropped full-size Tailscale
  packets (0.6–1.7 s TLS handshakes, ~10 KB/s). Setting `TS_DEBUG_MTU=1236`
  brought handshakes to 65–75 ms and a 20 KB page to 0.25 s, over both the
  tailnet's IPv4 and IPv6 addresses.

Remaining: Telegram with a real bot, crash and backup drills.

## Live validation plan

Run in a new Railway project, in order. Each step lists what to record.

1. **Deploy** ([DEPLOYMENT.md](DEPLOYMENT.md) steps 1–3). Record: `railway config plan` output (two services, two volumes, no domains); first `openclaw` deploy turns healthy; time to healthy.
2. **SSH environment.** `railway ssh --service openclaw -- sh -c 'id -un; echo ${OPENCLAW_GATEWAY_TOKEN:+token-present}; openclaw health'`. Record that `railway ssh` reaches a service with no domain, and whether Railway variables are visible in SSH sessions (affects the troubleshooting note).
3. **Onboarding** (steps 4–6). Record: the container restarts once by itself and returns healthy.
4. **Tailscale** (step 7). Record: machine `openclaw` with tag `tag:openclaw`; `curl` to both URLs from an allowed device succeeds and from a disallowed device times out; `tailscale` logs show no `failed to TCP proxy`.
5. **Mac app** (steps 8–9). Record: Test succeeds over `wss://`; pairing requests appear and approve; Mac capabilities online.
6. **Telegram** (step 10). Record: pairing code, approval, agent reply.
7. **Audit** (step 11). Record: `openclaw security audit --deep` summary.
8. **Persistence and restarts.** `railway redeploy --service openclaw --yes` and `railway redeploy --service tailscale --yes`. Record: no new pairing requests, same Tailscale machine, no new auth key consumed, Telegram still answers.
9. **Crash recovery.** `railway ssh --service openclaw -- pkill -KILL -f openclaw-gateway`. Record: Railway restarts the container and it returns healthy.
10. **Backup and restore drill.** Create a Railway backup, change a config value, restore, deploy. Record: the value is back.
11. **First CI run.** Push to GitHub and confirm both CI jobs pass. The OpenClaw base image is ≈5 GB unpacked; if the runner runs out of disk, add a disk-cleanup step before the image job.
12. **Upgrade drill.** When the next OpenClaw release ships, follow [UPGRADING.md](UPGRADING.md) end to end.
