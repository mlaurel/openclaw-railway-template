# Acceptance criteria

Status as of 2026-10-08. Statuses:

- **Verified**: checked on this machine by a repeatable test or command, cited.
- **Live validation required**: depends on a real Railway project, tailnet,
  Mac app, or Telegram bot, none of which has been exercised yet. The local
  evidence that exists is listed.
- **Failed**: none.

Local test suites: `sh tests/image.test.sh` (50 checks, all passing, ≈70 s),
`npm run test:railway-config` (5 tests), `npm run typecheck`,
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
| 6 | Railway manages container restarts | Live validation required | Config: `restartPolicyType: "ALWAYS"` (`tests/railway-config.test.ts`). Locally: a killed Gateway exits the container non-zero; graceful stop exits 0; a Docker `--restart always` container came back after onboarding's restart exit. |
| 7 | Persistent configuration survives redeployment | Live validation required | Locally verified on a Docker volume: config change, pairing, and baseline-not-reapplied all survive stop/start and crash/start. Railway volume behavior not yet exercised. |
| 8 | Gateway authentication is enforced | Verified | `--auth token` pinned; 401 without or with a wrong token from a remote peer; entrypoint refuses missing or short tokens; token-only clients without device identity get no operator scopes. |
| 9 | The Gateway is not publicly exposed by default | Verified (config) / live check pending | `.railway/railway.ts` declares no domains or TCP proxies (tested); `serve.json` has no Funnel (tested). Confirm in the Railway dashboard after deploy. |
| 10 | Tailscale provides authenticated private access | Verified with a real tailnet; Railway network pending | End-to-end test above: tailnet → Tailscale TLS → raw TCP forward → Gateway token auth and device pairing, with Docker DNS standing in for `openclaw.railway.internal`. Railway's own private DNS and dual-stack routing not yet exercised. |
| 11 | Tailscale configuration survives restarts | Verified locally | Recreated the container without `TS_AUTHKEY` on the same state volume: same node, same tailnet IP, no re-authentication. A Railway volume is expected to behave the same; confirm in live step 8. |
| 12 | Proxy attribution is handled securely | Verified | Header-free remote peer with token → 200; same request plus `X-Forwarded-For` or `Tailscale-User-Login` → 403 "Proxy client attribution is required". Repeated through real Tailscale Serve from a tailnet device. `trustedProxies` stays empty. [ARCHITECTURE.md](ARCHITECTURE.md#why-the-proxy-attribution-error-cannot-recur) |
| 13 | The macOS desktop app can connect | Live validation required | Workflow in [DESKTOP.md](DESKTOP.md), from the 2026.9.8 macOS docs. Gateway side tested with a non-loopback client. The app itself not run. |
| 14 | Desktop device pairing works | Live validation required | Tested with a headless node over `wss://` through Tailscale: the request stays pending, `openclaw devices approve` admits it, and pairing survives restarts of both services. Mac app pairing not run. |
| 15 | Telegram integration works | Live validation required | Tested with a dummy token: `TELEGRAM_BOT_TOKEN` enables Telegram with `dmPolicy: pairing` / `groupPolicy: allowlist`, the token never lands on the volume, `channels add --use-env` works, and a bad token makes `/readyz` 503 while `/startupz` stays 200. A real bot DM not yet tried. |
| 16 | Railway health checks reflect actual Gateway availability | Verified locally / live pending | `/startupz` is 200 only after the Gateway admits traffic; it accepts Host `healthcheck.railway.app`; it ignores channel failures by design. Railway's own probe not yet exercised. |
| 17 | Security auditing is documented | Verified | [SECURITY.md](SECURITY.md#security-audit). Tested: fresh boot → only `allowed_origins_required`; after `gateway.publicOrigin` → 0 critical, 0 warn. `--deep` adds upstream `gateway.probe_failed`, also seen on the unmodified official image. |
| 18 | Docker builds are reproducible | Verified | Base images and BuildKit frontend pinned by digest; no package installs at build or run time; npm lockfile; GitHub Actions pinned to commit SHAs. |
| 19 | Version upgrades require one authoritative version change | Verified | The `FROM` line is the only reference; the test derives the expected version from it. Dependabot updates tag and digest together. |
| 20 | CI validates the deployment configuration | Verified | `.github/workflows/ci.yml` passed on GitHub on the first push (run 37742254091: static checks and image build/test both green) and on every push since. actionlint clean. |
| 21 | Backup and rollback procedures are documented | Verified (docs) / restore live pending | [UPGRADING.md](UPGRADING.md). `openclaw backup create --verify` tested against a running Gateway. Railway backup restore not exercised. |
| 22 | The repository can be deployed from GitHub to Railway | Live validation required | `.railway/railway.ts` type-checks and evaluates with `railway@3.13.0`; `railway config plan` against a real project not run. |
| 23 | Suitable for a reusable public Railway template | Live validation required | Template composition documented ([DEPLOYMENT.md](DEPLOYMENT.md#publishing-as-a-railway-template)). MIT licensed (`LICENSE`); public repository. |

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
