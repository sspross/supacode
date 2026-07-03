import ComposableArchitecture
import Foundation
import Sharing

nonisolated extension SharedReaderKey where Self == AppStorageKey<Bool>.Default {
  static var customCodePanelShown: Self {
    Self[.appStorage("customCodePanelShown"), default: false]
  }
}

/// Drives the right-hand project-status inspector: tracks whether the selected
/// worktree carries a `customcode.py` page script and renders its HTML through
/// `CustomCodeClient` whenever the panel is visible. Local and remote (SSH)
/// worktrees are both supported; the client owns the transport split.
@Reducer
struct CustomCodeFeature {
  @ObservableState
  struct State: Equatable {
    @Shared(.customCodePanelShown) var isPanelShown: Bool
    var worktree: Worktree?
    var scriptPresent = false
    var isRendering = false
    var html: String?
    var lastError: CustomCodeError?
  }

  enum Action: Equatable {
    case selectionChanged(Worktree?)
    case filesChanged(Worktree.ID)
    case panelAppeared
    case refreshRequested
    case setPanelShown(Bool)
    case presenceResolved(worktreeID: Worktree.ID, result: Result<Bool, CustomCodeError>)
    case renderCompleted(worktreeID: Worktree.ID, result: Result<String, CustomCodeError>)
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
        return .merge(
          .cancel(id: CancelID.render),
          checkPresence(worktree: worktree)
        )

      case .filesChanged(let worktreeID):
        // Re-check presence, not just re-render: a branch switch can add or
        // remove customcode.py itself.
        guard let worktree = state.worktree, worktree.id == worktreeID else { return .none }
        return checkPresence(worktree: worktree)

      case .panelAppeared, .refreshRequested:
        // Re-check presence, don't just re-render: the script may have been
        // added since selection, and the HEAD-based watcher never fires for a
        // plain file drop — this is the only discovery path in that case.
        guard let worktree = state.worktree else { return .none }
        return checkPresence(worktree: worktree)

      case .presenceResolved(let worktreeID, let result):
        guard let worktree = state.worktree, worktree.id == worktreeID else { return .none }
        switch result {
        case .success(true):
          state.scriptPresent = true
          state.lastError = nil
          guard state.isPanelShown else { return .none }
          return render(worktree: worktree, state: &state)
        case .success(false):
          state.clearPage()
          return .cancel(id: CancelID.render)
        case .failure(let error):
          state.scriptPresent = false
          state.isRendering = false
          state.lastError = error
          return .cancel(id: CancelID.render)
        }

      case .setPanelShown(let shown):
        // Opening the panel mounts its view, whose `panelAppeared` triggers the
        // render — no effect needed here.
        state.$isPanelShown.withLock { $0 = shown }
        return .none

      case .renderCompleted(let worktreeID, let result):
        guard state.worktree?.id == worktreeID else { return .none }
        state.isRendering = false
        switch result {
        case .success(let html):
          state.html = html
          state.lastError = nil
        case .failure(let error):
          state.lastError = error
        }
        return .none
      }
    }
  }

  private func checkPresence(worktree: Worktree) -> Effect<Action> {
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
      let result: Result<String, CustomCodeError>
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
    isRendering = false
    html = nil
    lastError = nil
  }
}
