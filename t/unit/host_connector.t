#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use lib 'src';
use PVE::Storage::FCLU::Host::Connector;

# ARCHITECTURE.md §3: the abstract host-connector interface. Pins the canonical
# surface and the loud not-implemented stubs.

subtest 'canonical surface is the §3 set' => sub {
    is_deeply(
        [ sort( PVE::Storage::FCLU::Host::Connector->contract_methods ) ],
        [ sort qw(host_context attach detach resize flush device_path) ],
        'contract_methods is exactly the §3 interface',
    );
};

subtest 'every method croaks not-implemented on the base' => sub {
    my $c = PVE::Storage::FCLU::Host::Connector->new;
    isa_ok( $c, 'PVE::Storage::FCLU::Host::Connector', 'base connector' );
    for my $m ( PVE::Storage::FCLU::Host::Connector->contract_methods ) {
        ok( $c->can($m), "$m present" );
        eval { $c->$m() };
        like( $@, qr/does not implement '\Q$m\E'/, "$m croaks on the abstract base" );
    }
};

subtest 'a subclass override shadows the stub' => sub {
    package My::Conn;
    use parent -norequire, 'PVE::Storage::FCLU::Host::Connector';
    sub device_path { return '/dev/mapper/3abc' }

    package main;
    my $c = My::Conn->new;
    is( $c->device_path, '/dev/mapper/3abc', 'overridden method runs' );
    eval { $c->attach };
    like( $@, qr/My::Conn does not implement 'attach'/, 'inherited stub names the concrete class' );
};

done_testing();
