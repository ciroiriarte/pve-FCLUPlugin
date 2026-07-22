# ADR 0003 — Shard nodes across FC target-port groups within one storeid

- **Status:** Accepted (static-config first pass; derive-from-login deferred)
- **Date:** 2026-07-22
- **Issue:** #5 (framework-core). Related: #4 (control-plane session scaling), #1 (FC
  zoning automation), #2 (PR / shared-LU).
- **Scope:** Hitachi reference driver today; the modelling (per-node port resolution) is
  universal to FC arrays and belongs to the framework.

> First entry under `docs/adr/`. ADRs record a decision, its context, and the
> alternatives rejected — so a future reader knows *why*, not just *what*. (ADR 0001 and
> 0002 are referenced in ARCHITECTURE.md as Hitachi-plugin decisions predating this repo.)

## Context

A "LU path" is consumed per **(LDEV × host-group × port)**. The Hitachi per-front-end-port
budget — **2,048** LU paths/port on midrange, **4,096** on high-end, and **255** host
groups/port — is the **aggregate across every host group on that physical port**.

The plugin maps every node's host group (`PVE_<hostname>`) onto **all** `target_ports`. If
the whole cluster shares the same two ports (e.g. CL1-A/CL2-A for MPIO), those two ports
must absorb the **entire cluster's** live mapped disks — a hard ceiling of **~2,048
concurrently-mapped disks cluster-wide, regardless of node count**. Late binding (map only
on the running node, unmap on migrate) fixes host-side device explosion but does **not**
relieve this per-port budget.

## Decision

Shard PVE nodes across **disjoint front-end target-port groups**, each ideally ≥2 ports on
different controllers (MPIO + controller-failover HA), **within one storage definition** so
free live migration is preserved.

- Two optional Hitachi config properties, **default off** (unset ⇒ today's behavior,
  byte-for-byte):
  - `port_groups` — named groups: `g1=CL1-A,CL2-A g2=CL3-A,CL4-A` (group labels arbitrary
    but unique; every port must be in `target_ports`).
  - `node_port_groups` — node→group: `pve01=g1 pve02=g1 pve03=g2 pve04=g2`. The node key is
    the **PVE cluster node name** (`PVE::INotify::nodename()` — what `pvecm nodes` shows and
    what the `PVE_<node>` host groups are named after).
- A driver helper **`_resolve_local_ports($hostname)`** returns the node's port subset
  (feature off or node unmapped ⇒ all `target_ports`; assigned ⇒ its group's ports). The
  four per-node mapping loops — `ensure_host_access`, `publish_lu`, `unpublish_lu`,
  `reclaim_empty_host_groups` — iterate that subset instead of all `target_ports`.
- **Validation** at driver construction (only when the feature is on): a group port outside
  `target_ports` or a node assigned to an undefined group is a **fatal** config error (both
  are typos that would silently strand a node); a group with <2 ports **warns** (no HA).
- **Composes with `port_scheduler`, does not replace it:** the resolved group is the port
  set within which `port_scheduler` would spread volumes (`ldev_id % n`); a 2-port group
  makes that a no-op. (`port_scheduler` itself is presently an unwired stub.)

Capacity, with sharding on:

```
4 groups × 2,048 ≈ 8,192  live disks (midrange)
4 groups × 4,096 ≈ 16,384 live disks (high-end)
```

Also relieves the 255-host-group/port limit — each port hosts only its group's nodes.

## Consequences

- **Migration preserved:** one `storeid`, per-node resolution at runtime. A same-group
  migration briefly double-counts LU paths during handover, so size each group with
  headroom. The destination's zoning must pre-exist; WWID/NAA is derived from the LDEV so
  multipath identity is stable across ports; the destination does a targeted rescan + settle
  before QEMU opens the disk.
- **Manual zoning is a prerequisite.** The plugin does not program the fabric (yet, #1). An
  unmapped node safely falls back to all ports; a node whose group ports it cannot reach
  fails loud in `ensure_host_access` (no path on any of its ports).
- **Assignment is explicit** while zoning is manual. `hash(nodename)`/round-robin/
  least-loaded become viable only once the plugin can program the fabric to match its own
  computed assignment (auto-zoning, #1).
- **Drain a node before changing its assignment or first enabling sharding.** Per-node
  resolution narrows `publish_lu`/`unpublish_lu`/`reclaim_empty_host_groups` to the node's
  *current* ports. If a volume is mapped on a node's old ports and the node is then
  reassigned (or sharding is enabled while volumes are already mapped on the full port set),
  a later `unpublish_lu` looks only at the new ports and leaves the old LU paths + empty
  host groups behind — they keep consuming the old port's LU-path / host-group budget.
  Mitigation: `unpublish_lu_all` (used by `free_image`/delete) iterates the LDEV's
  *actual* mapped ports, so deleting the volume self-heals the leak; but a
  reassigned-then-migrated (not deleted) volume does not. **Operational rule:** unpublish /
  migrate a node's volumes off before you change its `node_port_groups` entry or enable the
  feature. A future cluster-wide sweep over excluded ports could automate the cleanup.

## Rejected / deferred alternatives

- **`nodes=`-scoped multi-storage** (one storeid per port group, node-restricted):
  **rejected** — it blocks migration outside the node subset, defeating the point.
- **NPIV:** **rejected** — trades the LU-path wall for a worse 255-HG/port +
  zone-transaction-per-migration wall, with no QEMU/PVE support.
- **Derive the port set from the array's per-port fabric-login table** (`chosen = policy ∩
  available_from_login`), eliminating config drift: **deferred**. It needs a RestClient
  `/ports` list and a per-port login-table read that do not exist yet — they "land with the
  Fabric plane" alongside auto-zoning (#1). The static explicit map is the first pass; the
  login intersection becomes an optional overlay when that infra exists.
