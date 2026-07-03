import ComposableArchitecture
import SwiftUI

/// The right-hand project-status inspector content: the rendered
/// customcode.py page for the selected worktree, full-bleed, with a single
/// short centered status line for the missing / error states and a
/// refresh-or-spinner control floating bottom-trailing.
struct CustomCodePanelView: View {
  let store: StoreOf<CustomCodeFeature>

  var body: some View {
    ZStack {
      if let html = store.html, store.lastError == nil {
        HTMLPageView(html: html)
      } else if let message = statusMessage {
        Text(message)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding()
          .help(statusDetail)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // The inspector reserves a toolbar-height strip at the top; the page
    // should own the full column, edge to edge.
    .ignoresSafeArea(edges: .top)
    .overlay(alignment: .bottomLeading) { refreshControl }
    .onAppear { store.send(.panelAppeared) }
  }

  /// One short line; the tooltip carries the full detail.
  private var statusMessage: String? {
    if let error = store.lastError {
      switch error {
      case .uvMissing:
        return "uv not installed"
      case .hostUnreachable(let destination):
        return "can't reach \(destination)"
      case .emptyOutput:
        return "customcode.py printed nothing"
      case .scriptFailed:
        return "customcode.py failed"
      }
    }
    if !store.scriptPresent {
      return "./customcode.py not found"
    }
    return nil
  }

  private var statusDetail: String {
    if let error = store.lastError {
      return error.message
    }
    return "Add a customcode.py script to the worktree root to render a project status page here."
  }

  @ViewBuilder
  private var refreshControl: some View {
    Group {
      if store.isRendering {
        ProgressView()
          .controlSize(.small)
      } else {
        Button {
          store.send(.refreshRequested)
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help("Re-run customcode.py and refresh the status page")
        .disabled(store.worktree == nil)
      }
    }
    .padding(8)
  }
}

extension View {
  /// Attaches the customcode.py status panel as a trailing inspector. Lives in
  /// its own modifier so panel-state observation doesn't re-render the detail
  /// view it wraps. Toggled from the View menu (`SidebarCommands`), which
  /// writes `@Shared(.customCodePanelShown)` directly.
  func customCodeInspector(_ store: StoreOf<CustomCodeFeature>) -> some View {
    modifier(CustomCodeInspectorModifier(store: store))
  }
}

private struct CustomCodeInspectorModifier: ViewModifier {
  let store: StoreOf<CustomCodeFeature>
  // Read through the shared key (not the store) so this view provably
  // re-evaluates when the View-menu command flips the flag from outside the
  // reducer; a value captured only inside the Binding getter would not
  // register observation during body.
  @Shared(.customCodePanelShown) private var isPanelShown: Bool

  func body(content: Content) -> some View {
    // Manual binding instead of `$store...sending` because `isPanelShown` is
    // `@Shared`-backed (no settable key path for `@Bindable` to project).
    // Writes go through the reducer so close-affordances stay action-driven.
    let isPresented = Binding(
      get: { isPanelShown },
      set: { store.send(.setPanelShown($0)) }
    )
    return
      content
      .inspector(isPresented: isPresented) {
        CustomCodePanelView(store: store)
          .inspectorColumnWidth(min: 220, ideal: 280, max: 400)
      }
  }
}
