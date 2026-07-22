# FCLU — First-class Logical Unit framework: Architecture Proposal

A vendor-neutral Proxmox VE storage framework that delivers first-class
per-virtual-disk volume service (**one array LUN per virtual disk**, array-offloaded snapshots/clones/QoS/replication)
over Fibre Channel, with per-vendor drivers (Hitachi today; Dell, Pure, HPE, IBM, NetApp
next). Refactored out of `pve-HitachiBlockPlugin`. Optional FC-fabric (Brocade/Cisco)
zoning automation is a separate, capability-gated plane (§14).

> **Provenance.** This is a joint review. The design was produced by Claude from a
> full read of the Hitachi plugin, then cross-checked against two independent model
> reviews of the same brief — **Codex** (`docs/architecture/review-codex.md`) and
> **agy / Gemini 3.1 Pro** (`docs/architecture/review-gemini.md`), both answering the
> shared brief in `docs/architecture/brief.md`. All three converged on the major
> decisions; divergences and adjudications are flagged inline as **[consensus]**,
> **[Codex]**, **[agy]**, **[Claude]**.
>
> **Tracks the reference implementation.** This design follows `pve-HitachiBlockPlugin`
> (≥ `1.2.0~alpha30`); features landed there — PVE 9 `qemu_blockdev_options`, per-volume
> `protected`/`notes`, `lock_timeout`, the tested-API-version clamp, cloud-init volumes —
> are reflected below, and its `docs/adr/0002-full-clone-offload.md` is the source for the
> full-clone constraint cited in §6.

---

## 0. The decisive constraint (read this first)

PVE's storage layer is **statically wired**, and that shapes everything:

- `PVE::SectionConfig` properties are **global and static**. A property name can only
  be declared once across the loaded plugin set, and `username`/`password` are already
  defined by core plugins — redefining them makes the PVE daemons die (this is already
  worked around in `HitachiBlockPlugin.pm:152` by *referencing* but not redeclaring them).
- The ExtJS storage add/edit dialog is **static per storage type**.
- A plugin registers exactly **one** `type()` string, and that string is the
  `storage.cfg` section type.

**Therefore: the framework is vendor-neutral _internally_, but NOT at the PVE
type/schema layer.** We expose **one thin registered plugin type per vendor**
(`hitachiblock`, later `pureblock`, `powermaxblock`, …), each a ~50-line subclass over
a shared `PVE::Storage::FCLU::*` core. We explicitly reject a single dynamic `type:
fclu` plugin with a `vendor` dropdown.

This was the one place the brief's framing was pushed back on, and **all three reviews
independently reached the same conclusion** [consensus]. A single umbrella type would
force every vendor's auth + tuning properties into one global schema (namespace
pollution, a confusing union form, validation loss) and still couldn't give each
vendor a tailored GUI panel. The subclass approach also keeps existing
`type: hitachiblock` storage definitions working verbatim — zero migration for current
users.

---

## 1. Layering & module decomposition

```
PVE::Storage::FCLU::Plugin            # generic PVE::Storage::Plugin body: orchestration,
                                      # registry use, rollback, feature exposure
PVE::Storage::FCLU::Registry          # vendor-neutral identity/state + cluster locking
PVE::Storage::FCLU::Credentials       # generic credential store (was Config.pm creds)
PVE::Storage::FCLU::Label             # ownership-label encode/decode w/ per-driver limits
PVE::Storage::FCLU::Capabilities      # normalized feature matrix + volume_has_feature glue
PVE::Storage::FCLU::Txn               # partial-failure rollback helpers
PVE::Storage::FCLU::Error             # blessed driver/core error type (retryable/transient/code) — §13

PVE::Storage::FCLU::Driver            # ARRAY BACKEND contract (base class / role)
PVE::Storage::FCLU::Driver::Hitachi   # Hitachi adapter wrapping the existing RestClient
PVE::Storage::FCLU::Driver::Hitachi::Profile   # model/microcode quirk profiles
PVE::Storage::FCLU::Driver::Mock      # in-memory fake backend for core/orchestration tests

PVE::Storage::FCLU::Host::Connector   # HOST-SIDE contract (attach/detach/resize/path)
PVE::Storage::FCLU::Host::FCMultipath # current Linux FC + multipath implementation

PVE::Storage::FCLU::Driver::Replication   # OPTIONAL replication mix-in (§8), capable drivers only
PVE::Storage::FCLU::Fabric            # OPTIONAL FC-zoning contract (§14)
PVE::Storage::FCLU::Fabric::Noop      # default: fabric already zoned (today's behaviour)
PVE::Storage::FCLU::Fabric::Brocade   # Brocade FOS zoning (REST/SSH)
PVE::Storage::FCLU::Fabric::Cisco     # Cisco MDS NX-OS zoning (NX-API/SSH)

PVE::Storage::Custom::HitachiBlockPlugin   # THIN registered plugin: type()='hitachiblock',
                                           # vendor schema only, picks the Hitachi driver
```

Four clean responsibility boundaries:

- **`Driver::*` — array semantics only.** Knows LDEVs/host-groups/Thin-Image/REST jobs.
  The core never sees a host group, masking view, storage group, or REST job id.
- **`Host::*` — Linux side only.** Knows sysfs, multipath, SCSI/`blockdev`. Vendor-blind.
- **`Fabric::*` — FC switch side only (optional).** Knows Brocade/Cisco zoning; default
  `Fabric::Noop` assumes a pre-zoned fabric. A third control plane, peer to Driver and
  Host — see §14.
- **`Plugin` + `Registry` + `Capabilities` — the generic spine.** Knows PVE, the
  volname↔LU identity, snapshots, clone parentage, reservations, rollback, orphans.

---

## 2. Driver (array backend) interface

Normalized contract around an **opaque backend LU id** (`backend_id`, a string — not an
integer `ldev_id`). Methods return **normalized hashes, never raw REST payloads**.
Async-job polling, retries, and eventual-consistency handling stay **inside the driver**.

```perl
package PVE::Storage::FCLU::Driver;

# --- session / introspection ---
sub connect            { }   # auth + endpoint failover
sub disconnect         { }
sub ping               { }
sub detect_profile     { }   # model / firmware / quirk selection (see §4)
sub capabilities       { }   # normalized feature map (see §6)
sub storage_status     { }   # ($total, $free, $used) for the configured pool/group

# --- LU lifecycle ---
sub create_lu          { }   # (size_bytes, pool_ref, requested_id?, label?) -> $backend_id
sub delete_lu          { }   # ($backend_id); core unmaps all hosts first (#24 teardown symmetry)
sub get_lu             { }   # ($backend_id) -> normalized {size,label,pool,...}
sub list_lus           { }   # (%filter) -> for orphan scans & allocation fences
sub set_lu_label       { }
sub resize_lu          { }   # grow online
sub set_lu_qos         { }   # optional (capability-gated)
sub get_lu_qos         { }
sub migrate_lu         { }   # optional: pool/tier migration

# --- host access (THE key abstraction — see note) ---
sub ensure_host_access { }   # (%host_ctx) -> $access_handle; idempotent host-object/group/mask setup
sub publish_lu         { }   # ($backend_id, %host_ctx) -> mapping; map/export to THAT node (idempotent)
sub unpublish_lu       { }   # ($backend_id, %host_ctx); remove THAT node's mapping (idempotent)
sub list_lu_mappings   { }   # ($backend_id) -> [mappings]; AUTHORITATIVE for safe-unmap (shape: §12.1)
sub target_ports       { }   # (%host_ctx?) -> [target endpoints {wwpn,...}] for fabric zoning (§14)

# --- identity ---
sub get_lu_identity    { }   # -> { protocol=>'scsi-fc', ids=>{ naa=>'...', eui=>..., wwid=>... } }

# --- snapshots / clones (capability-gated) ---
sub create_snapshot    { }
sub delete_snapshot    { }
sub restore_snapshot   { }
sub list_snapshots     { }
sub create_linked_clone{ }   # persistent CoW child; takes host_ctx (#24: S-VOL mapped before assign)
sub create_full_clone  { }   # optional
sub create_cg_snapshot { }   # optional: consistency-group snapshot
```

**Host access is the hardest part of the abstraction, and the part most over-fit to
Hitachi today** [Claude + Codex]. Hitachi uses *host groups* (`PVE_<hostname>` per FC
port, with WWNs + host-mode options + HMO numbers). But the control plane, the LU
object, and the host-access model differ sharply per vendor — a concrete spec sheet for
driver authors:

| Vendor / family | Control plane (API) | LU object | Host-access model |
|---|---|---|---|
| **Hitachi VSP** (E, G, One) | Configuration Manager REST | LDEV | **Host Group** per FC port (WWNs + host-mode + HMO) |
| **Dell PowerStore** | Native array REST (`/api/rest/`) | Volume | **Host / Host Group** objects |
| **Dell PowerMax** | Unisphere for PowerMax REST | Device | **Masking View** = Initiator Group + Port Group + Storage Group |
| **Pure FlashArray** | Native REST (`/api/`) | Volume | **Host / Host-Group** objects with connections |
| **IBM FlashSystem** | Native REST / CLI | Volume (vdisk) | **Host objects + volume mappings** |
| **HPE Alletra MP / Primera / 3PAR** | WSAPI REST | Volume (VV) | **Host / Host-Set** objects + VLUN exports |
| **HPE Alletra 9000 / XP8** | rebadged Hitachi VSP — Configuration Manager REST *if exposed* | LDEV | **Host Group** per FC port |
| **NetApp ONTAP** | ONTAP REST / ONTAPI | LUN | **igroup** (initiator group) + LUN map |

> **HPE is three unrelated control planes, not one driver** [Claude]: *Primera / Alletra
> MP / 3PAR* (WSAPI → `Driver::HPE3par`), *Alletra 5000/6000* (Nimble lineage → a separate
> `Driver::Nimble`), and *Alletra 9000 / XP8* (rebadged Hitachi VSP → reuse
> `Driver::Hitachi` **only** if Configuration Manager REST is present, else a distinct
> driver). See §11 packaging and Open decisions.

The spread — three- vs one-object masking, per-port host groups vs cluster-wide host
objects — is exactly why host access cannot be generic. So the core must speak only
`ensure_host_access(%host_ctx)` / `publish_lu` /
`unpublish_lu`, where `%host_ctx` carries `{ hostname, protocol, initiators => [wwns] }`.
The current `_ensure_host_groups` / `_map_lun_to_local` / `_unmap_lun_from_local` logic
(`HitachiBlockPlugin.pm:1326–1505`), including HMO reconciliation and host-mode options,
moves **into `Driver::Hitachi` verbatim** — it is Hitachi-specific and does not belong
in the generic plugin.

**Per-node port resolution is a scaling lever, not just a mapping detail.** An FC array
meters a finite budget of LU paths and host groups *per front-end port* (aggregate across
all host groups on that port), so mapping every node onto the same ports caps the whole
cluster at one port's budget regardless of node count. Sharding nodes across disjoint
target-port groups — resolved per node at map time, within one storeid so migration is
preserved — multiplies that ceiling. See [ADR 0003](docs/adr/0003-port-group-sharding.md).

**`list_lu_mappings` must be driver-authoritative** [Codex, important]. Today
`_unmap_lun_from_local` leans on `list_luns`, whose server-side `ldevId` filter is a
no-op on Hitachi (it filters client-side — a documented quirk). The contract instead
asks the driver for the authoritative mapping list (Hitachi: `get_ldev->{ports}`), so
the core never makes an unsafe unmap/delete decision from a generic group scan.

### Hitachi RestClient → contract mapping

| Contract method | Hitachi `RestClient` |
|---|---|
| `create_lu` / `delete_lu` / `get_lu` / `list_lus` | `create_ldev` / `delete_ldev` / `get_ldev` / `list_ldevs`, `list_defined_ldevs_in_range` |
| `set_lu_label` / `resize_lu` / `set_lu_qos` | `set_ldev_label` / `expand_ldev` / `set_ldev_qos` |
| `ensure_host_access` | `create_host_group`, `set_host_group_mode`, `add_wwn_to_host_group`, host-mode/HMO logic |
| `publish_lu` / `unpublish_lu` | `map_lun` / `unmap_lun` |
| `list_lu_mappings` | `get_ldev->{ports}` (preferred over `list_luns`) |
| `get_lu_identity` | array-reported `get_ldev->{naaId}` (see §3) |
| `create_snapshot` / `delete_snapshot` / `restore_snapshot` | Thin Image methods |
| `create_linked_clone` | "create thin S-VOL + snapshot autoSplit" |
| `create_cg_snapshot` | repeated snapshot creation with shared `isConsistencyGroup` |
| `migrate_lu` / capacity | `migrate_ldev`, `reclaim_zero_pages`, `get_pool`/`list_pools` |

The existing `RestClient.pm` is **kept and wrapped, not rewritten** — only the
plugin↔driver boundary is new.

---

## 3. Host connector interface

Generic around **protocol + canonical device identity**, never vendor synthesis.

```perl
package PVE::Storage::FCLU::Host::Connector;
sub host_context  { }   # hostname, protocol, local initiators (FC: get_local_wwns)
sub attach        { }   # rescan + wait for /dev/mapper device by canonical id
sub detach        { }   # flush + remove multipath map + SCSI delete + settle
sub resize        { }   # rescan paths + multipathd resize
sub flush         { }
sub device_path   { }   # canonical identity -> /dev/mapper path
```

`Host::FCMultipath` reuses today's `Multipath.pm` almost verbatim — `get_local_wwns`,
`rescan_scsi_hosts`, `whitelist_wwid` (the `find_multipaths strict` handling),
`resize_device`, `flush_device`, `remove_device`/`_prune_wwid_entries`, taint-safe
`_run_cmd`. **What gets deleted from the host layer** [consensus]:

- `ldev_to_wwid()` — WWID **synthesis** from OUI `60060e80`+serial+ldev (`Multipath.pm:309`).
- `discover_wwid()`'s `60060e80`-OUI + `"HITACHI"` vendor-string filtering (`:354–358`).

Replaced by: the driver's `get_lu_identity()` is the **single source of truth**; the
connector does generic sysfs / SCSI page-83 matching against that canonical id. This is
*more* robust than synthesis (whose byte layout already "varies across VSP models" per
the code's own comment) and is what makes a second vendor cheap.

- **Migration safety valve** [Codex]: keep Hitachi synthesis alive *only* as a private
  fallback inside `Driver::Hitachi` during the transition, then drop it.
- **Future transports** [consensus]: `protocol => 'scsi-fc'` now; the same orchestration
  admits `scsi-iscsi` / `nvme-fc` / `nvme-tcp` later as alternate `Host::*`
  implementations. Structure for it; do not build it yet.
- **Fabric zoning is a *separate third plane*** [Claude], not part of `Host::*` or
  `Driver::*`. The connector assumes the initiator↔target zoning already exists; optional
  Brocade/Cisco automation lives in `Fabric::*` (§14). `host_context` supplies the
  initiator WWPNs that zoning consumes; array target WWPNs come from `Driver->target_ports`.

---

## 4. Per-model / generation drift — **driver + profile + quirks** [consensus]

No driver-per-model explosion (no `Driver::Hitachi::VSP_E` vs `::VSP_5000`). One driver
per **brand**; a `Profile` selected at `connect()`/`detect_profile()` carries the deltas:

```perl
{
  family       => 'vsp_e',
  min_lu_mb    => 48,            # was the hardcoded MIN_LDEV_MB
  max_label_len=> 32,            # was Config.pm MAX_LABEL_LEN — NOT in the core
  default_port => 443,           # was %PLATFORM_DEFAULTS
  alloc_granule=> 256,           # was LDEVS_PER_CU
  api_version_range => ['v1','v3'],  # clamp array-reported storage API version to a tested range (#17)
  op_timeout_s => 600,           # per-operation async wall-clock budget (§13.6)
  capabilities => { linked_clone => 1, qos => 1, cg_snapshot => 1 },
  quirks => {
    list_luns_ignores_lu_filter => 1,   # client-side filter fallback
    used_pool_capacity_missing  => 1,   # status() field fallback (Plugin.pm:418 today)
    supports_hmo_91             => 1,
    hostWwnNickname_unsupported => 1,    # E-series add_wwn quirk
    split_snapshot_omit_operationType => 1,  # KART40038-E on Thin Image split (#12)
  },
}
```

The driver normalizes raw vendor responses into the contract **through the profile** —
field aliases, capability gates, defaults, broken-filter workarounds, firmware
predicates. The platform enum (`vsp_g`/`vsp_e`/`vsp_one`) becomes profile selection
input, not branching scattered through the plugin.

---

## 5. PVE integration & config schema

**One thin subclass per vendor over a shared core** [consensus — see §0].

```perl
package PVE::Storage::Custom::HitachiBlockPlugin;
use base 'PVE::Storage::FCLU::Plugin';
sub type         { 'hitachiblock' }          # unchanged → backward compatible
sub vendor       { 'hitachi' }
sub driver_class { 'PVE::Storage::FCLU::Driver::Hitachi' }
sub properties   { ... }   # storage_id, target_ports, host_mode_options, platform, …
sub options      { ... }   # vendor knobs + inherited generic ones
```

- `FCLU::Plugin` holds **almost every method body** (alloc/free/activate/snapshot/clone…).
- **The generic base implements the full PVE plugin surface**, including the PVE 9
  additions already shipped in the Hitachi reference (alpha30): `qemu_blockdev_options`
  (the `-blockdev` interface, #14), `volume_export`/`volume_import` (+`*_formats`),
  `rename_volume`, and `get_volume_attribute`/`update_volume_attribute` for the
  `protected` and `notes` attributes (§7, #15). These are host/registry-level and
  vendor-neutral — drivers add no code for them.
- Generic, safe-to-share properties (`pool_id`, generic QoS defaults, `tls_*`,
  `lock_timeout` (cluster-lock acquisition budget, #10),
  `content`/`nodes`/`shared`/`disable`) live in the base; vendor specifics
  (`storage_id`, `target_ports`, `host_mode_options`, `platform`, Pure's `api_token`, …)
  live in the subclass.
- **Avoid a single `driver_options` blob** [Codex] — it kills schema validation and
  produces a poor GUI. Declare real typed properties per vendor.
- Keep the `'sensitive-properties'` pattern and *reference-don't-redeclare* discipline
  for `username`/`password` (the existing `SectionConfig` landmine).

---

## 6. Capability negotiation

Driver exposes a normalized capability object; the core consumes it everywhere a
feature might not exist:

```perl
{
  snapshot => { single => 1, consistency_group => 1, rollback => 1 },
  clone    => { linked => 1, from_snapshot => 1, from_base => 1 },   # CoW child (PVE clone_image)
  copy     => { full => 1, from_snapshot => 1, from_base => 1 },     # full-copy (NON-CoW) — see below
  qos      => { per_lu => 1 },
  resize   => { grow_online => 1, shrink => 0 },
  transfer => { import => 1, migrate_pool => 1 },                    # nested for shape consistency
  replication => { tc => 1, ur => 1, gad => 1 },
}
```

Consumed by: `volume_has_feature`, `activate_storage` sanity checks, GUI field
enable/disable, and CLI exposure of optional extensions.

**Sharp semantic point** [Codex]: PVE's `clone_image` is specifically a **linked-clone
(persistent CoW child)** primitive. Only advertise `clone` where the backend gives a real
CoW child from base/snapshot.

**No full-copy offload hook exists in PVE** [Hitachi ADR 0002]. `qm clone --full` always
copies host-side (`qemu-img convert`, or `drive-mirror` for a running VM); `pve-storage`
exposes no `copy_image`/XCOPY/ODX plugin method, and `alloc_image` is handed no source
reference. So `clone_image` (CoW/linked) is the **only** array-offloaded clone PVE drives.
The `copy` capability and `create_full_clone` (§2) therefore describe **out-of-band /
`fclu`-CLI** offload or a *future* upstream `copy_image` hook — they are **not** wired to
`qm clone --full`, and a full-copy-only array simply falls back to PVE's host-side copy
(it is not "mis-driven"). The core MUST NOT route `clone_image` to `copy`. The upstream
`copy_image` hook has been requested at **Proxmox Bugzilla
[#7780](https://bugzilla.proxmox.com/show_bug.cgi?id=7780)** (pve/Storage); if accepted,
the driver's `create_full_clone` can be wired to array-side XCOPY/ShadowImage offload.

---

## 7. Registry & cross-cutting state → generic core [consensus]

`Config.pm`'s registry, `cfs_lock_domain` cluster locking, reservation/identity
enforcement, parent/dependent (clone) tracking, snapshot metadata, orphan detection, and
partial-failure rollback are **vendor-neutral** and move into `FCLU::Registry` /
`FCLU::Txn` essentially as-is. The dedicated lock domain (deliberately *not*
`cfs_lock_storage`, to avoid self-deadlock against PVE's own storage lock —
`Config.pm:160`) stays and stays generic.

**One change**: generalize the entry shape off the integer `ldev_id` to an opaque
`backend_id` + recorded identity [Codex]:

```perl
volname => {
  backend_id     => "1234",                 # opaque, was ldev_id
  identity       => { protocol=>'scsi-fc', ids=>{ naa=>'...' } },
  size_mb        => ...,
  pool_ref       => ...,
  parent_volname => ..., parent_snap => ...,
  protected      => 0,                       # PVE volume attr: blocks delete while set (#15)
  notes          => undef,                   # PVE volume attr: free-text passthrough (#15)
  backend_meta   => { ... },                # driver scratch space
  snapshots      => { ... },
}
```

The registry carries the PVE volume attributes `protected` and `notes`, surfaced through
the generic `get_volume_attribute`/`update_volume_attribute` (§5); a `protected` volume
refuses deletion in the core before any driver call. The cluster lock honours a
configurable `lock_timeout` (§5, #10), and `parse_volname` recognizes cloud-init volumes
(`vm-<vmid>-cloudinit`) alongside `vm-<vmid>-disk-N` — all vendor-neutral.

Vendor hooks the core still needs from the driver: ownership-label constraints
(length/charset — **not** a hardcoded 32 in the core), `list_lus`/`get_lu` rich enough
for orphan scans, an optional `safe_delete_precheck` (vendor-specific deletion rules),
and `get_lu_identity` after publish.

**Multi-node presentation** stays in core orchestration. Steady state is single-node
(the node where the volume is active), but the core MUST permit **transient dual-node
presentation** during live migration / HA failover — PVE maps the LU on the target node
*before* deactivating the source. `publish_lu` / `unpublish_lu` are therefore per-`%host_ctx`
(§2, §12.2), and the core may legitimately hold mappings on two nodes for the migration
window, tearing down the source side only after handover. Drivers MUST NOT assume a single
mapping exists when servicing `unpublish_lu`.

---

## 8. Replication — optional extension, **not** mandatory contract [consensus]

TC/UR/GAD vs Dell SRDF vs Pure ActiveCluster differ too much in quorum/witness, failure
handling, and CG coupling to force into the base contract; most second-tier arrays won't
support an equivalent at all. Keep it a **separate optional interface**, CLI-driven
initially (the existing `hitachiblock-repl` becomes `fclu-repl` dispatching to the
driver):

```perl
package PVE::Storage::FCLU::Driver::Replication;   # mixed in only by capable drivers
sub replication_capabilities { }
sub list_relationships       { }
sub create_relationship      { }
sub split_relationship       { }
sub resync_relationship      { }
sub delete_relationship      { }
```

Generic vocabulary where it fits (`sync` / `async` / `active-active`) with vendor
subtype annotations (GAD, SRDF/Metro, …). Gate exposure on the `replication` capability.

---

## 9. Migration path — Hitachi stays green throughout

Strangler-fig, one seam at a time; tests pass at every step:

1. **Extract state.** `Config.pm` → `FCLU::Registry` + `FCLU::Credentials` +
   `FCLU::Label`, no behavioral change. Repoint the Hitachi plugin at them.
2. **Extract host side.** `Multipath.pm` → `Host::FCMultipath`; keep Hitachi WWID
   synthesis temporarily as a private driver fallback only.
3. **Wrap, don't rewrite.** `RestClient.pm` → `Driver::Hitachi` implementing the
   contract. Transport untouched.
4. **Introduce `FCLU::Plugin`**, move read-only/common methods first: `status`,
   `list_images`, `volume_size_info`, shared `parse_volname` helpers.
5. **Move orchestration** alloc/free/activate/deactivate/resize/snapshot/clone into the
   generic plugin **one operation at a time**, swapping direct `RestClient` calls for
   driver-contract calls as you go.
6. **Add profile detection** + quirk handling behind the driver; delete scattered
   platform/microcode conditionals from the (now generic) plugin.
7. **Cutover.** `HitachiBlockPlugin` becomes the thin subclass: `type()=='hitachiblock'`,
   vendor schema + driver pick only. GUI unchanged.
8. **Validate the abstraction with a *second* driver** before trusting it (see §10).

**Moves ~verbatim:** registry+locking (incl. `lock_timeout`), snapshot/dependency
tracking, multipath rescan/wait/remove/resize/flush, much of the alloc/free/snapshot
rollback orchestration, the PVE-plugin surface (`status`/`list_images`/`volume_size_info`/
`parse_volname` plus PVE 9 `qemu_blockdev_options`, `volume_export`/`volume_import`,
`rename_volume`, `get`/`update_volume_attribute`), and the `protected`/`notes` attrs.
**Gets rewritten/relocated:** anything named `ldev`/`host_group`/`HMO`/`target_ports`,
WWID synthesis + vendor sysfs discovery, and any direct-REST assumptions in plugin logic.

---

## 10. Risks & sharp edges

- **`SectionConfig` duplicate properties** — keep core-defined props (`username`,
  `password`, …) out of vendor `properties()`; reference only. Already a live landmine.
- **Single `type()` registration** — reinforces thin-subclass-per-vendor over a dynamic
  umbrella type.
- **Taint mode (`pct -T`)** — every array-reported identity now flows into `exec`/`open`
  paths. Untaint WWIDs/paths at the connector boundary, exactly as `_run_cmd` /
  `get_device_path` do today. Array-supplied ids widen the tainted surface vs synthesized
  ones — validate shape (`/^[0-9a-f]+$/`) before use.
- **Safe unmap/delete** — rely on driver-authoritative `list_lu_mappings`, never a
  generic group scan; preserve the host-side-teardown-before-array-unmap ordering
  (`free_image`, the "LU is executing host I/O" interlock).
- **Async semantics** — job polling/retry/eventual-consistency stay inside each driver.
- **Don't hardcode array limits** (label length, min LU size, alloc granule) in the core
  — they live in the profile.
- **Host-access model variance** — host groups vs masking views vs host objects vs ACLs
  all differ; confine 100% of it to `ensure_host_access`/`publish_lu`/`unpublish_lu`.
- **Fabric zoning is an external prerequisite by default** — `ensure_host_access` is
  array-side masking only; it assumes the FC fabric is already zoned. Optional Brocade/Cisco
  automation is a separate capability-gated plane (§14), off by default, because it requires
  fabric-admin credentials on each node (a real trust-surface expansion).
- **One-LU-per-disk scaling limits** — per-disk array LUs consume host-group / masking-view
  / total-LU quotas and one multipath device per node per disk (100 VMs × 5 disks = 500 LUs
  mapped on *every* node). Each new disk is an array op + a SAN rescan on every node. Surface
  the array's limits via the Profile (§4) and document a practical ceiling. Zoning, by
  contrast, is per-node-pair not per-LU (§14), so it does not grow with disk count.
- **Abstraction-over-one-vendor risk** [all three, emphatically] — the contract will be
  silently Hitachi-shaped until a **second** driver exercises it. Treat driver #2 as the
  real design review, and pick it deliberately (see below).

### Testing strategy

- `Driver::Mock` (in-memory) → test the generic plugin state machine, rollback, and
  cluster locking with no array.
- Per-driver **contract tests** (every driver satisfies the same suite).
- Fixture/recorded-API tests for `Driver::Hitachi` response normalization.
- `Host::FCMultipath` tests against a **fake sysfs tree**.
- Rollback tests for partial failure after create/map/label/snapshot.

---

## 11. Packaging — multi-binary split, driver depends on core [Claude]

One git repo, one Debian **source** package, **multiple binary packages**: a
vendor-neutral core library plus **one binary package per vendor brand** (not per
model — model/microcode drift lives in the driver Profile, §4). PVE custom plugins
deploy as Perl modules under `/usr/share/perl5/PVE/Storage/Custom/*.pm` plus an ExtJS
panel, registered on `pvedaemon`/`pveproxy` restart — so each vendor package cleanly
owns its `Custom/<Vendor>BlockPlugin.pm`, its GUI panel, and its service-restart
`postinst`; core owns the shared spine and base widget.

```
pve-fclu-core        FCLU::{Plugin,Registry,Credentials,Label,Capabilities,Txn,
                     Driver(base),Host::*,Fabric::{base,Noop}} + shared JS. No vendor dep.
pve-fclu-hitachi     Driver::Hitachi + RestClient + thin HitachiBlockPlugin + vendor JS
pve-fclu-pure        Driver::Pure + thin plugin + vendor JS
pve-fclu-powermax    …
pve-fclu-hpe3par     Driver::HPE3par + thin plugin + vendor JS   (Primera/Alletra MP/3PAR)
pve-fclu-fabric-brocade   Fabric::Brocade — optional FC zoning (§14)
pve-fclu-fabric-cisco     Fabric::Cisco   — optional FC zoning (§14)
pve-fclu             optional metapackage: Depends core, Recommends common drivers
```

**Dependency direction is driver → core, never core → driver.** A driver without core
is useless (`Depends`); core without a driver is also useless, but core must stay
vendor-neutral and so must **not** name any vendor. There is therefore no "pull at least
one driver" obligation on core — it is **inverted**: the user's install entry point is
the *vendor* package, and `apt install pve-fclu-hitachi` pulls `pve-fclu-core`
transitively. A `Recommends` on some arbitrary default vendor would be wrong (no sensible
default across Hitachi/Dell/Pure). **The driver choice is left to the user at install
time** (core + the driver(s) for their array) — which also keeps each driver's own
dependencies (extra CPAN modules, differing `multipath`/`nvme-cli` sets) out of everyone
else's install. The optional `pve-fclu` metapackage is the only "give me everything"
convenience, and stays `Recommends`/`Suggests`, never a hard `Depends` on all drivers.

```
Package: pve-fclu-hitachi
Depends: pve-fclu-core (= ${binary:Version}), fclu-driver-api-1, ${perl:Depends}, multipath-tools
```

**Contract ABI versioning via a virtual provides.** The driver contract "will be
silently Hitachi-shaped until a second driver exercises it" (§10) — it *will* break
early. Decouple the contract version from the Debian version so breakage is explicit and
coexisting drivers stay safe: core `Provides: fclu-driver-api-1`; each driver
`Depends: fclu-driver-api-1`. Bump to `-api-2` on a contract break, so a stale driver
refuses to install against new core instead of failing at runtime inside pvedaemon.
While it is still core + Hitachi only, the stricter `Depends: pve-fclu-core
(= ${binary:Version})` lockstep is fine; relax to the `api-N` floor once driver #2 lands.

**Backward-compat rename.** The deployed `pve-storage-hitachiblock` package (the
reference plugin's Debian binary name) and its `type: hitachiblock` storage
definitions must survive the rename (§0). The Hitachi package carries
`Provides: pve-storage-hitachiblock`, `Replaces: pve-storage-hitachiblock`,
`Conflicts: pve-storage-hitachiblock` so `apt upgrade` swaps them cleanly and existing
`storage.cfg` keeps working verbatim. (The swap removes the old package wholesale;
`pve-fclu-hitachi` re-ships its web UI panel and the opt-in SCSI-3 PR systemd units, so
only the `hitachiblock-repl` replication CLI remains to be re-shipped.)

Cost is only more `debian/*.install` control files and CI matrix entries; OBS builds
multiple binaries from one source natively. Benefits: core stays dependency-light, a
smaller per-node trust surface (ship only the array's driver each node talks to), and
independent driver release cadence.

---

## 12. Driver API v1 — the normative contract (`fclu-driver-api-1`) [Claude]

This is the surface the packaging ABI (§11) pins, the contract-test suite asserts, and
every driver author implements. §2 lists the *methods*; this section freezes the *data
shapes and behavioural rules*. A change that alters any **MUST** below is a breaking
change and bumps the ABI to `api-2`. Adding an optional, capability-gated method, or a
new optional key to a hash, is **non**-breaking.

Keywords MUST / SHOULD / MAY are normative.

### 12.1 Core data types

All driver method inputs and outputs are plain Perl hashes/scalars — **never raw REST
payloads** (§2). Drivers normalize inbound array data into these shapes; the core never
sees a vendor field name.

**`backend_id`** — opaque LU handle.
- MUST be a non-empty string, treated as opaque by the core (no arithmetic, no ordering).
- MUST match `/^[\w.:-]{1,255}$/` so it is safe to interpolate into taint-mode
  `exec`/`open` paths (§10). Drivers that wrap an integer id (Hitachi `ldev_id`)
  stringify it.
- MUST be stable for the life of the LU and unique within one storage.

**`%host_ctx`** — node identity handed to host-access methods. Canonical shape:
```perl
{
  hostname   => 'pve-node-3',        # MUST: PVE node name
  protocol   => 'scsi-fc',           # MUST: enum, see below
  initiators => ['10000000c9...'],   # MUST: node-local initiator ids (FC: WWPNs, lowercase hex, no colons)
  node_meta  => { ... },             # MAY: driver scratch (opaque to core)
}
```

**`protocol`** — closed enum for v1: `scsi-fc` only. `scsi-iscsi`, `nvme-fc`,
`nvme-tcp` are **reserved** (§3) and adding one is non-breaking.

**LU descriptor** — `get_lu` / entries of `list_lus`:
```perl
{
  backend_id => '1234',              # MUST
  size_bytes => 53687091200,         # MUST: integer bytes (NOT MB — core converts at the edge)
  label      => 'pve:store1:vm-100-disk-0',  # MUST (may be undef if unlabelled)
  pool_ref   => '63',                # MUST: see pool_ref
  identity   => { ... },             # SHOULD if known pre-publish; MUST after publish_lu
  backend_meta => { ... },           # MAY: driver scratch, round-tripped verbatim by core
}
```

**`identity`** — canonical device identity, the single source of truth for host matching
(§3, replaces WWID synthesis):
```perl
{
  protocol => 'scsi-fc',
  ids => { naa => '60060e8012...', eui => undef, wwid => undef },   # at least one MUST be set
}
```
- The `naa`/`eui`/`wwid` values MUST be array-reported, lowercase hex, shape-validated by
  the driver before return (taint surface, §10).

**`pool_ref`** — opaque pool/pool-group handle (string), same opacity rules as
`backend_id`.

**Capability object** — normative schema (the §6 example, frozen). Every documented
**top-level branch** (`snapshot`, `clone`, `copy`, `qos`, `resize`, `transfer`,
`replication`) MUST be present. Within a branch, an unsupported feature is expressed as
`0` (preferred) or by omission of that leaf key — the two are equivalent, and the core
treats any absent or unknown key as `0`. Omitting a whole top-level branch is
non-conformant. `copy` (full, non-CoW copy) is distinct from `clone` (CoW child): a
full-copy-only array MUST advertise `copy` and `clone => {}` so PVE does not mis-drive
`clone_image` (§6).

**Snapshot descriptor** — `list_snapshots` entries / `create_snapshot` return:
```perl
{ snap_id => 'opaque-string', parent_backend_id => '1234', created => 1719500000, meta => {} }
```
`snap_id` follows the `backend_id` charset rule.

**`access_handle`** — opaque token returned by `ensure_host_access(%host_ctx)` identifying
the per-node host object / group / masking-view the driver maps into. Same opacity +
charset rules as `backend_id`. The core round-trips it (or re-passes `%host_ctx`) to
`publish_lu` / `unpublish_lu`.

**Mapping descriptor** — entries of `list_lu_mappings($backend_id)`, the **sole authority
for safe unmap** (§2, §10, §12.3):
```perl
{
  hostname     => 'pve-node-3',       # MUST: node this mapping exposes the LU to
  access_ref   => 'PVE_pve-node-3',   # MUST: opaque host-object/group/masking-view id
  lun          => 7,                  # SHOULD: SCSI LUN number, if the array assigns one
  target_wwpns => ['50060e80...'],    # SHOULD: array target ports carrying this mapping
}
```
The core matches `hostname` to decide which node's mapping to tear down; absence of a node
in this list means "not mapped there" (drives idempotent `unpublish_lu`, §12.2).

**Target endpoint** — entries of `target_ports()`, consumed by fabric zoning (§14):
```perl
{ wwpn => '50060e80...', port_id => 'CL1-A' }   # wwpn array-reported, lowercase hex
```

### 12.2 Idempotency & retry contract

The core's Txn/rollback layer (§7) assumes these properties; drivers MUST provide them.

| Method | Idempotent? | On "already in desired state" | Retry-safe? |
|---|---|---|---|
| `connect` / `ping` | yes | no-op | yes |
| `create_lu` | **no** (allocating) | — | only via `requested_id` re-assert (see below) |
| `delete_lu` | **yes** | return success, MUST NOT throw "not found" | yes |
| `ensure_host_access` | **yes** (MUST) | no-op success | yes |
| `publish_lu` | **yes** (MUST) | return existing mapping, no error | yes |
| `unpublish_lu` | **yes** (MUST) | success if already unmapped | yes |
| `set_lu_label` / `resize_lu` / `set_lu_qos` | **yes** (converge to target) | no-op success | yes |
| `create_snapshot` | no | — | via `snap_id` re-assert |
| `delete_snapshot` | **yes** | success if absent | yes |
| `list_*` / `get_*` / `*_identity` | yes (read-only) | — | yes |

- **Allocating calls** (`create_lu`, `create_snapshot`) accept an optional caller-supplied
  id (`requested_id` / `snap_id`). If the object with that id already exists **and matches
  the requested attributes**, the driver MUST return it as success (makes the create
  retry-safe after a core crash mid-Txn); if it exists but mismatches, the driver MUST
  fail.
- `ensure_host_access` MUST be safe to call on every `publish_lu` (the core does not track
  host-object state — the driver reconciles).
- **Host-access methods are node-targeted.** `ensure_host_access(%host_ctx)`,
  `publish_lu($backend_id, %host_ctx)` and `unpublish_lu($backend_id, %host_ctx)` all act on
  the host identified by `%host_ctx` (or the returned `access_handle`). The core MAY hold
  mappings on two nodes at once during live migration (§7); `unpublish_lu` MUST remove only
  the `%host_ctx` node's mapping and leave others intact.

### 12.3 Authoritative reads

- **`list_lu_mappings` is the sole authority for unmap/delete safety** (§2, §10). The core
  MUST NOT infer mappings from `list_lus` or any group scan. Drivers MUST return the real
  per-LU mapping set (Hitachi: `get_ldev->{ports}`) as **Mapping descriptors** (§12.1), not
  a filtered list whose server-side filter may be a client-side no-op.
- `list_lus` MUST be complete enough for orphan detection: every LU the driver could have
  created under this storage's pool, with at least `backend_id` + `label`.

### 12.4 Error signalling (summary — full taxonomy in §13)

A failing method MUST `die` with a blessed `PVE::Storage::FCLU::Error` carrying at least
`{ code, retryable, transient }` (§13). Bare-string `die` is non-conformant. `retryable
=> 1` asserts the call left **no partial side effect**; anything that may have
half-applied MUST be `retryable => 0` so the core compensates via Txn. Async job polling,
endpoint failover, and eventual-consistency waits stay **inside** the driver (§2) — a
method MUST NOT return until array state is observable, or it fails.

### 12.5 Conformance

`Driver::Mock` implements this surface exactly and is the executable reference. The
per-driver contract-test suite (§10) is the same test file parametrized over every
driver; passing it is the definition of "conforms to `fclu-driver-api-1`".

---

## 13. Error taxonomy [Claude]

The model the Txn/rollback layer (§7) and the retry policy sit on. Drivers raise **one
normalized error type** regardless of vendor; the core decides retry-vs-compensate-vs-fail
from its classification, and the PVE boundary renders an admin-facing message. Raw vendor
REST errors never reach the GUI and never drive control flow directly — the driver
**translates** them at its boundary.

### 13.1 The error object

```perl
package PVE::Storage::FCLU::Error;   # blessed exception, the ONLY thing drivers die() with
{
  code      => 'array_busy',   # MUST: closed vocabulary, §13.3
  message   => '...',          # MUST: normalized, admin-safe, NO raw vendor payload
  retryable => 0|1,            # MUST: safe to re-issue the same call unchanged?
  transient => 0|1,            # MUST: root cause expected to clear on its own?
  vendor    => { ... },        # MAY: raw vendor error/job result — for LOGS only, never GUI
  cause     => $err,           # MAY: wrapped lower-level exception
}
```

Classification is carried by the two booleans + `code`; `code` is authoritative. Drivers
MAY also bless into thin subclasses (`...::Error::Auth`, `...::Error::OutOfSpace`) for
`isa`-based `catch`, but the core branches on `code`, not class.

### 13.2 Classification axes (orthogonal)

- **`retryable`** — may the core re-call this exact method, unchanged, and expect
  correctness? TRUE **only** when the failed call left no partial side effect. This is the
  property §12.2 promises per method; an error contradicting it is a driver bug.
- **`transient`** — is the cause temporary (network blip, array busy, lock contention,
  async-job timeout) vs structural (auth, out-of-space, unsupported, bad argument)?

The two are independent. A timeout *mid-mutation* is `transient => 1, retryable => 0`: the
condition is temporary but the call may have half-applied, so the **operation** can be
retried only after the core compensates the partial step — the **method** cannot be blindly
re-issued.

### 13.3 Code vocabulary (closed for v1)

| `code` | Meaning | Typical `retryable` | Typical `transient` | Core action |
|---|---|---|---|---|
| `connectivity` | endpoint unreachable / TLS / connect timeout | 1 | 1 | backoff + retry, then fail |
| `auth` | credentials rejected / session invalid | 0 | 0 | fail fast → surface to admin |
| `array_busy` | array threw busy / throttle / concurrent-op lock | 1 | 1 | backoff + retry |
| `conflict` | precondition / optimistic-lock / state mismatch | 0 | 1 | re-read state, caller re-plans |
| `not_found` | object absent | — | 0 | **see note** |
| `already_exists` | id collision, **mismatched** attributes (§12.2) | 0 | 0 | fail → orphan/registry reconcile |
| `out_of_space` | pool capacity exhausted | 0 | 0 | fail → surface to admin |
| `limit` | array object/host-group/LU count limit hit | 0 | 0 | fail → surface to admin |
| `unsupported` | capability/firmware missing (should be cap-gated, §6) | 0 | 0 | fail → driver/capability bug |
| `invalid` | bad argument / shape | 0 | 0 | fail → programming error |
| `timeout` | async job didn't converge in budget | 0* | 1 | compensate then maybe retry |
| `partial` | operation half-applied, compensation required | 0 | — | run Txn rollback for the step |
| `internal` | driver bug / unexpected vendor payload | 0 | 0 | fail → log `vendor`, file bug |

`*` `timeout` is `retryable => 1` **only** for read-only methods; for any mutation it is
`retryable => 0` (treat as `partial`).

**`not_found` note:** for the idempotent teardown methods (`delete_lu`, `delete_snapshot`,
`unpublish_lu`) the driver MUST convert "not found" into **success** internally (§12.2) and
NOT raise. `code => 'not_found'` is therefore only ever raised by *read/mutate* methods
(`get_lu`, `resize_lu`, …) where absence is a real error.

### 13.4 How the core consumes it

- `partial`, or any mutation failing `retryable => 0`, ⇒ the core runs the registered
  **compensation** for that Txn step (§7) before deciding whether to re-drive the
  operation. The driver does not roll back across methods — the core orchestrates it.
- `retryable => 1 && transient => 1` ⇒ bounded exponential backoff retry; the retry budget
  lives in the **core**, not the driver. (Driver-internal retries — async job polling,
  endpoint failover — are invisible to this and already happened, §2.)
- `retryable => 1 && transient => 0` ⇒ a clean no-op failure (e.g. read-only `timeout` on a
  dead path during failover); retry once cheaply, else fail.
- Structural codes (`auth`, `out_of_space`, `limit`, `unsupported`, `invalid`) ⇒ fail fast,
  no retry — retrying cannot help and burns the operation's time budget.

### 13.5 PVE boundary mapping

`FCLU::Plugin` is the single place that catches `FCLU::Error` and turns it into what PVE
expects (a plain `die "<message>\n"` for storage ops). It:
- renders `message` (admin-safe) to the GUI/task log, never the `vendor` blob;
- logs `code` + `vendor` + `cause` to syslog/the task log for diagnosis;
- untaints nothing from `vendor` into any message that may re-enter `exec`/`open` (§10) —
  vendor strings are log payload only.

Drivers therefore stay **PVE-agnostic**: they raise structured errors; only the core knows
about PVE error conventions.

### 13.6 Async & timeout budget

Each driver owns its async-job timeout and emits `timeout` (read) / `partial` (mutation)
when the budget is exceeded — it MUST NOT hang indefinitely or return optimistically before
the array reflects the change (§2, §12.4). The per-operation wall-clock budget is a driver
Profile field (§4), not a core constant.

`Driver::Mock` can be told to raise any `code` on demand, so the contract suite (§12.5)
asserts the core's retry/compensate behaviour for every classification.

---

## 14. Fabric / FC zoning — optional third concern [Claude]

The architecture has two mandatory control planes — the **array** (`Driver::*`, §2) and
the **Linux host** (`Host::*`, §3). FC **zoning** is a *third* plane: the fabric switches
(Brocade FOS, Cisco MDS NX-OS). The base design deliberately does **not** require it —
`ensure_host_access` (§2) is array-side masking only and **assumes the initiator↔target
zoning already exists** (the current Hitachi plugin works exactly this way). Zoning
automation is therefore an **optional, capability-gated extension**, structured like
replication (§8): present the seam now, default to a no-op, build real drivers later.

```perl
package PVE::Storage::FCLU::Fabric;          # mixed in only when zoning automation is enabled
sub fabric_capabilities { }   # { zoning => 1, zone_mode => 'peer'|'wwpn'|'port', activate => 1 }
sub ensure_connectivity { }   # (initiators=>[wwpns], targets=>[wwpns]) -> idempotent zone + activate
sub remove_connectivity { }   # tear down zones created for this initiator/target set
sub list_zones          { }   # AUTHORITATIVE current zoning, for safe teardown
```

- **`Fabric::Noop`** is the default and preserves today's behaviour: the admin pre-zones
  the fabric, PVE touches nothing. Real drivers (`Fabric::Brocade`, `Fabric::Cisco`) are
  separate packages (§11), selected per storage.

**Orchestration ordering.** Zoning is created **before** array masking, which is created
**before** host attach; teardown reverses it:

1. `Host::Connector->host_context` → initiator WWPNs
2. `Driver->target_ports` → array target WWPNs (§2)
3. `Fabric->ensure_connectivity(initiators, targets)` → create + activate zones on **each**
   fabric (dual-fabric SANs are zoned independently)
4. `Driver->ensure_host_access` + `publish_lu` → array-side masking (§2)
5. `Host::Connector->attach` → rescan + multipath (§3)

Teardown: `detach` → `unpublish_lu` → (optionally) `remove_connectivity`.

**Zoning is per-node-pair, not per-LU.** WWPN/port zoning between a node and an array is
created once and reused by every LU on that path, so the Fabric hook fires at
`activate_storage` / first publish for a node, **not** per `alloc_image`. This is why the
layer is cheap, and why one-LU-per-disk (§10) does not multiply zoning work.

**Prior art.** This mirrors OpenStack Cinder, which separates volume drivers from a
distinct `FCZoneManager` with Brocade/Cisco sub-drivers, driven by `initialize_connection`
/ `terminate_connection` returning initiator-target maps. The split (array driver ⟂ fabric
zoner ⟂ host connector) is proven there.

**Trust surface** [important]. Automated zoning requires **fabric-admin credentials on each
PVE node** (or a privileged proxy) — the same objection that sank the out-of-process broker
(*Considered alternatives*). Many sites keep zoning change-controlled under the SAN team.
Hence the default is `Fabric::Noop`; automation is strictly opt-in and gated on
`fabric_capabilities`.

**Independent ABI.** The Fabric contract versions separately (`fclu-fabric-api-1`), so
adding or breaking it does **not** move the array driver ABI (`fclu-driver-api-1`, §11/§12).

---

## Open decisions for the maintainer

1. **Second driver choice (validation target).** [Claude] recommends **Pure FlashArray**
   first — clean REST, host/host-group objects, array-reported NAA, simple QoS — to
   shake out Hitachi-shaped assumptions cheaply; then **Dell PowerMax** to stress the
   host-access abstraction (masking views) and replication. Confirm priority.
2. **Repo strategy.** ~~One repo shipping core + all drivers as one package, vs core
   package + per-vendor add-on packages.~~ **Resolved — see §11:** one source package →
   multi-binary `pve-fclu-core` + per-vendor `pve-fclu-<brand>`, drivers depend on core,
   user installs the vendor package they need. Confirm before first OBS build.
3. **Label/ownership scheme** across vendors — keep `pve:<storeid>:` with per-driver
   length/charset limits from the profile.
4. **`fclu-repl`** — generalize the replication CLI now, or defer until a second
   replication-capable backend exists.
5. **HPE & NetApp scope.** [Claude] HPE is three unrelated control planes — Primera /
   Alletra MP / 3PAR (WSAPI → `Driver::HPE3par`), Alletra 5000/6000 (Nimble → a separate
   `Driver::Nimble`), and Alletra 9000 / XP8 (rebadged Hitachi VSP → reuse `Driver::Hitachi`
   *only* if Configuration Manager REST is exposed). NetApp ONTAP (igroup / LUN-map) is now
   in the §2 table — confirm it stays in scope. Decide which HPE families ship, and in what
   order, relative to the §10 second-driver validation target.
6. **FC zoning automation (§14).** Ship `Fabric::Noop` only (assume pre-zoned) for v1, or
   build `Fabric::Brocade` / `Fabric::Cisco` now? Weigh demand against the fabric-credential
   trust-surface cost before committing.

---

## Considered alternatives

### Out-of-process broker (REJECTED)

A fourth-model review proposed a two-tier design: a near-empty Perl shim that forwards
PVE hooks as JSON over a local socket to a **Python/FastAPI broker daemon** on each node,
which performs vendor REST via official SDKs (Dell PyU4V / PyPowerStore, etc.). Rejected
— it loses to the in-process Perl design on the factors that matter for a PVE storage
plugin:

- **Its premises don't hold.** "REST in Perl is too painful" is disproven by the
  existing `RestClient.pm` (async job polling, multi-endpoint failover, pagination —
  already working). "Stateless, state lives on the array" ignores the **mandatory
  cluster registry** (volname↔LU identity, snapshot/clone parentage, atomic
  reservations) that must live on pmxcfs under corosync locks regardless — see §7.
- **It doesn't shrink the hard part.** Host-side multipath/SCSI/sysfs, taint-mode
  untainting, device-path resolution, and the registry+locking all stay on the node in
  Perl. The broker offloads only array REST while importing a whole second runtime.
- **It adds operational, availability, and security cost** — a daemon per node to
  package/boot-order/upgrade, a new *broker-down → storage-down* failure mode, and a
  local service holding array-admin credentials.

**What was salvaged from it** and folded into this document:
- The concrete **vendor control-plane / object / host-access table** (§2) — the
  proposal's most useful contribution.
- **SDK-as-reference**: the official vendor Python SDKs (PyU4V for PowerMax/Unisphere,
  PyPowerStore for PowerStore, vendor Configuration-Manager tooling for Hitachi) are
  excellent **reference implementations** to mine when authoring each Perl driver —
  auth flows, object models, quirks — *without* taking them as a runtime dependency.
- The design value it optimized for — **a low barrier to contribute a new vendor** — is
  kept, and met in-process by the thin-driver model (§1, §5): adding a backend is one
  `Driver::<Vendor>` plus a ~50-line plugin subclass, no daemon to touch.
