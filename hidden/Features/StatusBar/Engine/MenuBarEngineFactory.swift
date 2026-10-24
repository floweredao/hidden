import Foundation

enum MenuBarEngineFactory {
    static func make(items: MenuBarItemProvider) -> MenuBarEngine {
        #if HIDDENBAR_NATIVE_VISIBILITY
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            return AllowListEngine(items: items)
        }
        #endif
        return LegacyLengthEngine(items: items)
    }
}
