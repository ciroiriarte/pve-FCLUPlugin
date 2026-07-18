# Writing an FCLU driver

This guide is for someone who wants to add support for a new storage array — Dell
PowerStore, Pure FlashArray, IBM FlashSystem, NetApp, anything else — without having read
the rest of this codebase.

You should not need to understand Proxmox's storage plugin API, multipath, or how PVE
clones a VM. That is the framework's job. Your job is to translate a defined set of method
calls into your array's management API.

## What you are building

| # | File | What it is |
|---|---|---|
| 1 | `src/PVE/Storage/FCLU/Driver/<Vendor>.pm` | The driver. This is the real work. |
| 2 | `src/PVE/Storage/Custom/<Vendor>Plugin.pm` | A ~40-line shim declaring vendor identity and `storage.cfg` fields. |
| 3 | `t/unit/contract_<vendor>.t` | Three lines. Runs the conformance suite against your driver. |
| 4 | `debian/pve-fclu-<vendor>.install` + a `debian/control` stanza | Your driver's package. |

There is no fifth thing. You do not write host-side code, registry code, rollback logic,
or PVE integration.

## How big is this, honestly

The only complete driver today is Hitachi, and it is **1592 lines** plus a **1339-line**
REST client, with a **370-line** plugin shim. Treat that as the upper end: it accumulated
multi-cluster safety work, QoS, consistency groups and error-code translation over many
iterations, and a first driver targeting basic provisioning will be considerably smaller.

The honest split of effort:

- **Mechanical** — session handling, LU create/delete/resize/label, capacity reporting.
  A day or two against a REST API you already know.
- **Where the time actually goes** — [host access](driver-contract.md#host-access-is-where-drivers-get-hard),
  async job convergence, and translating your array's error codes into the framework's
  vocabulary. Budget most of your time here, not on the CRUD.

Perl fluency is not really the constraint; the driver is plain hashes, `LWP::UserAgent`
and `JSON`, all standard on a PVE node. Knowing your array's failure modes is the
constraint.

---

# Part 1 — Quickstart

The goal of this part is a driver skeleton that the conformance suite loads and reports
on, in a couple of minutes. You then make failing tests pass one at a time.

## 1. The skeleton

Save as `src/PVE/Storage/FCLU/Driver/Acme.pm`. This runs as-is:

```perl
package PVE::Storage::FCLU::Driver::Acme;

use strict;
use warnings;

use PVE::Storage::FCLU::Driver;
use parent -norequire, 'PVE::Storage::FCLU::Driver';

use PVE::Storage::FCLU::Error;
use PVE::Storage::FCLU::Capabilities;

sub new {
    my ($class, %opts) = @_;
    return bless { %opts, connected => 0 }, $class;
}

sub connect    { my ($self) = @_; $self->{connected} = 1; return $self }
sub disconnect { my ($self) = @_; $self->{connected} = 0; return 1 }
sub ping       { my ($self) = @_; return 1 }

sub detect_profile { return { model => 'acme-unknown' } }

# NOTE: normalize(), not new(). The contract requires a plain normalized HASH here;
# normalize() fills in every required branch with zeroed leaves, so you only list
# what your array actually supports.
sub capabilities {
    return PVE::Storage::FCLU::Capabilities->normalize({
        resize => { grow_online => 1 },
    });
}

sub storage_status { return ( 1 << 40, 1 << 39, 1 << 39 ) }   # total, free, used (bytes)

1;
```

That trailing `1;` is not decoration — a Perl module without it fails to load with
*"did not return a true value"*.

Everything else is inherited from the abstract base, where each contract method dies with
"not implemented". That is deliberate: a half-finished driver fails loudly instead of
silently returning `undef`.

## 2. The conformance test

Save as `t/unit/contract_acme.t`:

```perl
use strict; use warnings; use Test::More;
use lib 'src'; use lib 't/lib';

use FCLU::ContractTest qw(run_contract_tests);
use PVE::Storage::FCLU::Driver::Acme;

run_contract_tests(
    name    => 'Acme',
    factory => sub { PVE::Storage::FCLU::Driver::Acme->new->connect },
);
done_testing();
```

The factory must return a **fresh, connected, empty** driver — note the `->connect`.

## 3. Run it and watch it fail

```bash
perl -Isrc t/unit/contract_acme.t
```

With the skeleton above you get the whole method surface confirmed present, capabilities
accepted, and then:

```
ok 1 - [Acme] is a Driver implementing the whole surface
ok 2 - [Acme] capabilities() is a conformant §6 object
PVE::Storage::FCLU::Driver::Acme does not implement 'create_lu' (fclu-driver-api-1, §2)
```

That is your work queue. Implement `create_lu`, re-run, get told the next missing method.
Repeat until the suite is green.

## 4. A sensible implementation order

1. `create_lu`, `get_lu`, `delete_lu`, `list_lus` — provisioning, and the data shapes.
2. `set_lu_label`, `resize_lu` — converging setters.
3. `get_lu_identity` — the NAA/EUI the host uses to find the device.
4. `ensure_host_access`, `publish_lu`, `unpublish_lu`, `list_lu_mappings`, `target_ports`
   — read [Host access](driver-contract.md#host-access-is-where-drivers-get-hard) **before** starting these.
5. Optional, capability-gated: snapshots, clones, QoS.

## 5. Read the reference implementation as you go

`src/PVE/Storage/FCLU/Driver/Mock.pm` is a complete driver implementing the entire
contract against an in-memory fake array. It is the executable reference the conformance
suite was written against, and it is the best answer to "what exactly should this return?".

Read it, but **do not start by copying it**: roughly 40 of its lines are fault-injection
scaffolding (`arm_fault`, `_maybe_fault`, `clear_faults`) that exists so the framework's
own tests can simulate array failures. You would spend your first hour deleting machinery
you do not need. Start from the skeleton above and consult Mock per method.

## 6. Developing off a PVE node

The driver contract has no PVE dependencies, so a driver and its contract test run
anywhere Perl does. The plugin shim (Part 2) does not: it inherits from
`PVE::Storage::Plugin`, which only exists on a Proxmox install, so loading it on a laptop
fails with *"Base class package PVE::Storage::Plugin is empty"*. The unit tests solve this
with a `BEGIN` block of minimal stubs — see the top of `t/unit/plugin.t` and copy it.

---

# The contract

Part 1 gets you a driver that is *shaped* right. What makes it correct under failure,
concurrency and retry — the things that do not show up until production — is the contract
reference:

**→ [`driver-contract.md`](driver-contract.md)**

It covers the full method surface, the data shapes, the idempotency and retry table, the
error vocabulary, capability advertisement, and the host-access safety invariants.

Two sections there are not optional reading, because getting them wrong loses or corrupts
data rather than merely failing:

- [Idempotency and retry](driver-contract.md#idempotency-and-retry--read-this-one-twice) —
  a driver that ignores it passes every unit test and leaks LUs in production.
- [Host access](driver-contract.md#host-access-is-where-drivers-get-hard) — wholesale
  unmapping breaks live migration, hidden mappings make delete unsafe, and merging into a
  foreign host object exposes your LUNs to another cluster.

---

# Part 2 — Shipping it

## The plugin shim

The only file that touches Proxmox. It declares vendor identity and maps `storage.cfg` to
your driver's constructor. Model it on `src/PVE/Storage/Custom/HitachiBlockPlugin.pm`:

```perl
package PVE::Storage::Custom::AcmePlugin;

use strict;
use warnings;

# `use base`, not `use parent -norequire` — base.pm loads the parent if it is not
# already loaded. With -norequire and no preceding `use`, every method inherited
# from FCLU::Plugin is unreachable and PVE cannot load the plugin.
use base qw(PVE::Storage::FCLU::Plugin);

use PVE::Storage::FCLU::Driver::Acme;

sub type         { 'acmeblock' }                               # storage.cfg type
sub vendor       { 'acme' }
sub driver_class { 'PVE::Storage::FCLU::Driver::Acme' }

sub driver_config {
    my ($class, $scfg) = @_;
    return {
        mgmt_ip => $scfg->{mgmt_ip},
        pool_id => $scfg->{pool_id},
    };
}

1;
```

`properties()` and `options()` then declare your typed `storage.cfg` fields in PVE's
`SectionConfig` style — this is the one place you do have to meet Proxmox on its own
terms. Copy the Hitachi shim's versions and adapt; they are the clearest worked example.

**Credentials are not your problem.** Do not put a username or password in
`driver_config` — the core's `_build_driver` injects them from the cluster-private
credential store (mode 0600, never written to `storage.cfg`), and your constructor simply
receives `username` and `password`.

## Packaging

Add a binary package stanza to `debian/control` depending on `pve-fclu-core`, list your
files in `debian/pve-fclu-<vendor>.install`, and add the install lines to the `Makefile`.
Follow `pve-fclu-hitachi`. The core declares `Provides: fclu-driver-api-1`, which is what
your driver package depends on.

## What the framework already does for you

Do not reimplement these — if you find yourself writing one, you are in the wrong layer:

- **Host-side FC and multipath** (`Host/FCMultipath.pm`) — device discovery, multipath
  settling, WWID handling. Vendor-neutral; an FC array reuses it as-is.
- **The volume registry** — the `volname` → backend-id mapping, snapshot records, and
  crash-safe commit/rollback.
- **Credential storage** — cluster-private, never in `storage.cfg`.
- **PVE integration** — `alloc_image`, `free_image`, `activate_volume`, clone and snapshot
  orchestration, `volume_has_feature` wiring, the GUI panel.
- **Transactional rollback** — the core undoes partial work when a step fails; you report
  accurately with typed errors and it does the compensation.

## What passing the conformance suite does and does not prove

Passing it *is* the definition of conforming to `fclu-driver-api-1`, and you should not
consider a driver submittable without it. It asserts the §12.1 data shapes, the §12.2
idempotency rules, node-targeted unpublish, and that failures are conformant typed errors.

It does **not** prove your driver works. It cannot see async convergence under real
latency, partial-side-effect classification, whether your vendor error mapping is right,
foreign-host safety on a shared array, concurrency races, or array-busy retry behaviour.
Those need hardware. `docs/test-plan.md` is the live validation runbook, and its phases
are what actually qualified the Hitachi driver.

## Getting help

Open an issue at <https://github.com/ciroiriarte/pve-FCLUPlugin>. A driver for a second
vendor is the most valuable contribution this project can receive right now: the
vendor-neutral abstraction has so far only been exercised by one array family, so the
first outside driver is what proves — or corrects — the design.

If the contract makes something awkward for your array, that is worth reporting even if
you work around it. The contract is not finished, and a second implementation is exactly
what surfaces the parts that were quietly shaped around Hitachi.
