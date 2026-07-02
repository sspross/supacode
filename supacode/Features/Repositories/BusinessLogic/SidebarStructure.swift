import ComposableArchitecture
import Dependencies
import Foundation
import OrderedCollections
import SupacodeSettingsShared

/// Dependency switch that gates the reducer's post-reduce sidebar-structure
/// recompute. Defaults `true` everywhere so production, preview, and tests
/// see the same cached structure. See `AGENTS.md` (Sidebar performance) for
/// the canonical TestStore mirror rules.
public nonisolated enum SidebarStructureAutoRecomputeKey: DependencyKey {
  public static let liveValue: Bool = true
  public static let previewValue: Bool = true
  public static let testValue: Bool = true
}

extension DependencyValues {
  public nonisolated var sidebarStructureAutoRecompute: Bool {
    get { self[SidebarStructureAutoRecomputeKey.self] }
    set { self[SidebarStructureAutoRecomputeKey.self] = newValue }
  }
}

/// Classification buckets for the global Active section. Lower raw value =
/// higher priority. Rows that don't classify into one of the ten buckets are
/// excluded from Active and (when the Pinned section is in play) fall to the
/// bottom of Pinned alphabetically.
enum SidebarActiveClassification: Int, CaseIterable, Comparable, Sendable {
  case unreadAwaitingRunning = 1
  case unreadAwaiting = 2
  case unreadAgentRunning = 3
  case unreadAgent = 4
  case unreadRunning = 5
  case awaitingRunning = 6
  case awaiting = 7
  case agentRunning = 8
  case agent = 9
  case running = 10

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  /// Pure classifier driven by four leaf-local flags. Returns `nil` for rows
  /// that don't belong in Active (no unread, no awaiting, no agent, no script).
  static func classify(
    hasUnread: Bool,
    hasAwaiting: Bool,
    hasAgent: Bool,
    hasRunning: Bool
  ) -> Self? {
    if hasUnread && hasAwaiting && hasRunning { return .unreadAwaitingRunning }
    if hasUnread && hasAwaiting { return .unreadAwaiting }
    if hasUnread && hasAgent && hasRunning { return .unreadAgentRunning }
    if hasUnread && hasAgent { return .unreadAgent }
    if hasUnread && hasRunning { return .unreadRunning }
    if hasAwaiting && hasRunning { return .awaitingRunning }
    if hasAwaiting { return .awaiting }
    if hasAgent && hasRunning { return .agentRunning }
    if hasAgent { return .agent }
    if hasRunning { return .running }
    return nil
  }

  /// `hasAgent` is keyed off agent badge presence (any tracked instance,
  /// including `.idle`) so a row with a visible agent badge surfaces in
  /// Active even when the agent isn't actively working; `state.agents` is
  /// already empty when badges are disabled by the user.
  static func classify(_ state: SidebarItemFeature.State) -> Self? {
    classify(
      hasUnread: state.hasUnseenNotifications,
      hasAwaiting: state.hasAgentAwaitingInput,
      hasAgent: !state.agents.isEmpty,
      hasRunning: !state.runningScripts.isEmpty
    )
  }
}

/// Pure ordering layer behind the highlight aggregator: priority sort over
/// `SidebarActiveClassification`, alphabetical tie-break. Pinned keeps
/// unclassified rows at the bottom; Active drops them.
enum SidebarHighlightOrdering {
  struct Candidate: Equatable, Sendable {
    let id: SidebarItemID
    let branchName: String
    let classification: SidebarActiveClassification?
  }

  static func orderedRowIDs(
    forPinned: Bool,
    candidates: [Candidate]
  ) -> [SidebarItemID] {
    struct Entry {
      let id: SidebarItemID
      let priority: Int
      let sortKey: String
    }
    let unclassifiedPriority = SidebarActiveClassification.allCases.count + 1
    var entries: [Entry] = []
    entries.reserveCapacity(candidates.count)
    for candidate in candidates {
      if forPinned {
        let priority = candidate.classification?.rawValue ?? unclassifiedPriority
        entries.append(Entry(id: candidate.id, priority: priority, sortKey: candidate.branchName))
      } else {
        guard let classification = candidate.classification else { continue }
        entries.append(
          Entry(id: candidate.id, priority: classification.rawValue, sortKey: candidate.branchName)
        )
      }
    }
    entries.sort { lhs, rhs in
      if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
      return lhs.sortKey.localizedCaseInsensitiveCompare(rhs.sortKey) == .orderedAscending
    }
    return entries.map(\.id)
  }
}

/// Per-repo render plan precomputed by the reducer. Lives here, not in a view
/// file, so the per-repo slot partition / hoisted-row filter / dedupe is a
/// reducer-state derivation (per the "view does zero computation" contract).
struct SidebarItemGroup: Identifiable, Equatable, Sendable {
  enum MoveBehavior: Hashable, Sendable {
    case disabled
    case pinned(Repository.ID)
    case unpinned(Repository.ID)
  }

  enum Slot: Hashable, Sendable {
    case main(isSole: Bool)
    case pinnedTail
    case pending
    case unpinnedTail
  }

  let slot: Slot
  let repositoryID: Repository.ID
  let rowIDs: [SidebarItemID]

  var id: Slot { slot }

  var hideSubtitle: Bool {
    if case .main(let isSole) = slot { isSole } else { false }
  }

  var moveBehavior: MoveBehavior {
    switch slot {
    case .main, .pending: .disabled
    case .pinnedTail: .pinned(repositoryID)
    case .unpinnedTail: .unpinned(repositoryID)
    }
  }

  /// Only the pinned and unpinned tails participate in branch nesting.
  /// The main and pending slots are structural and shouldn't be folded into a tree.
  var supportsBranchNesting: Bool {
    switch slot {
    case .pinnedTail, .unpinnedTail: true
    case .main, .pending: false
    }
  }
}

/// Per-repo tally of rows hoisted into the highlight sections, surfaced as a
/// muted summary line at the bottom of the repo section so a hoisted row stays
/// discoverable from its origin repo without rendering a duplicate. `revealTarget`
/// is the row a click scrolls to: the repo's first pinned hoist, else its first
/// active hoist.
struct SidebarHoistSummary: Equatable, Sendable {
  let pinnedCount: Int
  let activeCount: Int
  let revealTarget: Worktree.ID

  /// Nil when neither bucket has a row, so a `(0, 0)` summary is unrepresentable.
  init?(pinnedCount: Int, activeCount: Int, revealTarget: Worktree.ID) {
    guard pinnedCount > 0 || activeCount > 0 else { return nil }
    self.pinnedCount = pinnedCount
    self.activeCount = activeCount
    self.revealTarget = revealTarget
  }

  /// Spoken VoiceOver form, pinned before active, omitting a zero bucket.
  var label: String {
    var parts: [String] = []
    if pinnedCount > 0 { parts.append("+\(pinnedCount) \(SidebarStructure.HighlightKind.pinned.summaryNoun)") }
    if activeCount > 0 { parts.append("+\(activeCount) \(SidebarStructure.HighlightKind.active.summaryNoun)") }
    return parts.joined(separator: ", ")
  }
}

/// Single source of truth for what the sidebar List renders. The reducer
/// builds it once per `recomputeSidebarStructure()` and caches it on
/// `RepositoriesFeature.State.sidebarStructure`; the view walks `sections`
/// and does no layout calculation itself.
struct SidebarStructure: Equatable, Sendable {
  enum HighlightKind: String, Equatable, Sendable {
    case pinned
    case active

    var title: String {
      switch self {
      case .pinned: "Pinned"
      case .active: "Active"
      }
    }

    /// Lowercase noun used in the per-repo hoist summary line.
    var summaryNoun: String {
      switch self {
      case .pinned: "pinned"
      case .active: "active"
      }
    }
  }

  enum Section: Equatable, Sendable, Identifiable {
    case highlight(kind: HighlightKind, rowIDs: [Worktree.ID])
    /// Header row for a user-defined repository group. When collapsed the
    /// member repo sections are omitted from `sections` entirely (which also
    /// removes their rows from hotkey numbering); `leafRowIDs` then carries
    /// the members' visible row ids so the header can render aggregated
    /// activity indicators. `memberRepositoryIDs` is always populated so the
    /// view can translate a header drag into a whole-group move.
    case repoGroupHeader(
      groupID: SidebarGroupID,
      name: String,
      isCollapsed: Bool,
      memberRepositoryIDs: [Repository.ID],
      leafRowIDs: [Worktree.ID]
    )
    case repository(repositoryID: Repository.ID, groups: [SidebarItemGroup])
    case folder(repositoryID: Repository.ID, rowID: Worktree.ID)
    case failedRepository(
      repositoryID: Repository.ID,
      rootURL: URL,
      customTitle: String?,
      color: RepositoryColor?,
      isRemote: Bool
    )
    case placeholder

    var id: SectionID {
      switch self {
      case .highlight(let kind, _): .highlight(kind)
      case .repoGroupHeader(let groupID, _, _, _, _): .repoGroupHeader(groupID)
      case .repository(let repositoryID, _): .repository(repositoryID)
      case .folder(let repositoryID, _): .folder(repositoryID)
      case .failedRepository(let repositoryID, _, _, _, _): .failedRepository(repositoryID)
      case .placeholder: .placeholder
      }
    }

    enum SectionID: Hashable, Sendable {
      case highlight(HighlightKind)
      case repoGroupHeader(SidebarGroupID)
      case repository(Repository.ID)
      case folder(Repository.ID)
      case failedRepository(Repository.ID)
      case placeholder
    }
  }

  var sections: [Section]
  /// Union of every hoisted row across the highlight sections. Per-repo
  /// payloads have already filtered against this set; exposed for hotkey
  /// consumers and ad-hoc lookups.
  var hoistedRowIDs: Set<Worktree.ID>
  /// Pre-projected menu slots for `focusedSceneValue(\.visibleHotkeyWorktreeRows, …)`.
  var hotkeySlots: [HotkeyWorktreeSlot]
  /// Visible top-down position of each hotkey-eligible row, used by the
  /// view's `commandKeyObserver`-gated shortcut hint render.
  var slotByID: [Worktree.ID: Int]
  /// Per-repo color + name payload used to render the `repo · trail`
  /// subtitle on highlight rows. Built only for repos that contributed at
  /// least one row to the highlight sections.
  var repositoryHighlightByID: [Repository.ID: SidebarHighlightRepoTag]
  /// Per-repo hoisted-row tally; git repos only, built only for repos that
  /// contributed at least one highlight row.
  var hoistSummaryByRepositoryID: [Repository.ID: SidebarHoistSummary]
  /// Outer-ForEach data ordering for repository sections. The view uses
  /// this to translate `.onMove` flat offsets into the index space the
  /// `.repositoriesMoved` reducer action expects.
  var reorderableRepositoryIDs: [Repository.ID]
  /// Repositories whose section rendered under an expanded group header.
  /// The view indents these so they read as children of the group.
  var groupedRepositoryIDs: Set<Repository.ID>

  static let empty = SidebarStructure(
    sections: [],
    hoistedRowIDs: [],
    hotkeySlots: [],
    slotByID: [:],
    repositoryHighlightByID: [:],
    hoistSummaryByRepositoryID: [:],
    reorderableRepositoryIDs: [],
    groupedRepositoryIDs: []
  )

  /// First-frame value used before the reducer recomputes. Surfaces the
  /// placeholder section immediately so the sidebar isn't blank during the
  /// brief window between `init` and the first `.task` effect.
  static let placeholder = SidebarStructure(
    sections: [.placeholder],
    hoistedRowIDs: [],
    hotkeySlots: [],
    slotByID: [:],
    repositoryHighlightByID: [:],
    hoistSummaryByRepositoryID: [:],
    reorderableRepositoryIDs: [],
    groupedRepositoryIDs: []
  )
}

extension RepositoriesFeature.State {
  /// Equatable-diffs the freshly-built structure against the cached one so a
  /// no-op rebuild doesn't invalidate SwiftUI observation.
  mutating func recomputeSidebarStructureIfChanged() {
    @Shared(.sidebarGroupPinnedRows) var groupPinned
    @Shared(.sidebarGroupActiveRows) var groupActive
    let new = computeSidebarStructure(
      groupPinned: groupPinned,
      groupActive: groupActive
    )
    if new != sidebarStructure {
      sidebarStructure = new
    }
  }

  /// Refreshes the cached `selectedWorktreeSlice` from the focused row, using
  /// an Equatable diff so observation only invalidates on a real change.
  /// Mirrors `recomputeSidebarStructureIfChanged()` for slice-affecting
  /// actions; per-leaf reads on `sidebarItems[id:]` happen here, not in views.
  mutating func recomputeSelectedWorktreeSliceIfChanged() {
    let new = selectedRow(for: selectedWorktreeID).map { SelectedWorktreeSlice($0) }
    if new != selectedWorktreeSlice {
      selectedWorktreeSlice = new
    }
  }

  /// Equatable-diffs the toolbar notification snapshot against the cache so a
  /// per-row notification append only invalidates SwiftUI when the toolbar
  /// projection actually changes.
  mutating func recomputeToolbarNotificationGroupsIfChanged() {
    let new = computeToolbarNotificationGroups()
    if new != toolbarNotificationGroupsCache {
      toolbarNotificationGroupsCache = new
    }
  }
}

/// Per-cache invalidation flag set returned by every reducer action. Exhaustive
/// switches over the action enums force every new case to declare which
/// post-reduce caches it touches; a missing case is a compile error rather
/// than a silent "skip the recompute".
struct CacheInvalidations: OptionSet {
  let rawValue: UInt8
  static let sidebarStructure = CacheInvalidations(rawValue: 1 << 0)
  static let selectedWorktreeSlice = CacheInvalidations(rawValue: 1 << 1)
  static let toolbarNotificationGroups = CacheInvalidations(rawValue: 1 << 2)
  static let all: CacheInvalidations = [
    .sidebarStructure, .selectedWorktreeSlice, .toolbarNotificationGroups,
  ]
}

extension SidebarItemFeature.Action {
  var cacheInvalidations: CacheInvalidations {
    switch self {
    case .lifecycleChanged, .runningScriptStarted, .runningScriptStopped:
      return [.sidebarStructure, .selectedWorktreeSlice]
    case .agentSnapshotChanged:
      return .sidebarStructure
    case .terminalProjectionChanged:
      return [.sidebarStructure, .toolbarNotificationGroups]
    case .pullRequestChanged:
      return .selectedWorktreeSlice
    case .diffStatsChanged, .pullRequestQueryStarted,
      .dragSessionChanged,
      .focusTerminalRequested, .focusTerminalConsumed:
      return []
    }
  }
}

extension RepositoriesFeature.Action {
  /// Exhaustive cache-invalidation map. Update this alongside every new
  /// `RepositoriesFeature.Action` case. Adding a case without listing it here
  /// is a compile error (no `default`), so we never silently regress the
  /// "post-reduce skips the recompute" path.
  var cacheInvalidations: CacheInvalidations {
    switch self {
    case .sidebarItems(.element(id: _, action: let inner)):
      return inner.cacheInvalidations
    case .sidebarItems:
      return []

    // Sidebar layout toggles only.
    case .sidebarGroupingTogglesChanged, .sidebarNestByBranchChanged,
      .repositoryExpansionChanged, .branchNestExpansionChanged,
      .repositoriesMoved, .pinnedWorktreesMoved, .unpinnedWorktreesMoved,
      .worktreeNotificationReceived, .worktreeLineChangesLoaded,
      .consumeTerminalFocus:
      return .sidebarStructure

    // Repo-group mutations reshape the section list (and thereby hotkeys).
    case .sidebarGroupSetCollapsed, .sidebarGroupAssignRepository,
      .sidebarGroupDissolved, .sidebarGroupMoved:
      return .sidebarStructure

    // Name-sheet submit creates or renames a group; the header title lives
    // in the structure. Every other prompt action is presentation-only.
    case .sidebarGroupNamePrompt(.presented(.delegate(.submitted))):
      return .sidebarStructure
    case .sidebarGroupNamePrompt:
      return []

    // Sheet presentation only; the structure changes on submit.
    case .sidebarGroupCreateRequested, .sidebarGroupRenameRequested:
      return []

    // Bulk repository / worktree set changes that touch all caches.
    case .repositoriesLoaded, .openRepositoriesFinished,
      .repositoryRemovalCompleted, .repositoriesRemoved,
      .removeFailedRepository, .remoteRepositoryResolved,
      .archiveWorktreeApply, .unarchiveWorktree,
      .deleteWorktreeApply, .worktreeDeleted,
      .createWorktreeInRepository, .createRandomWorktreeInRepository,
      .autoDeleteExpiredArchivedWorktrees:
      return .all

    // `worktreeInfoEvent` is a pure effect-launcher (HEAD watcher tick): the
    // arm only spawns `.run { ... await send(.branchNameLoaded(...)) }` etc.
    // and never mutates `state`. The downstream `.worktreeBranchNameLoaded` /
    // `.repositoryPullRequestsLoaded` arms declare their own invalidations.
    case .worktreeInfoEvent:
      return []

    // Pure effect launcher: spawns the async SSH resolution, mutates no state.
    // The per-repo `.remoteRepositoryResolved` results recompute the caches.
    case .resolveRemoteRepositories:
      return []

    // Pure signal observed by AppFeature to drain a parked CLI ack; no state.
    case .cliWorktreeAckCancelled:
      return []

    // `worktreeBranchNameLoaded` mutates `worktree.name` via `updateWorktreeName`,
    // which feeds `computeToolbarNotificationGroups()` (notification group title).
    // Without `.toolbarNotificationGroups` the popover would show the old name
    // until an unrelated bulk action recomputed the cache.
    case .worktreeBranchNameLoaded:
      return .all

    // Layout + slice but not the notification snapshot (no notification touch).
    case .createRandomWorktreeSucceeded, .createRandomWorktreeFailed,
      .pendingWorktreeProgressUpdated,
      .archiveScriptCompleted, .deleteScriptCompleted, .scriptCompleted,
      .consumeSetupScript,
      .pinWorktree, .unpinWorktree,
      .repositoryPullRequestsLoaded:
      return [.sidebarStructure, .selectedWorktreeSlice]

    // Selection changes only refresh the slice.
    case .selectionChanged, .selectWorktree, .selectArchivedWorktrees,
      .selectNextWorktree, .selectPreviousWorktree, .selectWorktreeAtHotkeySlot,
      .worktreeHistoryBack, .worktreeHistoryForward:
      return .selectedWorktreeSlice

    // Repo customization save mutates the section title / color, which flow
    // into the sidebar layout's highlight tag and the notification group name.
    case .repositoryCustomization(.presented(.delegate(.save))):
      return .all
    case .repositoryCustomization:
      return []

    // Worktree customization save mutates the bucketed Item's title / color, picked up via
    // per-row `customTitle` / `customTint` mirror (highlight tags + notification group name).
    case .worktreeCustomization(.presented(.delegate(.save))):
      return .all
    case .worktreeCustomization:
      return []

    // Branch rename updates the worktree.name shown in the sidebar row and notification group.
    case .renameBranchPrompt(.presented(.delegate(.renamed))):
      return .all
    case .renameBranchPrompt:
      return []

    // Everything else is UI / effects / transient state, no cache touched.
    case .task, .setOpenPanelPresented,
      .requestAddRemoteRepository, .requestEditRemoteRepository, .remoteConnectionForm,
      .requestCloneRepository, .cloneRepositoryForm,
      .loadPersistedRepositories,
      .removeRemoteRepository,
      .refreshWorktrees, .reloadRepositories,
      .setSidebarSelectedWorktreeIDs,
      .openRepositories,
      .revealSelectedWorktreeInSidebar, .revealHoistedWorktreeInSidebar,
      .consumePendingSidebarReveal,
      .createRandomWorktree,
      .promptedWorktreeCreationDataLoaded, .promptedWorktreeBranchesLoaded,
      .startPromptedWorktreeCreation,
      .promptedWorktreeCreationChecked,
      .requestArchiveWorktree, .requestArchiveWorktrees,
      .archiveWorktreeConfirmed,
      .requestDeleteSidebarItems, .deleteSidebarItemConfirmed,
      .deleteWorktreeFailed,
      .requestDeleteRepository, .requestRemoveFailedRepository,
      .presentAlert,
      .refreshGithubIntegrationAvailability,
      .githubIntegrationAvailabilityUpdated,
      .repositoryPullRequestRefreshCompleted,
      .setGithubIntegrationEnabled,
      .setMergedWorktreeAction,
      .setAutoDeleteArchivedWorktreesAfterDays,
      .setMoveNotifiedWorktreeToTop,
      .pullRequestAction,
      .showToast, .dismissToast,
      .delayedPullRequestRefresh,
      .openRepositorySettings, .requestCustomizeRepository,
      .requestCustomizeWorktree,
      .requestRenameBranch,
      .contextMenuOpenWorktree,
      .worktreeCreationPrompt,
      .alert,
      .delegate:
      return []
    }
  }
}

extension RepositoriesFeature.State {
  /// Single source of truth for the post-reduce cache recompute. The
  /// production hook in `RepositoriesFeature.body` and the test mirror in
  /// `RepositoriesSidebarTestHelpers` both call this so a fourth cache lands
  /// in one place instead of needing two coordinated updates.
  @MainActor
  mutating func applyCacheRecomputes(_ invalidations: CacheInvalidations) {
    if invalidations.contains(.sidebarStructure) {
      recomputeSidebarStructureIfChanged()
    }
    if invalidations.contains(.selectedWorktreeSlice) {
      recomputeSelectedWorktreeSliceIfChanged()
    }
    if invalidations.contains(.toolbarNotificationGroups) {
      recomputeToolbarNotificationGroupsIfChanged()
    }
  }

  /// Pinned worktree IDs across every repository in the user's repo order.
  /// Git main worktrees are excluded (they belong to the per-repo main slot,
  /// not the user-curated pinned list). Folders seed into `.unpinned` by
  /// default and only appear here after an explicit pin. Archived rows are
  /// filtered for parity with the Active candidate filter. The optional
  /// `archived` parameter lets a caller share an already-computed set with
  /// the aggregator so the O(R) walk runs once per call body, not twice.
  func orderedHighlightPinnedIDs(archived: Set<Worktree.ID>? = nil) -> [SidebarItemID] {
    let archivedSet = archived ?? archivedWorktreeIDSet
    var ids: [SidebarItemID] = []
    for repoID in orderedRepositoryIDs() {
      guard let repository = repositories[id: repoID] else { continue }
      let isGit = repository.isGitRepository
      for worktreeID in sidebar.sections[repoID]?.buckets[.pinned]?.items.keys ?? [] {
        if isGit, let worktree = repository.worktrees[id: worktreeID], isMainWorktree(worktree) {
          continue
        }
        if archivedSet.contains(worktreeID) { continue }
        ids.append(worktreeID)
      }
    }
    return ids
  }

  /// Derive the full sidebar render plan in a single pass. Called by the
  /// reducer (see `recomputeSidebarStructure(...)`); never call from a view
  /// body or the per-leaf reads here will observation-track every row at
  /// the parent and reintroduce the regression commit `0a1ed578` documents.
  func computeSidebarStructure(
    groupPinned: Bool,
    groupActive: Bool
  ) -> SidebarStructure {
    if !isInitialLoadComplete, repositories.isEmpty {
      return SidebarStructure(
        sections: [.placeholder],
        hoistedRowIDs: [],
        hotkeySlots: [],
        slotByID: [:],
        repositoryHighlightByID: [:],
        hoistSummaryByRepositoryID: [:],
        reorderableRepositoryIDs: [],
        groupedRepositoryIDs: []
      )
    }

    let hoists = computeHighlightHoists(groupPinned: groupPinned, groupActive: groupActive)
    let repoSections = buildRepositorySections(hoisted: hoists.hoistedSet)

    var sections: [SidebarStructure.Section] = []
    if !hoists.pinned.isEmpty {
      sections.append(.highlight(kind: .pinned, rowIDs: hoists.pinned))
    }
    if !hoists.active.isEmpty {
      sections.append(.highlight(kind: .active, rowIDs: hoists.active))
    }
    sections.append(contentsOf: repoSections.sections)

    let hotkey = computeHotkeyOrdering(
      pinnedHoisted: hoists.pinned,
      activeHoisted: hoists.active,
      hoisted: hoists.hoistedSet,
      sections: sections
    )

    let highlightProjections = computeRepositoryHighlightProjections(
      pinnedHoisted: hoists.pinned,
      activeHoisted: hoists.active
    )

    return SidebarStructure(
      sections: sections,
      hoistedRowIDs: hoists.hoistedSet,
      hotkeySlots: hotkey.slots,
      slotByID: hotkey.slotByID,
      repositoryHighlightByID: highlightProjections.tags,
      hoistSummaryByRepositoryID: highlightProjections.summaries,
      reorderableRepositoryIDs: repoSections.reorderableRepositoryIDs,
      groupedRepositoryIDs: repoSections.groupedRepositoryIDs
    )
  }

  /// Hoisted-row payload for a single structure pass.
  private struct HighlightHoists {
    var pinned: [Worktree.ID]
    var active: [Worktree.ID]
    var hoistedSet: Set<Worktree.ID>
  }

  private func computeHighlightHoists(groupPinned: Bool, groupActive: Bool) -> HighlightHoists {
    let archived = archivedWorktreeIDSet
    let pinned: [Worktree.ID]
    if groupPinned {
      let pinnedIDs = orderedHighlightPinnedIDs(archived: archived)
      pinned = orderedHighlightCandidates(forPinned: true, candidateIDs: pinnedIDs, excluding: [])
    } else {
      pinned = []
    }
    var hoistedSet: Set<Worktree.ID> = Set(pinned)

    let active: [Worktree.ID]
    if groupActive {
      let candidateIDs = sidebarItems.ids.filter { id in
        guard !archived.contains(id) else { return false }
        guard let item = sidebarItems[id: id] else { return false }
        // Terminating rows already signal their wind-down inline.
        guard !item.lifecycle.isTerminating else { return false }
        // Orphan rows have no working dir for the agent/script badge to act on.
        return !item.isMissing
      }
      active = orderedHighlightCandidates(
        forPinned: false,
        candidateIDs: Array(candidateIDs),
        excluding: hoistedSet
      )
      hoistedSet.formUnion(active)
    } else {
      active = []
    }
    return HighlightHoists(pinned: pinned, active: active, hoistedSet: hoistedSet)
  }

  /// Per-repo dispatch output.
  private struct RepositorySectionsBuild {
    var sections: [SidebarStructure.Section]
    var reorderableRepositoryIDs: [Repository.ID]
    var groupedRepositoryIDs: Set<Repository.ID>
  }

  private func buildRepositorySections(hoisted: Set<Worktree.ID>) -> RepositorySectionsBuild {
    var sections: [SidebarStructure.Section] = []
    var reorderableRepositoryIDs: [Repository.ID] = []
    var groupedRepositoryIDs: Set<Repository.ID> = []
    let pendingIDsByRepo: [Repository.ID: Set<Worktree.ID>] = Dictionary(
      grouping: pendingWorktrees,
      by: \.repositoryID
    ).mapValues { Set($0.map(\.id)) }
    // Failed local repos have no `repositories[id:]` entry, so resolve their
    // root from the persisted `repositoryRoots` instead.
    let localRootsByID: [Repository.ID: URL] = Dictionary(
      uniqueKeysWithValues: repositoryRoots.map {
        (RepositoryID($0.standardizedFileURL.path(percentEncoded: false)), $0.standardizedFileURL)
      }
    )

    // Local and remote repositories share one flat, reorderable order driven by
    // `orderedRepositoryIDs()` (local roots and host-keyed remote ids honoring
    // the persisted sidebar order). Remote repos are no longer pinned below the
    // local ones: the user can interleave local and remote rows by drag.
    // `reorderableRepositoryIDs` mirrors `orderedRepositoryIDs()` 1:1 (even ids
    // with no rendered section, e.g. a still-loading root or a hoisted folder)
    // so the offset-based `.repositoriesMoved` move maps cleanly back.
    let ordered = orderedRepositoryIDs()

    // Membership resolved once up front: a group renders at the position of
    // its first member, pulling all members together even if a stray persisted
    // order left them non-contiguous (the mutation API keeps them contiguous
    // by construction; this walk is the render-side safety net).
    var membersByGroup: [SidebarGroupID: [Repository.ID]] = [:]
    for repositoryID in ordered {
      if let groupID = sidebar.groupID(of: repositoryID) {
        membersByGroup[groupID, default: []].append(repositoryID)
      }
    }

    var emittedGroups: Set<SidebarGroupID> = []
    for repositoryID in ordered {
      reorderableRepositoryIDs.append(repositoryID)
      guard let groupID = sidebar.groupID(of: repositoryID) else {
        if let section = repositorySection(
          for: repositoryID,
          hoisted: hoisted,
          pendingIDsByRepo: pendingIDsByRepo,
          localRootsByID: localRootsByID
        ) {
          sections.append(section)
        }
        continue
      }
      guard emittedGroups.insert(groupID).inserted else { continue }
      let members = membersByGroup[groupID] ?? []
      let group = sidebar.groups[groupID]
      let isCollapsed = group?.collapsed ?? false
      sections.append(
        .repoGroupHeader(
          groupID: groupID,
          name: group?.name ?? "",
          isCollapsed: isCollapsed,
          memberRepositoryIDs: members,
          leafRowIDs: isCollapsed ? groupLeafRowIDs(members: members, hoisted: hoisted) : []
        )
      )
      guard !isCollapsed else { continue }
      for member in members {
        if let section = repositorySection(
          for: member,
          hoisted: hoisted,
          pendingIDsByRepo: pendingIDsByRepo,
          localRootsByID: localRootsByID
        ) {
          sections.append(section)
          groupedRepositoryIDs.insert(member)
        }
      }
    }

    return RepositorySectionsBuild(
      sections: sections,
      reorderableRepositoryIDs: reorderableRepositoryIDs,
      groupedRepositoryIDs: groupedRepositoryIDs
    )
  }

  /// Render section for a single repository id, or `nil` when nothing should
  /// render (still-loading root, hoisted folder row). Extracted from the
  /// `buildRepositorySections` walk so grouped and top-level repos share one
  /// code path.
  private func repositorySection(
    for repositoryID: Repository.ID,
    hoisted: Set<Worktree.ID>,
    pendingIDsByRepo: [Repository.ID: Set<Worktree.ID>],
    localRootsByID: [Repository.ID: URL]
  ) -> SidebarStructure.Section? {
    let repository = repositories[id: repositoryID]
    let isRemote = repository?.host != nil

    // A disconnected remote keeps a placeholder repository (so it isn't
    // pruned) plus a load failure; render it like a missing local folder.
    if loadFailuresByID[repositoryID] != nil {
      guard let rootURL = localRootsByID[repositoryID] ?? repository?.rootURL else { return nil }
      let sectionEntry = sidebar.sections[repositoryID]
      // A folder's custom name / color live on its synthetic folder-worktree
      // item (the row is a worktree row), not the section, so fall back to it.
      let folderItem = sectionEntry?.folderWorktreeItem(for: repositoryID)
      return .failedRepository(
        repositoryID: repositoryID,
        rootURL: rootURL,
        customTitle: sectionEntry?.title ?? folderItem?.title,
        color: sectionEntry?.color ?? folderItem?.color,
        isRemote: isRemote
      )
    }

    guard let repository else { return nil }

    if !repository.isGitRepository {
      // Local folder rows key off the path-derived synthetic id; a remote
      // folder uses its synthetic worktree's own host-keyed id so it never
      // collides with a local folder at the same path.
      let folderRowID =
        isRemote ? repository.worktrees.first?.id : Repository.folderWorktreeID(for: repository.rootURL)
      guard let folderRowID, !hoisted.contains(folderRowID) else { return nil }
      return .folder(repositoryID: repositoryID, rowID: folderRowID)
    }

    let groups = SidebarItemGroup.computeSlots(
      in: self,
      repositoryID: repositoryID,
      pendingIDs: pendingIDsByRepo[repositoryID] ?? [],
      hoistedRowIDs: hoisted,
      nestWorktreesByBranch: sidebarNestWorktreesByBranch && repository.isGitRepository
    )
    return .repository(repositoryID: repositoryID, groups: groups)
  }

  /// Visible (non-archived, non-hoisted) row ids across a collapsed group's
  /// members, feeding the header's aggregated activity indicators. Hoisted
  /// rows are excluded because they stay visible in the highlight sections
  /// even while the group is collapsed.
  private func groupLeafRowIDs(
    members: [Repository.ID],
    hoisted: Set<Worktree.ID>
  ) -> [Worktree.ID] {
    var ids: [Worktree.ID] = []
    for repositoryID in members {
      guard let bucket = sidebarGrouping.bucketsByRepository[repositoryID] else { continue }
      for id in bucket[.pinned] where !hoisted.contains(id) { ids.append(id) }
      for id in bucket[.unpinned] where !hoisted.contains(id) { ids.append(id) }
    }
    return ids
  }

  /// Hotkey assignment output for a single structure pass.
  private struct HotkeyOrdering {
    var slots: [HotkeyWorktreeSlot]
    var slotByID: [Worktree.ID: Int]
  }

  private func computeHotkeyOrdering(
    pinnedHoisted: [Worktree.ID],
    activeHoisted: [Worktree.ID],
    hoisted: Set<Worktree.ID>,
    sections: [SidebarStructure.Section]
  ) -> HotkeyOrdering {
    let perRepoVisibleIDs = hotkeyEligibleIDs(in: sections)
    var order: [Worktree.ID] = []
    order.reserveCapacity(pinnedHoisted.count + activeHoisted.count + perRepoVisibleIDs.count)
    order.append(contentsOf: pinnedHoisted)
    order.append(contentsOf: activeHoisted)
    for id in perRepoVisibleIDs where !hoisted.contains(id) {
      order.append(id)
    }
    var slotByID: [Worktree.ID: Int] = [:]
    slotByID.reserveCapacity(order.count)
    for (index, id) in order.enumerated() {
      slotByID[id] = index
    }
    return HotkeyOrdering(slots: hotkeyWorktreeSlots(for: order), slotByID: slotByID)
  }

  /// Per-repo highlight projections derived in a single walk of the hoisted
  /// arrays.
  private struct HighlightProjections {
    var tags: [Repository.ID: SidebarHighlightRepoTag]
    var summaries: [Repository.ID: SidebarHoistSummary]
  }

  /// Resolve the highlight tags (every contributing repo) and the hoist
  /// summaries (git repos only) in one pass. Walks the ordered arrays, not
  /// `hoistedSet`, so `revealTarget` is deterministic: a repo's first pinned
  /// hoist, else its first active.
  private func computeRepositoryHighlightProjections(
    pinnedHoisted: [Worktree.ID],
    activeHoisted: [Worktree.ID]
  ) -> HighlightProjections {
    guard !pinnedHoisted.isEmpty || !activeHoisted.isEmpty else {
      return HighlightProjections(tags: [:], summaries: [:])
    }

    var contributingRepoIDs: Set<Repository.ID> = []
    var pinnedCounts: [Repository.ID: Int] = [:]
    var activeCounts: [Repository.ID: Int] = [:]
    var firstPinned: [Repository.ID: Worktree.ID] = [:]
    var firstActive: [Repository.ID: Worktree.ID] = [:]

    for id in pinnedHoisted {
      guard let repoID = sidebarItems[id: id]?.repositoryID else { continue }
      contributingRepoIDs.insert(repoID)
      pinnedCounts[repoID, default: 0] += 1
      if firstPinned[repoID] == nil { firstPinned[repoID] = id }
    }
    for id in activeHoisted {
      guard let repoID = sidebarItems[id: id]?.repositoryID else { continue }
      contributingRepoIDs.insert(repoID)
      activeCounts[repoID, default: 0] += 1
      if firstActive[repoID] == nil { firstActive[repoID] = id }
    }

    // Output is keyed by repo id, so build order is irrelevant.
    var tags: [Repository.ID: SidebarHighlightRepoTag] = [:]
    var summaries: [Repository.ID: SidebarHoistSummary] = [:]
    for repoID in contributingRepoIDs {
      guard let repository = repositories[id: repoID] else { continue }
      let section = sidebar.sections[repoID]
      tags[repoID] = SidebarHighlightRepoTag(
        repoName: Repository.sidebarDisplayName(custom: section?.title, fallback: repository.name),
        repoColor: section?.color,
        hostInfo: repository.host?.displayAuthority
      )
      guard repository.isGitRepository, let revealTarget = firstPinned[repoID] ?? firstActive[repoID] else {
        continue
      }
      summaries[repoID] = SidebarHoistSummary(
        pinnedCount: pinnedCounts[repoID] ?? 0,
        activeCount: activeCounts[repoID] ?? 0,
        revealTarget: revealTarget
      )  // Non-nil: `revealTarget` exists only when a bucket contributed a row.
    }
    return HighlightProjections(tags: tags, summaries: summaries)
  }

  /// Walk the freshly-built sections to extract visible per-repo row IDs in
  /// the same top-down order the user sees them. Skips group headers (only
  /// leaves get hotkeys) and falls back to `orderedSidebarItemIDs` for repo
  /// sections where branch nesting hides some rows inside collapsed groups.
  private func hotkeyEligibleIDs(in sections: [SidebarStructure.Section]) -> [Worktree.ID] {
    let expandedRepoIDs = expandedRepositoryIDs
    let nestingFilter = orderedSidebarItemIDs(includingRepositoryIDs: expandedRepoIDs)
    let visibleSet = Set(nestingFilter)
    var ids: [Worktree.ID] = []
    for section in sections {
      switch section {
      // Collapsed groups already omit their member repo sections from
      // `sections`, so their rows drop out of hotkey numbering here for free.
      case .highlight, .placeholder, .failedRepository, .repoGroupHeader:
        continue
      case .folder(_, let rowID):
        ids.append(rowID)
      case .repository(let repositoryID, let groups):
        guard expandedRepoIDs.contains(repositoryID) else { continue }
        for group in groups {
          for rowID in group.rowIDs where visibleSet.contains(rowID) {
            ids.append(rowID)
          }
        }
      }
    }
    return ids
  }

  /// Materialize candidates by reading branchName + classification flags
  /// from each leaf, then delegate to the pure `SidebarHighlightOrdering`
  /// sorter.
  private func orderedHighlightCandidates(
    forPinned: Bool,
    candidateIDs: [SidebarItemID],
    excluding: Set<Worktree.ID>
  ) -> [Worktree.ID] {
    var candidates: [SidebarHighlightOrdering.Candidate] = []
    candidates.reserveCapacity(candidateIDs.count)
    for id in candidateIDs {
      if excluding.contains(id) { continue }
      guard let state = sidebarItems[id: id] else { continue }
      candidates.append(
        SidebarHighlightOrdering.Candidate(
          id: id,
          branchName: state.branchName,
          classification: SidebarActiveClassification.classify(state)
        )
      )
    }
    return SidebarHighlightOrdering.orderedRowIDs(forPinned: forPinned, candidates: candidates)
  }
}

extension SidebarItemGroup {
  /// Split one repo's bucketed item IDs into the four ordered slots the
  /// sidebar renders (`main`, `pinnedTail`, `pending`, `unpinnedTail`), then
  /// filter against `hoistedRowIDs` and dedupe across slots via a seen-set
  /// so a row that survived a pre-existing double-bucket pre-state renders
  /// in at most one position (priority order: main > pinnedTail > pending >
  /// unpinnedTail).
  ///
  /// `nestWorktreesByBranch` should be the effective per-repo value
  /// (`@Shared(.sidebarNestWorktreesByBranch)` gated on `isGitRepository`).
  /// When set, the pinned and unpinned tails are sorted by branch name
  /// (case-insensitive) to match `SidebarBranchNesting.buildRows`, so the
  /// hotkey / arrow projection that walks `rowIDs` sees the same top-down
  /// order the view renders. Main and pending slots stay in bucket order
  /// (they don't participate in branch nesting).
  static func computeSlots(
    in state: RepositoriesFeature.State,
    repositoryID: Repository.ID,
    pendingIDs: Set<Worktree.ID>,
    hoistedRowIDs: Set<Worktree.ID>,
    nestWorktreesByBranch: Bool
  ) -> [SidebarItemGroup] {
    guard let bucket = state.sidebarGrouping.bucketsByRepository[repositoryID] else { return [] }
    let pinnedRows = bucket[.pinned]
    let unpinnedRows = bucket[.unpinned]

    // Scan the whole pinned bucket: rebuild seeds main at index 0, but a
    // corrupted persisted `.pinned` (hand-edit, migrator race) may surface
    // main at a non-zero position. Matching `orderedPinnedWorktreeIDs`'s
    // any-position filter keeps `pinnedTail` and the reducer's source list
    // in agreement for `translateFilteredMove`.
    let rawMainID: SidebarItemID? = pinnedRows.first(where: { id in
      state.sidebarItems[id: id]?.isMainWorktree == true
    })

    var seen: Set<Worktree.ID> = []
    var mainID: SidebarItemID?
    if let rawMainID {
      seen.insert(rawMainID)
      if !hoistedRowIDs.contains(rawMainID) { mainID = rawMainID }
    }

    var rawPinnedTail: [SidebarItemID] = []
    for id in pinnedRows where id != rawMainID && !seen.contains(id) {
      rawPinnedTail.append(id)
      seen.insert(id)
    }
    var rawPendingTail: [SidebarItemID] = []
    for id in unpinnedRows where pendingIDs.contains(id) && !seen.contains(id) {
      rawPendingTail.append(id)
      seen.insert(id)
    }
    var rawUnpinnedTail: [SidebarItemID] = []
    for id in unpinnedRows where !pendingIDs.contains(id) && !seen.contains(id) {
      rawUnpinnedTail.append(id)
      seen.insert(id)
    }

    // Read live lifecycle here (the `.deletingScript` flip recomputes the
    // structure but not the grouping). Render-only: the surfaced row is absent
    // from the nav, hotkey, and multi-select projections, which exclude archived.
    if let archivedItems = state.sidebar.sections[repositoryID]?.buckets[.archived]?.items {
      for id in archivedItems.keys
      where state.sidebarItems[id: id]?.lifecycle == .deletingScript && !seen.contains(id) {
        rawUnpinnedTail.append(id)
        seen.insert(id)
      }
    }

    var pinnedTail = rawPinnedTail.filter { !hoistedRowIDs.contains($0) }
    let pendingTail = rawPendingTail.filter { !hoistedRowIDs.contains($0) }
    var unpinnedTail = rawUnpinnedTail.filter { !hoistedRowIDs.contains($0) }

    if nestWorktreesByBranch {
      pinnedTail = sortedByBranchName(pinnedTail, in: state)
      unpinnedTail = sortedByBranchName(unpinnedTail, in: state)
    }

    let isSoleDefaultWorktree =
      mainID != nil && pinnedTail.isEmpty && pendingTail.isEmpty && unpinnedTail.isEmpty

    return [
      SidebarItemGroup(
        slot: .main(isSole: isSoleDefaultWorktree),
        repositoryID: repositoryID,
        rowIDs: mainID.map { [$0] } ?? []
      ),
      SidebarItemGroup(
        slot: .pinnedTail,
        repositoryID: repositoryID,
        rowIDs: pinnedTail
      ),
      SidebarItemGroup(
        slot: .pending,
        repositoryID: repositoryID,
        rowIDs: pendingTail
      ),
      SidebarItemGroup(
        slot: .unpinnedTail,
        repositoryID: repositoryID,
        rowIDs: unpinnedTail
      ),
    ]
  }

  /// Case-insensitive sort by `branchName`, matching `SidebarBranchNesting.buildRows`.
  /// Fallback to the row id keeps a transient missing leaf from breaking sort
  /// stability rather than crashing.
  private static func sortedByBranchName(
    _ ids: [SidebarItemID],
    in state: RepositoriesFeature.State
  ) -> [SidebarItemID] {
    ids.sorted { lhs, rhs in
      let lhsName = state.sidebarItems[id: lhs]?.branchName ?? lhs.rawValue
      let rhsName = state.sidebarItems[id: rhs]?.branchName ?? rhs.rawValue
      return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
    }
  }

  /// SwiftUI emits `.onMove` offsets/destination against the *visible* rows
  /// (the post-hoisting filter). The reducer's `pinnedWorktreesMoved` /
  /// `unpinnedWorktreesMoved` mutates the *full* bucket. Translate visible
  /// indices to full-bucket indices before dispatching so a reorder inside a
  /// bucket with hoisted rows lands the dragged row at the visible target
  /// without disturbing hoisted siblings' relative positions.
  ///
  /// Returns `nil` if the inputs disagree (visible id not present in full,
  /// or out-of-range offset / destination); the caller should drop the move.
  static func translateFilteredMove(
    offsets: IndexSet,
    destination: Int,
    visibleIDs: [Worktree.ID],
    fullIDs: [Worktree.ID]
  ) -> (offsets: IndexSet, destination: Int)? {
    guard destination >= 0, destination <= visibleIDs.count else { return nil }
    var fullIndexByID: [Worktree.ID: Int] = [:]
    fullIndexByID.reserveCapacity(fullIDs.count)
    for (index, id) in fullIDs.enumerated() { fullIndexByID[id] = index }

    var translatedOffsets = IndexSet()
    for visibleIndex in offsets {
      guard visibleIDs.indices.contains(visibleIndex) else { return nil }
      guard let fullIndex = fullIndexByID[visibleIDs[visibleIndex]] else { return nil }
      translatedOffsets.insert(fullIndex)
    }

    let translatedDestination: Int
    if destination == visibleIDs.count {
      translatedDestination = fullIDs.count
    } else if let fullIndex = fullIndexByID[visibleIDs[destination]] {
      translatedDestination = fullIndex
    } else {
      return nil
    }
    return (translatedOffsets, translatedDestination)
  }
}

extension SidebarState.Section {
  /// A folder repo's custom title / color live on its synthetic folder-worktree
  /// item (the row is a worktree row), keyed by the repo id string.
  fileprivate func folderWorktreeItem(for repositoryID: Repository.ID) -> SidebarState.Item? {
    let folderID = WorktreeID(repositoryID.rawValue)
    return buckets[.pinned]?.items[folderID] ?? buckets[.unpinned]?.items[folderID]
  }
}
