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
/// `CustomCodeClient` whenever the panel is visible.
@Reducer
struct CustomCodeFeature {
  @ObservableState
  struct State: Equatable {
    @Shared(.customCodePanelShown) var isPanelShown: Bool
    var worktreeID: Worktree.ID?
    var worktreeDirectory: URL?
    var scriptPresent = false
    var isRendering = false
    var html: String?
    var errorMessage: String?
  }

  enum Action: Equatable {
    case selectionChanged(Worktree?)
    case filesChanged(Worktree.ID)
    case panelAppeared
    case refreshRequested
    case setPanelShown(Bool)
    case presenceResolved(worktreeID: Worktree.ID, present: Bool)
    case renderCompleted(worktreeID: Worktree.ID, result: Result<String, CustomCodeError>)
  }

  @Dependency(CustomCodeClient.self) private var customCodeClient

  private nonisolated enum CancelID: Hashable, Sendable { case render }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .selectionChanged(let worktree):
        // Remote worktrees have no local directory to run the script in.
        guard let worktree, let directory = worktree.localWorkingDirectory else {
          guard state.worktreeID != nil else { return .none }
          state.clearPage()
          state.worktreeID = nil
          state.worktreeDirectory = nil
          return .cancel(id: CancelID.render)
        }
        guard worktree.id != state.worktreeID || directory != state.worktreeDirectory else {
          return .none
        }
        state.clearPage()
        state.worktreeID = worktree.id
        state.worktreeDirectory = directory
        return .merge(
          .cancel(id: CancelID.render),
          checkPresence(worktreeID: worktree.id, directory: directory)
        )

      case .filesChanged(let worktreeID):
        // Re-check presence, not just re-render: a branch switch can add or
        // remove customcode.py itself.
        guard worktreeID == state.worktreeID, let directory = state.worktreeDirectory else {
          return .none
        }
        return checkPresence(worktreeID: worktreeID, directory: directory)

      case .presenceResolved(let worktreeID, let present):
        guard worktreeID == state.worktreeID, let directory = state.worktreeDirectory else {
          return .none
        }
        state.scriptPresent = present
        guard present else {
          state.clearPage()
          return .cancel(id: CancelID.render)
        }
        guard state.isPanelShown else { return .none }
        return render(worktreeID: worktreeID, directory: directory, state: &state)

      case .panelAppeared, .refreshRequested:
        guard state.scriptPresent, let worktreeID = state.worktreeID,
          let directory = state.worktreeDirectory
        else { return .none }
        return render(worktreeID: worktreeID, directory: directory, state: &state)

      case .setPanelShown(let shown):
        // Opening the panel mounts its view, whose `panelAppeared` triggers the
        // render — no effect needed here.
        state.$isPanelShown.withLock { $0 = shown }
        return .none

      case .renderCompleted(let worktreeID, let result):
        guard worktreeID == state.worktreeID else { return .none }
        state.isRendering = false
        switch result {
        case .success(let html):
          state.html = html
          state.errorMessage = nil
        case .failure(let error):
          state.errorMessage = error.message
        }
        return .none
      }
    }
  }

  private func checkPresence(worktreeID: Worktree.ID, directory: URL) -> Effect<Action> {
    let pagePresent = customCodeClient.pagePresent
    return .run { send in
      await send(.presenceResolved(worktreeID: worktreeID, present: pagePresent(directory)))
    }
  }

  private func render(worktreeID: Worktree.ID, directory: URL, state: inout State) -> Effect<Action> {
    state.isRendering = true
    let renderPage = customCodeClient.renderPage
    return .run { send in
      let result: Result<String, CustomCodeError>
      do {
        result = .success(try await renderPage(directory))
      } catch let error as CustomCodeError {
        result = .failure(error)
      } catch {
        result = .failure(.scriptFailed(message: error.localizedDescription))
      }
      await send(.renderCompleted(worktreeID: worktreeID, result: result))
    }
    .cancellable(id: CancelID.render, cancelInFlight: true)
  }
}

extension CustomCodeFeature.State {
  fileprivate mutating func clearPage() {
    scriptPresent = false
    isRendering = false
    html = nil
    errorMessage = nil
  }
}
