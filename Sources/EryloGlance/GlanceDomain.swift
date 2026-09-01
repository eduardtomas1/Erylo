import EryloActivity
import Foundation

final class GlanceReleaseCleanupToken: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?

    func activate() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if let activeGeneration { return activeGeneration }
        generation &+= 1
        activeGeneration = generation
        return generation
    }

    func complete(generation: UInt64) {
        lock.lock()
        if activeGeneration == generation {
            activeGeneration = nil
        }
        lock.unlock()
    }

    func claimFallback() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeGeneration != nil else { return false }
        activeGeneration = nil
        return true
    }
}

final class GlanceBrokerActivityLease: @unchecked Sendable {
    let identity: ActivityIdentity

    private let lock = NSLock()
    private var revision: UInt64?

    init(identity: ActivityIdentity) {
        self.identity = identity
    }

    func record(_ snapshot: ActivityBrokerSnapshot) {
        let submittedRevision = snapshot.ordered.first {
            $0.activity.identity == identity
        }?.revision
        lock.lock()
        revision = submittedRevision
        lock.unlock()
    }

    func ownedRevision() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return revision
    }

    func retire(revision: UInt64) {
        lock.lock()
        if self.revision == revision {
            self.revision = nil
        }
        lock.unlock()
    }
}

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
    public let activeBrokerMutationCount: Int

    public init(
        activeObserverCount: Int,
        activeConsumerTaskCount: Int,
        scheduledBoundaryCount: Int
    ) {
        self.init(
            activeObserverCount: activeObserverCount,
            activeConsumerTaskCount: activeConsumerTaskCount,
            scheduledBoundaryCount: scheduledBoundaryCount,
            activeBrokerMutationCount: 0
        )
    }

    public init(
        activeObserverCount: Int,
        activeConsumerTaskCount: Int,
        scheduledBoundaryCount: Int,
        activeBrokerMutationCount: Int
    ) {
        self.activeObserverCount = activeObserverCount
        self.activeConsumerTaskCount = activeConsumerTaskCount
        self.scheduledBoundaryCount = scheduledBoundaryCount
        self.activeBrokerMutationCount = activeBrokerMutationCount
    }

    public var isIdle: Bool {
        activeObserverCount == 0
            && activeConsumerTaskCount == 0
            && scheduledBoundaryCount == 0
            && activeBrokerMutationCount == 0
    }
}

/// Injectable broker boundary used to deterministically exercise provider lifecycle races.
/// `ActivityBroker` remains the production implementation.
public protocol GlanceActivityBroker: Sendable {
    @discardableResult
    func submit(_ request: ActivityRequest) async throws -> ActivityBrokerSnapshot

    @discardableResult
    func cancel(_ identity: ActivityIdentity) async -> Bool
}

/// Opt-in atomic revision capability for brokers that can compare and remove in
/// one isolated operation. Original `GlanceActivityBroker` conformers remain valid.
public protocol GlanceRevisionActivityBroker: GlanceActivityBroker {
    /// Removes the identity only when it still names the exact revision owned by
    /// the caller.
    @discardableResult
    func cancel(_ identity: ActivityIdentity, ifRevision revision: UInt64) async -> Bool
}

/// Opt-in cross-instance admission capability. Providers use this path whenever
/// available; original conformers retain their legacy submit/cancel behavior.
public protocol GlanceOwnershipActivityBroker: GlanceActivityBroker {
    /// Shared synchronous admission coordinator. Wrappers must forward the exact
    /// coordinator used by their underlying ownership mutations.
    var ownershipCoordinator: ActivityOwnershipCoordinator { get }

    /// Claims the newest cross-instance ownership generation for one identity.
    func claimOwnership(
        of identity: ActivityIdentity,
        admitting intent: ActivityOwnershipClaimIntent
    ) async -> ActivityOwnershipLease?

    /// Releases the exact generation after its terminal broker cleanup settles.
    @discardableResult
    func releaseOwnership(_ lease: ActivityOwnershipLease) async -> Bool

    /// Submits only while the lease remains active and current. A `nil` result
    /// means the mutation was rejected without changing broker state.
    @discardableResult
    func submit(
        _ request: ActivityRequest,
        ifOwnedBy lease: ActivityOwnershipLease
    ) async throws -> ActivityBrokerSnapshot?

    /// Cancels only while the lease remains the broker's newest generation.
    @discardableResult
    func cancel(_ identity: ActivityIdentity, ifOwnedBy lease: ActivityOwnershipLease) async -> Bool
}

extension ActivityBroker: GlanceOwnershipActivityBroker, GlanceRevisionActivityBroker {
    /// Exact async protocol witness. Actor entry happens once and the synchronous
    /// ownership claim completes in this same actor turn.
    public func claimOwnership(
        of identity: ActivityIdentity,
        admitting intent: ActivityOwnershipClaimIntent
    ) async -> ActivityOwnershipLease? {
        let claim: (
            ActivityIdentity,
            ActivityOwnershipClaimIntent
        ) -> ActivityOwnershipLease? = claimOwnership(of:admitting:)
        return claim(identity, intent)
    }

    /// Exact async protocol witness; pruning is conditional on the same generation.
    @discardableResult
    public func releaseOwnership(_ lease: ActivityOwnershipLease) async -> Bool {
        let release: (ActivityOwnershipLease) -> Bool = releaseOwnership(_:)
        return release(lease)
    }

    /// Exact async protocol witness with no suspension between lease validation
    /// and the synchronous actor-isolated submission.
    @discardableResult
    public func submit(
        _ request: ActivityRequest,
        ifOwnedBy lease: ActivityOwnershipLease
    ) async throws -> ActivityBrokerSnapshot? {
        let ownedSubmit: (
            ActivityRequest,
            ActivityOwnershipLease
        ) throws -> ActivityBrokerSnapshot? = submit(_:ifOwnedBy:)
        return try ownedSubmit(request, lease)
    }

    /// Exact async protocol witness. Actor entry happens once; the synchronous
    /// overload performs the comparison and removal in this same actor turn.
    @discardableResult
    public func cancel(_ identity: ActivityIdentity, ifRevision revision: UInt64) async -> Bool {
        await cancelAndWait(identity, ifRevision: revision)
    }

    /// Exact async protocol witness with one actor entry and no suspension before
    /// the synchronous generation check and removal.
    @discardableResult
    public func cancel(
        _ identity: ActivityIdentity,
        ifOwnedBy lease: ActivityOwnershipLease
    ) async -> Bool {
        await cancelAndWait(identity, ifOwnedBy: lease)
    }

    /// Exact async protocol witness. Record removal remains atomic and return is
    /// delayed until every predecessor expiry task for the identity has joined.
    @discardableResult
    public func cancel(_ identity: ActivityIdentity) async -> Bool {
        await cancelAndWait(identity)
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

public enum BatteryPresentationPolicyError: Error, Equatable, Sendable {
    case invalidLowBatteryThreshold
    case invalidTransientDuration
}

public enum CalendarPresentationWindowError: Error, Equatable, Sendable {
    case invalidLeadTime
}

/// Whether a provider should leave no activity, briefly acknowledge a change, or
/// remain present while an actionable condition exists.
public enum GlancePresentationLifetime: Equatable, Sendable {
    case hidden
    case transient(milliseconds: Int)
    case ambient
}

/// Battery is silent for an ordinary initial snapshot, transient for later changes,
/// and ambient only while an unplugged battery is at or below the low-battery threshold.
public struct BatteryPresentationPolicy: Equatable, Sendable {
    public static let standard = Self(
        uncheckedLowBatteryThreshold: 0.2,
        transientMilliseconds: 1_800
    )

    public let lowBatteryThreshold: Double
    public let transientMilliseconds: Int

    public init(
        lowBatteryThreshold: Double,
        transientMilliseconds: Int
    ) throws(BatteryPresentationPolicyError) {
        guard lowBatteryThreshold.isFinite,
              (0...1).contains(lowBatteryThreshold) else {
            throw .invalidLowBatteryThreshold
        }
        guard (ActivityLimits.minimumTTLMilliseconds...ActivityLimits.maximumTTLMilliseconds)
            .contains(transientMilliseconds) else {
            throw .invalidTransientDuration
        }
        self.lowBatteryThreshold = lowBatteryThreshold
        self.transientMilliseconds = transientMilliseconds
    }

    private init(
        uncheckedLowBatteryThreshold: Double,
        transientMilliseconds: Int
    ) {
        lowBatteryThreshold = uncheckedLowBatteryThreshold
        self.transientMilliseconds = transientMilliseconds
    }

    public func lifetime(
        for snapshot: PowerSnapshot,
        previous: PowerSnapshot?
    ) -> GlancePresentationLifetime {
        if !snapshot.isCharging,
           !snapshot.isConnectedToPower,
           snapshot.chargeLevel <= lowBatteryThreshold {
            return .ambient
        }
        guard let previous, previous != snapshot else { return .hidden }
        return .transient(milliseconds: transientMilliseconds)
    }
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

/// Calendar presentation begins shortly before a meeting and ends exactly with it.
/// Distant meetings are retained only to schedule their single lead-time boundary.
public struct CalendarPresentationWindow: Equatable, Sendable {
    public static let maximumLeadTime: TimeInterval = 24 * 60 * 60
    public static let standard = Self(uncheckedLeadTime: 10 * 60)

    public let leadTime: TimeInterval

    public init(leadTime: TimeInterval) throws(CalendarPresentationWindowError) {
        guard leadTime.isFinite,
              (0...Self.maximumLeadTime).contains(leadTime) else {
            throw .invalidLeadTime
        }
        self.leadTime = leadTime
    }

    private init(uncheckedLeadTime: TimeInterval) {
        leadTime = uncheckedLeadTime
    }

    public func presentationStart(for meeting: CalendarMeeting) -> Date {
        meeting.startDate.addingTimeInterval(-leadTime)
    }

    public func contains(_ meeting: CalendarMeeting, at date: Date) -> Bool {
        date >= presentationStart(for: meeting) && date < meeting.endDate
    }

    public func nextBoundary(for meeting: CalendarMeeting, at date: Date) -> Date? {
        let presentationStart = presentationStart(for: meeting)
        if date < presentationStart { return presentationStart }
        if date < meeting.startDate { return meeting.startDate }
        if date < meeting.endDate { return meeting.endDate }
        return nil
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
    public static let maximumOutputDisplayNameBytes = 96
    public static let outputDisplayNameFallback = "Audio output"

    public let deviceID: UInt32
    public let scalar: Double
    public let isMuted: Bool
    public let outputDisplayName: String?

    public init(
        deviceID: UInt32,
        scalar: Double,
        isMuted: Bool,
        outputDisplayName: String? = nil
    ) throws(GlanceDataError) {
        guard scalar.isFinite, (0...1).contains(scalar) else {
            throw .invalidVolume
        }
        self.deviceID = deviceID
        self.scalar = scalar
        self.isMuted = isMuted
        self.outputDisplayName = outputDisplayName.map {
            GlanceText.bounded(
                $0,
                maximumBytes: Self.maximumOutputDisplayNameBytes,
                fallback: Self.outputDisplayNameFallback
            )
        }
    }
}

package enum VolumePresentationChange: Equatable, Sendable {
    case levelChanged
    case muted
    case unmuted
    case outputChanged

    package static func classify(
        previous: VolumeSnapshot,
        current: VolumeSnapshot
    ) -> Self? {
        if previous.deviceID != current.deviceID {
            return .outputChanged
        }
        if previous.isMuted != current.isMuted {
            return current.isMuted ? .muted : .unmuted
        }
        if previous.scalar != current.scalar {
            return .levelChanged
        }
        return nil
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

public enum CalendarPermissionRequestError: Error, Equatable, Sendable {
    case requestFailed
}

public enum CalendarSourceEvent: Equatable, Sendable {
    case eventStoreChanged
    case wallClockChanged
    case timeZoneChanged
    case didWake
}

public enum CountdownPresentationDemand: Equatable, Sendable {
    case hidden
    case visible
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
    /// Suspends once until a boundary. Implementations must not poll or repeat and must
    /// promptly finish by throwing when the calling task is cancelled.
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
        power(snapshot, ttlMilliseconds: nil)
    }

    public static func power(
        _ snapshot: PowerSnapshot,
        lifetime: GlancePresentationLifetime
    ) -> ActivityRequest? {
        switch lifetime {
        case .hidden:
            nil
        case let .transient(milliseconds):
            power(snapshot, ttlMilliseconds: milliseconds)
        case .ambient:
            power(snapshot, ttlMilliseconds: nil)
        }
    }

    private static func power(
        _ snapshot: PowerSnapshot,
        ttlMilliseconds: Int?
    ) -> ActivityRequest {
        let percentage = Int((snapshot.chargeLevel * 100).rounded())
        let charging = snapshot.isCharging || snapshot.isConnectedToPower
        return ActivityRequest(
            identifier: GlanceActivityIdentity.batteryIdentifier,
            source: ActivitySource.battery.rawValue,
            kind: charging ? ActivityKind.charging.rawValue : ActivityKind.battery.rawValue,
            priority: ActivityPriority.low.rawValue,
            title: charging ? "Charging" : "Battery",
            detail: "\(percentage)%",
            progress: snapshot.chargeLevel,
            ttlMilliseconds: ttlMilliseconds
        )
    }

    public static func volume(_ snapshot: VolumeSnapshot) -> ActivityRequest {
        volume(
            snapshot,
            change: snapshot.isMuted ? .muted : .levelChanged
        )
    }

    package static func volume(
        _ snapshot: VolumeSnapshot,
        change: VolumePresentationChange
    ) -> ActivityRequest {
        let title: String
        let detail: String?
        let progress: Double?
        let presentationRole: ActivityPresentationRole

        switch change {
        case .levelChanged:
            title = "Volume"
            detail = nil
            progress = snapshot.scalar
            presentationRole = .volumeLevelChanged
        case .muted:
            title = "Muted"
            detail = nil
            progress = nil
            presentationRole = .volumeMuted
        case .unmuted:
            title = "Sound on"
            detail = nil
            progress = snapshot.scalar
            presentationRole = .volumeUnmuted
        case .outputChanged:
            title = snapshot.outputDisplayName ?? VolumeSnapshot.outputDisplayNameFallback
            detail = "Output changed"
            progress = nil
            presentationRole = .volumeOutputChanged
        }

        return ActivityRequest(
            identifier: GlanceActivityIdentity.volumeIdentifier,
            source: ActivitySource.volume.rawValue,
            kind: ActivityKind.volume.rawValue,
            priority: ActivityPriority.high.rawValue,
            title: title,
            detail: detail,
            progress: progress,
            ttlMilliseconds: 1_800,
            temporalProgress: nil,
            presentationRole: presentationRole
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
            actionIdentifier: CountdownActivityContract.cancelActionIdentifier,
            actionLabel: "Cancel",
            actionIntent: ActivityActionIntent.cancel.rawValue,
            temporalProgress: ActivityTemporalProgress(
                startedAt: timer.startedAt,
                endsAt: timer.endsAt
            )
        )
    }

    static func countdownCompletion() -> ActivityRequest {
        ActivityRequest(
            identifier: GlanceActivityIdentity.timerIdentifier,
            source: ActivitySource.timer.rawValue,
            kind: ActivityKind.timer.rawValue,
            priority: 60,
            title: "Focus complete",
            actionIdentifier: CountdownActivityContract.dismissActionIdentifier,
            actionLabel: "Done",
            actionIntent: ActivityActionIntent.dismiss.rawValue,
            ttlMilliseconds: 8_000,
            temporalProgress: nil,
            presentationRole: .completionAcknowledgement
        )
    }

}

/// The closed activity contract used by the built-in countdown provider and its
/// application action router. It contains identifiers only, never executable work.
public enum CountdownActivityContract {
    public static let identifier = "active-countdown"
    public static let source = ActivitySource.timer
    public static let kind = ActivityKind.timer
    public static let cancelActionIdentifier = "timer.cancel"
    public static let dismissActionIdentifier = "timer.dismiss-completion"

    public static let identity = ActivityIdentity(
        source: source,
        identifier: try! ActivityIdentifier(validating: identifier)
    )
}

enum GlanceActivityIdentity {
    static let batteryIdentifier = "battery-status"
    static let volumeIdentifier = "output-volume"
    static let meetingIdentifier = "next-meeting"
    static let timerIdentifier = CountdownActivityContract.identifier

    static let battery = make(source: .battery, identifier: batteryIdentifier)
    static let volume = make(source: .volume, identifier: volumeIdentifier)
    static let meeting = make(source: .calendar, identifier: meetingIdentifier)
    static let timer = CountdownActivityContract.identity

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
        if result.isEmpty, fallback.utf8.count <= maximumBytes {
            return fallback
        }
        return result + (maximumBytes >= ellipsis.utf8.count ? ellipsis : "")
    }
}
