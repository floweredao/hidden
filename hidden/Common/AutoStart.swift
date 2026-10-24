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
    private let schedule: (@escaping () -> Void) -> Void
    private let reply: (Bool) -> Void
    private let report: (TerminationOutcome) -> Void
    private var isRestoring = false

    init(isOwner: @escaping () -> Bool,
         recover: @escaping () -> Bool,
         restore: @escaping () -> Bool,
         schedule: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         reply: @escaping (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) },
         report: @escaping (TerminationOutcome) -> Void = AppLifecycle.log(_:)) {
        self.isOwner = isOwner
        self.recover = recover
        self.restore = restore
        self.schedule = schedule
        self.reply = reply
        self.report = report
    }

    // Recovery runs before the controller exists, so nothing can hide icons on
    // top of a journal left by a crash. It does not depend on the backend
    // preference: switching the backend off afterwards still leaves those apps
    // switched off, and with no journal the bridge does nothing.
    func launch(start: (_ recovered: Bool) -> Void) {
        let recovered = recover()
        if !recovered {
            Self.log.error("Launch recovery failed; the recovery journal is kept")
        }
        start(recovered)
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
        guard !isRestoring else { return .terminateLater }
        isRestoring = true
        schedule { [self] in
            report(restore() ? .restored : .restoreFailed)
            reply(true)
        }
        return .terminateLater
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
