import Foundation
import Testing
@testable import GraftCore

@Suite("HealthEvent")
struct HealthEventTests {
    @Test("round-trips through compact JSON unchanged")
    func roundTrip() throws {
        let original = HealthEvent(
            severity: .warn,
            category: .runner,
            checkID: "offline-runner",
            subject: "graft-mac-0",
            message: "runner offline past grace",
            detail: ["status": "offline", "graceSeconds": "120"],
            suggestedAction: "deregister + replace",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try HealthEvent.compactEncoder.encode(original)
        let decoded = try HealthEvent.decoder.decode(HealthEvent.self, from: data)
        #expect(decoded == original)
    }

    @Test("compact encoding is exactly one line (JSONL-safe)")
    func singleLine() throws {
        let event = HealthEvent(
            severity: .critical, category: .auth, checkID: "token-mint",
            message: "could not mint installation token",
            detail: ["url": "https://api.github.com/app/installations/42/access_tokens"]
        )
        let line = String(decoding: try HealthEvent.compactEncoder.encode(event), as: UTF8.self)
        #expect(!line.contains("\n"))
        #expect(line.contains("https://api.github.com")) // slash not escaped
    }

    @Test("key identifies the condition; differs by subject, matches across emissions")
    func keyStability() {
        let a1 = HealthEvent(severity: .warn, category: .leaf, checkID: "wedged-guest",
                             subject: "graft-mac-0", message: "x")
        let a2 = HealthEvent(severity: .critical, category: .leaf, checkID: "wedged-guest",
                             subject: "graft-mac-0", message: "y",
                             timestamp: Date(timeIntervalSince1970: 1))
        let b = HealthEvent(severity: .warn, category: .leaf, checkID: "wedged-guest",
                            subject: "graft-mac-1", message: "x")
        #expect(a1.key == a2.key)   // same condition, different severity/time
        #expect(a1.key != b.key)    // different subject
        #expect(a1.id != a2.id)     // distinct emissions
    }
}
