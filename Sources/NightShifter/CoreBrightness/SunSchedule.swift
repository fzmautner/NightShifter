import Foundation

/// The sun times macOS has already computed for the user's location.
///
/// `BrightnessSystemClient` answers a "BlueLightSunSchedule" dictionary containing sunrise/sunset
/// plus the previous and next of each. Reading it means we never link CoreLocation and never
/// trigger a location permission prompt — and our curve can never disagree with the schedule
/// System Settings itself would have used.
struct SunSchedule {
    var previousSunrise: Date
    var previousSunset: Date
    var sunrise: Date
    var sunset: Date
    var nextSunrise: Date
    var nextSunset: Date
    var isDaylight: Bool
}

final class SunScheduleReader {
    static let shared = SunScheduleReader()

    private let client: NSObject?
    private let cls: AnyClass?

    private init() {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        cls = NSClassFromString("BrightnessSystemClient")
        client = (cls as? NSObject.Type)?.init()
    }

    func read() -> SunSchedule? {
        // Selector is copyPropertyForKey:, not copyProperty:.
        guard let client, let cls,
              let m = class_getInstanceMethod(cls, Selector(("copyPropertyForKey:"))) else { return nil }
        typealias FnCopy = @convention(c) (AnyObject, Selector, CFString) -> Unmanaged<AnyObject>?
        let f = unsafeBitCast(method_getImplementation(m), to: FnCopy.self)
        guard let raw = f(client, Selector(("copyPropertyForKey:")), "BlueLightSunSchedule" as CFString),
              let dict = raw.takeRetainedValue() as? [String: Any] else { return nil }

        func date(_ key: String) -> Date? { dict[key] as? Date }
        guard let sunrise = date("sunrise"), let sunset = date("sunset"),
              let nextSunrise = date("nextSunrise"), let nextSunset = date("nextSunset"),
              let prevSunrise = date("previousSunrise"), let prevSunset = date("previousSunset")
        else { return nil }

        return SunSchedule(
            previousSunrise: prevSunrise, previousSunset: prevSunset,
            sunrise: sunrise, sunset: sunset,
            nextSunrise: nextSunrise, nextSunset: nextSunset,
            isDaylight: dict["isDaylight"] as? Bool ?? true
        )
    }
}
