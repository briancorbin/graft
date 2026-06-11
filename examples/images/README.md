# Example image recipes

Starting points for `graft image build` — generic, meant to be adapted. Pin the
versions to match your project's lockfiles ("works in CI, fails locally" is almost
always version drift).

A recipe is a **`.graft`** file (YAML with declarative toolchain fields), or plain
`.yml`/`.json`. The declarative fields expand into the right provisioning commands —
preview what a recipe compiles to with `graft image render -f <recipe>`.

| Recipe | Base | For |
|--------|------|-----|
| [`rn-detox.graft`](rn-detox.graft) | `macos-sequoia-xcode` | React Native + Detox iOS e2e |
| [`ios-fastlane.graft`](ios-fastlane.graft) | `macos-sequoia-xcode` | iOS build/release with Fastlane |
| [`node-ci.json`](node-ci.json) | `macos-sequoia-base` | Lean Node/TS CI — `run:` escape hatch |
| [`script-based/`](script-based/) | `macos-sequoia-xcode` | Point at an existing `provision.sh` |

```sh
graft image render -f examples/images/rn-detox.graft   # see the compiled script
graft image build  -f examples/images/rn-detox.graft   # build it
graft dev --image rn-detox                             # shell in, your repo mounted
```

## Declarative fields

graft compiles these (in this order) into provisioning steps:

| Field | Expands to |
|-------|-----------|
| `node: "20.19.4"` | `fnm install`/`default` + `corepack` + a stable `/usr/local/bin` node symlink (Xcode needs it) |
| `ruby: "3.3.5"` | `rbenv install` + `global` + `bundler` |
| `brew: [pkg, …]` | `brew install …` |
| `gems: [pkg, …]` | `gem install … --no-document` |
| `npm: [pkg, …]` | `npm install -g …` |
| `xcode-first-launch: true` | `sudo xcodebuild -runFirstLaunch` |
| `warm-simulators: ["iPhone 17 Pro"]` | cold-boot each (warms on-disk caches) + shutdown |
| `run: \|` / `script:` | escape hatch — raw bash / a script file, run last |

Notes:

- `node:`/`ruby:` assume the **`cirruslabs/*-xcode`** base (it ships `fnm`/`rbenv`).
  On a bare `*-base` image, install them yourself via `run:` (see `node-ci.json`).
- For caching strategy (bake vs. mount, APFS copy-on-write, the read-only rule for
  shared caches), see [../../docs/images-and-caching.md](../../docs/images-and-caching.md).
- Keep images that contain proprietary code **private** — don't `graft image push` them
  to a public registry.
