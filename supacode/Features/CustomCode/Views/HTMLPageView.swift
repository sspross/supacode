import AppKit
import SwiftUI
import WebKit

/// Renders a self-contained HTML string (the customcode.py page contract:
/// inline CSS, no external resources). Navigation stays locked to the loaded
/// document; link clicks — plain or `target="_blank"` — open in the default
/// browser, restricted to http/https because the HTML is repo-authored.
struct HTMLPageView: NSViewRepresentable {
  let html: String

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> WKWebView {
    let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    webView.navigationDelegate = context.coordinator
    webView.uiDelegate = context.coordinator
    // Suppress WebKit's opaque canvas: the page declares a transparent
    // background so the sidebar material should show through.
    webView.setValue(false, forKey: "drawsBackground")
    webView.underPageBackgroundColor = .clear
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    guard context.coordinator.loadedHTML != html else { return }
    context.coordinator.loadedHTML = html
    webView.loadHTMLString(html, baseURL: nil)
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    var loadedHTML: String?

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      if navigationAction.navigationType == .linkActivated {
        Self.openInBrowser(navigationAction.request.url)
        decisionHandler(.cancel)
        return
      }
      decisionHandler(.allow)
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

    private static func openInBrowser(_ url: URL?) {
      guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
      NSWorkspace.shared.open(url)
    }
  }
}
