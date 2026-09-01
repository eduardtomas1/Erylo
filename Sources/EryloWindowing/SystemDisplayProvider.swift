import AppKit
import CoreGraphics
import EryloCore
import EryloIntegrations

@MainActor
public final class SystemDisplayProvider: EnabledDisplayProviding {
    private static let maximumDisplayNameBytes = 80

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
            guard let uuid = Self.displayUUID(for: directDisplayID) else {
                return nil
            }
            let screen = Self.screen(for: directDisplayID, in: screens)
            return DisplaySnapshot(
                identity: DisplayIdentity(rawValue: directDisplayID),
                uuid: uuid,
                localizedName: Self.boundedDisplayName(screen?.localizedName),
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

    private static func displayUUID(for displayID: CGDirectDisplayID) -> DisplayUUID? {
        guard let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        // The Core Graphics function follows the Create Rule and hands Swift an
        // owning Unmanaged reference on current SDKs.
        let uuid = unmanagedUUID.takeRetainedValue()
        let value = CFUUIDCreateString(nil, uuid) as String
        return DisplayUUID(rawValue: value)
    }

    private static func screen(
        for displayID: CGDirectDisplayID,
        in screens: [NSScreen]
    ) -> NSScreen? {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        return screens.first { screen in
            guard let number = screen.deviceDescription[screenNumberKey] as? NSNumber else {
                return false
            }
            return number.uint32Value == displayID
        }
    }

    private static func boundedDisplayName(_ value: String?) -> String {
        guard let value else { return "Display" }
        var result = ""
        var byteCount = 0
        for scalar in value.unicodeScalars.prefix(maximumDisplayNameBytes * 2) {
            guard !CharacterSet.controlCharacters.contains(scalar) else { continue }
            let fragment = String(scalar)
            let fragmentBytes = fragment.utf8.count
            guard byteCount + fragmentBytes <= maximumDisplayNameBytes else { break }
            result.unicodeScalars.append(scalar)
            byteCount += fragmentBytes
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Display" : trimmed
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
