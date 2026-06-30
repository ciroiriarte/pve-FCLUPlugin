#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use lib 'src';

use PVE::Storage::FCLU::Error;

# ARCHITECTURE.md §13: the normalized error type drivers die with. These tests
# pin the normative behaviour (closed code vocabulary, default classification,
# admin-safe stringification) so a future change that breaks the contract — an
# api-2 bump — is caught here.

subtest 'default classification per code (§13.3)' => sub {
    my %expect = (
        connectivity   => [ 1, 1 ],
        auth           => [ 0, 0 ],
        array_busy     => [ 1, 1 ],
        conflict       => [ 0, 1 ],
        not_found      => [ 0, 0 ],
        already_exists => [ 0, 0 ],
        out_of_space   => [ 0, 0 ],
        limit          => [ 0, 0 ],
        unsupported    => [ 0, 0 ],
        invalid        => [ 0, 0 ],
        timeout        => [ 0, 1 ],
        partial        => [ 0, 0 ],
        internal       => [ 0, 0 ],
    );

    # The module's advertised vocabulary must match the contract exactly — no
    # missing codes, no extras.
    is_deeply( [ PVE::Storage::FCLU::Error->codes ],
        [ sort keys %expect ], 'code vocabulary is exactly the §13.3 set' );

    for my $code ( sort keys %expect ) {
        my $e = PVE::Storage::FCLU::Error->new( code => $code, message => 'x' );
        isa_ok( $e, 'PVE::Storage::FCLU::Error', $code );
        is( $e->code,         $code,            "$code: code accessor" );
        is( $e->is_retryable, $expect{$code}[0], "$code: default retryable" );
        is( $e->is_transient, $expect{$code}[1], "$code: default transient" );
    }
};

subtest 'explicit overrides win, and 0 is preserved' => sub {
    # A read-only timeout is retryable (§13.3 note) — the override must take.
    my $r = PVE::Storage::FCLU::Error->new(
        code => 'timeout', message => 'read probe', retryable => 1 );
    is( $r->is_retryable, 1, 'retryable override to 1' );
    is( $r->is_transient, 1, 'transient default kept' );

    # An explicit 0 must not be swallowed by the default (the `//` guard).
    my $z = PVE::Storage::FCLU::Error->new(
        code => 'connectivity', message => 'x', retryable => 0, transient => 0 );
    is( $z->is_retryable, 0, 'explicit retryable=0 preserved over default 1' );
    is( $z->is_transient, 0, 'explicit transient=0 preserved over default 1' );

    # Booleans are normalized to strict 0|1 regardless of truthy input shape.
    my $n = PVE::Storage::FCLU::Error->new(
        code => 'auth', message => 'x', retryable => 'yes', transient => [1] );
    is( $n->is_retryable, 1, 'truthy override normalized to 1' );
    is( $n->is_transient, 1, 'truthy override normalized to 1' );
};

subtest 'required fields + closed vocabulary are enforced' => sub {
    eval { PVE::Storage::FCLU::Error->new( message => 'x' ) };
    like( $@, qr/'code' is required/, 'missing code dies' );

    eval { PVE::Storage::FCLU::Error->new( code => 'bogus', message => 'x' ) };
    like( $@, qr/unknown code 'bogus'/, 'code outside the closed vocab dies' );

    eval { PVE::Storage::FCLU::Error->new( code => 'auth' ) };
    like( $@, qr/'message' is required/, 'missing message dies' );

    eval { PVE::Storage::FCLU::Error->new( code => 'auth', message => '' ) };
    like( $@, qr/'message' is required/, 'empty message dies' );
};

subtest 'throw() dies with a blessed, catchable object' => sub {
    my $ok = eval {
        PVE::Storage::FCLU::Error->throw(
            code => 'out_of_space', message => 'pool full' );
        1;
    };
    ok( !$ok, 'throw raised an exception' );

    my $e = $@;
    isa_ok( $e, 'PVE::Storage::FCLU::Error', 'thrown value' );
    is( $e->code,    'out_of_space', 'code survives throw' );
    is( $e->message, 'pool full',    'message survives throw' );
};

subtest 'stringification is admin-safe — no vendor payload (§13.5)' => sub {
    my $e = PVE::Storage::FCLU::Error->new(
        code    => 'internal',
        message => 'unexpected vendor payload',
        vendor  => { secret => 'TOPSECRET', raw => 'do-not-leak' },
        cause   => 'lower-level boom',
    );

    my $s = "$e";    # overloaded stringification
    like( $s, qr/\Q[internal] unexpected vendor payload\E/,
        'renders code + message' );
    unlike( $s, qr/TOPSECRET|do-not-leak/,
        'vendor blob is NOT in the string (logs only)' );

    is_deeply( $e->vendor, { secret => 'TOPSECRET', raw => 'do-not-leak' },
        'vendor blob retained for log diagnosis' );
    is( $e->cause, 'lower-level boom', 'cause retained' );
};

done_testing();
