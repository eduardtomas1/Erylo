import AppKit
import CoreGraphics
import EryloCore

package enum ExpandedMouseDownDecision: Equatable, Sendable {
    case keepOpen
    case dismiss
}

package enum DeliberatePanelFocusPolicy {
    package static func shouldRequestKey(
        from oldState: PanelPresentationState,
        to newState: PanelPresentationState,
        isWindowPresented: Bool
    ) -> Bool {
        isWindowPresented && oldState != .expanded && newState == .expanded
    }
}

/// Pure policy for the only surface state that may own keyboard focus or
/// process-wide dismissal monitors. Native resources consume these decisions;
/// they do not invent broader interaction behavior.
package struct ExpandedInteractionPolicy: Equatable, Sendable {
    package let state: PanelPresentationState
    package let isWindowPresented: Bool
    package let hitRegion: HitRegion

    package init(
        state: PanelPresentationState,
        isWindowPresented: Bool,
        hitRegion: HitRegion
    ) {
        self.state = state
        self.isWindowPresented = isWindowPresented
        self.hitRegion = hitRegion
    }

    package var allowsKeyInteraction: Bool {
        isWindowPresented && state == .expanded
    }

    package var requiresMouseDownMonitoring: Bool {
        allowsKeyInteraction
    }

    package func mouseDownDecision(at localPoint: CGPoint) -> ExpandedMouseDownDecision {
        guard requiresMouseDownMonitoring else { return .keepOpen }
        return hitRegion.contains(localPoint) ? .keepOpen : .dismiss
    }

    package func shouldHandleEscape(panelIsKey: Bool) -> Bool {
        allowsKeyInteraction && panelIsKey
    }
}

package struct ExpandedInteractionLeasePolicy: Equatable, Sendable {
    package private(set) var isActive = false
    private var generation: UInt64 = 0

    package init() {}

    package mutating func activate() -> UInt64 {
        generation &+= 1
        isActive = true
        return generation
    }

    package mutating func retire() {
        generation &+= 1
        isActive = false
    }

    package func admits(_ lease: UInt64) -> Bool {
        isActive && generation == lease
    }
}

@MainActor
private final class ExpandedMouseDownMonitorResources {
    private(set) var localMonitor: Any?
    private(set) var globalMonitor: Any?
    private var handler: (@MainActor @Sendable (CGPoint) -> Void)?
    private var leasePolicy = ExpandedInteractionLeasePolicy()

    var isRunning: Bool {
        leasePolicy.isActive && localMonitor != nil && globalMonitor != nil
    }

    func start(handler: @escaping @MainActor @Sendable (CGPoint) -> Void) {
        if isRunning {
            self.handler = handler
            return
        }
        stop()

        let lease = leasePolicy.activate()
        self.handler = handler
        let events: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
        ]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            let screenPoint = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.emit(screenPoint, lease: lease)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            let screenPoint = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.emit(screenPoint, lease: lease)
            }
            return event
        }

        guard localMonitor != nil, globalMonitor != nil else {
            stop()
            return
        }
    }

    func stop() {
        leasePolicy.retire()
        handler = nil
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    private func emit(_ screenPoint: CGPoint, lease: UInt64) {
        guard leasePolicy.admits(lease), isRunning else { return }
        handler?(screenPoint)
    }
}

@MainActor
final class ExpandedMouseDownMonitor {
    private let resources = ExpandedMouseDownMonitorResources()

    var isRunning: Bool {
        resources.isRunning
    }

    func start(handler: @escaping @MainActor @Sendable (CGPoint) -> Void) {
        resources.start(handler: handler)
    }

    func stop() {
        resources.stop()
    }

    deinit {
        let resources = resources
        Task { @MainActor in
            resources.stop()
        }
    }
}
