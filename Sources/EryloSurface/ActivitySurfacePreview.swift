import EryloActivity
import EryloCore

public struct ActivitySurfacePreviewScenario: Equatable, Sendable {
    public let name: String
    public let state: PanelPresentationState
    public let current: ActivityRequest?
    public let queued: [ActivityRequest]
    public let showsFocusTimerLauncher: Bool

    public init(
        name: String,
        state: PanelPresentationState,
        current: ActivityRequest?,
        queued: [ActivityRequest] = [],
        showsFocusTimerLauncher: Bool = false
    ) {
        self.name = name
        self.state = state
        self.current = current
        self.queued = Array(queued.prefix(ActivityQueueContext.maximumVisibleItems))
        self.showsFocusTimerLauncher = showsFocusTimerLauncher
    }

    public func snapshot() throws(ActivityValidationError) -> ActivityBrokerSnapshot {
        let requests = [current].compactMap { $0 } + queued
        var presented: [PresentedActivity] = []
        presented.reserveCapacity(requests.count)
        for (index, request) in requests.enumerated() {
            presented.append(
                PresentedActivity(
                activity: try Activity(validating: request),
                submissionSequence: UInt64(index + 1),
                revision: UInt64(index + 1)
                )
            )
        }
        return ActivityBrokerSnapshot(
            version: 1,
            current: presented.first,
            queued: Array(presented.dropFirst())
        )
    }
}

/// Deterministic, bounded data for native previews and a later real screenshot host.
/// It performs no provider, network, file, timer, or broker subscription work.
public enum ActivitySurfacePreviewCatalog {
    public static let focusTimerLauncher = ActivitySurfacePreviewScenario(
        name: "Focus Timer launcher",
        state: .compact,
        current: nil,
        showsFocusTimerLauncher: true
    )

    public static let generic = ActivitySurfacePreviewScenario(
        name: "Generic compact",
        state: .compact,
        current: request(
            identifier: "preview.generic",
            source: .external,
            kind: .generic,
            title: "Build completed",
            detail: "Debug build succeeded"
        )
    )

    public static let battery = ActivitySurfacePreviewScenario(
        name: "Battery peek",
        state: .peek,
        current: request(
            identifier: "preview.battery",
            source: .battery,
            kind: .battery,
            title: "Battery",
            detail: "62% remaining",
            progress: 0.62
        )
    )

    public static let charging = ActivitySurfacePreviewScenario(
        name: "Charging peek",
        state: .peek,
        current: request(
            identifier: "preview.charging",
            source: .battery,
            kind: .charging,
            title: "Charging",
            detail: "48% · preview value",
            progress: 0.48
        )
    )

    public static let timer = ActivitySurfacePreviewScenario(
        name: "Timer expanded",
        state: .expanded,
        current: request(
            identifier: "preview.timer",
            source: .timer,
            kind: .timer,
            title: "Focus timer",
            detail: "12:40 remaining",
            progress: 0.36,
            actionIdentifier: "preview.timer.cancel",
            actionLabel: "Cancel timer",
            actionIntent: .cancel
        )
    )

    public static let timerCompact = ActivitySurfacePreviewScenario(
        name: "Timer compact",
        state: .compact,
        current: request(
            identifier: "preview.timer.compact",
            source: .timer,
            kind: .timer,
            title: "Focus Timer",
            detail: "12:40"
        )
    )

    public static let timerCompletion = ActivitySurfacePreviewScenario(
        name: "Timer completion",
        state: .peek,
        current: request(
            identifier: "preview.timer.complete",
            source: .timer,
            kind: .timer,
            title: "Focus complete"
        )
    )

    public static let meeting = ActivitySurfacePreviewScenario(
        name: "Meeting expanded",
        state: .expanded,
        current: request(
            identifier: "preview.meeting",
            source: .calendar,
            kind: .meeting,
            title: "Design review",
            detail: "Starts in 10 minutes",
            actionIdentifier: "preview.meeting.open",
            actionLabel: "Open calendar",
            actionIntent: .openSource
        )
    )

    public static let volume = ActivitySurfacePreviewScenario(
        name: "Volume compact",
        state: .compact,
        current: request(
            identifier: "preview.volume",
            source: .volume,
            kind: .volume,
            title: "Output volume",
            detail: "MacBook Pro Speakers",
            progress: 0.72
        )
    )

    public static let media = ActivitySurfacePreviewScenario(
        name: "Media with queue",
        state: .expanded,
        current: request(
            identifier: "preview.media",
            source: .appleMusic,
            kind: .media,
            title: "Night Drive",
            detail: "Synthetic preview track",
            progress: 0.41,
            actionIdentifier: "preview.media.toggle",
            actionLabel: "Play or pause",
            actionIntent: .togglePlayback
        ),
        queued: [timer.current, meeting.current].compactMap { $0 }
    )

    public static let file = ActivitySurfacePreviewScenario(
        name: "File activity",
        state: .peek,
        current: request(
            identifier: "preview.file",
            source: .fileHold,
            kind: .file,
            title: "File handoff requested",
            detail: "Preview only · no files stored"
        )
    )

    public static let empty = ActivitySurfacePreviewScenario(
        name: "Empty expanded",
        state: .expanded,
        current: nil
    )

    public static let dropTarget = ActivitySurfacePreviewScenario(
        name: "Unavailable drop target",
        state: .dropTarget,
        current: nil
    )

    public static let representative: [ActivitySurfacePreviewScenario] = [
        focusTimerLauncher,
        generic,
        battery,
        charging,
        timer,
        timerCompact,
        timerCompletion,
        meeting,
        volume,
        media,
        file,
        empty,
        dropTarget,
    ]

    @MainActor
    public static func makeModel(
        scenario: ActivitySurfacePreviewScenario,
        displayGeometry: DisplayGeometry,
        metrics: PanelMetrics = .feasibility,
        scheduler: any OneShotScheduling = TaskOneShotScheduler()
    ) throws(ActivityValidationError) -> PanelSurfaceModel {
        let activityModel = SurfaceActivityModel(previewSnapshot: try scenario.snapshot())
        let model = PanelSurfaceModel(
            displayGeometry: displayGeometry,
            initialState: scenario.state,
            metrics: metrics,
            scheduler: scheduler,
            activityModel: activityModel
        )
        if scenario.showsFocusTimerLauncher {
            model.setFocusTimerStartHandler { _ in true }
        }
        return model
    }

    private static func request(
        identifier: String,
        source: ActivitySource,
        kind: ActivityKind,
        title: String,
        detail: String? = nil,
        progress: Double? = nil,
        actionIdentifier: String? = nil,
        actionLabel: String? = nil,
        actionIntent: ActivityActionIntent? = nil
    ) -> ActivityRequest {
        ActivityRequest(
            identifier: identifier,
            source: source.rawValue,
            kind: kind.rawValue,
            priority: ActivityPriority.normal.rawValue,
            title: title,
            detail: detail,
            progress: progress,
            actionIdentifier: actionIdentifier,
            actionLabel: actionLabel,
            actionIntent: actionIntent?.rawValue
        )
    }
}
