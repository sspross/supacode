import ComposableArchitecture
import SwiftUI

/// Name-entry sheet for creating or renaming a sidebar repository group.
/// Mirrors `RenameBranchView`'s layout so the two prompts feel identical.
struct SidebarGroupNameView: View {
  @Bindable var store: StoreOf<SidebarGroupNameFeature>
  @FocusState private var isNameFocused: Bool

  var body: some View {
    Form {
      Section {
        TextField("Group Name", text: $store.name)
          .focused($isNameFocused)
          .onSubmit { submit() }
      } header: {
        Text(store.isRename ? "Rename Group" : "New Group")
        Text(
          store.isRename
            ? "Enter a new name for this group."
            : "Group repositories under a collapsible sidebar section."
        )
      }
      .headerProminence(.increased)
    }
    .formStyle(.grouped)
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HStack {
        Spacer()
        Button("Cancel") {
          store.send(.cancelButtonTapped)
        }
        .keyboardShortcut(.cancelAction)
        .help("Cancel (Esc)")
        Button(store.isRename ? "Rename" : "Create") {
          submit()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!store.canSubmit)
        .help(store.isRename ? "Rename (↩)" : "Create (↩)")
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 20)
    }
    .frame(minWidth: 420)
    .task { isNameFocused = true }
  }

  private func submit() {
    guard store.canSubmit else { return }
    store.send(.submitButtonTapped)
  }
}
