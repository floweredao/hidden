import AppKit

protocol MenuBarEngine: AnyObject {
    func apply(collapsed: Bool, alwaysHiddenShown: Bool)
    var isArrangementValid: Bool { get }
    var isAlwaysHiddenSeparatorPlaced: Bool { get }
    func invalidateLayout()
    func refreshArrangement()
    @discardableResult func restoreAll() -> Bool
}

enum HidingUnavailableReason: Equatable {
    case fileAccessNeeded
}

enum MenuBarOrder {
    // True when `item` sits on the hidden side of `boundary`: to its left in a
    // left-to-right layout, to its right otherwise. False when either is not on
    // screen, since nothing can be judged then.
    static func isItem(_ item: NSStatusItem?, onHiddenSideOf boundary: NSStatusItem?) -> Bool {
        guard let itemX = item?.button?.window?.frame.origin.x,
              let boundaryX = boundary?.button?.window?.frame.origin.x else { return false }
        return Constant.isUsingLTRLanguage ? boundaryX >= itemX : boundaryX <= itemX
    }
}

// The controller owns and recreates the status items; engines only borrow them.
protocol MenuBarItemProvider: AnyObject {
    var toggleItem: NSStatusItem { get }
    var separatorItem: NSStatusItem { get }
    var alwaysHiddenItem: NSStatusItem? { get }
}
