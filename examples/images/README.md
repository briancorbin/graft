# Example image recipes

Starting points for `graft image build` — generic, meant to be adapted. Pin the
versions to match your project's lockfiles ("works in CI, fails locally" is almost
always version drift).

| Recipe | Base | For |
|--------|------|-----|
| [`rn-detox.json`](rn-detox.json) | `macos-sequoia-xcode` | React Native + Detox iOS e2e |
| [`ios-fastlane.json`](ios-fastlane.json) | `macos-sequoia-xcode` | iOS build/release with Fastlane |
| [`node-ci.json`](node-ci.json) | `macos-sequoia-base` | Lean Node/TS CI (no Xcode) |
| [`script-based/`](script-based/) | `macos-sequoia-xcode` | Point at an existing `provision.sh` |

```sh
graft image build -f examples/images/rn-detox.json
graft dev --image rn-detox            # shell into it, your repo mounted
```

Notes:

- The **`cirruslabs/*-xcode`** bases already ship Xcode, simulators, CocoaPods, `fnm`,
  `rbenv`, `gh`, `jq`, and more — so recipes mostly **pin versions** and add the few
  missing tools, rather than installing a toolchain from scratch.
- **`run`** steps run in order in one guest shell (env carries across), or use
  **`script`** to run an existing shell script (see `script-based/`). Whatever the
  steps leave on disk is baked into the image.
- For caching strategy (bake vs. mount, APFS copy-on-write, the read-only rule for
  shared caches), see [../../docs/images-and-caching.md](../../docs/images-and-caching.md).
- Keep images that contain proprietary code **private** — don't `graft image push` them
  to a public registry.
