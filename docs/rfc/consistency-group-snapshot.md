# RFC: optional multi-volume / consistency-group snapshot storage hook

Status: **filed as Proxmox Bugzilla #7812**
(https://bugzilla.proxmox.com/show_bug.cgi?id=7812) — product `pve` / component
`Storage` / enhancement / version 9 (2026-07-12). Next: pve-devel post + patch series.
Companion to the `copy_image` full-clone offload hook (Bugzilla #7780) — same shape of
gap: a backend can do something atomically that the per-volume storage API cannot express.

## Problem

Many block backends can snapshot a *set* of volumes **atomically** — every volume
frozen at the same instant (a crash-consistent point-in-time). Storage arrays call
this a consistency-group / volume-group snapshot; Ceph has `rbd group snap`; LVM/ZFS
can freeze a set together. Proxmox has **no way to ask for it**: the storage plugin
API snapshots **one volume at a time** (`volume_snapshot($scfg,$storeid,$volname,$snap)`),
and `qemu-server`'s VM snapshot loops that call over a VM's disks **sequentially**. So a
multi-disk VM's snapshot is *not* crash-consistent across its disks even when the
backend could trivially make it so — each disk freezes at a different instant, and a
DB whose data and log LUNs are separate disks can restore to a torn state.

## Current behaviour

`PVE::QemuConfig`/`qemu-server` snapshot flow calls `PVE::Storage::volume_snapshot`
per volume. There is no grouping and no hook where a plugin is handed the whole set,
so a plugin **cannot** offer atomicity even internally without breaking PVE's
per-`(volname, snapname)` bookkeeping and per-volume rollback.

## Proposal

An **optional** storage-plugin capability + hook, mirroring the `copy_image` pattern:

1. **Capability / option.** A plugin advertises multi-volume snapshot support (a
   per-storage capability, e.g. `snapshot-group`), analogous to how `copy-offload`
   is being added for #7780.

2. **Hook (base class dies; only reached when advertised).**
   ```
   $plugin->volume_group_snapshot($scfg, $storeid, \@volnames, $snap)
   $plugin->volume_group_snapshot_delete($scfg, $storeid, \@volnames, $snap)
   $plugin->volume_group_snapshot_rollback($scfg, $storeid, \@volnames, $snap)   # optional
   ```
   The plugin owns atomicity and its own cleanup/rollback on partial failure (same
   contract direction agreed for `copy_image`: the plugin undoes its own work; the
   word "atomically" describes the *result the backend guarantees*, not a core
   promise). `@volnames` are all on the SAME storage (see integration).

3. **qemu-server integration.** When snapshotting a VM, group its disks by storeid.
   For a storage advertising the capability, call `volume_group_snapshot` with that
   store's disk set instead of N per-volume calls; for others, keep the existing
   per-volume path. A VM whose disks span several capable stores gets one group
   snapshot per store (each store's set is internally consistent; cross-store
   atomicity is out of scope — no backend spans arrays). Snapshot config/state stays
   keyed by `snapname` exactly as today, so `qm`'s snapshot list/rollback/delete are
   unchanged from the operator's view.

4. **Crash vs application consistency.** Orthogonal and already handled: PVE fs-freezes
   a running VM around snapshots (`QemuServer/BlockJob.pm`); this hook only upgrades the
   *storage-side* freeze from "per disk, staggered" to "all disks, together".

## Why not do it purely in the plugin?

A plugin *could* intercept `volume_snapshot` and fan out to a group, but it breaks
PVE's model: `volume_snapshot` is called once per disk (N× fan-out), the sibling pairs
it creates are not recorded under their own `(volname, snapname)`, and per-volume
delete/rollback then desync. Atomicity has to be expressed at the layer that knows the
whole set — qemu-server — which is exactly what this hook adds.

## Interim (FCLU today)

FCLU ships consistency groups **out-of-band** now: a per-volume `cg` attribute plus a
`pve-fclu-cg` CLI that resolves a group's members and issues one crash-consistent array
snapshot (`create_cg_snapshot`). Per-volume `qm`/`pvesm` snapshots are unaffected. This
covers scripted/operator use; the hook above is what makes a plain `qm snapshot` of a
multi-disk VM automatically crash-consistent.

## Open questions

- Capability granularity: a single `snapshot-group` flag, or classes (atomic vs
  best-effort) as we did for `copy-offload`?
- Rollback: require `volume_group_snapshot_rollback`, or let core fall back to
  per-volume rollback when the backend's group snapshot is just per-volume pairs under
  a shared tag?
- APIVER/APIAGE bump + where the disk-grouping lives in qemu-server's snapshot path.
