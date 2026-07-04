import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct CustomCodeFeatureTests {
  @Test(.dependencies) func selectionRendersWhenScriptPresentAndPanelShown() async {
    let worktree = makeWorktree()
    let initialState = makeState(panelOpenFor: worktree)
    let store = TestStore(initialState: initialState) {
      CustomCodeFeature()
    } withDependencies: {
      $0[CustomCodeClient.self].pagePresent = { _ in true }
      $0[CustomCodeClient.self].renderPage = { _ in "<html>ok</html>" }
    }

    await store.send(.selectionChanged(worktree)) {
      $0.worktree = worktree
      $0.isCheckingPresence = true
    }
    await store.receive(.presenceResolved(worktreeID: worktree.id, result: .success(true))) {
      $0.isCheckingPresence = false
      $0.scriptPresent = true
      $0.isRendering = true
    }
    await store.receive(
      .renderCompleted(worktreeID: worktree.id, result: .success("<html>ok</html>"))
    ) {
      $0.isRendering = false
      $0.html = "<html>ok</html>"
      $0.htmlByWorktreeID[worktree.id] = "<html>ok</html>"
    }
  }

  @Test(.dependencies) func remoteWorktreeRendersOverSSH() async {
    let worktree = makeRemoteWorktree()
    let initialState = makeState(panelOpenFor: worktree)
    let store = TestStore(initialState: initialState) {
      CustomCodeFeature()
    } withDependencies: {
      $0[CustomCodeClient.self].pagePresent = { _ in true }
      $0[CustomCodeClient.self].renderPage = { _ in "<html>remote</html>" }
    }

    await store.send(.selectionChanged(worktree)) {
      $0.worktree = worktree
      $0.isCheckingPresence = true
    }
    await store.receive(.presenceResolved(worktreeID: worktree.id, result: .success(true))) {
      $0.isCheckingPresence = false
      $0.scriptPresent = true
      $0.isRendering = true
    }
    await store.receive(
      .renderCompleted(worktreeID: worktree.id, result: .success("<html>remote</html>"))
    ) {
      $0.isRendering = false
      $0.html = "<html>remote</html>"
      $0.htmlByWorktreeID[worktree.id] = "<html>remote</html>"
    }
  }

  @Test(.dependencies) func unreachableHostSurfacesErrorInsteadOfMissingScript() async {
    let worktree = makeRemoteWorktree()
    let store = TestStore(initialState: CustomCodeFeature.State()) {
      CustomCodeFeature()
    } withDependencies: {
      $0[CustomCodeClient.self].pagePresent = { _ in
        throw CustomCodeError.hostUnreachable(destination: "customcode-vm")
      }
    }

    await store.send(.selectionChanged(worktree)) {
      $0.worktree = worktree
      $0.isCheckingPresence = true
    }
    await store.receive(
      .presenceResolved(
        worktreeID: worktree.id,
        result: .failure(.hostUnreachable(destination: "customcode-vm"))
      )
    ) {
      $0.isCheckingPresence = false
      $0.lastError = .hostUnreachable(destination: "customcode-vm")
    }
  }

  @Test(.dependencies) func selectionWithoutScriptClearsPage() async {
    let worktree = makeWorktree()
    var initialState = CustomCodeFeature.State()
    initialState.worktree = makeWorktree(path: "/tmp/other/wt")
    initialState.scriptPresent = true
    initialState.html = "<html>stale</html>"
    let store = TestStore(initialState: initialState) {
      CustomCodeFeature()
    } withDependencies: {
      $0[CustomCodeClient.self].pagePresent = { _ in false }
    }

    await store.send(.selectionChanged(worktree)) {
      $0.worktree = worktree
      $0.scriptPresent = false
      $0.html = nil
      $0.isCheckingPresence = true
    }
    await store.receive(.presenceResolved(worktreeID: worktree.id, result: .success(false))) {
      $0.isCheckingPresence = false
    }
  }

  @Test(.dependencies) func scriptRemovedDropsCachedPage() async {
    let worktree = makeWorktree()
    var initialState = makeState(panelOpenFor: worktree)
    initialState.worktree = worktree
    initialState.scriptPresent = true
    initialState.html = "<html>old</html>"
    initialState.htmlByWorktreeID[worktree.id] = "<html>old</html>"
    let store = TestStore(initialState: initialState) {
      CustomCodeFeature()
    } withDependencies: {
      $0[CustomCodeClient.self].pagePresent = { _ in false }
    }

    await store.send(.refreshRequested) {
      $0.isCheckingPresence = true
    }
    await store.receive(.presenceResolved(worktreeID: worktree.id, result: .success(false))) {
      $0.isCheckingPresence = false
      $0.scriptPresent = false
      $0.html = nil
      $0.htmlByWorktreeID[worktree.id] = nil
    }
  }

  @Test(.dependencies) func hiddenPanelResolvesPresenceButSkipsRender() async {
    let worktree = makeWorktree()
    let store = TestStore(initialState: CustomCodeFeature.State()) {
      CustomCodeFeature()
    } withDependencies: {
      $0[CustomCodeClient.self].pagePresent = { _ in true }
      $0[CustomCodeClient.self].renderPage = { _ in
        Issue.record("renderPage should not run while the panel is hidden")
        return ""
      }
    }

    await store.send(.selectionChanged(worktree)) {
      $0.worktree = worktree
      $0.isCheckingPresence = true
    }
    await store.receive(.presenceResolved(worktreeID: worktree.id, result: .success(true))) {
      $0.isCheckingPresence = false
      $0.scriptPresent = true
    }
  }

  @Test(.dependencies) func panelAppearedRechecksPresenceAndRenders() async {
    let worktree = makeWorktree()
    var initialState = makeState(panelOpenFor: worktree)
    initialState.worktree = worktree
    let store = TestStore(initialState: initialState) {
      CustomCodeFeature()
    } withDependencies: {
      $0[CustomCodeClient.self].pagePresent = { _ in true }
      $0[CustomCodeClient.self].renderPage = { _ in "<html>fresh</html>" }
    }

    await store.send(.panelAppeared) {
      $0.isCheckingPresence = true
    }
    await store.receive(.presenceResolved(worktreeID: worktree.id, result: .success(true))) {
      $0.isCheckingPresence = false
      $0.scriptPresent = true
      $0.isRendering = true
    }
    await store.receive(
      .renderCompleted(worktreeID: worktree.id, result: .success("<html>fresh</html>"))
    ) {
      $0.isRendering = false
      $0.html = "<html>fresh</html>"
      $0.htmlByWorktreeID[worktree.id] = "<html>fresh</html>"
    }
  }

  @Test(.dependencies) func panelAppearedSkipsDuplicateCheckWhileOneIsInFlight() async {
    let worktree = makeWorktree()
    var initialState = makeState(panelOpenFor: worktree)
    initialState.worktree = worktree
    initialState.isCheckingPresence = true
    let store = TestStore(initialState: initialState) {
      CustomCodeFeature()
    } withDependencies: {
      $0[CustomCodeClient.self].pagePresent = { _ in
        Issue.record("panelAppeared must not start a second presence check")
        return true
      }
    }

    await store.send(.panelAppeared)
    await store.finish()
  }

  @Test(.dependencies) func filesChangedRechecksPresenceAndRerenders() async {
    let worktree = makeWorktree()
    var initialState = makeState(panelOpenFor: worktree)
    initialState.worktree = worktree
    initialState.scriptPresent = true
    initialState.html = "<html>old</html>"
    let store = TestStore(initialState: initialState) {
      CustomCodeFeature()
    } withDependencies: {
      $0[CustomCodeClient.self].pagePresent = { _ in true }
      $0[CustomCodeClient.self].renderPage = { _ in "<html>new</html>" }
    }

    await store.send(.filesChanged(worktree.id)) {
      $0.isCheckingPresence = true
    }
    await store.receive(.presenceResolved(worktreeID: worktree.id, result: .success(true))) {
      $0.isCheckingPresence = false
      $0.isRendering = true
    }
    await store.receive(
      .renderCompleted(worktreeID: worktree.id, result: .success("<html>new</html>"))
    ) {
      $0.isRendering = false
      $0.html = "<html>new</html>"
      $0.htmlByWorktreeID[worktree.id] = "<html>new</html>"
    }
  }

  @Test(.dependencies) func filesChangedForOtherWorktreeIsIgnored() async {
    let worktree = makeWorktree()
    var initialState = CustomCodeFeature.State()
    initialState.worktree = worktree
    initialState.scriptPresent = true
    let store = TestStore(initialState: initialState) {
      CustomCodeFeature()
    }

    await store.send(.filesChanged("/tmp/unrelated/wt"))
    await store.finish()
  }

  @Test(.dependencies) func refreshDiscoversScriptAddedAfterSelection() async {
    let worktree = makeWorktree()
    var initialState = makeState(panelOpenFor: worktree)
    initialState.worktree = worktree
    initialState.scriptPresent = false
    let store = TestStore(initialState: initialState) {
      CustomCodeFeature()
    } withDependencies: {
      $0[CustomCodeClient.self].pagePresent = { _ in true }
      $0[CustomCodeClient.self].renderPage = { _ in "<html>found</html>" }
    }

    await store.send(.refreshRequested) {
      $0.isCheckingPresence = true
    }
    await store.receive(.presenceResolved(worktreeID: worktree.id, result: .success(true))) {
      $0.isCheckingPresence = false
      $0.scriptPresent = true
      $0.isRendering = true
    }
    await store.receive(
      .renderCompleted(worktreeID: worktree.id, result: .success("<html>found</html>"))
    ) {
      $0.isRendering = false
      $0.html = "<html>found</html>"
      $0.htmlByWorktreeID[worktree.id] = "<html>found</html>"
    }
  }

  @Test(.dependencies) func renderFailureSurfacesErrorMessage() async {
    let worktree = makeWorktree()
    var initialState = makeState(panelOpenFor: worktree)
    initialState.worktree = worktree
    initialState.scriptPresent = true
    let store = TestStore(initialState: initialState) {
      CustomCodeFeature()
    } withDependencies: {
      $0[CustomCodeClient.self].pagePresent = { _ in true }
      $0[CustomCodeClient.self].renderPage = { _ in throw CustomCodeError.uvMissing }
    }

    await store.send(.refreshRequested) {
      $0.isCheckingPresence = true
    }
    await store.receive(.presenceResolved(worktreeID: worktree.id, result: .success(true))) {
      $0.isCheckingPresence = false
      $0.isRendering = true
    }
    await store.receive(
      .renderCompleted(worktreeID: worktree.id, result: .failure(.uvMissing))
    ) {
      $0.isRendering = false
      $0.lastError = .uvMissing
    }
  }

  @Test(.dependencies) func deselectionClearsPageButKeepsCache() async {
    let worktree = makeWorktree()
    var initialState = CustomCodeFeature.State()
    initialState.worktree = worktree
    initialState.scriptPresent = true
    initialState.html = "<html>old</html>"
    initialState.htmlByWorktreeID[worktree.id] = "<html>old</html>"
    let store = TestStore(initialState: initialState) {
      CustomCodeFeature()
    }

    await store.send(.selectionChanged(nil)) {
      $0.worktree = nil
      $0.scriptPresent = false
      $0.html = nil
    }
    #expect(store.state.htmlByWorktreeID[worktree.id] == "<html>old</html>")
  }

  @Test(.dependencies) func cachedPageIsServedImmediatelyOnReselection() async {
    let worktreeA = makeWorktree(path: "/tmp/repo-a/wt", root: "/tmp/repo-a")
    let worktreeB = makeWorktree(path: "/tmp/repo-b/wt", root: "/tmp/repo-b")
    var initialState = makeState(panelOpenFor: worktreeA)
    initialState.$openPanelRepositoryIDs.withLock {
      $0.insert(worktreeB.location.repositoryLocation.id)
    }
    let renderCount = LockIsolated(0)
    let store = TestStore(initialState: initialState) {
      CustomCodeFeature()
    } withDependencies: {
      $0[CustomCodeClient.self].pagePresent = { _ in true }
      $0[CustomCodeClient.self].renderPage = { _ in
        renderCount.withValue {
          $0 += 1
          return "<html>\($0)</html>"
        }
      }
    }

    await store.send(.selectionChanged(worktreeA)) {
      $0.worktree = worktreeA
      $0.isCheckingPresence = true
    }
    await store.receive(.presenceResolved(worktreeID: worktreeA.id, result: .success(true))) {
      $0.isCheckingPresence = false
      $0.scriptPresent = true
      $0.isRendering = true
    }
    await store.receive(
      .renderCompleted(worktreeID: worktreeA.id, result: .success("<html>1</html>"))
    ) {
      $0.isRendering = false
      $0.html = "<html>1</html>"
      $0.htmlByWorktreeID[worktreeA.id] = "<html>1</html>"
    }

    await store.send(.selectionChanged(worktreeB)) {
      $0.worktree = worktreeB
      $0.scriptPresent = false
      $0.html = nil
      $0.isCheckingPresence = true
    }
    await store.receive(.presenceResolved(worktreeID: worktreeB.id, result: .success(true))) {
      $0.isCheckingPresence = false
      $0.scriptPresent = true
      $0.isRendering = true
    }
    await store.receive(
      .renderCompleted(worktreeID: worktreeB.id, result: .success("<html>2</html>"))
    ) {
      $0.isRendering = false
      $0.html = "<html>2</html>"
      $0.htmlByWorktreeID[worktreeB.id] = "<html>2</html>"
    }

    // Switching back serves worktree A's cached page synchronously — no flash
    // through the empty state — while a fresh render replaces it.
    await store.send(.selectionChanged(worktreeA)) {
      $0.worktree = worktreeA
      $0.scriptPresent = true
      $0.html = "<html>1</html>"
      $0.isCheckingPresence = true
    }
    await store.receive(.presenceResolved(worktreeID: worktreeA.id, result: .success(true))) {
      $0.isCheckingPresence = false
      $0.isRendering = true
    }
    await store.receive(
      .renderCompleted(worktreeID: worktreeA.id, result: .success("<html>3</html>"))
    ) {
      $0.isRendering = false
      $0.html = "<html>3</html>"
      $0.htmlByWorktreeID[worktreeA.id] = "<html>3</html>"
    }
  }

  @Test(.dependencies) func panelVisibilityIsPerRepository() async {
    let worktreeA = makeWorktree(path: "/tmp/repo-a/wt", root: "/tmp/repo-a")
    let worktreeB = makeWorktree(path: "/tmp/repo-b/wt", root: "/tmp/repo-b")
    let initialState = makeState(panelOpenFor: worktreeA)
    let store = TestStore(initialState: initialState) {
      CustomCodeFeature()
    } withDependencies: {
      $0[CustomCodeClient.self].pagePresent = { _ in true }
      $0[CustomCodeClient.self].renderPage = { _ in "<html>a</html>" }
    }

    await store.send(.selectionChanged(worktreeA)) {
      $0.worktree = worktreeA
      $0.isCheckingPresence = true
    }
    #expect(store.state.isPanelShown)
    await store.receive(.presenceResolved(worktreeID: worktreeA.id, result: .success(true))) {
      $0.isCheckingPresence = false
      $0.scriptPresent = true
      $0.isRendering = true
    }
    await store.receive(
      .renderCompleted(worktreeID: worktreeA.id, result: .success("<html>a</html>"))
    ) {
      $0.isRendering = false
      $0.html = "<html>a</html>"
      $0.htmlByWorktreeID[worktreeA.id] = "<html>a</html>"
    }

    // Repo B was left closed: presence still resolves, but nothing renders.
    await store.send(.selectionChanged(worktreeB)) {
      $0.worktree = worktreeB
      $0.scriptPresent = false
      $0.html = nil
      $0.isCheckingPresence = true
    }
    #expect(!store.state.isPanelShown)
    await store.receive(.presenceResolved(worktreeID: worktreeB.id, result: .success(true))) {
      $0.isCheckingPresence = false
      $0.scriptPresent = true
    }
  }

  @Test(.dependencies) func panelToggleTargetsOnlySelectedRepository() async {
    let worktreeA = makeWorktree(path: "/tmp/repo-a/wt", root: "/tmp/repo-a")
    let worktreeB = makeWorktree(path: "/tmp/repo-b/wt", root: "/tmp/repo-b")
    let repoA = worktreeA.location.repositoryLocation.id
    let repoB = worktreeB.location.repositoryLocation.id
    var initialState = CustomCodeFeature.State()
    initialState.worktree = worktreeA
    let store = TestStore(initialState: initialState) {
      CustomCodeFeature()
    }

    await store.send(.panelToggled) {
      $0.$openPanelRepositoryIDs.withLock { _ = $0.insert(repoA) }
    }
    await store.send(.selectionChanged(worktreeB)) {
      $0.worktree = worktreeB
      $0.isCheckingPresence = true
    }
    await store.receive(.presenceResolved(worktreeID: worktreeB.id, result: .success(false))) {
      $0.isCheckingPresence = false
    }
    #expect(!store.state.isPanelShown)
    await store.send(.setPanelShown(true)) {
      $0.$openPanelRepositoryIDs.withLock { _ = $0.insert(repoB) }
    }
    await store.send(.setPanelShown(false)) {
      $0.$openPanelRepositoryIDs.withLock { _ = $0.remove(repoB) }
    }
    #expect(store.state.openPanelRepositoryIDs == [repoA])
  }

  @Test(.dependencies) func panelToggleWithoutSelectionIsIgnored() async {
    let store = TestStore(initialState: CustomCodeFeature.State()) {
      CustomCodeFeature()
    }

    await store.send(.panelToggled)
    await store.send(.setPanelShown(true))
    #expect(store.state.openPanelRepositoryIDs.isEmpty)
  }

  /// State pre-seeded with the worktree's repository marked panel-open, so
  /// presence resolutions render like a visible inspector would.
  private func makeState(panelOpenFor worktree: Worktree) -> CustomCodeFeature.State {
    let state = CustomCodeFeature.State()
    state.$openPanelRepositoryIDs.withLock {
      $0.insert(worktree.location.repositoryLocation.id)
    }
    return state
  }

  private func makeWorktree(
    path: String = "/tmp/repo/wt-1",
    root: String = "/tmp/repo"
  ) -> Worktree {
    Worktree(
      id: WorktreeID(path),
      name: "wt-1",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: path),
      repositoryRootURL: URL(fileURLWithPath: root)
    )
  }

  private func makeRemoteWorktree() -> Worktree {
    Worktree(
      location: .remote(
        RemoteHost(alias: "customcode-vm"),
        workingDirectory: "/home/me/supacode",
        repositoryRoot: "/home/me/supacode"
      ),
      kind: .git,
      name: "supacode",
      detail: "detail"
    )
  }
}
