import Foundation

/// User-adjustable Norwegian 4×4 structure. The defaults are the canonical
/// protocol; nobody has to open settings to get it.
public struct N4x4Settings: Equatable, Hashable, Sendable, Codable {
    public var warmUpMinutes = 3
    public var intervalMinutes = 4
    public var recoveryMinutes = 3
    public var rounds = 4
    public var cooldownMinutes = 3
    public var highLowerPercent = 85
    public var highUpperPercent = 95
    public var recoveryLowerPercent = 65
    public var recoveryUpperPercent = 70
    public var toleranceBPM = 8

    public static let standard = N4x4Settings()

    public init() {}

    public var isStandard: Bool { self == .standard }

    public var totalMinutes: Int {
        warmUpMinutes + rounds * intervalMinutes + max(rounds - 1, 0) * recoveryMinutes + cooldownMinutes
    }

    public var highFraction: ClosedRange<Double> {
        Double(highLowerPercent) / 100...Double(highUpperPercent) / 100
    }

    public var recoveryFraction: ClosedRange<Double> {
        Double(recoveryLowerPercent) / 100...Double(recoveryUpperPercent) / 100
    }

    func target(for kind: PhaseKind) -> HeartRateTarget? {
        switch kind {
        case .highIntensity:
            return .fractionOfMax(lower: highFraction.lowerBound, upper: highFraction.upperBound)
        case .activeRecovery:
            return .fractionOfMax(lower: recoveryFraction.lowerBound, upper: recoveryFraction.upperBound)
        default:
            return nil
        }
    }

    static func label(for kind: PhaseKind, rounds: Int) -> String {
        switch kind {
        case .warmUp:                return "Warm-up"
        case .highIntensity(let r):  return "\(r)/\(rounds) (high intensity)"
        case .activeRecovery(let r): return "\(r)/\(rounds) (recovery)"
        case .cooldown:              return "Cool-down"
        case .steady:                return "Steady"
        case .fixedWorkload:         return "Hold your workload"
        case .stillness:             return "Stand still"
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = N4x4Settings.standard
        warmUpMinutes = try c.decodeIfPresent(Int.self, forKey: .warmUpMinutes) ?? d.warmUpMinutes
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? d.intervalMinutes
        recoveryMinutes = try c.decodeIfPresent(Int.self, forKey: .recoveryMinutes) ?? d.recoveryMinutes
        rounds = try c.decodeIfPresent(Int.self, forKey: .rounds) ?? d.rounds
        cooldownMinutes = try c.decodeIfPresent(Int.self, forKey: .cooldownMinutes) ?? d.cooldownMinutes
        highLowerPercent = try c.decodeIfPresent(Int.self, forKey: .highLowerPercent) ?? d.highLowerPercent
        highUpperPercent = try c.decodeIfPresent(Int.self, forKey: .highUpperPercent) ?? d.highUpperPercent
        recoveryLowerPercent = try c.decodeIfPresent(Int.self, forKey: .recoveryLowerPercent) ?? d.recoveryLowerPercent
        recoveryUpperPercent = try c.decodeIfPresent(Int.self, forKey: .recoveryUpperPercent) ?? d.recoveryUpperPercent
        toleranceBPM = try c.decodeIfPresent(Int.self, forKey: .toleranceBPM) ?? d.toleranceBPM
    }
}

/// Hold-HR mode: keep one heart rate for a set time.
public struct SteadySettings: Equatable, Hashable, Sendable, Codable {
    /// `nil` derives the target from HRmax (≈70%, the top of the aerobic zone).
    public var targetBPM: Int?
    public var toleranceBPM = 5
    public var durationMinutes = 30
    public var warmUpMinutes = 5

    public static let standard = SteadySettings()

    public init() {}

    /// The bpm this session will hold: the user's own value, else 70% of
    /// HRmax rounded to 5, else a conservative 130.
    public func resolvedTarget(hrMax: Double?) -> Int {
        if let targetBPM { return targetBPM }
        guard let hrMax else { return 130 }
        return Int((hrMax * 0.70 / 5).rounded()) * 5
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SteadySettings.standard
        targetBPM = try c.decodeIfPresent(Int.self, forKey: .targetBPM)
        toleranceBPM = try c.decodeIfPresent(Int.self, forKey: .toleranceBPM) ?? d.toleranceBPM
        durationMinutes = try c.decodeIfPresent(Int.self, forKey: .durationMinutes) ?? d.durationMinutes
        warmUpMinutes = try c.decodeIfPresent(Int.self, forKey: .warmUpMinutes) ?? d.warmUpMinutes
    }
}

/// The heart check's fixed workload. It must stay identical between checks:
/// only then does a change in heart rate mean a change in fitness.
public struct HeartCheckWorkload: Equatable, Hashable, Sendable, Codable {
    public var equipment: WorkoutEquipment
    public var speedKilometersPerHour: Double?
    public var inclinePercent: Double?
    /// Free-text machine setting for equipment without speed/incline, e.g. "Level 8".
    public var setting: String

    public init(
        equipment: WorkoutEquipment,
        speedKilometersPerHour: Double? = nil,
        inclinePercent: Double? = nil,
        setting: String = ""
    ) {
        self.equipment = equipment
        self.speedKilometersPerHour = speedKilometersPerHour
        self.inclinePercent = inclinePercent
        self.setting = setting
    }

    /// Short human description, e.g. "Treadmill walk · 5.5 km/h · 8%".
    public var summary: String {
        var parts = [equipment.title]
        if let speedKilometersPerHour {
            parts.append("\(speedKilometersPerHour.formatted(.number.precision(.fractionLength(0...1)))) km/h")
        }
        if let inclinePercent {
            parts.append("\(inclinePercent.formatted(.number.precision(.fractionLength(0...1))))%")
        }
        let trimmed = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(trimmed) }
        return parts.joined(separator: " · ")
    }

    /// The workload phase instruction shown during the check.
    public var instruction: String {
        var parts: [String] = []
        if let speedKilometersPerHour {
            parts.append("\(speedKilometersPerHour.formatted(.number.precision(.fractionLength(0...1)))) km/h")
        }
        if let inclinePercent {
            parts.append("\(inclinePercent.formatted(.number.precision(.fractionLength(0...1))))%")
        }
        let trimmed = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(trimmed) }
        return parts.isEmpty ? "Hold your workload" : "Hold " + parts.joined(separator: " · ")
    }
}

/// Everything adjustable about the guided workouts, shared phone → Watch.
public struct WorkoutSettings: Equatable, Hashable, Sendable, Codable {
    /// `nil` uses the automatic estimate (``HRMaxEstimator``).
    public var customMaxHeartRate: Int?
    public var n4x4 = N4x4Settings()
    public var steady = SteadySettings()
    public var heartCheckWorkload: HeartCheckWorkload?
    /// Last equipment chosen, offered first on the next start (also on Watch).
    public var lastEquipment: WorkoutEquipment = .unspecified

    public init() {}

    /// HRmax used for targets: the user's own value wins over the estimate.
    public func resolvedMaxHeartRate(estimated: Double?) -> Double? {
        customMaxHeartRate.map(Double.init) ?? estimated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        customMaxHeartRate = try c.decodeIfPresent(Int.self, forKey: .customMaxHeartRate)
        n4x4 = try c.decodeIfPresent(N4x4Settings.self, forKey: .n4x4) ?? .standard
        steady = try c.decodeIfPresent(SteadySettings.self, forKey: .steady) ?? .standard
        heartCheckWorkload = try c.decodeIfPresent(HeartCheckWorkload.self, forKey: .heartCheckWorkload)
        lastEquipment = (try? c.decodeIfPresent(WorkoutEquipment.self, forKey: .lastEquipment)) ?? .unspecified
    }
}

// MARK: - Programs

extension ProtocolConfig {
    /// Norwegian 4×4 with the user's structure and zones.
    public static func n4x4(_ settings: N4x4Settings) -> ProtocolConfig {
        let rounds = max(settings.rounds, 1)
        var blocks: [(PhaseKind, Int)] = []
        if settings.warmUpMinutes > 0 { blocks.append((.warmUp, settings.warmUpMinutes)) }
        for round in 1...rounds {
            blocks.append((.highIntensity(round: round), settings.intervalMinutes))
            if round < rounds, settings.recoveryMinutes > 0 {
                blocks.append((.activeRecovery(round: round), settings.recoveryMinutes))
            }
        }
        if settings.cooldownMinutes > 0 { blocks.append((.cooldown, settings.cooldownMinutes)) }

        return ProtocolConfig(
            mode: .n4x4,
            blocks: blocks.map { kind, minutes in
                Block(
                    kind: kind,
                    duration: TimeInterval(minutes * 60),
                    target: settings.target(for: kind),
                    label: N4x4Settings.label(for: kind, rounds: rounds)
                )
            },
            rampDuration: 60,
            deadBand: Double(settings.toleranceBPM)
        )
    }

    /// Hold one heart rate. The target line eases up from the warm-up HR over
    /// three minutes, then holds; End after five minutes saves the session.
    public static func steadyHeartRate(_ settings: SteadySettings, hrMax: Double?) -> ProtocolConfig {
        let target = Double(settings.resolvedTarget(hrMax: hrMax))
        var blocks: [Block] = []
        if settings.warmUpMinutes > 0 {
            blocks.append(Block(
                kind: .warmUp,
                duration: TimeInterval(settings.warmUpMinutes * 60),
                target: nil,
                label: "Warm-up"
            ))
        }
        blocks.append(Block(
            kind: .steady,
            duration: TimeInterval(max(settings.durationMinutes, 1) * 60),
            target: .beatsPerMinute(lower: target, upper: target),
            label: "Hold \(Int(target)) bpm"
        ))
        return ProtocolConfig(
            mode: .steadyHeartRate,
            blocks: blocks,
            rampDuration: 180,
            deadBand: Double(settings.toleranceBPM),
            finishesEarlyAfter: 5 * 60
        )
    }

    /// Heart check: 3 min easy warm-up, 6 min at the fixed workload, then 2 min
    /// standing still while the heart-rate drop is measured.
    public static let heartCheckWarmUp: TimeInterval = 3 * 60
    public static let heartCheckWorkload: TimeInterval = 6 * 60
    public static let heartCheckStillness: TimeInterval = 2 * 60

    public static func heartCheck(_ workload: HeartCheckWorkload?) -> ProtocolConfig {
        ProtocolConfig(
            mode: .heartCheck,
            blocks: [
                Block(kind: .warmUp, duration: heartCheckWarmUp, target: nil, label: "Warm-up · easy"),
                Block(
                    kind: .fixedWorkload,
                    duration: heartCheckWorkload,
                    target: nil,
                    label: workload?.instruction ?? "Hold your workload"
                ),
                Block(kind: .stillness, duration: heartCheckStillness, target: nil, label: "Stop and stand still"),
            ],
            rampDuration: 60,
            deadBand: IntervalEngine.deadBandBPM
        )
    }
}

extension WorkoutSettings {
    /// The protocol to run for `mode` with these settings.
    public func program(for mode: WorkoutMode, hrMax: Double?) -> ProtocolConfig {
        switch mode {
        case .n4x4:            return .n4x4(n4x4)
        case .steadyHeartRate: return .steadyHeartRate(steady, hrMax: hrMax)
        case .heartCheck:      return .heartCheck(heartCheckWorkload)
        }
    }
}
