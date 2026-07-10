package PVE::Storage::FCLU::Driver;

use strict;
use warnings;

use Carp qw(croak);

use PVE::Storage::FCLU::Error;

# Abstract array-backend contract for fclu-driver-api-1 (ARCHITECTURE.md §2, §12).
#
# This is the surface every vendor driver subclasses and the contract-test suite
# (§12.5) asserts against. The base class implements NO behaviour: each contract
# method croaks "not implemented" so a half-finished driver fails loudly rather
# than silently returning undef. `Driver::Mock` is the executable reference
# implementation.
#
# Method inputs/outputs are normalized plain Perl hashes/scalars (§12.1) — NEVER
# raw vendor REST payloads. Async-job polling, retries, endpoint failover and
# eventual-consistency waits stay INSIDE the driver (§2): a mutating method MUST
# NOT return until array state is observable, or it MUST die with an
# FCLU::Error (§12.4, §13).
#
# On failure a driver dies with a blessed PVE::Storage::FCLU::Error (§13) — never
# a bare string. See that module for the closed `code` vocabulary and the
# retryable/transient classification the core's Txn layer (§7) consumes.

# The canonical method surface of fclu-driver-api-1, grouped as in §2. Exposed so
# the contract suite and `Driver::Mock` can assert completeness against one list
# instead of a hand-copied duplicate. `optional => 1` marks a capability-gated
# method (§6): a driver MAY leave it unimplemented if it does not advertise the
# matching capability, but if present it MUST honour the §12 shapes.
my @CONTRACT_METHODS = (
    # --- session / introspection ---
    { name => 'connect' },
    { name => 'disconnect' },
    { name => 'ping' },
    { name => 'detect_profile' },
    { name => 'capabilities' },
    { name => 'storage_status' },
    # --- LU lifecycle ---
    { name => 'create_lu' },
    { name => 'delete_lu' },
    { name => 'get_lu' },
    { name => 'list_lus' },
    { name => 'set_lu_label' },
    { name => 'resize_lu' },
    { name => 'set_lu_qos', optional => 1 },
    { name => 'get_lu_qos', optional => 1 },
    { name => 'migrate_lu', optional => 1 },
    # --- host access ---
    { name => 'ensure_host_access' },
    { name => 'publish_lu' },
    { name => 'unpublish_lu' },
    { name => 'list_lu_mappings' },
    { name => 'target_ports' },
    # --- identity ---
    { name => 'get_lu_identity' },
    # --- snapshots / clones (capability-gated) ---
    { name => 'create_snapshot', optional => 1 },
    { name => 'delete_snapshot', optional => 1 },
    { name => 'restore_snapshot', optional => 1 },
    { name => 'list_snapshots', optional => 1 },
    { name => 'create_linked_clone', optional => 1 },
    { name => 'create_full_clone', optional => 1 },
    { name => 'create_cg_snapshot', optional => 1 },
);

# Class-method accessors over the canonical surface (returned as copies so callers
# cannot mutate the master list).
sub contract_methods { return map { $_->{name} } @CONTRACT_METHODS }
sub mandatory_methods { return map { $_->{name} } grep { !$_->{optional} } @CONTRACT_METHODS }
sub optional_methods  { return map { $_->{name} } grep { $_->{optional} } @CONTRACT_METHODS }

# A trivial base constructor. Drivers typically override to stash endpoint /
# credentials / profile; the contract does not mandate a particular shape, only
# that `new` returns a blessed object on which the contract methods are callable.
sub new {
    my ($class, %args) = @_;
    return bless { %args }, $class;
}

# Shared "you forgot to implement this" raiser. Uses `internal` (driver bug) so a
# stub reaching the core surfaces as a structured error, not a bare die. `croak`
# reports the caller's line, pointing at the offending call site.
sub _nyi {
    my ($self, $method) = @_;
    my $class = ref($self) || $self;
    croak "$class does not implement '$method' (fclu-driver-api-1, §2)";
}

# --- session / introspection ---------------------------------------------------

# connect(%opts) -> $self (or true). Authenticates and selects a live endpoint;
# performs endpoint failover internally. Idempotent + retry-safe (§12.2).
sub connect { my ($self) = @_; $self->_nyi('connect') }

# disconnect(). Tears down the session/endpoint. Best-effort; see the
# teardown-on-error rule — drivers MUST guarantee session logout.
sub disconnect { my ($self) = @_; $self->_nyi('disconnect') }

# ping() -> true. Cheap liveness/auth probe. Idempotent, retry-safe (§12.2).
sub ping { my ($self) = @_; $self->_nyi('ping') }

# detect_profile() -> \%profile. Model/firmware/quirk selection (§4): family,
# limits, capabilities, op_timeout_s, quirks. Drives normalization of every later
# response.
sub detect_profile { my ($self) = @_; $self->_nyi('detect_profile') }

# capabilities() -> \%cap. Normalized capability object (§6, §12.1). Every
# top-level branch (snapshot/clone/copy/qos/resize/transfer/replication) MUST be
# present; unsupported leaves are 0 or omitted (treated as 0).
sub capabilities { my ($self) = @_; $self->_nyi('capabilities') }

# storage_status() -> ($total, $free, $used) bytes for the configured pool/group.
sub storage_status { my ($self) = @_; $self->_nyi('storage_status') }

# --- LU lifecycle --------------------------------------------------------------

# create_lu(%args: size_bytes, pool_ref, requested_id?, label?) -> $backend_id.
# Allocating, so NOT idempotent in general; with `requested_id` it MUST be
# retry-safe: if that id exists and matches the requested attributes return it as
# success, if it exists and mismatches die `already_exists` (§12.2). `size_bytes`
# is integer bytes (§12.1). Returns an opaque `backend_id` string.
sub create_lu { my ($self) = @_; $self->_nyi('create_lu') }

# delete_lu($backend_id). Idempotent + retry-safe: "not found" MUST be converted
# to success internally, never raised (§12.2, §13.3).
#
# Teardown symmetry (§6): a clone S-VOL, like any volume, is mapped on activate and the
# contract has no paired driver-side unmap. The CORE owns the unmap — free_image runs
# the host teardown (this-node detach/unmap via deactivate_volume, then a cluster-wide
# reap via the optional unpublish_lu_all) BEFORE calling delete_lu — so
# delete_lu is always invoked on an already-unmapped LU. A driver whose array refuses
# to delete an LDEV that still has LU paths may rely on that guarantee; a driver whose
# delete implicitly clears mappings is equally conformant.
sub delete_lu { my ($self) = @_; $self->_nyi('delete_lu') }

# get_lu($backend_id) -> \%lu (LU descriptor, §12.1). Raises `not_found` if absent.
sub get_lu { my ($self) = @_; $self->_nyi('get_lu') }

# list_lus(%filter) -> [\%lu, ...]. MUST be complete enough for orphan detection
# (§12.3): every LU the driver could have created under this storage's pool, each
# with at least backend_id + label.
sub list_lus { my ($self) = @_; $self->_nyi('list_lus') }

# set_lu_label($backend_id, $label). Converges to target; idempotent no-op when
# already set (§12.2).
sub set_lu_label { my ($self) = @_; $self->_nyi('set_lu_label') }

# resize_lu($backend_id, $new_size_bytes). Grows online; converges to target,
# idempotent + retry-safe (§12.2). Shrink is not part of v1.
sub resize_lu { my ($self) = @_; $self->_nyi('resize_lu') }

# set_lu_qos($backend_id, \%qos). OPTIONAL, capability-gated (qos.per_lu). Converges.
sub set_lu_qos { my ($self) = @_; $self->_nyi('set_lu_qos') }

# get_lu_qos($backend_id) -> \%qos. OPTIONAL, capability-gated.
sub get_lu_qos { my ($self) = @_; $self->_nyi('get_lu_qos') }

# migrate_lu($backend_id, $dest_pool_ref). OPTIONAL pool/tier migration
# (capability transfer.migrate_pool).
sub migrate_lu { my ($self) = @_; $self->_nyi('migrate_lu') }

# --- host access ---------------------------------------------------------------

# ensure_host_access(%host_ctx) -> $access_handle. Idempotent (MUST): reconciles
# the per-node host object/group/masking-view, no-op success if already present.
# Safe to call on every publish (the core holds no host-object state) (§12.2).
sub ensure_host_access { my ($self) = @_; $self->_nyi('ensure_host_access') }

# publish_lu($backend_id, %host_ctx) -> \%mapping. Maps the LU to THAT node.
# Idempotent (MUST): if already mapped, return the existing mapping with no error.
sub publish_lu { my ($self) = @_; $self->_nyi('publish_lu') }

# unpublish_lu($backend_id, %host_ctx). Removes ONLY the %host_ctx node's mapping,
# leaving other nodes' mappings intact (§12.2 live-migration note). Idempotent
# (MUST): success if already unmapped.
sub unpublish_lu { my ($self) = @_; $self->_nyi('unpublish_lu') }

# list_lu_mappings($backend_id) -> [\%mapping, ...]. The SOLE authority for safe
# unmap/delete (§12.3): the real per-LU mapping set as Mapping descriptors (§12.1),
# never a filtered group scan. MUST NOT collapse distinct host-access paths — return
# one descriptor per unique access path (the driver must key on an identifier the array
# guarantees unique, e.g. Hitachi's port+hostGroupNumber, NOT a display name the array
# may truncate) so no live mapping is ever hidden. `hostname` is a best-effort hint.
sub list_lu_mappings { my ($self) = @_; $self->_nyi('list_lu_mappings') }

# target_ports(%host_ctx?) -> [\%endpoint, ...]. Array target ports for fabric
# zoning (§14): each { wwpn, port_id }, wwpn lowercase hex.
sub target_ports { my ($self) = @_; $self->_nyi('target_ports') }

# --- identity ------------------------------------------------------------------

# get_lu_identity($backend_id) -> \%identity. Canonical device identity (§12.1),
# the single source of truth for host-side matching (replaces WWID synthesis, §3):
# { protocol, ids => { naa, eui, wwid } }, at least one id set, array-reported,
# lowercase hex.
sub get_lu_identity { my ($self) = @_; $self->_nyi('get_lu_identity') }

# --- snapshots / clones (capability-gated) -------------------------------------

# create_snapshot($backend_id, %args: snap_id?) -> \%snap. OPTIONAL
# (snapshot.single). Allocating; retry-safe via `snap_id` re-assert (§12.2).
sub create_snapshot { my ($self) = @_; $self->_nyi('create_snapshot') }

# delete_snapshot($snap_id). OPTIONAL. Idempotent: success if absent (§12.2).
sub delete_snapshot { my ($self) = @_; $self->_nyi('delete_snapshot') }

# restore_snapshot($snap_id). OPTIONAL (snapshot.rollback).
sub restore_snapshot { my ($self) = @_; $self->_nyi('restore_snapshot') }

# list_snapshots($backend_id) -> [\%snap, ...]. OPTIONAL. Snapshot descriptors (§12.1).
sub list_snapshots { my ($self) = @_; $self->_nyi('list_snapshots') }

# create_linked_clone($backend_id, %args) -> $backend_id. OPTIONAL (clone.linked).
# Persistent CoW child — the PVE clone_image primitive (§6). Only advertise `clone`
# where the backend gives a real space-efficient CoW child. %args may carry
# requested_id. host_ctx is accepted for back-compat but a driver SHOULD NOT need to
# map the clone to create it (the reference Hitachi driver binds the S-VOL at pair
# creation, both volumes unmapped). §12.2: the pair MUST be observable to
# list_snapshots on return so the core can release it (#23).
sub create_linked_clone { my ($self) = @_; $self->_nyi('create_linked_clone') }

# create_full_clone($backend_id, %args) -> $backend_id. OPTIONAL (copy.full).
# Full, NON-CoW copy. NOT wired to qm clone --full (§6); out-of-band / fclu-CLI only.
sub create_full_clone { my ($self) = @_; $self->_nyi('create_full_clone') }

# create_cg_snapshot(\@backend_ids, %args) -> [\%snap, ...]. OPTIONAL
# (snapshot.consistency_group). Consistency-group snapshot.
sub create_cg_snapshot { my ($self) = @_; $self->_nyi('create_cg_snapshot') }

1;
