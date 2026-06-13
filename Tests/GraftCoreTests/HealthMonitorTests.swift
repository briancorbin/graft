import Foundation
import Testing
@testable import GraftCore

@Suite("HealthMonitor")
struct HealthMonitorTests {
    /// Mutable test state shared into the detector + clock closures.
    final class Box: @unchecked Sendable {
        var events: [HealthEvent] = []
        var date = Date(timeIntervalSince1970: 0)
    }

    struct StubDetector: HealthDetector {
        let box: Box
        var name: String { "stub" }
        func probe() async -> [HealthEvent] { box.events }
    }

    actor Recorder: EventSink {
        private(set) var events: [HealthEvent] = []
        func emit(_ event: HealthEvent) async { events.append(event) }
        func all() -> [HealthEvent] { events }
    }

    private func warn(_ checkID: String = "offline-runner", subject: String = "graft-x") -> HealthEvent {
        HealthEvent(severity: .warn, category: .runner, checkID: checkID, subject: subject, message: "m")
    }

    @Test("emits a new problem once, suppresses it unchanged, then recovers it")
    func edgeTriggerAndRecover() async {
        let box = Box(), rec = Recorder()
        let monitor = HealthMonitor(
            detectors: [StubDetector(box: box)], reporter: HealthReporter(sinks: [rec]),
            interval: .seconds(60), heartbeatSeconds: nil, now: { box.date })

        let problem = warn()
        box.events = [problem]
        await monitor.tick()          // new → emit
        await monitor.tick()          // unchanged → suppressed
        box.events = []
        await monitor.tick()          // cleared → recovered

        let all = await rec.all()
        #expect(all.count == 2)
        #expect(all[0].severity == .warn)
        #expect(all[1].severity == .recovered)
        #expect(all[1].key == problem.key)   // recovery clears the same condition
    }

    @Test("re-emits when a problem's severity escalates")
    func severityChange() async {
        let box = Box(), rec = Recorder()
        let monitor = HealthMonitor(
            detectors: [StubDetector(box: box)], reporter: HealthReporter(sinks: [rec]),
            interval: .seconds(60), heartbeatSeconds: nil, now: { box.date })

        box.events = [warn()]
        await monitor.tick()
        box.events = [HealthEvent(severity: .critical, category: .runner,
                                  checkID: "offline-runner", subject: "graft-x", message: "worse")]
        await monitor.tick()

        let all = await rec.all()
        #expect(all.count == 2)
        #expect(all[1].severity == .critical)
    }

    @Test("beats a heartbeat on the first tick and again only after the interval elapses")
    func heartbeat() async {
        let box = Box(), rec = Recorder()
        let monitor = HealthMonitor(
            detectors: [StubDetector(box: box)], reporter: HealthReporter(sinks: [rec]),
            interval: .seconds(60), heartbeatSeconds: 300, now: { box.date })

        box.date = Date(timeIntervalSince1970: 1000)
        await monitor.tick()                                   // first → beat
        box.date = Date(timeIntervalSince1970: 1100)           // +100s
        await monitor.tick()                                   // too soon → no beat
        box.date = Date(timeIntervalSince1970: 1400)           // +400s from first
        await monitor.tick()                                   // due → beat

        let beats = await rec.all().filter { $0.checkID == "heartbeat" }
        #expect(beats.count == 2)
        #expect(beats.allSatisfy { $0.severity == .info })
    }

    // MARK: factory isTrunk gating

    struct StubProvider: VMProvider {
        func capacity(for os: GuestOS) async -> Int { 2 }
        func acquire(image: String, os: GuestOS, mounts: [Mount], network: VMNetwork, resources: VMResources, onProgress: (@Sendable (AcquireProgress) -> Void)?) async throws -> RunningVM {
            RunningVM(name: "x", ip: "", os: os)
        }
        func release(_ vm: RunningVM) async throws {}
        func exec(on vm: RunningVM, _ command: [String], timeout: Duration?) async throws -> ShellResult {
            ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
        func execStreaming(on vm: RunningVM, script: String, onLine: (@Sendable (String) -> Void)?) async throws -> Int32 { 0 }
    }

    struct StubSecrets: SecretStore {
        func privateKeyPEM(forAppID appID: Int) async throws -> String { "" }
    }

    @Test("factory includes state-backed detectors only on the trunk")
    func factoryIsTrunkGate() {
        let cfg = GraftConfig(
            github: GitHubConfig(appId: 1, target: "org:acme"),
            pools: [PoolConfig(name: "p", image: "i", os: .macOS, count: 1)])

        let trunk = HealthMonitorFactory.detectors(
            config: cfg, provider: StubProvider(), secrets: StubSecrets(), isTrunk: true)
        let observer = HealthMonitorFactory.detectors(
            config: cfg, provider: StubProvider(), secrets: StubSecrets(), isTrunk: false)

        #expect(Set(trunk.map(\.name)) == ["auth", "runner", "capacity", "leaf", "supervisor"])
        #expect(Set(observer.map(\.name)) == ["auth", "runner", "capacity"])  // no leaf/deadwood off-trunk
        #expect(trunk.count == 5)   // Tart: no controller-reachability detector
    }

    @Test("factory adds the controller-reachability detector on the Orchard backend")
    func factoryOrchardControllerCheck() {
        let orchard = OrchardConfig(controllerURL: URL(string: "http://c:6120")!, serviceAccount: "graft")
        let cfg = GraftConfig(
            provider: .orchard(orchard),
            github: GitHubConfig(appId: 1, target: "org:acme"),
            pools: [PoolConfig(name: "p", image: "i", os: .macOS, count: 1)])
        let detectors = HealthMonitorFactory.detectors(
            config: cfg, provider: OrchardProvider(config: orchard), secrets: StubSecrets(), isTrunk: true)
        // auth, runner, capacity, controller-reachability, leaf, deadwood
        #expect(detectors.count == 6)
    }
}
