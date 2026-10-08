# Security

There are two separate questions:

1. **Infrastructure security**: who can reach the Gateway, and what does the
   container run with? This template answers it, and the image tests check it.
2. **Agent-level authorization**: what can the agent do once a message reaches
   it, and who may send it messages? That is OpenClaw configuration, and it is
   your call. Recommended starting points are below.

A perfectly private Gateway can still be talked into running a harmful command
by a web page or email it reads. Infrastructure controls don't protect against
that; agent policy does.

## Infrastructure controls

| Control | How | Evidence |
| --- | --- | --- |
| No public exposure | No Railway domain or TCP proxy on either service; Tailscale Serve has no Funnel. | `tests/railway-config.test.ts`, `tests/serve-config.test.sh` |
| Tailnet-only access | Gateway reachable only on Railway's private network; only the Tailscale service forwards to it; tailnet policy limits who reaches the Tailscale node. | [TAILSCALE.md](TAILSCALE.md) |
| Gateway authentication | `--auth token` pinned in `CMD`; token ≥ 32 chars enforced by the entrypoint; failed-auth rate limiting in the seed. | `tests/image.test.sh` (401 without/with a wrong token) |
| No proxy-trust shortcuts | `gateway.trustedProxies` empty; no `allowRealIpFallback`, no Host-header origin fallback, no `auth.mode: none`, no `allowTailscale`. Forwarded headers from any peer are rejected. | `tests/image.test.sh` (403 with `X-Forwarded-For` or `Tailscale-User-Login`) |
| No auto-trusted devices | Remote devices must be approved; SSH-verified node auto-approval disabled; no `autoApproveCidrs`. | `tests/image.test.sh` (remote node stays pending) |
| Least privilege | Gateway and all its children run as uid 1000; root is used only by the entrypoint to prepare the volume, then dropped with `setpriv`. No added Linux capabilities on either service. The operator terminal (host shell) is off. | `tests/image.test.sh` (every process uid 1000) |
| Secrets stay out of images and the repo | Dockerfiles declare no `ARG`; secrets are Railway variables (seal them); config refers to them as env SecretRefs; onboarding stores references, not values. | `tests/image.test.sh` (environment and history scans); manual check that no secret value appears under `/data/.openclaw` |
| Secrets stay out of logs and `ps` | The entrypoint never prints the token; the token is never a command-line argument. | `tests/image.test.sh` (token absent from process arguments) |
| No self-update | `OPENCLAW_SUPERVISOR_MODE=external` and `OPENCLAW_NO_AUTO_UPDATE=1`; upgrades only by image change. | [UPGRADING.md](UPGRADING.md) |

Known trade-offs:

- The Tailscale container runs as root in its own container (the official
  image's default) with no extra capabilities and userspace networking.
- Every tailnet client appears to the Gateway as the Tailscale service's private
  IP. Auth rate limiting is shared, and Gateway logs don't show which device
  connected; Tailscale's own logs do.
- The volume holds OAuth tokens (plaintext SQLite), pairing records, and
  conversation history. Railway volume backups contain the same. Limit who has
  access to the Railway project; project members can also `railway ssh` in as
  root.

## Security audit

Run after onboarding, after any config change, and after every upgrade:

```bash
railway ssh --service openclaw -- openclaw security audit --deep
```

Expected result on a correctly deployed template (checked in
`tests/image.test.sh`, deep probe checked manually):

- **0 critical.** Before deployment step 7, `gateway.control_ui.allowed_origins_required`
  is critical; setting `gateway.publicOrigin` clears it.
- **1 warning with `--deep`: `gateway.probe_failed` ("missing scope:
  operator.read").** The deep probe connects without a device identity by
  design, so it gets no operator scopes. The same warning appears on the
  unmodified official 2026.9.8 image; it is not a deployment problem. Plain
  `openclaw security audit` (without `--deep`) has no warnings.

Other useful forms: `openclaw security audit --json` for automation, and
`openclaw security audit --fix` for OpenClaw's narrow safe fixes (file
permissions and open group policies). Triage order and the full check catalog
are in [OpenClaw's audit docs](https://docs.openclaw.ai/gateway/security/running-the-audit).

## Recommended agent policy

A starting point for a personal assistant that reads untrusted content such as
the web, email, and documents. Every key was validated against 2026.9.8 with
`openclaw config set`:

```bash
railway ssh --service openclaw -- openclaw config set --batch-json '[
  {"path":"tools.exec.mode","value":"ask"},
  {"path":"tools.exec.strictInlineEval","value":true},
  {"path":"tools.elevated.enabled","value":false},
  {"path":"tools.agentToAgent.enabled","value":false},
  {"path":"session.dmScope","value":"per-channel-peer"},
  {"path":"browser.enabled","value":false},
  {"path":"gateway.nodes.browser.mode","value":"off"}
]'
railway redeploy --service openclaw --yes   # browser.enabled needs a restart
```

### Shell execution

By default (`tools.exec.mode` unset), the agent may run any shell command in the
Gateway container. There, a command can read the state volume (OAuth tokens,
pairing database, history) and the process environment (provider keys,
`OPENCLAW_GATEWAY_TOKEN`). OpenClaw's tool sandbox needs a Docker or Podman
daemon, which a Railway container doesn't have, so **exec policy is the main
boundary here**:

- `tools.exec.mode: "ask"` runs allowlisted commands and asks you to approve the
  rest (in the Mac app, the dashboard, or Telegram for the command owner).
  `"deny"` blocks host exec entirely; `"full"` is OpenClaw's trusted-operator
  default.
- `tools.exec.strictInlineEval: true` makes `python -c`, `node -e`, and similar
  forms always need approval.
- Keep `tools.elevated.enabled: false`.

### Browser automation

The default image has no Chromium, and browser control acts with whatever
sessions the browser profile holds. Keep `browser.enabled: false` and
`gateway.nodes.browser.mode: "off"` unless you need it. If you do, use the
`-browser` image variant with a dedicated profile, and treat downloads and
page content as untrusted.

### Telegram

Defaults when `TELEGRAM_BOT_TOKEN` is set: `dmPolicy: "pairing"`,
`groupPolicy: "allowlist"` with no groups allowed. For a one-owner bot:

```bash
railway ssh --service openclaw -- openclaw config set channels.telegram.allowFrom '["<your-numeric-user-id>"]'
railway ssh --service openclaw -- openclaw config set channels.telegram.dmPolicy allowlist
# Optional, per group you add the bot to (negative chat ID):
railway ssh --service openclaw -- openclaw config set channels.telegram.groups '{"<group-chat-id>":{"requireMention":true}}'
```

Never use `dmPolicy: "open"` with `allowFrom: ["*"]` on a bot with tools: anyone
who finds the bot's username can command it. Pairing approval grants DM access
only, and the first approved pairing becomes the command owner
(`commands.ownerAllowFrom`), who can approve exec requests and change config.

### Local node permissions (the Mac)

A paired Mac node lets the Gateway invoke commands on your Mac, including
`system.run`, which is remote code execution there. Control it on the Mac in
**Settings → Exec approvals** (security, ask, allowlist). To forbid remote shell
on every node from the Gateway side:

```bash
railway ssh --service openclaw -- openclaw config set gateway.nodes.commands.deny '["system.run"]'
```

Approve node capability requests (`openclaw nodes pending`) deliberately; they
widen what the agent can do on that device.

### Prompt injection

Anything the agent reads can carry instructions: web pages, search results,
emails, documents, attachments, pasted logs. Allowlisting senders doesn't help
against content.

- Use a current, top-tier model for any agent with tools. OpenClaw's own
  guidance is explicit that smaller and older models are much easier to steer.
- Keep `exec` on `ask` (above) for agents that read untrusted content, or route
  that content through a separate reader agent with no tools.
- Keep the hook bypass flags (`allowUnsafeExternalContent`) off.
- Don't put secrets in prompts, workspace files, or memory; they belong in
  Railway variables.

See [OpenClaw's prompt-injection guidance](https://docs.openclaw.ai/gateway/security/prompt-injection).

## Rotating credentials

| Credential | Rotate by | Notes |
| --- | --- | --- |
| Gateway token | Set a new `OPENCLAW_GATEWAY_TOKEN` (deployment step 3; Railway redeploys), then update each client. | Paired devices also hold per-device tokens that a shared-token rotation does not revoke. To cut a device off, `openclaw devices revoke --device <id> --role <role>`. |
| Provider key | Set the new value on the Railway variable; revoke the old key at the provider. | Onboarding stored a reference, so no OpenClaw change is needed. |
| Telegram bot token | `/revoke` in @BotFather, set the new `TELEGRAM_BOT_TOKEN`. | |
| Tailscale node | [TAILSCALE.md](TAILSCALE.md#operations) | |

## If something is compromised

1. Remove the `openclaw` machine from the tailnet (admin console) to cut all
   access immediately.
2. Rotate the Gateway token and revoke every paired device:
   `openclaw devices list`, then `openclaw devices revoke …`.
3. Rotate provider keys and the Telegram bot token.
4. Review `openclaw security audit --deep` and recent sessions before re-adding
   the Tailscale node.
