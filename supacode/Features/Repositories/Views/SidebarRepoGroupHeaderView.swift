import ComposableArchitecture
import OrderedCollections
import SwiftUI

/// Top-level sidebar row for a user-defined repository group. Clicking
/// toggles collapse; while collapsed the member repo sections are omitted
/// from the structure and this row shows their aggregated activity
/// indicators (same per-leaf-scoped pattern as nested branch groups, so a
/// per-row tick invalidates only this row).
struct SidebarRepoGroupHeaderRow: View {
  let groupID: SidebarGroupID
  let name: String
  let isCollapsed: Bool
  let leafRowIDs: [Worktree.ID]
  @Bindable var store: StoreOf<RepositoriesFeature>

  var body: some View {
    Button {
      _ = withAnimation(.easeOut(duration: 0.2)) {
        store.send(.sidebarGroupSetCollapsed(groupID, isCollapsed: !isCollapsed))
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(isCollapsed ? 0 : 90))
          .animation(.easeInOut(duration: 0.15), value: isCollapsed)
          .frame(width: 12)
          .accessibilityHidden(true)
        Text(name)
          .font(.body.weight(.semibold))
          .lineLimit(1)
          .foregroundStyle(.primary)
        Spacer(minLength: 0)
        if isCollapsed {
          SidebarPathGroupAggregatedIndicators(parentStore: store, leafIDs: leafRowIDs)
        }
      }
      .contentShape(.interaction, .rect)
    }
    .buttonStyle(.plain)
    .listRowInsets(.leading, 0)
    .listRowInsets(.vertical, 6)
    .help(isCollapsed ? "Expand \(name)" : "Collapse \(name)")
    .accessibilityLabel("\(name) group, \(isCollapsed ? "collapsed" : "expanded")")
    .contextMenu {
      Button("Rename Group…", systemImage: "pencil") {
        store.send(.sidebarGroupRenameRequested(groupID))
      }
      .help("Rename this group")
      Button("Ungroup", systemImage: "rectangle.stack.badge.minus") {
        store.send(.sidebarGroupDissolved(groupID))
      }
      .help("Delete the group; its repositories stay in the sidebar")
    }
  }
}

/// "Move to Group" submenu shared by the repo section ellipsis menu and the
/// folder row context menu. Lists every existing group (checkmark on the
/// current one), an exit entry while grouped, and "New Group…".
struct SidebarMoveToGroupMenu: View {
  let repositoryID: Repository.ID
  @Bindable var store: StoreOf<RepositoriesFeature>

  var body: some View {
    let sidebar = store.state.sidebar
    let currentGroupID = sidebar.groupID(of: repositoryID)
    Menu("Move to Group") {
      ForEach(Array(sidebar.groups.keys), id: \.self) { groupID in
        let isCurrent = groupID == currentGroupID
        Button {
          store.send(.sidebarGroupAssignRepository(repositoryID, groupID: groupID))
        } label: {
          if isCurrent {
            Label(sidebar.groups[groupID]?.name ?? "", systemImage: "checkmark")
          } else {
            Text(sidebar.groups[groupID]?.name ?? "")
          }
        }
        .disabled(isCurrent)
        .help("Move this repository into \(sidebar.groups[groupID]?.name ?? "the group")")
      }
      if currentGroupID != nil {
        Button("Remove from Group", systemImage: "rectangle.stack.badge.minus") {
          store.send(.sidebarGroupAssignRepository(repositoryID, groupID: nil))
        }
        .help("Move this repository back to the top level")
      }
      if !sidebar.groups.isEmpty {
        Divider()
      }
      Button("New Group…", systemImage: "plus") {
        store.send(.sidebarGroupCreateRequested(memberRepositoryIDs: [repositoryID]))
      }
      .help("Create a new group containing this repository")
    }
  }
}
