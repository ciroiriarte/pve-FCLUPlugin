# The FCLU driver contract

The reference specification for `fclu-driver-api-1`: the method surface, the data shapes,
the idempotency rules, the error vocabulary, capability advertisement, and the host-access
safety invariants.

This is the companion to [`driver-authoring.md`](driver-authoring.md), which is the
tutorial. If you are starting a driver, go there first and get a skeleton running — come
here when you are implementing each method for real, and read
[Host access](#host-access-is-where-drivers-get-hard) before you touch the host-access
methods.

Section numbers (§12.1, §12.2, §6, §13) refer to [`../ARCHITECTURE.md`](../ARCHITECTURE.md),
which is normative if anything here disagrees with it.

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

