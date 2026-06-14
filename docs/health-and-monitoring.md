# Health & monitoring

`graft arborist --tend` is graft's **self-monitoring loop** — a continuous tending pass
that watches a running fleet and reports what's wrong. It is **detection-first**: it
observes, classifies, and ships findings to wherever you want them. It does **not**
remediate anything (yet) — see [the self-healing seam](#the-self-healing-seam).

The one-shot `graft arborist` verifies the GitHub App auth chain once and exits.
`--tend` keeps the doctor in the room: it runs the auth check *plus* four more detectors
on a cadence, forever.

```sh
graft arborist --tend                 # tend the active profile, default 60s sweeps
graft arborist --tend --interval 30   # faster cadence
graft arborist --tend --profile work  # a specific profile
```

It runs against the active profile's pools. Stop it with Ctrl-C.

## Where to run it

The monitor belongs with the **supervisor** — the host where `graft run` lives (it holds
the GitHub App key and writes `~/.graft/state`). Note this is *not* the trunk/controller
(`graft tree plant`): on a real Orchard fleet the controller can be a separate Linux box
with no key and no supervisor state. The monitor watches the controller + workers
*remotely* through the Orchard API. Two ways to run it:

- **`graft run --tend`** (recommended) — fold the monitor into the supervisor, in the same
  process. It's unambiguously the trunk, shares the live state, and "run it next to your
  runners" is one flag. This is how you'd run it on a server — under launchd/systemd, same
  as `graft run --daemon`.
- **`graft arborist --tend`** — a standalone monitor. On the trunk it sees everything; run
  it anywhere else (e.g. a laptop pointed at the Orchard controller) and it drops to
  **observer mode** — auth + runner + capacity only — so the state-backed checks can't
  false-fire on an empty local state.

### Each role tends itself

A full Orchard fleet runs three long-running graft processes, and **each has its own
`--tend`** — same event schema and sinks, but detectors matched to what that host can
actually see:

| Process | Vantage | `--tend` detectors |
|---|---|---|
| `graft run` | supervisor / demand | auth · runner · capacity · wedged-slot · deadwood |
| `graft tree branch` | worker host | disk · memory · `tart` health · stranded VMs |
| `graft tree plant` | controller host | disk · memory · controller-responding |

The supervisor sees a worker is *paused* (the symptom) through the controller API; the
branch agent, running *on* that Mac, sees *why* — its disk is full — ideally first. The
worker and controller agents carry **no GitHub creds** (host probes only), so the "worker
holds no secret" property is preserved. All three emit the same `HealthEvent` to the same
JSONL/webhook → one dashboard. (For local Tart there's just the one process, `graft run --tend`.)

## What it watches

Five detectors, each reusing a probe graft already has rather than paralleling it. The
event JSON uses plain machine categories; the horticultural names are just how we talk
about them.

| Category (JSON) | Metaphor | What it flags | Reuses |
|---|---|---|---|
| `auth` | rot | GitHub App auth chain fails (key → JWT → installation → token) | the `arborist` chain |
| `runner` | blight | a graft-named runner registered but **offline** on GitHub (a missed deregistration) | `listRunners` |
| `capacity` | drought | configured count exceeds host capacity; a fleet worker is **paused**; the **controller is unreachable** | `provider.capacity`, Orchard `report()` |
| `leaf` | wilt | a slot **wedged** in a transient phase (booting/provisioning/…) past a timeout | persisted slot phases |
| `supervisor` | deadwood | a graft VM the backend still has that **no slot owns** (a leak) | `provider.managedVMNames()` |
| `host` | soil | low disk · memory pressure · `tart`/controller unhealthy · stranded worker VMs (branch/trunk agents) | FileManager, Mach, `tart list` |

### Severity

| Severity | Meaning |
|---|---|
| `info` | a normal observation — e.g. the periodic heartbeat |
| `warn` | degraded, worth a look, not yet dropping work |
| `critical` | actively broken / will drop jobs |
| `recovered` | a previously-reported problem has cleared |

The monitor **edge-triggers**: it emits a problem when it first appears or its severity
changes, stays quiet while it persists unchanged, and emits a `recovered` when it clears.
A periodic `info` heartbeat (default every 300s) proves the monitor is alive even when
everything's healthy.

## Where findings go (sinks)

Every event fans out to all configured sinks at once. The generic ones are the trunk;
Slack / PagerDuty / Sentry are just reformatters in front of a webhook.

| Sink | Destination | Always on? |
|---|---|---|
| log | the normal `graft` stdout/stderr (human lines) | yes |
| JSONL | `~/.graft/logs/health.jsonl` — one event per line, append-only | yes |
| snapshot | `~/.graft/state/health.json` — the *current* set of active problems | yes |
| webhook | `POST <url>` per event, JSON body | when `monitor.webhooks` is set |

`health.jsonl` is your durable history (`tail -f` it, ship it anywhere line-oriented).
`health.json` is the pull surface for a GUI/dashboard — it holds only what's wrong *right
now* (a `warn`/`critical` upserts by key; a `recovered` clears it).

## Event schema

```json
{
  "timestamp": "2026-06-12T21:30:00Z",
  "severity": "warn",
  "category": "runner",
  "checkID": "offline-runner",
  "subject": "graft-9f2a…",
  "message": "graft runner registered but offline on org:acme — likely a missed deregistration",
  "detail": { "target": "org:acme", "runnerId": "42", "status": "offline" },
  "suggestedAction": "deregister it (`graft runners prune`) so the slot can replace it"
}
```

| Field | Notes |
|---|---|
| `timestamp` | ISO-8601 (UTC) |
| `severity` | `info` \| `warn` \| `critical` \| `recovered` |
| `category` | `auth` \| `runner` \| `capacity` \| `leaf` \| `supervisor` |
| `checkID` | stable sub-id within a category (`offline-runner`, `wedged-slot`, `orphan-vm`, …) |
| `subject` | the pool / vm / runner / host it's about, or absent if global |
| `message` | human summary |
| `detail` | string→string context, varies by check |
| `suggestedAction` | a hint — **graft does not act on it yet** (the remediation seam reads it) |

`category` + `checkID` + `subject` together identify a *condition*, so a webhook receiver
can dedup and correlate a problem with its later `recovered`.

## Wiring an alert sink

A receiver is tiny — it gets the schema above and reformats. A complete relay to Slack:

```python
# health_relay.py — POST graft health events, forward problems to Slack
from http.server import BaseHTTPRequestHandler, HTTPServer
import json, urllib.request

SLACK = "https://hooks.slack.com/services/XXX/YYY/ZZZ"

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        e = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if e["severity"] in ("warn", "critical", "recovered"):
            icon = {"warn":"⚠️","critical":"🔴","recovered":"✅"}[e["severity"]]
            text = f'{icon} *{e["category"]}/{e["checkID"]}* {e.get("subject","")}: {e["message"]}'
            urllib.request.urlopen(SLACK, json.dumps({"text": text}).encode())
        self.send_response(204); self.end_headers()

HTTPServer(("", 8099), H).serve_forever()
```

Then point graft at it:

```json
"monitor": { "webhooks": ["http://127.0.0.1:8099"] }
```

The same shape forwards to PagerDuty (Events API v2) or Sentry — only the reformat
differs. The webhook sink never blocks the monitor: a dead receiver degrades to a warning
in graft's own log, nothing more.

## Config

A `monitor` block is optional — absent, you get observe-only defaults (no webhooks). It
sits at the top level of a profile, alongside `provider`/`github`/`pools`:

```json
{
  "provider": { "type": "tart" },
  "github": { "appId": 12345, "target": "org:acme" },
  "pools": [ { "name": "macos", "image": "…", "os": "macos", "count": 2 } ],
  "monitor": {
    "intervalSeconds": 60,
    "webhooks": ["http://127.0.0.1:8099"],
    "heartbeatSeconds": 300,
    "slotStuckTimeoutSeconds": 300,
    "webhookMinSeverity": "warn"
  }
}
```

| Key | Default | Meaning |
|---|---|---|
| `intervalSeconds` | 60 | seconds between sweeps (CLI `--interval` overrides) |
| `webhooks` | `[]` | URLs each event is POSTed to |
| `heartbeatSeconds` | 300 | min spacing of the `info` heartbeat; `0` disables |
| `slotStuckTimeoutSeconds` | 300 | a transient-phase slot older than this is flagged |
| `webhookMinSeverity` | `warn` | floor for webhook delivery (`recovered` always goes) |

## The self-healing seam

Remediation is the *next* layer, deliberately not built yet — you trust detection in the
wild first, then flip on healers one at a time. The seam is published:
[`Remediator`](../Sources/GraftCore/Remediator.swift) is a protocol that consumes the same
`HealthEvent` stream the sinks already carry, reads `suggestedAction`, and dispatches on
`category` + `checkID`. When it lands it will be opt-in (a future `--tend --heal`),
guarded by backoff + a circuit breaker so it absorbs failures instead of amplifying them —
never on by default.
