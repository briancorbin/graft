import Foundation
import Yams

/// A declarative image build (a `.graft` / YAML / JSON file): clone `from`, set up a
/// toolchain, snapshot the result as a local image named `name`.
///
/// High-level fields (`ruby`, `node`, `brew`, …) are *compiled* by graft into the right
/// provisioning commands — including non-obvious best practices like exposing `node` at
/// a stable `/usr/local/bin` path for Xcode build phases. Drop to `run:` (a `|` block or
/// list) or `script:` (a file) for anything custom. Everything runs in one guest shell:
/// compiled toolchain → script → run.
public struct ImageRecipe: Codable, Sendable {
    public let name: String
    public let from: String

    // High-level toolchain (compiled to provisioning steps, in this order):
    public let node: String?            // fnm install + default + corepack + stable symlink
    public let ruby: String?            // rbenv install + global + bundler
    public let brew: [String]?          // brew install …
    public let gems: [String]?          // gem install … --no-document
    public let npm: [String]?           // npm install -g …
    public let xcodeFirstLaunch: Bool?  // sudo xcodebuild -runFirstLaunch
    public let warmSimulators: [String]?// boot once + shutdown (warms on-disk caches)

    // Escape hatches (run after the compiled steps, script then run):
    public let script: String?          // path to a shell script (relative to the recipe)
    public let run: [String]            // inline: a `|` block (one string) or a list

    public let mounts: [Mount]?
    public let os: GuestOS?

    public init(
        name: String, from: String,
        node: String? = nil, ruby: String? = nil, brew: [String]? = nil, gems: [String]? = nil,
        npm: [String]? = nil, xcodeFirstLaunch: Bool? = nil, warmSimulators: [String]? = nil,
        run: [String] = [], script: String? = nil, mounts: [Mount]? = nil, os: GuestOS? = nil
    ) {
        self.name = name; self.from = from
        self.node = node; self.ruby = ruby; self.brew = brew; self.gems = gems
        self.npm = npm; self.xcodeFirstLaunch = xcodeFirstLaunch; self.warmSimulators = warmSimulators
        self.run = run; self.script = script; self.mounts = mounts; self.os = os
    }

    public var guestOS: GuestOS { os ?? .macOS }

    enum CodingKeys: String, CodingKey {
        case name, from, node, ruby, brew, gems, npm, script, run, mounts, os
        case xcodeFirstLaunch = "xcode-first-launch"
        case warmSimulators = "warm-simulators"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        from = try c.decode(String.self, forKey: .from)
        node = Self.version(c, .node)        // tolerate `node: 20` (int) as well as "20.19.4"
        ruby = Self.version(c, .ruby)
        brew = try c.decodeIfPresent([String].self, forKey: .brew)
        gems = try c.decodeIfPresent([String].self, forKey: .gems)
        npm = try c.decodeIfPresent([String].self, forKey: .npm)
        xcodeFirstLaunch = try c.decodeIfPresent(Bool.self, forKey: .xcodeFirstLaunch)
        warmSimulators = try c.decodeIfPresent([String].self, forKey: .warmSimulators)
        script = try c.decodeIfPresent(String.self, forKey: .script)
        // `run` may be a single block-scalar script (YAML `run: |`) or a list of steps.
        if let single = try? c.decode(String.self, forKey: .run) {
            run = [single]
        } else {
            run = try c.decodeIfPresent([String].self, forKey: .run) ?? []
        }
        mounts = try c.decodeIfPresent([Mount].self, forKey: .mounts)
        os = try c.decodeIfPresent(GuestOS.self, forKey: .os)
    }

    private static func version(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let s = try? c.decode(String.self, forKey: key) { return s }
        if let i = try? c.decode(Int.self, forKey: key) { return String(i) }
        if let d = try? c.decode(Double.self, forKey: key) { return String(d) }
        return nil
    }

    // MARK: Compilation

    /// The full provisioning script for the guest, or nil if there's nothing to do.
    /// Order: compiled toolchain steps → `script:` body → `run:` steps.
    public func provisioning(scriptBody: String?) -> String? {
        var parts = ["set -eo pipefail"]
        parts.append(contentsOf: compiledSteps)
        if let scriptBody, !scriptBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(scriptBody)
        }
        parts.append(contentsOf: run)
        return parts.count > 1 ? parts.joined(separator: "\n") : nil
    }

    /// The high-level fields expanded into bash blocks.
    public var compiledSteps: [String] {
        var steps: [String] = []
        if let node { steps.append(Self.nodeStep(node)) }
        if let ruby { steps.append(Self.rubyStep(ruby)) }
        if let brew, !brew.isEmpty {
            let list = brew.joined(separator: " ")
            steps.append("echo \"==> brew install \(list)\"\nbrew install \(list)")
        }
        if let gems, !gems.isEmpty {
            let list = gems.joined(separator: " ")
            steps.append("echo \"==> gem install \(list)\"\ngem install \(list) --no-document")
        }
        if let npm, !npm.isEmpty {
            let list = npm.joined(separator: " ")
            steps.append("echo \"==> npm install -g \(list)\"\nnpm install -g \(list)")
        }
        if xcodeFirstLaunch == true {
            steps.append("echo \"==> Xcode first-launch components\"\nsudo xcodebuild -runFirstLaunch")
        }
        if let warmSimulators, !warmSimulators.isEmpty {
            steps.append(Self.warmSimsStep(warmSimulators))
        }
        return steps
    }

    private static func nodeStep(_ v: String) -> String {
        """
        echo "==> Node \(v)"
        eval "$(fnm env)"
        fnm install \(v)
        fnm default \(v)
        corepack enable
        # Expose node at a stable path — Xcode build phases & non-login shells don't see fnm.
        NODE_REAL="$(node -e 'console.log(require("fs").realpathSync(process.execPath))')"
        sudo mkdir -p /usr/local/bin
        for b in node npm npx; do [ -e "$(dirname "$NODE_REAL")/$b" ] && sudo ln -sf "$(dirname "$NODE_REAL")/$b" "/usr/local/bin/$b"; done
        """
    }

    private static func rubyStep(_ v: String) -> String {
        """
        echo "==> Ruby \(v)"
        rbenv install -s \(v)
        rbenv global \(v)
        gem install bundler --no-document
        """
    }

    private static func warmSimsStep(_ devices: [String]) -> String {
        var lines = ["echo \"==> Warming simulators\""]
        for d in devices {
            lines.append("xcrun simctl boot \"\(d)\"")
            lines.append("xcrun simctl bootstatus \"\(d)\" -b")
        }
        lines.append("xcrun simctl shutdown all")
        return lines.joined(separator: "\n")
    }

    // MARK: Load

    /// Load a recipe from a `.graft` / `.yml` / `.yaml` (YAML) or `.json` file. A file
    /// literally named `Graftfile` is treated as YAML too.
    public static func load(from path: String) throws -> ImageRecipe {
        let expanded = (path as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)) else {
            throw GraftError("can't read image recipe at \(expanded)")
        }
        let ext = (expanded as NSString).pathExtension.lowercased()
        let isYAML = ["graft", "yml", "yaml"].contains(ext)
            || (expanded as NSString).lastPathComponent == "Graftfile"
        do {
            return isYAML
                ? try YAMLDecoder().decode(ImageRecipe.self, from: data)
                : try JSONDecoder().decode(ImageRecipe.self, from: data)
        } catch let error as DecodingError {
            throw GraftError("invalid image recipe at \(expanded): \(error.readableDescription)")
        } catch {
            throw GraftError("invalid image recipe at \(expanded): \(error)")
        }
    }

    /// A starter `.graft` recipe for `graft image template`.
    public static func template() -> String {
        """
        # A .graft image recipe — declarative toolchain, expanded by graft into the right
        # provisioning steps (incl. a stable /usr/local/bin node symlink for Xcode).
        name: rn-detox
        from: ghcr.io/cirruslabs/macos-sequoia-xcode:latest

        node: "20.19.4"          # fnm install + default + corepack + stable symlink
        # ruby: "3.3.5"          # rbenv install + bundler
        npm: [detox-cli]         # npm install -g
        brew: [applesimutils]    # brew install
        xcode-first-launch: true

        # Escape hatch — raw bash for anything not covered (runs last):
        # run: |
        #   echo custom step
        """
    }
}
