package PVE::Storage::FCLU::Host::FCMultipath;

use strict;
use warnings;

use POSIX ();
use Carp qw(croak);

use PVE::Storage::FCLU::Host::Connector;
use parent -norequire, 'PVE::Storage::FCLU::Host::Connector';

# Vendor-neutral FC + device-mapper-multipath host connector (ARCHITECTURE.md
# §3, §9 Phase 1 step 2). Ported from the Hitachi Multipath.pm, which was already
# almost entirely generic host plumbing. TWO Hitachi-specific things were DELETED
# (consensus, §3):
#
#   * ldev_to_wwid() — WWID *synthesis* from OUI 60060e80 + serial + ldev. The
#     driver's get_lu_identity() is now the single source of truth for the
#     canonical device id; the host side never fabricates one.
#   * discover_wwid()'s 60060e80-OUI + "HITACHI"-vendor filtering. Page-83
#     matching is now generic: any vendor's device whose canonical id matches is
#     accepted (more robust than synthesis, and what makes a second vendor cheap).
#
# The connector speaks the §3 interface (host_context/attach/detach/resize/flush/
# device_path) in terms of a CANONICAL identity (§12.1: { ids => { naa, eui, wwid }})
# and translates it to a multipath WWID exactly once, in _wwid_from_identity. The
# lower-level helpers still operate on a bare/3-prefixed wwid so their tested,
# taint-safe behaviour carries over verbatim.

my $DEVICE_TIMEOUT = 60;
my $POLL_INTERVAL  = 2;

sub new {
    my ($class, %opts) = @_;

    return bless {
        timeout => $opts{timeout} || $DEVICE_TIMEOUT,
    }, $class;
}

# ── Canonical identity → multipath WWID ──
#
# The ONE place the §12.1 identity becomes a device-mapper wwid. Accepts the full
# identity hash, its inner ids hash, or a bare id string (convenience). Prefers
# the array-reported NAA, then an explicit page-83 wwid (naa is the canonical raw
# descriptor; a driver supplying a dm-form '3...' wwid still survives _dm_wwid).
# Strips the naa./0x page-83 prefixes and lowercases. Returns the bare hex id.
#
# This pipeline is NAA-centric end to end: _dm_wwid hardcodes the multipath '3'
# (NAA) prefix and find_device_paths strips only naa./0x. A true EUI-64 device
# uses the multipath '2' prefix and an 'eui.' page-83 form, so an eui-ONLY
# identity is rejected loudly here rather than silently mis-resolved — EUI support
# is deferred until a driver that needs it lands (§3 reserves nvme/iscsi too).
sub _wwid_from_identity {
    my ($self, $identity) = @_;

    my $id;
    if ( ref $identity eq 'HASH' ) {
        my $ids = ( ref $identity->{ids} eq 'HASH' ) ? $identity->{ids} : $identity;
        $id = $ids->{naa} // $ids->{wwid};
        unless ( defined $id && length $id ) {
            croak "FC multipath connector needs a naa or page-83 wwid; "
                . ( defined $ids->{eui}
                    ? "an EUI-only identity is not supported yet"
                    : "identity carries no usable id" );
        }
    } else {
        croak "identity is required" unless defined $identity && length $identity;
        $id = $identity;
    }

    $id =~ s/^naa\.//i;
    $id =~ s/^0x//i;
    return lc($id);
}

# ── Validation / untaint helpers (issue #19) ──
#
# Array-sourced values (WWIDs) and the device paths derived from them flow into
# host-side tools (multipath, multipathd, blockdev) and sysfs. Validate them
# against strict patterns at the boundary so a malformed value is rejected with an
# actionable error instead of reaching an external tool. _run_cmd() is the final
# argv-untaint backstop; this gives a precise early error and normalises the WWID.

# Normalise + validate a device WWID to the multipath '3<naa-hex>' form. Accepts
# the bare id (e.g. 60060e80...) or an already-'3'-prefixed id; both must be pure
# hex. Returns the untainted '3<hex>' string; croaks on anything else.
sub _dm_wwid {
    my ($self, $wwid) = @_;

    croak "wwid is required" unless defined $wwid && $wwid ne '';
    my $dm = $wwid =~ /^3/ ? $wwid : "3$wwid";
    $dm =~ /^(3[0-9a-fA-F]+)\z/
        or croak "invalid device WWID '$wwid' (expected a hex NAA identifier)";
    return $1;
}

# ── §3 connector interface ──

# This node's identity for host-access methods (§12.1 %host_ctx). hostname is
# supplied by the caller (the plugin knows the PVE nodename); protocol is fixed
# scsi-fc for this connector; initiators are the local FC WWPNs.
sub host_context {
    my ($self, %opts) = @_;

    my $hostname = $opts{hostname} // $self->_local_hostname();
    croak "hostname is required (pass hostname => ... or run on a PVE node)"
        unless defined $hostname && length $hostname;

    return {
        hostname   => $hostname,
        protocol   => 'scsi-fc',
        initiators => $self->get_local_wwns(),
    };
}

sub device_path {
    my ($self, $identity) = @_;
    return $self->get_device_path( $self->_wwid_from_identity($identity) );
}

sub attach {
    my ($self, $identity, $timeout) = @_;
    return $self->wait_for_device( $self->_wwid_from_identity($identity), $timeout );
}

sub detach {
    my ($self, $identity) = @_;
    return $self->remove_device( $self->_wwid_from_identity($identity) );
}

sub resize {
    my ($self, $identity) = @_;
    return $self->resize_device( $self->_wwid_from_identity($identity) );
}

sub flush {
    my ($self, $identity) = @_;
    return $self->flush_device( $self->_wwid_from_identity($identity) );
}

# Seam: this node's PVE nodename, or undef off-cluster (tests pass hostname).
sub _local_hostname {
    my ($self) = @_;
    return eval { require PVE::INotify; PVE::INotify::nodename() };
}

# ── FC WWN discovery ──

sub get_local_wwns {
    my ($self) = @_;

    my @wwns;
    my @hosts = glob('/sys/class/fc_host/host*');

    for my $host_path (@hosts) {
        my $port_name_file = "$host_path/port_name";
        next unless -r $port_name_file;

        open( my $fh, '<', $port_name_file ) or next;
        my $wwn = <$fh>;
        close($fh);

        chomp($wwn);
        # port_name is typically "0x50060b0000c26040" — strip the 0x prefix.
        $wwn =~ s/^0x//i;
        push @wwns, lc($wwn) if $wwn;
    }

    return \@wwns;
}

# ── SCSI rescan ──

sub rescan_scsi_hosts {
    my ($self, %opts) = @_;

    my @hosts = glob('/sys/class/scsi_host/host*');
    croak "No SCSI hosts found" unless @hosts;

    for my $host_path (@hosts) {
        # glob() returns TAINTED paths; pct runs in taint mode (-T), which forbids
        # write-open on tainted data. Untaint by validating the sysfs shape.
        next unless $host_path =~ m{^(/sys/class/scsi_host/host\d+)\z};
        my $scan_file = "$1/scan";
        next unless -w $scan_file;

        open( my $fh, '>', $scan_file ) or next;
        print $fh "- - -\n";
        close($fh);
    }

    _run_cmd( 'udevadm', 'settle', '--timeout=10' );

    return 1;
}

sub rescan_scsi_targeted {
    my ($self, $hctl) = @_;

    # hctl format: "host:channel:target:lun" e.g. "3:0:0:5".
    croak "hctl is required" unless $hctl;

    my ( $host, $channel, $target, $lun ) = split( /:/, $hctl );
    # Untaint the host number (taint mode forbids write-open with tainted data).
    ($host) = ( $host // '' ) =~ /^(\d+)$/
        or croak "invalid host in hctl '$hctl'";
    my $scan_file = "/sys/class/scsi_host/host${host}/scan";

    if ( -w $scan_file ) {
        open( my $fh, '>', $scan_file ) or croak "Cannot write to $scan_file: $!";
        print $fh "$channel $target $lun\n";
        close($fh);
    }

    _run_cmd( 'udevadm', 'settle', '--timeout=10' );

    return 1;
}

# ── Device path resolution ──

sub wait_for_device {
    my ($self, $wwid, $timeout) = @_;

    $timeout //= $self->{timeout};
    my $path = $self->get_device_path($wwid);

    # Whitelist the WWID and (re)assemble the map up front. PVE ships multipath
    # with `find_multipaths strict` by default, where ONLY WWIDs explicitly listed
    # in /etc/multipath/wwids are turned into /dev/mapper devices — so without this
    # the device would never appear, even with all paths present.
    $self->whitelist_wwid($wwid);
    eval { _run_cmd( 'multipath', '-r' ) };

    my $elapsed = 0;
    while ( $elapsed < $timeout ) {
        if ( -e $path ) {
            eval { _run_cmd( 'multipathd', 'reconfigure' ) };
            return $path if -e $path;
        }

        sleep($POLL_INTERVAL);
        $elapsed += $POLL_INTERVAL;

        eval { _run_cmd( 'multipath', '-r' ) } if $elapsed % 6 == 0;
    }

    croak "Device $path did not appear within ${timeout}s";
}

# Whitelist a device WWID with multipath-tools (append to /etc/multipath/wwids) so
# it is assembled into a /dev/mapper device even under `find_multipaths strict`.
# Idempotent and best-effort: `multipath -a` can exit non-zero when the entry
# already exists or the device is not yet visible, which must not be fatal.
sub whitelist_wwid {
    my ($self, $wwid) = @_;

    my $dm_wwid = $self->_dm_wwid($wwid);

    eval { _run_cmd( 'multipath', '-a', $dm_wwid ) };
    warn "multipath -a $dm_wwid warning: $@" if $@;

    return $dm_wwid;
}

sub get_device_path {
    my ($self, $wwid) = @_;

    # _dm_wwid validates (hex only) and untaints: the wwid is tainted (registry /
    # syssfs), and PVE runs mkfs/mount on this path via exec, which dies "Insecure
    # dependency" under pct's taint mode if the path is tainted.
    my $dm_wwid = $self->_dm_wwid($wwid);

    return "/dev/mapper/$dm_wwid";
}

sub get_device_size {
    my ($self, $path) = @_;

    croak "path is required" unless $path;
    # Only ever query our own multipath devices; validate + untaint the path so a
    # malformed value never reaches blockdev.
    $path =~ m{^(/dev/mapper/3[0-9a-fA-F]+)\z}
        or croak "refusing to query non-multipath device path '$path'";
    $path = $1;
    croak "Device $path not found" unless -e $path;

    my $size = _run_cmd( 'blockdev', '--getsize64', $path );
    chomp($size);

    return int($size);
}

# ── Device lifecycle ──

sub remove_device {
    my ($self, $wwid) = @_;

    my $dm_wwid = $self->_dm_wwid($wwid);

    # Flush multipath map.
    eval { _run_cmd( 'multipath', '-f', $dm_wwid ) };

    # Drop the WWID from /etc/multipath/wwids so the whitelist does not accumulate
    # stale entries (best-effort: -w is unavailable on older multipath-tools).
    # `multipath -w` only COMMENTS the entry, and repeated activate/free cycles
    # leave accumulating duplicate "#<wwid>" lines — prune them (the LUN is gone).
    eval { _run_cmd( 'multipath', '-w', $dm_wwid ) };
    eval { $self->_prune_wwid_entries($dm_wwid) };

    # Find and remove the underlying SCSI devices by matching the canonical id.
    my @sd_devs = glob("/sys/block/sd*/device/wwid");
    for my $wwid_file (@sd_devs) {
        open( my $fh, '<', $wwid_file ) or next;
        my $dev_wwid = <$fh>;
        close($fh);
        chomp($dev_wwid);

        if ( $dev_wwid =~ /\Q$wwid\E/i ) {
            my ($sd_name) = $wwid_file =~ m{/sys/block/(sd\w+)/};
            next unless $sd_name;

            my $delete_file = "/sys/block/$sd_name/device/delete";
            if ( -w $delete_file ) {
                open( my $dfh, '>', $delete_file ) or next;
                print $dfh "1\n";
                close($dfh);
            }
        }
    }

    # Let the kernel finish tearing the paths down before the caller unmaps on the
    # array: while the SCSI devices are still draining, the array reports "the LU
    # is executing host I/O" and refuses the unmap. Settling here shrinks that
    # window so the unmap retry loop succeeds sooner.
    eval { _run_cmd( 'udevadm', 'settle', '--timeout=10' ) };

    return 1;
}

# Remove every /etc/multipath/wwids line referencing $wwid (commented or active).
# `multipath -w` comments the entry instead of deleting it, so repeated
# activate/free cycles pile up duplicate "#<wwid>/" lines; once the LUN is freed
# the entry is pure cruft. Best-effort, atomic, taint-safe (the path is a constant
# and the wwid is validated to hex before use).
sub _prune_wwid_entries {
    my ($self, $wwid, $file) = @_;

    $file //= '/etc/multipath/wwids';
    return unless defined $wwid && $wwid =~ /^3?([0-9a-fA-F]+)$/;
    my $bare = $1;
    return unless -f $file && -w $file;

    open( my $in, '<', $file ) or return;
    my @keep = grep { !/\Q$bare\E/ } <$in>;
    close($in);

    my $tmp = "$file.tmp.$$";
    open( my $out, '>', $tmp ) or return;
    print $out @keep;
    close($out);
    rename( $tmp, $file ) or unlink($tmp);

    return 1;
}

sub resize_device {
    my ($self, $wwid) = @_;

    my $dm_wwid = $self->_dm_wwid($wwid);

    # Rescan all SCSI paths for this device to pick up the new size.
    my @sd_devs = glob("/sys/block/sd*/device/wwid");
    for my $wwid_file (@sd_devs) {
        open( my $fh, '<', $wwid_file ) or next;
        my $dev_wwid = <$fh>;
        close($fh);
        chomp($dev_wwid);

        if ( $dev_wwid =~ /\Q$wwid\E/i ) {
            my ($sd_name) = $wwid_file =~ m{/sys/block/(sd\w+)/};
            next unless $sd_name;

            my $rescan_file = "/sys/block/$sd_name/device/rescan";
            if ( -w $rescan_file ) {
                open( my $rfh, '>', $rescan_file ) or next;
                print $rfh "1\n";
                close($rfh);
            }
        }
    }

    # Tell multipathd to resize the DM device.
    _run_cmd( 'multipathd', 'resize', 'map', $dm_wwid );

    return 1;
}

sub flush_device {
    my ($self, $wwid) = @_;

    my $dm_wwid = $self->_dm_wwid($wwid);

    my $path = "/dev/mapper/$dm_wwid";
    if ( -e $path ) {
        eval { _run_cmd( 'blockdev', '--flushbufs', $path ) };
        warn "blockdev flush warning: $@" if $@;
    }

    return 1;
}

# ── Generic page-83 device matching (replaces the Hitachi discover_wwid) ──

# Find the sysfs SCSI devices whose page-83 identifier matches a canonical
# identity, returning a deduped arrayref of { sd, wwid }. This is the GENERIC
# replacement for the old discover_wwid: NO OUI gate, NO vendor gate — it matches
# purely on the driver-reported canonical id, so any vendor's array works. Returns
# [] when no path is visible yet.
sub find_device_paths {
    my ($self, $identity) = @_;

    my $want = $self->_wwid_from_identity($identity);

    my %seen;
    my @found;
    for my $wwid_file ( glob('/sys/block/sd*/device/wwid') ) {
        my ($sd_name) = $wwid_file =~ m{/sys/block/(sd\w+)/};
        next unless $sd_name;

        my $wwid = _read_first_line($wwid_file);
        next unless defined $wwid;
        $wwid =~ s/^naa\.//i;
        $wwid =~ s/^0x//i;
        $wwid = lc($wwid);

        next unless $wwid eq $want;

        push @found, { sd => $sd_name, wwid => $wwid } unless $seen{$sd_name}++;
    }

    return \@found;
}

# ── Internal helpers ──

sub _read_first_line {
    my ($file) = @_;
    open( my $fh, '<', $file ) or return undef;
    my $line = <$fh>;
    close($fh);
    return undef unless defined $line;
    chomp($line);
    return $line;
}

# ── SCSI-3 Persistent Reservation readiness (issue #2) ──

# Default qemu-pr-helper socket (a package var so tests can localise it). QEMU
# forwards a guest's PERSISTENT RESERVE IN/OUT to this helper, which executes them
# against the real device.
our $PR_HELPER_SOCK = '/run/qemu-pr-helper.sock';

# Read-only check that this node's host-side SCSI-3 PR plumbing is ready to serve a
# clustered guest on the given multipath device. Returns
#   { ok => 0|1, issues => [ actionable message, ... ] }.
# It NEVER mutates anything — only inspects — so an opt-in PR path can warn and let
# the operator fix it. $wwid is accepted for the caller's logging context; the two
# prerequisites are node-level.
sub check_pr_ready {
    my ($self, $wwid) = @_;

    my @issues;
    unless ( $self->_pr_helper_active() ) {
        push @issues, "qemu-pr-helper is not running on this node, so a guest's"
            . " SCSI-3 PR commands cannot be serviced — enable it with"
            . " 'systemctl enable --now qemu-pr-helper.socket'";
    }
    unless ( $self->_multipath_reservation_key_configured() ) {
        push @issues, "multipath reservation_key is not configured, so a persistent"
            . " reservation will not survive path failover — set reservation_key in"
            . " multipath.conf (defaults{} globally, or your array's devices{}"
            . " section) and reload multipathd";
    }

    return { ok => ( @issues ? 0 : 1 ), issues => \@issues };
}

# Seam: is the qemu-pr-helper socket present/listening on this node?
sub _pr_helper_active {
    my ($self) = @_;
    return ( -S $PR_HELPER_SOCK ) ? 1 : 0;
}

# Seam: does multipathd's effective config carry a usable (non-disabled)
# reservation_key that would apply to our devices? Read-only parse of `multipathd
# show config`; multipathd prints reservation_key "0" (or omits it) when
# unset/disabled. Coarse/node-level by design: any non-zero reservation_key line
# counts as configured, so the worst case is a false "ready" — never a false "not
# ready" that would block — the right bias for validate-and-warn.
sub _multipath_reservation_key_configured {
    my ($self) = @_;

    my $cfg = eval { _run_cmd( 'multipathd', 'show', 'config' ) };
    return 0 unless defined $cfg;
    for my $line ( split /\n/, $cfg ) {
        next unless $line =~ /^\s*reservation_key\s+"?([^"\s]+)"?/;
        my $val = $1;
        return 1 if $val ne '0' && lc($val) ne 'none';
    }
    return 0;
}

sub _run_cmd {
    my (@cmd) = @_;

    # Taint safety: pct runs the storage layer in taint mode (-T), which refuses
    # exec with a tainted $ENV{PATH} or tainted argv. Use a known-good PATH and
    # untaint each argument against a conservative charset. These are internal
    # command names, flags, device paths and WWIDs we construct — never user
    # free-text — so validating the shape is sufficient.
    local $ENV{PATH} = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin';
    delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};
    @cmd = map {
        $_ =~ /^([\w\@%+=:,.\/-]+)$/
            ? $1
            : croak "refusing to exec invalid/tainted argument: $_";
    } @cmd;

    # Execute without a shell (list form) to avoid quoting/injection issues and to
    # capture combined stdout/stderr reliably.
    my $pid = open( my $fh, '-|' );
    croak "Cannot fork for '@cmd': $!" unless defined $pid;

    my $output = '';
    if ($pid) {
        local $/;
        my $data = <$fh>;
        $output = $data if defined $data;
        close($fh);
    } else {
        open( STDERR, '>&', \*STDOUT );
        # _exit (not die/exit) avoids running parent destructors if exec fails.
        { exec { $cmd[0] } @cmd };
        print "exec '$cmd[0]' failed: $!";
        POSIX::_exit(127);
    }

    my $rc = $? >> 8;
    croak "Command '@cmd' failed (rc=$rc): $output" if $rc != 0;

    return $output;
}

1;
