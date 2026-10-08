# Tools for skills

Several bundled OpenClaw skills drive command-line tools. The image includes the
ones that make sense on a server as a pinned, checksum-verified **baseline**, so
a fresh deploy works immediately. Every one of them can then be updated on the
volume, where updates persist ([below](#keeping-tools-current)):

| Tool | Version | Used by | Source |
| --- | --- | --- | --- |
| `gh` | 2.102.0 | GitHub connections, `github`, `gh-issues` | GitHub release, `Dockerfile` |
| `gog` | 0.43.0 | `gog` (Gmail, Calendar, Drive, Contacts, Sheets, Docs) | GitHub release, `Dockerfile` |
| `claude` | 2.1.285 | `coding-agent` | npm, `tools/package-lock.json` |
| `codex` | follows OpenClaw (0.158.0 in 2026.9.8) | `coding-agent` | already in the OpenClaw image |
| `jq`, `tmux` | Debian stable | `trello`, `tmux` | apt, `Dockerfile` |

Skills for macOS (Apple Notes, Reminders, Bear, Things, Peekaboo) run on your
Mac through the paired app, not here. Skills for devices on your home network
(Sonos, Hue, cameras, Eight Sleep, local Spotify) can't reach it from Railway.

## Logins persist

`HOME` is `/data/home`, on the volume, so anything a tool stores under `~`
(Google tokens, Claude Code and Codex sessions, tool settings) survives
redeploys. Back it up with the rest of the volume.

`railway ssh` gives you a root shell. Run tool commands with `as-node` so their
files belong to the Gateway's user; the agent can't read root-owned files. (The
container hands stray root-owned files back to `node` on every start, but only
then.)

```bash
railway ssh --service openclaw -- as-node gog auth list
```

For an interactive login, open a shell first, then use `as-node` inside it:

```bash
railway ssh --service openclaw
as-node claude auth login
```

## Google (`gog`)

`gog` needs your own Google OAuth client and a password for its token file.
**(live-unverified:** these steps follow the gog skill's instructions for
headless hosts; the flow has not been run against this deployment yet.)

1. In Google Cloud Console, create an OAuth client of type **Desktop app**, enable
   the APIs you want (Gmail, Calendar, Drive, …), and download its JSON.
2. Give the token file a password, stored as a sealed Railway variable:

   ```bash
   openssl rand -hex 32 | tr -d '\n' | railway variable set GOG_KEYRING_PASSWORD --stdin --service openclaw
   ```

   (`GOG_KEYRING_PASSWORD` is already declared in `.railway/railway.ts`.)
3. Copy the client JSON onto the volume. The service has no domain, so use its
   instance ID (dashboard → ⌘K → **Copy Service Instance ID**):

   ```bash
   scp client_secret.json <service-instance-id>@ssh.railway.com:/data/home/gog-client.json
   ```

4. Configure `gog` and start the remote authorization:

   ```bash
   railway ssh --service openclaw -- as-node gog auth keyring file
   railway ssh --service openclaw -- as-node gog auth credentials /data/home/gog-client.json
   railway ssh --service openclaw -- as-node gog auth add you@gmail.com \
     --services gmail,calendar,drive,contacts,docs,sheets --remote --step 1
   ```

5. Open the printed `auth_url`, approve, and copy the URL your browser ends on
   (a failed `localhost` page is expected). Finish in a shell, not in chat:

   ```bash
   railway ssh --service openclaw -- as-node gog auth add you@gmail.com \
     --services gmail,calendar,drive,contacts,docs,sheets --remote --step 2 --auth-url '<the localhost URL>'
   railway ssh --service openclaw -- as-node gog auth list --check
   ```

Never paste the callback URL, client secret, or tokens into a chat with the
agent.

## Coding agents (`claude`, `codex`)

`claude` uses `ANTHROPIC_API_KEY` from the service's variables when it's set,
so the `coding-agent` skill works with the key you onboarded with. To use a
Claude subscription instead, run `as-node claude auth login` in a `railway ssh`
shell. `codex` uses `OPENAI_API_KEY` when set, or `as-node codex login`.
The image's copy is the pinned baseline; `as-node claude install stable` adds a
self-updating copy on the volume ([below](#keeping-tools-current)).

## Keeping tools current

Tools resolve in this order (first match wins):

1. `/usr/local/sbin`: the `openclaw` and `brew` wrappers. The OpenClaw CLI always
   matches the running Gateway; it can't be shadowed or self-updated.
2. `~/.local/bin` on the volume: Claude Code's native install, `npm install -g`.
3. Homebrew on the volume (`/home/linuxbrew/.linuxbrew` → `/data/linuxbrew`).
4. The image's baseline.

So an update you install on the volume takes over from the image's copy and
survives redeploys:

| Tool | Update it with | Then |
| --- | --- | --- |
| Claude Code | `as-node claude install stable` (or `latest`) | updates itself |
| Codex | `as-node npm install -g @openai/codex@latest` | rerun to update, or follow Codex's own prompt |
| `gh`, `gog`, `jq`, `tmux` | `brew install gh gogcli jq tmux` | `brew upgrade` |
| anything else | `brew install <formula>`, `as-node npm install -g <package>` | `brew upgrade`, `npm update -g` |

Run these through `railway ssh --service openclaw -- …`; `brew` already runs as
`node` without `as-node`. Homebrew pours prebuilt bottles (verified for
`gogcli`). Some formulae also pull Homebrew's own glibc and libraries, a few
hundred MB on the volume the first time. Homebrew updates its formula list
when you install; `HOMEBREW_CACHE` is in `/tmp`, so downloads don't fill the
volume.

**What this layer gives up.** Tools on the volume aren't pinned: they change when
you or the agent update them, not through a reviewed PR, and rolling back the
image doesn't roll them back. To return to the baseline, remove the override:
`as-node rm ~/.local/bin/claude`, `brew uninstall <formula>`, or
`as-node npm uninstall -g <package>`. The agent can use the same commands, so
it can install software too ([SECURITY.md](SECURITY.md#tools-in-the-image)).

## Changing the image's baseline

- **Pinned release binaries** (`gh`, `gog`): change the version and both
  checksums (amd64, arm64) in the `Dockerfile` `RUN` step, copying the checksums
  from the release's checksum file. The build fails on a mismatch.
- **npm tools**: add them to `tools/package.json` and run
  `npm install --package-lock-only` in `tools/`. Dependabot proposes updates.
  A package whose install script must run also needs an `allowScripts` entry
  (npm 12 blocks dependency scripts by default).
- **Debian packages**: add them to the `apt-get install` line.

Add a `--version` check for the new tool to `tests/image.test.sh`.

Each tool the agent can run widens what a prompt-injected agent could do with
it; see [SECURITY.md](SECURITY.md#tools-in-the-image).
