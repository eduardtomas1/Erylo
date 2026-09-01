import CoreGraphics
import EryloCore
import EryloSurface

@MainActor
public protocol PanelPresenting: AnyObject {
    var displayIdentity: DisplayIdentity { get }

    func show()
    func hide()
    func close()
    func update(snapshot: DisplaySnapshot)
    func updatePointer(screenPoint: CGPoint)
    func performPrimaryAction()
    func performVisibilityToggle()
    func cancelPendingInteractions()
    func contractForEnvironmentalTransition()
    func setFullscreenAuxiliaryEnabled(_ enabled: Bool)
}

/// Package-only feedback from native panels to the process coordinator. The
/// surface is demanded only while its window is shown and its state is not hidden.
@MainActor
package protocol PanelActivityVisibilityReporting: AnyObject {
    var isActivitySurfaceVisible: Bool { get }

    func setActivityVisibilityHandler(
        _ handler: (@MainActor @Sendable (Bool) -> Void)?
    )
}

/// Package-only state demand from a panel model to its native window owner.
/// A hidden model keeps its already-constructed tree ordered out and owns no
/// pointer monitors; a visible model asks the coordinator to prepare pointer
/// delivery before ordering the window in.
@MainActor
package protocol PanelPresentationDemandReporting: AnyObject {
    var wantsSurfacePresentation: Bool { get }

    func setPresentationDemandHandler(
        _ handler: (@MainActor @Sendable (Bool) -> Void)?
    )
}

@MainActor
package protocol PanelFocusTimerLaunching: AnyObject {
    func setFocusTimerStartHandler(
        _ handler: (@MainActor @Sendable (Int) -> Bool)?
    )
}

/// A deliberate shortcut may focus controls that are already on screen without
/// also invoking the surface's semantic primary action.
@MainActor
package protocol PanelExistingControlFocusing: AnyObject {
    @discardableResult
    func focusExistingControls() -> Bool
}

/// Native panels distinguish lifecycle retirement from a user-visible demand
/// contraction. Sleep must never wait for the outgoing surface animation.
@MainActor
package protocol PanelImmediateEnvironmentalHiding: AnyObject {
    func hideImmediatelyForEnvironmentalTransition()
}

public extension PanelPresenting {
    /// Compatibility fallback for injected presenters that only implement the original action.
    /// The native presenter overrides this with a strict hidden/visible surface toggle.
    func performVisibilityToggle() {
        performPrimaryAction()
    }

    /// Compatibility fallback for injected presenters without an internal
    /// surface reducer. Native panels override this to retire Peek/Expanded.
    func contractForEnvironmentalTransition() {
        cancelPendingInteractions()
    }

    /// Compatibility fallback for injected presenters without native AppKit policy.
    func setFullscreenAuxiliaryEnabled(_ enabled: Bool) {
        _ = enabled
    }
}

public typealias PanelPresentationFactory = @MainActor (
    DisplaySnapshot
) -> any PanelPresenting

public typealias ActivityPanelPresentationFactory = @MainActor (
    DisplaySnapshot,
    SurfaceActivityModel
) -> any PanelPresenting
