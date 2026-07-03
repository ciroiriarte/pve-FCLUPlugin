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

subtest 'find_host_group_by_wwn: ONE /host-wwns query (no per-host-group scan)' => sub {
    my $c = new_mock_client();
    MockRestClient::clear_request_log();
    MockRestClient::set_mock_responses(
        # /host-wwns?portId=CL1-A -> every WWN on the port with its hostGroupNumber
        { data => [
            { portId => 'CL1-A', hostGroupNumber => 1, hostWwn => '10000000aaaa' },
            { portId => 'CL1-A', hostGroupNumber => 2, hostWwn => '10000000bbbb' },
            { portId => 'CL1-A', hostGroupNumber => 3, hostWwn => '10000000cccc' },
        ] },
        # /host-groups?portId=CL1-A -> the group objects (for the name/mode)
        { data => [
            { portId => 'CL1-A', hostGroupNumber => 1, hostGroupName => 'PVE_a' },
            { portId => 'CL1-A', hostGroupNumber => 2, hostGroupName => 'PVE_b' },
            { portId => 'CL1-A', hostGroupNumber => 3, hostGroupName => 'PVE_c' },
        ] },
    );
    my $hg = $c->find_host_group_by_wwn( 'CL1-A', '10000000BBBB' );
    is( $hg->{hostGroupNumber}, 2, 'resolved the WWN to its host group' );
    is( $hg->{hostGroupName}, 'PVE_b', 'returned the full host group object (name preserved)' );

    my @wwn_calls = grep { $_->{url} =~ m{/host-wwns} } MockRestClient::get_request_log();
    is( scalar @wwn_calls, 1, 'exactly ONE /host-wwns query regardless of host-group count' );
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

done_testing();

BEGIN { require HTTP::Response; }
