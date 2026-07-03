import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

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
      $0.worktreeID = worktree.id
      $0.worktreeDirectory = worktree.localWorkingDirectory
    }
    await store.receive(.presenceResolved(worktreeID: worktree.id, present: true)) {
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

  @Test(.dependencies) func selectionWithoutScriptClearsPage() async {
    let worktree = makeWorktree()
    var initialState = CustomCodeFeature.State()
    initialState.worktreeID = "/tmp/other/wt"
    initialState.worktreeDirectory = URL(fileURLWithPath: "/tmp/other/wt")
    initialState.scriptPresent = true
    initialState.html = "<html>stale</html>"
    let store = TestStore(initialState: initialState) {
      CustomCodeFeature()
    } withDependencies: {
      $0[CustomCodeClient.self].pagePresent = { _ in false }
    }

    await store.send(.selectionChanged(worktree)) {
      $0.worktreeID = worktree.id
      $0.worktreeDirectory = worktree.localWorkingDirectory
      $0.scriptPresent = false
      $0.html = nil
    }
    await store.receive(.presenceResolved(worktreeID: worktree.id, present: false))
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
      $0.worktreeID = worktree.id
      $0.worktreeDirectory = worktree.localWorkingDirectory
    }
    await store.receive(.presenceResolved(worktreeID: worktree.id, present: true)) {
      $0.scriptPresent = true
    }
  }

  @Test(.dependencies) func panelAppearedRendersResolvedScript() async {
    let worktree = makeWorktree()
    var initialState = CustomCodeFeature.State()
    initialState.worktreeID = worktree.id
    initialState.worktreeDirectory = worktree.localWorkingDirectory
    initialState.scriptPresent = true
    let store = TestStore(initialState: initialState) {
      CustomCodeFeature()
    } withDependencies: {
      $0[CustomCodeClient.self].renderPage = { _ in "<html>fresh</html>" }
    }

    await store.send(.panelAppeared) {
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
    initialState.worktreeID = worktree.id
    initialState.worktreeDirectory = worktree.localWorkingDirectory
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
    await store.receive(.presenceResolved(worktreeID: worktree.id, present: true)) {
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
    initialState.worktreeID = worktree.id
    initialState.worktreeDirectory = worktree.localWorkingDirectory
    initialState.scriptPresent = true
    let store = TestStore(initialState: initialState) {
      CustomCodeFeature()
    }

    await store.send(.filesChanged("/tmp/unrelated/wt"))
    await store.finish()
  }

  @Test(.dependencies) func renderFailureSurfacesErrorMessage() async {
    let worktree = makeWorktree()
    var initialState = CustomCodeFeature.State()
    initialState.worktreeID = worktree.id
    initialState.worktreeDirectory = worktree.localWorkingDirectory
    initialState.scriptPresent = true
    let store = TestStore(initialState: initialState) {
      CustomCodeFeature()
    } withDependencies: {
      $0[CustomCodeClient.self].renderPage = { _ in throw CustomCodeError.uvMissing }
    }

    await store.send(.refreshRequested) {
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
    initialState.worktreeID = worktree.id
    initialState.worktreeDirectory = worktree.localWorkingDirectory
    initialState.scriptPresent = true
    initialState.html = "<html>old</html>"
    let store = TestStore(initialState: initialState) {
      CustomCodeFeature()
    }

    await store.send(.selectionChanged(nil)) {
      $0.worktreeID = nil
      $0.worktreeDirectory = nil
      $0.scriptPresent = false
      $0.html = nil
    }
  }

  private func makeWorktree() -> Worktree {
    Worktree(
      id: "/tmp/repo/wt-1",
      name: "wt-1",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }
}
