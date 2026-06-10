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

    /// Generate a single-use JIT runner config for `pool`. The returned blob goes
    /// straight to `./run.sh --jitconfig <blob>` on the VM — no `config.sh`, and the
    /// runner is ephemeral by construction.
    public func generateJITConfig(pool: PoolConfig, runnerName: String) async throws -> String {
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
        struct Response: Decodable { let encodedJITConfig: String
            enum CodingKeys: String, CodingKey { case encodedJITConfig = "encoded_jit_config" }
        }
        return try JSONDecoder().decode(Response.self, from: data).encodedJITConfig
    }

    // MARK: Auth chain

    /// Discover the installation for `target` and exchange the App JWT for a
    /// short-lived installation access token.
    func installationAccessToken(for target: GitHubTarget) async throws -> String {
        let jwt = try await appJWT()

        struct Installation: Decodable { let id: Int }
        let installationData = try await request("GET", path: "\(target.apiPath)/installation", bearer: jwt)
        let installation = try JSONDecoder().decode(Installation.self, from: installationData)

        struct TokenResponse: Decodable { let token: String }
        let tokenData = try await request(
            "POST",
            path: "app/installations/\(installation.id)/access_tokens",
            bearer: jwt,
            json: [:]
        )
        return try JSONDecoder().decode(TokenResponse.self, from: tokenData).token
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
        var req = URLRequest(url: apiBase.appendingPathComponent(path))
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
