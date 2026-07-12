#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use lib 'src';
use PVE::Storage::FCLU::Driver::Hitachi::RestClient;

# §9 Phase 1 step 3: the Hitachi RestClient transport vendored into the framework
# (wrap, don't rewrite). These tests confirm the moved transport loads and behaves
# under its new package name, using the reference mock pattern (override _request
# with canned responses — no network). They pin the load-bearing request-shaping
# and async-job-id extraction that the driver relies on.

package MockRestClient;
use parent -norequire, 'PVE::Storage::FCLU::Driver::Hitachi::RestClient';

my @mock_responses;
my @request_log;

sub set_mock_responses { @mock_responses = @_ }
sub get_request_log    { return @request_log }
sub clear_request_log  { @request_log = () }

sub _request {
    my ($self, $method, $url, $body, $skip_reauth) = @_;
    push @request_log, { method => $method, url => $url, body => $body };
    if (@mock_responses) {
        my $response = shift @mock_responses;
        return ref $response eq 'CODE' ? $response->( $method, $url, $body ) : $response;
    }
    return {};
}

package main;

sub new_mock_client {
    my $client = MockRestClient->new(
        mgmt_ip    => '10.0.1.100',
        storage_id => '836000123456',
        username   => 'admin',
        password   => 'secret',
        port       => 443,
    );
    $client->{token}      = 'mock_token';
    $client->{session_id} = 'mock_session';
    MockRestClient::clear_request_log();
    return $client;
}

subtest 'constructor validates required fields and builds the CM base url' => sub {
    my $c = new_mock_client();
    isa_ok( $c, 'PVE::Storage::FCLU::Driver::Hitachi::RestClient', 'client' );
    like( $c->{base_url},
        qr{^https://10\.0\.1\.100:443/ConfigurationManager/v1/objects/storages/836000123456$},
        'Configuration Manager base url' );

    eval { PVE::Storage::FCLU::Driver::Hitachi::RestClient->new( storage_id => 'x', username => 'u', password => 'p' ) };
    like( $@, qr/mgmt_ip is required/, 'mgmt_ip required' );

    # Async-job poll budget is configurable (driven by the driver's op_timeout_s) so a
    # large Thin Image clone that runs past the default 300s does not time out.
    my $cj = PVE::Storage::FCLU::Driver::Hitachi::RestClient->new(
        mgmt_ip => '10.0.1.100', storage_id => 'x', username => 'u', password => 'p', job_timeout => 600 );
    is( $cj->{job_timeout}, 600, 'job_timeout honoured from opts' );
    my $def = PVE::Storage::FCLU::Driver::Hitachi::RestClient->new(
        mgmt_ip => '10.0.1.100', storage_id => 'x', username => 'u', password => 'p' );
    is( $def->{job_timeout}, 300, 'job_timeout falls back to the 300s default' );
};

subtest 'control_plane picks the default endpoint port (§10 Ops Center CM)' => sub {
    my %base = ( mgmt_ip => 'h', storage_id => 'x', username => 'u', password => 'p' );
    is( PVE::Storage::FCLU::Driver::Hitachi::RestClient->new(%base)->{port}, 443,
        'embedded (default) -> port 443' );
    is( PVE::Storage::FCLU::Driver::Hitachi::RestClient->new(%base, control_plane => 'embedded')->{port}, 443,
        'control_plane=embedded -> 443' );
    is( PVE::Storage::FCLU::Driver::Hitachi::RestClient->new(%base, control_plane => 'cm')->{port}, 23451,
        'control_plane=cm -> Ops Center CM port 23451' );
    is( PVE::Storage::FCLU::Driver::Hitachi::RestClient->new(%base, control_plane => 'cm', port => 8443)->{port}, 8443,
        'explicit port overrides the control_plane default' );
};

subtest 'list_host_groups is cached per port; invalidated on create/delete' => sub {
    my $c = new_mock_client();
    MockRestClient::clear_request_log();
    MockRestClient::set_mock_responses(
        { data => [ { portId => 'CL1-A', hostGroupNumber => 2, hostGroupName => 'PVE_b' } ] },
        { jobId => 'j' }, { state => 'Succeeded' },   # create_host_group job
        { data => [ { portId => 'CL1-A', hostGroupNumber => 2, hostGroupName => 'PVE_b' },
                    { portId => 'CL1-A', hostGroupNumber => 3, hostGroupName => 'PVE_c' } ] },
    );
    $c->list_host_groups( port_id => 'CL1-A' );
    $c->list_host_groups( port_id => 'CL1-A' );   # served from cache (no 2nd GET)
    my @g1 = grep { $_->{method} eq 'GET' && $_->{url} =~ m{/host-groups} } MockRestClient::get_request_log();
    is( scalar @g1, 1, 'second list_host_groups served from cache (one GET)' );

    $c->create_host_group( port_id => 'CL1-A', host_group_name => 'PVE_c' );   # invalidates CL1-A
    my $g = $c->list_host_groups( port_id => 'CL1-A' );   # re-fetches (sees the new group)
    is( scalar @$g, 2, 'cache invalidated on create_host_group -> fresh list' );
};

subtest 'create_ldev: auto-assign body + job resourceId extraction' => sub {
    my $c = new_mock_client();
    MockRestClient::set_mock_responses(
        { jobId => 'job-1' },
        { state => 'Succeeded', affectedResources => ['/ldevs/42'] },
    );
    my $r = $c->create_ldev( pool_id => 0, size_mb => 1024 );
    is( $r->{resourceId}, 42, 'resourceId extracted from the async job' );

    my @log = MockRestClient::get_request_log();
    is( $log[0]{method}, 'POST', 'POST' );
    like( $log[0]{url}, qr{/ldevs$}, 'ldevs url' );
    is( $log[0]{body}{poolId}, 0, 'poolId in body' );
    is( $log[0]{body}{byteFormatCapacity}, '1024M', 'byteFormatCapacity' );
    ok( $log[0]{body}{isParallelExecutionEnabled}, 'parallel exec when auto-assigning' );
    ok( !exists $log[0]{body}{ldevId}, 'no ldevId when auto-assigning' );
};

subtest 'create_ldev: explicit ldevId omits isParallelExecutionEnabled (KART40046-E)' => sub {
    my $c = new_mock_client();
    MockRestClient::set_mock_responses(
        { jobId => 'job-2' },
        { state => 'Succeeded', affectedResources => ['/ldevs/256'] },
    );
    $c->create_ldev( pool_id => 0, size_mb => 1024, ldev_id => 256 );
    my @log = MockRestClient::get_request_log();
    is( $log[0]{body}{ldevId}, 256, 'ldevId in body' );
    ok( !exists $log[0]{body}{isParallelExecutionEnabled}, 'parallel exec omitted with explicit id' );
};

subtest 'delete/get/set_label/expand request shapes' => sub {
    my $c = new_mock_client();
    MockRestClient::set_mock_responses( {}, { ldevId => 42, label => 'pve:t:vm-1-disk-1' }, {}, {} );

    $c->delete_ldev(42);
    my $ldev = $c->get_ldev(42);
    is( $ldev->{ldevId}, 42, 'get_ldev returns the object' );
    $c->set_ldev_label( 42, 'pve:t:vm-1-disk-1' );
    $c->expand_ldev( 42, 512 );

    my @log = MockRestClient::get_request_log();
    is( $log[0]{method}, 'DELETE', 'delete' );
    like( $log[0]{url}, qr{/ldevs/42$}, 'delete url' );
    is( $log[2]{method}, 'PATCH', 'set_label is PATCH' );
    is( $log[2]{body}{label}, 'pve:t:vm-1-disk-1', 'label in body' );
    like( $log[3]{url}, qr{/ldevs/42/actions/expand/invoke}, 'expand url' );
    is( $log[3]{body}{parameters}{additionalByteFormatCapacity}, '512M', 'expand size' );
};

subtest 'list_ldevs unwraps the data array and applies filters' => sub {
    my $c = new_mock_client();
    MockRestClient::set_mock_responses( { data => [ { ldevId => 1 }, { ldevId => 2 } ] } );
    my $ldevs = $c->list_ldevs( pool_id => 0, dp_only => 1 );
    is( scalar @$ldevs, 2, 'two ldevs' );
    my @log = MockRestClient::get_request_log();
    like( $log[0]{url}, qr/poolId=0/, 'poolId filter' );
    like( $log[0]{url}, qr/ldevOption=dpVolume/, 'dp_only filter' );
};

subtest '_retry_delay honours a numeric Retry-After (pure function)' => sub {
    my $c = new_mock_client();
    my $res = HTTP::Response->new(503);
    $res->header( 'Retry-After' => '7' );
    is( $c->_retry_delay( 1, $res ), 7, 'server Retry-After takes precedence' );
};

subtest 'N16: _wait_for_job extracts composite (port,hg) resource ids' => sub {
    my $c = new_mock_client();
    # The job poll returns Succeeded with a composite host-group affectedResource.
    MockRestClient::set_mock_responses(
        { state => 'Succeeded', affectedResources => ['/host-groups/CL1-A,0'] } );
    my $r = $c->_wait_for_job( { jobId => 'j1' } );
    is( $r->{resourceId}, 'CL1-A,0', 'composite host-group id kept whole (not missed)' );
};

subtest 'N9/N11: real _request transport-retry + non-JSON guard' => sub {
    require HTTP::Response;
    my $real = PVE::Storage::FCLU::Driver::Hitachi::RestClient->new(
        mgmt_ip => '10.0.0.9', storage_id => '836000123456',
        username => 'u', password => 'p', port => 443, sessionless => 1 );

    # N11: a 200 with a NON-JSON (HTML) body must not decode_json — surface a clear error.
    {
        package StubUA_HTML;
        sub new { bless {}, shift }
        sub request {
            return HTTP::Response->new( 200, 'OK',
                [ 'Content-Type' => 'text/html' ], '<html>login portal</html>' );
        }
    }
    $real->{ua} = StubUA_HTML->new;
    eval { $real->_request( 'GET', 'https://x/y' ); 1 };
    like( $@, qr/non-JSON/, 'HTML 200 => clear non-JSON error, not an opaque decode die' );

    # N9: a CONNECT-phase transport error on a POST (request provably never sent) is retried
    # and then succeeds. Keep the retry instant.
    {
        package StubUA_Flap;
        sub new { bless { n => 0 }, shift }
        sub request {
            my ($s) = @_; $s->{n}++;
            if ( $s->{n} == 1 ) {
                my $r = HTTP::Response->new( 500, "Can't connect to x:443 (connection refused)" );
                $r->header( 'Client-Warning' => 'Internal response' );
                return $r;
            }
            return HTTP::Response->new( 200, 'OK',
                [ 'Content-Type' => 'application/json' ], '{"ok":1}' );
        }
    }
    my $flap = StubUA_Flap->new;
    $real->{ua} = $flap;
    my $res;
    {
        no warnings 'redefine';
        local *PVE::Storage::FCLU::Driver::Hitachi::RestClient::_retry_delay = sub { 0 };
        $res = $real->_request( 'POST', 'https://x/z', { a => 1 } );
    }
    is_deeply( $res, { ok => 1 }, 'connect-phase transport error on a POST retried, then succeeded' );
    is( $flap->{n}, 2, 'exactly one retry (request never left the client => safe to resend)' );

    # N9 SAFETY: a READ-timeout transport error on a POST must NOT be resent (the array may
    # already have applied it — e.g. a relative expand). It croaks instead of double-applying.
    {
        package StubUA_ReadTimeout;
        sub new { bless { n => 0 }, shift }
        sub request {
            my ($s) = @_; $s->{n}++;
            my $r = HTTP::Response->new( 500, 'read timeout' );
            $r->header( 'Client-Warning' => 'Internal response' );
            return $r;
        }
    }
    my $rt = StubUA_ReadTimeout->new;
    $real->{ua} = $rt;
    {
        no warnings 'redefine';
        local *PVE::Storage::FCLU::Driver::Hitachi::RestClient::_retry_delay = sub { 0 };
        eval { $real->_request( 'POST', 'https://x/z', { a => 1 } ); 1 };
    }
    ok( $@, 'read-timeout POST croaks (not resent)' );
    is( $rt->{n}, 1, 'the POST was sent exactly once (no double-apply)' );
};

done_testing();

BEGIN { require HTTP::Response; }
