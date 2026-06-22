I've created a comprehensive architecture proposal detailing the extraction of the Hitachi PVE storage plugin into the multi-vendor "First-class Logical Unit" (FCLU) framework. 

You can read the full proposal here: [fclu_architecture_proposal.md](file:///home/ciro/.gemini/antigravity-cli/brain/9cc6e53c-82c0-462d-817c-8499ea00cc5e/fclu_architecture_proposal.md)

Here are some highlights from the proposed architecture:

1. **Layering & Module Decomposition**: The architecture separates the PVE integration layer (`FCLUPlugin`), the generic orchestration core (`Registry` and `HostConnector`), and the vendor-specific array backend drivers (`Driver::Base` and `Driver::<Vendor>`).
2. **The Driver Interface**: I've defined a minimal, vendor-neutral interface for array backends covering capabilities, CRUD on LUs, identification (canonical WWIDs), host mapping, and snapshot creation.
3. **The Host Connector**: The multipath logic becomes vendor-agnostic by no longer synthesizing WWIDs based on Hitachi semantics, but relying directly on the driver to report the array's canonical NAA/EUI, bringing robustness and paving the way for iSCSI/NVMe-oF in the future.
4. **Per-Model Specialization**: To prevent driver explosions (e.g., separating VSP_E from VSP_5000), the driver uses a capability profile/trait pattern loaded at login to handle quirks and minor differences.
5. **Config Schema**: Rather than a monolithic `type: fclu` plugin risking PVE `SectionConfig` crashes from duplicate property definitions across all vendors, the design opts for **one thin PVE plugin subclass per vendor** inheriting from the core `FCLUPlugin`.
6. **Capability Negotiation**: Feature flags retrieved via the driver interface inform PVE whether to display/hide capabilities like snapshots and QoS.
7. **Replication**: I recommend keeping enterprise replication as an optional per-driver capability rather than abstracting it away completely, to avoid creating a leaky abstraction for vastly different topologies like SRDF and GAD.

Let me know if you would like to refine any of these design decisions or if you're ready to proceed with the migration!
