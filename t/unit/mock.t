#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use lib 'src';

use PVE::Storage::FCLU::Driver::Mock;
use PVE::Storage::FCLU::Error;

# ARCHITECTURE.md §12.5 / §13.6: Mock is the executable reference. mock.t pins the
# Mock-SPECIFIC behaviour — fault injection, capacity accounting, deterministic
# ids — that the generic contract suite (contract_mock.t) does not assert. The
# api-1 behavioural contract itself lives in the parametrized harness.

sub mk { PVE::Storage::FCLU::Driver::Mock->new(@_) }

subtest 'is a Driver and answers the whole contract surface' => sub {
    my $m = mk();
    isa_ok( $m, 'PVE::Storage::FCLU::Driver', 'Mock' );
    for my $meth ( PVE::Storage::FCLU::Driver->contract_methods ) {
        # An overridden method must NOT be the croaking base stub.
        my $base = PVE::Storage::FCLU::Driver->can($meth);
        my $impl = PVE::Storage::FCLU::Driver::Mock->can($meth);
        isnt( $impl, $base, "$meth is implemented (not the base stub)" );
    }
};

subtest 'arm_fault raises the requested code, then clears' => sub {
    my $m = mk();
    $m->arm_fault( 'create_lu', code => 'array_busy' );

    my $e = exception( sub { $m->create_lu( size_bytes => 1024 ) } );
    isa_ok( $e, 'PVE::Storage::FCLU::Error', 'injected error' );
    is( $e->code,         'array_busy', 'injected code surfaces' );
    is( $e->is_retryable, 1,            'array_busy default classification carried' );

    # Fault was one-shot (times default 1): the next call succeeds.
    my $bid = $m->create_lu( size_bytes => 1024 );
    ok( defined $bid && length $bid, 'call after a one-shot fault succeeds' );
};

subtest 'arm_fault honours times, always, and explicit classification' => sub {
    my $m = mk();
    $m->arm_fault( 'ping', code => 'connectivity', times => 2 );
    ok( exception( sub { $m->ping } ), 'ping fails 1st' );
    ok( exception( sub { $m->ping } ), 'ping fails 2nd' );
    ok( !exception( sub { $m->ping } ), 'ping succeeds 3rd (times exhausted)' );

    $m->arm_fault( 'get_lu', code => 'connectivity', always => 1 );
    ok( exception( sub { $m->get_lu('x') } ), 'always-fault fires once' );
    ok( exception( sub { $m->get_lu('x') } ), 'always-fault fires again' );
    $m->clear_faults('get_lu');
    # now get_lu reaches real logic: missing id => not_found
    my $e = exception( sub { $m->get_lu('nope') } );
    is( $e->code, 'not_found', 'after clear, real logic runs' );

    # Explicit classification override on the injected error.
    $m->arm_fault( 'resize_lu', code => 'timeout', retryable => 1 );
    my $te = exception( sub { $m->resize_lu( 'x', 1 ) } );
    is( $te->code,         'timeout', 'timeout injected' );
    is( $te->is_retryable, 1,         'explicit retryable override carried' );
};

subtest 'capacity accounting: create / delete / resize move pool_free' => sub {
    my $m = mk( pool_total => 1000 );
    my ( $t0, $f0, $u0 ) = $m->storage_status;
    is( $t0, 1000, 'total' );
    is( $f0, 1000, 'free starts at total' );
    is( $u0, 0,    'used starts at 0' );

    my $a = $m->create_lu( size_bytes => 400 );
    my $b = $m->create_lu( size_bytes => 300 );
    ( undef, my $f1, my $u1 ) = $m->storage_status;
    is( $f1, 300, 'free reduced by 700' );
    is( $u1, 700, 'used is 700' );

    # Out of space is structural.
    my $e = exception( sub { $m->create_lu( size_bytes => 500 ) } );
    is( $e->code, 'out_of_space', 'over-allocation => out_of_space' );

    $m->resize_lu( $a, 500 );   # grow by 100
    ( undef, my $f2 ) = $m->storage_status;
    is( $f2, 200, 'grow consumed 100 more' );

    $m->delete_lu($b);          # free 300
    ( undef, my $f3 ) = $m->storage_status;
    is( $f3, 500, 'delete returned the LU space' );
};

subtest 'deterministic identity is array-reported lowercase-hex naa' => sub {
    my $m   = mk();
    my $bid = $m->create_lu( size_bytes => 1024 );
    my $id  = $m->get_lu_identity($bid);
    is( $id->{protocol}, 'scsi-fc', 'protocol' );
    like( $id->{ids}{naa}, qr/^[0-9a-f]+$/, 'naa is lowercase hex' );
    ok( !defined $id->{ids}{eui}, 'eui undef when unknown' );
};

subtest 'returned descriptors are copies — core cannot mutate driver state' => sub {
    my $m   = mk();
    my $bid = $m->create_lu( size_bytes => 1024, label => 'orig' );
    my $lu  = $m->get_lu($bid);
    $lu->{label}      = 'tampered';
    $lu->{identity}{ids}{naa} = 'deadbeef';
    my $fresh = $m->get_lu($bid);
    is( $fresh->{label}, 'orig', 'label untouched by caller mutation' );
    like( $fresh->{identity}{ids}{naa}, qr/^60060e80/, 'identity untouched' );
};

subtest 'configurable capabilities flow through' => sub {
    my $m = mk( capabilities => { snapshot => { single => 1 } } );
    my $cap = $m->capabilities;
    is( $cap->{snapshot}{single}, 1, 'advertised cap present' );
    is_deeply( $cap->{clone}, {}, 'unadvertised branch normalized to {}' );
};

# Minimal Try::Tiny-free exception helper.
sub exception {
    my ($code) = @_;
    my $err;
    { local $@; eval { $code->(); 1 } or $err = $@; }
    return $err;
}

done_testing();
