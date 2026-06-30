#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use lib 'src';
use lib 't/lib';

use FCLU::ContractTest qw(run_contract_tests);
use FCLU::FakeHitachiRest;
use PVE::Storage::FCLU::Driver::Hitachi;

# ARCHITECTURE.md §12.5: the conformance suite (FCLU::ContractTest) parametrized
# over the REAL Driver::Hitachi, backed by the stateful FakeHitachiRest simulator
# (no array). Passing this IS the proof that driver #1 conforms to
# fclu-driver-api-1 — the §12.1 data shapes, the §12.2 idempotency/retry table,
# host-access idempotency/node-targeting/authoritative mappings, and the
# snapshot + linked-clone capability-gated behaviour. This is the same harness
# that proves Mock conformant (contract_mock.t).

run_contract_tests(
    name    => 'Hitachi',
    factory => sub {
        PVE::Storage::FCLU::Driver::Hitachi->new(
            platform     => 'vsp_e',
            rest         => FCLU::FakeHitachiRest->new,
            pool_id      => '63',
            snap_pool_id => '63',
            array_ports  => [ 'CL1-A', 'CL2-A' ],
        );
    },
);

done_testing();
