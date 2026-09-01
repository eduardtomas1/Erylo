import CoreGraphics
import Foundation

public struct PanelMetrics: Equatable, Sendable {
    public let maximumSize: CGSize
    public let compactSize: CGSize
    public let peekSize: CGSize
    public let expandedSize: CGSize
    public let dropTargetSize: CGSize
    public let notchHorizontalPadding: CGFloat
    public let notchlessTopInset: CGFloat
    public let timerLauncherSize: CGSize
    public let notchlessTimerLauncherSize: CGSize

    public init(
        maximumSize: CGSize,
        compactSize: CGSize,
        peekSize: CGSize,
        expandedSize: CGSize,
        dropTargetSize: CGSize,
        notchHorizontalPadding: CGFloat,
        notchlessTopInset: CGFloat = 0,
        timerLauncherSize: CGSize = CGSize(width: 316, height: 88),
        notchlessTimerLauncherSize: CGSize = CGSize(width: 300, height: 44)
    ) {
        self.maximumSize = maximumSize
        self.compactSize = compactSize
        self.peekSize = peekSize
        self.expandedSize = expandedSize
        self.dropTargetSize = dropTargetSize
        self.notchHorizontalPadding = notchHorizontalPadding
        self.notchlessTopInset = notchlessTopInset
        self.timerLauncherSize = timerLauncherSize
        self.notchlessTimerLauncherSize = notchlessTimerLauncherSize
    }

    public static let feasibility = PanelMetrics(
        maximumSize: CGSize(width: 560, height: 240),
        compactSize: CGSize(width: 240, height: 32),
        peekSize: CGSize(width: 292, height: 68),
        expandedSize: CGSize(width: 376, height: 164),
        dropTargetSize: CGSize(width: 404, height: 180),
        notchHorizontalPadding: 30,
        notchlessTopInset: 8,
        timerLauncherSize: CGSize(width: 316, height: 88),
        notchlessTimerLauncherSize: CGSize(width: 300, height: 44)
    )
}

public struct RoundedHitRegion: Equatable, Sendable {
    public let rect: CGRect
    public let cornerRadius: CGFloat

    public init(rect: CGRect, cornerRadius: CGFloat) {
        self.rect = rect
        self.cornerRadius = cornerRadius
    }
}

public enum HitRegion: Equatable, Sendable {
    case empty
    case roundedRectangle(CGRect, cornerRadius: CGFloat)
    /// A flattened, deduplicated conjunction. It cannot form a recursive chain.
    case intersection([RoundedHitRegion])

    public var componentCount: Int {
        switch self {
        case .empty:
            0
        case .roundedRectangle:
            1
        case let .intersection(components):
            components.count
        }
    }

    public func contains(_ point: CGPoint) -> Bool {
        switch self {
        case .empty:
            return false
        case let .roundedRectangle(rect, cornerRadius):
            return Self.roundedRectangleContains(
                point,
                rect: rect,
                cornerRadius: cornerRadius
            )
        case let .intersection(components):
            return !components.isEmpty && components.allSatisfy { component in
                Self.roundedRectangleContains(
                    point,
                    rect: component.rect,
                    cornerRadius: component.cornerRadius
                )
            }
        }
    }

    public func intersecting(_ other: HitRegion) -> HitRegion {
        switch (self, other) {
        case (.empty, _), (_, .empty):
            return .empty
        case _ where self == other:
            return self
        default:
            let components = (roundedComponents + other.roundedComponents).reduce(
                into: [RoundedHitRegion]()
            ) { result, component in
                if !result.contains(component) {
                    result.append(component)
                }
            }
            let sharedBounds = components
                .dropFirst()
                .reduce(components[0].rect) { bounds, component in
                    bounds.intersection(component.rect)
                }
            guard !sharedBounds.isNull,
                  sharedBounds.width > 0,
                  sharedBounds.height > 0 else {
                return .empty
            }
            return components.count == 1
                ? .roundedRectangle(
                    components[0].rect,
                    cornerRadius: components[0].cornerRadius
                )
                : .intersection(components)
        }
    }

    private var roundedComponents: [RoundedHitRegion] {
        switch self {
        case .empty:
            []
        case let .roundedRectangle(rect, cornerRadius):
            [RoundedHitRegion(rect: rect, cornerRadius: cornerRadius)]
        case let .intersection(components):
            components
        }
    }

    private static func roundedRectangleContains(
        _ point: CGPoint,
        rect: CGRect,
        cornerRadius: CGFloat
    ) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        guard point.x >= rect.minX, point.x <= rect.maxX,
              point.y >= rect.minY, point.y <= rect.maxY else {
            return false
        }

        let radius = min(max(cornerRadius, 0), min(rect.width, rect.height) / 2)
        guard radius > 0 else { return true }

        if point.x >= rect.minX + radius, point.x <= rect.maxX - radius {
            return true
        }
        if point.y >= rect.minY + radius, point.y <= rect.maxY - radius {
            return true
        }

        let centerX = point.x < rect.midX ? rect.minX + radius : rect.maxX - radius
        let centerY = point.y < rect.midY ? rect.minY + radius : rect.maxY - radius
        let deltaX = point.x - centerX
        let deltaY = point.y - centerY
        return deltaX * deltaX + deltaY * deltaY <= radius * radius
    }
}

public enum PanelAttachment: Equatable, Sendable {
    case notchIntegrated
    case notchlessPill
}

public struct PanelLayout: Equatable, Sendable {
    /// The window frame in global display coordinates. It is invariant across states.
    public let fixedFrame: CGRect
    /// The visible SwiftUI surface in fixed-frame-local AppKit coordinates.
    public let surfaceFrame: CGRect
    public let cornerRadius: CGFloat
    public let hitRegion: HitRegion
    public let attachment: PanelAttachment
    public let surfaceTopInset: CGFloat
    /// Concave outer curl that visually joins the surface to the top bezel.
    /// Zero on notchless displays.
    package let topCornerRadius: CGFloat
    /// Top inset that keeps rendered content below the physical occlusion and
    /// its shoulder transition.
    package let surfaceContentTopInset: CGFloat
    /// Stable top-edge envelope used to enter and retain hover independently
    /// from the lower shelf's click geometry.
    package let hoverAnchorRegion: HitRegion

    public init(
        display: DisplayGeometry,
        state: PanelPresentationState,
        metrics: PanelMetrics = .feasibility,
        showsFocusTimerLauncher: Bool = false,
        minimumNotchWingWidth: CGFloat = 0,
        minimumNotchBodyHeight: CGFloat = 0
    ) {
        let maximumSize = metrics.maximumSize
        let resolvedAttachment: PanelAttachment = display.topEdgeOcclusion == nil
            ? .notchlessPill
            : .notchIntegrated
        attachment = resolvedAttachment
        let fixedFrameTopEdge = resolvedAttachment == .notchlessPill
            ? display.visibleFrame.maxY
            : display.frame.maxY
        fixedFrame = CGRect(
            x: display.frame.midX - maximumSize.width / 2,
            y: fixedFrameTopEdge - maximumSize.height,
            width: maximumSize.width,
            height: maximumSize.height
        )

        let resolvedSurfaceTopInset = resolvedAttachment == .notchlessPill
            ? metrics.notchlessTopInset
            : 0
        surfaceTopInset = resolvedSurfaceTopInset

        let requestedSize = Self.requestedSurfaceSize(
            state: state,
            display: display,
            metrics: metrics,
            showsFocusTimerLauncher: showsFocusTimerLauncher,
            minimumNotchWingWidth: minimumNotchWingWidth,
            minimumNotchBodyHeight: minimumNotchBodyHeight
        )
        let availableHeight = max(maximumSize.height - resolvedSurfaceTopInset, 0)
        let size = CGSize(
            width: min(max(requestedSize.width, 0), maximumSize.width),
            height: min(max(requestedSize.height, 0), availableHeight)
        )
        surfaceFrame = CGRect(
            x: (maximumSize.width - size.width) / 2,
            y: maximumSize.height - resolvedSurfaceTopInset - size.height,
            width: size.width,
            height: size.height
        )

        if let occlusion = display.topEdgeOcclusion {
            topCornerRadius = switch (state, showsFocusTimerLauncher) {
            case (.compact, true):
                13
            case (.hidden, _):
                0
            case (.compact, _):
                6
            case (.peek, _):
                13
            case (.expanded, _):
                19
            case (.dropTarget, _):
                21
            }
            surfaceContentTopInset = state == .compact && !showsFocusTimerLauncher
                ? 0
                : min(max(occlusion.frame.height, 0), size.height)

            let compactAnchorWidth = min(
                max(
                    metrics.compactSize.width,
                    occlusion.frame.width + metrics.notchHorizontalPadding * 2
                ),
                maximumSize.width
            )
            let anchorHeight = min(max(occlusion.frame.height, 0), maximumSize.height)
            hoverAnchorRegion = anchorHeight == 0
                ? .empty
                : .roundedRectangle(
                    CGRect(
                        x: (maximumSize.width - compactAnchorWidth) / 2,
                        y: maximumSize.height - anchorHeight,
                        width: compactAnchorWidth,
                        height: anchorHeight
                    ),
                    cornerRadius: 0
                )
        } else {
            topCornerRadius = 0
            surfaceContentTopInset = 0
            hoverAnchorRegion = .empty
        }

        cornerRadius = switch (resolvedAttachment, state, showsFocusTimerLauncher) {
        case (_, .hidden, _):
            0
        case (.notchlessPill, .compact, true):
            min(19, size.height / 2)
        case (.notchlessPill, .compact, _), (.notchlessPill, .peek, _):
            size.height / 2
        case (.notchIntegrated, .compact, true):
            min(19, size.height / 2)
        case (.notchIntegrated, .compact, _):
            min(14, size.height / 2)
        case (.notchIntegrated, .peek, _):
            min(19, size.height / 2)
        case (_, .expanded, _), (_, .dropTarget, _):
            min(23, size.height / 2)
        }

        if state == .hidden || state == .dropTarget {
            // File Hold is not mounted. The compatibility state must stay inert
            // and can never become an invisible AppKit click blocker.
            hitRegion = .empty
        } else if resolvedAttachment == .notchIntegrated {
            // The concave top corners are transparent. Accept clicks only in an
            // inscribed visible shelf; the global pointer monitor owns the wider
            // noninteractive hover envelope.
            let bodyHeight = state == .compact && !showsFocusTimerLauncher
                ? size.height
                : max(size.height - surfaceContentTopInset, 0)
            let bodyWidth = max(size.width - topCornerRadius * 2, 0)
            let bodyFrame = CGRect(
                x: surfaceFrame.minX + topCornerRadius,
                y: surfaceFrame.minY,
                width: bodyWidth,
                height: bodyHeight
            )
            hitRegion = bodyHeight == 0 || bodyWidth == 0
                ? .empty
                : .roundedRectangle(
                    bodyFrame,
                    cornerRadius: min(cornerRadius, bodyHeight / 2)
                )
        } else {
            hitRegion = .roundedRectangle(surfaceFrame, cornerRadius: cornerRadius)
        }
    }

    private static func requestedSurfaceSize(
        state: PanelPresentationState,
        display: DisplayGeometry,
        metrics: PanelMetrics,
        showsFocusTimerLauncher: Bool,
        minimumNotchWingWidth: CGFloat,
        minimumNotchBodyHeight: CGFloat
    ) -> CGSize {
        var size = if state == .compact && showsFocusTimerLauncher {
            display.topEdgeOcclusion == nil
                ? metrics.notchlessTimerLauncherSize
                : metrics.timerLauncherSize
        } else {
            switch state {
        case .hidden:
            CGSize.zero
        case .compact:
            metrics.compactSize
        case .peek:
            metrics.peekSize
        case .expanded:
            metrics.expandedSize
        case .dropTarget:
            metrics.dropTargetSize
            }
        }

        if state != .hidden, let occlusion = display.topEdgeOcclusion {
            let horizontalPadding = max(
                metrics.notchHorizontalPadding,
                state == .compact ? minimumNotchWingWidth : 0
            )
            size.width = max(size.width, occlusion.frame.width + horizontalPadding * 2)
            size.height = max(
                size.height,
                occlusion.frame.height + max(minimumNotchBodyHeight, 0)
            )
        }
        return size
    }
}
