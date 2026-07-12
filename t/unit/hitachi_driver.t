#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use lib 'src';
use PVE::Storage::FCLU::Driver::Hitachi;
use PVE::Storage::FCLU::Driver::Hitachi::RestClient;   # defines the RestError class
use PVE::Storage::FCLU::Capabilities;

# §9 Phase 1 step 3 (slice A): the Driver::Hitachi spine — profile/port selection
# (incl the Ops Center vs embedded distinction), the §6 capability shape, and the
# §13 error-translation boundary that maps RestClient bare-string dies to a
# classified FCLU::Error.

# Minimal scripted/recording rest stub. Methods return a scripted value or die a
# scripted string (for error-translation tests).
package MockRest;
sub new { bless { log => [], plan => {} }, shift }
sub _do {
    my ( $self, $name, @args ) = @_;
    push @{ $self->{log} }, [ $name, @args ];
    my $p = $self->{plan}{$name};
    return ( ref $p eq 'CODE' ) ? $p->(@args) : $p;
}
our $AUTOLOAD;
sub AUTOLOAD {
    my $self = shift;
    ( my $name = $AUTOLOAD ) =~ s/.*:://;
    return if $name eq 'DESTROY';
    return $self->_do( $name, @_ );
}

package main;

sub drv {
    my (%o) = @_;
    return PVE::Storage::FCLU::Driver::Hitachi->new(
        platform => $o{platform} // 'vsp_one',
        rest     => $o{rest} // MockRest->new,
        pool_id  => $o{pool_id},
    );
}

subtest 'is a Driver subclass' => sub {
    isa_ok( drv(), 'PVE::Storage::FCLU::Driver', 'Driver::Hitachi' );
    eval { PVE::Storage::FCLU::Driver::Hitachi->new( platform => 'bogus', rest => MockRest->new ) };
    like( $@, qr/unknown platform/, 'unknown platform rejected' );
};

subtest 'profile encodes the Ops Center vs embedded control-plane port (§4)' => sub {
    is( drv( platform => 'vsp_g' )->detect_profile->{default_port}, 23451,
        'vsp_g -> Ops Center Configuration Manager server (23451)' );
    is( drv( platform => 'vsp_e' )->detect_profile->{default_port}, 443,
        'vsp_e -> embedded/direct GUM REST (443)' );
    is( drv( platform => 'vsp_one' )->detect_profile->{default_port}, 443, 'vsp_one -> 443' );
    is( drv( platform => 'vsp_e' )->profile->{min_lu_mb}, 48, 'min_lu_mb floor (KART)' );
    ok( drv( platform => 'vsp_e' )->profile->{quirks}{used_pool_capacity_missing},
        'E590H quirk present on vsp_e' );
};

subtest 'capabilities is a conformant §6 object reflecting the profile' => sub {
    my $cap = drv( platform => 'vsp_e' )->capabilities;
    my $C   = 'PVE::Storage::FCLU::Capabilities';
    is_deeply( [ sort keys %$cap ], [ sort $C->branches ], 'all seven branches present' );
    is( $C->has_feature( $cap, 'snapshot', 'single' ),  1, 'snapshot advertised' );
    is( $C->has_feature( $cap, 'clone', 'linked' ),     1, 'linked clone advertised' );
    is( $C->has_feature( $cap, 'qos', 'per_lu' ),       0,
        'qos NOT advertised on vsp_e (E series has no QoS per Hitachi support matrix)' );
    is( $C->has_feature( $cap, 'resize', 'grow_online'),1, 'grow advertised' );
    is_deeply( $cap->{replication}, {}, 'replication off by default (gated, §8)' );

    # QoS is model-gated: VSP One Block also lacks it; only vsp_g (VSP F/G350-900 via
    # Ops Center CM) advertises it. See %PLATFORM + the OpenStack HBSD QoS matrix.
    is( $C->has_feature( drv( platform => 'vsp_one' )->capabilities, 'qos', 'per_lu' ), 0,
        'qos NOT advertised on vsp_one' );
    is( $C->has_feature( drv( platform => 'vsp_g' )->capabilities, 'qos', 'per_lu' ), 1,
        'qos advertised on vsp_g (Ops Center CM; F/G350-900)' );
};

subtest 'connect/disconnect/ping wrap the transport; logout never propagates' => sub {
    my $m = MockRest->new;
    my $d = drv( rest => $m );
    $d->connect;
    $d->ping;
    is( $m->{log}[0][0], 'login',     'connect -> login' );
    is( $m->{log}[1][0], 'keepalive', 'ping -> keepalive' );

    $m->{plan}{logout} = sub { die "boom\n" };
    is( $d->disconnect, 1, 'disconnect swallows a logout failure (guaranteed teardown)' );
};

subtest '_translate_rest_error maps RestClient strings to §13 codes' => sub {
    my $d = drv();
    my %cases = (
        'API request failed: GET https://a/ldevs/9 -> 401 Unauthorized'        => 'auth',
        'API request failed: GET https://a/ldevs/9 -> 404 Not Found'           => 'not_found',
        'API request failed: POST https://a/ldevs -> 409 Conflict already exists' => 'already_exists',
        'API request failed: POST https://a/ldevs -> 409 Conflict locked'      => 'conflict',
        'API request failed: GET https://a -> 429 Too Many Requests'           => 'array_busy',
        'API request failed: GET https://a -> 503 Service Unavailable'         => 'array_busy',
        'API request failed: POST https://a -> 400 Bad Request'                => 'invalid',
        'Job job-7 timed out after 300s'                                       => 'timeout',
        q{API request failed: GET https://a -> 500 Can't connect to a:443}     => 'connectivity',
        'Job job-3 failed: pool capacity insufficient'                         => 'out_of_space',
        'Job job-4 failed: maximum number of LDEVs reached'                    => 'limit',
        'Job job-5 failed: some weird thing'                                   => 'internal',
        # A mapping PRECONDITION, not an absent object — must NOT be not_found even
        # though the array's phrasing ends with "...or the ... pair does not exist".
        'Job 3602 failed: An error occurred in the storage system. (message = The specified snapshot P-VOL does not have LU paths, or the specified snapshot pair does not exist.)' => 'invalid',
    );
    for my $str ( sort keys %cases ) {
        my $e = $d->_translate_rest_error($str);
        isa_ok( $e, 'PVE::Storage::FCLU::Error', $cases{$str} );
        is( $e->code, $cases{$str}, "'$str' -> $cases{$str}" );
        like( $e->is_retryable, qr/^[01]$/, 'retryable classified' );
        unlike( "$e", qr{\Qhttps://a\E}, 'admin message excludes the raw url (§13.5)' );
        is( $e->vendor->{raw}, $str, 'raw text kept in vendor blob (logs only)' );
    }

    # An already-FCLU::Error passes through unchanged.
    my $orig = PVE::Storage::FCLU::Error->new( code => 'auth', message => 'x' );
    is( $d->_translate_rest_error($orig), $orig, 'existing FCLU::Error not re-wrapped' );
};

subtest '_call rethrows a translated error and passes success through' => sub {
    my $m = MockRest->new;
    my $d = drv( rest => $m );
    $m->{plan}{get_pool} = sub { die "API request failed: GET x -> 404 Not Found\n" };
    # Capture $@ into a lexical immediately — an intervening Test::More call would
    # otherwise clobber $@ before we inspect it.
    my $err;
    my $ok = eval { $d->_call( sub { $m->get_pool } ); 1 };
    $err = $@ unless $ok;
    ok( !$ok, '_call propagated the failure' );
    isa_ok( $err, 'PVE::Storage::FCLU::Error', 'translated' );
    is( $err->code, 'not_found', 'mapped to not_found' );

    $m->{plan}{get_pool} = sub { { ok => 1 } };
    is_deeply( $d->_call( sub { $m->get_pool } ), { ok => 1 }, 'success passes through' );
};

subtest 'T3-8: _translate classifies off structured messageId/SSB code first' => sub {
    my $d = drv();
    my $RE = 'PVE::Storage::FCLU::Driver::Hitachi::RestError';

    my %ssb = (
        '2E22,0001' => 'already_exists',   # LDEV already defined
        'B958,015A' => 'already_exists',   # LU path already defined
        'B958,0947' => 'conflict',         # another LDEV mapped
        'B957,4184' => 'limit',            # exceed max WWN
        '2E11,2209' => 'limit',            # no available ldev id
        '2E30,600E' => 'invalid',          # invalid snapshot pool
        '2E11,2205' => 'array_busy',       # resource locked
        '2E11,2206' => 'array_busy',       # resource locked (mid of the 2205-2207 range)
    );
    for my $k ( sort keys %ssb ) {
        my ( $s1, $s2 ) = split /,/, $k;
        my $e = $d->_translate_rest_error(
            $RE->new( message => "Job 5 failed: whatever", ssb1 => $s1, ssb2 => $s2 ) );
        is( $e->code, $ssb{$k}, "SSB $k -> $ssb{$k}" );
        is( $e->vendor->{ssb}, $k, "SSB $k preserved in vendor blob" );
    }

    # messageId classification.
    is( $d->_translate_rest_error( $RE->new( message => 'Job 1 failed: busy', message_id => 'KART00003-E' ) )->code,
        'array_busy', 'KART00003-E (REST busy) -> array_busy' );
    my $nf = $d->_translate_rest_error( $RE->new( message => 'Job 2 failed: gone', message_id => 'KART30013-E' ) );
    is( $nf->code, 'not_found', 'KART30013-E -> not_found' );
    is( $nf->vendor->{message_id}, 'KART30013-E', 'messageId preserved in vendor blob' );

    # PRECEDENCE: a stable code wins over misleading English text. The array phrases
    # LDEV-already-defined with "... does not exist" nearby, which the regex would call
    # not_found; the SSB pins it to already_exists.
    my $p = $d->_translate_rest_error( $RE->new(
        message => 'Job 3 failed: the specified object does not exist', ssb1 => '2E22', ssb2 => '0001' ) );
    is( $p->code, 'already_exists', 'structured SSB overrides the "does not exist" regex' );

    # Fallback: a RestError with NO structured code still classifies off HTTP status.
    my $fb = $d->_translate_rest_error(
        $RE->new( message => 'API request failed: POST https://a/ldevs -> 409 Conflict locked', http_status => 409 ) );
    is( $fb->code, 'conflict', 'no SSB -> falls back to the HTTP-status regex' );
};

done_testing();
