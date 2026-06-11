import Foundation

/// Registers and deregisters JIT runners for a pool. `GitHubAppClient` is the
/// production conformer; tests inject a mock. Keeps the supervisor off the network.
public protocol JITConfigProvider: Sendable {
    func generateJITRunner(pool: PoolConfig, runnerName: String) async throws -> GitHubAppClient.JITRunner
    func deleteRunner(id: Int, target: GitHubTarget) async throws
}

/// Runs the ephemeral runner in a VM and returns its exit code.
/// `RunnerProvisioner` is the production conformer.
public protocol RunnerRunner: Sendable {
    func runEphemeralRunner(on vm: RunningVM, jitConfig: String) async throws -> Int32
}

extension GitHubAppClient: JITConfigProvider {}
extension RunnerProvisioner: RunnerRunner {}

/// What a runner slot is currently doing — surfaced to an optional status reporter
/// so a live UI (the `graft run` spinner dashboard) can show per-slot progress.
public enum RunnerPhase: Sendable {
    case acquiring          // cloning + booting the VM
    case running            // runner is up; jobs flow through it
    case deregistering      // removing the JIT runner from GitHub
    case stopping           // stopping + deleting the VM
    case retrying           // acquire failed; backing off
    case done               // slot exited (remove its row)

    public var label: String {
        switch self {
        case .acquiring: return "booting VM"
        case .running: return "running"
        case .deregistering: return "deregistering runner"
        case .stopping: return "stopping VM"
        case .retrying: return "retrying…"
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
    private let runner: any RunnerRunner
    private let state: StateManager
    private let status: RunnerStatusReporter?
    private var runners: [String: RunnerRecord] = [:]
    /// VMs currently being torn down — so the shutdown watcher and a slot's own
    /// teardown can't both fire `tart stop`/`delete` on the same VM and wedge tart
    /// on its per-VM lock inside an un-cancellable `Shell.run`.
    private var releasing: Set<String> = []

    /// `github` is a factory keyed by App ID — different pools can use different
    /// GitHub Apps (personal vs. work), each with its own client.
    public init(
        config: GraftConfig,
        provider: any VMProvider,
        github: @escaping @Sendable (Int) -> any JITConfigProvider,
        runner: any RunnerRunner,
        state: StateManager = StateManager(),
        status: RunnerStatusReporter? = nil
    ) {
        self.config = config
        self.provider = provider
        self.github = github
        self.runner = runner
        self.state = state
        self.status = status
    }

    /// Convenience for the production path: GitHub App clients backed by `secrets`,
    /// runner via the provider's exec channel.
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
            runner: RunnerProvisioner(provider: provider),
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
        let github = github(pool.github.appId)
        let tag = "\(pool.name)#\(index)"
        func report(_ phase: RunnerPhase, _ vm: String? = nil) { status?(tag, vm, phase) }

        while !Task.isCancelled {
            do {
                report(.acquiring)
                let vm = try await provider.acquire(image: pool.image, os: pool.os)
                track(vm, pool: pool.name)
                Log.info("[\(tag)] acquired \(vm.name) (\(vm.ip))")

                var runnerID: Int?
                do {
                    report(.running, vm.name)
                    let jit = try await github.generateJITRunner(pool: pool, runnerName: vm.name)
                    runnerID = jit.runnerID
                    let exitCode = try await runner.runEphemeralRunner(on: vm, jitConfig: jit.encodedConfig)
                    Log.info("[\(tag)] runner \(vm.name) finished (exit \(exitCode))")
                } catch is CancellationError {
                    Log.info("[\(tag)] runner \(vm.name) stopped (shutdown)")
                } catch {
                    Log.warn("[\(tag)] runner \(vm.name) failed: \(error)")
                }

                // Deregister from GitHub so a runner that never ran a job (e.g. killed
                // on shutdown) doesn't linger as an offline husk. A completed job is
                // already gone — deleteRunner 404s, which we ignore. Must survive the
                // slot's own cancellation: on graceful shutdown the task is already
                // cancelled here, so a plain `await` would be aborted and leak the
                // runner — exactly the case this cleans up.
                if let runnerID, let target = try? pool.github.parsedTarget() {
                    report(.deregistering, vm.name)
                    await deregister(runnerID: runnerID, target: target, via: github)
                }

                report(.stopping, vm.name)
                await releaseOnce(vm)
            } catch {
                if Task.isCancelled { break }
                report(.retrying)
                Log.warn("[\(tag)] acquire failed: \(error) — retrying in 5s")
                try? await Task.sleep(for: .seconds(5))
            }
        }
        report(.done)
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
        untrack(vm.name)
        try? await provider.release(vm)
        releasing.remove(vm.name)
    }

    private func persist() {
        do {
            try state.save(PoolState(runners: Array(runners.values), updatedAt: Date()))
        } catch {
            Log.warn("state save failed: \(error)")
        }
    }

    // MARK: Lifecycle

    /// Destroy leftovers from a prior run. With `tart exec`, the watching process
    /// died with us, so any surviving graft VM is a dead-runner husk — clean slate,
    /// then fill fresh. (Reattach isn't meaningful without a live exec channel.)
    private func reconcile() async {
        for record in state.load()?.runners ?? [] {
            Log.info("reconcile: releasing leftover \(record.vm.name)")
            try? await provider.release(record.vm)
        }
        // Sweep any graft-* VMs that never made it into state (crash before persist).
        await sweepGraftVMs()
        runners.removeAll()
        persist()
    }

    /// Stop every tracked VM — the reliable lever for breaking a slot blocked in
    /// `tart exec` during shutdown.
    private func stopTrackedVMs() async {
        for record in Array(runners.values) {
            Log.info("shutdown: stopping \(record.vm.name)")
            await releaseOnce(record.vm)
        }
    }

    /// Destroy any graft-managed VMs still on the host — belt-and-suspenders so a
    /// crash or a teardown race never leaves a VM (and its quota slot) behind.
    private func sweepGraftVMs() async {
        guard let tart = provider as? LocalTartProvider else { return }
        for vm in (try? await tart.graftManagedVMs()) ?? [] {
            Log.info("sweeping \(vm.name)")
            try? await Tart.stop(name: vm.name)
            try? await Tart.delete(name: vm.name)
        }
    }

    private func cleanup() async {
        for record in Array(runners.values) {
            Log.info("shutdown: releasing \(record.vm.name)")
            await releaseOnce(record.vm)
        }
        runners.removeAll()
        // Final sweep catches anything a slot's own teardown raced past.
        await sweepGraftVMs()
        persist()
        Log.info("graft stopped")
    }
}
