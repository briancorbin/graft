import Foundation

/// Per-pool VM sizing — CPU cores + memory (MB). `nil` means "let the backend
/// default." A pool declares these for its workload (a lint pool is small, an e2e pool
/// is fat), independent of the image: same toolchain image, different shapes. On the
/// Orchard backend graft also requests `memory` as a schedulable resource so the
/// controller only places a leaf where that much RAM is actually free.
public struct VMResources: Sendable, Equatable {
    public var cpu: Int?
    public var memory: Int?   // megabytes
    public init(cpu: Int? = nil, memory: Int? = nil) { self.cpu = cpu; self.memory = memory }
    public static let none = VMResources()
    public var isEmpty: Bool { cpu == nil && memory == nil }
}

/// The central abstraction. The pool supervisor never calls `tart` directly — it
/// always goes through a provider. This is what makes Orchard (multi-host) or a
/// future native backend (Twig) a drop-in swap rather than a rewrite.
public protocol VMProvider: Sendable {
    /// How many more VMs of this OS this provider can currently hand out.
    /// For local Tart + macOS this is Apple's hard 2-VM ceiling minus what's running.
    func capacity(for os: GuestOS) async -> Int

    /// Clone + boot a VM from `image`, wait for it to get an IP, and return it.
    /// `os` is declared by the caller (from pool config) — providers don't probe.
    /// `mounts` are host directory shares passed to the VM at boot; `network` selects
    /// the VM's networking mode (default shared NAT); `resources` sizes the leaf
    /// (CPU/memory) per the pool — on Orchard it's also requested from the scheduler so
    /// a branch won't be over-packed.
    func acquire(image: String, os: GuestOS, mounts: [Mount], network: VMNetwork, resources: VMResources) async throws -> RunningVM

    /// Stop and destroy a VM. Idempotent where possible — releasing an
    /// already-gone VM should not throw.
    func release(_ vm: RunningVM) async throws

    /// Run a short command in the guest and capture its output. The provider owns
    /// the channel — Tart uses `tart exec` (Guest Agent), Orchard its own transport.
    /// `timeout`, if given, bounds the call so a hung transport can't block forever.
    func exec(on vm: RunningVM, _ command: [String], timeout: Duration?) async throws -> ShellResult

    /// Run a script in the guest, streaming its output, and return the remote exit
    /// code. Blocks until the command exits — this is how we run the ephemeral runner
    /// and wait for its single job to finish. `onLine`, if given, receives each output
    /// line live (so the supervisor can echo it and watch for runner state markers);
    /// when nil the output inherits this process's streams.
    func execStreaming(on vm: RunningVM, script: String, onLine: (@Sendable (String) -> Void)?) async throws -> Int32

    /// Destroy any graft-managed VMs this backend still has lying around — a
    /// belt-and-suspenders sweep the supervisor runs on shutdown so a crash or
    /// teardown race never strands a VM (and its capacity slot). Each backend knows
    /// how to enumerate its own (local Tart by name prefix, Orchard via its API).
    /// Default no-op for backends that don't need it.
    func sweepOrphans() async
}

extension VMProvider {
    /// Most backends don't strand host-side state; opt in by overriding.
    public func sweepOrphans() async {}

    /// Convenience: acquire with default networking + backend-default sizing.
    public func acquire(image: String, os: GuestOS, mounts: [Mount] = []) async throws -> RunningVM {
        try await acquire(image: image, os: os, mounts: mounts, network: .nat, resources: .none)
    }

    /// Convenience: unbounded exec (kept for callers that don't need a timeout).
    public func exec(on vm: RunningVM, _ command: [String]) async throws -> ShellResult {
        try await exec(on: vm, command, timeout: nil)
    }

    /// Wait until the guest can run commands (Guest Agent up). Replaces SSH-port
    /// probing — readiness is "can I exec", nothing more.
    ///
    /// Each probe is **bounded** (`probeTimeout`): a `tart exec` that hangs — e.g. when the
    /// Guest Agent never comes up after a bad boot — would otherwise block this loop on a
    /// single iteration and defeat the overall deadline entirely (the original "stuck on
    /// booting VM for 30 minutes" wedge). Bounding the probe lets the deadline actually win.
    public func waitForGuest(
        _ vm: RunningVM,
        timeout: Duration = .seconds(60),
        probeTimeout: Duration = .seconds(10)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let result = try? await exec(on: vm, ["true"], timeout: probeTimeout), result.succeeded { return }
            try await Task.sleep(for: .seconds(2))
        }
        throw GraftError("guest on \(vm.name) wasn't ready to exec within \(timeout)")
    }
}
