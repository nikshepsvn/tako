import Darwin
import XCTest
@testable import Tako

/// The steward's rules: bands, admission, escalations, sleep, the heavy-job semaphore, and what
/// macOS lets a same-user app do to another process's priority.
final class StewardTests: XCTestCase {
    // MARK: Bands

    func testFocusedWinsOverEveryState() {
        for state in [AgentState.working, .idle, .needsInput("approve"), .exited(0)] {
            XCTAssertEqual(StewardRules.band(state: state, isAgent: true, focused: true), .focused)
        }
    }

    func testHiddenAgentBands() {
        XCTAssertEqual(StewardRules.band(state: .working, isAgent: true, focused: false), .working)
        XCTAssertEqual(StewardRules.band(state: .starting, isAgent: true, focused: false), .working)
        XCTAssertEqual(StewardRules.band(state: .needsInput("approve"), isAgent: true, focused: false), .waiting)
        XCTAssertEqual(StewardRules.band(state: .idle, isAgent: true, focused: false), .idle)
        XCTAssertEqual(StewardRules.band(state: .failed("x"), isAgent: true, focused: false), .idle)
    }

    func testHiddenShellsAndServersCountAsWorking() {
        XCTAssertEqual(StewardRules.band(state: .running, isAgent: false, focused: false), .working)
        XCTAssertEqual(StewardRules.band(state: .idle, isAgent: false, focused: false), .working)
    }

    func testOnlyRestingSessionsAreLoweredUnlessHot() {
        XCTAssertFalse(StewardRules.shouldLower(.focused, thermal: .critical))
        XCTAssertFalse(StewardRules.shouldLower(.working, thermal: .fair))
        XCTAssertTrue(StewardRules.shouldLower(.working, thermal: .serious))
        XCTAssertTrue(StewardRules.shouldLower(.waiting, thermal: .nominal))
        XCTAssertTrue(StewardRules.shouldLower(.idle, thermal: .nominal))
    }

    // MARK: Admission

    func testEstimateIsP75WithMargin() {
        let gb: UInt64 = 1 << 30
        XCTAssertEqual(Admission.estimate([gb, 2 * gb, 3 * gb, 4 * gb]), 3 * gb * 6 / 5)
        XCTAssertEqual(Admission.estimate([0, 0]), Admission.defaultAgentFootprint * 6 / 5)
    }

    func testNormalPressureAdmitsEvenWhenFreeMemoryLooksLow() {
        // macOS keeps "free" low on purpose; its pressure level is the real signal.
        XCTAssertTrue(Admission.admits(available: 100 << 20, pressure: .normal, estimate: 2 << 30, reserved: 2,
                                       activeAgents: 3, maxActiveAgents: nil))
    }

    func testUnderWarningAdmissionNeedsHeadroomForReservedLaunchesToo() {
        let estimate: UInt64 = 600 << 20
        XCTAssertTrue(Admission.admits(available: 1 << 30, pressure: .warning, estimate: estimate, activeAgents: 3, maxActiveAgents: nil))
        XCTAssertFalse(Admission.admits(available: 1 << 30, pressure: .warning, estimate: estimate, reserved: 1,
                                        activeAgents: 3, maxActiveAgents: nil))
        XCTAssertEqual(Admission.blocker(available: 500 << 20, pressure: .warning, estimate: estimate, activeAgents: 0, maxActiveAgents: nil),
                       "memory is short")
    }

    func testAdmissionStopsWhenCriticalAndAtTheCap() {
        let plenty: UInt64 = 32 << 30
        XCTAssertFalse(Admission.admits(available: plenty, pressure: .critical, estimate: 1, activeAgents: 0, maxActiveAgents: nil))
        XCTAssertEqual(Admission.blocker(available: plenty, pressure: .normal, estimate: 1, activeAgents: 4, maxActiveAgents: 4),
                       "4 agents are already working (the cap)")
        XCTAssertTrue(Admission.admits(available: plenty, pressure: .normal, estimate: 1, activeAgents: 3, maxActiveAgents: 4))
    }

    // MARK: Heavy slots

    func testHeavySlotsShrinkUnderPressureAndHeat() {
        XCTAssertEqual(StewardRules.heavySlots(performanceCores: 10, pressure: .normal, thermal: .nominal), 5)
        XCTAssertEqual(StewardRules.heavySlots(performanceCores: 10, pressure: .warning, thermal: .nominal), 2)
        XCTAssertEqual(StewardRules.heavySlots(performanceCores: 10, pressure: .normal, thermal: .serious), 2)
        XCTAssertEqual(StewardRules.heavySlots(performanceCores: 10, pressure: .critical, thermal: .nominal), 1)
        XCTAssertEqual(StewardRules.heavySlots(performanceCores: 1, pressure: .normal, thermal: .nominal), 1)
    }

    func testSemaphoreGrantsInOrderAndFreesOnRelease() {
        var queue = HeavyQueue(capacity: 2)
        var granted: [pid_t] = []
        for pid: pid_t in [11, 12, 13, 14] { queue.acquire(pid) { granted.append(pid) } }
        XCTAssertEqual(granted, [11, 12])
        XCTAssertEqual(queue.waiting, 2)
        queue.release(12)
        XCTAssertEqual(granted, [11, 12, 13])
        queue.release(14)   // a waiter gives up
        queue.release(11)
        XCTAssertEqual(granted, [11, 12, 13])
        XCTAssertEqual(queue.holders, [13])
    }

    func testSemaphoreReapsDeadHoldersAndKeepsSlotsWhenShrunk() {
        var queue = HeavyQueue(capacity: 2)
        var granted: [pid_t] = []
        for pid: pid_t in [21, 22, 23] { queue.acquire(pid) { granted.append(pid) } }
        queue.setCapacity(1)
        XCTAssertEqual(queue.holders, [21, 22], "lowering the capacity never revokes a slot")
        queue.reap { $0 != 21 }
        XCTAssertEqual(queue.holders, [22])
        XCTAssertEqual(granted, [21, 22])
        queue.reap { $0 == 23 }
        XCTAssertEqual(granted, [21, 22, 23])
    }

    // MARK: Escalations

    func testABigAgentAloneIsNotNewsUnderNormalPressure() {
        var tracker = EscalationTracker()
        let now = Date()
        // 4 GB is an ordinary Claude Code; it used to escalate at 3 GB.
        for minute in 0..<60 {
            XCTAssertTrue(tracker.update(sessionID: "a", label: "api", footprint: 4 << 30, cpu: 5, agentIdle: false,
                                         now: now + Double(minute * 60)).isEmpty)
        }
        XCTAssertTrue(tracker.active.isEmpty)
    }

    func testMemoryPressureNamesTheBigAgentsOncePerEpisode() {
        var tracker = EscalationTracker()
        let now = Date()
        let big: UInt64 = 4 << 30
        XCTAssertTrue(tracker.update(sessionID: "s", label: "small", footprint: 1 << 30, cpu: 5, agentIdle: false, pressure: .warning, now: now).isEmpty)
        let raised = tracker.update(sessionID: "a", label: "api", footprint: big, cpu: 5, agentIdle: false, pressure: .warning, now: now)
        XCTAssertEqual(raised.map(\.kind), [.memory])
        XCTAssertTrue(raised[0].message.contains("pressure is warning"), raised[0].message)
        XCTAssertTrue(tracker.update(sessionID: "a", label: "api", footprint: big, cpu: 5, agentIdle: false, pressure: .critical, now: now + 3).isEmpty)
        _ = tracker.update(sessionID: "a", label: "api", footprint: big, cpu: 5, agentIdle: false, pressure: .normal, now: now + 6)
        XCTAssertTrue(tracker.active.isEmpty)
    }

    func testGrowthPastItsOwnBaselineEscalatesAfterWarmup() {
        var tracker = EscalationTracker()
        let start = Date()
        // Early growth is startup, not a leak.
        _ = tracker.update(sessionID: "a", label: "api", footprint: 1 << 30, cpu: 5, agentIdle: false, now: start)
        XCTAssertTrue(tracker.update(sessionID: "a", label: "api", footprint: 4 << 30, cpu: 5, agentIdle: false, now: start + 60).isEmpty)
        var settled = EscalationTracker()
        for minute in 0...20 {
            _ = settled.update(sessionID: "a", label: "api", footprint: 3 << 30, cpu: 5, agentIdle: false, now: start + Double(minute * 60))
        }
        // 1.5x but only 1.5 GB more: quiet. 5.5 GB: 1.8x and 2.5 GB more: news.
        XCTAssertTrue(settled.update(sessionID: "a", label: "api", footprint: 4_831_838_208, cpu: 5, agentIdle: false, now: start + 1_270).isEmpty)
        let raised = settled.update(sessionID: "a", label: "api", footprint: 5_905_580_032, cpu: 5, agentIdle: false, now: start + 1_280)
        XCTAssertEqual(raised.map(\.kind), [.memory])
        XCTAssertTrue(raised[0].message.contains("its usual"), raised[0].message)
    }

    func testARunawayEscalatesWithoutHistoryOrPressure() {
        var tracker = EscalationTracker()
        XCTAssertEqual(tracker.update(sessionID: "a", label: "api", footprint: 13 << 30, cpu: 5, agentIdle: false, now: Date()).map(\.kind), [.memory])
    }

    func testIdleBurningNeedsFiveMinutesWhileIdle() {
        var tracker = EscalationTracker()
        let start = Date()
        XCTAssertTrue(tracker.update(sessionID: "a", label: "api", footprint: 0, cpu: 40, agentIdle: true, now: start).isEmpty)
        XCTAssertTrue(tracker.update(sessionID: "a", label: "api", footprint: 0, cpu: 40, agentIdle: true, now: start + 200).isEmpty)
        let raised = tracker.update(sessionID: "a", label: "api", footprint: 0, cpu: 40, agentIdle: true, now: start + 301)
        XCTAssertEqual(raised.map(\.kind), [.idleBurning])
        XCTAssertEqual(raised.first?.since, start)

        // Working agents may burn CPU; a dip resets the clock.
        var other = EscalationTracker()
        _ = other.update(sessionID: "b", label: "web", footprint: 0, cpu: 90, agentIdle: false, now: start)
        XCTAssertTrue(other.update(sessionID: "b", label: "web", footprint: 0, cpu: 90, agentIdle: false, now: start + 600).isEmpty)
        _ = other.update(sessionID: "b", label: "web", footprint: 0, cpu: 40, agentIdle: true, now: start)
        _ = other.update(sessionID: "b", label: "web", footprint: 0, cpu: 2, agentIdle: true, now: start + 60)
        XCTAssertTrue(other.update(sessionID: "b", label: "web", footprint: 0, cpu: 40, agentIdle: true, now: start + 330).isEmpty)
    }

    func testTakoWarnsOnceWhenItsOwnFootprintCrossesTheLine() {
        var tako = TakoFootprint()
        let now = Date()
        XCTAssertNil(tako.update(1 << 30, now: now))
        XCTAssertEqual(tako.update(TakoFootprint.warnBytes, now: now)?.kind, .takoMemory)
        XCTAssertNil(tako.update(TakoFootprint.warnBytes + (1 << 30), now: now))
        // Hovering just under the line doesn't start a new episode.
        XCTAssertNil(tako.update(TakoFootprint.warnBytes - (1 << 20), now: now))
        XCTAssertNotNil(tako.warning)
        XCTAssertNil(tako.update(1 << 30, now: now))
        XCTAssertNil(tako.warning)
        XCTAssertNotNil(tako.update(TakoFootprint.warnBytes, now: now))
        XCTAssertGreaterThan(TakoFootprint.current(), 0)
    }

    @MainActor func testMachineStatusMentionsTakoItself() {
        var status = MachineStatus(pressure: .normal, thermal: .nominal, lowPower: false, freeBytes: 0, totalBytes: 0,
                                   admissionOK: true, queuedLaunches: 0, heavySlotsUsed: 0, heavySlotsTotal: 1,
                                   heavyWaiting: 0, sessions: [])
        status.takoBytes = 4 << 30
        let text = ControlHandler.describe(status)
        XCTAssertTrue(text.contains("Tako itself · 4.0 GB · high"), text)
    }

    // MARK: Sleep candidates

    func testSleepCandidateAfterQuietIdleStretch() {
        var tracker = SleepTracker()
        tracker.after = 600
        let start = Date()
        XCTAssertFalse(tracker.update(sessionID: "a", band: .idle, cpu: 0.2, now: start))
        XCTAssertFalse(tracker.update(sessionID: "a", band: .idle, cpu: 0.2, now: start + 599))
        XCTAssertTrue(tracker.update(sessionID: "a", band: .idle, cpu: 0.2, now: start + 600))
        XCTAssertFalse(tracker.update(sessionID: "a", band: .idle, cpu: 0.2, now: start + 900), "reported once")
        XCTAssertFalse(tracker.update(sessionID: "a", band: .focused, cpu: 0, now: start + 901))
        XCTAssertFalse(tracker.update(sessionID: "a", band: .idle, cpu: 0, now: start + 902), "the clock restarts")
        XCTAssertFalse(tracker.update(sessionID: "b", band: .waiting, cpu: 0, now: start + 2000))
    }

    // MARK: Sensors

    func testCPUMeterUsesPerProcessDeltas() {
        var meter = CPUMeter()
        XCTAssertNil(meter.update([1: 1_000_000_000], at: 10))
        // pid 1 used 0.5 s, pid 2 is new with 0.5 s, over 2 s: 50%.
        XCTAssertEqual(meter.update([1: 1_500_000_000, 2: 500_000_000], at: 12) ?? -1, 50, accuracy: 0.01)
    }

    func testSensorsReadThisProcess() {
        let usage = ProcessUsage.read(getpid())
        XCTAssertGreaterThan(usage?.footprint ?? 0, 1 << 20)
        XCTAssertGreaterThan(HostMemory.availableBytes(), 0)
        XCTAssertGreaterThanOrEqual(HostMemory.performanceCores, 1)
    }

    func testPolicyRoundTripsThroughDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "StewardTests"))
        defaults.removePersistentDomain(forName: "StewardTests")
        XCTAssertEqual(StewardPolicy.load(defaults), StewardPolicy())
        let policy = StewardPolicy(maxActiveAgents: 4, pinned: ["api"])
        policy.save(defaults)
        XCTAssertEqual(StewardPolicy.load(defaults), policy)
    }

    // MARK: Priority experiment

    /// What a same-user, non-root app can set and undo on another process. Background takes and
    /// clears (scheduler priority drops to 4 and comes back); nice goes up but can't come back
    /// down without root, which is why the steward uses background only.
    func testPriorityExperiment() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }
        let pid = child.processIdentifier
        usleep(100_000)
        let normal = try XCTUnwrap(Priority.schedulerPriority(pid))

        XCTAssertTrue(Priority.lower(pid))
        let lowered = try XCTUnwrap(Priority.schedulerPriority(pid))
        XCTAssertLessThan(lowered, normal)
        XCTAssertTrue(Priority.restore(pid))
        XCTAssertEqual(Priority.schedulerPriority(pid), normal)

        XCTAssertEqual(setpriority(PRIO_PROCESS, id_t(pid), 10), 0, "raising nice is allowed")
        XCTAssertEqual(setpriority(PRIO_PROCESS, id_t(pid), 0), -1, "lowering it again needs root")
        XCTAssertEqual(errno, EACCES)
    }

    func testTheAgentCLIAndItsHelpersAreNotWork() {
        XCTAssertTrue(StewardRules.isAgentMachinery(name: "2.1.289", path: "/Users/u/.local/share/claude/versions/2.1.289"))
        XCTAssertTrue(StewardRules.isAgentMachinery(name: "ht", path: "/Users/u/.tako/bin/ht"))
        XCTAssertFalse(StewardRules.isAgentMachinery(name: "node", path: "/opt/homebrew/bin/node"))
    }
}
