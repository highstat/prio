import PrioCore
import SwiftUI

/// Everything the menu panel can highlight, in visual order.
enum MenuItemID: Hashable {
    case automaticSwitching
    case section(Direction)
    case device(Direction, String)
    case undo
    case settings
    case quit
}

/// Keyboard and pointer highlight for the menu panel (F16), shared so that
/// arrows and hover move the same highlight, like a native menu.
@MainActor
final class MenuNavigator: ObservableObject {
    @Published var highlighted: MenuItemID?
    @Published var expanded: Direction?

    private let model: AppModel
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}

    init(model: AppModel) {
        self.model = model
    }

    var items: [MenuItemID] {
        var items: [MenuItemID] = [.automaticSwitching]
        for d in Direction.allCases {
            items.append(.section(d))
            if expanded == d {
                items += model.menuRows(d).filter(\.isUsable).map { .device(d, $0.uid) }
            }
        }
        if model.canUndo { items.append(.undo) }
        return items + [.settings, .quit]
    }

    func move(_ delta: Int) {
        let items = items
        guard !items.isEmpty else { return }
        let current = highlighted.flatMap { items.firstIndex(of: $0) }
        let next = current.map { ($0 + delta + items.count) % items.count } ?? (delta > 0 ? 0 : items.count - 1)
        highlighted = items[next]
    }

    func activate(_ item: MenuItemID? = nil) {
        guard let item = item ?? highlighted else { return }
        switch item {
        case .automaticSwitching:
            model.engine.setAutomaticSwitching(!model.settings.automaticSwitching)
        case .section(let d):
            toggle(d)
        case .device(let d, let uid):
            model.engine.pick(uid, d)
        case .undo:
            model.engine.undo()
        case .settings:
            openSettings()
        case .quit:
            quit()
        }
    }

    func toggle(_ d: Direction) {
        expanded = expanded == d ? nil : d
    }

    func expandHighlighted(_ open: Bool) {
        switch highlighted {
        case .section(let d):
            expanded = open ? d : nil
        case .device(let d, _) where !open:
            expanded = nil
            highlighted = .section(d)
        default:
            break
        }
    }
}
