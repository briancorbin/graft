import Foundation

/// Validates a GitHub App private key without touching the network — parses it and
/// signs a probe JWT. Used by `graft secrets import` to fail early on a bad PEM.
public enum PrivateKeyValidator {
    public static func validate(pem: String) throws {
        _ = try AppJWT.sign(appID: 0, pem: pem)
    }
}

/// Talks to the GitHub REST API as a GitHub App. The auth chain:
/// App JWT (RS256) → installation access token → JIT runner config. The PEM is
/// pulled from a `SecretStore` (Keychain) on demand — never held on disk.
public struct GitHubAppClient: Sendable {
    public let appID: Int
    private let secrets: any SecretStore
    private let apiBase: URL

    public init(
        appID: Int,
        secrets: any SecretStore,
        apiBase: URL = URL(string: "https://api.github.com")!
    ) {
        self.appID = appID
        self.secrets = secrets
        self.apiBase = apiBase
    }

    /// A freshly-minted JIT runner: its server-side id (for cleanup) and the encoded
    /// config blob for `./run.sh --jitconfig`.
    public struct JITRunner: Sendable {
        public let runnerID: Int
        public let encodedConfig: String
    }

    /// Create a single-use JIT runner for `pool`. Generating the config registers a
    /// runner entity on GitHub (id returned for cleanup); the blob is ephemeral by
    /// construction — `./run.sh --jitconfig <blob>`, no `config.sh`.
    public func generateJITRunner(pool: PoolConfig, runnerName: String) async throws -> JITRunner {
        let target = try pool.github.parsedTarget()
        let token = try await installationAccessToken(for: target)
        let body: [String: Any] = [
            "name": runnerName,
            "runner_group_id": pool.github.runnerGroupId,
            "labels": pool.resolvedLabels(),
            "work_folder": "_work",
        ]
        let data = try await request(
            "POST",
            path: "\(target.apiPath)/actions/runners/generate-jitconfig",
            bearer: token,
            json: body
        )
        struct Response: Decodable {
            struct Runner: Decodable { let id: Int }
            let runner: Runner
            let encodedJITConfig: String
            enum CodingKeys: String, CodingKey {
                case runner
                case encodedJITConfig = "encoded_jit_config"
            }
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return JITRunner(runnerID: decoded.runner.id, encodedConfig: decoded.encodedJITConfig)
    }

    /// Just the JIT blob — the supervisor's hot path.
    public func generateJITConfig(pool: PoolConfig, runnerName: String) async throws -> String {
        try await generateJITRunner(pool: pool, runnerName: runnerName).encodedConfig
    }

    /// Remove a runner by id (cleanup for offline/probe runners). A runner GitHub has
    /// already auto-removed (a completed ephemeral job) yields a 404 — callers that
    /// just want it gone can ignore that.
    public func deleteRunner(id: Int, target: GitHubTarget) async throws {
        let token = try await installationAccessToken(for: target)
        _ = try await request("DELETE", path: "\(target.apiPath)/actions/runners/\(id)", bearer: token)
    }

    /// One self-hosted runner as GitHub reports it.
    public struct Runner: Sendable, Decodable {
        public let id: Int
        public let name: String
        public let status: String   // "online" | "offline"
        public var isOffline: Bool { status.lowercased() == "offline" }
    }

    /// Runners registered on `target` (first 100 — graft husks rarely exceed that).
    /// Backs `graft runners list/prune`.
    public func listRunners(target: GitHubTarget) async throws -> [Runner] {
        let token = try await installationAccessToken(for: target)
        let data = try await request(
            "GET",
            path: "\(target.apiPath)/actions/runners?per_page=100",
            bearer: token
        )
        struct Response: Decodable { let runners: [Runner] }
        return try Self.snakeDecoder.decode(Response.self, from: data).runners
    }

    /// Targets this App can actually reach: `org:<login>` for every org the App is
    /// installed on, plus `repo:<owner>/<name>` for every accessible repo. Powers the
    /// setup wizard's target picker so you select a valid target instead of retyping.
    public func accessibleTargets() async throws -> [String] {
        let jwt = try await appJWT()
        struct Installation: Decodable {
            let id: Int
            let account: Account
            struct Account: Decodable { let login: String; let type: String }
        }
        let instData = try await request("GET", path: "app/installations", bearer: jwt)
        let installations = try Self.snakeDecoder.decode([Installation].self, from: instData)

        var targets: [String] = []
        for inst in installations {
            if inst.account.type == "Organization" {
                targets.append("org:\(inst.account.login)")
            }
            // Repos need an installation token (the App JWT can't read them directly).
            guard let token = try? await installationToken(installationID: inst.id),
                  let repoData = try? await request("GET", path: "installation/repositories", bearer: token)
            else { continue }
            struct Repos: Decodable {
                let repositories: [Repo]
                struct Repo: Decodable { let fullName: String }
            }
            let repos = (try? Self.snakeDecoder.decode(Repos.self, from: repoData))?.repositories ?? []
            targets.append(contentsOf: repos.map { "repo:\($0.fullName)" })
        }
        return targets
    }

    /// Mint an installation token straight from an installation id (the
    /// `accessibleTargets` path already has the id, so it skips target→id lookup).
    private func installationToken(installationID: Int) async throws -> String {
        let jwt = try await appJWT()
        struct TokenResponse: Decodable { let token: String }
        let data = try await request(
            "POST",
            path: "app/installations/\(installationID)/access_tokens",
            bearer: jwt,
            json: [:]
        )
        return try JSONDecoder().decode(TokenResponse.self, from: data).token
    }

    private static let snakeDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    // MARK: Auth chain (each step public so `graft arborist` can report it)

    /// Read the PEM from the secret store and sign the App JWT.
    public func makeAppJWT() async throws -> String {
        try await appJWT()
    }

    /// Discover the App's installation id for `target`.
    public func installationID(for target: GitHubTarget) async throws -> Int {
        let jwt = try await appJWT()
        struct Installation: Decodable { let id: Int }
        let data = try await request("GET", path: "\(target.apiPath)/installation", bearer: jwt)
        return try JSONDecoder().decode(Installation.self, from: data).id
    }

    /// Exchange the App JWT for a short-lived installation access token.
    public func installationAccessToken(for target: GitHubTarget) async throws -> String {
        let installationID = try await installationID(for: target)
        let jwt = try await appJWT()
        struct TokenResponse: Decodable { let token: String }
        let data = try await request(
            "POST",
            path: "app/installations/\(installationID)/access_tokens",
            bearer: jwt,
            json: [:]
        )
        return try JSONDecoder().decode(TokenResponse.self, from: data).token
    }

    private func appJWT() async throws -> String {
        let pem = try await secrets.privateKeyPEM(forAppID: appID)
        return try AppJWT.sign(appID: appID, pem: pem)
    }

    // MARK: HTTP

    private func request(
        _ method: String,
        path: String,
        bearer: String,
        json: [String: Any]? = nil
    ) async throws -> Data {
        // String-join rather than appendingPathComponent so a `?query` survives
        // (appendingPathComponent percent-encodes the `?`). Paths are API-internal
        // and contain no characters needing escaping.
        guard let url = URL(string: apiBase.absoluteString + "/" + path) else {
            throw GraftError("bad request path: \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("graft", forHTTPHeaderField: "User-Agent")
        if let json, !json.isEmpty {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GraftError("no HTTP response for \(method) \(path)")
        }
        guard (200..<300).contains(http.statusCode) else {
            let apiMessage = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw GraftError("GitHub API \(http.statusCode) for \(method) /\(path)" + (apiMessage.map { ": \($0)" } ?? ""))
        }
        return data
    }
}
