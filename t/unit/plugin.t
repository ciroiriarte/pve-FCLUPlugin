#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);

# ── Minimal PVE stubs so FCLU::Plugin compiles standalone (mirrors the reference
# plugin.t): the real PVE::Storage framework is not installed in CI. ──
BEGIN {
    $INC{'PVE/Storage/Plugin.pm'} = 1;
    package PVE::Storage::Plugin;
    sub api { 0 }
    # Storage-migration stream helpers (real ones live in PVE::Storage::Plugin).
    our @HDR;
    sub write_common_header { my ( $fh, $size ) = @_; push @HDR, $size; return; }
    sub read_common_header  { return $main::IMPORT_SIZE // 0; }
    # Free-name helper (inherited from PVE::Storage::Plugin in production).
    sub find_free_diskname { my ( $class, $storeid, $scfg, $vmid, $fmt ) = @_; return "vm-${vmid}-disk-7"; }
    # SUPER::cluster_lock_storage stub: record the resolved timeout, then run $func.
    our @LOCK_TIMEOUTS;
    sub cluster_lock_storage {
        my ( $class, $storeid, $shared, $timeout, $func, @param ) = @_;
        push @LOCK_TIMEOUTS, $timeout;
        return $func ? $func->(@param) : $timeout;
    }
    package PVE::Storage;
    sub APIVER { 11 }
    # storage.cfg accessor stub for cluster_lock_storage's lock_timeout lookup.
    sub config { return { ids => ( $main::PVE_STORAGE_IDS // {} ) } }
    package PVE::Tools;
    $INC{'PVE/Tools.pm'} = 1;
    our @CMDS;
    sub run_command { my ( $cmd, %o ) = @_; push @CMDS, $cmd; return 0; }
}

use lib 'src';
use PVE::Storage::FCLU::Plugin;

# A stateful fake array driver (the §2 surface the plugin calls in slices 4A/4B).
{
    package T::FakeDriver;
    # Backend ids are globally monotonic (like real, unique array LDEV ids) so ids
    # from different driver instances never collide in the shared registry tempdir.
    our $SEQ = 1000;
    sub new { bless { connected => 0, status => $_[1], lus => {}, calls => {} }, $_[0] }
    sub connect    { $_[0]{connected} = 1; $_[0] }
    sub disconnect { $_[0]{calls}{disconnect}++; $_[0]{connected} = 0; 1 }
    sub storage_status { my ($s) = @_; die "BOOM status\n" if $s->{fail_status}; @{ $s->{status} // [ 1000, 600, 400 ] } }
    sub detect_profile { { max_label_len => 32 } }
    sub _id { my $s = shift; my $n = $_[0]; return defined $n ? "$n" : '' . ++$SEQ; }
    sub create_lu {
        my ( $s, %o ) = @_; $s->{calls}{create_lu}++;
        die "BOOM create\n" if $s->{fail_create};
        my $bid = $s->_id( $o{requested_id} );
        $s->{lus}{$bid} = { backend_id => $bid, size_bytes => $o{size_bytes}, pool_ref => $o{pool_ref},
            identity => { protocol => 'scsi-fc', ids => { naa => '60060e80' . sprintf( '%08x', $SEQ ) } } };
        return $bid;
    }
    sub get_lu { my ( $s, $id ) = @_; $s->{lus}{$id} or die "API request failed: GET x -> 404\n"; return { %{ $s->{lus}{$id} } } }
    sub get_lu_identity { my ( $s, $id ) = @_; $s->{lus}{$id} or die "404\n"; return $s->{lus}{$id}{identity} }
    sub set_lu_label { my ( $s, $id, $l ) = @_; $s->{calls}{set_lu_label}++; die "BOOM label\n" if $s->{fail_label}; $s->{lus}{$id}{label} = $l if $s->{lus}{$id}; 1 }
    sub set_lu_qos   { my ( $s ) = @_; $s->{calls}{set_lu_qos}++; 1 }
    sub delete_lu    { my ( $s, $id ) = @_; $s->{calls}{delete_lu}++; delete $s->{lus}{$id}; 1 }
    sub resize_lu    { my ( $s, $id, $new ) = @_; $s->{calls}{resize_lu}++;
        $s->{lus}{$id}{size_bytes} = $new if $s->{lus}{$id} && $new > $s->{lus}{$id}{size_bytes}; 1 }
    sub capabilities { { snapshot => { single => 1 }, clone => { linked => 1 }, copy => {}, qos => {}, resize => {}, transfer => {}, replication => {} } }
    # Stateful snapshots: $s->{snaps}{$pvol} = [ { snap_id, group, svol, status } ].
    sub _snap_descr { my ( $s, $bid, $p ) = @_;
        { snap_id => $p->{snap_id}, parent_backend_id => "$bid", created => undef,
          meta => { group => $p->{group}, status => $p->{status}, svol => $p->{svol} } } }
    sub create_snapshot {
        my ( $s, $bid, %o ) = @_; $s->{calls}{create_snapshot}++;
        my $svol = '' . ++$SEQ;
        my $p = { snap_id => "$bid," . scalar( @{ $s->{snaps}{$bid} // [] } ),
            group => $o{snapshot_group}, svol => $svol, status => 'PSUS' };
        push @{ $s->{snaps}{$bid} }, $p;
        return $s->_snap_descr( $bid, $p );
    }
    sub list_snapshots { my ( $s, $bid ) = @_; $s->{calls}{list_snapshots}++;
        [ map { $s->_snap_descr( $bid, $_ ) } @{ $s->{snaps}{$bid} // [] } ] }
    sub delete_snapshot { my ( $s, $sid ) = @_; $s->{calls}{delete_snapshot}++;
        for my $bid ( keys %{ $s->{snaps} } ) {
            @{ $s->{snaps}{$bid} } = grep { $_->{snap_id} ne $sid } @{ $s->{snaps}{$bid} };
        }
        1 }
    sub restore_snapshot { my ( $s ) = @_; $s->{calls}{restore_snapshot}++; 1 }
    sub create_linked_clone {
        my ( $s, $src, %o ) = @_; $s->{calls}{create_linked_clone}++;
        $s->{last_clone_hctx} = $o{host_ctx};
        die "BOOM clone\n" if $s->{fail_clone};
        my $svol = $s->_id( $o{requested_id} );
        # Back the clone with a CoW pair on the source carrying this svol, so the
        # core can discover the backing pair (meta.svol) for the #23 release.
        push @{ $s->{snaps}{$src} }, { snap_id => "$src,lc$SEQ",
            group => "pve_lc_$svol", svol => $svol, status => 'PSUS' };
        $s->{lus}{$svol} = { backend_id => $svol,
            size_bytes => ( $s->{lus}{$src} ? $s->{lus}{$src}{size_bytes} : 1 << 30 ),
            pool_ref => $o{pool_ref}, identity => { protocol => 'scsi-fc',
                ids => { naa => '60060e80' . sprintf( '%08x', $SEQ ) } } };
        return $svol;
    }
    sub ensure_host_access { my ( $s, %c ) = @_; $s->{calls}{ensure_host_access}++; "PVE_$c{hostname}" }
    sub publish_lu   { my ( $s, $id, %c ) = @_; $s->{calls}{publish_lu}++; { hostname => $c{hostname}, access_ref => "PVE_$c{hostname}" } }
    sub unpublish_lu { my ( $s ) = @_; $s->{calls}{unpublish_lu}++; 1 }
    sub unpublish_lu_all { my ( $s, $id ) = @_; $s->{calls}{unpublish_lu_all}++; 1 }
}

# A fake host connector.
{
    package T::FakeConn;
    sub new { bless { calls => {} }, shift }
    sub host_context { my ( $s, %o ) = @_; { hostname => $o{hostname}, protocol => 'scsi-fc', initiators => ['10000000c9aa'] } }
    sub attach      { my ( $s, $id ) = @_; $s->{calls}{attach}++; '/dev/mapper/3' . $id->{ids}{naa} }
    sub detach      { my ( $s ) = @_; $s->{calls}{detach}++; 1 }
    sub flush       { my ( $s ) = @_; $s->{calls}{flush}++; 1 }
    sub resize      { my ( $s ) = @_; $s->{calls}{resize}++; 1 }
    sub device_path { my ( $s, $id ) = @_; my $naa = $id->{ids}{naa};
        die "no usable device id\n" unless defined $naa && length $naa; '/dev/mapper/3' . $naa }
    sub check_pr_ready { my ( $s, $id ) = @_; $s->{calls}{check_pr_ready}++; return $s->{pr_result} // { ok => 1, issues => [] }; }
}

# A concrete vendor subclass providing the abstract hooks + injecting the fakes.
{
    package T::Plugin;
    use parent -norequire, 'PVE::Storage::FCLU::Plugin';
    our $FAKE;
    our $CONN;
    sub type          { 'testblock' }
    sub vendor        { 'test' }
    sub driver_class  { 'T::FakeDriver' }
    sub driver_config { { platform => 'vsp_e', pool_id => '63' } }
    sub _build_driver { return $FAKE //= T::FakeDriver->new }
    sub _connector    { return $CONN //= T::FakeConn->new }
    sub _nodename     { 'node-x' }
}

my $P = 'T::Plugin';

# Redirect the registry store to a tempdir for every test.
my $dir = tempdir( CLEANUP => 1 );
$PVE::Storage::FCLU::Plugin::REGISTRY_BASE_DIR = $dir;
$PVE::Storage::FCLU::Plugin::CREDS_BASE_DIR    = $dir;

sub reg { return PVE::Storage::FCLU::Registry->new( storeid => 'store1', base_dir => $dir ) }

subtest 'identity: api mirrors host APIVER (clamped); plugindata; abstract hooks' => sub {
    is( PVE::Storage::FCLU::Plugin->api, 11, 'api mirrors the host APIVER within range' );
    my $pd = PVE::Storage::FCLU::Plugin->plugindata;
    ok( $pd->{content}[0]{images}, 'images content advertised' );
    is_deeply( $pd->{'sensitive-properties'}, { password => 1 }, 'password is sensitive' );

    # The bare base must croak on every vendor hook.
    for my $hook (qw(type vendor driver_class driver_config)) {
        eval { PVE::Storage::FCLU::Plugin->$hook };
        like( $@, qr/must define '\Q$hook\E'/, "$hook is abstract on the base" );
    }
    is( $P->connector_class, 'PVE::Storage::FCLU::Host::FCMultipath', 'default connector' );
};

subtest 'parse_volname / vmid_from_volname (§7)' => sub {
    my @r = $P->parse_volname('vm-100-disk-1');
    is_deeply( [ @r[ 0, 1, 2, 5, 6 ] ], [ 'images', 'vm-100-disk-1', 100, undef, 'raw' ], 'live disk' );
    is( ( $P->parse_volname('base-9-disk-0') )[5], 1, 'base flag set' );
    is( ( $P->parse_volname('vm-7-cloudinit') )[2], 7, 'cloudinit parsed (#6)' );
    eval { $P->parse_volname('garbage') };
    like( $@, qr/unable to parse/, 'invalid name dies' );

    is( PVE::Storage::FCLU::Plugin::vmid_from_volname('vm-42-disk-3'), 42, 'vmid extracted' );
    is( PVE::Storage::FCLU::Plugin::vmid_from_volname('weird'), 0, 'no vmid => 0' );
};

subtest 'volume_has_feature role table' => sub {
    is( $P->volume_has_feature( {}, 'snapshot', 's', 'vm-1-disk-0' ), 1, 'snapshot on current' );
    is( $P->volume_has_feature( {}, 'clone', 's', 'vm-1-disk-0' ), undef, 'no clone from a live volume' );
    is( $P->volume_has_feature( {}, 'clone', 's', 'base-1-disk-0' ), 1, 'clone from a base' );
    is( $P->volume_has_feature( {}, 'clone', 's', 'vm-1-disk-0', 'snap1' ), 1, 'clone from a snapshot' );
    is( $P->volume_has_feature( {}, 'rename', 's', 'vm-1-disk-0' ), 1, 'rename on current' );
};

subtest 'volume attributes: protected + notes via the registry' => sub {
    reg()->register( 'vm-100-disk-0', 'dev-1', size_mb => 1024 );

    is( $P->get_volume_attribute( {}, 'store1', 'vm-100-disk-0', 'protected' ), 0, 'protected default 0' );
    $P->update_volume_attribute( {}, 'store1', 'vm-100-disk-0', 'protected', 1 );
    is( $P->get_volume_attribute( {}, 'store1', 'vm-100-disk-0', 'protected' ), 1, 'protected set' );
    $P->update_volume_attribute( {}, 'store1', 'vm-100-disk-0', 'protected', 0 );
    is( $P->get_volume_attribute( {}, 'store1', 'vm-100-disk-0', 'protected' ), 0, 'protected cleared' );

    $P->update_volume_attribute( {}, 'store1', 'vm-100-disk-0', 'notes', 'hello' );
    is( $P->get_volume_attribute( {}, 'store1', 'vm-100-disk-0', 'notes' ), 'hello', 'notes set' );
    $P->update_volume_attribute( {}, 'store1', 'vm-100-disk-0', 'notes', '' );
    is( $P->get_volume_attribute( {}, 'store1', 'vm-100-disk-0', 'notes' ), '', 'empty notes cleared' );

    eval { $P->update_volume_attribute( {}, 'store1', 'ghost', 'protected', 1 ) };
    like( $@, qr/not found in registry/, 'unknown volume dies' );
    eval { $P->update_volume_attribute( { type => 'testblock' }, 'store1', 'vm-100-disk-0', 'bogus', 1 ) };
    like( $@, qr/not supported/, 'unknown attribute rejected' );
};

subtest 'list_images: committed entries only, vmid/vollist filters' => sub {
    my $r = reg();
    $r->register( 'vm-200-disk-0', 'dev-2', size_mb => 2048, parent_volname => 'base-9-disk-0' );
    $r->reserve_volname(300);   # a reservation (no backend_id) — must be skipped

    my $all = $P->list_images( 'store1', {}, undef, undef );
    my %byvol = map { $_->{volid} => $_ } @$all;
    ok( $byvol{'store1:vm-200-disk-0'}, 'committed volume listed' );
    is( $byvol{'store1:vm-200-disk-0'}{size}, 2048 * 1024 * 1024, 'size in bytes' );
    is( $byvol{'store1:vm-200-disk-0'}{parent}, 'store1:base-9-disk-0', 'parent volid' );
    ok( !( grep { $_->{vmid} == 300 } @$all ), 'reservation (no backend) not listed' );

    my $just200 = $P->list_images( 'store1', {}, 200, undef );
    is( scalar @$just200, 1, 'vmid filter' );
    my $bylist = $P->list_images( 'store1', {}, undef, ['store1:vm-200-disk-0'] );
    is( scalar @$bylist, 1, 'vollist filter' );
};

subtest 'status + activate/deactivate drive the driver lifecycle' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new( [ 5000, 3000, 2000 ] );

    is_deeply( [ $P->status( 'store1', {} ) ], [ 5000, 3000, 2000, 1 ], 'status from driver storage_status' );
    ok( $T::Plugin::FAKE->{connected}, 'driver connected (lazily by status)' );

    $P->deactivate_storage( 'store1', {} );
    ok( !$T::Plugin::FAKE->{connected}, 'deactivate disconnected the driver' );

    ok( $P->activate_storage( 'store1', {} ), 'activate_storage' );
    ok( $T::Plugin::FAKE->{connected}, 'activate connected the driver' );
    $P->deactivate_storage( 'store1', {} );
};

subtest 'alloc_image: create + register, host-mapping deferred to activate' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    $P->deactivate_storage( 'store1', {} );   # drop any cached driver so _driver picks up this FAKE
    my $name = $P->alloc_image( 'store1', { pool_id => '63' }, 500, 'raw', undef, 4 * 1024 * 1024 );
    is( $name, 'vm-500-disk-1', 'reserved name returned' );

    my ( $bid, $entry ) = reg()->lookup($name);
    ok( defined $bid, 'registry committed with a backend_id' );
    ok( $entry->{identity}{ids}{naa}, 'canonical identity recorded at alloc' );
    is( $T::Plugin::FAKE->{calls}{create_lu}, 1, 'driver create_lu called' );
    is( $T::Plugin::FAKE->{calls}{set_lu_label}, 1, 'label set' );
    ok( !$T::Plugin::FAKE->{calls}{publish_lu}, 'no host mapping during alloc (deferred to activate)' );

    # An explicit name that already exists is refused.
    eval { $P->alloc_image( 'store1', { pool_id => '63' }, 500, 'raw', $name, 1024 ) };
    like( $@, qr/already exists/, 'duplicate explicit name refused' );
    eval { $P->alloc_image( 'store1', {}, 1, 'qcow2', undef, 1024 ) };
    like( $@, qr/unsupported format/, 'non-raw format refused' );
};

subtest 'alloc_image rolls back the array LU + reservation on failure' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    $P->deactivate_storage( 'store1', {} );   # drop any cached driver so _driver picks up this FAKE
    $T::Plugin::FAKE->{fail_create} = 1;
    eval { $P->alloc_image( 'store1', { pool_id => '63' }, 999, 'raw', undef, 1024 ) };
    like( $@, qr/failed to allocate/, 'alloc failure surfaced' );
    is( reg()->lookup('vm-999-disk-1'), undef, 'name reservation rolled back' );
};

subtest 'alloc_image rolls back the ORPHAN LU on a post-create failure' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    $P->deactivate_storage( 'store1', {} );
    $T::Plugin::FAKE->{fail_label} = 1;   # create_lu succeeds, then set_lu_label throws

    eval { $P->alloc_image( 'store1', { pool_id => '63' }, 998, 'raw', undef, 1 << 30 ) };
    like( $@, qr/failed to allocate/, 'alloc failure surfaced' );
    is( $T::Plugin::FAKE->{calls}{create_lu}, 1, 'the LU was created' );
    is( $T::Plugin::FAKE->{calls}{delete_lu}, 1, 'the orphan LU was deleted (rollback)' );
    is_deeply( $T::Plugin::FAKE->{lus}, {}, 'no LU left on the array' );
    is( reg()->lookup('vm-998-disk-1'), undef, 'name reservation rolled back' );
};

subtest 'activate_volume publishes + attaches; deactivate detaches + unpublishes' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    $P->deactivate_storage( 'store1', {} );   # drop any cached driver so _driver picks up this FAKE
    local $T::Plugin::CONN = T::FakeConn->new;
    my $name = $P->alloc_image( 'store1', { pool_id => '63' }, 600, 'raw', undef, 1 << 30 );

    ok( $P->activate_volume( 'store1', {}, $name ), 'activate_volume' );
    is( $T::Plugin::FAKE->{calls}{ensure_host_access}, 1, 'ensure_host_access called' );
    is( $T::Plugin::FAKE->{calls}{publish_lu}, 1, 'publish_lu called' );
    is( $T::Plugin::CONN->{calls}{attach}, 1, 'connector attach called' );

    ok( $P->deactivate_volume( 'store1', {}, $name ), 'deactivate_volume' );
    is( $T::Plugin::CONN->{calls}{detach}, 1, 'connector detach called (host side first)' );
    is( $T::Plugin::FAKE->{calls}{unpublish_lu}, 1, 'unpublish_lu called' );

    # Deactivating an unknown volume is an idempotent no-op success.
    is( $P->deactivate_volume( 'store1', {}, 'vm-12345-disk-0' ), 1, 'soft deactivate of a missing volume' );
};

subtest 'filesystem_path resolves from the recorded identity (no array session)' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    $P->deactivate_storage( 'store1', {} );   # drop any cached driver so _driver picks up this FAKE
    local $T::Plugin::CONN = T::FakeConn->new;
    my $name = $P->alloc_image( 'store1', { pool_id => '63' }, 700, 'raw', undef, 1 << 30 );

    my ( $path, $vmid, $vtype ) = $P->filesystem_path( {}, $name, 'store1' );
    like( $path, qr{^/dev/mapper/360060e80}, 'dm path from canonical identity' );
    is( $vmid, 700, 'vmid' );
    is( $vtype, 'images', 'vtype is the 3rd element (PVE contract)' );

    my $scalar = $P->path( {}, $name, 'store1' );
    is( $scalar, $path, 'path() scalar form matches' );
};

subtest 'filesystem_path resolves + persists a null identity live (never-activated volume)' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    $P->deactivate_storage( 'store1', {} );
    local $T::Plugin::CONN = T::FakeConn->new;
    my $name = $P->alloc_image( 'store1', { pool_id => '63' }, 950, 'raw', undef, 1 << 30 );

    # Simulate an array whose NAA is only known post-publish: a volume alloc'd but never
    # activated has a null recorded identity. device_path would die on it.
    reg()->update_meta( $name, identity => { protocol => 'scsi-fc', ids => { naa => undef } } );

    my $path = $P->filesystem_path( {}, $name, 'store1' );
    like( $path, qr{^/dev/mapper/360060e80}, 'path resolved via the live-identity fallback' );
    my ( undef, $meta ) = reg()->lookup($name);
    ok( defined $meta->{identity}{ids}{naa}, 'the resolved identity is persisted back to the registry' );
};

subtest 'alloc: QoS is capability-gated (not attempted on a platform without QoS)' => sub {
    # Regression (live E590H G-phase finding): the VSP E series / VSP One advertise no
    # QoS; attempting set_lu_qos there just draws an [invalid] from the array. The alloc
    # path must skip it (and say so) when the driver does not advertise qos/per_lu.
    local $T::Plugin::FAKE = T::FakeDriver->new;   # capabilities() advertises no qos (per_lu absent)
    $P->deactivate_storage( 'store1', {} );
    my @warns;
    local $SIG{__WARN__} = sub { push @warns, $_[0] };
    $P->alloc_image( 'store1', { pool_id => '63', qos_upper_iops => 2000 }, 610, 'raw', undef, 1 << 30 );
    ok( !$T::Plugin::FAKE->{calls}{set_lu_qos}, 'set_lu_qos NOT attempted when the platform lacks QoS' );
    ok( ( grep { /does not support per-volume QoS/ } @warns ), 'a clear "unsupported QoS" warning is emitted' );
};

subtest 'never-mapped volume: filesystem_path returns metadata (no die) so pvesm free works' => sub {
    # Regression (live E590H G-phase finding): PVE's API DELETE handler resolves the
    # volume vtype via path() BEFORE vdisk_free. A volume allocated but NEVER activated
    # has no device NAA yet (Hitachi exposes it only post-map) and the live
    # get_lu_identity cannot produce one either — filesystem_path must NOT die (it used
    # to), or `pvesm free` wedges before the delete and orphans the LU on the array.
    local $T::Plugin::FAKE = T::FakeDriver->new;
    $P->deactivate_storage( 'store1', {} );
    local $T::Plugin::CONN = T::FakeConn->new;
    my $name = $P->alloc_image( 'store1', { pool_id => '63' }, 951, 'raw', undef, 1 << 30 );
    my ($bid) = reg()->lookup($name);

    # Simulate a never-mapped LU: the array carries no NAA and the recorded identity is null.
    $T::Plugin::FAKE->{lus}{$bid}{identity} = { protocol => 'scsi-fc', ids => { naa => undef } };
    reg()->update_meta( $name, identity => { protocol => 'scsi-fc', ids => { naa => undef } } );

    my ( $path, $vmid, $vtype ) = $P->filesystem_path( {}, $name, 'store1' );
    is( $path,  undef,    'no device path for a never-mapped volume (returns instead of dying)' );
    is( $vmid,  951,      'vmid still derived from the volname for the metadata caller' );
    is( $vtype, 'images', 'vtype still returned for the metadata caller' );

    # The pvesm-free path must then succeed and actually delete the LU (no orphan).
    is( $P->free_image( 'store1', {}, $name ), undef, 'free_image on a never-mapped volume succeeds' );
    is( $T::Plugin::FAKE->{calls}{delete_lu}, 1, 'the LU was deleted (no orphan)' );
    is( reg()->lookup($name), undef, 'unregistered' );
};

subtest 'vendor hooks: _alloc_backend_id requested_id, safe_delete_precheck default' => sub {
    package T::RangedPlugin;
    use parent -norequire, 'T::Plugin';
    our $RANGE_FAKE;
    sub _build_driver { return $RANGE_FAKE //= T::FakeDriver->new }
    sub _alloc_backend_id { return '4242' }   # subclass allocates an explicit id

    package main;
    local $T::RangedPlugin::RANGE_FAKE = T::FakeDriver->new;
    T::RangedPlugin->deactivate_storage( 'store1', {} );   # shared %DRIVERS cache reset
    my $name = T::RangedPlugin->alloc_image( 'store1', { pool_id => '63' }, 800, 'raw', undef, 1 << 30 );
    is( scalar( reg()->lookup($name) ), '4242', 'subclass _alloc_backend_id drove the backend id' );

    is( $P->safe_delete_precheck( {}, 'anything' ), 1, 'default safe_delete_precheck allows' );
};

subtest 'free_image: guards, snapshot cleanup, teardown, delete, unregister' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    local $T::Plugin::CONN = T::FakeConn->new;
    $P->deactivate_storage( 'store1', {} );
    my $name = $P->alloc_image( 'store1', { pool_id => '63' }, 900, 'raw', undef, 1 << 30 );

    is( $P->free_image( 'store1', {}, $name ), undef, 'free_image returns undef (PVE contract)' );
    is( $T::Plugin::FAKE->{calls}{list_snapshots}, 1, 'capability-gated snapshot cleanup ran' );
    is( $T::Plugin::CONN->{calls}{detach}, 1, 'host detach (via deactivate)' );
    is( $T::Plugin::FAKE->{calls}{unpublish_lu}, 1, 'unpublish (via deactivate)' );
    is( $T::Plugin::FAKE->{calls}{unpublish_lu_all}, 1, 'cluster-wide unmap before delete (4C)' );
    is( $T::Plugin::FAKE->{calls}{delete_lu}, 1, 'array delete_lu' );
    is( reg()->lookup($name), undef, 'unregistered' );

    eval { $P->free_image( 'store1', {}, 'vm-404-disk-0' ) };
    like( $@, qr/not found in registry/, 'free of a missing volume dies' );
};

subtest 'free_image refuses protected + dependents + fence' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    $P->deactivate_storage( 'store1', {} );
    my $r = reg();

    $r->register( 'vm-901-disk-0', 'b901' );
    $r->update_meta( 'vm-901-disk-0', protected => 1 );
    eval { $P->free_image( 'store1', {}, 'vm-901-disk-0' ) };
    like( $@, qr/marked protected/, 'protected volume refused' );

    $r->register( 'base-902-disk-0', 'b902' );
    $r->register( 'vm-903-disk-0', 'b903', parent_volname => 'base-902-disk-0' );
    eval { $P->free_image( 'store1', {}, 'base-902-disk-0' ) };
    like( $@, qr/linked clone\(s\) depend/, 'volume with dependents refused' );

    # Vendor §7 fence: a subclass whose safe_delete_precheck returns 0 blocks free.
    package T::FencedPlugin;
    use parent -norequire, 'T::Plugin';
    our $FENCED_FAKE;
    sub _build_driver { return $FENCED_FAKE //= T::FakeDriver->new }
    sub safe_delete_precheck { 0 }

    package main;
    local $T::FencedPlugin::FENCED_FAKE = T::FakeDriver->new;
    T::FencedPlugin->deactivate_storage( 'store1', {} );
    reg()->register( 'vm-904-disk-0', 'b904' );
    eval { T::FencedPlugin->free_image( 'store1', {}, 'vm-904-disk-0' ) };
    like( $@, qr/safe-delete precheck/, 'fence refusal blocks free before any destructive op' );
    # The fence must gate before ANY destructive op, not just delete_lu.
    is( $T::FencedPlugin::FENCED_FAKE->{calls}{delete_lu},      undef, 'no delete_lu after a fence refusal' );
    is( $T::FencedPlugin::FENCED_FAKE->{calls}{list_snapshots}, undef, 'no snapshot touch after a fence refusal' );
    is( $T::FencedPlugin::FENCED_FAKE->{calls}{unpublish_lu},   undef, 'no host teardown after a fence refusal' );
};

subtest 'volume_resize grows + commits; rejects shrink' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    local $T::Plugin::CONN = T::FakeConn->new;
    $P->deactivate_storage( 'store1', {} );
    # alloc_image $size is KiB (PVE), volume_resize $size is bytes (PVE) — 1 GiB.
    my $name = $P->alloc_image( 'store1', { pool_id => '63' }, 905, 'raw', undef, 1024 * 1024 );

    ok( $P->volume_resize( {}, 'store1', $name, 2 << 30, 1 ), 'resize grows' );
    is( $T::Plugin::FAKE->{calls}{resize_lu}, 1, 'driver resize_lu called' );
    is( $T::Plugin::CONN->{calls}{flush},  1, 'pre-resize flush (running)' );
    is( $T::Plugin::CONN->{calls}{resize}, 1, 'host-side resize' );
    my ( undef, $meta ) = reg()->lookup($name);
    is( $meta->{size_mb}, 2048, 'registry size committed to the grown size' );

    eval { $P->volume_resize( {}, 'store1', $name, 1 << 30, 0 ) };
    like( $@, qr/cannot shrink/, 'shrink refused' );
};

subtest 'qemu_blockdev_options + volume_size_info' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    local $T::Plugin::CONN = T::FakeConn->new;
    $P->deactivate_storage( 'store1', {} );
    my $name = $P->alloc_image( 'store1', { pool_id => '63' }, 906, 'raw', undef, 1024 * 1024 );

    my $bd = $P->qemu_blockdev_options( {}, 'store1', $name, undef, {} );
    is( $bd->{driver}, 'host_device', 'host_device driver (raw block)' );
    like( $bd->{filename}, qr{^/dev/mapper/3}, 'absolute dm path' );

    my ( $size, $fmt, $used, $parent ) = $P->volume_size_info( {}, 'store1', $name );
    is( $size, 1024 * 1024 * 1024, 'size from registry' );
    is( $fmt,  'raw', 'format raw' );
    is( $used, $size, 'fully provisioned: used == size' );
};

subtest 'snapshot lifecycle: create/info/rename/rollback/delete + dependent guards' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    local $T::Plugin::CONN = T::FakeConn->new;
    $P->deactivate_storage( 'store1', {} );
    my $name = $P->alloc_image( 'store1', { pool_id => '63' }, 910, 'raw', undef, 1 << 30 );

    is( $P->volume_snapshot( {}, 'store1', $name, 'snap1' ), undef, 'volume_snapshot returns undef' );
    is( $T::Plugin::FAKE->{calls}{create_snapshot}, 1, 'driver create_snapshot called' );
    my $sm = reg()->lookup_snapshot( $name, 'snap1' );
    ok( $sm && defined $sm->{snap_id}, 'snapshot registered with a backend snap_id' );
    ok( defined $sm->{svol}, 'snapshot S-VOL backend id recorded (linked-clone source)' );

    $P->volume_snapshot( {}, 'store1', $name, 'snap2' );
    my $info = $P->volume_snapshot_info( {}, 'store1', $name );
    is( $info->{snap1}{parent}, undef, 'oldest snap has no parent' );
    is( $info->{snap2}{parent}, 'snap1', 'chain: snap2 parent is snap1' );
    is( $info->{current}{parent}, 'snap2', 'current parent is the newest snap' );
    ok( $info->{snap2}{order} > $info->{snap1}{order}, 'monotonic creation order' );

    ok( $P->volume_rollback_is_possible( {}, 'store1', $name, 'snap1' ), 'rollback possible' );
    ok( $P->volume_snapshot_rollback( {}, 'store1', $name, 'snap1' ), 'rollback drives restore' );
    is( $T::Plugin::FAKE->{calls}{restore_snapshot}, 1, 'driver restore_snapshot called' );

    $P->rename_snapshot( {}, 'store1', $name, 'snap2', 'snap2b' );
    ok( reg()->lookup_snapshot( $name, 'snap2b' ), 'snapshot renamed in registry' );
    ok( !reg()->lookup_snapshot( $name, 'snap2' ), 'old snapshot name gone' );

    # Dependent guards: a linked clone recorded off snap2b blocks its delete/rollback.
    reg()->register( 'vm-911-disk-0', 'bdep', parent_volname => $name, parent_snap => 'snap2b' );
    eval { $P->volume_snapshot_delete( {}, 'store1', $name, 'snap2b' ) };
    like( $@, qr/linked clone\(s\) depend/, 'snapshot delete refused while a clone depends on it' );
    eval { $P->volume_rollback_is_possible( {}, 'store1', $name, 'snap2b' ) };
    like( $@, qr/linked clone\(s\) depend/, 'rollback blocked by dependents' );

    ok( $P->volume_snapshot_delete( {}, 'store1', $name, 'snap1' ), 'snapshot delete' );
    is( $T::Plugin::FAKE->{calls}{delete_snapshot}, 1, 'driver delete_snapshot called' );
    ok( !reg()->lookup_snapshot( $name, 'snap1' ), 'snapshot unregistered' );

    eval { $P->volume_snapshot_delete( {}, 'store1', $name, 'ghost' ) };
    like( $@, qr/not found for volume/, 'deleting an unknown snapshot dies' );
    eval { $P->volume_snapshot( {}, 'store1', 'vm-99999-disk-0', 'x' ) };
    like( $@, qr/not found in registry/, 'snapshot of a missing volume dies' );
};

subtest 'volume_has_feature capability gating (fail soft when the driver lacks it)' => sub {
    package T::NoSnapDriver;
    our @ISA = ('T::FakeDriver');
    sub capabilities { { snapshot => {}, clone => {} } }

    package T::NoSnapPlugin;
    use parent -norequire, 'T::Plugin';
    our $D;
    sub _build_driver { return $D //= T::NoSnapDriver->new }

    package main;
    local $T::NoSnapPlugin::D = T::NoSnapDriver->new;

    T::NoSnapPlugin->deactivate_storage( 'store1', {} );
    is( T::NoSnapPlugin->volume_has_feature( {}, 'snapshot', 'store1', 'vm-1-disk-0' ), undef,
        'snapshot gated off when the driver does not advertise it' );
    T::NoSnapPlugin->deactivate_storage( 'store1', {} );
    is( T::NoSnapPlugin->volume_has_feature( {}, 'clone', 'store1', 'base-1-disk-0' ), undef,
        'clone gated off when the driver lacks clone.linked' );
    T::NoSnapPlugin->deactivate_storage( 'store1', {} );
    is( T::NoSnapPlugin->volume_has_feature( {}, 'rename', 'store1', 'vm-1-disk-0' ), 1,
        'rename stays available (host/registry feature, not array-gated)' );

    local $T::Plugin::FAKE = T::FakeDriver->new;
    $P->deactivate_storage( 'store1', {} );
    is( $P->volume_has_feature( {}, 'snapshot', 'store1', 'vm-1-disk-0' ), 1, 'snapshot allowed with capability' );
    is( $P->volume_has_feature( {}, 'clone', 'store1', 'base-1-disk-0' ), 1, 'clone allowed with capability' );
};

subtest 'clone_image: linked clone from a base + backing-pair release on free (#23)' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    local $T::Plugin::CONN = T::FakeConn->new;
    $P->deactivate_storage( 'store1', {} );

    my $base = $P->alloc_image( 'store1', { pool_id => '63' }, 920, 'raw', 'base-920-disk-0', 1 << 30 );
    my $clone = $P->clone_image( { pool_id => '63' }, 'store1', $base, 921, undef, 0 );
    like( $clone, qr/^vm-921-disk-\d+$/, 'clone returns a fresh volname' );
    is( $T::Plugin::FAKE->{calls}{create_linked_clone}, 1, 'driver create_linked_clone called' );
    ok( defined $T::Plugin::FAKE->{last_clone_hctx}, 'host_ctx handed to the driver (#24)' );

    my ( $cbid, $cmeta ) = reg()->lookup($clone);
    ok( defined $cbid, 'clone committed to the registry' );
    is( $cmeta->{parent_volname}, $base, 'parent linkage recorded' );
    ok( $cmeta->{identity}{ids}{naa}, 'clone identity recorded' );
    ok( defined $cmeta->{clone_backing_snap}, 'backing CoW pair id recorded (#23)' );

    # The base cannot be freed while the clone depends on it.
    eval { $P->free_image( 'store1', {}, $base ) };
    like( $@, qr/linked clone\(s\) depend/, 'parent refused while a clone depends on it' );

    # Freeing the clone releases the backing pair, then deletes the S-VOL.
    is( $P->free_image( 'store1', {}, $clone ), undef, 'clone freed' );
    is( $T::Plugin::FAKE->{calls}{delete_snapshot}, 1, 'backing CoW pair released (#23)' );
    is( reg()->lookup($clone), undef, 'clone unregistered' );
};

subtest 'clone_image: from a snapshot uses the snapshot S-VOL as the CoW source' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    local $T::Plugin::CONN = T::FakeConn->new;
    $P->deactivate_storage( 'store1', {} );
    my $vol = $P->alloc_image( 'store1', { pool_id => '63' }, 930, 'raw', undef, 1 << 30 );
    $P->volume_snapshot( {}, 'store1', $vol, 'snapA' );
    my $sm = reg()->lookup_snapshot( $vol, 'snapA' );

    my $clone = $P->clone_image( { pool_id => '63' }, 'store1', $vol, 931, 'snapA', 0 );
    my ( undef, $cmeta ) = reg()->lookup($clone);
    is( $cmeta->{parent_volname}, $vol, 'parent volume recorded' );
    is( $cmeta->{parent_snap}, 'snapA', 'parent snapshot recorded' );
    ok( scalar @{ $T::Plugin::FAKE->{snaps}{ $sm->{svol} } // [] } >= 1,
        'CoW pair created on the snapshot S-VOL, not the base LU' );
};

subtest 'clone_image rolls back the reservation on an in-create failure (nothing built yet)' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    local $T::Plugin::CONN = T::FakeConn->new;
    $P->deactivate_storage( 'store1', {} );
    my $base = $P->alloc_image( 'store1', { pool_id => '63' }, 935, 'raw', 'base-935-disk-0', 1 << 30 );
    $T::Plugin::FAKE->{fail_clone} = 1;   # create_linked_clone throws before any pair/S-VOL exists
    eval { $P->clone_image( { pool_id => '63' }, 'store1', $base, 936, undef, 0 ) };
    like( $@, qr/failed to clone/, 'clone failure surfaced' );
    is( reg()->lookup('vm-936-disk-1'), undef, 'clone name reservation rolled back' );
    is( $T::Plugin::FAKE->{calls}{delete_snapshot}, undef, 'no pair to release (none was created)' );
};

subtest 'clone_image releases the backing pair + S-VOL on a POST-create failure (#23 rollback)' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    local $T::Plugin::CONN = T::FakeConn->new;
    $P->deactivate_storage( 'store1', {} );
    my $base = $P->alloc_image( 'store1', { pool_id => '63' }, 937, 'raw', 'base-937-disk-0', 1 << 30 );
    my ($src_bid) = reg()->lookup($base);

    # create_linked_clone SUCCEEDS (pair + S-VOL built), then set_lu_label throws — the
    # exact partial-failure window the commit-last pattern exists to unwind (#23).
    $T::Plugin::FAKE->{fail_label} = 1;
    eval { $P->clone_image( { pool_id => '63' }, 'store1', $base, 938, undef, 0 ) };
    like( $@, qr/failed to clone/, 'post-create clone failure surfaced' );

    is( $T::Plugin::FAKE->{calls}{create_linked_clone}, 1, 'the pair + S-VOL were created' );
    is( $T::Plugin::FAKE->{calls}{delete_snapshot}, 1, 'the backing CoW pair was released FIRST (#23)' );
    is( $T::Plugin::FAKE->{calls}{delete_lu}, 1, 'then the orphan S-VOL was deleted' );
    is_deeply( $T::Plugin::FAKE->{snaps}{$src_bid}, [], 'no backing pair left on the source LU' );
    is( reg()->lookup('vm-938-disk-1'), undef, 'clone name reservation rolled back' );
};

subtest 'create_base converts a live volume to a base image + guards' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    local $T::Plugin::CONN = T::FakeConn->new;
    $P->deactivate_storage( 'store1', {} );
    my $vol = $P->alloc_image( 'store1', { pool_id => '63' }, 940, 'raw', undef, 1 << 30 );

    my $base = $P->create_base( 'store1', {}, $vol );
    is( $base, 'base-940-disk-1', 'base name derived from the disk index' );
    ok( reg()->lookup($base), 'registry renamed to the base name' );
    is( reg()->lookup($vol), undef, 'old volname gone' );
    is( $T::Plugin::FAKE->{calls}{set_lu_label}, 2, 'LU relabelled (alloc + create_base)' );

    eval { $P->create_base( 'store1', {}, $base ) };
    like( $@, qr/not possible for base image/, 'a base image cannot be re-based' );

    my $v2 = $P->alloc_image( 'store1', { pool_id => '63' }, 941, 'raw', undef, 1 << 30 );
    reg()->register( 'vm-942-disk-0', 'bdep2', parent_volname => $v2 );
    eval { $P->create_base( 'store1', {}, $v2 ) };
    like( $@, qr/linked clone\(s\) depend/, 'a volume with dependents cannot be based' );
};

subtest 'export/import format negotiation + rejection guards' => sub {
    is_deeply( [ $P->volume_export_formats( {}, 'store1', 'vm-1-disk-0', undef, undef, 0 ) ],
        ['raw+size'], 'export raw+size for the active volume' );
    is_deeply( [ $P->volume_import_formats( {}, 'store1', 'vm-1-disk-0', undef, undef, 0 ) ],
        ['raw+size'], 'import raw+size for the active volume' );
    is_deeply( [ $P->volume_export_formats( {}, 'store1', 'vm-1-disk-0', undef, undef, 1 ) ],
        [], 'no format with_snapshots' );
    is_deeply( [ $P->volume_import_formats( {}, 'store1', 'vm-1-disk-0', 'snap', undef, 0 ) ],
        [], 'no format for a snapshot' );
    is_deeply( [ $P->volume_import_formats( {}, 'store1', 'vm-1-disk-0', undef, 'base', 0 ) ],
        [], 'no incremental format' );

    eval { $P->volume_export( {}, 'store1', undef, 'vm-1-disk-0', 'qcow2', undef, undef, 0 ) };
    like( $@, qr/not available/, 'export rejects a non raw+size format' );
    eval { $P->volume_export( {}, 'store1', undef, 'vm-1-disk-0', 'raw+size', 'snap', undef, 0 ) };
    like( $@, qr/cannot export a snapshot/, 'export rejects a snapshot' );
    eval { $P->volume_export( {}, 'store1', undef, 'vm-1-disk-0', 'raw+size', undef, undef, 1 ) };
    like( $@, qr/together with their snapshots/, 'export rejects with_snapshots' );
    eval { $P->volume_import( {}, 'store1', undef, 'vm-1-disk-0', 'raw+size', undef, 'base', 0 ) };
    like( $@, qr/incremental/, 'import rejects an incremental stream' );
};

subtest 'export streams the device; import allocs + dd + returns the volid' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    local $T::Plugin::CONN = T::FakeConn->new;
    local @PVE::Storage::Plugin::HDR = ();
    local @PVE::Tools::CMDS = ();
    $P->deactivate_storage( 'store1', {} );
    my $name = $P->alloc_image( 'store1', { pool_id => '63' }, 950, 'raw', undef, 1024 * 1024 );
    $P->activate_volume( 'store1', {}, $name );

    open my $out, '>', \my $buf or die "open: $!";
    is( $P->volume_export( {}, 'store1', $out, $name, 'raw+size', undef, undef, 0 ), undef, 'export returns' );
    is( scalar @PVE::Storage::Plugin::HDR, 1, 'common header written once' );
    is( $PVE::Storage::Plugin::HDR[0], 1024 * 1024 * 1024, 'header carries the volume size in bytes' );
    like( "@{ $PVE::Tools::CMDS[-1] }", qr/\bdd\b.*\bif=/, 'dd read from the device path' );

    local $main::IMPORT_SIZE = 512 * 1024 * 1024;   # bytes
    open my $in, '<', \my $indata or die "open: $!";
    my $volid = $P->volume_import(
        { pool_id => '63' }, 'store1', $in, 'vm-960-disk-9', 'raw+size', undef, undef, 0, 0 );
    is( $volid, 'store1:vm-960-disk-9', 'import returns storeid:volname' );
    ok( reg()->lookup('vm-960-disk-9'), 'imported volume registered' );
    like( "@{ $PVE::Tools::CMDS[-1] }", qr/\bdd\b.*\bof=/, 'dd wrote into the device path' );
};

subtest 'rename_volume reassigns + guards; manage/unmanage adopt/release without deleting the LU' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    local $T::Plugin::CONN = T::FakeConn->new;
    $P->deactivate_storage( 'store1', {} );

    my $vol = $P->alloc_image( 'store1', { pool_id => '63' }, 970, 'raw', undef, 1 << 30 );

    my $volid = $P->rename_volume( { pool_id => '63' }, 'store1', $vol, 971, 'vm-971-disk-0' );
    is( $volid, 'store1:vm-971-disk-0', 'rename returns storeid:target' );
    ok( reg()->lookup('vm-971-disk-0'), 'registry renamed' );
    is( reg()->lookup($vol), undef, 'old name gone' );

    my $volid2 = $P->rename_volume( { pool_id => '63' }, 'store1', 'vm-971-disk-0', 972, undef );
    is( $volid2, 'store1:vm-972-disk-7', 'auto-derives a free name via find_free_diskname' );

    reg()->register( 'vm-973-disk-0', 'bdep3', parent_volname => 'vm-972-disk-7' );
    eval { $P->rename_volume( { pool_id => '63' }, 'store1', 'vm-972-disk-7', 974, 'vm-974-disk-0' ) };
    like( $@, qr/linked clone\(s\) depend/, 'rename refused while a clone depends on the source' );

    # Unmanage the live volume: releases tracking, keeps the array LU.
    my $cur = 'vm-972-disk-7';
    my ($cur_bid) = reg()->lookup($cur);
    my $released = $P->unmanage_volume( 'store1', {}, $cur );
    is( $released, $cur_bid, 'unmanage returns the backend id' );
    is( reg()->lookup($cur), undef, 'unmanaged: registry entry gone' );
    ok( exists $T::Plugin::FAKE->{lus}{$cur_bid}, 'unmanage did NOT delete the array LU' );
    is( $T::Plugin::FAKE->{calls}{delete_lu}, undef, 'no delete_lu on unmanage' );

    # Re-adopt the same LU under a fresh name.
    my $adopted = $P->manage_volume( 'store1', { pool_id => '63' }, $cur_bid, 975 );
    like( $adopted, qr/^vm-975-disk-\d+$/, 'manage adopts under a fresh volname' );
    my ( $abid, $ameta ) = reg()->lookup($adopted);
    is( $abid, $cur_bid, 'adopted the same backend LU' );
    ok( $ameta->{identity}{ids}{naa}, 'identity recorded on adopt (via activate)' );

    eval { $P->manage_volume( 'store1', { pool_id => '63' }, $cur_bid, 976 ) };
    like( $@, qr/already managed/, 'manage refuses an already-tracked LU' );
};

subtest 'free_image rediscovers a linked-clone backing pair from the parent (#23 fallback)' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    local $T::Plugin::CONN = T::FakeConn->new;
    $P->deactivate_storage( 'store1', {} );

    # A clone committed WITHOUT clone_backing_snap (its pair was not observable at
    # clone time) but WITH clone_parent_backend recorded; the array pair lives on the
    # parent LU with the clone as its S-VOL.
    my $parent = $P->alloc_image( 'store1', { pool_id => '63' }, 945, 'raw', 'base-945-disk-0', 1 << 30 );
    my ($pbid) = reg()->lookup($parent);
    my $clone  = $P->alloc_image( 'store1', { pool_id => '63' }, 946, 'raw', undef, 1 << 30 );
    my ($cbid) = reg()->lookup($clone);
    reg()->update_meta( $clone, parent_volname => $parent, clone_parent_backend => $pbid );
    push @{ $T::Plugin::FAKE->{snaps}{$pbid} },
        { snap_id => "$pbid,lcX", group => "pve_lc_$cbid", svol => $cbid, status => 'PSUS' };

    is( $P->free_image( 'store1', {}, $clone ), undef, 'clone freed' );
    is( $T::Plugin::FAKE->{calls}{delete_snapshot}, 1, 'backing pair rediscovered + released via the parent' );
    is_deeply( $T::Plugin::FAKE->{snaps}{$pbid}, [], 'the rediscovered pair was removed' );
};

subtest 'schema: properties() omits username/password; options() references them (§5 landmine)' => sub {
    my $props = $P->properties;
    ok( $props->{mgmt_ip} && $props->{pool_id}, 'generic properties declared' );
    ok( !exists $props->{username}, 'username NOT redeclared in properties (avoids the duplicate-property die)' );
    ok( !exists $props->{password}, 'password NOT redeclared in properties' );
    is( $props->{qos_priority}{maximum}, 3, 'typed QoS property carries constraints' );

    my $opts = $P->options;
    ok( $opts->{username} && $opts->{password}, 'username/password referenced in options' );
    ok( $opts->{mgmt_ip}{fixed} && $opts->{pool_id}{fixed}, 'mgmt_ip + pool_id are fixed' );
};

subtest 'on_add_hook stores creds + probes connectivity (session always torn down)' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    $P->deactivate_storage( 'store1', {} );
    $P->on_add_hook( 'store1', { username => 'u', pool_id => '63' }, password => 'secret' );
    my ( $u, $pw ) = PVE::Storage::FCLU::Credentials->new( storeid => 'store1', base_dir => $dir )->read;
    is( $u, 'u', 'username stored' );
    is( $pw, 'secret', 'password stored' );
    ok( $T::Plugin::FAKE->{calls}{disconnect}, 'probe session disconnected' );

    eval { $P->on_add_hook( 'store1', { pool_id => '63' }, password => 'x' ) };
    like( $@, qr/required/, 'missing username refused' );
};

subtest 'on_add_hook: a failing probe dies, tears the session down, and rolls back creds' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    $P->deactivate_storage( 'store_probe', {} );
    $T::Plugin::FAKE->{fail_status} = 1;
    eval { $P->on_add_hook( 'store_probe', { username => 'u', pool_id => '63' }, password => 's' ) };
    like( $@, qr/storage validation failed/, 'a bad probe surfaces' );
    ok( $T::Plugin::FAKE->{calls}{disconnect}, 'session torn down despite the failure' );
    eval { PVE::Storage::FCLU::Credentials->new( storeid => 'store_probe', base_dir => $dir )->read };
    like( $@, qr/not found/, 'orphan credentials rolled back on probe failure' );
};

subtest 'on_update_hook / on_delete_hook credential lifecycle' => sub {
    my $creds = PVE::Storage::FCLU::Credentials->new( storeid => 'store2', base_dir => $dir );
    $creds->store( 'olduser', 'oldpass' );

    $P->on_update_hook( 'store2', { username => 'newuser' } );
    my ( $u, $pw ) = $creds->read;
    is( $u, 'newuser', 'username updated' );
    is( $pw, 'oldpass', 'password preserved on a username-only change' );

    $P->on_update_hook( 'store2', { username => 'newuser' }, password => undef );
    eval { $creds->read };
    like( $@, qr/not found/, 'explicit password clear removed the credential file' );

    $creds->store( 'u', 'p' );
    $P->on_delete_hook( 'store2', {} );
    eval { $creds->read };
    like( $@, qr/not found/, 'on_delete cleared creds' );
};

subtest 'volume_qemu_snapshot_method + cluster_lock_storage timeout resolution' => sub {
    is( $P->volume_qemu_snapshot_method( 'store1', {}, 'vm-1-disk-0' ), 'storage', 'array-side snapshot method' );

    local @PVE::Storage::Plugin::LOCK_TIMEOUTS = ();
    $P->cluster_lock_storage( 'store1', 0, 45, sub { 1 } );
    is( $PVE::Storage::Plugin::LOCK_TIMEOUTS[-1], 45, 'an explicit timeout passes through' );

    local $main::PVE_STORAGE_IDS = { store1 => { lock_timeout => 300 } };
    $P->cluster_lock_storage( 'store1', 0, undef, sub { 1 } );
    is( $PVE::Storage::Plugin::LOCK_TIMEOUTS[-1], 300, 'configured lock_timeout used when PVE passes undef' );

    local $main::PVE_STORAGE_IDS = {};
    $P->cluster_lock_storage( 'store1', 0, undef, sub { 1 } );
    is( $PVE::Storage::Plugin::LOCK_TIMEOUTS[-1], 120, 'default 120 when unconfigured' );
};

subtest 'activate_volume: persistent_reservations drives a validate-and-warn PR check' => sub {
    local $T::Plugin::FAKE = T::FakeDriver->new;
    local $T::Plugin::CONN = T::FakeConn->new;
    $P->deactivate_storage( 'store1', {} );
    my $name = $P->alloc_image( 'store1', { pool_id => '63' }, 915, 'raw', undef, 1 << 30 );

    # PR opt-out: no readiness check at all.
    ok( $P->activate_volume( 'store1', {}, $name ), 'activate without PR opt-in' );
    is( $T::Plugin::CONN->{calls}{check_pr_ready}, undef, 'no PR check when persistent_reservations off' );

    # PR opt-in + ready: check runs, activation succeeds, no warning.
    ok( $P->activate_volume( 'store1', { persistent_reservations => 1 }, $name ), 'activate with PR opt-in (ready)' );
    is( $T::Plugin::CONN->{calls}{check_pr_ready}, 1, 'PR readiness checked on activate' );

    # PR opt-in + NOT ready: warns with guidance but does NOT block activation.
    $T::Plugin::CONN->{pr_result} =
        { ok => 0, issues => [ 'qemu-pr-helper is not running', 'multipath reservation_key is not configured' ] };
    my @warns;
    local $SIG{__WARN__} = sub { push @warns, $_[0] };
    my $ok = $P->activate_volume( 'store1', { persistent_reservations => 1 }, $name );
    is( $ok, 1, 'activation still succeeds when PR is not ready (validate-and-warn only)' );
    ok( ( grep { /SCSI-3 PR not ready/ } @warns ), 'warns that PR is not ready' );
    ok( ( grep { /qemu-pr-helper/ } @warns ), 'surfaces the actionable prerequisite' );
};

subtest 'base _connector loads its connector_class (regression: missing require)' => sub {
    # T::Plugin overrides _connector with a fake, so the real class-load path is never
    # exercised by the other subtests — an unloaded connector_class only bit in
    # production ("can't locate method new"). Drive the REAL base method: it must
    # require the module before calling ->new.
    my $conn = PVE::Storage::FCLU::Plugin->_connector;
    isa_ok( $conn, 'PVE::Storage::FCLU::Host::FCMultipath', 'base _connector returns a loaded connector instance' );
};

done_testing();
