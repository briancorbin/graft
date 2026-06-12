# Dev boxes (`graft dev`)

A **dev box** is a VM cloned from one of your golden images — the same image your CI
runners use. You get a disposable-or-persistent Mac dev environment with the full
toolchain already baked in, and the host stays a thin client.

```sh
graft dev                      # picker: resume a box / clone a repo / mount here / scratch
graft dev briancorbin/app      # clone a repo into a persistent box and open it
graft dev app                  # resume the persistent box 'app'
graft dev .                    # mount the current directory into an ephemeral box
graft dev ls                   # list dev boxes
graft dev rm [box]             # remove a box (picker if omitted)
```

## The model: clone is persistent, mount is ephemeral

Persistence isn't a separate choice — it falls out of where the code comes from:

| Source | Box | Resume? | Connect |
|---|---|---|---|
| **clone `<repo>`** | **persistent** (`graft-dev-<repo>`) | ✅ yes | shell / `--code` |
| **mount `.`** (`$PWD`) | **ephemeral** (deleted on exit) | ❌ never | shell / `-- cmd` |
| **scratch** (no repo) | **ephemeral** | ❌ | shell / `--code` |

- **Clone** copies the repo *into* the VM (`~/work/<repo>`), so `node_modules`, Pods,
  branches, and build state live there — worth keeping and resuming. This is your dev
  *home*. Auth is a short-lived `gh` token over HTTPS; nothing is stored in the VM, and
  `git push`/`pull` use VS Code's forwarded credentials.
- **Mount** shares your current directory from the host — your files are the source of
  truth *on your laptop*, so there's nothing in the VM worth keeping. graft spins a fresh
  ephemeral box each time and deletes it when you're done. Use this for "run my local
  files in a CI-identical env."
- A mount box can't be *resumed* anyway (Tart mounts are fixed at boot — a different
  directory means a fresh boot), so resume only applies to clone boxes. The two modes
  self-select by usage: repeated work → clone (instant resume); one-off → mount.

## Connecting: shell (default) or VS Code

Shell is the default — everyone has it. `--code` opens **VS Code over Remote-SSH** *into*
the box, so the editor, terminal, language servers, and builds all run guest-side against
the baked toolchain. The interactive picker asks which you want.

```sh
graft dev briancorbin/app --code     # clone + open VS Code
graft dev app                        # resume into a shell
graft dev . -- yarn test             # mount $PWD, run one command, tear down
```

> `--code` boxes are always left running (VS Code can't tell graft when you've closed the
> window). Remove with `graft dev rm <box>`.

### VS Code prerequisites
- The `code` CLI on your PATH (VS Code → ⌘⇧P → "Shell Command: Install 'code' command").
- The **Remote - SSH** extension (graft installs it if missing).
- graft mints a dedicated key (`~/.graft/dev_ed25519`), injects it, and writes a
  self-managed `~/.ssh/graft.config` (Include'd from your main config) — so the box also
  appears in VS Code's **Remote Explorer**; you can open it from there too.

## Advanced flags

| Flag | What |
|---|---|
| `--image <ref>` | base image for a **new** box (default: pick from local images) |
| `--ref <branch\|tag>` | branch/tag to clone |
| `--name <name>` | override the box name |
| `--network bridged:<iface>` | bridged networking (e.g. behind Zscaler) — see [ec2-mac-setup](ec2-mac-setup.md) |
| `--mount <path[:ro]>` | extra host directory shared at boot (boot-time only — can't mount into a running box) |
| `--ephemeral` | force a throwaway box even when cloning |
| `-- <cmd>` | run a command in the box instead of an interactive shell |

## Why this is special

It's GitHub Codespaces / dev-containers, but for **native macOS/iOS** — which containers
can't do, because Xcode and the simulator need a real macOS VM. Your dev box is a clone of
the *same golden image your CI runs*, so "works on my machine" is gone: your machine **is**
the CI machine.
