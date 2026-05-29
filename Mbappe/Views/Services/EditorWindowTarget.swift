import Foundation

/// Identifies which editor a standalone editor window should present.
///
/// The create/edit flows run in a real window (not a popover sheet) so that
/// `NSOpenPanel` file/folder pickers get and keep focus correctly.
enum EditorWindowTarget: Identifiable, Hashable, Codable {
    case newService
    case newGroup
    case editGroup(ServiceGroup)

    var id: String {
        switch self {
        case .newService: "newService"
        case .newGroup: "newGroup"
        case .editGroup(let group): "editGroup-\(group.id)"
        }
    }
}
