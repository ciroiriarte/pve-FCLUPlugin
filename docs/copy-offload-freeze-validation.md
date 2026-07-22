# Live validation — qemu-server freeze bracket (copy-offload RFC, issue #22)

Operator procedure for the riskiest untested path in the copy-offload RFC series
(`[RFC PATCH storage, qemu-server 0/5] offload full clone to the storage backend`,
`<20260720.0.copyoffload@cyruspy.gmail.com>`; pve-FCLUPlugin issue **#22**).

The 5/5 qemu-server consumer restructured `clone_disk` so that a **full clone of a
running guest** brackets the offloaded array copy with a freeze (`savevm-start`, or a
`vm_suspend` fallback when the guest agent is absent) and a guaranteed thaw. That freeze
touches `BlockJob::monitor()`, **shared with live migration and move-disk** — so a
regression there is worse than a broken clone. It has only ever run offline. This
procedure exercises it on a real running multi-disk guest.

The harness is [`tools/validate-copy-offload-freeze.sh`](../tools/validate-copy-offload-freeze.sh).
It is a **supervised operator tool**: without `--run` it prints the plan and exits (a dry
run). It stays inside a dedicated test-VMID window, refuses a production VMID, and tears
down every VM it creates. It does **not** install or revert the patched packages.

> This exercises `pvedaemon`'s own clone path, not a script, so the `use lib` override
> trick used for the storage-side validation does **not** work — the patched packages
> must be **really installed** on the node.

## What it checks

| Case | Shape | Why it is unproven |
|------|-------|--------------------|
| **S1** all-offloaded | both data disks on a copy-offload storage | no mirror jobs, so `clone_vm()` must establish its **own** freeze; S1b stops the guest agent to hit the **`vm_suspend` fallback** |
| **S2** mixed | one offloaded disk + one **mirrored** (non-offload) disk | `on_frozen` must fire inside the real **mirror-cutover** freeze (qemu-server#1) |
| **S3** last-disk-deferred | all offloaded, exercises the deferred-start branch | that branch runs the rendezvous itself |
| **INV-thaw** | — | the guest is **always running** after each clone (the freeze/cancel/thaw block was restructured so nothing between freeze and thaw can die) |
| **INV-consist** | — | a running multi-disk guest clones **consistent, not torn** |

**Consistency probe.** Each guest runs an in-guest writer that paints a monotonically
increasing 20-digit clock into a file on **both** data-disk filesystems (scsi1 then scsi2,
each `sync -f`'d), then increments. At a frozen instant the two files are equal — or scsi1
is exactly one ahead (the write-ordering window, hence the default tolerance `1`). A torn
(non-simultaneous) clone captures the two disks at different iterations and they diverge.
The harness reads the frozen clocks by booting the clone and reaching it over the
guest-agent virtio-serial channel (no network needed); the writer does **not** auto-restart
on the clone, so the files hold exactly the clone-time values.

## Prerequisites

1. **Both patched packages installed on the node.** Build `libpve-storage-perl` +
   `qemu-server` from the `copy-image-offload` branch
   (`/home/ciro/code/pve-upstream/{pve-storage,qemu-server}`) and install them. The
   harness preflight refuses to run unless **both** are patched — it checks the installed
   `PVE::Storage::Plugin` for the `copy_image_*` hook **and** the installed
   `PVE::QemuServer` for the deferred-copy freeze bracket. This is the central false-PASS
   guard: with stock `qemu-server`, a running clone silently falls back to **drive-mirror**
   — which is *also* consistent and never freezes — so thaw + consistency would both pass
   for a bracket that never ran. Belt-and-braces, each scenario also asserts the clone task
   log shows the `offloaded copy` marker (and, for the all-offloaded S1/S3, that **no**
   drive-mirror job ran).
2. **Deliberate node selection.** On the lab, **prod VM 2001 runs on pve-03** and pve-03
   is the only ESXi-free node. Pick the node with the least at stake. Confirm the staged
   rollback exists **before** installing: `ls /root/pre-upgrade-*/ROLLBACK.sh`.
   (Per memory: `dev-mp01-pve-03` already carries qemu-server 9.2.0 == git master and
   libpve-storage-perl 9.1.6, APIVER 15 — the series applies with no rebase.)
3. **A copy-offload-enabled RBD storage** reachable from the node (lab: `ec2-1`) — needs
   no vendor hardware. For S2, a second **non-offload** storage for the mirrored disk.
4. **A Debian cloud image** on the node with cloud-init + `qemu-guest-agent`.

## Run

```sh
# 1. Dry run first — prints the plan, touches nothing.
tools/validate-copy-offload-freeze.sh --scenarios "S1 S2 S3"

# 2. Live run on the chosen node (test VMIDs default to 79001..79099).
tools/validate-copy-offload-freeze.sh --run \
    --cloud-image /var/lib/vz/template/iso/debian-13-genericcloud-amd64.qcow2 \
    --offload-store ec2-1 \
    --mirror-store  <a-non-offload-store> \
    --scenarios "S1 S2 S3"
```

Read the `PASS:` / `FAIL:` lines. A `FAIL` on INV-thaw means the freeze/thaw block broke
(the migration-shared hazard); a `FAIL` on INV-consist means the clone was torn.

## Revert (mandatory, operator step)

The harness destroys its test VMs on exit but **does not touch the packages**. Reverting
`libpve-storage-perl` / `qemu-server` restarts `pvedaemon` on a node that hosts other
guests, so it is left to you:

```sh
/root/pre-upgrade-*/ROLLBACK.sh          # the staged exact pre-patch .debs
# or, equivalently:
apt-get install --reinstall <pre-patch libpve-storage-perl> <pre-patch qemu-server>
```

## Feeding the result upstream

A clean S1/S2/S3 + both invariants is the evidence reviewers of the 5/5 patch will ask
for (qemu-server#1, the mixed-freeze case, is explicitly called out in the RFC cover).
Post the PASS lines into the pve-devel copy-offload thread as the "not blocked —
actionable now" item.
