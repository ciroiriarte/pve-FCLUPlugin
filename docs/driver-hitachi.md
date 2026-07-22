# Hitachi VSP Driver — `pve-fclu-hitachi`

Hitachi-VSP-specific documentation for the FCLU Hitachi driver. This complements the
vendor-neutral [`user-guide.md`](user-guide.md) — install, credentials, multipath,
multi-cluster safety, and migration are documented there and are not repeated here.

> Design authority: `ARCHITECTURE.md` §4 (profiles/quirks), §6 (capabilities), §7
> (allocation fence). Storage type is `hitachiblock` (backward-compatible with the
> legacy single-vendor plugin).

## Platform (model) & control plane (§4)

Two **orthogonal** axes select the driver's behavior:

**`platform`** — the array MODEL family, which governs *capabilities*:

| `platform`          | Family                              | QoS |
| ------------------- | ----------------------------------- | --- |
| `vsp_one` (default) | VSP One Block                       | no  |
| `vsp_e`             | VSP E series (E590/E790/E990/E1090) | no  |
| `vsp_g`             | VSP F/G350–900                      | yes |

**`control_plane`** — WHERE the Configuration Manager REST API lives (both speak the
*same* API — this only picks the endpoint):

| `control_plane`       | Endpoint                                        | Default port |
| --------------------- | ----------------------------------------------- | ------------ |
| `embedded` (default)  | The array's own built-in GUM REST               | 443          |
| `cm`                  | A fronting Ops Center **Configuration Manager** server | 23451 |

The axes combine freely: a VSP E fronted by an Ops Center CM is `platform=vsp_e` +
`control_plane=cm` (QoS still correctly gated off — it's the *model* that lacks QoS,
not the control plane). `mgmt_port` overrides the port either way.

- **`storage_id`** (`fixed`) — the array's `storageDeviceId` (the 12-digit
  model+serial id from `GET /v1/objects/storages`), **not** the bare serial.
- **`rest_keepalive`** — keep a persistent REST session per process instead of
  authenticating each request. The default is **session-less** (basic auth per
  request), which avoids exhausting the array's per-array session cap on large
  clusters. **A `control_plane=cm` store must stay session-less** (leave
  `rest_keepalive` off) — the CM does not expose the per-storage session endpoint.

### Using an Ops Center CM control plane (`control_plane=cm`)

1. Set `mgmt_ip` to the **CM server** host and `control_plane=cm` (port defaults to
   23451). Keep `platform` set to the array's real model.
2. The array must be **registered on the CM** first (`POST
   /ConfigurationManager/v1/objects/storages` with the array's `ctl1Ip`/`ctl2Ip`,
   `serialNumber`, `model`) — authenticated with the **array** credentials, not the
   CM's. Credentials for the store are the array's REST user (the CM proxies auth).
3. Leave `rest_keepalive` off (session-less, the default).

## Provisioning & the fence (§7)

| Property     | Default | Notes |
| ------------ | ------- | ----- |
| `pool_id`    | — (`fixed`) | DP pool for volume (LDEV) allocation. |
| `snap_pool_id` | = `pool_id` | Thin Image pool for snapshots/clones. |
| `ldev_range` | — | Restrict LDEV-id allocation, dec (`1000-1999`) or hex (`0x3E8-0x7CF`). |
| `copy_speed` | 3 | Array-side clone copy speed (1–15). |
| `discard_zero_page` | 0 | Reclaim zero-filled pages on deactivation (thin-pool recovery). |

- **Backend id = the LDEV id** (an opaque string). Allocation picks the next free
  id, **excluding array-DEFINED ids and registry-reserved ids**.
- **`ldev_range` is dual-purpose:** the allocation window *and* the §7 destructive-op
  fence — the plugin refuses to unmap or delete any LDEV outside the range, so it can
  never touch a foreign volume that merely shares a target port.
- **CU alignment:** a Hitachi Control Unit spans 256 LDEV ids; the plugin emits a
  CU-alignment hint for ranges. On a pool shared by multiple clusters, give each
  cluster a **disjoint** range (see the shared-pool section of the user guide).

## Host access

| Property             | Default        | Notes |
| -------------------- | -------------- | ----- |
| `target_ports`       | — (`fixed`)    | Comma-separated FC target port IDs (e.g. `CL1-A,CL2-A`). |
| `host_mode`          | `LINUX/IRIX`   | Host mode for host-group creation. |
| `host_mode_options`  | `2,22,25,68`   | HMO numbers set on the plugin's host groups. `68` = WRITE SAME / SCSI UNMAP for in-guest `fstrim`; `2,22,25` = Veritas / SPC-3 PR reservation compatibility. `''` disables. Added idempotently to existing groups (never removed). |
| `skip_unmap_io_check`| 0              | Adds HMO **91** (skip the array's host-I/O check on LUN-path deletion) so unmap on `free_image` succeeds immediately. Safe because teardown is host-first. |
| `port_scheduler`     | 0              | Spread LUN mappings across target ports with stable, deterministic per-LDEV port selection. |
| `group_delete`       | 0              | Auto-delete empty host groups on storage deactivation. |
| `host_group_prefix`  | `PVE`          | See below + the user guide's shared-pool section. |
| `port_groups`        | — (off)        | Port-group sharding (#5): named groups, `g1=CL1-A,CL2-A g2=CL3-A,CL4-A`. See below. |
| `node_port_groups`   | — (off)        | Node→group assignment for `port_groups`, `pve01=g1 pve02=g1 pve03=g2`. |

**Host groups** are named `<host_group_prefix>_<hostname>`, one per FC target port.
The prefix defaults to a stable short **`PVE`** (matching groups created as
`PVE_<hostname>`). It is **only a human label** — a physical WWPN is globally unique
and the WWN-ownership guard fail-closes any residual collision. Set a distinct short
prefix per cluster on a shared pool.

- **Adopt-by-WWN:** existing legacy `PVE_<hostname>` groups are **adopted in place**,
  never renamed — the WWN set is the true identity. This is how resolution stays
  correct across the legacy→FCLU migration.
- **Fail-loud WWN-ownership guard:** a host group holding foreign initiator WWNs
  causes activation to throw `conflict` (never a silent merge). Reads are fresh and
  never cached; a transient read failure is a retryable `array_busy`, never a false
  conflict.
- **Host-group names are NOT truncated by the array** (the real name limit is
  ≥46/64 chars). The 16-char truncation seen in practice is only the
  `get_ldev->{ports}` **view**, so `list_lu_mappings` keys on `(port,
  hostGroupNumber)` — never on the name — and name resolution is
  truncation-tolerant.

### Port-group sharding (`port_groups` / `node_port_groups`, #5)

By default every node maps its host groups + LU paths onto **all** `target_ports`. A "LU
path" is consumed per **(LDEV × host-group × port)**, and the per-FE-port budget (**2,048**
LU paths on midrange, **4,096** on high-end; **255** host groups/port) is the aggregate
across *all* host groups on that physical port. So if the whole cluster shares two ports,
those two ports cap the cluster at **~2,048 mapped disks regardless of node count**.

Shard nodes across **disjoint** port groups to multiply that ceiling — within **one**
storage (migration preserved):

```
target_ports      CL1-A,CL2-A,CL3-A,CL4-A
port_groups       g1=CL1-A,CL2-A g2=CL3-A,CL4-A
node_port_groups  pve01=g1 pve02=g1 pve03=g2 pve04=g2
```

The node names in `node_port_groups` are the **PVE cluster node names** — exactly what
`pvecm nodes` / `hostname` returns and what the array host groups are named after
(`PVE_<node>`). Group names (`g1`, `g2`) are arbitrary labels, unique within `port_groups`.
Every port in a group must appear in `target_ports`. The example above (2 groups) doubles
the ceiling; each additional group adds one port-budget's worth of headroom:

```
2 groups × 2,048 ≈ 4,096   live disks (midrange, the example above)
4 groups × 2,048 ≈ 8,192   live disks (midrange, 8 ports)
4 groups × 4,096 ≈ 16,384  live disks (high-end, 8 ports)
```

- **Default off** — unset ⇒ today's behavior (all nodes on all ports), byte-for-byte.
- **≥2 ports per group on different controllers** for MPIO + controller-failover HA (a
  single-port group **warns**). A node **not** listed in `node_port_groups` safely falls
  back to all ports.
- **Manual zoning is a prerequisite:** zone each node's HBAs to exactly its group's ports.
  A node that cannot reach any of its group's ports fails loud on activation. The plugin
  does not program the fabric (that is #1, auto-zoning).
- **Migration** stays free (one `storeid`). Size each group with headroom — a same-group
  migration briefly double-counts LU paths during handover; the destination's zoning must
  pre-exist. WWID/NAA is derived from the LDEV, so multipath identity is stable across ports.
- **Drain before reassigning.** Per-node resolution narrows unpublish/reclaim to a node's
  *current* ports, so **unpublish/migrate a node's volumes off before changing its
  `node_port_groups` entry or first enabling the feature** — otherwise mappings left on the
  old ports leak until the volume is deleted (`free_image` reaps them via the LDEV's actual
  ports). See [ADR 0003](adr/0003-port-group-sharding.md).
- Composes with `port_scheduler` (spread volumes *within* a group); deriving the port set
  from the array's fabric-login table is deferred — see [ADR 0003](adr/0003-port-group-sharding.md).

## Thin Image snapshots & clones

- **Snapshots:** an `autoSplit` pair; **restore = reverse-copy + re-split** (issue
  #12 — the driver owns the RCPY→PAIR→re-split settle).

- **#24 linked clone — the real-array flow.** The E590H microcode **rejects** a Thin
  Image pair created *with* `svolLdevId` ("the specified snapshot S-VOL does not have
  LU paths"). The driver therefore:

  1. creates the S-VOL as a TI **virtual** volume (`create_ldev`, `poolId -1`);
  2. creates a **data-only** `autoSplit` pair (`create_snapshot`, **no**
     `svolLdevId`);
  3. **maps the S-VOL** (`ensure_host_access` + `publish_lu` with `host_ctx`) so it
     has LU paths;
  4. calls `assign_snapshot_volume(pairId, svol)`.

  Rollback is reverse-order and leak-free. The core passes `host_ctx` into
  `create_linked_clone` precisely so the driver can do the map-before-assign step.

- **`OPEN-0V` multipath:** a clone S-VOL presents SCSI product **`OPEN-0V`** (TI
  v-vol). Multipath must match `OPEN-.*` or the clone never gets a `/dev/mapper`
  device (see the user guide's multipath section).

- **#23 free ordering:** `free_image` **releases the backing CoW pair before**
  deleting the S-VOL; `delete_lu` is called only **after** a cluster-wide unpublish
  (teardown symmetry with the `create_linked_clone(host_ctx)` mapping). Skipping the
  pair release would orphan an unfreeable S-VOL+pair.

- **#19 linked clone from a *live* volume.** The driver advertises the
  `clone.from_current` capability, so `qm clone` (linked) of a **running / non-template**
  disk is offloaded instead of falling back to a host-side copy. A Thin Image pair binds
  its S-VOL directly onto a **live P-VOL**, so no separate intermediate snapshot object is
  created — the `autoSplit` **is** the point-in-time. The clone's backing pair (P-VOL = the
  live source, S-VOL = the clone) is recorded and released on `free_image` exactly like a
  base/snapshot linked clone (#23). Backends whose clone API *requires* a snapshot source
  (e.g. the Nimble model) leave `clone.from_current` off and PVE keeps host-copying.
  - **Crash-consistency caveat:** cloning a *running* guest captures a **crash-consistent**
    image only (in-flight, un-flushed guest writes are not quiesced) — same guarantee an
    array-side snapshot of a live volume gives. Freeze the guest / use fsfreeze for
    application consistency.
  - **⚠️ PVE routing (live-confirmed NEGATIVE on PVE 9.2, E590H, alpha38):** stock PVE does
    **not** route a `current`-source (non-template) clone through `clone_image`. `qm clone`
    of a non-template VM forces a **full** clone regardless of `clone.from_current` — a
    running source goes through drive-mirror (suspend/resume), a stopped source through
    `qemu-img convert`; both produce a full independent copy with no CoW parent. `clone_image`
    (linked clone) is only reached when the **source is a template**. So the plugin capability
    + `clone_image` handling here are correct and forward-compatible **but currently inert**:
    delivering #19's instant array linked-clone of a live volume needs an **upstream PVE
    change** to route a `current`-source clone through `clone_image` when the storage
    advertises `clone.from_current` — the same class of gap as full-clone copy-offload
    (Bugzilla #7780). Until then, live-source clones full-copy exactly as before (no
    regression). Verified live on the E590H: 2026-07-22.

## Advanced services

- **QoS** — upper/lower IOPS + MB/s and I/O priority, set per volume from the store's
  `qos_*` defaults (core properties). **Model-gated:** per Hitachi's support matrix,
  QoS is available only on **VSP F/G350–900** and **VSP 5000** (firmware 88-06-01+ /
  Configuration Manager REST 10.2.0+) — i.e. the `vsp_g` (Ops Center CM) platform. The
  **VSP E series** (`vsp_e`: E590/E790/E990/E1090) and **VSP One Block** (`vsp_one`)
  do **not** expose a QoS REST surface, so the driver does not advertise QoS on them
  and silently ignores any `qos_*` settings there (with a warning). QoS on `vsp_g`
  rides the §10 Ops Center CM connector and is not yet validated end-to-end.
- **SCSI-3 PR readiness** — `persistent_reservations` validates the `qemu-pr-helper`
  socket + multipath reservation key on activation and **warns** only (never edits
  `multipath.conf`, never blocks). Ship the `qemu-pr-helper` units (disabled by
  default) to use it.
- `copy_speed`, `discard_zero_page`, `group_delete` — see the tables above.

## Multi-tenancy on a shared array

The gold-standard hard boundary is a Hitachi **Resource Group** with a **scoped Ops
Center REST service account** per cluster — the REST account only sees its own LDEVs,
ports, and host groups. Combine with a disjoint `ldev_range` and a distinct
`host_group_prefix`. A `resource_group` configuration hint may be reserved for this.

## Transport & error taxonomy

The driver talks to the Configuration Manager REST API via `RestClient.pm`. The
`_translate_rest_error` boundary maps raw HTTP status + Hitachi **KART** codes onto
the closed FCLU error vocabulary (`FCLU::Error`, §13) with an admin-safe message and
the raw payload preserved in the vendor blob. Sessions are **always logged out** /
torn down on error (guaranteed `disconnect`), even on the failure path.
