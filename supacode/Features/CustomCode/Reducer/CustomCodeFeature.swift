import ComposableArchitecture
import Foundation
import Sharing
import SupacodeSettingsShared

nonisolated extension SharedReaderKey where Self == FileStorageKey<Set<RepositoryID>>.Default {
  /// Repositories whose project-status panel was left open. Visibility is
  /// per-repository so each repo restores its own open/closed state when the
  /// selection moves between them; persisted so the layout survives relaunch.
  static var customCodePanelOpenRepositoryIDs: Self {
    Self[
      .fileStorage(
        SupacodePaths.baseDirectory.appending(
          path: "customcode-panel.json",
          directoryHint: .notDirectory
        )
      ),
      default: []
    ]
  }
}

/// Drives the right-hand project-status inspector: tracks whether the selected
/// worktree carries a `customcode.py` page script and renders its output
/// through `CustomCodeClient` whenever the panel is visible. Snapshot pages
/// re-render in place; serve-mode URLs reload only when the URL changes, the
/// user explicitly refreshes, or the previous load failed — never on the
/// periodic same-URL tick, so the web app's in-page state survives. Local and
/// remote (SSH) worktrees are both supported; the client owns the transport
/// split.
@Reducer
struct CustomCodeFeature {
  @ObservableState
  struct State: Equatable {
    @Shared(.customCodePanelOpenRepositoryIDs) var openPanelRepositoryIDs: Set<RepositoryID>
    var worktree: Worktree?
    var scriptPresent = false
    var isCheckingPresence = false
    var isRendering = false
    var content: CustomCodeContent?
    var lastError: CustomCodeError?
    /// Session cache of the last rendered page per worktree (snapshot HTML or
    /// serve URL). Served immediately on re-selection so switching worktrees
    /// shows the previous page instead of flashing the empty state while the
    /// fresh render runs.
    var contentByWorktreeID: [WorktreeID: CustomCodeContent] = [:]
    /// Bumped whenever the webview should (re)issue a load of the current
    /// serve URL. The view loads iff (url, loadRequestID) differs from what
    /// its coordinator last loaded — never on mere SwiftUI updates.
    var loadRequestID = 0
    /// The webview reported that loading the current serve URL failed
    /// (server down). Cleared only by a confirmed successful load.
    var serveLoadFailed = false
    /// Set by refreshRequested so the next render reloads even when the
    /// serve URL is unchanged.
    var forceReloadOnNextRender = false

    var repositoryID: RepositoryID? { worktree?.location.repositoryLocation.id }

    var isPanelShown: Bool {
      guard let repositoryID else { return false }
      return openPanelRepositoryIDs.contains(repositoryID)
    }
  }

  enum Action: Equatable {
    case selectionChanged(Worktree?)
    case filesChanged(Worktree.ID)
    case panelAppeared
    case refreshRequested
    case setPanelShown(Bool)
    case panelToggled
    case presenceResolved(worktreeID: Worktree.ID, result: Result<Bool, CustomCodeError>)
    case renderCompleted(worktreeID: Worktree.ID, result: Result<CustomCodeContent, CustomCodeError>)
    case serveLoadResult(url: URL, success: Bool)
  }

  @Dependency(CustomCodeClient.self) private var customCodeClient

  private nonisolated enum CancelID: Hashable, Sendable { case render }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .selectionChanged(let worktree):
        guard let worktree else {
          guard state.worktree != nil else { return .none }
          state.clearPage()
          state.worktree = nil
          return .cancel(id: CancelID.render)
        }
        guard worktree != state.worktree else { return .none }
        state.clearPage()
        state.worktree = worktree
        // Serve the cached page immediately so the switch doesn't flash the
        // missing-script state; the presence check below re-renders (or
        // clears) it in the background.
        if let cached = state.contentByWorktreeID[worktree.id] {
          state.content = cached
          state.scriptPresent = true
        }
        return .merge(
          .cancel(id: CancelID.render),
          checkPresence(worktree: worktree, state: &state)
        )

      case .filesChanged(let worktreeID):
        // Re-check presence, not just re-render: a branch switch can add or
        // remove customcode.py itself.
        guard let worktree = state.worktree, worktree.id == worktreeID else { return .none }
        return checkPresence(worktree: worktree, state: &state)

      case .panelAppeared:
        guard let worktree = state.worktree else { return .none }
        // Switching to a repository whose panel was left open mounts the view
        // while the selection-change presence check is still in flight; that
        // check's resolution renders now that the panel is visible, so a
        // second one here would only run customcode.py twice.
        guard !state.isCheckingPresence else { return .none }
        return checkPresence(worktree: worktree, state: &state)

      case .refreshRequested:
        // Re-check presence, don't just re-render: the script may have been
        // added since selection, and the HEAD-based watcher never fires for a
        // plain file drop — this is the only discovery path in that case.
        guard let worktree = state.worktree else { return .none }
        state.forceReloadOnNextRender = true
        return checkPresence(worktree: worktree, state: &state)

      case .presenceResolved(let worktreeID, let result):
        guard let worktree = state.worktree, worktree.id == worktreeID else { return .none }
        state.isCheckingPresence = false
        switch result {
        case .success(true):
          state.scriptPresent = true
          state.lastError = nil
          guard state.isPanelShown else { return .none }
          return render(worktree: worktree, state: &state)
        case .success(false):
          state.clearPage()
          state.contentByWorktreeID[worktreeID] = nil
          return .cancel(id: CancelID.render)
        case .failure(let error):
          state.scriptPresent = false
          state.isRendering = false
          state.lastError = error
          return .cancel(id: CancelID.render)
        }

      case .setPanelShown(let shown):
        return setPanelShown(shown, state: &state)

      case .panelToggled:
        return setPanelShown(!state.isPanelShown, state: &state)

      case .renderCompleted(let worktreeID, let result):
        guard state.worktree?.id == worktreeID else { return .none }
        state.isRendering = false
        switch result {
        case .success(let content):
          let previous = state.content
          state.content = content
          state.contentByWorktreeID[worktreeID] = content
          state.lastError = nil
          if case .url(let url) = content {
            // Reload policy: load when the URL changed; retry once per tick
            // after a reported failure (the script restarts the server, so
            // recovery lands within ~30s without hammering); reload on
            // explicit refresh; never on a same-URL periodic tick, which
            // would reset the web app's state.
            let sameURL = previous == .url(url)
            if !sameURL || state.serveLoadFailed || state.forceReloadOnNextRender {
              state.loadRequestID &+= 1
            }
          }
          state.forceReloadOnNextRender = false
        case .failure(let error):
          state.lastError = error
          state.forceReloadOnNextRender = false
        }
        return .none

      case .serveLoadResult(let url, let success):
        // Stale reports (a load that raced a content change) don't count.
        guard state.content == .url(url) else { return .none }
        state.serveLoadFailed = !success
        return .none
      }
    }
  }

  /// Records the panel state for the selected repository. Opening the panel
  /// mounts its view, whose `panelAppeared` triggers the render — no effect
  /// needed here. Without a selection there is no repository to toggle.
  private func setPanelShown(_ shown: Bool, state: inout State) -> Effect<Action> {
    guard let repositoryID = state.repositoryID else { return .none }
    state.$openPanelRepositoryIDs.withLock { ids in
      if shown {
        ids.insert(repositoryID)
      } else {
        ids.remove(repositoryID)
      }
    }
    return .none
  }

  private func checkPresence(worktree: Worktree, state: inout State) -> Effect<Action> {
    state.isCheckingPresence = true
    let pagePresent = customCodeClient.pagePresent
    return .run { send in
      let result: Result<Bool, CustomCodeError>
      do {
        result = .success(try await pagePresent(worktree))
      } catch let error as CustomCodeError {
        result = .failure(error)
      } catch {
        result = .failure(.scriptFailed(message: error.localizedDescription))
      }
      await send(.presenceResolved(worktreeID: worktree.id, result: result))
    }
  }

  private func render(worktree: Worktree, state: inout State) -> Effect<Action> {
    state.isRendering = true
    let renderPage = customCodeClient.renderPage
    return .run { send in
      let result: Result<CustomCodeContent, CustomCodeError>
      do {
        result = .success(try await renderPage(worktree))
      } catch let error as CustomCodeError {
        result = .failure(error)
      } catch {
        result = .failure(.scriptFailed(message: error.localizedDescription))
      }
      await send(.renderCompleted(worktreeID: worktree.id, result: result))
    }
    .cancellable(id: CancelID.render, cancelInFlight: true)
  }
}

extension CustomCodeFeature.State {
  fileprivate mutating func clearPage() {
    scriptPresent = false
    isCheckingPresence = false
    isRendering = false
    content = nil
    lastError = nil
    serveLoadFailed = false
    forceReloadOnNextRender = false
    // loadRequestID stays monotonic: a freshly mounted coordinator always
    // loads because it has no last-loaded URL yet.
  }
}
