# PVE FCLU — First-class Logical Unit storage framework

> **📝 DRAFT.** This is an early-stage draft. The repository currently holds a
> **design proposal only** — no implementation. Everything here (interfaces, naming,
> layering, decisions) is provisional and expected to change as the design is reviewed
> and the migration begins. Do not treat it as stable or final.

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

> ### ⚠️ Project status: design phase
>
> This repository currently contains the **architecture proposal only** — no
> implementation yet. The reference implementation lives in `pve-HitachiBlockPlugin`
> and will be refactored into this framework following the staged migration in
> [`ARCHITECTURE.md`](ARCHITECTURE.md) §9, keeping the Hitachi driver working and its
> tests green throughout.

## Start here

- **[`ARCHITECTURE.md`](ARCHITECTURE.md)** — the full proposal: layering, the driver
  and host-connector interfaces, per-model/generation specialization, PVE config-schema
  integration, capability negotiation, the registry, replication, the migration path,
  and the risk register.

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
