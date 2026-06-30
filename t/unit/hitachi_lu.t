#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use lib 'src';
use PVE::Storage::FCLU::Driver::Hitachi;

# §9 Phase 1 step 3 (slice A): Driver::Hitachi LU lifecycle/introspection/identity.
# Verifies the §12.1 normalization (backend_id stringified, blockCapacity*512
# bytes, naaId identity), the byte<->MiB conversions, and the §12.2 idempotency
# rules (create requested_id re-assert, delete not_found->success) against a
# scripted mock rest client.

package MockRest;
sub new { bless { log => [], plan => {} }, shift }
sub _do {
    my ( $self, $name, @args ) = @_;
    push @{ $self->{log} }, [ $name, @args ];
    my $p = $self->{plan}{$name};
    return ( ref $p eq 'CODE' ) ? $p->(@args) : $p;
}
sub called { my ( $s, $n ) = @_; return grep { $_->[0] eq $n } @{ $s->{log} } }
our $AUTOLOAD;
sub AUTOLOAD {
    my $self = shift;
    ( my $name = $AUTOLOAD ) =~ s/.*:://;
    return if $name eq 'DESTROY';
    return $self->_do( $name, @_ );
}

package main;

use constant { GIB => 1073741824, MIB => 1048576 };

sub mk {
    my ($plan, %o) = @_;
    my $m = MockRest->new;
    $m->{plan} = $plan // {};
    my $d = PVE::Storage::FCLU::Driver::Hitachi->new(
        platform => 'vsp_e', rest => $m, pool_id => ( $o{pool_id} // 63 ) );
    return ( $d, $m );
}

my $not_found = sub { die "API request failed: GET x -> 404 Not Found\n" };

subtest 'create_lu auto-assign: bytes->MiB, no ldevId' => sub {
    my ( $d, $m ) = mk( { create_ldev => { resourceId => 42 } } );
    is( $d->create_lu( size_bytes => GIB ), '42', 'returns stringified resourceId' );
    my ($call) = $m->called('create_ldev');
    my %body = @{$call}[ 1 .. $#$call ];
    is( $body{pool_id}, 63,   'pool_id from driver config' );
    is( $body{size_mb}, 1024, '1 GiB -> 1024 MiB' );
    ok( !exists $body{ldev_id}, 'no ldev_id when auto-assigning' );
};

subtest 'create_lu clamps below the array minimum LU size' => sub {
    my ( $d, $m ) = mk( { create_ldev => { resourceId => 7 } } );
    $d->create_lu( size_bytes => MIB );    # 1 MiB
    my ($call) = $m->called('create_ldev');
    my %body = @{$call}[ 1 .. $#$call ];
    is( $body{size_mb}, 48, '1 MiB clamped up to min_lu_mb (48)' );
};

subtest 'create_lu with requested_id (absent) sets ldevId + label' => sub {
    my ( $d, $m ) = mk( {
        get_ldev      => $not_found,       # re-assert sees no existing ldev
        create_ldev   => { resourceId => 100 },
        set_ldev_label => {},
    } );
    is( $d->create_lu( size_bytes => GIB, requested_id => '100', label => 'L' ),
        '100', 'returns the requested id' );
    my ($cc) = $m->called('create_ldev');
    my %body = @{$cc}[ 1 .. $#$cc ];
    is( $body{ldev_id}, '100', 'create_ldev got the explicit ldev_id' );
    my ($lc) = $m->called('set_ldev_label');
    is_deeply( [ @{$lc}[ 1, 2 ] ], [ '100', 'L' ], 'label set after create' );
};

subtest 'create_lu requested_id re-assert: match => success, no create' => sub {
    my ( $d, $m ) = mk( {
        get_ldev => { ldevId => 100, blockCapacity => GIB / 512, poolId => 63 },
    } );
    is( $d->create_lu( size_bytes => GIB, requested_id => '100', pool_ref => '63' ),
        '100', 're-assert returns the existing id' );
    is( scalar $m->called('create_ldev'), 0, 'no create_ldev on a matching re-assert' );
};

subtest 'create_lu requested_id re-assert: mismatch => already_exists' => sub {
    my ( $d, $m ) = mk( {
        get_ldev => { ldevId => 100, blockCapacity => ( 2 * GIB ) / 512, poolId => 63 },
    } );
    my $err;
    my $ok = eval { $d->create_lu( size_bytes => GIB, requested_id => '100', pool_ref => '63' ); 1 };
    $err = $@ unless $ok;
    isa_ok( $err, 'PVE::Storage::FCLU::Error', 'mismatch' );
    is( $err->code, 'already_exists', 'size mismatch => already_exists' );
};

subtest 'delete_lu: success normally, idempotent on not_found' => sub {
    my ( $d, $m ) = mk( { delete_ldev => {} } );
    is( $d->delete_lu('42'), 1, 'normal delete' );
    is( scalar $m->called('delete_ldev'), 1, 'delete_ldev invoked' );

    my ( $d2 ) = mk( { delete_ldev => $not_found } );
    is( $d2->delete_lu('99'), 1, 'deleting an absent ldev is success (not_found swallowed)' );
};

subtest 'get_lu normalizes to the §12.1 descriptor' => sub {
    my ( $d ) = mk( {
        get_ldev => {
            ldevId => 42, blockCapacity => GIB / 512,
            label => 'pve:s:vm-1-disk-0', poolId => 63, naaId => '60060E8000ABCD',
        },
    } );
    my $lu = $d->get_lu('42');
    is( $lu->{backend_id}, '42',          'backend_id stringified' );
    is( $lu->{size_bytes}, GIB,           'size = blockCapacity * 512' );
    is( $lu->{label}, 'pve:s:vm-1-disk-0','label' );
    is( $lu->{pool_ref}, '63',            'pool_ref stringified' );
    is( $lu->{identity}{ids}{naa}, '60060e8000abcd', 'naa lowercased from naaId' );
};

subtest 'get_lu / get_lu_identity raise not_found on absent or empty slot' => sub {
    my ( $d ) = mk( { get_ldev => { emulationType => 'NOT DEFINED', ldevId => 5 } } );
    my $err;
    eval { $d->get_lu('5'); 1 } or $err = $@;
    is( $err->code, 'not_found', 'NOT DEFINED slot => not_found' );

    my ( $d2 ) = mk( { get_ldev => $not_found } );
    my $err2;
    eval { $d2->get_lu_identity('5'); 1 } or $err2 = $@;
    is( $err2->code, 'not_found', '404 on identity => not_found' );
};

subtest 'resize_lu grows by the delta and converges' => sub {
    my ( $d, $m ) = mk( { get_ldev => { ldevId => 42, blockCapacity => GIB / 512 }, expand_ldev => {} } );
    $d->resize_lu( '42', 2 * GIB );
    my ($ec) = $m->called('expand_ldev');
    is( $ec->[2], 1024, 'expand by 1024 MiB (2GiB - 1GiB)' );

    my ( $d2, $m2 ) = mk( { get_ldev => { ldevId => 42, blockCapacity => GIB / 512 } } );
    is( $d2->resize_lu( '42', GIB ), 1, 'resize to current size converges' );
    is( scalar $m2->called('expand_ldev'), 0, 'no expand on converge' );
};

subtest 'storage_status returns bytes, with the E590H used-capacity fallback' => sub {
    my ( $d ) = mk( { get_pool => { totalPoolCapacity => 1000, usedPoolCapacity => 400 } } );
    is_deeply( [ $d->storage_status ], [ 1000 * MIB, 600 * MIB, 400 * MIB ],
        'total/free/used in bytes' );

    my ( $d2 ) = mk( { get_pool => { totalPoolCapacity => 1000, availableVolumeCapacity => 600 } } );
    is_deeply( [ $d2->storage_status ], [ 1000 * MIB, 600 * MIB, 400 * MIB ],
        'used derived from availableVolumeCapacity when usedPoolCapacity absent' );
};

subtest 'set_lu_label invokes the transport' => sub {
    my ( $d, $m ) = mk( { set_ldev_label => {} } );
    $d->set_lu_label( '42', 'newlabel' );
    my ($lc) = $m->called('set_ldev_label');
    is_deeply( [ @{$lc}[ 1, 2 ] ], [ '42', 'newlabel' ], 'set_ldev_label(id,label)' );
};

done_testing();
