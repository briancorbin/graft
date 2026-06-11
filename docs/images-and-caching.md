# Images & caching

Graft builds **golden images** (a base + your toolchain + warm caches baked in) and
clones them for both CI runners and `graft dev`. The same image on your laptop and
your runners means "works on my machine" stops being a thing.

## Build an image

A recipe is JSON (`graft image template` prints a starter):

```json
{
  "name": "rn-detox",
  "from": "ghcr.io/cirruslabs/macos-sequoia-xcode:latest",
  "run": [
    "brew install applesimutils",
    "npm install -g detox-cli"
  ]
}
```

```sh
graft image build -f image.json     # clone → boot → run steps in-guest → snapshot
graft image list                    # local images + VMs
graft image push rn-detox ghcr.io/you/rn-detox:latest   # share with the team
```

`from` is any Tart ref (start from a `cirruslabs/*-xcode` base — Xcode + simulators are
already baked). `run` steps execute in the guest; whatever they leave behind is baked
into the image. `mounts` (optional) expose host dirs during the build, e.g. to warm a
project's caches.

Reference the image from a pool (`"image": "rn-detox"`) or `graft dev --image
rn-detox`.

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
graft pool add --name mac --image rn-detox --app-id 123 --target repo:org/app \
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
