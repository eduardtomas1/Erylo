import EryloCore
import SwiftUI
import UniformTypeIdentifiers

public struct PanelSurfaceView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let model: PanelSurfaceModel

    @MainActor
    public init(model: PanelSurfaceModel) {
        self.model = model
    }

    public var body: some View {
        let layout = model.layout

        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous)
                .fill(Color(red: 6 / 255, green: 8 / 255, blue: 11 / 255))
                .overlay(alignment: .top) {
                    content
                        .frame(height: layout.surfaceFrame.height)
                }
                .frame(
                    width: layout.surfaceFrame.width,
                    height: layout.surfaceFrame.height,
                    alignment: .top
                )
                .offset(y: layout.surfaceTopInset)
                .contentShape(
                    RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous)
                )
                .onTapGesture {
                    model.send(.primaryAction)
                }
                .onHover { isHovering in
                    model.setPointerInside(isHovering)
                }
                .onDrop(
                    of: [UTType.fileURL.identifier],
                    isTargeted: dropTargetBinding,
                    perform: { _ in
                        // File transport belongs to a later feature branch.
                        false
                    }
                )
        }
        .frame(
            width: model.metrics.maximumSize.width,
            height: model.metrics.maximumSize.height,
            alignment: .top
        )
        .animation(animation, value: model.state)
        .onChange(of: reduceMotion, initial: true) { _, newValue in
            model.updateReduceMotion(newValue)
        }
        .onDisappear {
            model.cancelPendingInteractions()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Erylo activity surface")
    }

    private var dropTargetBinding: Binding<Bool> {
        Binding(
            get: { model.state == .dropTarget },
            set: { model.send($0 ? .dragEntered : .dragExited) }
        )
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch model.state {
            case .hidden:
                EmptyView()
            case .compact:
                statusLine(title: "Erylo", detail: nil)
            case .peek:
                statusLine(title: "Erylo", detail: "Activity surface spike")
            case .expanded:
                VStack(spacing: 10) {
                    statusLine(title: "Foundation", detail: "No providers enabled")
                    Text("Click to collapse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            case .dropTarget:
                statusLine(title: "Drop target", detail: "File transport is not implemented")
            }
        }
        .id(model.state)
        .transition(
            .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
        )
    }

    private func statusLine(title: String, detail: String?) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(red: 98 / 255, green: 242 / 255, blue: 193 / 255))
                .frame(width: 8, height: 8)
            Text(title)
                .font(.system(.body, design: .rounded, weight: .semibold))
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(Color(red: 244 / 255, green: 247 / 255, blue: 250 / 255))
        .padding(.horizontal, 16)
    }

    private var animation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.22, dampingFraction: 0.86)
    }
}
