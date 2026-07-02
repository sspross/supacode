import ComposableArchitecture
import OrderedCollections
import SwiftUI

/// Top-level sidebar header for a user-defined repository group, rendered as
/// the header of a content-less `Section`. It must NOT be a bare list row:
/// SwiftUI wraps bare rows in an implicit section whose extra boundary makes
/// the header → first-member gap ~14pt larger than the repo → repo rhythm
/// (measured; negative padding can't cancel it without overlapping the row).
/// As a section header every list boundary is the same kind, so the rhythm is
/// uniform by construction. Clicking toggles collapse; while collapsed the
/// member repo sections are omitted from the structure and this header shows
/// their aggregated activity indicators (same per-leaf-scoped pattern as
/// nested branch groups, so a per-row tick invalidates only this header).
struct SidebarRepoGroupHeaderRow: View {
  let groupID: SidebarGroupID
  let name: String
  let isCollapsed: Bool
  let leafRowIDs: [Worktree.ID]
  @Bindable var store: StoreOf<RepositoriesFeature>

  var body: some View {
    Button {
      store.send(.sidebarGroupSetCollapsed(groupID, isCollapsed: !isCollapsed))
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(isCollapsed ? 0 : 90))
          .frame(width: 12)
          .accessibilityHidden(true)
        Text(name)
          .font(.body.weight(.semibold))
          .lineLimit(1)
          .foregroundStyle(.secondary)
        // Trailing rule filling the rest of the row, so the header reads as
        // a section divider rather than a primary content row.
        Rectangle()
          .fill(.separator)
          .frame(height: 1)
          .frame(maxWidth: .infinity)
          .accessibilityHidden(true)
        if isCollapsed {
          SidebarPathGroupAggregatedIndicators(parentStore: store, leafIDs: leafRowIDs)
        }
      }
      .contentShape(.interaction, .rect)
    }
    .buttonStyle(.plain)
    // Section headers ignore `listRowInsets`; padding is the layout knob.
    // Extra top keeps the group boundary the dominant gap (the last member
    // above shouldn't read as part of this group); the small bottom brings
    // header → first-member to the same ~21pt rhythm as repo → repo.
    .padding(.top, SidebarNestLayout.groupHeaderTopPadding)
    .padding(.bottom, SidebarNestLayout.groupHeaderBottomPadding)
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
