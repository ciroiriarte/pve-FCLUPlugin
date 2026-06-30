package PVE::Storage::FCLU::Label;

use strict;
use warnings;

use Digest::MD5 qw(md5_hex);
use Carp qw(croak);

# Ownership-label synthesis (ARCHITECTURE.md §7, §9 Phase 1). The label is what
# tags an array LU as owned by a given PVE storage and lets orphan detection
# rediscover it: "pve:<storeid>:<volname>".
#
# Generalized from the Hitachi Config.pm helpers with ONE deliberate change (§7):
# the maximum label length is NOT a hardcoded 32 in the core. Array label limits
# are vendor/model facts (a Driver Profile field, e.g. max_label_len), so the
# caller passes $max_len. `undef` $max_len means "no limit" — emit the full,
# human-readable prefix unconditionally.
#
# When "pve:<storeid>:" plus a typical volname would exceed $max_len, the storeid
# is replaced by a stable 8-char md5 hash so labels stay within bounds, unique,
# and consistently matchable. NOTE: in that hashed regime make_label and
# parse_label are not perfect inverses (parse returns the hash, not the original
# storeid) — orphan detection matches on the synthesized prefix, so this is
# correct and intentional, carried over from the reference plugin.

# Bytes reserved for the volume name when deciding whether the readable prefix
# fits (e.g. "vm-999999999-disk-99" ~ 20 chars). A label-domain heuristic, NOT a
# vendor limit.
use constant VOLNAME_BUDGET => 20;

# The label prefix tagging LUs owned by $storeid, clamped to fit $max_len.
sub label_prefix {
    my ($class, $storeid, $max_len) = @_;

    croak "storeid is required" unless defined $storeid && length $storeid;

    my $full = "pve:${storeid}:";

    # No limit, or the readable prefix plus a typical volname still fits: use it.
    return $full
        if !defined $max_len
        || length($full) + VOLNAME_BUDGET <= $max_len;

    # Otherwise fall back to a stable hashed storeid so the label stays bounded.
    my $hash = substr( md5_hex($storeid), 0, 8 );
    return "pve:${hash}:";
}

sub make_label {
    my ($class, $storeid, $volname, $max_len) = @_;

    croak "volname is required" unless defined $volname && length $volname;

    my $label = $class->label_prefix( $storeid, $max_len ) . $volname;
    # Final safety clamp; volnames are short so this is effectively never hit.
    $label = substr( $label, 0, $max_len )
        if defined $max_len && length($label) > $max_len;
    return $label;
}

sub parse_label {
    my ($class, $label) = @_;

    return undef unless defined $label && length $label;

    if ( $label =~ /^pve:([^:]+):(.+)$/ ) {
        return { storeid => $1, volname => $2 };
    }

    return undef;
}

1;
