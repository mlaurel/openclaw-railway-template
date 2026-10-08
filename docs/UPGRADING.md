# Upgrading and rolling back

An OpenClaw upgrade is one change: the `FROM` line in `Dockerfile` (tag and
digest). The Gateway never updates itself in place: `OPENCLAW_SUPERVISOR_MODE=external`
makes OpenClaw refuse self-update, and `OPENCLAW_NO_AUTO_UPDATE=1` disables
automatic update checks and applies.

**Merging to `main` deploys.** Railway builds and deploys every push to the
branch it watches. Treat the merge of an upgrade PR as the deploy step below.

## 1. Review the release

- Release notes: <https://github.com/openclaw/openclaw/releases>. The npm
  package carries the same `CHANGELOG.md` and the docs for that exact version:
  `npm pack openclaw@<version> && tar xzf openclaw-<version>.tgz package/CHANGELOG.md package/docs`.
- Look for config migrations, retired keys, database schema changes, Node
  version changes, and anything under "Upgrading very old versions".
- Pick stable releases (`latest`). Avoid `-beta` tags. OpenClaw also publishes
  an `extended-stable` line if you prefer a slower cadence.

## 2. Update the pin

Dependabot opens a PR for new image tags weekly (`.github/dependabot.yml`), and
updates tag and digest together. To do it by hand:

```bash
version=2026.9.9   # example
docker buildx imagetools inspect "ghcr.io/openclaw/openclaw:$version" --format '{{json .Manifest}}' | jq -r .digest
# edit Dockerfile: FROM ghcr.io/openclaw/openclaw:<version>@sha256:<digest>
```

Nothing else references the version.

## 3–4. Build and validate

CI (`.github/workflows/ci.yml`) builds both images and runs `tests/image.test.sh`
against them on every PR. Among other things, it checks that `openclaw --version`
inside the built image equals the `FROM` tag, that a fresh volume boots, that an
existing volume survives a restart, and that auth, attribution, pairing, and the
security audit still behave. Don't merge on red.

To test an upgrade against a copy of real state, restore an OpenClaw backup
archive (step 5) into a local Docker volume and start the new image on it.

## 5. Back up

Two complementary backups; take both before merging an upgrade.

**Railway volume backup** (restorable in place, whole volume): in the dashboard,
`openclaw` service → **Backups** → **Create backup**. Manual backups are limited
to 50% of the volume size; grow the volume first if needed.

**OpenClaw archive** (portable, verified, off-platform):

```bash
railway ssh --service openclaw -- sh -c 'install -d -o node /tmp/openclaw-backup && openclaw backup create --verify --output /tmp/openclaw-backup && ls /tmp/openclaw-backup'
scp <service-instance-id>@ssh.railway.com:/tmp/openclaw-backup/<archive>.tar.gz .
```

(The service instance ID is in the dashboard: ⌘K → **Copy Service Instance
ID**.) `/tmp` is wiped on redeploy, so copy the archive off first. Always pass
`--output`: the default is the current directory, `/app`, which the `node` user
can't write. Archives contain credentials; store them like secrets. Verified
locally while the Gateway was running; SQLite files belonging to the bundled
Codex runtime are archived as raw bytes with a warning.

## 6. Deploy

Merge the PR. On start, OpenClaw's entrypoint runs `openclaw doctor --fix`
under exclusive state ownership before the Gateway starts, which applies config
and database migrations. Before changing a database schema, Doctor saves
`<database>.pre-startup-migration-<id>.bak` copies beside the originals. The
health check allows 600 seconds for this.

If Doctor can't migrate safely, the container exits with code **78** and Railway
keeps restarting it. Don't delete state or lock files; see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md#exit-code-78).

## 7–9. Verify

```bash
railway ssh --service openclaw -- openclaw --version     # the new version
railway ssh --service openclaw -- openclaw health
railway ssh --service openclaw -- openclaw status        # channels, agents
railway ssh --service openclaw -- openclaw security audit --deep
```

- **Desktop:** Mac app → Connection → **Test**. If the dashboard reports a
  protocol mismatch, hard-refresh or clear its site data.
- **Channels:** send a Telegram DM; check `openclaw status` shows Telegram OK.

## Rolling back

**Rolling back the image does not roll back state.** Doctor migrates schemas
forward, and older releases refuse newer database schemas. A rollback is
therefore "old image + the backup taken before the upgrade":

1. Revert the upgrade commit and push. The old image starts and will likely
   refuse the migrated state (exit 78). That's expected, and safer than
   proceeding.
2. **Backups** → choose the pre-upgrade backup → **Restore**. Railway mounts a
   new volume from the backup and keeps the current one unmounted for
   inspection.
3. Review the staged change and **Deploy**. The old image now starts on the old
   state.

Anything written after the backup (conversations, pairings, config changes) is
lost in a rollback; the unmounted volume still has it if you need to recover
something by hand. **(live-unverified: the restore flow follows Railway's backup
docs.)**

Railway's **Rollback** button (redeploy a previous image) is only safe for
releases that did not migrate state; read the release notes first.

## Tailscale upgrades

Dependabot also proposes `tailscale/tailscale` tags for `tailscale/Dockerfile`.
CI re-checks `serve.json` against the new release's types. Node state carries
across versions; roll back by reverting the commit.

## Migrating from the previous deployment

Moving data from the old `arjunkomath/openclaw-railway-template` deployment is a
separate, approved operation and not covered here. Don't point this template at
the old volume.
