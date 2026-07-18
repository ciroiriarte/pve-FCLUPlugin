# PVE FCLU — First-class Logical Unit storage framework

*Bring enterprise SAN features — zero-copy cloning, hardware snapshots, per-VM storage
policies — natively into the Proxmox VE ecosystem.*

[![OBS build (PVE 9)](https://build.opensuse.org/projects/home:ciriarte:pve-FCLUPlugin/packages/pve-fclu/badge.svg?type=default)](https://build.opensuse.org/package/show/home:ciriarte:pve-FCLUPlugin/pve-fclu)

> ### ⚠️ Project status: alpha
>
> The framework is **implemented and packaged** — the generic core, the Hitachi
> reference driver, the `type: hitachiblock` plugin (`FCLU::Plugin` cutover), and the
> multi-binary Debian packaging are in place, with **214 unit tests** green against
> fakes and simulators.
>
> It has been **validated live on a Hitachi VSP E590H** cluster, well past the core
> data path:
>
> - package swap + registry migration, alloc/map/IO/free, online resize;
> - hardware snapshots, Thin Image linked clones, and multi-disk `qm clone`;
> - **crash-consistent consistency-group snapshots** (hardware CTG);
> - a **destructive/robustness battery** — migration and adopt/release, manage/unmanage,
>   concurrent-lock and persistent-reservation readiness, and byte-verified data
>   integrity under load with no corruption;
> - both control planes: the array's **embedded** REST endpoint and **Ops Center
>   Configuration Manager**.
>
> **Why it is still alpha:** the multi-vendor claim is unproven. There is exactly one
> production driver (Hitachi) plus a mock, so the vendor-neutral abstraction has never
> been exercised by a second array vendor; replication remains a design, not an
> implementation. It has not been validated against other arrays or at production
> scale — treat it as lab/test only until verified on your own hardware.

A vendor-neutral [Proxmox VE](https://www.proxmox.com/) storage framework that
delivers **first-class per-virtual-disk volume** service over Fibre Channel: **one array LUN per virtual
disk**, with array-offloaded snapshots, copy-on-write linked clones, online resize,
per-volume QoS, and replication. The generic core is shared; each storage vendor
plugs in through a thin driver.

It generalizes [`pve-HitachiBlockPlugin`](https://github.com/ciroiriarte/pve-HitachiBlockPlugin)
— a working single-vendor (Hitachi VSP) plugin — into a framework where Dell
PowerMax/PowerStore, Pure Storage FlashArray, IBM FlashSystem, NetApp, and others are
added as drivers that reuse the generic orchestration, registry, and host-side FC
connector.

## Quick start

Install from the [OBS](https://build.opensuse.org/package/show/home:ciriarte:pve-FCLUPlugin/pve-fclu)
repository on each PVE 9 node (Debian 13 / Trixie base) — pick the driver package for
your array; it pulls `pve-fclu-core` transitively:

```bash
echo 'deb http://download.opensuse.org/repositories/home:/ciriarte:/pve-FCLUPlugin/PVE_9/ /' \
  > /etc/apt/sources.list.d/pve-fclu.list
curl -fsSL 'https://download.opensuse.org/repositories/home:/ciriarte:/pve-FCLUPlugin/PVE_9/Release.key' \
  | gpg --dearmor > /etc/apt/trusted.gpg.d/home_ciriarte_pve-fclu.gpg
apt update && apt install pve-fclu-hitachi
systemctl restart pvedaemon
```

`pve-fclu-hitachi` supersedes the standalone `pve-storage-hitachiblock` package;
existing `type: hitachiblock` storage.cfg entries keep working. It currently ships an
**alpha** build — see the status note above and
[`docs/packaging-obs.md`](docs/packaging-obs.md) for packaging details.

Or build and install from source on each node:

```bash
make install    # or: make deb && dpkg -i ../pve-fclu-*_all.deb
systemctl restart pvedaemon
```

## Start here

- **[`ARCHITECTURE.md`](ARCHITECTURE.md)** — the full proposal: layering, the driver
  and host-connector interfaces, per-model/generation specialization, PVE config-schema
  integration, capability negotiation, the registry, replication, the migration path,
  and the risk register.

### Operator documentation

- **[`docs/user-guide.md`](docs/user-guide.md)** — vendor-neutral install, `storage.cfg`
  configuration, multipath requirements, multi-cluster shared-pool safety, operational
  behavior, and troubleshooting.
- **[`docs/driver-hitachi.md`](docs/driver-hitachi.md)** — Hitachi VSP driver: platform
  profiles, the `ldev_range` fence, host-access, Thin Image snapshots/clones, QoS/PR,
  and the CM REST transport.
- **[`docs/migration-hitachi.md`](docs/migration-hitachi.md)** — zero-window swap from
  `pve-storage-hitachiblock` and rollback.
- **[`docs/packaging-obs.md`](docs/packaging-obs.md)** — the OBS build/release pipeline.

## Design provenance

The architecture was produced as a **joint multi-model review**: drafted by Claude from
a full read of the Hitachi plugin, then cross-checked against two independent reviews of
the same brief. The inputs are preserved for traceability:

- [`docs/architecture/brief.md`](docs/architecture/brief.md) — the shared 10-point brief.
- [`docs/architecture/review-codex.md`](docs/architecture/review-codex.md) — Codex review.
- [`docs/architecture/review-gemini.md`](docs/architecture/review-gemini.md) — agy / Gemini 3.1 Pro review.

## Core design decisions (summary)

- **Vendor-neutral internally, one thin PVE plugin type per vendor** — not a single
  dynamic `type: fclu`. PVE's static `SectionConfig` schema and per-type GUI dialogs
  make per-vendor subclasses over a shared `PVE::Storage::FCLU::*` core the right shape.
- **Three layers:** array `Driver`, host `Connector`, and a generic `Plugin` +
  `Registry` + `Capabilities` spine.
- **Array-reported canonical WWID** (NAA/EUI) instead of vendor-specific synthesis.
- **Driver + profile/quirk** pattern for intra-brand model/microcode drift — no
  driver-per-model explosion.
- **Capability negotiation** drives `volume_has_feature` and the GUI per backend.
- **Replication** stays an optional per-driver extension, not part of the base contract.

## License

[GNU AGPL v3](LICENSE), matching the Hitachi plugin it derives from.

## Author

Ciro Iriarte &lt;ciro.iriarte+software@gmail.com&gt;
