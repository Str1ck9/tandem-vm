# Roadmap

Rough, unordered, and honest: nothing here is a promise. See `README.md` for what works today.

## Release and distribution
- Notarised, signed releases and the automatic-update feed on a public repository
- Continuous integration that runs the portable test suites on every pull request

## Hardware and graphics
- Full USB pass-through of arbitrary devices (needs Apple's `com.apple.vm.device-access` entitlement)
- Windows 3D: resizing while running, display scaling on Retina-sized boots, hardware video decoding, Direct3D 12 and Vulkan routes
- Linux 3D: lower read-back cost at large sizes
- Seamless mode for 3D Windows VMs
- Shared printers, camera pass-through

## Guest integration
- macOS guests: more testing of the guest tools (clipboard, restart, clock after resume, suspend with the tools disc attached)
- Linux guests: Seamless mode and Mac-side launchers for Linux programs; drag and drop
- Windows: drag-out from the Windows desktop and from more programs; more editions, languages and time zones in the unattended install
- Guest tools: non-English command output, per-VM version and update status

## Installing and importing
- Installing macOS from a restore image you already have
- Templates tested for more Linux distributions
- Importers for other VM formats (VMware Fusion, UTM)

## App
- Live network changes without a restart
- Accessibility pass (VoiceOver, keyboard navigation) and localisation
- Splitting the large application model into smaller, testable services

## Known limitations
- The AI-tools switch is a policy, not a sandbox (see `SECURITY.md`)
- Provisioning a new VM does not hold the per-VM lock outside its QEMU runs
- Some tests need local sockets, disk images or a signed app and are skipped or flaky on hosted CI runners
