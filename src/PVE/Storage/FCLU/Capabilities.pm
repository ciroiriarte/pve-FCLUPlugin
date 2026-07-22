package PVE::Storage::FCLU::Capabilities;

use strict;
use warnings;

use Carp qw(croak);

# The normalized capability object (ARCHITECTURE.md §6, frozen as a §12.1 data
# type). A driver advertises which optional features its array actually offers;
# the core consumes it in volume_has_feature, activate_storage sanity checks, GUI
# field enable/disable, and CLI exposure of optional extensions.
#
# Normative rules this module enforces (§6, §12.1):
#   * Every top-level BRANCH MUST be present. Omitting a whole branch is
#     non-conformant; normalize() fills a missing branch with {} (= all features
#     off) so the rest of the core never has to special-case absence.
#   * Within a branch, an unsupported feature is expressed as 0 OR by omission —
#     the two are EQUIVALENT. The core treats any absent or unknown key as 0.
#   * Leaf values are coerced to a strict 0|1.
#
# Branch leaves are deliberately OPEN: `replication` carries vendor-specific keys
# (Hitachi tc/ur/gad; others differ, §8), so this module fixes the seven branches
# but not the leaf vocabulary inside them.

# The seven top-level branches (the §6 schema). This set is closed for api-1; a
# new branch is a non-breaking addition (§12).
my @BRANCHES = qw(snapshot clone copy qos resize transfer replication);

# Known leaves per branch, from the §6 example. Used ONLY to seed an all-off
# default and to document the canonical vocabulary — NOT to reject unknown leaves
# (replication is intentionally open-ended).
my %KNOWN_LEAVES = (
    snapshot    => [qw(single consistency_group rollback)],
    clone       => [qw(linked from_snapshot from_base from_current)],
    copy        => [qw(full from_snapshot from_base)],
    qos         => [qw(per_lu)],
    resize      => [qw(grow_online shrink)],
    transfer    => [qw(import migrate_pool)],
    replication => [qw(tc ur gad)],
);

# Mapping from a PVE volume_has_feature() name to a capability (branch, leaf).
# Only the array-OFFLOADED features are gated here (§6):
#   * snapshot      -> snapshot.single  (array snapshot)
#   * clone         -> clone.linked     (CoW child — PVE's clone_image primitive)
# PVE's other features (copy, sparseinit, template, rename) are host/registry
# level and NOT array-gated — pve_feature() returns undef for them so the caller
# decides by its own rules. Note `copy` is intentionally NOT mapped to the `copy`
# branch: no full-copy offload hook exists in PVE (§6), so a full-copy-only array
# must not have clone_image mis-driven onto it.
my %PVE_FEATURE_MAP = (
    snapshot => [ 'snapshot', 'single' ],
    clone    => [ 'clone',    'linked' ],
);

sub branches { return @BRANCHES }

# --- static helpers (operate on a plain capability hash) ------------------------

# normalize($raw) -> \%cap. Returns a NEW complete hash: all seven branches
# present, every leaf coerced to strict 0|1. Missing branches become {}. Unknown
# top-level keys (typos, future branches a newer driver advertises) are preserved
# verbatim so a forward-compatible core can still see them, but they play no part
# in the api-1 contract. Accepts undef (→ all-off default) for driver convenience.
sub normalize {
    my ($class, $raw) = @_;
    $raw //= {};
    croak 'capability object must be a HASH ref'
        unless ref $raw eq 'HASH';

    my %cap;

    # Coerce every provided branch's leaves to 0|1.
    for my $branch ( keys %$raw ) {
        my $leaves = $raw->{$branch};
        if ( ref $leaves eq 'HASH' ) {
            $cap{$branch} = { map { $_ => ( $leaves->{$_} ? 1 : 0 ) } keys %$leaves };
        } else {
            croak "capability branch '$branch' must be a HASH ref";
        }
    }

    # Guarantee all seven canonical branches exist (= conformant shape).
    $cap{$_} //= {} for @BRANCHES;

    return \%cap;
}

# default() -> \%cap. A conformant all-features-off object: every branch present,
# every known leaf set to 0. Useful for a driver with no optional features and as
# a merge base.
sub default {
    my ($class) = @_;
    return { map {
        my $b = $_;
        ( $b => { map { $_ => 0 } @{ $KNOWN_LEAVES{$b} } } );
    } @BRANCHES };
}

# has_feature($cap, $branch, $leaf) -> 0|1. The "absent/unknown key ⇒ 0" rule
# (§6, §12.1) in one place: a missing branch, a non-hash branch, or a missing leaf
# all read as 0. Works on a raw OR normalized hash.
sub has_feature {
    my ($class, $cap, $branch, $leaf) = @_;
    return 0 unless ref $cap eq 'HASH';
    my $b = $cap->{$branch};
    return 0 unless ref $b eq 'HASH';
    return $b->{$leaf} ? 1 : 0;
}

# merge($base, $override) -> \%cap. Two-level deep merge (e.g. profile caps over
# driver defaults, §4): override leaves win, both sides normalized first, result
# is a fresh normalized hash. A leaf present only in $base survives; a leaf in
# $override replaces it.
sub merge {
    my ($class, $base, $override) = @_;
    my $b = $class->normalize($base);
    my $o = $class->normalize($override);

    my %out;
    for my $branch ( keys %$b, keys %$o ) {
        next if $out{$branch};
        $out{$branch} = {
            %{ $b->{$branch} // {} },
            %{ $o->{$branch} // {} },
        };
    }
    return \%out;
}

# --- OO wrapper ----------------------------------------------------------------

# new($raw_or_wrapper) -> $self. Wraps a normalized capability hash for ergonomic
# querying. Accepts a plain hash, another Capabilities, or undef.
sub new {
    my ($class, $raw) = @_;
    $raw = $raw->{cap} if ref $raw eq __PACKAGE__;
    return bless { cap => $class->normalize($raw) }, $class;
}

# to_hash() -> \%cap. The normalized plain hash, for handing back to PVE-facing
# code that expects the §6 shape.
sub to_hash { return $_[0]->{cap} }

# has($branch, $leaf) -> 0|1. Instance form of has_feature.
sub has {
    my ($self, $branch, $leaf) = @_;
    return __PACKAGE__->has_feature( $self->{cap}, $branch, $leaf );
}

# merged($override) -> new Capabilities. Returns a new wrapper with $override
# applied over this object (non-mutating).
sub merged {
    my ($self, $override) = @_;
    return __PACKAGE__->new( __PACKAGE__->merge( $self->{cap}, $override ) );
}

# pve_feature($feature) -> 0|1|undef. Maps a PVE volume_has_feature() name to the
# capability object. Returns undef when the feature is not array-gated (the caller
# decides by host/registry rules). See %PVE_FEATURE_MAP.
sub pve_feature {
    my ($self, $feature) = @_;
    my $map = $PVE_FEATURE_MAP{$feature} or return undef;
    return $self->has( @$map );
}

1;
