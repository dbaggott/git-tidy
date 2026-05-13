#!/usr/bin/env bash
# git-tidy installer — downloads the latest git-tidy script into PREFIX/bin.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/dbaggott/git-tidy/main/install.sh | bash
#
# Env overrides:
#   PREFIX  Install prefix (default: $HOME/.local). Binary goes in $PREFIX/bin.
#   REF     Git ref to install from (default: main). Use a tag like v0.1.0 for a pinned install.

set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
REF="${REF:-main}"
BINDIR="$PREFIX/bin"
URL="https://raw.githubusercontent.com/dbaggott/git-tidy/$REF/git-tidy"
TARGET="$BINDIR/git-tidy"

mkdir -p "$BINDIR"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

echo "Downloading git-tidy from $URL"
curl -fsSL "$URL" -o "$tmp"

# Sanity check: must be a bash script.
if ! head -1 "$tmp" | grep -q '^#!/usr/bin/env bash'; then
  echo "install: downloaded file does not look like git-tidy" >&2
  exit 1
fi

chmod +x "$tmp"
mv "$tmp" "$TARGET"
trap - EXIT

installed_version="$("$TARGET" --version 2>/dev/null || echo 'git-tidy (unknown)')"
echo "Installed: $TARGET ($installed_version)"

case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *)
    echo
    echo "Note: $BINDIR is not in your PATH. Add this to your shell profile:"
    echo "  export PATH=\"$BINDIR:\$PATH\""
    ;;
esac
