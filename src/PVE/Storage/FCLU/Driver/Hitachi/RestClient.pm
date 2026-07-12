package PVE::Storage::FCLU::Driver::Hitachi::RestClient;

use strict;
use warnings;

use LWP::UserAgent;
use HTTP::Request;
use JSON qw(encode_json decode_json);
use Carp qw(croak);
use Time::HiRes ();

# Default timeouts and retry settings
my $DEFAULT_TIMEOUT     = 30;
my $JOB_POLL_INTERVAL   = 2;
my $JOB_POLL_TIMEOUT    = 300;
# TTL for the per-port host-group LIST cache. Long enough to absorb a clone burst
# (the whole point), short enough that an out-of-band deletion of our own host group
# self-heals within a long-lived pvedaemon instead of persisting until restart.
my $HG_LIST_CACHE_TTL   = 30;
my $MAX_RETRIES         = 3;
my $RETRY_DELAY         = 2;
my $RETRY_MAX_DELAY     = 30;   # hard cap on any single backoff (seconds)

# Backoff before a retry. When the server provides a numeric Retry-After it takes
# precedence and is honored as-is (the server's explicit instruction). Otherwise
# use a linear base (RETRY_DELAY * attempt) plus random jitter — a random fraction
# of RETRY_DELAY — so that many nodes hitting the same array-side fault (e.g. the
# GUM returning 503 under load, with no Retry-After) do not retry in lockstep and
# re-saturate the shared management endpoint (thundering herd, #11). Bounded by
# RETRY_MAX_DELAY. Pure function of (attempt, response) so it is unit-testable.
sub _retry_delay {
    my ($self, $attempt, $res) = @_;

    if ($res) {
        my $retry_after = $res->header('Retry-After');
        return $retry_after + 0
            if defined $retry_after && $retry_after =~ /^\d+$/;
    }

    my $delay = ($RETRY_DELAY * $attempt) + (rand() * $RETRY_DELAY);
    $delay = $RETRY_MAX_DELAY if $delay > $RETRY_MAX_DELAY;
    return $delay;
}

sub new {
    my ($class, %opts) = @_;

    croak "mgmt_ip is required"    unless $opts{mgmt_ip};
    croak "storage_id is required" unless $opts{storage_id};
    croak "username is required"   unless $opts{username};
    croak "password is required"   unless $opts{password};

    # mgmt_ip may be a comma-separated list of per-controller management endpoints
    # (e.g. each VSP controller's GUM). We keep a "current" endpoint and fail over
    # to the next one on a transport-level failure, re-authenticating there. A
    # single IP (or a floating management VIP) is just a one-element list.
    my @endpoints =
        grep { length } map { my $h = $_; $h =~ s/^\s+|\s+$//g; $h } split(/,/, $opts{mgmt_ip});
    croak "mgmt_ip is required" unless @endpoints;

    # Control plane (§10): 'cm' = a fronting Ops Center Configuration Manager server
    # (default port 23451) vs 'embedded' = the array's own GUM REST (443). This ONLY
    # picks the default port — the CM and the embedded GUM speak the SAME
    # Configuration Manager REST API (session-less basic auth + storage-scoped jobs
    # work identically on both), so there is no behavioural fork. `mgmt_port`
    # overrides the default either way.
    my $port = $opts{port}
        || ( ( ($opts{control_plane} // 'embedded') eq 'cm' ) ? 23451 : 443 );

    # TLS verification is opt-in: Configuration Manager ships a self-signed cert by
    # default, so verification is disabled unless the caller explicitly enables it
    # (optionally pinning a CA bundle).
    my %ssl_opts = ( verify_hostname => 0, SSL_verify_mode => 0 );
    if ($opts{tls_verify}) {
        $ssl_opts{verify_hostname} = 1;
        $ssl_opts{SSL_verify_mode} = 0x01;   # SSL_VERIFY_PEER
        $ssl_opts{SSL_ca_file}     = $opts{tls_ca_file} if $opts{tls_ca_file};
    }

    # N5: enable HTTP keep-alive so one TCP+TLS connection is REUSED across a
    # create-then-poll sequence and the per-port host-group/LUN calls in the clone hot
    # path, instead of a fresh handshake per request (TLS handshakes dominate against a
    # slow GUM — GH #17). N10: the socket timeout is configurable via `http_timeout`; LWP
    # applies one timeout to both connect and read, so the default stays the validated 30s
    # (connect-refused is instant regardless; raise it only for an unusually slow GUM whose
    # single GETs — e.g. a large range scan — legitimately run long).
    my $ua = LWP::UserAgent->new(
        timeout    => $opts{http_timeout} || $opts{timeout} || $DEFAULT_TIMEOUT,
        keep_alive => 1,
        ssl_opts   => \%ssl_opts,
    );

    my $self = bless {
        endpoints  => \@endpoints,
        ep_idx     => 0,
        mgmt_ip    => $endpoints[0],   # current active endpoint
        port       => $port,
        storage_id => $opts{storage_id},
        username   => $opts{username},
        password   => $opts{password},
        ua         => $ua,
        token      => undef,
        session_id => undef,
        # Session-less mode: authenticate every request with HTTP basic auth and
        # never create a persistent Configuration Manager session. CM caps
        # concurrent sessions per array; a kept-alive session per worker process
        # across a cluster exhausts that cap (GitHub #26). The array opens and
        # immediately releases a transient session per basic-auth request, so
        # nothing accumulates. login()/logout()/keepalive() become no-ops.
        sessionless => $opts{sessionless} ? 1 : 0,
        # Max seconds to poll an async CM REST job before giving up. Driven by the
        # driver's profile op_timeout_s (default falls back to $JOB_POLL_TIMEOUT) —
        # large Thin Image v-vol operations (e.g. cloning a 64G template disk) can run
        # well past the old hard-coded 300s, so the poll budget must match the
        # profile's declared operation timeout, not a shorter constant.
        job_timeout => $opts{job_timeout} || $JOB_POLL_TIMEOUT,
        # Diagnostic logging verbosity (#33): 0=off, 2=+per-request method/path/
        # status/timing, 3=+bodies (redacted). Never logs auth headers/tokens.
        debug       => $opts{debug} // 0,
    }, $class;

    $self->{base_url} = $self->_build_base_url();

    return $self;
}

sub _build_base_url {
    my ($self) = @_;
    return "https://$self->{mgmt_ip}:$self->{port}"
        . "/ConfigurationManager/v1/objects/storages/$self->{storage_id}";
}

# Advance to the next management endpoint (controller). Returns false when there is
# only one endpoint (nothing to fail over to). The session token is per-controller,
# so it is dropped — the caller must re-authenticate against the new endpoint.
sub _switch_endpoint {
    my ($self) = @_;

    my $n = scalar(@{$self->{endpoints}});
    return 0 if $n < 2;

    $self->{ep_idx}     = ($self->{ep_idx} + 1) % $n;
    $self->{mgmt_ip}    = $self->{endpoints}[$self->{ep_idx}];
    $self->{base_url}   = $self->_build_base_url();
    $self->{token}      = undef;
    $self->{session_id} = undef;

    return 1;
}

# A response LWP synthesized for a connect/timeout/DNS failure (vs. a real HTTP
# status from the controller) is marked "Client-Warning: Internal response".
sub _is_transport_error {
    my ($self, $res) = @_;
    return 0 unless $res;
    return ($res->header('Client-Warning') // '') eq 'Internal response' ? 1 : 0;
}

# N9: is this transport error CONNECT-phase — i.e. the request provably never left the
# client, so a resend cannot double-apply a non-idempotent POST? Only a small allowlist of
# LWP-synthesized connect messages qualify; a READ timeout (the array may already hold the
# request) and anything ambiguous return false, so a POST is NOT resent for those.
sub _is_connect_phase_error {
    my ($self, $res) = @_;
    return 0 unless $res;
    my $m = ( $res->content // '' ) . ' ' . ( $res->message // '' );
    return 0 if $m =~ /read timeout/i;   # response phase — may already be applied
    return $m =~ /can'?t connect
                 | connection\s+refused
                 | no\s+route\s+to\s+host
                 | network\s+is\s+unreachable
                 | name\s+or\s+service\s+not\s+known
                 | temporary\s+failure\s+in\s+name\s+resolution/ix ? 1 : 0;
}

# Rewrite the scheme+authority of an absolute URL to the current endpoint, so a
# request built for a now-failed controller is re-targeted at the survivor.
sub _rewrite_host {
    my ($self, $url) = @_;
    $url =~ s{^https?://[^/]+}{https://$self->{mgmt_ip}:$self->{port}};
    return $url;
}

sub _sessions_url {
    my ($self) = @_;
    return $self->_objects_url('sessions');
}

# ── Session Management ──

sub login {
    my ($self) = @_;

    # Session-less mode holds no session, so there is nothing to create — each
    # request authenticates itself with basic auth (#26). A no-op here keeps the
    # activate_storage / failover call sites unchanged.
    return undef if $self->{sessionless};

    # Session creation is on the critical path for activate_storage/on_add_hook, so
    # it gets the same transient-error handling as _request: retry on rate limits
    # (429) and 5xx, honoring Retry-After. These codes mean the request was not
    # processed, so retrying cannot create duplicate sessions. A transport-level
    # failure (controller unreachable) fails over to the next endpoint and retries
    # there, so login succeeds as long as any controller's GUM is up.
    my $retries  = 0;
    my $tried    = 0;
    my $max_ep   = scalar(@{$self->{endpoints}});
    my $last_err = '';

    while (1) {
        my $req = HTTP::Request->new('POST', $self->_sessions_url());
        $req->header('Content-Type'  => 'application/json');
        $req->header('Accept'        => 'application/json');
        $req->authorization_basic($self->{username}, $self->{password});
        $req->content(encode_json({}));

        my $res = $self->{ua}->request($req);

        if ($res->is_success) {
            my $data = decode_json($res->content);
            $self->{token}      = $data->{token};
            $self->{session_id} = $data->{sessionId};
            return $self->{token};
        }

        $last_err = $res->status_line . " " . ($res->content || '');

        # Controller unreachable → try the next endpoint (bounded by endpoint count).
        if ($self->_is_transport_error($res) && ++$tried < $max_ep && $self->_switch_endpoint()) {
            next;
        }

        my $code = $res->code;
        if (($code == 429 || $code >= 500) && $retries < $MAX_RETRIES) {
            $retries++;
            sleep($self->_retry_delay($retries, $res));
            next;
        }

        last;
    }

    croak "Login failed (endpoints: " . join(',', @{$self->{endpoints}}) . "): $last_err";
}

sub logout {
    my ($self) = @_;
    return unless $self->{session_id};

    my $url = $self->_objects_url("sessions/$self->{session_id}");
    eval {
        $self->_request('DELETE', $url, undef, 1);
    };
    $self->{token}      = undef;
    $self->{session_id} = undef;

    return;
}

sub keepalive {
    my ($self) = @_;
    return unless $self->{session_id};

    my $url = $self->_objects_url("sessions/$self->{session_id}");
    $self->_request('PATCH', $url);
    return 1;
}

# ── LDEV Operations ──

sub create_ldev {
    my ($self, %opts) = @_;

    croak "pool_id is required" unless defined $opts{pool_id};
    croak "size_mb or block_capacity is required"
        unless defined $opts{size_mb} || defined $opts{block_capacity};

    # poolId -1 creates a "virtual volume for Thin Image" (the S-VOL type for a
    # linked clone) rather than a DP volume from a real pool. block_capacity (exact
    # 512-byte block count) is preferred when the LDEV must match another volume's
    # size exactly — e.g. a Thin Image S-VOL must equal its P-VOL's block count;
    # otherwise byteFormatCapacity ("<n>M") is used.
    my $body = { poolId => int($opts{pool_id}) };
    if (defined $opts{block_capacity}) {
        $body->{blockCapacity} = int($opts{block_capacity});
    } else {
        $body->{byteFormatCapacity} = $opts{size_mb} . "M";
    }

    if (defined $opts{ldev_id}) {
        # Explicit LDEV id (the plugin always allocates from ldev_range).
        # isParallelExecutionEnabled is ONLY valid when the array auto-assigns
        # the id; combining it with an explicit ldevId is rejected (KART40046-E).
        $body->{ldevId} = int($opts{ldev_id});
    } else {
        $body->{isParallelExecutionEnabled} = JSON::true;
    }

    my $res = $self->_request('POST', $self->_url('/ldevs'), $body);

    return $self->_wait_for_job($res);
}

sub delete_ldev {
    my ($self, $ldev_id) = @_;

    croak "ldev_id is required" unless defined $ldev_id;

    my $res = $self->_request('DELETE', $self->_url("/ldevs/$ldev_id"));
    return $self->_wait_for_job($res);
}

sub get_ldev {
    my ($self, $ldev_id) = @_;

    croak "ldev_id is required" unless defined $ldev_id;

    return $self->_request('GET', $self->_url("/ldevs/$ldev_id"));
}

sub list_ldevs {
    my ($self, %filter) = @_;

    my @params;
    # GET /ldevs returns a *window* of consecutive LDEV slots starting at
    # headLdevId (default 0) for `count` slots (default 100), INCLUDING empty
    # slots (emulationType "NOT DEFINED"). Pass head_ldev_id to scan a window
    # that does not start at 0 (the array 503s on very large counts).
    push @params, "headLdevId=$filter{head_ldev_id}" if defined $filter{head_ldev_id};
    push @params, "poolId=$filter{pool_id}"  if defined $filter{pool_id};
    push @params, "count=$filter{count}"     if defined $filter{count};
    push @params, "ldevOption=dpVolume"      if $filter{dp_only};

    my $query = @params ? '?' . join('&', @params) : '';
    my $data = $self->_request('GET', $self->_url("/ldevs$query"));

    return $data->{data} || [];
}

# Page through LDEV slots [$min..$max] and return only DEFINED LDEVs (skipping
# "NOT DEFINED" empty slots). The default list_ldevs() only sees slots 0-99, so
# any scan of a high ldev_range (or whole-array orphan detection) MUST page;
# requesting the whole LDEV space in one call (count=16384) makes the GUM 503.
sub list_defined_ldevs_in_range {
    my ($self, $min, $max, %opts) = @_;

    my $chunk = $opts{chunk} || 256;   # 256/512/1000 verified OK; 16384 -> 503
    my @out;
    my $head = $min;
    while ($head <= $max) {
        my $count = $max - $head + 1;
        $count = $chunk if $count > $chunk;
        my $batch = $self->list_ldevs(head_ldev_id => $head, count => $count);
        for my $ldev (@$batch) {
            my $id = $ldev->{ldevId};
            next unless defined $id && $id >= $min && $id <= $max;
            next if ($ldev->{emulationType} // '') eq 'NOT DEFINED';
            push @out, $ldev;
        }
        $head += $count;
    }
    return \@out;
}

sub set_ldev_label {
    my ($self, $ldev_id, $label) = @_;

    croak "ldev_id is required" unless defined $ldev_id;
    croak "label is required"   unless defined $label;

    my $body = { label => $label };
    my $res = $self->_request('PATCH', $self->_url("/ldevs/$ldev_id"), $body);
    return $self->_wait_for_job($res);
}

sub expand_ldev {
    my ($self, $ldev_id, $additional_mb) = @_;

    croak "ldev_id is required"       unless defined $ldev_id;
    croak "additional_mb is required" unless defined $additional_mb;

    my $body = {
        parameters => {
            additionalByteFormatCapacity => $additional_mb . "M",
        },
    };

    my $res = $self->_request('POST', $self->_url("/ldevs/$ldev_id/actions/expand/invoke"), $body);
    return $self->_wait_for_job($res);
}

# ── Pool Operations ──

sub get_pool {
    my ($self, $pool_id) = @_;

    croak "pool_id is required" unless defined $pool_id;

    return $self->_request('GET', $self->_url("/pools/$pool_id"));
}

# Fetch the array's own storage object (model, serial, microcode version). Used by
# the diagnostics bundle as a lightweight reachability + version probe — a GET on
# the base storages/<id> resource. Returns the decoded object (e.g. model,
# serialNumber, dkcMicroVersion).
sub get_storage_info {
    my ($self) = @_;
    return $self->_request('GET', $self->{base_url});
}

sub list_pools {
    my ($self) = @_;

    my $data = $self->_request('GET', $self->_url('/pools'));
    return $data->{data} || [];
}

# ── Host Group Operations ──

sub create_host_group {
    my ($self, %opts) = @_;

    croak "port_id is required"         unless $opts{port_id};
    croak "host_group_name is required" unless $opts{host_group_name};

    my $body = {
        portId        => $opts{port_id},
        hostGroupName => $opts{host_group_name},
        hostMode      => $opts{host_mode} || 'LINUX/IRIX',
    };
    # Host mode options (integers), e.g. 68 = "WRITE SAME command support and SCSI
    # ANSI Version 5 support" (Page Reclamation for Linux: enables UNMAP/discard so
    # thin pools reclaim on fstrim/blkdiscard).
    $body->{hostModeOptions} = [ map { int($_) } @{$opts{host_mode_options}} ]
        if $opts{host_mode_options} && @{$opts{host_mode_options}};

    my $res = $self->_request('POST', $self->_url('/host-groups'), $body);
    $self->_invalidate_hg_list_cache($opts{port_id});
    return $self->_wait_for_job($res);
}

# Set a host group's host mode + host mode options. The CM REST requires hostMode
# to be present whenever hostModeOptions is changed (else KART40046-E). Used to
# reconcile host mode options on host groups created before this was set (idempotent
# at the caller: only PATCH when the desired options are not already present).
sub set_host_group_mode {
    my ($self, %opts) = @_;

    croak "host_group_id is required" unless defined $opts{host_group_id};
    croak "host_mode is required"     unless defined $opts{host_mode};

    my $body = { hostMode => $opts{host_mode} };
    $body->{hostModeOptions} = [ map { int($_) } @{$opts{host_mode_options}} ]
        if $opts{host_mode_options};

    my $res = $self->_request('PATCH', $self->_url("/host-groups/$opts{host_group_id}"), $body);
    return $self->_wait_for_job($res);
}

sub list_host_groups {
    my ($self, %filter) = @_;
    my $port = $filter{port_id};

    # Per-instance cache of a port's host-group LIST (topology: names + numbers, NOT
    # WWNs). find_host_group_by_name/by_wwn call this repeatedly in the clone
    # host-mapping hot path; on slow CM REST re-fetching per lookup dominates. WWN
    # membership is ALWAYS read fresh (list_host_wwns is never cached), so the
    # multi-cluster WWN-ownership guard never sees stale initiators. Invalidated on
    # create_host_group/delete_host_group (our own mutations); a group another node
    # adds out-of-band that we haven't seen only means we resolve OUR group as usual.
    if ( defined $port ) {
        my $c = $self->{_hg_list_cache}{$port};
        return $c->{list} if $c && ( time - $c->{ts} ) < $HG_LIST_CACHE_TTL;
    }

    my @params;
    push @params, "portId=$port" if $port;
    my $query = @params ? '?' . join('&', @params) : '';
    my $data = $self->_request('GET', $self->_url("/host-groups$query"));
    my $list = $data->{data} || [];
    $self->{_hg_list_cache}{$port} = { ts => time, list => $list } if defined $port;
    return $list;
}

# Drop the cached host-group list for a port (after a create/delete on it).
sub _invalidate_hg_list_cache {
    my ($self, $port) = @_;
    delete $self->{_hg_list_cache}{$port} if defined $port;
}

sub get_host_group {
    my ($self, $host_group_id) = @_;

    croak "host_group_id is required" unless defined $host_group_id;

    return $self->_request('GET', $self->_url("/host-groups/$host_group_id"));
}

sub add_wwn_to_host_group {
    my ($self, %opts) = @_;

    croak "port_id is required"           unless defined $opts{port_id};
    croak "host_group_number is required" unless defined $opts{host_group_number};
    croak "wwn is required"               unless $opts{wwn};

    # CM REST /host-wwns needs portId + hostGroupNumber to target the right host
    # group; without hostGroupNumber the WWN would not land in our group.
    # NOTE: hostWwnNickname is NOT accepted in this body on the embedded REST of
    # the VSP E series (KART40038-E "unsupported parameter") — omit it. (A WWN
    # nickname, if ever wanted, must be set via a separate request.)
    my $body = {
        portId          => $opts{port_id},
        hostGroupNumber => int($opts{host_group_number}),
        hostWwn         => $opts{wwn},
    };

    my $res = $self->_request('POST', $self->_url("/host-wwns"), $body);
    return $self->_wait_for_job($res);
}

sub list_host_wwns {
    my ($self, %opts) = @_;

    croak "port_id is required" unless defined $opts{port_id};

    # CM REST lists host WWNs via the top-level /host-wwns collection filtered by
    # portId (+ hostGroupNumber), NOT a /host-groups/<id>/host-wwns subresource
    # (that path 404s on the VSP E embedded REST).
    my @params = ("portId=$opts{port_id}");
    push @params, "hostGroupNumber=$opts{host_group_number}"
        if defined $opts{host_group_number};
    my $query = '?' . join('&', @params);

    my $data = $self->_request('GET', $self->_url("/host-wwns$query"));
    return $data->{data} || [];
}

sub find_host_group_by_name {
    my ($self, $port_id, $name) = @_;

    my $groups = $self->list_host_groups(port_id => $port_id);
    for my $hg (@$groups) {
        return $hg if defined $hg->{hostGroupName} && $hg->{hostGroupName} eq $name;
    }
    return undef;
}

sub find_host_group_by_wwn {
    my ($self, $port_id, $wwn) = @_;

    # debug(3) diagnostic: this scan is O(host groups) and should be rare (a name-miss
    # fallback). Log the caller chain past the _call/__ANON__ wrapper so a live trace
    # can pin WHICH path still triggers it (ensure_host_access vs a publish/unpublish
    # _find_node_hg fallback). Gated so the caller() walk only runs at debug>=3.
    if ( ( $self->{debug} // 0 ) >= 3 ) {
        my @chain;
        for my $lvl ( 1 .. 6 ) { my @c = caller($lvl); last unless @c; push @chain, ( $c[3] // '?' ) . ':' . ( $c[2] // 0 ); }
        $self->_debug( 3, "find_host_group_by_wwn scan on $port_id caller-chain: " . join( ' <- ', @chain ) );
    }

    # NOTE: the CM REST /host-wwns collection REQUIRES both portId AND hostGroupNumber
    # (portId alone -> KART40044-E "Required parameters not specified"), so this must
    # scan per host group. It is therefore O(host groups) and slow on a busy port —
    # avoid it on the hot path (publish_lu resolves by the ensured name instead).
    my $groups = $self->list_host_groups(port_id => $port_id);
    for my $hg (@$groups) {
        my $wwns = eval {
            $self->list_host_wwns(
                port_id           => $port_id,
                host_group_number => $hg->{hostGroupNumber},
            );
        } || [];
        for my $w (@$wwns) {
            if (lc($w->{hostWwn}) eq lc($wwn)) {
                return $hg;
            }
        }
    }
    return undef;
}

# ── LUN Path Operations ──

sub map_lun {
    my ($self, %opts) = @_;

    croak "port_id is required"       unless $opts{port_id};
    croak "host_group_number is required" unless defined $opts{host_group_number};
    croak "ldev_id is required"       unless defined $opts{ldev_id};

    my $body = {
        portId          => $opts{port_id},
        hostGroupNumber => int($opts{host_group_number}),
        ldevId          => int($opts{ldev_id}),
    };
    $body->{lun} = int($opts{lun}) if defined $opts{lun};

    my $res = $self->_request('POST', $self->_url('/luns'), $body);
    return $self->_wait_for_job($res);
}

sub unmap_lun {
    my ($self, $lun_id) = @_;

    croak "lun_id is required" unless defined $lun_id;

    my $res = $self->_request('DELETE', $self->_url("/luns/$lun_id"));
    return $self->_wait_for_job($res);
}

sub list_luns {
    my ($self, %filter) = @_;

    my @params;
    push @params, "portId=$filter{port_id}"                     if $filter{port_id};
    push @params, "hostGroupNumber=$filter{host_group_number}"  if defined $filter{host_group_number};

    my $query = @params ? '?' . join('&', @params) : '';
    my $data = $self->_request('GET', $self->_url("/luns$query"));
    my $luns = $data->{data} || [];

    # CRITICAL: ldevId is NOT honoured as a server-side filter on GET /luns — the
    # array IGNORES it and returns every LUN path in the host group. Filtering by
    # ldevId MUST be done client-side; otherwise a caller iterating host groups
    # would see (and could unmap) OTHER hosts' / other volumes' LUN paths.
    if (defined $filter{ldev_id}) {
        my $want = int($filter{ldev_id});
        $luns = [ grep { defined $_->{ldevId} && int($_->{ldevId}) == $want } @$luns ];
    }

    return $luns;
}

# ── Snapshot Operations (Thin Image) ──

sub create_snapshot {
    my ($self, %opts) = @_;

    croak "pvol_ldev_id is required"   unless defined $opts{pvol_ldev_id};
    croak "snap_pool_id is required"   unless defined $opts{snap_pool_id};

    # autoSplit=true splits the pair right after creation so the S-VOL becomes host
    # R/W-accessible (PSUS) while still sharing unchanged blocks with the P-VOL via
    # the pool (copy-on-write). Default on; pass auto_split=0 only to leave the pair
    # un-split (reference-only S-VOL). NOTE: must NOT be combined with isClone=true.
    my $auto_split = (exists $opts{auto_split} && !$opts{auto_split}) ? JSON::false : JSON::true;

    my $body = {
        snapshotGroupName  => $opts{snapshot_group} || 'pve_snap',
        snapshotPoolId     => int($opts{snap_pool_id}),
        pvolLdevId         => int($opts{pvol_ldev_id}),
        isConsistencyGroup => $opts{is_consistency_group} ? JSON::true : JSON::false,
        autoSplit          => $auto_split,
    };

    $body->{svolLdevId} = int($opts{svol_ldev_id}) if defined $opts{svol_ldev_id};
    $body->{copySpeed}  = int($opts{copy_speed})   if defined $opts{copy_speed};

    # canCascade lets the S-VOL itself be a P-VOL of a further pair (clone chains).
    # isDataReductionForceCopy permits the pair when the P-VOL is a data-reduction
    # (dedup/compression) volume. Together with svolLdevId they let the array bind the
    # S-VOL at pair creation with NEITHER volume mapped — the space-efficient linked
    # clone recipe (per the OpenStack HBSD driver), avoiding the map-then-assign dance.
    $body->{canCascade}               = JSON::true if $opts{can_cascade};
    $body->{isDataReductionForceCopy} = JSON::true if $opts{is_data_reduction_force_copy};

    my $res = $self->_request('POST', $self->_url('/snapshots'), $body);
    return $self->_wait_for_job($res);
}

sub delete_snapshot {
    my ($self, $snapshot_id) = @_;

    croak "snapshot_id is required" unless defined $snapshot_id;

    my $res = $self->_request('DELETE', $self->_url("/snapshots/$snapshot_id"));
    return $self->_wait_for_job($res);
}

sub list_snapshots {
    my ($self, %filter) = @_;

    my @params;
    push @params, "pvolLdevId=$filter{pvol_ldev_id}" if defined $filter{pvol_ldev_id};

    my $query = @params ? '?' . join('&', @params) : '';
    my $data = $self->_request('GET', $self->_url("/snapshots$query"));
    return $data->{data} || [];
}

sub get_snapshot {
    my ($self, $snapshot_id) = @_;

    croak "snapshot_id is required" unless defined $snapshot_id;

    return $self->_request('GET', $self->_url("/snapshots/$snapshot_id"));
}

sub split_snapshot {
    my ($self, $snapshot_id) = @_;

    croak "snapshot_id is required" unless defined $snapshot_id;

    # The single-pair split action takes an EMPTY parameters object. The REST API
    # Reference lists "Body: None" for this action, and this microcode (E590H
    # 93-07-23) rejects an `operationType` attribute with KART40038-E ("unsupported
    # parameter ... operationType") — the same quirk as restore (see #22). Send
    # {"parameters":{}}, the form the array accepts. (split was previously unused:
    # pairs are created with autoSplit=true; the rollback re-split path, #12, is the
    # first caller and exposed the stale operationType body.)
    my $body = { parameters => {} };

    my $res = $self->_request('POST', $self->_url("/snapshots/$snapshot_id/actions/split/invoke"), $body);
    return $self->_wait_for_job($res);
}

sub split_snapshotgroup {
    my ($self, $group_name) = @_;

    croak "group_name is required" unless defined $group_name;

    # Atomically split every pair in a snapshot group — the crash-consistent CG
    # snapshot action: all S-VOLs suspend (PAIR->PSUS) at the same instant. The object
    # id is the snapshot group NAME. Send {"parameters":{}} — the same empty-params form
    # the single-pair split/restore actions require on this microcode (an operationType
    # attribute is rejected with KART40038-E; see split_snapshot).
    my $body = { parameters => {} };

    my $res = $self->_request('POST',
        $self->_url("/snapshot-groups/$group_name/actions/split/invoke"), $body);
    return $self->_wait_for_job($res);
}

sub restore_snapshot {
    my ($self, $snapshot_id) = @_;

    croak "snapshot_id is required" unless defined $snapshot_id;

    # The restore action takes an EMPTY parameters object. This microcode (E590H
    # 93-07-23) rejects an `operationType` attribute with KART40038-E ("unsupported
    # parameter ... operationType"), and rejects a bare {} with KART40046-E
    # ("required parameters not specified"); {"parameters":{}} is the form the array
    # accepts (confirmed live). See GitHub #22.
    my $body = { parameters => {} };

    my $res = $self->_request('POST', $self->_url("/snapshots/$snapshot_id/actions/restore/invoke"), $body);
    return $self->_wait_for_job($res);
}

# Assign an existing S-VOL LDEV to a data-only Thin Image pair's snapshot data,
# making the snapshot host-readable through that S-VOL (status PSUS, copy-on-write
# sharing with the P-VOL). This is the second half of the linked-clone workflow on
# VSP One Block / Thin Image Advanced: a pair created WITHOUT an S-VOL, then the
# S-VOL assigned here. The S-VOL **must already have LU paths** (be mapped to a
# host group) before assign — otherwise the array rejects it with KART30000-E
# ("The specified snapshot S-VOL does not have LU paths …"). The microcode also
# rejects supplying svolLdevId at pair-creation time, which is why the assignment
# is a separate step. Confirmed live on the E590H (93-07-23). See GitHub #24.
sub assign_snapshot_volume {
    my ($self, $snapshot_id, $svol_ldev_id) = @_;

    croak "snapshot_id is required"  unless defined $snapshot_id;
    croak "svol_ldev_id is required" unless defined $svol_ldev_id;

    my $body = { parameters => { svolLdevId => int($svol_ldev_id) } };
    my $res = $self->_request('POST',
        $self->_url("/snapshots/$snapshot_id/actions/assign-volume/invoke"), $body);
    return $self->_wait_for_job($res);
}

sub clone_snapshot_to_ldev {
    my ($self, %opts) = @_;

    croak "pvol_ldev_id is required"  unless defined $opts{pvol_ldev_id};
    croak "svol_ldev_id is required"  unless defined $opts{svol_ldev_id};
    croak "snap_pool_id is required"  unless defined $opts{snap_pool_id};

    my $body = {
        snapshotGroupName  => $opts{snapshot_group} || 'pve_clone',
        snapshotPoolId     => int($opts{snap_pool_id}),
        pvolLdevId         => int($opts{pvol_ldev_id}),
        svolLdevId         => int($opts{svol_ldev_id}),
        isClone            => JSON::true,
        isConsistencyGroup => JSON::false,
        autoSplit          => JSON::true,
    };

    $body->{copySpeed} = int($opts{copy_speed}) if defined $opts{copy_speed};

    my $res = $self->_request('POST', $self->_url('/snapshots'), $body);
    return $self->_wait_for_job($res);
}

# ── QoS Operations ──

sub set_ldev_qos {
    my ($self, $ldev_id, %opts) = @_;

    croak "ldev_id is required" unless defined $ldev_id;

    my $body = {};
    $body->{upperIops} = int($opts{upper_iops})                   if defined $opts{upper_iops};
    $body->{upperTransferRate} = int($opts{upper_mbps})           if defined $opts{upper_mbps};
    $body->{lowerIops} = int($opts{lower_iops})                   if defined $opts{lower_iops};
    $body->{lowerTransferRate} = int($opts{lower_mbps})           if defined $opts{lower_mbps};
    $body->{responsePriority} = int($opts{response_priority})     if defined $opts{response_priority};

    croak "At least one QoS parameter is required" unless keys %$body;

    my $res = $self->_request('PATCH', $self->_url("/ldevs/$ldev_id"), $body);
    return $self->_wait_for_job($res);
}

sub get_ldev_qos {
    my ($self, $ldev_id) = @_;

    croak "ldev_id is required" unless defined $ldev_id;

    my $ldev = $self->get_ldev($ldev_id);
    return {
        upper_iops        => $ldev->{upperIops},
        upper_mbps        => $ldev->{upperTransferRate},
        lower_iops        => $ldev->{lowerIops},
        lower_mbps        => $ldev->{lowerTransferRate},
        response_priority => $ldev->{responsePriority},
    };
}

# ── Replication Operations (TrueCopy / Universal Replicator / GAD) ──

sub create_remote_copy_pair {
    my ($self, %opts) = @_;

    croak "copy_group_name is required" unless $opts{copy_group_name};
    croak "pvol_ldev_id is required"    unless defined $opts{pvol_ldev_id};
    croak "svol_ldev_id is required"    unless defined $opts{svol_ldev_id};
    croak "remote_storage_id is required" unless $opts{remote_storage_id};
    croak "copy_pace is required"       unless $opts{copy_pace};

    my $body = {
        copyGroupName        => $opts{copy_group_name},
        copyPairName         => $opts{copy_pair_name} || "pair_$opts{pvol_ldev_id}_$opts{svol_ldev_id}",
        replicationType      => $opts{replication_type} || 'TC',  # TC, UR, GAD
        pvolLdevId           => int($opts{pvol_ldev_id}),
        svolLdevId           => int($opts{svol_ldev_id}),
        remoteStorageDeviceId => $opts{remote_storage_id},
        copyPace             => int($opts{copy_pace}),
        isConsistencyGroup   => $opts{consistency_group} ? JSON::true : JSON::false,
    };

    # GAD-specific options
    if (($opts{replication_type} || '') eq 'GAD') {
        $body->{quorumDiskId} = int($opts{quorum_disk_id}) if defined $opts{quorum_disk_id};
    }

    # UR-specific options
    if (($opts{replication_type} || '') eq 'UR') {
        $body->{journalId} = int($opts{journal_id}) if defined $opts{journal_id};
    }

    my $res = $self->_request('POST', $self->_url('/remote-mirror-copypairs'), $body);
    return $self->_wait_for_job($res);
}

sub delete_remote_copy_pair {
    my ($self, $pair_id) = @_;

    croak "pair_id is required" unless defined $pair_id;

    my $res = $self->_request('DELETE', $self->_url("/remote-mirror-copypairs/$pair_id"));
    return $self->_wait_for_job($res);
}

sub get_remote_copy_pair {
    my ($self, $pair_id) = @_;

    croak "pair_id is required" unless defined $pair_id;

    return $self->_request('GET', $self->_url("/remote-mirror-copypairs/$pair_id"));
}

sub list_remote_copy_pairs {
    my ($self, %filter) = @_;

    my @params;
    push @params, "replicationType=$filter{replication_type}" if $filter{replication_type};

    my $query = @params ? '?' . join('&', @params) : '';
    my $data = $self->_request('GET', $self->_url("/remote-mirror-copypairs$query"));
    return $data->{data} || [];
}

sub split_remote_copy_pair {
    my ($self, $pair_id) = @_;

    croak "pair_id is required" unless defined $pair_id;

    my $body = {
        parameters => {
            operationType => 'split',
        },
    };

    my $res = $self->_request('POST', $self->_url("/remote-mirror-copypairs/$pair_id/actions/split/invoke"), $body);
    return $self->_wait_for_job($res);
}

sub resync_remote_copy_pair {
    my ($self, $pair_id) = @_;

    croak "pair_id is required" unless defined $pair_id;

    my $body = {
        parameters => {
            operationType => 'resync',
        },
    };

    my $res = $self->_request('POST', $self->_url("/remote-mirror-copypairs/$pair_id/actions/resync/invoke"), $body);
    return $self->_wait_for_job($res);
}

# ── Remote Storage Registration ──

sub register_remote_storage {
    my ($self, %opts) = @_;

    croak "remote_storage_id is required" unless $opts{remote_storage_id};
    croak "remote_ip is required"         unless $opts{remote_ip};

    my $body = {
        remoteStorageDeviceId => $opts{remote_storage_id},
        pathGroupId           => int($opts{path_group_id} || 0),
        remoteIpAddress       => $opts{remote_ip},
    };

    my $res = $self->_request('POST', $self->_url('/remote-storages'), $body);
    return $self->_wait_for_job($res);
}

sub list_remote_storages {
    my ($self) = @_;

    my $data = $self->_request('GET', $self->_url('/remote-storages'));
    return $data->{data} || [];
}

# ── Zero Page Reclamation ──

sub reclaim_zero_pages {
    my ($self, $ldev_id) = @_;

    croak "ldev_id is required" unless defined $ldev_id;

    my $body = { parameters => {} };
    my $res = $self->_request('POST', $self->_url("/ldevs/$ldev_id/actions/discard-zero-page/invoke"), $body);
    return $self->_wait_for_job($res);
}

# ── Storage-Assisted LDEV Migration ──

sub migrate_ldev {
    my ($self, $ldev_id, $target_pool_id) = @_;

    croak "ldev_id is required"        unless defined $ldev_id;
    croak "target_pool_id is required" unless defined $target_pool_id;

    my $body = {
        parameters => {
            poolId => int($target_pool_id),
        },
    };

    my $res = $self->_request('POST', $self->_url("/ldevs/$ldev_id/actions/change-pool/invoke"), $body);
    return $self->_wait_for_job($res);
}

# ── Host Group Deletion ──

sub delete_host_group {
    my ($self, $host_group_id) = @_;

    croak "host_group_id is required" unless defined $host_group_id;

    my $res = $self->_request('DELETE', $self->_url("/host-groups/$host_group_id"));
    my ($port) = split /,/, $host_group_id;
    $self->_invalidate_hg_list_cache($port);
    return $self->_wait_for_job($res);
}

# ── Internal HTTP / Job Helpers ──

sub _url {
    my ($self, $path) = @_;
    return $self->{base_url} . $path;
}

# Build a ConfigurationManager v1/objects URL for a suffix that is NOT
# storage-scoped (sessions, jobs).  All hand-assembled literals that share
# the prefix https://<host>:<port>/ConfigurationManager/v1/objects/ funnel
# through here so the prefix is owned in one place.
sub _objects_url {
    my ($self, $suffix) = @_;
    return "https://$self->{mgmt_ip}:$self->{port}/ConfigurationManager/v1/objects/$suffix";
}

# Apply HTTP authentication to $req based on the current mode: basic auth for
# session-less clients, session token for established sessions, nothing if no
# token yet (login not yet called).  Extracted to eliminate the identical
# if/elsif block that appears at both the initial request build and the
# post-failover re-auth site inside _request.
sub _apply_auth {
    my ($self, $req) = @_;
    if ($self->{sessionless}) {
        $req->authorization_basic($self->{username}, $self->{password});
    } elsif ($self->{token}) {
        $req->header('Authorization' => "Session $self->{token}");
    }
    return;
}

# Return the bare API path segment of $url for use in log messages: everything
# from /v1/objects/ onwards, with the long base URL stripped.  Produces the
# same string the three inline s{^.*/v1/objects/}{/} substitutions produced.
sub _short_path {
    my ($self, $url) = @_;
    (my $path = $url) =~ s{^.*/v1/objects/}{/};
    return $path;
}

# Accumulate per-request latency so callers (e.g. the diagnostics bundle, #18) can
# report management-endpoint responsiveness — the GUM is intrinsically slow, so
# per-call timing is a primary troubleshooting signal. Stats live on the client
# object (per-process); negligible overhead and no logging here (threshold logging
# belongs with the debug-level work, #33). Slowest sample keeps its method+path.
sub _record_rest_timing {
    my ($self, $method, $url, $secs) = @_;

    my $s = $self->{rest_stats} ||= { count => 0, total => 0, max => 0 };
    $s->{count}++;
    $s->{total} += $secs;
    $s->{last}   = $secs;
    if ($secs > $s->{max}) {
        $s->{max}        = $secs;
        # Record the bare API path (drop the long base URL) for a readable report.
        $s->{slowest} = "$method " . $self->_short_path($url);
    }
    return;
}

# Snapshot of accumulated REST timing for this client (or undef if no calls yet):
# { count, total, last, max, slowest, avg } — all times in seconds.
sub rest_timing_stats {
    my ($self) = @_;
    my $s = $self->{rest_stats};
    return undef unless $s && $s->{count};
    return { %$s, avg => $s->{total} / $s->{count} };
}

# Diagnostic logging (#33). Emits to syslog (tag 'fclu-hitachi') only when the
# client's debug level is >= $level. No-op at 0; never throws. The Authorization
# header and basic-auth credentials are never passed here; body logging is
# redacted by the caller via _redact().
my $_rc_syslog_open = 0;
sub _debug {
    my ($self, $level, $msg) = @_;

    return unless ($self->{debug} // 0) >= $level;
    eval {
        require Sys::Syslog;
        unless ($_rc_syslog_open) {
            Sys::Syslog::openlog('fclu-hitachi', 'ndelay,pid', 'daemon');
            $_rc_syslog_open = 1;
        }
        Sys::Syslog::syslog('info', '%s', "[$self->{storage_id}] L$level REST $msg");
    };
    return;
}

# Mask the values of secret-bearing JSON keys before logging a request/response
# body at trace level. Defensive only — the plugin never puts secrets in bodies
# (auth is via the HTTP header) — but a future field must never leak. Operates on
# the raw JSON string so it works regardless of nesting.
sub _redact {
    my ($self, $body) = @_;
    return '' unless defined $body;
    $body =~ s/("(?:password|passwd|token|sessionId|auth\w*|credential\w*|secret)"\s*:\s*)"[^"]*"/$1"<redacted>"/gi;
    return $body;
}

sub _request {
    my ($self, $method, $url, $body, $skip_reauth) = @_;

    my $req = HTTP::Request->new($method, $url);
    $req->header('Content-Type' => 'application/json');
    $req->header('Accept'       => 'application/json');

    # Session-less mode authenticates each request with HTTP basic auth and never
    # creates a persistent session (#26); otherwise use the session token.
    $self->_apply_auth($req);

    if ($body) {
        my $json = encode_json($body);
        $req->content($json);
        # Only build the (redacted) trace line when level 3 is active, so the
        # common debug=0 path does no extra work per request.
        if (($self->{debug} // 0) >= 3) {
            $self->_debug(3, "$method " . $self->_short_path($url) . " body=" . $self->_redact($json));
        }
    }

    my $res;
    my $retries   = 0;
    my $failovers = 0;

    while ($retries <= $MAX_RETRIES) {
        my $t0 = Time::HiRes::time();
        $res = $self->{ua}->request($req);
        my $elapsed = Time::HiRes::time() - $t0;
        $self->_record_rest_timing($method, $url, $elapsed);

        if (($self->{debug} // 0) >= 2) {
            $self->_debug(2, sprintf('%s %s -> %s (%d ms)',
                $method, $self->_short_path($url), $res->code, int($elapsed * 1000)));
            $self->_debug(3, 'response body=' . $self->_redact($res->content // ''))
                if length($res->content // '');
        }

        if ($res->is_success) {
            my $content = $res->content;
            if ($content && length($content) > 0) {
                # N11: only decode when the body is actually JSON. An interposed auth
                # portal / reverse proxy / GUM can return an HTML 200 — surface that as a
                # classified error instead of an opaque decode_json die with no HTTP status
                # for _translate_rest_error to key on.
                my $ct = $res->content_type // '';
                croak "API request failed: $method $url -> 200 non-JSON response"
                    . " (content-type '$ct')"
                    unless $ct =~ /json/i;
                my $data = eval { decode_json($content) };
                croak "API request failed: $method $url -> 200 with an unparseable JSON body: $@"
                    if $@;
                return $data;
            }

            # For async operations, extract job URL from Location or response headers
            my $job_id = $res->header('Job-Id');
            my $location = $res->header('Location');
            if ($job_id) {
                return { jobId => $job_id };
            }
            if ($location) {
                return { location => $location };
            }
            return {};
        }

        my $code = $res->code;

        # Transport-level failure (controller/GUM unreachable) → fail over to the
        # next management endpoint, re-authenticate there, re-target the request at
        # the survivor, and retry. Bounded by the number of endpoints. Skipped for
        # single-endpoint configs and for best-effort calls that opt out of reauth
        # (e.g. logout).
        if ($self->_is_transport_error($res)
            && $self->{username} && !$skip_reauth
            && $failovers < scalar(@{$self->{endpoints}})
            && $self->_switch_endpoint()) {
            $failovers++;
            $self->login() unless $self->{sessionless};   # croaks only if NO controller is reachable
            $url = $self->_rewrite_host($url);
            $req->uri($url);
            # Re-apply auth for the survivor: basic auth is host-independent, the
            # session token is per-controller and was just refreshed by login().
            $self->_apply_auth($req);
            next;
        }

        # N9: a GENUINE transport error (an LWP-synthesized response, not a server status)
        # means no HTTP reply arrived. For an IDEMPOTENT method it is always safe to resend.
        # For a non-idempotent POST it is safe ONLY when the failure is clearly CONNECT-phase
        # (connection refused / host unreachable / DNS — the request never left the client);
        # a READ timeout may mean the array already RECEIVED and applied the request (e.g. the
        # RELATIVE expand_ldev), so resending would double-apply. LWP stamps the same
        # Client-Warning on both, so we distinguish by the synthesized message. When there is
        # nothing to fail over to (single endpoint / floating VIP), retry here rather than
        # croaking; a server-returned 5xx is NOT a transport error and gates on idempotency
        # below.
        my $idempotent_n9 = $method =~ /^(?:GET|PUT|DELETE|HEAD)$/i;
        if ($self->_is_transport_error($res) && !$skip_reauth && $retries < $MAX_RETRIES
            && ($idempotent_n9 || $self->_is_connect_phase_error($res))) {
            $retries++;
            sleep($self->_retry_delay($retries, $res));
            next;
        }

        # 401 Unauthorized - re-authenticate once (session mode only; in session-less
        # mode basic auth is already on every request, so a 401 is a real credential
        # failure and must not loop).
        if ($code == 401 && !$skip_reauth && $self->{username} && !$self->{sessionless}) {
            $self->login();
            $req->header('Authorization' => "Session $self->{token}");
            $retries++;
            next;
        }

        # Decide whether this failure is safe to retry. A 429 means the request was
        # rate-limited *before* being processed, so it is always safe to resend —
        # even a POST. For 5xx and 409 the server may have already applied a
        # non-idempotent POST (create LDEV / map LUN / expand), and resending would
        # double-create or double-apply, so those are only retried for idempotent
        # methods (GET/PUT/DELETE/HEAD).
        my $idempotent = $method =~ /^(?:GET|PUT|DELETE|HEAD)$/i;
        my $retriable  = ($code == 429)
            || ($idempotent && ($code >= 500 || $code == 409));

        if ($retriable && $retries < $MAX_RETRIES) {
            $retries++;
            sleep($self->_retry_delay($retries, $res));
            next;
        }

        last;
    }

    croak "API request failed: $method $url -> " . $res->status_line . " " . ($res->content || '');
}

sub _wait_for_job {
    my ($self, $res) = @_;

    return $res unless ref $res eq 'HASH';

    my $job_id = $res->{jobId};

    # Some async operations return only a Location header pointing at the job
    # resource instead of a jobId in the body. Derive the job URL from either.
    my $url;
    if ($job_id) {
        # Poll the job scoped UNDER the storage system (.../storages/<id>/jobs/<id>).
        # This is the universal form: it works on both a fronting Ops Center CM server
        # AND the array's embedded GUM REST (verified live on an E590 — both return the
        # job). The flat /objects/jobs/<id> only works on the embedded GUM and 404s via
        # a CM (which fronts many arrays, so job ids must be storage-scoped). §10.
        $url = $self->_url("/jobs/$job_id");
    } elsif ($res->{location}) {
        my $loc = $res->{location};
        # Location may be absolute or relative to the API root.
        $url = $loc =~ m{^https?://}
            ? $loc
            : "https://$self->{mgmt_ip}:$self->{port}$loc";
        ($job_id) = $loc =~ m{/jobs/([^/]+)} ;
        $job_id //= $loc;
    } else {
        return $res;
    }

    my $elapsed = 0;
    my $budget  = $self->{job_timeout} || $JOB_POLL_TIMEOUT;
    while ($elapsed < $budget) {
        sleep($JOB_POLL_INTERVAL);
        $elapsed += $JOB_POLL_INTERVAL;

        my $job = $self->_request('GET', $url);
        my $state = $job->{state} || '';

        if ($state eq 'Succeeded') {
            my $affected = $job->{affectedResources} || [];
            if (@$affected) {
                # Extract the resource id from the last path segment. N16: a pure-numeric
                # tail (LDEV) becomes an int for back-compat; a COMPOSITE id — host group
                # ".../host-groups/CL1-A,0", LUN ".../luns/CL1-A,0,1" — is kept as the full
                # last segment (an opaque string), instead of being missed by a numeric-only
                # regex and degrading to a bare resourceUrl.
                my $resource_url = $affected->[0];
                if ( my ($last) = $resource_url =~ m{/([^/]+)$} ) {
                    return { resourceId => ( $last =~ /^\d+$/ ? int($last) : $last ),
                             jobId => $job_id };
                }
                return { resourceUrl => $resource_url, jobId => $job_id };
            }
            return { jobId => $job_id };
        }

        if ($state eq 'Failed' || $state eq 'Unknown') {
            my $error = $job->{error} || {};
            croak "Job $job_id failed: " . ($error->{message} || $state);
        }
    }

    croak "Job $job_id timed out after ${budget}s";
}

1;
