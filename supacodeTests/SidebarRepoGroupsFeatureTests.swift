import ComposableArchitecture
import Foundation
import IdentifiedCollections
import OrderedCollections
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Reducer-level coverage for user-defined sidebar repository groups:
/// the name-prompt create/rename flow, assignment, collapse (and its effect
/// on the cached structure), whole-group moves, and the membership
/// reconciliation a manual repo drag triggers. The `SidebarState` mutation
/// primitives have their own unit coverage in `SidebarStateTests`.
@MainActor
struct SidebarRepoGroupsFeatureTests {
  private func makeRepository(root: String, name: String) -> Repository {
    let repoRoot = URL(fileURLWithPath: root)
    let main = Worktree(
      id: WorktreeID(repoRoot.path(percentEncoded: false)),
      name: "main",
      detail: "",
      workingDirectory: repoRoot,
      repositoryRootURL: repoRoot
    )
    return Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: name,
      worktrees: IdentifiedArray(uniqueElements: [main])
    )
  }

  private func makeState(repositories: [Repository]) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State(reconciledRepositories: repositories)
    state.isInitialLoadComplete = true
    return state
  }

  @Test func createGroupViaNamePrompt() async {
    let repoA = makeRepository(root: "/tmp/group-repo-a", name: "a")
    let store = TestStore(initialState: makeState(repositories: [repoA])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.sidebarGroupCreateRequested(memberRepositoryIDs: [repoA.id]))
    #expect(store.state.sidebarGroupNamePrompt?.mode == .create(memberRepositoryIDs: [repoA.id]))

    await store.send(.sidebarGroupNamePrompt(.presented(.binding(.set(\.name, "Work")))))
    await store.send(.sidebarGroupNamePrompt(.presented(.submitButtonTapped)))
    await store.receive(\.sidebarGroupNamePrompt.presented.delegate.submitted)

    let groupID = SidebarGroupID(UUID(0).uuidString)
    #expect(store.state.sidebarGroupNamePrompt == nil)
    #expect(store.state.sidebar.groups[groupID]?.name == "Work")
    #expect(store.state.sidebar.groupID(of: repoA.id) == groupID)
    // The structure cache picked the group up via the post-reduce hook.
    #expect(store.state.sidebarStructure.sections.first?.id == .repoGroupHeader(groupID))
  }

  @Test func renameGroupViaNamePrompt() async {
    let repoA = makeRepository(root: "/tmp/group-repo-a", name: "a")
    var initial = makeState(repositories: [repoA])
    let groupID = SidebarGroupID("group-1")
    initial.$sidebar.withLock { sidebar in
      sidebar.createGroup(id: groupID, name: "Work", memberRepositoryIDs: [repoA.id])
    }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(.sidebarGroupRenameRequested(groupID))
    #expect(store.state.sidebarGroupNamePrompt?.mode == .rename(groupID))
    #expect(store.state.sidebarGroupNamePrompt?.name == "Work")

    await store.send(.sidebarGroupNamePrompt(.presented(.binding(.set(\.name, "Projects")))))
    await store.send(.sidebarGroupNamePrompt(.presented(.submitButtonTapped)))
    await store.receive(\.sidebarGroupNamePrompt.presented.delegate.submitted)

    #expect(store.state.sidebar.groups[groupID]?.name == "Projects")
    #expect(store.state.sidebarGroupNamePrompt == nil)
  }

  @Test func assignRepositoryToGroupAndBack() async {
    let repoA = makeRepository(root: "/tmp/group-repo-a", name: "a")
    let repoB = makeRepository(root: "/tmp/group-repo-b", name: "b")
    var initial = makeState(repositories: [repoA, repoB])
    let groupID = SidebarGroupID("group-1")
    initial.$sidebar.withLock { sidebar in
      sidebar.createGroup(id: groupID, name: "Work", memberRepositoryIDs: [repoA.id])
    }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(.sidebarGroupAssignRepository(repoB.id, groupID: groupID))
    #expect(store.state.sidebar.memberRepositoryIDs(of: groupID) == [repoA.id, repoB.id])

    await store.send(.sidebarGroupAssignRepository(repoA.id, groupID: nil))
    #expect(store.state.sidebar.memberRepositoryIDs(of: groupID) == [repoB.id])

    await store.send(.sidebarGroupAssignRepository(repoB.id, groupID: nil))
    // Last member left → group auto-deletes.
    #expect(store.state.sidebar.groups[groupID] == nil)
  }

  @Test func collapseRemovesMemberSectionsFromStructure() async {
    let repoA = makeRepository(root: "/tmp/group-repo-a", name: "a")
    let repoB = makeRepository(root: "/tmp/group-repo-b", name: "b")
    var initial = makeState(repositories: [repoA, repoB])
    let groupID = SidebarGroupID("group-1")
    initial.$sidebar.withLock { sidebar in
      sidebar.createGroup(id: groupID, name: "Work", memberRepositoryIDs: [repoA.id])
    }
    initial.recomputeSidebarStructureIfChanged()
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off
    #expect(store.state.sidebarStructure.sections.map(\.id).contains(.repository(repoA.id)))

    await store.send(.sidebarGroupSetCollapsed(groupID, isCollapsed: true))

    let sectionIDs = store.state.sidebarStructure.sections.map(\.id)
    #expect(sectionIDs.contains(.repoGroupHeader(groupID)))
    #expect(!sectionIDs.contains(.repository(repoA.id)))
    #expect(sectionIDs.contains(.repository(repoB.id)))
    // Hidden member rows drop out of hotkey numbering.
    let hotkeyIDs = store.state.sidebarStructure.hotkeySlots.map(\.id)
    #expect(hotkeyIDs == repoB.worktrees.map(\.id))

    await store.send(.sidebarGroupSetCollapsed(groupID, isCollapsed: false))
    #expect(store.state.sidebarStructure.sections.map(\.id).contains(.repository(repoA.id)))
  }

  @Test func repositoriesMovedStrictlyInsideGroupJoinsIt() async {
    let repoA = makeRepository(root: "/tmp/group-repo-a", name: "a")
    let repoB = makeRepository(root: "/tmp/group-repo-b", name: "b")
    let repoX = makeRepository(root: "/tmp/group-repo-x", name: "x")
    var initial = makeState(repositories: [repoA, repoB, repoX])
    let groupID = SidebarGroupID("group-1")
    initial.$sidebar.withLock { sidebar in
      sidebar.createGroup(id: groupID, name: "Work", memberRepositoryIDs: [repoA.id, repoB.id])
    }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off
    // Ordered pre-move: [a, b, x] (group run first, x top-level).
    #expect(store.state.orderedRepositoryIDs() == [repoA.id, repoB.id, repoX.id])

    // Drag x between a and b.
    await store.send(.repositoriesMoved(IndexSet([2]), 1))

    #expect(store.state.orderedRepositoryIDs() == [repoA.id, repoX.id, repoB.id])
    #expect(store.state.sidebar.groupID(of: repoX.id) == groupID)
  }

  @Test func repositoriesMovedOutOfGroupLeavesIt() async {
    let repoA = makeRepository(root: "/tmp/group-repo-a", name: "a")
    let repoB = makeRepository(root: "/tmp/group-repo-b", name: "b")
    let repoX = makeRepository(root: "/tmp/group-repo-x", name: "x")
    var initial = makeState(repositories: [repoA, repoB, repoX])
    let groupID = SidebarGroupID("group-1")
    initial.$sidebar.withLock { sidebar in
      sidebar.createGroup(id: groupID, name: "Work", memberRepositoryIDs: [repoA.id, repoB.id])
    }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    // Drag a below x: [b, x, a] — no longer adjacent to its run.
    await store.send(.repositoriesMoved(IndexSet([0]), 3))

    #expect(store.state.orderedRepositoryIDs() == [repoB.id, repoX.id, repoA.id])
    #expect(store.state.sidebar.groupID(of: repoA.id) == nil)
    #expect(store.state.sidebar.memberRepositoryIDs(of: groupID) == [repoB.id])
  }

  @Test func groupMovedRelocatesWholeRunPreservingMembership() async {
    let repoA = makeRepository(root: "/tmp/group-repo-a", name: "a")
    let repoB = makeRepository(root: "/tmp/group-repo-b", name: "b")
    let repoX = makeRepository(root: "/tmp/group-repo-x", name: "x")
    var initial = makeState(repositories: [repoA, repoB, repoX])
    let groupID = SidebarGroupID("group-1")
    initial.$sidebar.withLock { sidebar in
      sidebar.createGroup(id: groupID, name: "Work", memberRepositoryIDs: [repoA.id, repoB.id])
    }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    // Drag the group header below x.
    await store.send(.sidebarGroupMoved(groupID, destination: 3))

    #expect(store.state.orderedRepositoryIDs() == [repoX.id, repoA.id, repoB.id])
    #expect(store.state.sidebar.groupID(of: repoA.id) == groupID)
    #expect(store.state.sidebar.groupID(of: repoB.id) == groupID)
  }

  @Test func dissolveReturnsMembersToTopLevel() async {
    let repoA = makeRepository(root: "/tmp/group-repo-a", name: "a")
    let repoB = makeRepository(root: "/tmp/group-repo-b", name: "b")
    var initial = makeState(repositories: [repoA, repoB])
    let groupID = SidebarGroupID("group-1")
    initial.$sidebar.withLock { sidebar in
      sidebar.createGroup(id: groupID, name: "Work", memberRepositoryIDs: [repoA.id, repoB.id])
    }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(.sidebarGroupDissolved(groupID))

    #expect(store.state.sidebar.groups[groupID] == nil)
    #expect(store.state.sidebar.groupID(of: repoA.id) == nil)
    #expect(store.state.sidebar.groupID(of: repoB.id) == nil)
    // Members stay in place at the top level.
    #expect(store.state.orderedRepositoryIDs() == [repoA.id, repoB.id])
    let sectionIDs = store.state.sidebarStructure.sections.map(\.id)
    #expect(!sectionIDs.contains(.repoGroupHeader(groupID)))
  }
}
