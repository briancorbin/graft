<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Assets/header-dark.png">
    <img src="Assets/header-light.png" alt="Graft — ephemeral GitHub Actions runners on Tart VMs" width="480">
  </picture>
</p>

Ephemeral GitHub Actions runners on [Tart](https://tart.run) VMs. An open-source,
fleet-ready replacement for Tartelet.

Each runner boots a fresh macOS or Linux VM, registers with GitHub, runs **exactly
one job**, then tears itself down. No persistent runners, no state drift, no
leftover secrets — ephemerality is enforced by construction (JIT runners), not by
convention.

## Why

- **Tartelet is effectively abandoned** and hard-caps at 2 runners.
- Graft scales to any number of runners, respects Apple's constraints, and is
  designed from day one to swap a local Tart backend for an [Orchard](https://github.com/cirruslabs/orchard)
  fleet without touching the runner logic.

## Status

| Area | State |
|------|-------|
| VM layer (`tart` clone/boot/IP/destroy) | ✅ working |
| GitHub App auth + JIT runner config | ✅ built (HTTP unverified without a real App) |
| Keychain secret store (login + system) | ✅ working (cross-process read needs ACL hardening) |
| `tart exec` provisioning + runner loop | ✅ built (runner download unverified on a live VM) |
| Pool supervisor + state + daemon | ✅ built & unit-tested |
| Image builder + `graft dev` + `.graft` recipes | ✅ built & tested (real image baked end-to-end) |
| Orchard multi-host backend | ⬜ planned |

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
  "provider": "tart",
  "pools": [
    {
      "name": "macos-release",
      "image": "ghcr.io/cirruslabs/macos-sequoia-xcode:latest",
      "os": "macos",
      "count": 2,
      "github": {
        "appId": 12345,
        "target": "org:my-org",
        "runnerGroupId": 1,
        "labels": ["self-hosted", "macos", "graft"]
      }
    }
  ],
  "secrets": { "store": "keychain", "scope": "login" }
}
```

`labels` are baked into the JIT config at generation time (immutable per runner);
omit to default to `["self-hosted", <os>, <pool-name>]`. `runnerGroupId` defaults
to `1`.

### 4. Run

```sh
graft run                      # foreground, Ctrl+C to stop
graft status                   # daemon liveness + live runner snapshot
graft stop                     # graceful shutdown
```

**Running headless / on an EC2 Mac?** Tart needs an active GUI login session — see
[docs/ec2-mac-setup.md](docs/ec2-mac-setup.md) for the auto-login setup, verification
steps, and security trade-offs.

## Commands

```
graft init                              Interactive setup: profile + pools + key import
graft doctor                            Verify GitHub App auth end-to-end (no VM boot)
graft run [--profile NAME] [--daemon] [--verbose]   Start the supervisor (live spinner; -v for full logs)
graft status                            Show supervisor + runner state
graft stop                              Gracefully stop a running supervisor

graft profile create                    Interactive wizard: new profile + pools
graft profile list                      List profiles (active marked *)
graft profile use <name>                Set the active profile
graft profile show [name]               Print a profile's config
graft profile rm <name>                 Delete a profile
graft pool new [--profile NAME]         Interactive wizard: add a pool (image picked from the machine)
graft pool add --name N --image I --app-id A --target T [--os] [--count] [--labels]
graft pool rm <name> [--profile NAME]
graft pool list [--profile NAME]

graft image build -f <recipe.graft>     Build a golden image (declarative toolchain)
graft image render -f <recipe.graft>    Preview the compiled provisioning script
graft image list / rm / prune / push / pull / template   Manage images (prune clears orphaned build VMs)
graft dev [--image N] [--ephemeral] [--network bridged:en0] [-- CMD]   Local dev VM with your repo mounted

graft vm create <image> [--os macos|linux]   Clone + boot a VM, print name<TAB>ip
graft vm delete <name>                  Stop + destroy a VM
graft vm list [--all]                   List graft-managed (or all) VMs
graft vm ip <name> [--wait]             Print a VM's IP
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
`graft image template` prints a starter; the full field reference is in
[docs/images-and-caching.md](docs/images-and-caching.md).

```sh
graft image render -f examples/images/rn-detox.graft  # preview the compiled script
graft image build  -f examples/images/rn-detox.graft  # build the golden image
graft dev --image rn-detox                            # shell into it, $PWD mounted
graft dev --image rn-detox -- npx detox test e2e/     # or run a command
```

Ready-to-adapt recipes (React Native/Detox, iOS/Fastlane, Node, script-based) live in
**[examples/images/](examples/images/)**. Editing `.graft` files? There's a
**[VS Code extension](editors/vscode/)** (highlighting incl. embedded shell, field
completion/hover, render/build commands).

### Dev *in* the VM (`--code`)

`graft dev --code` makes the VM your dev box and the host a thin client: it opens **VS
Code over Remote-SSH** *into* the VM. Source, `node_modules`, Pods, language servers,
the terminal, and builds all run guest-side against the baked toolchain — off the same
image your CI runs, so "works on my machine" is gone. graft mints a dedicated SSH key,
injects it, and writes a self-managed `~/.ssh/graft.config` (you never touch `tart`/`ssh`).

```sh
graft dev --repo your-org/app --code        # fresh clone INTO the VM, open VS Code (host stays empty)
graft dev --code                            # in a repo dir: seed your working tree (keeps WIP)
graft dev --code                            # elsewhere: pick a box to reattach, or a repo to clone
```

- **`--repo <owner/name | url>`** clones fresh from the remote into a per-repo box
  (`graft-dev-app`), over agent-forwarded SSH — so private repos work and `git push`
  from inside the VM uses your host key, **nothing baked**. Add `--ref <branch|tag>`.
  Requires your key in the ssh-agent (`ssh-add`).
- **No `--repo`, in a repo dir** seeds your local checkout (uncommitted WIP and all);
  **elsewhere** you get a picker: reattach an existing box, or clone one of the repos
  your GitHub App can reach.
- Boxes are **persistent + per-repo** — reattach with `graft dev --code`, remove with
  `graft vm delete graft-dev-app`.

## Architecture

Everything pivots on **`VMProvider`** — `capacity`, `acquire`, `release`, plus an
`exec` channel. The supervisor never calls `tart` directly, so `LocalTartProvider`
(now) and a future `OrchardProvider` are a drop-in swap. The same move backs
`SecretStore` (Keychain now, Vault/1Password later).

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

## Roadmap

- `OrchardProvider` for multi-host fleets
- Full desktop GUI app (dashboard, live logs, run history) — the menu-bar app's bigger sibling
- Keychain ACL hardening for the headless daemon (bind to the graft binary)
- `--unsafe-unrestricted-quota` (kernel boot-arg override, SIP off, opt-in)
- `Twig`: native `Virtualization.framework` backend

Shipped: ✅ menu-bar app (`Graft.app`); ✅ image builder + `graft dev` + `.graft` recipes (toolchain/system/cache-warming/VM-shape fields, bridged networking, repo pre-caching)

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
