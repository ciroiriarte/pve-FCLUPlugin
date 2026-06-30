package PVE::Storage::FCLU::Driver::Mock;

use strict;
use warnings;

use PVE::Storage::FCLU::Driver;
use parent -norequire, 'PVE::Storage::FCLU::Driver';

use PVE::Storage::FCLU::Error;
use PVE::Storage::FCLU::Capabilities;

# The executable reference implementation of fclu-driver-api-1 (ARCHITECTURE.md
# §12.5). An in-memory array backend that honours every §12.1 data shape and the
# §12.2 idempotency/retry contract, with no I/O. Two jobs:
#
#   1. It is the conformance oracle: the parametrized contract-test suite runs
#      against Mock, so "conforms to api-1" is defined as "behaves like Mock".
#   2. It can be told to raise ANY error `code` on demand (§13.6) via arm_fault(),
#      so the core's retry/compensate behaviour (§13.4) is testable for every
#      classification without a real array.
#
# Determinism: ids come from a counter and timestamps from a monotonic clock, so
# runs are reproducible (no wall-clock / RNG). Drivers raise PVE::Storage::FCLU
# ::Error on failure (§12.4) — never a bare die — and Mock models exactly that.

use constant {
    DEFAULT_POOL       => 'mock-pool-0',
    DEFAULT_POOL_BYTES => 1 << 40,            # 1 TiB
    CLOCK_EPOCH        => 1_700_000_000,      # fixed monotonic seed (no real time)
};

# Full-featured default capability object so the contract suite can exercise the
# optional surface (snapshots, clones, qos). Callers may override via new().
my %DEFAULT_CAPS = (
    snapshot    => { single => 1, consistency_group => 1, rollback => 1 },
    clone       => { linked => 1, from_snapshot => 1, from_base => 1 },
    copy        => { full => 1, from_snapshot => 1, from_base => 1 },
    qos         => { per_lu => 1 },
    resize      => { grow_online => 1, shrink => 0 },
    transfer    => { import => 1, migrate_pool => 1 },
    replication => { tc => 0, ur => 0, gad => 0 },
);

sub new {
    my ($class, %args) = @_;

    my $total = $args{pool_total} // DEFAULT_POOL_BYTES;

    my $self = {
        # --- backend state ---
        lus        => {},        # backend_id => LU record
        mappings   => {},        # backend_id => { hostname => mapping descriptor }
        access     => {},        # hostname   => { access_ref, initiators }
        snaps      => {},        # snap_id    => snapshot record
        pool_ref   => $args{pool_ref} // DEFAULT_POOL,
        pool_total => $total,
        pool_free  => $total,
        target_ports => $args{target_ports} // [
            { wwpn => '50060e8000aaaa00', port_id => 'CL1-A' },
            { wwpn => '50060e8000aaaa01', port_id => 'CL2-A' },
        ],
        caps    => PVE::Storage::FCLU::Capabilities->normalize(
            $args{capabilities} // \%DEFAULT_CAPS ),
        profile => $args{profile} // {
            family => 'mock', min_lu_mb => 1, op_timeout_s => 60, quirks => {},
        },
        # --- bookkeeping ---
        connected => 1,          # ready to use without an explicit connect()
        _seq      => 0,          # backend_id / naa allocator
        _snap_seq => 0,
        _lun_seq  => 0,
        _clock    => CLOCK_EPOCH,
        _faults   => {},         # method => [ fault spec, ... ] (FIFO)
    };

    return bless $self, $class;
}

# --- fault injection (§13.6) ----------------------------------------------------

# arm_fault($method, code => ..., [message, retryable, transient, vendor, times,
# always]). Queues a fault consumed the next time $method runs (FIFO). `times`
# (default 1) fires it that many calls then drops it; `always => 1` makes it
# permanent until clear_faults(). Explicit retryable/transient override the code
# default, exactly as a real driver may (§13.3).
sub arm_fault {
    my ($self, $method, %spec) = @_;
    die "arm_fault: 'code' required\n" unless defined $spec{code};
    $spec{times} //= 1;
    push @{ $self->{_faults}{$method} }, \%spec;
    return $self;
}

# clear_faults([$method]) — drop armed faults for one method, or all of them.
sub clear_faults {
    my ($self, $method) = @_;
    if ( defined $method ) { delete $self->{_faults}{$method} }
    else                   { $self->{_faults} = {} }
    return $self;
}

# Consume and raise an armed fault for $method, if any.
sub _maybe_fault {
    my ($self, $method) = @_;
    my $q = $self->{_faults}{$method} or return;
    my $f = $q->[0] or return;

    unless ( $f->{always} ) {
        if ( --$f->{times} <= 0 ) { shift @$q }
    }

    PVE::Storage::FCLU::Error->throw(
        code    => $f->{code},
        message => $f->{message} // "injected '$f->{code}' fault on $method",
        ( exists $f->{retryable} ? ( retryable => $f->{retryable} ) : () ),
        ( exists $f->{transient} ? ( transient => $f->{transient} ) : () ),
        ( exists $f->{vendor}    ? ( vendor    => $f->{vendor} )    : () ),
    );
}

# --- internal helpers ----------------------------------------------------------

sub _err { shift; PVE::Storage::FCLU::Error->throw(@_) }

sub _require_connected {
    my ($self) = @_;
    $self->_err( code => 'connectivity', message => 'driver is not connected' )
        unless $self->{connected};
}

# Validate the §12.1 backend_id / opaque-handle charset (taint surface, §10).
sub _check_id {
    my ($self, $id, $what) = @_;
    $self->_err( code => 'invalid', message => "$what must be a non-empty string" )
        unless defined $id && length $id;
    $self->_err( code => 'invalid', message => "$what '$id' violates the api-1 charset" )
        unless $id =~ /^[\w.:-]{1,255}$/;
    return $id;
}

sub _alloc_id { my ($self) = @_; return '' . ( ++$self->{_seq} + 1000 ) }

# Deterministic canonical identity (§12.1): array-reported, lowercase hex.
sub _make_identity {
    my ($self) = @_;
    my $naa = sprintf( '60060e8000%010x', ++$self->{_seq} );
    return { protocol => 'scsi-fc', ids => { naa => $naa, eui => undef, wwid => undef } };
}

# undef-safe scalar equality, for create_lu's retry-safe attribute re-assert.
sub _eq {
    my ($a, $b) = @_;
    return 1 if !defined $a && !defined $b;
    return 0 if !defined $a || !defined $b;
    return $a eq $b;
}

sub _lu_or_not_found {
    my ($self, $backend_id) = @_;
    my $lu = $self->{lus}{$backend_id}
        or $self->_err( code => 'not_found', message => "no such LU '$backend_id'" );
    return $lu;
}

# A defensive copy of an LU's public descriptor (§12.1) — the core must not be
# able to mutate driver-internal state through a returned ref.
sub _lu_descriptor {
    my ($self, $lu) = @_;
    return {
        backend_id   => $lu->{backend_id},
        size_bytes   => $lu->{size_bytes},
        label        => $lu->{label},
        pool_ref     => $lu->{pool_ref},
        identity     => { protocol => $lu->{identity}{protocol},
                          ids => { %{ $lu->{identity}{ids} } } },
        backend_meta => { %{ $lu->{backend_meta} } },
    };
}

# --- session / introspection ---------------------------------------------------

sub connect    { my ($self) = @_; $self->_maybe_fault('connect'); $self->{connected} = 1; return $self }
sub disconnect { my ($self) = @_; $self->{connected} = 0; return 1 }
sub ping       { my ($self) = @_; $self->_maybe_fault('ping'); $self->_require_connected; return 1 }

sub detect_profile {
    my ($self) = @_;
    $self->_maybe_fault('detect_profile');
    return { %{ $self->{profile} } };
}

sub capabilities {
    my ($self) = @_;
    $self->_maybe_fault('capabilities');
    return PVE::Storage::FCLU::Capabilities->normalize( $self->{caps} );
}

sub storage_status {
    my ($self) = @_;
    $self->_maybe_fault('storage_status');
    $self->_require_connected;
    my $total = $self->{pool_total};
    my $free  = $self->{pool_free};
    return ( $total, $free, $total - $free );
}

# --- LU lifecycle --------------------------------------------------------------

sub create_lu {
    my ($self, %args) = @_;
    $self->_require_connected;
    $self->_maybe_fault('create_lu');

    my $size = $args{size_bytes};
    $self->_err( code => 'invalid', message => 'size_bytes must be a positive integer' )
        unless defined $size && $size =~ /^[0-9]+$/ && $size > 0;

    my $pool_ref = $args{pool_ref} // $self->{pool_ref};
    my $label    = $args{label};
    my $rid      = $args{requested_id};

    # Retry-safe re-assert (§12.2): an existing id that MATCHES is success; a
    # MISMATCH is a hard already_exists.
    if ( defined $rid && ( my $lu = $self->{lus}{$rid} ) ) {
        if ( $lu->{size_bytes} == $size
            && _eq( $lu->{pool_ref}, $pool_ref )
            && _eq( $lu->{label}, $label ) ) {
            return $lu->{backend_id};
        }
        $self->_err( code => 'already_exists',
            message => "LU '$rid' already exists with different attributes" );
    }

    $self->_err( code => 'out_of_space',
        message => "pool '$pool_ref' has insufficient free space" )
        if $size > $self->{pool_free};

    my $bid = defined $rid ? $self->_check_id( $rid, 'requested_id' ) : $self->_alloc_id;

    $self->{lus}{$bid} = {
        backend_id   => $bid,
        size_bytes   => $size + 0,
        label        => $label,
        pool_ref     => $pool_ref,
        identity     => $self->_make_identity,
        backend_meta => {},
        qos          => undef,
    };
    $self->{pool_free} -= $size;

    return $bid;
}

sub delete_lu {
    my ($self, $backend_id) = @_;
    $self->_require_connected;
    $self->_maybe_fault('delete_lu');

    # Idempotent teardown (§12.2/§13.3): absent => success, never not_found.
    my $lu = $self->{lus}{$backend_id} or return 1;

    $self->{pool_free} += $lu->{size_bytes};
    delete $self->{lus}{$backend_id};
    delete $self->{mappings}{$backend_id};
    # Drop snapshots whose parent just went away.
    for my $sid ( keys %{ $self->{snaps} } ) {
        delete $self->{snaps}{$sid}
            if $self->{snaps}{$sid}{parent_backend_id} eq $backend_id;
    }
    return 1;
}

sub get_lu {
    my ($self, $backend_id) = @_;
    $self->_require_connected;
    $self->_maybe_fault('get_lu');
    return $self->_lu_descriptor( $self->_lu_or_not_found($backend_id) );
}

sub list_lus {
    my ($self, %filter) = @_;
    $self->_require_connected;
    $self->_maybe_fault('list_lus');

    my @out;
    for my $lu ( values %{ $self->{lus} } ) {
        next if defined $filter{pool_ref} && !_eq( $lu->{pool_ref}, $filter{pool_ref} );
        next if defined $filter{label}    && !_eq( $lu->{label}, $filter{label} );
        push @out, $self->_lu_descriptor($lu);
    }
    # Deterministic order for reproducible tests.
    return [ sort { $a->{backend_id} cmp $b->{backend_id} } @out ];
}

sub set_lu_label {
    my ($self, $backend_id, $label) = @_;
    $self->_require_connected;
    $self->_maybe_fault('set_lu_label');
    my $lu = $self->_lu_or_not_found($backend_id);
    $lu->{label} = $label;   # converge; idempotent no-op when already equal
    return 1;
}

sub resize_lu {
    my ($self, $backend_id, $new_size) = @_;
    $self->_require_connected;
    $self->_maybe_fault('resize_lu');
    my $lu = $self->_lu_or_not_found($backend_id);

    $self->_err( code => 'invalid', message => 'new size must be a positive integer' )
        unless defined $new_size && $new_size =~ /^[0-9]+$/ && $new_size > 0;

    my $delta = $new_size - $lu->{size_bytes};
    return 1 if $delta == 0;   # converge: already at target
    $self->_err( code => 'invalid', message => 'shrink is not supported (api-1)' )
        if $delta < 0;
    $self->_err( code => 'out_of_space', message => 'pool cannot satisfy grow' )
        if $delta > $self->{pool_free};

    $lu->{size_bytes} = $new_size + 0;
    $self->{pool_free} -= $delta;
    return 1;
}

sub set_lu_qos {
    my ($self, $backend_id, $qos) = @_;
    $self->_require_connected;
    $self->_maybe_fault('set_lu_qos');
    my $lu = $self->_lu_or_not_found($backend_id);
    $lu->{qos} = ref $qos eq 'HASH' ? { %$qos } : undef;
    return 1;
}

sub get_lu_qos {
    my ($self, $backend_id) = @_;
    $self->_require_connected;
    $self->_maybe_fault('get_lu_qos');
    my $lu = $self->_lu_or_not_found($backend_id);
    return defined $lu->{qos} ? { %{ $lu->{qos} } } : undef;
}

sub migrate_lu {
    my ($self, $backend_id, $dest_pool_ref) = @_;
    $self->_require_connected;
    $self->_maybe_fault('migrate_lu');
    my $lu = $self->_lu_or_not_found($backend_id);
    $lu->{pool_ref} = $dest_pool_ref;   # converge; idempotent
    return 1;
}

# --- host access ---------------------------------------------------------------

sub _check_host_ctx {
    my ($self, %ctx) = @_;
    for my $k (qw(hostname protocol initiators)) {
        $self->_err( code => 'invalid', message => "host_ctx missing '$k'" )
            unless defined $ctx{$k};
    }
    $self->_err( code => 'invalid', message => "unsupported protocol '$ctx{protocol}'" )
        unless $ctx{protocol} eq 'scsi-fc';
    $self->_err( code => 'invalid', message => 'host_ctx initiators must be a non-empty arrayref' )
        unless ref $ctx{initiators} eq 'ARRAY' && @{ $ctx{initiators} };
    return $ctx{hostname};
}

sub ensure_host_access {
    my ($self, %ctx) = @_;
    $self->_require_connected;
    $self->_maybe_fault('ensure_host_access');
    my $hostname = $self->_check_host_ctx(%ctx);

    # Idempotent (§12.2): reconcile the per-node access object, return its handle.
    my $access_ref = "PVE_$hostname";
    $self->{access}{$hostname} = {
        access_ref => $access_ref,
        initiators => [ @{ $ctx{initiators} } ],
    };
    return $access_ref;
}

sub publish_lu {
    my ($self, $backend_id, %ctx) = @_;
    $self->_require_connected;
    $self->_maybe_fault('publish_lu');
    $self->_lu_or_not_found($backend_id);
    my $hostname = $self->_check_host_ctx(%ctx);

    # ensure_host_access is safe to call on every publish (§12.2).
    my $access_ref = $self->ensure_host_access(%ctx);

    # Idempotent (§12.2): existing mapping returned unchanged, no error.
    my $existing = $self->{mappings}{$backend_id}{$hostname};
    return { %$existing } if $existing;

    my $mapping = {
        hostname     => $hostname,
        access_ref   => $access_ref,
        lun          => $self->{_lun_seq}++,
        target_wwpns => [ map { $_->{wwpn} } @{ $self->{target_ports} } ],
    };
    $self->{mappings}{$backend_id}{$hostname} = $mapping;
    return { %$mapping };
}

sub unpublish_lu {
    my ($self, $backend_id, %ctx) = @_;
    $self->_require_connected;
    $self->_maybe_fault('unpublish_lu');
    my $hostname = $self->_check_host_ctx(%ctx);

    # Idempotent teardown (§12.2): removes ONLY this node's mapping; success even
    # if the LU or the mapping is already gone.
    delete $self->{mappings}{$backend_id}{$hostname}
        if $self->{mappings}{$backend_id};
    delete $self->{mappings}{$backend_id}
        if $self->{mappings}{$backend_id} && !%{ $self->{mappings}{$backend_id} };
    return 1;
}

sub list_lu_mappings {
    my ($self, $backend_id) = @_;
    $self->_require_connected;
    $self->_maybe_fault('list_lu_mappings');
    $self->_lu_or_not_found($backend_id);   # authoritative read of a real LU

    my $by_host = $self->{mappings}{$backend_id} // {};
    return [
        map { { %{ $by_host->{$_} }, target_wwpns => [ @{ $by_host->{$_}{target_wwpns} } ] } }
        sort keys %$by_host
    ];
}

sub target_ports {
    my ($self, %ctx) = @_;
    $self->_maybe_fault('target_ports');
    return [ map { { %$_ } } @{ $self->{target_ports} } ];
}

# --- identity ------------------------------------------------------------------

sub get_lu_identity {
    my ($self, $backend_id) = @_;
    $self->_require_connected;
    $self->_maybe_fault('get_lu_identity');
    my $lu = $self->_lu_or_not_found($backend_id);
    return { protocol => $lu->{identity}{protocol}, ids => { %{ $lu->{identity}{ids} } } };
}

# --- snapshots / clones --------------------------------------------------------

sub _new_snap {
    my ($self, $parent, %args) = @_;
    my $sid = defined $args{snap_id}
        ? $self->_check_id( $args{snap_id}, 'snap_id' )
        : 'snap-' . ( ++$self->{_snap_seq} );
    return {
        snap_id           => $sid,
        parent_backend_id => $parent,
        created           => $self->{_clock}++,
        meta              => ref $args{meta} eq 'HASH' ? { %{ $args{meta} } } : {},
    };
}

sub create_snapshot {
    my ($self, $backend_id, %args) = @_;
    $self->_require_connected;
    $self->_maybe_fault('create_snapshot');
    $self->_lu_or_not_found($backend_id);

    # Retry-safe via snap_id re-assert (§12.2): same parent => success, else
    # already_exists.
    if ( defined $args{snap_id} && ( my $s = $self->{snaps}{ $args{snap_id} } ) ) {
        return { %$s } if $s->{parent_backend_id} eq $backend_id;
        $self->_err( code => 'already_exists',
            message => "snapshot '$args{snap_id}' exists on a different LU" );
    }

    my $snap = $self->_new_snap( $backend_id, %args );
    $self->{snaps}{ $snap->{snap_id} } = $snap;
    return { %$snap };
}

sub delete_snapshot {
    my ($self, $snap_id) = @_;
    $self->_require_connected;
    $self->_maybe_fault('delete_snapshot');
    delete $self->{snaps}{$snap_id};   # idempotent: absent => success
    return 1;
}

sub restore_snapshot {
    my ($self, $snap_id) = @_;
    $self->_require_connected;
    $self->_maybe_fault('restore_snapshot');
    $self->{snaps}{$snap_id}
        or $self->_err( code => 'not_found', message => "no such snapshot '$snap_id'" );
    return 1;
}

sub list_snapshots {
    my ($self, $backend_id) = @_;
    $self->_require_connected;
    $self->_maybe_fault('list_snapshots');
    $self->_lu_or_not_found($backend_id);
    return [
        map  { { %{ $self->{snaps}{$_} }, meta => { %{ $self->{snaps}{$_}{meta} } } } }
        sort
        grep { $self->{snaps}{$_}{parent_backend_id} eq $backend_id }
        keys %{ $self->{snaps} }
    ];
}

# Clone helper: a clone is a brand-new LU of the same size in the same pool.
sub _clone {
    my ($self, $backend_id, %args) = @_;
    my $src = $self->_lu_or_not_found($backend_id);
    return $self->create_lu(
        size_bytes   => $src->{size_bytes},
        pool_ref     => $args{pool_ref} // $src->{pool_ref},
        label        => $args{label},
        requested_id => $args{requested_id},
    );
}

sub create_linked_clone {
    my ($self, $backend_id, %args) = @_;
    $self->_require_connected;
    $self->_maybe_fault('create_linked_clone');
    return $self->_clone( $backend_id, %args );
}

sub create_full_clone {
    my ($self, $backend_id, %args) = @_;
    $self->_require_connected;
    $self->_maybe_fault('create_full_clone');
    return $self->_clone( $backend_id, %args );
}

sub create_cg_snapshot {
    my ($self, $backend_ids, %args) = @_;
    $self->_require_connected;
    $self->_maybe_fault('create_cg_snapshot');
    $self->_err( code => 'invalid', message => 'create_cg_snapshot needs an arrayref of backend_ids' )
        unless ref $backend_ids eq 'ARRAY' && @$backend_ids;

    # Validate every member exists BEFORE creating any (all-or-nothing intent).
    $self->_lu_or_not_found($_) for @$backend_ids;

    my @snaps;
    for my $bid (@$backend_ids) {
        my $snap = $self->_new_snap( $bid, %args );
        $self->{snaps}{ $snap->{snap_id} } = $snap;
        push @snaps, { %$snap };
    }
    return \@snaps;
}

1;
