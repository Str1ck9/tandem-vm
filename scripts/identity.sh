# Sourced by the build scripts (not run): the identifiers of this build.
#
#   TANDEM_BUNDLE_PREFIX   the prefix of the helper, the bundled tools, the guest agent and the document type
#                          (default: local.tandem)
#   TANDEM_APP_ID          the app's own bundle identifier (default: $TANDEM_BUNDLE_PREFIX.app)
#
# The defaults are fine for building and running Tandem yourself. To make builds under your own name
# (for example to ship them), set both before running any script, for instance:
#
#   export TANDEM_BUNDLE_PREFIX=com.example.tandem TANDEM_APP_ID=com.example.tandem
#
# scripts/build-app.sh writes them into the app's Info.plist, and the app, its helper and its command-line
# tool read them from there, so the whole build stays consistent. Use the same values for every script of
# one build (and for `sudo scripts/install-net-helper.sh`, which sudo does not pass them to by itself:
# `sudo TANDEM_BUNDLE_PREFIX=... TANDEM_APP_ID=... scripts/install-net-helper.sh`).
TANDEM_BUNDLE_PREFIX=${TANDEM_BUNDLE_PREFIX:-local.tandem}
TANDEM_APP_ID=${TANDEM_APP_ID:-$TANDEM_BUNDLE_PREFIX.app}
# Letters, digits, dots, dashes, underscores: the values end up in file names, launchd labels and code
# signing requirements.
case "$TANDEM_BUNDLE_PREFIX$TANDEM_APP_ID" in
  *[!A-Za-z0-9._-]*|'') echo "TANDEM_BUNDLE_PREFIX and TANDEM_APP_ID may only contain letters, digits, '.', '-' and '_'." >&2; exit 2 ;;
esac
case "$TANDEM_BUNDLE_PREFIX" in -*|.*) echo "TANDEM_BUNDLE_PREFIX must start with a letter or digit." >&2; exit 2 ;; esac
case "$TANDEM_APP_ID" in -*|.*) echo "TANDEM_APP_ID must start with a letter or digit." >&2; exit 2 ;; esac
export TANDEM_BUNDLE_PREFIX TANDEM_APP_ID
