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
sub list_host_groups {
    my ( $s, %o ) = @_; $s->_c('list_host_groups');
    return [ grep { !defined $o{port_id} || $_->{portId} eq $o{port_id} } values %{ $s->{hgs} } ];
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
sub delete_host_group {
    my ( $s, $id ) = @_; $s->_c('delete_host_group');
    delete $s->{hgs}{$id};
    return {};
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
sub _invalidate_hg_list_cache { $_[0]->_c('_invalidate_hg_list_cache') }   # fake has no list cache
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
        ( defined $o{prefix} ? ( host_group_prefix => $o{prefix} ) : () ),
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

subtest 'host_group_prefix namespaces the host group name' => sub {
    my $f = FakeRest->new;
    my $d = drv( $f, prefix => 'clsX' );
    my $ref = $d->ensure_host_access( ctx('node-a') );
    is( $ref, 'clsX_node-a', 'access handle uses the configured prefix' );
    ok( $f->find_host_group_by_name( 'CL1-A', 'clsX_node-a' ), 'group created with the prefixed name' );
};

subtest 'ensure_host_access REFUSES a group holding FOREIGN initiators (multi-cluster guard)' => sub {
    my $f = FakeRest->new;
    my $d = drv($f);
    # Our-named group, but seeded with another cluster node's (foreign) WWN.
    $f->create_host_group( port_id => 'CL1-A', host_group_name => 'PVE_node-a', host_mode_options => [] );
    $f->create_host_group( port_id => 'CL2-A', host_group_name => 'PVE_node-a', host_mode_options => [] );
    $f->add_wwn_to_host_group( port_id => 'CL1-A', host_group_number => 0, wwn => '10000000dead' );
    my $err;
    eval { $d->ensure_host_access( ctx( 'node-a', '10000000c9aa' ) ); 1 } or $err = $@;
    ok( $err, 'ensure_host_access dies' );
    is( ref $err && $err->code, 'conflict', 'error code is conflict' );
    like( "$err", qr/foreign|not owned/i, 'message flags the foreign-initiator collision' );
    ok( !$f->{hgs}{'CL1-A,0'}{wwns}{'10000000c9aa'}, 'this node WWN was NOT merged into the foreign group' );
};

subtest 'adopts a legacy PVE_<host> group by WWN under a new prefix (no rename, no duplicate)' => sub {
    my $f = FakeRest->new;
    $f->create_host_group( port_id => 'CL1-A', host_group_name => 'PVE_node-a', host_mode_options => [] );
    $f->create_host_group( port_id => 'CL2-A', host_group_name => 'PVE_node-a', host_mode_options => [] );
    $f->add_wwn_to_host_group( port_id => 'CL1-A', host_group_number => 0, wwn => '10000000c9aa' );
    $f->add_wwn_to_host_group( port_id => 'CL2-A', host_group_number => 0, wwn => '10000000c9aa' );
    my $d = drv( $f, prefix => 'clsX' );
    my $ref = $d->ensure_host_access( ctx( 'node-a', '10000000c9aa' ) );
    is( $ref, 'PVE_node-a', 'adopted the legacy group name, not renamed to clsX_node-a' );
    ok( !$f->find_host_group_by_name( 'CL1-A', 'clsX_node-a' ), 'no duplicate prefixed group created' );
    is( $f->{calls}{create_host_group}, 2, 'no additional host groups created (only the 2 pre-existing)' );
};

subtest '#4 atomic create: a freshly-created group with zero WWNs is rolled back + fails loud' => sub {
    my $f = FakeRest->new;
    my $d = drv( $f, array_ports => ['CL1-A'] );
    my $err;
    my @warns;
    {
        no warnings 'redefine';
        local *FakeRest::add_wwn_to_host_group =
            sub { die "API request failed: POST /host-wwns -> 400 EXCEED_WWN_MAX\n" };
        local $SIG{__WARN__} = sub { push @warns, $_[0] };
        eval { $d->ensure_host_access( ctx( 'node-a', '10000000c9aa' ) ); 1 } or $err = $@;
    }
    ok( $err, 'ensure_host_access dies rather than leave an empty group' );
    # The rollback warning must actually name the node — guards against a `$hostname's`
    # apostrophe being parsed as the old `'` package separator (interpolates to empty).
    ok( ( grep { /rolled back the empty group/ && /\bnode-a\b/ } @warns ),
        'rollback warning names the node (no empty-interpolation regression)' );
    is( ref $err && $err->code, 'internal', 'zero-WWN create => internal error' );
    like( "$err", qr/registered none|rolled the empty group/i, 'message explains the rollback' );
    is( $f->{calls}{delete_host_group}, 1, 'the empty group was deleted (rolled back)' );
    ok( !$f->find_host_group_by_name( 'CL1-A', 'PVE_node-a' ), 'no empty group left on the array' );
};

subtest '#4 an EXISTING group whose WWN add glitches is kept (additive/best-effort)' => sub {
    my $f = FakeRest->new;
    # Pre-existing group already holding this node's WWN (re-bring-up).
    $f->create_host_group( port_id => 'CL1-A', host_group_name => 'PVE_node-a', host_mode_options => [] );
    $f->{hgs}{'CL1-A,0'}{wwns}{'10000000c9aa'} = 1;
    my $d = drv( $f, array_ports => ['CL1-A'] );
    my $ok = eval { $d->ensure_host_access( ctx( 'node-a', '10000000c9aa' ) ); 1 };
    ok( $ok, 'existing group with our WWN present is not rolled back' );
    is( $f->{calls}{delete_host_group} // 0, 0, 'no rollback of a pre-existing group' );
};

subtest '#4 asymmetric zoning: a dead port is rolled back but activation SUCCEEDS' => sub {
    my $f = FakeRest->new;
    my $d = drv( $f, array_ports => [ 'CL1-A', 'CL2-A' ] );
    my $ref;
    {
        no warnings 'redefine';
        my $orig = \&FakeRest::add_wwn_to_host_group;
        # Node is zoned to CL1-A only; the WWN add on CL2-A fails (not logged in there).
        local *FakeRest::add_wwn_to_host_group = sub {
            my ( $s, %o ) = @_;
            die "API request failed: POST /host-wwns -> 400 not logged in\n" if $o{port_id} eq 'CL2-A';
            return $orig->( $s, %o );
        };
        local $SIG{__WARN__} = sub { };
        $ref = eval { $d->ensure_host_access( ctx( 'node-a', '10000000c9aa' ) ) };
    }
    ok( defined $ref && !ref $ref, 'activation succeeds on the working port (no abort)' );
    is( $ref, 'PVE_node-a', 'access handle from the zoned port' );
    is( $f->{calls}{delete_host_group}, 1, 'only the dead (CL2-A) group was rolled back' );
    ok( $f->find_host_group_by_name( 'CL1-A', 'PVE_node-a' ), 'the working port keeps its group' );
    ok( $f->{hgs}{'CL1-A,0'}{wwns}{'10000000c9aa'}, 'and it holds this node WWN' );
    ok( !$f->find_host_group_by_name( 'CL2-A', 'PVE_node-a' ), 'the empty CL2-A group is gone' );
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

subtest 'publish_lu SAFETY GATE: refuses to map into a group holding a foreign WWN' => sub {
    my $f = FakeRest->new;
    my $d = drv($f);
    $d->ensure_host_access( ctx( 'node-a', '10000000c9aa' ) );   # PVE_node-a, our WWN
    # A foreign initiator lands in our group's number (cross-cluster collision / number reuse).
    $f->{hgs}{'CL1-A,0'}{wwns}{'2100000000ffff'} = 1;
    my $err;
    eval { $d->publish_lu( '42', ctx( 'node-a', '10000000c9aa' ) ); 1 } or $err = $@;
    is( ref $err && $err->code, 'conflict', 'foreign WWN => conflict (fail closed)' );
    ok( !$err->is_retryable, 'conflict is NOT retryable' );
    is( $f->{calls}{map_lun} // 0, 0, 'nothing mapped' );
};

subtest 'publish_lu SAFETY GATE: transient host-wwn read => array_busy (retryable, not fail-closed)' => sub {
    my $f = FakeRest->new;
    my $d = drv($f);
    $d->ensure_host_access( ctx( 'node-a', '10000000c9aa' ) );
    my $err;
    {
        no warnings 'redefine';
        # The FRESH ownership read glitches (the same shared-array load that 503s).
        local *FakeRest::list_host_wwns =
            sub { die "API request failed: GET /host-wwns -> 503 Service Unavailable\n" };
        eval { $d->publish_lu( '42', ctx( 'node-a', '10000000c9aa' ) ); 1 } or $err = $@;
    }
    is( ref $err && $err->code, 'array_busy', 'transient read => array_busy, NOT conflict' );
    ok( $err->is_retryable, 'array_busy is retryable (core retries; no prod outage on a glitch)' );
    is( $f->{calls}{map_lun} // 0, 0, 'nothing mapped on an unverified group' );
};

subtest 'unpublish_lu SAFETY GATE: never unmaps paths in a group we no longer own' => sub {
    my $f = FakeRest->new;
    my $d = drv($f);
    $d->ensure_host_access( ctx( 'node-a', '10000000c9aa' ) );
    $d->publish_lu( '42', ctx( 'node-a', '10000000c9aa' ) );
    my $unmaps = $f->{calls}{unmap_lun} // 0;
    # Both ports' groups get a foreign WWN (number reuse) before teardown.
    $f->{hgs}{'CL1-A,0'}{wwns}{'2100000000ffff'} = 1;
    $f->{hgs}{'CL2-A,0'}{wwns}{'2100000000ffff'} = 1;
    $d->unpublish_lu( '42', ctx( 'node-a', '10000000c9aa' ) );
    is( $f->{calls}{unmap_lun} // 0, $unmaps, 'no unmap on the now-foreign groups (skipped, not touched)' );
};

subtest '#2 adopts a group stored under the array-TRUNCATED name, no O(N) WWN scan' => sub {
    my $f = FakeRest->new;
    my $d = drv($f);
    # The array's list view truncated PVE_dev-mp01-pve-03 (19) to PVE_dev-mp01-pve (16);
    # the group holds THIS node's WWN.
    for my $p ( 'CL1-A', 'CL2-A' ) {
        $f->create_host_group( port_id => $p, host_group_name => 'PVE_dev-mp01-pve', host_mode_options => [] );
        $f->{hgs}{"$p,0"}{wwns}{'10000000c9aa'} = 1;
    }
    my $before = $f->{calls}{find_host_group_by_wwn} // 0;
    is( $d->ensure_host_access( ctx( 'dev-mp01-pve-03', '10000000c9aa' ) ),
        'PVE_dev-mp01-pve', 'adopted the truncated-name group' );
    is( $f->{calls}{create_host_group}, 2, 'no new group created — existing truncated group adopted' );
    is( $f->{calls}{find_host_group_by_wwn} // 0, $before,
        'resolved via the truncated-name pre-filter — the O(host-groups) WWN scan never ran' );
};

subtest '#2 does NOT adopt a same-truncation group owned by ANOTHER node (clean miss -> create)' => sub {
    my $f = FakeRest->new;
    my $d = drv($f);
    # node-04's group truncates to the SAME 16 chars but holds only node-04's WWN.
    for my $p ( 'CL1-A', 'CL2-A' ) {
        $f->create_host_group( port_id => $p, host_group_name => 'PVE_dev-mp01-pve', host_mode_options => [] );
        $f->{hgs}{"$p,0"}{wwns}{'2100000000ff04'} = 1;   # node-04's WWN, foreign to us
    }
    my $ref = eval { $d->ensure_host_access( ctx( 'dev-mp01-pve-03', '10000000c9aa' ) ) };
    ok( !$@, 'no FALSE conflict — the foreign same-truncation group was skipped, not adopted' )
        or diag($@);
    is( $f->{calls}{create_host_group}, 4, 'created THIS node\'s own group per port (2 new + 2 pre-existing foreign)' );
    ok( $f->find_host_group_by_name( 'CL1-A', 'PVE_dev-mp01-pve-03' ), 'our own full-named group exists' );
};

subtest '#2 a MIXED-ownership truncated group (ours + foreign) is rejected by the WWN gate, no map' => sub {
    my $f = FakeRest->new;
    my $d = drv($f);
    # A truncated-name group holds one of OUR WWNs (so the #2 pre-filter selects it) but
    # ALSO a foreign one — the fresh-WWN ownership gate must fail closed, never map.
    for my $p ( 'CL1-A', 'CL2-A' ) {
        $f->create_host_group( port_id => $p, host_group_name => 'PVE_dev-mp01-pve', host_mode_options => [] );
        $f->{hgs}{"$p,0"}{wwns}{'10000000c9aa'}   = 1;   # ours
        $f->{hgs}{"$p,0"}{wwns}{'2100000000ff04'} = 1;   # foreign
    }
    my $err;
    eval { $d->publish_lu( '42', ctx( 'dev-mp01-pve-03', '10000000c9aa' ) ); 1 } or $err = $@;
    is( ref $err && $err->code, 'conflict',
        'pre-filter selects the group, the fresh-WWN gate rejects the foreign initiator' );
    is( $f->{calls}{map_lun} // 0, 0, 'nothing mapped into the mixed-ownership group' );
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

subtest 'unpublish_lu resolves the node group by NAME (no per-group WWN scan)' => sub {
    my $f = FakeRest->new;
    my $d = drv($f);
    $d->publish_lu( '42', ctx( 'node-a', '10000000c9aa' ) );   # creates PVE_node-a
    $f->{calls}{find_host_group_by_wwn} = 0;                    # reset the scan counter
    $d->unpublish_lu( '42', ctx( 'node-a', '10000000c9aa' ) );
    is( $f->{calls}{find_host_group_by_wwn} // 0, 0,
        'unpublish resolves by canonical name — no O(host-groups) WWN scan' );
};

subtest 'unpublish_lu_all reaps EVERY node mapping (crashed-migration cleanup)' => sub {
    my $f = FakeRest->new;
    my $d = drv($f);
    $d->publish_lu( '42', ctx( 'node-a', '10000000c9aa' ) );
    $d->publish_lu( '42', ctx( 'node-b', '10000000c9bb' ) );
    my %n0 = map { $_->{hostname} => 1 } @{ $d->list_lu_mappings('42') };
    is( scalar keys %n0, 2, 'mapped on two nodes to start' );

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
    my @nodes = sort keys %{ { map { $_->{hostname} => 1 } @$maps } };
    is_deeply( \@nodes, [ 'node-a', 'node-b' ],
        'both nodes surface (deduped from the per-host-group-path entries)' );
    ok( defined $maps->[0]{access_ref}, 'access_ref present (MUST)' );
    ok( defined $maps->[0]{host_group}, 'host_group number present (exact id, truncation-proof)' );

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

subtest 'list_lu_mappings does NOT collapse groups the array truncated to one name' => sub {
    # The array truncates long host group names, so two DIFFERENT nodes can end up with
    # the SAME stored name (PVE_dev-mp01-pve-03/-04 -> "PVE_dev-mp01-pve"). Keying by
    # name would hide a node's mapping; the (port,hostGroupNumber) composite keeps both.
    my $f = FakeRest->new;
    $f->{ldevs}{'88'} = 1;
    $f->{hgs}{'CL1-A,2'} = { portId => 'CL1-A', hostGroupNumber => 2, hostGroupName => 'PVE_trunc', wwns => {} };
    $f->{hgs}{'CL1-A,3'} = { portId => 'CL1-A', hostGroupNumber => 3, hostGroupName => 'PVE_trunc', wwns => {} };
    push @{ $f->{luns} },
        { lunId => 'La', portId => 'CL1-A', hostGroupNumber => 2, ldevId => '88', lun => 1 },
        { lunId => 'Lb', portId => 'CL1-A', hostGroupNumber => 3, ldevId => '88', lun => 2 };
    my $d = drv($f);

    my $maps = $d->list_lu_mappings('88');
    is( scalar @$maps, 2, 'both truncated-name groups reported (NOT collapsed to one)' );
    is_deeply( [ sort { $a <=> $b } map { $_->{host_group} } @$maps ], [ 2, 3 ],
        'distinct host-group numbers preserved as the exact identifier' );
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
