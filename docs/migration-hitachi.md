# Migrating from `pve-storage-hitachiblock` to `pve-fclu-hitachi`

The standalone reference plugin (`pve-storage-hitachiblock`) and the FCLU Hitachi
driver (`pve-fclu-hitachi`) both register the **same `type: hitachiblock`** storage, so
your `storage.cfg` keeps working verbatim across the swap. **But the two keep their
volume→LU map in different places and formats**, and they **`Conflict`** (only one can
be installed), so a naïve `apt install pve-fclu-hitachi` would leave the new plugin
seeing **zero volumes** — orphaning every existing disk and breaking any guest that uses
them.

| | reference `pve-storage-hitachiblock` | FCLU `pve-fclu-hitachi` |
|---|---|---|
| registry | `/etc/pve/priv/hitachiblock/<storeid>.json` | `/etc/pve/priv/fclu/<storeid>.json` |
| backend id | `ldev_id` (integer) | `backend_id` (string) |
| device identity | `wwid` (flat NAA) | `identity: {protocol, ids:{naa}}` |
| pool | `pool_id` (int) | `pool_ref` (string) |
| clone `#23` handle | `clone_snapshot_id` / `clone_pvol_ldev` | `clone_backing_snap` / `clone_parent_backend` |
| credentials | `hitachiblock/<storeid>.creds` | `fclu/<storeid>.creds` |

`pve-fclu-migrate-hitachi` bridges the gap. It is **COPY mode**: it reads the legacy
store and writes the FCLU store through the real `FCLU::Registry`/`FCLU::Credentials`
(so the output is guaranteed-correct, atomically written, `0600`), and it **never
deletes or modifies the legacy files** — they remain as a rollback safety net. It is
idempotent (safe to re-run) and translates volumes, linked-clone parentage + the `#23`
backing-pair handles, per-volume `protected`/`notes`, and the snapshot subregistry.

## Why the swap is safe with the right sequence

Two facts make a zero-orphan swap possible:

1. The legacy `/etc/pve/priv/hitachiblock/*.json` files are **runtime data, not package
   files** — removing `pve-storage-hitachiblock` does **not** delete them.
2. The **running `pvedaemon` keeps the old plugin loaded in memory** until it is
   restarted — so between installing FCLU and restarting the daemons, the array keeps
   working under the old code.

So the migration reads the surviving legacy data and populates the FCLU registry
**before** `pvedaemon` reloads with the new plugin.

## Procedure — populate the FCLU registry BEFORE the swap (recommended, zero-window)

The registry lives in the shared pmxcfs (`/etc/pve/priv` is cluster-wide), so the
migration runs **once on one node** and applies cluster-wide. The package swap is
per-node, but because the FCLU registry is already populated first, **node order is
irrelevant** and there is no window in which a node comes up on FCLU with an empty
registry.

```bash
# 0. Record the current state to compare against afterwards.
pvesm list <storeid>            # note the volumes
pvesm status                    # note the storage is 'active'

# 1. From a source checkout (the tool is pure Perl; it needs only the FCLU core
#    modules, so it runs BEFORE pve-fclu-* is installed). Preview, then migrate.
perl -Isrc bin/pve-fclu-migrate-hitachi --dry-run --all
perl -Isrc bin/pve-fclu-migrate-hitachi --all     # copies hitachiblock/ -> fclu/

# 2. Now swap the plugin on each node (order irrelevant — the FCLU registry is ready).
apt install pve-fclu-hitachi                       # pulls pve-fclu-core; removes the reference
systemctl restart pvedaemon pveproxy pvestatd

# 3. Verify parity — the SAME volumes must be listed, storage still active.
pvesm list <storeid>            # same volumes as step 0
pvesm status                    # 'active', capacity sane
qm start <a-test-vmid>          # a guest resolves + boots from its disk
```

### Alternative — install then migrate (only in a strict change window)

If you cannot run the tool from source and must use the packaged binary, install first
(the tool ships in `pve-fclu-hitachi`; the legacy `/etc/pve/priv/hitachiblock/` data
survives the removal and the *already-running* pvedaemon keeps serving from the
in-memory old plugin), then migrate, then restart:

```bash
apt install pve-fclu-hitachi
pve-fclu-migrate-hitachi --dry-run --all && pve-fclu-migrate-hitachi --all
systemctl restart pvedaemon pveproxy pvestatd
```

> ⚠️ **Window hazard.** Once `pve-fclu-hitachi` is installed, *any fresh process* resolves
> `type: hitachiblock` against the still-empty FCLU registry. Between the install and the
> migrate, do **NOT** reboot the node, run backup/HA/replication jobs, or invoke
> `pvesm`/`qm`; an involuntary `pvedaemon`/`pvestatd` restart in that gap makes existing
> volumes unresolvable for *new* operations (already-running VMs keep their mapped
> devices — this is an operation-time outage, not data loss). The recommended
> migrate-from-source-first flow has no such window.

## Rollback

Because the migration never touches the legacy store, rolling back is just reinstalling
the reference package:

```bash
apt install pve-storage-hitachiblock    # Conflicts -> removes pve-fclu-*
systemctl restart pvedaemon pveproxy pvestatd
# the untouched /etc/pve/priv/hitachiblock/ registry is used again
```

The stray `/etc/pve/priv/fclu/<storeid>.json` left behind is inert while the reference
plugin is active; remove it if you like.

## Tool reference

```
pve-fclu-migrate-hitachi [--all] [--dry-run] [--legacy-dir DIR] [--fclu-dir DIR] [<storeid> ...]

  --all             migrate every store found under the legacy directory
  --dry-run         show what would be migrated; write nothing (run this first)
  --legacy-dir DIR  legacy store dir (default /etc/pve/priv/hitachiblock)
  --fclu-dir DIR    FCLU store dir   (default /etc/pve/priv/fclu)
```

It prints a per-store summary (volume count, snapshot count, whether credentials were
copied) and the `volname -> backend_id` map. **Credentials are never printed or logged.**
Exit status is non-zero if any store failed.
