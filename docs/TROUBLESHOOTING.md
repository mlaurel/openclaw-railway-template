# Troubleshooting

Start with the logs: `railway logs --service openclaw` and
`railway logs --service tailscale`. Lines from this template's entrypoint start
with `openclaw-railway:`.

## The `openclaw` service won't start

| Log line | Cause | Fix |
| --- | --- | --- |
| `openclaw-railway: OPENCLAW_GATEWAY_TOKEN is not set` (exit 64) | Missing variable. | [DEPLOYMENT.md step 3](DEPLOYMENT.md#3-configure-gateway-authentication). |
| `… must be at least 32 characters` | Weak token. | `openssl rand -hex 32`. |
| `PORT is 8080 but the Gateway listens on 18789` | Railway's `PORT` doesn't match. | Set `PORT=18789` on the service. |
| `the entrypoint must start as root` | `RAILWAY_RUN_UID` or a user override is set. | Remove it. The entrypoint drops to `node` itself. |
| `warning: /data is not a mounted volume` | No volume at `/data`. State will be lost. | Attach the volume at `/data` (`requiredMountPath` normally blocks this deploy). |
| `Doctor could not enter maintenance … failed to acquire gateway state ownership` | Usually a permission problem (it shows up with EACCES on a root-owned volume), or another Gateway really holds the state. | Redeploy: the entrypoint repairs ownership on every start. Never delete lock files. |
| `Gateway start blocked: existing config is missing gateway.mode` (exit 78) | `openclaw.json` was replaced by a config without `gateway.mode`. | In [maintenance mode](#exit-code-78), run `openclaw config set gateway.mode local`, or restore `openclaw.json.last-good` / `.bak` from `/data/.openclaw`. |
| `Config file is not readable by the current process` | A file in the state directory is owned by root. | Redeploy; the entrypoint hands every file back to `node`. Run `openclaw` from `railway ssh` (the wrapper runs it as `node`), not `node /app/openclaw.mjs`. |

### Exit code 78

OpenClaw exits 78 when state can't be migrated safely (conflicting identities,
unreadable data, another writer, or a filesystem missing a required primitive).
The log names the failing check. **Don't delete state, lock, claim, or backup
files to silence it**; they are the recovery inputs.

- After an upgrade: roll back ([UPGRADING.md](UPGRADING.md#rolling-back)).
- To run Doctor by hand: put the service in maintenance mode, which keeps the
  container alive without starting the Gateway. In the dashboard, set the
  `openclaw` service's **Start Command** to `sleep infinity` and clear its
  **Healthcheck Path**, deploy, then:

  ```bash
  railway ssh --service openclaw -- openclaw doctor --fix
  ```

  Restore both settings afterwards. Verified locally: with this image,
  `sleep infinity` runs as `node` through the normal entrypoint and Doctor runs
  from an exec shell. Whether Railway's Start Command replaces only the `CMD`
  (as this assumes) is **live-unverified**.

## `railway config plan` proposes a destructive volume change

`Update <volume> config.region` (or `config.sizeMB`) marked destructive means the
volume's actual placement differs from `region` / `volumeSizeMB` in
`.railway/railway.ts`. Don't apply it: Railway accepts the change and leaves the
volume where it is (observed). Either set the constants to the volume's real
values (`railway config pull --json` shows them), or move the service's region in
the dashboard; the volume migrates with the service on its next deploy. See
[DEPLOYMENT.md](DEPLOYMENT.md#1-create-the-railway-project).

## The deploy health check fails

Railway calls `GET /startupz` on port 18789 with Host `healthcheck.railway.app`
for up to 600 seconds.

- The logs end in Doctor output: migrations are slow or blocked. Wait, or see
  exit 78 above.
- `/startupz` doesn't depend on channels, so a broken Telegram token does not
  fail deploys. `/readyz` does (it returns 503 with an invalid token; observed).
- Because the volume can't be shared between deployments, a failed deploy
  leaves the service down rather than on the previous version.

## The container restarts after a config change

Expected. Some settings (for example `gateway.port`, `browser.enabled`) need a
restart. In external-supervisor mode the Gateway exits cleanly
(`restart mode: full process restart (supervisor restart)`) and Railway's
`ALWAYS` restart policy starts it again. If it does *not* come back, check that
the restart policy is `ALWAYS`, not `ON_FAILURE`.

## Tailscale

| Symptom | Cause | Fix |
| --- | --- | --- |
| `tailscale` deploy unhealthy; log shows `To authenticate, visit:` | Not logged in. | Set `TS_AUTHKEY`, or open the URL. [TAILSCALE.md](TAILSCALE.md#2-authenticate-the-node) |
| Machine is `openclaw-1`, not `openclaw` | Name already taken. | Remove the stale machine, or set `TS_HOSTNAME`. |
| `curl https://openclaw.<tailnet>.ts.net` times out | Access policy doesn't allow your device, or the node is offline. | Check the policy grant and `tailscale ping openclaw`. |
| HTTPS fails but `http://openclaw.<tailnet>.ts.net:18789` works | Tailnet HTTPS certificates not enabled. | Admin console → DNS → HTTPS Certificates. |
| Tailscale log: `localbackend: failed to TCP proxy port … to openclaw.railway.internal:18789` | The Gateway is down, the service isn't named `openclaw`, or the environment is a legacy IPv6-only one. | Check the `openclaw` service; rename it; deploy into an environment created after 2025-10-16. |
| Node logged out after months | Untagged node hit key expiry. | Tag it or disable key expiry. |

## Connecting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `pairing required` / `disconnected (1008)` | New device. | `openclaw devices list`, then `approve <requestId>`. |
| `Proxy client attribution is required …` (403) | Something in front of the Gateway now adds `X-Forwarded-*` or `Tailscale-*` headers, for example `serve.json` changed to an HTTP proxy. | Restore raw TCP forwarding (CI checks this). Don't add `trustedProxies`. |
| Gateway log: `observed unattributable proxy-shaped traffic from <ip>` | A client sent `X-Forwarded-*` or `Tailscale-*` headers. Tailscale's TCP forward passes client headers through unchanged, and the Gateway rejected that request (403). Logged once per process. | Nothing, unless it repeats from clients you don't expect. |
| `missing scope: operator.read` from a remote CLI with `--url` | `--url` connections without a paired device identity get no operator scopes. | Run operator commands through `railway ssh`, or pair the client. |
| Mac app: dashboard works but Mac capabilities offline | The node role or its capabilities aren't approved. | `openclaw devices list` and `openclaw nodes pending`; approve. |
| `Protocol mismatch` in the dashboard after an upgrade | Stale cached UI. | Hard-refresh or clear site data for the dashboard origin. |
| `401 Unauthorized` everywhere | Wrong or rotated token, or too many failures. | Check the token; after 10 failures in a minute, the Tailscale service's IP is locked out for 5 minutes. That affects every tailnet client, because they share it. |

## `railway ssh` commands

- Inside `railway ssh` you're root; `openclaw` runs as `node` automatically.
  Calling `node /app/openclaw.mjs` directly bypasses that and can create
  root-owned files.
- SSH sessions receive the service's Railway variables (verified on a live
  deployment), so the CLI authenticates to the Gateway without extra setup.
- `Host key verification failed`: `ssh.railway.com` isn't in `~/.ssh/known_hosts`.
  See the SSH note under [Prerequisites](DEPLOYMENT.md#prerequisites).
- `No registered SSH keys found`: `railway ssh keys add --key ~/.ssh/id_ed25519.pub`.
  (`railway ssh keys github` can fail with "You do not have access to this
  resource" when Railway's GitHub integration lacks access.)
- `openclaw models status --probe` refuses to run while the Gateway holds the
  state. Test the provider through the Gateway instead:
  `openclaw agent --agent main --message "Reply with exactly: OK"`.
- `openclaw security audit --deep` always reports `gateway.probe_failed (missing
  scope: operator.read)` on 2026.9.8, including on the unmodified upstream image.
  See [SECURITY.md](SECURITY.md#security-audit).
