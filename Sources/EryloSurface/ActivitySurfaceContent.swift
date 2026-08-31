import EryloActivity
import EryloCore
import Foundation

public enum ActivityAccent: Equatable, Sendable {
    case mint
    case sky
    case amber
    case coral
    case mist
}

package struct ActivitySurfaceTemporalProjection: Equatable, Sendable {
    package let startedAt: Date
    package let endsAt: Date

    package func snapshot(at date: Date) -> ActivitySurfaceTemporalSnapshot {
        let duration = endsAt.timeIntervalSince(startedAt)
        let elapsed = date.timeIntervalSince(startedAt)
        let rawRemaining = endsAt.timeIntervalSince(date)
        let remaining = rawRemaining.isFinite ? max(rawRemaining, 0) : 0
        return ActivitySurfaceTemporalSnapshot(
            remainingText: Self.remainingText(seconds: Int(remaining.rounded(.up))),
            fractionCompleted: min(max(elapsed / duration, 0), 1)
        )
    }

    package static func remainingText(seconds: Int) -> String {
        let boundedSeconds = min(
            max(seconds, 0),
            Int(CountdownLikeLimits.maximumDuration)
        )
        let hours = boundedSeconds / 3_600
        let minutes = (boundedSeconds % 3_600) / 60
        let seconds = boundedSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private enum CountdownLikeLimits {
        static let maximumDuration: TimeInterval = 30 * 24 * 60 * 60
    }
}

package struct ActivitySurfaceTemporalSnapshot: Equatable, Sendable {
    package let remainingText: String
    package let fractionCompleted: Double
}

public struct ActivitySurfaceItem: Equatable, Sendable {
    public let identity: ActivityIdentity
    public let revision: UInt64
    public let kind: ActivityKind
    public let kindLabel: String
    public let symbolName: String
    public let accent: ActivityAccent
    public let title: String
    public let detail: String?
    public let progressFraction: Double?
    public let progressValue: String?
    public let shortProgressValue: String?
    package let temporalProjection: ActivitySurfaceTemporalProjection?
    package let presentationRole: ActivityPresentationRole

    public init(_ presented: PresentedActivity) {
        identity = presented.activity.identity
        revision = presented.revision
        kind = presented.activity.kind
        let descriptor = Self.descriptor(for: presented.activity.kind)
        kindLabel = descriptor.kindLabel
        symbolName = descriptor.symbolName
        accent = descriptor.accent
        title = presented.activity.presentation.title
        detail = presented.activity.presentation.detail
        progressFraction = presented.activity.presentation.progress?.fractionCompleted
        progressValue = presented.activity.presentation.progress.map {
            SurfaceStrings.progressValue(Int(($0.fractionCompleted * 100).rounded()))
        }
        shortProgressValue = presented.activity.presentation.progress.map {
            SurfaceStrings.shortProgressValue(Int(($0.fractionCompleted * 100).rounded()))
        }
        temporalProjection = presented.activity.presentation.temporalProgress.map {
            ActivitySurfaceTemporalProjection(
                startedAt: $0.startedAt,
                endsAt: $0.endsAt
            )
        }
        presentationRole = presented.activity.presentation.presentationRole
    }

    public var accessibilitySummary: String {
        [kindLabel, title, detail, progressValue]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private static func descriptor(
        for kind: ActivityKind
    ) -> (kindLabel: String, symbolName: String, accent: ActivityAccent) {
        switch kind {
        case .generic:
            (SurfaceStrings.genericKind, "sparkle", .mint)
        case .battery:
            (SurfaceStrings.batteryKind, "batteryblock", .sky)
        case .charging:
            (SurfaceStrings.chargingKind, "bolt.fill", .mint)
        case .timer:
            (SurfaceStrings.timerKind, "timer", .amber)
        case .meeting:
            (SurfaceStrings.meetingKind, "calendar", .sky)
        case .volume:
            (SurfaceStrings.volumeKind, "speaker.fill", .mist)
        case .media:
            (SurfaceStrings.mediaKind, "waveform", .coral)
        case .file:
            (SurfaceStrings.fileKind, "doc", .amber)
        }
    }
}

public struct ActivityQueueContext: Equatable, Sendable {
    public static let maximumVisibleItems = 2
    public static let maximumRemainingCount = ActivityLimits.maximumActivityCount
    public static let empty = ActivityQueueContext(items: [], remainingCount: 0)

    public let items: [ActivitySurfaceItem]
    public let remainingCount: Int

    public init(items: [ActivitySurfaceItem], remainingCount: Int) {
        let boundedItems = Array(items.prefix(Self.maximumVisibleItems))
        self.items = boundedItems
        let boundedReportedCount = min(max(remainingCount, 0), Self.maximumRemainingCount)
        let omittedCount = min(
            max(items.count - boundedItems.count, 0),
            Self.maximumRemainingCount - boundedReportedCount
        )
        self.remainingCount = boundedReportedCount + omittedCount
    }

    init(snapshot: ActivityBrokerSnapshot, maximumVisibleItems: Int) {
        let visibleLimit = min(max(maximumVisibleItems, 0), Self.maximumVisibleItems)
        let visible = snapshot.queued.prefix(visibleLimit).map(ActivitySurfaceItem.init)
        self.init(
            items: visible,
            remainingCount: max(snapshot.queued.count - visible.count, 0)
        )
    }
}

public struct ActivityHandoff: Equatable, Sendable {
    public let from: ActivityIdentity?
    public let to: ActivityIdentity?
    public let snapshotVersion: UInt64

    public init(from: ActivityIdentity?, to: ActivityIdentity?, snapshotVersion: UInt64) {
        self.from = from
        self.to = to
        self.snapshotVersion = snapshotVersion
    }
}

public struct SurfaceActionIdentity: Equatable, Sendable {
    public let activityIdentity: ActivityIdentity
    public let activityRevision: UInt64
    public let actionIdentifier: String

    public init(
        activityIdentity: ActivityIdentity,
        activityRevision: UInt64,
        actionIdentifier: String
    ) {
        self.activityIdentity = activityIdentity
        self.activityRevision = activityRevision
        self.actionIdentifier = actionIdentifier
    }
}

public struct SurfaceActivityAction: Equatable, Sendable {
    public let identity: SurfaceActionIdentity
    public let label: String
    public let intent: ActivityActionIntent

    init?(presented: PresentedActivity?) {
        guard let presented, let action = presented.activity.action else { return nil }
        identity = SurfaceActionIdentity(
            activityIdentity: presented.activity.identity,
            activityRevision: presented.revision,
            actionIdentifier: action.identifier
        )
        label = action.label
        intent = action.intent
    }
}

public enum SurfaceActivityPhase: Equatable, Sendable {
    case stopped
    case waiting
    case active
    case degraded
}

public enum ActivityActionDispatchState: Equatable, Sendable {
    case idle
    case inProgress
    case handled
    case unhandled
    case stale
}

public enum ActivityActionOutcome: Equatable, Sendable {
    case handled
    case unhandled
    case stale
}

public enum ActivitySurfacePrimaryContent: Equatable, Sendable {
    case hidden
    case activity(ActivitySurfaceItem)
    case empty(title: String, detail: String?)
    case degraded(title: String, detail: String)
    case dropTarget(title: String, detail: String)
}

public struct ActivitySurfaceContent: Equatable, Sendable {
    public let state: PanelPresentationState
    public let primary: ActivitySurfacePrimaryContent
    public let queue: ActivityQueueContext
    public let action: SurfaceActivityAction?
    public let actionStatus: String?
    public let showsFocusTimerLauncher: Bool

    public init(
        state: PanelPresentationState,
        phase: SurfaceActivityPhase,
        current: PresentedActivity?,
        queueContext: ActivityQueueContext,
        action: SurfaceActivityAction?,
        actionDispatchState: ActivityActionDispatchState,
        showsFocusTimerLauncher: Bool = false
    ) {
        self.state = state
        self.showsFocusTimerLauncher = showsFocusTimerLauncher
        switch state {
        case .hidden:
            primary = .hidden
        case .dropTarget:
            primary = .dropTarget(
                title: SurfaceStrings.dropTargetTitle,
                detail: SurfaceStrings.dropTargetDetail
            )
        case .compact, .peek, .expanded:
            if phase == .degraded {
                primary = .degraded(
                    title: SurfaceStrings.degradedTitle,
                    detail: SurfaceStrings.degradedDetail
                )
            } else if let current {
                primary = .activity(ActivitySurfaceItem(current))
            } else {
                primary = .empty(
                    title: showsFocusTimerLauncher
                        ? SurfaceStrings.focusTimerLauncherTitle
                        : (state == .compact ? SurfaceStrings.compactQuietTitle : SurfaceStrings.quietTitle),
                    detail: state == .compact ? nil : SurfaceStrings.quietDetail
                )
            }
        }

        queue = state == .expanded ? queueContext : .empty
        self.action = state == .expanded ? action : nil
        actionStatus = switch actionDispatchState {
        case .idle, .handled:
            nil
        case .inProgress:
            SurfaceStrings.actionInProgress
        case .unhandled:
            SurfaceStrings.actionUnavailable
        case .stale:
            SurfaceStrings.actionStale
        }
    }
}

public struct PanelSurfaceAccessibility: Equatable, Sendable {
    public let label: String
    public let value: String
    public let hint: String

    public init(content: ActivitySurfaceContent) {
        label = SurfaceStrings.surfaceLabel
        let stateName: String
        switch content.state {
        case .hidden:
            stateName = SurfaceStrings.hiddenState
        case .compact:
            stateName = SurfaceStrings.compactState
        case .peek:
            stateName = SurfaceStrings.peekState
        case .expanded:
            stateName = SurfaceStrings.expandedState
        case .dropTarget:
            stateName = SurfaceStrings.dropTargetState
        }

        let primaryValue: String
        switch content.primary {
        case .hidden:
            primaryValue = stateName
        case let .activity(item):
            primaryValue = [stateName, item.accessibilitySummary].joined(separator: ", ")
        case let .empty(title, detail):
            primaryValue = [stateName, title, detail]
                .compactMap { $0 }
                .joined(separator: ", ")
        case let .degraded(title, detail), let .dropTarget(title, detail):
            primaryValue = [stateName, title, detail].joined(separator: ", ")
        }
        value = primaryValue

        hint = switch content.state {
        case .hidden:
            ""
        case .compact, .peek:
            if content.showsFocusTimerLauncher {
                SurfaceStrings.focusTimerLauncherHint
            } else {
                switch content.primary {
            case .activity:
                SurfaceStrings.expandHint
            case .empty, .degraded:
                SurfaceStrings.hideHint
            case .hidden, .dropTarget:
                ""
                }
            }
        case .expanded:
            SurfaceStrings.collapseHint
        case .dropTarget:
            SurfaceStrings.dropTargetHint
        }
    }
}
