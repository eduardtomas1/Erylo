import CoreGraphics

/// Small, testable layout tokens shared by the production surface and its native harness.
/// They describe visible control spacing only; panel geometry and hit testing remain owned by
/// `PanelLayout` and `PanelSurfaceModel`.
package enum PanelSurfaceVisualMetrics {
    package static let notchWingOuterPadding: CGFloat = 14
    package static let notchWingCameraClearance: CGFloat = 6
    package static let minimumCompactNotchWingWidth: CGFloat = 48
    package static let statusCompactNotchWingWidth: CGFloat = 60

    package static let expandedActionLeadingInset: CGFloat = 19
    package static let expandedActionTrailingInset: CGFloat = 26

    package static let focusTimerPresetSpacing: CGFloat = 4
    package static let focusTimerPresetMinimumWidth: CGFloat = 38
    package static let focusTimerPresetMinimumHeight: CGFloat = 28
    package static let focusTimerPresetCornerRadius: CGFloat = 7

    package static let notchlessLightShadowOpacity = 0.16
    package static let notchlessLightShadowRadius: CGFloat = 5
    package static let notchlessLightShadowOffsetY: CGFloat = 1
    package static let notchlessDarkShadowOpacity = 0.28
    package static let notchlessDarkShadowRadius: CGFloat = 7
    package static let notchlessDarkShadowOffsetY: CGFloat = 2

    package static func notchWingContentWidth(for wingWidth: CGFloat) -> CGFloat {
        max(
            wingWidth - notchWingOuterPadding - notchWingCameraClearance,
            0
        )
    }
}
