#!/bin/bash
# Copies a program and every non-system library it needs (Homebrew's, /usr/local's) into one folder,
# rewired to load those copies. Used for the copies of QEMU and its tools that Tandem.app carries, and for
# the copies the root helper runs (never from /opt/homebrew, /usr/local or the user's Library, which the
# user can write to).
#
#   scripts/bundle-tool.sh <program> <folder> [<check argument>]
#       -> <folder>/<program name>, <folder>/lib/*.dylib; runs "<program> <check argument>" at the end.
#
# Options, as environment variables:
#   BUNDLE_KEEP=1          add to <folder> instead of starting it afresh (several programs, one lib folder)
#   BUNDLE_LIBDIR=<dir>    where the libraries go (default <folder>/lib)
#   BUNDLE_LIBREF=<ref>    how programs name that folder (default @executable_path/lib; for QEMU's
#                          bin/ + lib/ layout: @executable_path/../lib)
#   BUNDLE_CHECK=0         do not run the program at the end
# Everything is signed ad hoc here; scripts/sign-app.sh signs the finished app properly.
set -euo pipefail
source_tool=${1:?usage: bundle-tool.sh <program> <folder> [<check argument>]}
dest=${2:?usage: bundle-tool.sh <program> <folder> [<check argument>]}
check=${3:---help}
libdir=${BUNDLE_LIBDIR:-$dest/lib}
libref=${BUNDLE_LIBREF:-@executable_path/lib}
[ -x "$source_tool" ] || { echo "not a program: $source_tool" >&2; exit 1; }
realpath_() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
source_tool=$(realpath_ "$source_tool")
name=$(basename "$source_tool")

[ "${BUNDLE_KEEP:-0}" = 1 ] || rm -rf "$dest"
mkdir -p "$dest" "$libdir"
rm -f "$dest/$name"
cp "$source_tool" "$dest/$name"
chmod u+w "$dest/$name"

# Non-system libraries a Mach-O file links, as written in its load commands.
# @rpath/<name>.framework/… are frameworks the caller ships next to the program (the 3D QEMU's Frameworks/),
# not Homebrew libraries, so they are left as they are.
brew_deps() { otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -E '^(/opt/homebrew|/usr/local|@rpath|@loader_path)/' \
  | grep -v -E '^@rpath/[^/]+\.framework/' || true; }

resolve() {
  # Turns a load-command path into a real file. @rpath and @loader_path are resolved against the file that
  # names them: Homebrew's own libraries only use them for siblings in their lib folder.
  local name=$1 from=$2
  case "$name" in
    @rpath/*|@loader_path/*) local base=${name#*/}
      for dir in "$(dirname "$from")" /opt/homebrew/lib /usr/local/lib; do [ -f "$dir/$base" ] && { realpath_ "$dir/$base"; return; }; done
      echo "cannot resolve $name for $from" >&2; return 1 ;;
    *) realpath_ "$name" ;;
  esac
}

queue=("$dest/$name")
origin=("$source_tool")
while [ ${#queue[@]} -gt 0 ]; do
  file=${queue[0]}; from=${origin[0]}
  queue=("${queue[@]:1}"); origin=("${origin[@]:1}")
  for dep in $(brew_deps "$file"); do
    real=$(resolve "$dep" "$from")
    base=$(basename "$real")
    if [ ! -f "$libdir/$base" ]; then
      cp "$real" "$libdir/$base"
      chmod u+w "$libdir/$base"
      install_name_tool -id "$libref/$base" "$libdir/$base" 2>/dev/null
      # Homebrew leaves some run paths into its Cellar (libjpeg-turbo); the copy must not search there.
      for rp in $(otool -l "$libdir/$base" | awk '/LC_RPATH/ {getline; getline; print $2}' | grep -E '^(/opt/homebrew|/usr/local)/' || true); do
        install_name_tool -delete_rpath "$rp" "$libdir/$base" 2>/dev/null
      done
      queue+=("$libdir/$base"); origin+=("$real")
    fi
    install_name_tool -change "$dep" "$libref/$base" "$file" 2>/dev/null
  done
done

# Rewriting load commands breaks the signatures; sign every file again (ad hoc).
for f in "$libdir"/*.dylib "$dest/$name"; do codesign --force --sign - "$f" 2>/dev/null; done
if [ "${BUNDLE_CHECK:-1}" = 1 ]; then
  "$dest/$name" "$check" >/dev/null 2>&1 || { echo "the bundled $name does not run" >&2; exit 1; }
fi
echo "$dest/$name ($(ls "$libdir" | wc -l | tr -d ' ') libraries in $(basename "$libdir"))"
