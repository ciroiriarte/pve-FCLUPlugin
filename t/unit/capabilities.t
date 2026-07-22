#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use lib 'src';

use PVE::Storage::FCLU::Capabilities;

my $C = 'PVE::Storage::FCLU::Capabilities';

# ARCHITECTURE.md §6 / §12.1: the normalized capability object. These tests pin
# the conformant shape (all seven branches present), the "absent/unknown key ⇒ 0"
# rule, strict 0|1 leaf coercion, the profile-over-defaults merge, and the
# volume_has_feature glue.

subtest 'branch set is the §6 seven' => sub {
    is_deeply(
        [ sort $C->branches ],
        [ sort qw(snapshot clone copy qos resize transfer replication) ],
        'the seven top-level branches',
    );
};

subtest 'normalize fills missing branches and coerces leaves to 0|1' => sub {
    my $cap = $C->normalize( { snapshot => { single => 1 }, resize => { shrink => 0 } } );

    # All seven branches present even though only two were supplied.
    is_deeply(
        [ sort keys %$cap ],
        [ sort $C->branches ],
        'every canonical branch is present after normalize',
    );
    is_deeply( $cap->{clone}, {}, 'a wholly-missing branch becomes {} (all off)' );

    # Truthy/falsy leaves normalized to strict 0|1.
    my $n = $C->normalize( { snapshot => { single => 'yes', rollback => 0, consistency_group => [1] } } );
    is( $n->{snapshot}{single},            1, 'truthy leaf -> 1' );
    is( $n->{snapshot}{rollback},          0, 'explicit 0 stays 0' );
    is( $n->{snapshot}{consistency_group}, 1, 'truthy ref leaf -> 1' );
};

subtest 'normalize tolerates undef and rejects bad shapes' => sub {
    my $cap = $C->normalize(undef);
    is_deeply( [ sort keys %$cap ], [ sort $C->branches ], 'undef -> all-off conformant object' );

    eval { $C->normalize( [] ) };
    like( $@, qr/must be a HASH ref/, 'non-hash capability object dies' );

    eval { $C->normalize( { snapshot => 1 } ) };
    like( $@, qr/branch 'snapshot' must be a HASH ref/, 'non-hash branch dies' );
};

subtest 'default() is conformant and all-off' => sub {
    my $d = $C->default;
    is_deeply( [ sort keys %$d ], [ sort $C->branches ], 'default has all branches' );
    is( $d->{snapshot}{single},   0, 'default leaf single = 0' );
    is( $d->{resize}{grow_online}, 0, 'default leaf grow_online = 0' );
    # Every leaf in default is 0.
    my @nonzero = grep { $_ } map { values %$_ } values %$d;
    is( scalar @nonzero, 0, 'no leaf in default is truthy' );
};

subtest 'has_feature applies the absent/unknown ⇒ 0 rule' => sub {
    my $cap = { snapshot => { single => 1 } };   # deliberately partial / unnormalized
    is( $C->has_feature( $cap, 'snapshot', 'single' ),   1, 'present truthy leaf' );
    is( $C->has_feature( $cap, 'snapshot', 'rollback' ), 0, 'absent leaf in present branch -> 0' );
    is( $C->has_feature( $cap, 'clone',    'linked' ),   0, 'absent branch -> 0' );
    is( $C->has_feature( $cap, 'bogus',    'leaf' ),     0, 'unknown branch -> 0' );
    is( $C->has_feature( undef, 'snapshot', 'single' ),  0, 'non-hash cap -> 0' );
};

subtest 'merge: override leaves win, base-only leaves survive' => sub {
    my $base = {
        snapshot => { single => 1, rollback => 1 },
        qos      => { per_lu => 1 },
    };
    my $override = {
        snapshot => { rollback => 0 },          # turn one leaf off
        clone    => { linked => 1 },            # add a branch
    };
    my $m = $C->merge( $base, $override );

    is( $m->{snapshot}{single},   1, 'base-only leaf survives merge' );
    is( $m->{snapshot}{rollback}, 0, 'override leaf wins' );
    is( $m->{clone}{linked},      1, 'override-only branch added' );
    is( $m->{qos}{per_lu},        1, 'untouched base branch survives' );
    is_deeply( [ sort keys %$m ], [ sort $C->branches ], 'merge result is conformant' );
};

subtest 'OO wrapper: has / to_hash / merged / pve_feature' => sub {
    my $cap = $C->new( { snapshot => { single => 1 }, clone => { linked => 1 } } );
    isa_ok( $cap, $C, 'wrapper' );

    is( $cap->has( 'snapshot', 'single' ), 1, 'has() present' );
    is( $cap->has( 'qos', 'per_lu' ),      0, 'has() absent -> 0' );

    is_deeply( [ sort keys %{ $cap->to_hash } ], [ sort $C->branches ], 'to_hash is conformant' );

    # Wrapping an existing wrapper is idempotent.
    my $again = $C->new($cap);
    is_deeply( $again->to_hash, $cap->to_hash, 'new(wrapper) re-wraps the same caps' );

    # Non-mutating merge.
    my $m = $cap->merged( { qos => { per_lu => 1 } } );
    is( $m->has( 'qos', 'per_lu' ),   1, 'merged() applied override' );
    is( $cap->has( 'qos', 'per_lu' ), 0, 'merged() did not mutate the original' );

    # clone.from_current is a distinct leaf: a live-source linked clone (#19). Absent
    # here (snapshot-only clone backend), so it reads 0 even though clone.linked is 1.
    is( $cap->has( 'clone', 'from_current' ), 0, 'clone.from_current absent -> 0 (snapshot-only clone)' );
    my $livecap = $C->new( { clone => { linked => 1, from_current => 1 } } );
    is( $livecap->has( 'clone', 'from_current' ), 1, 'clone.from_current advertised -> 1' );

    # PVE feature glue.
    is( $cap->pve_feature('snapshot'), 1,     'PVE snapshot -> snapshot.single' );
    is( $cap->pve_feature('clone'),    1,     'PVE clone -> clone.linked' );
    is( $cap->pve_feature('copy'),     undef, 'PVE copy is not array-gated here (§6)' );
    is( $cap->pve_feature('rename'),   undef, 'unmapped PVE feature -> undef' );

    my $nocaps = $C->new;
    is( $nocaps->pve_feature('snapshot'), 0, 'no-caps array: snapshot feature off' );
};

done_testing();
