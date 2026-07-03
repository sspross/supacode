import ComposableArchitecture
import SwiftUI

/// The right-hand project-status inspector content: the rendered
/// customcode.py page for the selected worktree, with loading / error /
/// missing-script states.
struct CustomCodePanelView: View {
  let store: StoreOf<CustomCodeFeature>

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
    }
    .onAppear { store.send(.panelAppeared) }
  }

  private var header: some View {
    HStack {
      Text("Project Status")
        .font(.subheadline.weight(.semibold))
      Spacer()
      if store.isRendering {
        ProgressView()
          .controlSize(.small)
      }
      Button {
        store.send(.refreshRequested)
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
          .labelStyle(.iconOnly)
      }
      .buttonStyle(.borderless)
      .help("Re-run customcode.py and refresh the status page")
      .disabled(!store.scriptPresent)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  @ViewBuilder
  private var content: some View {
    if let errorMessage = store.errorMessage {
      ContentUnavailableView {
        Label("Script Failed", systemImage: "exclamationmark.triangle")
      } description: {
        Text(errorMessage)
          .monospaced()
      } actions: {
        Button("Retry") {
          store.send(.refreshRequested)
        }
        .help("Re-run customcode.py")
      }
    } else if let html = store.html {
      HTMLPageView(html: html)
    } else if store.scriptPresent {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ContentUnavailableView {
        Label("No Status Page", systemImage: "doc.text.magnifyingglass")
      } description: {
        Text("Add a customcode.py script to the worktree root to render a project status page here.")
      }
    }
  }
}

extension View {
  /// Attaches the customcode.py status panel as a trailing inspector plus its
  /// toolbar toggle. Lives in its own modifier so panel-state observation
  /// doesn't re-render the detail view it wraps.
  func customCodeInspector(_ store: StoreOf<CustomCodeFeature>) -> some View {
    modifier(CustomCodeInspectorModifier(store: store))
  }
}

private struct CustomCodeInspectorModifier: ViewModifier {
  let store: StoreOf<CustomCodeFeature>

  func body(content: Content) -> some View {
    // Manual binding instead of `$store...sending` because `isPanelShown` is
    // `@Shared`-backed (no settable key path for `@Bindable` to project).
    let isPresented = Binding(
      get: { store.isPanelShown },
      set: { store.send(.setPanelShown($0)) }
    )
    return
      content
      .inspector(isPresented: isPresented) {
        CustomCodePanelView(store: store)
          .inspectorColumnWidth(min: 220, ideal: 280, max: 400)
      }
      .toolbar {
        ToolbarItem {
          Button {
            store.send(.setPanelShown(!store.isPanelShown))
          } label: {
            Label("Project Status", systemImage: "sidebar.trailing")
          }
          .help(
            store.isPanelShown
              ? "Hide the project status panel"
              : "Show the project status panel rendered by customcode.py"
          )
        }
      }
  }
}
