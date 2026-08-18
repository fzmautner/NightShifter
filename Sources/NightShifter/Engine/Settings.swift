import Foundation
import SwiftUI

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    @AppStorage("engaged") var engaged: Bool = false
    @AppStorage("eveningOffsetMinutes") var eveningOffsetMinutes: Double = -45
    @AppStorage("eveningRampMinutes") var eveningRampMinutes: Double = 60
    @AppStorage("morningOffsetMinutes") var morningOffsetMinutes: Double = 0
    @AppStorage("morningRampMinutes") var morningRampMinutes: Double = 45
    @AppStorage("maxStrength") var maxStrength: Double = 0.5
    @AppStorage("easingRaw") var easingRaw: String = Easing.smoothstep.rawValue

    var easing: Easing {
        get { Easing(rawValue: easingRaw) ?? .smoothstep }
        set { easingRaw = newValue.rawValue }
    }

    var plan: RampPlan {
        RampPlan(eveningOffsetMinutes: eveningOffsetMinutes,
                 eveningRampMinutes: eveningRampMinutes,
                 morningOffsetMinutes: morningOffsetMinutes,
                 morningRampMinutes: morningRampMinutes,
                 maxStrength: Float(maxStrength),
                 easing: easing)
    }
}
