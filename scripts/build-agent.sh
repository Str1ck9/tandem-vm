#!/bin/sh
# Builds the guest agent for Linux arm64 (static musl), macOS arm64 and Windows arm64.
# The Windows build needs llvm-mingw unpacked under .cache/toolchains/ (see docs/spikes/phase0-findings.md).
# The macOS agent is signed with the first "Developer ID Application" identity in the keychain
# (TANDEM_SIGN_IDENTITY overrides), else ad hoc; a packaged app signs it again (scripts/sign-app.sh).
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/scripts/identity.sh"
cd "$root/guest"
cargo build --release --target aarch64-unknown-linux-musl -p tandem-agent
echo "$root/guest/target/aarch64-unknown-linux-musl/release/tandem-agent"
cargo build --release --target aarch64-apple-darwin -p tandem-agent --features macos-guest
mac_agent="$root/guest/target/aarch64-apple-darwin/release/tandem-agent"
identity=${TANDEM_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')}
codesign --force --sign "${identity:--}" --options runtime --identifier "$TANDEM_BUNDLE_PREFIX.agent" --timestamp=none "$mac_agent"
echo "$mac_agent"
mingw="$(ls -d "$root"/.cache/toolchains/llvm-mingw-*/bin 2>/dev/null | tail -1 || true)"
if [ -z "$mingw" ]; then
  echo "skipping Windows build: llvm-mingw not found under .cache/toolchains/" >&2
  exit 0
fi
# crt-static links libunwind into the exe; otherwise it needs libunwind.dll, which Windows does not have.
PATH="$mingw:$PATH" CARGO_TARGET_AARCH64_PC_WINDOWS_GNULLVM_LINKER=aarch64-w64-mingw32-clang \
  CARGO_TARGET_AARCH64_PC_WINDOWS_GNULLVM_RUSTFLAGS="-C target-feature=+crt-static" \
  cargo build --release --target aarch64-pc-windows-gnullvm -p tandem-agent
echo "$root/guest/target/aarch64-pc-windows-gnullvm/release/tandem-agent.exe"
