import Foundation
import Testing
@testable import GraftCore

@Suite("Image recipe")
struct ImageRecipeTests {
    @Test("decodes a minimal recipe with defaults")
    func minimal() throws {
        let json = #"{"name":"rn-detox","from":"base:latest","run":["a","b"]}"#
        let r = try JSONDecoder().decode(ImageRecipe.self, from: Data(json.utf8))
        #expect(r.name == "rn-detox")
        #expect(r.from == "base:latest")
        #expect(r.run == ["a", "b"])
        #expect(r.mounts == nil)
        #expect(r.guestOS == .macOS)        // default when os omitted
    }

    @Test("decodes os + mounts")
    func full() throws {
        let json = #"{"name":"x","from":"b","run":[],"os":"linux","mounts":[{"name":"repo","source":"/x","readOnly":true}]}"#
        let r = try JSONDecoder().decode(ImageRecipe.self, from: Data(json.utf8))
        #expect(r.guestOS == .linux)
        #expect(r.mounts?.first == Mount(name: "repo", source: "/x", readOnly: true))
    }

    @Test("loads a YAML recipe with a run: block scalar as one inline script")
    func loadYAML() throws {
        let yaml = """
        name: rn-detox
        from: base:latest
        run: |
          set -euo pipefail
          echo step1
          echo step2
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("recipe.yml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let r = try ImageRecipe.load(from: file.path)
        #expect(r.name == "rn-detox")
        #expect(r.from == "base:latest")
        #expect(r.run.count == 1)                       // block scalar → one script string
        #expect(r.run[0].contains("echo step1"))
        #expect(r.run[0].contains("echo step2"))
    }

    @Test("compiles declarative toolchain fields into provisioning steps")
    func compile() throws {
        let r = ImageRecipe(
            name: "x", from: "b",
            node: "20.19.4", ruby: "3.4.3", brew: ["watchman"], npm: ["detox-cli"],
            xcodeFirstLaunch: true, warmSimulators: ["iPhone 17 Pro"]
        )
        let p = try #require(r.provisioning(scriptBody: nil))
        #expect(p.contains("set -eo pipefail"))
        #expect(p.contains("fnm install 20.19.4"))
        #expect(p.contains("/usr/local/bin"))                 // the node-symlink best practice
        #expect(p.contains("rbenv install -s 3.4.3"))
        #expect(p.contains("gem install bundler"))
        #expect(p.contains("brew install watchman"))
        #expect(p.contains("npm install -g detox-cli"))
        #expect(p.contains("xcodebuild -runFirstLaunch"))
        #expect(p.contains("simctl boot \"iPhone 17 Pro\""))
        // node before ruby before xcode (toolchain ordering)
        #expect(p.range(of: "fnm install")!.lowerBound < p.range(of: "rbenv install")!.lowerBound)
    }

    @Test("compiled steps come before script + run, and run appends after")
    func order() throws {
        let r = ImageRecipe(name: "x", from: "b", node: "20", run: ["echo custom"])
        let p = try #require(r.provisioning(scriptBody: "echo from-script"))
        #expect(p.range(of: "fnm install")!.lowerBound < p.range(of: "echo from-script")!.lowerBound)
        #expect(p.range(of: "echo from-script")!.lowerBound < p.range(of: "echo custom")!.lowerBound)
    }

    @Test("loads a .graft file; tolerates a bare-int version")
    func loadGraft() throws {
        let graft = """
        name: g1
        from: base:latest
        node: 20
        ruby: 3.4.3
        xcode-first-launch: true
        warm-simulators: ["iPhone 17 Pro"]
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("image.graft")
        try graft.write(to: file, atomically: true, encoding: .utf8)

        let r = try ImageRecipe.load(from: file.path)
        #expect(r.node == "20")                  // bare int coerced to string
        #expect(r.ruby == "3.4.3")
        #expect(r.xcodeFirstLaunch == true)
        #expect(r.warmSimulators == ["iPhone 17 Pro"])
    }

    @Test("the starter template is valid YAML that loads")
    func template() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("template.yml")
        try ImageRecipe.template().write(to: file, atomically: true, encoding: .utf8)

        let r = try ImageRecipe.load(from: file.path)
        #expect(!r.name.isEmpty)
        #expect(!r.from.isEmpty)
        #expect(r.node != nil)                          // template showcases declarative fields
        #expect(r.provisioning(scriptBody: nil) != nil) // and compiles to something runnable
    }
}
