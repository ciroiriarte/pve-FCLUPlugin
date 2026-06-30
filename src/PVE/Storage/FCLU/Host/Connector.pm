package PVE::Storage::FCLU::Host::Connector;

use strict;
use warnings;

use Carp qw(croak);

# Abstract host-connector interface (ARCHITECTURE.md §3). The host side of the
# framework: it turns a canonical device identity (the driver's get_lu_identity,
# §12.1) into a usable block device on THIS node, and reports the node's local
# initiators for host-access/zoning. It is generic around protocol + canonical
# identity — never vendor synthesis (the deleted Hitachi `ldev_to_wwid` lived in
# the old plugin; the driver is now the single source of truth for identity).
#
# The base class implements no behaviour: each method croaks "not implemented",
# so a half-finished connector fails loudly. `Host::FCMultipath` is the concrete
# scsi-fc implementation; future transports (scsi-iscsi, nvme-fc, nvme-tcp, §3)
# are alternate subclasses over the same surface.

# Canonical method surface (§3). Exposed so a connector and any conformance check
# assert against one list rather than a hand-copied duplicate (mirrors
# FCLU::Driver->contract_methods).
my @CONTRACT_METHODS = qw(
    host_context
    attach
    detach
    resize
    flush
    device_path
);

sub contract_methods { return @CONTRACT_METHODS }

sub new {
    my ($class, %args) = @_;
    return bless { %args }, $class;
}

sub _nyi {
    my ($self, $method) = @_;
    my $class = ref($self) || $self;
    croak "$class does not implement '$method' (host-connector interface, §3)";
}

# host_context(%opts) -> \%ctx. This node's identity for host-access methods:
# { hostname, protocol, initiators => [local initiator ids] } (§12.1 %host_ctx).
sub host_context { my ($self) = @_; $self->_nyi('host_context') }

# attach($identity) -> $device_path. Rescan + wait for the /dev/mapper device that
# carries the canonical identity, returning its path. Idempotent.
sub attach { my ($self) = @_; $self->_nyi('attach') }

# detach($identity). Flush + remove the multipath map + delete the SCSI devices +
# settle, so the array can safely unmap. Idempotent / best-effort.
sub detach { my ($self) = @_; $self->_nyi('detach') }

# resize($identity). Rescan the underlying paths and grow the multipath device to
# the LU's new size.
sub resize { my ($self) = @_; $self->_nyi('resize') }

# flush($identity). Flush buffered writes on the device (pre-detach hygiene).
sub flush { my ($self) = @_; $self->_nyi('flush') }

# device_path($identity) -> $path. Deterministic canonical identity -> /dev/mapper
# path mapping (no I/O).
sub device_path { my ($self) = @_; $self->_nyi('device_path') }

1;
