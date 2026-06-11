#!/usr/bin/env bash
#
# Example provisioning script run in the guest by `graft image build` when a recipe
# uses "script": "provision.sh". A real build-image.sh lives in your repo and is the
# single source of truth. This is a generic starting point — adjust the versions.
#
set -euo pipefail

NODE_VERSION="20"
RUBY_VERSION="3.3.5"

echo "==> Pin Node $NODE_VERSION (the cirruslabs xcode image ships fnm)"
eval "$(fnm env)"
fnm install "$NODE_VERSION"
fnm default "$NODE_VERSION"
corepack enable

echo "==> Pin Ruby $RUBY_VERSION (rbenv ships in the image)"
rbenv install -s "$RUBY_VERSION"
rbenv global "$RUBY_VERSION"
gem install bundler --no-document

# fnm's node lives under a per-shell path that non-login shells and Xcode build
# phases can't see. Expose it at a stable location on the default PATH.
echo "==> Expose node at /usr/local/bin"
NODE_REAL="$(node -e 'console.log(require("fs").realpathSync(process.execPath))')"
sudo mkdir -p /usr/local/bin
for b in node npm npx; do
  [ -e "$(dirname "$NODE_REAL")/$b" ] && sudo ln -sf "$(dirname "$NODE_REAL")/$b" "/usr/local/bin/$b"
done

echo "==> Install Xcode first-launch components headlessly"
sudo xcodebuild -runFirstLaunch

echo "✅ image ready"
