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

    public init(
        maximumSize: CGSize,
        compactSize: CGSize,
        peekSize: CGSize,
        expandedSize: CGSize,
        dropTargetSize: CGSize,
        notchHorizontalPadding: CGFloat,
        notchlessTopInset: CGFloat = 0
    ) {
        self.maximumSize = maximumSize
        self.compactSize = compactSize
        self.peekSize = peekSize
        self.expandedSize = expandedSize
        self.dropTargetSize = dropTargetSize
        self.notchHorizontalPadding = notchHorizontalPadding
        self.notchlessTopInset = notchlessTopInset
    }

    public static let feasibility = PanelMetrics(
        maximumSize: CGSize(width: 560, height: 240),
        compactSize: CGSize(width: 240, height: 32),
        peekSize: CGSize(width: 292, height: 68),
        expandedSize: CGSize(width: 376, height: 164),
        dropTargetSize: CGSize(width: 404, height: 180),
        notchHorizontalPadding: 30,
        notchlessTopInset: 8
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
        metrics: PanelMetrics = .feasibility
    ) {
        let maximumSize = metrics.maximumSize
        fixedFrame = CGRect(
            x: display.frame.midX - maximumSize.width / 2,
            y: display.frame.maxY - maximumSize.height,
            width: maximumSize.width,
            height: maximumSize.height
        )

        attachment = display.topEdgeOcclusion == nil ? .notchlessPill : .notchIntegrated
        surfaceTopInset = attachment == .notchlessPill ? metrics.notchlessTopInset : 0

        let requestedSize = Self.requestedSurfaceSize(
            state: state,
            display: display,
            metrics: metrics
        )
        let availableHeight = max(maximumSize.height - surfaceTopInset, 0)
        let size = CGSize(
            width: min(max(requestedSize.width, 0), maximumSize.width),
            height: min(max(requestedSize.height, 0), availableHeight)
        )
        surfaceFrame = CGRect(
            x: (maximumSize.width - size.width) / 2,
            y: maximumSize.height - surfaceTopInset - size.height,
            width: size.width,
            height: size.height
        )

        if let occlusion = display.topEdgeOcclusion {
            topCornerRadius = switch state {
            case .hidden:
                0
            case .compact:
                6
            case .peek:
                13
            case .expanded:
                19
            case .dropTarget:
                21
            }
            surfaceContentTopInset = state == .compact
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

        cornerRadius = switch (attachment, state) {
        case (_, .hidden):
            0
        case (.notchlessPill, .compact), (.notchlessPill, .peek):
            size.height / 2
        case (.notchIntegrated, .compact):
            min(14, size.height / 2)
        case (.notchIntegrated, .peek):
            min(19, size.height / 2)
        case (_, .expanded), (_, .dropTarget):
            min(23, size.height / 2)
        }

        if state == .hidden {
            hitRegion = .empty
        } else if attachment == .notchIntegrated {
            // The concave top corners are transparent. Accept clicks only in an
            // inscribed visible shelf; the global pointer monitor owns the wider
            // noninteractive hover envelope.
            let bodyHeight = state == .compact
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
        metrics: PanelMetrics
    ) -> CGSize {
        var size = switch state {
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

        if state != .hidden, let occlusion = display.topEdgeOcclusion {
            size.width = max(size.width, occlusion.frame.width + metrics.notchHorizontalPadding * 2)
            size.height = max(size.height, occlusion.frame.height)
        }
        return size
    }
}
