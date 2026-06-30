package FCLU::FakeHitachiRest;

use strict;
use warnings;

# A STATEFUL in-memory Hitachi Configuration Manager REST simulator, implementing
# exactly the RestClient method surface that PVE::Storage::FCLU::Driver::Hitachi
# calls. It is the backend for the §12.5 conformance run (contract_hitachi.t) and
# the snapshot/clone unit tests: a real array's create->get->map->snapshot->delete
# sequences actually mutate state here, so idempotency/retry behaviour is exercised
# for real rather than scripted.
#
# IDs are treated OPAQUELY (string keys, never int()) so the driver-agnostic
# contract suite's string ids ('reasrt-1', …) work — production ids happen to be
# numeric, but the contract says backend_id is opaque.

use constant MIB => 1024 * 1024;

sub new {
    my ($class, %opts) = @_;
    return bless {
        ldevs => {},        # id => { ldevId, blockCapacity, label, poolId, naaId, emulationType, qos... }
        hgs   => {},        # "port,num" => host group
        luns  => [],        # [ { lunId, portId, hostGroupNumber, ldevId, lun } ]
        snaps => {},        # snapshotId => { snapshotId, pvolLdevId, svolLdevId, snapshotGroupName, status }
        pool  => $opts{pool} // { totalPoolCapacity => 1 << 20, usedPoolCapacity => 0 },
        calls => {},
        _ldev => 1000, _lun => 0, _lunid => 0, _naa => 0, _hgnum => {}, _mu => {},
    }, $class;
}

sub _c { $_[0]->{calls}{ $_[1] }++ }
sub _404 { die "API request failed: $_[0] -> 404 Not Found\n" }

# ── session ──
sub login     { $_[0]->_c('login');     1 }
sub logout    { $_[0]->_c('logout');    1 }
sub keepalive { $_[0]->_c('keepalive'); 1 }

# ── ldev lifecycle ──
sub create_ldev {
    my ($s, %o) = @_; $s->_c('create_ldev');
    my $blocks =
        defined $o{block_capacity} ? $o{block_capacity}
      : ( ( $o{size_mb} // ( $o{byteFormatCapacity} =~ /^(\d+)/ ? $1 : 0 ) ) * MIB / 512 );
    my $id = defined $o{ldev_id} ? "$o{ldev_id}" : '' . ( ++$s->{_ldev} );
    $s->{ldevs}{$id} = {
        ldevId => $id, blockCapacity => $blocks,
        poolId => $o{pool_id}, emulationType => 'OPEN-V',
        naaId  => sprintf( '60060e80%016x', ++$s->{_naa} ),
        label  => undef,
    };
    return { resourceId => $id };
}
sub delete_ldev {
    my ($s, $id) = @_; $s->_c('delete_ldev');
    delete $s->{ldevs}{"$id"};   # idempotent: absent => no-op
    $s->{luns} = [ grep { $_->{ldevId} ne "$id" } @{ $s->{luns} } ];
    return 1;
}
sub get_ldev {
    my ($s, $id) = @_; $s->_c('get_ldev');
    my $l = $s->{ldevs}{"$id"} or _404("GET /ldevs/$id");
    my @ports = map { {
        portId => $_->{portId}, hostGroupNumber => $_->{hostGroupNumber},
        lun => $_->{lun}, hostGroupName => $s->_hgname( $_->{portId}, $_->{hostGroupNumber} ),
    } } grep { $_->{ldevId} eq "$id" } @{ $s->{luns} };
    return { %$l, ports => \@ports };
}
sub list_ldevs {
    my ($s, %f) = @_; $s->_c('list_ldevs');
    return [ grep { !defined $f{pool_id} || ( defined $_->{poolId} && $_->{poolId} eq $f{pool_id} ) }
             map { { %{ $s->{ldevs}{$_} } } } sort keys %{ $s->{ldevs} } ];
}
sub set_ldev_label {
    my ($s, $id, $label) = @_; $s->_c('set_ldev_label');
    my $l = $s->{ldevs}{"$id"} or _404("PATCH /ldevs/$id");
    $l->{label} = $label;
    return 1;
}
sub expand_ldev {
    my ($s, $id, $add_mb) = @_; $s->_c('expand_ldev');
    my $l = $s->{ldevs}{"$id"} or _404("POST /ldevs/$id/expand");
    $l->{blockCapacity} += $add_mb * MIB / 512;
    return 1;
}
sub get_pool { my ($s) = @_; $s->_c('get_pool'); return { %{ $s->{pool} } } }

# ── QoS ──
sub set_ldev_qos {
    my ($s, $id, %o) = @_; $s->_c('set_ldev_qos');
    my $l = $s->{ldevs}{"$id"} or _404("PATCH /ldevs/$id");
    $l->{upperIops} = $o{upper_iops} if defined $o{upper_iops};
    $l->{upperTransferRate} = $o{upper_mbps} if defined $o{upper_mbps};
    $l->{lowerIops} = $o{lower_iops} if defined $o{lower_iops};
    $l->{lowerTransferRate} = $o{lower_mbps} if defined $o{lower_mbps};
    $l->{responsePriority} = $o{response_priority} if defined $o{response_priority};
    return 1;
}
sub get_ldev_qos {
    my ($s, $id) = @_; $s->_c('get_ldev_qos');
    my $l = $s->{ldevs}{"$id"} or _404("GET /ldevs/$id");
    return {
        upper_iops => $l->{upperIops}, upper_mbps => $l->{upperTransferRate},
        lower_iops => $l->{lowerIops}, lower_mbps => $l->{lowerTransferRate},
        response_priority => $l->{responsePriority},
    };
}

# ── host groups ──
sub _hgname { my ( $s, $p, $n ) = @_; my $hg = $s->{hgs}{"$p,$n"}; return $hg ? $hg->{hostGroupName} : undef }
sub find_host_group_by_name {
    my ( $s, $port, $name ) = @_; $s->_c('find_host_group_by_name');
    for my $hg ( values %{ $s->{hgs} } ) { return $hg if $hg->{portId} eq $port && $hg->{hostGroupName} eq $name }
    return undef;
}
sub find_host_group_by_wwn {
    my ( $s, $port, $wwn ) = @_; $s->_c('find_host_group_by_wwn');
    for my $hg ( values %{ $s->{hgs} } ) { return $hg if $hg->{portId} eq $port && $hg->{wwns}{ lc $wwn } }
    return undef;
}
sub create_host_group {
    my ( $s, %o ) = @_; $s->_c('create_host_group');
    my $num = $s->{_hgnum}{ $o{port_id} }++ // 0;
    $s->{hgs}{"$o{port_id},$num"} = {
        portId => $o{port_id}, hostGroupNumber => $num, hostGroupName => $o{host_group_name},
        hostModeOptions => [ @{ $o{host_mode_options} || [] } ], wwns => {},
    };
    return { resourceId => "$o{port_id},$num" };
}
sub get_host_group { my ( $s, $id ) = @_; $s->_c('get_host_group'); return $s->{hgs}{$id} }
sub set_host_group_mode {
    my ( $s, %o ) = @_; $s->_c('set_host_group_mode');
    $s->{hgs}{ $o{host_group_id} }{hostModeOptions} = [ @{ $o{host_mode_options} || [] } ];
    return 1;
}
sub list_host_wwns {
    my ( $s, %o ) = @_; $s->_c('list_host_wwns');
    my $hg = $s->{hgs}{"$o{port_id},$o{host_group_number}"} or return [];
    return [ map {; { hostWwn => $_ } } sort keys %{ $hg->{wwns} } ];
}
sub add_wwn_to_host_group {
    my ( $s, %o ) = @_; $s->_c('add_wwn_to_host_group');
    $s->{hgs}{"$o{port_id},$o{host_group_number}"}{wwns}{ lc $o{wwn} } = 1;
    return 1;
}

# ── lun paths ──
sub list_luns {
    my ( $s, %o ) = @_; $s->_c('list_luns');
    return [ grep {
        $_->{portId} eq $o{port_id} && $_->{hostGroupNumber} == $o{host_group_number}
            && ( !defined $o{ldev_id} || $_->{ldevId} eq "$o{ldev_id}" )
    } @{ $s->{luns} } ];
}
sub map_lun {
    my ( $s, %o ) = @_; $s->_c('map_lun');
    push @{ $s->{luns} }, {
        lunId => 'L' . $s->{_lunid}++, portId => $o{port_id},
        hostGroupNumber => $o{host_group_number}, ldevId => "$o{ldev_id}", lun => $s->{_lun}++,
    };
    return 1;
}
sub unmap_lun {
    my ( $s, $lid ) = @_; $s->_c('unmap_lun');
    $s->{luns} = [ grep { $_->{lunId} ne $lid } @{ $s->{luns} } ];
    return 1;
}

# ── snapshots (Thin Image) ──
sub _new_snap {
    my ( $s, %o ) = @_;
    my $pvol = $o{pvol_ldev_id};
    my $sid  = "$pvol," . ( $s->{_mu}{$pvol}++ // 0 );
    $s->{snaps}{$sid} = {
        snapshotId => $sid, pvolLdevId => $pvol, svolLdevId => $o{svol_ldev_id},
        snapshotGroupName => $o{snapshot_group}, status => 'PSUS',
    };
    return { resourceId => $sid };
}
sub create_snapshot      { my ( $s, %o ) = @_; $s->_c('create_snapshot');      return $s->_new_snap(%o) }
sub clone_snapshot_to_ldev { my ( $s, %o ) = @_; $s->_c('clone_snapshot_to_ldev'); return $s->_new_snap(%o) }
sub list_snapshots {
    my ( $s, %f ) = @_; $s->_c('list_snapshots');
    return [ map { { %{ $s->{snaps}{$_} } } }
             grep { !defined $f{pvol_ldev_id} || $s->{snaps}{$_}{pvolLdevId} eq "$f{pvol_ldev_id}" }
             sort keys %{ $s->{snaps} } ];
}
sub get_snapshot { my ( $s, $id ) = @_; $s->_c('get_snapshot'); my $sn = $s->{snaps}{$id} or _404("GET /snapshots/$id"); return { %$sn } }
sub delete_snapshot { my ( $s, $id ) = @_; $s->_c('delete_snapshot'); delete $s->{snaps}{$id}; return 1 }
sub split_snapshot  { my ( $s, $id ) = @_; $s->_c('split_snapshot');  ( $s->{snaps}{$id} || _404("split") )->{status} = 'PSUS'; return 1 }
sub restore_snapshot { my ( $s, $id ) = @_; $s->_c('restore_snapshot'); ( $s->{snaps}{$id} || _404("restore") )->{status} = 'PAIR'; return 1 }
sub assign_snapshot_volume {
    my ( $s, $id, $svol ) = @_; $s->_c('assign_snapshot_volume');
    ( $s->{snaps}{$id} || _404("assign") )->{svolLdevId} = $svol; return 1;
}

1;
