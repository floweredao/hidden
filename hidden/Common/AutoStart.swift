//
//  AutoStart.swift
//  Hidden Bar
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit
import Foundation
import OSLog
import ServiceManagement

// The login-item surface of SMAppService behind a protocol so the apply logic is
// unit-testable without touching the real system registration.
protocol LoginItemServing {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemServing {}

enum AutoStart {
    // Returns whether the system ended up in the desired state. A throw is one
    // failure mode; a register() that lands on .requiresApproval (or any status
    // other than the terminal one) is another, so the post-call status is what
    // decides, not the absence of an error.
    @discardableResult
    static func apply(enabled: Bool, service: LoginItemServing = SMAppService.mainApp) -> Bool {
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status != .notRegistered { try service.unregister() }
            }
        } catch {
            NSLog("AutoStart: \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
        let ok = service.status == (enabled ? SMAppService.Status.enabled : .notRegistered)
        NSLog("AutoStart: status = \(service.status.rawValue)")
        return ok
    }
}

// Launch recovery and quit restore for the "Allow in the Menu Bar" switches,
// kept apart from AppDelegate so the order and the duplicate-instance rule can
// be tested without a running app.
final class AppLifecycle {
    enum TerminationOutcome: Equatable {
        case restored
        case restoreFailed
        case skippedDuplicate
    }

    private static let log = Logger(subsystem: "com.dwarvesv.minimalbar", category: "lifecycle")

    private let isOwner: () -> Bool
    private let recover: () -> Bool
    private let restore: () -> Bool
    private let repairStuck: () -> StuckSwitchRepair
    private let reloadMenuBar: () -> Void
    private let report: (TerminationOutcome) -> Void

    init(isOwner: @escaping () -> Bool,
         recover: @escaping () -> Bool,
         restore: @escaping () -> Bool,
         repairStuck: @escaping () -> StuckSwitchRepair,
         reloadMenuBar: @escaping () -> Void,
         report: @escaping (TerminationOutcome) -> Void = AppLifecycle.log(_:)) {
        self.isOwner = isOwner
        self.recover = recover
        self.restore = restore
        self.repairStuck = repairStuck
        self.reloadMenuBar = reloadMenuBar
        self.report = report
    }

    // Recovery runs before the controller exists, so nothing can hide icons on
    // top of a journal left by a crash. It does not depend on the backend
    // preference: switching the backend off afterwards still leaves those apps
    // switched off, and with no journal the bridge does nothing.
    func launch(start: (_ recovered: Bool) -> Void) {
        let recovered = recover()
        if recovered {
            repairIfStuck("Launch")
        } else {
            Self.log.error("Launch recovery failed; the recovery journal is kept")
        }
        start(recovered)
    }

    // #50: MenuBarAgent can keep icons hidden, and write their switches back off, after
    // Hidden Bar turned them on again. Quit and launch repair that on their own; MenuBarAgent
    // reloads the switches (the menu bar blinks) only when a stuck switch was turned back on.
    private func repairIfStuck(_ moment: String) {
        switch repairStuck() {
        case .nothingStuck:
            break
        case .repaired:
            Self.log.notice("\(moment, privacy: .public): stuck switches turned back on; reloading MenuBarAgent")
            reloadMenuBar()
        case .failed:
            Self.log.error("\(moment, privacy: .public): repairing stuck switches failed")
        }
    }

    // The process must not end before the switches are back on. A failed
    // restore leaves the journal for the next launch and still quits, because
    // an app that refuses to quit is worse than one that recovers at launch.
    func shouldTerminate() -> NSApplication.TerminateReply {
        // A duplicate launch shares the running instance's journal; restoring
        // from it would turn back on the switches that instance still holds off.
        guard isOwner() else {
            report(.skippedDuplicate)
            return .terminateNow
        }
        // The restore is synchronous, so it runs here. Deferring it with
        // .terminateLater does not work: AppKit's wait loop does not drain the
        // main dispatch queue, so the reply never came and the app could no
        // longer quit at all.
        let restored = restore()
        if restored { repairIfStuck("Quit") }
        report(restored ? .restored : .restoreFailed)
        return .terminateNow
    }

    // #30: the menu bar can stop drawing Hidden Bar's arrow and the icons it turns
    // back on while Hidden Bar keeps running; quitting and reopening it brings them
    // back. A refresh does the same without ending the process: restore the switches
    // as a quit does, take the old status items out, then start a new controller
    // through the launch path.
    func refresh(reason: String, removeItems: () -> Void, start: (_ recovered: Bool) -> Void) {
        guard isOwner() else { return }
        let restored = restore()
        Self.log.notice("Refresh (\(reason, privacy: .public)): switches \(restored ? "restored" : "not restored", privacy: .public)")
        removeItems()
        launch(start: start)
    }

    // #50: MenuBarAgent can keep icons hidden after their switches read on again, even
    // after Hidden Bar quits. Restore All Icons restores as a refresh does, also turns
    // back on every switch Hidden Bar's records show it turned off, and has MenuBarAgent
    // reload the switches before the controller starts again.
    func restoreAllIcons(restoreRecorded: () -> Bool,
                         removeItems: () -> Void, start: (_ recovered: Bool) -> Void) {
        guard isOwner() else { return }
        let restored = restore()
        let recorded = restoreRecorded()
        Self.log.notice("Restore All Icons: switches \(restored ? "restored" : "not restored", privacy: .public), recorded switches \(recorded ? "restored" : "not restored", privacy: .public)")
        removeItems()
        reloadMenuBar()
        launch(start: start)
    }

    // SIGTERM (pkill, the install script) and SIGINT (Ctrl-C) end the process
    // without AppKit's termination, leaving switches off until the next launch.
    // The default action is ignored first, or it would kill the process before
    // the dispatch source delivers the signal.
    static func installSignalHandlers(_ signals: [Int32] = [SIGTERM, SIGINT],
                                      queue: DispatchQueue = .main,
                                      handler: @escaping (Int32) -> Void) -> [DispatchSourceSignal] {
        return signals.map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { handler(signalNumber) }
            source.resume()
            return source
        }
    }

    static func logDisplayChange(_ configuration: DisplayConfiguration) {
        log.notice("Displays changed: \(configuration.description, privacy: .public)")
    }

    private static func log(_ outcome: TerminationOutcome) {
        switch outcome {
        case .restored:
            log.notice("Quit: menu bar switches restored")
        case .restoreFailed:
            log.error("Quit: restoring the menu bar switches failed; the recovery journal is kept for the next launch")
        case .skippedDuplicate:
            log.notice("Quit: duplicate instance exits without touching the recovery journal")
        }
    }
}

// The attached screens. The screen-parameters notification also fires when only
// the Dock or a visible frame moves; a refresh follows only a changed set of
// screens (hot-plug, lid, resolution), the change upstream #390 reports.
struct DisplayConfiguration: Equatable, CustomStringConvertible {
    struct Screen: Equatable {
        let id: UInt32
        let frame: CGRect
    }

    let screens: [Screen]

    static var current: DisplayConfiguration {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return DisplayConfiguration(screens: NSScreen.screens.map { screen in
            Screen(id: (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0, frame: screen.frame)
        })
    }

    var description: String {
        screens.map { "\($0.id) \(Int($0.frame.width))x\(Int($0.frame.height))@\(Int($0.frame.minX)),\(Int($0.frame.minY))" }
            .joined(separator: "; ")
    }
}
