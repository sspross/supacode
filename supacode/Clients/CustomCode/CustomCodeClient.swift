import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// Runs a repository's `customcode.py` status-page script (snapshot-mode
/// contract: the script prints a self-contained HTML document to stdout).
nonisolated struct CustomCodeClient: Sendable {
  var pagePresent: @Sendable (_ worktreeDirectory: URL) -> Bool
  var renderPage: @Sendable (_ worktreeDirectory: URL) async throws -> String

  static let scriptFileName = "customcode.py"
}

nonisolated enum CustomCodeError: Error, Equatable {
  case uvMissing
  case emptyOutput
  case scriptFailed(message: String)

  var message: String {
    switch self {
    case .uvMissing:
      return "uv is required to run customcode.py but was not found on your PATH."
    case .emptyOutput:
      return "customcode.py finished without printing a page."
    case .scriptFailed(let message):
      return message
    }
  }
}

extension CustomCodeClient {
  /// The script runs through a login shell so `uv` installed via the user's
  /// profile PATH (~/.local/bin, homebrew, mise) resolves, mirroring GitClient.
  static func make(shell: ShellClient) -> Self {
    Self(
      pagePresent: { directory in
        FileManager.default.fileExists(
          atPath: directory.appending(path: scriptFileName).path(percentEncoded: false)
        )
      },
      renderPage: { directory in
        let output: ShellOutput
        do {
          output = try await shell.runLogin(
            URL(fileURLWithPath: "/usr/bin/env"),
            ["uv", "run", "--script", scriptFileName],
            directory
          )
        } catch let error as ShellClientError {
          // 127 is the shell's command-not-found exit for a missing `uv`.
          if error.exitCode == 127 {
            throw CustomCodeError.uvMissing
          }
          let stderr = error.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
          throw CustomCodeError.scriptFailed(
            message: stderr.isEmpty ? "customcode.py exited with code \(error.exitCode)." : stderr
          )
        }
        guard !output.stdout.isEmpty else { throw CustomCodeError.emptyOutput }
        return output.stdout
      }
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
