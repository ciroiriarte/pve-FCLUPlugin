#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);

# Minimal PVE stubs so the FCLU base (and thus the subclass) compiles standalone.
BEGIN {
    $INC{'PVE/Storage/Plugin.pm'} = 1;
    package PVE::Storage::Plugin;
    sub api { 0 }
    package PVE::Storage;
    sub APIVER { 11 }
}

use lib 'src';
use PVE::Storage::Custom::HitachiBlockPlugin;

my $HB = 'PVE::Storage::Custom::HitachiBlockPlugin';

my $dir = tempdir( CLEANUP => 1 );
$PVE::Storage::FCLU::Plugin::REGISTRY_BASE_DIR = $dir;
sub reg { PVE::Storage::FCLU::Registry->new( storeid => 's1', base_dir => $dir ) }

# A fake driver exposing only the vendor allocation hook the plugin calls.
{
    package T::HDriver;
    sub new { bless { calls => {} }, shift }
    sub next_free_backend_id {
        my ( $s, %a ) = @_;
        $s->{calls}{next} = \%a;
        my %used = map { ( "$_" => 1 ) } @{ $a{reserved} // [] };
        for my $id ( $a{min} .. $a{max} ) { return "$id" unless $used{"$id"} }
        die "no free id\n";
    }
}

subtest 'vendor identity + driver_class' => sub {
    is( $HB->type, 'hitachiblock', 'type' );
    is( $HB->vendor, 'hitachi', 'vendor' );
    is( $HB->driver_class, 'PVE::Storage::FCLU::Driver::Hitachi', 'driver_class' );
    is( $HB->connector_class, 'PVE::Storage::FCLU::Host::FCMultipath', 'inherited connector default' );
};

subtest 'driver_config maps storage.cfg to the Driver::Hitachi constructor opts' => sub {
    my $cfg = $HB->driver_config( {
        platform => 'vsp_e', pool_id => '63', snap_pool_id => '64', mgmt_ip => '10.0.0.1',
        storage_id => '900000012345', mgmt_port => 443, tls_verify => 1, tls_ca_file => '/ca',
        rest_keepalive => 1, target_ports => 'CL1-A,CL2-A', host_mode => 'LINUX/IRIX',
        host_mode_options => '2,22,25,68', skip_unmap_io_check => 1, host_group_prefix => 'clsX',
    } );
    is( $cfg->{platform}, 'vsp_e', 'platform' );
    is( $cfg->{array_ports}, 'CL1-A,CL2-A', 'target_ports -> array_ports' );
    is( $cfg->{port}, 443, 'mgmt_port -> port' );
    is( $cfg->{sessionless}, 0, 'rest_keepalive=1 -> sessionless=0' );
    is( $cfg->{snap_pool_id}, '64', 'snap_pool_id passed' );
    is( $cfg->{skip_unmap_io_check}, 1, 'skip_unmap_io_check passed' );
    is( $cfg->{host_group_prefix}, 'clsX', 'explicit host_group_prefix passed through' );

    my $def = $HB->driver_config( {} );
    is( $def->{platform}, 'vsp_one', 'default platform vsp_one' );
    is( $def->{sessionless}, 1, 'default sessionless=1 (session-less)' );
    is( $def->{host_group_prefix}, 'PVE', 'host_group_prefix defaults to a stable, short "PVE" (context-independent)' );
    ok( !exists $def->{port}, 'no port when mgmt_port unset (driver uses profile default)' );
    ok( !exists $def->{tls_verify}, 'no tls_verify key when unset' );
};

subtest 'properties/options merge over the base + avoid the SectionConfig landmine' => sub {
    my $props = $HB->properties;
    ok( $props->{mgmt_ip} && $props->{pool_id} && $props->{lock_timeout}, 'inherited base properties' );
    ok( $props->{storage_id} && $props->{target_ports} && $props->{ldev_range}, 'vendor properties present' );
    ok( $props->{host_group_prefix}, 'host_group_prefix property present (multi-cluster namespacing)' );
    is( $props->{platform}{enum}[0], 'vsp_g', 'platform enum declared' );
    ok( !exists $props->{username}, 'username NOT redeclared (avoids duplicate-property die)' );
    ok( !exists $props->{password}, 'password NOT redeclared' );

    my $opts = $HB->options;
    ok( $opts->{username} && $opts->{password}, 'inherited username/password references' );
    ok( $opts->{target_ports}{fixed} && $opts->{storage_id}{fixed}, 'vendor fixed keys' );
    ok( $opts->{ldev_range}{optional}, 'ldev_range optional' );
};

subtest 'safe_delete_precheck: the §7 ldev_range fence' => sub {
    is( $HB->safe_delete_precheck( { ldev_range => '1000-1999' }, '1500' ), 1, 'in-range id allowed' );
    is( $HB->safe_delete_precheck( { ldev_range => '1000-1999' }, '2500' ), 0, 'out-of-range id blocked' );
    is( $HB->safe_delete_precheck( { ldev_range => '1000-1999' }, '1000' ), 1, 'lower bound inclusive' );
    is( $HB->safe_delete_precheck( { ldev_range => '1000-1999' }, '1999' ), 1, 'upper bound inclusive' );
    is( $HB->safe_delete_precheck( {}, '99999' ), 1, 'no range -> allowed (registry is the primary fence)' );
};

subtest '_alloc_backend_id: next free in-range id, excluding registry-reserved ids' => sub {
    reg()->register( 'vm-1-disk-0', '1000' );
    reg()->register( 'vm-2-disk-0', '1001' );
    my $d = T::HDriver->new;

    my $id = $HB->_alloc_backend_id( 's1', { ldev_range => '1000-1999' }, $d );
    is( $id, '1002', 'returns the first free in-range id, skipping reserved' );
    is_deeply( [ sort @{ $d->{calls}{next}{reserved} } ], [ '1000', '1001' ],
        'registry-claimed backend ids passed as reserved' );
    is( $d->{calls}{next}{min}, 1000, 'min from ldev_range' );
    is( $d->{calls}{next}{max}, 1999, 'max from ldev_range' );

    is( $HB->_alloc_backend_id( 's1', {}, $d ), undef, 'no ldev_range -> undef (array auto-assigns)' );
};

subtest '_parse_ldev_range + CU-alignment hint' => sub {
    is_deeply( [ $HB->_parse_ldev_range('1000-1999') ], [ 1000, 1999 ], 'decimal range' );
    is_deeply( [ $HB->_parse_ldev_range('0x3E8-0x7CF') ], [ 1000, 1999 ], 'hex range' );
    eval { $HB->_parse_ldev_range('garbage') };
    like( $@, qr/invalid ldev_range/, 'malformed range dies' );
    eval { $HB->_parse_ldev_range('2000-1000') };
    like( $@, qr/min .* > max/, 'inverted range dies' );

    my @warns;
    local $SIG{__WARN__} = sub { push @warns, $_[0] };
    $HB->_warn_if_ldev_range_misaligned('1000-1999');
    ok( ( grep { /not CU-aligned/ } @warns ), 'misaligned range warns (non-fatal)' );

    @warns = ();
    $HB->_warn_if_ldev_range_misaligned('0-255');
    is( scalar @warns, 0, 'a CU-aligned range is silent' );

    @warns = ();
    $HB->_warn_if_ldev_range_misaligned(undef);
    is( scalar @warns, 0, 'an unset range is silent' );
};

done_testing();
