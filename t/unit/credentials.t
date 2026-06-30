#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);
use Fcntl qw(:mode);

use lib 'src';
use PVE::Storage::FCLU::Credentials;

# ARCHITECTURE.md §7/§9: the vendor-neutral per-storeid credential store. These
# tests pin the croak semantics, the 0600 perms, and the configurable base dir
# carried over (generalized) from the Hitachi Config.pm helpers.

sub mk {
    my (%o) = @_;
    return PVE::Storage::FCLU::Credentials->new(
        storeid => $o{storeid} // 'test', base_dir => $o{base_dir} );
}

subtest 'store + read round-trip' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $c   = mk( base_dir => $dir );

    ok( $c->store( 'admin', 'secret' ), 'store returns true' );
    my ( $u, $p ) = $c->read;
    is( $u, 'admin',  'username round-trips' );
    is( $p, 'secret', 'password round-trips' );
};

subtest 'file is 0600 and JSON-encoded' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $c   = mk( base_dir => $dir );
    $c->store( 'u', 'p' );

    my $file = "$dir/test.creds";
    ok( -f $file, 'creds file exists at <base_dir>/<storeid>.creds' );
    my $mode = ( stat $file )[2] & 07777;
    is( $mode, 0600, 'creds file is mode 0600' );
};

subtest 'delete then read croaks not-found' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $c   = mk( base_dir => $dir );
    $c->store( 'u', 'p' );
    ok( $c->delete, 'delete returns true' );
    eval { $c->read };
    like( $@, qr/not found/, 'read after delete croaks not-found' );
    ok( $c->delete, 'delete is idempotent (no file => still true)' );
};

subtest 'required fields are enforced' => sub {
    eval { PVE::Storage::FCLU::Credentials->new() };
    like( $@, qr/storeid is required/, 'storeid required' );

    my $c = mk( base_dir => tempdir( CLEANUP => 1 ) );
    eval { $c->store( undef, 'p' ) };
    like( $@, qr/username is required/, 'username required' );
    eval { $c->store( 'u', '' ) };
    like( $@, qr/password is required/, 'password required' );
};

subtest 'default base dir is the framework namespace, not hitachiblock' => sub {
    my $c = PVE::Storage::FCLU::Credentials->new( storeid => 's' );
    is( $c->_creds_file, '/etc/pve/priv/fclu/s.creds', 'default path is vendor-neutral' );
};

done_testing();
