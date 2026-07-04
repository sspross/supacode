import Foundation
import Testing

@testable import supacode

/// The customcode.py stdout contract: snapshot HTML passes through verbatim;
/// the serve-mode sentinel must carry a loopback http URL.
struct CustomCodeContentTests {
  @Test func plainHTMLPassesThroughVerbatim() throws {
    let stdout = "  <!doctype html>\n<html>ok</html>\n"
    #expect(try CustomCodeContent.parse(stdout: stdout) == .html(stdout))
  }

  @Test func sentinelOnASecondLineIsStillHTML() throws {
    let stdout = "<html>supacode docs</html>\nsupacode-serve: http://127.0.0.1:1/"
    #expect(try CustomCodeContent.parse(stdout: stdout) == .html(stdout))
  }

  @Test(arguments: [
    "http://127.0.0.1:8123/",
    "http://127.0.0.1/",
    "http://localhost:9000/",
    "http://LOCALHOST:9000/",
    "http://[::1]:8080/",
  ])
  func acceptsLoopbackHTTPURLs(_ text: String) throws {
    let content = try CustomCodeContent.parse(stdout: "supacode-serve: \(text)\n")
    #expect(content == .url(URL(string: text)!))
  }

  @Test func trailingLinesAfterTheSentinelAreIgnored() throws {
    let stdout = "supacode-serve: http://127.0.0.1:8123/\nreserved\nfor later\n"
    #expect(try CustomCodeContent.parse(stdout: stdout) == .url(URL(string: "http://127.0.0.1:8123/")!))
  }

  @Test func surroundingWhitespaceIsTolerated() throws {
    let stdout = "\n\nsupacode-serve: http://127.0.0.1:8123/   \n"
    #expect(try CustomCodeContent.parse(stdout: stdout) == .url(URL(string: "http://127.0.0.1:8123/")!))
  }

  @Test(arguments: [
    "https://127.0.0.1:8123/",  // https is pointless on loopback; keep the contract narrow
    "http://0.0.0.0:8000/",
    "http://192.168.1.5:80/",
    "http://127.0.0.2/",  // only the canonical loopback literal is allowed
    "http://example.com/",
    "ftp://127.0.0.1/",
    "not a url at all",
  ])
  func rejectsNonLoopbackServeURLs(_ text: String) {
    #expect(throws: CustomCodeError.self) {
      try CustomCodeContent.parse(stdout: "supacode-serve: \(text)")
    }
  }
}
