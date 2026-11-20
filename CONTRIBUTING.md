# Contributing to Tandem

Thanks for helping. Tandem is early software: small, focused changes with tests are the easiest to review.

## Ground rules

- **Be kind.** See `CODE_OF_CONDUCT.md`.
- **No code or assets from other products.** Do not copy source, decompiled code, protocol numbers, identifiers or artwork
  from Parallels Desktop, VMware Fusion, UTM or any other product unless its licence allows it and you say where it
  came from. Ideas and public documentation are fine. Tandem's own guest protocol (`protocol/PROTOCOL.md`) uses numbers of
  its own.
- **Licence.** By contributing you agree that your work is licensed under the Apache License 2.0 (`LICENSE`).
  Sign off commits with `git commit -s` (Developer Certificate of Origin).
- **Security problems** go through `SECURITY.md`, not public issues.

## Setup

Requirements: Apple silicon Mac, macOS 15 or later, Xcode (Swift 6), Rust, and `brew install qemu swtpm` for development.

```sh
cd host  && swift build && swift test
cd guest && cargo test
scripts/build-app.sh            # build/Tandem.app, signed ad hoc, for local use
```

You need no Apple developer account: builds are signed ad hoc and use the default identifiers (`local.tandem.*`). To build under your
own identifiers, see Maintainers in the README (`TANDEM_BUNDLE_PREFIX`, `TANDEM_APP_ID`). An ad hoc signed app cannot register
its helper with macOS's service manager; use `sudo scripts/install-net-helper.sh` for bridged networking and USB while developing.

Use `TANDEM_HOME=/some/folder` so test VMs stay out of your real library. Tests never need a signed app; the few that do
read `TANDEM_TEST_APP` and `TANDEM_TEST_TEAM` and skip when those are not set.

## Making a change

1. Open an issue first for anything large.
2. Keep the change focused; add or update tests (`host/Tests`, `guest/crates/*`). Run both test suites.
3. The guest protocol is shared by Swift and Rust: change `protocol/PROTOCOL.md` first, regenerate `protocol/vectors.json`
   with `protocol/gen_vectors.py`, then update both codecs.
4. Describe what you tried, and what you could not test (for example a Windows guest or real USB hardware).

## Layout

| Path | Content |
|---|---|
| `host/` | Swift package: `VMCore` (model), `EngineVZ`, `EngineQEMU`, `GuestLink`, `Provisioning`, `Sharing`, `Updater`, `TandemApp`, `vmctl`, `tandem` |
| `guest/` | Rust workspace: `link-proto` and the guest agent |
| `protocol/` | The GuestLink protocol, reference encoder and test vectors |
| `patches/` | Patches to QEMU (under QEMU's licence) |
| `scripts/` | Build, signing, packaging and release scripts |
