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

done_testing();
