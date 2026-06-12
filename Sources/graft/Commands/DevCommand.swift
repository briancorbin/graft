import ArgumentParser
import Foundation
import GraftCore

/// `graft dev` — spin up a local dev VM from an image. Three repo sources:
///   • mount (default): share your `$PWD` into the VM (quick checks against your WIP).
///   • seed (`--code` in a repo): copy your working tree onto the VM's disk (guest-resident).
///   • clone (`--repo <spec>`): fresh `git clone` into the VM over agent-forwarded SSH.
/// Two front-ends: a shell (default / `-- CMD`) or VS Code Remote-SSH (`--code`).
/// Persistent by default (reattach across sessions); `--ephemeral` for a throwaway.
struct Dev: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dev",
        abstract: "Boot a dev VM from an image; mount/seed/clone a repo; shell in or open VS Code."
    )

    @Option(name: .long, help: "Image to clone the VM from (default: pick from local images).")
    var image: String?

    @Option(name: .long, help: "Dev VM name (default: derived from the repo, or the image).")
    var name: String?

    @Option(name: .long, help: "Clone this repo into the VM (owner/name or a git URL) instead of using $PWD.")
    var repo: String?

    @Option(name: .long, help: "Branch or tag to clone with --repo.")
    var ref: String?

    @Option(name: .long, parsing: .singleValue, help: "Extra mount: path | name:path | name:path:ro (repeatable).")
    var mount: [String] = []

    @Flag(name: .long, help: "Don't mount the current directory as 'repo'.")
    var noRepo = false

    @Flag(help: "Throwaway VM: fresh clone, deleted on exit (default: persistent).")
    var ephemeral = false

    @Option(name: .long, help: "VM networking: nat (default), bridged:<iface> (e.g. behind Zscaler), or softnet.")
    var network: String?

    @Flag(name: .long, help: "Open VS Code into the VM over Remote-SSH (guest-resident: code lives on the VM's disk).")
    var code = false

    @Option(name: .long, help: "Profile to source the GitHub App from (for the repo picker). Default: active.")
    var profile: String?

    @Argument(parsing: .postTerminator, help: "Command after `--` to run in the VM (default: interactive shell).")
    var command: [String] = []

    func run() async throws {
        guard !(code && ephemeral) else { throw GraftError("--code is for a persistent dev VM — drop --ephemeral") }

        let provider = LocalTartProvider()
        let cwd = FileManager.default.currentDirectoryPath
        let cwdIsRepo = FileManager.default.fileExists(atPath: (cwd as NSString).appendingPathComponent(".git"))

        // ---- Decide the repo source ----
        var cloneSpec: (url: String, name: String)?
        var seedFromPWD = false
        var reattach: String?

        if let repo {
            cloneSpec = DevCode.expandRepoSpec(repo)
        } else if code && cwdIsRepo {
            seedFromPWD = true
        } else if code {
            // --code, not in a repo, no --repo: pick a box/repo.
            if name != nil {
                // box is already named → just choose a repo to clone into it
                guard let spec = await DevBoxPicker.pickRepo(profile: profile) else { printErr("nothing selected"); return }
                cloneSpec = DevCode.expandRepoSpec(spec)
            } else {
                switch await DevBoxPicker.resolve(profile: profile) {
                case .reattach(let vm): reattach = vm
                case .clone(let url, let name): cloneSpec = (url, name)
                case .scratch: break
                case .cancelled: printErr("nothing selected"); return
                }
            }
        }
        // else: mount mode — share $PWD below.

        // ---- Image (not needed when reattaching an existing box) ----
        let img: String
        if reattach != nil { img = "" }
        else if let image { img = image }
        else { img = await ImagePicker.resolve() }

        // ---- Name the box ----
        let vmName: String
        if let reattach { vmName = reattach }
        else if let name { vmName = name }
        else if ephemeral { vmName = "graft-dev-eph-" + UUID().uuidString.prefix(8).lowercased() }
        else if let cloneSpec { vmName = "graft-dev-\(cloneSpec.name)" }
        else if seedFromPWD { vmName = "graft-dev-\(URL(fileURLWithPath: cwd).lastPathComponent)" }
        else { vmName = Self.devName(for: img) }

        // ---- Mounts: share $PWD for mount mode, or to seed under --code ----
        var mounts: [Mount] = []
        let needPWDMount = seedFromPWD || (!code && cloneSpec == nil && reattach == nil && !noRepo)
        if needPWDMount { mounts.append(Mount(name: "repo", source: cwd)) }
        mounts += try mount.map { try Mount(spec: $0) }
        let repoGuestPath = mounts.first { $0.name == "repo" }?.guestPath

        // Capacity heads-up (macOS 2-VM limit).
        let running = (try? await Tart.list())?.filter {
            $0.name.hasPrefix("graft-") && $0.isRunning && $0.name != vmName
        } ?? []
        if running.count >= LocalTartProvider.hostCapacity(for: .macOS) {
            printErr("⚠ \(running.count) other graft VM(s) running — at the macOS 2-VM limit; this may fail to boot.")
        }

        // ---- Clone the VM from the image if it doesn't exist; boot it ----
        let existing = try await Tart.list().first { $0.name == vmName }
        if existing == nil {
            guard !img.isEmpty else { throw GraftError("no dev box named '\(vmName)'") }
            try await Tart.ensureAvailable(img)
            printErr("cloning \(img) → \(vmName)…")
            try await Tart.clone(image: img, to: vmName)
        }
        let net = try network.map { try VMNetwork(spec: $0) } ?? .nat
        if existing?.isRunning != true {
            printErr("booting \(vmName) — a fresh clone's first boot can take ~60–90s, don't cancel…")
            try Tart.run(name: vmName, mounts: mounts, network: net)
            try await provider.waitForGuest(RunningVM(name: vmName, ip: "", os: .macOS), timeout: .seconds(180))
            printErr("  guest is up.")
        }

        // ---- VS Code Remote-SSH (guest-resident) ----
        if code {
            let ip = try await Tart.waitForIP(name: vmName)
            let vm = RunningVM(name: vmName, ip: ip, os: .macOS)
            printErr("setting up Remote-SSH access…")
            let pub = try await DevCode.ensureKeyPair()
            try await DevCode.injectKey(pub, into: vm, provider: provider)
            try DevCode.writeSSHConfig(alias: vmName, ip: ip, user: "admin")
            try await DevCode.waitForSSH(alias: vmName)

            let guestRepo: String
            if let cloneSpec {
                printErr("cloning \(cloneSpec.url) into the VM…")
                let token = await DevCode.ghToken()
                guestRepo = try await DevCode.cloneRepo(url: cloneSpec.url, ref: ref, repoName: cloneSpec.name, alias: vmName, token: token)
            } else if seedFromPWD, let repoGuestPath {
                printErr("seeding repo onto the VM's disk (node_modules/Pods stay guest-local)…")
                guestRepo = try await DevCode.seedRepo(
                    mountGuestPath: repoGuestPath, repoName: URL(fileURLWithPath: cwd).lastPathComponent,
                    on: vm, provider: provider)
            } else {
                let slug = vmName.hasPrefix("graft-dev-") ? String(vmName.dropFirst("graft-dev-".count)) : vmName
                guestRepo = try await DevCode.resolveWorkDir(slug: slug, on: vm, provider: provider)
            }

            printErr("opening VS Code → \(vmName):\(guestRepo)")
            try await DevCode.launchCode(alias: vmName, remotePath: guestRepo)
            printErr("""

            ✓ VS Code is connecting into \(vmName).
              • Code + node_modules + Pods live on the VM (\(guestRepo)) — native speed, no file share.
              • Terminal, language servers, builds run guest-side; `git push`/`pull` use VS Code's forwarded credentials (no token stored in the VM).
              • Reattach with `graft dev --code`; remove with `graft vm delete \(vmName)`.
            """)
            return
        }

        // ---- --repo without --code: clone into the VM, then shell in ----
        if let cloneSpec {
            let ip = try await Tart.waitForIP(name: vmName)
            let vm = RunningVM(name: vmName, ip: ip, os: .macOS)
            let pub = try await DevCode.ensureKeyPair()
            try await DevCode.injectKey(pub, into: vm, provider: provider)
            try DevCode.writeSSHConfig(alias: vmName, ip: ip, user: "admin")
            try await DevCode.waitForSSH(alias: vmName)
            printErr("cloning \(cloneSpec.url) into the VM…")
            let token = await DevCode.ghToken()
            let guestRepo = try await DevCode.cloneRepo(url: cloneSpec.url, ref: ref, repoName: cloneSpec.name, alias: vmName, token: token)
            let exit = try Tart.execInteractive(
                name: vmName, command: Self.shell(cd: guestRepo, run: command), interactive: command.isEmpty)
            try await finish(vmName: vmName, exit: exit)
            return
        }

        // ---- Mount / shell (the original path) ----
        if let repoGuestPath { printErr("repo mounted at \(repoGuestPath)") }
        let exit = try Tart.execInteractive(
            name: vmName, command: Self.shell(cd: repoGuestPath, run: command), interactive: command.isEmpty)
        try await finish(vmName: vmName, exit: exit)
    }

    /// Tear down (ephemeral) or report the persistent VM, then propagate the exit code.
    private func finish(vmName: String, exit: Int32) async throws {
        if ephemeral {
            printErr("\ntearing down \(vmName)…")
            try? await Tart.stop(name: vmName)
            try? await Tart.delete(name: vmName)
        } else {
            printErr("\n\(vmName) left running — `graft dev` to reattach, `graft vm delete \(vmName)` to remove.")
        }
        if exit != 0 { throw ExitCode(exit) }
    }

    /// Build the bash invocation: cd into the repo dir (if any), then either run the
    /// passthrough command or replace with an interactive login shell.
    private static func shell(cd: String?, run: [String]) -> [String] {
        let prefix = cd.map { "cd '\($0)' 2>/dev/null; " } ?? ""
        let body = run.isEmpty ? "exec bash -l" : run.joined(separator: " ")
        return ["bash", "-lc", prefix + body]
    }

    /// `ghcr.io/cirruslabs/macos-sequoia-xcode:latest` → `graft-dev-macos-sequoia-xcode`.
    private static func devName(for image: String) -> String {
        let base = image.split(separator: "/").last.map(String.init) ?? image
        let noTag = base.split(separator: ":").first.map(String.init) ?? base
        let safe = String(noTag.map { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") ? $0 : "-" })
        return "graft-dev-" + (safe.isEmpty ? "vm" : safe)
    }
}
