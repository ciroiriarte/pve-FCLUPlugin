package PVE::Storage::FCLU::Registry;

use strict;
use warnings;

use JSON qw(encode_json decode_json);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Fcntl qw(:flock);
use IO::Handle;
use Carp qw(croak);

# Vendor-neutral volume registry (ARCHITECTURE.md §7, §9 Phase 1). Generalized
# from the Hitachi Config.pm registry: it maps a PVE volname to an opaque
# backend_id plus recorded identity and metadata, so the core can resolve volids
# and enforce reservation/identity/clone invariants WITHOUT querying the array.
#
# Two deliberate generalizations off the Hitachi original (§7):
#   * The integer `ldev_id` becomes an OPAQUE `backend_id` (string) — entries are
#     compared with `eq`, never int(), so a driver wrapping non-numeric handles
#     (Pure NAA, PowerStore UUID) works unchanged.
#   * The cluster lock domain is `fclu-registry-<storeid>` — generic, but still a
#     DEDICATED domain (not cfs_lock_storage), preserving the original's
#     self-deadlock avoidance (PVE already holds cfs_lock_storage around
#     vdisk_alloc/free/activate; re-taking it here would stall every op).
#
# The entry shape is (§7):
#   volname => {
#     backend_id => "1234",          # opaque, was ldev_id
#     identity   => { ... },         # canonical device id (naa/eui/wwid)
#     size_mb, pool_ref,
#     parent_volname, parent_snap,   # linked-clone lineage
#     protected, notes,              # PVE volume attrs (#15)
#     backend_meta => { ... },       # driver scratch
#     snapshots => { snapname => { ... } },
#   }
# All keys except `backend_id` and the `snapshots` subregistry are opaque %meta.

use constant DEFAULT_BASE_DIR => '/etc/pve/priv/fclu';

# Seconds to wait for the cluster registry lock before giving up.
use constant DEFAULT_LOCK_TIMEOUT => 10;

sub new {
    my ($class, %opts) = @_;

    croak "storeid is required" unless $opts{storeid};

    return bless {
        storeid      => $opts{storeid},
        base_dir     => $opts{base_dir} // DEFAULT_BASE_DIR,
        lock_timeout => $opts{lock_timeout} // DEFAULT_LOCK_TIMEOUT,
    }, $class;
}

# ── Locking & atomic persistence ──

sub _read_registry_unlocked {
    my ($self) = @_;

    my $file = $self->_registry_file();
    return {} unless -f $file;

    open( my $fh, '<', $file ) or croak "Cannot read registry $file: $!";
    local $/;
    my $content = <$fh>;
    close($fh);

    return {} unless $content && length($content) > 0;

    my $data = eval { decode_json($content) };
    croak "Registry $file is corrupt: $@" if $@;
    return $data;
}

sub _write_registry_atomic {
    my ($self, $registry) = @_;

    my $file = $self->_registry_file();
    my $dir  = dirname($file);
    make_path($dir) unless -d $dir;

    # Write to a temp file, fsync, then atomically rename into place so a crash
    # mid-write can never truncate or corrupt the live registry.
    my $tmp = "$file.tmp.$$";
    open( my $fh, '>', $tmp ) or croak "Cannot write registry $tmp: $!";
    print $fh encode_json($registry);
    $fh->flush;
    eval { $fh->sync };   # best-effort fsync
    close($fh);

    unless ( rename( $tmp, $file ) ) {
        my $err = $!;
        unlink($tmp);
        croak "Cannot commit registry $file: $err";
    }

    return 1;
}

# Run $code under an exclusive, cluster-wide lock with a freshly-loaded registry.
# $code receives the registry hashref, mutates it in place, and may return a value.
# The lock spans the whole read-modify-write so concurrent operations cannot lose
# updates. $code also receives a scalar ref: setting it to 1 skips the write (a
# refusal that changed nothing costs no pmxcfs write).
sub _with_registry_lock {
    my ($self, $code) = @_;

    croak "code must be a coderef" unless ref $code eq 'CODE';

    my $critical = sub {
        my $registry = $self->_read_registry_unlocked();
        my $nowrite  = 0;
        my @result   = $code->( $registry, \$nowrite );
        $self->_write_registry_atomic($registry) unless $nowrite;
        return [@result];
    };

    my $res = $self->_run_locked($critical);
    return wantarray ? @$res : $res->[0];
}

# Acquire the registry mutex (cluster-wide where possible) and run $critical,
# returning its (arrayref) result.
sub _run_locked {
    my ($self, $critical) = @_;

    if ( $self->_use_cluster_lock() ) {
        # DEDICATED corosync lock domain (NOT cfs_lock_storage) — see the header
        # note on self-deadlock avoidance. cfs_lock_* sets $@ and returns undef on
        # in-code failure; returns the coderef's value on success.
        my $res = PVE::Cluster::cfs_lock_domain(
            "fclu-registry-$self->{storeid}", $self->{lock_timeout}, $critical );
        croak "Cannot acquire cluster registry lock: $@" if $@;
        return $res;
    }

    my $lockfile = $self->_lock_file();
    my $dir      = dirname($lockfile);
    make_path($dir) unless -d $dir;

    open( my $lock_fh, '>', $lockfile )
        or croak "Cannot open registry lock $lockfile: $!";
    flock( $lock_fh, LOCK_EX )
        or croak "Cannot acquire registry lock $lockfile: $!";

    my $res;
    my $ok  = eval { $res = $critical->(); 1 };
    my $err = $@;
    close($lock_fh);   # releases the lock
    croak $err unless $ok;

    return $res;
}

# True when the registry is backed by pmxcfs and PVE::Cluster is loadable, so we
# can use the corosync-coordinated cluster lock. Cached after first probe. Unit
# tests redirect the registry to a tempdir, so they always take the flock path.
my $CLUSTER_LOCK_OK;
sub _use_cluster_lock {
    my ($self) = @_;

    return 0 unless $self->_registry_file() =~ m{^/etc/pve/};

    return $CLUSTER_LOCK_OK if defined $CLUSTER_LOCK_OK;
    $CLUSTER_LOCK_OK = eval {
        require PVE::Cluster;
        PVE::Cluster->can('cfs_lock_domain') ? 1 : 0;
    } || 0;
    return $CLUSTER_LOCK_OK;
}

# ── Volume registry ──

sub load {
    my ($self) = @_;

    my $file = $self->_registry_file();
    return {} unless -f $file;

    open( my $fh, '<', $file ) or croak "Cannot read registry $file: $!";
    flock( $fh, LOCK_SH );
    local $/;
    my $content = <$fh>;
    close($fh);

    return {} unless $content && length($content) > 0;
    my $data = eval { decode_json($content) };
    croak "Registry $file is corrupt: $@" if $@;
    return $data;
}

sub list { return $_[0]->load() }

sub register {
    my ($self, $volname, $backend_id, %meta) = @_;

    croak "volname is required"    unless $volname;
    croak "backend_id is required" unless defined $backend_id && length $backend_id;

    $self->_with_registry_lock( sub {
        my ($reg) = @_;
        my $existing = ( ref $reg->{$volname} eq 'HASH' ) ? $reg->{$volname} : {};
        # Enforce a stable volname <-> backend_id identity: a committed entry must
        # never be silently retargeted to a different backend (that would orphan the
        # old LU and point the volid at the wrong data). Re-registering the SAME
        # backend_id (resize, pool change, meta update) is fine. backend_id is
        # opaque, so compare as strings (§7) — never int().
        if ( defined $existing->{backend_id} && !$existing->{reserved}
            && $existing->{backend_id} ne $backend_id ) {
            croak "Registry conflict: '$volname' already maps to backend "
                . "$existing->{backend_id}; refusing to retarget to $backend_id";
        }
        # Merge over any existing entry (preserves snapshots / parent links unless
        # overridden) and clear the reservation marker now that the LU is real.
        my %entry = ( %$existing, backend_id => "$backend_id", %meta );
        delete $entry{reserved};
        $reg->{$volname} = \%entry;
        return;
    } );

    return 1;
}

# Merge arbitrary metadata keys into an existing volume's entry without touching
# its backend_id — used for per-volume attributes like `protected`/`notes` (#15).
# A key whose value is undef is removed. Croaks if the volume is unknown. Runs
# under the registry lock so it is cluster-safe and replicates across nodes.
sub update_meta {
    my ($self, $volname, %meta) = @_;

    croak "volname is required" unless $volname;

    # `backend_id` is identity-guarded (only register() may set/retarget it) and
    # `snapshots` is the subregistry owned by the register_snapshot() family —
    # neither is a free-form attribute, so refuse to let a metadata merge silently
    # overwrite them (closes an identity-bypass latent in the reference source).
    croak "update_meta must not touch reserved key '$_'"
        for grep { exists $meta{$_} } qw(backend_id snapshots cg_snapshots busy);

    $self->_with_registry_lock( sub {
        my ($reg) = @_;
        my $entry = $reg->{$volname};
        croak "Volume '$volname' not in registry" unless ref $entry eq 'HASH';
        for my $k ( keys %meta ) {
            if ( defined $meta{$k} ) { $entry->{$k} = $meta{$k} }
            else                     { delete $entry->{$k} }
        }
        return;
    } );

    return 1;
}

# Return the volname currently mapped to $backend_id, or undef. Used to reject
# importing/managing an LU already tracked under another name.
sub find_volname_by_backend {
    my ($self, $backend_id) = @_;

    croak "backend_id is required" unless defined $backend_id && length $backend_id;

    my $reg = $self->load();
    for my $name ( keys %$reg ) {
        my $e = $reg->{$name};
        next unless ref $e eq 'HASH' && defined $e->{backend_id};
        return $name if $e->{backend_id} eq $backend_id;
    }
    return undef;
}

sub unregister {
    my ($self, $volname) = @_;

    croak "volname is required" unless $volname;

    $self->_with_registry_lock( sub {
        my ($reg) = @_;
        delete $reg->{$volname};
        return;
    } );

    return 1;
}

# Atomically reserve the next free volume name for a VMID and insert a placeholder
# entry so concurrent allocations (same or other node) cannot pick the same name.
# Pass base => 1 to reserve a base-volume name. The reservation is finalized by a
# later register() or released by unregister() on failure.
# %opts: base => 1 for a base-* name; parent_volname / parent_snap (+ node) when
# reserving for a linked clone, so the in-flight clone counts as a dependent and the
# reservation is refused while a rollback is rewriting what it would copy: the named
# snapshot, or, for a clone of the live volume, a rollback to ANY of its snapshots
# (the P-VOL is mid reverse-copy).
sub reserve_volname {
    my ($self, $vmid, %opts) = @_;

    croak "vmid is required" unless defined $vmid;
    my $prefix = $opts{base} ? 'base' : 'vm';
    my %lineage = map { defined $opts{$_} ? ( $_ => $opts{$_} ) : () }
        qw(parent_volname parent_snap);

    # A refusal is returned out of the locked section (see begin_snapshot_restore).
    my ( $reserved, $refusal ) = $self->_with_registry_lock( sub {
        my ( $reg, $nowrite ) = @_;
        if ( defined( my $pv = $lineage{parent_volname} ) ) {
            my $ps    = $lineage{parent_snap};
            my $pe    = ref $reg->{$pv} eq 'HASH' ? $reg->{$pv} : {};
            my $snaps = $pe->{snapshots} || {};
            # #26: the parent is being deleted (free_image holds a live marker).
            if ( _mark_active( $pe->{busy}, $opts{node} ) ) {
                $$nowrite = 1;
                return ( undef, "can't clone '$pv': it is being "
                    . ( $pe->{busy}{op} // 'changed' ) . "\n" );
            }
            # #26: the snapshot is being deleted.
            if ( defined $ps && ref $snaps->{$ps} eq 'HASH'
                && _mark_active( $snaps->{$ps}{deleting}, $opts{node} ) ) {
                $$nowrite = 1;
                return ( undef, "can't clone from snapshot '$ps' of '$pv': it is being deleted\n" );
            }
            for my $sn ( defined $ps ? ($ps) : sort keys %$snaps ) {
                my $meta = $snaps->{$sn};
                next unless ref $meta eq 'HASH'
                    && _restore_mark_active( $meta->{restoring}, $opts{node} );
                $$nowrite = 1;
                return ( undef, defined $ps
                    ? "can't clone from snapshot '$ps' of '$pv': a rollback to it is running\n"
                    : "can't clone '$pv': a rollback to its snapshot '$sn' is running\n" );
            }
        }
        my $max = 0;
        for my $name ( keys %$reg ) {
            if ( $name =~ /^(?:vm|base)-${vmid}-disk-(\d+)$/ ) {
                $max = $1 if $1 > $max;
            }
        }
        my $name = "${prefix}-${vmid}-disk-" . ( $max + 1 );
        $reg->{$name} = { reserved => 1, timestamp => time(), %lineage };
        return ( $name, undef );
    } );
    die $refusal if defined $refusal;

    return $reserved;
}

# Atomically rename a registry entry (used by create_base: vm-... -> base-...).
# %opts: refuse_dependents => 'message prefix' — refuse (die "<prefix>: linked
# clone(s) depend on it: ...\n") if any volume, including an in-flight clone
# reservation, lists $old_volname as its parent; checked in the same locked write as
# the rename, so no clone can slip in between (#26). node => for marker staleness.
sub rename_volume {
    my ($self, $old_volname, $new_volname, %opts) = @_;

    croak "old_volname is required" unless $old_volname;
    croak "new_volname is required" unless $new_volname;

    my $refusal = $self->_with_registry_lock( sub {
        my ( $reg, $nowrite ) = @_;
        croak "Volume '$old_volname' not in registry" unless $reg->{$old_volname};
        if ( $reg->{$new_volname} ) {
            $$nowrite = 1;
            return "cannot rename '$old_volname': volume '$new_volname' already exists\n";
        }
        if ( defined $opts{refuse_dependents} ) {
            my $deps = _dependents_in( $reg, $old_volname );
            if (@$deps) {
                $$nowrite = 1;
                return "$opts{refuse_dependents}: linked clone(s) depend on it: "
                    . _dep_list( $reg, $deps ) . "\n";
            }
            if ( _mark_active( $reg->{$old_volname}{busy}, $opts{node} ) ) {
                $$nowrite = 1;
                return "$opts{refuse_dependents}: it is being "
                    . ( $reg->{$old_volname}{busy}{op} // 'changed' ) . "\n";
            }
            # Snapshot markers are keyed under the volume: a rename would carry them away
            # from their owner (its pair_released / unregister would then miss).
            if ( defined( my $sop = _live_snapshot_op( $reg->{$old_volname}, $opts{node} ) ) ) {
                $$nowrite = 1;
                return "$opts{refuse_dependents}: $sop is running\n";
            }
        }
        $reg->{$new_volname} = delete $reg->{$old_volname};
        # Repoint every clone of the old name (they only exist without refuse_dependents).
        for my $e ( values %$reg ) {
            next unless ref $e eq 'HASH';
            $e->{parent_volname} = $new_volname
                if ( $e->{parent_volname} // '' ) eq $old_volname;
        }
        return undef;
    } );
    die $refusal if defined $refusal;

    return 1;
}

# Return an arrayref of volnames that list $volname as their parent (linked clones).
sub find_dependents {
    my ($self, $volname) = @_;
    return _dependents_in( $self->load(), $volname );
}

# Pure scan: volumes (incl. live clone reservations) whose parent is $volname.
sub _dependents_in {
    my ($reg, $volname) = @_;
    my @deps;
    for my $name ( keys %$reg ) {
        next if $name eq $volname;
        my $entry = $reg->{$name};
        next unless _counts_as_dependent($entry);
        push @deps, $name
            if defined $entry->{parent_volname} && $entry->{parent_volname} eq $volname;
    }
    return \@deps;
}

sub _dep_list {
    my ($reg, $deps) = @_;
    return join( ', ', map { $reg->{$_}{reserved} ? "$_ (clone in progress)" : $_ } sort @$deps );
}

# Return an arrayref of volnames cloned from a specific snapshot of $volname (they
# record parent_volname + parent_snap). Used to refuse deletion of a snapshot whose
# child volume still backs linked clones.
sub find_snapshot_dependents {
    my ($self, $volname, $snapname) = @_;

    croak "volname is required"  unless $volname;
    croak "snapname is required" unless $snapname;

    return _snapshot_dependents_in( $self->load(), $volname, $snapname );
}

# A clone's reservation counts as a dependent only while its build could still be
# running. Linked-clone creation takes seconds; a reservation older than this was
# left by a killed process and must not pin its parent forever (a reserved entry has
# no backend_id, so pvesm cannot free it).
use constant RESERVATION_DEP_TTL => 3600;

sub _counts_as_dependent {
    my ($entry) = @_;
    return 0 unless ref $entry eq 'HASH';
    return 1 unless $entry->{reserved};
    return time() - ( $entry->{timestamp} // 0 ) <= RESERVATION_DEP_TTL ? 1 : 0;
}

# Pure scan over an already-loaded registry, so the locked mutators below can check
# dependents against the SAME snapshot of state they are about to write. Counts a
# clone still being built: clone_image reserves its volname with the parent fields
# set, so an in-flight clone blocks delete/rollback exactly like a committed one.
sub _snapshot_dependents_in {
    my ($reg, $volname, $snapname) = @_;

    my @deps;
    for my $name ( keys %$reg ) {
        next if $name eq $volname;
        my $entry = $reg->{$name};
        next unless _counts_as_dependent($entry);
        push @deps, $name
            if defined $entry->{parent_volname} && $entry->{parent_volname} eq $volname
            && defined $entry->{parent_snap}    && $entry->{parent_snap}    eq $snapname;
    }
    return \@deps;
}

sub lookup {
    my ($self, $volname) = @_;

    my $reg   = $self->load();
    my $entry = $reg->{$volname};
    return undef unless $entry;

    return wantarray ? ( $entry->{backend_id}, $entry ) : $entry->{backend_id};
}

# ── Snapshot subregistry ──
# Per-volume snapshot metadata: volname -> { snapshots => { snapname -> { ... } } }

sub register_snapshot {
    my ($self, $volname, $snapname, %meta) = @_;

    croak "volname is required"  unless $volname;
    croak "snapname is required" unless $snapname;

    $self->_with_registry_lock( sub {
        my ($reg) = @_;
        croak "Volume '$volname' not in registry" unless $reg->{$volname};

        $reg->{$volname}{snapshots} //= {};
        $reg->{$volname}{snapshots}{$snapname} = { timestamp => time(), %meta };
        return;
    } );

    return 1;
}

# Rename a snapshot's registry key, preserving its metadata. Croaks if the source
# is missing or the target already exists. Cluster-safe (under the registry lock).
sub rename_snapshot {
    my ($self, $volname, $source, $target, %opts) = @_;

    croak "volname is required"         unless $volname;
    croak "source snapname is required" unless $source;
    croak "target snapname is required" unless $target;
    return 1 if $source eq $target;

    my $refusal = $self->_with_registry_lock( sub {
        my ( $reg, $nowrite ) = @_;
        my $snaps = $reg->{$volname} && $reg->{$volname}{snapshots};
        croak "snapshot '$source' not found for '$volname'"
            unless $snaps && $snaps->{$source};
        croak "target snapshot '$target' already exists for '$volname'"
            if $snaps->{$target};
        # A rollback or delete in flight owns a marker keyed by the name; renaming would
        # carry it away from the owner, which then could not clear it (#26).
        for my $k (qw(restoring deleting)) {
            next unless _mark_active( $snaps->{$source}{$k}, $opts{node} );
            $$nowrite = 1;
            return "can't rename snapshot '$source' of '$volname': a "
                . ( $k eq 'restoring' ? 'rollback to' : 'delete of' ) . " it is running\n";
        }
        $snaps->{$target} = delete $snaps->{$source};
        # Repoint linked clones pinned to the old name in the same write, otherwise
        # find_snapshot_dependents stops seeing them and delete/rollback of the
        # renamed snapshot would pass its dependent guard.
        $reg->{$_}{parent_snap} = $target
            for @{ _snapshot_dependents_in( $reg, $volname, $source ) };
        return undef;
    } );
    die $refusal if defined $refusal;

    return 1;
}

# ── Rollback serialization ──
#
# A restore rewrites the volume from the snapshot, which breaks any linked clone
# sharing that snapshot's blocks. The dependent check and the "restore in progress"
# marker are taken in ONE locked write, and clone_image's reservation refuses a
# snapshot carrying a live marker, so whichever of rollback/clone reaches the
# registry first wins. The marker is NOT held under the registry lock (a restore can
# run for hours); it records who set it so a crashed rollback cannot pin the
# snapshot forever: it is stale once its pid is gone on the recording node, or once
# its `expires` time passes. The caller supplies that TTL from the driver's restore
# budget (restore times are vendor facts); DEFAULT_RESTORE_MARK_TTL applies only
# when it does not.
use constant DEFAULT_RESTORE_MARK_TTL => 25 * 3600;

sub _restore_mark_active { return _mark_active(@_) }

# A marker { started, node, pid, expires } is live until it expires, or — seen from
# its own node — until its pid is gone.
sub mark_active { my ( $self, $mark, $node ) = @_; return _mark_active( $mark, $node ) }

# Overridable for tests. True only when the cluster positively reports $node offline.
our $NODE_OFFLINE = sub {
    my ($n) = @_;
    my $m = eval { require PVE::Cluster; PVE::Cluster::get_members() };
    return 0 unless ref $m eq 'HASH' && ref $m->{$n} eq 'HASH';
    return $m->{$n}{online} ? 0 : 1;
};

sub _mark_active {
    my ($mark, $node, %o) = @_;

    return 0 unless ref $mark eq 'HASH';
    my $expires = $mark->{expires}
        // ( ( $mark->{started} // 0 ) + DEFAULT_RESTORE_MARK_TTL );
    return 0 if time() > $expires;
    if ( defined $node && defined $mark->{node} && $mark->{node} eq $node
        && $mark->{pid} ) {
        return 0 unless kill( 0, $mark->{pid} ) || $!{EPERM};
    }
    # Takeover only (the retry of a delete/free, #26): a retry-safe marker from a node
    # corosync reports offline may be taken over, otherwise a crashed node blocks the
    # retry elsewhere until expiry. A second delete/free over the first is guarded
    # against id reuse (label check, pair_released). Every other gate (clones, rollback,
    # rename) keeps the strict rule: building on something a partitioned node may still
    # be destroying is not safe. The taker writes its own marker, so those stay blocked.
    if ( $o{takeover} && $mark->{retry_safe} && defined $mark->{node}
        && !( defined $node && $mark->{node} eq $node ) ) {
        return 0 if $NODE_OFFLINE->( $mark->{node} );
    }
    return 1;
}

# Check for dependents and set the restore marker atomically. Croaks (message ends
# in "\n", suitable for PVE) if the snapshot is missing, has dependents, or another
# restore of it is live. %opts: node => the caller's node name (for stale detection),
# ttl => seconds the marker stays authoritative (the driver's restore budget + margin).
sub begin_snapshot_restore {
    my ($self, $volname, $snapname, %opts) = @_;

    croak "volname is required"  unless $volname;
    croak "snapname is required" unless $snapname;

    # Refusals are RETURNED from the locked section and raised after it: dying inside
    # would surface as "Cannot acquire cluster registry lock: ..." on the pmxcfs path.
    my $refusal = $self->_with_registry_lock( sub {
        my ( $reg, $nowrite ) = @_;
        $$nowrite = 1;   # every return below but the last is a refusal
        my $meta = $reg->{$volname} && $reg->{$volname}{snapshots}
            && $reg->{$volname}{snapshots}{$snapname};
        return "can't rollback, snapshot '$snapname' does not exist on '$volname'\n"
            unless $meta;

        my $deps = _snapshot_dependents_in( $reg, $volname, $snapname );
        return "can't rollback to '$snapname': linked clone(s) depend on this snapshot: "
            . join( ', ', map { $reg->{$_}{reserved} ? "$_ (clone in progress)" : $_ }
                sort @$deps ) . "\n" if @$deps;

        return "can't rollback to '$snapname': it is being deleted\n"
            if _mark_active( $meta->{deleting}, $opts{node} );
        return "can't rollback to '$snapname': '$volname' is being "
            . ( $reg->{$volname}{busy}{op} // 'changed' ) . "\n"
            if _mark_active( $reg->{$volname}{busy}, $opts{node} );

        my $m = $meta->{restoring};
        return "can't rollback to '$snapname': a rollback of this snapshot is already"
            . " running (node " . ( $m->{node} // '?' ) . ", pid " . ( $m->{pid} // '?' ) . ")\n"
            if _restore_mark_active( $m, $opts{node} );

        $$nowrite = 0;
        my $now = time();
        $meta->{restoring} = { started => $now, node => $opts{node}, pid => $$,
            expires => $now + ( $opts{ttl} // DEFAULT_RESTORE_MARK_TTL ) };
        return undef;
    } );
    die $refusal if defined $refusal;

    return 1;
}

# ── Delete serialization (#26) ──
#
# Same pattern as the restore marker, for operations that destroy what a linked clone
# would be built from: the dependent check and the marker are one locked write, and
# reserve_volname refuses a clone of a marked snapshot (`deleting`) or volume (`busy`).
# A successful delete removes the record and its marker with it; a failed one clears
# the marker it set. Stale like the restore marker (dead pid on its node, or expiry).
use constant DEFAULT_OP_MARK_TTL => 6 * 3600;

# First live restoring/deleting marker among the snapshots of entry $e, as
# "rollback to snapshot 'x'" / "delete of snapshot 'x'", or undef.
sub _live_snapshot_op {
    my ($e, $node) = @_;
    my $snaps = ref $e eq 'HASH' && ref $e->{snapshots} eq 'HASH' ? $e->{snapshots} : {};
    for my $sn ( sort keys %$snaps ) {
        my $m = $snaps->{$sn};
        next unless ref $m eq 'HASH';
        return "a rollback to snapshot '$sn'" if _mark_active( $m->{restoring}, $node );
        return "a delete of snapshot '$sn'"   if _mark_active( $m->{deleting},  $node );
    }
    return undef;
}

sub _new_mark {
    my (%opts) = @_;
    my $now = time();
    return { started => $now, node => $opts{node}, pid => $$, retry_safe => 1,
        expires => $now + ( $opts{ttl} // DEFAULT_OP_MARK_TTL ), %{ $opts{extra} // {} } };
}

sub _own_mark {
    my ($m, %opts) = @_;
    return ref $m eq 'HASH' && ( $m->{pid} // 0 ) == $$
        && ( $m->{node} // '' ) eq ( $opts{node} // '' );
}

# Check dependents and mark snapshot $snapname of $volname as being deleted. Dies
# (PVE-ready message) if it has dependents, a rollback to it is running, or another
# delete of it is live. %opts: node, ttl.
sub begin_snapshot_delete {
    my ($self, $volname, $snapname, %opts) = @_;

    croak "volname is required"  unless $volname;
    croak "snapname is required" unless $snapname;

    my $refusal = $self->_with_registry_lock( sub {
        my ( $reg, $nowrite ) = @_;
        my $meta = $reg->{$volname} && $reg->{$volname}{snapshots}
            && $reg->{$volname}{snapshots}{$snapname};
        $$nowrite = 1;
        return "snapshot '$snapname' not found for volume '$volname'\n" unless ref $meta eq 'HASH';
        my $deps = _snapshot_dependents_in( $reg, $volname, $snapname );
        return "cannot delete snapshot '$snapname' of '$volname': linked clone(s) depend on it: "
            . _dep_list( $reg, $deps ) . "\n" if @$deps;
        return "cannot delete snapshot '$snapname' of '$volname': a rollback to it is running\n"
            if _mark_active( $meta->{restoring}, $opts{node} );
        my $m = $meta->{deleting};
        return "cannot delete snapshot '$snapname' of '$volname': another delete of it is running"
            . " (node " . ( $m->{node} // '?' ) . ", pid " . ( $m->{pid} // '?' ) . ")\n"
            if _mark_active( $m, $opts{node}, takeover => 1 ) && !_own_mark( $m, %opts );
        return "cannot delete snapshot '$snapname' of '$volname': '$volname' is being "
            . ( $reg->{$volname}{busy}{op} // 'changed' ) . "\n"
            if _mark_active( $reg->{$volname}{busy}, $opts{node} );
        $$nowrite = 0;
        $meta->{deleting} = _new_mark(%opts);
        return undef;
    } );
    die $refusal if defined $refusal;

    return 1;
}

# Clear the delete marker this process set; tolerates a record that is already gone.
sub end_snapshot_delete {
    my ($self, $volname, $snapname, %opts) = @_;

    $self->_with_registry_lock( sub {
        my ( $reg, $nowrite ) = @_;
        my $meta = $reg->{$volname} && $reg->{$volname}{snapshots}
            && $reg->{$volname}{snapshots}{$snapname};
        if ( ref $meta eq 'HASH' && _own_mark( $meta->{deleting}, %opts ) ) {
            delete $meta->{deleting};
        } else {
            $$nowrite = 1;
        }
        return;
    } );

    return 1;
}

# Check dependents and mark volume $volname busy with $op ('deleted', ...). Dies if a
# linked clone (or a clone in progress) depends on it, or another operation holds it.
# %opts: node, ttl, what => message prefix (default "cannot delete '$volname'").
sub begin_volume_op {
    my ($self, $volname, $op, %opts) = @_;

    croak "volname is required" unless $volname;
    croak "op is required"      unless $op;
    my $what = $opts{what} // "cannot delete '$volname'";

    my $refusal = $self->_with_registry_lock( sub {
        my ( $reg, $nowrite ) = @_;
        my $e = $reg->{$volname};
        $$nowrite = 1;
        return "volume '$volname' not found in registry\n" unless ref $e eq 'HASH';
        my $deps = _dependents_in( $reg, $volname );
        return "$what: linked clone(s) depend on it: " . _dep_list( $reg, $deps ) . "\n" if @$deps;
        my $m = $e->{busy};
        return "$what: it is being " . ( $m->{op} // 'changed' ) . " (node " . ( $m->{node} // '?' )
            . ", pid " . ( $m->{pid} // '?' ) . ")\n"
            if _mark_active( $m, $opts{node}, takeover => 1 ) && !_own_mark( $m, %opts );
        if ( defined( my $sop = _live_snapshot_op( $e, $opts{node} ) ) ) {
            return "$what: $sop is running\n";
        }
        $$nowrite = 0;
        $e->{busy} = _new_mark( %opts, extra => { op => $op } );
        return undef;
    } );
    die $refusal if defined $refusal;

    return 1;
}

# Clear the busy marker this process set; tolerates an entry that is already gone.
sub end_volume_op {
    my ($self, $volname, %opts) = @_;

    $self->_with_registry_lock( sub {
        my ( $reg, $nowrite ) = @_;
        my $e = $reg->{$volname};
        if ( ref $e eq 'HASH' && _own_mark( $e->{busy}, %opts ) ) {
            delete $e->{busy};
        } else {
            $$nowrite = 1;
        }
        return;
    } );

    return 1;
}

# Clear the restore marker THIS process set (same pid + node), never one a later
# rollback set after ours was judged stale. Tolerates a snapshot that vanished.
# %opts: node => the same node name passed to begin_snapshot_restore.
sub end_snapshot_restore {
    my ($self, $volname, $snapname, %opts) = @_;

    $self->_with_registry_lock( sub {
        my ($reg) = @_;
        my $meta = $reg->{$volname} && $reg->{$volname}{snapshots}
            && $reg->{$volname}{snapshots}{$snapname};
        my $m = ref $meta eq 'HASH' ? $meta->{restoring} : undef;
        delete $meta->{restoring}
            if ref $m eq 'HASH' && ( $m->{pid} // 0 ) == $$
            && ( $m->{node} // '' ) eq ( $opts{node} // '' );
        return;
    } );

    return 1;
}

# Record the LU that presents a snapshot (its "source": the S-VOL a clone or a host
# read uses), compare-and-set under the registry lock. If the snapshot already has a
# source, that one wins and is returned unchanged; otherwise $svol is recorded with
# %extra (e.g. svol_owned => 1, svol_identity => {...}). Returns the effective source,
# or undef if the snapshot no longer exists.
sub set_snapshot_source {
    my ($self, $volname, $snapname, $svol, %extra) = @_;

    croak "volname is required"  unless $volname;
    croak "snapname is required" unless $snapname;
    croak "svol is required"     unless defined $svol && length $svol;

    return scalar $self->_with_registry_lock( sub {
        my ($reg) = @_;
        my $meta = $reg->{$volname} && $reg->{$volname}{snapshots}
            && $reg->{$volname}{snapshots}{$snapname};
        return undef unless ref $meta eq 'HASH';
        return $meta->{svol} if defined $meta->{svol} && length $meta->{svol};
        $meta->{svol} = "$svol";
        $meta->{$_} = $extra{$_} for keys %extra;
        return $meta->{svol};
    } );
}

# Drop LU $id from a snapshot record once it has been deleted: the recorded source
# (svol + its owned/label/identity keys) if it is $id, and a pending allocation that
# named $id. Keeps a retry from ever acting on an id the array may hand out again.
sub clear_snapshot_source {
    my ($self, $volname, $snapname, $id) = @_;

    croak "volname is required"  unless $volname;
    croak "snapname is required" unless $snapname;
    croak "id is required"       unless defined $id;

    $self->_with_registry_lock( sub {
        my ($reg) = @_;
        my $m = $reg->{$volname} && $reg->{$volname}{snapshots}
            && $reg->{$volname}{snapshots}{$snapname};
        return unless ref $m eq 'HASH';
        if ( defined $m->{svol} && "$m->{svol}" eq "$id" ) {
            delete @$m{qw(svol svol_owned svol_label svol_identity)};
        }
        delete $m->{svol_pending}
            if ref $m->{svol_pending} eq 'HASH' && ( $m->{svol_pending}{id} // '' ) eq "$id";
        return;
    } );

    return 1;
}

# Every backend id the registry knows: volumes, their snapshots' source LUs, and
# pending source allocations. For id allocation, so a fresh LU never reuses one.
sub known_backend_ids {
    my ($self) = @_;
    my @ids;
    for my $e ( values %{ $self->load } ) {
        next unless ref $e eq 'HASH';
        push @ids, $e->{backend_id} if defined $e->{backend_id};
        for my $sm ( values %{ $e->{snapshots} // {} } ) {
            next unless ref $sm eq 'HASH';
            push @ids, $sm->{svol} if defined $sm->{svol};
            push @ids, $sm->{svol_pending}{id}
                if ref $sm->{svol_pending} eq 'HASH' && defined $sm->{svol_pending}{id};
        }
    }
    return [ map {"$_"} @ids ];
}

# Merge metadata into an existing snapshot record (e.g. svol_identity after a host
# activation). The identity- and lifecycle-bearing keys have their own writers and
# are refused here. A key whose value is undef is removed. No-op if the snapshot is gone.
sub update_snapshot_meta {
    my ($self, $volname, $snapname, %meta) = @_;

    croak "volname is required"  unless $volname;
    croak "snapname is required" unless $snapname;
    croak "update_snapshot_meta must not touch reserved key '$_'"
        for grep { exists $meta{$_} } qw(snap_id svol svol_owned restoring deleting);

    $self->_with_registry_lock( sub {
        my ($reg) = @_;
        my $m = $reg->{$volname} && $reg->{$volname}{snapshots}
            && $reg->{$volname}{snapshots}{$snapname};
        return unless ref $m eq 'HASH';
        for my $k ( keys %meta ) {
            if ( defined $meta{$k} ) { $m->{$k} = $meta{$k} }
            else                     { delete $m->{$k} }
        }
        return;
    } );

    return 1;
}

sub unregister_snapshot {
    my ($self, $volname, $snapname) = @_;

    croak "volname is required"  unless $volname;
    croak "snapname is required" unless $snapname;

    $self->_with_registry_lock( sub {
        my ($reg) = @_;
        if ( $reg->{$volname} && $reg->{$volname}{snapshots} ) {
            delete $reg->{$volname}{snapshots}{$snapname};
            # Drop the snapshots hash entirely once the last snapshot is gone.
            delete $reg->{$volname}{snapshots}
                unless %{ $reg->{$volname}{snapshots} };
        }
        return;
    } );

    return 1;
}

sub lookup_snapshot {
    my ($self, $volname, $snapname) = @_;

    my $reg   = $self->load();
    my $entry = $reg->{$volname} or return undef;
    my $snaps = $entry->{snapshots} or return undef;

    return $snaps->{$snapname};
}

sub list_snapshots {
    my ($self, $volname) = @_;

    my $reg   = $self->load();
    my $entry = $reg->{$volname} or return {};

    return $entry->{snapshots} || {};
}

# The volume's CG-snapshot records (label => {snap_id, group, cg, timestamp}), symmetric
# with list_snapshots. Used by #7's OOB filter to exclude CG-snapshot pairs from the
# array-side out-of-band discovery (they are PVE-created, just tracked separately).
sub list_cg_snapshots {
    my ($self, $volname) = @_;

    my $reg   = $self->load();
    my $entry = $reg->{$volname} or return {};

    return $entry->{cg_snapshots} || {};
}

# ── Consistency groups (§6 snapshot.consistency_group) ──
#
# CG membership is a plain per-volume attribute (`cg` => "<name>", set via
# update_meta). A group snapshot is out-of-band (PVE's storage API is per-volume);
# its per-member records live under a SEPARATE `cg_snapshots` subtree so they never
# leak into volume_snapshot_info (the PVE per-volume snapshot view reads `snapshots`).

# Volnames currently tagged into consistency group $cg (excludes reservations).
sub find_cg_members {
    my ($self, $cg) = @_;
    croak "cg is required" unless defined $cg && length $cg;
    my $reg = $self->load();
    return [ sort grep {
        ref $reg->{$_} eq 'HASH' && !$reg->{$_}{reserved}
            && defined $reg->{$_}{cg} && $reg->{$_}{cg} eq $cg
    } keys %$reg ];
}

# All consistency groups on this store: { cgname => [volname, ...] }.
sub list_cgs {
    my ($self) = @_;
    my $reg = $self->load();
    my %cgs;
    for my $name ( keys %$reg ) {
        my $e = $reg->{$name};
        next unless ref $e eq 'HASH' && !$e->{reserved}
            && defined $e->{cg} && length $e->{cg};
        push @{ $cgs{ $e->{cg} } }, $name;
    }
    $_ = [ sort @$_ ] for values %cgs;
    return \%cgs;
}

# Record a member's array pair for a group snapshot labelled $label. Croaks if the
# label already exists for the volume (a partial/duplicate CG snapshot is invalid).
sub add_cg_snapshot {
    my ($self, $volname, $label, %rec) = @_;
    croak "volname is required" unless $volname;
    croak "label is required"   unless defined $label && length $label;

    $self->_with_registry_lock( sub {
        my ($reg) = @_;
        croak "Volume '$volname' not in registry" unless ref $reg->{$volname} eq 'HASH';
        $reg->{$volname}{cg_snapshots} //= {};
        croak "CG snapshot '$label' already exists for '$volname'"
            if $reg->{$volname}{cg_snapshots}{$label};
        $reg->{$volname}{cg_snapshots}{$label} = { timestamp => time(), %rec };
        return;
    } );
    return 1;
}

# Drop a member's CG-snapshot record (idempotent); prunes the empty subtree.
sub remove_cg_snapshot {
    my ($self, $volname, $label) = @_;
    croak "volname is required" unless $volname;
    croak "label is required"   unless defined $label && length $label;

    $self->_with_registry_lock( sub {
        my ($reg) = @_;
        if ( $reg->{$volname} && $reg->{$volname}{cg_snapshots} ) {
            delete $reg->{$volname}{cg_snapshots}{$label};
            delete $reg->{$volname}{cg_snapshots}
                unless %{ $reg->{$volname}{cg_snapshots} };
        }
        return;
    } );
    return 1;
}

# Every member record for a labelled CG snapshot: [ { volname, snap_id, group, cg,
# timestamp }, ... ]. Scans the whole registry (a member may have been untagged from
# the group after the snapshot), optionally filtered to $cg. Sorted by volname.
sub find_cg_snapshot {
    my ($self, $cg, $label) = @_;
    croak "label is required" unless defined $label && length $label;
    my $reg = $self->load();
    my @out;
    for my $v ( sort keys %$reg ) {
        my $e = $reg->{$v};
        next unless ref $e eq 'HASH';
        my $rec = $e->{cg_snapshots} && $e->{cg_snapshots}{$label} or next;
        next if defined $cg && ( $rec->{cg} // '' ) ne $cg;
        push @out, { volname => $v, %$rec };
    }
    return \@out;
}

# All recorded CG snapshots: { cgname => { label => [ { volname, snap_id, ... } ] } }.
sub list_all_cg_snapshots {
    my ($self) = @_;
    my $reg = $self->load();
    my %by;
    for my $v ( sort keys %$reg ) {
        my $e = $reg->{$v};
        next unless ref $e eq 'HASH' && $e->{cg_snapshots};
        for my $label ( keys %{ $e->{cg_snapshots} } ) {
            my $rec = $e->{cg_snapshots}{$label};
            push @{ $by{ $rec->{cg} // '?' }{$label} }, { volname => $v, %$rec };
        }
    }
    return \%by;
}

# ── Internal ──

sub _registry_file {
    my ($self) = @_;
    return "$self->{base_dir}/$self->{storeid}.json";
}

sub _lock_file {
    my ($self) = @_;
    return $self->_registry_file() . '.lock';
}

1;
