import Foundation
import Testing
@testable import GraftCore

@Suite("Config parsing & validation")
struct ConfigTests {
    @Test("runnerGroupId defaults to 1 when omitted")
    func runnerGroupIdDefault() throws {
        let json = """
        { "appId": 42, "target": "org:acme" }
        """
        let gh = try JSONDecoder().decode(GitHubConfig.self, from: Data(json.utf8))
        #expect(gh.runnerGroupId == 1)
    }

    @Test("labels default to [self-hosted, os, name] when unset")
    func defaultLabels() {
        let pool = PoolConfig(name: "macos-release", image: "img:latest", os: .macOS, count: 2)
        #expect(pool.resolvedLabels() == ["self-hosted", "macos", "macos-release"])
    }

    @Test("explicit labels override the default")
    func explicitLabels() {
        let pool = PoolConfig(name: "p", image: "i", os: .linux, count: 1, labels: ["custom"])
        #expect(pool.resolvedLabels() == ["custom"])
    }

    @Test("clean schema round-trips: provider is a self-contained object, github at profile level")
    func cleanSchemaRoundTrip() throws {
        let cfg = GraftConfig(
            provider: .orchard(OrchardConfig(controllerURL: URL(string: "http://127.0.0.1:6120")!,
                                             serviceAccount: "graft", maxVMs: 8)),
            github: GitHubConfig(appId: 7, target: "repo:o/r"),
            pools: [PoolConfig(name: "mac", image: "g1", os: .macOS, count: 2,
                               labels: ["self-hosted", "macos", "mac"], cpu: 4, memory: 8192)],
            secrets: SecretsConfig(store: "keychain", scope: "login")
        )
        let json = String(decoding: try GraftConfig.encoder.encode(cfg), as: UTF8.self)
        #expect(json.contains("\"type\" : \"orchard\""))   // discriminator
        #expect(json.contains("\"controllerURL\""))         // orchard fields inline in provider
        #expect(!json.contains("\"orchard\" :"))            // NOT a top-level block

        let back = try JSONDecoder().decode(GraftConfig.self, from: Data(json.utf8))
        #expect(back.orchard?.serviceAccount == "graft")
        #expect(back.github?.appId == 7)
        #expect(back.pools.first?.memory == 8192)
        #expect(back.gitHub(for: back.pools[0])?.target == "repo:o/r")   // pool inherits profile github
    }

    @Test("target parsing: org and repo")
    func targetParsing() throws {
        #expect(try GitHubTarget(parsing: "org:acme") == .org("acme"))
        #expect(try GitHubTarget(parsing: "repo:acme/widgets") == .repo(owner: "acme", name: "widgets"))
        #expect(try GitHubTarget(parsing: "org:acme").apiPath == "orgs/acme")
        #expect(try GitHubTarget(parsing: "repo:acme/widgets").apiPath == "repos/acme/widgets")
    }

    @Test("target parsing rejects malformed strings")
    func targetParsingRejects() {
        #expect(throws: GraftError.self) { _ = try GitHubTarget(parsing: "acme") }
        #expect(throws: GraftError.self) { _ = try GitHubTarget(parsing: "repo:acme") }
        #expect(throws: GraftError.self) { _ = try GitHubTarget(parsing: "team:acme") }
    }

    @Test("validation flags duplicate pools and bad targets")
    func validation() {
        let cfg = GraftConfig(pools: [
            PoolConfig(name: "dup", image: "i", os: .macOS, count: 1,
                       github: GitHubConfig(appId: 1, target: "org:acme")),
            PoolConfig(name: "dup", image: "", os: .macOS, count: 1,
                       github: GitHubConfig(appId: 1, target: "nonsense")),
        ])
        let problems = cfg.validate()
        #expect(problems.contains { $0.contains("duplicate pool name") })
        #expect(problems.contains { $0.contains("image is empty") })
    }

    @Test("a valid single-pool config has no problems")
    func validConfig() {
        let cfg = GraftConfig(pools: [
            PoolConfig(name: "p", image: "img:latest", os: .macOS, count: 2,
                       github: GitHubConfig(appId: 1, target: "org:acme")),
        ])
        #expect(cfg.validate().isEmpty)
    }
}
