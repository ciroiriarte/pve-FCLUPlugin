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
# updates.
sub _with_registry_lock {
    my ($self, $code) = @_;

    croak "code must be a coderef" unless ref $code eq 'CODE';

    my $critical = sub {
        my $registry = $self->_read_registry_unlocked();
        my @result   = $code->($registry);
        $self->_write_registry_atomic($registry);
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
        for grep { exists $meta{$_} } qw(backend_id snapshots);

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
sub reserve_volname {
    my ($self, $vmid, %opts) = @_;

    croak "vmid is required" unless defined $vmid;
    my $prefix = $opts{base} ? 'base' : 'vm';

    return $self->_with_registry_lock( sub {
        my ($reg) = @_;
        my $max = 0;
        for my $name ( keys %$reg ) {
            if ( $name =~ /^(?:vm|base)-${vmid}-disk-(\d+)$/ ) {
                $max = $1 if $1 > $max;
            }
        }
        my $name = "${prefix}-${vmid}-disk-" . ( $max + 1 );
        $reg->{$name} = { reserved => 1, timestamp => time() };
        return $name;
    } );
}

# Atomically rename a registry entry (used by create_base: vm-... -> base-...).
sub rename_volume {
    my ($self, $old_volname, $new_volname) = @_;

    croak "old_volname is required" unless $old_volname;
    croak "new_volname is required" unless $new_volname;

    $self->_with_registry_lock( sub {
        my ($reg) = @_;
        croak "Volume '$old_volname' not in registry" unless $reg->{$old_volname};
        croak "Volume '$new_volname' already exists"   if $reg->{$new_volname};
        $reg->{$new_volname} = delete $reg->{$old_volname};
        return;
    } );

    return 1;
}

# Return an arrayref of volnames that list $volname as their parent (linked clones).
sub find_dependents {
    my ($self, $volname) = @_;

    my $reg = $self->load();
    my @deps;
    for my $name ( keys %$reg ) {
        next if $name eq $volname;
        my $entry = $reg->{$name};
        next unless ref $entry eq 'HASH';
        push @deps, $name
            if defined $entry->{parent_volname} && $entry->{parent_volname} eq $volname;
    }
    return \@deps;
}

# Return an arrayref of volnames cloned from a specific snapshot of $volname (they
# record parent_volname + parent_snap). Used to refuse deletion of a snapshot whose
# child volume still backs linked clones.
sub find_snapshot_dependents {
    my ($self, $volname, $snapname) = @_;

    croak "volname is required"  unless $volname;
    croak "snapname is required" unless $snapname;

    my $reg = $self->load();
    my @deps;
    for my $name ( keys %$reg ) {
        next if $name eq $volname;
        my $entry = $reg->{$name};
        next unless ref $entry eq 'HASH';
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
    my ($self, $volname, $source, $target) = @_;

    croak "volname is required"         unless $volname;
    croak "source snapname is required" unless $source;
    croak "target snapname is required" unless $target;
    return 1 if $source eq $target;

    $self->_with_registry_lock( sub {
        my ($reg) = @_;
        my $snaps = $reg->{$volname} && $reg->{$volname}{snapshots};
        croak "snapshot '$source' not found for '$volname'"
            unless $snaps && $snaps->{$source};
        croak "target snapshot '$target' already exists for '$volname'"
            if $snaps->{$target};
        $snaps->{$target} = delete $snaps->{$source};
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
