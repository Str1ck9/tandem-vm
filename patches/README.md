# Patches to QEMU

These patches modify QEMU (and, for `qemu-10.0.12-utm-*`, UTM's QEMU fork). They are derived from QEMU and are therefore
licensed under **QEMU's licence (GNU GPL version 2, with the licences of the individual files)**, not under this
repository's Apache-2.0 licence. They apply to:

| File | Applies to | Purpose |
|---|---|---|
| `qemu-11.1.3-hvf-unknown-smc.patch` | QEMU 11.1.3 | Windows 11 22H2 boot manager: tolerate a firmware call QEMU's HVF accelerator faults |
| `qemu-11.1.3-usb-cdc-acm.patch` | QEMU 11.1.3 | A `usb-cdc-acm` device that presents a host serial port with its own USB IDs |
| `qemu-11.1.3-parallels-readonly-migration.patch` | QEMU 11.1.3 | Lets a read-only image in QEMU's `parallels` format be a backing file of a VM whose state is saved and resumed |
| `qemu-10.0.12-utm-egl-headless-darwin.patch` | UTM's QEMU 10.0.12 | `egl-headless` display on macOS (3D build) |
| `qemu-10.0.12-utm-virtio-gpu-shm-scanout.patch` | UTM's QEMU 10.0.12 | virtio-gpu shared-memory scanout (3D build) |

`scripts/build-qemu.sh` and `scripts/build-qemu-3d.sh` fetch the upstream sources and apply them. Binary builds of Tandem that
include QEMU come with the obligations described in `THIRD_PARTY_NOTICES.md` (source availability).
