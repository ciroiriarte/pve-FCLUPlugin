#!/usr/bin/env bash
#
# validate-copy-offload-freeze.sh — live validation harness for the qemu-server
# freeze bracket introduced by the copy-offload RFC series (pve-FCLUPlugin issue #22,
# upstream "[RFC PATCH storage, qemu-server 0/5] offload full clone to the storage
# backend", <20260720.0.copyoffload@cyruspy.gmail.com>).
#
# WHAT THIS PROVES
#   The 5/5 qemu-server consumer restructured clone_disk so a full clone of a RUNNING
#   guest brackets the offloaded copy with a freeze (savevm-start, or a vm_suspend
#   fallback when no guest agent is present) and a guaranteed thaw. That freeze code is
#   shared with live migration and move-disk via BlockJob::monitor(), so a regression is
#   worse than a broken clone. It has only ever run offline. This harness exercises, on a
#   real running multi-disk guest, the three untested shapes and the two invariants:
#     S1 all-offloaded    — every disk on a copy-offload storage; no mirror jobs, so
#                           clone_vm() must establish its OWN freeze (incl. the
#                           vm_suspend fallback path when the guest agent is absent).
#     S2 mixed            — one offloaded disk + one mirrored (non-offload) disk in the
#                           same VM; on_frozen must fire inside the real mirror-cutover
#                           freeze (qemu-server#1).
#     S3 last-disk-deferred — the deferred-start branch runs the rendezvous itself.
#     INV-thaw   — the guest is ALWAYS running (thawed) after each clone.
#     INV-consist— the two data disks of the clone reflect the SAME instant (a running
#                  multi-disk guest clones CONSISTENT, not torn).
#
# THIS SCRIPT DOES NOT RUN ITSELF. It is a supervised operator tool. Without --run it
# prints the plan and exits 0 (a dry run). It refuses to touch a production VMID, stays
# inside a dedicated test-VMID range, and tears down every VM it creates. It does NOT
# install or revert the patched packages — that is a deliberate, separate manual step
# (see PREREQUISITES) because reverting libpve-storage-perl/qemu-server restarts
# pvedaemon on a node that hosts other guests.
#
# PREREQUISITES (operator, before --run)
#   1. Patched libpve-storage-perl + qemu-server built from the copy-image-offload
#      branch (/home/ciro/code/pve-upstream/{pve-storage,qemu-server}) INSTALLED on the
#      chosen node. The `use lib` override trick does NOT work here — this exercises
#      pvedaemon's own clone path, not a script, so the packages must be really installed.
#   2. Node choice is DELIBERATE. On the lab, prod VM 2001 runs on pve-03 and pve-03 is
#      the only ESXi-free node — pick the node with the least at stake and confirm the
#      staged rollback exists (/root/pre-upgrade-*/ROLLBACK.sh) BEFORE installing.
#   3. A copy-offload-enabled RBD storage (lab: `ec2-1`) reachable from the node — needs
#      no vendor hardware. For S2 a second, NON-offload storage for the mirrored disk.
#   4. A Debian cloud image importable as the boot disk, with cloud-init + the
#      qemu-guest-agent (S1's agent-present path and the consistency reader use it; S1
#      also re-runs with the agent stopped to hit the vm_suspend fallback).
#
# REVERT (operator, after the run): run the node's staged ROLLBACK.sh (or
#   `apt-get install --reinstall` the exact pre-patch libpve-storage-perl + qemu-server),
#   which restarts pvedaemon. This harness intentionally leaves that to you.
#
# Concrete addressing / secrets live in the untracked TESTING.md + maintainer memory;
# everything here uses placeholders overridable by the flags/env below.

set -euo pipefail

# ── Configuration (override via flags or env) ──────────────────────────────────
OFFLOAD_STORE="${OFFLOAD_STORE:-ec2-1}"        # copy-offload-enabled storage (RBD)
MIRROR_STORE="${MIRROR_STORE:-}"               # a NON-offload storage for S2's mirrored disk
CLOUD_IMAGE="${CLOUD_IMAGE:-}"                  # path to a Debian cloud .qcow2/.img on the node
TEMPLATE_VMID="${TEMPLATE_VMID:-}"              # alt to --cloud-image: clone this template (needs a guest agent)
BRIDGE="${BRIDGE:-vmbr0}"
VMID_BASE="${VMID_BASE:-79000}"                 # test VMIDs live in [VMID_BASE, VMID_BASE+99]
DISK_GIB="${DISK_GIB:-2}"                       # size of each data disk
WRITER_SECS="${WRITER_SECS:-20}"                # how long the in-guest writer runs before cloning
CONSIST_TOL="${CONSIST_TOL:-1}"                 # allowed |clockA-clockB| (write-ordering window)
DO_RUN=0
SCENARIOS="S1 S2 S3"

# VMIDs this harness must NEVER touch, whatever the config says. Extend on the node.
PROD_VMID_DENYLIST=(2001 2003 2000 2002)

# ── CLI ────────────────────────────────────────────────────────────────────────
usage() {
    cat <<USAGE
usage: $0 [--run] [options]

  --run                    actually execute (default: dry-run — print the plan and exit)
  --offload-store NAME     copy-offload storage for offloaded disks   (default: $OFFLOAD_STORE)
  --mirror-store NAME      NON-offload storage for S2's mirrored disk  (required for S2)
  --cloud-image PATH       Debian cloud image on the node             (required for --run)
  --bridge NAME            guest NIC bridge                            (default: $BRIDGE)
  --vmid-base N            base of the test-VMID range [N, N+99]       (default: $VMID_BASE)
  --scenarios "S1 S2 S3"   which scenarios to run                      (default: all)
  --writer-secs N          in-guest writer runtime before cloning      (default: $WRITER_SECS)
  -h, --help               this help

Dry-run prints exactly what --run would do without creating or cloning anything.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --run)           DO_RUN=1 ;;
        --offload-store) OFFLOAD_STORE="$2"; shift ;;
        --mirror-store)  MIRROR_STORE="$2"; shift ;;
        --cloud-image)   CLOUD_IMAGE="$2"; shift ;;
        --from-template) TEMPLATE_VMID="$2"; shift ;;
        --bridge)        BRIDGE="$2"; shift ;;
        --vmid-base)     VMID_BASE="$2"; shift ;;
        --scenarios)     SCENARIOS="$2"; shift ;;
        --writer-secs)   WRITER_SECS="$2"; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '\e[31mFAIL:\e[0m %s\n' "$*" >&2; exit 1; }
pass() { printf '\e[32mPASS:\e[0m %s\n' "$*"; }

# Test VMIDs — a boot VM per scenario plus its clone target.
vmid_src()   { echo $(( VMID_BASE + $1 )); }        # S1->1 S2->2 S3->3
vmid_clone() { echo $(( VMID_BASE + 50 + $1 )); }

assert_not_prod() {
    local v="$1"
    for p in "${PROD_VMID_DENYLIST[@]}"; do
        [ "$v" = "$p" ] && fail "refusing to operate on production VMID $v (denylist)"
    done
    # Never touch a VMID outside our dedicated test window.
    if [ "$v" -lt "$VMID_BASE" ] || [ "$v" -gt $(( VMID_BASE + 99 )) ]; then
        fail "VMID $v is outside the test range [$VMID_BASE, $(( VMID_BASE + 99 ))]"
    fi
}

# ── Preflight ──────────────────────────────────────────────────────────────────
preflight() {
    log "preflight: node $(hostname), scenarios: $SCENARIOS"

    command -v qm >/dev/null    || fail "qm not found — run this ON a PVE node"
    command -v pvesm >/dev/null || fail "pvesm not found — run this ON a PVE node"

    # BOTH patched packages must be installed, else we would validate the OLD host-copy
    # path and call it a pass. This is the harness's central false-PASS guard:
    #   (a) patched libpve-storage-perl — the copy_image_* offload hook (rbd 2/5), and
    #   (b) patched qemu-server — the freeze bracket under test (5/5). Without (b), a
    #       full clone of a running guest silently falls back to drive-mirror, which is
    #       ALSO consistent and never freezes, so thaw+consistency would both pass for a
    #       bracket that never ran. Check both, fail closed if either is stock.

    # (a) storage: the offload hook subs the RFC adds to the plugin base.
    local storage_pm; storage_pm="$(perl -MPVE::Storage::Plugin -e 'print $INC{"PVE/Storage/Plugin.pm"}' 2>/dev/null || true)"
    [ -n "$storage_pm" ] || fail "cannot locate the installed PVE::Storage::Plugin"
    if ! grep -qE 'sub +copy_image_(prepare|start|status)\b' "$storage_pm"; then
        fail "installed $storage_pm has no copy_image_* offload hook — the patched libpve-storage-perl is NOT installed (see PREREQUISITES)"
    fi
    pass "patched storage layer present ($storage_pm advertises copy_image_*)"

    # (b) qemu-server: the deferred-copy freeze bracket the 5/5 patch adds. Locate the
    # installed QemuServer.pm and require its distinctive freeze sub.
    local qserver_pm; qserver_pm="$(perl -MPVE::QemuServer -e 'print $INC{"PVE/QemuServer.pm"}' 2>/dev/null || true)"
    [ -n "$qserver_pm" ] || fail "cannot locate the installed PVE::QemuServer"
    if ! grep -qE 'sub +(freeze_and_run_deferred_copies|run_deferred_copies)\b' "$qserver_pm"; then
        fail "installed $qserver_pm has no deferred-copy freeze bracket — the patched qemu-server is NOT installed; a running clone would fall back to drive-mirror and FALSE-PASS (see PREREQUISITES)"
    fi
    pass "patched qemu-server present ($qserver_pm has the deferred-copy freeze bracket)"

    # Offload storage exists and actually offloads (advertises the capability). We assert
    # via pvesm status + a storage.cfg option rather than guessing.
    pvesm status --storage "$OFFLOAD_STORE" >/dev/null 2>&1 \
        || fail "offload storage '$OFFLOAD_STORE' not found"
    pass "offload storage '$OFFLOAD_STORE' present"

    if echo "$SCENARIOS" | grep -qw S2; then
        [ -n "$MIRROR_STORE" ] || fail "S2 needs --mirror-store (a NON-offload storage)"
        pvesm status --storage "$MIRROR_STORE" >/dev/null 2>&1 \
            || fail "mirror storage '$MIRROR_STORE' not found"
        pass "mirror storage '$MIRROR_STORE' present"
    fi

    if [ -n "$TEMPLATE_VMID" ]; then
        qm config "$TEMPLATE_VMID" >/dev/null 2>&1 || fail "--from-template $TEMPLATE_VMID not found"
        qm config "$TEMPLATE_VMID" 2>/dev/null | grep -q '^agent:.*enabled=1' \
            || fail "template $TEMPLATE_VMID has no guest agent (agent: enabled=1) — the probe needs it"
        pass "guest source: template $TEMPLATE_VMID (with agent)"
    else
        [ -n "$CLOUD_IMAGE" ] || fail "need --from-template <vmid> or --cloud-image <path> for --run"
        [ -r "$CLOUD_IMAGE" ] || fail "cloud image '$CLOUD_IMAGE' not readable"
        pass "guest source: cloud image '$CLOUD_IMAGE'"
    fi

    # Every VMID we might use must be free and inside the test window.
    local i v
    for i in 1 2 3; do
        for v in "$(vmid_src "$i")" "$(vmid_clone "$i")"; do
            assert_not_prod "$v"
            if qm status "$v" >/dev/null 2>&1; then
                fail "test VMID $v is already in use — pick a clear --vmid-base"
            fi
        done
    done
    pass "test VMIDs free and inside [$VMID_BASE, $(( VMID_BASE + 99 ))]"
}

# ── Guest build ──────────────────────────────────────────────────────────────
# Build a running multi-disk VM: a cloud-init boot disk + two data disks. disk1 always
# lands on the offload storage; disk2 lands on $data2_store (offload for S1/S3, mirror
# for S2). cloud-init installs the guest agent and drops the writer + reader helpers.
build_guest() {
    local vmid="$1" data2_store="$2"
    assert_not_prod "$vmid"
    log "build VM $vmid (data2 on $data2_store)"

    if [ -n "$TEMPLATE_VMID" ]; then
        # Full-clone a template that already carries a guest agent; the boot disk lands on
        # the offload storage. This SETUP clone is not the path under test.
        qm clone "$TEMPLATE_VMID" "$vmid" --name "fclu-frz-$vmid" --full --storage "$OFFLOAD_STORE"
    else
        qm create "$vmid" --name "fclu-frz-$vmid" --memory 2048 --cores 2 \
            --net0 "virtio,bridge=$BRIDGE" --agent enabled=1 --serial0 socket --vga serial0
        qm importdisk "$vmid" "$CLOUD_IMAGE" "$OFFLOAD_STORE" >/dev/null
        qm set "$vmid" --scsihw virtio-scsi-single --scsi0 "$OFFLOAD_STORE:vm-$vmid-disk-0"
        qm set "$vmid" --ide2 "$OFFLOAD_STORE:cloudinit"
        qm set "$vmid" --boot order=scsi0 --ciuser fclu --cipassword fcluvalidate
    fi
    # Two data disks (scsi1/scsi2 -> /dev/sdb,/dev/sdc): the consistency probe writes a
    # shared clock into BOTH.
    qm set "$vmid" --scsi1 "$OFFLOAD_STORE:$DISK_GIB"
    qm set "$vmid" --scsi2 "$data2_store:$DISK_GIB"

    qm start "$vmid"
    wait_agent "$vmid"

    # Format + mount both data disks, then launch the writer. The writer paints a
    # monotonically increasing 64-bit clock to a file on EACH data-disk filesystem,
    # same value to both (scsi1 then scsi2) with fsync, then increments — so at a
    # frozen instant the two files are equal, or scsi1 is exactly one ahead (the
    # write-ordering window, hence CONSIST_TOL default 1). A torn (non-simultaneous)
    # clone captures the two disks at different iterations and they diverge.
    guest_exec "$vmid" bash -c '
        set -e
        mkfs.ext4 -q -F /dev/sdb; mkfs.ext4 -q -F /dev/sdc
        mkdir -p /mnt/d1 /mnt/d2
        mount /dev/sdb /mnt/d1; mount /dev/sdc /mnt/d2
        cat > /root/writer.sh <<"EOF"
#!/bin/bash
n=0
while true; do
  printf "%020d" "$n" > /mnt/d1/clock; sync -f /mnt/d1/clock
  printf "%020d" "$n" > /mnt/d2/clock; sync -f /mnt/d2/clock
  n=$((n+1))
done
EOF
        chmod +x /root/writer.sh
        setsid /root/writer.sh >/dev/null 2>&1 < /dev/null &
        echo started
    '
    log "VM $vmid: writer running; letting it churn ${WRITER_SECS}s"
    sleep "$WRITER_SECS"
}

wait_agent() {
    local vmid="$1" i
    for i in $(seq 1 60); do
        qm agent "$vmid" ping >/dev/null 2>&1 && return 0
        sleep 5
    done
    fail "VM $vmid: guest agent never came up"
}

# Run a command in the guest via the agent and return its stdout.
guest_exec() {
    local vmid="$1"; shift
    local pid out
    pid="$(qm guest exec "$vmid" --synchronous 0 -- "$@" | sed -n 's/.*"pid" *: *\([0-9]*\).*/\1/p')"
    [ -n "$pid" ] || fail "VM $vmid: guest exec did not return a pid"
    local i
    for i in $(seq 1 60); do
        out="$(qm guest exec-status "$vmid" "$pid" 2>/dev/null || true)"
        echo "$out" | grep -q '"exited" *: *1\|"exited" *: *true' && break
        sleep 2
    done
    echo "$out"
}

# Read the frozen clock off BOTH of a clone's data disks. The clone's writer does NOT
# auto-restart on boot (it was launched imperatively, with no fstab mount and no unit),
# so the clock files hold exactly the values captured at clone time. We boot the clone,
# reach it over the guest-agent virtio-serial channel (no network needed), mount the two
# data disks read-only, cat both clocks, and stop it again. Prints "A B".
read_clone_clocks() {
    local cvmid="$1"
    assert_not_prod "$cvmid"
    qm start "$cvmid" >/dev/null
    wait_agent "$cvmid"
    local out
    out="$(guest_exec "$cvmid" bash -c '
        mkdir -p /mnt/r1 /mnt/r2
        mount -o ro /dev/sdb /mnt/r1 2>/dev/null || mount /dev/sdb /mnt/r1
        mount -o ro /dev/sdc /mnt/r2 2>/dev/null || mount /dev/sdc /mnt/r2
        printf "%s %s\n" "$(cat /mnt/r1/clock 2>/dev/null)" "$(cat /mnt/r2/clock 2>/dev/null)"
    ')"
    qm stop "$cvmid" >/dev/null 2>&1 || true
    # Pull the two 20-digit numbers out of the agent JSON/out-data.
    echo "$out" | grep -oE '[0-9]{20}' | head -2 | tr '\n' ' '
}

# ── Invariant + scenario checks ────────────────────────────────────────────────
assert_thawed() {
    local vmid="$1"
    [ "$(qm status "$vmid" | awk '{print $2}')" = "running" ] \
        || fail "INV-thaw: VM $vmid is NOT running after the clone (freeze/thaw broke)"
    qm agent "$vmid" ping >/dev/null 2>&1 \
        || fail "INV-thaw: VM $vmid agent unresponsive after the clone"
    pass "INV-thaw: VM $vmid running + responsive after the clone"
}

assert_consistent() {
    local cvmid="$1"
    local clocks a b diff
    clocks="$(read_clone_clocks "$cvmid")"
    a="${clocks%% *}"; b="${clocks##* }"
    log "clone $cvmid clocks: scsi1=$a scsi2=$b"
    [ -n "$a" ] && [ -n "$b" ] \
        || fail "INV-consist: could not read both clocks off clone $cvmid (got '$clocks')"
    # 10#$a forces base-10 (leading zeros in the 20-digit clock would else parse as octal).
    diff=$(( 10#$a > 10#$b ? 10#$a - 10#$b : 10#$b - 10#$a ))
    [ "$diff" -le "$CONSIST_TOL" ] \
        || fail "INV-consist: clone $cvmid is TORN (|$a-$b|=$diff > tol $CONSIST_TOL)"
    pass "INV-consist: clone $cvmid data disks captured the same instant (diff=$diff)"
}

CLONE_LOG=""
clone_running() {
    # Full clone of a RUNNING guest — the path under test. Capture the task log so
    # assert_offload_taken can prove the OFFLOAD path ran (not a silent drive-mirror
    # fallback, which would also be consistent + thawed and thus false-PASS).
    local src="$1" dst="$2"
    assert_not_prod "$dst"
    CLONE_LOG="$(mktemp "/tmp/fclu-clone-${dst}.XXXXXX.log")"
    log "qm clone $src -> $dst --full (guest RUNNING); task log: $CLONE_LOG"
    qm clone "$src" "$dst" --name "clone-$dst" --full 1 2>&1 | tee "$CLONE_LOG"
    local rc="${PIPESTATUS[0]}"
    # A non-zero clone is a scenario failure in its own right (e.g. the offload copy or
    # its flatten-to-independence errored). Report it cleanly with the log pointer rather
    # than proceeding to assert on a clone that was rolled back.
    [ "$rc" = 0 ] || fail "clone of $src -> $dst FAILED (rc=$rc) — see $CLONE_LOG (offload/flatten error?)"
}

# Prove the offload path executed. mode=all (S1/S3): the 'offloaded copy' marker MUST be
# present and NO drive-mirror job may have run. mode=mixed (S2): both an offloaded copy
# AND a drive-mirror cutover must appear (offloaded scsi1 + mirrored scsi2).
assert_offload_taken() {
    local mode="$1"
    [ -r "$CLONE_LOG" ] || fail "no clone task log captured for the offload assertion"
    grep -qiE 'offloaded copy' "$CLONE_LOG" \
        || fail "offload NOT taken: clone log has no 'offloaded copy' marker — fell back to host copy/drive-mirror"
    if [ "$mode" = all ]; then
        grep -qiE 'drive-mirror|drive-scsi[0-9]+: .*mirror' "$CLONE_LOG" \
            && fail "all-offloaded scenario ran a drive-mirror job — offload did not cover every disk"
        pass "offload path confirmed (all-offloaded): 'offloaded copy' present, no drive-mirror job"
    else
        grep -qiE 'drive-mirror|mirror' "$CLONE_LOG" \
            || fail "mixed scenario: expected a drive-mirror cutover for the non-offload disk, none in the log"
        pass "mixed path confirmed: offloaded copy + drive-mirror cutover both present"
    fi
}

scenario_S1() {   # all-offloaded, agent present, then agent-absent (vm_suspend fallback)
    log "=== S1 all-offloaded ==="
    local src; src="$(vmid_src 1)"; local dst; dst="$(vmid_clone 1)"
    build_guest "$src" "$OFFLOAD_STORE"
    clone_running "$src" "$dst"
    assert_offload_taken all
    assert_thawed "$src"
    assert_consistent "$dst"

    # Re-clone with the guest agent stopped to exercise the vm_suspend fallback freeze.
    log "S1b: stopping guest agent to force the vm_suspend fallback freeze"
    guest_exec "$src" systemctl stop qemu-guest-agent || true
    local dst2; dst2=$(( dst + 20 )); assert_not_prod "$dst2"
    clone_running "$src" "$dst2"
    assert_offload_taken all
    [ "$(qm status "$src" | awk '{print $2}')" = "running" ] \
        || fail "INV-thaw(S1b): VM $src not running after vm_suspend-fallback clone"
    pass "S1b: vm_suspend fallback clone left the guest running"
    assert_consistent "$dst2"
    guest_exec "$src" systemctl start qemu-guest-agent || true
}

scenario_S2() {   # mixed offloaded + mirrored disk in one VM
    log "=== S2 mixed offloaded + mirrored ==="
    local src; src="$(vmid_src 2)"; local dst; dst="$(vmid_clone 2)"
    build_guest "$src" "$MIRROR_STORE"     # scsi2 on a NON-offload store -> drive-mirror
    clone_running "$src" "$dst"
    assert_offload_taken mixed
    assert_thawed "$src"
    assert_consistent "$dst"
    pass "S2: on_frozen fired inside the mirror-cutover freeze (offloaded scsi1 + mirrored scsi2)"
}

scenario_S3() {   # last-disk-deferred branch
    log "=== S3 last-disk-deferred ==="
    local src; src="$(vmid_src 3)"; local dst; dst="$(vmid_clone 3)"
    build_guest "$src" "$OFFLOAD_STORE"
    clone_running "$src" "$dst"
    assert_offload_taken all
    assert_thawed "$src"
    assert_consistent "$dst"
    pass "S3: last-deferred-disk rendezvous completed; clone consistent + guest thawed"
}

# ── Teardown ───────────────────────────────────────────────────────────────────
teardown() {
    log "teardown: destroying test VMs (never touches anything outside the test range)"
    local i v
    for i in 1 2 3; do
        for v in "$(vmid_src "$i")" "$(vmid_clone "$i")" $(( $(vmid_clone "$i") + 20 )); do
            if [ "$v" -ge "$VMID_BASE" ] && [ "$v" -le $(( VMID_BASE + 99 )) ] \
               && qm status "$v" >/dev/null 2>&1; then
                assert_not_prod "$v"
                qm stop "$v" >/dev/null 2>&1 || true
                qm destroy "$v" --purge --destroy-unreferenced-disks 1 >/dev/null 2>&1 || true
                log "destroyed test VM $v"
            fi
        done
    done
    log "teardown done. REMINDER: revert the patched packages via the node's ROLLBACK.sh"
    log "  (or apt-get install --reinstall the pre-patch libpve-storage-perl + qemu-server)."
}

# ── Main ───────────────────────────────────────────────────────────────────────
print_plan() {
    cat <<PLAN
DRY RUN — no VM will be created, cloned, or destroyed.

Node          : $(hostname)
Scenarios     : $SCENARIOS
Offload store : $OFFLOAD_STORE
Mirror store  : ${MIRROR_STORE:-<unset — required for S2>}
Cloud image   : ${CLOUD_IMAGE:-<unset — required for --run>}
Test VMIDs    : sources $(vmid_src 1)/$(vmid_src 2)/$(vmid_src 3), clones $(vmid_clone 1)/$(vmid_clone 2)/$(vmid_clone 3) (+20 for S1b)
Prod denylist : ${PROD_VMID_DENYLIST[*]}

Would, per scenario: build a running 2-data-disk cloud-init guest, run an in-guest
fsync'd clock writer across both disks for ${WRITER_SECS}s, then "qm clone --full" it
WHILE RUNNING, then assert the guest stayed thawed and the two cloned disks caught the same
instant (|clockA-clockB| <= $CONSIST_TOL). S1 also re-clones with the guest agent stopped
to hit the vm_suspend fallback freeze. Every created VMID is inside [$VMID_BASE,$((VMID_BASE+99))]
and destroyed on exit; the patched packages are NOT touched by this script.

Re-run with --run (and --cloud-image / --mirror-store) to execute on this node.
PLAN
}

main() {
    if [ "$DO_RUN" -ne 1 ]; then
        print_plan
        exit 0
    fi

    log "LIVE RUN on $(hostname). This creates + clones + destroys test guests."
    preflight
    trap teardown EXIT
    for s in $SCENARIOS; do
        case "$s" in
            S1) scenario_S1 ;;
            S2) scenario_S2 ;;
            S3) scenario_S3 ;;
            *) fail "unknown scenario '$s'" ;;
        esac
    done
    log "all requested scenarios completed — review PASS/FAIL lines above"
}

main
