import os

package enum ApplicationStartupMilestone: String, Equatable, Sendable {
    case applicationDidFinishLaunching
    case statusItemInstalled
    case restorationStarted
    case restorationCompleted
}

/// A deliberately small seam: production emits signpost events, while launch
/// regressions can record deterministic milestone order without wall-clock sleeps.
@MainActor
package protocol ApplicationStartupMeasuring: AnyObject {
    func record(_ milestone: ApplicationStartupMilestone)
}

@MainActor
package final class ApplicationStartupSignposter: ApplicationStartupMeasuring {
    private let log = OSLog(subsystem: "com.erylo.app", category: "StartupReadiness")

    package init() {}

    package func record(_ milestone: ApplicationStartupMilestone) {
        switch milestone {
        case .applicationDidFinishLaunching:
            os_signpost(.event, log: log, name: "Application Did Finish Launching")
        case .statusItemInstalled:
            os_signpost(.event, log: log, name: "Status Item Installed")
        case .restorationStarted:
            os_signpost(.event, log: log, name: "Persisted Module Restoration Started")
        case .restorationCompleted:
            os_signpost(.event, log: log, name: "Persisted Module Restoration Completed")
        }
    }
}
