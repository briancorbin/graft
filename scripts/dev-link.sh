#!/usr/bin/env bash
#
# Build, stably-sign, and symlink the local dev binary as `graft-dev`.
#
# Why sign? `swift build` ad-hoc-signs the binary, which gets a *new* code hash on
# every build. The macOS Keychain ACL that authorizes graft to read the GitHub App
# key is keyed to the binary's designated requirement — so an ad-hoc rebuild
# invalidates your "Always Allow" and re-prompts every single time. Signing with a
# stable identity keeps the requirement constant, so "Always Allow" sticks for good.
#
# Run this instead of `swift build -c release` whenever you want to refresh graft-dev.
# Override the identity with GRAFT_SIGN_IDENTITY, or the link path with GRAFT_DEV_LINK.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY="${GRAFT_SIGN_IDENTITY:-Developer ID Application: Brian Corbin (27N85AU6XK)}"
LINK="${GRAFT_DEV_LINK:-/opt/homebrew/bin/graft-dev}"
BIN="$REPO/.build/release/graft"

cd "$REPO"

echo "▸ building release…"
swift build -c release

echo "▸ signing with: $IDENTITY"
codesign --force --sign "$IDENTITY" "$BIN"

ln -sf "$BIN" "$LINK"

echo "▸ graft-dev → $BIN"
echo "✓ done. The first key read will prompt once for keychain access — click"
echo "  \"Always Allow\" and, because the signature is now stable, it won't ask again."
