import AppKit
import EryloCore
import EryloSurface
import SwiftUI

@MainActor
final class PanelController: PanelPresenting {
    let directDisplayID: CGDirectDisplayID

    var displayIdentity: DisplayIdentity {
        DisplayIdentity(rawValue: directDisplayID)
    }

    private let panel: NonActivatingPanel
    private let rootView: PanelHitTestView
    private let model: PanelSurfaceModel
    private var isVisible = false

    init(
        snapshot: DisplaySnapshot,
        activityModel: SurfaceActivityModel,
        initialState: PanelPresentationState = .hidden
    ) {
        directDisplayID = CGDirectDisplayID(snapshot.identity.rawValue)
        model = PanelSurfaceModel(
            displayGeometry: snapshot.geometry,
            initialState: initialState,
            activityModel: activityModel
        )
        let layout = model.layout

        panel = NonActivatingPanel(
            contentRect: layout.fixedFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        rootView = PanelHitTestView(frame: CGRect(origin: .zero, size: layout.fixedFrame.size))

        configurePanel()
        installSurface()
        refreshLayout()
        model.didChange = { [weak self] in
            self?.refreshLayout()
        }
    }

    func show() {
        isVisible = true
        panel.orderFrontRegardless()
        updatePointer(screenPoint: NSEvent.mouseLocation)
    }

    func close() {
        isVisible = false
        model.cancelPendingInteractions()
        panel.ignoresMouseEvents = true
        panel.close()
    }

    func hide() {
        isVisible = false
        model.cancelPendingInteractions()
        panel.ignoresMouseEvents = true
        panel.orderOut(nil)
    }

    func update(snapshot: DisplaySnapshot) {
        model.update(displayGeometry: snapshot.geometry)
    }

    func updatePointer(screenPoint: CGPoint) {
        guard isVisible else {
            panel.ignoresMouseEvents = true
            return
        }
        let localPoint = panel.convertPoint(fromScreen: screenPoint)
        let pointerDisposition = model.pointerDisposition(at: localPoint)
        panel.ignoresMouseEvents = !pointerDisposition.acceptsMouseEvents
        model.setPointerInside(pointerDisposition.isInsideTargetSurface)
    }

    func performPrimaryAction() {
        model.send(.primaryAction)
    }

    func cancelPendingInteractions() {
        model.cancelPendingInteractions()
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
    }

    private func installSurface() {
        let hostingView = NSHostingView(rootView: PanelSurfaceView(model: model))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: rootView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])
        panel.contentView = rootView
    }

    private func refreshLayout() {
        let layout = model.layout
        panel.setFrame(layout.fixedFrame, display: true, animate: false)
        rootView.frame = CGRect(origin: .zero, size: layout.fixedFrame.size)
        rootView.hitRegion = model.interactionHitRegion
        if isVisible {
            updatePointer(screenPoint: NSEvent.mouseLocation)
        }
    }
}
