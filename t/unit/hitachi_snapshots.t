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

subtest 'N1: plain + CG snapshots set canCascade + isDataReductionForceCopy' => sub {
    my ( $d, $f ) = setup();
    my $bid = $d->create_lu( size_bytes => GIB );
    my $s = $d->create_snapshot($bid);
    ok( $f->{snaps}{ $s->{snap_id} }{can_cascade}, 'plain snapshot sets canCascade' );
    ok( $f->{snaps}{ $s->{snap_id} }{is_dr_force}, 'plain snapshot sets isDataReductionForceCopy' );
    my $a = $d->create_lu( size_bytes => GIB );
    my $b = $d->create_lu( size_bytes => GIB );
    my $cg = $d->create_cg_snapshot( [ $a, $b ], snapshot_group => 'cg9' );
    ok( $f->{snaps}{ $cg->[0]{snap_id} }{can_cascade}, 'CG snapshot sets canCascade' );
    ok( $f->{snaps}{ $cg->[0]{snap_id} }{is_dr_force}, 'CG snapshot sets isDataReductionForceCopy' );
};

subtest 'N3: restore refuses a pair whose P-VOL is not the target' => sub {
    my ( $d, $f ) = setup();
    my $bid = $d->create_lu( size_bytes => GIB );
    my $s = $d->create_snapshot($bid);
    is( $d->restore_snapshot( $s->{snap_id}, pvol => $bid ), 1, 'matching P-VOL restores' );
    my $err;
    eval { $d->restore_snapshot( $s->{snap_id}, pvol => '999999' ); 1 } or $err = $@;
    is( ref $err && $err->code, 'invalid', 'foreign P-VOL refused' );
};

subtest 'N2: restore that never reaches PAIR fails and does NOT split' => sub {
    my ( $d, $f ) = setup();
    my $bid = $d->create_lu( size_bytes => GIB );
    my $s = $d->create_snapshot($bid);
    my $err;
    {
        no warnings 'redefine';
        # restore leaves the pair un-PAIRed (reverse copy still running past the budget).
        local *FCLU::FakeHitachiRest::restore_snapshot = sub { 1 };
        eval { $d->restore_snapshot( $s->{snap_id} ); 1 } or $err = $err = $@;
    }
    is( ref $err && $err->code, 'timeout', 'non-convergent restore => timeout' );
    ok( !$f->{calls}{split_snapshot}, 'the pair was NOT split mid-restore (no torn P-VOL)' );
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

subtest 'create_cg_snapshot is crash-consistent: one group, single atomic split' => sub {
    my ( $d, $f ) = setup();
    my $a = $d->create_lu( size_bytes => GIB );
    my $b = $d->create_lu( size_bytes => GIB );

    my $snaps = $d->create_cg_snapshot( [ $a, $b ], snapshot_group => 'cg1' );
    is( scalar @$snaps, 2, 'one descriptor per LU' );
    is_deeply( [ sort map { $_->{parent_backend_id} } @$snaps ], [ sort $a, $b ], 'both parents' );
    is( $snaps->[0]{meta}{group}, 'cg1', 'shared CG group name' );

    # Crash-consistency: pairs created UNSPLIT (auto_split off) then split as ONE group
    # in a single action — NOT one autoSplit-per-pair (which froze each S-VOL at a
    # different instant). So exactly one group-split call, and no per-pair splits.
    is( $f->{calls}{split_snapshotgroup}, 1, 'the whole group is split in a single action' );
    ok( !$f->{calls}{split_snapshot}, 'no per-pair splits (would break crash-consistency)' );
    is( $f->{snaps}{ $snaps->[0]{snap_id} }{status}, 'PSUS', 'both S-VOLs suspended after the group split' );
    is( $f->{snaps}{ $snaps->[1]{snap_id} }{status}, 'PSUS', 'both S-VOLs suspended after the group split' );

    # A default (unnamed) CG derives a unique group name so concurrent CGs never collide.
    my $c = $d->create_lu( size_bytes => GIB );
    my $auto = $d->create_cg_snapshot( [$c] );
    like( $auto->[0]{meta}{group}, qr/^pveC/, 'unnamed CG derives a unique pveC<...> group' );
    isnt( $auto->[0]{meta}{group}, 'cg1', 'and it does not collide with a prior group' );
};

subtest 'create_cg_snapshot sweeps created pairs if the group split fails (no leak)' => sub {
    my ( $d, $f ) = setup();
    my $a = $d->create_lu( size_bytes => GIB );
    my $b = $d->create_lu( size_bytes => GIB );
    my $err;
    {
        no warnings 'redefine';
        local *FCLU::FakeHitachiRest::split_snapshotgroup =
            sub { die "API request failed: POST /snapshot-groups/cgX/actions/split -> 400 KART\n" };
        local $SIG{__WARN__} = sub { };
        eval { $d->create_cg_snapshot( [ $a, $b ], snapshot_group => 'cgX' ); 1 } or $err = $@;
    }
    ok( $err, 'CG snapshot fails when the group split fails' );
    is( scalar @{ $d->list_snapshots($a) }, 0, 'pair on A swept (no orphan)' );
    is( scalar @{ $d->list_snapshots($b) }, 0, 'pair on B swept (no orphan)' );
};

subtest 'wait_pair_released waits until the pair object is gone (#3 SMPP guard)' => sub {
    my ( $d, $f ) = setup();
    my $bid = $d->create_lu( size_bytes => GIB );
    my $s = $d->create_snapshot($bid);

    # Pair still present → probe-once (interval 0) reports not-yet-released.
    is( $d->wait_pair_released( $s->{snap_id} ), 0, 'still present → 0' );
    # Once the pair delete lands, get_snapshot 404s → released.
    $d->delete_snapshot( $s->{snap_id} );
    is( $d->wait_pair_released( $s->{snap_id} ), 1, 'gone → 1' );
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

subtest 'create_linked_clone: single-step pair with svolLdevId (DP S-VOL, no map/assign)' => sub {
    my ( $d, $f ) = setup();
    my $bid = $d->create_lu( size_bytes => GIB );

    # No host_ctx needed: the pair is created with svolLdevId + canCascade +
    # isDataReductionForceCopy, binding the S-VOL at creation with neither vol mapped.
    my $clone = $d->create_linked_clone($bid);
    isnt( $clone, $bid, 'clone is a distinct LU' );
    ok( $d->get_lu($clone), 'clone ldev is gettable' );
    is( $d->get_lu($clone)->{size_bytes}, GIB, 'clone sized to parent' );

    # The S-VOL is a DP volume from the pool (NOT a poolId -1 v-vol).
    is( $f->{ldevs}{$clone}{poolId}, '63', 'S-VOL is a DP volume from the pool' );
    # One-step pair creation — no separate assign_snapshot_volume, no host mapping.
    ok( !$f->{calls}{assign_snapshot_volume}, 'no assign_snapshot_volume (single-step pair)' );
    ok( !$f->{calls}{ensure_host_access},     'no host mapping during clone' );
    my ($pair) = @{ $d->list_snapshots($bid) };
    is( $pair->{meta}{svol}, $clone, 'pair S-VOL is the clone (bound at creation)' );

    # host_ctx is accepted for back-compat but ignored (not required).
    my $c2 = $d->create_linked_clone( $bid, host_ctx => { hostname => 'x' } );
    ok( $d->get_lu($c2), 'host_ctx is tolerated (ignored), clone still created' );
};

subtest 'create_full_clone uses the clone (full-copy) path' => sub {
    my ( $d, $f ) = setup();
    my $bid = $d->create_lu( size_bytes => GIB );
    my $clone = $d->create_full_clone($bid);
    isnt( $clone, $bid, 'distinct LU' );
    is( $f->{calls}{clone_snapshot_to_ldev}, 1, 'used clone_snapshot_to_ldev (isClone)' );
};

subtest 'N7: full clone waits for completion and surfaces a PSUE copy failure' => sub {
    my ( $d, $f ) = setup();
    my $bid = $d->create_lu( size_bytes => GIB );
    # Happy path: the fake isClone leaves no lingering pair -> completion resolves cleanly.
    my $c = $d->create_full_clone($bid);
    ok( $d->get_lu($c), 'clone LU created' );
    # PSUE: the source shows a copy-failed pair under the clone group.
    my $err;
    {
        no warnings 'redefine';
        local *FCLU::FakeHitachiRest::list_snapshots = sub {
            return [ { snapshotId => 'x,9', snapshotGroupName => 'pve_clone',
                       status => 'PSUE', pvolLdevId => 'x' } ];
        };
        eval { $d->create_full_clone( $bid, snapshot_group => 'pve_clone' ); 1 } or $err = $@;
    }
    is( ref $err && $err->code, 'internal', 'PSUE copy failure surfaced as an error' );
};

done_testing();
