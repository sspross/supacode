import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct CustomCodeSSHTests {
  private let panelControlOptions: [String] = [
    "-o", "ControlMaster=auto",
    "-o", "ControlPath=~/.ssh/customcode-%C",
    "-o", "ControlPersist=1h",
  ]

  @Test func forwardInvocationHasNoRemoteCommandAndDestinationLast() {
    let arguments = CustomCodeSSH.muxForwardInvocation(
      host: RemoteHost(alias: "devbox"),
      localPort: 50123,
      targetHost: "127.0.0.1",
      targetPort: 3000
    )
    #expect(
      arguments == panelControlOptions + [
        "-O", "forward",
        "-L", "127.0.0.1:50123:127.0.0.1:3000",
        "devbox",
      ]
    )
  }

  @Test func forwardInvocationCarriesUserAndPortTokensForControlPathHash() {
    // `%C` hashes (local host, remote host, port, user): the `-O` invocation
    // must present the same `-p` / `user@host` tokens as the render
    // invocations or it would resolve a different socket.
    let arguments = CustomCodeSSH.muxForwardInvocation(
      host: RemoteHost(alias: "box", username: "alice", port: 2222),
      localPort: 50123,
      targetHost: "127.0.0.1",
      targetPort: 3000
    )
    #expect(
      arguments == panelControlOptions + [
        "-p", "2222",
        "-O", "forward",
        "-L", "127.0.0.1:50123:127.0.0.1:3000",
        "alice@box",
      ]
    )
  }

  @Test func forwardSpecificationBracketsIPv6TargetHost() {
    #expect(
      CustomCodeSSH.localForwardSpecification(localPort: 50123, targetHost: "::1", targetPort: 3000)
        == "127.0.0.1:50123:[::1]:3000"
    )
    #expect(
      CustomCodeSSH.localForwardSpecification(localPort: 50123, targetHost: "localhost", targetPort: 80)
        == "127.0.0.1:50123:localhost:80"
    )
  }

  @Test func cancelInvocationUsesIdenticalSpecification() {
    let forward = CustomCodeSSH.muxForwardInvocation(
      host: RemoteHost(alias: "devbox"), localPort: 50123, targetHost: "::1", targetPort: 3000
    )
    let cancel = CustomCodeSSH.muxCancelForwardInvocation(
      host: RemoteHost(alias: "devbox"), localPort: 50123, targetHost: "::1", targetPort: 3000
    )
    // ssh matches a cancel to a forward by exact spec; only the operation differs.
    #expect(cancel == forward.map { $0 == "forward" ? "cancel" : $0 })
    #expect(cancel.contains("cancel"))
    #expect(!cancel.contains("forward"))
  }

  @Test func muxProbeRunsBareTrueUnderProbeOptions() {
    let arguments = CustomCodeSSH.muxProbeInvocation(
      host: RemoteHost(alias: "box", username: "alice", port: 2222)
    )
    #expect(
      arguments == panelControlOptions + SSHCommand.backgroundProbeOptions + [
        "-p", "2222",
        "alice@box",
        "true",
      ]
    )
  }

  @Test func invocationWrapsRemoteCommandInLoginShellOnPanelSocket() {
    let result = CustomCodeSSH.invocation(
      host: RemoteHost(alias: "devbox"),
      executable: "/usr/bin/env",
      arguments: ["uv", "run", "--script", "customcode.py"],
      workingDirectory: URL(fileURLWithPath: "/home/me/wt")
    )
    #expect(result.executableURL == URL(fileURLWithPath: "/usr/bin/ssh"))
    let expectedScript = SSHCommand.remoteCommand(
      executable: "/usr/bin/env",
      arguments: ["uv", "run", "--script", "customcode.py"],
      workingDirectory: URL(fileURLWithPath: "/home/me/wt")
    )
    #expect(
      result.arguments == panelControlOptions + SSHCommand.backgroundProbeOptions + [
        "devbox",
        SSHCommand.loginShellWrapped(expectedScript),
      ]
    )
    // The remote command rides the login shell with a `cd --` into the worktree.
    #expect(result.arguments.last?.hasPrefix("exec \"$SHELL\" -l -c ") == true)
    #expect(result.arguments.last?.contains("cd -- ") == true)
    // The panel's own socket, never upstream's.
    #expect(result.arguments.contains("ControlPath=~/.ssh/customcode-%C"))
    #expect(!result.arguments.contains("ControlPath=~/.ssh/supacode-%C"))
  }
}
