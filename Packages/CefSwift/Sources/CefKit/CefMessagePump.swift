import CCef
import Foundation

/// Drives CEF's message loop from the main run loop (external message pump).
///
/// CEF requests work via `on_schedule_message_pump_work(delay_ms)`; we honor
/// those requests with one-shot timers clamped to the poll interval, and
/// additionally run a steady fallback poll so work is never starved (the
/// official cefclient pattern). The poll is needed because CEF's external
/// pump does not re-request delayed work that was posted while it was already
/// running, so a delayed task is only picked up by the next poll.
///
/// Tako patch: the poll runs at ~30 Hz while browsers exist, and drops to a
/// slow, coalescable tick when the runtime is idle (no browsers), so a
/// Chromium that stays alive with no pages costs ~1 wakeup/s instead of 30.
/// All work happens on the main thread, with a re-entrancy guard around
/// `cef_do_message_loop_work()`.
@MainActor
final class CefMessagePump {
    /// Poll interval while browsers exist (33 ms ≈ 30 Hz).
    static let activeInterval: TimeInterval = 0.033
    /// Poll interval while idle: bounds how late a stranded delayed task runs
    /// when nothing is on screen.
    static let idleInterval: TimeInterval = 1.0

    private var fallbackTimer: Timer?
    private var scheduledTimer: Timer?
    private var isPerformingWork = false
    private var isRunning = false
    /// Whether the slow idle poll is in effect.
    private(set) var isIdle = false

    private var pollInterval: TimeInterval { isIdle ? Self.idleInterval : Self.activeInterval }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startFallbackTimer()
    }

    func stop() {
        isRunning = false
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        scheduledTimer?.invalidate()
        scheduledTimer = nil
    }

    /// Switches between the 30 Hz and the idle poll. Going active also does a
    /// slice of work right away so nothing waits out the idle tick.
    func setIdle(_ idle: Bool) {
        guard idle != isIdle else { return }
        isIdle = idle
        guard isRunning else { return }
        startFallbackTimer()
        if !idle { performWork() }
    }

    private func startFallbackTimer() {
        fallbackTimer?.invalidate()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { _ in
            // Timer fires on the main run loop; CEF's UI thread is the main
            // thread with an external pump.
            MainActor.assumeIsolated {
                CefRuntime.shared.messagePump?.performWork()
            }
        }
        // Idle ticks may be coalesced with other wakeups by the OS.
        if isIdle { timer.tolerance = Self.idleInterval * 0.2 }
        // .common so the pump keeps running during window drags/menus.
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    /// Entry point for `on_schedule_message_pump_work`. May be called from
    /// any thread.
    nonisolated func scheduleWork(delayMilliseconds: Int64) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.scheduleOnMain(delayMilliseconds: delayMilliseconds)
            }
        }
    }

    private func scheduleOnMain(delayMilliseconds: Int64) {
        guard isRunning else { return }
        scheduledTimer?.invalidate()
        scheduledTimer = nil
        if delayMilliseconds <= 0 {
            performWork()
            return
        }
        let delay = min(TimeInterval(delayMilliseconds) / 1000.0, pollInterval)
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                CefRuntime.shared.messagePump?.performWork()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        scheduledTimer = timer
    }

    func performWork() {
        guard isRunning, !isPerformingWork else { return }
        isPerformingWork = true
        cef_do_message_loop_work()
        isPerformingWork = false
    }
}
