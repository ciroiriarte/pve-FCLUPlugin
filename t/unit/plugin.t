#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);

# ── Minimal PVE stubs so FCLU::Plugin compiles standalone (mirrors the reference
# plugin.t): the real PVE::Storage framework is not installed in CI. ──
BEGIN {
    $INC{'PVE/Storage/Plugin.pm'} = 1;
    package PVE::Storage::Plugin;
    sub api { 0 }
    package PVE::Storage;
    sub APIVER { 11 }
}

use lib 'src';
use PVE::Storage::FCLU::Plugin;

# A stateful fake array driver (the §2 surface the plugin calls in slices 4A/4B).
{
    package T::FakeDriver;
    sub new { bless { connected => 0, status => $_[1], lus => {}, calls => {}, _seq => 0 }, $_[0] }
    sub connect    { $_[0]{connected} = 1; $_[0] }
    sub disconnect { $_[0]{connected} = 0; 1 }
    sub storage_status { @{ $_[0]{status} // [ 1000, 600, 400 ] } }
    sub detect_profile { { max_label_len => 32 } }
    sub _id { my $s = shift; my $n = $_[0]; my $bid = defined $n ? "$n" : '' . ( 1000 + ++$s->{_seq} );
        return $bid; }
    sub create_lu {
        my ( $s, %o ) = @_; $s->{calls}{create_lu}++;
        die "BOOM create\n" if $s->{fail_create};
        my $bid = $s->_id( $o{requested_id} );
        $s->{lus}{$bid} = { backend_id => $bid, size_bytes => $o{size_bytes}, pool_ref => $o{pool_ref},
            identity => { protocol => 'scsi-fc', ids => { naa => '60060e80' . sprintf( '%08x', $s->{_seq} ) } } };
        return $bid;
    }
    sub get_lu { my ( $s, $id ) = @_; $s->{lus}{$id} or die "API request failed: GET x -> 404\n"; return { %{ $s->{lus}{$id} } } }
    sub get_lu_identity { my ( $s, $id ) = @_; $s->{lus}{$id} or die "404\n"; return $s->{lus}{$id}{identity} }
    sub set_lu_label { my ( $s, $id, $l ) = @_; $s->{calls}{set_lu_label}++; die "BOOM label\n" if $s->{fail_label}; $s->{lus}{$id}{label} = $l if $s->{lus}{$id}; 1 }
    sub set_lu_qos   { my ( $s ) = @_; $s->{calls}{set_lu_qos}++; 1 }
    sub delete_lu    { my ( $s, $id ) = @_; $s->{calls}{delete_lu}++; delete $s->{lus}{$id}; 1 }
    sub ensure_host_access { my ( $s, %c ) = @_; $s->{calls}{ensure_host_access}++; "PVE_$c{hostname}" }
    sub publish_lu   { my ( $s, $id, %c ) = @_; $s->{calls}{publish_lu}++; { hostname => $c{hostname}, access_ref => "PVE_$c{hostname}" } }
    sub unpublish_lu { my ( $s ) = @_; $s->{calls}{unpublish_lu}++; 1 }
}

# A fake host connector.
{
    package T::FakeConn;
    sub new { bless { calls => {} }, shift }
    sub host_context { my ( $s, %o ) = @_; { hostname => $o{hostname}, protocol => 'scsi-fc', initiators => ['10000000c9aa'] } }
    sub attach      { my ( $s, $id ) = @_; $s->{calls}{attach}++; '/dev/mapper/3' . $id->{ids}{naa} }
    sub detach      { my ( $s ) = @_; $s->{calls}{detach}++; 1 }
    sub device_path { my ( $s, $id ) = @_; '/dev/mapper/3' . $id->{ids}{naa} }
}

# A concrete vendor subclass providing the abstract hooks + injecting the fakes.
{
    package T::Plugin;
    use parent -norequire, 'PVE::Storage::FCLU::Plugin';
    our $FAKE;
    our $CONN;
    sub type          { 'testblock' }
    sub vendor        { 'test' }
    sub driver_class  { 'T::FakeDriver' }
    sub driver_config { { platform => 'vsp_e', pool_id => '63' } }
    sub _build_driver { return $FAKE //= T::FakeDriver->new }
    sub _connector    { return $CONN //= T::FakeConn->new }
    sub _nodename     { 'node-x' }
}

my $P = 'T::Plugin';

# Redirect the registry store to a tempdir for every test.
my $dir = tempdir( CLEANUP => 1 );
$PVE::Storage::FCLU::Plugin::REGISTRY_BASE_DIR = $dir;

sub reg { return PVE::Storage::FCLU::Registry->new( storeid => 'store1', base_dir => $dir ) }

subtest 'identity: api mirrors host APIVER (clamped); plugindata; abstract hooks' => sub {
    is( PVE::Storage::FCLU::Plugin->api, 11, 'api mirrors the host APIVER within range' );
    my $pd = PVE::Storage::FCLU::Plugin->plugindata;
    ok( $pd->{content}[0]{images}, 'images content advertised' );
    is_deeply( $pd->{'sensitive-properties'}, { password => 1 }, 'password is sensitive' );

    # The bare base must croak on every vendor hook.
    for my $hook (qw(type vendor driver_class driver_config)) {
        eval { PVE::Storage::FCLU::Plugin->$hook };
        like( $@, qr/must define '\Q$hook\E'/, "$hook is abstract on the base" );
    }
    is( $P->connector_class, 'PVE::Storage::FCLU::Host::FCMultipath', 'default connector' );
};

subtest 'parse_volname / vmid_from_volname (§7)' => sub {
    my @r = $P->parse_volname('vm-100-disk-1');
    is_deeply( [ @r[ 0, 1, 2, 5, 6 ] ], [ 'images', 'vm-100-disk-1', 100, undef, 'raw' ], 'live disk' );
    is( ( $P->parse_volname('base-9-disk-0') )[5], 1, 'base flag set' );
    is( ( $P->parse_volname('vm-7-cloudinit') )[2], 7, 'cloudinit parsed (#6)' );
    eval { $P->parse_volname('garbage') };
    like( $@, qr/unable to parse/, 'invalid name dies' );

    is( PVE::Storage::FCLU::Plugin::vmid_from_volname('vm-42-disk-3'), 42, 'vmid extracted' );
    is( PVE::Storage::FCLU::Plugin::vmid_from_volname('weird'), 0, 'no vmid => 0' );
};

subtest 'volume_has_feature role table' => sub {
    is( $P->volume_has_feature( {}, 'snapshot', 's', 'vm-1-disk-0' ), 1, 'snapshot on current' );
    is( $P->volume_has_feature( {}, 'clone', 's', 'vm-1-disk-0' ), undef, 'no clone from a live volume' );
    is( $P->volume_has_feature( {}, 'clone', 's', 'base-1-disk-0' ), 1, 'clone from a base' );
    is( $P->volume_has_feature( {}, 'clone', 's', 'vm-1-disk-0', 'snap1' ), 1, 'clone from a snapshot' );
    is( $P->volume_has_feature( {}, 'rename', 's', 'vm-1-disk-0' ), 1, 'rename on current' );
};

subtest 'volume attributes: protected + notes via the registry' => sub {
    reg()->register( 'vm-100-disk-0', 'dev-1', size_mb => 1024 );

    is( $P->get_volume_attribute( {}, 'store1', 'vm-100-disk-0', 'protected' ), 0, 'protected default 0' );
    $P->update_volume_attribute( {}, 'store1', 'vm-100-disk-0', 'protected', 1 );
    is( $P->get_volume_attribute( {}, 'store1', 'vm-100-disk-0', 'protected' ), 1, 'protected set' );
    $P->update_volume_attribute( {}, 'store1', 'vm-100-disk-0', 'protected', 0 );
    is( $P->get_volume_attribute( {}, 'store1', 'vm-100-disk-0', 'protected' ), 0, 'protected cleared' );

    $P->update_volume_attribute( {}, 'store1', 'vm-100-disk-0', 'notes', 'hello' );
    is( $P->get_volume_attribute( {}, 'store1', 'vm-100-disk-0', 'notes' ), 'hello', 'notes set' );
    $P->update_volume_attribute( {}, 'store1', 'vm-100-disk-0', 'notes', '' );
    is( $P->get_volume_attribute( {}, 'store1', 'vm-100-disk-0', 'notes' ), '', 'empty notes cleared' );

    eval { $P->update_volume_attribute( {}, 'store1', 'ghost', 'protected', 1 ) };
    like( $@, qr/not found in registry/, 'unknown volume dies' );
    eval { $P->update_volume_attribute( { type => 'testblock' }, 'store1', 'vm-100-disk-0', 'bogus', 1 ) };
    like( $@, qr/not supported/, 'unknown attribute rejected' );
};

subtest 'list_images: committed entries only, vmid/vollist filters' => sub {
    my $r = reg();
    $r->register( 'vm-200-disk-0', 'dev-2', size_mb => 2048, parent_volname => 'base-9-disk-0' );
    $r->reserve_volname(300);   # a reservation (no backend_id) — must be skipped

    my $all = $P->list_images( 'store1', {}, undef, undef );
    my %byvol = map { $_->{volid} => $_ } @$all;
    ok( $byvol{'store1:vm-200-disk-0'}, 'committed volume listed' );
    is( $byvol{'store1:vm-200-disk-0'}{size}, 2048 * 1024 * 1024, 'size in bytes' );
    is( $byvol{'store1:vm-200-disk-0'}{parent}, 'store1:base-9-disk-0', 'parent volid' );
    ok( !( grep { $_->{vmid} == 300 } @$all ), 'reservation (no backend) not listed' );

    my $just200 = $P->list_images( 'store1', {}, 200, undef );
    is( scalar @$just200, 1, 'vmid filter' );
    my $bylist = $P->list_images( 'store1', {}, undef, ['store1:vm-200-disk-0'] );
    is( scalar @$bylist, 1, 'vollist filter' );
};

subtest 'status + activate/deactivate drive the driver lifecycle' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new( [ 5000, 3000, 2000 ] );

    is_deeply( [ $P->status( 'store1', {} ) ], [ 5000, 3000, 2000, 1 ], 'status from driver storage_status' );
    ok( $T::Plugin::FAKE->{connected}, 'driver connected (lazily by status)' );

    $P->deactivate_storage( 'store1', {} );
    ok( !$T::Plugin::FAKE->{connected}, 'deactivate disconnected the driver' );

    ok( $P->activate_storage( 'store1', {} ), 'activate_storage' );
    ok( $T::Plugin::FAKE->{connected}, 'activate connected the driver' );
    $P->deactivate_storage( 'store1', {} );
};

subtest 'alloc_image: create + register, host-mapping deferred to activate' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    $P->deactivate_storage( 'store1', {} );   # drop any cached driver so _driver picks up this FAKE
    my $name = $P->alloc_image( 'store1', { pool_id => '63' }, 500, 'raw', undef, 4 * 1024 * 1024 );
    is( $name, 'vm-500-disk-1', 'reserved name returned' );

    my ( $bid, $entry ) = reg()->lookup($name);
    ok( defined $bid, 'registry committed with a backend_id' );
    ok( $entry->{identity}{ids}{naa}, 'canonical identity recorded at alloc' );
    is( $T::Plugin::FAKE->{calls}{create_lu}, 1, 'driver create_lu called' );
    is( $T::Plugin::FAKE->{calls}{set_lu_label}, 1, 'label set' );
    ok( !$T::Plugin::FAKE->{calls}{publish_lu}, 'no host mapping during alloc (deferred to activate)' );

    # An explicit name that already exists is refused.
    eval { $P->alloc_image( 'store1', { pool_id => '63' }, 500, 'raw', $name, 1024 ) };
    like( $@, qr/already exists/, 'duplicate explicit name refused' );
    eval { $P->alloc_image( 'store1', {}, 1, 'qcow2', undef, 1024 ) };
    like( $@, qr/unsupported format/, 'non-raw format refused' );
};

subtest 'alloc_image rolls back the array LU + reservation on failure' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    $P->deactivate_storage( 'store1', {} );   # drop any cached driver so _driver picks up this FAKE
    $T::Plugin::FAKE->{fail_create} = 1;
    eval { $P->alloc_image( 'store1', { pool_id => '63' }, 999, 'raw', undef, 1024 ) };
    like( $@, qr/failed to allocate/, 'alloc failure surfaced' );
    is( reg()->lookup('vm-999-disk-1'), undef, 'name reservation rolled back' );
};

subtest 'alloc_image rolls back the ORPHAN LU on a post-create failure' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    $P->deactivate_storage( 'store1', {} );
    $T::Plugin::FAKE->{fail_label} = 1;   # create_lu succeeds, then set_lu_label throws

    eval { $P->alloc_image( 'store1', { pool_id => '63' }, 998, 'raw', undef, 1 << 30 ) };
    like( $@, qr/failed to allocate/, 'alloc failure surfaced' );
    is( $T::Plugin::FAKE->{calls}{create_lu}, 1, 'the LU was created' );
    is( $T::Plugin::FAKE->{calls}{delete_lu}, 1, 'the orphan LU was deleted (rollback)' );
    is_deeply( $T::Plugin::FAKE->{lus}, {}, 'no LU left on the array' );
    is( reg()->lookup('vm-998-disk-1'), undef, 'name reservation rolled back' );
};

subtest 'activate_volume publishes + attaches; deactivate detaches + unpublishes' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    $P->deactivate_storage( 'store1', {} );   # drop any cached driver so _driver picks up this FAKE
    local $T::Plugin::CONN = T::FakeConn->new;
    my $name = $P->alloc_image( 'store1', { pool_id => '63' }, 600, 'raw', undef, 1 << 30 );

    ok( $P->activate_volume( 'store1', {}, $name ), 'activate_volume' );
    is( $T::Plugin::FAKE->{calls}{ensure_host_access}, 1, 'ensure_host_access called' );
    is( $T::Plugin::FAKE->{calls}{publish_lu}, 1, 'publish_lu called' );
    is( $T::Plugin::CONN->{calls}{attach}, 1, 'connector attach called' );

    ok( $P->deactivate_volume( 'store1', {}, $name ), 'deactivate_volume' );
    is( $T::Plugin::CONN->{calls}{detach}, 1, 'connector detach called (host side first)' );
    is( $T::Plugin::FAKE->{calls}{unpublish_lu}, 1, 'unpublish_lu called' );

    # Deactivating an unknown volume is an idempotent no-op success.
    is( $P->deactivate_volume( 'store1', {}, 'vm-12345-disk-0' ), 1, 'soft deactivate of a missing volume' );
};

subtest 'filesystem_path resolves from the recorded identity (no array session)' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    $P->deactivate_storage( 'store1', {} );   # drop any cached driver so _driver picks up this FAKE
    local $T::Plugin::CONN = T::FakeConn->new;
    my $name = $P->alloc_image( 'store1', { pool_id => '63' }, 700, 'raw', undef, 1 << 30 );

    my ( $path, $vmid, $vtype ) = $P->filesystem_path( {}, $name, 'store1' );
    like( $path, qr{^/dev/mapper/360060e80}, 'dm path from canonical identity' );
    is( $vmid, 700, 'vmid' );
    is( $vtype, 'images', 'vtype is the 3rd element (PVE contract)' );

    my $scalar = $P->path( {}, $name, 'store1' );
    is( $scalar, $path, 'path() scalar form matches' );
};

subtest 'vendor hooks: _alloc_backend_id requested_id, safe_delete_precheck default' => sub {
    package T::RangedPlugin;
    use parent -norequire, 'T::Plugin';
    our $RANGE_FAKE;
    sub _build_driver { return $RANGE_FAKE //= T::FakeDriver->new }
    sub _alloc_backend_id { return '4242' }   # subclass allocates an explicit id

    package main;
    local $T::RangedPlugin::RANGE_FAKE = T::FakeDriver->new;
    T::RangedPlugin->deactivate_storage( 'store1', {} );   # shared %DRIVERS cache reset
    my $name = T::RangedPlugin->alloc_image( 'store1', { pool_id => '63' }, 800, 'raw', undef, 1 << 30 );
    is( scalar( reg()->lookup($name) ), '4242', 'subclass _alloc_backend_id drove the backend id' );

    is( $P->safe_delete_precheck( {}, 'anything' ), 1, 'default safe_delete_precheck allows' );
};

done_testing();
