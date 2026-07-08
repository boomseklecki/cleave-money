# Disaster Recovery

How to restore Cleave after data loss, and the two secrets you MUST keep off-host or the restore is
only partial.

## What a backup contains (and what it deliberately does NOT)

A backup - local (`backups` bucket) or off-device (restic) - is a full snapshot: a Postgres custom-format
dump (`database.dump`) plus every receipt object.

It does **NOT** contain `ENCRYPTION_KEYS`. Only `plaid_items.access_token` and
`splitwise_tokens.access_token` are encrypted at rest (Fernet, keyed by `ENCRYPTION_KEYS`). The dump holds
the **ciphertext**; the key never touches the database or the backup. This is intentional - a stolen backup
must not also carry the key that unlocks the tokens.

## The two secrets to escrow off-host

Store both, separately from the server, somewhere you will still have after losing the host (a password
manager / offline vault). Without them a restore is incomplete:

| Secret | Lives in | If lost |
| --- | --- | --- |
| `ENCRYPTION_KEYS` | `.env` (env var) | All non-token data restores fine, but Plaid/Splitwise access tokens are **permanently undecryptable** - every user must re-link their banks and re-authorize Splitwise. No other data is lost. |
| `RESTIC_PASSWORD` | `.env` (env var) | The **off-device restic repo cannot be opened at all** - that entire tier is unrecoverable. (The local `backups` bucket is unaffected.) |

The app warns at startup (`ENCRYPTION_KEYS cannot decrypt ... stored token(s)`) if it comes up with a DB whose
tokens don't match the configured key - i.e. you restored without the right `ENCRYPTION_KEYS`.

## Restore procedure

### From a local backup (same or rebuilt host, MinIO intact)
Use the admin API/app: `POST /backups/{name}/restore`. It takes a `pre-restore` safety backup first, then
`pg_restore --clean --single-transaction` + re-uploads receipts. Ensure `.env` has the **original**
`ENCRYPTION_KEYS` before restoring, or tokens won't decrypt.

### From the off-device restic repo (host lost - full rebuild)
1. Stand up the stack (Postgres + MinIO + api) and put the **original** `ENCRYPTION_KEYS` and the
   `RESTIC_PASSWORD` + remote credentials into `.env`. Set the same `offsite_backup_target` you used.
2. Pull the latest snapshot out of the repo (run inside the `api` container, which has `restic`):
   ```sh
   export RESTIC_REPOSITORY="<your offsite_backup_target>"   # e.g. s3:s3.amazonaws.com/bucket/path
   restic snapshots                       # find the snapshot ID to restore
   restic restore latest --target /tmp/dr # yields /tmp/dr/.../database.dump + receipts/
   ```
   For an `rclone:` target, `rclone` is also in the image and restic invokes it automatically. For an
   `sftp:` target, the rebuilt host also needs the SSH material back in `./secrets/ssh` (key + `known_hosts` +
   `config`) - see the setup section below; restore is otherwise identical.
3. Restore the database from the recovered dump:
   ```sh
   pg_restore --clean --if-exists --no-owner --single-transaction -d "<libpq DSN>" /tmp/dr/.../database.dump
   ```
4. Re-upload the recovered `receipts/` tree into the receipts bucket (or drop it in via MinIO).
5. `alembic upgrade head` (no-op if the dump is already at head), then start the api and confirm no
   `ENCRYPTION_KEYS` drift warning in the logs.

## Configuring an SFTP / Synology off-device target (restic native)

restic's `sftp:` backend backs up over SFTP-over-SSH with **SSH-key** auth (no password, no extra env). The
image ships `openssh-client`, and the `api` service mounts `./secrets/ssh` read-only at `/root/.ssh`. Set it
up on the host (all secrets stay on-host):

```sh
# On the host, in the compose project dir:
mkdir -p secrets/ssh && chmod 700 secrets/ssh
ssh-keygen -t ed25519 -N '' -C cleave-backup -f secrets/ssh/id_ed25519   # 0600 key + .pub alongside
ssh-keyscan -p <port> <synology-host> > secrets/ssh/known_hosts             # then VERIFY the fingerprint
cat > secrets/ssh/config <<'EOF'
Host synology
  HostName <synology-lan-ip>
  User <backup-user>
  Port <22-or-custom>
  IdentityFile /root/.ssh/id_ed25519    # in-CONTAINER path - config is read inside the api container
  IdentitiesOnly yes
EOF
chown -R 0:0 secrets/ssh    # OpenSSH refuses a key not owned by the running user (the container runs as root)
```

On the **Synology (DSM):** Control Panel → File Services → FTP → enable **SFTP**; add `id_ed25519.pub` to the
backup user's `~/.ssh/authorized_keys` and give that user **read access to the `homes` share** plus RW on the
target shared folder. Synology is strict about perms - and beyond the mode bits, a Synology **ACL** on the home
(shown as a trailing `+` in `ls -ld`) can still make it group/writable and get the key **silently rejected by
StrictModes**. Required end state (as root on the NAS):
```sh
chmod go-w /var/services/homes/<backup-user>              # clears the ACL-driven group-write (the usual culprit)
chmod 700  /var/services/homes/<backup-user>/.ssh
chmod 600  /var/services/homes/<backup-user>/.ssh/authorized_keys
chown -R <backup-user> /var/services/homes/<backup-user>/.ssh
# "Enable user home service" must be on (Control Panel → User & Group → Advanced). Verify the authorized key:
ssh-keygen -lf /var/services/homes/<backup-user>/.ssh/authorized_keys   # fingerprint must match id_ed25519.pub
```

Then set `RESTIC_PASSWORD` in `.env`, rebuild the `api` image, and in **Settings → Server Settings** set the
target and enable the tier. **Two Synology-specific gotchas (learned in the live setup):**
- **The path is relative to the SFTP chroot, NOT the NAS absolute path.** The DSM SFTP account is chrooted, so
  a share created at `/volume2/cleave-backup` appears over SFTP as **`/cleave-backup`**. The working
  target is `offsite_backup_target = sftp:synology:/cleave-backup` (verify with `sftp synology` → `ls` from
  inside the container). First push runs `restic init` automatically.
- **The DSM backup account is SFTP-only** (`ForceCommand internal-sftp`), so `ssh synology true` returns
  non-zero even when key auth succeeds - don't use it as the health check. Confirm with the SFTP subsystem
  instead (see the verify command below); `ssh -vv synology` will still log `Authenticated ... using publickey`.
- **HostName must be a LAN IP, not the `.local` mDNS name** - the slim api container has no mDNS resolver, so
  put the resolved IP (e.g. `192.168.1.50`) in the ssh `config` and give the Synology a DHCP reservation.

## Verifying the off-device tier is healthy
- Admin app: Settings → Server Settings → Off-device backup shows the last run + `ok`/`error`.
- API: `GET /backups/offsite` returns `{enabled, target, last_run_at, last_status}` (no secrets).
- Manual push: `POST /backups/offsite`. Integrity check inside the container: `restic check`.
- SFTP key/connectivity check inside the container: `ssh synology -s sftp </dev/null` (no password prompt).
