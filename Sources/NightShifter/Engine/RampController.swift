import Foundation
import AppKit
import Combine

/// Drives Night Shift warmth on a timer.
///
/// CoreBrightness applies Night Shift below CoreGraphics (it does not appear in the display's
/// gamma table), so there is no way to observe the tint actually on screen — we can only command
/// it. The ramp is therefore open-loop: recompute the target from the clock each tick and set it.
@MainActor
final class RampController: ObservableObject {
    static let shared = RampController()

    /// The hardware quantises CCT to 20K, ~0.0053 strength on the cool segment. At 20s a 60-minute
    /// ramp lands ~180 ticks across ~95 visible steps, so every visible step is a single quantum.
    private static let tickInterval: TimeInterval = 20

    @Published private(set) var currentStrength: Float = 0
    @Published private(set) var sun: SunSchedule?
    @Published private(set) var isSupported: Bool = true

    private var timer: Timer?
    private var restoreMode: NightShiftMode?
    private var restoreStrength: Float?
    private var lastCommitted: Float = -1
    /// Enabled/strength captured when a preview starts, so scrubbing can tint the real screen and
    /// still hand it back — including when we are not engaged and macOS still owns the schedule.
    private var previewRestore: (enabled: Bool, strength: Float)?
    private let client = NightShiftClient.shared
    private var observers: [NSObjectProtocol] = []

    private init() {
        isSupported = client.isSupported
        sun = SunScheduleReader.shared.read()

        // A ramp computed before sleep is stale on wake; recompute immediately rather than waiting
        // out the remainder of the tick.
        let wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in Task { @MainActor in RampController.shared.tick() } }
        observers.append(wake)

        let timeChange = NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main
        ) { _ in Task { @MainActor in RampController.shared.tick() } }
        observers.append(timeChange)
    }

    func engage() {
        guard restoreMode == nil else { return }
        let status = client.status
        restoreMode = status.mode
        restoreStrength = client.strength
        // Take the schedule away from macOS; we own enabled/strength from here.
        client.setMode(.off)
        startTimer()
        tick()
    }

    func disengage() {
        stopTimer()
        if let mode = restoreMode { client.setMode(mode) }
        if let strength = restoreStrength { client.setStrength(strength, commit: true) }
        client.setEnabled(false)
        restoreMode = nil
        restoreStrength = nil
        currentStrength = 0
    }

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: Self.tickInterval, repeats: true) { _ in
            Task { @MainActor in RampController.shared.tick() }
        }
        // .common so the ramp keeps running while a menu is open tracking events.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func tick() {
        guard restoreMode != nil else { return }
        guard let schedule = SunScheduleReader.shared.read() else { return }
        sun = schedule

        let target = Settings.shared.plan.strength(at: Date(), sun: schedule)
        currentStrength = target

        if target <= 0.001 {
            client.setStrength(0, commit: false)
            client.setEnabled(false)
            return
        }
        client.setEnabled(true)
        // commit:false is the preview path — it applies without writing prefs. Persist only when
        // we settle on a plateau, so an hour-long ramp is one pref write rather than 180.
        let atPlateau = abs(target - Float(Settings.shared.maxStrength)) < 0.001
        let shouldCommit = atPlateau && abs(target - lastCommitted) > 0.001
        client.setStrength(target, period: Float(Self.tickInterval), commit: shouldCommit)
        if shouldCommit { lastCommitted = target }
    }

    /// Live preview while the user drags a slider or scrubs the timeline. Applies to the display
    /// so the warmth can actually be seen, but never persists.
    func preview(strength: Float) {
        if previewRestore == nil {
            previewRestore = (client.status.enabled, client.strength)
        }
        client.setEnabled(strength > 0.001)
        client.setStrength(strength, commit: false)
    }

    /// Put the screen back. If we own the schedule the next tick is authoritative; if macOS still
    /// owns it, restore what it had and let its own ramp carry on from there.
    func endPreview() {
        guard let restore = previewRestore else { return }
        previewRestore = nil
        if restoreMode != nil {
            tick()
        } else {
            client.setStrength(restore.strength, commit: false)
            client.setEnabled(restore.enabled)
        }
    }

    var currentKelvin: Float { ColorTemperature.kelvin(forStrength: currentStrength) }
}
