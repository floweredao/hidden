import AppKit

enum ExpandCollapseAction {
    case toggle
    case toggleSeparators
    case none
}

enum ExpandCollapseActionResolver {
    static func modifiers(eventFlags: NSEvent.ModifierFlags?, liveFlags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        (eventFlags ?? []).union(liveFlags).intersection(.deviceIndependentFlagsMask)
    }

    static func action(eventType: NSEvent.EventType?, modifiers: NSEvent.ModifierFlags,
                       alwaysHiddenSectionEnabled: Bool) -> ExpandCollapseAction {
        guard let type = eventType else { return .toggle }
        let mouse = type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp
        let secondary = type == .rightMouseUp || type == .otherMouseUp
            || (mouse && !modifiers.intersection([.control, .option]).isEmpty)
        return secondary ? (alwaysHiddenSectionEnabled ? .toggleSeparators : .none) : .toggle
    }
}

// Keeping the decision separate lets hostless tests exercise the same render-before-write
// path as the controller without creating real status items.
final class MenuBarStateMachine {
    private(set) var isCollapsed = false
    private(set) var alwaysHiddenShown: Bool
    private let engine: MenuBarEngine
    private let clock: () -> TimeInterval
    private let render: (Bool, Bool) -> Void
    private var lastAction: TimeInterval?

    init(engine: MenuBarEngine, alwaysHiddenShown: Bool,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         render: @escaping (Bool, Bool) -> Void) {
        self.engine = engine
        self.alwaysHiddenShown = alwaysHiddenShown
        self.clock = clock
        self.render = render
    }

    @discardableResult func perform(_ action: ExpandCollapseAction, alwaysHiddenEnabled: Bool) -> Bool {
        let now = clock()
        guard lastAction.map({ now - $0 >= 0.3 }) ?? true else { return false }
        switch action {
        case .none: return false
        case .toggle:
            guard isCollapsed || engine.isArrangementValid else { return false }
            isCollapsed.toggle()
        case .toggleSeparators:
            guard alwaysHiddenEnabled && engine.isAlwaysHiddenSeparatorPlaced else { return false }
            alwaysHiddenShown.toggle()
            isCollapsed = false
        }
        lastAction = now
        synchronize()
        return true
    }

    @discardableResult func collapse() -> Bool {
        guard !isCollapsed && engine.isArrangementValid else { return false }
        isCollapsed = true
        synchronize()
        return true
    }

    func alwaysHiddenSectionToggled() {
        alwaysHiddenShown = true
        synchronize()
    }

    func synchronize() {
        render(isCollapsed, alwaysHiddenShown)
        engine.apply(collapsed: isCollapsed, alwaysHiddenShown: alwaysHiddenShown)
    }
}

enum MenuBarBand {
    // The visible frame stops below the bar, unless the bar auto-hides: then it
    // reaches the top of the screen and the band must come from the bar's height.
    static func minY(frame: CGRect, visibleFrame: CGRect, thickness: CGFloat) -> CGFloat {
        if visibleFrame.maxY >= frame.maxY { return frame.maxY - thickness }
        return visibleFrame.maxY
    }
}

// AppKit can deliver duplicate begin notifications. Identity, rather than a
// counter, keeps one missed or unrelated end from disabling auto-collapse.
struct OwnedMenuTracking {
    private var menus = Set<ObjectIdentifier>()

    mutating func began(_ menu: NSMenu, owned: Bool) {
        if owned { menus.insert(ObjectIdentifier(menu)) }
    }

    mutating func ended(_ menu: NSMenu) {
        menus.remove(ObjectIdentifier(menu))
    }

    var isTracking: Bool { !menus.isEmpty }
}

struct AutoCollapseDeferral {
    enum Reason: String, CaseIterable {
        case mouseInMenuBar, preferencesEditing, ownedMenuTracking, menuBarNavigation
    }

    private var softDeferralStarted: TimeInterval?
    let maximumIdleDeferral: TimeInterval = 60

    mutating func reasons(now: TimeInterval, mouseInMenuBar: Bool, preferencesEditing: Bool,
                          ownedMenuTracking: Bool, menuBarNavigation: Bool, recentKeyboardInput: Bool) -> [Reason] {
        var reasons: [Reason] = []
        if mouseInMenuBar { reasons.append(.mouseInMenuBar) }
        if preferencesEditing { reasons.append(.preferencesEditing) }
        let soft = ownedMenuTracking || menuBarNavigation
        if !soft || recentKeyboardInput || !reasons.isEmpty {
            softDeferralStarted = nil
        }
        if soft {
            let start = softDeferralStarted ?? now
            softDeferralStarted = start
            // AX focus may remain on a menu extra long after its menu closes.
            // Actual keyboard use resets this bound; stale focus does not.
            if now - start < maximumIdleDeferral {
                if ownedMenuTracking { reasons.append(.ownedMenuTracking) }
                if menuBarNavigation { reasons.append(.menuBarNavigation) }
            }
        }
        return reasons
    }
}
