import SwiftUI

struct MenuBarPanel: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var controller = RampController.shared
    @State private var now = Date()
    @State private var previewDate: Date?
    @State private var snapBack: Task<Void, Never>?
    @FocusState private var focusedField: String?

    private let ticker = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if !controller.isSupported {
                Label("This Mac does not report Night Shift support.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let sun = controller.sun {
                SunCurveView(sun: sun, settings: settings, now: now,
                             previewDate: $previewDate,
                             onCommit: { focusedField = nil; controller.tick() },
                             onScrub: scrub)
                HStack(spacing: 6) {
                    Text(previewDate == nil
                         ? "Drag the points to reshape the schedule, or the blue line to scrub time."
                         : "Previewing — snapping back shortly.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                    if previewDate != nil {
                        Button("Now") { snapToNow() }
                            .font(.system(size: 10))
                            .buttonStyle(.borderless)
                    }
                }
                timings(sun: sun)
            } else {
                Label("Waiting for the system sun schedule…", systemImage: "location.slash")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Divider()
            warmthControl
            Divider()

            HStack {
                Toggle("Run schedule", isOn: Binding(
                    get: { settings.engaged },
                    set: { on in settings.engaged = on; on ? controller.engage() : controller.disengage() }
                ))
                .toggleStyle(.switch)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 400)
        // Clicking off a field should drop the caret; a menu bar panel has no window chrome to
        // click, so the panel's own background has to be the target.
        .background(
            Color.clear.contentShape(Rectangle()).onTapGesture { focusedField = nil }
        )
        .onReceive(ticker) { now = $0 }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(stateLabel).font(.headline)
                if let preview = previewDate {
                    Text("at \(preview.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(Color.accentColor)
                } else if let sun = controller.sun,
                          let next = settings.plan.nextTransition(after: now, sun: sun) {
                    Text("\(next.label) at \(next.at.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(displayKelvin))K")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(previewDate == nil ? .primary : Color.accentColor)
                Text("\(Int(displayStrength * 100))% warm")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var stateLabel: String {
        guard let sun = controller.sun else { return "Off" }
        if let preview = previewDate { return settings.plan.phase(at: preview, sun: sun).label }
        guard settings.engaged else { return "Off" }
        return settings.plan.phase(at: now, sun: sun).label
    }

    /// While scrubbing the readout follows the cursor rather than the display, so the numbers and
    /// the dot on the curve always agree.
    private var displayStrength: Double {
        guard let sun = controller.sun else { return Double(controller.currentStrength) }
        if let preview = previewDate { return Double(settings.plan.strength(at: preview, sun: sun)) }
        return Double(controller.currentStrength)
    }
    private var displayKelvin: Float { ColorTemperature.kelvin(forStrength: Float(displayStrength)) }

    /// Auto-return rather than leaving the view parked in the past. The explicit button is there
    /// for when five seconds is too long to wait.
    private func scrub(_ date: Date?) {
        focusedField = nil
        previewDate = date
        snapBack?.cancel()
        guard let date, let sun = controller.sun else {
            controller.endPreview()
            return
        }
        // Tint the actual screen, so scrubbing shows the warmth rather than only describing it.
        controller.preview(strength: settings.plan.strength(at: date, sun: sun))
        snapBack = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await MainActor.run { snapToNow() }
        }
    }

    private func snapToNow() {
        snapBack?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { previewDate = nil }
        controller.endPreview()
    }

    @ViewBuilder
    private func timings(sun: SunSchedule) -> some View {
        let a = settings.plan.anchors(sun: sun)
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
            MinuteRow(title: "Start warming", minutes: $settings.eveningOffsetMinutes,
                      range: -240...180, suffix: relative(settings.eveningOffsetMinutes, "sunset"),
                      at: a.warmStart, focused: $focusedField, onCommit: controller.tick)
            MinuteRow(title: "Warm-up length", minutes: $settings.eveningRampMinutes,
                      range: 0...300, suffix: "to full warmth",
                      at: a.warmFull, focused: $focusedField, onCommit: controller.tick)
            MinuteRow(title: "Clear by", minutes: $settings.morningOffsetMinutes,
                      range: -240...240, suffix: relative(settings.morningOffsetMinutes, "sunrise"),
                      at: a.coolEnd, focused: $focusedField, onCommit: controller.tick)
            MinuteRow(title: "Cool-down length", minutes: $settings.morningRampMinutes,
                      range: 0...300, suffix: "back to clear",
                      at: a.coolStart, focused: $focusedField, onCommit: controller.tick)
        }
    }

    private func relative(_ minutes: Double, _ anchor: String) -> String {
        if minutes == 0 { return "at \(anchor)" }
        return minutes < 0 ? "before \(anchor)" : "after \(anchor)"
    }

    private var warmthControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Maximum warmth").font(.caption)
                Spacer()
                Text("\(Int(ColorTemperature.kelvin(forStrength: Float(settings.maxStrength))))K · \(Int(settings.maxStrength * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: $settings.maxStrength, in: 0...1) { editing in
                if editing { controller.preview(strength: Float(settings.maxStrength)) }
                else { controller.endPreview() }
            }
            Picker("Curve", selection: Binding(get: { settings.easing }, set: { settings.easing = $0 })) {
                ForEach(Easing.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

/// A minute value typed exactly, with a stepper for nudging — the offsets are the part of this
/// schedule people know a precise number for ("45 minutes before sunset"), so a slider fights them.
private struct MinuteRow: View {
    let title: String
    @Binding var minutes: Double
    let range: ClosedRange<Double>
    let suffix: String
    let at: Date
    @FocusState.Binding var focused: String?
    let onCommit: () -> Void

    var body: some View {
        GridRow {
            Text(title).font(.caption).gridColumnAlignment(.leading)
            HStack(spacing: 3) {
                TextField("", value: $minutes, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                    .focused($focused, equals: title)
                    .onSubmit { focused = nil; commit() }
                    .onChange(of: minutes) { _, _ in commit() }
                Stepper("", value: $minutes, in: range, step: 5, onEditingChanged: { _ in commit() })
                    .labelsHidden()
            }
            Text("min \(suffix)").font(.caption).foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(at, format: .dateTime.hour().minute())
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
        }
    }

    private func commit() {
        let clamped = min(max(minutes.rounded(), range.lowerBound), range.upperBound)
        if clamped != minutes { minutes = clamped }
        onCommit()
    }
}
