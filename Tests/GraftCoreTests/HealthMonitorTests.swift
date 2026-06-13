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
}
