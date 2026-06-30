package PVE::Storage::FCLU::Error;

use strict;
use warnings;

# The single normalized error type every FCLU driver dies with (ARCHITECTURE.md
# §13). Raw vendor REST errors never reach the core or the GUI — the driver
# translates them into this object at its boundary. The core decides
# retry-vs-compensate-vs-fail from `code` + the two booleans; the PVE boundary
# (§13.5) renders `message` to the admin and logs `vendor`/`cause` only.

use overload
    '""'     => \&to_string,
    'bool'   => sub { 1 },
    fallback => 1;

# Closed code vocabulary for fclu-driver-api-1 (§13.3). Each value is the DEFAULT
# [retryable, transient] classification. Callers may override either explicitly —
# e.g. `timeout` defaults to a mutation (retryable 0), but a read-only timeout is
# raised with retryable => 1 (§13.3 note).
my %CODES = (
    connectivity   => [ 1, 1 ],   # endpoint unreachable / TLS / connect timeout
    auth           => [ 0, 0 ],   # credentials rejected / session invalid
    array_busy     => [ 1, 1 ],   # busy / throttle / concurrent-op lock
    conflict       => [ 0, 1 ],   # precondition / optimistic-lock / state mismatch
    not_found      => [ 0, 0 ],   # object absent (only from read/mutate methods, §13.3)
    already_exists => [ 0, 0 ],   # id collision, mismatched attributes (§12.2)
    out_of_space   => [ 0, 0 ],   # pool capacity exhausted
    limit          => [ 0, 0 ],   # array object/host-group/LU count limit hit
    unsupported    => [ 0, 0 ],   # capability/firmware missing (should be cap-gated)
    invalid        => [ 0, 0 ],   # bad argument / shape
    timeout        => [ 0, 1 ],   # async job didn't converge; mutation default
    partial        => [ 0, 0 ],   # operation half-applied, compensation required
    internal       => [ 0, 0 ],   # driver bug / unexpected vendor payload
);

sub new {
    my ($class, %args) = @_;

    my $code = $args{code};
    die "FCLU::Error: 'code' is required\n" unless defined $code;
    die "FCLU::Error: unknown code '$code'\n" unless exists $CODES{$code};

    my $message = $args{message};
    die "FCLU::Error: 'message' is required\n"
        unless defined $message && length $message;

    my ($def_retryable, $def_transient) = @{ $CODES{$code} };

    my $self = {
        code      => $code,
        message   => $message,
        # `// default` keeps an explicit 0 from the caller; the ternary normalizes
        # any truthy/falsy override down to a strict 0|1 (the contract — §13.1).
        retryable => ( ( $args{retryable} // $def_retryable ) ? 1 : 0 ),
        transient => ( ( $args{transient} // $def_transient ) ? 1 : 0 ),
        vendor    => $args{vendor},   # raw vendor payload — LOGS ONLY, never the GUI (§13.5)
        cause     => $args{cause},    # wrapped lower-level exception, if any
    };

    return bless $self, $class;
}

# Convenience: build and die in one call — `FCLU::Error->throw(code => ..., ...)`.
sub throw {
    my ($class, %args) = @_;
    die $class->new(%args);
}

sub code         { $_[0]->{code} }
sub message      { $_[0]->{message} }
sub is_retryable { $_[0]->{retryable} }
sub is_transient { $_[0]->{transient} }
sub vendor       { $_[0]->{vendor} }
sub cause        { $_[0]->{cause} }

# Admin-safe rendering: code + normalized message ONLY. The `vendor` blob is
# deliberately excluded so a stringified error can never leak a raw payload into
# a task log or GUI message (§13.5). The PVE boundary appends "\n" for `die`.
sub to_string {
    my ($self) = @_;
    return sprintf( '[%s] %s', $self->{code}, $self->{message} );
}

# The closed code vocabulary, for callers/tests that need to enumerate it.
sub codes { return sort keys %CODES }

1;
