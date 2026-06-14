import ArgumentParser
import Foundation
import GraftCore

/// `graft nest` — spin up or resume a nest (dev box) from a sapling.
///
///   graft nest                 picker: resume a box / clone a repo / mount here / scratch
///   graft nest <owner/repo>    clone a repo into a persistent box and open it
///   graft nest <box>           resume a persistent box
///   graft nest .               mount the current directory into an ephemeral box
///   graft nest ls              list nests
///   graft nest rm [box]        remove a box
///
/// Model: **clone → persistent + resumable** (your repo + state live in the box);
/// **mount / scratch → ephemeral** (your files are the source of truth on the host).
/// Shell is the default; `--code` opens VS Code over Remote-SSH.
struct Dev: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nest",
        abstract: "Spin up or resume a nest — a dev box — from a sapling.",
        subcommands: [Open.self, List.self, Remove.self],
        defaultSubcommand: Open.self
    )
}

extension Dev {
    /// The default action: open a dev box (clone / resume / mount / pick).
    struct Open: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "open",
            abstract: "Open a dev box (clone a repo, resume a box, mount '.', or pick)."
        )

        @Argument(help: "owner/repo or git URL (clone) · box name (resume) · '.' (mount this dir) · omit to pick.")
        var target: String?

        @Flag(name: .long, help: "Open VS Code into the VM over Remote-SSH (default: a shell).")
        var code = false

        @Option(name: .long, help: "Base image for a NEW box (default: pick from local images).")
        var image: String?

        @Option(name: .long, help: "Branch or tag to clone (with a repo target).")
        var ref: String?

        @Option(name: .long, help: "Override the box name.")
        var name: String?

        @Option(name: .long, parsing: .singleValue, help: "Advanced: extra mount path|name:path[:ro] (repeatable).")
        var mount: [String] = []

        @Option(name: .long, help: "Advanced: VM networking — nat (default), bridged:<iface>, softnet.")
        var network: String?

        @Option(name: .long, help: "Profile whose GitHub App backs the repo picker (default: active).")
        var profile: String?

        @Flag(name: .long, help: "Advanced: force a throwaway box even when cloning.")
        var ephemeral = false

        @Argument(parsing: .postTerminator, help: "Command to run in the VM (default: interactive shell).")
        var command: [String] = []

        enum Source { case clone(url: String, name: String); case resume(String); case mount; case scratch }

        func run() async throws {
            let provider = LocalTartProvider()
            let cwd = FileManager.default.currentDirectoryPath

            // 1) Resolve the source — from the target, or the interactive picker.
            var openInCode = code
            let source: Source
            if let target {
                source = try await Self.classify(target)
            } else {
                switch await DevBoxPicker.resolve(profile: profile) {
                case .resume(let b): source = .resume(b)
                case .clone(let u, let n): source = .clone(url: u, name: n)
                case .mount: source = .mount
                case .scratch: source = .scratch
                case .cancelled: printErr("nothing selected"); return
                }
                if !code { openInCode = DevBoxPicker.askConnect() }   // picker offers shell/code
            }

            // 2) Box name + whether it's a fresh box needing an image. `--name` is kept in
            // the graft-dev- namespace so it shows up in `ls`/`rm`/`graft dev <name>`.
            let override = name.map { $0.hasPrefix("graft-dev-") ? $0 : "graft-dev-\($0)" }
            let vmName: String
            let needsImage: Bool
            switch source {
            case .resume(let b): vmName = b; needsImage = false
            case .clone(_, let n): vmName = override ?? "graft-dev-\(n)"; needsImage = true
            case .mount, .scratch:
                vmName = override ?? "graft-dev-eph-" + UUID().uuidString.prefix(8).lowercased()
                needsImage = true
            }

            // 3) Mounts: $PWD for mount mode, plus any advanced --mount.
            var mounts: [Mount] = []
            if case .mount = source { mounts.append(Mount(name: "repo", source: cwd)) }
            mounts += try mount.map { try Mount(spec: $0) }
            let mountGuestPath = mounts.first { $0.name == "repo" }?.guestPath

            // Capacity heads-up (macOS 2-VM limit).
            let running = (try? await Tart.list())?.filter {
                $0.name.hasPrefix("graft-") && $0.isRunning && $0.name != vmName
            } ?? []
            if running.count >= LocalTartProvider.hostCapacity(for: .macOS) {
                printErr("⚠ \(running.count) other graft VM(s) running — at the macOS 2-VM limit; this may fail to boot.")
            }

            // 4) Create the box from an image if it doesn't exist, then boot it.
            let existing = try await Tart.list().first { $0.name == vmName }
            if existing == nil {
                guard needsImage else { throw GraftError("no dev box '\(vmName)'") }
                let img: String
                if let image { img = image } else { img = await ImagePicker.resolve() }
                try await Tart.ensureAvailable(img)
                printErr("creating \(vmName) from \(img)…")
                try await Tart.clone(image: img, to: vmName)
            }
            let net = try network.map { try VMNetwork(spec: $0) } ?? .nat
            if existing?.isRunning != true {
                printErr("booting \(vmName) — a fresh first boot can take ~60–90s, don't cancel…")
                try Tart.run(name: vmName, mounts: mounts, network: net)
                try await provider.waitForGuest(RunningVM(name: vmName, ip: "", os: .macOS), timeout: .seconds(180))
                printErr("  guest is up.")
            }

            // 5) SSH setup is needed to clone (runs over ssh) or to open VS Code.
            let isClone: Bool = { if case .clone = source { return true } else { return false } }()
            var vm = RunningVM(name: vmName, ip: "", os: .macOS)
            if isClone || openInCode {
                let ip = try await Tart.waitForIP(name: vmName)
                vm = RunningVM(name: vmName, ip: ip, os: .macOS)
                printErr("setting up SSH access…")
                let pub = try await DevCode.ensureKeyPair()
                try await DevCode.injectKey(pub, into: vm, provider: provider)
                try DevCode.writeSSHConfig(alias: vmName, ip: ip, user: "admin")
                try await DevCode.waitForSSH(alias: vmName)
            }

            // 6) Put the repo in place; figure out which dir to open.
            let guestPath: String
            switch source {
            case .clone(let url, let repoName):
                printErr("cloning \(url) into the VM (or reusing the existing checkout)…")
                guestPath = try await DevCode.cloneRepo(url: url, ref: ref, repoName: repoName, alias: vmName)
            case .resume(let box):
                let slug = box.replacingOccurrences(of: "graft-dev-", with: "")
                guestPath = (try? await DevCode.resolveWorkDir(slug: slug, on: vm, provider: provider)) ?? "$HOME"
            case .mount:
                guestPath = mountGuestPath ?? "$HOME"
            case .scratch:
                guestPath = "$HOME"
            }

            // 7) Connect. VS Code can't tear down on close, so code mode is always persistent;
            // shell mode tears down ephemeral (mount/scratch/--ephemeral) boxes on exit.
            if openInCode {
                printErr("opening VS Code → \(vmName):\(guestPath)")
                try await DevCode.launchCode(alias: vmName, remotePath: guestPath)
                printErr("""

                ✓ VS Code connecting into \(vmName) — terminal, builds, language servers run guest-side.
                  Remove with `graft dev rm \(vmName.replacingOccurrences(of: "graft-dev-", with: ""))`.
                """)
                return
            }

            let cd = (guestPath == "$HOME") ? nil : guestPath
            let exit = try Tart.execInteractive(
                name: vmName, command: Self.shell(cd: cd, run: command), interactive: command.isEmpty)
            try await Self.finish(source: source, ephemeralFlag: ephemeral, vmName: vmName, exit: exit)
        }

        /// Map a target string to a source: `.` → mount, slash/URL → clone, else resume a box.
        static func classify(_ target: String) async throws -> Source {
            if target == "." { return .mount }
            if target.contains("/") || target.contains("://") || target.hasPrefix("git@") {
                let (url, name) = DevCode.expandRepoSpec(target)
                return .clone(url: url, name: name)
            }
            let all = (try? await Tart.list()) ?? []
            if let box = all.first(where: { $0.name == target || $0.name == "graft-dev-\(target)" })?.name {
                return .resume(box)
            }
            throw GraftError("no dev box '\(target)' — `graft dev ls` to list, or pass owner/repo to clone.")
        }

        /// Tear down ephemeral boxes (mount/scratch, or `--ephemeral`) after a shell exits;
        /// leave persistent (clone/resume) boxes running.
        static func finish(source: Source, ephemeralFlag: Bool, vmName: String, exit: Int32) async throws {
            let ephemeral: Bool
            switch source {
            case .mount, .scratch: ephemeral = true
            case .clone: ephemeral = ephemeralFlag
            case .resume: ephemeral = false
            }
            if ephemeral {
                printErr("\ntearing down \(vmName)…")
                try? await Tart.stop(name: vmName)
                try? await Tart.delete(name: vmName)
            } else {
                let short = vmName.replacingOccurrences(of: "graft-dev-", with: "")
                printErr("\n\(vmName) left running — `graft dev \(short)` to resume, `graft dev rm \(short)` to remove.")
            }
            if exit != 0 { throw ExitCode(exit) }
        }

        /// Build the bash invocation: cd into the dir (if any), then a login shell or the command.
        static func shell(cd: String?, run: [String]) -> [String] {
            let prefix = cd.map { "cd '\($0)' 2>/dev/null; " } ?? ""
            let body = run.isEmpty ? "exec bash -l" : run.joined(separator: " ")
            return ["bash", "-lc", prefix + body]
        }
    }

    /// `graft dev ls` — list dev boxes.
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "ls", abstract: "List dev boxes.")

        func run() async throws {
            let boxes = (try await Tart.list())
                .filter { $0.name.hasPrefix("graft-dev-") }
                .sorted { $0.name < $1.name }
            guard !boxes.isEmpty else { printErr("no dev boxes — `graft dev <owner/repo>` to make one"); return }
            for b in boxes {
                let short = b.name.replacingOccurrences(of: "graft-dev-", with: "")
                print("\(short)\t\(b.state)\t\(b.name)")
            }
        }
    }

    /// `graft dev rm [box]` — remove a dev box (picker if omitted).
    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove a dev box.")

        @Argument(help: "Box name (short or full). Omit to pick.")
        var box: String?

        func run() async throws {
            let boxes = (try await Tart.list())
                .filter { $0.name.hasPrefix("graft-dev-") }
                .sorted { $0.name < $1.name }
            guard !boxes.isEmpty else { printErr("no dev boxes"); return }

            let target: String
            if let box {
                guard let match = boxes.first(where: { $0.name == box || $0.name == "graft-dev-\(box)" })?.name else {
                    throw GraftError("no dev box '\(box)'")
                }
                target = match
            } else {
                let choice = Prompt.choose("Remove which box?", boxes.map {
                    "\($0.name.replacingOccurrences(of: "graft-dev-", with: ""))  (\($0.state))"
                })
                target = boxes[choice].name
            }
            try? await Tart.stop(name: target)
            try await Tart.delete(name: target)
            printErr("✓ removed \(target)")
        }
    }
}
