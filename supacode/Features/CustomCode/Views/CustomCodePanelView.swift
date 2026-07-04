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
      if let content = store.content, store.lastError == nil {
        CustomCodePageView(
          content: content,
          loadRequestID: store.loadRequestID,
          onServeLoadResult: { store.send(.serveLoadResult(url: $0, success: $1)) }
        )
        // Remount per worktree: two worktrees announcing the same port must
        // not share scroll/DOM state, and a cached serve URL should issue a
        // fresh load on reselection.
        .id(store.worktree?.id)
        .overlay {
          if store.serveLoadFailed {
            Text("page server not responding — retrying…")
              .font(.callout)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
              .padding()
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(.thinMaterial)
          }
        }
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
      case .serveURLInvalid:
        return "customcode.py printed a bad serve URL"
      case .serveForwardFailed:
        return "couldn't tunnel to the page server"
      }
    }
    if !store.scriptPresent {
      // Stay blank while the presence check is in flight so a selection
      // switch doesn't flash "not found" before the page comes up.
      return store.isCheckingPresence ? nil : "./customcode.py not found"
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
  /// view it wraps. Visibility is per-repository: the View-menu toggle
  /// (`SidebarCommands`) routes through `panelToggled`, and switching the
  /// selection restores whatever state the repository was left in.
  func customCodeInspector(_ store: StoreOf<CustomCodeFeature>) -> some View {
    modifier(CustomCodeInspectorModifier(store: store))
  }
}

private struct CustomCodeInspectorModifier: ViewModifier {
  let store: StoreOf<CustomCodeFeature>

  func body(content: Content) -> some View {
    // Eager read during body so observation registers on both inputs of the
    // per-repo lookup (selected worktree + shared open-repository set); a
    // read confined to the Binding getter would not register during body,
    // and the inspector would miss View-menu toggles and selection switches.
    let isPanelShown = store.isPanelShown
    // Manual binding instead of `$store...sending` because the flag is
    // derived per-repository (no settable key path for `@Bindable` to
    // project). Writes go through the reducer so close-affordances stay
    // action-driven.
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
