import Foundation

/// Typed wrapper over the private `CBBlueLightClient` in CoreBrightness.framework.
///
/// There is no public API for Night Shift; every app that controls it (Shifty, NightShifter,
/// `nightlight`) goes through this class. We resolve it at runtime via dlopen + the ObjC runtime
/// rather than linking a .tbd stub, so a missing/renamed symbol degrades to `isSupported == false`
/// instead of failing to launch.
enum NightShiftMode: Int32 {
    case off = 0      // no schedule; strength is whatever we last set
    case solar = 1    // macOS drives sunset -> sunrise
    case custom = 2   // macOS drives a fixed from/to time
}

struct NightShiftStatus {
    var active = false
    var enabled = false
    var sunSchedulePermitted = false
    var mode: NightShiftMode = .off
    var scheduleFrom = (hour: Int32(0), minute: Int32(0))
    var scheduleTo = (hour: Int32(0), minute: Int32(0))
}

final class NightShiftClient {
    static let shared = NightShiftClient()

    private let client: NSObject?
    private let cls: AnyClass?

    // getBlueLightStatus: writes a 40-byte C struct. The equivalent Swift struct reports
    // MemoryLayout.size == 33 (Swift omits the trailing padding C includes), so passing it via
    // withUnsafeMutableBytes overflows by 7 bytes and silently corrupts the stack. Always hand
    // the callee an over-allocated raw buffer and read fields back by measured offset.
    private static let statusBufferSize = 64
    private enum Offset {
        static let active = 0, enabled = 1, sunPermitted = 2
        static let mode = 4
        static let fromHour = 8, fromMinute = 12, toHour = 16, toMinute = 20
    }

    private init() {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        cls = NSClassFromString("CBBlueLightClient")
        client = (cls as? NSObject.Type)?.init()
    }

    private func fn<T>(_ selector: String, _ type: T.Type) -> T? {
        guard let cls, let m = class_getInstanceMethod(cls, Selector((selector))) else { return nil }
        return unsafeBitCast(method_getImplementation(m), to: type)
    }

    private typealias FnGetFloat = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Float>) -> ObjCBool
    private typealias FnSetStrengthCommit = @convention(c) (AnyObject, Selector, Float, ObjCBool) -> ObjCBool
    private typealias FnSetStrengthPeriod = @convention(c) (AnyObject, Selector, Float, Float, ObjCBool) -> ObjCBool
    private typealias FnSetBool = @convention(c) (AnyObject, Selector, ObjCBool) -> ObjCBool
    private typealias FnSetInt = @convention(c) (AnyObject, Selector, Int32) -> ObjCBool
    private typealias FnStatus = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> ObjCBool

    var isSupported: Bool {
        guard let client, let cls,
              let m = class_getInstanceMethod(cls, Selector(("supported"))) else { return false }
        typealias FnBool = @convention(c) (AnyObject, Selector) -> ObjCBool
        let f = unsafeBitCast(method_getImplementation(m), to: FnBool.self)
        return f(client, Selector(("supported"))).boolValue
    }

    private func readFloat(_ selector: String) -> Float? {
        guard let client, let f = fn(selector, FnGetFloat.self) else { return nil }
        var v: Float = 0
        return f(client, Selector((selector)), &v).boolValue ? v : nil
    }

    /// The configured warmth (0...1). NOTE: this is the *target* the slider is set to, not the
    /// instantaneous applied tint — it returns the new value immediately after a set, even while
    /// a transition is still visibly in progress.
    var strength: Float { readFloat("getStrength:") ?? 0 }

    /// Correlated colour temperature in Kelvin for the current strength.
    var cct: Float { readFloat("getCCT:") ?? 0 }

    var status: NightShiftStatus {
        var out = NightShiftStatus()
        guard let client, let f = fn("getBlueLightStatus:", FnStatus.self) else { return out }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Self.statusBufferSize, alignment: 8)
        defer { buf.deallocate() }
        buf.initializeMemory(as: UInt8.self, repeating: 0, count: Self.statusBufferSize)
        guard f(client, Selector(("getBlueLightStatus:")), buf).boolValue else { return out }
        out.active = buf.load(fromByteOffset: Offset.active, as: UInt8.self) != 0
        out.enabled = buf.load(fromByteOffset: Offset.enabled, as: UInt8.self) != 0
        out.sunSchedulePermitted = buf.load(fromByteOffset: Offset.sunPermitted, as: UInt8.self) != 0
        out.mode = NightShiftMode(rawValue: buf.load(fromByteOffset: Offset.mode, as: Int32.self)) ?? .off
        out.scheduleFrom = (buf.load(fromByteOffset: Offset.fromHour, as: Int32.self),
                            buf.load(fromByteOffset: Offset.fromMinute, as: Int32.self))
        out.scheduleTo = (buf.load(fromByteOffset: Offset.toHour, as: Int32.self),
                          buf.load(fromByteOffset: Offset.toMinute, as: Int32.self))
        return out
    }

    @discardableResult
    func setEnabled(_ on: Bool) -> Bool {
        guard let client, let f = fn("setEnabled:", FnSetBool.self) else { return false }
        return f(client, Selector(("setEnabled:")), ObjCBool(on)).boolValue
    }

    @discardableResult
    func setMode(_ mode: NightShiftMode) -> Bool {
        guard let client, let f = fn("setMode:", FnSetInt.self) else { return false }
        return f(client, Selector(("setMode:")), mode.rawValue).boolValue
    }

    /// Set warmth. `commit: false` is the preview path System Settings uses while dragging — it
    /// applies without writing prefs, so ramp ticks should use it and only checkpoint occasionally.
    /// `period` asks CoreBrightness to ease into the value; harmless where unsupported.
    @discardableResult
    func setStrength(_ value: Float, period: Float = 0, commit: Bool = false) -> Bool {
        guard let client else { return false }
        let clamped = min(max(value, 0), 1)
        if period > 0, let f = fn("setStrength:withPeriod:commit:", FnSetStrengthPeriod.self) {
            return f(client, Selector(("setStrength:withPeriod:commit:")), clamped, period, ObjCBool(commit)).boolValue
        }
        guard let f = fn("setStrength:commit:", FnSetStrengthCommit.self) else { return false }
        return f(client, Selector(("setStrength:commit:")), clamped, ObjCBool(commit)).boolValue
    }
}

/// Measured on macOS 15.6.1: the strength->Kelvin curve is piecewise linear with its knee exactly
/// at the values `getWarningStrength:`/`getWarningCCT:` report (0.5 -> 4100K). A single linear fit
/// through the lower half mispredicts the warm end by ~350K.
enum ColorTemperature {
    static let coolCCT: Float = 6000
    static let warnStrength: Float = 0.5
    static let warnCCT: Float = 4100
    static let warmCCT: Float = 2700
    /// The hardware quantises CCT to 20K, so ~0.0053 strength is the smallest visible step on the
    /// cool segment. Ramp ticks finer than that are wasted work.
    static let quantumK: Float = 20

    static func kelvin(forStrength s: Float) -> Float {
        let s = min(max(s, 0), 1)
        if s <= warnStrength {
            return coolCCT + (warnCCT - coolCCT) * (s / warnStrength)
        }
        return warnCCT + (warmCCT - warnCCT) * ((s - warnStrength) / (1 - warnStrength))
    }

    static func strength(forKelvin k: Float) -> Float {
        let k = min(max(k, warmCCT), coolCCT)
        if k >= warnCCT {
            return warnStrength * (coolCCT - k) / (coolCCT - warnCCT)
        }
        return warnStrength + (1 - warnStrength) * (warnCCT - k) / (warnCCT - warmCCT)
    }
}
