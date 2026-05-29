import SwiftUI

/// Hosts the create/edit editors inside a standalone window.
struct EditorWindowView: View {
    let target: EditorWindowTarget
    @EnvironmentObject private var store: ServicesStore

    var body: some View {
        Group {
            switch target {
            case .newService:
                UserServiceEditorView()
            case .newGroup:
                GroupEditorView()
            case .editGroup(let group):
                GroupEditorView(editing: group)
            }
        }
        .environmentObject(store)
    }
}
