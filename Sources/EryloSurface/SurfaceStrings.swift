import Foundation

/// User-facing surface copy lives in one place so a string catalog can replace the fallbacks.
public enum SurfaceStrings {
    public static let surfaceLabel = String(
        localized: "surface.accessibility.label",
        defaultValue: "Erylo activity surface"
    )
    public static let quietTitle = String(
        localized: "surface.empty.title",
        defaultValue: "Nothing active"
    )
    public static let quietDetail = String(
        localized: "surface.empty.detail",
        defaultValue: "Erylo is ready when you are."
    )
    public static let compactQuietTitle = String(
        localized: "surface.empty.compact",
        defaultValue: "Erylo"
    )
    public static let compactQuietValue = String(
        localized: "surface.empty.compact.value",
        defaultValue: "No current activity"
    )
    public static let compactReady = String(
        localized: "surface.empty.compact.ready",
        defaultValue: "Ready"
    )
    public static let compactPaused = String(
        localized: "surface.degraded.compact",
        defaultValue: "Paused"
    )
    public static let primaryShortcutKey = "⌃⌥⌘E"
    public static let degradedTitle = String(
        localized: "surface.degraded.title",
        defaultValue: "Activity feed paused"
    )
    public static let degradedDetail = String(
        localized: "surface.degraded.detail",
        defaultValue: "No activity updates are available."
    )
    public static let queueTitle = String(
        localized: "surface.queue.title",
        defaultValue: "Up next"
    )
    public static let actionUnavailable = String(
        localized: "surface.action.unavailable",
        defaultValue: "Action unavailable"
    )
    public static let actionStale = String(
        localized: "surface.action.stale",
        defaultValue: "Activity changed before the action ran"
    )
    public static let actionInProgress = String(
        localized: "surface.action.progress",
        defaultValue: "Working"
    )
    public static let dropTargetTitle = String(
        localized: "surface.drop-target.title",
        defaultValue: "File Hold isn’t connected yet"
    )
    public static let dropTargetDetail = String(
        localized: "surface.drop-target.detail",
        defaultValue: "This drop is not accepted and no files will be stored."
    )
    public static let expandHint = String(
        localized: "surface.accessibility.expand-hint",
        defaultValue: "Activate Erylo or press Control-Option-Command-E to show activity details."
    )
    public static let collapseHint = String(
        localized: "surface.accessibility.collapse-hint",
        defaultValue: "Activate Erylo or press Control-Option-Command-E to return to compact view."
    )
    public static let hideHint = String(
        localized: "surface.accessibility.hide-hint",
        defaultValue: "Activate Erylo or press Control-Option-Command-E to hide Erylo."
    )
    public static let dropTargetHint = String(
        localized: "surface.accessibility.drop-target-hint",
        defaultValue: "Move the files away to return to the activity surface."
    )
    public static let actionHint = String(
        localized: "surface.accessibility.action-hint",
        defaultValue: "Runs the single action supplied by this activity."
    )

    public static let genericKind = String(localized: "activity.kind.generic", defaultValue: "Activity")
    public static let batteryKind = String(localized: "activity.kind.battery", defaultValue: "Battery")
    public static let chargingKind = String(localized: "activity.kind.charging", defaultValue: "Charging")
    public static let timerKind = String(localized: "activity.kind.timer", defaultValue: "Timer")
    public static let meetingKind = String(localized: "activity.kind.meeting", defaultValue: "Meeting")
    public static let volumeKind = String(localized: "activity.kind.volume", defaultValue: "Volume")
    public static let mediaKind = String(localized: "activity.kind.media", defaultValue: "Media")
    public static let fileKind = String(localized: "activity.kind.file", defaultValue: "File")

    public static let hiddenState = String(localized: "surface.state.hidden", defaultValue: "Hidden")
    public static let compactState = String(localized: "surface.state.compact", defaultValue: "Compact")
    public static let peekState = String(localized: "surface.state.peek", defaultValue: "Peek")
    public static let expandedState = String(localized: "surface.state.expanded", defaultValue: "Expanded")
    public static let dropTargetState = String(
        localized: "surface.state.drop-target",
        defaultValue: "File drop target"
    )

    public static func progressValue(_ percent: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "activity.progress.percent", defaultValue: "%lld percent"),
            percent
        )
    }

    public static func shortProgressValue(_ percent: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "activity.progress.short-percent", defaultValue: "%lld%%"),
            percent
        )
    }

    public static func queueRemaining(_ count: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "surface.queue.remaining", defaultValue: "%lld more in queue"),
            count
        )
    }
}
