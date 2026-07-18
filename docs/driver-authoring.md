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
- **Where the time actually goes** — host access (§ *Host access is where drivers get
  hard*), async job convergence, and translating your array's error codes into the
  framework's vocabulary. Budget most of your time here, not on the CRUD.

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
   — read the host-access section below **before** starting these.
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
anywhere Perl does. The plugin shim (Part 3) does not: it inherits from
`PVE::Storage::Plugin`, which only exists on a Proxmox install, so loading it on a laptop
fails with *"Base class package PVE::Storage::Plugin is empty"*. The unit tests solve this
with a `BEGIN` block of minimal stubs — see the top of `t/unit/plugin.t` and copy it.

---

# Part 2 — The contract

Part 1 gets you a driver that is *shaped* right. This part is what makes it correct under
failure, concurrency and retry — the things that do not show up until production.

## The 18 methods you must implement

```
session/introspection   connect  disconnect  ping  detect_profile
                        capabilities  storage_status

LU lifecycle            create_lu  delete_lu  get_lu  list_lus
                        set_lu_label  resize_lu

host access             ensure_host_access  publish_lu  unpublish_lu
                        list_lu_mappings  target_ports

identity                get_lu_identity
```

## The 10 you may implement

```
qos                     set_lu_qos  get_lu_qos
pool/tier               migrate_lu
snapshots               create_snapshot  delete_snapshot  restore_snapshot
                        list_snapshots
clones                  create_linked_clone  create_full_clone
consistency groups      create_cg_snapshot
```

These are **capability-gated**. If your array cannot do snapshots, do not implement them
and do not advertise them — the framework will not offer the feature, and the conformance
suite skips those assertions. An array legitimately lacking a feature is not
non-conformant.

The canonical list lives in `@CONTRACT_METHODS` in `Driver.pm`:

```bash
perl -Isrc -MPVE::Storage::FCLU::Driver \
  -e 'print join("\n", PVE::Storage::FCLU::Driver->mandatory_methods), "\n"'
```

## Data shapes

Methods take and return plain Perl hashes and scalars — **never raw vendor REST
payloads**. If your array calls a volume a "storage resource" with 40 JSON fields,
`get_lu` still returns the shape below. The normative definitions are `ARCHITECTURE.md`
§12.1; the ones people get wrong:

**`backend_id`** — opaque LU handle. Non-empty string, must match `/^[\w.:-]{1,255}$/`
(it gets interpolated into taint-mode paths), stable for the LU's life. Wrapping an
integer id? Stringify it.

**LU descriptor** (`get_lu`, entries of `list_lus`):

```perl
{
  backend_id => '1234',                       # MUST
  size_bytes => 53687091200,                  # MUST: BYTES, not MB
  label      => 'pve:store1:vm-100-disk-0',   # MUST be present; may be undef
  pool_ref   => '63',                         # MUST: opaque pool handle
  identity   => { ... },                      # SHOULD pre-publish; MUST after publish_lu
  backend_meta => { ... },                    # MAY: driver scratch, round-tripped verbatim
}
```

**`identity`** — how the host finds the device. Array-reported, lowercase hex, validated
by you before returning:

```perl
{ protocol => 'scsi-fc', ids => { naa => '60060e8012...', eui => undef, wwid => undef } }
```

**`%host_ctx`** — node identity passed to every host-access method:

```perl
{
  hostname   => 'pve-node-3',           # PVE node name
  protocol   => 'scsi-fc',              # closed enum; only scsi-fc in v1
  initiators => ['10000000c9abcdef'],   # FC WWPNs, lowercase hex, NO colons
}
```

**`target_ports`** — arrayref of `{ wwpn, port_id }`; `port_id` alone is conformant if you
cannot resolve WWPNs yet.

## Idempotency and retry — read this one twice

The core's transaction layer assumes these properties. A driver that ignores them passes
unit tests and corrupts or leaks in production.

| Method | Idempotent? | On "already in desired state" | Retry-safe? |
|---|---|---|---|
| `connect` / `ping` | yes | no-op | yes |
| `create_lu` | **no** (allocating) | — | only via `requested_id` re-assert |
| `delete_lu` | **yes** | success, **MUST NOT** throw `not_found` | yes |
| `ensure_host_access` | **yes** (MUST) | no-op success | yes |
| `publish_lu` | **yes** (MUST) | return existing mapping, no error | yes |
| `unpublish_lu` | **yes** (MUST) | success if already unmapped | yes |
| `set_lu_label` / `resize_lu` / `set_lu_qos` | **yes** (converge) | no-op success | yes |
| `create_snapshot` | no | — | via `snap_id` re-assert |
| `delete_snapshot` | **yes** | success if absent | yes |
| reads (`list_*`, `get_*`, `*_identity`) | yes | — | yes |

Three consequences worth stating plainly:

- **Allocating calls take a caller-supplied id.** If `create_lu` is given a
  `requested_id` that already exists **and its attributes match**, return it as success —
  that is what makes a create retry-safe after the core crashes mid-transaction. If it
  exists and mismatches, fail with `already_exists`.
- **Teardown converts absent to success; reads do not.** `delete_lu` on a missing LU is
  success. `get_lu` on a missing LU raises `not_found`. This asymmetry is deliberate and
  the suite tests both.
- **A mutation that times out is effectively `partial`, not retryable.** The core must
  run compensation rather than blindly reissuing a call that may have half-applied.

**A mutating method must not return until the change is observable.** Async job polling,
retries, endpoint failover and eventual-consistency waits all live *inside* your driver.
If your array returns a job id, you poll it. This is the single most common place a new
driver goes subtly wrong, and the resulting bugs only appear under load.

## Errors

Die with a blessed `PVE::Storage::FCLU::Error` carrying a code from a closed vocabulary —
never a bare string. The core reads the classification to decide retry vs rollback:

| Code | Retryable | Transient | Use for |
|---|---|---|---|
| `connectivity` | ✓ | ✓ | endpoint unreachable, TLS failure, connect timeout |
| `auth` | | | credentials rejected, session invalid |
| `array_busy` | ✓ | ✓ | busy, throttled, concurrent-op lock |
| `conflict` | | ✓ | precondition failed, optimistic lock, state mismatch |
| `not_found` | | | object absent |
| `already_exists` | | | id collision, mismatched attributes |
| `out_of_space` | | | pool capacity exhausted |
| `limit` | | | array object/host-group/LU count limit hit |
| `unsupported` | | | capability or firmware missing |
| `invalid` | | | bad argument or shape |
| `timeout` | | ✓ | async job did not converge |
| `partial` | | | half-applied, compensation required |
| `internal` | | | driver bug, unexpected vendor payload |

```perl
PVE::Storage::FCLU::Error->throw(
    code    => 'out_of_space',
    message => "pool $pool has no free capacity",
);
```

Translating your vendor's errors into this vocabulary is real design work. **Match on your
array's stable numeric or symbolic error codes, not on English message text** — messages
change between firmware revisions. The Hitachi driver had to retire exactly that kind of
regex matching in favour of the array's structured codes.

## Capabilities

`capabilities()` returns what your array can actually do:

```
snapshot     single  consistency_group  rollback
clone        linked  from_snapshot  from_base
copy         full  from_snapshot  from_base
qos          per_lu
resize       grow_online  shrink
transfer     import  migrate_pool
replication  tc  ur  gad
```

Every top-level branch must be present; `normalize()` handles that for you. Unadvertised
leaves are 0.

**`clone` and `copy` are not the same thing, and confusing them mis-drives PVE.** `clone`
means a persistent copy-on-write child — PVE's `clone_image` primitive. `copy` means a
full, non-CoW data copy. An array that can only do full copies **must** advertise `copy`
and leave `clone` empty, or PVE will drive `clone_image` onto a backend that cannot
provide it.

Capabilities may depend on the model or firmware you discover in `detect_profile()`. The
Hitachi driver does this: QoS exists on some VSP models and not others, so it is reported
per-array rather than per-driver.

## Host access is where drivers get hard

These five methods are mandatory, and they are the ones where a mistake corrupts data
rather than merely failing. The framework cannot enforce most of this for you, because
only your driver knows how your array models host objects.

**Unpublish is node-targeted.** `unpublish_lu($backend_id, %host_ctx)` MUST remove only
that node's mapping and leave every other node's intact. During a live migration the core
deliberately holds mappings on two nodes at once; a driver that "unmaps the LU" wholesale
will cut the data path out from under a running VM.

**`list_lu_mappings` is the sole authority for safe unmap and delete, so it must not hide
anything.** Return one descriptor per unique access path, and key it on an identifier the
array guarantees unique — Hitachi uses `port + hostGroupNumber` — **not** a display name
the array may truncate or duplicate. Collapsing two distinct paths into one entry means
the core believes an LU is unmapped when it is still live somewhere.

**Prove ownership before you map or unmap.** On an array shared by more than one cluster,
two clusters can collide on the same host-group name, or a group can be mis-created. If
you find a host object that already contains initiators you do not recognise, **fail loudly
rather than merging into it** — silently adding your node's WWPNs to a foreign group
exposes this cluster's LUNs to another cluster's host, which is concurrent-write
corruption, not a cosmetic bug. `Driver::Hitachi` refuses in exactly this case; the
comment at the guard explains the reasoning.

**`ensure_host_access` must be safe to call on every publish.** The core does not track
host-object state — your driver reconciles. Expect it to be called constantly.

---

# Part 3 — Shipping it

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
