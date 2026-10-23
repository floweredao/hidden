//
//  Preferences.swift
//  Hidden Bar
//
//  Created by phucld on 12/18/19.
//  Copyright © 2019 Dwarves Foundation. All rights reserved.
//

import Foundation

enum Preferences {
    
    static var globalKey: GlobalKeybindPreferences? {
        get {
            guard let data = UserDefaults.standard.value(forKey: UserDefaults.Key.globalKey) as? Data else { return nil }
            return try? JSONDecoder().decode(GlobalKeybindPreferences.self, from: data)
        }
        
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: UserDefaults.Key.globalKey)
            
            NotificationCenter.default.post(Notification(name: .prefsChanged))
        }
    }
    
    static var isAutoStart: Bool {
        get {
            return UserDefaults.standard.bool(forKey: UserDefaults.Key.isAutoStart)
        }
        
        set {
            // Apply first, then persist the outcome: on failure the stored value
            // stays at the previous state so the prefs checkbox shows reality
            // instead of the intent.
            let applied = Util.setUpAutoStart(isAutoStart: newValue)
            UserDefaults.standard.set(applied ? newValue : isAutoStart, forKey: UserDefaults.Key.isAutoStart)

            NotificationCenter.default.post(Notification(name: .prefsChanged))
        }
    }
    
    static var numberOfSecondForAutoHide: Double {
        get {
            UserDefaults.standard.double(forKey: UserDefaults.Key.numberOfSecondForAutoHide)
        }
        
        set {
            UserDefaults.standard.set(newValue, forKey: UserDefaults.Key.numberOfSecondForAutoHide)
            
            NotificationCenter.default.post(Notification(name: .prefsChanged))
        }
    }
    
    static var isAutoHide: Bool {
        get {
            UserDefaults.standard.bool(forKey: UserDefaults.Key.isAutoHide)
        }
        
        set {
            UserDefaults.standard.set(newValue, forKey: UserDefaults.Key.isAutoHide)
            
            NotificationCenter.default.post(Notification(name: .prefsChanged))
        }
    }
    
    static var isShowPreference: Bool {
        get {
            UserDefaults.standard.bool(forKey: UserDefaults.Key.isShowPreference)
        }
        
        set {
            UserDefaults.standard.set(newValue, forKey: UserDefaults.Key.isShowPreference)
            
            NotificationCenter.default.post(Notification(name: .prefsChanged))
        }
    }
    
    static var areSeparatorsHidden: Bool {
        get {
            UserDefaults.standard.bool(forKey: UserDefaults.Key.areSeparatorsHidden)
        }
        
        set {
            UserDefaults.standard.set(newValue, forKey: UserDefaults.Key.areSeparatorsHidden)
        }
    }
    
    static var alwaysHiddenSectionEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: UserDefaults.Key.alwaysHiddenSectionEnabled)
        }
        
        set {
            UserDefaults.standard.set(newValue, forKey: UserDefaults.Key.alwaysHiddenSectionEnabled)
            NotificationCenter.default.post(Notification(name: .alwayHideToggle))
        }
    }
    
    static var hoverToExpand: Bool {
        get {
            UserDefaults.standard.bool(forKey: UserDefaults.Key.hoverToExpand)
        }

        set {
            UserDefaults.standard.set(newValue, forKey: UserDefaults.Key.hoverToExpand)
        }
    }

    static var useFullStatusBarOnExpandEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: UserDefaults.Key.useFullStatusBarOnExpandEnabled)
        }

        set {
            UserDefaults.standard.set(newValue, forKey: UserDefaults.Key.useFullStatusBarOnExpandEnabled)
        }
    }

    // Per-app sections chosen in Settings (bundle id -> MenuBarSection raw value),
    // used instead of the app's ⌘-drag position. A missing entry follows the position.
    static var sectionOverrides: [String: MenuBarSection] {
        get {
            let stored = UserDefaults.standard.dictionary(forKey: UserDefaults.Key.sectionOverrides) as? [String: Int] ?? [:]
            return stored.compactMapValues(MenuBarSection.init(rawValue:))
        }

        set {
            UserDefaults.standard.set(newValue.mapValues(\.rawValue), forKey: UserDefaults.Key.sectionOverrides)
            NotificationCenter.default.post(Notification(name: .sectionOverridesChanged))
        }
    }

    // macOS 27 direct build: expanding holds no visibility restriction, so the
    // Focus icon and the mic/camera capsule show (the always-hidden section too).
    static var showsSystemIndicatorsWhenExpanded: Bool {
        get {
            UserDefaults.standard.bool(forKey: UserDefaults.Key.showsSystemIndicatorsWhenExpanded)
        }

        set {
            UserDefaults.standard.set(newValue, forKey: UserDefaults.Key.showsSystemIndicatorsWhenExpanded)
            NotificationCenter.default.post(Notification(name: .systemIndicatorsPreferenceChanged))
        }
    }

    // macOS 27: hide by pushing icons into macOS's « menu, which holds no
    // visibility restriction, so the Focus icon and the mic/camera capsule stay.
    // Read once at launch, when the engine is picked.
    static var hidesIntoSystemOverflow: Bool {
        get {
            UserDefaults.standard.bool(forKey: UserDefaults.Key.hidesIntoSystemOverflow)
        }

        set {
            UserDefaults.standard.set(newValue, forKey: UserDefaults.Key.hidesIntoSystemOverflow)
        }
    }

    // macOS 27 direct build: hide by turning apps off in System Settings ›
    // Menu Bar (MenuBarAgent restarts on each change). Wins over the overflow
    // collapse. Read once at launch, when the engine is picked.
    static var hidesWithMenuBarSettings: Bool {
        get {
            UserDefaults.standard.bool(forKey: UserDefaults.Key.hidesWithMenuBarSettings)
        }

        set {
            UserDefaults.standard.set(newValue, forKey: UserDefaults.Key.hidesWithMenuBarSettings)
        }
    }

    static var notchOverflowEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: UserDefaults.Key.notchOverflowEnabled)
        }

        set {
            UserDefaults.standard.set(newValue, forKey: UserDefaults.Key.notchOverflowEnabled)
        }
    }
}
