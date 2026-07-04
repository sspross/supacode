import ComposableArchitecture
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct CustomCodeClientTests {
  private static let serveSentinel = "supacode-serve: http://127.0.0.1:3000/"

  @Test func remoteServeRenderForwardsAndReturnsLocalURL() async throws {
    let harness = makeHarness(remoteStdout: Self.serveSentinel)
    let content = try await harness.client.renderPage(makeRemoteWorktree())
    #expect(content == .url(URL(string: "http://127.0.0.1:50123/")!))
    #expect(
      harness.sshCalls.value == [
        CustomCodeSSH.muxForwardInvocation(
          host: RemoteHost(alias: "devbox"), localPort: 50123, targetHost: "127.0.0.1", targetPort: 3000
        )
      ]
    )
  }

  @Test func localServeRenderPassesURLThroughWithoutForwarder() async throws {
    let harness = makeHarness(localStdout: Self.serveSentinel)
    let content = try await harness.client.renderPage(makeLocalWorktree())
    #expect(content == .url(URL(string: "http://127.0.0.1:3000/")!))
    #expect(harness.sshCalls.value.isEmpty)
    #expect(harness.allocatedPorts.value == 0)
  }

  @Test func remoteRenderRidesThePanelControlPath() async throws {
    let harness = makeHarness(remoteStdout: "<html>snapshot</html>")
    let content = try await harness.client.renderPage(makeRemoteWorktree())
    #expect(content == .html("<html>snapshot</html>"))
    let argv = harness.runArgv.value.first ?? []
    #expect(argv.first == "/usr/bin/ssh")
    #expect(argv.contains("ControlPath=~/.ssh/customcode-%C"))
    #expect(!argv.contains("ControlPath=~/.ssh/supacode-%C"))
  }

  private struct Harness {
    let client: CustomCodeClient
    let runArgv: LockIsolated<[[String]]>
    let sshCalls: LockIsolated<[[String]]>
    let allocatedPorts: LockIsolated<Int>
  }

  private func makeHarness(
    remoteStdout: String = "",
    localStdout: String = ""
  ) -> Harness {
    let runArgv = LockIsolated<[[String]]>([])
    let sshCalls = LockIsolated<[[String]]>([])
    let allocatedPorts = LockIsolated(0)
    let shell = ShellClient(
      run: { executableURL, arguments, _ in
        runArgv.withValue { $0.append([executableURL.path(percentEncoded: false)] + arguments) }
        return ShellOutput(stdout: remoteStdout, stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in
        ShellOutput(stdout: localStdout, stderr: "", exitCode: 0)
      }
    )
    let forwarder = RemoteServeForwarder(
      runSSH: { arguments in sshCalls.withValue { $0.append(arguments) } },
      allocatePort: {
        allocatedPorts.withValue { $0 += 1 }
        return 50123
      },
      canConnect: { _ in false }
    )
    return Harness(
      client: CustomCodeClient.make(shell: shell, forwarder: forwarder),
      runArgv: runArgv,
      sshCalls: sshCalls,
      allocatedPorts: allocatedPorts
    )
  }

  private func makeLocalWorktree() -> Worktree {
    Worktree(
      id: WorktreeID("/tmp/repo/wt"),
      name: "wt",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  private func makeRemoteWorktree() -> Worktree {
    Worktree(
      location: .remote(
        RemoteHost(alias: "devbox"),
        workingDirectory: "/home/me/wt",
        repositoryRoot: "/home/me/repo"
      ),
      kind: .git,
      name: "wt",
      detail: "detail"
    )
  }
}
