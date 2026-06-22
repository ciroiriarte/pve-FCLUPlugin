**Recommendation**

Build a vendor-neutral **internal** framework, but do **not** start with a single vendor-neutral PVE storage type. Keep one registered PVE plugin type per vendor, implemented as thin subclasses over a shared `PVE::Storage::FCLU` core. PVE’s static `SectionConfig` schema, duplicate-property traps, and static ExtJS storage dialogs make a single dynamic `fclu` type more trouble than it is worth in phase 1.

That means:

- Internal API: generic and reusable.
- External PVE type: per vendor (`hitachiblock` first, later `pureblock`, `powermaxblock`, etc.).
- Hitachi remains working during the refactor, with near-zero user-visible churn.

**1. Layering**

Suggested namespace layout:

```perl
PVE::Storage::FCLU::Plugin              # generic PVE::Storage::Plugin implementation
PVE::Storage::FCLU::Registry            # volume/snapshot/clone registry + locking
PVE::Storage::FCLU::Credentials         # generic credential store
PVE::Storage::FCLU::Label               # ownership label encode/decode with length limits
PVE::Storage::FCLU::Capabilities        # normalized feature matrix
PVE::Storage::FCLU::Txn                 # rollback helpers / partial-failure cleanup
PVE::Storage::FCLU::DriverFactory       # resolve vendor driver
PVE::Storage::FCLU::Driver              # backend contract (role/base class)
PVE::Storage::FCLU::Driver::Hitachi     # Hitachi adapter over current RestClient
PVE::Storage::FCLU::Driver::Hitachi::Profile
PVE::Storage::FCLU::Host::Connector     # host-side contract
PVE::Storage::FCLU::Host::FCMultipath   # current Linux FC + multipath implementation
PVE::Storage::FCLU::Plugin::Hitachi     # thin registered PVE plugin class
```

Responsibility split:

- `FCLU::Plugin`: PVE lifecycle, volume orchestration, registry use, rollback, feature exposure.
- `FCLU::Driver::*`: array semantics only.
- `FCLU::Host::*`: host attach/detach/resize/path discovery only.
- `Registry`: cluster-safe identity/state for volname, snapshots, clone parentage, reservations, orphan bookkeeping.

**2. Driver Interface**

Use a normalized, minimal contract around an opaque backend LU id.

```perl
package PVE::Storage::FCLU::Driver;

sub connect($self) {}
sub disconnect($self) {}
sub ping($self) {}

sub detect_profile($self) {}         # model/fw/quirk selection
sub capabilities($self) {}           # normalized feature map
sub storage_status($self, %args) {}  # total/free/used for configured pool/group

sub create_lu($self, %args) {}       # size_bytes, pool_ref, requested_id?, label?
sub delete_lu($self, $lu_id) {}
sub get_lu($self, $lu_id) {}
sub list_lus($self, %args) {}        # for orphan scans / allocation fences
sub set_lu_label($self, $lu_id, $label) {}
sub resize_lu($self, $lu_id, %args) {}
sub set_lu_qos($self, $lu_id, %qos) {}
sub get_lu_qos($self, $lu_id) {}
sub migrate_lu($self, $lu_id, %args) {}

sub ensure_host_access($self, %host_ctx) {}     # idempotent host object setup
sub publish_lu($self, $lu_id, %host_ctx) {}     # map/export to this node
sub unpublish_lu($self, $lu_id, %host_ctx) {}
sub list_lu_mappings($self, $lu_id) {}          # authoritative safe-unmap source

sub get_lu_identity($self, $lu_id) {}           # canonical device identity
# => { protocol=>'scsi-fc', ids=>{ naa=>'...', wwid=>'...' } }

sub create_snapshot($self, %args) {}
sub delete_snapshot($self, $snap_id) {}
sub restore_snapshot($self, $snap_id) {}
sub list_snapshots($self, %args) {}

sub create_linked_clone($self, %args) {}        # optional
sub create_full_clone($self, %args) {}          # optional
sub create_consistency_group_snapshot($self, %args) {}  # optional
```

Semantics:

- Methods return **normalized hashes**, not raw REST payloads.
- The core never knows about host groups, masking views, storage groups, or REST job IDs.
- Async-job polling is always hidden inside the driver.

Hitachi mapping:

- `create_lu` -> `create_ldev`
- `delete_lu` -> `delete_ldev`
- `get_lu` -> `get_ldev`
- `list_lus` -> `list_ldevs` / `list_defined_ldevs_in_range`
- `set_lu_label` -> `set_ldev_label`
- `resize_lu` -> `expand_ldev`
- `set_lu_qos` -> `set_ldev_qos`
- `ensure_host_access` -> `create_host_group` / `set_host_group_mode` / `add_wwn_to_host_group`
- `publish_lu` -> `map_lun`
- `unpublish_lu` -> `unmap_lun`
- `list_lu_mappings` -> `get_ldev->{ports}` preferred, not `list_luns`
- `get_lu_identity` -> `get_ldev->{naaId}`
- `create_snapshot` / `delete_snapshot` / `restore_snapshot` -> current Thin Image methods
- `create_linked_clone` -> current “create thin S-VOL + snapshot autoSplit”
- `create_consistency_group_snapshot` -> current repeated snapshot creation with shared group

**3. Host Connector**

Make the host side generic around **protocol + canonical device identity**, not vendor synthesis.

```perl
package PVE::Storage::FCLU::Host::Connector;

sub host_context($self, %scfg) {}    # hostname, protocol, initiators
sub attach($self, %args) {}          # rescan + wait for device path
sub detach($self, %args) {}
sub resize($self, %args) {}
sub flush($self, %args) {}
sub device_path($self, %identity) {}
```

For FC now:

- Implement `FCLU::Host::FCMultipath`.
- Reuse current `get_local_wwns`, rescans, multipath whitelist, resize, flush, remove.
- Replace `ldev_to_wwid()` and vendor-specific `discover_wwid()` with:
  - driver-supplied canonical ids (`naa`, `eui`, `wwid`)
  - generic sysfs/page-83 matching
  - no OUI/vendor string assumptions in the core path

Future-proofing:

- `protocol => 'scsi-fc'` now
- later `scsi-iscsi`, `nvme-tcp`, `nvme-fc`
- same orchestration, different connector implementations

**4. Per-Model / Generation Drift**

Do not create one driver per model. Use **driver + profile + quirks**.

Pattern:

- `Driver::Hitachi` owns behavior.
- `Driver::Hitachi::Profile` is selected at `connect/detect_profile`.
- Profile supplies:
  - capability gates
  - field aliases / response normalizers
  - defaults (`min_lu_mb`, label length, default API port)
  - host access quirks
  - broken-filter workarounds
  - firmware predicates

Example profile data:

```perl
{
  family => 'vsp_e',
  min_lu_mb => 48,
  max_label_len => 32,
  capabilities => { linked_clone => 1, qos => 1, cg_snapshot => 1 },
  quirks => {
    list_luns_ignores_lu_filter => 1,
    used_pool_capacity_missing => 1,
    supports_hmo_91 => 1,
  },
}
```

The driver normalizes raw vendor responses into the FCLU contract using that profile.

**5. PVE Integration / Config Schema**

Recommendation: **thin subclasses per vendor**, shared core beneath.

Why:

- `PVE::SectionConfig` properties are static and global.
- duplicate properties like `username` are easy to break
- ExtJS storage add/edit dialogs are static by type
- vendor-specific fields are unavoidable

Shape:

- `PVE::Storage::FCLU::Plugin` contains almost all method bodies.
- `PVE::Storage::Custom::HitachiBlockPlugin` becomes a thin subclass:
  - `type() => 'hitachiblock'`
  - `vendor() => 'hitachi'`
  - vendor properties/options only
  - maybe `driver_class()`

Shared properties across vendors:

- `content`, `nodes`, `shared`, `disable`
- generic QoS defaults only if the vendor panel supports them
- generic credential references if possible

Vendor-specific stay vendor-specific:

- `storage_id`, `target_ports`, `host_mode_options`, `platform`, etc.

I would avoid a single `driver_options` blob unless forced. It weakens validation and makes the GUI poor.

**6. Capability Negotiation**

Backends should expose a normalized capability object, for example:

```perl
{
  snapshot => { single => 1, consistency_group => 1, rollback => 1 },
  clone => { linked => 1, full => 1, from_snapshot => 1, from_base => 1 },
  qos => { per_lu => 1 },
  resize => { grow_online => 1, shrink => 0 },
  import => 1,
  migrate_pool => 1,
  replication => { tc => 1, ur => 1, gad => 1 },
}
```

Use it in:

- `volume_has_feature`
- storage activation sanity checks
- GUI field enable/disable for vendor-specific panels
- CLI command exposure for optional extensions

Important nuance: PVE `clone_image` is a **linked clone primitive**. Only advertise `clone` where the backend supports a persistent CoW child from base/snapshot. Full-copy-only arrays should expose `copy`, not `clone`.

**7. Registry / Cross-Cutting State**

Yes: registry, locking, reservations, parent/dependent tracking, orphan detection, rollback bookkeeping, and active-node-only mapping belong in the generic core.

Generalize the current registry shape away from `ldev_id`:

```perl
{
  volname => {
    backend_id => "1234",         # opaque LU identifier
    identity => { protocol=>"scsi-fc", ids=>{ naa=>"..." } },
    size_mb => ...,
    pool_ref => ...,
    parent_volname => ...,
    parent_snap => ...,
    backend_meta => { ... },
    snapshots => { ... },
  }
}
```

Vendor hooks needed:

- `make_ownership_label` constraints: max length / charset
- `list_owned_lus` or enough `list_lus + get_lu` support for orphan scans
- `safe_delete_precheck` where deletion rules are vendor-specific
- `get_lu_identity` after publish

Keep the separate lock domain pattern. The current avoidance of re-entering PVE’s storage lock is correct and should remain generic.

**8. Replication**

Do **not** force replication into the mandatory FCLU backend contract.

Reason:

- it is outside the core PVE storage plugin contract
- topology and semantics differ too much across vendors
- many arrays will not support an equivalent of TC/UR/GAD

Recommendation:

- define an **optional extension interface**
- keep replication CLI-driven initially

```perl
package PVE::Storage::FCLU::Driver::Replication;
sub replication_capabilities($self) {}
sub list_relationships($self, %args) {}
sub create_relationship($self, %args) {}
sub split_relationship($self, $id) {}
sub resync_relationship($self, $id) {}
sub delete_relationship($self, $id) {}
```

Use generic relationship vocabulary where possible: `sync`, `async`, `active-active`, but allow vendor subtype annotations.

**9. Migration Path**

Low-risk sequence:

1. Extract `Registry`, credentials, label helpers from `HitachiBlock::Config` into `FCLU::*` with no behavioral change.
2. Extract host-side generic FC multipath code into `FCLU::Host::FCMultipath`; keep Hitachi WWID synthesis only as a temporary driver fallback.
3. Wrap current `RestClient` in `FCLU::Driver::Hitachi`; do not rewrite transport first.
4. Introduce `FCLU::Plugin` and move read-only/common methods first:
   - `status`
   - `list_images`
   - `volume_size_info`
   - `parse_volname` helpers if still shared
5. Move alloc/free/activate/deactivate/resize/snapshot/clone orchestration into the generic plugin one operation at a time.
6. Replace direct `RestClient` calls in the plugin with driver contract calls.
7. Add Hitachi profile detection and quirk handling behind the driver.
8. Keep `type() => 'hitachiblock'` and current GUI intact through the whole process.
9. Only after Hitachi is stable behind the contract, add a second vendor driver to validate the abstraction.

What moves almost verbatim:

- registry locking and snapshot/dependency tracking
- multipath rescan/wait/remove/resize/flush
- much of alloc/free/snapshot rollback orchestration

What should be rewritten:

- anything named around `ldev`, `host_group`, `HMO`, `target_ports`
- WWID synthesis and vendor sysfs discovery
- direct REST object assumptions in plugin logic

**10. Risks / Sharp Edges**

- `SectionConfig` duplicate properties: keep common PVE properties out of vendor `properties()` if PVE already defines them.
- Single `type()` constraint: another reason to prefer thin per-vendor subclasses over one dynamic plugin type.
- Taint mode: keep untainting at every sysfs-derived path and every device identity used in exec/open.
- Safe unmap/delete: core must rely on driver-authoritative LU mapping enumeration, not generic group scans.
- Async semantics: job polling, retry rules, and eventual consistency must stay inside the driver.
- Label limits: do not hardcode 32 chars in the core.
- Host access model variance: host groups, masking views, host objects, ACLs all differ; keep all of that in `ensure_host_access/publish/unpublish`.
- Testing:
  - contract tests for every driver
  - fake driver tests for generic plugin orchestration
  - fixture-based API tests for Hitachi driver normalization
  - host connector tests with fake sysfs trees
  - rollback tests for partial failure after create/map/label/snapshot
- Abstraction risk: do not generalize based only on Hitachi. The second driver is the real validation point.

**Where I disagree slightly with the framing**

The framework should be **vendor-neutral internally**, but probably **not vendor-neutral at the PVE type/schema layer** yet. PVE’s plugin/config/UI model pushes hard toward thin vendor-specific entrypoints over one dynamic umbrella type. Trying to hide that too early will make the framework worse, not better.
