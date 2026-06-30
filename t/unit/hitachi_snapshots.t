#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use lib 'src';
use lib 't/lib';
use FCLU::FakeHitachiRest;
use PVE::Storage::FCLU::Driver::Hitachi;

# §9 Phase 1 step 3 (slice C): Driver::Hitachi Thin Image snapshot/clone + QoS.
# Covers the specifics the conformance suite doesn't drill into — the restore
# re-split (#12) sequence, CG snapshots, QoS round-trip, and the clone S-VOL
# allocation — against the stateful FakeHitachiRest.

use constant { GIB => 1073741824 };

sub setup {
    my $f = FCLU::FakeHitachiRest->new;
    my $d = PVE::Storage::FCLU::Driver::Hitachi->new(
        platform => 'vsp_e', rest => $f, pool_id => '63', snap_pool_id => '63' );
    $d->{_snap_poll_interval} = 0;   # fast status waits in tests
    return ( $d, $f );
}

subtest 'create_snapshot returns a §12.1 descriptor; re-assert is idempotent' => sub {
    my ( $d, $f ) = setup();
    my $bid = $d->create_lu( size_bytes => GIB );

    my $s = $d->create_snapshot($bid);
    ok( defined $s->{snap_id}, 'snap_id present' );
    is( $s->{parent_backend_id}, $bid, 'parent backend id' );
    ok( exists $s->{created} && exists $s->{meta}, 'created + meta keys present' );
    is( $s->{meta}{status}, 'PSUS', 'autoSplit snapshot is PSUS' );

    my $again = $d->create_snapshot( $bid, snap_id => $s->{snap_id} );
    is( $again->{snap_id}, $s->{snap_id}, 're-assert returns the same pair' );
    is( scalar @{ $d->list_snapshots($bid) }, 1, 're-assert created no second pair' );
};

subtest 'delete_snapshot is idempotent' => sub {
    my ( $d, $f ) = setup();
    my $bid = $d->create_lu( size_bytes => GIB );
    my $s = $d->create_snapshot($bid);
    is( $d->delete_snapshot( $s->{snap_id} ), 1, 'delete' );
    is( $d->delete_snapshot( $s->{snap_id} ), 1, 'delete again => success' );
    is( scalar @{ $d->list_snapshots($bid) }, 0, 'gone' );
};

subtest 'restore_snapshot restores then re-splits (PSUS)' => sub {
    my ( $d, $f ) = setup();
    my $bid = $d->create_lu( size_bytes => GIB );
    my $s = $d->create_snapshot($bid);

    is( $d->restore_snapshot( $s->{snap_id} ), 1, 'restore returns success' );
    is( $f->{calls}{restore_snapshot}, 1, 'restore invoked' );
    is( $f->{calls}{split_snapshot},   1, 're-split invoked (so the pair stays re-restorable, #12)' );
    is( $f->{snaps}{ $s->{snap_id} }{status}, 'PSUS', 'settled back to PSUS' );
};

subtest 'create_cg_snapshot snapshots every LU under one group' => sub {
    my ( $d, $f ) = setup();
    my $a = $d->create_lu( size_bytes => GIB );
    my $b = $d->create_lu( size_bytes => GIB );

    my $snaps = $d->create_cg_snapshot( [ $a, $b ], snapshot_group => 'cg1' );
    is( scalar @$snaps, 2, 'one descriptor per LU' );
    is_deeply( [ sort map { $_->{parent_backend_id} } @$snaps ], [ sort $a, $b ], 'both parents' );
    is( $snaps->[0]{meta}{group}, 'cg1', 'shared CG group name' );
};

subtest 'QoS round-trip' => sub {
    my ( $d, $f ) = setup();
    my $bid = $d->create_lu( size_bytes => GIB );
    $d->set_lu_qos( $bid, { upper_iops => 5000, upper_mbps => 200 } );
    my $q = $d->get_lu_qos($bid);
    is( $q->{upper_iops}, 5000, 'upper_iops persisted' );
    is( $q->{upper_mbps}, 200,  'upper_mbps persisted' );

    eval { $d->set_lu_qos( $bid, {} ) };
    like( $@->message, qr/non-empty hashref/, 'empty qos rejected' );
};

subtest 'create_linked_clone allocates an S-VOL + binds a CoW pair' => sub {
    my ( $d, $f ) = setup();
    my $bid = $d->create_lu( size_bytes => GIB );

    my $clone = $d->create_linked_clone($bid);
    isnt( $clone, $bid, 'clone is a distinct LU' );
    ok( $d->get_lu($clone), 'clone ldev is gettable' );
    # The clone S-VOL is sized to the parent.
    is( $d->get_lu($clone)->{size_bytes}, GIB, 'clone sized to parent' );
    # A Thin Image pair binds parent -> clone.
    my ($pair) = @{ $d->list_snapshots($bid) };
    is( $pair->{meta}{svol}, $clone, 'pair S-VOL is the clone' );
};

subtest 'create_full_clone uses the clone (full-copy) path' => sub {
    my ( $d, $f ) = setup();
    my $bid = $d->create_lu( size_bytes => GIB );
    my $clone = $d->create_full_clone($bid);
    isnt( $clone, $bid, 'distinct LU' );
    is( $f->{calls}{clone_snapshot_to_ldev}, 1, 'used clone_snapshot_to_ldev (isClone)' );
};

done_testing();
