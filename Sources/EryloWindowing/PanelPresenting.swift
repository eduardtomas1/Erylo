import CoreGraphics
import EryloCore

@MainActor
public protocol PanelPresenting: AnyObject {
    var displayIdentity: DisplayIdentity { get }

    func show()
    func hide()
    func close()
    func update(snapshot: DisplaySnapshot)
    func updatePointer(screenPoint: CGPoint)
    func performPrimaryAction()
    func cancelPendingInteractions()
}

public typealias PanelPresentationFactory = @MainActor (DisplaySnapshot) -> any PanelPresenting
