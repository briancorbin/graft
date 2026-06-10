import Testing
@testable import GraftCore

@Suite("Runner provisioning script")
struct RunnerProvisionerTests {
    @Test("macOS script targets osx-arm64 and embeds the JIT config")
    func macOSScript() {
        let script = RunnerProvisioner.provisionScript(os: .macOS, jitConfig: "BASE64BLOB")
        #expect(script.contains("actions-runner-osx-arm64-"))
        #expect(script.contains("JITCONFIG='BASE64BLOB'"))
        #expect(script.contains("./run.sh --jitconfig"))
        #expect(!script.contains("config.sh"))            // JIT means no config.sh step
        #expect(script.contains("set -euo pipefail"))
    }

    @Test("linux script targets linux-arm64")
    func linuxScript() {
        let script = RunnerProvisioner.provisionScript(os: .linux, jitConfig: "X")
        #expect(script.contains("actions-runner-linux-arm64-"))
    }

    @Test("uses a pre-baked runner when present, else downloads latest")
    func runnerDiscovery() {
        let script = RunnerProvisioner.provisionScript(os: .macOS, jitConfig: "X")
        #expect(script.contains("if [ ! -x \"$RUNNER_DIR/run.sh\" ]"))
        #expect(script.contains("releases/latest"))        // version fetched, not hardcoded
    }
}
