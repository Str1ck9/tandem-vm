#!/bin/sh
# Switches on (or off) the names of published guest services: <vm>.tandem.test.
#
#   sudo scripts/install-local-names.sh              switch on
#   sudo scripts/install-local-names.sh --uninstall  switch off
#
# What it does: writes one small file, /etc/resolver/tandem.test, which tells macOS to ask Tandem
# (on 127.0.0.1, port 53535) about names that end in .tandem.test. Tandem answers 127.0.0.1 for all of
# them while a VM with published services runs. Nothing else on the Mac is changed, no program is
# installed, and no other names are affected. Without it, published services are reached as
# localhost:<port> or <vm>.localhost:<port>.
set -eu

FILE=/etc/resolver/tandem.test
PORT=53535

if [ "$(id -u)" -ne 0 ]; then
  echo "This must run as root. Run it again with sudo in front." >&2
  exit 1
fi

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$FILE"
  echo "Names under tandem.test are switched off."
  exit 0
fi

mkdir -p /etc/resolver
printf '# Tandem: names of published guest services\nnameserver 127.0.0.1\nport %s\n' "$PORT" > "$FILE"
chmod 0644 "$FILE"
echo "Names under tandem.test are switched on. Try:  dscacheutil -q host -a name test.tandem.test"
