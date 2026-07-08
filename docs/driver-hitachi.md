# Hitachi VSP Driver — `pve-fclu-hitachi`

Hitachi-VSP-specific documentation for the FCLU Hitachi driver. This complements the
vendor-neutral [`user-guide.md`](user-guide.md) — install, credentials, multipath,
multi-cluster safety, and migration are documented there and are not repeated here.

> Design authority: `ARCHITECTURE.md` §4 (profiles/quirks), §6 (capabilities), §7
> (allocation fence). Storage type is `hitachiblock` (backward-compatible with the
> legacy single-vendor plugin).

## Platform profiles (§4)

One `Driver::Hitachi` handles the whole VSP family; the control-plane differences are
a **profile** concern, selected by `platform`:

| `platform`           | Control plane                                  | Default port |
| -------------------- | ---------------------------------------------- | ------------ |
| `vsp_one` (default)  | Embedded / direct GUM REST (VSP One, E·G midrange) | 443      |
| `vsp_e`              | Embedded / direct GUM REST                     | 443          |
| `vsp_g`              | Ops Center **Configuration Manager** server    | 23451        |

- **`mgmt_port`** — override the port to mix models (auto-detected from `platform`
  when omitted).
- **`storage_id`** (`fixed`) — the array's `storageDeviceId` (the 12-digit
  model+serial id from `GET /v1/objects/storages`), **not** the bare serial.
- **`rest_keepalive`** — keep a persistent CM REST session per process instead of
  authenticating each request. The default is **session-less** (auth per request),
  which avoids exhausting the array's per-array session cap on large clusters. Enable
  only if your array requires session auth.

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

## Advanced services

- **QoS** — upper/lower IOPS + MB/s and I/O priority, set per volume from the store's
  `qos_*` defaults (core properties).
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
