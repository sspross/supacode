import AppKit
import SwiftUI
import WebKit

/// Renders a self-contained HTML string (the customcode.py page contract:
/// inline CSS, no external resources). Navigation stays locked to the loaded
/// document; activated links open in the default browser instead.
struct HTMLPageView: NSViewRepresentable {
  let html: String

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> WKWebView {
    let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    webView.navigationDelegate = context.coordinator
    // Suppress WebKit's opaque default background so the page's own
    // prefers-color-scheme surface paints without a white flash in dark mode.
    webView.setValue(false, forKey: "drawsBackground")
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    guard context.coordinator.loadedHTML != html else { return }
    context.coordinator.loadedHTML = html
    webView.loadHTMLString(html, baseURL: nil)
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate {
    var loadedHTML: String?

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
        return
      }
      decisionHandler(.allow)
    }
  }
}
