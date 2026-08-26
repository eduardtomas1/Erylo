import AppKit
import CoreGraphics
import EryloCore
import EryloIntegrations

@MainActor
public final class SystemDisplayProvider: EnabledDisplayProviding {
    public init() {}

    public func enabledDisplays() -> [DisplaySnapshot] {
        let screens = NSScreen.screens
        let mainDisplayID = CGMainDisplayID()
        let mainQuartzFrame = CGDisplayBounds(mainDisplayID)

        return Self.activeDisplayIDs().compactMap { directDisplayID in
            guard CGDisplayMirrorsDisplay(directDisplayID) == kCGNullDirectDisplay else {
                return nil
            }

            let frame = Self.appKitFrame(
                forQuartzFrame: CGDisplayBounds(directDisplayID),
                mainQuartzFrame: mainQuartzFrame
            )
            let screen = screens.first { Self.framesMatch($0.frame, frame) }
            return DisplaySnapshot(
                identity: DisplayIdentity(rawValue: directDisplayID),
                geometry: DisplayGeometry(
                    frame: frame,
                    visibleFrame: screen?.visibleFrame ?? frame,
                    backingScaleFactor: screen?.backingScaleFactor ?? 1,
                    topEdgeOcclusion: screen.flatMap(Self.topEdgeOcclusion)
                ),
                isMain: directDisplayID == mainDisplayID
            )
        }
    }

    private static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let result = displays.withUnsafeMutableBufferPointer { buffer in
            CGGetActiveDisplayList(count, buffer.baseAddress, &count)
        }
        guard result == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }

    private static func appKitFrame(
        forQuartzFrame quartzFrame: CGRect,
        mainQuartzFrame: CGRect
    ) -> CGRect {
        CGRect(
            x: quartzFrame.minX,
            y: mainQuartzFrame.height - quartzFrame.maxY,
            width: quartzFrame.width,
            height: quartzFrame.height
        )
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 0.5
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private static func topEdgeOcclusion(for screen: NSScreen) -> TopEdgeOcclusion? {
        guard let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else {
            return nil
        }

        let width = rightArea.minX - leftArea.maxX
        let height = screen.safeAreaInsets.top
        guard width > 0, height > 0 else { return nil }

        return TopEdgeOcclusion(
            frame: CGRect(
                x: leftArea.maxX,
                y: screen.frame.maxY - height,
                width: width,
                height: height
            )
        )
    }
}
