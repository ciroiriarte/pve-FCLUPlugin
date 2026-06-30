#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use lib 'src';

use PVE::Storage::FCLU::Driver;

# ARCHITECTURE.md §2/§12: the abstract array-backend contract. The base class
# implements no behaviour — every contract method must exist and must croak
# "not implemented" so a half-finished driver fails loudly. These tests pin the
# canonical method surface (which the contract suite and Driver::Mock both build
# on) and the loud-stub behaviour.

subtest 'canonical method surface is the §2 set' => sub {
    my @expect = qw(
        connect disconnect ping detect_profile capabilities storage_status
        create_lu delete_lu get_lu list_lus set_lu_label resize_lu
        set_lu_qos get_lu_qos migrate_lu
        ensure_host_access publish_lu unpublish_lu list_lu_mappings target_ports
        get_lu_identity
        create_snapshot delete_snapshot restore_snapshot list_snapshots
        create_linked_clone create_full_clone create_cg_snapshot
    );

    is_deeply(
        [ sort( PVE::Storage::FCLU::Driver->contract_methods ) ],
        [ sort @expect ],
        'contract_methods is exactly the §2 surface',
    );

    # mandatory ∪ optional == contract, and they are disjoint.
    my @mand = PVE::Storage::FCLU::Driver->mandatory_methods;
    my @opt  = PVE::Storage::FCLU::Driver->optional_methods;
    is_deeply(
        [ sort( @mand, @opt ) ],
        [ sort @expect ],
        'mandatory + optional covers the whole surface',
    );
    my %m = map { $_ => 1 } @mand;
    is( ( scalar grep { $m{$_} } @opt ), 0, 'mandatory and optional are disjoint' );

    # The capability-gated methods (§6) are the optional set.
    is_deeply(
        [ sort @opt ],
        [ sort qw(
            set_lu_qos get_lu_qos migrate_lu
            create_snapshot delete_snapshot restore_snapshot list_snapshots
            create_linked_clone create_full_clone create_cg_snapshot
        ) ],
        'optional set is the capability-gated methods',
    );
};

subtest 'every contract method exists and croaks not-implemented' => sub {
    my $drv = PVE::Storage::FCLU::Driver->new;
    isa_ok( $drv, 'PVE::Storage::FCLU::Driver', 'base constructor' );

    for my $m ( PVE::Storage::FCLU::Driver->contract_methods ) {
        ok( $drv->can($m), "$m is defined on the base class" );
        eval { $drv->$m() };
        like(
            $@,
            qr/does not implement '\Q$m\E'/,
            "$m croaks not-implemented on the abstract base",
        );
    }
};

subtest 'croak reports the caller, not the module internals' => sub {
    my $drv = PVE::Storage::FCLU::Driver->new;
    eval { $drv->create_lu( size_bytes => 1024 ) };
    like( $@, qr/\Qdriver.t\E line \d+/, 'croak blames the call site' );
};

subtest 'a subclass overriding a method shadows the stub' => sub {
    package My::TestDriver;
    use parent -norequire, 'PVE::Storage::FCLU::Driver';
    sub ping { return 'pong' }

    package main;
    my $drv = My::TestDriver->new;
    is( $drv->ping, 'pong', 'overridden method runs' );
    # Un-overridden methods still croak through inheritance.
    eval { $drv->create_lu };
    like( $@, qr/My::TestDriver does not implement 'create_lu'/,
        'inherited stub names the concrete class' );
};

done_testing();
