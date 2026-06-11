<p align="center">
  <img src="Assets/app-icon-light.svg" alt="Graft" width="96" height="96">
</p>

<h1 align="center">Graft</h1>

<p align="center">Ephemeral GitHub Actions runners on Tart VMs.</p>

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

Headless via launchd: see [`Resources/com.graft.runner.plist`](Resources/com.graft.runner.plist).

## Commands

```
graft init                              Interactive setup: profile + pools + key import
graft doctor                            Verify GitHub App auth end-to-end (no VM boot)
graft run [--profile NAME] [--daemon]   Start the supervisor
graft status                            Show supervisor + runner state
graft stop                              Gracefully stop a running supervisor

graft profile list                      List profiles (active marked *)
graft profile use <name>                Set the active profile
graft profile show [name]               Print a profile's config
graft profile rm <name>                 Delete a profile
graft pool add --name N --image I --app-id A --target T [--os] [--count] [--labels]
graft pool rm <name> [--profile NAME]
graft pool list [--profile NAME]

graft vm create <image> [--os macos|linux]   Clone + boot a VM, print name<TAB>ip
graft vm delete <name>                  Stop + destroy a VM
graft vm list [--all]                   List graft-managed (or all) VMs
graft vm ip <name> [--wait]             Print a VM's IP
graft secrets import --app-id N --pem P [--system]
graft secrets list [--system]
graft secrets rm --app-id N [--system]
graft config validate [--profile NAME] [--skip-keys]
graft config template
```

**Profiles** live at `~/.graft/profiles/<name>.json`; the active one is used by
`run`/`doctor`/`config validate` unless you pass `--profile` or `--config`. Switch
setups (personal vs. work) with `graft profile use`.

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
- Keychain ACL hardening for the headless daemon (bind to the graft binary)
- `--unsafe-unrestricted-quota` (kernel boot-arg override, SIP off, opt-in)
- Menu-bar GUI talking to the daemon
- `Twig`: native `Virtualization.framework` backend

## Install

```sh
brew install briancorbin/tap/graft
```

(Requires Apple Silicon + [Tart](https://tart.run). The formula pulls in Tart as a dependency.)

## License

MIT — see [LICENSE](LICENSE).
