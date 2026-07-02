#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use lib 'src';
use PVE::Storage::FCLU::Driver::Hitachi;

# §9 Phase 1 step 3 (slice B): Driver::Hitachi host-access. Verifies the migrated
# host-group/HMO/WWN logic and the §2 map/unmap/list_lu_mappings contract against a
# small STATEFUL fake rest that models host groups + LUN paths in memory, so
# idempotency and node-targeting (§12.2) are genuinely exercised, not just call
# shapes.

# ── stateful fake Hitachi REST ──
package FakeRest;
sub new { bless { hgs => {}, luns => [], ldevs => {}, calls => {}, _hgnum => {}, _lun => 0, _lunid => 0 }, shift }
sub _c { $_[0]->{calls}{ $_[1] }++ }

sub _hg_name {
    my ( $s, $port, $num ) = @_;
    my $hg = $s->{hgs}{"$port,$num"};
    return $hg ? $hg->{hostGroupName} : undef;
}
sub find_host_group_by_name {
    my ( $s, $port, $name ) = @_; $s->_c('find_host_group_by_name');
    for my $hg ( values %{ $s->{hgs} } ) {
        return $hg if $hg->{portId} eq $port && $hg->{hostGroupName} eq $name;
    }
    return undef;
}
sub find_host_group_by_wwn {
    my ( $s, $port, $wwn ) = @_; $s->_c('find_host_group_by_wwn');
    for my $hg ( values %{ $s->{hgs} } ) {
        return $hg if $hg->{portId} eq $port && $hg->{wwns}{ lc $wwn };
    }
    return undef;
}
sub create_host_group {
    my ( $s, %o ) = @_; $s->_c('create_host_group');
    my $num = $s->{_hgnum}{ $o{port_id} }++ // 0;
    $s->{hgs}{"$o{port_id},$num"} = {
        portId => $o{port_id}, hostGroupNumber => $num,
        hostGroupName => $o{host_group_name},
        hostModeOptions => [ @{ $o{host_mode_options} || [] } ], wwns => {},
    };
    return { resourceId => "$o{port_id},$num" };
}
sub get_host_group {
    my ( $s, $id ) = @_; $s->_c('get_host_group');
    return $s->{hgs}{$id};
}
sub set_host_group_mode {
    my ( $s, %o ) = @_; $s->_c('set_host_group_mode');
    $s->{hgs}{ $o{host_group_id} }{hostModeOptions} = [ @{ $o{host_mode_options} || [] } ];
    return {};
}
sub list_host_wwns {
    my ( $s, %o ) = @_; $s->_c('list_host_wwns');
    my $hg = $s->{hgs}{"$o{port_id},$o{host_group_number}"} or return [];
    return [ map { { hostWwn => $_ } } sort keys %{ $hg->{wwns} } ];
}
sub add_wwn_to_host_group {
    my ( $s, %o ) = @_; $s->_c('add_wwn_to_host_group');
    $s->{hgs}{"$o{port_id},$o{host_group_number}"}{wwns}{ lc $o{wwn} } = 1;
    return {};
}
sub list_luns {
    my ( $s, %o ) = @_; $s->_c('list_luns');
    return [ grep {
        $_->{portId} eq $o{port_id}
            && $_->{hostGroupNumber} == $o{host_group_number}
            && ( !defined $o{ldev_id} || $_->{ldevId} eq "$o{ldev_id}" )
    } @{ $s->{luns} } ];
}
sub map_lun {
    my ( $s, %o ) = @_; $s->_c('map_lun');
    push @{ $s->{luns} }, {
        lunId => 'L' . $s->{_lunid}++, portId => $o{port_id},
        hostGroupNumber => $o{host_group_number}, ldevId => "$o{ldev_id}",
        lun => $s->{_lun}++,
    };
    $s->{ldevs}{ "$o{ldev_id}" } = 1;
    return {};
}
sub unmap_lun {
    my ( $s, $lid ) = @_; $s->_c('unmap_lun');
    $s->{luns} = [ grep { $_->{lunId} ne $lid } @{ $s->{luns} } ];
    return {};
}
sub get_ldev {
    my ( $s, $id ) = @_; $s->_c('get_ldev');
    die "API request failed: GET /ldevs/$id -> 404 Not Found\n" unless $s->{ldevs}{"$id"};
    my @ports = map { {
        portId => $_->{portId}, hostGroupNumber => $_->{hostGroupNumber},
        lun => $_->{lun}, hostGroupName => $s->_hg_name( $_->{portId}, $_->{hostGroupNumber} ),
    } } grep { $_->{ldevId} eq "$id" } @{ $s->{luns} };
    return { ldevId => $id, emulationType => 'OPEN-V', ports => \@ports };
}

package main;

sub drv {
    my ($fake, %o) = @_;
    return PVE::Storage::FCLU::Driver::Hitachi->new(
        platform => 'vsp_e', rest => $fake,
        array_ports => $o{array_ports} // [ 'CL1-A', 'CL2-A' ],
        host_mode_options => $o{hmo} // [ 2, 22, 25, 68 ],
        ( $o{skip_unmap} ? ( skip_unmap_io_check => 1 ) : () ),
    );
}
sub ctx { my ( $h, @w ) = @_; return ( hostname => $h, protocol => 'scsi-fc', initiators => [ @w ? @w : ('10000000c9aa') ] ); }

subtest 'ensure_host_access creates PVE_<host> per port, adds WWNs, idempotent' => sub {
    my $f = FakeRest->new;
    my $d = drv($f);
    is( $d->ensure_host_access( ctx('node-a') ), 'PVE_node-a', 'returns the access handle' );
    is( $f->{calls}{create_host_group}, 2, 'one host group created per port' );
    my $hg = $f->find_host_group_by_name( 'CL1-A', 'PVE_node-a' );
    ok( $hg->{wwns}{'10000000c9aa'}, 'node WWN registered' );

    # Second call: no new create, no duplicate WWN add.
    $d->ensure_host_access( ctx('node-a') );
    is( $f->{calls}{create_host_group}, 2, 'idempotent — no second create' );
    is( $f->{calls}{add_wwn_to_host_group}, 2, 'WWN added only on the first pass (once per port)' );
};

subtest 'ensure_host_access reuses a group found by WWN under a different name' => sub {
    my $f = FakeRest->new;
    # Pre-existing group with a non-PVE name but containing our WWN.
    $f->create_host_group( port_id => 'CL1-A', host_group_name => 'legacy', host_mode_options => [] );
    $f->{hgs}{'CL1-A,0'}{wwns}{'10000000c9aa'} = 1;
    my $d = drv( $f, array_ports => ['CL1-A'] );
    $d->ensure_host_access( ctx('node-a') );
    is( $f->{calls}{create_host_group}, 1, 'reused the WWN-matched group, no new create' );
};

subtest 'ensure_host_access reconciles missing host-mode options (union)' => sub {
    my $f = FakeRest->new;
    $f->create_host_group( port_id => 'CL1-A', host_group_name => 'PVE_node-a', host_mode_options => [ 2, 22 ] );
    $f->{hgs}{'CL1-A,0'}{wwns}{'10000000c9aa'} = 1;
    my $d = drv( $f, array_ports => ['CL1-A'], hmo => [ 22, 25, 68 ] );
    $d->ensure_host_access( ctx('node-a') );
    is_deeply( $f->{hgs}{'CL1-A,0'}{hostModeOptions}, [ 2, 22, 25, 68 ],
        'missing options added as a sorted union; existing kept' );
};

subtest 'skip_unmap_io_check appends HMO 91' => sub {
    my $f = FakeRest->new;
    my $d = drv( $f, array_ports => ['CL1-A'], skip_unmap => 1 );
    $d->ensure_host_access( ctx('node-a') );
    ok( ( grep { $_ == 91 } @{ $f->{hgs}{'CL1-A,0'}{hostModeOptions} } ), 'HMO 91 present' );
};

subtest 'host_ctx validation' => sub {
    my $d = drv( FakeRest->new );
    eval { $d->ensure_host_access( protocol => 'scsi-fc', initiators => ['x'] ) };
    like( $@->message, qr/missing 'hostname'/, 'missing hostname' );
    eval { $d->ensure_host_access( hostname => 'h', protocol => 'nvme-fc', initiators => ['x'] ) };
    like( $@->message, qr/unsupported protocol/, 'bad protocol' );
    eval { $d->ensure_host_access( hostname => 'h', protocol => 'scsi-fc', initiators => [] ) };
    like( $@->message, qr/non-empty arrayref/, 'empty initiators' );
};

subtest 'publish_lu maps the ldev per port, idempotently' => sub {
    my $f = FakeRest->new;
    my $d = drv($f);
    my $m = $d->publish_lu( '42', ctx('node-a') );
    is( $m->{hostname}, 'node-a', 'mapping hostname' );
    is( $m->{access_ref}, 'PVE_node-a', 'mapping access_ref' );
    ok( defined $m->{lun}, 'a lun number is reported' );
    is( $f->{calls}{map_lun}, 2, 'mapped on both ports' );

    # Re-publish: no new map_lun (already mapped).
    $d->publish_lu( '42', ctx('node-a') );
    is( $f->{calls}{map_lun}, 2, 'idempotent — no remap' );
};

subtest 'unpublish_lu removes only this node, idempotently' => sub {
    my $f = FakeRest->new;
    my $d = drv($f);
    $d->publish_lu( '42', ctx( 'node-a', '10000000c9aa' ) );
    $d->publish_lu( '42', ctx( 'node-b', '10000000c9bb' ) );

    $d->unpublish_lu( '42', ctx( 'node-a', '10000000c9aa' ) );
    my %nodes = map { $_->{hostname} => 1 } @{ $d->list_lu_mappings('42') };
    ok( !$nodes{'node-a'}, 'node-a mapping gone' );
    ok( $nodes{'node-b'}, 'node-b mapping intact (node-targeted unmap)' );

    # Idempotent: unpublishing the already-removed node is a no-op success.
    my $before = $f->{calls}{unmap_lun};
    is( $d->unpublish_lu( '42', ctx( 'node-a', '10000000c9aa' ) ), 1, 'no-op success' );
    is( $f->{calls}{unmap_lun}, $before, 'no further unmap calls' );
};

subtest 'unpublish_lu_all reaps EVERY node mapping (crashed-migration cleanup)' => sub {
    my $f = FakeRest->new;
    my $d = drv($f);
    $d->publish_lu( '42', ctx( 'node-a', '10000000c9aa' ) );
    $d->publish_lu( '42', ctx( 'node-b', '10000000c9bb' ) );
    is( scalar @{ $d->list_lu_mappings('42') }, 2, 'mapped on two nodes to start' );

    # Cluster-wide reap (what this node's WWN-scoped unpublish_lu cannot do).
    is( $d->unpublish_lu_all('42'), 1, 'unpublish_lu_all returns success' );
    is( scalar @{ $d->list_lu_mappings('42') }, 0, 'ALL node mappings removed' );

    # Idempotent: the ldev still exists but has no LU paths left.
    my $before = $f->{calls}{unmap_lun};
    is( $d->unpublish_lu_all('42'), 1, 'idempotent when nothing is mapped' );
    is( $f->{calls}{unmap_lun}, $before, 'no further unmap calls' );
};

subtest 'list_lu_mappings is authoritative from get_ldev->{ports}' => sub {
    my $f = FakeRest->new;
    my $d = drv($f);
    $d->publish_lu( '42', ctx( 'node-a', '10000000c9aa' ) );
    $d->publish_lu( '42', ctx( 'node-b', '10000000c9bb' ) );

    my $maps = $d->list_lu_mappings('42');
    is_deeply( [ sort map { $_->{hostname} } @$maps ], [ 'node-a', 'node-b' ],
        'one descriptor per node, hostname parsed from PVE_<host>' );
    ok( defined $maps->[0]{access_ref}, 'access_ref present (MUST)' );

    my $err;
    eval { $d->list_lu_mappings('999'); 1 } or $err = $@;
    is( $err->code, 'not_found', 'missing ldev => not_found' );
};

subtest 'list_lu_mappings never DROPS a mapping when the group name is unresolved' => sub {
    # SAFETY: the sole authority for safe-unmap must not hide a node. Craft a port
    # entry whose host group cannot be name-resolved (no hg record, get_host_group
    # returns undef) — the mapping must still surface, keyed by the composite id.
    my $f = FakeRest->new;
    $f->{ldevs}{'77'} = 1;
    push @{ $f->{luns} },
        { lunId => 'L9', portId => 'CL1-A', hostGroupNumber => 5, ldevId => '77', lun => 3 };
    my $d = drv($f);

    my $maps = $d->list_lu_mappings('77');
    is( scalar @$maps, 1, 'the unresolved mapping is still reported (not dropped)' );
    is( $maps->[0]{access_ref}, 'CL1-A,5', 'falls back to the composite port,hgnum id' );
    is( $maps->[0]{hostname},   'CL1-A,5', 'hostname falls back to the raw key (visible to safe-unmap)' );
};

subtest 'unpublish_lu surfaces the cause when EVERY unmap fails (§12.4)' => sub {
    my $f = FakeRest->new;
    my $d = drv($f);
    $d->publish_lu( '42', ctx('node-a') );

    # Make every unmap fail with a retryable array-busy.
    no warnings 'redefine';
    local *FakeRest::unmap_lun = sub { die "API request failed: DELETE /luns/x -> 503 Service Unavailable\n" };
    local $SIG{__WARN__} = sub { };

    my $err;
    eval { $d->unpublish_lu( '42', ctx('node-a') ); 1 } or $err = $@;
    isa_ok( $err, 'PVE::Storage::FCLU::Error', 'all-unmap-fail' );
    is( $err->code, 'array_busy', 'classified from the underlying cause (retryable)' );
};

subtest 'target_ports surfaces configured ports (WWPN deferred to fabric §14)' => sub {
    my $d = drv( FakeRest->new, array_ports => [ 'CL1-A', 'CL2-A' ] );
    is_deeply( $d->target_ports, [ { port_id => 'CL1-A' }, { port_id => 'CL2-A' } ],
        'configured ports surfaced, no fabricated wwpn' );
};

done_testing();
