# FCLU — First-class Logical Unit framework: Architecture Proposal

A vendor-neutral Proxmox VE storage framework that delivers first-class
per-virtual-disk volume service (**one array LUN per virtual disk**, array-offloaded snapshots/clones/QoS/replication)
over Fibre Channel, with per-vendor drivers (Hitachi today; Dell, Pure, IBM, NetApp
next). Refactored out of `pve-HitachiBlockPlugin`.

> **Provenance.** This is a joint review. The design was produced by Claude from a
> full read of the Hitachi plugin, then cross-checked against two independent model
> reviews of the same brief — **Codex** (`docs/architecture/review-codex.md`) and
> **agy / Gemini 3.1 Pro** (`docs/architecture/review-gemini.md`), both answering the
> shared brief in `docs/architecture/brief.md`. All three converged on the major
> decisions; divergences and adjudications are flagged inline as **[consensus]**,
> **[Codex]**, **[agy]**, **[Claude]**.

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

PVE::Storage::FCLU::Driver            # ARRAY BACKEND contract (base class / role)
PVE::Storage::FCLU::Driver::Hitachi   # Hitachi adapter wrapping the existing RestClient
PVE::Storage::FCLU::Driver::Hitachi::Profile   # model/microcode quirk profiles
PVE::Storage::FCLU::Driver::Mock      # in-memory fake backend for core/orchestration tests

PVE::Storage::FCLU::Host::Connector   # HOST-SIDE contract (attach/detach/resize/path)
PVE::Storage::FCLU::Host::FCMultipath # current Linux FC + multipath implementation

PVE::Storage::Custom::HitachiBlockPlugin   # THIN registered plugin: type()='hitachiblock',
                                           # vendor schema only, picks the Hitachi driver
```

Three clean responsibility boundaries:

- **`Driver::*` — array semantics only.** Knows LDEVs/host-groups/Thin-Image/REST jobs.
  The core never sees a host group, masking view, storage group, or REST job id.
- **`Host::*` — Linux side only.** Knows sysfs, multipath, SCSI/`blockdev`. Vendor-blind.
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
sub delete_lu          { }   # ($backend_id)
sub get_lu             { }   # ($backend_id) -> normalized {size,label,pool,...}
sub list_lus           { }   # (%filter) -> for orphan scans & allocation fences
sub set_lu_label       { }
sub resize_lu          { }   # grow online
sub set_lu_qos         { }   # optional (capability-gated)
sub get_lu_qos         { }
sub migrate_lu         { }   # optional: pool/tier migration

# --- host access (THE key abstraction — see note) ---
sub ensure_host_access { }   # idempotent host-object/group/mask setup for %host_ctx
sub publish_lu         { }   # map/export $backend_id to this node
sub unpublish_lu       { }   # remove the mapping for this node
sub list_lu_mappings   { }   # AUTHORITATIVE source for safe-unmap decisions

# --- identity ---
sub get_lu_identity    { }   # -> { protocol=>'scsi-fc', ids=>{ naa=>'...', eui=>..., wwid=>... } }

# --- snapshots / clones (capability-gated) ---
sub create_snapshot    { }
sub delete_snapshot    { }
sub restore_snapshot   { }
sub list_snapshots     { }
sub create_linked_clone{ }   # persistent CoW child (PVE clone_image primitive)
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

The spread — three- vs one-object masking, per-port host groups vs cluster-wide host
objects — is exactly why host access cannot be generic. So the core must speak only
`ensure_host_access(%host_ctx)` / `publish_lu` /
`unpublish_lu`, where `%host_ctx` carries `{ hostname, protocol, initiators => [wwns] }`.
The current `_ensure_host_groups` / `_map_lun_to_local` / `_unmap_lun_from_local` logic
(`HitachiBlockPlugin.pm:1326–1505`), including HMO reconciliation and host-mode options,
moves **into `Driver::Hitachi` verbatim** — it is Hitachi-specific and does not belong
in the generic plugin.

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
  capabilities => { linked_clone => 1, qos => 1, cg_snapshot => 1 },
  quirks => {
    list_luns_ignores_lu_filter => 1,   # client-side filter fallback
    used_pool_capacity_missing  => 1,   # status() field fallback (Plugin.pm:418 today)
    supports_hmo_91             => 1,
    hostWwnNickname_unsupported => 1,    # E-series add_wwn quirk
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
- Generic, safe-to-share properties (`pool_id`, generic QoS defaults, `tls_*`,
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
  clone    => { linked => 1, full => 1, from_snapshot => 1, from_base => 1 },
  qos      => { per_lu => 1 },
  resize   => { grow_online => 1, shrink => 0 },
  import => 1, migrate_pool => 1,
  replication => { tc => 1, ur => 1, gad => 1 },
}
```

Consumed by: `volume_has_feature`, `activate_storage` sanity checks, GUI field
enable/disable, and CLI exposure of optional extensions.

**Sharp semantic point** [Codex]: PVE's `clone_image` is specifically a **linked-clone
(persistent CoW child)** primitive. Only advertise `clone` where the backend gives a
real CoW child from base/snapshot. Full-copy-only arrays must expose a `copy` capability
instead, or PVE will mis-drive them.

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
  backend_meta   => { ... },                # driver scratch space
  snapshots      => { ... },
}
```

Vendor hooks the core still needs from the driver: ownership-label constraints
(length/charset — **not** a hardcoded 32 in the core), `list_lus`/`get_lu` rich enough
for orphan scans, an optional `safe_delete_precheck` (vendor-specific deletion rules),
and `get_lu_identity` after publish. Active-node-only mapping stays in the core
orchestration.

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

**Moves ~verbatim:** registry+locking, snapshot/dependency tracking, multipath
rescan/wait/remove/resize/flush, much of the alloc/free/snapshot rollback orchestration.
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

## Open decisions for the maintainer

1. **Second driver choice (validation target).** [Claude] recommends **Pure FlashArray**
   first — clean REST, host/host-group objects, array-reported NAA, simple QoS — to
   shake out Hitachi-shaped assumptions cheaply; then **Dell PowerMax** to stress the
   host-access abstraction (masking views) and replication. Confirm priority.
2. **Repo strategy.** One repo (`pve-FCLUPlugin`) shipping core + all drivers as one
   package, vs core package + per-vendor add-on packages. Affects OBS/Debian packaging.
3. **Label/ownership scheme** across vendors — keep `pve:<storeid>:` with per-driver
   length/charset limits from the profile.
4. **`fclu-repl`** — generalize the replication CLI now, or defer until a second
   replication-capable backend exists.

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
