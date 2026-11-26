package PVE::Storage::FCLU::Plugin;

use strict;
use warnings;

use base qw(PVE::Storage::Plugin);

use POSIX qw(ceil);

use PVE::Storage::FCLU::Registry;
use PVE::Storage::FCLU::Credentials;
use PVE::Storage::FCLU::Capabilities;
use PVE::Storage::FCLU::Label;
use Digest::MD5 qw(md5_hex);

# The generic, vendor-neutral PVE Storage plugin base (ARCHITECTURE.md §5/§7).
# Almost every method body lives here; a per-vendor subclass is a thin shim that
# only declares type()/vendor()/driver_class()/driver_config() and merges vendor
# properties (see §5). The base orchestrates the shared core — Registry,
# Credentials, Label, the array Driver, and the Host Connector — so a driver adds
# no PVE-facing code.
#
# Slice 4A scope: identity, the abstract vendor hooks, the core accessors, and the
# vendor-neutral READ-ONLY/common methods (parse_volname, volume_has_feature,
# volume attributes, list_images, status, activate/deactivate_storage). The
# allocation/host-mapping/snapshot/clone orchestration lands in later slices.

# Storage API version window we have validated our method signatures against. api()
# reports the host's own APIVER clamped into this range so PVE loads us
# warning-free across tested hosts and only warns (never refuses) outside it.
use constant FCLU_MIN_APIVER => 10;
# 17 = the PVE 9.3 storage APIVER (libpve-storage-perl 9.1.17+). Reviewed against the
# ApiChangeLog for 15-17: v15 volume_resize($snapname) is refused below (no volume
# chains); v15 virtual-size and v16 format helpers serve volume chains / base-class
# alloc_image and rename_volume, which we do not use; v17 guest volume types are
# optional (parse_volname keeps returning 'images', and nothing here compares a vtype
# with 'images'). Reporting a lower value makes PVE log "implementing an older storage
# API". Raise as newer APIVERs are tested.
use constant FCLU_MAX_APIVER => 17;

# Per-storeid caches (PVE storage plugins are CLASS-based — no instance to hold
# state), mirroring the reference's %_clients. Cleared by deactivate_storage.
my %DRIVERS;

# Test seams: when set, the registry/credential stores are redirected here instead
# of /etc/pve/priv/fclu, so unit tests run without pmxcfs (and without
# monkey-patching). Production leaves them undef.
our $REGISTRY_BASE_DIR;
our $CREDS_BASE_DIR;

# ── Plugin identity ──

sub api {
    my $host = eval { PVE::Storage::APIVER() };
    return FCLU_MAX_APIVER if !defined $host;
    return FCLU_MAX_APIVER if $host > FCLU_MAX_APIVER;
    warn "FCLU: host storage APIVER $host is below the validated floor "
        . FCLU_MIN_APIVER . "; loading best-effort\n"
        if $host < FCLU_MIN_APIVER;
    return $host;
}

# Web UI field labels (schema 'title') and the advanced section, for the dialog that
# PVE 9.3+ generates from a third-party plugin's schema (storage API 17 changelog).
our %CORE_TITLES = (
    mgmt_ip               => 'Management endpoint',
    pool_id               => 'DP pool ID',
    snap_pool_id          => 'Snapshot pool ID',
    qos_upper_iops        => 'QoS upper IOPS',
    qos_upper_iops_per_gb => 'QoS upper IOPS per GiB',
    qos_upper_mbps        => 'QoS upper MB/s',
    qos_lower_iops        => 'QoS lower IOPS',
    qos_lower_mbps        => 'QoS lower MB/s',
    qos_priority          => 'QoS priority (1-3)',
    tls_verify            => 'Verify TLS certificate',
    tls_ca_file           => 'TLS CA file',
    lock_timeout          => 'Lock timeout (s)',
    debug                 => 'Debug level',
    device_timeout        => 'Device timeout (s)',
    surface_oob_snapshots => 'Show array-side snapshots',
    auto_cg               => 'Auto consistency group',
);
our @CORE_ADVANCED = qw(snap_pool_id qos_upper_iops qos_upper_iops_per_gb qos_upper_mbps
    qos_lower_iops qos_lower_mbps qos_priority tls_verify tls_ca_file lock_timeout debug
    device_timeout surface_oob_snapshots auto_cg);

sub plugindata {
    return {
        # images = VM disks; rootdir = LXC rootfs (PVE formats+mounts the raw LUN,
        # the block model); none = configurable with no content type.
        content => [ { images => 1, rootdir => 1, none => 1 }, { images => 1 } ],
        format  => [ { raw => 1 }, 'raw' ],
        # password is sensitive: PVE never writes it to storage.cfg and passes it to
        # the add/update hooks via %sensitive.
        'sensitive-properties' => { password => 1 },
        # Web UI (PVE 9.3+ generates the add/edit dialog from the schema; ignored by
        # older versions): tuning knobs go to the advanced section.
        'advanced-properties' => { map { $_ => 1 } @CORE_ADVANCED },
    };
}

# Add a 'title' to each property schema that has one in %$titles (copies; the schema
# hashes are not shared with callers).
sub _titled {
    my ($class, $props, $titles) = @_;
    return { map {
        my $k = $_;
        ( $k => { %{ $props->{$k} }, ( exists $titles->{$k} ? ( title => $titles->{$k} ) : () ) } )
    } keys %$props };
}

# ── Configuration schema (§5) ──
#
# The vendor-neutral, safe-to-share subset only. A vendor subclass MERGES its own
# typed properties over these (`{ %{ $class->SUPER::properties }, <vendor…> }`) and
# NEVER redeclares `username`/`password`: PVE's base/other plugins already define
# them, and a duplicate makes PVE::SectionConfig die "duplicate property" (§5). They
# are referenced (not defined) in options() so PVE keeps `password` out of
# storage.cfg and hands it to the add/update hooks via %sensitive.
sub properties {
    return __PACKAGE__->_titled( {
        mgmt_ip => {
            description => "Management endpoint (IP/hostname) of the array's control-plane"
                . " REST API. May be a comma-separated list for management-plane failover.",
            type        => 'string',
        },
        pool_id => {
            description => "Backend pool reference for volume (LU) allocation.",
            type        => 'string',
        },
        snap_pool_id => {
            description => "Pool reference for snapshot/clone allocation (defaults to pool_id).",
            type        => 'string',
            optional    => 1,
        },
        qos_upper_iops => {
            description => "Default upper IOPS limit per volume (0 = unlimited).",
            type        => 'integer', minimum => 0, optional => 1,
        },
        qos_upper_iops_per_gb => {
            description => "Adaptive upper IOPS limit that SCALES with volume size:"
                . " ceiling = size_GiB * this value (HBSD upperIopsPerGB). Takes precedence"
                . " over qos_upper_iops when set. Useful when one storage backs many"
                . " differently-sized disks.",
            type        => 'integer', minimum => 1, optional => 1,
        },
        qos_upper_mbps => {
            description => "Default upper throughput limit per volume in MB/s (0 = unlimited).",
            type        => 'integer', minimum => 0, optional => 1,
        },
        qos_lower_iops => {
            description => "Default lower IOPS guarantee per volume.",
            type        => 'integer', minimum => 0, optional => 1,
        },
        qos_lower_mbps => {
            description => "Default lower throughput guarantee per volume in MB/s.",
            type        => 'integer', minimum => 0, optional => 1,
        },
        qos_priority => {
            description => "Default QoS I/O response priority (1=high, 2=medium, 3=low).",
            type        => 'integer', minimum => 1, maximum => 3, optional => 1,
        },
        tls_verify => {
            description => "Verify the control-plane TLS certificate (default off for self-signed).",
            type        => 'boolean', default => 0, optional => 1,
        },
        tls_ca_file => {
            description => "CA bundle path used to verify the API certificate when tls_verify is on.",
            type        => 'string', optional => 1,
        },
        lock_timeout => {
            description => "Seconds to wait to ACQUIRE the per-storage cluster lock for"
                . " provisioning (alloc/free/clone). Extends only the acquisition wait; pmxcfs"
                . " still hard-caps the locked work at 60s.",
            type        => 'integer', minimum => 10, default => 120, optional => 1,
        },
        debug => {
            description => "Diagnostic logging verbosity (0 = off .. 3 = trace). Credentials are"
                . " never logged at any level.",
            type        => 'integer', minimum => 0, maximum => 3, default => 0, optional => 1,
        },
        device_timeout => {
            description => "Seconds to wait for a freshly mapped LUN's multipath device to"
                . " appear on this host during activation. Raise it for arrays whose LUN"
                . " presentation is slow under load (default 120).",
            type        => 'integer', minimum => 10, default => 120, optional => 1,
        },
        surface_oob_snapshots => {
            description => "Show array-side (out-of-band) snapshots — created by array"
                . " schedules, replication, or the array UI/CLI, not through PVE — in the"
                . " snapshot listing (as read-only 'oob-*' entries). Off by default: it adds"
                . " a live array read per snapshot-info call. Out-of-band snapshots are"
                . " display-only; delete/rollback of them is refused (manage on the array).",
            type        => 'boolean', default => 0, optional => 1,
        },
        auto_cg => {
            description => "Consistency/protection group to auto-assign every newly allocated"
                . " volume to (sets the volume's 'cg' attribute at alloc). New disks then"
                . " automatically join 'pve-fclu-cg' group snapshots — schedule those (e.g."
                . " via cron) for hands-off protection. Membership only; taking the snapshots"
                . " stays an explicit/scheduled pve-fclu-cg operation. Unset = no auto-assign.",
            type        => 'string', optional => 1,
        },
    }, \%CORE_TITLES );
}

sub options {
    return {
        mgmt_ip      => { fixed => 1 },
        pool_id      => { fixed => 1 },
        snap_pool_id => { optional => 1 },
        qos_upper_iops => { optional => 1 },
        qos_upper_iops_per_gb => { optional => 1 },
        qos_upper_mbps => { optional => 1 },
        qos_lower_iops => { optional => 1 },
        qos_lower_mbps => { optional => 1 },
        qos_priority   => { optional => 1 },
        tls_verify   => { optional => 1 },
        tls_ca_file  => { optional => 1 },
        lock_timeout => { optional => 1 },
        device_timeout => { optional => 1 },
        surface_oob_snapshots => { optional => 1 },
        auto_cg      => { optional => 1 },
        debug        => { optional => 1 },
        # Inherited PVE properties — referenced, never redeclared in properties().
        nodes    => { optional => 1 },
        shared   => { optional => 1 },
        disable  => { optional => 1 },
        content  => { optional => 1 },
        username => { optional => 1 },
        password => { optional => 1 },
    };
}

# ── Abstract vendor hooks (the subclass provides these) ──

sub _abstract {
    my ($class, $what) = @_;
    $class = ref($class) || $class;
    die "$class must define '$what' (FCLU::Plugin vendor hook, §5)\n";
}

sub type         { $_[0]->_abstract('type') }          # PVE storage type, e.g. 'hitachiblock'
sub vendor       { $_[0]->_abstract('vendor') }        # 'hitachi'
sub driver_class { $_[0]->_abstract('driver_class') }  # 'PVE::Storage::FCLU::Driver::Hitachi'

# Map storage.cfg ($scfg) to the driver constructor options (platform, pool ids,
# array ports, host-mode, …). Credentials are added by the base, not here.
sub driver_config { $_[0]->_abstract('driver_config') }

# The host-side connector; overridable for future transports (§3).
sub connector_class { return 'PVE::Storage::FCLU::Host::FCMultipath' }

# ── Core accessors ──

sub _registry {
    my ($class, $storeid) = @_;
    return PVE::Storage::FCLU::Registry->new(
        storeid => $storeid,
        ( defined $REGISTRY_BASE_DIR ? ( base_dir => $REGISTRY_BASE_DIR ) : () ),
    );
}

sub _credentials {
    my ($class, $storeid) = @_;
    return PVE::Storage::FCLU::Credentials->new(
        storeid => $storeid,
        ( defined $CREDS_BASE_DIR ? ( base_dir => $CREDS_BASE_DIR ) : () ),
    );
}

# Build a fresh (unconnected) driver from the vendor's driver_config + the stored
# credentials. This is the injection SEAM: tests override _build_driver to return
# a fake without credentials/network.
sub _build_driver {
    my ($class, $storeid, $scfg) = @_;
    my %opts = %{ $class->driver_config($scfg) };
    my ( $user, $pass ) = $class->_credentials($storeid)->read;
    my $dclass = $class->driver_class;
    _load_class($dclass);
    return $dclass->new( %opts, username => $user, password => $pass );
}

# Load a class named by string before calling a method on it. driver_class /
# connector_class are vendor-overridable strings, so the base cannot `use` them at
# compile time — a missing load surfaces only at runtime as "can't locate method
# new" (a real deployment bug the fake-injecting unit tests cannot see).
sub _load_class {
    my ($pkg) = @_;
    ( my $file = "$pkg.pm" ) =~ s{::}{/}g;
    require $file;
    return $pkg;
}

# Return the cached connected driver for this storage, building (and caching) one
# on demand if the storage is active but the cache was cleared (#13 resilience).
sub _driver {
    my ($class, $storeid, $scfg) = @_;
    return $DRIVERS{$storeid} if $DRIVERS{$storeid};
    my $d = $class->_build_driver( $storeid, $scfg );
    $d->connect;
    $DRIVERS{$storeid} = $d;
    return $d;
}

# ── Session lifecycle ──

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    # Tear down any stale cached session before replacing it (always-teardown).
    if ( my $old = delete $DRIVERS{$storeid} ) { eval { $old->disconnect } }
    my $d = $class->_build_driver( $storeid, $scfg );
    $d->connect;
    $DRIVERS{$storeid} = $d;
    # Verify the pool is reachable (cheap reachability probe).
    $d->storage_status;
    # NOTE (slice 4A): host-group pre-creation (ensure_host_access on all nodes)
    # and the snap-pool Thin-Image precheck move here in the activation slice.
    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    if ( my $d = delete $DRIVERS{$storeid} ) {
        eval { $d->disconnect };   # guaranteed teardown — never propagate
    }
    return 1;
}

# Reachability probe for PVE::Storage::activate_storage(), which calls this before
# activation and reports "storage '$storeid' is not online" when it returns false.
#
# Deliberately uses a THROWAWAY session rather than _driver(): the probe must not
# populate %DRIVERS (a cached session would outlive a probe on an inactive storage)
# nor tear down a session an active storage is using. Never dies — the caller wraps
# this in eval and treats a false return as offline, so an unreachable array must
# read as "offline", not as a fatal error.
sub check_connection {
    my ($class, $storeid, $scfg) = @_;

    my $ok = eval {
        my $d = $class->_build_driver( $storeid, $scfg );
        eval {
            $d->connect;
            $d->storage_status;   # reaching the pool, not just the endpoint
        };
        my $err = $@;
        eval { $d->disconnect };  # guaranteed teardown, success or failure
        die $err if $err;
        1;
    };

    return $ok ? 1 : 0;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;
    my ( $total, $free, $used ) = $class->_driver( $storeid, $scfg )->storage_status;
    return ( $total, $free, $used, 1 );
}

# ── Registration lifecycle (§5) ──
#
# Credentials live in the cluster-private FCLU::Credentials store (0600). `username`
# is a normal storage.cfg property; `password` is sensitive (§`sensitive-properties`)
# and arrives via %sensitive, never persisted to storage.cfg.

sub on_add_hook {
    my ($class, $storeid, $scfg, %sensitive) = @_;

    my $username = $scfg->{username};
    my $password = $sensitive{password};
    die "$class: 'username' and 'password' are required\n"
        if !defined $username || !defined $password;
    $class->_credentials($storeid)->store( $username, $password );

    # Connectivity probe: build a driver from this config, connect, reach the pool,
    # and ALWAYS tear the session down (never leak an array session on validation).
    my $d = $class->_build_driver( $storeid, $scfg );
    eval {
        $d->connect;
        $d->storage_status;
    };
    my $err = $@;
    eval { $d->disconnect };
    if ($err) {
        # Don't leave an orphan credential file for a storage PVE never created.
        eval { $class->_credentials($storeid)->delete };
        die "storage validation failed: $err";
    }

    return;
}

sub on_update_hook {
    my ($class, $storeid, $scfg, %sensitive) = @_;

    my $creds = $class->_credentials($storeid);

    # Explicit password clear (`pvesm set --delete password`) removes stored creds.
    if ( exists $sensitive{password} && !defined $sensitive{password} ) {
        $creds->delete;
        return;
    }

    my $username = $scfg->{username};
    # Use the new password when (re)set, else keep the stored one so a username-only
    # change still rewrites a complete credential file.
    my $password = $sensitive{password};
    $password = eval { ( $creds->read )[1] } if !defined $password;

    $creds->store( $username, $password )
        if defined $username && defined $password;

    return;
}

sub on_delete_hook {
    my ($class, $storeid, $scfg) = @_;
    $class->_credentials($storeid)->delete;
    return;
}

# Our volumes are raw block LUNs; snapshots are taken array-side (Thin Image et al.),
# transparently to a running guest — qemu never snapshots the disk itself.
sub volume_qemu_snapshot_method {
    my ($class, $storeid, $scfg, $volname) = @_;
    return 'storage';
}

# Per-storage lock ACQUISITION timeout (#10): PVE core wraps the mutating ops
# (alloc/free/clone/rename) in cluster_lock_storage with NO explicit timeout, so the
# pmxcfs default (~10s) applies — too short when many disks provision concurrently and
# serialize here. Substitute the configured `lock_timeout` only when PVE passes undef;
# an explicit caller timeout passes through. This extends only the wait to ACQUIRE the
# lock — pmxcfs still hard-caps the locked work at 60s, which no setting can change.
sub cluster_lock_storage {
    my ($class, $storeid, $shared, $timeout, $func, @param) = @_;

    if ( !defined $timeout ) {
        # PVE::Storage is fully loaded by lock time, so call it fully-qualified — a
        # compile-time `use PVE::Storage` would create a circular dep in a custom
        # plugin. The eval only guards reading storage.cfg before the cluster fs is up.
        my $configured;
        eval {
            my $cfg = PVE::Storage::config();
            $configured = $cfg->{ids}{$storeid}{lock_timeout};
        };
        warn "FCLU: lock_timeout lookup for '$storeid' failed, using default: $@" if $@;
        $timeout = $configured // 120;
    }

    return $class->SUPER::cluster_lock_storage( $storeid, $shared, $timeout, $func, @param );
}

# ── Volume lifecycle: provision + map (§5/§7) ──
#
# alloc creates the array LU and commits it to the registry LAST (so a mid-flight
# failure rolls back cleanly); the host mapping is deferred to activate_volume,
# which PVE calls before any use. activate publishes the LU to THIS node (driver)
# then attaches the multipath device (connector) by the driver-reported canonical
# identity — no host-side WWID synthesis. deactivate is the strict reverse: tear
# the host device down FIRST, then unmap on the array.

# Vendor hooks (overridable by the subclass) ----------------------------------

# Allocate the backend id the driver should create (Hitachi: next free id in
# ldev_range). Default: undef => let the array auto-assign (§12.2).
sub _alloc_backend_id { return undef }

# Destructive-op safety fence (§7): may we unmap/delete this backend id? The
# registry membership is the primary fence (free_image looks the volume up first);
# a vendor MAY add a stricter check (Hitachi: ldev_range). Default: allow.
sub safe_delete_precheck { return 1 }

# Map QoS storage.cfg knobs to the driver's qos hash (generic field names). $size_bytes
# (when given) enables the adaptive per-GiB IOPS ceiling.
sub _qos_from_scfg {
    my ($class, $scfg, $size_bytes) = @_;
    my %qos;
    # N15: adaptive per-GiB upper IOPS — ceiling scales with volume size (HBSD
    # upperIopsPerGB). Takes precedence over the static qos_upper_iops. Clamped to >=1.
    if ( $scfg->{qos_upper_iops_per_gb} && $size_bytes ) {
        my $gib  = $size_bytes / ( 1024 * 1024 * 1024 );
        my $iops = int( $scfg->{qos_upper_iops_per_gb} * $gib );
        $qos{upper_iops} = $iops > 0 ? $iops : 1;
    }
    elsif ( $scfg->{qos_upper_iops} ) {
        $qos{upper_iops} = $scfg->{qos_upper_iops};
    }
    $qos{upper_mbps}        = $scfg->{qos_upper_mbps} if $scfg->{qos_upper_mbps};
    $qos{lower_iops}        = $scfg->{qos_lower_iops} if $scfg->{qos_lower_iops};
    $qos{lower_mbps}        = $scfg->{qos_lower_mbps} if $scfg->{qos_lower_mbps};
    $qos{response_priority} = $scfg->{qos_priority}   if $scfg->{qos_priority};
    return \%qos;
}

# The array snapshot group name for snapshot $snap of $backend_id. It encodes the
# volume's backend id, so a name-based array fallback search can never resolve to
# another volume's pair sharing this snapshot name (the reference's collision guard).
# The readable form is used when it fits the driver's max_group_len; otherwise a
# compact form keeps the backend id plus a hash of store, volume and snapshot name.
# Hitachi rejects (does not truncate) a name over 32 characters (#28). The name is
# recorded with the snapshot and never re-derived, so existing snapshots are unaffected.
sub _snapshot_group_name {
    my ($class, $storeid, $backend_id, $snap, $d) = @_;
    my $full = "pve_${storeid}_${backend_id}_${snap}";
    my $max  = $d->detect_profile->{max_group_len};
    return $full if !$max || length $full <= $max;
    my $pre = "pve_${backend_id}_";
    die "cannot build a snapshot group name for backend id '$backend_id' within $max characters\n"
        if length($pre) + 8 > $max;
    return substr( $pre . md5_hex("$storeid\0$backend_id\0$snap"), 0, $max );
}

# Ownership label, clamped to the driver's advertised max length (§7 — not a
# hardcoded 32 in the core; the constraint comes from the driver profile).
sub _make_label {
    my ($class, $storeid, $volname, $driver) = @_;
    my $max = $driver->detect_profile->{max_label_len};
    return PVE::Storage::FCLU::Label->make_label( $storeid, $volname, $max );
}

# Seams: the host connector and this node's name (overridable in tests).
sub _connector { my ($class) = @_; my $cc = $class->connector_class; _load_class($cc); return $cc->new }

sub _nodename {
    my ($class) = @_;
    my $n = eval { require PVE::INotify; PVE::INotify::nodename() };
    die "cannot determine the local PVE node name\n" unless defined $n && length $n;
    return $n;
}

# Resolve (volname, optional snapname) to its backend id + entry. $mode 'die'
# raises on a missing volume; 'soft' returns () (idempotent teardown path).
sub _resolve_backend {
    my ($class, $storeid, $scfg, $volname, $snapname, $mode) = @_;
    my $reg = $class->_registry($storeid);
    my ( $backend_id, $entry ) = $reg->lookup($volname);

    if ( defined $backend_id && $snapname ) {
        # A snapshot resolves ONLY to the LU that presents it (its source, recorded in
        # the snapshot record with its own identity), NEVER to the volume: falling back
        # would hand a reader the CURRENT disk under the snapshot's name, so a full clone
        # "from a snapshot" would silently copy live data (#27). activate_volume
        # materializes the source first; without one, fail closed.
        my $snap = $reg->lookup_snapshot( $volname, $snapname );
        # A half-deleted snapshot (pair gone, source delete pending a retry) no longer
        # holds its image: never hand its leftover LU to a reader.
        my $usable = $snap && !$snap->{pair_released};
        return ( "$snap->{svol}", { identity => $snap->{svol_identity} } )
            if $usable && defined $snap->{svol} && length $snap->{svol};
        return () if ( $mode // 'die' ) eq 'soft';
        die "snapshot '$snapname' not found for volume '$volname'\n" unless $snap;
        die "snapshot '$snapname' of '$volname' is being deleted; finish the delete\n"
            unless $usable;
        die "snapshot '$snapname' of '$volname' has no host-readable volume yet;"
            . " activate it first\n";
    }

    if ( !defined $backend_id ) {
        return () if ( $mode // 'die' ) eq 'soft';
        die "volume '$volname'" . ( $snapname ? "\@$snapname" : '' ) . " not found in registry\n";
    }
    return ( $backend_id, $entry );
}

# The LU that presents snapshot $snap of $volname (its "source"): the volume a host
# reads for a full copy, and the CoW parent of a linked clone. A recorded source is
# reused; otherwise the driver materializes one (materialize_snapshot, §2) and it is
# recorded as OWNED by the snapshot, so snapshot delete / free_image delete it (#27).
#
# Crash/race safety: the intended id + label are recorded (svol_pending) BEFORE the
# driver allocates, so a crash mid-way leaves a record cleanup can act on; the source
# write is compare-and-set; and nothing here deletes an LU that may already be
# assigned to the pair (a later call adopts it instead).
sub _snapshot_source {
    my ($class, $storeid, $scfg, $volname, $snap, $d) = @_;

    my $reg = $class->_registry($storeid);
    my ($pvol) = $reg->lookup($volname);
    die "volume '$volname' not found in registry\n" unless defined $pvol;
    my $sm = $reg->lookup_snapshot( $volname, $snap );
    die "snapshot '$snap' not found for volume '$volname'\n"
        unless $sm && defined $sm->{snap_id};
    die "snapshot '$snap' of '$volname' is being deleted; finish the delete\n"
        if $sm->{pair_released};
    return "$sm->{svol}" if defined $sm->{svol} && length $sm->{svol};

    $d //= $class->_driver( $storeid, $scfg );
    die "storage '$storeid' cannot present snapshot '$snap' of '$volname' as a volume"
        . " (the driver has no materialize_snapshot)\n"
        unless $d->can('materialize_snapshot');

    # An earlier attempt that crashed before assigning left an LDEV under its pending
    # id. Reclaim it before the record is overwritten, unless it became the pair's S-VOL
    # (the driver adopts that one) or the pair cannot be read (leave it alone then).
    # Only a STALE record (older than an hour): a fresh one may be another node still
    # building the same snapshot's source.
    if ( my $old = $sm->{svol_pending} ) {
        if ( defined $old->{id} && time() - ( $old->{started} // 0 ) > 3600 ) {
            my $pairs = eval { $d->list_snapshots($pvol) };
            my ($pair) = grep { $_->{snap_id} eq $sm->{snap_id} } @{ $pairs // [] };
            my $assigned = $pair && defined $pair->{meta}{svol} && "$pair->{meta}{svol}" eq "$old->{id}";
            if ( $pairs && !$assigned
                && ( $class->_owned_lun_check( $storeid, $scfg, $d, $old->{id}, $old->{label} ) // '' ) eq 'ok' )
            {
                $class->_unmap_owned_luns( $d, $sm, $old->{id} );
                eval { $d->delete_lu( $old->{id} ) };
                warn "FCLU: reclaiming abandoned snapshot volume '$old->{id}' failed: $@" if $@;
            }
        }
    }

    my $conn  = $class->_connector;
    my %hctx  = %{ $conn->host_context( hostname => $class->_nodename ) };
    $d->ensure_host_access(%hctx);   # a driver may need this node's host object (temporary paths)
    my $rid   = $class->_alloc_backend_id( $storeid, $scfg, $d );
    # Unique per snapshot even after label truncation (the cleanup guard relies on the
    # label identifying THIS snapshot's LU): keyed on the pair id, not the name, so it
    # also survives a snapshot rename.
    my $label = $class->_make_label( $storeid,
        "${volname}_" . substr( md5_hex("$sm->{snap_id}"), 0, 8 ), $d );
    $reg->update_snapshot_meta( $volname, $snap,
        svol_pending => { label => $label, started => time(), node => $class->_nodename,
            ( defined $rid ? ( id => "$rid" ) : () ) } );

    my $res = eval {
        $d->materialize_snapshot( $pvol, $sm->{snap_id},
            ( defined $rid ? ( requested_id => $rid ) : () ),
            host_ctx => \%hctx,
            label    => $label,
            ( defined $sm->{group} ? ( group => $sm->{group} ) : () ),
        );
    };
    if ( my $err = $@ ) {
        # The driver cleaned up after a definite failure, so drop the intent record.
        # Keep it when the outcome is uncertain (partial / timeout, or an unclassified
        # exception): snapshot delete then reclaims whatever was left.
        my $code = ref $err && eval { $err->isa('PVE::Storage::FCLU::Error') } ? $err->code : '';
        eval { $reg->update_snapshot_meta( $volname, $snap, svol_pending => undef ) }
            if $code && $code ne 'partial' && $code ne 'timeout';
        die $err;
    }
    my $svol = ref $res eq 'HASH' ? $res->{backend_id} : undef;
    die "driver materialize_snapshot returned no backend_id for '$volname\@$snap'\n"
        unless defined $svol && length $svol;
    # Never adopt the parent or a registered volume as a snapshot-owned LU: a stale
    # snap_id resolving to a linked clone's backing pair would hand back that clone,
    # and snapshot delete would then destroy it.
    die "refusing snapshot volume '$svol' for '$volname\@$snap': it is the parent or a"
        . " registered volume\n"
        if "$svol" eq "$pvol" || defined $reg->find_volname_by_backend($svol);

    # A driver that mapped the LU temporarily may have surfaced a host device; make
    # sure none lingers here. The identity is the driver's (taken while mapped) when given.
    my $ident = $res->{identity} // eval { $d->get_lu_identity($svol) };
    eval { $conn->detach($ident) } if $ident && $res->{created};
    my $lbl = $res->{created} ? $label : ( ( eval { $d->get_lu($svol) } // {} )->{label} // $label );

    my $eff = $reg->set_snapshot_source( $volname, $snap, $svol,
        svol_owned => 1, svol_label => $lbl, ( $ident ? ( svol_identity => $ident ) : () ) );
    die "snapshot '$snap' of '$volname' was deleted while it was being prepared;"
        . " volume '$svol' was left in place\n" unless defined $eff;
    if ( "$eff" ne "$svol" && $res->{created} ) {
        # Another caller recorded a different source first; ours is unreferenced.
        if ( ( $class->_owned_lun_check( $storeid, $scfg, $d, $svol, $label ) // '' ) eq 'ok' ) {
            eval { $d->delete_lu($svol) };
            warn "FCLU: deleting unused snapshot volume '$svol' failed: $@" if $@;
        }
    }
    $reg->update_snapshot_meta( $volname, $snap, svol_pending => undef );
    return "$eff";
}

sub _is_not_found {
    my ($class, $e) = @_;
    return $e->code eq 'not_found' if ref $e && eval { $e->isa('PVE::Storage::FCLU::Error') };
    return defined $e && "$e" =~ /\b404\b|not[ _]found/i ? 1 : 0;
}

# The LUs snapshot record $sm owns, as { backend_id => expected label }: its recorded
# source, plus — when an allocation was pending (crash before the source was recorded)
# — the pending id and the pair's live S-VOL ($pair_svol, from the driver).
sub _owned_snapshot_luns {
    my ($class, $sm, $pair_svol) = @_;
    my %c;
    $c{ $sm->{svol} } = $sm->{svol_label}
        if $sm->{svol_owned} && defined $sm->{svol} && length $sm->{svol};
    if ( my $p = $sm->{svol_pending} ) {
        $c{ $p->{id} } //= $p->{label} if defined $p->{id};
        $c{$pair_svol} //= $p->{label}
            if defined $pair_svol && length $pair_svol && !defined $sm->{svol};
    }
    return \%c;
}

# Gate before ANY unmap or delete of a snapshot-owned LU. Returns 'ok', 'gone'
# (already deleted) or undef (refused, with a warning). It must be inside the delete
# fence, not a registered volume, and still carry the label recorded when it was
# created: an id the array has since reused for another volume fails here and is
# left alone, which is what makes a retried delete safe.
sub _owned_lun_check {
    my ($class, $storeid, $scfg, $d, $id, $label) = @_;
    if ( !$class->safe_delete_precheck( $scfg, $id ) ) {
        warn "FCLU: snapshot volume '$id' is outside the delete fence; leaving it\n";
        return undef;
    }
    if ( defined $class->_registry($storeid)->find_volname_by_backend($id) ) {
        warn "FCLU: snapshot volume id '$id' now belongs to a registered volume; leaving it\n";
        return undef;
    }
    my $lu = eval { $d->get_lu($id) };
    if ( !$lu ) {
        my $e = $@;
        return 'gone' if $class->_is_not_found($e);
        warn "FCLU: cannot read snapshot volume '$id' ($e); leaving it\n";
        return undef;
    }
    if ( !defined $label || ( $lu->{label} // '' ) ne $label ) {
        warn "FCLU: snapshot volume '$id' no longer carries its label (id reused?); leaving it\n";
        return undef;
    }
    return 'ok';
}

# Host side of owned LUs: detach on this node and reap every mapping cluster-wide,
# so the pair and the LU can be deleted. Only for LUs that passed _owned_lun_check.
sub _unmap_owned_luns {
    my ($class, $d, $sm, @ids) = @_;
    for my $id (@ids) {
        eval { $class->_connector->detach( $sm->{svol_identity} ) }
            if $sm->{svol_identity} && defined $sm->{svol} && "$sm->{svol}" eq "$id";
        warn "FCLU: snapshot volume detach warning: $@" if $@;
        next unless $d->can('unpublish_lu_all');
        eval { $d->unpublish_lu_all($id) };
        warn "FCLU: snapshot volume unmap warning: $@" if $@;
    }
    return;
}

# Plan the cleanup of one snapshot's owned LUs: { id => 'ok' } for those that may be
# unmapped and deleted. $pair_svol is the pair's live S-VOL when known.
sub _owned_cleanup_plan {
    my ($class, $storeid, $scfg, $d, $sm, $pair_svol) = @_;
    my $c = $class->_owned_snapshot_luns( $sm, $pair_svol );
    my %ok;
    for my $id ( sort keys %$c ) {
        my $r = $class->_owned_lun_check( $storeid, $scfg, $d, $id, $c->{$id} );
        $ok{$id} = 1 if defined $r && $r eq 'ok';
    }
    return \%ok;
}

# Delete planned LUs (pair already gone) and drop them from the snapshot record right
# away, so a retry can never act on an id the array may hand out again.
sub _delete_owned_luns {
    my ($class, $reg, $d, $volname, $snap, $plan) = @_;
    for my $id ( sort keys %$plan ) {
        $d->delete_lu($id);
        $reg->clear_snapshot_source( $volname, $snap, $id );
    }
    $reg->update_snapshot_meta( $volname, $snap, svol_pending => undef );
    return 1;
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;
    die "unsupported format '$fmt'\n" if $fmt && $fmt ne 'raw';

    my $reg = $class->_registry($storeid);

    # Reserve a unique name under the cluster lock unless PVE supplied one; reject
    # an explicit name that already maps to a backend (never double-create).
    my $reserved = 0;
    if ( !$name ) {
        $name = $reg->reserve_volname($vmid);
        $reserved = 1;
    } else {
        $class->parse_volname($name);   # validate shape
        die "volume '$name' already exists in registry\n" if defined $reg->lookup($name);
    }

    my $size_bytes = ( $size || 0 ) * 1024;   # PVE size is KiB; the driver clamps to its min
    my $d = $class->_driver( $storeid, $scfg );

    my ( $backend_id, $committed ) = ( undef, 0 );
    eval {
        my %opts = ( size_bytes => $size_bytes, pool_ref => $scfg->{pool_id} );
        my $rid = $class->_alloc_backend_id( $storeid, $scfg, $d );
        $opts{requested_id} = $rid if defined $rid;
        $backend_id = $d->create_lu(%opts);
        die "driver create_lu returned no backend_id\n" unless defined $backend_id;

        $d->set_lu_label( $backend_id, $class->_make_label( $storeid, $name, $d ) );

        # QoS is best-effort AND capability-gated: only attempt it where the control
        # plane actually supports per-volume QoS (Hitachi: VSP F/G350-900 / VSP 5000 —
        # NOT the E series or VSP One, whose embedded REST has no QoS surface). Calling
        # it elsewhere only draws an [invalid] from the array. A limit-set failure must
        # never fail provisioning.
        my $qos = $class->_qos_from_scfg( $scfg, $size_bytes );
        if (%$qos) {
            if ( PVE::Storage::FCLU::Capabilities->has_feature( $d->capabilities, 'qos', 'per_lu' ) ) {
                eval { $d->set_lu_qos( $backend_id, $qos ) };
                warn "FCLU: QoS application warning: $@" if $@;
            } else {
                warn "FCLU: qos_* is configured but this array/platform does not support"
                    . " per-volume QoS; ignoring the QoS settings for '$name'.\n";
            }
        }

        # Read the real (possibly min-clamped) size + canonical identity once, then
        # commit to the registry LAST — the volume is now real and discoverable.
        my $lu = $d->get_lu($backend_id);
        $reg->register( $name, $backend_id,
            identity => $lu->{identity},
            size_mb  => ceil( $lu->{size_bytes} / ( 1024 * 1024 ) ),
            pool_ref => $lu->{pool_ref},
            # #8: auto-join a standing consistency/protection group so newly allocated disks
            # are covered by pve-fclu-cg group snapshots without per-disk config. This is the
            # per-volume `cg` tag (same field update_volume_attribute sets), a registry-only
            # write — it never issues an array call, so it cannot fail provisioning.
            ( defined $scfg->{auto_cg} && length $scfg->{auto_cg}
                ? ( cg => $scfg->{auto_cg} ) : () ),
        );
        $committed = 1;
    };
    if ( my $err = $@ ) {
        eval { $d->delete_lu($backend_id) } if defined $backend_id;
        eval { $reg->unregister($name) } if $reserved && !$committed;
        die "failed to allocate volume '$name': $err";
    }

    return $name;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    my $d = $class->_driver( $storeid, $scfg );
    # A snapshot is read through its source LU; materialize it on first use (#27).
    $class->_snapshot_source( $storeid, $scfg, $volname, $snapname, $d ) if $snapname;
    my ($backend_id) = $class->_resolve_backend( $storeid, $scfg, $volname, $snapname, 'die' );

    my $conn = $class->_connector;
    my %hctx = %{ $conn->host_context( hostname => $class->_nodename ) };

    # Ensure host-object/group setup, then map THIS node (both idempotent, §12.2).
    $d->ensure_host_access(%hctx);
    $d->publish_lu( $backend_id, %hctx );

    # Identity is MUST-be-set after publish_lu (§12.1). Persist it back to the
    # registry so filesystem_path / deactivate_volume resolve the device with no
    # array session — and so a driver whose NAA is only known POST-publish records
    # it now (alloc-time identity may have been undef for such an array).
    my $identity = $d->get_lu_identity($backend_id);
    if ($identity) {
        my $reg = $class->_registry($storeid);
        $snapname ? $reg->update_snapshot_meta( $volname, $snapname, svol_identity => $identity )
                  : $reg->update_meta( $volname, identity => $identity );
    }

    # Attach the multipath device by the array-reported canonical identity (§3).
    # device_timeout (storage.cfg) overrides the connector default for arrays whose
    # LUN presentation is slow under load; undef keeps the connector's own default.
    $conn->attach( $identity, $scfg->{device_timeout} );

    # Opt-in SCSI-3 PR readiness — validate-and-warn, NEVER blocks (§7 #2). When the
    # storage enables persistent_reservations, check this node's host-side PR plumbing
    # (qemu-pr-helper socket + a multipath reservation_key) and warn with actionable
    # guidance if it is not ready. Connector-specific and best-effort: a transport
    # whose connector has no PR concept simply skips it, keeping the core neutral.
    if ( $scfg->{persistent_reservations} && $conn->can('check_pr_ready') ) {
        my $pr = eval { $conn->check_pr_ready($identity) };
        warn "FCLU: PR readiness check for '$volname' errored: $@" if $@;
        if ( $pr && !$pr->{ok} ) {
            warn "FCLU: SCSI-3 PR not ready for '$volname': $_\n" for @{ $pr->{issues} };
        }
    }

    return 1;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    my ($backend_id, $entry) = $class->_resolve_backend( $storeid, $scfg, $volname, $snapname, 'soft' );
    return 1 unless defined $backend_id;

    my $d    = $class->_driver( $storeid, $scfg );
    my $conn = $class->_connector;

    # Host side FIRST (flush + remove the multipath/SCSI device) so the array does
    # not refuse the unmap with "the LU is executing host I/O", then unmap THIS
    # node only (§12.2 live-migration rule). Resolve the device identity from the
    # REGISTRY (recorded at alloc), not a live array call — host teardown must work
    # even when the array session is down (node fencing / array maintenance), which
    # is exactly when it matters. For a snapshot, $entry is its source's record
    # (identity from the snapshot subregistry), so this tears down the source LU.
    my $identity = $entry->{identity};
    eval { $conn->detach($identity) } if $identity;
    warn "FCLU: device detach warning: $@" if $@;

    my %hctx = %{ $conn->host_context( hostname => $class->_nodename ) };
    eval { $d->unpublish_lu( $backend_id, %hctx ) };
    warn "FCLU: unmap warning: $@" if $@;

    # Vendor post-deactivate hook (best-effort, e.g. Hitachi discard-zero-page thin
    # reclaim on the now-unmapped LU). Default no-op; must never fail the deactivate.
    # Not for a snapshot's source: that LU is the snapshot image, not a thin volume.
    if ( !$snapname ) {
        eval { $class->_after_deactivate( $storeid, $scfg, $backend_id, $d ) };
        warn "FCLU: post-deactivate hook warning: $@" if $@;
    }

    return 1;
}

# Vendor hook: run after a volume is torn down on this node (device detached + LU
# unmapped). Best-effort, called eval-wrapped. Default no-op; a driver-specific
# subclass may override it (e.g. Hitachi discard_zero_page thin-pool reclaim).
sub _after_deactivate { return 1 }

# Explicit map/unmap hooks (PVE 8+): the volume is a real block device, so map ==
# activate + return the dm path; unmap == deactivate. Idempotent.
sub map_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $hints) = @_;
    $class->activate_volume( $storeid, $scfg, $volname, $snapname );
    my ($path) = $class->filesystem_path( $scfg, $volname, $storeid, $snapname );
    return $path;
}

sub unmap_volume {
    my ($class, $storeid, $scfg, $volname, $snapname) = @_;
    $class->deactivate_volume( $storeid, $scfg, $volname, $snapname );
    return 1;
}

# Canonical identity -> /dev/mapper path. Reads the identity recorded at alloc
# (registry) so it needs no array session. PVE contract: the 3rd element is the
# volume TYPE (vtype), not the format.
sub filesystem_path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;
    my ( $backend_id, $entry ) = $class->_resolve_backend( $storeid, $scfg, $volname, $snapname, 'die' );

    my $conn = $class->_connector;

    # Resolve the recorded identity to a /dev/mapper path. On arrays that only expose
    # the device NAA once the LU is MAPPED (e.g. Hitachi), alloc records a null-NAA
    # identity and activate_volume fills it in on first activation.
    my $identity = $entry->{identity};
    my $path = $identity ? eval { $conn->device_path($identity) } : undef;

    if ( !defined $path ) {
        # Try to resolve+persist the identity live (covers a volume mapped out-of-band).
        my $d    = $class->_driver( $storeid, $scfg );
        my $live = eval { $d->get_lu_identity($backend_id) };
        my $p    = $live ? eval { $conn->device_path($live) } : undef;
        if ( defined $p ) {
            $path = $p;
            my $reg = $class->_registry($storeid);
            $snapname ? $reg->update_snapshot_meta( $volname, $snapname, svol_identity => $live )
                      : $reg->update_meta( $volname, identity => $live );
        }
        # else: the LU was never mapped, so there is no host device to name YET. Do NOT
        # die: PVE resolves the volume vtype via path() during `pvesm free` (the API
        # DELETE handler reads it for the permission check, before vdisk_free) and
        # during content listing — on volumes that were allocated but never activated.
        # Real device consumers (attach, qemu_blockdev_options, volume_export) only call
        # path() post-activation, when the identity is recorded. Return an undef device
        # path with the correct vtype/ownervm so those metadata-only callers succeed
        # instead of wedging `pvesm free` and orphaning the LU.
    }

    return wantarray ? ( $path, vmid_from_volname($volname), 'images' ) : $path;
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;
    return $class->filesystem_path( $scfg, $volname, $storeid, $snapname );
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $format) = @_;

    my $reg = $class->_registry($storeid);
    my ( $backend_id, $meta ) = $reg->lookup($volname);
    die "volume '$volname' not found in registry\n" unless defined $backend_id;

    # Refuse to delete a protected volume (#15) — cleared via update_volume_attribute.
    die "cannot delete '$volname': it is marked protected; clear the protected flag first\n"
        if $meta->{protected};

    # Refuse while linked clones (CoW children) still depend on this volume as their
    # source — deleting it would corrupt them.
    my $deps = $reg->find_dependents($volname);
    die "cannot delete '$volname': linked clone(s) depend on it: " . join( ', ', sort @$deps ) . "\n"
        if @$deps;

    # §7 destructive-op fence (registry membership is primary — we looked it up; a
    # vendor MAY add a stricter check, e.g. Hitachi ldev_range). Fail fast.
    $class->safe_delete_precheck( $scfg, $backend_id )
        or die "refusing to free '$volname' (backend '$backend_id'): failed the safe-delete precheck\n";

    my $d = $class->_driver( $storeid, $scfg );

    # Shared-pool id-recycle guard (from the OpenStack HBSD `is_invalid_ldev` pattern):
    # the registry maps volname -> backend_id, but on a shared array an LDEV id can be
    # freed and re-allocated to a DIFFERENT volume. Before ANY destructive op, re-read
    # the LU's array label; if it names a DIFFERENT volume, the id was recycled — drop
    # the stale registry entry only and refuse to unmap/delete a foreign LU. This backs
    # up the §7 ldev_range fence (safe_delete_precheck, above): the fence blocks a
    # cross-store recycle when ranges are disjoint; this catches a same-range recycle.
    #
    # Match on the parsed VOLNAME, not raw-string equality: the label's storeid PREFIX
    # can legitimately change form across plugin versions (readable `pve:<store>:` vs the
    # bounded `pve:<hash>:` fallback when max_label_len shrinks), and a raw compare would
    # then misread an owned LU as recycled and strand it. A missing/empty label or an
    # unreadable LU falls through to the normal path (delete_lu is idempotent).
    my $cur = eval { $d->get_lu($backend_id) };
    if ( $cur && defined $cur->{label} && length $cur->{label} ) {
        my $parsed   = PVE::Storage::FCLU::Label->parse_label( $cur->{label} );
        # A parseable pve: label → compare its volname; an UNparseable/foreign label →
        # fall back to exact-match vs our expected label (which fails → treated foreign,
        # the safe direction: never delete an LU we cannot positively identify as ours).
        my $mismatch = $parsed ? ( $parsed->{volname} ne $volname )
            : ( $cur->{label} ne $class->_make_label( $storeid, $volname, $d ) );
        if ( $mismatch ) {
            warn "FCLU: refusing to free '$volname': backend LU '$backend_id' now carries a"
                . " label for a different volume — the LDEV id was recycled. Dropping the"
                . " stale registry entry only (the LU is left intact).\n";
            $reg->unregister($volname);
            return undef;
        }
    }

    # Delete this volume's own snapshot pairs (capability-gated), and the LUs its
    # snapshots own (#27): checked and unmapped before the pairs go, deleted after,
    # and dropped from the record at once so a retried free never touches a reused id.
    my $snaps = $reg->list_snapshots($volname);
    my ( $pairs, $listed, %pair_svol, %deleted ) = ( [], 0 );
    if ( PVE::Storage::FCLU::Capabilities->has_feature( $d->capabilities, 'snapshot', 'single' ) ) {
        $pairs  = eval { $d->list_snapshots($backend_id) };
        $listed = defined $pairs ? 1 : 0;
        warn "FCLU: snapshot listing warning: $@" if !$listed;
        $pairs //= [];
        $pair_svol{ $_->{snap_id} } = $_->{meta}{svol} for @$pairs;
    }
    my %plan = map {
        my $sm = $snaps->{$_};
        ( $_ => $class->_owned_cleanup_plan( $storeid, $scfg, $d, $sm,
            defined $sm->{svol} ? undef : $pair_svol{ $sm->{snap_id} // '' } ) )
    } keys %$snaps;
    $class->_unmap_owned_luns( $d, $snaps->{$_}, keys %{ $plan{$_} } ) for keys %plan;
    for my $p (@$pairs) {
        if ( eval { $d->delete_snapshot( $p->{snap_id} ); 1 } ) { $deleted{ $p->{snap_id} } = 1 }
        else { warn "FCLU: snapshot cleanup warning ($p->{snap_id}): $@" }
    }
    for my $name ( sort keys %plan ) {
        next unless %{ $plan{$name} };
        my $sid = $snaps->{$name}{snap_id} // '';
        # Only once its pair is gone: deleted here, already released, or confirmed absent
        # from a successful listing. Never rely on the array refusing an assigned S-VOL.
        my $gone = $deleted{$sid} || $snaps->{$name}{pair_released}
            || ( $listed && !exists $pair_svol{$sid} );
        if ( !$gone ) {
            warn "FCLU: keeping snapshot volume(s) of '$name': its pair could not be deleted\n";
            next;
        }
        # Wait only on a pair this call actually deleted (else the poll burns its budget).
        eval { $d->wait_pair_released($sid) } if $deleted{$sid} && $d->can('wait_pair_released');
        eval { $class->_delete_owned_luns( $reg, $d, $volname, $name, $plan{$name} ) };
        warn "FCLU: snapshot volume cleanup warning ($name): $@" if $@;
    }

    # Release this volume's own backing CoW pair when it is itself a linked clone
    # (#23): the pair lives on the PARENT's LU (not this S-VOL), so the own-snapshot
    # cleanup above does not cover it. Prefer the id recorded at clone time; fall back
    # to rediscovering the pair by S-VOL on the recorded parent LU (covers a clone
    # committed before its pair was observable). Best-effort — a stale pair must not
    # wedge the delete; the array frees the snapshot data and unassigns the S-VOL.
    my $backing_snap = $meta->{clone_backing_snap};
    if ( !defined $backing_snap && defined $meta->{clone_parent_backend} ) {
        eval {
            my ($pair) = grep { ( $_->{meta}{svol} // '' ) eq "$backend_id" }
                @{ $d->list_snapshots( $meta->{clone_parent_backend} ) };
            $backing_snap = $pair->{snap_id} if $pair;
        };
        warn "FCLU: linked-clone pair rediscovery warning: $@" if $@;
    }
    if ( defined $backing_snap ) {
        my $released = eval { $d->delete_snapshot($backing_snap); 1 };
        warn "FCLU: linked-clone pair release warning: $@" if !$released;
        # Wait for the pair to fully dissolve before this S-VOL's LU is deleted below,
        # so the array does not reject the delete and leak the S-VOL (#3). Only when the
        # delete SUCCEEDED — else the pair never 404s and the poll would burn its full
        # budget. Optional driver capability — the generic core stays vendor-neutral.
        eval { $d->wait_pair_released($backing_snap) }
            if $released && $d->can('wait_pair_released');
    }

    # Tear the host side down (detach the device + unmap THIS node) before deleting
    # on the array — reuses the deactivate path (idempotent).
    $class->deactivate_volume( $storeid, $scfg, $volname );

    # deactivate_volume unmapped only THIS node. A leftover mapping from a crashed
    # live-migration on another node would block delete_lu (the array refuses to delete
    # an LDEV that still has LU paths) and leak the LU — this node's WWN-scoped
    # unpublish_lu cannot reach a remote node's host group. Reap every remaining
    # host-group mapping cluster-wide first. Optional driver capability; best-effort so
    # a transient array error does not wedge the delete (a failed delete_lu below then
    # leaves the registry entry for PVE to retry).
    if ( $d->can('unpublish_lu_all') ) {
        eval { $d->unpublish_lu_all($backend_id) };
        warn "FCLU: cluster-wide unmap warning: $@" if $@;
    }

    $d->delete_lu($backend_id);
    $reg->unregister($volname);

    return undef;
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running, $snapname) = @_;

    # API 15: $snapname targets a snapshot, used only with snapshot-as-volume-chain,
    # which this plugin does not support (array snapshots are not resizable images).
    die "resizing a snapshot is not supported on storage '$storeid'\n" if defined $snapname;

    my $reg = $class->_registry($storeid);
    my ( $backend_id, $meta ) = $reg->lookup($volname);
    die "volume '$volname' not found in registry\n" unless defined $backend_id;

    my $d = $class->_driver( $storeid, $scfg );

    # Block-storage resize is grow-only.
    my $cur = $d->get_lu($backend_id);
    die "cannot shrink volume '$volname'\n" if $size < $cur->{size_bytes};

    my $identity = $meta->{identity};
    my $conn     = $class->_connector;

    # Flush host buffers before the expand (safety for a running guest).
    if ( $running && $identity ) {
        eval { $conn->flush($identity) };
        warn "FCLU: pre-resize flush warning: $@" if $@;
    }

    # Grow on the array, then resize the multipath device on the host.
    $d->resize_lu( $backend_id, $size );
    if ($identity) {
        eval { $conn->resize($identity) };
        warn "FCLU: host-side resize warning: $@" if $@;
    }

    # Commit the real (post-grow) size to the registry.
    my $grown = $d->get_lu($backend_id);
    $reg->update_meta( $volname, size_mb => ceil( $grown->{size_bytes} / ( 1024 * 1024 ) ) );

    return 1;
}

# PVE 9 -blockdev attachment (APIVER 14, #14): our volumes are always raw, fully
# provisioned block devices (/dev/mapper/<wwid>), so declare host_device
# unconditionally — bypassing the inherited path()+stat() qcow2-chain heuristic
# that does not apply to a raw block volume.
sub qemu_blockdev_options {
    my ($class, $scfg, $storeid, $volname, $machine_version, $options) = @_;

    my ($path) = $class->path( $scfg, $volname, $storeid, $options->{'snapshot-name'} );
    die "qemu_blockdev_options: expected an absolute device path, got "
        . ( defined($path) ? "'$path'" : 'undef' ) . "\n"
        if !defined($path) || $path !~ m{^/};

    return { driver => 'host_device', filename => $path };
}

# Size straight from the registry instead of shelling out to qemu-img on a raw
# block device. A raw block volume is fully provisioned: used == size.
sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    my ( $backend_id, $meta ) = $class->_registry($storeid)->lookup($volname);
    die "volume '$volname' not found in registry\n" unless defined $backend_id;

    my $size   = ( $meta->{size_mb} || 0 ) * 1024 * 1024;
    my $parent = $meta->{parent_volname} ? "$storeid:$meta->{parent_volname}" : undef;

    return wantarray ? ( $size, 'raw', $size, $parent ) : $size;
}

# ── Snapshots (§6, array-offloaded, capability-gated) ──
#
# The array driver owns the pair mechanics (Thin Image et al.) behind the §2
# contract (create/delete/restore/list_snapshots); the core only orchestrates and
# tracks per-volume snapshot metadata in the registry snapshot subregistry
# (snap_id = the driver's opaque pair id; svol = the LU presenting the snapshot —
# from the driver's descriptor, or materialized on first read/clone and then marked
# svol_owned so it is deleted with the snapshot, #27). Migrated from the reference plugin's
# volume_snapshot* family, with the direct REST/Config calls swapped for the
# driver contract + Registry.

# Does the array driver advertise an array-offloaded PVE feature (snapshot/clone)?
# Callers gate on this to fail fast before driving the op onto a driver that lacks it.
sub _driver_supports {
    my ($class, $d, $feature) = @_;
    return PVE::Storage::FCLU::Capabilities->new( $d->capabilities )->pve_feature($feature) ? 1 : 0;
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    # #7: 'oob-' is reserved for surfaced array-side (out-of-band) snapshots, so a PVE
    # snapshot can never collide with — or be mistaken for — an array-managed one.
    die "snapshot name '$snap' is reserved ('oob-' marks array-managed snapshots)\n"
        if $snap =~ /^oob-/;

    my $reg = $class->_registry($storeid);
    my ($backend_id) = $reg->lookup($volname);
    die "volume '$volname' not found in registry\n" unless defined $backend_id;

    my $d = $class->_driver( $storeid, $scfg );
    die "storage '$storeid' does not support snapshots\n"
        unless $class->_driver_supports( $d, 'snapshot' );

    my $group = $class->_snapshot_group_name( $storeid, $backend_id, $snap, $d );

    # Monotonic 0-based creation index, so the snapshot chain stays correctly
    # ordered even when two snapshots land in the same wall-clock second (the
    # registry timestamp alone cannot disambiguate sub-second creations).
    my $seq   = scalar keys %{ $reg->list_snapshots($volname) };
    my $descr = $d->create_snapshot( $backend_id, snapshot_group => $group );

    $reg->register_snapshot( $volname, $snap,
        snap_id => $descr->{snap_id},
        group   => $group,
        seq     => $seq,
        ( defined $descr->{meta}{svol} ? ( svol => $descr->{meta}{svol} ) : () ),
    );

    return undef;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    # #7: never delete a surfaced array-side (out-of-band) snapshot through PVE — it may be
    # a replication/retention base whose loss breaks array-side data protection irrecoverably.
    die "snapshot '$snap' is an array-managed (out-of-band) snapshot; manage it on the array\n"
        if $snap =~ /^oob-/;

    my $reg = $class->_registry($storeid);
    my ($backend_id) = $reg->lookup($volname);
    die "volume '$volname' not found in registry\n" unless defined $backend_id;

    # Refuse while linked clones created FROM this snapshot still share its blocks —
    # deleting the pair would corrupt them (promote/remove the clones first).
    my $deps = $reg->find_snapshot_dependents( $volname, $snap );
    die "cannot delete snapshot '$snap' of '$volname': linked clone(s) depend on it: "
        . join( ', ', sort @$deps ) . "\n" if @$deps;

    my $meta = $reg->lookup_snapshot( $volname, $snap );
    die "snapshot '$snap' not found for volume '$volname'\n"
        unless $meta && defined $meta->{snap_id};

    # Owned source LUs (#27) are checked and unmapped before the pair goes, deleted
    # after. Retry-safe: once the pair is deleted that is recorded (pair_released), so
    # a retry never re-issues delete_snapshot on an id the array may have reused; each
    # LU is dropped from the record as soon as it is deleted; and _owned_lun_check
    # refuses any id that no longer carries our label.
    my $d = $class->_driver( $storeid, $scfg );
    my $pair_svol;
    if ( $meta->{svol_pending} && !defined $meta->{svol} && !$meta->{pair_released} ) {
        my ($pair) = grep { $_->{snap_id} eq $meta->{snap_id} }
            @{ ( eval { $d->list_snapshots($backend_id) } // [] ) };
        $pair_svol = $pair->{meta}{svol} if $pair;
    }
    my $plan = $class->_owned_cleanup_plan( $storeid, $scfg, $d, $meta, $pair_svol );
    $class->_unmap_owned_luns( $d, $meta, keys %$plan );
    if ( !$meta->{pair_released} ) {
        $d->delete_snapshot( $meta->{snap_id} );
        $reg->update_snapshot_meta( $volname, $snap, pair_released => 1 );
        eval { $d->wait_pair_released( $meta->{snap_id} ) }
            if %$plan && $d->can('wait_pair_released');
    }
    $class->_delete_owned_luns( $reg, $d, $volname, $snap, $plan );
    $reg->unregister_snapshot( $volname, $snap );

    return 1;
}

# PVE snapshot chain: {current} plus one entry per snapshot, oldest first, each
# pointing at the previous one as its parent (the block-storage linear model). The
# array carries no portable creation order, so we sort by the registry timestamp.
sub volume_snapshot_info {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $snaps = $class->_registry($storeid)->list_snapshots($volname);

    my $info = { current => { description => '', parent => undef } };
    my @ordered = sort {
        ( $snaps->{$a}{seq} // 0 ) <=> ( $snaps->{$b}{seq} // 0 )
            || ( $snaps->{$a}{timestamp} || 0 ) <=> ( $snaps->{$b}{timestamp} || 0 )
    } keys %$snaps;

    my $prev  = 'current';
    my $order = 0;
    for my $name (@ordered) {
        $info->{$name} = {
            description => '',
            parent      => ( $prev eq 'current' ? undef : $prev ),
            timestamp   => $snaps->{$name}{timestamp},
            order       => $order++,
        };
        $prev = $name;
    }
    $info->{current}{parent} = $prev eq 'current' ? undef : $prev;
    $info->{current}{order}  = $order;

    # #7: optionally surface array-side (out-of-band) snapshots. They are added as DETACHED
    # roots (parent => undef, order AFTER the registry tip) and NEVER threaded into the
    # `current` ancestry — that linear chain drives rollback/delta and must reflect only
    # PVE-created state. Opt-in (a live array read per call); read-only (delete/rollback of
    # an oob- name is refused below).
    if ( $scfg->{surface_oob_snapshots} ) {
        my $reg = $class->_registry($storeid);
        my ($backend_id) = $reg->lookup($volname);
        my $d = defined $backend_id ? eval { $class->_driver( $storeid, $scfg ) } : undef;
        for my $o ( @{ $class->_oob_snapshots( $storeid, $volname, $backend_id, $reg, $d ) } ) {
            next if exists $info->{ $o->{name} };   # never shadow a real chain entry
            $info->{ $o->{name} } = {
                description => 'array-managed (out-of-band)',
                parent      => undef,
                timestamp   => $o->{timestamp},
                order       => ++$order,
            };
        }
    }

    return $info;
}

# #7: discover array-side (out-of-band) snapshots on this volume's LDEV — Thin Image pairs
# the array holds that PVE did NOT create (schedules, replication, the array UI/CLI).
# Classification is REGISTRY-AUTHORITATIVE, never a group-name heuristic: a pair is OOB iff
# its snap_id is in neither the volume's PVE `snapshots` nor its `cg_snapshots` record set,
# AND its S-VOL is not a registered volume (which would make it a linked/full-clone backing
# pair, not a snapshot). Names are `oob-<sanitized snap_id>` — stable across list calls,
# config-id-safe (starts with a letter), and round-trippable back to the pair. Fails SOFT:
# a driver/array read error surfaces zero OOB snaps rather than breaking the snapshot tree.
sub _oob_snapshots {
    my ($class, $storeid, $volname, $backend_id, $reg, $d) = @_;
    return [] unless defined $backend_id && $d;

    # Fully fail-soft: ANY error discovering OOB snaps yields an empty list, never an
    # exception that would break the snapshot tree for the array-reachable case.
    my $oob = eval {
        my %known;   # snap_ids PVE owns for this volume (plain + CG snapshots)
        $known{ $_->{snap_id} } = 1
            for grep { defined $_->{snap_id} }
                ( values %{ $reg->list_snapshots($volname) },
                  values %{ $reg->list_cg_snapshots($volname) } );

        my @out;
        my %seen;
        for my $p ( @{ $d->list_snapshots($backend_id) } ) {
            my $sid = $p->{snap_id};
            next unless defined $sid;
            next if $known{$sid};                                # PVE / CG snapshot
            my $svol = $p->{meta}{svol};
            # A registered S-VOL means a linked/full-clone backing pair, not a snapshot.
            # Require length so an empty svol is treated as OOB, not fed to a croaking lookup.
            next if defined $svol && length $svol
                && defined $reg->find_volname_by_backend($svol);
            ( my $name = "oob-$sid" ) =~ s/[^A-Za-z0-9]+/-/g;    # config-id-safe, stable
            # Distinct snap_ids sanitizing to the same name would hide one — warn rather
            # than drop silently (inert for Hitachi's "pvol,mu" ids; a guard for drivers
            # whose ids differ only in punctuation).
            if ( $seen{$name}++ ) {
                warn "FCLU: out-of-band snapshot '$sid' maps to an already-surfaced name"
                    . " '$name' on '$volname' — hidden (snapshot-id name collision)\n";
                next;
            }
            push @out, { name => $name, snap_id => $sid, timestamp => $p->{created} };
        }
        \@out;
    };
    if ( my $err = $@ ) {
        warn "FCLU: out-of-band snapshot discovery for '$volname' failed: $err";
        return [];
    }
    return $oob // [];
}

# Registry-only rename (#34): every op resolves the pair via the recorded snap_id,
# so the array group label may keep the old name — renaming the key is sufficient.
sub rename_snapshot {
    my ($class, $scfg, $storeid, $volname, $source, $target) = @_;
    # #7: keep 'oob-' reserved on rename too — renaming a real snapshot INTO oob-* would
    # make it permanently unmanageable through PVE (delete/rollback refuse the prefix).
    die "snapshot name '$target' is reserved ('oob-' marks array-managed snapshots)\n"
        if $target =~ /^oob-/;
    $class->_registry($storeid)->rename_snapshot( $volname, $source, $target );
    return;
}

# Thin-Image-style snapshots are independent pairs, so restoring one does NOT
# destroy newer snapshots — we allow rollback to ANY existing snapshot (unlike
# ZFS/LVM-thin). A snapshot with dependent linked clones is blocked, mirroring the
# deletion guard, since restoring it disturbs the shared base.
sub volume_rollback_is_possible {
    my ($class, $scfg, $storeid, $volname, $snap, $blockers) = @_;
    $blockers //= [];

    die "can't rollback to '$snap': it is an array-managed (out-of-band) snapshot;"
        . " roll it back on the array\n" if $snap =~ /^oob-/;

    my $reg = $class->_registry($storeid);
    my $rsm = $reg->lookup_snapshot( $volname, $snap );
    die "can't rollback, snapshot '$snap' does not exist on '$volname'\n" unless $rsm;
    die "can't rollback to '$snap': it is being deleted; finish the delete\n"
        if $rsm->{pair_released};

    my $deps = $reg->find_snapshot_dependents( $volname, $snap );
    if (@$deps) {
        push @$blockers, @$deps;
        die "can't rollback to '$snap': linked clone(s) depend on this snapshot: "
            . join( ', ', sort @$deps ) . "\n";
    }
    return 1;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    die "can't rollback to '$snap': it is an array-managed (out-of-band) snapshot;"
        . " roll it back on the array\n" if $snap =~ /^oob-/;

    my $reg = $class->_registry($storeid);
    my ($backend_id) = $reg->lookup($volname);
    die "volume '$volname' not found in registry\n" unless defined $backend_id;

    my $meta = $reg->lookup_snapshot( $volname, $snap );
    die "snapshot '$snap' not found for volume '$volname'\n"
        unless $meta && defined $meta->{snap_id};
    die "can't rollback to '$snap': it is being deleted; finish the delete\n"
        if $meta->{pair_released};

    # Re-check dependents HERE, not only in volume_rollback_is_possible: callers may
    # skip the preflight, and a clone can start after it. begin_snapshot_restore does
    # the check and sets a restore marker in one locked write; clone_image's
    # reservation refuses a marked snapshot, closing the check-then-act window.
    # The marker's TTL comes from the driver's restore budget (optional
    # restore_budget_s; the registry default applies without one) plus an hour of
    # margin, so a long but live restore is never mistaken for a crashed one.
    my $d    = $class->_driver( $storeid, $scfg );
    my $node = eval { $class->_nodename };
    my $budget = $d->can('restore_budget_s') ? $d->restore_budget_s : undef;
    $reg->begin_snapshot_restore( $volname, $snap, node => $node,
        ( $budget ? ( ttl => $budget + 3600 ) : () ) );

    # The driver owns the reverse-copy + re-split settle (#12): restore_snapshot
    # MUST leave the snapshot a usable, re-restorable pair before returning. Pass the
    # target's backend id so the driver refuses a pair that isn't this volume's (N3).
    my $ok = eval {
        $d->restore_snapshot( $meta->{snap_id}, pvol => $backend_id,
            ( defined $meta->{group} ? ( group => $meta->{group} ) : () ) );
        1;
    };
    my $err = $@;
    eval { $reg->end_snapshot_restore( $volname, $snap, node => $node ) };
    warn "FCLU: could not clear the rollback marker on '$volname\@$snap': $@" if $@;
    die $err unless $ok;

    return 1;
}

# ── Clones (§6, array-offloaded linked clone = PVE's clone_image primitive) ──
#
# clone_image is PVE's LINKED-clone primitive: a CoW child that shares blocks with
# its source (a base image or a snapshot). Full copies do NOT come through here —
# PVE copies host-side via alloc_image + the device path (§6). The array driver owns
# the pair mechanics behind create_linked_clone; the core resolves the CoW source,
# drives the driver, and records parentage + the backing-pair id so free_image can
# release it (#23). The driver creates the CoW child without any host context (the
# Hitachi driver binds the S-VOL at pair creation, both volumes unmapped).
sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap, $running, $target) = @_;

    # Source must be a base image, a snapshot, OR a live volume whose driver can pair
    # a CoW child straight onto a live P-VOL — volume_has_feature enforces the whole
    # rule (role table + the array-offloaded clone capability, incl. from_current).
    die "clone_image: source '$volname' does not support a linked clone here"
        . " (needs a base image, a snapshot, or a driver with live-source cloning)\n"
        unless $class->volume_has_feature( $scfg, 'clone', $storeid, $volname, $snap );

    my $reg = $class->_registry($storeid);
    my ( $src_backend, $src_meta ) = $reg->lookup($volname);
    die "source volume '$volname' not found in registry\n" unless defined $src_backend;

    # The CoW parent: the snapshot's S-VOL when cloning from a snapshot, else the
    # source volume's own LU. For a LIVE ('current') source that own LU is the running
    # volume itself — the Thin Image auto_split binds the child at that instant, so the
    # backing pair (P-VOL = the live source, S-VOL = the clone) IS the crash-consistent
    # point-in-time; no separate implicit snapshot object is created, and free_image
    # releases that one pair like any other linked clone (#23).
    my $d            = $class->_driver( $storeid, $scfg );
    my $clone_source = $src_backend;

    # Reserve WITH lineage: the in-flight clone then counts as a dependent of its
    # source (and snapshot), and the reservation is refused while that snapshot is
    # being rolled back, so clone and rollback serialize through the registry lock.
    my $new_name = $reg->reserve_volname( $vmid,
        parent_volname => $volname,
        ( $snap ? ( parent_snap => $snap ) : () ),
        node => scalar eval { $class->_nodename },
    );

    # $pair is resolved inside the eval but MUST be visible to the rollback: a linked
    # clone is a split CoW pair, so undoing a partial build has to release that pair
    # before the S-VOL LU can be deleted (a real array refuses to delete an LDEV that
    # is still assigned to a pair — the reference's #23 hazard).
    my ( $svol, $pair, $committed ) = ( undef, undef, 0 );
    eval {
        # From a snapshot, the CoW parent is the LU presenting it (materialized on
        # first use, #27), so the clone shares the snapshot's blocks, never the live
        # volume's. Done AFTER the reservation: the reservation already counts as a
        # dependent and is refused during a rollback, so a concurrent snapshot delete or
        # rollback cannot slip in between.
        $clone_source = $class->_snapshot_source( $storeid, $scfg, $volname, $snap, $d )
            if $snap;
        my $rid = $class->_alloc_backend_id( $storeid, $scfg, $d );
        $svol = $d->create_linked_clone( $clone_source,
            ( defined $rid ? ( requested_id => $rid ) : () ),
        );
        die "driver create_linked_clone returned no backend_id\n" unless defined $svol;

        # Find the backing CoW pair (its S-VOL is our new clone) so both rollback and
        # free_image can release it before deleting the S-VOL (#23). Discovered through
        # the §2 list_snapshots contract, so no vendor-specific call leaks into the core.
        # §12.2 requires create_linked_clone to leave the pair observable on return, so
        # a missing pair here means a non-conformant/slow driver — warn loudly rather
        # than silently record no backing id (which would leave the clone unfreeable).
        ($pair) = grep { ( $_->{meta}{svol} // '' ) eq "$svol" }
            @{ $d->list_snapshots($clone_source) };
        warn "FCLU: linked clone '$new_name' (svol=$svol): backing CoW pair not found on"
            . " source '$clone_source' — free_image will rediscover it from the parent\n"
            unless $pair;

        $d->set_lu_label( $svol, $class->_make_label( $storeid, $new_name, $d ) );

        # Commit LAST: identity + size + the backing-pair id AND its P-VOL, so
        # free_image can release the pair by id, or rediscover it from the P-VOL (#23).
        # Parentage (parent_volname/parent_snap) is NOT passed: the reservation already
        # carries it and register() merges over it. Re-passing the local $snap would
        # overwrite a rename_snapshot that repointed the reservation meanwhile.
        my $lu = $d->get_lu($svol);
        $reg->register( $new_name, $svol,
            identity              => $d->get_lu_identity($svol),
            size_mb               => $src_meta->{size_mb},
            pool_ref              => $lu->{pool_ref},
            clone_parent_backend  => $clone_source,
            ( $pair ? ( clone_backing_snap => $pair->{snap_id} ) : () ),
        );
        $committed = 1;
    };
    if ( my $err = $@ ) {
        # Reverse order: release the backing pair FIRST (frees the snapshot data and
        # unassigns the S-VOL), else delete_lu on the still-assigned S-VOL fails and
        # leaks both the S-VOL and its pair on a shared pool.
        eval { $d->delete_snapshot( $pair->{snap_id} ) } if $pair;
        eval { $d->delete_lu($svol) } if defined $svol;
        eval { $reg->unregister($new_name) } unless $committed;
        die "failed to clone '$volname' to '$new_name': $err";
    }

    return $new_name;
}

# ── Base / template images (§7) ──
#
# Convert a live volume into a base image: relabel the LU and atomically rename the
# registry entry to base-<vmid>-disk-<n>. No data copy — the base IS the volume, now
# read-only per the role table (clones spring from it via clone_image).
sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    my ( undef, $name, $vmid, undef, undef, $isBase ) = $class->parse_volname($volname);
    die "create_base not possible for base image '$volname'\n" if $isBase;

    my $reg = $class->_registry($storeid);
    my ($backend_id) = $reg->lookup($volname);
    die "volume '$volname' not found in registry\n" unless defined $backend_id;

    my $deps = $reg->find_dependents($volname);
    die "cannot convert '$volname' to a base image: linked clone(s) depend on it: "
        . join( ', ', sort @$deps ) . "\n" if @$deps;

    my ($disk) = $name =~ /-disk-(\d+)$/;
    my $base_name = "base-${vmid}-disk-${disk}";

    my $d = $class->_driver( $storeid, $scfg );
    $d->set_lu_label( $backend_id, $class->_make_label( $storeid, $base_name, $d ) );
    $reg->rename_volume( $volname, $base_name );

    return $base_name;
}

# ── Storage migration (volume export / import, §5) ──
#
# Lets the volume ride PVE's storage_migrate path — offline `qm migrate` to a node
# where this storage is not shared, cross-cluster `qm remote-migrate`, and
# `pvesm export`/`import`. We stream the raw block device (`raw+size`), exactly like
# the RBD plugin. Same-node/cluster "Move Storage" does NOT use these (qemu copies
# through the device path). Array-offloaded snapshots are NOT in the stream: only
# the active volume state transfers, so with_snapshots/incremental are unsupported.

sub volume_export_formats {
    my ($class, $scfg, $storeid, $volname, $snapshot, $base_snapshot, $with_snapshots) = @_;
    return $class->volume_import_formats(
        $scfg, $storeid, $volname, $snapshot, $base_snapshot, $with_snapshots );
}

sub volume_import_formats {
    my ($class, $scfg, $storeid, $volname, $snapshot, $base_snapshot, $with_snapshots) = @_;
    return () if $with_snapshots;          # array snapshots are not streamed
    return () if defined($base_snapshot);  # no incremental streams
    return () if defined($snapshot);       # no snapshot-specific export
    return ('raw+size');
}

sub volume_export {
    my ($class, $scfg, $storeid, $fh, $volname, $format, $snapshot, $base_snapshot, $with_snapshots)
        = @_;

    die "volume export format '$format' not available for $class\n" if $format ne 'raw+size';
    die "cannot export volumes together with their snapshots in $class\n" if $with_snapshots;
    die "cannot export a snapshot in $class\n"            if defined($snapshot);
    die "cannot export an incremental stream in $class\n" if defined($base_snapshot);

    # The LUN is already mapped and its device present on this node (the migration
    # framework activates source volumes before export).
    my $path   = $class->filesystem_path( $scfg, $volname, $storeid );
    my ($size) = $class->volume_size_info( $scfg, $storeid, $volname );

    require PVE::Tools;
    PVE::Storage::Plugin::write_common_header( $fh, $size );
    PVE::Tools::run_command(
        [ 'dd', "if=$path", 'bs=4k', 'status=progress' ],
        output  => '>&' . fileno($fh),
        # dd draws progress with carriage returns; split into individual log lines.
        errfunc => sub { print STDERR "$_[0]\n" },
    );

    return;
}

sub volume_import {
    my ($class, $scfg, $storeid, $fh, $volname, $format, $snapshot, $base_snapshot,
        $with_snapshots, $allow_rename) = @_;

    die "volume import format '$format' not available for $class\n" if $format ne 'raw+size';
    die "cannot import volumes together with their snapshots in $class\n" if $with_snapshots;
    die "cannot import an incremental stream in $class\n" if defined($base_snapshot);

    my ( undef, $name, $vmid, undef, undef, undef, $file_format ) = $class->parse_volname($volname);
    die "cannot import format $format into a volume of format $file_format\n"
        if $file_format ne 'raw';

    my $reg = $class->_registry($storeid);
    if ( defined $reg->lookup($volname) ) {
        die "volume '$volname' already exists\n" if !$allow_rename;
        warn "volume '$volname' already exists - importing with a different name\n";
        $name = undef;   # let alloc_image reserve a fresh name under the cluster lock
    }

    require PVE::Tools;
    # Header size is in bytes; alloc_image expects KiB.
    my ($size)  = PVE::Storage::Plugin::read_common_header($fh);
    my $size_kb = ceil( $size / 1024 );

    my $new_volname;
    eval {
        # alloc creates + registers the LU (host mapping deferred); activate maps it
        # to this node so the device path exists for the dd below.
        $new_volname = $class->alloc_image( $storeid, $scfg, $vmid, 'raw', $name, $size_kb );
        $class->activate_volume( $storeid, $scfg, $new_volname );
        my $path = $class->filesystem_path( $scfg, $new_volname, $storeid )
            or die "failed to resolve a path for the new volume '$new_volname'\n";
        PVE::Tools::run_command(
            [ 'dd', "of=$path", 'conv=sparse', 'bs=64k' ],
            input => '<&' . fileno($fh),
        );
    };
    if ( my $err = $@ ) {
        eval { $class->free_image( $storeid, $scfg, $new_volname, 0, 'raw' ) }
            if defined $new_volname;
        warn $@ if $@;
        die $err;
    }

    return "$storeid:$new_volname";
}

# ── Reassign + adopt/release (§7) ──

# Reassign a volume to another VMID / name (PVE "Reassign disk", qm disk reassign):
# relabel the LU and atomically rename the registry entry. No data movement.
sub rename_volume {
    my ($class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname) = @_;

    my $reg = $class->_registry($storeid);
    my ($backend_id) = $reg->lookup($source_volname);
    die "volume '$source_volname' not found in registry\n" unless defined $backend_id;

    # Renaming a parent would dangle its linked clones' parent_volname reference.
    my $deps = $reg->find_dependents($source_volname);
    die "cannot rename '$source_volname': linked clone(s) depend on it: "
        . join( ', ', sort @$deps ) . "\n" if @$deps;

    my $format = ( $class->parse_volname($source_volname) )[6];
    $target_volname = $class->find_free_diskname( $storeid, $scfg, $target_vmid, $format )
        if !$target_volname;

    my $d = $class->_driver( $storeid, $scfg );
    $d->set_lu_label( $backend_id, $class->_make_label( $storeid, $target_volname, $d ) );
    $reg->rename_volume( $source_volname, $target_volname );

    return "${storeid}:${target_volname}";
}

# Adopt an existing, untracked array LU into PVE (LU import). The LU pre-exists, so
# there is NO orphan-on-failure risk and we register before mapping; rollback clears
# tracking + the label but NEVER deletes the LU.
sub manage_volume {
    my ($class, $storeid, $scfg, $backend_id, $vmid) = @_;

    die "backend_id is required\n" unless defined $backend_id;
    die "vmid is required\n"       unless defined $vmid;

    my $reg = $class->_registry($storeid);
    my $d   = $class->_driver( $storeid, $scfg );

    my $lu = $d->get_lu($backend_id);   # verify it exists on the array (dies if not)

    # Refuse to adopt an LU already tracked under another volname — else two volids
    # would point at one LU.
    if ( my $existing = $reg->find_volname_by_backend($backend_id) ) {
        die "backend LU '$backend_id' is already managed as '$existing'\n";
    }

    my $name = $reg->reserve_volname($vmid);
    eval {
        $d->set_lu_label( $backend_id, $class->_make_label( $storeid, $name, $d ) );
        $reg->register( $name, $backend_id,
            size_mb  => ceil( $lu->{size_bytes} / ( 1024 * 1024 ) ),
            pool_ref => $lu->{pool_ref},
        );
        # Map to this node; activate_volume persists the canonical identity.
        $class->activate_volume( $storeid, $scfg, $name );
    };
    if ( my $err = $@ ) {
        eval { $class->deactivate_volume( $storeid, $scfg, $name ) };
        eval { $d->set_lu_label( $backend_id, '' ) };
        eval { $reg->unregister($name) };
        die "failed to manage backend LU '$backend_id' as '$name': $err";
    }

    return $name;
}

# Release a volume from PVE tracking (LU un-import): tear the host side down, clear
# the label, drop the registry entry — but leave the LU on the array intact.
sub unmanage_volume {
    my ($class, $storeid, $scfg, $volname) = @_;

    die "volname is required\n" unless $volname;

    my $reg = $class->_registry($storeid);
    my ($backend_id) = $reg->lookup($volname);
    die "volume '$volname' not found in registry\n" unless defined $backend_id;

    my $d = $class->_driver( $storeid, $scfg );

    eval { $class->deactivate_volume( $storeid, $scfg, $volname ) };
    warn "FCLU: unmanage teardown warning: $@" if $@;
    eval { $d->set_lu_label( $backend_id, '' ) };
    warn "FCLU: unmanage label-clear warning: $@" if $@;

    $reg->unregister($volname);

    return $backend_id;
}

# ── Volume name parsing (§7, vendor-neutral) ──

sub vmid_from_volname {
    my ($volname) = @_;
    return ( $volname =~ /^(?:vm|base)-(\d+)-/ ) ? $1 : 0;
}

sub parse_volname {
    my ($class, $volname) = @_;

    # Returns ($vtype, $name, $vmid, $basename, $basevmid, $isBase, $format).
    return ( 'images', $volname, $1, undef, undef, 1, 'raw' )
        if $volname =~ /^base-(\d+)-disk-(\d+)$/;
    return ( 'images', $volname, $1, undef, undef, undef, 'raw' )
        if $volname =~ /^vm-(\d+)-disk-(\d+)$/;
    # Cloud-init drive: a regular raw LUN, only the name differs (§7, #6).
    return ( 'images', $volname, $1, undef, undef, undef, 'raw' )
        if $volname =~ /^vm-(\d+)-cloudinit$/;

    die "unable to parse volume name '$volname'\n";
}

# ── Feature negotiation ──

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    # Keyed by the volume's role (block-storage / LVM-thin model): a linked clone is
    # a CoW Thin Image S-VOL. It is offered from a base image, a snapshot, OR a live
    # ('current') volume — the last one is capability-gated below, since a backend can
    # only clone off a live source if its array can pair a CoW child directly onto a
    # live P-VOL (#19). Full copies use 'copy'.
    my $features = {
        snapshot   => { current => 1 },
        clone      => { base => 1, snap => 1, current => 1 },
        copy       => { base => 1, current => 1, snap => 1 },
        sparseinit => { base => 1, current => 1 },
        template   => { current => 1 },
        rename     => { current => 1 },
        resize     => { current => 1 },
    };

    my $isBase = ( $class->parse_volname($volname) )[5];
    my $key = $snapname ? 'snap' : ( $isBase ? 'base' : 'current' );

    return undef unless $features->{$feature} && $features->{$feature}{$key};

    # Nothing is offered FROM a half-deleted snapshot (its pair is gone, #27).
    if ( $key eq 'snap' && defined $storeid ) {
        my $sm = eval { $class->_registry($storeid)->lookup_snapshot( $volname, $snapname ) };
        return undef if $sm && $sm->{pair_released};
    }

    # Array-offloaded features (snapshot/clone) ALSO require the driver to advertise
    # the matching capability (§6, via Capabilities). Fail SOFT: only downgrade to
    # "unsupported" when the driver POSITIVELY lacks it — a driver build/connection
    # hiccup must not make PVE think a normally-supported feature vanished, so any
    # lookup error falls through to the role-table "yes". Host and registry features
    # (copy/sparseinit/template/rename/resize) are not array-gated.
    if ( defined $storeid && ( $feature eq 'snapshot' || $feature eq 'clone' ) ) {
        my $gated = eval {
            my $d  = $class->_driver( $storeid, $scfg );
            my $ok = $class->_driver_supports( $d, $feature );   # snapshot.single / clone.linked
            # A live-source linked clone additionally needs clone.from_current: the
            # array must be able to bind a CoW child straight onto a live P-VOL. A
            # backend that advertises clone.linked but not from_current (snapshot-only
            # clone source) declines a live clone and PVE falls back to a host copy.
            $ok = PVE::Storage::FCLU::Capabilities->has_feature(
                $d->capabilities, 'clone', 'from_current' )
                if $ok && $feature eq 'clone' && $key eq 'current';
            # A clone FROM a snapshot needs clone.from_snapshot (#27): the driver must
            # be able to clone the snapshot's image, not just a volume.
            $ok = PVE::Storage::FCLU::Capabilities->has_feature(
                $d->capabilities, 'clone', 'from_snapshot' )
                if $ok && $feature eq 'clone' && $key eq 'snap';
            $ok;
        };
        return undef if defined $gated && !$gated;
    }

    # A full copy FROM a snapshot reads it through its source LU (#27): offer it only
    # when the snapshot has one or the driver can materialize one. Fail soft as above.
    if ( defined $storeid && $feature eq 'copy' && $key eq 'snap' ) {
        my $readable = eval {
            my $sm = $class->_registry($storeid)->lookup_snapshot( $volname, $snapname );
            ( $sm && defined $sm->{svol} ) || $class->_driver( $storeid, $scfg )->can('materialize_snapshot')
                ? 1 : 0;
        };
        return undef if defined $readable && !$readable;
    }

    return 1;
}

# ── Image listing ──

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $registry = $class->_registry($storeid)->list;
    my @res;
    for my $volname ( sort keys %$registry ) {
        my $entry = $registry->{$volname};
        # Skip name reservations (no backend committed yet).
        next unless ref $entry eq 'HASH' && defined $entry->{backend_id};

        my $evmid = ( $volname =~ /^(?:vm|base)-(\d+)-/ ) ? $1 : 0;
        next if $vmid && $evmid != $vmid;
        if ($vollist) {
            my $full = "$storeid:$volname";
            next unless grep { $_ eq $full } @$vollist;
        }

        push @res, {
            volid  => "$storeid:$volname",
            format => 'raw',
            size   => ( $entry->{size_mb} || 0 ) * 1024 * 1024,
            vmid   => $evmid,
            parent => $entry->{parent_volname} ? "$storeid:$entry->{parent_volname}" : undef,
        };
    }
    return \@res;
}

# ── Volume attributes (protected / notes, §7 #15) ──

sub get_volume_attribute {
    my ($class, $scfg, $storeid, $volname, $attribute) = @_;

    if ( $attribute eq 'protected' ) {
        my ( undef, $meta ) = $class->_registry($storeid)->lookup($volname);
        return $meta && $meta->{protected} ? 1 : 0;
    }
    if ( $attribute eq 'notes' ) {
        return $class->get_volume_notes( $scfg, $storeid, $volname );
    }
    return;
}

# ── Consistency-group snapshots (§6 snapshot.consistency_group) ──
#
# CG membership is the per-volume `cg` attribute. Because PVE's storage API is per-volume
# with NO multi-volume snapshot hook, a group snapshot is an EXPLICIT out-of-band operation
# (the `pve-fclu-cg` CLI calls these) — per-volume volume_snapshot is untouched and still
# works. It resolves every member sharing the tag and asks the driver for ONE crash-
# consistent array snapshot (all S-VOLs frozen at the same instant). Records live under the
# registry `cg_snapshots` subtree, SEPARATE from PVE's per-volume `snapshots` view, so they
# never leak into volume_snapshot_info. (Transparent `qm snapshot` integration needs an
# upstream storage hook — see docs/rfc/consistency-group-snapshot.md.)

sub _cg_driver {
    my ($class, $storeid, $scfg) = @_;
    my $d = $class->_driver( $storeid, $scfg );
    die "storage '$storeid' does not support consistency-group snapshots\n"
        unless PVE::Storage::FCLU::Capabilities->has_feature(
                   $d->capabilities, 'snapshot', 'consistency_group' )
            && $d->can('create_cg_snapshot');
    return $d;
}

sub cg_snapshot_create {
    my ($class, $scfg, $storeid, $cgname, $label) = @_;
    die "consistency-group name is required\n" unless defined $cgname && length $cgname;
    die "snapshot label is required\n"         unless defined $label  && length $label;

    my $reg     = $class->_registry($storeid);
    my $members = $reg->find_cg_members($cgname);
    die "consistency group '$cgname' has no members on '$storeid'\n" unless @$members;
    die "CG snapshot '$label' already exists for group '$cgname'\n"
        if @{ $reg->find_cg_snapshot( $cgname, $label ) };

    my $d   = $class->_cg_driver( $storeid, $scfg );
    my @ids = map { my ($bid) = $reg->lookup($_); $bid } @$members;

    # One crash-consistent array snapshot across every member. On failure the driver
    # sweeps its own partial pairs (no shared-pool leak); nothing is recorded here.
    my $snaps  = $d->create_cg_snapshot( \@ids );
    my %by_bid = map {; "$_->{parent_backend_id}" => $_ } @$snaps;   # leading ; forces a block

    for my $i ( 0 .. $#$members ) {
        my $descr = $by_bid{ "$ids[$i]" }
            or die "internal: CG snapshot missing a descriptor for member '$members->[$i]'\n";
        $reg->add_cg_snapshot( $members->[$i], $label,
            snap_id => $descr->{snap_id},
            group   => $descr->{meta}{group},
            cg      => $cgname,
        );
    }
    return { cg => $cgname, label => $label, members => $members };
}

sub cg_snapshot_delete {
    my ($class, $scfg, $storeid, $cgname, $label) = @_;
    die "consistency-group name is required\n" unless defined $cgname && length $cgname;
    die "snapshot label is required\n"         unless defined $label  && length $label;

    my $reg  = $class->_registry($storeid);
    my $recs = $reg->find_cg_snapshot( $cgname, $label );
    die "no CG snapshot '$label' found for group '$cgname'\n" unless @$recs;

    my $d = $class->_cg_driver( $storeid, $scfg );
    # Release every member's array pair (delete_snapshot is idempotent), then drop its
    # record — so a re-run after a partial failure still converges.
    for my $r (@$recs) {
        $d->delete_snapshot( $r->{snap_id} );
        $reg->remove_cg_snapshot( $r->{volname}, $label );
    }
    return 1;
}

# { cgname => { label => [ { volname, snap_id, group, cg, timestamp } ] } }, or a single
# group's map when $cgname is given.
sub cg_snapshot_list {
    my ($class, $storeid, $cgname) = @_;
    my $all = $class->_registry($storeid)->list_all_cg_snapshots();
    return defined $cgname ? ( $all->{$cgname} // {} ) : $all;
}

# Read helpers for the CLI (keep the registry encapsulated).
sub cg_list    { return $_[0]->_registry( $_[1] )->list_cgs }
sub cg_members { return $_[0]->_registry( $_[1] )->find_cg_members( $_[2] ) }

# ── Grouped full clone (crash-consistent, over a consistency group) ──
#
# Clones every member of a CG as an INDEPENDENT full copy, all captured at the SAME
# instant. Because the array fixes the point-in-time by the GROUP ACTION (not pair
# creation), all the expensive work — S-VOL allocation + idle pair creation — is done
# ahead (prepare_full_clone), then ONE array action triggers the whole group
# (start_clone_group), then the copies run and are polled to completion (clone_copy_state).
# Out-of-band, like cg_snapshot_create: the new volumes are registered for $target_vmid;
# the operator wires them into the target VM config. (This is the array-side consumer the
# grouped-clone primitives were built for; the #7780 copy-offload hook can drive the same
# primitives once upstream lands.)

my $_cg_clone_seq = 0;
sub cg_clone_create {
    my ($class, $scfg, $storeid, $cgname, $target_vmid) = @_;
    die "consistency-group name is required\n" unless defined $cgname && length $cgname;
    die "target vmid is required\n" unless defined $target_vmid && "$target_vmid" =~ /^\d+$/;

    my $reg     = $class->_registry($storeid);
    my $members = $reg->find_cg_members($cgname);
    die "consistency group '$cgname' has no members on '$storeid'\n" unless @$members;

    my $d = $class->_driver($storeid, $scfg);
    die "storage '$storeid' does not support grouped full clone\n"
        unless PVE::Storage::FCLU::Capabilities->has_feature( $d->capabilities, 'copy', 'full' )
            && $d->can('prepare_full_clone') && $d->can('start_clone_group')
            && $d->can('clone_copy_state');

    # One clone group: start_clone_group fixes the crash-consistent point-in-time across
    # every member at once. Unique name so concurrent grouped clones never collide (≤29) —
    # mix the PID with a per-process counter so two processes cloning to the same target VMID
    # within one wall-clock second still get distinct group names.
    $_cg_clone_seq = ( $_cg_clone_seq + 1 ) & 0xffff;
    my $group = substr(
        sprintf( 'pveGC%x_%x_%x', $target_vmid, time(), ( $$ ^ $_cg_clone_seq ) & 0xffff ), 0, 29 );

    my @prepared;   # { src, src_bid, new, svol }
    my $ok = eval {
        # 1. Prepare every member IDLE under the group (allocates S-VOLs; NO data moves yet).
        for my $src (@$members) {
            my ($src_bid) = $reg->lookup($src);
            my $new_name  = $reg->reserve_volname($target_vmid);
            # Track the entry BEFORE prepare (svol undef) so a prepare failure still rolls
            # back the reservation placeholder rather than leaking it.
            my $entry = { src => $src, src_bid => $src_bid, new => $new_name, svol => undef };
            push @prepared, $entry;
            my $rid  = $class->_alloc_backend_id( $storeid, $scfg, $d );
            $entry->{svol} = $d->prepare_full_clone( $src_bid, snapshot_group => $group,
                ( defined $rid ? ( requested_id => $rid ) : () ) );
            # Read the real S-VOL size + pool and register them: size_mb does NOT self-heal
            # (unlike identity, which activate_volume resolves post-publish), so an omitted
            # size would make volume_size_info/list_images report 0 → an unusable clone.
            my $lu = $d->get_lu( $entry->{svol} );
            $reg->register( $new_name, $entry->{svol},
                size_mb  => ceil( $lu->{size_bytes} / ( 1024 * 1024 ) ),
                pool_ref => $lu->{pool_ref},
                ( defined $lu->{identity} ? ( identity => $lu->{identity} ) : () ),
            );
        }
        # 2. Trigger the WHOLE group in one action → the shared point-in-time.
        $d->start_clone_group($group);
        # 3. Wait for every independent full copy to finish (dies on a PSUE copy failure).
        for my $p (@prepared) {
            $class->_await_clone_complete( $d, $p->{src_bid}, $group, $p->{svol} )
                or die "clone of '$p->{src}' did not complete in time\n";
        }
        1;
    };
    if ( !$ok ) {
        my $err = $@;
        $class->_rollback_prepared_clones( $d, $reg, $group, \@prepared );
        die ref $err ? $err : "cg_clone_create failed: $err";
    }
    return [ map { "$storeid:$_->{new}" } @prepared ];
}

# Poll a grouped-clone pair to completion. Bounded; returns 1 on complete, 0 on timeout.
# Propagates a PSUE copy failure from the driver. Package-var cadence (these are CLASS
# methods, so no instance to hang a knob on); tests set $CLONE_POLL_INTERVAL = 0 to probe
# once. ~1h budget by default for a large full copy.
our $CLONE_POLL_INTERVAL = 2;
our $CLONE_POLL_TRIES    = 7200;   # ~4h ceiling; a very large full copy on a busy shared
                                   # array can run long, and a timeout here rolls the copy
                                   # back. Raise (or set INTERVAL) for multi-TB clones.
sub _await_clone_complete {
    my ($class, $d, $src_bid, $group, $svol) = @_;
    my $tries = $CLONE_POLL_INTERVAL > 0 ? $CLONE_POLL_TRIES : 1;   # interval 0 → probe once
    for ( 1 .. $tries ) {
        return 1 if $d->clone_copy_state( $src_bid, $group, $svol ) eq 'complete';
        last if $CLONE_POLL_INTERVAL <= 0;
        sleep($CLONE_POLL_INTERVAL);
    }
    return 0;
}

# Best-effort teardown of a partially-built grouped clone: release each S-VOL's clone pair
# (idle or PSUE — a COMPLETED isClone pair already auto-deleted, so that's a no-op), delete
# the S-VOL LU, and drop the registry entry, so nothing leaks on the shared pool.
sub _rollback_prepared_clones {
    my ($class, $d, $reg, $group, $prepared) = @_;
    for my $p (@$prepared) {
        eval {
            if ( defined $p->{svol} ) {   # prepared → release its pair + delete the S-VOL
                my ($pair) = grep { ( $_->{meta}{group} // '' ) eq $group }
                    @{ $d->list_snapshots( $p->{src_bid} ) };
                $d->delete_snapshot( $pair->{snap_id} ) if $pair;
                $d->delete_lu( $p->{svol} );
            }
            $reg->unregister( $p->{new} );   # drops a finalized entry OR a bare reservation
            1;
        } or warn "FCLU: cg_clone rollback warning for '$p->{new}': $@";
    }
}

# N12: operator "unmanage host" — reap THIS node's now-empty host groups on the array
# (WWN-ownership-gated in the driver). Node-local: builds this node's host context.
sub unmanage_host {
    my ($class, $scfg, $storeid) = @_;
    my $conn = $class->_connector;
    my %hctx = %{ $conn->host_context( hostname => $class->_nodename ) };
    return $class->_driver( $storeid, $scfg )->reclaim_empty_host_groups(%hctx);
}

sub update_volume_attribute {
    my ($class, $scfg, $storeid, $volname, $attribute, $value) = @_;

    if ( $attribute eq 'protected' ) {
        my $reg = $class->_registry($storeid);
        die "Volume '$volname' not found in registry\n"
            unless defined $reg->lookup($volname);
        # Store 1 when set; remove the key when cleared.
        $reg->update_meta( $volname, protected => ( $value ? 1 : undef ) );
        return;
    }
    if ( $attribute eq 'notes' ) {
        return $class->update_volume_notes( $scfg, $storeid, $volname, $value );
    }
    if ( $attribute eq 'cg' ) {
        my $reg = $class->_registry($storeid);
        die "Volume '$volname' not found in registry\n"
            unless defined $reg->lookup($volname);
        # Consistency-group membership (§6 snapshot.consistency_group). A volume belongs
        # to at most one CG; an empty/undef value clears membership. Names are per-store.
        $reg->update_meta( $volname,
            cg => ( defined($value) && $value ne '' ? "$value" : undef ) );
        return;
    }
    die "attribute '$attribute' is not supported for storage type '$scfg->{type}'\n";
}

sub get_volume_notes {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;
    my ( $bid, $meta ) = $class->_registry($storeid)->lookup($volname);
    die "Volume '$volname' not found in registry\n" unless defined $bid;
    return $meta->{notes} // '';
}

sub update_volume_notes {
    my ($class, $scfg, $storeid, $volname, $notes, $timeout) = @_;
    my $reg = $class->_registry($storeid);
    die "Volume '$volname' not found in registry\n" unless defined $reg->lookup($volname);
    # Empty/undef clears the field rather than persisting an empty string.
    $reg->update_meta( $volname,
        notes => ( defined($notes) && $notes ne '' ? $notes : undef ) );
    return;
}

1;
