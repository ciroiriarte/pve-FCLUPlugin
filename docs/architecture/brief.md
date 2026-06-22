# Joint architecture review: generalize the Hitachi PVE storage plugin into a multi-vendor "First-class Logical Unit" (FCLU) framework

## Context

`/home/ciro/code/pve-HitachiBlockPlugin` is a Proxmox VE (PVE) storage plugin (Perl)
that drives Hitachi VSP Fibre Channel block arrays to deliver first-class per-virtual-disk volume storage:
**one array LUN (LDEV) per virtual disk**, with array-offloaded snapshots (Thin
Image), CoW linked clones, online resize, per-LDEV QoS, and replication (TC/UR/GAD).
It speaks the Hitachi Configuration Manager REST API and assembles the device on the
host via Linux FC multipath.

We want to refactor it into a **vendor-neutral framework** ("First-class Logical
Unit") so the same first-class per-virtual-disk functionality can be implemented against **any FC block
array** — Dell PowerMax/PowerStore, Pure Storage FlashArray, IBM FlashSystem, NetApp,
etc. — by adding a per-vendor driver, reusing as much generic orchestration as
possible and isolating per-brand and per-model/generation specifics.

## Current structure (read these files to verify and deepen)

- `src/PVE/Storage/Custom/HitachiBlockPlugin.pm` (~2128 lines) — the PVE plugin class.
  Implements the full PVE::Storage::Plugin contract: properties/options/plugindata,
  on_add/update/delete_hook, activate/deactivate_storage, status, alloc_image,
  free_image, list_images, activate/deactivate_volume, path/filesystem_path,
  volume_size_info, volume_snapshot/_delete/_rollback/_info, volume_has_feature,
  clone_image, create_base, rename_volume, volume_export/import, volume_resize,
  manage/unmanage_volume, volume_snapshot_consistency_group, volume_migrate_pool,
  list_orphans, cleanup_registry_orphans. Mixes GENERIC orchestration with
  Hitachi-specific calls and constants (MIN_LDEV_MB=48, LDEVS_PER_CU=256,
  host_mode 'LINUX/IRIX', host_mode_options '2,22,25,68', HMO 91, platform enum).
- `src/PVE/Storage/HitachiBlock/RestClient.pm` (~965 lines) — 100% Hitachi REST:
  ~50 methods (create/delete/expand/list/label LDEVs, pools, host groups, host WWNs,
  LUN map/unmap, Thin Image snapshots split/restore/clone, QoS get/set, remote-copy
  pairs TC/UR/GAD, reclaim_zero_pages, migrate_ldev, async _wait_for_job job polling,
  multi-endpoint failover login/logout/keepalive). API root is the Hitachi-specific
  `/ConfigurationManager/v1/objects/storages/<id>/...`.
- `src/PVE/Storage/HitachiBlock/Multipath.pm` (~422 lines) — host-side FC connector.
  Mostly vendor-neutral Linux SCSI/multipath (get_local_wwns from sysfs fc_host,
  rescan_scsi_hosts, whitelist_wwid into /etc/multipath/wwids under
  `find_multipaths strict`, get_device_path /dev/mapper/3<wwid>, resize_device via
  multipathd, remove_device + SCSI delete, _prune_wwid_entries). VENDOR-SPECIFIC bits:
  `ldev_to_wwid()` synthesizes the NAA-6 WWID from IEEE OUI `60060e80`+serial+ldev_hex;
  `discover_wwid()` scans sysfs filtering on the `60060e80` OUI and "HITACHI" vendor.
- `src/PVE/Storage/HitachiBlock/Config.pm` (~572 lines) — credentials store
  (/etc/pve/priv/hitachiblock/<storeid>.creds), the cluster-replicated **LDEV/snapshot
  registry** (/etc/pve/priv/hitachiblock/<storeid>.json, mutated under a corosync
  cfs_lock_domain), volname<->ldev_id identity + reservation, snapshot/clone parent
  tracking, dependents lookup, platform port defaults, 32-char label make/parse,
  config validation.
- `src/www/manager6/hitachiblock.js` — ExtJS GUI panel.
- `bin/hitachiblock-repl` — standalone replication CLI (TC/UR/GAD).

## Key facts / constraints

- PVE custom plugins subclass `PVE::Storage::Plugin` and are registered by `type()`
  returning a unique string used as the `storage.cfg` section type. There is ONE
  registered plugin class per type. A multi-vendor framework must decide how vendor
  selection maps onto PVE plugin types and the `storage.cfg` schema.
- The registry (volname<->LU identity, snapshots, clone parentage) and its
  cluster-locking are essentially **vendor-neutral** and high-value to reuse.
- The host-side connector is ~80% vendor-neutral; only WWID synthesis/identification
  is vendor-specific. NAA/page-83 EUI formats differ per vendor; relying on
  array-reported canonical WWID + sysfs discovery is more robust than synthesis.
- Vendor differences are TWO-dimensional: (a) by brand (REST dialect, object model,
  auth, async-job semantics, host-access model: host groups vs host objects vs
  volume-to-host mappings), and (b) by model/generation/microcode within a brand
  (field-name drift, feature availability, label limits, host-mode options).
- Some vendors use REST, some require a CLI/SSH or a separate management appliance.
- Capabilities differ: not every array supports CoW snapshots, linked clones,
  per-volume QoS, consistency groups, or the same replication topologies. The
  framework needs capability negotiation so `volume_has_feature` and the GUI reflect
  what each backend actually supports.

## What we want from you

Propose a concrete target architecture. Be specific and opinionated. Cover:

1. **Layering & module decomposition.** What is the generic core vs the per-vendor
   driver vs the host connector? Propose the Perl package namespace layout
   (e.g. `PVE::Storage::FCLU::*`, drivers under `PVE::Storage::FCLU::Driver::<Vendor>`).
2. **The driver (array backend) interface.** Define the minimal, vendor-neutral
   method contract every backend must implement (CRUD on logical units, mapping/
   unmapping to an initiator/host identity, snapshot/clone, resize, QoS, capacity,
   capability reporting, canonical WWID lookup). Name the methods and their
   semantics. Show how Hitachi's current RestClient maps onto it.
3. **The host connector interface.** How to keep the Linux FC/multipath layer generic
   while letting a vendor plug in WWID identification (prefer array-reported WWID +
   sysfs match over synthesis). Consider future iSCSI/NVMe-oF without over-engineering.
4. **Per-model/generation specialization.** How to handle intra-brand drift
   (microcode field fallbacks, host-mode options, label limits, feature gates)
   WITHOUT a driver-per-model explosion — e.g. capability/profile objects, traits,
   quirk tables, version detection. Recommend a pattern.
5. **PVE integration & config schema.** How vendor selection surfaces in storage.cfg
   and the GUI: one PVE plugin type with a `vendor`/`driver` property dispatching to a
   backend, vs one registered plugin type per vendor (thin subclasses). Trade-offs,
   and your recommendation. How shared vs vendor-specific properties are declared.
6. **Capability negotiation.** How `volume_has_feature`, QoS, consistency groups,
   replication, and the GUI adapt to per-backend capabilities.
7. **Registry & cross-cutting state.** Confirm the registry, locking, orphan
   detection, partial-failure rollback, and active-node-only mapping belong in the
   generic core; note any vendor-specific hooks they need.
8. **Replication.** How to generalize TC/UR/GAD into a vendor-neutral replication
   abstraction (or whether to keep it an optional per-driver extension).
9. **Migration path.** A staged, low-risk refactor from today's single-vendor plugin
   to the framework, keeping the Hitachi driver working and tests green throughout.
   Identify what moves verbatim, what gets an interface extracted, what is rewritten.
10. **Risks & sharp edges.** PVE SectionConfig duplicate-property pitfalls, the single
    `type()` registration constraint, taint mode, testing/mocking strategy per driver,
    and anything else you see.

Return a structured written proposal (headers, bullet lists, small Perl interface
sketches where useful). Do not write the full implementation — this is an architecture
proposal that I (Claude) will reconcile with a parallel proposal from another model.
Where you disagree with the framing above, say so.
