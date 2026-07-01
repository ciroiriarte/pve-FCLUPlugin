package FCLU::ContractTest;

use strict;
use warnings;

use Test::More;
use Exporter 'import';

use PVE::Storage::FCLU::Driver;
use PVE::Storage::FCLU::Capabilities;

our @EXPORT_OK = qw(run_contract_tests);

# The parametrized conformance suite for fclu-driver-api-1 (ARCHITECTURE.md §12.5).
# Passing it IS the definition of "conforms to api-1". It is driver-agnostic: a
# caller passes a factory that returns a FRESH, connected, EMPTY driver, and the
# same assertions run against Mock today and Driver::Hitachi / Driver::Pure later.
#
#   run_contract_tests(
#       name    => 'Mock',
#       factory => sub { PVE::Storage::FCLU::Driver::Mock->new },
#   );
#
# Assertions cover the §12.1 data shapes and the §12.2 idempotency/retry table.
# Capability-gated areas (snapshots, clones, qos) are skipped unless the driver's
# capabilities() advertises them — an array legitimately lacking a feature is not
# non-conformant for it.

my $CAP = 'PVE::Storage::FCLU::Capabilities';

# Local Try::Tiny-free exception capture: returns the error (or undef on success).
sub _exception {
    my ($code) = @_;
    my $err;
    { local $@; eval { $code->(); 1 } or $err = $@; }
    return $err;
}

sub _host_ctx {
    my ($hostname, @wwpns) = @_;
    # Distinct WWPN per hostname: real PVE nodes never share FC initiators, and a
    # driver that resolves host objects BY WWN (Hitachi) must see two nodes as two
    # groups. Derive a deterministic 16-hex wwpn from the hostname (6 chars of it,
    # enough to separate node-a/node-b). Drivers that key host access by hostname
    # (Mock) are unaffected.
    unless (@wwpns) {
        my $h = unpack( 'H*', $hostname ) . ( '0' x 12 );
        @wwpns = ( '1000' . substr( $h, 0, 12 ) );
    }
    return ( hostname => $hostname, protocol => 'scsi-fc', initiators => [@wwpns] );
}

# Assert a thrown value is a conformant FCLU::Error (§12.4/§13): blessed, with a
# closed-vocabulary code and strict-0|1 classification booleans. Returns the code.
sub _assert_fclu_error {
    my ($err, $label) = @_;
    isa_ok( $err, 'PVE::Storage::FCLU::Error', "$label: dies with FCLU::Error" );
    return undef unless ref $err && $err->isa('PVE::Storage::FCLU::Error');
    my %codes = map { $_ => 1 } PVE::Storage::FCLU::Error->codes;
    ok( $codes{ $err->code }, "$label: code '" . $err->code . "' is in the closed vocab" );
    like( $err->is_retryable, qr/^[01]$/, "$label: retryable is 0|1" );
    like( $err->is_transient, qr/^[01]$/, "$label: transient is 0|1" );
    return $err->code;
}

sub run_contract_tests {
    my (%opts) = @_;
    my $name    = $opts{name}    // 'driver';
    my $factory = $opts{factory} or die "run_contract_tests: 'factory' required\n";

    subtest "[$name] is a Driver implementing the whole surface" => sub {
        my $d = $factory->();
        isa_ok( $d, 'PVE::Storage::FCLU::Driver', $name );
        for my $m ( PVE::Storage::FCLU::Driver->contract_methods ) {
            ok( $d->can($m), "$m present" );
        }
    };

    subtest "[$name] capabilities() is a conformant §6 object" => sub {
        my $cap = $factory->()->capabilities;
        is( ref $cap, 'HASH', 'capabilities returns a hash' );
        for my $branch ( $CAP->branches ) {
            is( ref $cap->{$branch}, 'HASH', "branch '$branch' present and a hash" );
        }
        # Every leaf is strict 0|1.
        my @bad = grep { $_ ne '0' && $_ ne '1' } map { values %$_ } values %$cap;
        is( scalar @bad, 0, 'every advertised leaf is strict 0|1' );
    };

    subtest "[$name] create_lu / get_lu / list_lus shapes (§12.1)" => sub {
        my $d   = $factory->();
        my $bid = $d->create_lu( size_bytes => 1 << 30, label => 'pve:s:vm-1-disk-0' );

        like( $bid, qr/^[\w.:-]{1,255}$/, 'backend_id obeys the api-1 charset' );

        my $lu = $d->get_lu($bid);
        is( ref $lu, 'HASH', 'get_lu returns a hash' );
        is( $lu->{backend_id}, $bid, 'backend_id round-trips' );
        like( $lu->{size_bytes}, qr/^[0-9]+$/, 'size_bytes is an integer' );
        is( $lu->{size_bytes}, 1 << 30, 'size_bytes is bytes, exact' );
        ok( exists $lu->{label},    'label key present (may be undef)' );
        ok( defined $lu->{pool_ref}, 'pool_ref present' );

        my $found = grep { $_->{backend_id} eq $bid } @{ $d->list_lus };
        ok( $found, 'list_lus includes the created LU (orphan-scan completeness)' );

        $d->delete_lu($bid);
    };

    subtest "[$name] identity shape: ≥1 array-reported lowercase-hex id (§12.1)" => sub {
        my $d   = $factory->();
        my $bid = $d->create_lu( size_bytes => 1 << 30 );
        my $id  = $d->get_lu_identity($bid);
        is( ref $id, 'HASH', 'identity is a hash' );
        ok( defined $id->{protocol}, 'identity.protocol present' );
        is( ref $id->{ids}, 'HASH', 'identity.ids is a hash' );
        my @set = grep { defined $id->{ids}{$_} } qw(naa eui wwid);
        ok( scalar @set >= 1, 'at least one of naa/eui/wwid is set' );
        for my $k (@set) {
            like( $id->{ids}{$k}, qr/^[0-9a-f]+$/, "$k is lowercase hex" );
        }
        $d->delete_lu($bid);
    };

    subtest "[$name] create_lu is allocating; requested_id makes it retry-safe (§12.2)" => sub {
        my $d = $factory->();

        # No requested_id => two creates are DISTINCT (allocating, not idempotent).
        my $a = $d->create_lu( size_bytes => 1 << 30 );
        my $b = $d->create_lu( size_bytes => 1 << 30 );
        isnt( $a, $b, 'distinct allocations get distinct ids' );

        # requested_id + matching attrs => same id returned (crash-retry safe).
        my $r1 = $d->create_lu( size_bytes => 1 << 30, requested_id => 'reasrt-1', label => 'L' );
        my $r2 = $d->create_lu( size_bytes => 1 << 30, requested_id => 'reasrt-1', label => 'L' );
        is( $r1, 'reasrt-1', 'requested_id honoured' );
        is( $r2, $r1, 're-assert with matching attrs returns the same id' );

        # requested_id + MISMATCHED attrs => already_exists.
        my $e = _exception( sub {
            $d->create_lu( size_bytes => 2 << 30, requested_id => 'reasrt-1', label => 'L' );
        } );
        is( _assert_fclu_error( $e, 'mismatched re-assert' ), 'already_exists',
            'mismatched requested_id => already_exists' );
    };

    subtest "[$name] delete_lu is idempotent teardown — no not_found (§12.2/§13.3)" => sub {
        my $d   = $factory->();
        my $bid = $d->create_lu( size_bytes => 1 << 30 );

        ok( !_exception( sub { $d->delete_lu($bid) } ), 'first delete succeeds' );
        ok( !_exception( sub { $d->delete_lu($bid) } ), 'second delete is a no-op success' );
        ok( !_exception( sub { $d->delete_lu('never-existed') } ),
            'deleting an absent LU is success, never not_found' );
    };

    subtest "[$name] get_lu on a missing LU raises not_found (§13.3)" => sub {
        my $d = $factory->();
        my $e = _exception( sub { $d->get_lu('does-not-exist') } );
        is( _assert_fclu_error( $e, 'get_lu missing' ), 'not_found',
            'read of an absent LU => not_found' );
    };

    subtest "[$name] set_lu_label / resize_lu converge idempotently (§12.2)" => sub {
        my $d   = $factory->();
        my $bid = $d->create_lu( size_bytes => 1 << 30, label => 'first' );

        $d->set_lu_label( $bid, 'second' );
        is( $d->get_lu($bid)->{label}, 'second', 'label converged' );
        ok( !_exception( sub { $d->set_lu_label( $bid, 'second' ) } ),
            'setting the same label again is a no-op success' );

        $d->resize_lu( $bid, 2 << 30 );
        is( $d->get_lu($bid)->{size_bytes}, 2 << 30, 'resize grew the LU' );
        ok( !_exception( sub { $d->resize_lu( $bid, 2 << 30 ) } ),
            'resize to the current size is a no-op success' );
        $d->delete_lu($bid);
    };

    subtest "[$name] host access: idempotent, node-targeted, authoritative mappings (§12.2/§12.3)" => sub {
        my $d   = $factory->();
        my $bid = $d->create_lu( size_bytes => 1 << 30 );

        # ensure_host_access idempotent: same handle, no error on repeat.
        my $h1 = $d->ensure_host_access( _host_ctx('node-a') );
        my $h2 = $d->ensure_host_access( _host_ctx('node-a') );
        ok( defined $h1, 'ensure_host_access returns a handle' );
        is( $h2, $h1, 'ensure_host_access is idempotent (same handle)' );

        # publish_lu idempotent: same mapping returned, no error.
        my $m1 = $d->publish_lu( $bid, _host_ctx('node-a') );
        my $m2 = $d->publish_lu( $bid, _host_ctx('node-a') );
        is( ref $m1, 'HASH', 'publish_lu returns a mapping' );
        ok( defined $m1->{hostname} && defined $m1->{access_ref},
            'mapping has required hostname + access_ref (§12.1)' );
        is( $m2->{hostname}, $m1->{hostname}, 'republish returns the existing mapping' );

        # Publish to a second node; mappings list is authoritative for both.
        $d->publish_lu( $bid, _host_ctx('node-b') );
        my %mapped = map { $_->{hostname} => $_ } @{ $d->list_lu_mappings($bid) };
        ok( $mapped{'node-a'} && $mapped{'node-b'}, 'both nodes appear in list_lu_mappings' );
        # SHOULD fields, checked only when present.
        for my $h ( sort keys %mapped ) {
            if ( defined $mapped{$h}{target_wwpns} ) {
                like( $_, qr/^[0-9a-f]+$/, "$h target wwpn lowercase hex" )
                    for @{ $mapped{$h}{target_wwpns} };
            }
        }

        # unpublish only the named node; the other survives (live-migration rule).
        $d->unpublish_lu( $bid, _host_ctx('node-a') );
        %mapped = map { $_->{hostname} => $_ } @{ $d->list_lu_mappings($bid) };
        ok( !$mapped{'node-a'}, 'unpublished node is gone from mappings' );
        ok( $mapped{'node-b'},  'other node mapping is left intact' );

        # unpublish is idempotent: removing an already-absent node is success.
        ok( !_exception( sub { $d->unpublish_lu( $bid, _host_ctx('node-a') ) } ),
            'unpublish of an unmapped node is a no-op success' );

        $d->delete_lu($bid);
    };

    subtest "[$name] target_ports shape (§12.1/§14)" => sub {
        my $ports = $factory->()->target_ports;
        is( ref $ports, 'ARRAY', 'target_ports is an arrayref' );
        for my $p (@$ports) {
            # An endpoint MUST identify a port; wwpn is a fabric-zoning (§14) concern
            # a pre-fabric driver may not resolve yet, so port_id alone is conformant.
            ok( defined $p->{wwpn} || defined $p->{port_id},
                'endpoint identifies a port (wwpn or port_id)' );
            like( $p->{wwpn}, qr/^[0-9a-f]+$/, 'wwpn lowercase hex when present' )
                if defined $p->{wwpn};
        }
    };

    subtest "[$name] snapshots (capability-gated, §6/§12.2)" => sub {
        my $d   = $factory->();
        my $cap = $d->capabilities;
      SKIP: {
            skip 'snapshot.single not advertised', 1
                unless $CAP->has_feature( $cap, 'snapshot', 'single' );

            my $bid  = $d->create_lu( size_bytes => 1 << 30 );
            my $snap = $d->create_snapshot($bid);
            is( ref $snap, 'HASH', 'create_snapshot returns a descriptor' );
            ok( defined $snap->{snap_id},           'snap_id present' );
            is( $snap->{parent_backend_id}, $bid,   'parent_backend_id present' );
            ok( exists $snap->{created} && exists $snap->{meta}, 'created + meta present' );

            # snap_id re-assert: same parent => success.
            my $re = $d->create_snapshot( $bid, snap_id => $snap->{snap_id} );
            is( $re->{snap_id}, $snap->{snap_id}, 'snap_id re-assert returns the same snapshot' );

            my $found = grep { $_->{snap_id} eq $snap->{snap_id} } @{ $d->list_snapshots($bid) };
            ok( $found, 'list_snapshots includes it' );

            # delete_snapshot idempotent.
            ok( !_exception( sub { $d->delete_snapshot( $snap->{snap_id} ) } ), 'delete snapshot' );
            ok( !_exception( sub { $d->delete_snapshot( $snap->{snap_id} ) } ),
                'delete snapshot again is a no-op success' );
            $d->delete_lu($bid);
        }
    };

    subtest "[$name] linked clone (capability-gated, §6)" => sub {
        my $d   = $factory->();
        my $cap = $d->capabilities;
      SKIP: {
            skip 'clone.linked not advertised', 1
                unless $CAP->has_feature( $cap, 'clone', 'linked' );

            my $bid   = $d->create_lu( size_bytes => 1 << 30 );
            # host_ctx is part of the §2 create_linked_clone contract: a driver whose
            # array requires the S-VOL to be mapped before binding it to the pair (#24)
            # needs it. Drivers that do not still accept it.
            my $clone = $d->create_linked_clone( $bid, host_ctx => { _host_ctx('node-a') } );
            like( $clone, qr/^[\w.:-]{1,255}$/, 'clone backend_id obeys charset' );
            isnt( $clone, $bid, 'clone is a distinct LU' );
            ok( $d->get_lu($clone), 'clone is gettable' );
            $d->delete_lu($_) for $clone, $bid;
        }
    };
}

1;
