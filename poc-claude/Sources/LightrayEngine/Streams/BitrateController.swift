import LightrayCore

/// The v0 bitrate policy: manual, with a loss backstop.
///
/// There is no control loop and no automatic ramp-up. The sender measures
/// transport loss from FEEDBACK over fixed windows; if loss stays above the
/// threshold for several windows it clamps to the floor and says so, and only a
/// manual RECONFIGURE raises the bitrate again.
struct BitrateController {
    private(set) var target: UInt32
    private(set) var floor: UInt32
    private(set) var backstopEngaged = false

    private var windowStart: Instant = .zero
    private var windowSent = 0
    private var windowLost = 0
    private var consecutiveBadWindows = 0
    private(set) var lastWindowLoss: Double = 0

    let config: EngineConfig

    init(target: UInt32, floor: UInt32, config: EngineConfig, at: Instant) {
        self.target = target
        self.floor = floor
        self.config = config
        self.windowStart = at
    }

    mutating func setManualTarget(_ bitrate: UInt32, floor: UInt32? = nil) {
        target = bitrate
        if let f = floor { self.floor = f }
        // A manual change is the only way out of the backstop.
        backstopEngaged = false
        consecutiveBadWindows = 0
    }

    mutating func recordDelivered() { windowSent += 1 }

    mutating func recordLost() { windowSent += 1; windowLost += 1 }

    enum Outcome: Equatable {
        case unchanged
        case clamped(UInt32)
    }

    /// Closes the window if it has elapsed and applies the backstop.
    mutating func tick(at now: Instant) -> Outcome {
        guard now - windowStart >= config.lossWindow else { return .unchanged }
        windowStart = now
        let sent = windowSent
        let lost = windowLost
        windowSent = 0
        windowLost = 0
        guard sent > 0 else { consecutiveBadWindows = 0; return .unchanged }

        lastWindowLoss = Double(lost) / Double(sent)
        if lastWindowLoss > config.lossBackstopThreshold {
            consecutiveBadWindows += 1
            if consecutiveBadWindows >= config.lossBackstopWindows, !backstopEngaged {
                backstopEngaged = true
                target = floor
                return .clamped(floor)
            }
        } else {
            consecutiveBadWindows = 0
        }
        return .unchanged
    }

    mutating func reset(at now: Instant) {
        windowStart = now
        windowSent = 0
        windowLost = 0
        consecutiveBadWindows = 0
    }
}
