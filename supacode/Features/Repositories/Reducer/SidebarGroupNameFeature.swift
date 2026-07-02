import ComposableArchitecture
import Foundation

/// Name-entry sheet shared by "New Group…" and "Rename Group…". Pure UI
/// state: validation is a non-empty trimmed name; the parent applies the
/// submitted value to `@Shared(.sidebar)`.
@Reducer
struct SidebarGroupNameFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    enum Mode: Equatable {
      /// Creating a new group seeded with these members.
      case create(memberRepositoryIDs: [Repository.ID])
      /// Renaming an existing group.
      case rename(SidebarGroupID)
    }

    let mode: Mode
    var name: String

    var id: String {
      switch mode {
      case .create: "create"
      case .rename(let groupID): "rename-\(groupID.rawValue)"
      }
    }

    var isRename: Bool {
      if case .rename = mode { true } else { false }
    }

    var trimmedName: String {
      name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSubmit: Bool {
      !trimmedName.isEmpty
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case cancelButtonTapped
    case submitButtonTapped
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case cancel
    case submitted(mode: State.Mode, name: String)
  }

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .cancelButtonTapped:
        return .send(.delegate(.cancel))

      case .submitButtonTapped:
        guard state.canSubmit else { return .none }
        return .send(.delegate(.submitted(mode: state.mode, name: state.trimmedName)))

      case .delegate:
        return .none
      }
    }
  }
}
