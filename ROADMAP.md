# Roadmap

Rough, unordered, and honest: nothing here is a promise. See `README.md` for what works today.

## Release and distribution
- Switch on the automatic-update feed (needs a published signing key and feed address)

## Hardware and graphics
- Full USB pass-through of arbitrary devices (needs Apple's `com.apple.vm.device-access` entitlement, which has been requested)
- Windows 3D: the signed driver offers a fixed list of screen sizes, so resizing while running needs a driver that adds modes; hardware video decoding; Direct3D 12 and Vulkan routes
- Linux 3D: lower read-back cost at large sizes
- Seamless mode for 3D Windows VMs
- Shared printers, camera pass-through

## Guest integration
- macOS guests: more testing of the guest tools (clipboard, restart, clock after resume, suspend with the tools disc attached)
- Linux guests: real drag and drop from any program (XDND), per-window capture for Seamless mode, Wayland sessions
- Windows: drag-out from the Windows desktop and from more programs; more editions, languages and time zones in the unattended install
- Guest tools: non-English command output, per-VM version and update status

## Installing and importing
- Installing macOS from a restore image you already have
- Templates tested for more Linux distributions
- Importers for other VM formats (VMware Fusion, UTM)

## App
- Live network changes for macOS guests
- A full VoiceOver pass and more translations
- Splitting the large application model into smaller, testable services

## Known limitations
- The AI-tools switch is a policy, not a sandbox (see `SECURITY.md`)
- Provisioning a new VM does not hold the per-VM lock outside its QEMU runs
- Some tests need local sockets, disk images or a signed app and are skipped or flaky on hosted CI runners
