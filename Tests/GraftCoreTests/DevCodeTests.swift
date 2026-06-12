import Testing
@testable import GraftCore

@Suite("DevCode ssh-config")
struct DevCodeTests {
    @Test("stripBlock removes only the matching alias block, leaving others")
    func stripsOneBlock() {
        let text = """
        # >>> graft graft-dev-a
        Host graft-dev-a
          HostName 10.0.0.1
        # <<< graft graft-dev-a

        # >>> graft graft-dev-b
        Host graft-dev-b
          HostName 10.0.0.2
        # <<< graft graft-dev-b
        """
        let out = DevCode.stripBlock(text, alias: "graft-dev-a")
        #expect(!out.contains("graft-dev-a"))
        #expect(out.contains("Host graft-dev-b"))
        #expect(out.contains("10.0.0.2"))
    }

    @Test("stripBlock is a no-op when the alias isn't present")
    func noopWhenAbsent() {
        let text = "Host other\n  HostName 1.2.3.4"
        #expect(DevCode.stripBlock(text, alias: "graft-dev-x") == text)
    }

    @Test("expandRepoSpec: everything → HTTPS .git URL + short name")
    func expandsRepoSpec() {
        let a = DevCode.expandRepoSpec("your-org/app")
        #expect(a.url == "https://github.com/your-org/app.git")
        #expect(a.name == "app")

        let b = DevCode.expandRepoSpec("git@github.com:foo/bar.git")
        #expect(b.url == "https://github.com/foo/bar.git")     // SSH spec normalized to HTTPS
        #expect(b.name == "bar")

        let c = DevCode.expandRepoSpec("https://gitlab.com/team/svc.git")
        #expect(c.url == "https://gitlab.com/team/svc.git")
        #expect(c.name == "svc")

        let d = DevCode.expandRepoSpec("https://github.com/octocat/Hello-World")
        #expect(d.url == "https://github.com/octocat/Hello-World.git")
        #expect(d.name == "Hello-World")
    }
}
