#!/bin/bash
# Removes Tandem from this Mac: the helper, its leftovers in system folders, Tandem's settings, the
# downloads and caches in its library folder, the `tandem` link, and the app (to the Trash). The VM
# library stays unless --remove-vms is given and confirmed by typing; VMs then go to the Trash, not away.
# Tandem > Uninstall Tandem… in the app does the same, and also unregisters the in-app helper with macOS.
#
#   scripts/uninstall.sh --dry-run               show what would be removed, with sizes; change nothing
#   scripts/uninstall.sh                         uninstall, keeping the VMs (asks you to type "uninstall")
#   scripts/uninstall.sh --remove-vms            also move the VM library to the Trash (asks again, with the path)
#   --app <path>      the app to remove (default /Applications/Tandem.app)
#   --keep-caches     leave the library's downloads and caches
#
# TANDEM_BUNDLE_PREFIX / TANDEM_APP_ID name the build to remove (default local.tandem; see scripts/identity.sh).
# TANDEM_HOME (a test library) limits it to that folder: the helper, settings, link and app are left alone.
# Root-owned leftovers are removed with sudo, which asks for your password once.
set -euo pipefail

dry=0; remove_vms=0; keep_caches=0; app=/Applications/Tandem.app
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --remove-vms) remove_vms=1 ;;
    --keep-caches) keep_caches=1 ;;
    --app) shift; app=${1:?--app needs a path} ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

. "$(cd "$(dirname "$0")" && pwd)/identity.sh"
id=$TANDEM_APP_ID
helper_labels="$TANDEM_BUNDLE_PREFIX.helper $TANDEM_BUNDLE_PREFIX.nethelper"
test_library=0
if [ -n "${TANDEM_HOME:-}" ]; then root=$TANDEM_HOME; test_library=1; else root="$HOME/Library/Application Support/Tandem"; fi
root=${root%/}
default_vms="$root/VMs"
chosen_vms=""
if [ -f "$root/registry.json" ]; then
  chosen_vms=$(/usr/bin/plutil -extract vmsDirectory raw -o - "$root/registry.json" 2>/dev/null || true)
fi
vms_folders=("$default_vms")
if [ -n "$chosen_vms" ] && [ "${chosen_vms%/}" != "$default_vms" ]; then vms_folders+=("${chosen_vms%/}"); fi

size() { if [ -e "$1" ] || [ -L "$1" ]; then du -sh "$1" 2>/dev/null | awk '{print $1}'; else echo "-"; fi; }
say() { printf '%s\n' "$*"; }
run() { if [ $dry = 1 ]; then say "  would: $*"; else "$@"; fi; }
trash() { if [ $dry = 1 ]; then say "  would move to the Trash: $1"; else /usr/bin/trash "$1"; fi; }

# --- What is there ---
system_files=()
user_files=()
if [ $test_library = 0 ]; then
  p=$TANDEM_BUNDLE_PREFIX
  for f in "/Library/LaunchDaemons/$p.nethelper.plist" "/Library/PrivilegedHelperTools/$p.nethelper" \
           "/Library/PrivilegedHelperTools/$p.usbredirect" "/Library/PrivilegedHelperTools/$p.qemu-nbd"; do
    if [ -e "$f" ] || [ -L "$f" ]; then system_files+=("$f"); fi
  done
  for f in /var/run/tandem-net.sock /var/log/tandem-nethelper.log /etc/resolver/tandem.test /var/run/tandem-net-*; do
    if [ -e "$f" ] || [ -L "$f" ]; then system_files+=("$f"); fi
  done
  for i in "$id"; do
    for f in "$HOME/Library/Preferences/$i.plist" "$HOME/Library/Saved Application State/$i.savedState" \
             "$HOME/Library/Caches/$i" "$HOME/Library/HTTPStorages/$i" "$HOME/Library/WebKit/$i"; do
      if [ -e "$f" ]; then user_files+=("$f"); fi
    done
  done
  if [ -e "$HOME/Applications/Tandem" ]; then user_files+=("$HOME/Applications/Tandem"); fi
  for link in /opt/homebrew/bin/tandem "$HOME/.local/bin/tandem"; do
    if [ -L "$link" ] && readlink "$link" | grep -q '\.app/'; then user_files+=("$link"); fi
  done
fi
caches=()
if [ -d "$root" ]; then
  while IFS= read -r -d '' entry; do
    name=$(basename "$entry")
    case "$name" in VMs|registry.json|.DS_Store) continue ;; esac
    skip=0; for v in "${vms_folders[@]}"; do [ "$entry" = "$v" ] && skip=1; done
    [ $skip = 1 ] || caches+=("$entry")
  done < <(find "$root" -mindepth 1 -maxdepth 1 -print0 | sort -z)
fi
vms=()
for folder in "${vms_folders[@]}"; do
  [ -d "$folder" ] || continue
  while IFS= read -r -d '' b; do vms+=("$b"); done < <(find "$folder" -mindepth 1 -maxdepth 1 -name '*.tandemvm' -print0 | sort -z)
done
home_links=()
if [ $test_library = 0 ]; then
  for l in "$HOME"/*; do
    [ -L "$l" ] || continue
    t=$(readlink "$l")
    for v in "${vms_folders[@]}" "$root"; do [ "${t%/}" = "$v" ] && home_links+=("$l"); done
  done
fi

say "Tandem uninstall$( [ $dry = 1 ] && echo ' (dry run: nothing is changed)')"
[ $test_library = 1 ] && say "Test library (TANDEM_HOME=$root): the helper, settings, link and app are left alone."
say ""
if [ $test_library = 0 ]; then
  say "Always removed:"
  say "  helper launchd jobs: $(for l in $helper_labels; do printf 'system/%s ' "$l"; done)(in-app and script)"
  for f in "${system_files[@]+"${system_files[@]}"}"; do say "  $(size "$f")	$f (root)"; done
  for f in "${user_files[@]+"${user_files[@]}"}"; do say "  $(size "$f")	$f"; done
  [ -d "$app" ] && say "  $(size "$app")	$app (to the Trash)"
  say ""
fi
say "Downloads and caches$( [ $keep_caches = 1 ] && echo ' (kept: --keep-caches)'):"
for f in "${caches[@]+"${caches[@]}"}"; do say "  $(size "$f")	$f"; done
[ ${#caches[@]} = 0 ] && say "  none"
say ""
say "VM library: $( [ $remove_vms = 1 ] && echo 'MOVED TO THE TRASH (--remove-vms)' || echo 'kept')"
for v in "${vms_folders[@]}"; do say "  folder: $v"; done
for f in "${vms[@]+"${vms[@]}"}"; do say "  $(size "$f")	$f"; done
for l in "${home_links[@]+"${home_links[@]}"}"; do say "  link: $l"; done
say ""

# --- Confirm ---
if [ $dry = 0 ]; then
  if pgrep -qx Tandem; then echo "Quit Tandem first (its VMs would stop with it)." >&2; exit 1; fi
  read -r -p "Type \"uninstall\" to go ahead: " answer
  [ "$answer" = uninstall ] || { echo "Nothing was changed."; exit 1; }
  if [ $remove_vms = 1 ] && [ ${#vms[@]} -gt 0 ]; then
    say "This moves ${#vms[@]} virtual machines in ${vms_folders[*]} to the Trash, with their disks and snapshots."
    read -r -p "Type the VMs folder path ($default_vms) to confirm: " answer
    [ "${answer%/}" = "$default_vms" ] || { echo "The VMs are kept."; remove_vms=0; }
  fi
fi

# --- Do it ---
if [ $test_library = 0 ]; then
  loaded=0
  for l in $helper_labels; do launchctl print "system/$l" >/dev/null 2>&1 && loaded=1; done
  if [ $loaded = 1 ] || [ ${#system_files[@]} -gt 0 ]; then
    say "The helper and its files (sudo asks for your password):"
    for l in $helper_labels; do run sudo launchctl bootout "system/$l" 2>/dev/null || true; done
    [ ${#system_files[@]} -gt 0 ] && run sudo rm -rf "${system_files[@]}"
  fi
  if [ $dry = 0 ]; then defaults delete "$id" >/dev/null 2>&1 || true; fi
  for f in "${user_files[@]+"${user_files[@]}"}"; do run rm -rf "$f"; done
fi
if [ $keep_caches = 0 ]; then for f in "${caches[@]+"${caches[@]}"}"; do run rm -rf "$f"; done; fi
if [ $remove_vms = 1 ]; then
  for f in "${vms[@]+"${vms[@]}"}"; do trash "$f"; done
  for l in "${home_links[@]+"${home_links[@]}"}"; do run rm -f "$l"; done
  run rm -f "$root/registry.json"
  for v in "${vms_folders[@]}" "$root"; do run rmdir "$v" 2>/dev/null || true; done
fi
if [ $test_library = 0 ] && [ -d "$app" ]; then
  trash "$app"
  say "The Login Items entry for Tandem's helper goes away with the app."
fi
say "$( [ $dry = 1 ] && echo 'Dry run finished; nothing was changed.' || echo 'Tandem is uninstalled.')"
