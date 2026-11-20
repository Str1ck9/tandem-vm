#!/bin/sh
# Builds the Linux agent, puts it on a cloud-init seed ISO, and runs `vmctl agent-test` on both engines.
# Needs .cache/images/alpine-arm64.qcow2 (see docs/spikes/phase0-findings.md).
set -eu
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$root/.cache/agent-test"
export TANDEM_HOME="$root/.cache/tandem-test"
vmctl="$("$root/scripts/build.sh" | tail -1)"
(cd "$root/guest" && cargo build --release --target aarch64-unknown-linux-musl -p tandem-agent)
rm -rf "$work" && mkdir -p "$work/seed"
cp "$root"/scripts/agent-test/seed/* "$work/seed/"
cp "$root/guest/target/aarch64-unknown-linux-musl/release/tandem-agent" "$work/seed/"
hdiutil makehybrid -quiet -o "$work/seed.iso" "$work/seed" -iso -joliet -default-volume-name cidata
qemu-img convert -f qcow2 -O raw "$root/.cache/images/alpine-arm64.qcow2" "$work/alpine.raw"
status=0
for engine in vz qemu; do
  name="agent-test-$engine"
  "$vmctl" delete "$name" --force >/dev/null 2>&1 || true
  if [ "$engine" = vz ]; then disk="$work/alpine.raw"; else disk="$root/.cache/images/alpine-arm64.qcow2"; fi
  "$vmctl" create "$name" --os linux --engine "$engine" --cpus 2 --memory 1024 --disk 2 --seed "$work/seed.iso" --import-disk "$disk" >/dev/null
  echo "== $engine =="
  "$vmctl" agent-test "$name" | grep -v '^state' || status=1
  "$vmctl" delete "$name" --force >/dev/null
done
exit $status
