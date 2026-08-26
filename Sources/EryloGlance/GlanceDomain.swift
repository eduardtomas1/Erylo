import EryloActivity
import Foundation

public enum GlanceProviderCapability: Equatable, Sendable {
    case unknownWhileDisabled
    case available
    case unavailable
    case permissionRequired
    case permissionDenied
    case restricted
}

public enum GlanceProviderFailure: Equatable, Sendable {
    case eventSourceUnavailable
    case sourceQueryFailed
    case permissionRequestFailed
    case permissionDenied
    case permissionRestricted
    case invalidSourceData
    case brokerRejected
}

public enum GlanceProviderHealth: Equatable, Sendable {
    case disabled
    case starting
    case healthy
    case unavailable(GlanceProviderFailure)
    case degraded(GlanceProviderFailure)
}

public struct GlanceProviderStatus: Equatable, Sendable {
    public let isEnabled: Bool
    public let capability: GlanceProviderCapability
    public let health: GlanceProviderHealth

    public init(
        isEnabled: Bool,
        capability: GlanceProviderCapability,
        health: GlanceProviderHealth
    ) {
        self.isEnabled = isEnabled
        self.capability = capability
        self.health = health
    }

    public static let disabled = Self(
        isEnabled: false,
        capability: .unknownWhileDisabled,
        health: .disabled
    )
}

public struct GlanceProviderWorkState: Equatable, Sendable {
    public let activeObserverCount: Int
    public let activeConsumerTaskCount: Int
    public let scheduledBoundaryCount: Int

    public init(
        activeObserverCount: Int,
        activeConsumerTaskCount: Int,
        scheduledBoundaryCount: Int
    ) {
        self.activeObserverCount = activeObserverCount
        self.activeConsumerTaskCount = activeConsumerTaskCount
        self.scheduledBoundaryCount = scheduledBoundaryCount
    }

    public var isIdle: Bool {
        activeObserverCount == 0
            && activeConsumerTaskCount == 0
            && scheduledBoundaryCount == 0
    }
}

public enum GlanceDataError: Error, Equatable, Sendable {
    case invalidChargeLevel
    case invalidVolume
    case invalidDateRange
    case countdownDurationOutOfRange
    case meetingDurationOutOfRange
}

public enum GlanceConfigurationError: Error, Equatable, Sendable {
    case invalidCalendarLookAhead
}

public struct CalendarLookAhead: Equatable, Sendable {
    public static let maximumSeconds: TimeInterval = 30 * 24 * 60 * 60
    public static let sevenDays = Self(uncheckedSeconds: 7 * 24 * 60 * 60)

    public let seconds: TimeInterval

    public init(seconds: TimeInterval) throws(GlanceConfigurationError) {
        guard seconds.isFinite, seconds > 0 else {
            throw .invalidCalendarLookAhead
        }
        self.seconds = min(seconds, Self.maximumSeconds)
    }

    private init(uncheckedSeconds: TimeInterval) {
        seconds = uncheckedSeconds
    }
}

public struct PowerSnapshot: Equatable, Sendable {
    public let chargeLevel: Double
    public let isCharging: Bool
    public let isConnectedToPower: Bool

    public init(
        chargeLevel: Double,
        isCharging: Bool,
        isConnectedToPower: Bool
    ) throws(GlanceDataError) {
        guard chargeLevel.isFinite, (0...1).contains(chargeLevel) else {
            throw .invalidChargeLevel
        }
        self.chargeLevel = chargeLevel
        self.isCharging = isCharging
        self.isConnectedToPower = isConnectedToPower
    }
}

public enum PowerSourceEvent: Equatable, Sendable {
    case snapshot(PowerSnapshot)
    case unavailable
}

public struct VolumeSnapshot: Equatable, Sendable {
    public let deviceID: UInt32
    public let scalar: Double
    public let isMuted: Bool

    public init(deviceID: UInt32, scalar: Double, isMuted: Bool) throws(GlanceDataError) {
        guard scalar.isFinite, (0...1).contains(scalar) else {
            throw .invalidVolume
        }
        self.deviceID = deviceID
        self.scalar = scalar
        self.isMuted = isMuted
    }
}

public enum VolumeSourceEvent: Equatable, Sendable {
    case snapshot(VolumeSnapshot)
    case unavailable
}

public enum CalendarAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case fullAccess
    case writeOnly
}

public struct CalendarMeeting: Equatable, Sendable {
    public static let maximumDuration: TimeInterval = 7 * 24 * 60 * 60

    public let eventIdentifier: String
    public let title: String
    public let startDate: Date
    public let endDate: Date

    public init(
        eventIdentifier: String,
        title: String,
        startDate: Date,
        endDate: Date
    ) throws(GlanceDataError) {
        guard startDate.timeIntervalSinceReferenceDate.isFinite,
              endDate.timeIntervalSinceReferenceDate.isFinite,
              endDate > startDate else {
            throw .invalidDateRange
        }
        guard endDate.timeIntervalSince(startDate) <= Self.maximumDuration else {
            throw .meetingDurationOutOfRange
        }
        self.eventIdentifier = GlanceText.bounded(
            eventIdentifier,
            maximumBytes: 512,
            fallback: "unknown-event"
        )
        self.title = GlanceText.bounded(
            title,
            maximumBytes: ActivityLimits.titleBytes,
            fallback: "Upcoming meeting"
        )
        self.startDate = startDate
        self.endDate = endDate
    }
}

public struct CountdownTimer: Equatable, Sendable {
    public static let maximumDuration: TimeInterval = 30 * 24 * 60 * 60

    public let title: String
    public let startedAt: Date
    public let endsAt: Date

    public init(title: String, startedAt: Date, endsAt: Date) throws(GlanceDataError) {
        guard startedAt.timeIntervalSinceReferenceDate.isFinite,
              endsAt.timeIntervalSinceReferenceDate.isFinite,
              endsAt > startedAt else {
            throw .invalidDateRange
        }
        guard endsAt.timeIntervalSince(startedAt) <= Self.maximumDuration else {
            throw .countdownDurationOutOfRange
        }
        self.title = GlanceText.bounded(
            title,
            maximumBytes: ActivityLimits.titleBytes,
            fallback: "Timer"
        )
        self.startedAt = startedAt
        self.endsAt = endsAt
    }

    public func fractionCompleted(at date: Date) -> Double {
        let duration = endsAt.timeIntervalSince(startedAt)
        let elapsed = date.timeIntervalSince(startedAt)
        return min(max(elapsed / duration, 0), 1)
    }

    /// Bounded timestamp-derived state for a surface to render without broker tick submissions.
    public func presentation(at date: Date) -> CountdownPresentation {
        let rawRemaining = endsAt.timeIntervalSince(date)
        let boundedRemaining: TimeInterval
        if rawRemaining.isFinite {
            boundedRemaining = min(max(rawRemaining, 0), Self.maximumDuration)
        } else {
            boundedRemaining = rawRemaining.sign == .minus ? 0 : Self.maximumDuration
        }
        let secondsRemaining = Int(boundedRemaining.rounded(.up))
        return CountdownPresentation(
            title: title,
            detail: CountdownPresentation.durationDetail(seconds: secondsRemaining),
            fractionCompleted: fractionCompleted(at: date),
            startedAt: startedAt,
            endsAt: endsAt,
            isExpired: date >= endsAt
        )
    }
}

public struct CountdownPresentation: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let fractionCompleted: Double
    public let startedAt: Date
    public let endsAt: Date
    public let isExpired: Bool

    fileprivate static func durationDetail(seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s remaining"
        }
        let minutes = Int(ceil(Double(seconds) / 60))
        if minutes < 60 {
            return "\(minutes)m remaining"
        }
        let hours = Int(ceil(Double(minutes) / 60))
        return "\(hours)h remaining"
    }
}

public protocol GlanceClock: Sendable {
    func now() async -> Date
    /// Suspends once until a boundary. Implementations must not poll or repeat.
    func sleep(until deadline: Date) async throws
}

public enum GlanceClockError: Error, Equatable, Sendable {
    case deadlineOutOfRange
}

public struct SystemGlanceClock: GlanceClock {
    public static let maximumOneShotInterval: TimeInterval = 31 * 24 * 60 * 60

    public init() {}

    public func now() async -> Date {
        Date()
    }

    public func sleep(until deadline: Date) async throws {
        let interval = deadline.timeIntervalSinceNow
        guard interval > 0 else { return }
        guard interval.isFinite, interval <= Self.maximumOneShotInterval else {
            throw GlanceClockError.deadlineOutOfRange
        }
        try await ContinuousClock().sleep(for: .seconds(interval))
    }
}

public enum GlanceRequestFactory {
    public static func power(_ snapshot: PowerSnapshot) -> ActivityRequest {
        let percentage = Int((snapshot.chargeLevel * 100).rounded())
        let charging = snapshot.isCharging || snapshot.isConnectedToPower
        return ActivityRequest(
            identifier: GlanceActivityIdentity.batteryIdentifier,
            source: ActivitySource.battery.rawValue,
            kind: charging ? ActivityKind.charging.rawValue : ActivityKind.battery.rawValue,
            priority: ActivityPriority.low.rawValue,
            title: charging ? "Charging" : "Battery",
            detail: "\(percentage)%",
            progress: snapshot.chargeLevel
        )
    }

    public static func volume(_ snapshot: VolumeSnapshot) -> ActivityRequest {
        let percentage = Int((snapshot.scalar * 100).rounded())
        return ActivityRequest(
            identifier: GlanceActivityIdentity.volumeIdentifier,
            source: ActivitySource.volume.rawValue,
            kind: ActivityKind.volume.rawValue,
            priority: ActivityPriority.high.rawValue,
            title: "Volume",
            detail: snapshot.isMuted ? "Muted" : "\(percentage)%",
            progress: snapshot.isMuted ? 0 : snapshot.scalar,
            ttlMilliseconds: 1_800
        )
    }

    public static func meeting(_ meeting: CalendarMeeting, now: Date) -> ActivityRequest {
        let detail: String
        if meeting.startDate <= now {
            detail = "In progress"
        } else {
            detail = meeting.startDate.formatted(date: .omitted, time: .shortened)
        }
        return ActivityRequest(
            identifier: GlanceActivityIdentity.meetingIdentifier,
            source: ActivitySource.calendar.rawValue,
            kind: ActivityKind.meeting.rawValue,
            priority: 55,
            title: GlanceText.bounded(
                meeting.title,
                maximumBytes: ActivityLimits.titleBytes,
                fallback: "Upcoming meeting"
            ),
            detail: GlanceText.bounded(
                detail,
                maximumBytes: ActivityLimits.detailBytes,
                fallback: "Upcoming"
            ),
            actionIdentifier: "calendar.open",
            actionLabel: "Open Calendar",
            actionIntent: ActivityActionIntent.openSource.rawValue
        )
    }

    public static func countdown(_ timer: CountdownTimer, now: Date) -> ActivityRequest {
        let presentation = timer.presentation(at: now)
        return ActivityRequest(
            identifier: GlanceActivityIdentity.timerIdentifier,
            source: ActivitySource.timer.rawValue,
            kind: ActivityKind.timer.rawValue,
            priority: 60,
            title: GlanceText.bounded(
                timer.title,
                maximumBytes: ActivityLimits.titleBytes,
                fallback: "Timer"
            ),
            detail: presentation.detail,
            progress: presentation.fractionCompleted,
            actionIdentifier: "timer.cancel",
            actionLabel: "Cancel",
            actionIntent: ActivityActionIntent.cancel.rawValue
        )
    }

}

enum GlanceActivityIdentity {
    static let batteryIdentifier = "battery-status"
    static let volumeIdentifier = "output-volume"
    static let meetingIdentifier = "next-meeting"
    static let timerIdentifier = "active-countdown"

    static let battery = make(source: .battery, identifier: batteryIdentifier)
    static let volume = make(source: .volume, identifier: volumeIdentifier)
    static let meeting = make(source: .calendar, identifier: meetingIdentifier)
    static let timer = make(source: .timer, identifier: timerIdentifier)

    private static func make(source: ActivitySource, identifier: String) -> ActivityIdentity {
        do {
            return ActivityIdentity(
                source: source,
                identifier: try ActivityIdentifier(validating: identifier)
            )
        } catch {
            preconditionFailure("Invalid built-in glance activity identity: \(error)")
        }
    }
}

enum GlanceText {
    static func bounded(_ value: String, maximumBytes: Int, fallback: String) -> String {
        let normalized = value
            .unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        let source = normalized.isEmpty ? fallback : normalized
        guard source.utf8.count > maximumBytes else { return source }

        let ellipsis = "…"
        let contentLimit = max(maximumBytes - ellipsis.utf8.count, 0)
        var result = ""
        for character in source {
            let candidate = result + String(character)
            if candidate.utf8.count > contentLimit { break }
            result = candidate
        }
        return result + (maximumBytes >= ellipsis.utf8.count ? ellipsis : "")
    }
}
