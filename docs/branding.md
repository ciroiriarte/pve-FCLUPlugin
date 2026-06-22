# FCLU — branding notes

Working notes on project identity. Provisional, like everything at this stage.

## Name

- **FCLU** — "First-class Logical Unit". Vendor-neutral, conveys the core idea: the
  array LU *is* the VM disk (a first-class object), not a file on a filesystem.
- Read "FC" as **First-Class**, not Fibre Channel. The architecture future-proofs for
  iSCSI / NVMe-oF (`ARCHITECTURE.md` §3), so the name must not bind to a transport.

## Taglines

- **Short (repo "About"):** *VM-granular block storage integration for Proxmox VE.*
- **Why:** *Bring enterprise SAN features — zero-copy cloning, hardware snapshots,
  per-VM storage policies — natively into the Proxmox VE ecosystem.*

## Visual motif (brief, for when an icon is wanted)

- A LUN is traditionally a 3D cylinder / block. FCLU **elevates** it: an isometric
  cylinder highlighted, raised on a pedestal, or distinctly colored (gold / bright
  orange) among gray blocks — "first-class" made literal.
- Typography: a clean monospace-inspired face (JetBrains Mono, Fira Code, Roboto Mono)
  to read as a developer/systems tool.

## CLI naming convention (if/when a unified admin CLI emerges)

- A management/diagnostics CLI may be named `fclu` (verb-noun subcommands, e.g.
  `fclu vol list`, `fclu snap ls`), with structured `--json` output that pipes cleanly
  into `jq`. This generalizes the existing `hitachiblock-repl` (see the open `fclu-repl`
  decision in `ARCHITECTURE.md`).
- **Caveat — do NOT make the PVE storage `type()` `fclu`.** Per `ARCHITECTURE.md`
  §0/§5, the registered PVE plugin type stays **per vendor** (`hitachiblock`,
  `pureblock`, …) because PVE's static `SectionConfig`/GUI model requires it and it
  preserves existing storage configs. The `fclu` brand applies to the framework, repo,
  packages, and any standalone CLI — never to the `storage.cfg` section type.

## Framing to avoid

- Do not position FCLU relative to any proprietary hypervisor or its storage-awareness
  APIs, and do not borrow that ecosystem's product vocabulary. Describe FCLU on its own
  terms — a Proxmox-native SAN integration — never as a successor to a closed stack.
