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

subtest '#3: N linked clones share ONE base LU as P-VOL, no per-clone base snapshot' => sub {
    my ( $d, $f ) = setup();
    my $base = $d->create_lu( size_bytes => GIB );

    # Three linked clones off the SAME template LU (the create_base model: the base IS
    # the LU, relabelled read-only; clones bind directly onto it — no base snapshot).
    my @clones = map { $d->create_linked_clone($base) } 1 .. 3;
    is( scalar( grep { defined } @clones ), 3, 'three clones created' );

    # Exactly N pairs, every one anchored on the ONE shared base as its P-VOL — not a
    # per-clone intermediate base snapshot (which would multiply objects on the array).
    my $pairs = $d->list_snapshots($base);
    is( scalar @$pairs, 3, 'exactly N pairs on the base (one per clone)' );
    is_deeply( [ map { $_->{parent_backend_id} } @$pairs ], [ ("$base") x 3 ],
        'all N pairs share the single base LU as P-VOL' );
    is_deeply( [ sort map { $_->{meta}{svol} // '' } @$pairs ], [ sort @clones ],
        'each pair binds a distinct clone S-VOL (the clones, exactly)' );

    # No hidden intermediate object: the only LDEVs are the base + its N clones. This is
    # the object-minimal shared-base model — zero dedicated base-snapshot LDEVs (#3 AC1).
    is( scalar keys %{ $f->{ldevs} }, 1 + 3,
        'only base + N clones exist — zero intermediate/base-snapshot LDEVs' );

    # Each clone is an independent writable DP volume from the pool (CoW from the base).
    is( $f->{ldevs}{$_}{poolId}, '63', "clone $_ is a DP volume from the pool" )
        for @clones;
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

subtest 'grouped full clone: prepare is idle, one group action starts every pair' => sub {
    my ( $d, $f ) = setup();
    my $a = $d->create_lu( size_bytes => GIB );
    my $b = $d->create_lu( size_bytes => GIB );
    my $grp = 'pveRoleA';

    my $sa = $d->prepare_full_clone( $a, snapshot_group => $grp );
    my $sb = $d->prepare_full_clone( $b, snapshot_group => $grp );
    isnt( $sa, $sb, 'each prepare allocated its own S-VOL' );
    is( $f->{calls}{clone_snapshot_to_ldev}, 2, 'one pair created per disk' );

    # The array rejects a consistency group with autoSplit on, so the driver must ask
    # for the grouped shape -- otherwise each pair would fire at its own instant.
    ok( $f->{last_clone_opts}{is_consistency_group}, 'pairs created as a consistency group' );

    # Nothing has copied yet: prepare must not move data, so the freeze can be entered
    # after every disk is prepared.
    ok( !$f->{calls}{clone_snapshotgroup}, 'prepare did not trigger the group' );
    is( $d->clone_copy_state( $a, $grp, $sa ), 'pending', 'disk A idle before trigger' );
    is( $d->clone_copy_state( $b, $grp, $sb ), 'pending', 'disk B idle before trigger' );

    # ONE action for the whole group, regardless of disk count: this is what keeps the
    # guest freeze to a single request.
    ok( $d->start_clone_group($grp), 'group started' );
    is( $f->{calls}{clone_snapshotgroup}, 1, 'exactly one array action for both disks' );

    is( $d->clone_copy_state( $a, $grp, $sa ), 'complete', 'disk A independent' );
    is( $d->clone_copy_state( $b, $grp, $sb ), 'complete', 'disk B independent' );
};

subtest 'grouped full clone: several role groups are independent' => sub {
    my ( $d, $f ) = setup();
    my $a = $d->create_lu( size_bytes => GIB );
    my $b = $d->create_lu( size_bytes => GIB );

    my $sa = $d->prepare_full_clone( $a, snapshot_group => 'pveData' );
    my $sb = $d->prepare_full_clone( $b, snapshot_group => 'pveLog' );

    # Triggering one role's group must not start the other's -- disks grouped by role
    # are captured per group, and only the caller's freeze spans them.
    $d->start_clone_group('pveData');
    is( $d->clone_copy_state( $a, 'pveData', $sa ), 'complete', 'triggered group ran' );
    is( $d->clone_copy_state( $b, 'pveLog',  $sb ), 'pending',  'other group untouched' );

    $d->start_clone_group('pveLog');
    is( $d->clone_copy_state( $b, 'pveLog', $sb ), 'complete', 'second group ran' );
};

subtest 'grouped full clone: rollback and argument guards' => sub {
    my ( $d, $f ) = setup();
    my $bid = $d->create_lu( size_bytes => GIB );

    my $err;
    eval { $d->prepare_full_clone($bid); 1 } or $err = $@;
    is( ref $err && $err->code, 'invalid', 'prepare requires a group name' );

    $err = undef;
    eval { $d->start_clone_group(''); 1 } or $err = $@;
    is( ref $err && $err->code, 'invalid', 'start requires a group name' );

    # A failed pair creation must not leak the S-VOL it just allocated on the shared pool.
    my $before = scalar @{ $d->list_lus };
    {
        no warnings 'redefine';
        local *FCLU::FakeHitachiRest::clone_snapshot_to_ldev = sub { die "boom\n" };
        eval { $d->prepare_full_clone( $bid, snapshot_group => 'pveX' ); 1 };
        ok( $@, 'prepare failure surfaced' );
    }
    is( scalar @{ $d->list_lus }, $before, 'unpaired S-VOL was rolled back, not leaked' );
};

subtest 'restore_budget_s covers the reverse copy plus settle, and follows the profile' => sub {
    my ( $d ) = setup();
    is( $d->restore_budget_s, 24 * 3600 + 2 * 600, 'default: 24h restore + two op budgets' );
    $d->profile->{restore_timeout_s} = 48 * 3600;
    is( $d->restore_budget_s, 48 * 3600 + 2 * 600, 'a raised restore_timeout_s raises the budget' );
};

{
    package T::HitachiPaths;   # records host-access calls instead of driving host groups
    our @ISA = ('PVE::Storage::FCLU::Driver::Hitachi');
    sub publish_lu   { my ( $s, $id ) = @_; push @{ $s->{_pub} },   "$id"; die "BOOM map\n" if $s->{_fail_map}; 1 }
    sub unpublish_lu { my ( $s, $id ) = @_; push @{ $s->{_unpub} }, "$id"; 1 }
}
sub setup_paths {
    my $f = FCLU::FakeHitachiRest->new;
    my $d = T::HitachiPaths->new( platform => 'vsp_e', rest => $f, pool_id => '63', snap_pool_id => '63' );
    $d->{_snap_poll_interval} = 0;
    return ( $d, $f );
}
my %HCTX = ( hostname => 'node-x', protocol => 'scsi-fc', initiators => ['10000000c9aa0001'] );

subtest '#27 materialize_snapshot: map, assign, unmap; then idempotent' => sub {
    my ( $d, $f ) = setup_paths();
    my $bid  = $d->create_lu( size_bytes => GIB );
    my $snap = $d->create_snapshot($bid);
    ok( !defined $snap->{meta}{svol}, 'plain snapshot has no S-VOL' );

    my $r = $d->materialize_snapshot( $bid, $snap->{snap_id}, host_ctx => \%HCTX,
        requested_id => 300, label => 'pve:x:vm-1-disk-0_s1' );
    is( $r->{backend_id}, '300', 'S-VOL 300 created and assigned' );
    ok( $r->{created}, '... reported as created' );
    is( $f->{snaps}{ $snap->{snap_id} }{svolLdevId}, '300', 'pair now carries the S-VOL' );
    is_deeply( $d->{_pub}, ['300'], 'S-VOL mapped for the assign' );
    is_deeply( $d->{_unpub}, ['300'], '... and unmapped afterwards' );
    is( $d->get_lu('300')->{size_bytes}, GIB, 'S-VOL sized like the P-VOL' );

    my $again = $d->materialize_snapshot( $bid, $snap->{snap_id}, host_ctx => \%HCTX, requested_id => 301 );
    is_deeply( $again, { backend_id => '300', created => 0 }, 'existing S-VOL reused' );
    ok( !$f->{ldevs}{301}, 'no second LDEV allocated' );

    my $e = eval { $d->materialize_snapshot( 999, $snap->{snap_id}, host_ctx => \%HCTX ); 1 } ? undef : $@;
    like( "$e", qr/not on ldev/, 'wrong P-VOL refused' );
};

subtest '#27 materialize_snapshot: lost race and failures clean up the LDEV' => sub {
    my ( $d, $f ) = setup_paths();
    my $bid  = $d->create_lu( size_bytes => GIB );
    my $snap = $d->create_snapshot($bid);

    # A concurrent caller assigns first: ours is dropped, theirs returned.
    no warnings 'redefine';
    my $orig = \&FCLU::FakeHitachiRest::assign_snapshot_volume;
    local *FCLU::FakeHitachiRest::assign_snapshot_volume = sub {
        my ( $s, $id ) = @_; $s->{snaps}{$id}{svolLdevId} = '310'; die "API request failed: KART30000-E already assigned\n" };
    my $r = $d->materialize_snapshot( $bid, $snap->{snap_id}, host_ctx => \%HCTX, requested_id => 311 );
    is_deeply( $r, { backend_id => '310', created => 0 }, 'winner returned' );
    ok( !$f->{ldevs}{311} || ( $f->{ldevs}{311}{emulationType} // '' ) eq 'NOT DEFINED', 'our LDEV deleted' );

    # Map failure: LDEV deleted, error surfaces, pair untouched.
    my $snap2 = $d->create_snapshot($bid);
    $d->{_fail_map} = 1;
    local *FCLU::FakeHitachiRest::assign_snapshot_volume = $orig;
    my $ok = eval { $d->materialize_snapshot( $bid, $snap2->{snap_id}, host_ctx => \%HCTX, requested_id => 312 ); 1 };
    ok( !$ok, 'map failure surfaces' );
    ok( !$f->{ldevs}{312} || ( $f->{ldevs}{312}{emulationType} // '' ) eq 'NOT DEFINED', 'LDEV deleted after failure' );
    ok( !defined $f->{snaps}{ $snap2->{snap_id} }{svolLdevId}, 'pair left without an S-VOL' );
    $d->{_fail_map} = 0;

    my $e = eval { $d->materialize_snapshot( $bid, $snap2->{snap_id} ); 1 } ? undef : $@;
    like( "$e", qr/needs host_ctx/, 'host_ctx required' );
};

subtest '#27 materialize_snapshot: group pin, unconfirmed assign, failed create' => sub {
    my ( $d, $f ) = setup_paths();
    my $bid  = $d->create_lu( size_bytes => GIB );
    my $snap = $d->create_snapshot( $bid, snapshot_group => 'pve_s_1_a' );

    my $e = eval { $d->materialize_snapshot( $bid, $snap->{snap_id}, host_ctx => \%HCTX, group => 'other' ); 1 } ? undef : $@;
    like( "$e", qr/not the expected pair/, 'a pair from another group is refused' );

    # Assign lands, but the read-back fails every time: keep the LDEV, error out.
    no warnings 'redefine';
    my $orig = \&FCLU::FakeHitachiRest::get_snapshot;
    my $n = 0;
    local *FCLU::FakeHitachiRest::get_snapshot = sub { return $orig->(@_) if $n++ == 0; die "API request failed: 503\n" };
    my $ok = eval { $d->materialize_snapshot( $bid, $snap->{snap_id}, host_ctx => \%HCTX,
        requested_id => 320, group => 'pve_s_1_a' ); 1 };
    like( $@, qr/could not confirm/, 'unconfirmed assign reported' );
    ok( $f->{ldevs}{320} && ( $f->{ldevs}{320}{emulationType} // '' ) ne 'NOT DEFINED', 'LDEV kept (may be assigned)' );
    local *FCLU::FakeHitachiRest::get_snapshot = $orig;
    my $r = $d->materialize_snapshot( $bid, $snap->{snap_id}, host_ctx => \%HCTX, group => 'pve_s_1_a' );
    is_deeply( $r, { backend_id => '320', created => 0 }, 'next call adopts it' );

    # create_ldev fails: nothing to delete, no delete_ldev issued.
    my $snap2 = $d->create_snapshot($bid);
    my $dels  = $f->{calls}{delete_ldev} // 0;
    local *FCLU::FakeHitachiRest::create_ldev = sub { die "API request failed: KART40044-E id in use\n" };
    eval { $d->materialize_snapshot( $bid, $snap2->{snap_id}, host_ctx => \%HCTX, requested_id => 330 ) };
    ok( $@, 'create failure surfaces' );
    is( $f->{calls}{delete_ldev} // 0, $dels, 'no delete_ldev for an LDEV we never made' );
};

subtest '#27 N1: restore refuses a reused snapshot id from another group' => sub {
    my ( $d, $f ) = setup();
    my $bid  = $d->create_lu( size_bytes => GIB );
    my $snap = $d->create_snapshot( $bid, snapshot_group => 'pve_s_1_newer' );
    my $e = eval { $d->restore_snapshot( $snap->{snap_id}, pvol => $bid, group => 'pve_s_1_older' ); 1 } ? undef : $@;
    like( "$e", qr/not the expected pair/, 'mismatched group refused' );
    ok( !$f->{calls}{restore_snapshot}, 'no reverse copy issued' );
    ok( $d->restore_snapshot( $snap->{snap_id}, pvol => $bid, group => 'pve_s_1_newer' ), 'matching group restores' );
    ok( $d->_check_pair_group( { snapshotGroupName => 'pve_e590h-test_267_a_long' }, 'pve_e590h-test_267_a_long_snapshot_name' ),
        'an array-shortened group name is accepted' );
};

done_testing();
