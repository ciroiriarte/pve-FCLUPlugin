#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);
use JSON qw(encode_json);

use lib 'src';
use PVE::Storage::FCLU::Migrate::Hitachi;
use PVE::Storage::FCLU::Registry;
use PVE::Storage::FCLU::Credentials;

my $storeid = 'e590h-test';
my $legacy  = tempdir( CLEANUP => 1 );
my $fclu    = tempdir( CLEANUP => 1 );

sub spew { my ( $p, $c ) = @_; open my $fh, '>', $p or die "open $p: $!"; print $fh $c; close $fh; }
sub reg   { PVE::Storage::FCLU::Registry->new( storeid => $storeid, base_dir => $fclu ) }
sub creds { PVE::Storage::FCLU::Credentials->new( storeid => $storeid, base_dir => $fclu ) }

# A reference pve-storage-hitachiblock store: a plain volume, a linked clone (parent +
# #23 pair fields), a snapshotted + protected volume, and a name reservation to skip.
my %legacy_reg = (
    'base-9011-disk-1' => {
        ldev_id => 262, pool_id => 0, size_mb => 1454,
        wwid => '60060e8021a789005060a78900000106', timestamp => 1782626516,
    },
    'vm-9982-disk-2' => {
        ldev_id => 300, pool_id => 0, size_mb => 61440,
        wwid => '60060e8021a789005060a7890000012c',
        parent_volname => 'base-9120-disk-2', parent_snap => undef,
        clone_snapshot_id => '262,3', clone_pvol_ldev => 270,
    },
    'vm-7000-disk-1' => {
        ldev_id => 301, pool_id => 0, size_mb => 1024,
        wwid => '60060e8021a789005060a78900000200', protected => 1,
        snapshots => {
            # include the reference-only fields (pvol_ldev_id, svol_wwid) that FCLU does
            # not use, to prove they are safely dropped.
            snap1 => { snapshot_id => '301,0', snapshot_group => 'pve_e_301_snap1',
                       pvol_ldev_id => 301, svol_ldev_id => 310, svol_wwid => '60060e80...aa', timestamp => 100 },
            snap2 => { snapshot_id => '301,1', snapshot_group => 'pve_e_301_snap2',
                       pvol_ldev_id => 301, svol_ldev_id => 311, svol_wwid => '60060e80...bb', timestamp => 200 },
        },
    },
    # A prefixed/uppercase wwid to prove NAA canonicalization at migration time.
    'vm-6000-disk-0' => {
        ldev_id => 400, pool_id => 0, size_mb => 512,
        wwid => 'naa.60060E8021A789005060A789000002FF',
    },
    'vm-8000-disk-0' => { reserved => 1 },   # reservation, no ldev_id — must be skipped
);
spew( "$legacy/$storeid.json",  encode_json( \%legacy_reg ) );
spew( "$legacy/$storeid.creds", encode_json( { username => 'maintenance', password => 's3cret' } ) );

subtest '_transform_entry: field mapping (reference -> FCLU)' => sub {
    my ( $bid, $meta ) =
        PVE::Storage::FCLU::Migrate::Hitachi::_transform_entry( 'vm-9982-disk-2', $legacy_reg{'vm-9982-disk-2'} );
    is( $bid, '300', 'ldev_id -> stringified backend_id' );
    is( $meta->{identity}{protocol}, 'scsi-fc', 'identity protocol' );
    is( $meta->{identity}{ids}{naa}, '60060e8021a789005060a7890000012c', 'wwid -> identity.ids.naa' );
    is( $meta->{pool_ref}, '0', 'pool_id -> stringified pool_ref' );
    is( $meta->{parent_volname}, 'base-9120-disk-2', 'parent_volname preserved' );
    ok( !exists $meta->{parent_snap}, 'undef parent_snap not set' );
    is( $meta->{clone_backing_snap}, '262,3', 'clone_snapshot_id -> clone_backing_snap' );
    is( $meta->{clone_parent_backend}, '270', 'clone_pvol_ldev -> stringified clone_parent_backend' );
};

subtest 'dry-run writes nothing' => sub {
    my $s = PVE::Storage::FCLU::Migrate::Hitachi::migrate_store(
        storeid => $storeid, legacy_base => $legacy, fclu_base => $fclu, dry_run => 1 );
    is( scalar @{ $s->{volumes} }, 4, 'summary lists the 4 committed volumes (reservation skipped)' );
    is( $s->{creds}, 1, 'summary reports creds present' );
    is_deeply( reg()->list, {}, 'no FCLU registry written in dry-run' );
    ok( !-f "$fclu/$storeid.creds", 'no FCLU creds written in dry-run' );
};

subtest 'migrate_store: volumes, clone fields, snapshots, protected, creds' => sub {
    my $s = PVE::Storage::FCLU::Migrate::Hitachi::migrate_store(
        storeid => $storeid, legacy_base => $legacy, fclu_base => $fclu );
    is( scalar @{ $s->{volumes} }, 4, '4 volumes migrated' );
    is( $s->{snapshots}, 2, '2 snapshots migrated' );
    is( $s->{creds}, 1, 'creds migrated' );

    my ( $b, $meta ) = reg()->lookup('base-9011-disk-1');
    is( $b, '262', 'plain volume backend_id is a string' );
    is( $meta->{identity}{ids}{naa}, '60060e8021a789005060a78900000106', 'identity carried' );
    is( $meta->{pool_ref}, '0', 'pool_ref' );
    is( $meta->{size_mb}, 1454, 'size_mb' );

    ( undef, $meta ) = reg()->lookup('vm-9982-disk-2');
    is( $meta->{parent_volname}, 'base-9120-disk-2', 'clone parentage preserved' );
    is( $meta->{clone_backing_snap}, '262,3', '#23 backing-pair handle preserved' );
    is( $meta->{clone_parent_backend}, '270', '#23 pair P-VOL preserved (string)' );

    ( undef, $meta ) = reg()->lookup('vm-7000-disk-1');
    is( $meta->{protected}, 1, 'protected flag preserved' );
    my $sn1 = reg()->lookup_snapshot( 'vm-7000-disk-1', 'snap1' );
    is( $sn1->{snap_id}, '301,0', 'snapshot snapshot_id -> snap_id' );
    is( $sn1->{group}, 'pve_e_301_snap1', 'snapshot_group -> group' );
    is( $sn1->{svol}, '310', 'svol_ldev_id -> svol (string)' );
    is( $sn1->{seq}, 0, 'oldest snapshot seq 0' );
    is( reg()->lookup_snapshot( 'vm-7000-disk-1', 'snap2' )->{seq}, 1, 'next snapshot seq 1' );
    ok( !exists $sn1->{svol_wwid} && !exists $sn1->{pvol_ldev_id},
        'reference-only snapshot fields (svol_wwid/pvol_ldev_id) dropped' );

    # NAA canonicalization: prefixed/uppercase wwid -> stripped + lowercased identity.
    ( undef, $meta ) = reg()->lookup('vm-6000-disk-0');
    is( $meta->{identity}{ids}{naa}, '60060e8021a789005060a789000002ff',
        'wwid naa.<UPPER> normalized to bare lowercase (byte-identical to a fresh alloc)' );

    is( reg()->lookup('vm-8000-disk-0'), undef, 'reservation (no ldev_id) skipped' );

    my ( $u, $p ) = creds()->read;
    is( $u, 'maintenance', 'username migrated' );
    is( $p, 's3cret', 'password migrated' );
};

subtest 'idempotent re-run (register merges the same backend_id)' => sub {
    my $s = PVE::Storage::FCLU::Migrate::Hitachi::migrate_store(
        storeid => $storeid, legacy_base => $legacy, fclu_base => $fclu );
    is( scalar @{ $s->{volumes} }, 4, 're-run migrates the same 4 volumes without error' );
    is( ( reg()->lookup('base-9011-disk-1') ), '262', 'backend_id stable after re-run' );
};

subtest 'missing legacy store dies clearly' => sub {
    eval {
        PVE::Storage::FCLU::Migrate::Hitachi::migrate_store(
            storeid => 'nope', legacy_base => $legacy, fclu_base => $fclu );
    };
    like( $@, qr/no legacy registry/, 'a missing legacy store is a clear error' );
};

done_testing();
