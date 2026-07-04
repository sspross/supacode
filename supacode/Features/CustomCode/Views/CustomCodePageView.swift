import AppKit
import SwiftUI
import WebKit

/// Renders customcode.py output. Snapshot mode loads the HTML string with a
/// nil baseURL (opaque origin: no storage, relative URLs dead); serve mode
/// loads the announced loopback URL, giving the page a real http origin so
/// fetch and storage work. Serve-mode loads are gated on (url, loadRequestID)
/// so periodic re-renders never reset the web app's state. Link clicks open
/// in the default browser — except serve-mode clicks that stay on the served
/// origin, which navigate in place — restricted to http/https because the
/// content is repo-authored.
struct CustomCodePageView: NSViewRepresentable {
  let content: CustomCodeContent
  let loadRequestID: Int
  let onServeLoadResult: @MainActor (URL, Bool) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> WKWebView {
    let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    webView.navigationDelegate = context.coordinator
    webView.uiDelegate = context.coordinator
    // Suppress WebKit's opaque canvas: the page declares a transparent
    // background so the sidebar material should show through.
    webView.setValue(false, forKey: "drawsBackground")
    webView.underPageBackgroundColor = .clear
    context.coordinator.onServeLoadResult = onServeLoadResult
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    context.coordinator.onServeLoadResult = onServeLoadResult
    switch content {
    case .html(let html):
      guard context.coordinator.loadedHTML != html else { return }
      context.coordinator.loadedHTML = html
      context.coordinator.servedURL = nil
      webView.loadHTMLString(html, baseURL: nil)
    case .url(let url):
      guard
        context.coordinator.servedURL != url
          || context.coordinator.loadedRequestID != loadRequestID
      else { return }
      context.coordinator.servedURL = url
      context.coordinator.loadedRequestID = loadRequestID
      context.coordinator.loadedHTML = nil
      webView.load(URLRequest(url: url))
    }
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    var loadedHTML: String?
    /// Set iff the webview is in serve mode; nil means snapshot behavior.
    var servedURL: URL?
    var loadedRequestID = -1
    var onServeLoadResult: (@MainActor (URL, Bool) -> Void)?

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      if navigationAction.navigationType == .linkActivated {
        if let servedURL,
          let target = navigationAction.request.url,
          Self.sameOrigin(target, servedURL)
        {
          decisionHandler(.allow)  // in-app navigation within the served app
          return
        }
        Self.openInBrowser(navigationAction.request.url)
        decisionHandler(.cancel)
        return
      }
      decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      if let servedURL {
        onServeLoadResult?(servedURL, true)
      }
    }

    func webView(
      _ webView: WKWebView,
      didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      reportFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      reportFailure(error)
    }

    /// Connection-refused (the page server died) arrives here as
    /// `didFailProvisionalNavigation`; a load superseded by a newer one fails
    /// with NSURLErrorCancelled, which is not a server-down signal.
    private func reportFailure(_ error: Error) {
      guard (error as NSError).code != NSURLErrorCancelled else { return }
      if let servedURL {
        onServeLoadResult?(servedURL, false)
      }
    }

    /// `target="_blank"` links request a new webview instead of a navigation;
    /// returning nil discards the popup after handing the URL to the browser.
    func webView(
      _ webView: WKWebView,
      createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction,
      windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
      Self.openInBrowser(navigationAction.request.url)
      return nil
    }

    /// Browser-style origin equality: scheme + host + effective port, all
    /// literal — `localhost` and `127.0.0.1` are distinct origins on purpose.
    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
      func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
      }
      return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
        && lhs.host()?.lowercased() == rhs.host()?.lowercased()
        && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func openInBrowser(_ url: URL?) {
      guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
      NSWorkspace.shared.open(url)
    }
  }
}
