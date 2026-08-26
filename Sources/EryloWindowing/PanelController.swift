import AppKit
import EryloCore
import EryloSurface
import SwiftUI

@MainActor
final class PanelController {
    let directDisplayID: CGDirectDisplayID

    private let panel: NonActivatingPanel
    private let rootView: PanelHitTestView
    private let model: PanelSurfaceModel

    init(snapshot: DisplaySnapshot) {
        directDisplayID = CGDirectDisplayID(snapshot.identity.rawValue)
        model = PanelSurfaceModel(displayGeometry: snapshot.geometry)
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
        panel.orderFrontRegardless()
    }

    func close() {
        panel.close()
    }

    func update(snapshot: DisplaySnapshot) {
        model.update(displayGeometry: snapshot.geometry)
    }

    func updatePointer(screenPoint: CGPoint) {
        let localPoint = panel.convertPoint(fromScreen: screenPoint)
        let isInteractive = model.layout.hitRegion.contains(localPoint)
        panel.ignoresMouseEvents = !isInteractive

        if !isInteractive, model.state == .peek {
            model.send(.hoverEnded)
        }
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
        rootView.hitRegion = layout.hitRegion
        updatePointer(screenPoint: NSEvent.mouseLocation)
    }
}
