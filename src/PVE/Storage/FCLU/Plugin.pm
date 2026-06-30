package PVE::Storage::FCLU::Plugin;

use strict;
use warnings;

use base qw(PVE::Storage::Plugin);

use PVE::Storage::FCLU::Registry;
use PVE::Storage::FCLU::Credentials;
use PVE::Storage::FCLU::Capabilities;

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
