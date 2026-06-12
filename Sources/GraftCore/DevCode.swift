import Foundation

/// Glue for `graft dev --code` — guest-resident dev over VS Code Remote-SSH.
///
/// The host becomes a thin client: graft mints a dedicated SSH key, injects it into the
/// guest, seeds your repo onto the VM's native disk (so node_modules/Pods live there, not
/// on a slow file share), writes a graft-owned ssh config, and opens VS Code connected
/// *into* the VM. Language servers, the terminal, and builds all run guest-side.
public enum DevCode {
    static var home: String { NSHomeDirectory() }
    static var graftDir: String { (home as NSString).appendingPathComponent(".graft") }
    static var keyPath: String { (graftDir as NSString).appendingPathComponent("dev_ed25519") }
    static var knownHostsPath: String { (graftDir as NSString).appendingPathComponent("known_hosts") }
    static var sshDir: String { (home as NSString).appendingPathComponent(".ssh") }
    static var sshConfigPath: String { (sshDir as NSString).appendingPathComponent("config") }
    static var graftSSHConfigPath: String { (sshDir as NSString).appendingPathComponent("graft.config") }

    /// Ensure a dedicated graft dev keypair exists (so we never touch the user's personal
    /// keys); return the public key contents.
    public static func ensureKeyPair() async throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(atPath: graftDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: keyPath) {
            try await Shell.runChecked("ssh-keygen", ["-t", "ed25519", "-f", keyPath, "-N", "", "-C", "graft-dev", "-q"])
        }
        let pub = try String(contentsOfFile: keyPath + ".pub", encoding: .utf8)
        return pub.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Append the pubkey to the guest's authorized_keys (idempotent). The cirruslabs
    /// images already have Remote Login on; we enable it best-effort just in case.
    public static func injectKey(_ pub: String, into vm: RunningVM, provider: VMProvider) async throws {
        let script = """
        sudo -n systemsetup -f -setremotelogin on >/dev/null 2>&1 || true
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
        grep -qxF '\(pub)' ~/.ssh/authorized_keys || printf '%s\\n' '\(pub)' >> ~/.ssh/authorized_keys
        """
        let r = try await provider.exec(on: vm, ["bash", "-lc", script])
        guard r.succeeded else { throw GraftError("failed to inject SSH key into guest: \(r.stderrTrimmed)") }
    }

    /// Seed the mounted repo onto the guest's native disk, once, excluding the heavy build
    /// artifacts so they regenerate guest-local (the whole point — keep them off the share).
    /// Returns the absolute guest path of the working copy.
    public static func seedRepo(mountGuestPath: String, repoName: String, on vm: RunningVM, provider: VMProvider) async throws -> String {
        let dest = "$HOME/work/\(repoName)"
        let script = """
        set -e
        if [ ! -d "\(dest)/.git" ] && [ ! -d "\(dest)" ]; then
          mkdir -p "\(dest)"
          rsync -a \
            --exclude node_modules --exclude 'ios/Pods' --exclude .build \
            --exclude DerivedData --exclude .gradle --exclude .yarn/cache \
            "\(mountGuestPath)/" "\(dest)/"
        fi
        cd "\(dest)" && pwd
        """
        let r = try await provider.exec(on: vm, ["bash", "-lc", script])
        guard r.succeeded, !r.stdoutTrimmed.isEmpty else {
            throw GraftError("failed to seed repo into guest: \(r.stderrTrimmed)")
        }
        return r.stdoutTrimmed
    }

    /// Upsert a host block for `alias` into ~/.ssh/graft.config and make sure the main
    /// config Includes it — so per-boot IP churn never touches the user's real config.
    public static func writeSSHConfig(alias: String, ip: String, user: String) throws {
        let block = """
        # >>> graft \(alias)
        Host \(alias)
          HostName \(ip)
          User \(user)
          IdentityFile \(keyPath)
          IdentitiesOnly yes
          ForwardAgent yes
          StrictHostKeyChecking accept-new
          UserKnownHostsFile \(knownHostsPath)
        # <<< graft \(alias)
        """
        try FileManager.default.createDirectory(atPath: sshDir, withIntermediateDirectories: true)
        let existing = (try? String(contentsOfFile: graftSSHConfigPath, encoding: .utf8)) ?? ""
        let stripped = Self.stripBlock(existing, alias: alias).trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = (stripped.isEmpty ? block : stripped + "\n\n" + block) + "\n"
        try updated.write(toFile: graftSSHConfigPath, atomically: true, encoding: .utf8)
        try ensureInclude()
    }

    /// Remove an existing `# >>> graft <alias>` … `# <<< graft <alias>` block.
    static func stripBlock(_ text: String, alias: String) -> String {
        let start = "# >>> graft \(alias)", end = "# <<< graft \(alias)"
        var out: [String] = []
        var skipping = false
        for line in text.components(separatedBy: "\n") {
            if line == start { skipping = true; continue }
            if line == end { skipping = false; continue }
            if !skipping { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    /// Prepend `Include ~/.ssh/graft.config` to the main ssh config if it's not there.
    static func ensureInclude() throws {
        let includeLine = "Include \(graftSSHConfigPath)"
        let cfg = (try? String(contentsOfFile: sshConfigPath, encoding: .utf8)) ?? ""
        guard !cfg.contains(includeLine) else { return }
        let updated = includeLine + "\n" + cfg
        try updated.write(toFile: sshConfigPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sshConfigPath)
    }

    /// Wait until the guest is actually reachable over SSH. A fresh VM gets its DHCP lease
    /// (so `tart ip` returns) a few seconds before the network is routable — without this,
    /// the first `ssh` races the boot and fails with "No route to host".
    public static func waitForSSH(alias: String, timeout: Duration = .seconds(60)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let r = try? await Shell.run("ssh", [
                "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=accept-new",
                alias, "true",
            ], timeout: .seconds(8))
            if let r, r.exitCode == 0 { return }
            try await Task.sleep(for: .seconds(2))
        }
        throw GraftError("guest \(alias) didn't become reachable over SSH within \(timeout)")
    }

    /// Expand a `--repo` spec into an **HTTPS** clone URL + a short repo name. We clone over
    /// HTTPS (with a short-lived token), not SSH — 1Password's agent refuses to sign over
    /// agent forwarding, and HTTPS lets VS Code forward git credentials for push/pull.
    public static func expandRepoSpec(_ spec: String) -> (url: String, name: String) {
        var url: String
        if spec.hasPrefix("git@") {
            // git@host:owner/repo(.git) → https://host/owner/repo.git
            url = "https://" + String(spec.dropFirst(4)).replacingOccurrences(of: ":", with: "/")
        } else if spec.contains("://") {
            url = spec
        } else {
            url = "https://github.com/\(spec)"     // owner/name shorthand
        }
        if !url.hasSuffix(".git") { url += ".git" }
        var name = url
        if let cut = name.lastIndex(of: "/") { name = String(name[name.index(after: cut)...]) }
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        return (url, name.isEmpty ? "repo" : name)
    }

    /// The user's GitHub token, used once to clone (never stored). Reads gh's config file
    /// first — no subprocess, no keychain prompt (which can hang) — then falls back to
    /// `gh auth token` (bounded, so a keychain stall can't freeze graft).
    public static func ghToken() async -> String? {
        let hosts = (NSHomeDirectory() as NSString).appendingPathComponent(".config/gh/hosts.yml")
        if let text = try? String(contentsOfFile: hosts, encoding: .utf8) {
            for line in text.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("oauth_token:") {
                    let token = t.dropFirst("oauth_token:".count).trimmingCharacters(in: .whitespaces)
                    if !token.isEmpty { return token }
                }
            }
        }
        guard let r = try? await Shell.run("gh", ["auth", "token"], timeout: .seconds(8)),
              r.succeeded, !r.stdoutTrimmed.isEmpty else { return nil }
        return r.stdoutTrimmed
    }

    /// Clone `url` (HTTPS) into `~/work/<repoName>` inside the guest. For a github URL with a
    /// `token`, auth is supplied via `GIT_ASKPASS` (token passed over stdin — never in argv,
    /// `.git/config`, or the VM's disk), then the remote is reset to a clean URL so VS Code's
    /// credential forwarding owns push/pull. Idempotent. Returns the absolute guest path.
    public static func cloneRepo(url: String, ref: String?, repoName: String, alias: String, token: String?) async throws -> String {
        let branch = ref.map { " --branch '\($0)'" } ?? ""
        // `dest` is a bash variable assigned with double quotes so `$HOME` actually expands
        // in the guest — do NOT inline it single-quoted (that clones into a literal "$HOME"
        // directory, the bug behind every "workspace does not exist").
        let clone: String
        if let token, url.contains("github.com") {
            let tokenURL = url.replacingOccurrences(of: "https://", with: "https://x-access-token@")
            clone = """
            export GRAFT_GH_TOKEN='\(token)'
            _ap="$(mktemp)"; printf '#!/bin/sh\\necho "$GRAFT_GH_TOKEN"\\n' > "$_ap"; chmod +x "$_ap"
            GIT_ASKPASS="$_ap" GIT_TERMINAL_PROMPT=0 git -c credential.helper= clone\(branch) '\(tokenURL)' "$dest"
            rm -f "$_ap"
            git -C "$dest" remote set-url origin '\(url)'
            """
        } else {
            // No token: still disable prompts + credential helpers so a private repo
            // fails fast instead of hanging on a credential manager (GCM/osxkeychain)
            // in the headless guest.
            clone = "GIT_TERMINAL_PROMPT=0 git -c credential.helper= clone\(branch) '\(url)' \"$dest\""
        }
        // Script over stdin (`bash -s`) so the token never appears in `ps`. `set -e` makes a
        // failed clone propagate (no more silently opening an empty editor).
        let script = """
        set -e
        dest="$HOME/work/\(repoName)"
        if [ -d "$dest/.git" ]; then exit 0; fi
        mkdir -p "$(dirname "$dest")"
        \(clone)
        """
        let code = try await Shell.runStreaming("ssh", [alias, "bash", "-s"], stdin: script)
        guard code == 0 else {
            throw GraftError("clone failed (exit \(code)) — check the repo spec and `gh auth status`")
        }
        // Resolve the absolute guest path ($HOME expands in the remote shell here).
        let pathR = try? await Shell.run("ssh", ["-o", "BatchMode=yes", alias, "echo $HOME/work/\(repoName)"], timeout: .seconds(10))
        let resolved = pathR?.stdoutTrimmed ?? ""
        return resolved.isEmpty ? "/Users/admin/work/\(repoName)" : resolved
    }

    /// The folder to open when reattaching: `~/work/<slug>` if it exists, else `~`.
    public static func resolveWorkDir(slug: String, on vm: RunningVM, provider: VMProvider) async throws -> String {
        let script = "d=\"$HOME/work/\(slug)\"; if [ -d \"$d\" ]; then echo \"$d\"; else echo \"$HOME\"; fi"
        let r = try await provider.exec(on: vm, ["bash", "-lc", script])
        return r.stdoutTrimmed.isEmpty ? "/Users/admin" : r.stdoutTrimmed
    }

    /// Open VS Code connected into the guest at `remotePath`. Ensures the Remote-SSH
    /// extension is present first (the `ssh-remote` authority won't resolve without it).
    /// Returns the `code` exit code.
    @discardableResult
    public static func launchCode(alias: String, remotePath: String) async throws -> Int32 {
        let listed = try? await Shell.run("code", ["--list-extensions"])
        guard let listed, listed.succeeded else {
            throw GraftError("the VS Code `code` CLI isn't on PATH (VS Code → Cmd+Shift+P → \"Shell Command: Install 'code' command in PATH\")")
        }
        if !listed.stdout.contains("ms-vscode-remote.remote-ssh") {
            Log.info("installing the VS Code Remote-SSH extension…")
            try await Shell.runChecked("code", ["--install-extension", "ms-vscode-remote.remote-ssh"])
        }
        let r = try await Shell.run("code", ["--remote", "ssh-remote+\(alias)", remotePath])
        guard r.succeeded else { throw GraftError("`code --remote` failed: \(r.stderrTrimmed)") }
        return r.exitCode
    }
}
