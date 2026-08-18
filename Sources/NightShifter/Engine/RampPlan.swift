import Foundation

enum Easing: String, CaseIterable, Identifiable {
    case linear, smoothstep
    var id: String { rawValue }
    var label: String {
        switch self {
        case .linear: return "Linear"
        case .smoothstep: return "Ease in/out"
        }
    }
    func apply(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        switch self {
        case .linear: return t
        case .smoothstep: return t * t * (3 - 2 * t)
        }
    }
}

enum RampPhase {
    case clear, warming, full, clearing
    var label: String {
        switch self {
        case .clear: return "Clear"
        case .warming: return "Warming"
        case .full: return "Full warmth"
        case .clearing: return "Clearing"
        }
    }
}

/// One monotonic move between two warmth levels.
struct RampSegment {
    var start: Date
    var end: Date
    var from: Float
    var to: Float
}

/// Turns the user's offsets into an absolute strength-vs-time function.
///
/// Everything is expressed relative to the OS's sunset/sunrise instants rather than wall-clock
/// times, so the schedule tracks the seasons with no further input.
struct RampPlan {
    /// Minutes relative to sunset at which warming begins. Negative starts before sunset.
    var eveningOffsetMinutes: Double = -45
    /// How long the evening ramp takes to reach full warmth.
    var eveningRampMinutes: Double = 60
    /// Minutes relative to sunrise at which the screen is fully clear again.
    var morningOffsetMinutes: Double = 0
    /// How long the morning ramp takes to clear.
    var morningRampMinutes: Double = 45
    var maxStrength: Float = 0.5
    var easing: Easing = .smoothstep

    /// Absolute times of the four points that define tonight's curve. These are what the user
    /// drags directly on the chart, so the drawn handles and the applied schedule share one source.
    func anchors(sun: SunSchedule) -> (warmStart: Date, warmFull: Date, coolStart: Date, coolEnd: Date) {
        let warmStart = sun.sunset.addingTimeInterval(eveningOffsetMinutes * 60)
        let coolEnd = sun.nextSunrise.addingTimeInterval(morningOffsetMinutes * 60)
        return (warmStart,
                warmStart.addingTimeInterval(eveningRampMinutes * 60),
                coolEnd.addingTimeInterval(-morningRampMinutes * 60),
                coolEnd)
    }

    func segments(sun: SunSchedule) -> [RampSegment] {
        var out: [RampSegment] = []
        for sunset in [sun.previousSunset, sun.sunset, sun.nextSunset] {
            let start = sunset.addingTimeInterval(eveningOffsetMinutes * 60)
            out.append(RampSegment(start: start,
                                   end: start.addingTimeInterval(eveningRampMinutes * 60),
                                   from: 0, to: maxStrength))
        }
        for sunrise in [sun.previousSunrise, sun.sunrise, sun.nextSunrise] {
            let end = sunrise.addingTimeInterval(morningOffsetMinutes * 60)
            out.append(RampSegment(start: end.addingTimeInterval(-morningRampMinutes * 60),
                                   end: end,
                                   from: maxStrength, to: 0))
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Warmth (0...1) the screen should be at `date`.
    func strength(at date: Date, sun: SunSchedule) -> Float {
        let segs = segments(sun: sun)
        // Inside a ramp: interpolate.
        for seg in segs where date >= seg.start && date <= seg.end {
            let span = seg.end.timeIntervalSince(seg.start)
            guard span > 0 else { return seg.to }
            let t = easing.apply(date.timeIntervalSince(seg.start) / span)
            return seg.from + (seg.to - seg.from) * Float(t)
        }
        // Between ramps: hold whatever the most recent one finished on.
        if let last = segs.last(where: { $0.end < date }) { return last.to }
        return 0
    }

    /// Which leg of the schedule `date` falls on.
    func phase(at date: Date, sun: SunSchedule) -> RampPhase {
        let segs = segments(sun: sun)
        if let current = segs.first(where: { date >= $0.start && date <= $0.end }) {
            return current.to > current.from ? .warming : .clearing
        }
        if let last = segs.last(where: { $0.end < date }) {
            return last.to > 0.001 ? .full : .clear
        }
        return .clear
    }

    /// The next boundary worth showing the user ("full warmth at 20:40").
    func nextTransition(after date: Date, sun: SunSchedule) -> (label: String, at: Date)? {
        let segs = segments(sun: sun)
        if let current = segs.first(where: { date >= $0.start && date <= $0.end }) {
            return (current.to > current.from ? "Full warmth" : "Fully clear", current.end)
        }
        if let next = segs.first(where: { $0.start > date }) {
            return (next.to > next.from ? "Warming starts" : "Clearing starts", next.start)
        }
        return nil
    }
}
