#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use lib 'src';
use lib 't/lib';

use FCLU::ContractTest qw(run_contract_tests);
use PVE::Storage::FCLU::Driver::Mock;

# ARCHITECTURE.md §12.5: the conformance suite (FCLU::ContractTest) parametrized
# over Driver::Mock — the executable reference. Every future driver gets the same
# one-liner (its own t/unit/contract_<vendor>.t) so "conforms to api-1" is asserted
# identically against every backend.

run_contract_tests(
    name    => 'Mock',
    factory => sub { PVE::Storage::FCLU::Driver::Mock->new( pool_total => 1 << 42 ) },
);

done_testing();
