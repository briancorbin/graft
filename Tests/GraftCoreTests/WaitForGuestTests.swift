import Foundation
import Testing
@testable import GraftCore

@Suite("waitForGuest")
struct WaitForGuestTests {
    /// Records the timeout each readiness probe is given, and can be told to never
    /// become ready (to exercise the overall deadline).
    final class SpyProvider: VMProvider, @unchecked Sendable {
        var lastProbeTimeout: Duration?
        var probeCount = 0
        let everReady: Bool
        init(everReady: Bool) { self.everReady = everReady }

        func capacity(for os: GuestOS) async -> Int { 2 }
        func acquire(image: String, os: GuestOS, mounts: [Mount], network: VMNetwork, resources: VMResources) async throws -> RunningVM {
            RunningVM(name: "x", ip: "", os: os)
        }
        func release(_ vm: RunningVM) async throws {}
        func exec(on vm: RunningVM, _ command: [String], timeout: Duration?) async throws -> ShellResult {
            lastProbeTimeout = timeout
            probeCount += 1
            return ShellResult(exitCode: everReady ? 0 : 1, stdout: "", stderr: "")
        }
        func execStreaming(on vm: RunningVM, script: String, onLine: (@Sendable (String) -> Void)?) async throws -> Int32 { 0 }
    }

    @Test("bounds each readiness probe with the given probeTimeout")
    func boundsProbe() async throws {
        let spy = SpyProvider(everReady: true)
        try await spy.waitForGuest(RunningVM(name: "x", ip: "", os: .macOS),
                                   timeout: .seconds(5), probeTimeout: .seconds(3))
        #expect(spy.lastProbeTimeout == .seconds(3))   // the probe was bounded, not unbounded
    }

    @Test("honors the overall deadline when the guest never becomes ready")
    func honorsDeadline() async throws {
        let spy = SpyProvider(everReady: false)
        await #expect(throws: GraftError.self) {
            try await spy.waitForGuest(RunningVM(name: "x", ip: "", os: .macOS),
                                       timeout: .milliseconds(300), probeTimeout: .seconds(1))
        }
        #expect(spy.probeCount >= 1)
    }
}
