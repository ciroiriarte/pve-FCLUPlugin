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
my %PLATFORM = (
    vsp_g => {
        family       => 'vsp_g',
        default_port => 23451,           # Ops Center Configuration Manager server
        min_lu_mb    => 48,              # POST /ldevs <= 46 MiB fails the async job
        max_label_len => 32,
        op_timeout_s => 600,
        capabilities => { snapshot => 1, clone => 1, qos => 1, cg_snapshot => 1 },
        quirks       => {},
    },
    vsp_e => {
        family       => 'vsp_e',
        default_port => 443,             # embedded/direct GUM REST (e.g. E590H)
        min_lu_mb    => 48,
        max_label_len => 32,
        op_timeout_s => 600,
        capabilities => { snapshot => 1, clone => 1, qos => 1, cg_snapshot => 1 },
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
        capabilities => { snapshot => 1, clone => 1, qos => 1, cg_snapshot => 1 },
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
        rest     => $opts{rest},           # dependency-injected for tests
    }, $class;

    # Build a real transport unless one was injected (tests inject a mock).
    unless ( $self->{rest} ) {
        my $prof = $self->profile;
        $self->{rest} = PVE::Storage::FCLU::Driver::Hitachi::RestClient->new(
            mgmt_ip    => $opts{mgmt_ip},
            storage_id => $opts{storage_id},
            username   => $opts{username},
            password   => $opts{password},
            port       => $opts{port} // $prof->{default_port},
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
        transfer => { import => 0, migrate_pool => 1 },
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
sub _translate_rest_error {
    my ($self, $err) = @_;

    # Already normalized (e.g. a nested _call) — pass through unchanged.
    return $err if ref $err && eval { $err->isa('PVE::Storage::FCLU::Error') };

    my $msg = "$err";
    $msg =~ s/\s+\z//;

    my $code;
    if ( my ($status) = $msg =~ /->\s*(\d{3})\b/ ) {
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
        elsif ( $msg =~ /not (found|defined)|does not exist|no such/i )     { $code = 'not_found' }
        elsif ( $msg =~ /limit|maximum number|too many/i )                  { $code = 'limit' }
    }

    $code //= 'internal';

    return PVE::Storage::FCLU::Error->new(
        code    => $code,
        message => "Hitachi: $CODE_MESSAGE{$code}",
        vendor  => { raw => $msg },
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
    # used_pool_capacity_missing); fall back to total - availableVolumeCapacity.
    my $used;
    if ( defined $pool->{usedPoolCapacity} ) {
        $used = $pool->{usedPoolCapacity} * MIB;
    } elsif ( defined $pool->{availableVolumeCapacity} ) {
        $used = $total - $pool->{availableVolumeCapacity} * MIB;
    } else {
        $used = 0;
    }
    my $free = $total - $used;

    return ( $total, $free, $used );
}

# ── Internal helpers ──

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
    return {
        protocol => 'scsi-fc',
        ids => {
            naa  => ( defined $naa && length $naa ) ? lc($naa) : undef,
            eui  => undef,
            wwid => undef,
        },
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
