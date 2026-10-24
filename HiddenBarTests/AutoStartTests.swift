//
//  AutoStartTests.swift
//  HiddenBarTests
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit
import ServiceManagement
import XCTest

private final class FakeLoginItem: LoginItemServing {
    struct StubbedError: Error {}

    var status: SMAppService.Status
    var error: Error?
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCalls += 1
        if let error { throw error }
    }

    func unregister() throws {
        unregisterCalls += 1
        if let error { throw error }
    }
}

final class AutoStartTests: XCTestCase {

    func testEnableCallsRegisterWhenNotRegistered() {
        let service = FakeLoginItem(status: .notRegistered)
        _ = AutoStart.apply(enabled: true, service: service)
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(service.unregisterCalls, 0)
    }

    func testEnableSucceedsWhenRegistrationLandsEnabled() {
        let service = TransitioningLoginItem(finalStatus: .enabled)
        XCTAssertTrue(AutoStart.apply(enabled: true, service: service))
    }

    func testEnableIsNoOpWhenAlreadyEnabled() {
        let service = FakeLoginItem(status: .enabled)
        XCTAssertTrue(AutoStart.apply(enabled: true, service: service))
        XCTAssertEqual(service.registerCalls, 0)
    }

    func testDisableUnregistersWhenEnabled() {
        let service = TransitioningLoginItem(initialStatus: .enabled, finalStatus: .notRegistered)
        XCTAssertTrue(AutoStart.apply(enabled: false, service: service))
    }

    func testDisableIsNoOpWhenNotRegistered() {
        let service = FakeLoginItem(status: .notRegistered)
        XCTAssertTrue(AutoStart.apply(enabled: false, service: service))
        XCTAssertEqual(service.unregisterCalls, 0)
    }

    func testEnableReportsFailureWhenRegisterThrows() {
        let service = FakeLoginItem(status: .notRegistered)
        service.error = FakeLoginItem.StubbedError()
        XCTAssertFalse(AutoStart.apply(enabled: true, service: service))
    }

    // register() not throwing is not proof of success: a registration that lands
    // on .requiresApproval must still surface as failure so the checkbox reverts.
    func testEnableReportsFailureOnRequiresApproval() {
        let service = TransitioningLoginItem(finalStatus: .requiresApproval)
        XCTAssertFalse(AutoStart.apply(enabled: true, service: service))
    }

    func testDisableReportsFailureWhenUnregisterThrows() {
        let service = FakeLoginItem(status: .enabled)
        service.error = FakeLoginItem.StubbedError()
        XCTAssertFalse(AutoStart.apply(enabled: false, service: service))
    }
}

// A fake whose register/unregister moves status to a given terminal value, like
// the real SMAppService does on success.
private final class TransitioningLoginItem: LoginItemServing {
    var status: SMAppService.Status
    private let finalStatus: SMAppService.Status

    init(initialStatus: SMAppService.Status = .notRegistered, finalStatus: SMAppService.Status) {
        self.status = initialStatus
        self.finalStatus = finalStatus
    }

    func register() throws { status = finalStatus }
    func unregister() throws { status = finalStatus }
}

// Launch recovery, quit restore and signal handling, driven through injected
// closures so no status item, menu bar switch or real termination is involved.
final class AppLifecycleTests: XCTestCase {
    private var sources: [DispatchSourceSignal] = []

    override func tearDown() {
        sources.forEach { $0.cancel() }
        sources = []
        signal(SIGTERM, SIG_DFL)
        signal(SIGINT, SIG_DFL)
        super.tearDown()
    }

    private final class Recorder {
        var events: [String] = []
        var outcomes: [AppLifecycle.TerminationOutcome] = []
    }

    private func makeLifecycle(_ recorder: Recorder, owner: Bool = true,
                               recovers: Bool = true, restores: Bool = true) -> AppLifecycle {
        AppLifecycle(isOwner: { owner },
                     recover: { recorder.events.append("recover"); return recovers },
                     restore: { recorder.events.append("restore"); return restores },
                     report: { recorder.outcomes.append($0) })
    }

    private func isIgnored(_ signalNumber: Int32) -> Bool {
        var action = sigaction()
        sigaction(signalNumber, nil, &action)
        return unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self)
    }

    // L1: SIGTERM must reach the quit path on the main queue instead of killing
    // the process with the switches still off.
    func testTerminationSignalsAreIgnoredByDefaultAndDeliveredOnMain() {
        let delivered = expectation(description: "SIGTERM handler")
        sources = AppLifecycle.installSignalHandlers { signalNumber in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(signalNumber, SIGTERM)
            delivered.fulfill()
        }
        XCTAssertTrue(isIgnored(SIGINT), "SIGINT still has its default action")
        // Raising with the default action still in place would kill the test runner.
        guard isIgnored(SIGTERM) else {
            XCTFail("SIGTERM still has its default action")
            return
        }
        // Process-directed like pkill; raise() targets one thread, which the
        // dispatch signal source does not observe.
        kill(getpid(), SIGTERM)
        wait(for: [delivered], timeout: 5)
    }

    // L2: the restore has run before termination is allowed.
    func testQuitRestoresBeforeTerminating() {
        let recorder = Recorder()
        let lifecycle = makeLifecycle(recorder)
        XCTAssertEqual(lifecycle.shouldTerminate(), .terminateNow)
        XCTAssertEqual(recorder.events, ["restore"])
        XCTAssertEqual(recorder.outcomes, [.restored])
    }

    // L2: a failed restore keeps the journal (the bridge does not clear it) and
    // is reported, but never traps the user in an app that cannot quit.
    func testQuitRestoreFailureIsReportedAndStillTerminates() {
        let recorder = Recorder()
        let lifecycle = makeLifecycle(recorder, restores: false)
        XCTAssertEqual(lifecycle.shouldTerminate(), .terminateNow)
        XCTAssertEqual(recorder.outcomes, [.restoreFailed])
    }

    // L3: a journal left by a crash must be recovered even when the backend
    // preference now resolves off, so launch recovery takes no backend input.
    func testLaunchRecoveryRunsWhenBackendPreferenceIsOff() {
        let recorder = Recorder()
        let lifecycle = makeLifecycle(recorder)
        lifecycle.launch { _ in recorder.events.append("start") }
        XCTAssertEqual(recorder.events, ["recover", "start"])
    }

    // L3: the controller (and its initial collapse) starts only after recovery
    // and learns whether it failed.
    func testLaunchPassesRecoveryFailureToControllerStart() {
        let recorder = Recorder()
        let lifecycle = makeLifecycle(recorder, recovers: false)
        var recovered: Bool?
        lifecycle.launch { recovered = $0; recorder.events.append("start") }
        XCTAssertEqual(recorder.events, ["recover", "start"])
        XCTAssertEqual(recovered, false)
    }

    // A5: a duplicate shares the running instance's journal and must not
    // restore the switches that instance is holding off.
    func testDuplicateInstanceTerminatesWithoutRestoring() {
        let recorder = Recorder()
        let lifecycle = makeLifecycle(recorder, owner: false)
        XCTAssertEqual(lifecycle.shouldTerminate(), .terminateNow)
        XCTAssertEqual(recorder.events, [])
        XCTAssertEqual(recorder.outcomes, [.skippedDuplicate])
    }
}
