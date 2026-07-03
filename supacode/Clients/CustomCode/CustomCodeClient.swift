import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// Runs a repository's `customcode.py` status-page script (snapshot-mode
/// contract: the script prints a self-contained HTML document to stdout).
/// Local worktrees run through a login shell; remote worktrees run over the
/// multiplexed SSH transport, whose remote login shell resolves `uv` on the
/// host the same way.
nonisolated struct CustomCodeClient: Sendable {
  var pagePresent: @Sendable (Worktree) async throws -> Bool
  var renderPage: @Sendable (Worktree) async throws -> String

  static let scriptFileName = "customcode.py"
}

nonisolated enum CustomCodeError: Error, Equatable {
  case uvMissing
  case emptyOutput
  case hostUnreachable(destination: String)
  case scriptFailed(message: String)

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
    }
  }
}

extension CustomCodeClient {
  static func make(shell: ShellClient) -> Self {
    Self(
      pagePresent: { worktree in
        switch worktree.location {
        case .local(let workingDirectory, _):
          return FileManager.default.fileExists(
            atPath: workingDirectory.appending(path: scriptFileName).path(percentEncoded: false)
          )
        case .remote(let host, let workingDirectory, _):
          do {
            _ = try await Self.sshShell(host: host, base: shell).run(
              URL(fileURLWithPath: "/usr/bin/env"),
              ["test", "-f", scriptFileName],
              URL(fileURLWithPath: workingDirectory)
            )
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
            output = try await Self.sshShell(host: host, base: shell).run(
              URL(fileURLWithPath: "/usr/bin/env"), arguments, URL(fileURLWithPath: workingDirectory)
            )
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
        return output.stdout
      }
    )
  }

  /// Non-interactive SSH profile: shares the app's multiplexed connection and
  /// fails fast (BatchMode, 10s connect timeout) instead of hanging on prompts.
  private nonisolated static func sshShell(host: RemoteHost, base: ShellClient) -> ShellClient {
    .ssh(host: host, base: base, extraOptions: SSHCommand.backgroundProbeOptions)
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
  static let liveValue = make(shell: .live)
  static let testValue = Self(
    pagePresent: { _ in false },
    renderPage: { _ in "" }
  )
}
