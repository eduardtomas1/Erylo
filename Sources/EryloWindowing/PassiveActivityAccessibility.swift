import AppKit
import EryloSurface

@MainActor
package protocol PanelAccessibilityAnnouncing: AnyObject {
    func announce(_ text: String)
}

@MainActor
package final class SystemPanelAccessibilityAnnouncer: PanelAccessibilityAnnouncing {
    package init() {}

    package func announce(_ text: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}

/// Bounded semantic deduplication for passive HUD announcements. Revisions and
/// observer churn do not speak twice; a real value change does.
package struct PassiveActivityAnnouncementPolicy {
    package static let maximumRememberedActivities = 32

    private struct Memory: Equatable {
        let identity: String
        let text: String
    }

    private var recent: [Memory] = []

    package init() {}

    package mutating func announcement(for item: ActivitySurfaceItem?) -> String? {
        guard let item, let text = Self.semanticText(for: item) else { return nil }
        let identity = "\(item.identity.source.rawValue):\(item.identity.identifier.rawValue)"
        if let existingIndex = recent.firstIndex(where: { $0.identity == identity }) {
            let existing = recent.remove(at: existingIndex)
            recent.append(existing.text == text ? existing : Memory(identity: identity, text: text))
            return existing.text == text ? nil : text
        }

        recent.append(Memory(identity: identity, text: text))
        if recent.count > Self.maximumRememberedActivities {
            recent.removeFirst(recent.count - Self.maximumRememberedActivities)
        }
        return text
    }

    package mutating func reset() {
        recent.removeAll(keepingCapacity: false)
    }

    private static func semanticText(for item: ActivitySurfaceItem) -> String? {
        switch item.kind {
        case .battery, .charging:
            guard let progressValue = item.progressValue else { return nil }
            return [item.kindLabel, progressValue].joined(separator: ", ")
        case .volume:
            return volumeSemanticText(for: item)
        case .timer, .meeting, .media, .file, .generic:
            return nil
        }
    }

    private static func volumeSemanticText(for item: ActivitySurfaceItem) -> String? {
        let components: [String?] = switch item.presentationRole {
        case .volumeLevelChanged:
            [item.kindLabel, item.progressValue]
        case .volumeMuted:
            [item.kindLabel, SurfaceStrings.volumeMuted]
        case .volumeUnmuted:
            [item.kindLabel, SurfaceStrings.volumeUnmuted, item.progressValue]
        case .volumeOutputChanged:
            [item.kindLabel, SurfaceStrings.volumeOutputChanged, item.title]
        case .standard:
            [
                item.kindLabel,
                item.title.caseInsensitiveCompare(item.kindLabel) == .orderedSame
                    ? nil
                    : item.title,
                item.progressValue,
            ]
        case .completionAcknowledgement:
            []
        }
        let text = components.compactMap { $0 }.joined(separator: ", ")
        return text.isEmpty ? nil : text
    }
}
