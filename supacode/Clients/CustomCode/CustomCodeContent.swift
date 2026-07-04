import Foundation

/// What customcode.py's stdout resolved to: a self-contained HTML document
/// (snapshot mode, v0) or a local server URL announced via the serve-mode
/// sentinel (v1). Parsing lives here so the stdout contract has one home.
nonisolated enum CustomCodeContent: Equatable, Sendable {
  case html(String)
  case url(URL)

  /// First-line marker announcing serve mode:
  /// `supacode-serve: http://127.0.0.1:<port>/`. Lines after the first are
  /// reserved and ignored.
  static let serveSentinelPrefix = "supacode-serve: "

  private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

  /// Splits the two contract modes apart. Output without the sentinel is
  /// snapshot HTML, passed through byte-for-byte (trimming is only used for
  /// sentinel detection). A sentinel followed by anything but a loopback
  /// http URL is a script error, not a page.
  static func parse(stdout: String) throws -> CustomCodeContent {
    let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let firstLine = trimmed.prefix(while: { !$0.isNewline })
    guard firstLine.hasPrefix(serveSentinelPrefix) else { return .html(stdout) }
    let urlText = firstLine.dropFirst(serveSentinelPrefix.count)
      .trimmingCharacters(in: .whitespaces)
    guard
      !urlText.isEmpty,
      let url = URL(string: urlText),
      url.scheme?.lowercased() == "http",
      let host = url.host()?.lowercased(),
      loopbackHosts.contains(host)
    else {
      throw CustomCodeError.serveURLInvalid(line: String(firstLine))
    }
    return .url(url)
  }
}
