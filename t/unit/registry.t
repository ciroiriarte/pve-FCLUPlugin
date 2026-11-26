#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);

use lib 'src';
use PVE::Storage::FCLU::Registry;

# ARCHITECTURE.md §7/§9: the vendor-neutral volume registry. These tests pin the
# generalized behaviour carried over from the Hitachi Config.pm registry — the
# opaque backend_id identity (string, not int), the stable-identity refusal,
# reservation/rename, dependents, and the snapshot subregistry — all on the flock
# path (tempdir base_dir keeps it off the cluster lock).

sub mk {
    my (%o) = @_;
    return PVE::Storage::FCLU::Registry->new(
        storeid => $o{storeid} // 'test', base_dir => $o{base_dir} );
}

subtest 'empty/missing registry loads as {}' => sub {
    my $r = mk( base_dir => tempdir( CLEANUP => 1 ) );
    is_deeply( $r->load, {}, 'missing registry => {}' );
    is_deeply( $r->list, {}, 'list alias => {}' );
};

subtest 'register / lookup / list / unregister with opaque backend_id' => sub {
    my $r = mk( base_dir => tempdir( CLEANUP => 1 ) );

    # Opaque (non-numeric) backend_id must round-trip unchanged.
    $r->register( 'vm-100-disk-1', 'naa.60060e8000abcd', size_mb => 1024,
        identity => { ids => { naa => '60060e8000abcd' } } );

    my ( $bid, $entry ) = $r->lookup('vm-100-disk-1');
    is( $bid, 'naa.60060e8000abcd', 'opaque backend_id round-trips' );
    is( $entry->{size_mb}, 1024, 'meta stored' );
    is( $entry->{identity}{ids}{naa}, '60060e8000abcd', 'nested identity stored' );
    is( scalar $r->lookup('vm-100-disk-1'), 'naa.60060e8000abcd', 'scalar lookup returns id' );

    ok( exists $r->list->{'vm-100-disk-1'}, 'volume appears in list' );

    $r->unregister('vm-100-disk-1');
    is( $r->lookup('vm-100-disk-1'), undef, 'unregistered volume gone' );

    eval { $r->register( 'v', '' ) };
    like( $@, qr/backend_id is required/, 'empty backend_id rejected' );
};

subtest 'stable identity: refuse retarget, allow same-id re-register' => sub {
    my $r = mk( base_dir => tempdir( CLEANUP => 1 ) );
    $r->register( 'vm-1-disk-1', 'A', size_mb => 10 );

    # Re-registering the SAME backend_id (e.g. resize) is fine and merges meta.
    $r->register( 'vm-1-disk-1', 'A', size_mb => 20 );
    my ( undef, $e ) = $r->lookup('vm-1-disk-1');
    is( $e->{size_mb}, 20, 'same-id re-register merges new meta' );

    # Retargeting a committed entry to a DIFFERENT backend is refused.
    eval { $r->register( 'vm-1-disk-1', 'B' ) };
    like( $@, qr/refusing to retarget/, 'retarget to a different backend is blocked' );
    is( scalar $r->lookup('vm-1-disk-1'), 'A', 'original mapping intact after refusal' );
};

subtest 'reserve_volname allocates the next free name, then register finalizes' => sub {
    my $r = mk( base_dir => tempdir( CLEANUP => 1 ) );

    my $n1 = $r->reserve_volname(100);
    is( $n1, 'vm-100-disk-1', 'first reservation' );
    my $n2 = $r->reserve_volname(100);
    is( $n2, 'vm-100-disk-2', 'second reservation skips the reserved name' );

    my $b = $r->reserve_volname( 100, base => 1 );
    is( $b, 'base-100-disk-3', 'base reservation uses base- prefix and shared counter' );

    # A reserved placeholder may be finalized to any backend (no retarget refusal).
    $r->register( $n1, 'X' );
    is( scalar $r->lookup($n1), 'X', 'reserved entry finalized by register' );
};

subtest 'update_meta merges and deletes; unknown volume croaks' => sub {
    my $r = mk( base_dir => tempdir( CLEANUP => 1 ) );
    $r->register( 'vm-2-disk-1', 'A' );

    $r->update_meta( 'vm-2-disk-1', protected => 1, notes => 'hello' );
    my ( undef, $e ) = $r->lookup('vm-2-disk-1');
    is( $e->{protected}, 1,       'protected set' );
    is( $e->{notes},     'hello', 'notes set' );

    $r->update_meta( 'vm-2-disk-1', notes => undef );   # undef removes the key
    ( undef, $e ) = $r->lookup('vm-2-disk-1');
    ok( !exists $e->{notes}, 'undef value removes the meta key' );
    is( scalar $r->lookup('vm-2-disk-1'), 'A', 'backend_id untouched by update_meta' );

    eval { $r->update_meta( 'ghost', protected => 1 ) };
    like( $@, qr/not in registry/, 'update_meta on unknown volume croaks' );

    # update_meta must not be a back door around the identity guard or the
    # snapshot subregistry.
    eval { $r->update_meta( 'vm-2-disk-1', backend_id => 'B' ) };
    like( $@, qr/reserved key 'backend_id'/, 'update_meta refuses to retarget backend_id' );
    is( scalar $r->lookup('vm-2-disk-1'), 'A', 'backend_id intact after refused update_meta' );
    eval { $r->update_meta( 'vm-2-disk-1', snapshots => {} ) };
    like( $@, qr/reserved key 'snapshots'/, 'update_meta refuses to clobber snapshots' );
};

subtest 'find_volname_by_backend' => sub {
    my $r = mk( base_dir => tempdir( CLEANUP => 1 ) );
    $r->register( 'vm-3-disk-1', 'dev-7' );
    is( $r->find_volname_by_backend('dev-7'), 'vm-3-disk-1', 'reverse lookup hits' );
    is( $r->find_volname_by_backend('nope'),  undef,         'reverse lookup miss => undef' );
};

subtest 'rename_volume preserves the entry; guards source/target' => sub {
    my $r = mk( base_dir => tempdir( CLEANUP => 1 ) );
    $r->register( 'vm-4-disk-1', 'A', size_mb => 5 );

    $r->rename_volume( 'vm-4-disk-1', 'base-4-disk-1' );
    is( $r->lookup('vm-4-disk-1'), undef, 'old name gone' );
    my ( $bid, $e ) = $r->lookup('base-4-disk-1');
    is( $bid, 'A', 'entry moved to new name' );
    is( $e->{size_mb}, 5, 'meta preserved across rename' );

    eval { $r->rename_volume( 'ghost', 'x' ) };
    like( $@, qr/not in registry/, 'rename of missing source croaks' );
    $r->register( 'vm-5-disk-1', 'B' );
    eval { $r->rename_volume( 'vm-5-disk-1', 'base-4-disk-1' ) };
    like( $@, qr/already exists/, 'rename onto an existing target croaks' );
};

subtest 'find_dependents / find_snapshot_dependents track clone lineage' => sub {
    my $r = mk( base_dir => tempdir( CLEANUP => 1 ) );
    $r->register( 'base-9-disk-1', 'P' );
    $r->register( 'vm-10-disk-1', 'C1', parent_volname => 'base-9-disk-1', parent_snap => 's1' );
    $r->register( 'vm-11-disk-1', 'C2', parent_volname => 'base-9-disk-1' );

    is_deeply(
        [ sort @{ $r->find_dependents('base-9-disk-1') } ],
        [ 'vm-10-disk-1', 'vm-11-disk-1' ],
        'both children are dependents',
    );
    is_deeply(
        $r->find_snapshot_dependents( 'base-9-disk-1', 's1' ),
        ['vm-10-disk-1'],
        'only the snapshot-pinned child counts as a snapshot dependent',
    );
};

subtest 'snapshot subregistry lifecycle' => sub {
    my $r = mk( base_dir => tempdir( CLEANUP => 1 ) );
    $r->register( 'vm-100-disk-1', 'A' );

    $r->register_snapshot( 'vm-100-disk-1', 'snap1', svol => 'S1', snapshot_id => 'pair-1' );
    my $m = $r->lookup_snapshot( 'vm-100-disk-1', 'snap1' );
    ok( $m, 'snapshot found' );
    is( $m->{svol}, 'S1',  'snap meta stored' );
    ok( $m->{timestamp},   'timestamp auto-set' );

    $r->register_snapshot( 'vm-100-disk-1', 'snap2', svol => 'S2' );
    is( scalar keys %{ $r->list_snapshots('vm-100-disk-1') }, 2, 'two snapshots' );

    $r->rename_snapshot( 'vm-100-disk-1', 'snap1', 'snap1b' );
    ok( $r->lookup_snapshot( 'vm-100-disk-1', 'snap1b' ), 'renamed snapshot present' );
    is( $r->lookup_snapshot( 'vm-100-disk-1', 'snap1' ), undef, 'old snap name gone' );

    eval { $r->rename_snapshot( 'vm-100-disk-1', 'snap2', 'snap1b' ) };
    like( $@, qr/already exists/, 'rename onto existing snapshot croaks' );

    $r->unregister_snapshot( 'vm-100-disk-1', 'snap1b' );
    $r->unregister_snapshot( 'vm-100-disk-1', 'snap2' );
    is_deeply( $r->list_snapshots('vm-100-disk-1'), {},
        'snapshots hash cleaned up once empty' );

    # register_snapshot on an unknown volume croaks.
    eval { $r->register_snapshot( 'ghost', 's', x => 1 ) };
    like( $@, qr/not in registry/, 'snapshot on unknown volume croaks' );

    # nonexistent lookups are undef / {}.
    is( $r->lookup_snapshot( 'ghost', 's' ), undef, 'snap lookup on missing vol => undef' );
    is_deeply( $r->list_snapshots('ghost'), {}, 'snap list on missing vol => {}' );
};

subtest 'corrupt registry JSON croaks' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $r   = mk( base_dir => $dir );
    open( my $fh, '>', "$dir/test.json" ) or die $!;
    print $fh '{ this is not json';
    close($fh);
    eval { $r->load };
    like( $@, qr/is corrupt/, 'corrupt JSON is reported, not silently swallowed' );
};

subtest 'data persists to disk across instances' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    mk( base_dir => $dir )->register( 'vm-1-disk-1', 'A', size_mb => 7 );
    my ( $bid, $e ) = mk( base_dir => $dir )->lookup('vm-1-disk-1');
    is( $bid, 'A', 'a fresh instance reads the persisted entry' );
    is( $e->{size_mb}, 7, 'persisted meta survives' );
};

subtest 'consistency-group membership + cg_snapshot records' => sub {
    my $r = mk( base_dir => tempdir( CLEANUP => 1 ) );
    $r->register( 'vm-1-disk-0', 'a', cg => 'db' );
    $r->register( 'vm-1-disk-1', 'b', cg => 'db' );
    $r->register( 'vm-1-disk-2', 'c', cg => 'logs' );
    $r->register( 'vm-1-disk-3', 'd' );                       # untagged
    $r->reserve_volname(9);                                   # a reservation must be ignored

    is_deeply( $r->find_cg_members('db'), [ 'vm-1-disk-0', 'vm-1-disk-1' ], 'db members' );
    is_deeply( $r->find_cg_members('logs'), [ 'vm-1-disk-2' ], 'logs member' );
    is_deeply( $r->find_cg_members('nope'), [], 'unknown group => empty' );
    is_deeply( [ sort keys %{ $r->list_cgs() } ], [ 'db', 'logs' ], 'list_cgs enumerates groups' );

    # clearing the attribute drops membership
    $r->update_meta( 'vm-1-disk-1', cg => undef );
    is_deeply( $r->find_cg_members('db'), [ 'vm-1-disk-0' ], 'cleared member gone' );

    # cg_snapshot records live in their own subtree
    $r->add_cg_snapshot( 'vm-1-disk-0', 's1', snap_id => 'a,1', group => 'g', cg => 'db' );
    $r->add_cg_snapshot( 'vm-1-disk-2', 's1', snap_id => 'c,1', group => 'g', cg => 'logs' );
    my $found = $r->find_cg_snapshot( 'db', 's1' );
    is( scalar @$found, 1, 'find_cg_snapshot filters by cg' );
    is( $found->[0]{volname}, 'vm-1-disk-0', 'right holder' );
    is( $found->[0]{snap_id}, 'a,1', 'record carries snap_id' );
    ok( $r->list_all_cg_snapshots()->{db}{s1}, 'list_all groups by cg then label' );

    # add is idempotency-guarded
    eval { $r->add_cg_snapshot( 'vm-1-disk-0', 's1', snap_id => 'x' ) };
    like( $@, qr/already exists/, 'duplicate label per volume refused' );

    # cg_snapshots is reserved against update_meta clobbering
    eval { $r->update_meta( 'vm-1-disk-0', cg_snapshots => {} ) };
    like( $@, qr/reserved key/, 'update_meta refuses cg_snapshots' );

    # remove prunes the subtree
    $r->remove_cg_snapshot( 'vm-1-disk-0', 's1' );
    is_deeply( $r->find_cg_snapshot( 'db', 's1' ), [], 'record removed' );
    $r->remove_cg_snapshot( 'vm-1-disk-0', 's1' );   # idempotent
};

subtest 'rename_snapshot repoints only the dependents of THAT snapshot' => sub {
    my $r = mk( base_dir => tempdir( CLEANUP => 1 ) );
    $r->register( 'vm-1-disk-0', 'P' );
    $r->register( 'vm-3-disk-0', 'Q' );
    $r->register_snapshot( 'vm-1-disk-0', 'a', svol => 'S1' );
    $r->register_snapshot( 'vm-3-disk-0', 'a', svol => 'S3' );
    $r->register( 'vm-2-disk-0', 'C1', parent_volname => 'vm-1-disk-0', parent_snap => 'a' );
    $r->register( 'vm-4-disk-0', 'C3', parent_volname => 'vm-3-disk-0', parent_snap => 'a' );
    my $inflight = $r->reserve_volname( 5, parent_volname => 'vm-1-disk-0', parent_snap => 'a' );

    $r->rename_snapshot( 'vm-1-disk-0', 'a', 'b' );
    is( ( $r->lookup('vm-2-disk-0') )[1]->{parent_snap}, 'b', 'committed clone repointed' );
    is( $r->load->{$inflight}{parent_snap}, 'b', 'in-flight (reserved) clone repointed' );
    is( ( $r->lookup('vm-4-disk-0') )[1]->{parent_snap}, 'a',
        'same-named snapshot on another volume left alone' );
    is_deeply( [ sort @{ $r->find_snapshot_dependents( 'vm-1-disk-0', 'b' ) } ],
        [ sort( 'vm-2-disk-0', $inflight ) ], 'dependents found under the new name' );
    is_deeply( $r->find_snapshot_dependents( 'vm-1-disk-0', 'a' ), [], 'none under the old name' );
};

subtest 'reservations with lineage count as dependents until they go stale' => sub {
    my $r = mk( base_dir => tempdir( CLEANUP => 1 ) );
    $r->register( 'vm-1-disk-0', 'P' );
    $r->register_snapshot( 'vm-1-disk-0', 'a', svol => 'S1' );
    my $n = $r->reserve_volname( 2, parent_volname => 'vm-1-disk-0', parent_snap => 'a' );
    is_deeply( $r->find_snapshot_dependents( 'vm-1-disk-0', 'a' ), [$n], 'fresh reservation counts' );
    is_deeply( $r->find_dependents('vm-1-disk-0'), [$n], '... for find_dependents too' );

    $r->_with_registry_lock( sub { $_[0]{$n}{timestamp} = time() - 2 * 3600; return } );
    is_deeply( $r->find_snapshot_dependents( 'vm-1-disk-0', 'a' ), [],
        'stale reservation (killed clone) no longer pins the snapshot' );
};

subtest 'begin/end_snapshot_restore: dependents, live and stale markers' => sub {
    my $r = mk( base_dir => tempdir( CLEANUP => 1 ) );
    $r->register( 'vm-1-disk-0', 'P' );
    $r->register_snapshot( 'vm-1-disk-0', 'a', svol => 'S1' );

    eval { $r->begin_snapshot_restore( 'vm-1-disk-0', 'ghost', node => 'n1' ) };
    like( $@, qr/does not exist/, 'missing snapshot refused' );

    ok( $r->begin_snapshot_restore( 'vm-1-disk-0', 'a', node => 'n1' ), 'marker set' );
    my $mark = $r->lookup_snapshot( 'vm-1-disk-0', 'a' )->{restoring};
    is( $mark->{pid}, $$, 'marker records the pid' );
    is( $mark->{node}, 'n1', 'marker records the node' );

    eval { $r->begin_snapshot_restore( 'vm-1-disk-0', 'a', node => 'n1' ) };
    like( $@, qr/already running \(node n1, pid $$\)/, 'live marker blocks a second restore' );
    unlike( $@, qr/Cannot acquire/, 'refusal is not reported as a lock failure' );
    eval { $r->reserve_volname( 2, parent_volname => 'vm-1-disk-0', parent_snap => 'a', node => 'n1' ) };
    like( $@, qr/rollback to it is running/, 'live marker blocks a clone reservation' );
    ok( !grep( { /^vm-2-/ } keys %{ $r->load } ), 'refused reservation left no entry' );

    ok( $r->end_snapshot_restore( 'vm-1-disk-0', 'a', node => 'n1' ), 'marker cleared' );
    ok( !$r->lookup_snapshot( 'vm-1-disk-0', 'a' )->{restoring}, 'no marker after end' );
    ok( $r->end_snapshot_restore( 'vm-1-disk-0', 'gone' ), 'end on a vanished snapshot is a no-op' );

    # Stale: recording process gone on THIS node.
    my $dead = fork() // die "fork: $!";
    exit 0 unless $dead;
    waitpid( $dead, 0 );
    $r->_with_registry_lock( sub {
        $_[0]{'vm-1-disk-0'}{snapshots}{a}{restoring} =
            { started => time(), node => 'n1', pid => $dead };
        return } );
    ok( $r->begin_snapshot_restore( 'vm-1-disk-0', 'a', node => 'n1' ),
        'marker of a dead pid on this node is stale' );

    # Another node's marker is trusted until the TTL, then stale.
    $r->_with_registry_lock( sub {
        $_[0]{'vm-1-disk-0'}{snapshots}{a}{restoring} =
            { started => time(), node => 'n2', pid => $dead };
        return } );
    eval { $r->begin_snapshot_restore( 'vm-1-disk-0', 'a', node => 'n1' ) };
    like( $@, qr/already running/, "another node's marker is honored" );
    $r->_with_registry_lock( sub {
        $_[0]{'vm-1-disk-0'}{snapshots}{a}{restoring}{started} = time() - 26 * 3600;  # no expires: default TTL
        return } );
    ok( $r->begin_snapshot_restore( 'vm-1-disk-0', 'a', node => 'n1' ), 'expired marker is stale' );

    # Dependents block the restore (checked in the same locked write).
    $r->end_snapshot_restore( 'vm-1-disk-0', 'a', node => 'n1' );
    $r->register( 'vm-9-disk-0', 'C', parent_volname => 'vm-1-disk-0', parent_snap => 'a' );
    eval { $r->begin_snapshot_restore( 'vm-1-disk-0', 'a', node => 'n1' ) };
    like( $@, qr/linked clone\(s\) depend on this snapshot: vm-9-disk-0/, 'dependents refuse' );
    ok( !$r->lookup_snapshot( 'vm-1-disk-0', 'a' )->{restoring}, 'no marker left on refusal' );
};

subtest 'restore marker: caller TTL, own-marker-only clear, live-volume clones' => sub {
    my $r = mk( base_dir => tempdir( CLEANUP => 1 ) );
    $r->register( 'vm-1-disk-0', 'P' );
    $r->register_snapshot( 'vm-1-disk-0', 'a', svol => 'S1' );
    $r->register_snapshot( 'vm-1-disk-0', 'b', svol => 'S2' );

    $r->begin_snapshot_restore( 'vm-1-disk-0', 'a', node => 'n1', ttl => 100 );
    my $m = $r->lookup_snapshot( 'vm-1-disk-0', 'a' )->{restoring};
    is( $m->{expires} - $m->{started}, 100, 'marker expiry follows the caller TTL' );

    # Clone of the LIVE volume is refused while any of its snapshots is being restored.
    eval { $r->reserve_volname( 2, parent_volname => 'vm-1-disk-0', node => 'n1' ) };
    like( $@, qr/rollback to its snapshot 'a' is running/, 'live-volume clone refused mid-restore' );
    ok( $r->reserve_volname( 2, parent_volname => 'vm-1-disk-0', parent_snap => 'b', node => 'n1' ),
        'clone from an unrelated snapshot is still allowed' );

    # end only clears a marker this process set.
    $r->_with_registry_lock( sub {
        $_[0]{'vm-1-disk-0'}{snapshots}{a}{restoring}{pid} = $$ + 1; return } );
    $r->end_snapshot_restore( 'vm-1-disk-0', 'a', node => 'n1' );
    ok( $r->lookup_snapshot( 'vm-1-disk-0', 'a' )->{restoring}, "another process's marker kept" );
    $r->_with_registry_lock( sub {
        $_[0]{'vm-1-disk-0'}{snapshots}{a}{restoring}{pid} = $$; return } );
    $r->end_snapshot_restore( 'vm-1-disk-0', 'a', node => 'n2' );
    ok( $r->lookup_snapshot( 'vm-1-disk-0', 'a' )->{restoring}, "same pid on another node's marker kept" );

    # Past the caller TTL the marker is stale even from another node.
    $r->_with_registry_lock( sub {
        my $mk = $_[0]{'vm-1-disk-0'}{snapshots}{a}{restoring};
        @$mk{qw(node expires)} = ( 'n2', time() - 1 ); return } );
    ok( $r->begin_snapshot_restore( 'vm-1-disk-0', 'a', node => 'n1' ), 'expired TTL is stale' );
};

subtest 'register over a lineage reservation keeps a rename that happened mid-build' => sub {
    my $r = mk( base_dir => tempdir( CLEANUP => 1 ) );
    $r->register( 'vm-1-disk-0', 'P' );
    $r->register_snapshot( 'vm-1-disk-0', 'a', svol => 'S1' );
    my $n = $r->reserve_volname( 2, parent_volname => 'vm-1-disk-0', parent_snap => 'a' );
    $r->rename_snapshot( 'vm-1-disk-0', 'a', 'b' );
    $r->register( $n, 'C' );   # clone_image commits without re-passing lineage
    my ( undef, $e ) = $r->lookup($n);
    is( $e->{parent_snap}, 'b', 'committed clone keeps the renamed parent' );
    is( $e->{parent_volname}, 'vm-1-disk-0', 'parent volume kept' );
    ok( !$e->{reserved}, 'reservation marker cleared' );

    # In-flight reservations are labeled in the rollback refusal.
    my $f = $r->reserve_volname( 3, parent_volname => 'vm-1-disk-0', parent_snap => 'b' );
    $r->unregister($n);
    eval { $r->begin_snapshot_restore( 'vm-1-disk-0', 'b', node => 'n1' ) };
    like( $@, qr/\Q$f\E \(clone in progress\)/, 'reserved dependent labeled in the message' );
};

subtest '#27: set_snapshot_source is compare-and-set; update_snapshot_meta is guarded' => sub {
    my $r = mk( base_dir => tempdir( CLEANUP => 1 ) );
    $r->register( 'vm-1-disk-0', 'P' );
    $r->register_snapshot( 'vm-1-disk-0', 'a', snap_id => '1,0' );

    is( $r->set_snapshot_source( 'vm-1-disk-0', 'a', 'S1', svol_owned => 1 ), 'S1', 'first writer records' );
    is( $r->set_snapshot_source( 'vm-1-disk-0', 'a', 'S2', svol_owned => 1 ), 'S1', 'second writer gets the winner' );
    my $m = $r->lookup_snapshot( 'vm-1-disk-0', 'a' );
    is( $m->{svol}, 'S1', 'source unchanged' );
    ok( $m->{svol_owned}, 'owned flag recorded' );
    is( $r->set_snapshot_source( 'vm-1-disk-0', 'gone', 'S3' ), undef, 'missing snapshot => undef' );

    $r->update_snapshot_meta( 'vm-1-disk-0', 'a', svol_identity => { ids => { naa => 'ab' } } );
    is( $r->lookup_snapshot( 'vm-1-disk-0', 'a' )->{svol_identity}{ids}{naa}, 'ab', 'identity merged' );
    for my $k (qw(snap_id svol svol_owned restoring)) {
        eval { $r->update_snapshot_meta( 'vm-1-disk-0', 'a', $k => 'x' ) };
        like( $@, qr/reserved key '$k'/, "update_snapshot_meta refuses $k" );
    }
    ok( $r->update_snapshot_meta( 'vm-1-disk-0', 'gone', svol_identity => {} ), 'missing snapshot is a no-op' );
};

subtest '#26: snapshot delete marker blocks clones and rollback, clears on end' => sub {
    my $r = mk( base_dir => tempdir( CLEANUP => 1 ) );
    $r->register( 'vm-1-disk-0', '300' );
    $r->register_snapshot( 'vm-1-disk-0', 'a', snap_id => '300,3' );
    ok( $r->begin_snapshot_delete( 'vm-1-disk-0', 'a', node => 'n1' ), 'marker set' );
    ok( $r->lookup_snapshot( 'vm-1-disk-0', 'a' )->{deleting}, 'recorded' );
    eval { $r->reserve_volname( 2, parent_volname => 'vm-1-disk-0', parent_snap => 'a', node => 'n1' ) };
    like( $@, qr/it is being deleted/, 'clone from the snapshot refused' );
    ok( $r->reserve_volname( 2, parent_volname => 'vm-1-disk-0', node => 'n1' ), 'clone of the live volume still allowed' );
    eval { $r->begin_snapshot_restore( 'vm-1-disk-0', 'a', node => 'n1' ) };
    like( $@, qr/being deleted/, 'rollback refused' );
    eval { $r->rename_snapshot( 'vm-1-disk-0', 'a', 'b', node => 'n1' ) };
    like( $@, qr/delete of it is running/, 'rename refused' );
    ok( $r->begin_snapshot_delete( 'vm-1-disk-0', 'a', node => 'n1' ), 'own retry may re-enter' );
    $r->end_snapshot_delete( 'vm-1-disk-0', 'a', node => 'n1' );
    ok( !$r->lookup_snapshot( 'vm-1-disk-0', 'a' )->{deleting}, 'cleared' );

    # Another live process's marker refuses; a dead pid on the same node is stale.
    my $reg = $r->load;
    $reg->{'vm-1-disk-0'}{snapshots}{a}{deleting} = { node => 'n1', pid => 999999, started => time, expires => time + 600 };
    $r->_with_registry_lock( sub { %{ $_[0] } = %$reg; return } );
    ok( $r->begin_snapshot_delete( 'vm-1-disk-0', 'a', node => 'n1' ), 'dead-pid marker ignored' );
    $r->end_snapshot_delete( 'vm-1-disk-0', 'a', node => 'n1' );
    $reg = $r->load;
    $reg->{'vm-1-disk-0'}{snapshots}{a}{deleting} = { node => 'n2', pid => 1, started => time, expires => time + 600 };
    $r->_with_registry_lock( sub { %{ $_[0] } = %$reg; return } );
    eval { $r->begin_snapshot_delete( 'vm-1-disk-0', 'a', node => 'n1' ) };
    like( $@, qr/another delete of it is running/, 'live marker from another node refuses' );

    # A clone reservation already in place refuses the delete (the other order).
    my $r2 = mk( base_dir => tempdir( CLEANUP => 1 ) );
    $r2->register( 'vm-1-disk-0', '300' );
    $r2->register_snapshot( 'vm-1-disk-0', 'a', snap_id => '300,3' );
    $r2->reserve_volname( 2, parent_volname => 'vm-1-disk-0', parent_snap => 'a', node => 'n1' );
    eval { $r2->begin_snapshot_delete( 'vm-1-disk-0', 'a', node => 'n1' ) };
    like( $@, qr/clone in progress/, 'in-flight clone blocks the delete' );
};

subtest '#26: volume busy marker; atomic rename refusal; refusals do not write' => sub {
    my $r = mk( base_dir => tempdir( CLEANUP => 1 ) );
    $r->register( 'vm-1-disk-0', '300' );
    ok( $r->begin_volume_op( 'vm-1-disk-0', 'deleted', node => 'n1' ), 'busy marker set' );
    eval { $r->reserve_volname( 2, parent_volname => 'vm-1-disk-0', node => 'n1' ) };
    like( $@, qr/it is being deleted/, 'clone of a volume being deleted refused' );
    $r->end_volume_op( 'vm-1-disk-0', node => 'n1' );
    ok( !( $r->lookup('vm-1-disk-0') )[1]{busy}, 'cleared' );

    $r->reserve_volname( 2, parent_volname => 'vm-1-disk-0', node => 'n1' );
    eval { $r->begin_volume_op( 'vm-1-disk-0', 'deleted', node => 'n1' ) };
    like( $@, qr/cannot delete 'vm-1-disk-0': linked clone\(s\) depend on it: vm-2-disk-1 \(clone in progress\)/,
        'in-flight clone blocks free' );
    eval { $r->rename_volume( 'vm-1-disk-0', 'base-1-disk-0', refuse_dependents => "cannot convert 'vm-1-disk-0'" ) };
    like( $@, qr/^cannot convert 'vm-1-disk-0': linked clone\(s\) depend on it/, 'atomic rename refused' );
    ok( defined $r->lookup('vm-1-disk-0'), 'not renamed' );

    # A refusal costs no registry write.
    no warnings 'redefine';
    my $writes = 0;
    my $orig = \&PVE::Storage::FCLU::Registry::_write_registry_atomic;
    local *PVE::Storage::FCLU::Registry::_write_registry_atomic = sub { $writes++; $orig->(@_) };
    eval { $r->begin_volume_op( 'vm-1-disk-0', 'deleted', node => 'n1' ) };
    eval { $r->rename_volume( 'vm-1-disk-0', 'x', refuse_dependents => 'no' ) };
    is( $writes, 0, 'refused calls skipped the write' );

    $r->unregister('vm-2-disk-1');
    ok( $r->rename_volume( 'vm-1-disk-0', 'base-1-disk-0', refuse_dependents => 'no' ), 'renames once free' );
    is( $writes, 2, 'unregister + rename wrote' );
};

subtest '#26: rename_snapshot refused while a rollback holds the snapshot' => sub {
    my $r = mk( base_dir => tempdir( CLEANUP => 1 ) );
    $r->register( 'vm-1-disk-0', '300' );
    $r->register_snapshot( 'vm-1-disk-0', 'a', snap_id => '300,3' );
    $r->begin_snapshot_restore( 'vm-1-disk-0', 'a', node => 'n1' );
    eval { $r->rename_snapshot( 'vm-1-disk-0', 'a', 'b', node => 'n1' ) };
    like( $@, qr/rollback to it is running/, 'refused' );
    $r->end_snapshot_restore( 'vm-1-disk-0', 'a', node => 'n1' );
    ok( $r->rename_snapshot( 'vm-1-disk-0', 'a', 'b', node => 'n1' ), 'allowed after' );
};

subtest '#26 review: cross-guards, offline-node staleness, reserved keys' => sub {
    my $r = mk( base_dir => tempdir( CLEANUP => 1 ) );
    $r->register( 'vm-1-disk-0', '300' );
    $r->register_snapshot( 'vm-1-disk-0', 'a', snap_id => '300,3' );

    $r->begin_snapshot_delete( 'vm-1-disk-0', 'a', node => 'n1' );
    eval { $r->begin_volume_op( 'vm-1-disk-0', 'deleted', node => 'n1' ) };
    like( $@, qr/a delete of snapshot 'a' is running/, 'free refused during a snapshot delete' );
    eval { $r->rename_volume( 'vm-1-disk-0', 'base-1-disk-0', refuse_dependents => 'no', node => 'n1' ) };
    like( $@, qr/a delete of snapshot 'a' is running/, 'rename refused: would carry the marker away' );
    $r->end_snapshot_delete( 'vm-1-disk-0', 'a', node => 'n1' );

    $r->begin_volume_op( 'vm-1-disk-0', 'deleted', node => 'n1' );
    eval { $r->begin_snapshot_delete( 'vm-1-disk-0', 'a', node => 'n1' ) };
    like( $@, qr/'vm-1-disk-0' is being deleted/, 'snapshot delete refused during a free' );
    $r->end_volume_op( 'vm-1-disk-0', node => 'n1' );

    $r->register( 'vm-2-disk-0', '301' );
    eval { $r->rename_volume( 'vm-1-disk-0', 'vm-2-disk-0' ) };
    like( $@, qr/^cannot rename 'vm-1-disk-0': volume 'vm-2-disk-0' already exists\n/, 'clean exists refusal' );

    # A retry-safe marker from a node the cluster reports offline is stale; a rollback
    # marker from that node is not.
    my $reg = $r->load;
    my $far = { node => 'n2', pid => 1, started => time, expires => time + 600 };
    $reg->{'vm-1-disk-0'}{busy} = { %$far, op => 'deleted', retry_safe => 1 };
    $reg->{'vm-1-disk-0'}{snapshots}{a}{restoring} = {%$far};
    $r->_with_registry_lock( sub { %{ $_[0] } = %$reg; return } );
    delete $reg->{'vm-1-disk-0'}{snapshots}{a}{restoring};
    $reg->{'vm-1-disk-0'}{snapshots}{a}{deleting} = { %$far, retry_safe => 1 };
    $r->_with_registry_lock( sub { %{ $_[0] } = %$reg; return } );
    eval { $r->begin_volume_op( 'vm-1-disk-0', 'deleted', node => 'n1' ) };
    like( $@, qr/being deleted \(node n2/, 'online/unknown owner: free retry refused' );
    {
        local $PVE::Storage::FCLU::Registry::NODE_OFFLINE = sub { $_[0] eq 'n2' };
        ok( $r->mark_active( $r->load->{'vm-1-disk-0'}{busy}, 'n1' ), 'offline owner: still live for gates' );
        eval { $r->reserve_volname( 3, parent_volname => 'vm-1-disk-0', node => 'n1' ) };
        like( $@, qr/being deleted/, 'offline owner: clone of the volume still refused' );
        eval { $r->reserve_volname( 3, parent_volname => 'vm-1-disk-0', parent_snap => 'a', node => 'n1' ) };
        like( $@, qr/being deleted/, 'offline owner: clone of the snapshot still refused' );
        eval { $r->begin_snapshot_restore( 'vm-1-disk-0', 'a', node => 'n1' ) };
        like( $@, qr/being deleted/, 'offline owner: rollback still refused' );
        eval { $r->begin_snapshot_delete( 'vm-1-disk-0', 'a', node => 'n1' ) };
        like( $@, qr/'vm-1-disk-0' is being deleted/, 'remote busy still blocks a snapshot delete (strict)' );
        my $g = $r->load;
        delete $g->{'vm-1-disk-0'}{busy};
        $r->_with_registry_lock( sub { %{ $_[0] } = %$g; return } );
        ok( $r->begin_snapshot_delete( 'vm-1-disk-0', 'a', node => 'n1' ), 'offline owner: snapshot delete retry takes over' );
        is( $r->lookup_snapshot( 'vm-1-disk-0', 'a' )->{deleting}{node}, 'n1', 'marker now ours' );
        $r->end_snapshot_delete( 'vm-1-disk-0', 'a', node => 'n1' );
        $g = $r->load;
        $g->{'vm-1-disk-0'}{busy} = { %$far, op => 'deleted', retry_safe => 1 };
        $r->_with_registry_lock( sub { %{ $_[0] } = %$g; return } );
        ok( $r->begin_volume_op( 'vm-1-disk-0', 'deleted', node => 'n1' ), 'offline owner: free retry takes over' );
        eval { $r->reserve_volname( 3, parent_volname => 'vm-1-disk-0', node => 'n1' ) };
        like( $@, qr/being deleted/, 'clone blocked by the new owner' );
        $r->end_volume_op( 'vm-1-disk-0', node => 'n1' );
    }

    eval { $r->update_meta( 'vm-1-disk-0', busy => undef ) };
    like( $@, qr/reserved key 'busy'/, 'busy reserved' );
    eval { $r->update_snapshot_meta( 'vm-1-disk-0', 'a', deleting => undef ) };
    like( $@, qr/deleting/, 'deleting reserved' );
};

done_testing();
