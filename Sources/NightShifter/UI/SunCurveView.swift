import SwiftUI

/// Two stacked bands sharing one time axis: the sun's arc above, the warmth it drives below.
///
/// The four points that define the warmth curve are draggable. They read and write the same
/// `RampPlan.anchors` the controller applies, so what you drag is literally the schedule — there
/// is no separate editing model that could drift from it.
struct SunCurveView: View {
    let sun: SunSchedule
    @ObservedObject var settings: Settings
    let now: Date
    /// When set, the user is scrubbing: the accent line sits here instead of at `now`.
    @Binding var previewDate: Date?
    var onCommit: () -> Void
    var onScrub: (Date?) -> Void

    enum Handle: Int, CaseIterable, Identifiable {
        case warmStart, warmFull, coolStart, coolEnd
        var id: Int { rawValue }
    }

    private static let space = "chart"

    @State private var active: Handle?
    /// Setting values captured when a drag begins, so the gesture stays absolute rather than
    /// accumulating rounding error across onChanged calls.
    @State private var baseline: (a: Double, b: Double)?

    // The window frames the whole night plus `now`, so every handle stays reachable.
    private var windowStart: Date {
        min(sun.sunset.addingTimeInterval(-3 * 3600), now.addingTimeInterval(-3600))
    }
    private var windowEnd: Date {
        max(sun.nextSunrise.addingTimeInterval(3 * 3600), now.addingTimeInterval(3600))
    }
    private var cursor: Date { previewDate ?? now }
    private func date(atX px: CGFloat, _ w: CGFloat) -> Date {
        let f = min(max(Double(px / w), 0), 1)
        return windowStart.addingTimeInterval(span * f)
    }
    private var span: TimeInterval { windowEnd.timeIntervalSince(windowStart) }

    private func x(_ date: Date, _ w: CGFloat) -> CGFloat {
        CGFloat(date.timeIntervalSince(windowStart) / span) * w
    }
    private func skyHeight(_ h: CGFloat) -> CGFloat { h * 0.54 }
    private func horizon(_ h: CGFloat) -> CGFloat { skyHeight(h) * 0.62 }
    private func warmthTop(_ h: CGFloat) -> CGFloat { skyHeight(h) + 8 }
    private func warmthHeight(_ h: CGFloat) -> CGFloat { h - warmthTop(h) - 12 }
    private func y(strength s: Double, _ h: CGFloat) -> CGFloat {
        warmthTop(h) + warmthHeight(h) - CGFloat(s) * warmthHeight(h)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in draw(ctx, size) }
                scrubLayer(size)
                ForEach(Handle.allCases) { handle in
                    handleView(handle, size)
                }
            }
            // DragGesture reports `location` in the space of the view it is attached to. Without a
            // shared named space a gesture on a narrow subview reports 0...itsOwnWidth, which maps
            // every drag to nearly the same instant. Handles are immune because they use a delta.
            .coordinateSpace(name: Self.space)
        }
        .frame(height: 156)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Drawing

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let h = size.height, w = size.width
        let hz = horizon(h)
        let plan = settings.plan

        var nightBg = Path()
        nightBg.addRect(CGRect(x: 0, y: hz, width: w, height: skyHeight(h) - hz))
        ctx.fill(nightBg, with: .color(.primary.opacity(0.05)))

        // sun arc
        var sunPath = Path(), sunFill = Path()
        sunFill.move(to: CGPoint(x: 0, y: hz))
        let steps = 220
        for i in 0...steps {
            let t = windowStart.addingTimeInterval(span * Double(i) / Double(steps))
            let alt = SolarModel.altitude(at: t, sun: sun)
            let px = w * CGFloat(i) / CGFloat(steps)
            let py = hz - CGFloat(alt) * (alt >= 0 ? hz * 0.9 : (skyHeight(h) - hz) * 0.9)
            if i == 0 { sunPath.move(to: CGPoint(x: px, y: py)) } else { sunPath.addLine(to: CGPoint(x: px, y: py)) }
            sunFill.addLine(to: CGPoint(x: px, y: py))
        }
        sunFill.addLine(to: CGPoint(x: w, y: hz)); sunFill.closeSubpath()
        ctx.fill(sunFill, with: .linearGradient(
            Gradient(colors: [.orange.opacity(0.26), .orange.opacity(0.03)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: skyHeight(h))))
        ctx.stroke(sunPath, with: .color(.orange.opacity(0.85)), lineWidth: 1.6)

        var hzLine = Path()
        hzLine.move(to: CGPoint(x: 0, y: hz)); hzLine.addLine(to: CGPoint(x: w, y: hz))
        ctx.stroke(hzLine, with: .color(.secondary.opacity(0.45)),
                   style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        // warmth curve
        var warm = Path(), warmFill = Path()
        warmFill.move(to: CGPoint(x: 0, y: y(strength: 0, h)))
        for i in 0...steps {
            let t = windowStart.addingTimeInterval(span * Double(i) / Double(steps))
            let s = Double(plan.strength(at: t, sun: sun))
            let px = w * CGFloat(i) / CGFloat(steps)
            let py = y(strength: s, h)
            if i == 0 { warm.move(to: CGPoint(x: px, y: py)) } else { warm.addLine(to: CGPoint(x: px, y: py)) }
            warmFill.addLine(to: CGPoint(x: px, y: py))
        }
        warmFill.addLine(to: CGPoint(x: w, y: y(strength: 0, h))); warmFill.closeSubpath()
        ctx.fill(warmFill, with: .linearGradient(
            Gradient(colors: [.red.opacity(0.34), .red.opacity(0.05)]),
            startPoint: CGPoint(x: 0, y: warmthTop(h)),
            endPoint: CGPoint(x: 0, y: warmthTop(h) + warmthHeight(h))))
        ctx.stroke(warm, with: .color(.red.opacity(0.8)), lineWidth: 1.7)

        // sunset / sunrise references
        for (date, symbol) in [(sun.sunset, "sunset.fill"), (sun.nextSunrise, "sunrise.fill")] {
            let px = x(date, w)
            guard px >= 0, px <= w else { continue }
            var line = Path()
            line.move(to: CGPoint(x: px, y: 0)); line.addLine(to: CGPoint(x: px, y: h))
            // Dotted is reserved for the astronomical references, so the solid `now` line beside
            // them never reads as a second sunset marker.
            ctx.stroke(line, with: .color(.secondary.opacity(0.3)),
                       style: StrokeStyle(lineWidth: 1, dash: [1, 4]))
            ctx.draw(Text(Image(systemName: symbol)).font(.system(size: 9)).foregroundStyle(.secondary),
                     at: CGPoint(x: px, y: 8))
        }

        // Real now stays put in grey while scrubbing, so the cursor always has a reference.
        // Always solid: it is a different kind of thing from the dotted sun references.
        let nx = x(now, w)
        if nx >= 0, nx <= w, previewDate != nil {
            var nowLine = Path()
            nowLine.move(to: CGPoint(x: nx, y: 0)); nowLine.addLine(to: CGPoint(x: nx, y: h - 11))
            ctx.stroke(nowLine, with: .color(.secondary.opacity(0.6)), lineWidth: 1.5)
            ctx.draw(Text("now").font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary),
                     at: CGPoint(x: nx, y: h - 5))
        }

        // Scrub cursor.
        let cx = x(cursor, w)
        if cx >= 0, cx <= w {
            var line = Path()
            line.move(to: CGPoint(x: cx, y: 0)); line.addLine(to: CGPoint(x: cx, y: h))
            ctx.stroke(line, with: .color(.accentColor), lineWidth: 1.5)
            let s = Double(settings.plan.strength(at: cursor, sun: sun))
            ctx.fill(Path(ellipseIn: CGRect(x: cx - 3.5, y: y(strength: s, h) - 3.5, width: 7, height: 7)),
                     with: .color(.accentColor))
        }
    }

    /// The whole chart scrubs, so you can drag or click anywhere to move the cursor; the grip on
    /// the line is the affordance that says so.
    private func scrubLayer(_ size: CGSize) -> some View {
        let cx = x(cursor, size.width)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(.clear).contentShape(Rectangle())
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor)
                .frame(width: 12, height: 5)
                .position(x: cx, y: 3)
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .onChanged { v in onScrub(date(atX: v.location.x, size.width)) }
                .onEnded { v in onScrub(date(atX: v.location.x, size.width)) }
        )
    }

    // MARK: - Handles

    private func position(_ handle: Handle, _ size: CGSize) -> CGPoint {
        let a = settings.plan.anchors(sun: sun)
        let h = size.height, w = size.width
        switch handle {
        case .warmStart: return CGPoint(x: x(a.warmStart, w), y: y(strength: 0, h))
        case .warmFull:  return CGPoint(x: x(a.warmFull, w), y: y(strength: settings.maxStrength, h))
        case .coolStart: return CGPoint(x: x(a.coolStart, w), y: y(strength: settings.maxStrength, h))
        case .coolEnd:   return CGPoint(x: x(a.coolEnd, w), y: y(strength: 0, h))
        }
    }

    private func handleView(_ handle: Handle, _ size: CGSize) -> some View {
        let p = position(handle, size)
        let isActive = active == handle
        return Circle()
            .fill(Color.red)
            .overlay(Circle().stroke(.background, lineWidth: 2))
            .frame(width: isActive ? 13 : 10, height: isActive ? 13 : 10)
            .contentShape(Circle().size(width: 30, height: 30).offset(x: -10, y: -10))
            .position(p)
            .gesture(drag(handle, size))
            .overlay(alignment: .topLeading) {
                if isActive {
                    Text(timeLabel(handle))
                        .font(.system(size: 10, design: .rounded))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                        .position(x: p.x, y: max(10, p.y - 16))
                }
            }
    }

    private func timeLabel(_ handle: Handle) -> String {
        let a = settings.plan.anchors(sun: sun)
        let date: Date
        switch handle {
        case .warmStart: date = a.warmStart
        case .warmFull: date = a.warmFull
        case .coolStart: date = a.coolStart
        case .coolEnd: date = a.coolEnd
        }
        let time = date.formatted(date: .omitted, time: .shortened)
        switch handle {
        case .warmFull, .coolStart:
            return "\(time) · \(Int(ColorTemperature.kelvin(forStrength: Float(settings.maxStrength))))K"
        default:
            return time
        }
    }

    private func drag(_ handle: Handle, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if active != handle {
                    active = handle
                    baseline = captureBaseline(handle)
                }
                guard let base = baseline else { return }
                let minutesPerPoint = (span / 60) / Double(size.width)
                let dMinutes = (value.location.x - value.startLocation.x) * minutesPerPoint
                let dStrength = Double(value.startLocation.y - value.location.y) / Double(warmthHeight(size.height))

                switch handle {
                case .warmStart:
                    settings.eveningOffsetMinutes = clamp((base.a + dMinutes).rounded(), -240, 180)
                case .warmFull:
                    settings.eveningRampMinutes = clamp((base.a + dMinutes).rounded(), 0, 300)
                    settings.maxStrength = clamp(base.b + dStrength, 0, 1)
                case .coolStart:
                    // coolEnd is fixed, so dragging this handle right shortens the cool-down.
                    settings.morningRampMinutes = clamp((base.a - dMinutes).rounded(), 0, 300)
                    settings.maxStrength = clamp(base.b + dStrength, 0, 1)
                case .coolEnd:
                    settings.morningOffsetMinutes = clamp((base.a + dMinutes).rounded(), -240, 240)
                }
            }
            .onEnded { _ in
                active = nil
                baseline = nil
                onCommit()
            }
    }

    private func captureBaseline(_ handle: Handle) -> (Double, Double) {
        switch handle {
        case .warmStart: return (settings.eveningOffsetMinutes, settings.maxStrength)
        case .warmFull:  return (settings.eveningRampMinutes, settings.maxStrength)
        case .coolStart: return (settings.morningRampMinutes, settings.maxStrength)
        case .coolEnd:   return (settings.morningOffsetMinutes, settings.maxStrength)
        }
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
}
