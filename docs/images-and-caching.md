# Images & caching

Graft builds **golden images** (a base + your toolchain + warm caches baked in) and
clones them for both CI runners and `graft dev`. The same image on your laptop and
your runners means "works on my machine" stops being a thing.

## Build an image

A recipe is a **`.graft`** file (YAML with declarative toolchain fields), or plain
`.yml`/`.json`. The declarative fields compile into the right provisioning commands —
so a whole toolchain is a few lines:

```yaml
name: rn-detox
from: ghcr.io/cirruslabs/macos-tahoe-xcode:latest

node: "20.19.4"          # fnm install + default + corepack + stable /usr/local/bin symlink
ruby: "3.3.5"            # rbenv install + bundler
npm: [detox-cli]
brew: [applesimutils]
xcode-first-launch: true
warm-simulators: ["iPhone 17 Pro"]

# Escape hatch — raw bash for anything custom (runs last):
# run: |
#   echo custom step
```

```sh
graft image render -f image.graft   # preview the compiled provisioning script
graft image build  -f image.graft   # clone → boot → provision in-guest → snapshot
graft image push rn-detox ghcr.io/you/rn-detox:latest   # share with the team
```

`from` is any Tart ref (start from a `cirruslabs/*-xcode` base — Xcode + simulators are
already baked). Declarative fields (`node`, `ruby`, `brew`, `gems`, `npm`,
`xcode-first-launch`, `warm-simulators`) expand in order; `run:` (a `|` block or list)
and `script:` (a file) are escape hatches that run after. Whatever the steps leave on
disk is baked into the image. `mounts` (optional) expose host dirs during the build,
e.g. to warm a project's caches. See [examples/images/](../examples/images/) for the
full field reference.

Reference the image from a pool (`"image": "rn-detox"`) or `graft dev --image
rn-detox`.

### Recipe field reference

Everything runs in **one guest shell**, in this order:
`env → toolchain → system config → script → run → prefetch → verify → cleanup`.
VM-shape fields are applied to the finished image with `tart set`. Run `graft image
template` for a starter, or hover any field in the VS Code extension.

**Toolchain** (installed in this order — version managers are installed if missing):

| Field | Type | Compiles to |
|---|---|---|
| `xcode` | version | `sudo xcodes select <v>` |
| `node` | version | `fnm install/use/default` + `corepack` + stable `/usr/local/bin` symlink |
| `ruby` | version | `rbenv install/global` + shims + `bundler` |
| `python` | version | `pyenv install/global` + `pip` upgrade |
| `java` | version | `brew install openjdk@<v>` + JavaVirtualMachines symlink |
| `go` | boolean | `brew install go` |
| `rust` | toolchain | `rustup toolchain install` + `default` (e.g. `stable`) |
| `package-manager` | `pnpm`\|`yarn`\|`bun` | corepack (pnpm/yarn) or brew (bun) |
| `brew` | string[] | `brew install …` |
| `cocoapods` | version | `gem install cocoapods -v <v>` (pair with `ruby:`) |
| `fastlane` | boolean | `gem install fastlane` |
| `gems` | string[] | `gem install … --no-document` |
| `npm` | string[] | `npm install -g …` |
| `xcode-first-launch` | boolean | `sudo xcodebuild -runFirstLaunch` |
| `simulator-runtimes` | string[] | `xcodebuild -downloadPlatform <platform>` (e.g. `["iOS 26"]`) |
| `warm-simulators` | string[] | cold-boot each once to warm caches, then shut down |

**System config** (baked into the image):

| Field | Type | Compiles to |
|---|---|---|
| `env` | map | export now + persist to `/etc/zshenv` (runner shells inherit) |
| `git` | `{user, email}` | `git config --global user.name/.email` |
| `known-hosts` | string[] | `ssh-keyscan` → `~/.ssh/known_hosts` (no clone prompts) |
| `write` | map (path→contents) | write config files into the guest (`.npmrc`, `.gemrc`, …) |
| `timezone` | string | `systemsetup -settimezone` |
| `hostname` | string | `scutil --set HostName/LocalHostName/ComputerName` |
| `disable-spotlight` | boolean | `mdutil -a -i off` (CI perf) |
| `disable-sleep` | boolean | `pmset -a sleep 0 …` (long jobs) |
| `description` / `labels` | string / map | metadata baked to `/etc/graft-image` |

**Cache warming, verify, hygiene:**

| Field | Type | Compiles to |
|---|---|---|
| `pod-repo-warm` | boolean | `pod repo update` / `pod setup` |
| `prefetch` | string[] | commands run in the `repo` mount dir (bundle/yarn/pod install → baked in) |
| `repos` | list | clone repos into the guest, warm global caches, discard the source (see below) |
| `verify` | string[] | each must exit 0 at the end, or the build fails |
| `cleanup` | boolean | `brew cleanup` + clear caches → smaller image |

**VM shape** (via `tart set`, inherited by every clone):

| Field | Type | Compiles to |
|---|---|---|
| `cpu` | int | `tart set --cpu` |
| `memory` | int (MB) | `tart set --memory` |
| `disk` | int (GB) | `tart set --disk-size` (grow-only) |
| `display` | `WxH` | `tart set --display` |

**Escape hatches:** `script` (a file, runs before `run`), `run` (a `|` block or list),
`mounts` (host dirs shared during the build), `os` (`macos`\|`linux`), `network`
(`nat` default, `bridged:<iface>`, or `softnet`).

> **Networking behind a corporate proxy (Zscaler etc.):** the default shared NAT can be
> blocked or mangled. Set `network: bridged:en0` (your active interface — `tart run
> --net-bridged=list` lists them) to put the VM directly on the LAN. The same applies to
> a runner pool (`network: bridged:en0` in the pool config) and `graft dev --network
> bridged:en0`.

### Pre-caching repos (`repos:`) — warm caches, no workflow changes

A runner job runs `actions/checkout`, which clones into `$GITHUB_WORKSPACE`
(`_work/<repo>/<repo>`) — **not** wherever the image baked anything. So a baked working
tree at, say, `~/app` does *not* link to the job. What **does** transfer is the
**global package-manager caches** (yarn/npm download cache, CocoaPods CDN + spec repo,
bundler gems, SPM): they live in `$HOME`, are path-independent, and the job's normal
`yarn install` / `pod install` / `bundle install` just hit them — killing the
network-fetch cost with zero workflow changes.

`repos:` automates exactly that warming: clone → run installs → **discard the working
tree**, keeping only the warmed `$HOME` caches. No source is baked into the image.

```yaml
known-hosts: [github.com]                 # so the clone doesn't prompt on the host key
mounts:
  - { name: ssh, source: "~/.ssh", readOnly: true }   # credentials — NOT baked (mounts never are)
repos:
  - url: git@github.com:your-org/app.git
    ref: main                             # branch or tag (shallow clone)
    ssh-key: "/Volumes/My Shared Files/ssh/id_ed25519"   # the mounted key
    run:
      - bundle install
      - yarn install
      - cd ios && bundle exec pod install
```

**Private repos:** the build VM needs credentials to clone. Mount your key/credentials
**read-only** — because mounts are never written into the image, nothing sensitive is
baked — and point `ssh-key` at the mounted path. (Public repos need neither.)

**Make sure your tools use a *global* cache**, or there's nothing to warm: Yarn Berry
defaults to a *project-local* `.yarn/cache` (discarded with the source). Force a global
cache with `env: { YARN_ENABLE_GLOBAL_CACHE: "true" }` (or use yarn classic / bundler's
default global gem dir / CocoaPods' global CDN cache, which already qualify).

## Why baking caches is (almost) free: APFS copy-on-write

`tart clone` uses **APFS `clonefile`** — the clone's disk shares the *same physical
blocks* as the source image; no data is copied. Copy-on-write then diverges **per
block, on writes only**:

- **Reading** `node_modules` / Pods / DerivedData → shared blocks. Free, instant, no
  duplication.
- **Writing** (a `pod install` delta, a build) → only the changed blocks get a private
  copy, in the clone. The golden image is never touched.

```
cirruslabs xcode base
   └─ build → rn-detox        (+ Pods / node_modules / DerivedData blocks)
        ├─ clone → runner-abc      (writable; diverges only where it writes)
        └─ clone → runner-def      (its own divergence)
```

So **bake your heavy, slow-moving caches into the image** and every ephemeral runner
gets them instantly, privately, and writably — diverging only on the delta. Two
concurrent runners can't corrupt each other, because each write lands in its own block.
"Refresh the caches" = **rebuild the image on a schedule** (e.g. nightly); the job's
incremental install/build catches up the small drift since the last build.

> Only works because `~/.tart` is on an APFS volume — which it is by default.

What to bake: Pods, `node_modules`, DerivedData, and HOME caches (`~/.npm`,
`~/Library/Caches/CocoaPods`). HOME caches bake automatically when a `run` step like
`npm ci` / `pod install` runs in the guest; project-dir caches (node_modules, Pods)
bake if the project is present during the build (clone the repo in a `run` step, or
mount it via `mounts`).

## Host mounts (the escape hatch for volatile caches)

When a cache moves faster than your rebuild cadence, mount it from the host instead of
baking it. Pools take a `mounts` list; `graft pool add` takes `--mount`:

```sh
graft pool add --name mac --image rn-detox \
  --mount pods:/opt/graft-cache/pods:ro \
  --mount npm:/opt/graft-cache/npm:ro
```

```json
"mounts": [
  { "name": "pods", "source": "/opt/graft-cache/pods", "readOnly": true }
]
```

Each appears in the guest at `/Volumes/My Shared Files/<name>`.

### ⚠️ Concurrency: read-only for shared caches

Ephemeral runners are supposed to be isolated. A **read-write cache mounted into two
concurrent runners will corrupt each other** (two `pod install`s writing the same
dir). So:

- **Read-only, shared** (`:ro`) → safe. Pre-warm the cache out of band; runners get
  fast warm reads, zero corruption risk. **This is the recommended default.**
- **Read-write** → must be **per-runner** (its own directory), never shared. CocoaPods
  and DerivedData especially want RO-shared. npm's content-addressed store tolerates RW
  better, but RO is still safest.

For most setups: **bake into the image (CoW gives you a private writable copy for
free), and use RO mounts only for the volatile long-tail.**

## `graft dev` vs CI

| | `graft dev` | CI (`graft run`) |
|---|---|---|
| VM | persistent (or `--ephemeral`) | always ephemeral |
| repo | host-mounted RW (`$PWD`) | cloned into the guest |
| mounts | your repo + `--mount` | optional RO caches |
| image | the same golden image | the same golden image |

Same image, two workflows — your local box and your runners stay identical.
