# Card images and backups out of the ptcgl namespace

Piece 4 of the move to Rainier (PTCGL) as pokemon-api's own data source. The PTCGL mirror is gone, but its namespace still runs the storage two other things depend on. This change gives that storage to its owners and removes the `ptcgl` namespace.

## Today (2026-11-09)

- `ptcgl/rustfs`: one RustFS, 35 GB Longhorn volume `rustfs-data`, 25 GB used.
  - Bucket `ptcgl`, about 24 GB: card images, set art and icons under `decoded/`, the raw PTCGL bundles they are decoded from, and the image manifests. pokemon-api's rainier-sync, baked-assets and API pods read and write it.
  - Bucket `backups`, 1.2 GB: the nightly `db-backup` dumps of every database (14 days) and `ptcgl-final/` (the mirror's last dump, kept on purpose).
- `ptcgl/ptcgl-assets`: nginx serving `/images/` from bucket `ptcgl` for the Cloudflare tunnel route `^/images/` on pokemon-api.thomvandev.in, with `Cache-Control: public, max-age=604800`.
- `ptcgl/ptcgl-storage`: the RustFS console on Tailscale.
- `ptcgl-secret` holds the S3 keys (SOPS `ptcgl.s3_access_key`, `ptcgl.s3_secret_key`); pokemon-api's `api-secret` and db-backup's secret repeat them.
- pokemon-api's create-db init container still creates the `ptcgl` database and grants `ptcgl_reader` on every start, so an empty `ptcgl` database exists again.

## Decisions (agreed 2026-11-09)

- Split by owner: card images and the `/images/` proxy go to the `pokemon-api` namespace; backups get their own store in `db-system`, next to the backup job and Postgres.
- Copy, then switch. The old store stays untouched as the fallback until the user approves its removal. Re-binding the existing volume was rejected: a pruned claim with a Delete reclaim policy would lose the data, with no copy to fall back on.
- Public image URLs stay the same: no cache purge, no database rewrite.
- No new secrets: the new stores reuse the existing SOPS key values under new secret names.

## Design

### New stores

- `pokemon-api/rustfs`: RustFS (same image and settings as today), 35 GB Longhorn volume, bucket `cards`. Its bucket job applies the existing public-read policy on `decoded/*`. The console moves to Tailscale as `pokemon-api-storage`.
- `db-system/rustfs-backups`: RustFS, 5 GB Longhorn volume, bucket `backups`. No console; restores use the aws CLI as today.
- Secrets: `pokemon-api/api-secret` keeps its S3 keys (renamed from `ptcgl-s3-*` to `s3-*`); `db-system` gets the same values for the backup store.

### Copy and check

A one-off Job per bucket runs the aws CLI with `s3 sync` from the old store to the new one, then lists both sides and prints object count and total bytes. The switch happens only when both match. The card copy runs outside the rainier-sync window (02:40 to about 08:00 Amsterdam time), so nothing writes to the old bucket while it runs; a second `sync` right before the switch picks up anything newer.

### Switch

- pokemon-api: `RAINIER_S3_ENDPOINT=http://rustfs.pokemon-api.svc.cluster.local:9000` and `RAINIER_S3_BUCKET=cards` on the API deployment, the rainier-sync CronJob and the baked-assets CronJob, and in the bucket init container.
- `/images/`: the nginx proxy moves to `pokemon-api/card-images`, proxying to `rustfs.pokemon-api.svc:9000/cards/`; the Cloudflare tunnel route `^/images/` points to it. Paths below `/images/` are unchanged.
- db-backup: endpoint `http://rustfs-backups.db-system.svc.cluster.local:9000`; the restore recipe in its header comment follows.
- pokemon-api's create-db init container stops creating the `ptcgl` database and granting `ptcgl_reader`.

### Remove the old store

After one full night on the new stores, with rainier-sync, baked-assets and db-backup all succeeding and images served from `card-images`, the user is asked to approve the removal. Then `app-ptcgl.yaml` is deleted (namespace, RustFS, volume, nginx, console, secret), the empty `ptcgl` database and the `ptcgl_reader` role are dropped, and the `ptcgl.*` SOPS keys can be removed by the user.

## Errors and safety

- Nothing is deleted before the user approves; until then switching back is reverting one homelab commit.
- A copy with a different count or size stops the switch.
- Images keep serving from the old proxy until the tunnel route changes; the route change and the pokemon-api env change ship in one commit.
- Backups for the night of the switch: the backup job writes to whichever store its config names at 03:00; the switch commit lands outside 02:40 to 08:00.

## Testing

- After the copy: counts and bytes per bucket, printed by the copy job.
- After the switch: a card image, a set art image and an icon load through pokemon-api.thomvandev.in with status 200; a pokemon-api build runs; the next nightly rainier-sync, baked-assets and db-backup succeed and write to the new stores (checked by listing the newest objects).
- A restore check: one dump from the new backups store restores into a scratch database.

## Rollout

Homelab only, pushed to main; pokemon-api's code needs no change, since its bucket default is already `cards`.

1. Commit 1: the two new stores and their bucket jobs; copy jobs.
2. Run the copies outside the sync window and compare.
3. Commit 2: the switch (pokemon-api env, card-images proxy, tunnel route, db-backup endpoint, init container cleanup).
4. One night later: checks, then the user approves the removal; commit 3 removes `app-ptcgl.yaml`, and the `ptcgl` database and role are dropped.

## Out of scope

- Splitting raw bundles from decoded images into separate buckets.
- Changing image cache headers or URLs.

## Revision (2026-11-09, during execution)

Longhorn could not schedule the new 35 GB card volume: each worker schedules at most 166 GiB (238 GiB less the 72 GiB reserve, no over-provisioning) and already had 161 GiB scheduled. The user chose to re-attach the existing volume after all, with these safeguards:

- The old PV's reclaim policy is set to Retain and a Longhorn snapshot is taken before anything changes.
- One commit removes the old claim, RustFS and console from `ptcgl` and adds a claim `rustfs-data` in `pokemon-api` bound by `volumeName` to the same PV, with RustFS, the console, the `card-images` proxy and the tunnel route. After Argo prunes the old claim, the PV's `claimRef` is cleared so the new claim binds. Images are down for a few minutes.
- The bucket keeps its name `ptcgl` (renaming needs a copy, and there is no room); `RAINIER_S3_BUCKET` stays `ptcgl`.
- The backups move is unchanged: copy to `db-system/rustfs-backups`, switch db-backup. The old `backups` bucket on the card volume is deleted with the user's approval in the removal step.
