import Foundation

/// A normalised sun-altitude curve in -1...1, anchored so its zero crossings land exactly on the
/// sunrise/sunset the OS reports.
///
/// We deliberately do not compute true solar elevation in degrees. Recovering latitude from day
/// length is ill-conditioned — it is very sensitive to the declination estimate and the refraction
/// constant, and a plausible-looking fit can be several degrees out. Anchoring to the OS's own
/// times instead guarantees the drawn curve and the applied schedule never disagree, which is the
/// property that actually matters here.
enum SolarModel {

    static func altitude(at date: Date, sun: SunSchedule) -> Double {
        // Daylight arc: sunrise -> sunset, peaking at solar noon.
        if date >= sun.sunrise, date <= sun.sunset {
            return arc(date, from: sun.sunrise, to: sun.sunset, sign: 1)
        }
        // Night arc following today's sunset.
        if date > sun.sunset, date <= sun.nextSunrise {
            return arc(date, from: sun.sunset, to: sun.nextSunrise, sign: -1)
        }
        // Night arc preceding today's sunrise.
        if date >= sun.previousSunset, date < sun.sunrise {
            return arc(date, from: sun.previousSunset, to: sun.sunrise, sign: -1)
        }
        // Daylight arc on the neighbouring day.
        if date > sun.nextSunrise, date <= sun.nextSunset {
            return arc(date, from: sun.nextSunrise, to: sun.nextSunset, sign: 1)
        }
        if date >= sun.previousSunrise, date < sun.previousSunset {
            return arc(date, from: sun.previousSunrise, to: sun.previousSunset, sign: 1)
        }
        return 0
    }

    private static func arc(_ date: Date, from start: Date, to end: Date, sign: Double) -> Double {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return 0 }
        let fraction = date.timeIntervalSince(start) / span
        return sign * sin(.pi * min(max(fraction, 0), 1))
    }
}
