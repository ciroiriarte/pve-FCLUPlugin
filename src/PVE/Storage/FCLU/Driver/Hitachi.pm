package PVE::Storage::FCLU::Driver::Hitachi;

use strict;
use warnings;

use POSIX qw(ceil);
use Carp qw(croak);

use PVE::Storage::FCLU::Driver;
use parent -norequire, 'PVE::Storage::FCLU::Driver';

use PVE::Storage::FCLU::Error;
use PVE::Storage::FCLU::Capabilities;
use PVE::Storage::FCLU::Driver::Hitachi::RestClient;

# Hitachi VSP driver for fclu-driver-api-1 (ARCHITECTURE.md §2/§4/§13). It WRAPS
# the vendored RestClient transport (kept verbatim, never rewritten) and presents
# the normalized contract: §12.1 data shapes out, §13 FCLU::Error on failure.
#
# RestClient dies with BARE STRINGS carrying the HTTP status / Hitachi job error
# text. This driver is the translation boundary (§13.5): every RestClient call is
# funnelled through _call(), which catches those strings and re-dies a blessed,
# classified FCLU::Error so the core never branches on a vendor message and no raw
# payload leaks into an admin-facing message.
#
# Slice A scope: session, profile/capabilities, error translation, and the LU
# lifecycle/introspection/identity. Host-access (host-group/HMO), snapshots/clones,
# and the full parametrized contract suite are deferred to later slices.

use constant MIB => 1024 * 1024;

# Per-platform Profile (§4). The platform enum selects deltas; notably the default
# control-plane PORT encodes the Ops Center Configuration Manager server (23451,
# the dedicated CM server fronting a VSP G) vs the embedded/direct GUM REST (443,
# VSP One and the E/G midrange) — the maintainer's chosen Ops-Center-first
# validation axis lives here, as a profile concern, not a separate driver class.
#
# QoS (`qos`) is model-gated per Hitachi's documented support matrix (see the OpenStack
# HBSD "System requirements for a QoS"): only VSP F/G350-900 and VSP 5000 support QoS
# (firmware 88-06-01+ / CM REST API 10.2.0+). The VSP E series (E590/E790/E990/E1090,
# `vsp_e`) and VSP One Block (`vsp_one`) do NOT — their embedded GUM REST exposes no
# QoS surface at all (LIVE-CONFIRMED on an E590H: the LDEV object carries no QoS fields
# and every io-control endpoint 404s). So qos=1 only for `vsp_g` (Ops Center CM),
# UNVALIDATED end-to-end until §10 lands the CM connector against a real G/F array.
my %PLATFORM = (
    vsp_g => {
        family       => 'vsp_g',
        default_port => 23451,           # Ops Center Configuration Manager server
        min_lu_mb    => 48,              # POST /ldevs <= 46 MiB fails the async job
        max_label_len => 32,
        op_timeout_s => 600,
        # qos: VSP F/G350-900 support it (fw 88-06-01+, CM REST 10.2.0+). Advertised
        # here but UNVALIDATED — needs the §10 Ops Center CM connector + a real G/F array.
        capabilities => { snapshot => 1, clone => 1, qos => 1, cg_snapshot => 1 },
        quirks       => {},
    },
    vsp_e => {
        family       => 'vsp_e',
        default_port => 443,             # embedded/direct GUM REST (e.g. E590H)
        min_lu_mb    => 48,
        max_label_len => 32,
        op_timeout_s => 600,
        # qos=0: the VSP E series does not support QoS (no REST surface — live-confirmed on E590H).
        capabilities => { snapshot => 1, clone => 1, qos => 0, cg_snapshot => 1 },
        quirks       => {
            list_luns_ignores_lu_filter => 1,
            used_pool_capacity_missing  => 1,
            supports_hmo_91             => 1,
            hostWwnNickname_unsupported => 1,
            split_snapshot_omit_operationType => 1,
        },
    },
    vsp_one => {
        family       => 'vsp_one',
        default_port => 443,
        min_lu_mb    => 48,
        max_label_len => 32,
        op_timeout_s => 600,
        # qos=0: VSP One Block is not in Hitachi's QoS support matrix (embedded GUM REST).
        capabilities => { snapshot => 1, clone => 1, qos => 0, cg_snapshot => 1 },
        quirks       => {},
    },
);

sub new {
    my ($class, %opts) = @_;

    my $platform = $opts{platform} // 'vsp_one';
    croak "unknown platform '$platform'" unless $PLATFORM{$platform};

    my $self = bless {
        platform => $platform,
        profile  => undef,                 # computed lazily / by detect_profile
        pool_id  => $opts{pool_id},        # the configured DP pool ref
        snap_pool_id => $opts{snap_pool_id} // $opts{pool_id},   # Thin Image snapshot-data pool
        rest     => $opts{rest},           # dependency-injected for tests
        # Host-access config (§2). The array FC ports the per-node host groups live
        # on, and the host-mode knobs — all Hitachi-specific, hence driver-side
        # (they were scfg fields in the reference plugin).
        array_ports       => _as_list( $opts{array_ports} ),
        host_mode         => $opts{host_mode} // 'LINUX/IRIX',
        # Numeric-only (HMO ids), mirroring the reference's grep — a malformed
        # token must never reach the array (where int() would coerce it to 0).
        host_mode_options => [ grep { /^\d+$/ } @{ _as_list(
            defined $opts{host_mode_options} ? $opts{host_mode_options} : '2,22,25,68' ) } ],
        skip_unmap_io_check => $opts{skip_unmap_io_check} ? 1 : 0,
        # Host group name prefix (§ multi-cluster). Namespaces this cluster's host
        # groups on a SHARED array pool so two clusters do not collide on
        # <prefix>_<hostname>. The plugin resolves it (explicit config, else the PVE
        # cluster name); default 'PVE' preserves the legacy name for a single cluster.
        host_group_prefix => ( defined $opts{host_group_prefix} && length $opts{host_group_prefix} )
            ? $opts{host_group_prefix} : 'PVE',
    }, $class;

    # Build a real transport unless one was injected (tests inject a mock).
    unless ( $self->{rest} ) {
        my $prof = $self->profile;
        # Control plane (§10): 'cm' = a fronting Ops Center Configuration Manager
        # server (default port 23451) vs the array's own embedded GUM REST (443).
        # Orthogonal to the array MODEL that `platform` selects (the model governs
        # capabilities like QoS). The CM and the embedded GUM speak the SAME
        # Configuration Manager REST API — session-less basic auth and storage-scoped
        # jobs work identically on both — so control_plane ONLY picks the default
        # port; there is no behavioural fork. A CM-fronted E-series is
        # control_plane=cm + platform=vsp_e (correct QoS gating: none).
        my $is_cm = ( ( $opts{control_plane} // 'embedded' ) eq 'cm' ) ? 1 : 0;
        $self->{rest} = PVE::Storage::FCLU::Driver::Hitachi::RestClient->new(
            mgmt_ip    => $opts{mgmt_ip},
            storage_id => $opts{storage_id},
            username   => $opts{username},
            password   => $opts{password},
            port       => $opts{port} // ( $is_cm ? 23451 : $prof->{default_port} ),
            ( $opts{control_plane} ? ( control_plane => $opts{control_plane} ) : () ),
            # Poll async CM REST jobs up to the profile's operation timeout (large TI
            # v-vol clones can exceed the RestClient's shorter default).
            job_timeout => $prof->{op_timeout_s},
            ( defined $opts{debug} ? ( debug => $opts{debug} ) : () ),
            ( defined $opts{tls_verify}  ? ( tls_verify  => $opts{tls_verify} )  : () ),
            ( defined $opts{tls_ca_file} ? ( tls_ca_file => $opts{tls_ca_file} ) : () ),
            ( defined $opts{sessionless} ? ( sessionless => $opts{sessionless} ) : () ),
        );
    }

    return $self;
}

# ── Profile / capabilities ──

# The §4 profile for the configured platform. Cached after first build. A future
# enhancement queries the array's microcode at connect() to refine quirks; for now
# it is a static per-platform table.
sub profile {
    my ($self) = @_;
    $self->{profile} //= { %{ $PLATFORM{ $self->{platform} } } };
    return $self->{profile};
}

sub detect_profile {
    my ($self) = @_;
    return { %{ $self->profile } };
}

# Normalized §6 capability object built from the profile's coarse flags.
sub capabilities {
    my ($self) = @_;
    my $c = $self->profile->{capabilities} // {};
    return PVE::Storage::FCLU::Capabilities->normalize( {
        snapshot => { single => $c->{snapshot} ? 1 : 0,
                      consistency_group => $c->{cg_snapshot} ? 1 : 0,
                      rollback => $c->{snapshot} ? 1 : 0 },
        clone    => { linked => $c->{clone} ? 1 : 0,
                      from_snapshot => $c->{clone} ? 1 : 0,
                      from_base => $c->{clone} ? 1 : 0 },
        copy     => { full => $c->{clone} ? 1 : 0, from_snapshot => 1, from_base => 1 },
        qos      => { per_lu => $c->{qos} ? 1 : 0 },
        resize   => { grow_online => 1, shrink => 0 },
        transfer => { import => 0, migrate_pool => 0 },   # migrate_lu not implemented yet
        replication => {},   # gated behind the optional Replication mixin (§8)
    } );
}

# ── Session ──

sub connect {
    my ($self) = @_;
    $self->_call( sub { $self->{rest}->login } );
    return $self;
}

# Teardown MUST be guaranteed even on error paths (carried discipline): logout is
# best-effort and never propagates a failure that would mask the real error.
sub disconnect {
    my ($self) = @_;
    eval { $self->{rest}->logout };
    return 1;
}

sub ping {
    my ($self) = @_;
    $self->_call( sub { $self->{rest}->keepalive } );
    return 1;
}

# ── Error translation boundary (§13) ──

# Run a RestClient call, translating its bare-string die into a classified
# FCLU::Error. Preserves list/scalar context for the wrapped call.
sub _call {
    my ($self, $code) = @_;
    my $wa = wantarray;
    my @r;
    my $ok = eval {
        if ($wa) { @r = $code->() } else { $r[0] = $code->() }
        1;
    };
    return $wa ? @r : $r[0] if $ok;
    die $self->_translate_rest_error($@);
}

my %CODE_MESSAGE = (
    auth         => 'array authentication failed',
    not_found    => 'array object not found',
    conflict     => 'array reported a state conflict',
    already_exists => 'array object already exists',
    array_busy   => 'array is busy or throttling requests',
    connectivity => 'array management endpoint is unreachable',
    out_of_space => 'storage pool capacity is exhausted',
    limit        => 'array object/count limit reached',
    invalid      => 'array rejected the request as invalid',
    timeout      => 'array operation did not converge in time',
    internal     => 'unexpected array/driver error',
);

# Map a RestClient bare-string failure to a blessed FCLU::Error. RestClient throws
# strings like "API request failed: POST <url> -> 409 Conflict <body>" or "Job
# <id> failed: <KART text>" / "Job <id> timed out ...". We classify off the HTTP
# status first, then job/transport/keyword heuristics. The admin-facing `message`
# is a normalized per-code string (no raw payload, §13.5); the raw text is carried
# in `vendor` for the task log only.
# T3-8: HBSD's SSB1,SSB2 error-code pairs (keyed "SSB1,SSB2", uppercased) → §13 codes.
# Exact classification where the array's English message is fragile / locale-dependent.
my %SSB_CODE = (
    '2E22,0001' => 'already_exists',   # LDEV already defined
    'B958,015A' => 'already_exists',   # LU path already defined
    'B958,0947' => 'conflict',         # another LDEV already mapped at this LUN
    'B957,4184' => 'limit',            # exceed max WWN per host group
    '2E11,2209' => 'limit',            # no available LDEV id
    '2E10,2302' => 'limit',            # max consistency-group count exceeded
    '2E13,9900' => 'limit',            # max pairs in a consistency group exceeded
    '2E30,600E' => 'invalid',          # invalid snapshot pool
    '2E11,2205' => 'array_busy',       # resource locked (transient)
    '2E11,2206' => 'array_busy',       # resource locked (transient)
    '2E11,2207' => 'array_busy',       # resource locked (transient)
);
# messageId (KART id) → §13 code.
my %MSGID_CODE = (
    'KART00003-E' => 'array_busy',     # REST server busy
    'KART40050-E' => 'array_busy',     # lock failure
    'KART40051-E' => 'array_busy',
    'KART40052-E' => 'array_busy',
    'KART30013-E' => 'not_found',      # specified object does not exist
);

# Classify off the array's stable messageId / SSB code, or undef if unrecognized.
sub _classify_structured_error {
    my ($self, $mid, $ssb1, $ssb2) = @_;
    if ( defined $ssb1 && defined $ssb2 ) {
        my $c = $SSB_CODE{ uc("$ssb1,$ssb2") };
        return $c if $c;
    }
    return $MSGID_CODE{$mid} if defined $mid && $MSGID_CODE{$mid};
    return undef;
}

sub _translate_rest_error {
    my ($self, $err) = @_;

    # Already normalized (e.g. a nested _call) — pass through unchanged.
    return $err if ref $err && eval { $err->isa('PVE::Storage::FCLU::Error') };

    # T3-8: RestClient throws a RestError carrying the array's messageId + SSB code for
    # array/job failures; a plain string croak (transport, timeout, required-field) has none
    # and drops straight to the HTTP-status / English-text path below.
    my ($mid, $ssb1, $ssb2, $http);
    if ( ref $err && eval { $err->isa('PVE::Storage::FCLU::Driver::Hitachi::RestError') } ) {
        ($mid, $ssb1, $ssb2, $http) = ( $err->message_id, $err->ssb1, $err->ssb2, $err->http_status );
    }

    my $msg = "$err";
    $msg =~ s/\s+\z//;

    # Stable code FIRST; HTTP status + English regex are the fallback when the array gave no
    # code we recognize. Prefer the RestError's carried http_status over re-parsing the
    # message (which the string form still supports for plain-string dies).
    my $code = $self->_classify_structured_error( $mid, $ssb1, $ssb2 );

    my $status = $http;
    ($status) = $msg =~ /->\s*(\d{3})\b/ unless defined $status;
    if ( !defined $code && defined $status ) {
        if    ( $status == 401 || $status == 403 ) { $code = 'auth' }
        elsif ( $status == 404 )                   { $code = 'not_found' }
        elsif ( $status == 409 ) { $code = $msg =~ /alread|exist|duplicate/i ? 'already_exists' : 'conflict' }
        elsif ( $status == 429 || $status == 503 ) { $code = 'array_busy' }
        elsif ( $status == 400 )                   { $code = 'invalid' }
        elsif ( $status >= 500 )                   { $code = 'internal' }
    }

    # Transport / job-level overrides (no HTTP status, or a generic 5xx).
    if ( !defined $code || $code eq 'internal' ) {
        if ( $msg =~ /timed out/i ) { $code = 'timeout' }
        elsif ( $msg =~ /can'?t connect|connection (refused|reset|timed out)|no route to host|network is unreachable|name or service not known/i ) {
            $code = 'connectivity';
        }
    }

    # Hitachi job failures carry KART text rather than an HTTP status.
    if ( !defined $code ) {
        if    ( $msg =~ /insufficient|capacity|pool .*full|out of space/i ) { $code = 'out_of_space' }
        elsif ( $msg =~ /alread(y)? (exists|defined)|duplicate/i )          { $code = 'already_exists' }
        # "does not have LU paths" is a PRECONDITION failure (the volume must be mapped
        # for this operation), NOT an absent object. Must be matched BEFORE the generic
        # "does not exist" rule below: the array phrases it as
        # "The specified snapshot P-VOL does not have LU paths, or the specified snapshot
        # pair does not exist" — the trailing "does not exist" would otherwise mis-classify
        # a mapping precondition as not_found (which is misleading and hid the real cause).
        elsif ( $msg =~ /does not have LU paths/i ) { $code = 'invalid' }
        # "LDEV is not installed" is the array's phrasing for an absent/NOT DEFINED
        # ldev slot — treat it as not_found so idempotent teardown (delete_lu) succeeds
        # instead of failing [internal] and leaking the registry entry.
        elsif ( $msg =~ /not (found|defined|installed)|does not exist|no such/i ) { $code = 'not_found' }
        elsif ( $msg =~ /limit|maximum number|too many/i )                  { $code = 'limit' }
    }

    $code //= 'internal';

    return PVE::Storage::FCLU::Error->new(
        code    => $code,
        message => "Hitachi: $CODE_MESSAGE{$code}",
        vendor  => {
            raw => $msg,
            ( defined $mid  ? ( message_id => $mid )       : () ),
            ( defined $ssb1 ? ( ssb => uc("$ssb1,$ssb2") ) : () ),
        },
    );
}

# ── LU lifecycle / introspection (§12.1/§12.2) ──

sub create_lu {
    my ($self, %args) = @_;

    my $size = $args{size_bytes};
    $self->_err( 'invalid', 'size_bytes must be a positive integer' )
        unless defined $size && $size =~ /^[0-9]+$/ && $size > 0;

    my $pool = defined $args{pool_ref} ? $args{pool_ref} : $self->{pool_id};
    $self->_err( 'invalid', 'no pool_ref configured' ) unless defined $pool;

    my $size_mb = ceil( $size / MIB );
    my $min     = $self->profile->{min_lu_mb} // 0;
    $size_mb = $min if $size_mb < $min;   # array minimum LU size (KART floor)

    my $label = $args{label};
    my $rid   = $args{requested_id};

    # Crash-retry-safe re-assert (§12.2): if requested_id already exists and
    # matches the requested size+pool, return it as success; a mismatch is a hard
    # already_exists.
    if ( defined $rid ) {
        if ( my $ex = $self->_get_ldev_or_undef($rid) ) {
            my $ex_pool = defined $ex->{poolId} ? "$ex->{poolId}" : undef;
            if ( ceil( $self->_ldev_bytes($ex) / MIB ) == $size_mb
                && defined $ex_pool && $ex_pool eq "$pool" ) {
                return "$rid";
            }
            $self->_err( 'already_exists',
                "ldev $rid exists with different size/pool" );
        }
    }

    my $res = $self->_call( sub {
        $self->{rest}->create_ldev(
            pool_id => $pool,
            size_mb => $size_mb,
            ( defined $rid ? ( ldev_id => $rid ) : () ),
        );
    } );

    my $bid = defined $rid ? "$rid" : "$res->{resourceId}";

    $self->_call( sub { $self->{rest}->set_ldev_label( $bid, $label ) } )
        if defined $label;

    return $bid;
}

sub delete_lu {
    my ($self, $backend_id) = @_;
    # Idempotent teardown (§12.2/§13.3): not_found becomes success.
    eval { $self->_call( sub { $self->{rest}->delete_ldev($backend_id) } ); 1 }
        and return 1;
    my $e = $@;
    return 1 if $self->_is_not_found($e);
    die $e;
}

sub get_lu {
    my ($self, $backend_id) = @_;
    my $ldev = $self->_call( sub { $self->{rest}->get_ldev($backend_id) } );
    $self->_err( 'not_found', "no such ldev '$backend_id'" )
        unless $self->_is_defined_ldev($ldev);
    return $self->_normalize_ldev($ldev);
}

sub list_lus {
    my ($self, %filter) = @_;
    # Pool-scoped listing. NOTE (slice A): full ldev_range paging via
    # list_defined_ldevs_in_range for whole-array orphan scans (§12.3) is wired
    # when the plugin's ldev_range config lands; here we list the configured pool.
    my $ldevs = $self->_call( sub {
        $self->{rest}->list_ldevs(
            ( defined $self->{pool_id} ? ( pool_id => $self->{pool_id} ) : () ),
            %filter,
        );
    } );
    return [ map { $self->_normalize_ldev($_) }
             grep { $self->_is_defined_ldev($_) } @$ldevs ];
}

# Vendor allocation hook — NOT part of the §2 contract. Return the first LDEV id in
# [$min,$max] that is neither DEFINED on the array nor in the caller-supplied
# `reserved` set (the registry's already-claimed ids). The paired FCLU::Plugin
# subclass calls this for ldev_range-constrained allocation, so create_lu gets an
# explicit in-range id and the §7 teardown fence stays valid (#20). Backend ids are
# strings (§7); ids are compared as strings. The RestClient pages the range (the
# GUM 503s on a whole-array count), skipping NOT DEFINED slots.
sub next_free_backend_id {
    my ($self, %args) = @_;
    my ( $min, $max ) = @args{qw(min max)};
    $self->_err( 'invalid', 'min/max are required and min must be <= max' )
        unless defined $min && defined $max && $min <= $max;

    my %used = map { ( "$_" => 1 ) } @{ $args{reserved} // [] };
    my $defined = $self->_call( sub { $self->{rest}->list_defined_ldevs_in_range( $min, $max ) } );
    $used{ "$_->{ldevId}" } = 1 for grep { defined $_->{ldevId} } @$defined;

    for my $id ( $min .. $max ) {
        return "$id" unless $used{"$id"};
    }
    $self->_err( 'out_of_space', "no free LDEV id in range $min-$max" );
}

sub set_lu_label {
    my ($self, $backend_id, $label) = @_;
    $self->_call( sub { $self->{rest}->set_ldev_label( $backend_id, $label ) } );
    return 1;
}

sub resize_lu {
    my ($self, $backend_id, $new_size) = @_;
    $self->_err( 'invalid', 'new size must be a positive integer' )
        unless defined $new_size && $new_size =~ /^[0-9]+$/ && $new_size > 0;

    my $cur = $self->_call( sub { $self->{rest}->get_ldev($backend_id) } );
    $self->_err( 'not_found', "no such ldev '$backend_id'" )
        unless $self->_is_defined_ldev($cur);

    my $cur_bytes = $self->_ldev_bytes($cur);
    return 1 if $new_size <= $cur_bytes;   # converge: already >= target (no shrink)

    my $add_mb = ceil( ( $new_size - $cur_bytes ) / MIB );
    $self->_call( sub { $self->{rest}->expand_ldev( $backend_id, $add_mb ) } );
    return 1;
}

sub get_lu_identity {
    my ($self, $backend_id) = @_;
    my $ldev = $self->_call( sub { $self->{rest}->get_ldev($backend_id) } );
    $self->_err( 'not_found', "no such ldev '$backend_id'" )
        unless $self->_is_defined_ldev($ldev);
    return $self->_ldev_identity($ldev);
}

sub storage_status {
    my ($self) = @_;
    $self->_err( 'invalid', 'no pool_id configured' ) unless defined $self->{pool_id};

    my $pool = $self->_call( sub { $self->{rest}->get_pool( $self->{pool_id} ) } );

    my $total = ( $pool->{totalPoolCapacity} || 0 ) * MIB;
    # usedPoolCapacity is absent on some microcode (E590H quirk
    # used_pool_capacity_missing). Mirror the reference's three derivation tiers:
    #   1. usedPoolCapacity (direct, when present)
    #   2. total - availableVolumeCapacity (documented free field; E590H path)
    #   3. total * usedCapacityRate/100 (last-resort percentage)
    my $used;
    if ( defined $pool->{usedPoolCapacity} ) {
        $used = $pool->{usedPoolCapacity} * MIB;
    } elsif ( defined $pool->{availableVolumeCapacity} ) {
        $used = $total - $pool->{availableVolumeCapacity} * MIB;
    } elsif ( defined $pool->{usedCapacityRate} ) {
        $used = int( $total * $pool->{usedCapacityRate} / 100 );
    } else {
        $used = 0;
    }

    # Clamp against quirky microcode values so the core never sees used>total or a
    # negative free (matches the reference's defensive bounds).
    $used = 0      if $used < 0;
    $used = $total if $used > $total;
    my $free = $total - $used;
    $free = 0 if $free < 0;

    return ( $total, $free, $used );
}

# ── Snapshots / clones / QoS (§2, capability-gated) ──
#
# Thin Image (snapshots/linked-clone) and array QoS. Snapshots are array pairs
# identified by an array-assigned snapshotId; the driver resolves a freshly-created
# pair's id via a before/after list diff (the create job's resource id is not a
# portable handle). The Hitachi #22 quirk (split/restore reject operationType) lives
# inside the vendored RestClient, so the driver just calls split/restore.

sub _normalize_snap {
    my ($self, $s, $parent) = @_;
    return {
        snap_id           => "$s->{snapshotId}",
        parent_backend_id => "$parent",
        # Thin Image pairs carry no portable creation timestamp; the registry tracks
        # it. Present (per §12.1) but may be undef.
        created => $s->{createTime},
        meta    => {
            group  => $s->{snapshotGroupName},
            status => $s->{status},
            ( defined $s->{svolLdevId} ? ( svol => "$s->{svolLdevId}" ) : () ),
        },
    };
}

# Create one Thin Image pair on $pvol and return the new RAW snapshot object,
# resolved by diffing the pvol's pair list before/after.
sub _create_pair {
    my ($self, $pvol, %opts) = @_;
    $self->_err( 'invalid', 'no snap_pool_id configured' )
        unless defined $self->{snap_pool_id};

    my $before = $self->_call( sub { $self->{rest}->list_snapshots( pvol_ldev_id => $pvol ) } );
    my %had = map {; "$_->{snapshotId}" => 1 } @$before;   # leading ; forces a block, not a hashref

    $self->_call( sub {
        $self->{rest}->create_snapshot(
            pvol_ldev_id   => $pvol,
            snap_pool_id   => $self->{snap_pool_id},
            snapshot_group => $opts{snapshot_group} // 'pve_snap',
            # canCascade lets this snapshot's S-VOL later become a P-VOL of another pair
            # (clone-from-snapshot / cascaded chains); isDataReductionForceCopy permits the
            # pair when the P-VOL is a data-reduction (dedup/compression) volume. HBSD sets
            # both on EVERY Thin Image pair — FCLU previously set them only on the linked
            # clone, so a plain/CG snapshot of a DR P-VOL was array-rejected and a snapshot
            # could not be used as a clone source (N1).
            can_cascade                  => 1,
            is_data_reduction_force_copy => 1,
            ( defined $opts{auto_split}   ? ( auto_split => $opts{auto_split} ) : () ),
            ( $opts{is_consistency_group} ? ( is_consistency_group => 1 )       : () ),
        );
    } );

    my $after = $self->_call( sub { $self->{rest}->list_snapshots( pvol_ldev_id => $pvol ) } );
    my ($new) = grep { !$had{"$_->{snapshotId}"} } @$after;
    $self->_err( 'internal', "snapshot created on $pvol but not found in listing" )
        unless $new;
    return $new;
}

sub create_snapshot {
    my ($self, $backend_id, %args) = @_;

    # Re-assert (§12.2): a known snap_id already on this pvol is returned as success.
    if ( defined $args{snap_id} ) {
        my $snaps = $self->_call( sub { $self->{rest}->list_snapshots( pvol_ldev_id => $backend_id ) } );
        my ($ex) = grep { "$_->{snapshotId}" eq "$args{snap_id}" } @$snaps;
        return $self->_normalize_snap( $ex, $backend_id ) if $ex;
    }

    return $self->_normalize_snap(
        $self->_create_pair( $backend_id, snapshot_group => $args{snapshot_group} ),
        $backend_id );
}

sub delete_snapshot {
    my ($self, $snap_id) = @_;
    eval { $self->_call( sub { $self->{rest}->delete_snapshot($snap_id) } ); 1 }
        and return 1;
    my $e = $@;
    return 1 if $self->_is_not_found($e);   # idempotent teardown (§12.2)
    die $e;
}

sub restore_snapshot {
    my ($self, $snap_id, %opts) = @_;

    # N3: verify the pair actually belongs to the target volume before a reverse copy.
    # A stale/mis-recorded snap_id must never reverse-copy a FOREIGN P-VOL (HBSD's
    # has_snap_pair pvolLdevId check). When the caller passes the expected P-VOL, confirm
    # the array agrees; this also asserts the pair still exists.
    if ( defined $opts{pvol} ) {
        my $s   = $self->_call( sub { $self->{rest}->get_snapshot($snap_id) } );
        my $got = $s->{pvolLdevId};
        $self->_err( 'invalid',
            "refusing to restore snapshot '$snap_id': its P-VOL (" . ( $got // 'undef' )
            . ") does not match the target volume ($opts{pvol})" )
            unless defined $got && "$got" eq "$opts{pvol}";
    }

    # Reverse-copy S-VOL -> P-VOL, then RE-SPLIT so the snapshot stays a usable,
    # re-restorable PSUS pair (faithful to the reference #12 rollback: a restore
    # left un-split makes a later rollback to the same snapshot a silent no-op).
    $self->_call( sub { $self->{rest}->restore_snapshot($snap_id) } );
    # N2: a reverse copy of a large volume can far exceed the generic op timeout; use a
    # dedicated restore budget and FAIL rather than split mid-restore (which would leave
    # the P-VOL half-reverted and the snapshot reflecting neither state).
    $self->_wait_snap_status( $snap_id, 'PAIR', budget => $self->_restore_timeout )
        or $self->_err( 'timeout',
            "restore of '$snap_id' did not reach PAIR within the restore budget; NOT "
            . "splitting (the P-VOL may still be receiving the reverse copy)" );

    eval {
        $self->_call( sub { $self->{rest}->split_snapshot($snap_id) } );
        $self->_wait_snap_status( $snap_id, 'PSUS' )
            or warn "FCLU Hitachi: re-split of '$snap_id' did not settle to PSUS in time\n";
    };
    warn "FCLU Hitachi: re-split after restore warning ($snap_id): $@" if $@;

    return 1;
}

sub list_snapshots {
    my ($self, $backend_id) = @_;
    my $snaps = $self->_call( sub { $self->{rest}->list_snapshots( pvol_ldev_id => $backend_id ) } );
    return [ map { $self->_normalize_snap( $_, $backend_id ) } @$snaps ];
}

my $_cg_seq = 0;   # per-process disambiguator for derived CG group names
sub create_cg_snapshot {
    my ($self, $backend_ids, %args) = @_;
    $self->_err( 'invalid', 'create_cg_snapshot needs an arrayref of backend_ids' )
        unless ref $backend_ids eq 'ARRAY' && @$backend_ids;

    # Crash-consistent CG snapshot (the OpenStack HBSD recipe): create EVERY pair under
    # ONE snapshot group with isConsistencyGroup set and autoSplit OFF, let them all
    # reach PAIR, then split the WHOLE group in a single action so every S-VOL freezes at
    # the SAME instant. The old code looped one autoSplit pair per LU — each split fired
    # at a different moment, so cg_snapshot was advertised but the S-VOLs were NOT mutually
    # crash-consistent. A caller-supplied name is honoured (tests); otherwise derive a
    # UNIQUE one (the static 'pve_cg' collided across concurrent CGs). ≤29 chars.
    # Unique group name (unless the caller pins one): first P-VOL hex + a `_` separator +
    # time and a per-process counter, so two CGs over the same P-VOL within one wall-clock
    # second still get distinct names. ≤29 chars.
    my $group = $args{snapshot_group};
    if ( !defined $group ) {
        $_cg_seq = ( $_cg_seq + 1 ) & 0xffff;
        $group = substr( sprintf( 'pveC%x_%x%x', $backend_ids->[0], time(), $_cg_seq ), 0, 29 );
    }

    my @pairs;
    my $ok = eval {
        # 1. Create all pairs unsplit under the shared consistency group.
        for my $bid (@$backend_ids) {
            push @pairs, [ $bid, $self->_create_pair( $bid,
                snapshot_group => $group, is_consistency_group => 1, auto_split => 0 ) ];
        }
        # 2. Every pair must reach PAIR (fully paired) before the group split.
        for my $p (@pairs) {
            $self->_wait_snap_status( $p->[1]{snapshotId}, 'PAIR' )
                or $self->_err( 'timeout',
                    "CG snapshot pair '$p->[1]{snapshotId}' did not reach PAIR before the group split" );
        }
        # 3. One atomic split of the whole group → all S-VOLs suspend together (PSUS).
        $self->_call( sub { $self->{rest}->split_snapshotgroup($group) } );
        1;
    };
    if ( !$ok ) {
        my $err = $@;
        # Best-effort teardown so a partial CG (pairs created but not consistently split)
        # does not leak S-VOLs / pool space on the shared array.
        for my $p (@pairs) {
            eval { $self->{rest}->delete_snapshot( $p->[1]{snapshotId} ) };
            warn "FCLU Hitachi: CG snapshot rollback: releasing pair '$p->[1]{snapshotId}' failed: $@"
                if $@;
        }
        die ref $err ? $err : "create_cg_snapshot failed: $err";
    }

    return [ map { $self->_normalize_snap( $_->[1], $_->[0] ) } @pairs ];
}

sub set_lu_qos {
    my ($self, $backend_id, $qos) = @_;
    $self->_err( 'invalid', 'qos must be a non-empty hashref' )
        unless ref $qos eq 'HASH' && %$qos;
    $self->_call( sub { $self->{rest}->set_ldev_qos( $backend_id, %$qos ) } );
    return 1;
}

sub get_lu_qos {
    my ($self, $backend_id) = @_;
    return $self->_call( sub { $self->{rest}->get_ldev_qos($backend_id) } );
}

# Reclaim zero-filled pages of a DP volume (thin-pool space recovery). Off-contract
# vendor hook (Hitachi discard-zero-page), driven by the plugin's discard_zero_page
# option via _after_deactivate. Best-effort: the caller eval-wraps it.
sub reclaim_zero_pages {
    my ($self, $backend_id) = @_;
    $self->_call( sub { $self->{rest}->reclaim_zero_pages($backend_id) } );
    return 1;
}

# Allocate an S-VOL ldev sized to $parent (exact block count) and return its id.
sub _alloc_svol {
    my ($self, $parent_ldev, %args) = @_;
    my $blocks = $parent_ldev->{blockCapacity} // $parent_ldev->{numOfBlocks};
    $self->_err( 'internal', 'parent ldev has no block capacity' ) unless defined $blocks;

    my $res = $self->_call( sub {
        $self->{rest}->create_ldev(
            pool_id        => ( $args{pool_ref} // $self->{pool_id} ),
            block_capacity => $blocks,
            ( defined $args{requested_id} ? ( ldev_id => $args{requested_id} ) : () ),
        );
    } );
    return defined $args{requested_id} ? "$args{requested_id}" : "$res->{resourceId}";
}

# Persistent CoW child — the PVE clone_image primitive (§6). Allocate a DP S-VOL and
# bind it to the parent via a single autoSplit Thin Image pair creation.
#
# REAL-ARRAY FLOW (verified live on the E590H, 0 used blocks on the S-VOL + CoW reads):
# create the S-VOL as a DP volume, then create the pair WITH svolLdevId + canCascade +
# isDataReductionForceCopy — the array binds the S-VOL at creation with NEITHER volume
# mapped. This is the OpenStack HBSD recipe. It SUPERSEDES the old 4-step #24 workaround
# (poolId-1 v-vol → data-only pair → map → assign_snapshot_volume): a plain svolLdevId
# WAS rejected ("S-VOL does not have LU paths"), but the two extra flags remove that
# constraint. host_ctx is accepted for §2 back-compat but NO LONGER used.
sub create_linked_clone {
    my ($self, $backend_id, %args) = @_;

    my $src = $self->_call( sub { $self->{rest}->get_ldev($backend_id) } );
    $self->_err( 'not_found', "no such ldev '$backend_id'" )
        unless $self->_is_defined_ldev($src);
    my $blocks = $src->{blockCapacity} // $src->{numOfBlocks};
    $self->_err( 'internal', 'source ldev has no block capacity' ) unless defined $blocks;

    # Space-efficient copy-on-write clone via a SINGLE Thin Image pair creation (the
    # OpenStack HBSD recipe, verified live on the E590H: 0 used blocks on the S-VOL,
    # CoW reads of the P-VOL, both volumes unmapped). Create the S-VOL as a DP volume
    # (poolId = the DP pool), then create the autoSplit pair WITH svolLdevId +
    # canCascade + isDataReductionForceCopy — the array binds the S-VOL at creation
    # with NEITHER volume needing LU paths. This SUPERSEDES the old 4-step #24
    # workaround (poolId-1 v-vol → data-only pair → map S-VOL → assign_snapshot_volume),
    # which existed only because a plain svolLdevId was rejected ("S-VOL does not have
    # LU paths"); the two extra flags remove that constraint. No host context needed —
    # host_ctx is accepted for §2 back-compat but ignored. (`isClone` is never set;
    # that would full-copy then auto-delete the pair.)

    # 1. S-VOL as a DP volume sized to the P-VOL (explicit id when requested).
    my $svol_id;
    if ( defined $args{requested_id} ) {
        $svol_id = "$args{requested_id}";
        $self->_call( sub {
            $self->{rest}->create_ldev( pool_id => $self->{pool_id}, block_capacity => $blocks, ldev_id => int($svol_id) );
        } );
    } else {
        my $res = $self->_call( sub { $self->{rest}->create_ldev( pool_id => $self->{pool_id}, block_capacity => $blocks ) } );
        $svol_id = "$res->{resourceId}";
    }

    my $group   = "pve_lc_$svol_id";   # unique per clone → find this exact pair
    my $pair_id = undef;
    eval {
        # 2. Create the autoSplit Thin Image pair binding pvol -> svol in ONE step.
        $self->_call( sub {
            $self->{rest}->create_snapshot(
                pvol_ldev_id                 => $backend_id,
                svol_ldev_id                 => $svol_id,
                snap_pool_id                 => $self->{snap_pool_id},
                snapshot_group               => $group,
                auto_split                   => 1,
                can_cascade                  => 1,
                is_data_reduction_force_copy => 1,
            );
        } );
        $pair_id = $self->_find_pair_id( $backend_id, $group );
        $self->_err( 'internal', "linked-clone pair '$group' not found after creation" )
            unless defined $pair_id;
    };
    if ( my $err = $@ ) {
        # Best-effort rollback so no S-VOL/pair is orphaned on the shared pool: release
        # the pair (frees snapshot data + unbinds the S-VOL) before deleting the S-VOL
        # LDEV (#23). Each step WARNS on failure — a silent leak on shared production
        # storage is the hardest to detect.
        $pair_id //= eval { $self->_find_pair_id( $backend_id, $group ) };
        if ( defined $pair_id ) {
            my $released = eval { $self->{rest}->delete_snapshot($pair_id); 1 };
            warn "FCLU Hitachi: linked-clone rollback: releasing pair '$pair_id' failed: $@"
                if !$released;
            # Wait for the pair to fully dissolve before deleting the S-VOL, else the
            # delete races the SMPP state and leaks the S-VOL on the shared pool (#3).
            # Only when the delete SUCCEEDED — else the pair never 404s and the poll would
            # burn its full budget inside this rollback path.
            eval { $self->wait_pair_released($pair_id) } if $released;
        }
        eval { $self->{rest}->delete_ldev( int($svol_id) ) };
        warn "FCLU Hitachi: linked-clone rollback: deleting S-VOL '$svol_id' failed"
            . " — LEAKED on the shared pool: $@" if $@;
        die ref $err ? $err : "create_linked_clone failed: $err";
    }

    return $svol_id;
}

# Find the Thin Image pair id (snapshotId = "pvolLdevId,muNumber") on $pvol whose
# snapshot group is exactly $group, or undef.
sub _find_pair_id {
    my ($self, $pvol, $group) = @_;
    my $snaps = $self->_call( sub { $self->{rest}->list_snapshots( pvol_ldev_id => $pvol ) } );
    my ($pair) = grep { ( $_->{snapshotGroupName} // '' ) eq $group } @$snaps;
    return $pair ? $pair->{snapshotId} : undef;
}

# Full (non-CoW) copy via clone_snapshot_to_ldev (isClone). Out-of-band / fclu-CLI
# offload (§6), NOT wired to qm clone --full.
sub create_full_clone {
    my ($self, $backend_id, %args) = @_;
    my $src = $self->_call( sub { $self->{rest}->get_ldev($backend_id) } );
    $self->_err( 'not_found', "no such ldev '$backend_id'" )
        unless $self->_is_defined_ldev($src);

    my $svol_id = $self->_alloc_svol( $src, %args );
    my $group   = $args{snapshot_group} // 'pve_clone';
    $self->_call( sub {
        $self->{rest}->clone_snapshot_to_ldev(
            pvol_ldev_id   => $backend_id,
            svol_ldev_id   => $svol_id,
            snap_pool_id   => $self->{snap_pool_id},
            snapshot_group => $group,
        );
    } );
    # N7: the isClone copy runs ASYNC after pair creation; wait for it to finish (the pair
    # auto-deletes, leaving the S-VOL independent) and surface a PSUE copy failure — so a
    # caller cannot use or delete the source before the copy is complete, nor mistake a
    # failed copy for a good clone. Best-effort on timeout (warn; copy may still run). On a
    # PSUE failure the S-VOL LDEV we just allocated is orphaned — best-effort delete it so a
    # failed clone does not leak on the shared pool, then rethrow.
    my $ok = eval { $self->_wait_clone_done( $backend_id, $group, $svol_id ) };
    if ( my $err = $@ ) {
        eval { $self->{rest}->delete_ldev( int($svol_id) ) };
        warn "FCLU Hitachi: full-clone rollback: deleting failed S-VOL '$svol_id' failed"
            . " — LEAKED on the shared pool: $@" if $@;
        die ref $err ? $err : "create_full_clone failed: $err";
    }
    warn "FCLU Hitachi: full clone to '$svol_id' did not confirm completion in time; "
        . "the copy may still be running\n" unless $ok;
    return $svol_id;
}

# N7: poll the isClone pair on $pvol under $group until the copy completes. A full clone
# pair AUTO-DELETES on completion (S-VOL becomes independent), so "pair gone" (or SMPL) =
# done; PSUE = copy failed (fatal). interval<=0 probes once (test fast-path). Returns 1 on
# completion, 0 on timeout.
sub _wait_clone_done {
    my ($self, $pvol, $group, $svol) = @_;
    my $budget   = $self->profile->{op_timeout_s} || 600;
    my $interval = defined $self->{_snap_poll_interval} ? $self->{_snap_poll_interval} : 2;
    my $elapsed  = 0;
    while (1) {
        my $snaps = eval { $self->_call( sub { $self->{rest}->list_snapshots( pvol_ldev_id => $pvol ) } ) } // [];
        my ($pair) = grep { ( $_->{snapshotGroupName} // '' ) eq $group } @$snaps;
        my $st = $pair ? ( $pair->{status} // '' ) : '';
        $self->_err( 'internal', "full clone to S-VOL '$svol' failed (pair status PSUE)" )
            if $st eq 'PSUE';
        return 1 if !$pair || $st eq 'SMPL';   # copy done, pair auto-split/gone
        last if $interval <= 0 || $elapsed >= $budget;
        sleep($interval);
        $elapsed += $interval;
    }
    return 0;
}

# Dedicated reverse-copy budget (N2): a restore can far outlast the generic op timeout.
sub _restore_timeout {
    my ($self) = @_;
    return $self->profile->{restore_timeout_s} || 24 * 3600;
}

# Bounded poll for a snapshot pair to reach $want status. interval<=0 probes once
# (the test fast-path); returns 1 on convergence, 0 on timeout (caller warns). A caller
# may override the deadline with budget => <seconds> (e.g. the restore reverse-copy).
sub _wait_snap_status {
    my ($self, $snap_id, $want, %opts) = @_;
    my $budget   = $opts{budget} // ( $self->profile->{op_timeout_s} || 600 );
    my $interval = defined $self->{_snap_poll_interval} ? $self->{_snap_poll_interval} : 2;
    my $elapsed  = 0;
    while (1) {
        my $s = eval { $self->{rest}->get_snapshot($snap_id) };
        return 1 if ref $s eq 'HASH' && ( $s->{status} // '' ) eq $want;
        last if $interval <= 0 || $elapsed >= $budget;
        sleep($interval);
        $elapsed += $interval;
    }
    return 0;
}

# #3 SMPP guard: a snapshot-pair DELETE job can return while the array still holds the
# pair in a transient deleting state (SMPP). Deleting the S-VOL LDEV then races that and
# is rejected, leaking the S-VOL on a shared pool. Poll until the pair object is gone
# (get_snapshot 404s) before deleting the S-VOL. Bounded; returns 1 when gone, 0 on
# timeout (caller proceeds best-effort). interval<=0 probes once (test fast-path).
sub wait_pair_released {
    my ($self, $snap_id) = @_;
    my $budget   = $self->profile->{op_timeout_s} || 600;
    my $interval = defined $self->{_snap_poll_interval} ? $self->{_snap_poll_interval} : 2;
    my $elapsed  = 0;
    while (1) {
        my $present = eval { $self->_call( sub { $self->{rest}->get_snapshot($snap_id) } ); 1 };
        return 1 if !$present && $self->_is_not_found($@);
        last if $interval <= 0 || $elapsed >= $budget;
        sleep($interval);
        $elapsed += $interval;
    }
    return 0;
}

# ── Host access (§2) ──
#
# Migrated from the reference plugin's _ensure_host_groups / _map_lun_to_local /
# _unmap_lun_from_local — Hitachi uses one Host Group named PVE_<hostname> per
# configured FC port (WWNs + host-mode + HMO). The node's WWNs and hostname now
# arrive in %host_ctx (the core no longer reaches into Multipath); the array ports
# and host-mode knobs are driver config. Fatal RestClient failures translate to
# FCLU::Error via _call; the additive reconcile steps stay best-effort (warn), as
# in the reference, so a stray HMO/WWN hiccup never blocks activation.

sub ensure_host_access {
    my ($self, %ctx) = @_;
    my $hostname = $self->_check_host_ctx(%ctx);
    my $wwns     = $ctx{initiators};
    my $hg_name  = $self->_hg_name($hostname);
    my $access_ref;   # the REAL resolved name (canonical, or an adopted legacy group)
    my $any_access = 0;   # #4: did THIS node resolve a usable group on ANY port?

    my @hmo = @{ $self->{host_mode_options} };
    push @hmo, 91 if $self->{skip_unmap_io_check} && !grep { $_ == 91 } @hmo;

    for my $port ( @{ $self->{array_ports} } ) {
        # Idempotent: reuse an existing group (by our name, else by any of our
        # WWNs); only create when truly absent, then re-look-up for the
        # array-assigned hostGroupNumber.
        my $hg = $self->_call( sub { $self->{rest}->find_host_group_by_name( $port, $hg_name ) } );
        # Truncation-tolerant, WWN-validated fallback (#2): matches an existing group
        # whose >16-char name the array truncated in the list view, without the
        # O(host-groups) WWN scan on the common path.
        $hg = $self->_find_node_hg( $port, $wwns, $hg_name ) if !$hg;
        my $created = 0;   # #4: did WE just create this group (→ atomic-with-WWNs)?
        if ( !$hg ) {
            $self->_call( sub {
                $self->{rest}->create_host_group(
                    port_id => $port, host_group_name => $hg_name,
                    host_mode => $self->{host_mode}, host_mode_options => \@hmo );
            } );
            $hg = $self->_call( sub { $self->{rest}->find_host_group_by_name( $port, $hg_name ) } );
            $self->_err( 'internal', "host group '$hg_name' not found on $port after creation" )
                unless $hg;
            $created = 1;
        }
        my $hg_num = $hg->{hostGroupNumber};

        # Reconcile host-mode options additively (best-effort) — only ADD missing
        # options, never remove out-of-band ones; needed for groups predating an
        # HMO change so UNMAP/discard gets enabled.
        if (@hmo) {
            eval {
                my $info    = $self->{rest}->get_host_group("$port,$hg_num");
                my @current = @{ $info->{hostModeOptions} || [] };
                my %have    = map { $_ => 1 } @current;
                if ( grep { !$have{$_} } @hmo ) {
                    my @union = sort { $a <=> $b } keys %{ { map { $_ => 1 } ( @current, @hmo ) } };
                    $self->{rest}->set_host_group_mode(
                        host_group_id => "$port,$hg_num",
                        host_mode => $self->{host_mode}, host_mode_options => \@union );
                }
            };
            warn "FCLU Hitachi: HMO reconcile warning ($port,$hg_num): $@" if $@;
        }

        # Read current membership FRESH (never cached). A read FAILURE here must NOT be
        # treated as "empty" — that would bypass the foreign-WWN guard below and let us
        # add this node's WWN INTO a possibly-foreign group (isolation pollution the
        # pre-map gate cannot undo). Classify a transient read as array_busy (retryable),
        # exactly like the pre-map gate _assert_hg_ownership.
        my $existing = eval {
            $self->{rest}->list_host_wwns( port_id => $port, host_group_number => $hg_num );
        };
        $self->_err( 'array_busy',
            "host-wwn read for $port (#$hg_num) did not return; refusing to reconcile an "
            . "unverified group" )
            if $@ || ref $existing ne 'ARRAY';
        my %present = map { lc( $_->{hostWwn} // '' ) => 1 } @$existing;
        delete $present{''};   # ignore a malformed/empty hostWwn (no spurious "foreign" key)

        # SAFETY (multi-cluster shared pool): refuse to add THIS node's WWNs to a host
        # group that already holds FOREIGN initiators. On a shared array two clusters can
        # collide on <prefix>_<hostname> (same prefix AND hostname), or a group can be
        # mis-created; silently merging would expose this cluster's LUNs to the foreign
        # node (concurrent-write corruption). Fail LOUD instead. A group holding only our
        # own WWNs — normal re-bring-up, or a legacy PVE_<hostname> group adopted by WWN —
        # passes. Relies on host_context listing ALL of this node's PRESENT initiators, so a
        # stale WWN left by a REPLACED/REMOVED HBA on this node also trips it (still safe:
        # fail-loud, remedy = delete the stale WWN from the host group).
        my %ours = map { lc($_) => 1 } @$wwns;
        my @foreign = sort grep { !$ours{$_} } keys %present;
        $self->_err( 'conflict',
            "host group '$hg->{hostGroupName}' on $port (#$hg_num) already contains initiators "
            . "not owned by node '$hostname' (foreign WWN(s): @foreign); refusing to add this "
            . "node's WWNs. Likely a cross-cluster host-group collision on a shared pool — give "
            . "each cluster a distinct host_group_prefix + a disjoint ldev_range (or an array "
            . "Resource Group). If instead an HBA on THIS node was replaced/removed, delete the "
            . "stale WWN from the host group." )
            if @foreign;

        # Register any of our WWNs not already present (best-effort, idempotent).
        my $added = 0;
        for my $wwn (@$wwns) {
            next if $present{ lc $wwn };
            if ( eval {
                $self->{rest}->add_wwn_to_host_group(
                    port_id => $port, host_group_number => $hg_num, wwn => $wwn );
                1;
            } ) {
                $added++;
            } else {
                warn "FCLU Hitachi: WWN add warning ($port $wwn): $@";
            }
        }

        # #4 Atomic create: a group we JUST created that registered NONE of this node's
        # initiators would still be a valid map target — publish_lu would map LUNs into a
        # group the host cannot see, and it dangles empty on the shared array. That means
        # the node is not zoned to THIS port (or every add failed): roll the empty group
        # back (HBSD's NO_HBA_WWN_ADDED) and treat this port as no-access — but do NOT
        # abort, since other ports may be validly zoned (asymmetric fabric). We fail loud
        # only if NO port yields a path (after the loop). EXISTING groups stay additive/
        # best-effort (a partial add on re-bring-up only warns — %present holds our WWNs).
        if ( $created && !$added && !%present ) {
            eval { $self->{rest}->delete_host_group("$port,$hg_num") };
            warn "FCLU Hitachi: host group '$hg_name' on $port registered none of node "
                . "'$hostname' WWNs (@$wwns) — rolled back the empty group (node likely not "
                . "zoned to $port).\n";
            next;
        }

        # This port resolved a usable group — the canonical <prefix>_<host> we just
        # populated, a pre-existing group, or a legacy PVE_<host> adopted by WWN.
        $access_ref //= $hg->{hostGroupName};
        $any_access = 1;
    }

    # Fail loud only when the node registered NO path on ANY configured port — a real
    # zoning / HBA-login misconfig (every freshly-created group came up empty + was rolled
    # back). A subset of working ports (asymmetric zoning) is fine and proceeds.
    $self->_err( 'internal',
        "node '$hostname' registered none of its WWNs (@$wwns) on ANY configured array port "
        . "(@{ $self->{array_ports} }) — check FC zoning and HBA fabric login." )
        unless $any_access;

    return $access_ref // $hg_name;
}

# Host group name for this node, namespaced by the (per-cluster) prefix so two PVE
# clusters sharing an array pool do not collide on the same hostname. Default prefix
# 'PVE' preserves the historical PVE_<hostname> name for a single cluster.
sub _hg_name {
    my ($self, $hostname) = @_;
    return ( $self->{host_group_prefix} // 'PVE' ) . "_$hostname";
}

# N8: map a LUN idempotently + transient-tolerantly. On a shared array two concurrent
# publishes of the SAME ldev into one host group race (both see an empty list_luns, both
# call map_lun) — the loser gets "LU path already defined"; that path EXISTS, so treat it
# as success. And the array transiently rejects a map during an LU-path state transition
# (array_busy) — bounded retry, mirroring the snapshot-pair poll discipline. Test knobs:
# _lun_op_tries / _lun_op_delay.
sub _map_lun_settled {
    my ($self, $port, $hg_num, $backend_id) = @_;
    my $tries = $self->{_lun_op_tries} // 12;
    my $delay = defined $self->{_lun_op_delay} ? $self->{_lun_op_delay} : 5;
    for my $i ( 1 .. $tries ) {
        return 1 if eval {
            $self->{rest}->map_lun(
                port_id => $port, host_group_number => $hg_num, ldev_id => $backend_id );
            1;
        };
        my $err = $self->_translate_rest_error($@);
        return 1 if $err->code eq 'already_exists';   # path already defined = success
        die $err unless $err->code eq 'array_busy' && $i < $tries;
        sleep($delay);
    }
    return 1;
}

# N8: unmap a LUN path with the same bounded array_busy retry (an LU executing host I/O
# transiently rejects the unmap). not_found is idempotent success.
sub _unmap_lun_settled {
    my ($self, $lun_id) = @_;
    my $tries = $self->{_lun_op_tries} // 12;
    my $delay = defined $self->{_lun_op_delay} ? $self->{_lun_op_delay} : 5;
    for my $i ( 1 .. $tries ) {
        return 1 if eval { $self->{rest}->unmap_lun($lun_id); 1 };
        my $err = $self->_translate_rest_error($@);
        return 1 if $err->code eq 'not_found';        # already gone = success
        die $err unless $err->code eq 'array_busy' && $i < $tries;
        sleep($delay);
    }
    return 1;
}

# N12: reap THIS node's host groups that are now EMPTY (hold no LUN paths), on every
# configured port — "unmanage host". A decommissioned/renamed node otherwise leaves its
# <prefix>_<host> groups + initiator WWNs on the array forever, slowly exhausting per-port
# host-group slots on a shared pool and leaving stale WWNs that trip the foreign-WWN guard
# if the hostname is later reused on another cluster. WWN-ownership-GATED: only a group we
# resolve as OURS (holds our WWNs, no foreign — via _resolve_owned_hg) AND holding zero
# LUNs is deleted; a live or foreign group is never touched. Returns the reaped [port,hgnum].
sub reclaim_empty_host_groups {
    my ($self, %ctx) = @_;
    my $hostname = $self->_check_host_ctx(%ctx);
    my $wwns     = $ctx{initiators};
    my $hg_name  = $self->_hg_name($hostname);
    my @reaped;
    for my $port ( @{ $self->{array_ports} } ) {
        # Resolve OUR group + prove ownership; a conflict (foreign WWNs) or absence => skip.
        my $hg = eval { $self->_resolve_owned_hg( $port, $hg_name, $wwns ) };
        next if $@ || !$hg;
        my $hg_num = $hg->{hostGroupNumber};
        # Only reap when the group holds NO LUN paths (unused by this or any node). Fail
        # SAFE: an error OR any unexpected (non-arrayref) shape means "do not reap" — never
        # read an ambiguous result as "empty" and delete a possibly-in-use group.
        my $luns = eval { $self->{rest}->list_luns( port_id => $port, host_group_number => $hg_num ) };
        next if $@ || ref $luns ne 'ARRAY' || @$luns;
        if ( eval { $self->{rest}->delete_host_group("$port,$hg_num"); 1 } ) {
            push @reaped, "$port,$hg_num";
        } else {
            warn "FCLU Hitachi: reclaim of empty host group ($port,#$hg_num) failed: $@";
        }
    }
    return \@reaped;
}

sub publish_lu {
    my ($self, $backend_id, %ctx) = @_;
    my $hostname = $self->_check_host_ctx(%ctx);

    # ensure_host_access is safe to call on every publish (§12.2) — the core holds no
    # host-object state, the driver reconciles. It returns the node's RESOLVED host
    # group name (canonical or an adopted legacy name); reuse it to resolve each port's
    # group by NAME (a cheap, cached host-group list) instead of re-scanning every
    # group's WWNs per port. find_host_group_by_wwn is O(host groups) and the CM REST
    # /host-wwns requires a hostGroupNumber (can't be batched), so on a busy port that
    # per-group scan is the dominant clone host-mapping cost — this was THE qm-clone
    # REST amplifier. _find_node_hg stays as a fallback if a group name ever diverges
    # per port.
    my $hg_name = $self->ensure_host_access(%ctx);
    my $wwns = $ctx{initiators};

    my ( $lun, $access_ref );
    for my $port ( @{ $self->{array_ports} } ) {
        # #1 SAFETY GATE: resolve the node's group AND prove ownership (fresh WWN read)
        # before mapping — never map into a foreign/number-reused group.
        my $hg = $self->_resolve_owned_hg( $port, $hg_name, $wwns );
        next unless $hg;
        $access_ref //= $hg->{hostGroupName};   # the real group name (may be an adopted legacy name)
        my $hg_num = $hg->{hostGroupNumber};

        my $luns = $self->_call( sub {
            $self->{rest}->list_luns(
                port_id => $port, host_group_number => $hg_num, ldev_id => $backend_id );
        } );
        if ( !@$luns ) {
            $self->_map_lun_settled( $port, $hg_num, $backend_id );   # N8: idempotent + retry
            $luns = $self->_call( sub {
                $self->{rest}->list_luns(
                    port_id => $port, host_group_number => $hg_num, ldev_id => $backend_id );
            } );
        }
        $lun //= $luns->[0]{lun} if @$luns && defined $luns->[0]{lun};
    }

    return { hostname => $hostname, access_ref => $access_ref // $self->_hg_name($hostname), lun => $lun };
}

sub unpublish_lu {
    my ($self, $backend_id, %ctx) = @_;
    my $hostname = $self->_check_host_ctx(%ctx);
    my $wwns = $ctx{initiators};
    my $hg_name = $self->_hg_name($hostname);

    # Remove ONLY this node's mapping (the host group matched by the node's WWNs);
    # other nodes' host groups are left intact (§12.2 live-migration rule).
    my ( $attempted, $failed, $last_err ) = ( 0, 0, undef );
    for my $port ( @{ $self->{array_ports} } ) {
        # #1 SAFETY GATE, symmetric with publish_lu: resolve the node's group AND prove
        # ownership with a fresh read — INCLUDING the invalidate-and-re-resolve-once on a
        # stale-cache number alias (so a recycled number doesn't leave the node's real
        # path mapped). A CONFIRMED foreign group is SKIPPED (our paths aren't there). A
        # transient read counts as a failed teardown attempt so an all-port failure
        # surfaces (retryable) instead of a false idempotent success.
        my $hg = eval { $self->_resolve_owned_hg( $port, $hg_name, $wwns ) };
        if ( my $e = $@ ) {
            if ( ref $e && eval { $e->isa('PVE::Storage::FCLU::Error') } && $e->code eq 'conflict' ) {
                warn "FCLU Hitachi: unpublish skipping unowned group on $port: $e";
                next;
            }
            $attempted++; $failed++; $last_err = $e;
            warn "FCLU Hitachi: unpublish ownership check unavailable on $port: $e";
            next;
        }
        next unless $hg;
        my $hg_num = $hg->{hostGroupNumber};

        my $luns = $self->_call( sub {
            $self->{rest}->list_luns(
                port_id => $port, host_group_number => $hg_num,
                ldev_id => $backend_id );
        } );
        for my $l (@$luns) {
            $attempted++;
            unless ( eval { $self->_unmap_lun_settled( $l->{lunId} ); 1 } ) {   # N8: retry+idempotent
                $failed++;
                $last_err = $@;
                warn "FCLU Hitachi: unmap warning (lun $l->{lunId}): $@";
            }
        }
    }

    # If there were paths to remove and EVERY unmap failed, teardown made no
    # progress — surface the (classified) cause so the core can retry/compensate
    # (§12.4) instead of falsely reporting success. A partial failure stays a
    # warn-only success, backstopped by list_lu_mappings at delete time.
    die $self->_translate_rest_error($last_err)
        if $attempted > 0 && $failed == $attempted;

    return 1;   # idempotent: no group/no luns, or progress made => success
}

# AUTHORITATIVE per-LU mapping list (§2/§12.3): read from get_ldev->{ports}, NOT a
# host-group scan. Each port entry resolves to its host group name (carried on the
# entry or fetched), and entries are folded into one Mapping descriptor per node.
# unpublish_lu_all($backend_id) — remove the LU's mapping from EVERY host group it is
# currently mapped to (all nodes), not just this node's. free_image calls this before
# delete_lu to reap a leftover mapping from a crashed live-migration on another node:
# this node's WWN-scoped unpublish_lu cannot reach a remote node's host group, and the
# array refuses to delete an LDEV that still has LU paths, so the LU would leak.
# Idempotent (unknown/unmapped LU => success); best-effort per path (a partial failure
# is a warn, a total failure surfaces the classified cause, mirroring unpublish_lu).
# NOT a §2 contract method — an optional vendor teardown hook (cf. next_free_backend_id);
# the core invokes it via can().
sub unpublish_lu_all {
    my ($self, $backend_id) = @_;
    my $ldev = $self->_call( sub { $self->{rest}->get_ldev($backend_id) } );
    return 1 unless $self->_is_defined_ldev($ldev);

    my ( $attempted, $failed, $last_err ) = ( 0, 0, undef );
    for my $p ( @{ $ldev->{ports} || [] } ) {
        my ( $pid, $hgn ) = ( $p->{portId}, $p->{hostGroupNumber} );
        next unless defined $pid && defined $hgn;
        # get_ldev's ports carry the LUN number but not the lunId path resource id
        # that unmap_lun needs, so re-query this port+hg for this ldev to resolve it.
        my $luns = $self->_call( sub {
            $self->{rest}->list_luns(
                port_id => $pid, host_group_number => $hgn, ldev_id => $backend_id );
        } );
        for my $l (@$luns) {
            $attempted++;
            unless ( eval { $self->{rest}->unmap_lun( $l->{lunId} ); 1 } ) {
                $failed++;
                $last_err = $@;
                warn "FCLU Hitachi: cluster-wide unmap warning (lun $l->{lunId}): $@";
            }
        }
    }

    die $self->_translate_rest_error($last_err)
        if $attempted > 0 && $failed == $attempted;

    return 1;
}

sub list_lu_mappings {
    my ($self, $backend_id) = @_;
    my $ldev = $self->_call( sub { $self->{rest}->get_ldev($backend_id) } );
    $self->_err( 'not_found', "no such ldev '$backend_id'" )
        unless $self->_is_defined_ldev($ldev);

    my $ports = $ldev->{ports} || [];
    my %by_path;
    for my $p (@$ports) {
        my ( $pid, $hgn ) = ( $p->{portId}, $p->{hostGroupNumber} );
        next unless defined $pid && defined $hgn;
        my $key = "$pid,$hgn";   # the array's UNIQUE per-port host-group id

        my $hgname = $p->{hostGroupName};
        if ( !defined $hgname ) {
            my $info = eval { $self->{rest}->get_host_group($key) };
            $hgname = $info->{hostGroupName} if ref $info eq 'HASH';
        }
        $hgname //= $key;

        my $prefix = $self->{host_group_prefix} // 'PVE';
        my ($node) = $hgname =~ /^\Q$prefix\E_(.+)$/;
        ($node) = $hgname =~ /^PVE_(.+)$/ if !defined $node;   # legacy PVE_<host> groups
        $node //= $hgname;   # non-PVE groups: surface the raw group name as the node hint

        # Key by the (port, hostGroupNumber) COMPOSITE, never by hostGroupName: the array
        # TRUNCATES long host group names, so two DIFFERENT nodes whose PVE_<hostname>
        # share a prefix (e.g. dev-mp01-pve-03 / -04, both stored "PVE_dev-mp01-pve") end
        # up with the SAME name. Grouping by name would COLLAPSE them and hide a live
        # mapping — fatal for the sole safe-unmap authority (§2, §10). The composite is
        # unique per array path so nothing is ever dropped; `hostname` is a best-effort
        # hint (unreliable under truncation), while `port`/`host_group` are exact.
        $by_path{$key} //= {
            hostname => $node, access_ref => $hgname, lun => $p->{lun},
            port => $pid, host_group => $hgn,
        };
    }

    return [ map { $by_path{$_} } sort keys %by_path ];
}

# Array target ports for fabric zoning (§14). WWPN resolution needs a /ports REST
# wrap that lands with the Fabric plane; until then we surface the configured port
# ids without fabricating wwpn values.
sub target_ports {
    my ($self, %ctx) = @_;
    return [ map { { port_id => $_ } } @{ $self->{array_ports} } ];
}

# ── Internal helpers ──

# Normalize an arrayref-or-CSV config value to an arrayref of trimmed non-empty
# tokens. A plain function (used in new() before the object exists).
sub _as_list {
    my ($v) = @_;
    return []        unless defined $v;
    return [ @$v ]   if ref $v eq 'ARRAY';
    return [ grep { length } map { s/^\s+|\s+$//gr } split /,/, $v ];
}

sub _check_host_ctx {
    my ($self, %ctx) = @_;
    for my $k (qw(hostname protocol initiators)) {
        $self->_err( 'invalid', "host_ctx missing '$k'" ) unless defined $ctx{$k};
    }
    $self->_err( 'invalid', "unsupported protocol '$ctx{protocol}'" )
        unless $ctx{protocol} eq 'scsi-fc';
    $self->_err( 'invalid', 'host_ctx initiators must be a non-empty arrayref' )
        unless ref $ctx{initiators} eq 'ARRAY' && @{ $ctx{initiators} };
    return $ctx{hostname};
}

# Find the node's host group on $port by any of its WWNs (translated _call).
sub _find_node_hg {
    my ($self, $port, $wwns, $hg_name) = @_;

    # #2 truncation-tolerant fast path: the CM REST list view truncates hostGroupName
    # to 16 chars, so a >16-char canonical name (PVE_<hostname>) never EXACT-matches —
    # which is what forced the O(host-groups) list_host_wwns scan below on every
    # publish/unpublish. Instead pre-filter (over the CACHED host-group list) to groups
    # whose FULL or 16-char-truncated name equals ours, and ADOPT one only if a FRESH
    # read shows it holds one of THIS node's WWNs. WWN membership is the authority; the
    # name is only a pre-filter (safe because #1's _assert_hg_ownership re-proves it
    # before any map). A same-truncation group that is really ANOTHER node's holds none
    # of ours -> we skip it -> clean MISS (caller creates our group), never a false
    # 'conflict'. Cost: O(same-truncation candidates ~= 1) reads instead of O(all HGs).
    if ( defined $hg_name ) {
        my %ours   = map { lc $_ => 1 } grep { length } @$wwns;   # ignore malformed empty tokens
        my $trunc  = substr( $hg_name, 0, 16 );
        my $groups = eval { $self->{rest}->list_host_groups( port_id => $port ) } || [];
        for my $hg (@$groups) {
            my $n = $hg->{hostGroupName};
            next unless defined $n
                && ( $n eq $hg_name || ( length($hg_name) > 16 && $n eq $trunc ) );
            my $present = eval {
                $self->{rest}->list_host_wwns(
                    port_id => $port, host_group_number => $hg->{hostGroupNumber} );
            };
            next unless ref $present eq 'ARRAY';
            return $hg if grep { $ours{ lc( $_->{hostWwn} // '' ) } } @$present;
        }
        # debug(3) diagnostic: the fast path missed — dump the list the cache gave us so
        # we can see whether the node's group is present (and under which name) vs a
        # stale/truncated/partial list response.
        eval {
            $self->{rest}->_debug( 3, "_find_node_hg prefilter MISS on $port"
                . " want='$hg_name' trunc='$trunc' groups=["
                . join( ',', map { ( $_->{hostGroupName} // '?' ) . '#' . ( $_->{hostGroupNumber} // '?' ) } @$groups )
                . "]" );
        };
    }

    # Legacy fallback: the full per-group WWN scan (now rare — reached only when the
    # node's group name shares no prefix with ours, or the cached list read failed).
    for my $wwn (@$wwns) {
        my $hg = $self->_call( sub { $self->{rest}->find_host_group_by_wwn( $port, $wwn ) } );
        return $hg if $hg;
    }
    return undef;
}

# SAFETY GATE (§ multi-cluster): PROVE this node owns ($port,$hg_num) with a FRESH,
# never-cached list_host_wwns read before any map/unmap. A cached or array-reused
# hostGroupNumber can point at a FOREIGN cluster's group (numbers are recycled on
# out-of-band delete), so identity by number/name is only a hint — WWN membership is
# the authorization. Classification is deliberately split (the sharp edge): a
# CONFIRMED foreign WWN fails CLOSED ('conflict', non-retryable); a read that is
# absent/errored — the very shared-array load that also 503s — is 'array_busy'
# (retryable), NOT fail-closed, so a transient glitch never takes a prod volume
# offline. Like the ensure-time guard, this relies on %host_ctx enumerating ALL of
# this node's PRESENT initiator WWNs — a stale WWN from a replaced/removed HBA on this
# node reads as "foreign" (still safe: fail-loud, remedy = delete the stale WWN).
# Dies on violation; returns 1 when ownership holds.
sub _assert_hg_ownership {
    my ($self, $port, $hg_num, $wwns) = @_;

    my $present = eval {
        $self->{rest}->list_host_wwns( port_id => $port, host_group_number => $hg_num );
    };
    $self->_err( 'array_busy',
        "host-wwn read for $port (#$hg_num) did not return; refusing to map on an "
        . "unverified group" )
        if $@ || ref $present ne 'ARRAY';

    my %have = map { lc( $_->{hostWwn} // '' ) => 1 } @$present;
    my %ours = map { lc($_) => 1 } @$wwns;
    my @foreign = sort grep { length && !$ours{$_} } keys %have;

    # CONFIRMED foreign initiator in the group -> fail closed. Same remedy text as the
    # ensure-time guard: distinct host_group_prefix + disjoint ldev_range per cluster,
    # or delete a stale WWN left by a replaced HBA on this node.
    $self->_err( 'conflict',
        "host group on $port (#$hg_num) holds initiators not owned by this node "
        . "(foreign WWN(s): @foreign); refusing to map/unmap. Likely a host-group-number "
        . "reuse or a cross-cluster collision on a shared pool — give each cluster a "
        . "distinct host_group_prefix + a disjoint ldev_range, or delete the stale WWN." )
        if @foreign;

    # Non-empty group holding NONE of ours -> the number was reused for a different
    # (empty-of-ours) group; treat as a conflict, not our target.
    my @missing = grep { !$have{$_} } keys %ours;
    $self->_err( 'conflict',
        "host group on $port (#$hg_num) contains no initiator owned by this node "
        . "(missing: @missing); the host-group number was likely reused — refusing to map/unmap." )
        if @$present && @missing == keys %ours;

    return 1;
}

# Resolve THIS node's host group on $port AND prove ownership (fresh) before it is
# used to map. Returns the validated hg hashref, undef if the node has no group on
# the port, or dies (conflict / array_busy). A CONFIRMED conflict re-resolves once
# against a freshly-fetched host-group list (benign stale-cache number drift) before
# failing closed; a transient array_busy propagates immediately for the core to retry.
sub _resolve_owned_hg {
    my ($self, $port, $hg_name, $wwns) = @_;

    my $hg = $self->_call( sub { $self->{rest}->find_host_group_by_name( $port, $hg_name ) } )
        // $self->_find_node_hg( $port, $wwns, $hg_name );
    return undef unless $hg;

    return $hg if eval { $self->_assert_hg_ownership( $port, $hg->{hostGroupNumber}, $wwns ); 1 };
    my $e = $@;
    die $e unless ref $e && eval { $e->isa('PVE::Storage::FCLU::Error') } && $e->code eq 'conflict';

    # Confirmed conflict: the cached topology list may name-alias a stale number. Drop
    # it, re-resolve fresh once, and re-assert — dies if the group is genuinely foreign.
    $self->{rest}->_invalidate_hg_list_cache($port);
    $hg = $self->_call( sub { $self->{rest}->find_host_group_by_name( $port, $hg_name ) } )
        // $self->_find_node_hg( $port, $wwns, $hg_name );
    die $e unless $hg;
    $self->_assert_hg_ownership( $port, $hg->{hostGroupNumber}, $wwns );
    return $hg;
}

sub _err {
    my ($self, $code, $message) = @_;
    PVE::Storage::FCLU::Error->throw( code => $code, message => "Hitachi: $message" );
}

sub _is_not_found {
    my ($self, $e) = @_;
    return ref $e && eval { $e->isa('PVE::Storage::FCLU::Error') } && $e->code eq 'not_found';
}

# An ldev object the array actually has (a populated slot, not "NOT DEFINED").
sub _is_defined_ldev {
    my ($self, $ldev) = @_;
    return 0 unless ref $ldev eq 'HASH' && defined $ldev->{ldevId};
    return 0 if ( $ldev->{emulationType} // '' ) eq 'NOT DEFINED';
    return 1;
}

# get_ldev that returns undef on a not_found error (for the create re-assert).
sub _get_ldev_or_undef {
    my ($self, $backend_id) = @_;
    my $ldev = eval { $self->_call( sub { $self->{rest}->get_ldev($backend_id) } ) };
    if ($@) { return undef if $self->_is_not_found($@); die $@ }
    return $self->_is_defined_ldev($ldev) ? $ldev : undef;
}

# Capacity in bytes: blockCapacity (preferred) or numOfBlocks, * 512.
sub _ldev_bytes {
    my ($self, $ldev) = @_;
    my $blocks = $ldev->{blockCapacity} // $ldev->{numOfBlocks} // 0;
    return $blocks * 512;
}

# Canonical device identity (§12.1) from the array-reported naaId.
sub _ldev_identity {
    my ($self, $ldev) = @_;
    my $naa = $ldev->{naaId};
    if ( defined $naa && length $naa ) {
        # The driver is the single source of truth for identity (§12.1): emit the
        # canonical bare lowercase hex, stripping any page-83 prefix the array
        # reports (naa./0x), rather than leaning on the host connector to re-strip.
        $naa =~ s/^naa\.//i;
        $naa =~ s/^0x//i;
        $naa = lc $naa;
    } else {
        $naa = undef;
    }
    return {
        protocol => 'scsi-fc',
        ids => { naa => $naa, eui => undef, wwid => undef },
    };
}

# §12.1 LU descriptor.
sub _normalize_ldev {
    my ($self, $ldev) = @_;
    my $label = $ldev->{label};
    return {
        backend_id   => "$ldev->{ldevId}",
        size_bytes   => $self->_ldev_bytes($ldev),
        label        => ( defined $label && length $label ) ? $label : undef,
        pool_ref     => defined $ldev->{poolId} ? "$ldev->{poolId}" : undef,
        identity     => $self->_ldev_identity($ldev),
        backend_meta => {},
    };
}

1;
