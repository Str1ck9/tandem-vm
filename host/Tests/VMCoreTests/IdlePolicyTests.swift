import XCTest
@testable import VMCore

final class IdlePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
    private let fifteen = PowerSettings(idleSuspendMinutes: 15)

    func testWithoutTheTimerNothingIsEverSuspended() {
        let verdict = IdlePolicy.evaluate(PowerSettings(), .init(now: now, runningSince: ago(86_400)))
        XCTAssertNil(verdict.suspendIn)
        XCTAssertFalse(verdict.shouldSuspend)
        XCTAssertEqual(verdict.idleFor, 86_400)
    }

    func testAnUntouchedVMIsSuspendedWhenTheTimeIsUp() {
        XCTAssertEqual(IdlePolicy.evaluate(fifteen, .init(now: now, runningSince: ago(600))).suspendIn, 300)
        let late = IdlePolicy.evaluate(fifteen, .init(now: now, runningSince: ago(901)))
        XCTAssertEqual(late.suspendIn, 0)
        XCTAssertTrue(late.shouldSuspend)
    }

    func testTheLatestSignOfUseStartsTheTimerAgain() {
        // Started an hour ago; the Mac sent input 2 min ago; the guest saw input 1 min ago (20 s before its report of 40 s ago).
        let s = IdlePolicy.Signals(now: now, runningSince: ago(3600), lastHostInput: ago(120), lastFocused: ago(600), lastLaunch: ago(1800),
                                   guestReportAt: ago(40), guestIdleSeconds: 20, guestCPUPercent: 2)
        let verdict = IdlePolicy.evaluate(fifteen, s)
        XCTAssertEqual(verdict.idleFor, 60)
        XCTAssertEqual(verdict.suspendIn, 840)
        XCTAssertEqual(verdict.heldAwakeBy, [])
    }

    func testKeepAwakeHoldsTheVMAndSaysSo() {
        let verdict = IdlePolicy.evaluate(PowerSettings(idleSuspendMinutes: 15, keepAwake: true), .init(now: now, runningSince: ago(7200)))
        XCTAssertEqual(verdict.heldAwakeBy, ["Keep Awake is on"])
        XCTAssertNil(verdict.suspendIn)
        XCTAssertEqual(verdict.idleFor, 0, "a VM that is held awake is not idle")
    }

    func testAKeepAwakeRequestFromTheGuestHoldsTheVMWhileItsReportIsFresh() {
        var s = IdlePolicy.Signals(now: now, runningSince: ago(7200), guestReportAt: ago(15), guestIdleSeconds: 7000, guestCPUPercent: 1,
                                   guestKeepAwake: ["Nightly backup"])
        XCTAssertEqual(IdlePolicy.evaluate(fifteen, s).heldAwakeBy, ["In the VM: Nightly backup"])
        XCTAssertFalse(IdlePolicy.evaluate(fifteen, s).shouldSuspend)
        // The guest went quiet (crashed agent, frozen guest): its old word no longer holds anything.
        s.guestReportAt = ago(600)
        XCTAssertEqual(IdlePolicy.evaluate(fifteen, s).heldAwakeBy, [])
        XCTAssertTrue(IdlePolicy.evaluate(fifteen, s).shouldSuspend)
    }

    func testABusyProcessorHoldsTheVM() {
        let busy = IdlePolicy.Signals(now: now, runningSince: ago(7200), guestReportAt: ago(5), guestIdleSeconds: 7000, guestCPUPercent: 37.4)
        XCTAssertEqual(IdlePolicy.evaluate(fifteen, busy).heldAwakeBy, ["The VM is busy (37% processor use)"])
        // No guest report at all: the host's figure for the VM's process decides.
        XCTAssertEqual(IdlePolicy.evaluate(fifteen, .init(now: now, runningSince: ago(7200), hostCPUPercent: 180)).heldAwakeBy,
                       ["The VM is busy (180% of a Mac processor core)"])
        XCTAssertTrue(IdlePolicy.evaluate(fifteen, .init(now: now, runningSince: ago(7200), hostCPUPercent: 6)).shouldSuspend)
        // With a fresh guest report, the host's figure is not consulted (the guest knows better what is idle).
        let quiet = IdlePolicy.Signals(now: now, runningSince: ago(7200), guestReportAt: ago(5), guestIdleSeconds: 7000, guestCPUPercent: 3, hostCPUPercent: 90)
        XCTAssertTrue(IdlePolicy.evaluate(fifteen, quiet).shouldSuspend)
    }

    func testAfterAJobEndsTheFullTimeRunsAgain() {
        // The caller remembers that the VM was held awake until 4 min ago.
        let s = IdlePolicy.Signals(now: now, runningSince: ago(7200), lastHeldAwake: ago(240), guestReportAt: ago(5), guestIdleSeconds: 7000, guestCPUPercent: 1)
        XCTAssertEqual(IdlePolicy.evaluate(fifteen, s).suspendIn, 660)
    }

    func testClosingTheWindowOnlyStartsTheTimer() {
        // The window was the one in use until it was closed a second ago: the whole time is still ahead.
        let s = IdlePolicy.Signals(now: now, runningSince: ago(7200), lastHostInput: ago(3000), lastFocused: ago(1))
        let verdict = IdlePolicy.evaluate(fifteen, s)
        XCTAssertFalse(verdict.shouldSuspend)
        XCTAssertEqual(verdict.suspendIn, 899)
    }

    func testTandemsOwnWorkHoldsTheVM() {
        let verdict = IdlePolicy.evaluate(fifteen, .init(now: now, runningSince: ago(7200), work: "Installing Windows 11…"))
        XCTAssertEqual(verdict.heldAwakeBy, ["Installing Windows 11…"])
        XCTAssertNil(verdict.suspendIn)
    }

    func testAShorterMinuteForTrials() {
        XCTAssertEqual(IdlePolicy.evaluate(PowerSettings(idleSuspendMinutes: 2), .init(now: now, runningSince: ago(15)), minute: 10).suspendIn, 5)
    }

    func testSettingsDecodeFromOlderConfigurations() throws {
        XCTAssertEqual(try JSONDecoder().decode(PowerSettings.self, from: Data("{}".utf8)), PowerSettings())
        XCTAssertEqual(try JSONDecoder().decode(PowerSettings.self, from: Data(#"{"idleSuspendMinutes":30,"keepAwake":true}"#.utf8)),
                       PowerSettings(idleSuspendMinutes: 30, keepAwake: true))
    }

    func testIntervalsInWords() {
        XCTAssertEqual(IdlePolicy.describe(45), "45 s")
        XCTAssertEqual(IdlePolicy.describe(600), "10 min")
        XCTAssertEqual(IdlePolicy.describe(3 * 3600), "3.0 h")
    }
}
