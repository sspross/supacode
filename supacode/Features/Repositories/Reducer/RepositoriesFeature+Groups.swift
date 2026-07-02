import ComposableArchitecture
import Foundation
import OrderedCollections
import SwiftUI

extension RepositoriesFeature {
  /// Dedicated reducer for user-defined sidebar repository groups. Lives in
  /// its own file so the main `body` switch stays under the Swift
  /// type-checker's complexity limit. All mutations fold through
  /// `$sidebar.withLock` so each action persists one atomic `sidebar.json`
  /// update; the post-reduce hook recomputes the structure cache (see the
  /// group arms in `RepositoriesFeature.Action.cacheInvalidations`).
  static var sidebarGroupsReducer: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .sidebarGroupCreateRequested(let memberRepositoryIDs):
        guard !memberRepositoryIDs.isEmpty else { return .none }
        state.sidebarGroupNamePrompt = SidebarGroupNameFeature.State(
          mode: .create(memberRepositoryIDs: memberRepositoryIDs),
          name: ""
        )
        return .none

      case .sidebarGroupRenameRequested(let groupID):
        guard let group = state.sidebar.groups[groupID] else { return .none }
        state.sidebarGroupNamePrompt = SidebarGroupNameFeature.State(
          mode: .rename(groupID),
          name: group.name
        )
        return .none

      case .sidebarGroupNamePrompt(.presented(.delegate(.cancel))),
        .sidebarGroupNamePrompt(.dismiss):
        state.sidebarGroupNamePrompt = nil
        return .none

      case .sidebarGroupNamePrompt(.presented(.delegate(.submitted(let mode, let name)))):
        switch mode {
        case .create(let memberRepositoryIDs):
          @Dependency(\.uuid) var uuid
          let groupID = SidebarGroupID(uuid().uuidString)
          withAnimation(.snappy(duration: 0.2)) {
            state.$sidebar.withLock { sidebar in
              sidebar.createGroup(id: groupID, name: name, memberRepositoryIDs: memberRepositoryIDs)
            }
          }
        case .rename(let groupID):
          state.$sidebar.withLock { sidebar in
            sidebar.renameGroup(id: groupID, name: name)
          }
        }
        state.sidebarGroupNamePrompt = nil
        return .none

      case .sidebarGroupSetCollapsed(let groupID, let isCollapsed):
        state.$sidebar.withLock { sidebar in
          sidebar.setGroupCollapsed(id: groupID, collapsed: isCollapsed)
        }
        return .none

      case .sidebarGroupAssignRepository(let repositoryID, let groupID):
        withAnimation(.snappy(duration: 0.2)) {
          state.$sidebar.withLock { sidebar in
            sidebar.assign(repository: repositoryID, toGroup: groupID)
          }
        }
        return .none

      case .sidebarGroupDissolved(let groupID):
        withAnimation(.snappy(duration: 0.2)) {
          state.$sidebar.withLock { sidebar in
            sidebar.dissolveGroup(id: groupID)
          }
        }
        return .none

      case .sidebarGroupMoved(let groupID, let destination):
        var ordered = state.orderedRepositoryIDs()
        let memberOffsets = IndexSet(
          ordered.indices.filter { state.sidebar.groupID(of: ordered[$0]) == groupID }
        )
        guard !memberOffsets.isEmpty, destination >= 0, destination <= ordered.count else {
          return .none
        }
        ordered.move(fromOffsets: memberOffsets, toOffset: destination)
        withAnimation(.snappy(duration: 0.2)) {
          state.$sidebar.withLock { sidebar in
            sidebar.reorderSections(to: ordered)
          }
        }
        return .none

      default:
        return .none
      }
    }
  }
}
