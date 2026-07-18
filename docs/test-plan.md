# Test Plan — FCLU framework live validation on the VSP E590H (lab PVE 9)

Environment-specific runbook for the **first live validation of the FCLU framework**
(the refactored `Driver::Hitachi` + `FCLU::Plugin` + the `hitachiblock` thin subclass,
installed from the multi-binary OBS packages). It validates two things at once:

1. **storage behaviour** the reference plugin already proved on this array (so
   regressions from the refactor are caught), and
2. **framework-new surfaces** that have only been unit-tested against fakes — the
   driver-contract path, the code-enforced `ldev_range` fence, registry-recorded
   identity, the multi-binary packaging + re-shipped GUI, and the linked-clone flow.

> **Status:** alpha. All phases below have been **run live on the E590H** and passed —
> see the results table in §5. Treat every step as capable of destroying data on *your*
> hardware until proven otherwise: a phase passes only when verified on the array in
> front of you, **not** by `make test` (all 214 unit tests run against
> fakes/simulators).

> **Concrete addressing & secrets** (mgmt IPs, SID, credentials, node names) live in the
> **local, untracked `TESTING.md`** and the maintainer's project memory — this repo is
> public. Everything below uses placeholders/symbols.

---

## 1. Environment

| Item | Value |
|------|-------|
| PVE cluster | 4 × PVE 9 nodes (root SSH via the lab jump chain) |
| **SAN-connected nodes** | only 2 of the 4 (the FC-online nodes) — `SAN_NODES` |
| Array | Hitachi **VSP E590H**, `platform vsp_e`, embedded CM REST on the controller GUM, port **443** |
| Test pool | **pool 0** — tiered (HDT) **and shared with production backups** (expect unmanaged LUNs) |
| Snapshot pool | **`snap_pool_id 1`** (HDP) — Thin Image **rejects** the HDT pool 0, so TI S-VOLs must land in an HDP pool |
| Packages | `pve-fclu-core` + `pve-fclu-hitachi` from OBS `home:ciriarte:pve-FCLUPlugin/PVE_9` |

### Values to confirm in Phase A (from `TESTING.md` / memory; re-verify live)

| Symbol | Meaning |
|--------|---------|
| `SAN_NODES` | the 2 nodes with FC HBAs online |
| `MGMT_IPS` | controller GUM management IP(s). NOTE: one controller is historically unreachable — expect a single reachable mgmt IP |
| `SID` | 12-digit `storageDeviceId` (NOT the bare serial) |
| `TARGET_PORTS` | FC target ports zoned to the SAN nodes (e.g. `CL1-A,CL2-A`) |
| `LDEV_RANGE` | the **reserved, verified-empty** LDEV window — the fence (e.g. `256-511`) |
| `API_USER` | dedicated REST user (Provisioning + Local Copy roles) |

---

## 2. Safety controls (mandatory — read before touching the array)

Pool 0 holds **unmanaged production LUNs**. The framework can create, map, delete, and
scan LDEVs. To guarantee it can never touch production:

- **S1 — Fence with `ldev_range`.** Set a reserved, verified-empty `LDEV_RANGE` in
  `storage.cfg` **before any provisioning**. With no range the fence is OPEN (see S8).
  Confirm the window is unused on the array first.
- **S2 — No orphan auto-cleanup, and note the tooling gap.** The `hitachiblock-repl`
  CLI is **NOT shipped by `pve-fclu-hitachi`** (deferred — coupled to the reference's old
  modules). Do **all** orphan/reconcile inspection **read-only via the REST API or the
  array GUI**, eyeballing the list. There is no auto-cleanup command in this build — good.
- **S3 — Contain snapshots in an HDP pool.** Use **`snap_pool_id 1`** (Thin Image cannot
  use the HDT pool 0). Monitor its free space (S5).
- **S4 — Don't disturb existing zoning / host groups.** The driver creates only
  `PVE_<hostname>` host groups on the target ports. Confirm it never touches the production
  host group(s) or existing zones. **Never operate on the reserved prod host group.**
- **S5 — Capacity guardrail.** Record pool-0 and snap-pool free space first; keep total
  test allocation small (≤ a few hundred GiB thin) and watch `pvesm status` + the GUI.
- **S6 — Change window & prod VMs.** Run mapping/provisioning in an agreed window. **Do
  NOT touch running production VMs** on this cluster.
- **S7 — Snapshot the config.** Keep `storage.cfg` under version control on the nodes;
  record every value in the results log.
- **S8 — The `ldev_range` fence is now code-enforced in FCLU.** `HitachiBlockPlugin::
  safe_delete_precheck` → `_ldev_in_range` refuses any unmap/delete of a backend id
  outside `ldev_range`; `free_image` calls it before **any** destructive op. This is the
  hard backstop against foreign LUNs — but still set a correct range (empty range ⇒ open
  fence). **Validate the fence is active in Phase C (F-fence).**
- **S9 — Never assume an array selector filters server-side; prove it live.** Verified on
  the E590H that **`GET /luns` ignores `ldevId`**. Before trusting any destructive selector,
  test it with matching / non-matching / bogus values and confirm the counts differ.

> **Recorded incident (reference bring-up):** an early `free` trusted the ignored `ldevId`
> selector and unmapped several *production* LUN paths from another host group before the
> array's host-I/O guard halted it (no LDEV deleted; paths restored). The FCLU `unpublish`
> path unmaps via the LDEV's own `ports[]` and the S8 fence backstops it — **verify both
> hold on real hardware** (Phase C, E).

---

## 3. Storage configuration for this environment

The plugin `type` is still **`hitachiblock`** (backward-compatible), so `storage.cfg` is
identical to the reference. Add on the SAN nodes only:

```ini
hitachiblock: e590h-test
    mgmt_ip <MGMT_IPS>
    storage_id <SID>
    pool_id 0                    # test pool (shared with prod backups — S1/S5)
    snap_pool_id 1               # S3: HDP pool for Thin Image (pool 0 is HDT, rejects TI)
    target_ports <TARGET_PORTS>
    host_mode LINUX/IRIX
    platform vsp_e
    ldev_range <LDEV_RANGE>      # S1: REQUIRED fence — reserved empty window
    skip_unmap_io_check 1        # HMO 91 — immediate unmap, no 60s teardown timeout
    shared 1
    content images
    nodes <SAN_NODES>
    # tls_verify off by default (self-signed GUM cert)
```

```bash
pvesm set e590h-test --username <API_USER> --password '<...>'   # creds kept out of storage.cfg
```

---

## 4. Phased test sequence

Each phase: **goal → steps → expected**. Record pass/fail per row in §5. Stop and escalate
on any **STOP-gate** failure. Space out SSH through the jump chain (brute-force protection),
and run slow ops (alloc/free/clone ~60–90s) detached on-node.

### Phase A — Discovery & pre-flight (read-only, safe)
Goal: confirm prerequisites without changing anything.
- A1. On each node: FC `port_state`=`Online` + `port_name` (WWNs) → identifies `SAN_NODES`.
- A2. REST login from a SAN node; `GET .../objects/storages` → confirm `SID`; **log the
  session out** (teardown discipline).
- A3. `GET pools` → pool 0 present + free capacity; **confirm `snap_pool_id 1` is HDP** and
  TI-capable; `GET ports` → pick `TARGET_PORTS`.
- A4. `GET ldevs` over the candidate window → confirm `LDEV_RANGE` is **empty**.
- A5. Confirm Dynamic Provisioning + Thin Image licences active.
- A6. Baseline `multipath -ll` + `/etc/multipath/wwids` on both SAN nodes (for later diff).
- A7. Confirm the OBS `PVE_9` repo is reachable and the `pve-fclu-*` packages resolve.
- **STOP-gate:** REST reachable, `SID` known, pool 0 + HDP snap pool present, empty
  `LDEV_RANGE`, licences present, ≥2 FC-online nodes.

### Phase B — Install, swap & register (framework packaging gate)
Goal: the multi-binary packages install, the GUI panel appears, and the type resolves
cluster-wide. **New vs the reference — validate the §11 packaging.**
- B1. Install **both** `pve-fclu-core` **and** `pve-fclu-hitachi` on **every node** (not
  only SAN): `storage.cfg` is cluster-wide, and a node missing the modules cannot resolve
  the `hitachiblock` type and silently drops the storage from its view. `nodes=` scopes
  activation separately.
- B2. **Swap gate — MIGRATE THE REGISTRY FIRST** (if the old package is present). The
  reference and FCLU keep their volume→LU map in different stores and formats, so a naïve
  swap orphans every existing volume. Use the **zero-window** flow in
  `docs/migration-hitachi.md`: from a source checkout, `perl -Isrc
  bin/pve-fclu-migrate-hitachi --dry-run --all` then `--all` to populate the FCLU registry
  **before** any swap → then `apt install pve-fclu-hitachi` + `systemctl restart pvedaemon
  pveproxy pvestatd` on each node (node order irrelevant). Confirm **no dpkg file-overwrite
  error**, `pvesm list` shows the **same** volumes before and after, and guests resolve
  their disks. ⚠️ If instead you install-then-migrate, do NOT reboot / run backup·HA /
  invoke `pvesm`·`qm` in the gap — an involuntary daemon restart there orphans volumes for
  new operations. Rollback = reinstall the reference package (the untouched legacy store is
  reused).
- B3. **GUI gate:** `systemctl restart pvedaemon pveproxy`; in the web UI, Datacenter →
  Storage → Add shows **"Hitachi Block"**, the create dialog renders all fields, and the
  grid shows the friendly label. Confirm the `<script>` tag was injected into
  `index.html.tpl` and survives a `dpkg-reconfigure`/pve-manager rewrite (trigger).
- B4. Add the §3 stanza; `pvesm set` creds; `systemctl reload-or-restart pvedaemon`.
- B5. `pvesm status` → `e590h-test` `active`, capacity matches the GUI. On a **non-SAN**
  node it lists as `disabled` (not omitted).
- B6. Activate; confirm `PVE_<host>` host groups appear **only** on the target ports with
  each node's WWNs, production groups intact (S4).
- **STOP-gate:** both packages installed cluster-wide, GUI panel present, storage `active`,
  host groups correct, production untouched.

### Phase C — Core provisioning, data path & the fence
Goal: one LUN allocates, maps, multipaths, benchmarks, and frees cleanly — through the
driver contract — and the `ldev_range` fence is proven active.
- C1. `pvesm alloc e590h-test 0 '' 16G`. **Parse the volid** from `successfully created
  '<volid>'` (don't orphan the LU). Confirm the LDEV is created **inside `LDEV_RANGE`** with
  a correct label.
- C2. **Size-unit gate:** array `blockCapacity*512` == exactly the requested bytes (or note
  the documented min-clamp/rounding).
- C3. **Identity path (framework):** confirm `activate_volume` records the canonical NAA in
  the FCLU registry, `multipath -ll` shows `3<naa>` with paths across both fabrics, and the
  synthesized wwid == the array-reported page-83 identity (no host-side synthesis).
- C4. `fio` raw randrw/seq to `/dev/mapper/3<naa>` — sane throughput, no path errors.
- C5. **Identity-resilience (framework):** confirm `deactivate_volume`/`free` resolve the
  device from the **registry-recorded identity** (works even without an array session).
- C6. **F-fence gate (S8):** confirm `free` of the in-range volume calls
  `safe_delete_precheck` and succeeds; then verify (read-only, e.g. via a debug log or a
  crafted registry entry on a scratch storeid) that a backend id **outside** `LDEV_RANGE`
  is **refused** before any destructive op. Never point this at a real foreign LDEV.
- C7. Free the C1 volume; confirm unmap via the LDEV's own `ports[]`, multipath device gone,
  `wwids` entry removed, LDEV deleted. Diff against the A6 baseline → no residue.
- **STOP-gate:** alloc→map→multipath→IO→free clean, in-range, fence active, no orphan.

### Phase D — PVE functional acceptance (VM + CT)
Goal: the PVE-recommended matrix on `e590h-test`, on the SAN nodes. Use the lab guest
templates (Ubuntu 9120 w/ qemu-agent + sg_persist; openSUSE 9010/9011).
- D1. One VM + one CT with wizard defaults on `e590h-test`.
- D2. Add a second data disk to each.
- D3. Add a vTPM state drive to the VM (tiny-LUN handling).
- D4. In-guest `fio` on the data disk — adequate performance.
- D5. **Disk-bus matrix** (VM): VirtIO-Blk, SCSI (virtio-scsi), SCSI (LSI), SATA.
- D6. **Discard/trim:** enable Discard, write+delete a large file, `fstrim`; pool-0 usage
  drops.
- D7. **Online resize:** `qm resize`; guest sees the new size without reboot (driver
  `resize_lu` → connector resize → registry commit).
- D8. **Purge:** detach a disk, remove the unused-disk entry; LDEV freed, no orphan.

### Phase E — Snapshots & CoW linked clones (HIGHEST RISK — framework-new)
Goal: prove Thin Image + the driver-contract snapshot/clone paths on real microcode.
- E1. `qm snapshot` → write → `qm rollback` → confirm revert (driver
  create/restore-with-re-split, #12) → `qm delsnapshot`.
- E2. **Capability gate:** confirm `volume_has_feature` offers snapshot/clone only where the
  driver `capabilities()` advertises them (GUI/`qm` expose them correctly).
- E3. **★ #24 LINKED-CLONE GATE (the single biggest unknown).** Linked-clone a base/template
  and confirm **instant + minimal pool growth** (NOT a full copy) with a persistent CoW
  S-VOL. **RISK:** the FCLU `Driver::Hitachi::create_linked_clone` currently uses the
  *simulator* flow (creates the TI pair **with** `svolLdevId`), which this E590H microcode is
  documented to **reject (KART30000-E — the S-VOL must have LU paths first)**. The real flow
  is create-pair-without-svol → map the S-VOL → `assign_snapshot_volume`, orchestrated with
  host context. **This phase discovers whether the simulator flow happens to work here or
  hits KART30000-E** — if it fails, that confirms the deferred #24 orchestration is required
  and this is the finding to feed back. Do not treat a failure here as a regression; it is a
  known open gap.
- E4. **#23 pair release:** free a linked clone; confirm the backing CoW pair is released
  (via the recorded/rediscovered `snap_id`) **before** the S-VOL delete, and the array shows
  no orphan pair.
- E5. **Dependency guards:** deleting a base/source or its snapshot while a linked clone
  exists must fail clearly; delete the clone, then the source succeeds.
- E6. Multi-disk consistency-group snapshot (if exercised) + rollback.

### Phase F — Migration & adopt/release matrix (2 SAN nodes)
Goal: storage_migrate + the FCLU-new manage/unmanage + the data-integrity gate.
- F1. CT + VM offline migrate between the two SAN nodes.
- F2. VM **online (live)** migrate between the two SAN nodes; repeat with in-guest `fio`
  load — no path drops, no corruption.
- F3. **Move Storage** disk LUN→file and file→LUN, hot and cold.
- F4. **export/import (raw+size):** offline-migrate to a non-SAN node via the FCLU
  `volume_export`/`volume_import` stream; confirm clean relocation or the documented failure.
- F5. **manage/unmanage (framework-new):** `unmanage` an in-range test LUN (registry drops
  it, LUN survives on the array), then `manage` it back under a fresh volname (never targets
  a foreign/out-of-range LDEV — S8).
- **F6. DATA-INTEGRITY GATE (after every copy onto `e590h-test`).** Verify the **bytes**, not
  just "it booted": record the source allocated size (a real OS disk is GiB, not ~100 MiB);
  `cmp`/`sha256sum` a fixed prefix (e.g. first 4 GiB) source vs `/dev/mapper/3<naa>`; sanity-
  check the LDEV `numOfUsedBlock` is GiB-range. **STOP-gate:** any mismatch = a truncated
  copy — do not dismiss as "guest won't boot."

### Phase G — Advanced services (optional / time-permitting)
- G1. **QoS:** set `qos_upper_iops`, allocate, confirm the cap on the LDEV and its
  enforcement (driver `set_lu_qos`).
- G2. **SCSI-3 PR readiness (framework-new, alpha3):** set `persistent_reservations 1`;
  with qemu-pr-helper.socket **disabled** and no multipath `reservation_key`, activate a
  volume and confirm `activate_volume` **warns** (non-fatal) naming both prerequisites;
  enable them and confirm the warning clears. Never blocks activation.
- G3. **Multi-controller failover:** likely **N/A** — one controller is historically
  unreachable; record whether single-controller operation is clean.
- G4. **Zero-page reclaim:** `discard_zero_page`, deactivate, pool usage drops.
- G5. **Concurrent registry lock:** allocate from both SAN nodes at once; registry entry
  count == allocation count, no lost updates (FCLU `Registry` cluster lock).

### Phase H — Teardown & verification
- H1. Remove all test guests/disks; `pvesm free` any strays.
- H2. **Read-only orphan check (S2):** via the REST API / array GUI (there is no shipped
  CLI), confirm only test LDEVs **inside `LDEV_RANGE`** ever appeared and no production LUN
  was ever touched.
- H3. Confirm `PVE_<host>` host groups + `wwids` cleaned up; pool-0 + snap-pool usage back
  to the A3/A5 baseline; remove the stanza if ending the campaign. **Log out all REST/CLI
  sessions.**

---

## 5. Sign-off & results log

Record: **date, DKCMAIN/microcode, PVE version, the deployed `pve-fclu-*` versions, and
per-phase pass/fail with deviations.** Save under `t/integration/e590h-<date>.md` (kept out
of the public tree if it contains addressing). The **size-unit gate (C2)**, **fence gate
(C6)** and **#24 clone gate (E3)** have all passed on DKCMAIN 93-07-23/00. On any other
microcode or array, treat exact sizing, the delete fence, and space-efficient linked
clones as **unverified** until those three gates pass there.

Results below are **back-filled from the maintainer's validation log**, not transcribed
live during each run. All phases were executed on the E590H (DKCMAIN 93-07-23/00) on a
PVE 9 cluster; the package version column records the build each phase was last
exercised under. Re-run them on your own hardware rather than treating these as
inherited passes.

| Phase | Result | Microcode / PVE / pkg ver | Notes / deviations |
|-------|--------|---------------------------|--------------------|
| A Discovery | PASS | 93-07-23/00 / PVE 9 / alpha11 | Read-only pre-flight; `snap_pool_id 1` (HDP) confirmed — pool 0 (HDT) rejects Thin Image. |
| B Install/swap/GUI | PASS | 93-07-23/00 / PVE 9 / alpha11 | Multi-binary install, clean supersede of `pve-storage-hitachiblock`, registry migration, GUI panel renders/persists. |
| C Provisioning + fence | PASS | 93-07-23/00 / PVE 9 / alpha11 | alloc/map/IO/free, online resize; size-unit gate exact; `ldev_range` fence refuses out-of-range delete. |
| D PVE acceptance | PASS | 93-07-23/00 / PVE 9 / alpha20 | VM-from-clone works (alpha15); multi-disk `qm clone` end-to-end incl. linked efidisk0+scsi0 and cloud-init (alpha20). |
| E Snapshots/clones (#24) | PASS | 93-07-23/00 / PVE 9 / alpha15 | **★ #24 gate: the simulator flow WORKS on this microcode** — the deferred host-context orchestration was not required. CG snapshots added later (alpha29/30, hardware CTG, crash-consistent). |
| F Migration + manage | PASS | 93-07-23/00 / PVE 9 / alpha24–26 | F1–F4 + F6 (2026-07-07/08): data-integrity gate byte-verified, no corruption under load. F5 manage/unmanage (2026-07-08). |
| G Advanced (QoS/PR) | PARTIAL | 93-07-23/00 / PVE 9 / alpha25–26 | G1–G5 run: G2 PR-readiness PASS, G5 concurrent-lock PASS. G1 found 2 defects (fixed alpha25); G4 found `discard_zero_page` unwired (fixed alpha26). **QoS NOT testable here** — model-gated off on E-series via both control planes; needs a G/F350-900 or VSP 5000. |
| H Teardown | PASS | 93-07-23/00 / PVE 9 / alpha26 | Registry back to baseline, no stray disks or orphans, fence + `host_group_prefix` intact. |

### FCLU-specific gates (must pass before "validated")
- **Packaging/swap gate (B2):** multi-binary install + clean supersede of `pve-storage-hitachiblock`.
- **GUI gate (B3):** the Add-storage panel renders and persists all fields.
- **Size-unit gate (C2):** `blockCapacity*512` == requested bytes.
- **Fence gate (C6):** out-of-range delete refused by `safe_delete_precheck`.
- **★ #24 clone gate (E3):** linked clone works on this microcode, or confirms the deferred
  #24 host-context orchestration is required (the top open risk of the refactor).
- **Data-integrity gate (F6):** byte-verified copies, no truncation.
