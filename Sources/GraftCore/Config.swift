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
public struct GitHubConfig: Codable, Sendable {
    public var appId: Int
    public var target: String
    /// Required for org JIT runners; defaults to the default group (1).
    public var runnerGroupId: Int
    /// Baked into the JIT config at generation time (immutable after). When nil,
    /// `PoolConfig.resolvedLabels()` computes `["self-hosted", os, poolName]`.
    public var labels: [String]?

    enum CodingKeys: String, CodingKey {
        case appId, target, runnerGroupId, labels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appId = try c.decode(Int.self, forKey: .appId)
        target = try c.decode(String.self, forKey: .target)
        runnerGroupId = try c.decodeIfPresent(Int.self, forKey: .runnerGroupId) ?? 1
        labels = try c.decodeIfPresent([String].self, forKey: .labels)
    }

    public init(appId: Int, target: String, runnerGroupId: Int = 1, labels: [String]? = nil) {
        self.appId = appId
        self.target = target
        self.runnerGroupId = runnerGroupId
        self.labels = labels
    }

    public func parsedTarget() throws -> GitHubTarget { try GitHubTarget(parsing: target) }
}

/// One pool of identical runners.
public struct PoolConfig: Codable, Sendable {
    public var name: String
    public var image: String
    public var os: GuestOS
    public var count: Int
    public var github: GitHubConfig
    /// Host directory shares mounted into each runner VM (e.g. read-only warm caches).
    /// Absent (nil) → no mounts. See docs/images-and-caching.md for the strategy.
    public var mounts: [Mount]?
    /// VM networking mode for this pool's runners. Absent (nil) → shared NAT. Set
    /// `bridged:<iface>` on hosts where NAT is blocked (e.g. behind Zscaler).
    public var network: VMNetwork?

    public init(name: String, image: String, os: GuestOS, count: Int, github: GitHubConfig, mounts: [Mount]? = nil, network: VMNetwork? = nil) {
        self.name = name
        self.image = image
        self.os = os
        self.count = count
        self.github = github
        self.mounts = mounts
        self.network = network
    }

    /// Labels for runners in this pool — explicit config or the computed default.
    public func resolvedLabels() -> [String] {
        github.labels ?? ["self-hosted", os.rawValue, name]
    }
}

/// Multi-host backend settings — the Orchard controller graft schedules VMs onto.
public struct OrchardConfig: Codable, Sendable {
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
    public var provider: String
    public var pools: [PoolConfig]
    public var orchard: OrchardConfig?
    public var secrets: SecretsConfig?

    public init(
        provider: String = "tart",
        pools: [PoolConfig] = [],
        orchard: OrchardConfig? = nil,
        secrets: SecretsConfig? = nil
    ) {
        self.provider = provider
        self.pools = pools
        self.orchard = orchard
        self.secrets = secrets
    }
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

            do {
                let target = try pool.github.parsedTarget()
                if target.isOrg && pool.github.runnerGroupId < 1 {
                    problems.append("\(tag): runnerGroupId must be >= 1 for org targets")
                }
            } catch {
                problems.append("\(tag): \(error)")
            }
        }

        switch provider {
        case "tart":
            break
        case "orchard":
            if let orchard {
                if orchard.serviceAccount.isEmpty { problems.append("orchard: serviceAccount is empty") }
                // token is intentionally not required here — it may be Keychain-backed
                // (resolved at run time) or unused by an unsecured local `orchard dev`.
            } else {
                problems.append("provider is 'orchard' but no orchard config provided")
            }
        default:
            problems.append("unknown provider '\(provider)' — expected 'tart' or 'orchard'")
        }
        return problems
    }

    /// A starter config for `graft config template`.
    public static func template() -> String {
        """
        {
          "provider": "tart",
          "pools": [
            {
              "name": "macos-release",
              "image": "ghcr.io/cirruslabs/macos-tahoe-xcode:latest",
              "os": "macos",
              "count": 2,
              "github": {
                "appId": 12345,
                "target": "org:my-org",
                "runnerGroupId": 1,
                "labels": ["self-hosted", "macos", "graft"]
              }
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
