import Foundation
import SupacodeSettingsShared

/// Pure argv builders for the customcode panel's own SSH universe: the
/// presence probe, the ~30s render handshake, and the `-O forward` port
/// bridge all ride one dedicated multiplexed master at
/// `~/.ssh/customcode-%C` — never upstream's `supacode-%C` — so the fork's
/// serve-mode forwards can't perturb (or be torn down by) upstream's git /
/// terminal connection lifecycle, and upstream files stay untouched on
/// merges. Upstream's quoting and option helpers are reused read-only via
/// `SSHCommand`'s public statics.
nonisolated enum CustomCodeSSH {
  /// `%C` is ssh's hash of (local host, remote host, port, user): stable per
  /// connection and short, keeping the socket well under the
  /// `sockaddr_un.sun_path` limit.
  static let controlPath = "~/.ssh/customcode-%C"

  /// Long persist so the forward's master survives idle stretches; the
  /// panel's ~30s renders keep it warm while the panel is open, so `-O
  /// forward` virtually always finds a live master.
  static let controlPersist = "1h"

  /// The panel's multiplexing options — same shape as
  /// `SSHCommand.controlOptions()` but on the panel's own socket.
  static func controlOptions() -> [String] {
    [
      "-o", "ControlMaster=auto",
      "-o", "ControlPath=\(controlPath)",
      "-o", "ControlPersist=\(controlPersist)",
    ]
  }

  /// The panel's replacement for `ShellClient.ssh`: a full ssh argv running
  /// `executable arguments` on `host` under a remote login shell (so `uv`
  /// resolves through the user's profile PATH), non-interactive and
  /// fail-fast, multiplexed on the panel master.
  static func invocation(
    host: RemoteHost,
    executable: String,
    arguments: [String],
    workingDirectory: URL?
  ) -> (executableURL: URL, arguments: [String]) {
    var sshArguments = controlOptions()
    sshArguments += SSHCommand.backgroundProbeOptions
    sshArguments += host.sshOptionArguments
    sshArguments.append(host.sshDestination)
    sshArguments.append(
      SSHCommand.loginShellWrapped(
        SSHCommand.remoteCommand(
          executable: executable,
          arguments: arguments,
          workingDirectory: workingDirectory
        )
      )
    )
    return (URL(fileURLWithPath: SSHCommand.sshExecutablePath), sshArguments)
  }

  /// ssh `-L` forwarding spec: our listener is always IPv4 loopback; the
  /// target is whatever host the remote script announced, bracketed when it
  /// is an IPv6 literal (per ssh's `-L` grammar, a bare `::1` would be
  /// ambiguous with the spec's own colons).
  static func localForwardSpecification(localPort: Int, targetHost: String, targetPort: Int) -> String {
    let target = targetHost.contains(":") ? "[\(targetHost)]" : targetHost
    return "127.0.0.1:\(localPort):\(target):\(targetPort)"
  }

  /// `ssh -O forward` against the panel master: registers the local forward
  /// on the *existing* master and exits. No remote command — `-O` requests
  /// are answered by the control socket. The `-p` / `user@host` tokens must
  /// match the other invocations so `%C` hashes to the same socket.
  static func muxForwardInvocation(
    host: RemoteHost,
    localPort: Int,
    targetHost: String,
    targetPort: Int
  ) -> [String] {
    muxInvocation(
      operation: "forward",
      host: host, localPort: localPort, targetHost: targetHost, targetPort: targetPort
    )
  }

  /// `ssh -O cancel` for the identical spec, so a rekeyed worktree's stale
  /// forward is released instead of leaking until the master dies.
  static func muxCancelForwardInvocation(
    host: RemoteHost,
    localPort: Int,
    targetHost: String,
    targetPort: Int
  ) -> [String] {
    muxInvocation(
      operation: "cancel",
      host: host, localPort: localPort, targetHost: targetHost, targetPort: targetPort
    )
  }

  /// (Re)establishes the panel's control connection after `-O forward` found
  /// no control socket (Mac slept past ControlPersist). `true` is
  /// POSIX-guaranteed on PATH, so no login-shell wrap is needed.
  static func muxProbeInvocation(host: RemoteHost) -> [String] {
    var sshArguments = controlOptions()
    sshArguments += SSHCommand.backgroundProbeOptions
    sshArguments += host.sshOptionArguments
    sshArguments.append(host.sshDestination)
    sshArguments.append("true")
    return sshArguments
  }

  /// Shared assembly so forward and cancel stay in argv lockstep — ssh
  /// matches a cancel to a forward by the exact spec.
  private static func muxInvocation(
    operation: String,
    host: RemoteHost,
    localPort: Int,
    targetHost: String,
    targetPort: Int
  ) -> [String] {
    var sshArguments = controlOptions()
    sshArguments += host.sshOptionArguments
    sshArguments += [
      "-O", operation,
      "-L", localForwardSpecification(localPort: localPort, targetHost: targetHost, targetPort: targetPort),
    ]
    sshArguments.append(host.sshDestination)
    return sshArguments
  }
}
