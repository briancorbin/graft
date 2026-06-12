import Foundation
import GraftCore

/// Tiny stdin/stderr prompt helpers for interactive commands. Questions go to
/// stderr so stdout stays clean; answers are read from stdin. The `?`/`›` styling
/// matches the arrow-key `Select` so every prompt reads as one family.
enum Prompt {
    static func line(_ question: String, default fallback: String? = nil) -> String {
        let hint = fallback.map { " " + ANSI.dim("[\($0)]") } ?? ""
        FileHandle.standardError.write(Data("\(ANSI.green("?")) \(question)\(hint) \(ANSI.dim("›")) ".utf8))
        let input = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        if input.isEmpty, let fallback { return fallback }
        return input
    }

    static func required(_ question: String) -> String {
        while true {
            let value = line(question)
            if !value.isEmpty { return value }
            printErr(ANSI.dim("  (required)"))
        }
    }

    static func int(_ question: String, default fallback: Int) -> Int {
        while true {
            let value = line(question, default: String(fallback))
            if let number = Int(value) { return number }
            printErr(ANSI.dim("  (enter a number)"))
        }
    }

    static func positiveInt(_ question: String) -> Int {
        while true {
            let value = line(question)
            if let number = Int(value), number > 0 { return number }
            printErr(ANSI.dim("  (enter a positive number)"))
        }
    }

    static func confirm(_ question: String, default fallback: Bool = true) -> Bool {
        let hint = fallback ? "Y/n" : "y/N"
        let value = line("\(question) \(ANSI.dim("(\(hint))"))").lowercased()
        if value.isEmpty { return fallback }
        return value.hasPrefix("y")
    }

    /// Present a selectable menu (arrow-key `Select` on a TTY, numbered fallback when
    /// piped), return the chosen index. Non-cancellable: callers expect an answer.
    static func choose(_ question: String, _ options: [String]) -> Int {
        Select.choose(question, options, cancellable: false) ?? 0
    }
}

/// Resolve a GitHub App ID interactively (pick from keys already in the keychain or
/// enter a new one), then run the secrets step: ensure that App has a private key —
/// importing one if it's missing, or offering to rotate it if it's already there.
enum AppPicker {
    static func resolve(scope: KeychainScope) throws -> Int {
        let store = KeychainSecretStore(scope: scope)
        let existing = (try? store.storedAppIDs()) ?? []   // attribute read — no Keychain prompt

        let appID: Int
        if existing.isEmpty {
            printErr("(no GitHub App keys in the \(scope.rawValue) keychain yet)")
            appID = Prompt.positiveInt("GitHub App ID")
        } else {
            var options = existing.map { "app \($0)" }
            options.append("enter a different App ID…")
            let choice = Prompt.choose("Which GitHub App?", options)
            appID = choice < existing.count ? existing[choice] : Prompt.positiveInt("GitHub App ID")
        }

        try ensureKey(appID: appID, store: store, scope: scope)
        return appID
    }

    /// The wizard's secrets step. Always runs, so key import is a visible part of
    /// setup rather than a hidden branch: import if missing, offer rotate if present.
    private static func ensureKey(appID: Int, store: KeychainSecretStore, scope: KeychainScope) throws {
        let hasKey = ((try? store.storedAppIDs()) ?? []).contains(appID)
        if hasKey {
            printErr("✓ private key already stored for app \(appID) (\(scope.rawValue) keychain)")
            guard Prompt.confirm("Import a new .pem for app \(appID) (rotate the key)?", default: false) else { return }
        } else {
            printErr("No private key stored for app \(appID) yet.")
            guard Prompt.confirm("Import its .pem now?", default: true) else {
                printErr("  ⚠ skipped — `graft run` will fail until you import it:")
                let flag = scope == .system ? " --system" : ""
                printErr("    graft secrets import --app-id \(appID) --pem <path>\(flag)")
                return
            }
        }
        try importPEM(appID: appID, store: store, scope: scope)
    }

    private static func importPEM(appID: Int, store: KeychainSecretStore, scope: KeychainScope) throws {
        let path = (Prompt.required("Path to the App private-key .pem") as NSString).expandingTildeInPath
        guard let pem = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw GraftError("can't read PEM at \(path)")
        }
        try PrivateKeyValidator.validate(pem: pem)
        try store.store(pem: pem, forAppID: appID)
        printErr("✓ stored key for app \(appID) in the \(scope.rawValue) keychain")
        printErr("  shred the file:  rm -P \(path)")
    }
}

/// Pick a GitHub target (`org:NAME` / `repo:OWNER/NAME`) from what the App can
/// actually reach — its installations' orgs and repos — merged with targets already
/// configured locally, so you select instead of retyping. Falls back to free text.
enum TargetPicker {
    static func resolve(appID: Int, scope: KeychainScope) async -> String {
        let prompt = "Target (org:NAME or repo:OWNER/NAME)"
        var known = knownFromConfig()

        // Best-effort, time-bounded: ask GitHub what this App can reach. Network or
        // key-read failures just fall through to config-known + free text.
        let client = GitHubAppClient(appID: appID, secrets: KeychainSecretStore(scope: scope))
        if let fromAPI = try? await withTimeout(seconds: 6, { try await client.accessibleTargets() }) {
            known = dedupe(fromAPI + known)
        } else if known.isEmpty {
            printErr("(couldn't reach GitHub for the target list — type it below)")
        }

        guard !known.isEmpty else { return Prompt.required(prompt) }
        var options = known
        options.append("enter a custom target…")
        let choice = Prompt.choose("Which target?", options)
        return choice < known.count ? known[choice] : Prompt.required(prompt)
    }

    /// Distinct targets already used by any pool in any local profile.
    private static func knownFromConfig() -> [String] {
        var out: [String] = []
        for name in Profiles.names() {
            guard let cfg = try? Profiles.load(name) else { continue }
            out.append(contentsOf: cfg.pools.map { $0.github.target })
        }
        return dedupe(out)
    }

    private static func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}

/// The `graft dev` entry picker: resume a persistent box, clone a repo (from the repos the
/// GitHub App can reach), mount the current directory (ephemeral), or a scratch box.
enum DevBoxPicker {
    enum Choice {
        case resume(String)                 // existing persistent dev box
        case clone(url: String, name: String)
        case mount                          // mount $PWD, ephemeral
        case scratch                        // empty ephemeral box
        case cancelled
    }

    static func resolve(profile: String?) async -> Choice {
        let boxes = ((try? await Tart.list()) ?? [])
            .filter { $0.name.hasPrefix("graft-dev-") && !$0.name.hasPrefix("graft-dev-eph-") }
            .sorted { $0.name < $1.name }

        var options = boxes.map { "resume \($0.name.replacingOccurrences(of: "graft-dev-", with: ""))  (\($0.state))" }
        let cloneIndex = options.count;   options.append("clone a repo…")
        let mountIndex = options.count;   options.append("mount this directory (ephemeral)")
        let scratchIndex = options.count; options.append("scratch box (ephemeral)")

        let choice = Prompt.choose("Dev box?", options)
        if choice < boxes.count { return .resume(boxes[choice].name) }
        switch choice {
        case cloneIndex:
            guard let spec = await pickRepo(profile: profile) else { return .cancelled }
            let (url, name) = DevCode.expandRepoSpec(spec)
            return .clone(url: url, name: name)
        case mountIndex: return .mount
        case scratchIndex: return .scratch
        default: return .cancelled
        }
    }

    /// Ask how to connect (shell is the default everyone has; VS Code is opt-in).
    static func askConnect() -> Bool {   // returns true for VS Code
        Prompt.choose("Open with?", ["shell", "VS Code (Remote-SSH)"]) == 1
    }

    /// Pick a repo from the GitHub App's accessible repos (best-effort), or type one.
    static func pickRepo(profile: String?) async -> String? {
        var repos: [String] = []
        if let (appID, scope) = appCredentials(profile: profile) {
            let client = GitHubAppClient(appID: appID, secrets: KeychainSecretStore(scope: scope))
            if let targets = try? await withTimeout(seconds: 6, { try await client.accessibleTargets() }) {
                repos = targets.filter { $0.hasPrefix("repo:") }.map { String($0.dropFirst(5)) }.sorted()
            }
        }
        guard !repos.isEmpty else {
            let typed = Prompt.line("Repo (owner/name or git URL)")
            return typed.isEmpty ? nil : typed
        }
        var options = repos
        options.append("enter a custom repo…")
        let choice = Prompt.choose("Which repo?", options)
        if choice < repos.count { return repos[choice] }
        let typed = Prompt.line("Repo (owner/name or git URL)")
        return typed.isEmpty ? nil : typed
    }

    /// The active (or named) profile's App id + keychain scope, for the repo list.
    private static func appCredentials(profile: String?) -> (Int, KeychainScope)? {
        guard let name = try? resolveProfileName(profile),
              let cfg = try? Profiles.load(name),
              let appID = cfg.pools.first?.github.appId else { return nil }
        let scope = KeychainScope(rawValue: cfg.secrets?.scope ?? "login") ?? .login
        return (appID, scope)
    }
}

/// Run `operation`, but give up after `seconds` (e.g. a wizard network call that
/// shouldn't hang the prompt on a bad connection). Cancels the operation on timeout.
func withTimeout<T: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw GraftError("timed out after \(seconds)s")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// Pick a Tart image for a pool: choose from what's already on the machine
/// (local clones + pulled OCI images via `tart list`), or type any registry ref.
/// No baked-in default — the menu reflects reality.
enum ImagePicker {
    static func resolve() async -> String {
        let prompt = "Tart image (e.g. ghcr.io/cirruslabs/macos-tahoe-base:latest)"
        let available = (try? await Tart.list()) ?? []

        // Drop digest-pinned duplicates (`name@sha256:…`) — the tag/name ref is
        // what people clone from — and graft's own dev/build VMs (not base images).
        let names = available.map(\.name).filter {
            !$0.contains("@sha256:") && !$0.hasPrefix("graft-dev-") && !$0.hasPrefix("graft-imgbuild-")
        }
        let unique = Array(Set(names)).sorted()
        guard !unique.isEmpty else { return Prompt.required(prompt) }

        let sourceByName = Dictionary(
            available.map { ($0.name, $0.source ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        var options = unique.map { name -> String in
            let src = (sourceByName[name] ?? "").lowercased()
            return src.isEmpty ? name : "\(name)  (\(src))"
        }
        options.append("enter a custom image…")

        let choice = Prompt.choose("Which Tart image?", options)
        return choice < unique.count ? unique[choice] : Prompt.required(prompt)
    }
}

/// Shared interactive flows behind `init`, `profile create`, and `pool new` —
/// one source of truth so the three entry points can't drift.
enum Wizard {
    /// Prompt for a single pool's fields (image via `ImagePicker`, App via `AppPicker`).
    static func buildPool(scope: KeychainScope) async throws -> PoolConfig {
        printErr("\n— New pool —")
        let name = Prompt.line("Pool name", default: "mac")
        let os: GuestOS = Prompt.choose("Guest OS?", ["macOS", "Linux"]) == 0 ? .macOS : .linux
        let image = await ImagePicker.resolve()
        let count = Prompt.int("How many runners?", default: os == .macOS ? 2 : 4)
        let appID = try AppPicker.resolve(scope: scope)
        let target = await TargetPicker.resolve(appID: appID, scope: scope)
        let labelsRaw = Prompt.line("Labels (comma-separated; blank = default)", default: "")
        let labels = labelsRaw.isEmpty
            ? nil
            : labelsRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        return PoolConfig(
            name: name, image: image, os: os, count: count,
            github: GitHubConfig(appId: appID, target: target, runnerGroupId: 1, labels: labels)
        )
    }

    /// Full profile wizard: name → one-or-more pools → keychain secrets → save →
    /// optionally set active → validate. Returns the profile name.
    @discardableResult
    static func createProfile(scope: KeychainScope, makeActiveDefault: Bool = true) async throws -> String {
        printErr("Graft setup — let's build a profile.\n")

        let profileName = Prompt.line("Profile name", default: "default")
        var config = Profiles.exists(profileName)
            ? ((try? Profiles.load(profileName)) ?? GraftConfig())
            : GraftConfig(provider: "tart")
        if Profiles.exists(profileName) {
            printErr("(extending existing profile '\(profileName)')")
        }

        try await chooseBackend(into: &config, scope: scope)

        repeat {
            let pool = try await buildPool(scope: scope)
            config.pools.removeAll { $0.name == pool.name }
            config.pools.append(pool)
        } while Prompt.confirm("Add another pool?", default: false)

        config.secrets = SecretsConfig(store: "keychain", scope: scope.rawValue)
        try Profiles.save(config, as: profileName)
        printErr("\n✓ wrote profile '\(profileName)'  →  \(Profiles.path(for: profileName))")

        if Prompt.confirm("Make '\(profileName)' the active profile?", default: makeActiveDefault) {
            try Profiles.setActive(profileName)
            printErr("✓ active profile is now '\(profileName)'")
        }

        let problems = config.validate()
        if problems.isEmpty {
            printErr("✓ config is valid")
        } else {
            for problem in problems { printErr("  ⚠ \(problem)") }
        }
        printErr("\nNext:  graft arborist   (verify GitHub auth)   then   graft run")
        return profileName
    }

    /// Ask whether this profile runs on local Tart or an Orchard **tree** (multi-host).
    /// For a tree, collect the trunk (controller) URL + service account, stash the token
    /// in the Keychain, and set `provider`/`orchard` on the config. (Folds in what used to
    /// be `graft orchard init`.)
    static func chooseBackend(into config: inout GraftConfig, scope: KeychainScope) async throws {
        let isOrchard = Prompt.choose("Backend?", ["Local Tart (single host)", "Orchard tree (multi-host)"]) == 1
        guard isOrchard else {
            config.provider = "tart"
            config.orchard = nil
            return
        }
        guard let v = try? await Shell.run("orchard", ["--version"]), v.succeeded else {
            throw GraftError("`orchard` not found on PATH — install it: brew install cirruslabs/cli/orchard")
        }
        let urlString = Prompt.line("Trunk (controller) URL",
                                    default: config.orchard?.controllerURL.absoluteString ?? "https://orchard.example.com:6120")
        guard let url = URL(string: urlString), url.scheme != nil else {
            throw GraftError("'\(urlString)' isn't a valid URL")
        }
        let account = Prompt.line("Service account name", default: config.orchard?.serviceAccount ?? "graft")
        try await ensureOrchardToken(account: account, url: url, scope: scope)
        let maxVMs = Prompt.int("Max leaves graft should ask for (ceiling)", default: config.orchard?.maxVMs ?? 8)
        config.provider = "orchard"
        config.orchard = OrchardConfig(controllerURL: url, serviceAccount: account, token: nil, maxVMs: maxVMs)
        printErr("✓ tree backend wired → \(url.absoluteString)")
    }

    /// Ensure the service account's token is in the Keychain — create the account on the
    /// trunk (we pass our own token so we know it; the API doesn't echo the autogenerated
    /// one), or fall back to pasting an existing token.
    private static func ensureOrchardToken(account: String, url: URL, scope: KeychainScope) async throws {
        let store = KeychainSecretStore(scope: scope)
        if store.orchardToken(account: account) != nil,
           !Prompt.confirm("A token for '\(account)' is already stored — replace it?", default: false) {
            return
        }
        let token: String
        if Prompt.confirm("Create service account '\(account)' on the trunk now?", default: true) {
            token = UUID().uuidString.lowercased()
            var env = ProcessInfo.processInfo.environment
            env[OrchardEnv.url] = url.absoluteString
            // If we planted this trunk here (`graft tree plant`), use its captured admin
            // token to authenticate the create. A remote trunk falls back to your own
            // `orchard` admin context (or pasting a token if you lack admin).
            if let admin = try? String(contentsOfFile: Tree.adminTokenFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !admin.isEmpty {
                env[OrchardEnv.accountName] = "bootstrap-admin"
                env[OrchardEnv.accountToken] = admin
            }
            let result = try await Shell.run("orchard", [
                "create", "service-account", account,
                "--roles", "compute:read", "--roles", "compute:write", "--roles", "compute:connect",
                "--token", token,
            ], environment: env, timeout: .seconds(20))
            guard result.succeeded else {
                printErr(ANSI.yellow("  couldn't create it: \(result.stderrTrimmed.isEmpty ? result.stdoutTrimmed : result.stderrTrimmed)"))
                printErr("  (already exists, or no admin access on the trunk?)")
                let pasted = Prompt.required("Paste an existing token for '\(account)'")
                try store.storeOrchardToken(pasted, account: account)
                printErr("✓ stored token for '\(account)' in the \(scope.rawValue) keychain")
                return
            }
            printErr("✓ created service account '\(account)' (compute:read/write/connect)")
        } else {
            token = Prompt.required("Paste an existing token for '\(account)'")
        }
        try store.storeOrchardToken(token, account: account)
        printErr("✓ stored token for '\(account)' in the \(scope.rawValue) keychain")
    }
}

/// The active profile, or throw a helpful error.
func resolveProfileName(_ explicit: String?) throws -> String {
    if let explicit { return explicit }
    if let active = Profiles.activeName() { return active }
    throw GraftError("no active profile — pass --profile NAME or run `graft profile use NAME`")
}
