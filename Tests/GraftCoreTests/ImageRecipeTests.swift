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

    @Test("the starter template is valid and decodes")
    func template() throws {
        let r = try JSONDecoder().decode(ImageRecipe.self, from: Data(ImageRecipe.template().utf8))
        #expect(!r.name.isEmpty)
        #expect(!r.from.isEmpty)
    }
}
