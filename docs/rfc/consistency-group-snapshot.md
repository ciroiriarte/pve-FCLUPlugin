# RFC: optional multi-volume / consistency-group snapshot storage hook

Status: **filed as Proxmox Bugzilla #7812**
(https://bugzilla.proxmox.com/show_bug.cgi?id=7812) — product `pve` / component
`Storage` / enhancement / version 9 (2026-07-12). Companion to the `copy_image`
full-clone offload hook (Bugzilla #7780).

**The original framing of this RFC was wrong and has been corrected** — see below.
Fabian Grünbichler's reply on #7812 (comment #2) refuted the premise it was built on,
and directed the discussion to pve-devel (comment #1). Next: pve-devel post.

## Correction: PVE snapshots are already crash-consistent

The first version of this document claimed that a multi-disk VM snapshot is not
crash-consistent, and that a database with data and log on separate disks could restore
to a torn state. **That is not true.** PVE always calls `savevm-start` for a running VM,
which blocks the guest's writes for the duration of the snapshot, so every disk is
captured within one window where nothing is being written. Application consistency comes
on top of that from fs-freeze, or from persisting VM state — both optional.

There is therefore no correctness bug here, and nothing to fix on those grounds.

## What the actual case is

What a group snapshot changes is the **duration of the blocked-I/O window**, and whether
`savevm` is needed at all:

- Today the storage side of a snapshot is N sequential per-volume operations, so the
  window a guest spends blocked grows with the number of disks.
- A backend that can capture a set atomically does it in **one** operation whose cost
  does not scale with set size.
- If the backend guarantees the set is crash-consistent by itself, PVE could
  *optionally* skip `savevm` where the user is content with crash consistency — this
  possibility was raised by Fabian, not by us, and is the more interesting half.

Whether that is worth the API surface depends on how long a `savevm` window is
acceptable, which is a maintainer judgement. What follows is the measurement that was
missing from the discussion.

## Measurements

Both numbers are from real hardware, not estimates.

**Hitachi VSP E590H.** A grouped operation is one request for the whole group and its
cost does not scale with volume count. Driving four volumes arranged as two consistency
groups, each group trigger took ~2s — 4s total for 4 volumes in 2 groups, and it would
have been ~2s had they been a single group. The ungrouped equivalent is one array round
trip per volume, so the window grows linearly with disks.

For the snapshot case specifically the array recipe is: create every pair under one group
with autoSplit off, let them all reach PAIR, then split the **whole group in a single
action** so every S-VOL freezes at the same instant. Only that final split needs to be
inside the blocked window; the setup does not.

**Ceph RBD (Tentacle 20.2.1).** `rbd group snap create` is likewise a single call for the
whole group, and it does capture a common instant: with two images in a group, both
overwritten *after* the snapshot, clones taken from that snapshot both returned the
pre-snapshot content.

So on both backends the shape is the same — the blocked window becomes O(1) group
operations rather than O(number of disks).

## Proposal

An **optional** storage-plugin capability + hook, mirroring the `copy_image` pattern:

1. **Capability.** A plugin advertises multi-volume snapshot support, analogous to the
   `copy-offload` features added for #7780.

2. **Hook (base class dies; only reached when advertised).**
   ```
   $plugin->volume_group_snapshot($scfg, $storeid, \@volnames, $snap)
   $plugin->volume_group_snapshot_delete($scfg, $storeid, \@volnames, $snap)
   $plugin->volume_group_snapshot_rollback($scfg, $storeid, \@volnames, $snap)   # optional
   ```
   The plugin owns atomicity and its own cleanup on partial failure — the same contract
   direction agreed for `copy_image`. `@volnames` are all on the SAME storage.

3. **qemu-server integration.** When snapshotting a VM, group its disks by storeid; for a
   storage advertising the capability, call the group hook with that store's disk set
   instead of N per-volume calls. A VM spanning several capable stores gets one group
   snapshot per store; cross-store atomicity is out of scope, since no backend spans
   arrays. Snapshot config/state stays keyed by `snapname` as today, so `qm`'s snapshot
   list/rollback/delete are unchanged for the operator.

## Defining membership: the `cg` attribute

The part worth standardising is **how a group is named**, because it can be
storage-agnostic and needs no new API.

Membership is a per-volume attribute, `cg=<name>`, set through the **existing**
`get_volume_attribute` / `update_volume_attribute` plugin methods that `notes` and
`protected` already use. One CG per volume; a CG may span VMs; a VM's disks may sit in
different CGs, or in none. The group hook then acts on the set sharing a tag.

Two reasons to think this is the right shape rather than a vendor-shaped one:

- **It maps natively onto real backends.** On Ceph the tag *is* an rbd group
  (`rbd group image add`); on a VSP it is a consistency group. Neither needs emulation.
- **The cardinality is not a design choice.** Ceph enforces one group per image — adding
  an image to a second group fails with `EEXIST` — and arrays impose the same
  restriction. One-CG-per-volume is what the backends already are.

Backends with no grouping concept simply do not advertise the capability; the attribute
is inert there, as with any capability-gated feature.

**Limitation, stated up front:** one group per volume means CGs cannot overlap. If a
volume needs to be in two groups this model cannot express it, and neither backend could
implement it if it did.

## Second consumer: copy-offload (#7780)

The same tagging serves the full-clone offload hook, which needs to capture several disks
at one instant during a clone. If the tag is already **real backend group membership**,
an offloaded clone can snapshot the existing group rather than creating a transient one.

That matters because creating a transient group is what makes the RBD offload path
unattractive: an image may belong to only one group, so a transient group would mutate
the source's membership, collide with an administrator's own grouping, and leave stray
membership behind if the clone dies. Snapshotting a group that already exists has none of
those problems. Defining the tag once serves both hooks.

## Interim (FCLU today)

FCLU ships consistency groups **out-of-band**: a per-volume `cg` attribute plus a
`pve-fclu-cg` CLI that resolves a group's members and issues one crash-consistent array
snapshot (`create_cg_snapshot`). Per-volume `qm`/`pvesm` snapshots are unaffected. This
covers scripted and operator use; the hook above is what would let a plain `qm snapshot`
use the backend's grouping.

## Open questions

- Is the shorter blocked-I/O window worth the API surface at all? That is the question
  the measurements above are meant to inform, and it is a maintainer call.
- Should PVE be able to skip `savevm` when the backend guarantees a crash-consistent
  group and the user accepts crash consistency?
- Capability granularity: a single flag, or classes (atomic vs best-effort) as with
  `copy-offload`?
- Rollback: require `volume_group_snapshot_rollback`, or fall back to per-volume rollback
  when the backend's group snapshot is just per-volume pairs under a shared tag?
- APIVER/APIAGE bump, and where the disk-grouping lives in qemu-server's snapshot path.
