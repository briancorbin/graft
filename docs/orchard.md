# Multi-host runners with Orchard

A single Mac caps at **2 macOS VMs** (Apple's kernel limit). To run more runners,
add hosts — and let [Orchard](https://github.com/cirruslabs/orchard) schedule VMs
across them. Orchard is Cirrus Labs' orchestrator for Tart: a **controller** that
holds desired state and a fleet of **workers** (Apple Silicon Macs running `tart`)
that actually boot the VMs.

graft's `OrchardProvider` is a drop-in swap for the local Tart backend — same pool
config, same ephemeral runner loop, same `.graft` images. The only change is
`provider: "orchard"` plus an `orchard` block. graft asks the controller to create a
VM; the controller picks a worker with free capacity (and enforces the per-host
2-macOS limit for you); graft runs the runner over Orchard's SSH tunnel and deletes
the VM when the job's done. (Verified end-to-end — see the bottom of this doc.)

---

## How the fleet works

Three roles, loosely coupled — and that coupling is the whole point:

- **graft is _demand_.** Its job is a desired-state loop: "keep `count` runners alive,
  forever." It just keeps asking the controller for VMs — it never checks how much room
  the fleet has.
- **Workers are _supply_.** A worker (`orchard worker run`) registers with the
  controller and idles, advertising its free slots. **It never spins up a VM on its own.**
- **The controller is the _matchmaker_.** It places each of graft's "I need a VM"
  requests onto a worker with a free slot (respecting each host's 2-macOS-VM cap + labels).

So **adding a host is a no-op event.** The new worker just registers and becomes another
place the controller _can_ put a VM. On graft's next acquire (seconds away — slots churn
constantly), the controller starts placing fresh VMs on it. Nobody tells the new Mac to
do anything; the demand already exists, and it's new supply. Removing a worker is just as
quiet — its share of the churn lands on the others.

### The ephemeral churn loop

Each of graft's `count` slots runs this forever:

```
acquire   → orchard create vm → controller places it on a worker → boots → running
provision → start the JIT runner inside the VM (over the SSH tunnel)
run       → runner picks up ONE job, runs it, exits (jitconfig is single-use)
release   → orchard delete vm → worker destroys it
             └──────────── loop back to acquire (a FRESH VM) ───────────┘
```

The VM is **never reused** — every job gets a pristine one. Scaling the fleet up or down
is fully decoupled from graft: it keeps saying "I want `count` runners," and the
controller rebalances across whatever workers exist. graft never even learns the fleet
size changed.

### How the runner gets into the VM

graft holds the GitHub App key and mints a **single-use JIT config** (a base64 blob).
That blob is embedded in a bash provisioning script graft pipes over the **exec tunnel**
(`orchard ssh vm … bash -s`, script on stdin). The path: graft → controller websocket →
worker gRPC → worker SSHes into the VM → the VM's `bash -s` runs the script and
`exec ./run.sh --jitconfig <blob>`. The runner registers with GitHub _from inside the VM_.

Two properties fall out of this: the **worker is a dumb pipe** (it shells bytes between
the controller tunnel and the VM's sshd — it never parses the script, never touches
GitHub, holds no secret), and the **App key never leaves graft** — only the disposable
JIT token travels outward, into a VM that's destroyed after one job.

---

## Driving Orchard from graft

You don't have to leave the graft CLI to run a fleet — graft models it as a **tree**: a
**trunk** (the controller) with **branches** (workers) that your **leaves** (runner VMs)
grow on. `graft tree …` wraps the whole lifecycle (it shells out to `orchard` underneath;
the vendor name only appears in `provider: "orchard"` config):

| Command | What it does |
|---|---|
| `graft tree plant` | Plant the trunk — run the controller (foreground), capturing the one-time admin token so `branch`/`prune` can authenticate. |
| `graft tree branch <trunk-url>` | Graft a branch on — run a worker on this Mac that joins the tree (mints its own bootstrap token, or pass `--token`). |
| `graft tree prune <name>` | Prune a branch — deregister a worker. |
| `graft tree status` | Tree health — trunk, branch count, advertised/used/free capacity, graft's leaves. |
| `graft tree branches` | Per-branch table (advertised leaf slots, paused state) + the tree's free-slot total. |
| `graft tree leaves [--all]` | Leaves (VMs) on the tree — graft's by default, the whole cluster with `--all`. |

Setup happens in **`graft init`** — it asks the backend (Local Tart · Orchard tree) and,
for a tree, collects the trunk URL + service account and stashes the token in the
Keychain. A local fleet, end to end:

```sh
graft tree plant                       # terminal 1: the trunk (leave running)
graft tree branch http://localhost:6120  # terminal 2: graft a branch on (leave running)
graft init                             # terminal 3: pick "Orchard tree", point at the trunk
graft tree status                      # sanity-check
graft run                              # graft leaves onto the branches
```

The service-account **token is stored in the Keychain** (keyed by account name, same
mechanism as the GitHub App PEM), so it never lands in profile JSON. `graft run` resolves
it at start: an inline `orchard.token` wins if present, otherwise the Keychain, otherwise
empty (fine for an unsecured local trunk). For a *remote* secured controller, `graft init`
creates the service account for you when you hold an admin `orchard` context — otherwise
it falls back to pasting an existing token.

---

## How graft talks to Orchard

graft shells out to the `orchard` CLI (just like the local backend shells out to
`tart`), so the [`orchard` binary](https://tart.run/orchard/quick-start/) must be on
the `PATH` of the machine running `graft run`:

```sh
brew install cirruslabs/cli/orchard
```

Auth + endpoint are passed to every `orchard` call via environment, so graft never
runs `orchard context create` or touches `~/.config/orchard`:

| Env var | From config |
|---|---|
| `ORCHARD_URL` | `orchard.controllerURL` |
| `ORCHARD_SERVICE_ACCOUNT_NAME` | `orchard.serviceAccount` |
| `ORCHARD_SERVICE_ACCOUNT_TOKEN` | `orchard.token` |

Each `VMProvider` method maps to one `orchard` subcommand:

| graft | orchard |
|---|---|
| acquire | `orchard create vm --image … --os darwin\|linux [--host-dirs …] [--net-*] graft-<uuid>`, then poll `get vm <name>/status` until `running` |
| release | `orchard delete vm <name>` |
| exec | `orchard ssh vm <name> "<cmd>"` |
| run the runner | `orchard ssh vm <name> "bash -s"` (script on stdin) |

graft deliberately passes neither `--restart-policy` (Orchard defaults to `Never`) nor
`--wait` (Orchard's `--wait` bounds the whole port-forward rendezvous, and `--wait 0`
would kill it — see Troubleshooting).

graft names every VM `graft-<uuid>` so the shutdown sweep (`orchard list vms`) can
find and delete its own VMs without touching anything else on the cluster.

## Setup

For a single-machine smoke test, skip all of this: **`graft tree plant`** + **`graft tree branch http://localhost:6120`** then **`graft init`** (see [Driving Orchard from graft](#driving-orchard-from-graft))
gives you a local fleet with zero hand-editing. For a real fleet:

### 1. Stand up the controller
Run `orchard controller run` on a host reachable from your Macs and from wherever
`graft run` lives (it can be a Linux box — the controller only schedules and holds
state). Add TLS + auth per the
[Orchard deployment guide](https://tart.run/orchard/deploying-controller/).

### 2. Two service accounts
A fleet uses two, with different roles:

- **graft** — to create/exec/delete VMs. `graft init` creates this one and
  stores its token in the Keychain for you (when you hold an admin `orchard` context);
  the manual equivalent is:
  ```sh
  orchard create service-account graft \
    --roles compute:read --roles compute:write --roles compute:connect --token <token>
  ```
  Either way the token belongs in the **Keychain**, not plaintext config (see
  [Driving Orchard from graft](#driving-orchard-from-graft)).
- **workers** — a bootstrap token so Macs can join:
  ```sh
  orchard get bootstrap-token <worker-service-account>
  ```

### 3. Join each Mac as a worker
On every Apple Silicon Mac that will boot VMs:
```sh
orchard worker run https://orchard.example.com:6120 \
  --bootstrap-token <token> \
  --name mac-studio-1 \
  --labels hardware=m4max        # optional — pools can require labels to target hardware
```
That's the **entire** per-Mac setup. The worker needs `tart` installed and an **active
GUI login session** (Virtualization.framework won't boot a VM without one — see
[ec2-mac-setup.md](ec2-mac-setup.md) for headless Macs); keep it alive with a launchd
job so it survives reboots. The worker runs **no graft and holds no GitHub creds** — it's
pure muscle. Add or remove workers anytime; the controller absorbs the change on graft's
next acquire (see [How the fleet works](#how-the-fleet-works)).

### 4. Point graft at the controller
`graft init` writes this block (and stores the token in the Keychain) for you;
here's what it produces — note there's **no `token` field**, it's Keychain-backed:
```json
{
  "provider": "orchard",
  "orchard": {
    "controllerURL": "https://orchard.example.com:6120",
    "serviceAccount": "graft",
    "maxVMs": 8
  },
  "pools": [
    {
      "name": "macos-ci",
      "image": "ghcr.io/cirruslabs/macos-tahoe-xcode:latest",
      "os": "macos",
      "count": 6,
      "github": { "appId": 12345, "target": "org:my-org", "runnerGroupId": 1 }
    }
  ],
  "secrets": { "store": "keychain", "scope": "login" }
}
```

Validate and run:
```sh
graft config validate
graft run
```

## Capacity & scheduling

graft does **not** second-guess placement — the controller schedules across the
fleet and owns Apple's per-host 2-macOS-VM limit. At planning time graft queries the
fleet for **live free `tart-vms` slots** (what every schedulable worker advertises
minus what's already placed cluster-wide) and sizes its ask to that, capped at
`maxVMs` (default 100). If the controller is unreachable it falls back to the static
`maxVMs` ceiling. So set your pool `count` to the number of runners you actually want
and graft fills toward whatever the fleet can actually take.

**If `count` still exceeds the fleet's free slots** (e.g. a mixed macOS+Linux fleet
sharing one `tart-vms` pool, or capacity that shrinks mid-run), the controller queues
the excess VMs as `pending`; graft waits up to ~10 min for each, then times out,
deletes it, and retries. It works — VMs land as workers free up — but **churns** when
chronically over-subscribed. Live capacity (above) avoids this in the common case;
size `count` / `maxVMs` to roughly your real fleet capacity (~2 macOS VMs per worker)
to be safe. `graft tree status` / `branches` show the live free-slot count.

> **The 2-macOS escape hatch.** Orchard can schedule a macOS image as an `os: linux`
> VM to dodge the 2-macOS-VM/host cap (the guest still runs macOS; only the
> bookkeeping differs). graft passes the pool's declared `os` straight through, so
> this is an operator choice — set `os: linux` on the pool if you've accepted the
> tradeoffs. See the Orchard docs.

## Mounts & images

- **Images:** workers pull pool images themselves (`image-pull-policy` =
  *if-not-present*), so graft skips the local pre-pull it does for the Tart backend.
  Push your `.graft`-built images to a registry the workers can reach.
- **Mounts:** a pool's `mounts` become `orchard create vm --host-dirs …`. Note these
  resolve on the **worker** host, not on the machine running `graft run` — only
  useful for paths that exist on the workers.
- **Networking:** a pool's `network` maps to `--net-bridged <iface>` / `--net-softnet`
  on the worker, same as the local backend.

## Troubleshooting

- **`orchard ssh` / port-forward fails instantly with `context deadline exceeded` (500).**
  Orchard's `--wait` flag is the deadline for the *entire* port-forward rendezvous (the
  controller waiting for the worker to stand up the SSH tunnel), not just "wait for the VM
  to be running" — so `--wait 0` kills the tunnel in ~100µs before the worker can respond.
  graft never passes `--wait 0` for this reason (see `OrchardProvider.sshArgs`); if you
  hit this driving `orchard` by hand, pass a real `--wait` (the CLI default is 60s).
- **Tart's default 1-day DHCP lease** can independently cause worker↔VM comms issues
  (Orchard warns about it at startup); if VMs are genuinely unreachable, fix it per
  [tart.run/faq → DHCP lease time](https://tart.run/faq/#changing-the-default-dhcp-lease-time).

**Verified end-to-end against Orchard 0.55.0** (`orchard dev`, single Mac): `create vm`
(with `--os`), `get vm <name>/status` polling, `ssh vm` exec, the JIT runner downloading
over `orchard ssh` and registering on GitHub ("Listening for Jobs"), and `delete vm`.
graft avoids `list vms --quiet` (added after 0.55.0) and doesn't pass `--restart-policy`
(Orchard defaults to `Never`, which is what ephemeral runners want).
