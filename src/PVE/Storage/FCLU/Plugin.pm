package PVE::Storage::FCLU::Plugin;

use strict;
use warnings;

use base qw(PVE::Storage::Plugin);

use POSIX qw(ceil);

use PVE::Storage::FCLU::Registry;
use PVE::Storage::FCLU::Credentials;
use PVE::Storage::FCLU::Capabilities;
use PVE::Storage::FCLU::Label;

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
use constant FCLU_MAX_APIVER => 12;

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

sub plugindata {
    return {
        # images = VM disks; rootdir = LXC rootfs (PVE formats+mounts the raw LUN,
        # the block model); none = configurable with no content type.
        content => [ { images => 1, rootdir => 1, none => 1 }, { images => 1 } ],
        format  => [ { raw => 1 }, 'raw' ],
        # password is sensitive: PVE never writes it to storage.cfg and passes it to
        # the add/update hooks via %sensitive.
        'sensitive-properties' => { password => 1 },
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
    return $dclass->new( %opts, username => $user, password => $pass );
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

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;
    my ( $total, $free, $used ) = $class->_driver( $storeid, $scfg )->storage_status;
    return ( $total, $free, $used, 1 );
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

# Map QoS storage.cfg knobs to the driver's qos hash (generic field names).
sub _qos_from_scfg {
    my ($class, $scfg) = @_;
    my %qos;
    $qos{upper_iops}        = $scfg->{qos_upper_iops} if $scfg->{qos_upper_iops};
    $qos{upper_mbps}        = $scfg->{qos_upper_mbps} if $scfg->{qos_upper_mbps};
    $qos{lower_iops}        = $scfg->{qos_lower_iops} if $scfg->{qos_lower_iops};
    $qos{lower_mbps}        = $scfg->{qos_lower_mbps} if $scfg->{qos_lower_mbps};
    $qos{response_priority} = $scfg->{qos_priority}   if $scfg->{qos_priority};
    return \%qos;
}

# Ownership label, clamped to the driver's advertised max length (§7 — not a
# hardcoded 32 in the core; the constraint comes from the driver profile).
sub _make_label {
    my ($class, $storeid, $volname, $driver) = @_;
    my $max = $driver->detect_profile->{max_label_len};
    return PVE::Storage::FCLU::Label->make_label( $storeid, $volname, $max );
}

# Seams: the host connector and this node's name (overridable in tests).
sub _connector { return $_[0]->connector_class->new }

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
    my ( $backend_id, $entry ) = $class->_registry($storeid)->lookup($volname);

    if ($snapname) {
        # Snapshot S-VOL resolution lands with the snapshot slice; for now a
        # snapshot's own backend id is read from the snapshot subregistry if present.
        my $snap = $class->_registry($storeid)->lookup_snapshot( $volname, $snapname );
        $backend_id = $snap->{svol} if $snap && defined $snap->{svol};
    }

    if ( !defined $backend_id ) {
        return () if ( $mode // 'die' ) eq 'soft';
        die "volume '$volname'" . ( $snapname ? "\@$snapname" : '' ) . " not found in registry\n";
    }
    return ( $backend_id, $entry );
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

        # QoS is best-effort: a limit-set failure must not fail provisioning.
        my $qos = $class->_qos_from_scfg($scfg);
        if (%$qos) {
            eval { $d->set_lu_qos( $backend_id, $qos ) };
            warn "FCLU: QoS application warning: $@" if $@;
        }

        # Read the real (possibly min-clamped) size + canonical identity once, then
        # commit to the registry LAST — the volume is now real and discoverable.
        my $lu = $d->get_lu($backend_id);
        $reg->register( $name, $backend_id,
            identity => $lu->{identity},
            size_mb  => ceil( $lu->{size_bytes} / ( 1024 * 1024 ) ),
            pool_ref => $lu->{pool_ref},
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
    my ($backend_id) = $class->_resolve_backend( $storeid, $scfg, $volname, $snapname, 'die' );

    my $d    = $class->_driver( $storeid, $scfg );
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
    $class->_registry($storeid)->update_meta( $volname, identity => $identity )
        if $identity && !$snapname;   # snapshot-S-VOL identity lands with the snapshot slice

    # Attach the multipath device by the array-reported canonical identity (§3).
    $conn->attach($identity);
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
    # is exactly when it matters. (Snapshot-S-VOL identity lands with the snapshot
    # slice via the snapshot subregistry.)
    my $identity = $entry->{identity};
    eval { $conn->detach($identity) } if $identity;
    warn "FCLU: device detach warning: $@" if $@;

    my %hctx = %{ $conn->host_context( hostname => $class->_nodename ) };
    eval { $d->unpublish_lu( $backend_id, %hctx ) };
    warn "FCLU: unmap warning: $@" if $@;

    return 1;
}

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

    my $identity = $entry->{identity};
    die "volume '$volname' has no recorded device identity\n" unless $identity;
    my $path = $class->_connector->device_path($identity);

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

    # Delete this volume's own snapshot pairs first (capability-gated). NOTE: the
    # linked-clone P-VOL pair release (#23 — when THIS volume is a clone S-VOL) is
    # wired with clone_image in the snapshot/clone slice (4D).
    if ( PVE::Storage::FCLU::Capabilities->has_feature( $d->capabilities, 'snapshot', 'single' ) ) {
        eval {
            for my $s ( @{ $d->list_snapshots($backend_id) } ) {
                $d->delete_snapshot( $s->{snap_id} );
            }
        };
        warn "FCLU: snapshot cleanup warning: $@" if $@;
    }

    # Tear the host side down (detach the device + unmap THIS node) before deleting
    # on the array — reuses the deactivate path (idempotent).
    $class->deactivate_volume( $storeid, $scfg, $volname );

    $d->delete_lu($backend_id);
    $reg->unregister($volname);

    return undef;
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

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

    # Keyed by the volume's role (block-storage / LVM-thin model): a linked clone
    # is a CoW Thin Image S-VOL, so 'clone' is offered only FROM a base image or a
    # snapshot (not an arbitrary live volume); full copies use 'copy'.
    my $features = {
        snapshot   => { current => 1 },
        clone      => { base => 1, snap => 1 },
        copy       => { base => 1, current => 1, snap => 1 },
        sparseinit => { base => 1, current => 1 },
        template   => { current => 1 },
        rename     => { current => 1 },
        resize     => { current => 1 },
    };

    my $isBase = ( $class->parse_volname($volname) )[5];
    my $key = $snapname ? 'snap' : ( $isBase ? 'base' : 'current' );

    return 1 if $features->{$feature} && $features->{$feature}{$key};
    return undef;
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
