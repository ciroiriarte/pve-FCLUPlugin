# Writing an FCLU driver

This guide is for someone who wants to add support for a new storage array — Dell
PowerStore, Pure FlashArray, IBM FlashSystem, NetApp, anything else — without having read
the rest of this codebase.

You should not need to understand Proxmox's storage plugin API, multipath, or how PVE
clones a VM. That is the framework's job. Your job is to translate 18 method calls into
your array's management API.

## What you are actually building

Four things, in this order:

| # | File | What it is |
|---|---|---|
| 1 | `src/PVE/Storage/FCLU/Driver/<Vendor>.pm` | The driver. This is the real work. |
| 2 | `src/PVE/Storage/Custom/<Vendor>Plugin.pm` | A ~40-line shim declaring vendor identity and `storage.cfg` fields. |
| 3 | `t/unit/contract_<vendor>.t` | Three lines. Runs the conformance suite against your driver. |
| 4 | `debian/pve-fclu-<vendor>.install` + a `debian/control` stanza | Your driver's package. |

There is no fifth thing. You do not write host-side code, registry code, rollback logic,
or PVE integration.

## Start by reading the reference implementation

`src/PVE/Storage/FCLU/Driver/Mock.pm` is a complete, working, 558-line driver that
implements the entire contract against an in-memory fake array. It is not a toy — it is
the executable reference the conformance suite is written against.

Read it first. Then copy it and replace the in-memory hash operations with calls to your
array. That is genuinely the intended workflow.

`src/PVE/Storage/FCLU/Driver.pm` is the abstract base: it implements no behaviour, and
every contract method dies with "not implemented" so a half-finished driver fails loudly
instead of silently returning `undef`.

## Step 1 — the driver class

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
```

### The 18 methods you must implement

```
session/introspection   connect  disconnect  ping  detect_profile
                        capabilities  storage_status

LU lifecycle            create_lu  delete_lu  get_lu  list_lus
                        set_lu_label  resize_lu

host access             ensure_host_access  publish_lu  unpublish_lu
                        list_lu_mappings  target_ports

identity                get_lu_identity
```

### The 10 you may implement

```
qos                     set_lu_qos  get_lu_qos
pool/tier               migrate_lu
snapshots               create_snapshot  delete_snapshot  restore_snapshot
                        list_snapshots
clones                  create_linked_clone  create_full_clone
consistency groups      create_cg_snapshot
```

These are **capability-gated**. If your array cannot do snapshots, do not implement them
and do not advertise them — the framework will simply not offer the feature, and the
conformance suite skips those assertions. An array legitimately lacking a feature is not
non-conformant.

The canonical list lives in `@CONTRACT_METHODS` in `Driver.pm`, and you can always ask:

```bash
perl -Isrc -MPVE::Storage::FCLU::Driver \
  -e 'print join("\n", PVE::Storage::FCLU::Driver->mandatory_methods), "\n"'
```

### Three rules that matter more than the method list

**1. Normalize everything.** Methods take and return plain Perl hashes and scalars — never
raw vendor REST payloads. If your array calls a volume a "storage resource" with 40 JSON
fields, `get_lu` still returns the framework's LU descriptor shape. Copy the shapes from
`Mock.pm`; they are documented in `ARCHITECTURE.md` §12.1.

**2. A mutating method must not return until the change is observable.** Async job
polling, retries, endpoint failover and eventual-consistency waits all live *inside* your
driver. If your array returns a job ID, you poll it. The core assumes that when
`create_lu` returns, the LU exists and can be read back. This is the single most common
place a new driver goes subtly wrong, and it produces bugs that only appear under load.

**3. Die with a typed error, never a bare string.** See below.

## Step 2 — errors

Failures must die with a blessed `PVE::Storage::FCLU::Error` carrying a code from a closed
vocabulary. The core's transaction layer reads the classification to decide whether to
retry, roll back, or fail:

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

Translating your vendor's error codes into this vocabulary is real design work, not
mechanical mapping. Prefer your array's stable numeric/symbolic error codes over matching
English message text — message strings change between firmware revisions, and the Hitachi
driver had to retire exactly that kind of regex matching in favour of the array's
structured codes.

## Step 3 — capabilities

`capabilities()` returns what your array can actually do. Branches and their leaves:

```
snapshot     single  consistency_group  rollback
clone        linked  from_snapshot  from_base
copy         full  from_snapshot  from_base
qos          per_lu
resize       grow_online  shrink
transfer     import  migrate_pool
replication  tc  ur  gad
```

Unadvertised leaves default to 0. This drives `volume_has_feature`, the GUI, and which
optional methods are ever called — so an honest `capabilities()` is what keeps PVE from
asking your array for something it cannot do.

Capabilities may depend on the model or firmware you discover in `detect_profile()`. The
Hitachi driver uses this: QoS exists on some VSP models and not others, so it is reported
per-array rather than per-driver, and the framework gates the feature accordingly.

## Step 4 — the plugin shim

This is the only file that touches Proxmox. It declares vendor identity and maps
`storage.cfg` to your driver's constructor. Model it on
`src/PVE/Storage/Custom/HitachiBlockPlugin.pm`:

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
```

Then `properties()` and `options()` declare your typed `storage.cfg` fields in the usual
PVE `SectionConfig` style.

**Credentials are not your problem.** Do not put a username or password in
`driver_config` — the core's `_build_driver` injects them from the cluster-private
credential store (mode 0600, never written to `storage.cfg`), and your constructor simply
receives `username` and `password`.

## Step 5 — prove conformance

Passing the conformance suite *is* the definition of conforming to `fclu-driver-api-1`.
Your entire test file:

```perl
use lib 'src'; use lib 't/lib';
use FCLU::ContractTest qw(run_contract_tests);
use PVE::Storage::FCLU::Driver::Acme;

run_contract_tests(
    name    => 'Acme',
    factory => sub { PVE::Storage::FCLU::Driver::Acme->new(...) },
);
done_testing();
```

`factory` must return a **fresh, connected, empty** driver. The suite asserts the §12.1
data shapes, the §12.2 idempotency and retry rules, and that your failures are conformant
typed errors — and it skips capability-gated areas your driver does not advertise.

Against a real array you will want the factory to talk to hardware, or to a vendor
simulator. Run `make test` for the whole suite.

**Developing off a PVE node.** The driver contract has no PVE dependencies, so a driver
and its contract test run anywhere Perl does. The plugin shim does not: it inherits from
`PVE::Storage::Plugin`, which only exists on a Proxmox install, so loading it on a laptop
fails with *"Base class package PVE::Storage::Plugin is empty"*. The unit tests solve this
with a `BEGIN` block of minimal stubs — see the top of `t/unit/plugin.t` and copy it. That
lets you develop and test the whole driver without a PVE machine; you only need real
hardware for the `docs/test-plan.md` phases.

Passing the contract suite means your driver is *shaped* correctly. It does not mean it
works on hardware — `docs/test-plan.md` is the live validation runbook, and its phases are
what actually qualified the Hitachi driver.

## Step 6 — packaging

Add a binary package stanza to `debian/control` depending on `pve-fclu-core`, list your
files in `debian/pve-fclu-<vendor>.install`, and add the install lines to the `Makefile`.
Follow `pve-fclu-hitachi`. The core declares `Provides: fclu-driver-api-1`, which is what
your driver package depends on.

## What the framework already does for you

Do not reimplement these — if you find yourself writing one, you are in the wrong layer:

- **Host-side FC and multipath** (`Host/FCMultipath.pm`) — device discovery, multipath
  settling, WWID handling. It is vendor-neutral; an FC array reuses it as-is.
- **The volume registry** — the `volname` → backend-id mapping, snapshot records, and
  crash-safe commit/rollback.
- **Credential storage** — cluster-private, never in `storage.cfg`.
- **PVE integration** — `alloc_image`, `free_image`, `activate_volume`, clone and snapshot
  orchestration, `volume_has_feature` wiring, the GUI panel.
- **Transactional rollback** — the core undoes partial work when a step fails; you report
  accurately with typed errors and it does the compensation.

## Getting help

Open an issue at <https://github.com/ciroiriarte/pve-FCLUPlugin>. A driver for a second
vendor is the most valuable contribution this project can receive right now: the
vendor-neutral abstraction has so far only been exercised by one array family, so the
first outside driver is what proves — or corrects — the design.

If the contract makes something awkward for your array, that is worth reporting even if
you work around it. The contract is not finished, and a second implementation is exactly
what surfaces the parts that were quietly shaped around Hitachi.
