#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempfile);

use lib 'src';

# Install a CORE::GLOBAL::glob override BEFORE the module compiles so the
# find_device_paths glob('/sys/block/sd*/device/wwid') is interceptable per-test
# without touching production code (same technique as the reference suite).
our $glob_override;
BEGIN {
    *CORE::GLOBAL::glob = sub {
        return $glob_override->(@_) if defined $glob_override;
        return CORE::glob( $_[0] );
    };
}

use PVE::Storage::FCLU::Host::FCMultipath;

my $P = 'PVE::Storage::FCLU::Host::FCMultipath';

# ARCHITECTURE.md §3/§9: the vendor-neutral FC multipath connector. These tests
# pin the generalization (canonical-identity input, NO Hitachi OUI/vendor gate)
# and the carried-over taint-safe plumbing. They never touch real hardware —
# pure/validation logic and seams only, mirroring the reference multipath.t.

subtest 'is a Connector implementing the §3 surface' => sub {
    my $mp = $P->new;
    isa_ok( $mp, 'PVE::Storage::FCLU::Host::Connector', 'FCMultipath' );
    for my $m ( PVE::Storage::FCLU::Host::Connector->contract_methods ) {
        my $base = PVE::Storage::FCLU::Host::Connector->can($m);
        my $impl = $P->can($m);
        isnt( $impl, $base, "$m is implemented (not the base stub)" );
    }
    is( $P->new( timeout => 120 )->{timeout}, 120, 'custom timeout' );
};

subtest '_wwid_from_identity: naa preferred, prefixes stripped, lowercased' => sub {
    my $mp = $P->new;

    is( $mp->_wwid_from_identity( { ids => { naa => '60060E80ABCD' } } ),
        '60060e80abcd', 'naa from full identity, lowercased' );
    is( $mp->_wwid_from_identity( { ids => { naa => 'naa.60060e80AA', wwid => '0xdead' } } ),
        '60060e80aa', 'naa preferred over wwid; naa. prefix stripped' );
    is( $mp->_wwid_from_identity( { ids => { wwid => '0x60060e80BB' } } ),
        '60060e80bb', 'falls back to wwid; 0x stripped' );
    is( $mp->_wwid_from_identity('60060E8012'), '60060e8012', 'bare string accepted' );

    # EUI-only is rejected loudly (NAA-centric pipeline) rather than silently
    # mis-resolved into a wrong '3'-prefixed multipath path.
    eval { $mp->_wwid_from_identity( { ids => { eui => 'EUI123' } } ) };
    like( $@, qr/EUI-only identity is not supported/, 'eui-only identity rejected' );

    eval { $mp->_wwid_from_identity( { ids => {} } ) };
    like( $@, qr/carries no usable id/, 'identity with no ids croaks' );
    eval { $mp->_wwid_from_identity(undef) };
    like( $@, qr/identity is required/, 'undef identity croaks' );
};

subtest 'device_path maps a canonical identity to /dev/mapper/3<hex>' => sub {
    my $mp = $P->new;
    is( $mp->device_path( { ids => { naa => '60060e80123456780001000000000000' } } ),
        '/dev/mapper/360060e80123456780001000000000000',
        'identity -> 3-prefixed /dev/mapper path' );
    # _dm_wwid prefixing on a bare wwid, and the already-prefixed case.
    is( $mp->get_device_path('60060e8000'), '/dev/mapper/360060e8000', 'prefixes 3' );
    is( $mp->get_device_path('360060e8000'), '/dev/mapper/360060e8000', 'already prefixed' );
    eval { $mp->get_device_path() };
    like( $@, qr/wwid is required/, 'requires wwid' );
};

subtest 'the Hitachi WWID synthesis is gone' => sub {
    my $mp = $P->new;
    ok( !$mp->can('ldev_to_wwid'),   'ldev_to_wwid removed' );
    ok( !$mp->can('discover_wwid'),  'discover_wwid removed' );
    ok( !$mp->can('_assert_ldev_id'),'_assert_ldev_id removed' );
};

subtest 'find_device_paths matches by canonical id with NO OUI/vendor gate' => sub {
    my $mp = $P->new;

    my $run = sub {
        my ( $identity, %fs ) = @_;   # %fs: full sysfs path => file contents
        no warnings 'redefine';
        local $glob_override = sub {
            return grep { m{/sys/block/sd\w+/device/wwid$} } sort keys %fs;
        };
        local *PVE::Storage::FCLU::Host::FCMultipath::_read_first_line = sub {
            my ($path) = @_;
            return exists $fs{$path} ? $fs{$path} : undef;
        };
        return $mp->find_device_paths($identity);
    };

    my $naa = '60060e8000000000000000000106';

    # Hitachi-style device matches (0x prefix stripped, lowercased).
    my $r = $run->(
        { ids => { naa => $naa } },
        '/sys/block/sda/device/wwid'   => '0x60060E8000000000000000000106',
        '/sys/block/sda/device/vendor' => 'HITACHI',
    );
    is_deeply( $r, [ { sd => 'sda', wwid => $naa } ], 'matches a HITACHI device' );

    # CRITICAL generalization: a NON-Hitachi vendor + non-60060e80 OUI still
    # matches purely on the canonical id (the old code would have rejected both).
    my $pure = '624a9370abcdef00';
    $r = $run->(
        { ids => { naa => $pure } },
        '/sys/block/sda/device/wwid'   => "naa.$pure",
        '/sys/block/sda/device/vendor' => 'PURE',
    );
    is_deeply( $r, [ { sd => 'sda', wwid => $pure } ],
        'matches a PURE device with a non-Hitachi OUI (no vendor/OUI gate)' );

    # A different id does not match.
    $r = $run->(
        { ids => { naa => $naa } },
        '/sys/block/sda/device/wwid'   => '60060e8000000000000000009999',
        '/sys/block/sda/device/vendor' => 'HITACHI',
    );
    is_deeply( $r, [], 'non-matching id => no device' );

    # Two paths to the same LUN -> deduped per sd device, both kept (distinct sd).
    $r = $run->(
        { ids => { naa => $naa } },
        '/sys/block/sda/device/wwid' => $naa,
        '/sys/block/sdb/device/wwid' => $naa,
    );
    is_deeply(
        [ sort map { $_->{sd} } @$r ],
        [ 'sda', 'sdb' ],
        'both paths to the LUN are reported (one entry per sd device)',
    );
};

subtest 'whitelist_wwid runs multipath -a with the 3-prefixed wwid' => sub {
    my $mp = $P->new;

    eval { $mp->whitelist_wwid() };
    like( $@, qr/wwid is required/, 'requires wwid' );

    my @calls;
    no warnings 'redefine';
    local *PVE::Storage::FCLU::Host::FCMultipath::_run_cmd = sub { push @calls, [@_]; return ''; };

    my $dm = $mp->whitelist_wwid('60060e80123456780001000000000000');
    is( $dm, '360060e80123456780001000000000000', 'returns 3-prefixed dm wwid' );
    is_deeply( $calls[0], [ 'multipath', '-a', '360060e80123456780001000000000000' ],
        'multipath -a with the 3-prefixed wwid' );

    # Best-effort: a failing multipath -a must only warn, not die.
    local *PVE::Storage::FCLU::Host::FCMultipath::_run_cmd = sub { die "rc=1\n" };
    local $SIG{__WARN__} = sub { };
    my $ok = eval { $mp->whitelist_wwid('60060e80aa'); 1 };
    ok( $ok, 'whitelist_wwid does not die when multipath -a fails' );
};

subtest '_prune_wwid_entries removes all freed-wwid lines, keeps others' => sub {
    my $mp = $P->new;
    my ( $fh, $path ) = tempfile( UNLINK => 1 );
    print $fh <<'WWIDS';
# Multipath wwids, Version : 1.0
#360060e8021a789005060a78900000104/
/360060e8021a789005060a78900000104/
#360060e8021a789005060a78900000104/
/360060e8021a789005060a78900000107/
WWIDS
    close($fh);

    $mp->_prune_wwid_entries( '360060e8021a789005060a78900000104', $path );

    open( my $rd, '<', $path ) or die "reopen: $!";
    my $content = join( '', <$rd> );
    close($rd);
    unlike( $content, qr/00000104/, 'freed-wwid lines removed (commented + active + dups)' );
    like( $content, qr{/360060e8021a789005060a78900000107/}, 'other LUN entry preserved' );
    like( $content, qr/Version/, 'header preserved' );

    ok( eval { $mp->_prune_wwid_entries( '360060e80abc', '/nonexistent/wwids' ); 1 },
        'missing file is a no-op' );
    ok( eval { $mp->_prune_wwid_entries( 'not-hex!', $path ); 1 },
        'invalid wwid is a no-op' );
};

subtest 'host_context: scsi-fc + local initiators + hostname' => sub {
    my $mp = $P->new;
    no warnings 'redefine';
    local *PVE::Storage::FCLU::Host::FCMultipath::get_local_wwns = sub { [ '10000000c9aa', '10000000c9bb' ] };

    my $ctx = $mp->host_context( hostname => 'pve-node-3' );
    is( $ctx->{hostname}, 'pve-node-3', 'hostname passed through' );
    is( $ctx->{protocol}, 'scsi-fc',    'protocol is scsi-fc' );
    is_deeply( $ctx->{initiators}, [ '10000000c9aa', '10000000c9bb' ], 'initiators from get_local_wwns' );

    local *PVE::Storage::FCLU::Host::FCMultipath::_local_hostname = sub { undef };
    eval { $mp->host_context() };
    like( $@, qr/hostname is required/, 'croaks when hostname is undeterminable' );
};

subtest 'attach/detach/resize/flush translate identity -> bare wwid' => sub {
    my $mp = $P->new;
    my %got;
    my @order;
    no warnings 'redefine';
    # attach MUST rescan the SCSI hosts before waiting, else a just-published LUN
    # never appears (live-found on the E590H).
    local *PVE::Storage::FCLU::Host::FCMultipath::rescan_scsi_hosts = sub { push @order, 'rescan'; $got{rescan}++ };
    local *PVE::Storage::FCLU::Host::FCMultipath::wait_for_device = sub { push @order, 'wait'; $got{attach} = $_[1]; '/dev/mapper/3x' };
    local *PVE::Storage::FCLU::Host::FCMultipath::remove_device   = sub { $got{detach} = $_[1]; 1 };
    local *PVE::Storage::FCLU::Host::FCMultipath::resize_device   = sub { $got{resize} = $_[1]; 1 };
    local *PVE::Storage::FCLU::Host::FCMultipath::flush_device    = sub { $got{flush}  = $_[1]; 1 };

    my $id = { ids => { naa => '60060E80FF' } };
    is( $mp->attach($id), '/dev/mapper/3x', 'attach returns the device path' );
    $mp->detach($id);
    $mp->resize($id);
    $mp->flush($id);
    is( $got{attach}, '60060e80ff', 'attach got the bare lowercased wwid' );
    is( $got{detach}, '60060e80ff', 'detach translated identity' );
    is( $got{resize}, '60060e80ff', 'resize translated identity' );
    is( $got{flush},  '60060e80ff', 'flush translated identity' );
    is( $got{rescan}, 1, 'attach rescanned the SCSI hosts' );
    is_deeply( \@order, [ 'rescan', 'wait' ], 'rescan happens BEFORE waiting for the device' );

    # A volume allocated but never activated has no usable device id — detach must
    # be a no-op success (so free_image can still tear it down).
    delete $got{detach};
    is( $mp->detach( { ids => {} } ), 1, 'detach of a null-identity volume is a no-op success' );
    ok( !exists $got{detach}, 'no remove_device call for a null identity' );
};

subtest 'check_pr_ready validate-and-warn with vendor-neutral wording' => sub {
    my $mp = $P->new;
    no warnings 'redefine';
    no strict 'refs';

    { local *{"${P}::_pr_helper_active"} = sub { 1 };
      local *{"${P}::_multipath_reservation_key_configured"} = sub { 1 };
      my $r = $mp->check_pr_ready('3abc');
      is( $r->{ok}, 1, 'ready when both prerequisites present' );
      is_deeply( $r->{issues}, [], 'no issues when ready' ); }

    { local *{"${P}::_pr_helper_active"} = sub { 0 };
      local *{"${P}::_multipath_reservation_key_configured"} = sub { 0 };
      my $r = $mp->check_pr_ready('x');
      is( $r->{ok}, 0, 'not ready when both missing' );
      is( scalar @{ $r->{issues} }, 2, 'both issues reported' );
      my $all = join( "\n", @{ $r->{issues} } );
      like( $all, qr/qemu-pr-helper/,  'names qemu-pr-helper' );
      like( $all, qr/reservation_key/, 'names reservation_key' );
      unlike( $all, qr/HITACHI|OPEN-V/, 'advisory wording is vendor-neutral' ); }
};

subtest '_multipath_reservation_key_configured parses multipathd config' => sub {
    my $mp = $P->new;
    no warnings 'redefine';
    no strict 'refs';

    local *{"${P}::_run_cmd"} = sub { "defaults {\n\treservation_key 0x123456789abcdef0\n}\n" };
    is( $mp->_multipath_reservation_key_configured(), 1, 'configured hex key' );
    local *{"${P}::_run_cmd"} = sub { qq(defaults {\n\treservation_key "0"\n}\n) };
    is( $mp->_multipath_reservation_key_configured(), 0, 'reservation_key "0" = disabled' );
    local *{"${P}::_run_cmd"} = sub { "defaults {\n\tpolling_interval 5\n}\n" };
    is( $mp->_multipath_reservation_key_configured(), 0, 'absent directive = not configured' );
    local *{"${P}::_run_cmd"} = sub { die "multipathd not running\n" };
    is( $mp->_multipath_reservation_key_configured(), 0, 'command failure = not configured (no die)' );
};

subtest '_run_cmd refuses invalid/tainted arguments' => sub {
    eval { PVE::Storage::FCLU::Host::FCMultipath::_run_cmd( 'multipath', 'bad arg; rm -rf' ) };
    like( $@, qr/refusing to exec invalid\/tainted argument/, 'shell-metachar argument refused' );
};

done_testing();
