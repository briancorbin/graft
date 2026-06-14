import Foundation

/// Registers and deregisters JIT runners for a pool. `GitHubAppClient` is the
/// production conformer; tests inject a mock. Keeps the supervisor off the network.
public protocol JITConfigProvider: Sendable {
    func generateJITRunner(github: GitHubConfig, labels: [String], runnerName: String) async throws -> GitHubAppClient.JITRunner
    func deleteRunner(id: Int, target: GitHubTarget) async throws
    /// Runners registered on `target` — the supervisor polls this to watch each leaf's
    /// runner come online and then finish. This is how it monitors a leaf without ever
    /// exec-ing into the guest.
    func listRunners(target: GitHubTarget) async throws -> [GitHubAppClient.Runner]
    /// Best-effort name of the job a runner is currently running (for the dashboard label).
    func currentRunningJob(runnerName: String, target: GitHubTarget) async -> String?
}

extension GitHubAppClient: JITConfigProvider {}

/// What a runner slot is currently doing — surfaced to an optional status reporter
/// so a live UI (the `graft run` spinner dashboard) can show per-slot progress.
public enum RunnerPhase: Sendable {
    case acquiring          // submitted; cloning/creating the leaf
    case waitingForCapacity // fleet has no room right now — parked, not churning a doomed acquire
    case scheduling         // Orchard: submitted, waiting for a branch to take it (pending placement)
    case booting            // placed/cloned; the guest is coming up
    case provisioning       // leaf up; registering the JIT runner with GitHub
    case starting           // runner process launched, configuring inside the guest
    case connected          // connected to GitHub; configuring before it listens
    case ready              // connected + listening for jobs
    case busy(String)       // running a named job
    case deregistering      // removing the JIT runner from GitHub
    case stopping           // stopping + deleting the VM
    case retrying           // acquire failed; backing off
    case done               // slot exited (remove its row)

    public var label: String {
        switch self {
        case .acquiring: return "acquiring leaf"
        case .waitingForCapacity: return "waiting for capacity"
        case .scheduling: return "scheduling · waiting for a branch"
        case .booting: return "booting leaf"
        case .provisioning: return "registering runner"
        case .starting: return "starting up"
        case .connected: return "connected · preparing"
        case .ready: return "ready · waiting for jobs"
        case .busy(let job): return "running job: \(job)"
        case .deregistering: return "deregistering runner"
        case .stopping: return "stopping leaf"
        case .retrying: return "retrying…"
        case .done: return "done"
        }
    }

    /// Stable key (no payload) for status UIs to pick an icon/colour.
    public var kind: String {
        switch self {
        case .acquiring: return "acquiring"
        case .waitingForCapacity: return "waiting"
        case .scheduling: return "scheduling"
        case .booting: return "booting"
        case .provisioning: return "provisioning"
        case .starting: return "starting"
        case .connected: return "connected"
        case .ready: return "ready"
        case .busy: return "busy"
        case .deregistering: return "deregistering"
        case .stopping: return "stopping"
        case .retrying: return "retrying"
        case .done: return "done"
        }
    }
}

/// Per-slot progress callback: `(slotTag, vmName?, phase)`. Invoked from multiple
/// slot tasks concurrently, so conformers must be thread-safe.
public typealias RunnerStatusReporter = @Sendable (String, String?, RunnerPhase) -> Void

/// The desired-state loop. Keeps each pool filled to its runner count, respecting
/// the host's per-OS capacity (Apple's 2-macOS-VM limit, budgeted across pools).
/// Each slot runs the full ephemeral loop forever: acquire → JIT → run one job →
/// release → repeat. Runs until the task is cancelled (graceful shutdown).
public actor PoolSupervisor {
    private let config: GraftConfig
    private let provider: any VMProvider
    private let github: @Sendable (Int) -> any JITConfigProvider
    private let state: StateManager
    private let status: RunnerStatusReporter?
    private var runners: [String: RunnerRecord] = [:]
    /// Leaves re-adopted on restart (their runner was still online), queued by pool for a
    /// slot to monitor through to completion instead of acquiring a fresh leaf.
    private var adoptable: [String: [RunningVM]] = [:]
    /// VMs currently being torn down — so the shutdown watcher and a slot's own
    /// teardown can't both fire `tart stop`/`delete` on the same VM and wedge tart
    /// on its per-VM lock inside an un-cancellable `Shell.run`.
    private var releasing: Set<String> = []
    /// Per-slot phase, persisted so out-of-process UIs (menu bar, `graft status`)
    /// can show what each slot is doing — works in daemon mode where there's no
    /// live dashboard.
    private var slots: [String: SlotStatus] = [:]

    /// `github` is a factory keyed by App ID — different pools can use different
    /// GitHub Apps (personal vs. work), each with its own client.
    public init(
        config: GraftConfig,
        provider: any VMProvider,
        github: @escaping @Sendable (Int) -> any JITConfigProvider,
        state: StateManager = StateManager(),
        status: RunnerStatusReporter? = nil
    ) {
        self.config = config
        self.provider = provider
        self.github = github
        self.state = state
        self.status = status
    }

    /// Convenience for the production path: GitHub App clients backed by `secrets`.
    public init(
        config: GraftConfig,
        provider: any VMProvider,
        secrets: any SecretStore,
        state: StateManager = StateManager(),
        status: RunnerStatusReporter? = nil
    ) {
        self.init(
            config: config,
            provider: provider,
            github: { appID in GitHubAppClient(appID: appID, secrets: secrets) },
            state: state,
            status: status
        )
    }

    public func run() async {
        await reconcile()

        await withTaskGroup(of: Void.self) { group in
            // Budget capacity per OS across ALL pools (two macOS pools can't each
            // grab 2 VMs on a 2-VM host). Shared planner keeps this identical to the
            // target the menu-bar app shows.
            var capacityByOS: [GuestOS: Int] = [:]
            for os in GuestOS.allCases { capacityByOS[os] = await provider.capacity(for: os) }
            // Re-adopted leaves already hold capacity but *are* the desired runners — add them
            // back so the planner budgets a slot to reclaim each. Without this, a full fleet
            // (0 free) plans 0 slots and the re-adopted leaves are never monitored or torn down.
            for (poolName, leaves) in adoptable {
                if let os = config.pools.first(where: { $0.name == poolName })?.os {
                    capacityByOS[os, default: 0] += leaves.count
                }
            }

            for (pool, slots) in config.plannedSlots(capacity: { capacityByOS[$0] ?? 0 }) {
                if slots < pool.count {
                    Log.warn("pool '\(pool.name)': clamped \(pool.count) → \(slots) (host \(pool.os.rawValue) capacity)")
                }
                Log.info("pool '\(pool.name)': \(slots) runner slot(s)")
                for slot in 0..<slots {
                    group.addTask { await self.runSlot(pool: pool, index: slot) }
                }
            }

            // Shutdown watcher: once cancelled, stop every tracked VM. Stopping a VM
            // kills its guest runner, which makes a slot's blocked `tart exec` return
            // so the slot can tear down and the group can complete. Without this, a
            // runner that ignores SIGTERM hangs the entire shutdown.
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                await self.stopTrackedVMs()
            }

            await group.waitForAll()
        }

        await cleanup()
    }

    // MARK: One runner slot

    private func runSlot(pool: PoolConfig, index: Int) async {
        let tag = "\(pool.name)#\(index)"
        guard let gh = config.gitHub(for: pool) else {
            Log.warn("[\(tag)] no GitHub config — skipping (set a profile `github` or a pool override)")
            return
        }
        let github = github(gh.appId)
        func report(_ phase: RunnerPhase, _ vm: String? = nil) {
            recordPhase(tag: tag, pool: pool.name, vm: vm, phase: phase)
        }

        while !Task.isCancelled {
            do {
                // Re-adopt a leaf from a prior run before acquiring a fresh one: monitor it to
                // completion and tear it down, so a supervisor restart doesn't kill a running
                // job (and the re-adopted leaf counts toward the pool's desired count).
                if let adopted = claimAdoptable(pool: pool.name) {
                    Log.info("[\(tag)] re-adopted \(adopted.name) — monitoring to completion")
                    report(.ready, adopted.name)
                    await monitorRunner(tag: tag, pool: pool.name, vm: adopted.name, github: github, target: try? gh.parsedTarget())
                    report(.stopping, adopted.name)
                    await releaseOnce(adopted)
                    continue
                }
                // Park until the fleet has room. Firing `acquire` into a 0-capacity fleet
                // (e.g. every Orchard worker gone) just churns create→pending→timeout→delete;
                // instead wait and resume when capacity returns. Local Tart's capacity is its
                // fixed host ceiling (never 0), so only an Orchard fleet actually parks here.
                while !Task.isCancelled, await provider.capacity(for: pool.os) <= 0 {
                    report(.waitingForCapacity)
                    try await Task.sleep(for: .seconds(15))
                }
                if Task.isCancelled { break }
                let name = makeGraftVMName()
                report(.acquiring, name)
                // Surface the leaf's real lifecycle: scheduling (waiting for a branch) vs booting.
                let onProgress: @Sendable (AcquireProgress) -> Void = { progress in
                    let phase: RunnerPhase
                    switch progress {
                    case .scheduling: phase = .scheduling
                    case .booting: phase = .booting
                    }
                    Task { await self.recordPhase(tag: tag, pool: pool.name, vm: name, phase: phase) }
                }
                // Mint the JIT runner FIRST: its config is embedded in the leaf's startup
                // script, which the worker (Orchard) or local tart runs on boot. The
                // supervisor never execs into the guest — it watches the runner on GitHub.
                report(.provisioning, name)
                let jit = try await github.generateJITRunner(github: gh, labels: pool.resolvedLabels(), runnerName: name)
                let script = RunnerProvisioner.provisionScript(os: pool.os, jitConfig: jit.encodedConfig)

                let vm = try await provider.acquire(name: name, image: pool.image, os: pool.os, mounts: pool.mounts ?? [], network: pool.network ?? .nat, resources: pool.resources, startupScript: script, onProgress: onProgress)
                track(vm, pool: pool.name)
                Log.info("[\(tag)] acquired \(vm.name) (\(vm.ip))")

                // Watch the runner on GitHub until its single job finishes (or it never
                // registers within the grace window). No exec, no held stream.
                await monitorRunner(tag: tag, pool: pool.name, vm: vm.name, github: github, target: try? gh.parsedTarget())

                // Deregister so a runner that never ran (e.g. killed on shutdown) doesn't
                // linger as an offline husk; a completed ephemeral runner is already gone
                // (deleteRunner 404s, ignored). Shielded so it survives the slot's own
                // cancellation on graceful shutdown.
                if let target = try? gh.parsedTarget() {
                    report(.deregistering, vm.name)
                    await deregister(runnerID: jit.runnerID, target: target, via: github)
                }
                report(.stopping, vm.name)
                await releaseOnce(vm)
            } catch {
                if Task.isCancelled { break }
                report(.retrying)
                Log.warn("[\(tag)] slot error: \(error) — retrying in 5s")
                try? await Task.sleep(for: .seconds(5))
            }
        }
        report(.done)
    }

    /// How long a freshly-created leaf has to get its runner online before we give up and
    /// replace it (covers boot + startup-script + register). Tunable later via `monitor`.
    static let registrationDeadline: TimeInterval = 300
    static let runnerPollInterval: Duration = .seconds(15)

    /// Watch one leaf's runner on GitHub. "offline/absent" means *still starting* until the
    /// runner has been seen online (bounded by `registrationDeadline`), after which it means
    /// *done → replace*. GitHub unreachable = unknown → keep waiting (never abandon a possible
    /// live job). Returns when the job is done, the runner never registers in time, or the
    /// slot is cancelled.
    private func monitorRunner(tag: String, pool: String, vm: String, github: any JITConfigProvider, target: GitHubTarget?) async {
        guard let target else {
            while !Task.isCancelled { try? await Task.sleep(for: Self.runnerPollInterval) }
            return
        }
        let deadline = Date().addingTimeInterval(Self.registrationDeadline)
        var sawOnline = false
        while !Task.isCancelled {
            if let runners = try? await github.listRunners(target: target) {
                if let runner = runners.first(where: { $0.name == vm }), !runner.isOffline {
                    sawOnline = true
                    if runner.busy {
                        // Tier 1: show what it's actually running (best-effort; repo targets).
                        let job = await github.currentRunningJob(runnerName: vm, target: target)
                        recordPhase(tag: tag, pool: pool, vm: vm, phase: .busy(job ?? "a job"))
                    } else {
                        recordPhase(tag: tag, pool: pool, vm: vm, phase: .ready)
                    }
                } else if sawOnline {
                    Log.info("[\(tag)] runner \(vm) finished")
                    return                      // was online, now gone → job done
                } else if Date() > deadline {
                    Log.warn("[\(tag)] runner \(vm) never registered within \(Int(Self.registrationDeadline))s — replacing")
                    return                      // never came online → replace
                } else {
                    recordPhase(tag: tag, pool: pool, vm: vm, phase: .starting)
                }
            }
            // listRunners failed (GitHub unreachable) → don't decide; keep waiting.
            do { try await Task.sleep(for: Self.runnerPollInterval) } catch { return }
        }
    }

    private enum RunnerLiveness { case online, offline, unknown }

    /// One leaf's runner state on GitHub. Absent (not yet registered, or already
    /// deregistered) reads as `.offline`; an API error reads as `.unknown`.
    private func runnerLiveness(name: String, github: any JITConfigProvider, target: GitHubTarget) async -> RunnerLiveness {
        guard let runners = try? await github.listRunners(target: target) else { return .unknown }
        guard let runner = runners.first(where: { $0.name == name }) else { return .offline }
        return runner.isOffline ? .offline : .online
    }

    /// Deregister a runner from GitHub, shielded from the caller's cancellation and
    /// bounded by a timeout. `Task.detached` doesn't inherit the cancelled parent, so
    /// the cleanup completes during graceful shutdown; the timeout keeps a GitHub
    /// hiccup from stalling teardown.
    private func deregister(runnerID: Int, target: GitHubTarget, via github: any JITConfigProvider) async {
        let work = Task.detached { try await github.deleteRunner(id: runnerID, target: target) }
        let timeout = Task.detached {
            try await Task.sleep(for: .seconds(10))
            work.cancel()
        }
        _ = try? await work.value
        timeout.cancel()
    }

    /// Build the runner-output handler: echo each line above the dashboard (via the
    /// `Log` sink, so it never corrupts the live region) and watch for GitHub runner
    /// markers to move the slot's row to ready / running-job. `@Sendable` — the
    /// streamer calls it from a background reader, so it touches only thread-safe
    /// `Log` and the status reporter.
    private nonisolated func makeRunnerLineHandler(tag: String, pool: String, vm: String) -> @Sendable (String) -> Void {
        { line in
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                Log.raw("[\(tag)] \(line)")
            }
            let phase: RunnerPhase?
            if line.contains("Listening for Jobs") {
                phase = .ready
            } else if let range = line.range(of: "Running job: ") {
                phase = .busy(String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces))
            } else if line.contains("completed with result") {
                phase = .ready
            } else if line.contains("Connected to GitHub") {
                phase = .connected
            } else {
                phase = nil
            }
            if let phase {
                // Hop back onto the actor — the reader runs off-isolation.
                Task { await self.recordPhase(tag: tag, pool: pool, vm: vm, phase: phase) }
            }
        }
    }

    /// Single funnel for every phase change: update the persisted per-slot status and
    /// fan out to the live dashboard reporter. `.done` removes the slot's row.
    private func recordPhase(tag: String, pool: String, vm: String?, phase: RunnerPhase) {
        if case .done = phase {
            slots[tag] = nil
        } else {
            let prior = slots[tag]
            let ip = vm.flatMap { runners[$0]?.vm.ip } ?? prior?.ip
            let since = (prior?.phaseKind == phase.kind) ? (prior?.since ?? Date()) : Date()
            slots[tag] = SlotStatus(
                tag: tag, pool: pool, vmName: vm ?? prior?.vmName, ip: ip,
                phaseLabel: phase.label, phaseKind: phase.kind, since: since
            )
        }
        persist()
        status?(tag, vm, phase)
    }

    // MARK: Tracking + persistence

    private func track(_ vm: RunningVM, pool: String) {
        runners[vm.name] = RunnerRecord(vm: vm, pool: pool, startedAt: Date())
        persist()
    }

    private func untrack(_ name: String) {
        runners[name] = nil
        persist()
    }

    /// Release a VM exactly once. The `releasing` check-and-insert runs
    /// synchronously on the actor (no `await` between), so the second caller — a
    /// slot's own teardown vs. the shutdown watcher — bails before issuing a
    /// duplicate `tart stop`/`delete` that would collide on tart's per-VM lock.
    private func releaseOnce(_ vm: RunningVM) async {
        guard releasing.insert(vm.name).inserted else { return }
        do {
            try await provider.release(vm)
            // Untrack only after a confirmed delete. If release fails (e.g. the controller
            // is down), the VM is still running and still ours — keep it tracked so it isn't
            // mislabeled as orphan `deadwood` (untrack-then-failed-delete was the leak), and
            // so a later reconcile can re-adopt or re-delete it.
            untrack(vm.name)
        } catch {
            Log.warn("release of \(vm.name) failed: \(error) — keeping it tracked for retry")
        }
        releasing.remove(vm.name)
    }

    private func persist() {
        do {
            try state.save(PoolState(
                runners: Array(runners.values),
                slots: slots.values.sorted { $0.tag < $1.tag },
                updatedAt: Date()
            ))
        } catch {
            Log.warn("state save failed: \(error)")
        }
    }

    // MARK: Lifecycle

    /// On startup, reconcile leftover leaves from the last run against GitHub: a leaf whose
    /// runner is still **online** is re-adopted (kept + queued for a slot to monitor through
    /// to completion — a supervisor restart must not kill a running job); one whose runner is
    /// **offline** is released (its job finished or it died). GitHub-unreachable ⇒ keep (never
    /// murder a possible live job). Then sweep graft VMs the backend has that we aren't
    /// tracking — but only ones no target shows online.
    private func reconcile() async {
        for record in state.load()?.runners ?? [] {
            switch await leafLiveness(record) {
            case .offline:
                Log.info("reconcile: releasing finished/dead leaf \(record.vm.name)")
                try? await provider.release(record.vm)
            case .online, .unknown:
                Log.info("reconcile: re-adopting live leaf \(record.vm.name)")
                runners[record.vm.name] = record
                adoptable[record.pool, default: []].append(record.vm)
            }
        }
        // Crash-before-persist orphans: sweep graft VMs we aren't tracking — but never one
        // whose runner is still online somewhere (it may be running a real job).
        let tracked = Set(runners.keys)
        for name in await provider.managedVMNames() where !tracked.contains(name) {
            if await anyTargetOnline(name: name) {
                Log.info("reconcile: leaving live orphan \(name) (runner online)")
            } else {
                Log.info("reconcile: sweeping dead orphan \(name)")
                try? await provider.release(RunningVM(name: name, ip: "", os: .macOS))
            }
        }
        slots.removeAll()
        persist()
    }

    /// Pop one leaf queued for re-adoption in `pool`, if any (a slot claims it to monitor).
    private func claimAdoptable(pool: String) -> RunningVM? {
        guard var queue = adoptable[pool], !queue.isEmpty else { return nil }
        let vm = queue.removeFirst()
        adoptable[pool] = queue.isEmpty ? nil : queue
        return vm
    }

    /// Liveness of a leftover leaf's GitHub runner, resolved via its pool's GitHub config.
    private func leafLiveness(_ record: RunnerRecord) async -> RunnerLiveness {
        guard let pool = config.pools.first(where: { $0.name == record.pool }),
              let gh = config.gitHub(for: pool),
              let target = try? gh.parsedTarget() else { return .unknown }
        return await runnerLiveness(name: record.vm.name, github: github(gh.appId), target: target)
    }

    /// True if any distinct pool target shows a runner named `name` online — so we don't
    /// sweep a live orphan we can't otherwise map back to a pool.
    private func anyTargetOnline(name: String) async -> Bool {
        var seen = Set<String>()
        for pool in config.pools {
            guard let gh = config.gitHub(for: pool), let target = try? gh.parsedTarget(),
                  seen.insert("\(gh.appId)|\(gh.target)").inserted else { continue }
            if case .online = await runnerLiveness(name: name, github: github(gh.appId), target: target) { return true }
        }
        return false
    }

    /// Stop every tracked VM — the reliable lever for breaking a slot blocked in
    /// `tart exec` during shutdown.
    private func stopTrackedVMs() async {
        for record in Array(runners.values) {
            Log.info("shutdown: stopping \(record.vm.name)")
            await releaseOnce(record.vm)
        }
    }

    /// Destroy any graft-managed VMs the backend still has — belt-and-suspenders so a
    /// crash or a teardown race never leaves a VM (and its capacity slot) behind. Each
    /// provider knows how to find its own (local Tart by prefix, Orchard via its API).
    private func sweepGraftVMs() async {
        await provider.sweepOrphans()
    }

    private func cleanup() async {
        for record in Array(runners.values) {
            Log.info("shutdown: releasing \(record.vm.name)")
            await releaseOnce(record.vm)
        }
        runners.removeAll()
        slots.removeAll()
        // Final sweep catches anything a slot's own teardown raced past.
        await sweepGraftVMs()
        persist()
        Log.info("graft stopped")
    }
}
