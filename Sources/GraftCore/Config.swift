import Foundation

/// Where a runner registers. Parsed from the `target` string in pool config.
public enum GitHubTarget: Sendable, Equatable, CustomStringConvertible {
    case org(String)
    case repo(owner: String, name: String)

    public init(parsing raw: String) throws {
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw GraftError("invalid target '\(raw)' — expected 'org:NAME' or 'repo:OWNER/NAME'")
        }
        switch parts[0] {
        case "org":
            guard !parts[1].isEmpty else { throw GraftError("invalid target '\(raw)' — org name is empty") }
            self = .org(parts[1])
        case "repo":
            let rp = parts[1].split(separator: "/", maxSplits: 1).map(String.init)
            guard rp.count == 2, !rp[0].isEmpty, !rp[1].isEmpty else {
                throw GraftError("invalid target '\(raw)' — expected 'repo:OWNER/NAME'")
            }
            self = .repo(owner: rp[0], name: rp[1])
        default:
            throw GraftError("invalid target '\(raw)' — unknown kind '\(parts[0])'")
        }
    }

    public var description: String {
        switch self {
        case .org(let o): return "org:\(o)"
        case .repo(let owner, let name): return "repo:\(owner)/\(name)"
        }
    }

    /// REST path segment for the GitHub API (`orgs/{org}` or `repos/{owner}/{name}`).
    public var apiPath: String {
        switch self {
        case .org(let o): return "orgs/\(o)"
        case .repo(let owner, let name): return "repos/\(owner)/\(name)"
        }
    }

    public var isOrg: Bool { if case .org = self { return true }; return false }
}

/// GitHub App + JIT-runner settings for a pool. Note there is no private-key path:
/// the App's PEM is resolved from the Keychain by `appId`, never stored on disk.
public struct GitHubConfig: Codable, Sendable, Equatable {
    public var appId: Int
    public var target: String
    /// Required for org JIT runners; defaults to the default group (1).
    public var runnerGroupId: Int

    enum CodingKeys: String, CodingKey {
        case appId, target, runnerGroupId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appId = try c.decode(Int.self, forKey: .appId)
        target = try c.decode(String.self, forKey: .target)
        runnerGroupId = try c.decodeIfPresent(Int.self, forKey: .runnerGroupId) ?? 1
    }

    public init(appId: Int, target: String, runnerGroupId: Int = 1) {
        self.appId = appId
        self.target = target
        self.runnerGroupId = runnerGroupId
    }

    public func parsedTarget() throws -> GitHubTarget { try GitHubTarget(parsing: target) }
}

/// One pool of identical runners.
public struct PoolConfig: Codable, Sendable {
    public var name: String
    public var image: String
    public var os: GuestOS
    public var count: Int
    /// Per-pool GitHub override (App + target). Absent → inherit the profile's `github`.
    /// Lets one profile span repos/orgs; normally nil.
    public var github: GitHubConfig?
    /// Runner labels (tags) — how a workflow's `runs-on:` targets this pool. Absent →
    /// `["self-hosted", <os>, <name>]`. Baked into the JIT config (immutable per runner).
    public var labels: [String]?
    /// Host directory shares mounted into each runner VM (e.g. read-only warm caches).
    /// Absent (nil) → no mounts. See docs/images-and-caching.md for the strategy.
    public var mounts: [Mount]?
    /// VM networking mode for this pool's runners. Absent (nil) → shared NAT. Set
    /// `bridged:<iface>` on hosts where NAT is blocked (e.g. behind Zscaler).
    public var network: VMNetwork?
    /// Per-pool VM sizing for this pool's workload — independent of the image (a lint
    /// pool is small, an e2e pool is fat, same toolchain image). Absent → backend
    /// default. On Orchard, `memory` is also requested from the scheduler so a branch
    /// isn't over-packed. See [[VMResources]].
    public var cpu: Int?
    public var memory: Int?   // megabytes

    public init(name: String, image: String, os: GuestOS, count: Int, github: GitHubConfig? = nil, labels: [String]? = nil, mounts: [Mount]? = nil, network: VMNetwork? = nil, cpu: Int? = nil, memory: Int? = nil) {
        self.name = name
        self.image = image
        self.os = os
        self.count = count
        self.github = github
        self.labels = labels
        self.mounts = mounts
        self.network = network
        self.cpu = cpu
        self.memory = memory
    }

    /// Labels for runners in this pool — explicit config or the computed default.
    public func resolvedLabels() -> [String] {
        labels ?? ["self-hosted", os.rawValue, name]
    }

    /// This pool's per-leaf sizing as a `VMResources`.
    public var resources: VMResources { VMResources(cpu: cpu, memory: memory) }
}

/// Multi-host backend settings — the Orchard controller graft schedules VMs onto.
public struct OrchardConfig: Codable, Sendable, Equatable {
    /// Controller address, e.g. `https://orchard.example.com:6120`.
    public var controllerURL: URL
    /// Service account the controller authenticates graft as (needs VM compute rights).
    public var serviceAccount: String
    /// Service-account token. Optional: when nil it's resolved from the Keychain
    /// (`graft init` stores it there, keyed by `serviceAccount`), so it never
    /// has to sit in plaintext config. An unsecured local `orchard dev` controller
    /// ignores it entirely. See `Run.makeProvider` for the resolution order.
    public var token: String?
    /// Cluster-wide ceiling graft fills toward. The controller does the real scheduling
    /// (incl. Apple's per-host 2-macOS-VM limit); this only bounds graft's ask. Default 100.
    public var maxVMs: Int?

    public init(controllerURL: URL, serviceAccount: String, token: String? = nil, maxVMs: Int? = nil) {
        self.controllerURL = controllerURL
        self.serviceAccount = serviceAccount
        self.token = token
        self.maxVMs = maxVMs
    }
}

/// The VM backend, self-contained: a discriminator (`type`) plus that backend's own
/// settings, inline. Encodes/decodes as e.g. `{ "type": "tart" }` or
/// `{ "type": "orchard", "controllerURL": …, "serviceAccount": …, "maxVMs": … }` — so
/// there's no separate top-level `orchard` block disconnected from the choice.
public enum ProviderConfig: Sendable, Equatable {
    case tart
    case orchard(OrchardConfig)

    public var typeName: String {
        switch self { case .tart: return "tart"; case .orchard: return "orchard" }
    }
    public var orchard: OrchardConfig? {
        if case .orchard(let o) = self { return o }; return nil
    }
}

extension ProviderConfig: Codable {
    private enum Keys: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "tart":    self = .tart
        case "orchard": self = .orchard(try OrchardConfig(from: decoder))   // fields inline
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                debugDescription: "unknown provider type '\(other)' — expected 'tart' or 'orchard'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(typeName, forKey: .type)
        if case .orchard(let o) = self { try o.encode(to: encoder) }   // flatten fields alongside `type`
    }
}

/// Health-monitoring settings for `graft arborist --watch`. Absent → built-in defaults
/// (observe-only, no webhooks). Detection-first: nothing here remediates — these tune
/// what the monitor *watches* and where it *reports*, never what it would change.
public struct MonitorConfig: Codable, Sendable, Equatable {
    /// Seconds between detector sweeps. Default 60.
    public var intervalSeconds: Int
    /// Webhook URLs each event is POSTed to (vendor-neutral JSON). Default none — a
    /// Slack/PagerDuty/Sentry receiver is a thin reformatter in front of one of these.
    public var webhooks: [URL]
    /// Emit an info heartbeat at most this often even when healthy, so a quiet monitor
    /// is distinguishable from a dead one. Default 300; 0 disables.
    public var heartbeatSeconds: Int
    /// A slot wedged in a transient phase longer than this is flagged. Default 300.
    public var slotStuckTimeoutSeconds: Int
    /// Only POST events at/above this severity to webhooks (`info`|`warn`|`critical`);
    /// recoveries always go. Default `warn`.
    public var webhookMinSeverity: String

    enum CodingKeys: String, CodingKey {
        case intervalSeconds, webhooks, heartbeatSeconds, slotStuckTimeoutSeconds, webhookMinSeverity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        intervalSeconds = try c.decodeIfPresent(Int.self, forKey: .intervalSeconds) ?? 60
        webhooks = try c.decodeIfPresent([URL].self, forKey: .webhooks) ?? []
        heartbeatSeconds = try c.decodeIfPresent(Int.self, forKey: .heartbeatSeconds) ?? 300
        slotStuckTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .slotStuckTimeoutSeconds) ?? 300
        webhookMinSeverity = try c.decodeIfPresent(String.self, forKey: .webhookMinSeverity) ?? "warn"
    }

    public init(
        intervalSeconds: Int = 60, webhooks: [URL] = [], heartbeatSeconds: Int = 300,
        slotStuckTimeoutSeconds: Int = 300, webhookMinSeverity: String = "warn"
    ) {
        self.intervalSeconds = intervalSeconds
        self.webhooks = webhooks
        self.heartbeatSeconds = heartbeatSeconds
        self.slotStuckTimeoutSeconds = slotStuckTimeoutSeconds
        self.webhookMinSeverity = webhookMinSeverity
    }

    public var resolvedWebhookMinSeverity: HealthEvent.Severity {
        HealthEvent.Severity(rawValue: webhookMinSeverity) ?? .warn
    }
}

/// Where the GitHub App PEM lives. Keychain only — `scope` picks login (interactive
/// `graft run`) vs. system (`--daemon`, headless, root-accessible).
public struct SecretsConfig: Codable, Sendable {
    public var store: String
    public var scope: String?

    public init(store: String = "keychain", scope: String? = nil) {
        self.store = store
        self.scope = scope
    }
}

/// Top-level Graft configuration. Loaded from JSON; path resolved from
/// `--config`, then `$GRAFT_CONFIG`, then `~/.graft/config.json`.
public struct GraftConfig: Codable, Sendable {
    /// The VM backend + its settings (self-contained — see `ProviderConfig`).
    public var provider: ProviderConfig
    /// Default GitHub App + target for every pool. A pool may override via its own
    /// `github` (e.g. a profile that spans repos), but normally this is declared once.
    public var github: GitHubConfig?
    public var pools: [PoolConfig]
    public var secrets: SecretsConfig?
    /// Health-monitoring settings for `graft arborist --watch`. Absent → defaults
    /// (observe-only, no webhooks). Optional, so existing configs load unchanged.
    public var monitor: MonitorConfig?

    public init(
        provider: ProviderConfig = .tart,
        github: GitHubConfig? = nil,
        pools: [PoolConfig] = [],
        secrets: SecretsConfig? = nil,
        monitor: MonitorConfig? = nil
    ) {
        self.provider = provider
        self.github = github
        self.pools = pools
        self.secrets = secrets
        self.monitor = monitor
    }

    /// Orchard settings, if this profile's backend is Orchard.
    public var orchard: OrchardConfig? { provider.orchard }

    /// The effective GitHub config for a pool: its own override, else the profile default.
    public func gitHub(for pool: PoolConfig) -> GitHubConfig? { pool.github ?? github }
}

extension GraftConfig {
    public static var defaultPath: String {
        (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
            .appendingPathComponent(".graft/config.json")
    }

    /// Resolution order: explicit `--config` → `$GRAFT_CONFIG` → `--profile` →
    /// the active profile → `~/.graft/config.json`.
    public static func resolvePath(explicit: String? = nil, profile: String? = nil) -> String {
        if let explicit { return explicit }
        if let env = ProcessInfo.processInfo.environment["GRAFT_CONFIG"], !env.isEmpty { return env }
        if let profile { return Profiles.path(for: profile) }
        if let active = Profiles.activeName() { return Profiles.path(for: active) }
        return defaultPath
    }

    /// Shared pretty/sorted encoder for writing configs and profiles.
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public func jsonString() throws -> String {
        String(decoding: try Self.encoder.encode(self), as: UTF8.self)
    }

    public static func load(from path: String) throws -> GraftConfig {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw GraftError("no config file at \(expanded)")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: expanded))
        do {
            return try JSONDecoder().decode(GraftConfig.self, from: data)
        } catch let error as DecodingError {
            throw GraftError("invalid config at \(expanded): \(error.readableDescription)")
        }
    }

    /// Structural validation. Returns a list of problems (empty == valid).
    /// Does not check Keychain resolvability — that lives in `graft config validate`
    /// where a `SecretStore` is available.
    public func validate() -> [String] {
        var problems: [String] = []
        if pools.isEmpty { problems.append("no pools defined") }

        var seenNames = Set<String>()
        for pool in pools {
            let tag = "pool '\(pool.name)'"
            if !seenNames.insert(pool.name).inserted {
                problems.append("duplicate pool name '\(pool.name)'")
            }
            if pool.name.isEmpty { problems.append("a pool has an empty name") }
            if pool.image.isEmpty { problems.append("\(tag): image is empty") }
            if pool.count < 0 { problems.append("\(tag): count must be >= 0") }

            // Each pool needs a GitHub config — its own override or the profile default.
            if let gh = gitHub(for: pool) {
                do {
                    let target = try gh.parsedTarget()
                    if target.isOrg && gh.runnerGroupId < 1 {
                        problems.append("\(tag): runnerGroupId must be >= 1 for org targets")
                    }
                } catch {
                    problems.append("\(tag): \(error)")
                }
            } else {
                problems.append("\(tag): no GitHub config — set a top-level `github` or a pool override")
            }
        }

        switch provider {
        case .tart:
            break
        case .orchard(let orchard):
            if orchard.serviceAccount.isEmpty { problems.append("orchard: serviceAccount is empty") }
            // token is intentionally not required here — it may be Keychain-backed
            // (resolved at run time) or unused by an unsecured local trunk.
        }
        return problems
    }

    /// A starter config for `graft config template`.
    public static func template() -> String {
        """
        {
          "provider": { "type": "tart" },
          "github": { "appId": 12345, "target": "org:my-org" },
          "pools": [
            {
              "name": "macos-release",
              "image": "ghcr.io/cirruslabs/macos-tahoe-xcode:latest",
              "os": "macos",
              "count": 2,
              "labels": ["self-hosted", "macos", "release"]
            }
          ],
          "secrets": { "store": "keychain", "scope": "login" }
        }
        """
    }
}

extension DecodingError {
    /// A one-line, user-readable summary instead of the default multi-line dump.
    var readableDescription: String {
        switch self {
        case .keyNotFound(let key, let ctx):
            return "missing key '\(key.stringValue)' at \(ctx.codingPath.dotPath)"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
            return "\(ctx.debugDescription) at \(ctx.codingPath.dotPath)"
        case .dataCorrupted(let ctx):
            return ctx.debugDescription
        @unknown default:
            return localizedDescription
        }
    }
}

private extension Array where Element == CodingKey {
    var dotPath: String { isEmpty ? "<root>" : map(\.stringValue).joined(separator: ".") }
}
