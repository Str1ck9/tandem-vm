#!/usr/bin/env python3
"""Removes the build machine's absolute paths from a packaged Tandem.app, before it is signed.

QEMU and some libraries have the folders they were built in compiled in as text (assertion messages, data
directories), and QEMU's firmware descriptions list full paths. They are harmless when the app runs, but they
would publish the name of whoever built the release. This replaces every occurrence of the given paths with a
neutral string of the SAME LENGTH (so nothing in a program moves), in every file of the app. Nothing changes
when nothing matches, so it is safe for anyone's build.

  scripts/neutralize-paths.py <Tandem.app> [extra path ...]

The paths replaced, longest first: the extra paths given, the paths in TANDEM_NEUTRALIZE_PATHS (separated by
":"), and the home folder of the user running the build. Sign the app afterwards: changing a signed file
breaks its signature.
"""
import os
import sys


def neutral(n: int) -> bytes:
    """A harmless path of exactly n bytes."""
    return ("/build" + "/_" * n)[:n].encode()


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    app = sys.argv[1]
    paths = list(sys.argv[2:])
    paths += [p for p in os.environ.get("TANDEM_NEUTRALIZE_PATHS", "").split(":") if p]
    home = os.path.expanduser("~")
    if home not in ("", "/", "/var/root"):
        paths.append(home)
    # Longest first, so that "/Users/x/src/tandem" goes before "/Users/x".
    needles = sorted({p.rstrip("/").encode() for p in paths if len(p.rstrip("/")) >= 6}, key=len, reverse=True)
    if not needles:
        return 0
    changed = 0
    for dirpath, _dirs, files in os.walk(app):
        for name in files:
            path = os.path.join(dirpath, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            try:
                with open(path, "rb") as f:
                    data = f.read()
            except OSError:
                continue
            new = data
            for needle in needles:
                if needle in new:
                    new = new.replace(needle, neutral(len(needle)))
            if new != data:
                assert len(new) == len(data)
                mode = os.stat(path).st_mode
                os.chmod(path, mode | 0o200)
                with open(path, "wb") as f:
                    f.write(new)
                os.chmod(path, mode)
                changed += 1
    print(f"neutralize-paths: changed {changed} file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
