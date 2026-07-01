package PVE::Storage::FCLU::Migrate::Hitachi;

use strict;
use warnings;

use Carp qw(croak);
use JSON qw(decode_json);

use PVE::Storage::FCLU::Registry;
use PVE::Storage::FCLU::Credentials;

# One-shot, COPY-mode migration of a reference `pve-storage-hitachiblock` store into
# the FCLU on-disk format, so swapping the plugin does not orphan existing volumes.
#
# The reference plugin (PVE::Storage::HitachiBlock::Config) kept its volname->LU map
# in `<legacy_base>/<storeid>.json` with Hitachi-specific fields; FCLU::Registry uses
# `<fclu_base>/<storeid>.json` with vendor-neutral fields. This translates the former
# into the latter by WRITING through FCLU::Registry / FCLU::Credentials (so the output
# is guaranteed-correct FCLU format, atomically written and 0600-locked). It NEVER
# deletes or mutates the legacy store — the admin swaps packages after verifying.
#
# Field mapping (reference -> FCLU):
#   ldev_id (int)        -> backend_id (string, §7 opaque)
#   wwid ("60060e80...") -> identity { protocol => 'scsi-fc', ids => { naa => wwid } }
#   pool_id (int)        -> pool_ref (string)
#   parent_volname       -> parent_volname   (linked-clone parentage, verbatim)
#   parent_snap          -> parent_snap      (verbatim)
#   clone_snapshot_id    -> clone_backing_snap    (the #23 backing-pair handle)
#   clone_pvol_ldev      -> clone_parent_backend  (string; the pair's P-VOL)
#   protected / notes    -> protected / notes (verbatim, if present)
#   snapshots{...}       -> snapshot subregistry (snapshot_id->snap_id,
#                           snapshot_group->group, svol_ldev_id->svol, +monotonic seq)
#   timestamp            -> dropped (FCLU volume entries do not track it)

our $LEGACY_BASE = '/etc/pve/priv/hitachiblock';
our $FCLU_BASE   = '/etc/pve/priv/fclu';

sub _slurp {
    my ($path) = @_;
    open( my $fh, '<', $path ) or croak "cannot read $path: $!";
    local $/;
    my $c = <$fh>;
    close($fh);
    return $c;
}

# Translate one legacy volume entry -> ("$backend_id", \%fclu_meta, \%snapshots|undef).
sub _transform_entry {
    my ($volname, $e) = @_;

    croak "legacy entry '$volname' has no ldev_id" unless defined $e->{ldev_id};
    croak "legacy entry '$volname' has no wwid"
        unless defined $e->{wwid} && length $e->{wwid};

    # Canonicalize the NAA the same way Driver::Hitachi does at alloc time (strip a
    # naa./0x prefix, lowercase), so the migrated identity is byte-identical to what a
    # fresh alloc_image would record.
    my $naa = "$e->{wwid}";
    $naa =~ s/^naa\.//i;
    $naa =~ s/^0x//i;
    $naa = lc $naa;

    my %meta = (
        identity => { protocol => 'scsi-fc', ids => { naa => $naa } },
        size_mb  => $e->{size_mb},
    );
    $meta{pool_ref} = "$e->{pool_id}" if defined $e->{pool_id};

    # Linked-clone parentage + the #23 backing-pair handle (renamed keys, stringified).
    $meta{parent_volname}       = $e->{parent_volname}    if defined $e->{parent_volname};
    $meta{parent_snap}          = $e->{parent_snap}       if defined $e->{parent_snap};
    $meta{clone_backing_snap}   = $e->{clone_snapshot_id} if defined $e->{clone_snapshot_id};
    $meta{clone_parent_backend} = "$e->{clone_pvol_ldev}" if defined $e->{clone_pvol_ldev};

    # Per-volume attributes (#15), preserved if the reference tracked them.
    $meta{protected} = 1           if $e->{protected};
    $meta{notes}     = $e->{notes} if defined $e->{notes} && length $e->{notes};

    return ( "$e->{ldev_id}", \%meta, _transform_snapshots($e->{snapshots}) );
}

# Reference snapshot subregistry -> FCLU shape, oldest first with a monotonic seq.
sub _transform_snapshots {
    my ($legacy) = @_;
    return undef unless ref $legacy eq 'HASH' && %$legacy;

    my %out;
    my $seq = 0;
    for my $name (
        sort { ( $legacy->{$a}{timestamp} || 0 ) <=> ( $legacy->{$b}{timestamp} || 0 ) }
        keys %$legacy
    ) {
        my $s = $legacy->{$name};
        $out{$name} = {
            seq => $seq++,
            ( defined $s->{snapshot_id}    ? ( snap_id   => "$s->{snapshot_id}" )  : () ),
            ( defined $s->{snapshot_group} ? ( group     => $s->{snapshot_group} ) : () ),
            ( defined $s->{svol_ldev_id}   ? ( svol      => "$s->{svol_ldev_id}" )  : () ),
            ( defined $s->{timestamp}      ? ( timestamp => $s->{timestamp} )       : () ),
        };
    }
    return \%out;
}

# migrate_store(storeid =>, legacy_base =>, fclu_base =>, dry_run =>) -> \%summary.
# COPY mode: reads the legacy store, writes the FCLU store; never touches the legacy
# files. Idempotent (FCLU register() merges the same backend_id). Returns a summary
# with the translated volume list (NO secrets).
sub migrate_store {
    my (%o) = @_;
    my $storeid = $o{storeid} or croak "storeid is required";
    my $legacy_base = defined $o{legacy_base} ? $o{legacy_base} : $LEGACY_BASE;
    my $fclu_base   = defined $o{fclu_base}   ? $o{fclu_base}   : $FCLU_BASE;
    my $dry_run     = $o{dry_run} ? 1 : 0;

    my $legacy_json = "$legacy_base/$storeid.json";
    croak "no legacy registry at $legacy_json\n" unless -f $legacy_json;
    my $data = decode_json( _slurp($legacy_json) );

    my %summary = ( storeid => $storeid, dry_run => $dry_run, volumes => [], snapshots => 0, creds => 0 );
    my $reg = PVE::Storage::FCLU::Registry->new( storeid => $storeid, base_dir => $fclu_base );

    for my $volname ( sort keys %$data ) {
        my $e = $data->{$volname};
        # Skip name reservations / any non-committed entry (no ldev_id on the array).
        next unless ref $e eq 'HASH' && defined $e->{ldev_id};

        my ( $backend_id, $meta, $snaps ) = _transform_entry( $volname, $e );
        push @{ $summary{volumes} }, { volname => $volname, backend_id => $backend_id };
        next if $dry_run;

        $reg->register( $volname, $backend_id, %$meta );
        if ($snaps) {
            $reg->register_snapshot( $volname, $_, %{ $snaps->{$_} } ) for sort keys %$snaps;
            $summary{snapshots} += scalar keys %$snaps;
        }
    }

    # Credentials — copied verbatim, NEVER printed/logged.
    my $legacy_creds = "$legacy_base/$storeid.creds";
    if ( -f $legacy_creds ) {
        my $c = decode_json( _slurp($legacy_creds) );
        if ( defined $c->{username} && defined $c->{password} ) {
            $summary{creds} = 1;
            PVE::Storage::FCLU::Credentials->new( storeid => $storeid, base_dir => $fclu_base )
                ->store( $c->{username}, $c->{password} )
                unless $dry_run;
        }
    }

    return \%summary;
}

1;
