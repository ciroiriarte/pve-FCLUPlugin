#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Digest::MD5 qw(md5_hex);

use lib 'src';
use PVE::Storage::FCLU::Label;

my $L = 'PVE::Storage::FCLU::Label';

# ARCHITECTURE.md §7/§9: ownership-label synthesis with a DRIVER-supplied max_len
# (no hardcoded 32 in the core). These tests pin the readable label, the hashed
# fallback at a tight limit, the no-limit case, and parse behaviour.

subtest 'readable label when it fits (or no limit)' => sub {
    is( $L->make_label( 'myarray', 'vm-100-disk-1' ),
        'pve:myarray:vm-100-disk-1', 'no max_len => full readable label' );
    is( $L->make_label( 'myarray', 'vm-100-disk-1', 64 ),
        'pve:myarray:vm-100-disk-1', 'generous max_len => full readable label' );
    is( $L->label_prefix( 'myarray', 32 ), 'pve:myarray:', 'prefix readable at 32' );
};

subtest 'hashed fallback when the readable prefix will not fit' => sub {
    # A long storeid at the classic 32-char Hitachi limit forces the hash.
    my $storeid = 'verylongstorageidentifier12345';
    my $hash    = substr( md5_hex($storeid), 0, 8 );

    my $prefix = $L->label_prefix( $storeid, 32 );
    is( $prefix, "pve:${hash}:", 'long storeid at max_len=32 => hashed prefix' );

    my $label = $L->make_label( $storeid, 'vm-100-disk-1', 32 );
    is( $label, "pve:${hash}:vm-100-disk-1", 'label uses the hashed prefix' );
    cmp_ok( length($label), '<=', 32, 'label stays within max_len' );
};

subtest 'final clamp guarantees the bound even with a long volname' => sub {
    my $label = $L->make_label( 'a', 'x' x 100, 16 );
    cmp_ok( length($label), '<=', 16, 'over-long label is clamped to max_len' );
};

subtest 'parse_label round-trips and rejects junk' => sub {
    my $p = $L->parse_label('pve:myarray:vm-100-disk-1');
    is( $p->{storeid}, 'myarray',       'parsed storeid' );
    is( $p->{volname}, 'vm-100-disk-1', 'parsed volname' );

    # Volname containing a colon (cloud-init style) is preserved after the 2nd ':'.
    my $p2 = $L->parse_label('pve:store:vm-9-cloudinit');
    is( $p2->{volname}, 'vm-9-cloudinit', 'cloudinit volname parsed' );

    is( $L->parse_label('garbage'), undef, 'non-matching label => undef' );
    is( $L->parse_label(undef),     undef, 'undef label => undef' );
    is( $L->parse_label(''),        undef, 'empty label => undef' );
};

subtest 'required args are enforced' => sub {
    eval { $L->label_prefix( undef, 32 ) };
    like( $@, qr/storeid is required/, 'storeid required for prefix' );
    eval { $L->make_label( 's', undef, 32 ) };
    like( $@, qr/volname is required/, 'volname required for make_label' );
};

done_testing();
