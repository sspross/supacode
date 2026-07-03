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
    let store = TestStore(initialState: CustomCodeFeature.State()) {
      CustomCodeFeature()
    } withDependencies: {
      $0[CustomCodeClient.self].pagePresent = { _ in true }
      $0[CustomCodeClient.self].renderPage = { _ in "<html>ok</html>" }
    }

    await store.send(.setPanelShown(true)) {
      $0.$isPanelShown.withLock { $0 = true }
    }
    await store.send(.selectionChanged(worktree)) {
      $0.worktree = worktree
    }
    await store.receive(.presenceResolved(worktreeID: worktree.id, result: .success(true))) {
      $0.scriptPresent = true
      $0.isRendering = true
    }
    await store.receive(
      .renderCompleted(worktreeID: worktree.id, result: .success("<html>ok</html>"))
    ) {
      $0.isRendering = false
      $0.html = "<html>ok</html>"
    }
  }

  @Test(.dependencies) func remoteWorktreeRendersOverSSH() async {
    let worktree = makeRemoteWorktree()
    let store = TestStore(initialState: CustomCodeFeature.State()) {
      CustomCodeFeature()
    } withDependencies: {
      $0[CustomCodeClient.self].pagePresent = { _ in true }
      $0[CustomCodeClient.self].renderPage = { _ in "<html>remote</html>" }
    }

    await store.send(.setPanelShown(true)) {
      $0.$isPanelShown.withLock { $0 = true }
    }
    await store.send(.selectionChanged(worktree)) {
      $0.worktree = worktree
    }
    await store.receive(.presenceResolved(worktreeID: worktree.id, result: .success(true))) {
      $0.scriptPresent = true
      $0.isRendering = true
    }
    await store.receive(
      .renderCompleted(worktreeID: worktree.id, result: .success("<html>remote</html>"))
    ) {
      $0.isRendering = false
      $0.html = "<html>remote</html>"
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
    }
    await store.receive(
      .presenceResolved(
        worktreeID: worktree.id,
        result: .failure(.hostUnreachable(destination: "customcode-vm"))
      )
    ) {
      $0.errorMessage = CustomCodeError.hostUnreachable(destination: "customcode-vm").message
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
    }
    await store.receive(.presenceResolved(worktreeID: worktree.id, result: .success(false)))
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
    }
    await store.receive(.presenceResolved(worktreeID: worktree.id, result: .success(true))) {
      $0.scriptPresent = true
    }
  }

  @Test(.dependencies) func panelAppearedRechecksPresenceAndRenders() async {
    let worktree = makeWorktree()
    var initialState = CustomCodeFeature.State()
    initialState.worktree = worktree
    let store = TestStore(initialState: initialState) {
      CustomCodeFeature()
    } withDependencies: {
      $0[CustomCodeClient.self].pagePresent = { _ in true }
      $0[CustomCodeClient.self].renderPage = { _ in "<html>fresh</html>" }
    }

    await store.send(.setPanelShown(true)) {
      $0.$isPanelShown.withLock { $0 = true }
    }
    await store.send(.panelAppeared)
    await store.receive(.presenceResolved(worktreeID: worktree.id, result: .success(true))) {
      $0.scriptPresent = true
      $0.isRendering = true
    }
    await store.receive(
      .renderCompleted(worktreeID: worktree.id, result: .success("<html>fresh</html>"))
    ) {
      $0.isRendering = false
      $0.html = "<html>fresh</html>"
    }
  }

  @Test(.dependencies) func filesChangedRechecksPresenceAndRerenders() async {
    let worktree = makeWorktree()
    var initialState = CustomCodeFeature.State()
    initialState.worktree = worktree
    initialState.scriptPresent = true
    initialState.html = "<html>old</html>"
    let store = TestStore(initialState: initialState) {
      CustomCodeFeature()
    } withDependencies: {
      $0[CustomCodeClient.self].pagePresent = { _ in true }
      $0[CustomCodeClient.self].renderPage = { _ in "<html>new</html>" }
    }

    await store.send(.setPanelShown(true)) {
      $0.$isPanelShown.withLock { $0 = true }
    }
    await store.send(.filesChanged(worktree.id))
    await store.receive(.presenceResolved(worktreeID: worktree.id, result: .success(true))) {
      $0.isRendering = true
    }
    await store.receive(
      .renderCompleted(worktreeID: worktree.id, result: .success("<html>new</html>"))
    ) {
      $0.isRendering = false
      $0.html = "<html>new</html>"
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
    var initialState = CustomCodeFeature.State()
    initialState.worktree = worktree
    initialState.scriptPresent = false
    let store = TestStore(initialState: initialState) {
      CustomCodeFeature()
    } withDependencies: {
      $0[CustomCodeClient.self].pagePresent = { _ in true }
      $0[CustomCodeClient.self].renderPage = { _ in "<html>found</html>" }
    }

    await store.send(.setPanelShown(true)) {
      $0.$isPanelShown.withLock { $0 = true }
    }
    await store.send(.refreshRequested)
    await store.receive(.presenceResolved(worktreeID: worktree.id, result: .success(true))) {
      $0.scriptPresent = true
      $0.isRendering = true
    }
    await store.receive(
      .renderCompleted(worktreeID: worktree.id, result: .success("<html>found</html>"))
    ) {
      $0.isRendering = false
      $0.html = "<html>found</html>"
    }
  }

  @Test(.dependencies) func renderFailureSurfacesErrorMessage() async {
    let worktree = makeWorktree()
    var initialState = CustomCodeFeature.State()
    initialState.worktree = worktree
    initialState.scriptPresent = true
    let store = TestStore(initialState: initialState) {
      CustomCodeFeature()
    } withDependencies: {
      $0[CustomCodeClient.self].pagePresent = { _ in true }
      $0[CustomCodeClient.self].renderPage = { _ in throw CustomCodeError.uvMissing }
    }

    await store.send(.setPanelShown(true)) {
      $0.$isPanelShown.withLock { $0 = true }
    }
    await store.send(.refreshRequested)
    await store.receive(.presenceResolved(worktreeID: worktree.id, result: .success(true))) {
      $0.isRendering = true
    }
    await store.receive(
      .renderCompleted(worktreeID: worktree.id, result: .failure(.uvMissing))
    ) {
      $0.isRendering = false
      $0.errorMessage = CustomCodeError.uvMissing.message
    }
  }

  @Test(.dependencies) func deselectionClearsPage() async {
    let worktree = makeWorktree()
    var initialState = CustomCodeFeature.State()
    initialState.worktree = worktree
    initialState.scriptPresent = true
    initialState.html = "<html>old</html>"
    let store = TestStore(initialState: initialState) {
      CustomCodeFeature()
    }

    await store.send(.selectionChanged(nil)) {
      $0.worktree = nil
      $0.scriptPresent = false
      $0.html = nil
    }
  }

  private func makeWorktree(path: String = "/tmp/repo/wt-1") -> Worktree {
    Worktree(
      id: WorktreeID(path),
      name: "wt-1",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: path),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
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
