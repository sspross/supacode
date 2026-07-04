import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// Runs a repository's `customcode.py` page script. Two stdout contracts:
/// snapshot mode (v0) prints a self-contained HTML document; serve mode (v1)
/// prints a first line `supacode-serve: http://127.0.0.1:<port>/` (loopback
/// http only; later lines reserved) and exits, leaving a detached server it
/// owns — spawning, health-checking, restarting, idle shutdown — running at
/// that URL across our ~30s re-runs. A remote worktree's loopback URL lives
/// on the SSH host, so `RemoteServeForwarder` bridges it here with an
/// `ssh -O forward -L` local forward and the webview loads the rewritten
/// local URL. All panel SSH traffic (presence probe, render handshake,
/// forward) rides the panel's own multiplexed master (`CustomCodeSSH`,
/// `~/.ssh/customcode-%C`) rather than upstream's `supacode-%C`, keeping the
/// fork's upstream-merge surface confined to this feature. Local worktrees
/// run through a login shell; the remote login shell resolves `uv` on the
/// host the same way.
nonisolated struct CustomCodeClient: Sendable {
  var pagePresent: @Sendable (Worktree) async throws -> Bool
  var renderPage: @Sendable (Worktree) async throws -> CustomCodeContent

  static let scriptFileName = "customcode.py"
}

nonisolated enum CustomCodeError: Error, Equatable {
  case uvMissing
  case emptyOutput
  case hostUnreachable(destination: String)
  case scriptFailed(message: String)
  case serveURLInvalid(line: String)
  case serveForwardFailed(destination: String, detail: String)

  var message: String {
    switch self {
    case .uvMissing:
      return "uv is required to run customcode.py but was not found on the PATH."
    case .emptyOutput:
      return "customcode.py finished without printing a page."
    case .hostUnreachable(let destination):
      return "Can't reach \(destination) over SSH."
    case .scriptFailed(let message):
      return message
    case .serveURLInvalid(let line):
      return "customcode.py announced a serve URL that isn't a loopback http URL"
        + " (allowed hosts: 127.0.0.1, localhost, ::1): \(line)"
    case .serveForwardFailed(let destination, let detail):
      return "Couldn't forward the remote page server on \(destination) to this Mac: \(detail)"
    }
  }
}

extension CustomCodeClient {
  static func make(shell: ShellClient, forwarder: RemoteServeForwarder) -> Self {
    Self(
      pagePresent: { worktree in
        switch worktree.location {
        case .local(let workingDirectory, _):
          return FileManager.default.fileExists(
            atPath: workingDirectory.appending(path: scriptFileName).path(percentEncoded: false)
          )
        case .remote(let host, let workingDirectory, _):
          do {
            let (executableURL, arguments) = CustomCodeSSH.invocation(
              host: host,
              executable: "/usr/bin/env",
              arguments: ["test", "-f", scriptFileName],
              workingDirectory: URL(fileURLWithPath: workingDirectory)
            )
            _ = try await shell.run(executableURL, arguments, nil)
            return true
          } catch let error as ShellClientError {
            // `test -f` exits 1 for a missing file; anything else is transport.
            if error.exitCode == 1 { return false }
            throw Self.remoteFailure(host: host, error: error)
          }
        }
      },
      renderPage: { worktree in
        let arguments = ["uv", "run", "--script", scriptFileName]
        let output: ShellOutput
        do {
          switch worktree.location {
          case .local(let workingDirectory, _):
            // Login shell so `uv` installed via the user's profile PATH
            // (~/.local/bin, homebrew, mise) resolves, mirroring GitClient.
            output = try await shell.runLogin(
              URL(fileURLWithPath: "/usr/bin/env"), arguments, workingDirectory
            )
          case .remote(let host, let workingDirectory, _):
            let (executableURL, sshArguments) = CustomCodeSSH.invocation(
              host: host,
              executable: "/usr/bin/env",
              arguments: arguments,
              workingDirectory: URL(fileURLWithPath: workingDirectory)
            )
            output = try await shell.run(executableURL, sshArguments, nil)
          }
        } catch let error as ShellClientError {
          // 127 is the shell's command-not-found exit for a missing `uv`.
          if error.exitCode == 127 {
            throw CustomCodeError.uvMissing
          }
          if let host = worktree.host {
            throw Self.remoteFailure(host: host, error: error)
          }
          throw Self.scriptFailure(error)
        }
        guard !output.stdout.isEmpty else { throw CustomCodeError.emptyOutput }
        let content = try CustomCodeContent.parse(stdout: output.stdout)
        if case .url(let url) = content, let host = worktree.host {
          return .url(try await forwarder.localURL(worktreeID: worktree.id, host: host, remoteURL: url))
        }
        return content
      }
    )
  }

  private nonisolated static func remoteFailure(host: RemoteHost, error: ShellClientError) -> CustomCodeError {
    // ssh exits 255 for transport failures; remote command exits pass through.
    if error.exitCode == 255 {
      return .hostUnreachable(destination: host.sshDestination)
    }
    return scriptFailure(error)
  }

  private nonisolated static func scriptFailure(_ error: ShellClientError) -> CustomCodeError {
    let stderr = error.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    return .scriptFailed(
      message: stderr.isEmpty ? "customcode.py exited with code \(error.exitCode)." : stderr
    )
  }
}

extension CustomCodeClient: DependencyKey {
  static let liveValue = make(shell: .live, forwarder: RemoteServeForwarder())
  static let testValue = Self(
    pagePresent: { _ in false },
    renderPage: { _ in .html("") }
  )
}
