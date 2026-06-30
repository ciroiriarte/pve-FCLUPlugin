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

- [ ] Extract state: `Config.pm` → `FCLU::Registry` + `FCLU::Credentials` +
      `FCLU::Label` (no behaviour change).
- [ ] Extract host side: `Multipath.pm` → `FCLU::Host::FCMultipath`; Hitachi WWID
      synthesis kept only as a private driver fallback during transition.
- [ ] Wrap, don't rewrite: `RestClient.pm` → `FCLU::Driver::Hitachi` implementing
      the contract; transport untouched.
- [ ] Introduce `FCLU::Plugin`; move read-only/common methods first
      (`status`, `list_images`, `volume_size_info`, shared `parse_volname`).
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
