<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Assets/header-dark.png">
    <img src="Assets/header-light.png" alt="Graft — one golden Tart VM image for your dev box and your CI" width="480">
  </picture>
</p>

One golden [Tart](https://tart.run) VM image for macOS & Linux that powers both your
**dev environment** and your **ephemeral CI runners**. Open-source and fleet-ready.

Graft does three things off one `.graft` seed:

- **`graft sapling grow`** — grow a golden image (a *sapling*) with your full toolchain and
  warm caches (Xcode, Node, CocoaPods, Detox…) baked in.
- **`graft nest`** — develop *inside* that image over VS Code Remote-SSH. Codespaces for
  native macOS/iOS, off the exact image your CI uses.
- **`graft arborist tend`** — ephemeral GitHub Actions runners: each boots a fresh VM, registers
  with GitHub, runs **exactly one job**, then tears itself down. No state drift, no
  leftover secrets — ephemerality is enforced by construction (JIT runners), not by
  convention.

Because dev and CI share one image, "works on my machine" stops being a thing.

## Why

- Built for **fleets**: scale to any number of runners across hosts, with Apple's
  per-host macOS-VM limits respected by construction.
- **Warm by default** — caches bake into the image via APFS copy-on-write, so every
  ephemeral runner gets an instant private warm cache; "refresh" is just a rebuild.
- Designed from day one to swap a local Tart backend for an [Orchard](https://github.com/cirruslabs/orchard)
  fleet without touching the runner logic.

Graft owes a lot to [Tartelet](https://github.com/shapehq/tartelet), which pioneered
the ephemeral-Tart-runner approach on macOS — Graft pushes that idea toward
multi-host fleets and a shared dev/CI image.

## Status

| Area | State |
|------|-------|
| VM layer (`tart` clone/boot/IP/destroy) | ✅ working |
| GitHub App auth + JIT runner config | ✅ built (HTTP unverified without a real App) |
| Keychain secret store (login + system) | ✅ working (cross-process read needs ACL hardening) |
| `tart exec` provisioning + runner loop | ✅ built (runner download unverified on a live VM) |
| Pool supervisor + state + daemon | ✅ built & unit-tested |
| Image builder + `graft nest` + `.graft` recipes | ✅ built & tested (real image baked end-to-end) |
| Orchard multi-host backend | ✅ verified end-to-end against a live controller — [docs/orchard.md](docs/orchard.md) |
| Health monitor (`--tend` on run / tree branch / tree plant) | ✅ built & unit-tested — detection-only, per-role agents, [docs/health-and-monitoring.md](docs/health-and-monitoring.md) |

Built and driven through end-to-end; the parts that need real GitHub credentials or
a booted VM to fully prove are flagged in code (`TODO(real-VM)`).

## Requirements

- Apple Silicon Mac
- [Tart](https://tart.run) (`brew install cirruslabs/cli/tart`)
- Swift 6 toolchain
- A GitHub App (not a PAT) with self-hosted-runner admin permission

## Build

```sh
swift build -c release
sudo cp .build/release/graft /usr/local/bin/graft
```

## The Apple 2-VM limit

Apple Silicon enforces a **hard limit of 2 concurrent macOS VMs per host** in the
XNU kernel. Graft respects it: macOS pools are capped at 2 VMs per host, budgeted
across all pools. **Linux VMs are uncapped** (bounded by RAM/cores). To scale macOS
beyond 2, add hosts — that's what the Orchard backend is for.

## Setup

### 1. Create a GitHub App

Give it **Self-hosted runners: Read & write** (org) or **Administration: Read &
write** (repo), install it on your org/repo, and download its private key (`.pem`).

### 2. Import the key into the Keychain (never on disk)

```sh
# Interactive hosts (login keychain):
graft secrets import --app-id <APP_ID> --pem ./app.pem
rm -P ./app.pem          # then shred the file

# Headless daemon hosts (system keychain, no login session at boot):
sudo graft secrets import --app-id <APP_ID> --pem ./app.pem --system
```

Graft resolves the key from the Keychain by App ID — there is no key path in config.

### 3. Configure

```sh
graft config template > ~/.graft/config.json
graft config validate
```

```json
{
  "provider": { "type": "tart" },
  "github": { "appId": 12345, "target": "org:my-org" },
  "pools": [
    {
      "name": "macos-release",
      "image": "ghcr.io/cirruslabs/macos-tahoe-xcode:latest",
      "os": "macos",
      "count": 2,
      "labels": ["self-hosted", "macos", "release"],
      "cpu": 4,
      "memory": 8192
    }
  ],
  "secrets": { "store": "keychain", "scope": "login" }
}
```

The `provider` object owns the backend (`{ "type": "tart" }`, or
`{ "type": "orchard", "controllerURL": …, "serviceAccount": …, "maxVMs": … }`).
**`github`** (the App + where runners register) is declared once at the profile level
and inherited by every pool — a pool may override it with its own `github` for a
multi-repo profile. A **pool** is just its workload: `image`, `count`, `os`, `labels`
(its tags — `runs-on:` targets these; default `["self-hosted", <os>, <name>]`), and
optional `cpu`/`memory` per leaf. `runnerGroupId` defaults to `1`.

### 4. Tend

```sh
graft arborist tend            # foreground, Ctrl+C to stop (--monitor to report health)
graft status                   # daemon liveness + live runner snapshot
graft stop                     # graceful shutdown
```

**Running headless / on an EC2 Mac?** Tart needs an active GUI login session — see
[docs/ec2-mac-setup.md](docs/ec2-mac-setup.md) for the auto-login setup, verification
steps, and security trade-offs.

## Commands

```
graft init                              Interactive setup: backend (Tart | Orchard tree) + profile + pools + keys

graft arborist tend [--profile NAME] [--daemon] [-v] [--monitor]   Tend the pool (supervise; --monitor reports health)
graft arborist check                    Verify GitHub App auth end-to-end (no VM boot)
graft arborist canopy / branches / leaves   Inspect the tree (capacity, workers, VMs)
graft arborist runners                  List / prune GitHub runner registrations
graft status                            Show supervisor + runner state
graft stop                              Gracefully stop a running supervisor

graft profile create                    Interactive wizard: new profile + pools
graft profile list                      List profiles (active marked *)
graft profile use <name>                Set the active profile
graft profile show [name]               Print a profile's config
graft profile rm <name>                 Delete a profile
graft pool new [--profile NAME]         Interactive wizard: add a pool (image picked from the machine)
graft pool add --name N --image I --app-id A --target T [--os] [--count] [--labels] [--cpu] [--memory]
graft pool rm <name> [--profile NAME]
graft pool list [--profile NAME]

graft sapling grow --seed <recipe.graft>   Grow a golden image (sapling) from a .graft seed
graft sapling render --seed <recipe.graft> Preview the compiled provisioning script
graft sapling list / rm / prune / push / pull / template   Manage saplings (prune clears orphaned build VMs)
graft nest [<repo>|<box>|.] [--code]    Dev box (nest): clone a repo / resume a box / mount '.' (docs/dev-boxes.md)
graft nest ls / rm [box]                List / remove nests

graft plant                             Plant the trunk — run the controller (foreground)
graft branch <trunk-url> [--reserve N] [--monitor]   Graft a branch on — run a worker that joins the tree
graft prune <name>                      Prune a branch — remove a worker
graft bonsai                            Grow a bonsai — a whole tiny tree on this machine (local)

graft leaf create <image> [--os macos|linux]   Clone + boot a VM (leaf), print name<TAB>ip
graft leaf rm <name>                    Stop + destroy a leaf (VM)
graft leaf list [--all]                 List graft-managed (or all) leaves
graft leaf ip <name> [--wait]           Print a leaf's IP
graft runners list [--profile NAME]     List graft's runner registrations on GitHub
graft runners prune [--profile NAME]    Delete offline graft runner husks on GitHub
graft secrets import --app-id N --pem P [--system]
graft secrets list [--system]
graft secrets rm --app-id N [--system]
graft config validate [--profile NAME] [--skip-keys]
graft config template
```

**Profiles** live at `~/.graft/profiles/<name>.json`; the active one is used by
`run`/`doctor`/`config validate` unless you pass `--profile` or `--config`. Switch
setups (personal vs. work) with `graft profile use`.

## Images & local dev

Build a **golden image** (base + toolchain + warm caches) once and clone it for both CI
runners and a local dev box — so your laptop and your runners run byte-identical
environments. Tart clones are APFS copy-on-write, so baked caches cost nothing per
runner. See **[docs/images-and-caching.md](docs/images-and-caching.md)** for recipes,
the CoW caching strategy, and host-mount safety (read-only for shared caches).

A recipe is a declarative **`.graft`** file (YAML). Fields compile into the right
provisioning, grouped: **toolchain** (`node`, `ruby`, `python`, `cocoapods`, `xcode`,
`fastlane`, …), **system config** (`env`, `known-hosts`, `disable-spotlight`, `git`, …),
**cache warming** (`prefetch`; `repos:` clones a repo to warm global caches then discards
the source — no source baked), **verification** (`verify:`), and **VM shape**
(`cpu`/`memory`/`disk`). `network: bridged:<iface>` covers hosts where the default NAT is
blocked (e.g. behind Zscaler). Drop to a `run:` block or `script:` for anything custom.
`graft sapling template` prints a starter; the full field reference is in
[docs/images-and-caching.md](docs/images-and-caching.md).

```sh
graft sapling render --seed examples/images/rn-detox.graft  # preview the compiled script
graft sapling grow   --seed examples/images/rn-detox.graft  # grow the golden image (sapling)
graft nest your-org/app                                     # clone into a nest, shell in
graft nest your-org/app --code                              # …or open VS Code inside the VM
```

Ready-to-adapt recipes (React Native/Detox, iOS/Fastlane, Node, script-based) live in
**[examples/images/](examples/images/)**. Editing `.graft` files? There's a
**[VS Code extension](editors/vscode/)** (highlighting incl. embedded shell, field
completion/hover, render/build commands).

### Dev *in* the VM

A **dev box** is a VM cloned from one of your golden images — same toolchain as CI, host
stays a thin client. `--code` opens **VS Code over Remote-SSH** *into* the box, so the
editor, terminal, language servers, and builds run guest-side. It's Codespaces, but for
native macOS/iOS.

```sh
graft nest                     # picker: resume a box / clone a repo / mount here / scratch
graft nest your-org/app        # clone → persistent box, shell in   (--code for VS Code)
graft nest app                 # resume it
graft nest .                   # mount $PWD → ephemeral box → run here
graft nest ls / rm [box]        # list / remove boxes
```

The model: **clone → persistent & resumable**; **mount (`.`) / scratch → ephemeral**.
Full guide — clone vs mount, `--code`, the picker, advanced flags — in
**[docs/dev-boxes.md](docs/dev-boxes.md)**.

## Architecture

Everything pivots on **`VMProvider`** — `capacity`, `acquire`, `release`, plus an
`exec` channel. The supervisor never calls `tart` directly, so `LocalTartProvider`
(single host) and `OrchardProvider` (multi-host fleet) are a drop-in swap — same
runner logic, different backend. The same move backs `SecretStore` (Keychain now,
Vault/1Password later).

```
PoolSupervisor (actor, desired-state loop)
  └─ per slot, forever:
       provider.acquire(image, os)            → RunningVM
       GitHubAppClient.generateJITConfig(...)  → JIT blob   (App JWT → installation token → JIT)
       RunnerProvisioner.runEphemeralRunner    → tart exec ./run.sh --jitconfig, wait for exit
       provider.release(vm)                    → tart stop + delete
```

Provisioning uses **`tart exec`** (Tart Guest Agent) — no SSH, no keys, no
passwords. Stock cirruslabs images ship the agent; custom images must include it.

## Documentation

- **[docs/dev-boxes.md](docs/dev-boxes.md)** — `graft nest`: clone vs mount, persistence, `--code`, the picker
- **[docs/images-and-caching.md](docs/images-and-caching.md)** — `.graft` recipes, the full field reference, CoW caching
- **[docs/orchard.md](docs/orchard.md)** — the multi-host Orchard backend: controller/workers, service account, config
- **[docs/health-and-monitoring.md](docs/health-and-monitoring.md)** — `arborist --tend`: detectors, event schema, webhooks, the self-healing seam
- **[docs/ec2-mac-setup.md](docs/ec2-mac-setup.md)** — headless / EC2 Mac runners (auto-login, bridged networking)
- **[editors/vscode/](editors/vscode/)** — the `.graft` VS Code extension

## Roadmap

- Full desktop GUI app (dashboard, live logs, run history) — the menu-bar app's bigger sibling
- Keychain ACL hardening for the headless daemon (bind to the graft binary)
- `--unsafe-unrestricted-quota` (kernel boot-arg override, SIP off, opt-in)
- `Twig`: native `Virtualization.framework` backend

Shipped: ✅ menu-bar app (`Graft.app`); ✅ image builder + `graft nest` + `.graft` recipes (toolchain/system/cache-warming/VM-shape fields, bridged networking, repo pre-caching); ✅ `OrchardProvider` multi-host backend

## Install

CLI + daemon:

```sh
brew install briancorbin/tap/graft
```

Menu-bar app (installs the CLI too):

```sh
brew install --cask briancorbin/tap/graft-app
```

Apple Silicon only. [Tart](https://tart.run) is pulled in as a dependency.

## License

MIT — see [LICENSE](LICENSE).
