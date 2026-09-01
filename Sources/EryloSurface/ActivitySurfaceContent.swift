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

/// A deterministic rendering decision derived only from the bounded activity
/// contract. Keeping this separate from the SwiftUI hierarchy prevents built-in
/// signals from falling back to a generic title/detail card as the view evolves.
package enum ActivitySurfaceComposition: Equatable, Sendable {
    case timerCountdown
    case timerCompletion
    case volumeLevel
    case volumeMuted
    case volumeUnmuted
    case volumeOutput
    case battery
    case charging
    case standard
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
    package let notchCompactValue: String?

    public init(_ presented: PresentedActivity) {
        identity = presented.activity.identity
        revision = presented.revision
        kind = presented.activity.kind
        presentationRole = presented.activity.presentation.presentationRole
        let descriptor = Self.descriptor(
            for: presented.activity.kind,
            presentationRole: presentationRole
        )
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
        notchCompactValue = switch presentationRole {
        case .volumeLevelChanged:
            shortProgressValue
        case .volumeMuted:
            SurfaceStrings.volumeMuted
        case .volumeUnmuted:
            SurfaceStrings.volumeUnmuted
        case .volumeOutputChanged:
            title
        case .standard, .completionAcknowledgement:
            nil
        }
    }

    package var composition: ActivitySurfaceComposition {
        if kind == .timer, presentationRole == .completionAcknowledgement {
            return .timerCompletion
        }
        if kind == .volume {
            return switch presentationRole {
            case .volumeLevelChanged, .standard:
                .volumeLevel
            case .volumeMuted:
                .volumeMuted
            case .volumeUnmuted:
                .volumeUnmuted
            case .volumeOutputChanged:
                .volumeOutput
            case .completionAcknowledgement:
                .standard
            }
        }
        return switch kind {
        case .timer:
            .timerCountdown
        case .battery:
            .battery
        case .charging:
            .charging
        case .generic, .meeting, .media, .file, .volume:
            .standard
        }
    }

    /// Timer identity remains Amber wherever the countdown is composed. Completion replaces the
    /// timer glyph with a distinct success symbol and therefore retains its Mint descriptor.
    package var semanticSymbolAccent: ActivityAccent {
        composition == .timerCountdown ? .amber : accent
    }

    /// Static principal copy for deterministic previews and non-temporal
    /// activities. Timestamp-backed timers replace this with their local
    /// projection only while the physical surface is visible.
    package var signalPrincipalValue: String? {
        switch composition {
        case .timerCountdown:
            detail ?? shortProgressValue ?? title
        case .timerCompletion:
            title
        case .volumeLevel, .volumeUnmuted, .battery, .charging:
            shortProgressValue ?? detail ?? title
        case .volumeMuted, .volumeOutput:
            title
        case .standard:
            shortProgressValue
        }
    }

    /// A signal line is information, never decoration. Only a validated scalar
    /// or timestamp projection earns the extra visual channel.
    package var hasSemanticProgress: Bool {
        progressFraction != nil || temporalProjection != nil
    }

    package var hasUsefulPeekDetail: Bool {
        guard composition == .standard,
              let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !detail.isEmpty else {
            return false
        }
        return detail.caseInsensitiveCompare(title) != .orderedSame
    }

    package func supportsExpandedPresentation(
        action: SurfaceActivityAction?,
        queue: ActivityQueueContext
    ) -> Bool {
        switch composition {
        case .timerCountdown:
            action != nil
        case .standard:
            hasUsefulPeekDetail || action != nil || !queue.items.isEmpty
        case .timerCompletion, .volumeLevel, .volumeMuted, .volumeUnmuted,
             .volumeOutput, .battery, .charging:
            false
        }
    }

    public var accessibilitySummary: String {
        let components: [String?] = switch presentationRole {
        case .volumeLevelChanged:
            [kindLabel, progressValue]
        case .volumeMuted:
            [kindLabel, SurfaceStrings.volumeMuted]
        case .volumeUnmuted:
            [kindLabel, SurfaceStrings.volumeUnmuted, progressValue]
        case .volumeOutputChanged:
            [kindLabel, SurfaceStrings.volumeOutputChanged, title]
        case .standard, .completionAcknowledgement:
            [kindLabel, title, detail, progressValue]
        }
        return components.compactMap { $0 }.joined(separator: ", ")
    }

    package func accessibilitySummary(
        temporalSnapshot: ActivitySurfaceTemporalSnapshot?
    ) -> String {
        guard temporalProjection != nil, let temporalSnapshot else {
            return accessibilitySummary
        }
        return [
            kindLabel,
            title,
            SurfaceStrings.remainingTime(temporalSnapshot.remainingText),
        ].joined(separator: ", ")
    }

    private static func descriptor(
        for kind: ActivityKind,
        presentationRole: ActivityPresentationRole
    ) -> (kindLabel: String, symbolName: String, accent: ActivityAccent) {
        if kind == .timer, presentationRole == .completionAcknowledgement {
            return (SurfaceStrings.timerKind, "checkmark.circle.fill", .mint)
        }
        if kind == .volume {
            return switch presentationRole {
            case .volumeMuted:
                (SurfaceStrings.volumeKind, "speaker.slash.fill", .mist)
            case .volumeOutputChanged:
                (SurfaceStrings.volumeKind, "hifispeaker.2.fill", .mist)
            case .volumeLevelChanged, .volumeUnmuted, .standard,
                 .completionAcknowledgement:
                (SurfaceStrings.volumeKind, "speaker.wave.2.fill", .mist)
            }
        }
        return switch kind {
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
            preconditionFailure("Volume presentation descriptor must resolve above")
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

package enum ActivitySurfaceInteractionRole: Equatable, Sendable {
    case none
    case expand
    case collapse
    case dismiss
}

public struct ActivitySurfaceContent: Equatable, Sendable {
    public let state: PanelPresentationState
    public let primary: ActivitySurfacePrimaryContent
    public let queue: ActivityQueueContext
    public let action: SurfaceActivityAction?
    public let actionStatus: String?
    public let showsFocusTimerLauncher: Bool
    package let interactionRole: ActivitySurfaceInteractionRole

    /// Child controls may make a nonactivating panel key only after a deliberate
    /// user action. Passive HUD content never earns keyboard eligibility.
    package var hasExplicitControls: Bool {
        switch state {
        case .compact:
            // Activity actions are deliberately withheld until Expanded. The
            // idle timer launcher and a retained completion acknowledgement's
            // Done button are the only real Compact controls.
            if showsFocusTimerLauncher { return true }
            if case let .activity(item) = primary {
                return item.composition == .timerCompletion && action != nil
            }
            return false
        case .peek:
            // Today only the completion acknowledgement renders its Done
            // action in Peek. Other activity actions remain Expanded-only.
            if case let .activity(item) = primary {
                return item.composition == .timerCompletion && action != nil
            }
            return false
        case .expanded:
            return action != nil
        case .hidden, .dropTarget:
            return false
        }
    }

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
        let item = current.map(ActivitySurfaceItem.init)
        switch state {
        case .hidden:
            primary = .hidden
        case .dropTarget:
            // File Hold is not mounted. Keep the compatibility state inert so
            // production never advertises a drop operation it will reject.
            primary = .hidden
        case .compact, .peek, .expanded:
            if phase == .degraded {
                primary = .degraded(
                    title: SurfaceStrings.degradedTitle,
                    detail: SurfaceStrings.degradedDetail
                )
            } else if let item {
                primary = .activity(item)
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
        let isCompletion = item?.composition == .timerCompletion
        self.action = state == .expanded || isCompletion ? action : nil
        interactionRole = switch state {
        case .hidden, .dropTarget:
            .none
        case .expanded:
            .collapse
        case .compact, .peek:
            if isCompletion, action?.intent == .dismiss {
                .dismiss
            } else if let item,
                      item.supportsExpandedPresentation(
                          action: action,
                          queue: queueContext
                      ) {
                .expand
            } else {
                .none
            }
        }
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
        self.init(content: content, temporalSnapshot: nil)
    }

    package init(
        content: ActivitySurfaceContent,
        temporalSnapshot: ActivitySurfaceTemporalSnapshot?
    ) {
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
            stateName = SurfaceStrings.hiddenState
        }

        let primaryValue: String
        switch content.primary {
        case .hidden:
            primaryValue = stateName
        case let .activity(item):
            primaryValue = [
                stateName,
                item.accessibilitySummary(temporalSnapshot: temporalSnapshot),
            ].joined(separator: ", ")
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
                switch content.interactionRole {
                case .expand:
                    SurfaceStrings.expandHint
                case .dismiss:
                    SurfaceStrings.dismissCompletionHint
                case .none:
                    switch content.primary {
                    case .empty, .degraded:
                        SurfaceStrings.hideHint
                    case .activity:
                        SurfaceStrings.passiveStatusHint
                    case .hidden, .dropTarget:
                        ""
                    }
                case .collapse:
                    SurfaceStrings.collapseHint
                }
            }
        case .expanded:
            SurfaceStrings.collapseHint
        case .dropTarget:
            ""
        }
    }
}
