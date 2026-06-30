# Implementation plan

`ARCHITECTURE.md` is the authoritative design. This file tracks the build against
it: a bottom-up core scaffold first (the target the §9 strangler-fig refactor
converges toward), then the Hitachi seams.

## Phase 0 — generic core scaffold (greenfield, no Hitachi code yet)

The contract and its executable reference, built before touching the reference
plugin. `Driver::Mock` + the parametrized contract suite become the definition of
"conforms to `fclu-driver-api-1`" (§12.5), so everything later verifies against them.

- [x] `FCLU::Error` — normalized error type, closed code vocabulary, default
      classification, admin-safe stringification (§13). Tests: `t/unit/error.t`.
- [x] `FCLU::Driver` — abstract array-backend contract: every §2 method present,
      `croak`-not-implemented by default; POD documents the §12 data shapes.
      `contract_methods`/`mandatory_methods`/`optional_methods` expose the canonical
      surface. Tests: `t/unit/driver.t`.
- [x] `FCLU::Capabilities` — normalize/merge the §6 capability object; the
      `pve_feature` (`volume_has_feature`) glue and "absent/unknown key ⇒ 0" rule.
      Tests: `t/unit/capabilities.t`.
- [x] `FCLU::Driver::Mock` — in-memory backend implementing the full v1 surface,
      `arm_fault`/`clear_faults` raise any error `code` on demand (§13.6) for
      retry/compensate tests. Tests: `t/unit/mock.t`.
- [x] Contract-test harness — `FCLU::ContractTest::run_contract_tests` (`t/lib/`),
      one parametrized suite asserting the §12.2 idempotency/retry table and §12.1
      data shapes against any driver; run against Mock in `t/unit/contract_mock.t`.
      Each future driver adds its own `t/unit/contract_<vendor>.t` one-liner.

**Phase 0 complete** — the contract, its executable reference, and the conformance
suite are in place. Next: §9 Phase 1 (extract Registry/Credentials/Label from the
Hitachi `Config.pm`).

## Phase 1+ — strangler-fig migration of the Hitachi reference (§9)

Each step keeps the (frozen) Hitachi plugin behaviourally green; seams move one at
a time.

- [x] Extract state: `Config.pm` → `FCLU::Registry` + `FCLU::Credentials` +
      `FCLU::Label` (vendor-neutral, generalized). `ldev_id`→opaque `backend_id`
      (string identity), label `max_len` from the driver (no hardcoded 32),
      `fclu-registry-<storeid>` lock domain, configurable `base_dir` for tests.
      Hitachi-specific `platform_defaults`/`validate_config` deliberately NOT
      moved — they stay in the driver. Tests: `t/unit/{credentials,registry,label}.t`.
- [x] Extract host side: `Multipath.pm` → `FCLU::Host::Connector` (abstract §3
      interface) + `FCLU::Host::FCMultipath` (vendor-neutral port). DELETED the
      Hitachi WWID synthesis (`ldev_to_wwid`, `_assert_ldev_id`) and
      `discover_wwid`'s `60060e80`-OUI + `HITACHI`-vendor gate; page-83 matching
      (`find_device_paths`) is now generic against the driver's canonical identity
      (§12.1). `_wwid_from_identity` is the single identity→wwid translation.
      Synthesis-as-fallback is deferred to `Driver::Hitachi` (a private driver
      concern, not the host layer). Tests: `t/unit/{host_connector,fcmultipath}.t`.
- [x] Wrap, don't rewrite: `RestClient.pm` → `FCLU::Driver::Hitachi` implementing
      the contract; transport untouched. **COMPLETE (slices A+B+C).** Driver #1
      now passes the parametrized §12.5 conformance suite (`contract_hitachi.t`
      runs `FCLU::ContractTest` against the real driver backed by the stateful
      `t/lib/FCLU/FakeHitachiRest.pm` simulator). Slice C added Thin Image
      snapshots (create/delete/restore-with-re-split/list), CG snapshots,
      linked/full clones, and QoS; `transfer.migrate_pool` left unadvertised until
      `migrate_lu` lands; the real-array linked-clone S-VOL-assign-after-mapping
      (#24) is Plugin-orchestrated. Tests: `hitachi_snapshots.t`,
      `contract_hitachi.t`. **Slice A done:** transport vendored
      byte-faithful (`Driver/Hitachi/RestClient.pm`, pkg rename only); driver spine
      (`Driver/Hitachi.pm`): session, per-platform Profile incl the Ops Center CM
      (23451) vs embedded GUM (443) port split (§4), `capabilities` (§6), the §13
      error-translation boundary (RestClient bare-string die → classified
      `FCLU::Error`), and the LU lifecycle/introspection/identity normalized to
      §12.1 with §12.2 idempotency. Tests: `hitachi_restclient.t`,
      `hitachi_driver.t`, `hitachi_lu.t`. **Slice B done:** host-access —
      `ensure_host_access` (PVE_<hostname> host group per FC port, additive HMO
      reconcile, WWN add; node WWNs/hostname from `%host_ctx`, array ports/host_mode
      from driver config), `publish_lu`/`unpublish_lu` (node-targeted, idempotent
      map/unmap), `list_lu_mappings` (authoritative from `get_ldev->{ports}`, §12.3),
      `target_ports` (configured ports; WWPN resolution deferred to Fabric §14).
      Migrated from `HitachiBlockPlugin.pm` `_ensure_host_groups`/`_map_lun_to_local`/
      `_unmap_lun_from_local`. Test: `hitachi_hostaccess.t` (stateful fake rest).
      **Deferred (slice C):** snapshots/clones (Thin Image), and the stateful-fake
      `contract_hitachi.t` parametrizing `FCLU::ContractTest`.
- [~] Introduce `FCLU::Plugin`; move read-only/common methods first
      (`status`, `list_images`, `volume_size_info`, shared `parse_volname`).
      **Slice 4A done:** generic base `src/PVE/Storage/FCLU/Plugin.pm`
      (`use base PVE::Storage::Plugin`) — identity (`api`/`plugindata`), abstract
      vendor hooks (`type`/`vendor`/`driver_class`/`driver_config`, `connector_class`
      default), core accessors (`_registry`/`_credentials`/`_driver`/`_build_driver`
      seam, `$REGISTRY_BASE_DIR`/`$CREDS_BASE_DIR` test seams), and the
      vendor-neutral read-only methods: `parse_volname`/`vmid_from_volname` (§7
      cloudinit-aware), `volume_has_feature` (role table), `get`/`update_volume_attribute`
      + notes (registry-backed), `list_images`, `status` (driver `storage_status`),
      `activate`/`deactivate_storage` (driver connect/disconnect). Tested under
      BEGIN-stubbed PVE modules + a fake driver (`t/unit/plugin.t`). **Slice-4A
      follow-ups to wire in a later slice (architect review):** gate
      `volume_has_feature`'s `snapshot`/`clone` on the driver `capabilities()`
      (§6, via `Capabilities::pve_feature`) so a driver lacking a feature fails
      soft — keep host/registry features (copy/sparseinit/template/rename/resize)
      on the role table; cache `$scfg` alongside the cached driver (the reference's
      `%_client_scfg`, #13) once `_driver` gets callers PVE may invoke without
      `$scfg`. **Deferred (later step-4 slices):** `alloc_image`/`free_image` (+ the core `ldev_range`
      safety FENCE §7), `activate`/`deactivate_volume` map/unmap orchestration,
      snapshot/clone orchestration (incl the #24 linked-clone assign flow),
      `volume_export`/`import`, `create_base`/`rename`/`manage`/`migrate`/orphans.
- [ ] Move orchestration (alloc/free/activate/snapshot/clone) into `FCLU::Plugin`
      one operation at a time, swapping direct REST calls for driver-contract calls.
- [ ] Add profile detection + quirk handling behind the driver (§4); delete
      scattered platform/microcode conditionals.
- [ ] Cutover: `HitachiBlockPlugin` becomes the thin `type()='hitachiblock'`
      subclass (§5); GUI unchanged; `storage.cfg` backward-compatible.
- [ ] Validate the abstraction with a **second** driver before trusting it (§10) —
      target pending the maintainer's "Open decisions" (Pure FlashArray recommended).

## Notes
- Tests: `make test` (`prove -Isrc -r t/unit/`).
- Capability/feature additions are non-breaking; any change to a §12 **MUST**
  bumps the driver ABI to `fclu-driver-api-2` (§11/§12).
