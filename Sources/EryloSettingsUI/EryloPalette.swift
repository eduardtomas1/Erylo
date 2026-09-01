import SwiftUI

public enum EryloPalette {
    public static let ink = Color(red: 6 / 255, green: 8 / 255, blue: 11 / 255)
    public static let mint = Color(red: 98 / 255, green: 242 / 255, blue: 193 / 255)
    public static let graphite = Color(red: 21 / 255, green: 26 / 255, blue: 33 / 255)
    public static let sky = Color(red: 107 / 255, green: 155 / 255, blue: 255 / 255)
    public static let cloud = Color(red: 244 / 255, green: 247 / 255, blue: 250 / 255)
    public static let mist = Color(red: 152 / 255, green: 163 / 255, blue: 179 / 255)
    public static let amber = Color(red: 255 / 255, green: 180 / 255, blue: 84 / 255)
    public static let coral = Color(red: 255 / 255, green: 101 / 255, blue: 122 / 255)
}

/// Erylo's code-native mark: a quiet surface descending from the top edge.
/// The same path is used by onboarding and the native status item so branding
/// does not depend on an unrelated SF Symbol or a bundled bitmap.
public enum EryloSignalMarkGeometry {
    public static func path(in rect: CGRect) -> Path {
        let top = rect.minY + rect.height * 0.18
        let bottom = rect.minY + rect.height * 0.78
        let leftShoulder = rect.minX + rect.width * 0.28
        let leftBase = rect.minX + rect.width * 0.42
        let rightBase = rect.minX + rect.width * 0.58
        let rightShoulder = rect.minX + rect.width * 0.72

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: top))
        path.addLine(to: CGPoint(x: leftShoulder, y: top))
        path.addCurve(
            to: CGPoint(x: leftBase, y: bottom),
            control1: CGPoint(x: rect.minX + rect.width * 0.35, y: top),
            control2: CGPoint(x: rect.minX + rect.width * 0.35, y: bottom)
        )
        path.addLine(to: CGPoint(x: rightBase, y: bottom))
        path.addCurve(
            to: CGPoint(x: rightShoulder, y: top),
            control1: CGPoint(x: rect.minX + rect.width * 0.65, y: bottom),
            control2: CGPoint(x: rect.minX + rect.width * 0.65, y: top)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: top))
        return path
    }
}

public struct EryloSignalMark: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        EryloSignalMarkGeometry.path(in: rect)
    }
}
