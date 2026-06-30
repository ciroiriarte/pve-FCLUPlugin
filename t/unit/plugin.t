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

# A fake array driver (the §2 surface the plugin actually calls in slice 4A).
{
    package T::FakeDriver;
    sub new { bless { connected => 0, status => $_[1] }, $_[0] }
    sub connect    { $_[0]{connected} = 1; $_[0] }
    sub disconnect { $_[0]{connected} = 0; 1 }
    sub storage_status { @{ $_[0]{status} // [ 1000, 600, 400 ] } }
}

# A concrete vendor subclass providing the abstract hooks + injecting the fake.
{
    package T::Plugin;
    use parent -norequire, 'PVE::Storage::FCLU::Plugin';
    our $FAKE;
    sub type          { 'testblock' }
    sub vendor        { 'test' }
    sub driver_class  { 'T::FakeDriver' }
    sub driver_config { { platform => 'vsp_e', pool_id => '63' } }
    sub _build_driver { return $FAKE //= T::FakeDriver->new }
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

done_testing();
