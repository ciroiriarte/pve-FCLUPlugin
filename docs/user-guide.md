# PVE FCLU — User & Operator Guide

Vendor-neutral operator documentation for the FCLU framework: install, configure,
and run first-class per-virtual-disk Fibre Channel storage on Proxmox VE. This guide
is **general** — for Hitachi-VSP-specific knobs see
[`driver-hitachi.md`](driver-hitachi.md).

> `ARCHITECTURE.md` is authoritative for the design. This guide describes operator
> behavior and must never contradict it.

## Concept

FCLU provisions **one array LUN per virtual disk** ("first-class logical unit") and
offloads snapshots, copy-on-write linked clones, online resize, per-volume QoS, and
replication to the array. A shared vendor-neutral core (`pve-fclu-core`) does the
orchestration, registry, and host-side FC connector; each array plugs in through a
thin driver package (`pve-fclu-<vendor>`).

## Install & packaging

Packages are published on OBS
(`home:ciriarte:pve-FCLUPlugin/PVE_9`, Debian 13 / Trixie base) in a **multi-binary
layout**:

| Package             | Contents                                                        |
| ------------------- | --------------------------------------------------------------- |
| `pve-fclu-core`     | Vendor-neutral spine + host-side FC multipath connector. `Provides: fclu-driver-api-1`. `Depends: multipath-tools`. |
| `pve-fclu-<vendor>` | One per array family (e.g. `pve-fclu-hitachi`): the driver, its transport, and the `type:`-per-vendor plugin. `Depends: pve-fclu-core (= ${binary:Version})`. |
| `pve-fclu`          | Optional convenience metapackage.                               |

Install the driver package for your array on **every** PVE node; it pulls the core
transitively:

```bash
echo 'deb http://download.opensuse.org/repositories/home:/ciriarte:/pve-FCLUPlugin/PVE_9/ /' \
  > /etc/apt/sources.list.d/pve-fclu.list
curl -fsSL 'https://download.opensuse.org/repositories/home:/ciriarte:/pve-FCLUPlugin/PVE_9/Release.key' \
  | gpg --dearmor > /etc/apt/trusted.gpg.d/home_ciriarte_pve-fclu.gpg
apt update && apt install pve-fclu-hitachi
systemctl restart pvedaemon pvestatd
```

The Hitachi driver package declares `Provides/Replaces/Conflicts:
pve-storage-hitachiblock`, so `apt install pve-fclu-hitachi` performs a **clean
in-place swap** from the legacy single-vendor plugin. If you are swapping an existing
deployment, read [Migration](#migration-from-pve-storage-hitachiblock) FIRST — the
on-disk registry must be migrated before the swap or volumes orphan.

### PVE compatibility

Targets **Proxmox VE 9** (Debian 13 base). The plugin advertises storage APIVER 14
(matching PVE 9.2). An "older storage API" warning at load means the plugin's APIVER
is below the host's — upgrade the package.

## storage.cfg configuration

A store is declared with the vendor's `type:` (e.g. `hitachiblock`). Credentials are
**never** placed in `storage.cfg` — see [Credentials](#credentials). Generic
(core) properties, shared by all drivers:

| Property           | Req.  | Default | Notes |
| ------------------ | ----- | ------- | ----- |
| `mgmt_ip`          | yes (`fixed`) | — | Array control-plane REST endpoint (IP/host). Comma-separated list for management-plane failover. |
| `pool_id`          | yes (`fixed`) | — | Backend pool for volume allocation. |
| `snap_pool_id`     | no    | = `pool_id` | Pool for snapshot/clone allocation. |
| `qos_upper_iops`   | no    | 0 (unlimited) | Default per-volume upper IOPS cap. |
| `qos_upper_mbps`   | no    | 0 (unlimited) | Default per-volume upper throughput cap (MB/s). |
| `qos_lower_iops`   | no    | — | Default per-volume lower IOPS guarantee. |
| `qos_lower_mbps`   | no    | — | Default per-volume lower throughput guarantee (MB/s). |
| `qos_priority`     | no    | — | QoS I/O priority (1=high, 2=medium, 3=low). |
| `tls_verify`       | no    | 0 (off) | Verify the control-plane TLS certificate (off suits self-signed). |
| `tls_ca_file`      | no    | — | CA bundle used when `tls_verify` is on. |
| `lock_timeout`     | no    | 120 | Seconds to wait to **acquire** the per-storage cluster lock for alloc/free/clone. Extends only the wait; pmxcfs still hard-caps the *locked work* at 60s. |
| `device_timeout`   | no    | 120 | Seconds to wait for a freshly mapped LUN's multipath device to appear on this host during activation. Raise for arrays whose LUN presentation is slow under load. |
| `debug`            | no    | 0 | Diagnostic verbosity (0=off .. 3=trace). Credentials are never logged at any level. |

Properties marked `fixed` cannot be changed after the store is created (they identify
the array + pool). Standard PVE properties (`nodes`, `shared`, `disable`, `content`)
are supported.

### Credentials

The array's REST username/password live in the **cluster-private**
`/etc/pve/priv/fclu/<storeid>.json` (mode 0600), written by the plugin's add/update
hooks — not in `storage.cfg`. On store creation the plugin runs a connectivity probe
and **rolls the stored credentials back** if it fails, so a bad password never
persists a half-configured store.

## Multipath (REQUIRED host config)

FCLU resolves each volume by its array NAA at `/dev/mapper/3<naa>`. This depends on a
correct `multipath` configuration on every node.

**The device stanza** must claim the array's products. For Hitachi, match
`product "OPEN-.*"` — not just `"OPEN-V"` — so that **Thin Image v-vols (`OPEN-0V`,
used by snapshots and linked clones)** are claimed too. Recommended stanza settings:
`path_selector "service-time 0"`, `no_path_retry 10`,
`path_grouping_policy group_by_prio`, `prio alua`. (Ref: Red Hat KB 2598221; the
`multipath-tools` built-in hwtable already matches `(HITACHI|HP|HPE) ^OPEN-`, so a
custom stanza is only needed to override tuning.)

**Load-bearing "never add" warnings:**

- **Do NOT enable `user_friendly_names`.** It breaks the plugin's
  `/dev/mapper/3<naa>` device resolution.
- **Do NOT set a `reservation_key` in `multipath.conf`.** It conflicts with
  `qemu-pr-helper`'s per-VM SCSI-3 persistent reservations.

PVE ships `find_multipaths strict`; the plugin whitelists each volume's WWID
(`multipath -a`) on activation so `find_multipaths` is satisfied.

## Multi-cluster / shared array pool safety ⚠️

When two or more PVE clusters carve LUNs out of the **same** array pool, three
independent mechanisms keep them from touching each other's volumes. Configure all
three:

1. **`host_group_prefix` — namespaces host-group names per cluster**
   (`<prefix>_<hostname>`). It defaults to a stable short **`PVE`**, which is
   identical on every cluster and therefore does **not** separate clusters on its own.
   On a shared pool, set an explicit **distinct short** value per cluster.

2. **Disjoint `ldev_range` per cluster is REQUIRED.** The range is both the
   allocation window and the **§7 destructive-op fence**: the plugin refuses to unmap
   or delete any LUN outside its range, so it can never touch a foreign cluster's
   volume that merely shares a target port.

3. **The fail-loud WWN-ownership guard.** Before mapping/unmapping, the plugin does a
   fresh, never-cached read of the target host group's initiator WWNs. If the group
   holds a WWN this node does not own, activation throws a **`conflict`** (fail
   closed) rather than silently merging this node's WWNs into a foreign group. A
   transient read failure yields a retryable `array_busy`, never a false conflict.

**Array-native gold standard:** where the array supports it (e.g. Hitachi **Resource
Groups** with a per-cluster scoped REST account), use it as the hard tenancy
boundary — it is the recommended shared-array deployment. The prefix/range/guard
above remain valid defense-in-depth.

The FCLU **registry** (volname → backend LU map) is cluster-private
(`/etc/pve/priv/fclu/`); volume **labels** on the array are `pve:<storeid-hash>:<vol>`.

## Migration from pve-storage-hitachiblock

Swapping the legacy plugin for `pve-fclu-hitachi` **orphans existing volumes** unless
the on-disk registry is migrated: the legacy plugin stores its volname→LU map at
`/etc/pve/priv/hitachiblock/<storeid>.json`, FCLU reads
`/etc/pve/priv/fclu/<storeid>.json`, and the two packages conflict (cannot coexist).

Use `pve-fclu-migrate-hitachi` (COPY mode — reads the legacy store, writes the FCLU
store, **never touches the legacy data** so it is a rollback net; idempotent). The
supported **zero-window** procedure migrates from the source registry BEFORE the
package swap; an install-then-migrate ordering has an orphan window. Full procedure
and rollback: [`migration-hitachi.md`](migration-hitachi.md).

## Operational behavior & assumptions

- **One array LUN per virtual disk.** Host mapping is **deferred to
  `activate_volume`** (matching LVM/RBD/ZFS), not done at allocation.
- **Identity may be post-publish.** Some arrays only expose a device's NAA after it
  is mapped. A volume that was allocated but never activated has a **null identity**
  in the registry until first activation; path resolution live-resolves it.
- **SCSI-3 persistent reservations are opt-in.** Enable per-store
  `persistent_reservations` and install the `qemu-pr-helper` systemd units (shipped
  **disabled**). The check is validate-and-warn on activation; it never edits
  `multipath.conf` and never blocks.
- **Teardown is host-first.** `deactivate`/`free` flush and remove the host device
  *before* unmapping array-side, so an unmap cannot race in-flight I/O.

## Troubleshooting

| Symptom | Cause & fix |
| ------- | ----------- |
| A clone can't be used as a live disk; no `/dev/mapper` device appears | Multipath is not claiming `OPEN-0V` (TI v-vol). Set the device stanza to `product "OPEN-.*"` and `multipathd reconfigure`. |
| "older storage API" warning at load | The package's APIVER is below the host's — upgrade `pve-fclu-*`. |
| `conflict` thrown on activation | Cross-cluster host-group collision on a shared pool — the group holds a foreign WWN. Set a distinct `host_group_prefix` (and disjoint `ldev_range`) per cluster, or clear the stale WWN. |
| Activation times out waiting for the device under load | Raise `device_timeout`; the connector re-rescans SCSI while it waits. |
| Volume "orphaned" right after a package swap | Registry not migrated — run `pve-fclu-migrate-hitachi` (see [Migration](#migration-from-pve-storage-hitachiblock)). |

## Keeping docs in sync

`ARCHITECTURE.md` is authoritative for design; this guide must not contradict it, and
per `CLAUDE.md` documentation stays in sync with the code. When a property, default,
or behavior changes, update the tables here and in [`driver-hitachi.md`](driver-hitachi.md).
