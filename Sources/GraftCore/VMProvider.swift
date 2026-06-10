import Foundation

/// The central abstraction. The pool supervisor never calls `tart` directly — it
/// always goes through a provider. This is what makes Orchard (multi-host) or a
/// future native backend (Twig) a drop-in swap rather than a rewrite.
public protocol VMProvider: Sendable {
    /// How many more VMs of this OS this provider can currently hand out.
    /// For local Tart + macOS this is Apple's hard 2-VM ceiling minus what's running.
    func capacity(for os: GuestOS) async -> Int

    /// Clone + boot a VM from `image`, wait for it to get an IP, and return it.
    /// `os` is declared by the caller (from pool config) — providers don't probe.
    func acquire(image: String, os: GuestOS) async throws -> RunningVM

    /// Stop and destroy a VM. Idempotent where possible — releasing an
    /// already-gone VM should not throw.
    func release(_ vm: RunningVM) async throws

    /// Run a short command in the guest and capture its output. The provider owns
    /// the channel — Tart uses `tart exec` (Guest Agent), Orchard its own transport.
    func exec(on vm: RunningVM, _ command: [String]) async throws -> ShellResult

    /// Run a script in the guest, streaming its output to this process, and return
    /// the remote exit code. Blocks until the command exits — this is how we run the
    /// ephemeral runner and wait for its single job to finish.
    func execStreaming(on vm: RunningVM, script: String) async throws -> Int32
}

extension VMProvider {
    /// Wait until the guest can run commands (Guest Agent up). Replaces SSH-port
    /// probing — readiness is "can I exec", nothing more.
    public func waitForGuest(_ vm: RunningVM, timeout: Duration = .seconds(60)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let result = try? await exec(on: vm, ["true"]), result.succeeded { return }
            try await Task.sleep(for: .seconds(2))
        }
        throw GraftError("guest on \(vm.name) wasn't ready to exec within \(timeout)")
    }
}
