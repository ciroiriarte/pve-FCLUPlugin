package PVE::Storage::Custom::HitachiBlockPlugin;

use strict;
use warnings;

use base qw(PVE::Storage::FCLU::Plugin);

use PVE::Storage::FCLU::Driver::Hitachi;

# The thin Hitachi vendor shim over the generic FCLU::Plugin core (§5). It declares
# ONLY vendor identity, how storage.cfg maps to the driver, the Hitachi-specific
# typed properties, and the ldev_range safety overrides — every PVE-facing method
# body is inherited from FCLU::Plugin. Registering `type()='hitachiblock'` keeps the
# existing GUI and storage.cfg backward-compatible.

# A Hitachi Control Unit spans exactly 256 LDEV ids; a CU-aligned ldev_range gives
# clean per-CU reservations and optimal REST paging.
use constant LDEVS_PER_CU => 256;

# ── Vendor identity (the FCLU::Plugin abstract hooks) ──

sub type         { 'hitachiblock' }
sub vendor       { 'hitachi' }
sub driver_class { 'PVE::Storage::FCLU::Driver::Hitachi' }

# Map storage.cfg to the Driver::Hitachi constructor options. Credentials are added
# by the base _build_driver from FCLU::Credentials, NOT here.
sub driver_config {
    my ($class, $scfg) = @_;
    return {
        platform     => $scfg->{platform} // 'vsp_one',
        pool_id      => $scfg->{pool_id},
        snap_pool_id => $scfg->{snap_pool_id},
        mgmt_ip      => $scfg->{mgmt_ip},
        storage_id   => $scfg->{storage_id},
        ( defined $scfg->{mgmt_port}   ? ( port        => $scfg->{mgmt_port} )   : () ),
        ( defined $scfg->{tls_verify}  ? ( tls_verify  => $scfg->{tls_verify} )  : () ),
        ( defined $scfg->{tls_ca_file} ? ( tls_ca_file => $scfg->{tls_ca_file} ) : () ),
        # `rest_keepalive` (persistent session auth) is the inverse of the driver's
        # `sessionless` (the default); session-less avoids exhausting the array's
        # per-array session cap on large clusters.
        sessionless         => ( $scfg->{rest_keepalive} ? 0 : 1 ),
        array_ports         => $scfg->{target_ports},
        host_mode           => $scfg->{host_mode},
        host_mode_options   => $scfg->{host_mode_options},
        skip_unmap_io_check => $scfg->{skip_unmap_io_check},
        debug               => $scfg->{debug},
        # Host group name prefix: explicit config, else auto-derived from the PVE
        # cluster name so each cluster namespaces its host groups on a SHARED array
        # pool. See on_add_hook for the shared-array caveat.
        host_group_prefix   => $scfg->{host_group_prefix} // $class->_derive_cluster_prefix(),
    };
}

# The DEFAULT host-group name prefix when storage.cfg does not set host_group_prefix.
# It MUST be short and STABLE. An earlier version auto-derived "PVE-<clustername>" from
# corosync, which was actively harmful: (a) it read the cluster name only in a daemon
# context and returned plain "PVE" from a CLI, so the SAME node computed DIFFERENT names
# and never matched its own array group (forcing an O(host-groups) WWN scan on every
# map); (b) "PVE-<clustername>_<hostname>" easily exceeds the array's 16-char host-group
# name and truncates to a single "PVE-<clustername>_" that COLLAPSES all nodes — the
# opposite of the per-cluster separation it was meant to provide. A physical WWPN is
# globally unique and the §-multi-cluster WWN-ownership guard fail-closes any residual
# collision, so the prefix is only a human label. Default to plain "PVE" (matches groups
# created as PVE_<hostname>); multi-cluster shared-pool deployments set a distinct SHORT
# host_group_prefix per cluster explicitly.
sub _derive_cluster_prefix {
    my ($class) = @_;
    return 'PVE';
}

# ── Configuration schema (vendor deltas merged over the generic base) ──

sub properties {
    my ($class) = @_;
    return {
        %{ $class->SUPER::properties },
        storage_id => {
            description => "Storage device ID (storageDeviceId) of the array, e.g. the"
                . " 12-digit model+serial id returned by GET /v1/objects/storages — not"
                . " the bare serial number.",
            type        => 'string',
        },
        target_ports => {
            description => "Comma-separated list of target FC port IDs (e.g. CL1-A,CL2-A).",
            type        => 'string',
        },
        host_mode => {
            description => "Host mode for host group creation.",
            type        => 'string',
            default     => 'LINUX/IRIX',
            optional    => 1,
        },
        host_mode_options => {
            description => "Comma-separated Hitachi host mode option numbers set on the host"
                . " groups the plugin creates. Default '2,22,25,68' is the best-practice set"
                . " for LINUX/IRIX (68 = WRITE SAME / SCSI UNMAP for in-guest fstrim reclaim;"
                . " 2/22/25 = Veritas / SPC-3 PR reservation compatibility). Set to '' to"
                . " disable. Added idempotently to existing groups on activation (never removed).",
            type        => 'string',
            default     => '2,22,25,68',
            optional    => 1,
        },
        skip_unmap_io_check => {
            description => "Add Hitachi HMO 91 (skip the array's host-I/O check when a LUN path"
                . " is deleted) to the plugin's host groups, so unmap on free_image succeeds"
                . " immediately. Safe because the plugin always tears the host side down first"
                . " (flush + remove the device) before unmapping. Off by default.",
            type        => 'boolean',
            default     => 0,
            optional    => 1,
        },
        persistent_reservations => {
            description => "Validate-and-warn SCSI-3 Persistent Reservation readiness on"
                . " activate_volume (qemu-pr-helper socket + multipath reservation_key) for"
                . " shared/clustered guest disks. Never edits multipath.conf and never blocks"
                . " activation. Off by default.",
            type        => 'boolean',
            default     => 0,
            optional    => 1,
        },
        platform => {
            description => "Storage platform type. Sets the default API port: 'vsp_one' and"
                . " 'vsp_e' (embedded/direct REST) use 443; 'vsp_g' uses 23451 (Ops Center"
                . " Configuration Manager server). Override with mgmt_port to mix models.",
            type        => 'string',
            enum        => ['vsp_g', 'vsp_e', 'vsp_one'],
            default     => 'vsp_one',
            optional    => 1,
        },
        mgmt_port => {
            description => "Management API port (auto-detected from platform if omitted:"
                . " 443 for direct/embedded REST, 23451 for an Ops Center CM server).",
            type        => 'integer',
            optional    => 1,
        },
        ldev_range => {
            description => "Restrict LDEV ID allocation to a range (e.g. '1000-1999' or"
                . " '0x3E8-0x7CF'). Also fences destructive ops: the plugin refuses to unmap"
                . " or delete any LDEV outside the range, so it can never touch foreign"
                . " volumes that merely share a target port. On a pool shared by multiple PVE"
                . " clusters, give each cluster a DISJOINT range.",
            type        => 'string',
            optional    => 1,
        },
        host_group_prefix => {
            description => "Prefix for this cluster's per-node host group names"
                . " (<prefix>_<hostname>). Namespaces host groups on an array pool SHARED by"
                . " multiple PVE clusters so they never collide. Defaults to a stable, short"
                . " 'PVE' (matching groups created as PVE_<hostname>). Set an explicit,"
                . " distinct value per cluster when the clusters share a pool and could share"
                . " a hostname.",
            type        => 'string',
            optional    => 1,
        },
        discard_zero_page => {
            description => "Reclaim zero-filled pages on volume deactivation (thin pool space recovery).",
            type        => 'boolean',
            default     => 0,
            optional    => 1,
        },
        port_scheduler => {
            description => "Spread LUN mappings across target ports using stable, deterministic"
                . " per-LDEV port selection.",
            type        => 'boolean',
            default     => 0,
            optional    => 1,
        },
        copy_speed => {
            description => "Array-side copy speed for clone operations (1-15, default 3).",
            type        => 'integer',
            minimum     => 1,
            maximum     => 15,
            optional    => 1,
        },
        group_delete => {
            description => "Auto-delete empty host groups on storage deactivation.",
            type        => 'boolean',
            default     => 0,
            optional    => 1,
        },
        rest_keepalive => {
            description => "Keep a persistent Configuration Manager REST session per process"
                . " instead of authenticating each request (session-less, the default)."
                . " Session-less avoids exhausting the array's per-array session cap on large"
                . " clusters; enable only if your array requires session auth.",
            type        => 'boolean',
            default     => 0,
            optional    => 1,
        },
    };
}

sub options {
    my ($class) = @_;
    return {
        %{ $class->SUPER::options },
        storage_id          => { fixed => 1 },
        target_ports        => { fixed => 1 },
        host_mode           => { optional => 1 },
        host_mode_options   => { optional => 1 },
        skip_unmap_io_check => { optional => 1 },
        persistent_reservations => { optional => 1 },
        platform            => { optional => 1 },
        mgmt_port           => { optional => 1 },
        ldev_range          => { optional => 1 },
        host_group_prefix   => { optional => 1 },
        discard_zero_page   => { optional => 1 },
        port_scheduler      => { optional => 1 },
        copy_speed          => { optional => 1 },
        group_delete        => { optional => 1 },
        rest_keepalive      => { optional => 1 },
    };
}

# ── Registration hooks: base credential/probe lifecycle + an ldev_range hint ──

sub on_add_hook {
    my ($class, $storeid, $scfg, %sensitive) = @_;
    my $ret = $class->SUPER::on_add_hook( $storeid, $scfg, %sensitive );
    $class->_warn_if_ldev_range_misaligned( $scfg->{ldev_range} );
    $class->_warn_if_hg_prefix_unset($scfg);
    return $ret;
}

sub on_update_hook {
    my ($class, $storeid, $scfg, %sensitive) = @_;
    my $ret = $class->SUPER::on_update_hook( $storeid, $scfg, %sensitive );
    $class->_warn_if_ldev_range_misaligned( $scfg->{ldev_range} );
    $class->_warn_if_hg_prefix_unset($scfg);
    return $ret;
}

# Advisory: on a shared array pool the default prefix ('PVE') is identical on every
# cluster, so it does NOT namespace clusters apart — nudge the admin to set an
# explicit, distinct host_group_prefix.
sub _warn_if_hg_prefix_unset {
    my ($class, $scfg) = @_;
    return if defined $scfg->{host_group_prefix} && length $scfg->{host_group_prefix};
    warn "host_group_prefix is not set; host groups default to '"
        . $class->_derive_cluster_prefix() . "_<hostname>'."
        . " If this array pool is SHARED with another PVE cluster, set a distinct SHORT"
        . " host_group_prefix per cluster to prevent host-group collisions.\n";
}

# ── ldev_range: allocation hook + the §7 destructive-op safety fence ──

# Constrain allocation to the configured ldev_range (#20 — an explicit in-range id
# keeps the teardown fence valid). Returns undef when no range is set so the base
# lets the array auto-assign. The array scan lives in the driver; we pass the ids the
# registry has already claimed cluster-wide so two disks never race onto one id.
sub _alloc_backend_id {
    my ($class, $storeid, $scfg, $d) = @_;

    my $range = $scfg->{ldev_range};
    return undef unless defined $range && length $range;

    my ($min, $max) = $class->_parse_ldev_range($range);

    my $reg = $class->_registry($storeid)->list;
    my @reserved =
        grep { defined } map { ref eq 'HASH' ? $_->{backend_id} : () } values %$reg;

    return $d->next_free_backend_id( min => $min, max => $max, reserved => \@reserved );
}

# The §7 destructive-op FENCE the base free_image calls before ANY unmap/delete:
# refuse a backend id outside the configured ldev_range. With no range configured the
# registry membership stays the primary fence, so allow. This backstop keeps the
# plugin off foreign LUNs (the array does NOT filter LUN queries by ldevId — verified
# on the E590H), which matters on a shared production pool.
sub safe_delete_precheck {
    my ($class, $scfg, $backend_id) = @_;
    return $class->_ldev_in_range( $scfg, $backend_id );
}

# Post-deactivate reclaim: when discard_zero_page is enabled, reclaim the volume's
# zero-filled pages for thin-pool space recovery once the LU is unmapped on this
# node (ported from the reference plugin's deactivate_volume). Best-effort — the
# base deactivate_volume eval-wraps this, so a reclaim failure never wedges teardown.
sub _after_deactivate {
    my ($class, $storeid, $scfg, $backend_id, $driver) = @_;
    return 1 unless $scfg->{discard_zero_page};
    $driver->reclaim_zero_pages($backend_id);
    return 1;
}

# Parse an ldev_range ("1000-1999" or "0x3E8-0x7CF") into ($min,$max); dies on a
# malformed range.
sub _parse_ldev_range {
    my ($class, $range) = @_;

    my ($min, $max);
    if ( $range =~ /^(0x[0-9a-f]+)-(0x[0-9a-f]+)$/i ) {
        ($min, $max) = ( hex($1), hex($2) );
    } elsif ( $range =~ /^(\d+)-(\d+)$/ ) {
        ($min, $max) = ( int($1), int($2) );
    } else {
        die "invalid ldev_range format '$range' (expected 'min-max')\n";
    }

    die "invalid ldev_range: min ($min) > max ($max)\n" if $min > $max;
    return ($min, $max);
}

# True if $backend_id is inside the configured ldev_range; true when no range is set.
sub _ldev_in_range {
    my ($class, $scfg, $backend_id) = @_;

    my $range = $scfg->{ldev_range};
    return 1 unless defined $range && length $range;
    return 0 unless defined $backend_id;

    my ($min, $max) = $class->_parse_ldev_range($range);
    # Hitachi backend ids are decimal ldev-id strings, so int() is identity for them
    # and fail-safe for anything unexpected: a non-numeric id coerces toward 0, lands
    # out of range, and is BLOCKED — never mis-accepted as an in-range foreign LDEV.
    my $id = int($backend_id);
    return ( $id >= $min && $id <= $max ) ? 1 : 0;
}

# Informational hint (never fatal) when ldev_range is not CU-aligned. No-op when unset.
sub _warn_if_ldev_range_misaligned {
    my ($class, $range) = @_;
    return unless defined $range && length $range;

    my ($min, $max) = $class->_parse_ldev_range($range);
    my $aligned = ( ( $min % LDEVS_PER_CU ) == 0 )
        && ( ( ( $max + 1 ) % LDEVS_PER_CU ) == 0 );
    return if $aligned;

    my $first_cu = int( $min / LDEVS_PER_CU );
    warn sprintf(
        "hitachiblock: ldev_range %s is not CU-aligned. For clean per-CU reservation"
            . " and optimal paging, align to 256-LDEV CU boundaries, e.g. CU %d = %d-%d.\n",
        $range, $first_cu, $first_cu * LDEVS_PER_CU, $first_cu * LDEVS_PER_CU + LDEVS_PER_CU - 1,
    );
    return;
}

1;
