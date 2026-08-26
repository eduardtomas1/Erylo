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
        let content = model.content
        let accessibility = model.accessibility

        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous)
                .fill(EryloPalette.ink)
                .contentShape(
                    RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous)
                )
                .onTapGesture {
                    model.send(.primaryAction)
                }
                .overlay {
                    if model.state == .dropTarget {
                        RoundedRectangle(cornerRadius: layout.cornerRadius - 3, style: .continuous)
                            .stroke(
                                EryloPalette.sky,
                                style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                            )
                            .padding(5)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .top) {
                    surfaceContent(content)
                        .frame(
                            width: layout.surfaceFrame.width,
                            height: layout.surfaceFrame.height
                        )
                        .clipped()
                }
                .frame(
                    width: layout.surfaceFrame.width,
                    height: layout.surfaceFrame.height,
                    alignment: .top
                )
                .offset(y: layout.surfaceTopInset)
                .onHover { isHovering in
                    model.setPointerInside(isHovering)
                }
                .onDrop(
                    of: [UTType.fileURL.identifier],
                    isTargeted: dropTargetBinding,
                    perform: { _ in
                        // The state is an honest affordance only; File Hold transport is not wired.
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
        .animation(animation, value: model.activityModel.snapshotVersion)
        .onChange(of: reduceMotion, initial: true) { _, newValue in
            model.updateReduceMotion(newValue)
        }
        .onDisappear {
            model.cancelPendingInteractions()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibility.label)
        .accessibilityValue(accessibility.value)
        .accessibilityHint(accessibility.hint)
    }

    private var dropTargetBinding: Binding<Bool> {
        Binding(
            get: { model.state == .dropTarget },
            set: { model.send($0 ? .dragEntered : .dragExited) }
        )
    }

    @ViewBuilder
    private func surfaceContent(_ content: ActivitySurfaceContent) -> some View {
        Group {
            switch content.primary {
            case .hidden:
                EmptyView()
            case let .activity(item):
                switch content.state {
                case .compact:
                    compactActivity(item)
                case .peek:
                    peekActivity(item)
                case .expanded:
                    expandedActivity(item, content: content)
                case .hidden, .dropTarget:
                    EmptyView()
                }
            case let .empty(title, detail):
                emptyContent(title: title, detail: detail, expanded: content.state == .expanded)
            case let .degraded(title, detail):
                degradedContent(title: title, detail: detail)
            case let .dropTarget(title, detail):
                dropTargetContent(title: title, detail: detail)
            }
        }
        .id(ContentIdentity(content: content))
        .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
    }

    private func compactActivity(_ item: ActivitySurfaceItem) -> some View {
        HStack(spacing: 9) {
            activitySymbol(item, size: 13)
            Text(item.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let progressValue = item.shortProgressValue {
                Text(progressValue)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(EryloPalette.mist)
            }
        }
        .foregroundStyle(EryloPalette.cloud)
        .padding(.horizontal, 15)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.accessibilitySummary)
        .accessibilitySortPriority(3)
    }

    private func peekActivity(_ item: ActivitySurfaceItem) -> some View {
        HStack(spacing: 11) {
            activitySymbol(item, size: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.kindLabel.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(accentColor(item.accent))
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(EryloPalette.cloud)
                    .lineLimit(1)
                if let detail = item.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(EryloPalette.mist)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let progressValue = item.shortProgressValue {
                Text(progressValue)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(EryloPalette.cloud)
            }
        }
        .padding(.horizontal, 17)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.accessibilitySummary)
        .accessibilitySortPriority(3)
    }

    private func expandedActivity(
        _ item: ActivitySurfaceItem,
        content: ActivitySurfaceContent
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                activitySymbol(item, size: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.kindLabel.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(accentColor(item.accent))
                    Text(item.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(EryloPalette.cloud)
                        .lineLimit(1)
                    if let detail = item.detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(EryloPalette.mist)
                            .lineLimit(2)
                    }
                    if let progress = item.progressFraction,
                       let progressValue = item.shortProgressValue {
                        HStack(spacing: 9) {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .tint(accentColor(item.accent))
                                .accessibilityHidden(true)
                            Text(progressValue)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(EryloPalette.mist)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, content.queue.items.isEmpty ? 10 : 11)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(item.accessibilitySummary)
            .accessibilitySortPriority(4)

            if !content.queue.items.isEmpty {
                Rectangle()
                    .fill(EryloPalette.graphite)
                    .frame(height: 1)
                    .accessibilityHidden(true)
                queueView(content.queue)
            }

            Spacer(minLength: 5)
            actionArea(content)
                .padding(.horizontal, 20)
                .padding(.bottom, 15)
        }
    }

    private func queueView(_ queue: ActivityQueueContext) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(SurfaceStrings.queueTitle.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(EryloPalette.mist)
                Spacer()
                if queue.remainingCount > 0 {
                    Text(SurfaceStrings.queueRemaining(queue.remainingCount))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(EryloPalette.mist)
                }
            }

            ForEach(queue.items, id: \.revision) { item in
                HStack(spacing: 7) {
                    Image(systemName: item.symbolName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(accentColor(item.accent))
                        .accessibilityHidden(true)
                    Text(item.kindLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(EryloPalette.mist)
                    Text(item.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(EryloPalette.cloud)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(item.accessibilitySummary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SurfaceStrings.queueTitle)
        .accessibilitySortPriority(2)
    }

    @ViewBuilder
    private func actionArea(_ content: ActivitySurfaceContent) -> some View {
        if let action = content.action {
            HStack(spacing: 10) {
                if let status = content.actionStatus {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(EryloPalette.coral)
                        .accessibilityHidden(true)
                    Text(status)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(EryloPalette.mist)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(action.label) {
                    model.activityModel.dispatch(action)
                }
                .buttonStyle(SurfaceActionButtonStyle())
                .disabled(model.activityModel.actionDispatchState == .inProgress)
                .accessibilityLabel(action.label)
                .accessibilityHint(SurfaceStrings.actionHint)
                .accessibilitySortPriority(1)
            }
        } else if let status = content.actionStatus {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(EryloPalette.coral)
                    .accessibilityHidden(true)
                Text(status)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(EryloPalette.mist)
                Spacer()
            }
        }
    }

    private func emptyContent(title: String, detail: String?, expanded: Bool) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(EryloPalette.mint)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: expanded ? 16 : 13, weight: .semibold))
                    .foregroundStyle(EryloPalette.cloud)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(EryloPalette.mist)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, expanded ? 20 : 15)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([title, detail].compactMap { $0 }.joined(separator: ", "))
    }

    private func degradedContent(title: String, detail: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(EryloPalette.amber)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(EryloPalette.cloud)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(EryloPalette.mist)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 17)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([title, detail].joined(separator: ", "))
    }

    private func dropTargetContent(title: String, detail: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(EryloPalette.sky)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(EryloPalette.cloud)
            Text(detail)
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundStyle(EryloPalette.mist)
                .frame(maxWidth: 330)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([title, detail].joined(separator: ", "))
    }

    private func activitySymbol(_ item: ActivitySurfaceItem, size: CGFloat) -> some View {
        Image(systemName: item.symbolName)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(accentColor(item.accent))
            .frame(width: size + 6, height: size + 6)
            .accessibilityHidden(true)
    }

    private func accentColor(_ accent: ActivityAccent) -> Color {
        switch accent {
        case .mint:
            EryloPalette.mint
        case .sky:
            EryloPalette.sky
        case .amber:
            EryloPalette.amber
        case .coral:
            EryloPalette.coral
        case .mist:
            EryloPalette.mist
        }
    }

    private var animation: Animation {
        model.motionStyle == .reduced
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.22, dampingFraction: 0.88)
    }
}

private struct ContentIdentity: Hashable {
    let state: PanelPresentationState
    let revision: UInt64?

    init(content: ActivitySurfaceContent) {
        state = content.state
        if case let .activity(item) = content.primary {
            revision = item.revision
        } else {
            revision = nil
        }
    }
}

private struct SurfaceActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(EryloPalette.ink)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(configuration.isPressed ? EryloPalette.cloud : EryloPalette.sky)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private enum EryloPalette {
    static let ink = Color(red: 6 / 255, green: 8 / 255, blue: 11 / 255)
    static let mint = Color(red: 98 / 255, green: 242 / 255, blue: 193 / 255)
    static let graphite = Color(red: 21 / 255, green: 26 / 255, blue: 33 / 255)
    static let sky = Color(red: 107 / 255, green: 155 / 255, blue: 255 / 255)
    static let cloud = Color(red: 244 / 255, green: 247 / 255, blue: 250 / 255)
    static let mist = Color(red: 152 / 255, green: 163 / 255, blue: 179 / 255)
    static let amber = Color(red: 255 / 255, green: 180 / 255, blue: 84 / 255)
    static let coral = Color(red: 255 / 255, green: 101 / 255, blue: 122 / 255)
}
