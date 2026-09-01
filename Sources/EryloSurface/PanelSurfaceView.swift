import EryloActivity
import EryloCore
import SwiftUI

public struct PanelSurfaceView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var continuityNamespace
    @FocusState private var focusedControl: PanelFocusableControl?

    private let model: PanelSurfaceModel

    @MainActor
    public init(model: PanelSurfaceModel) {
        self.model = model
    }

    @ViewBuilder
    public var body: some View {
        let content = model.content
        if model.isTemporalProjectionActive,
           case let .activity(item) = content.primary,
           let temporalProjection = item.temporalProjection {
            TemporalProjectionView(projection: temporalProjection) { snapshot in
                surface(
                    content: content,
                    temporalSnapshot: snapshot,
                    accessibility: PanelSurfaceAccessibility(
                        content: content,
                        temporalSnapshot: snapshot
                    )
                )
            }
        } else {
            surface(
                content: content,
                temporalSnapshot: nil,
                accessibility: model.accessibility
            )
        }
    }

    private func surface(
        content: ActivitySurfaceContent,
        temporalSnapshot: ActivitySurfaceTemporalSnapshot?,
        accessibility: PanelSurfaceAccessibility
    ) -> some View {
        let layout = model.layout
        let silhouette = TopEdgeSurfaceShape(
            attachment: layout.attachment,
            topCornerRadius: layout.topCornerRadius,
            lowerCornerRadius: layout.cornerRadius
        )
        let contentHeight = max(
            layout.surfaceFrame.height - layout.surfaceContentTopInset,
            0
        )
        let acceptsBackgroundTap = model.acceptsBackgroundTap
        let notchlessShadowOpacity = colorScheme == .light
            ? PanelSurfaceVisualMetrics.notchlessLightShadowOpacity
            : PanelSurfaceVisualMetrics.notchlessDarkShadowOpacity
        let notchlessShadowRadius = colorScheme == .light
            ? PanelSurfaceVisualMetrics.notchlessLightShadowRadius
            : PanelSurfaceVisualMetrics.notchlessDarkShadowRadius
        let notchlessShadowOffsetY = colorScheme == .light
            ? PanelSurfaceVisualMetrics.notchlessLightShadowOffsetY
            : PanelSurfaceVisualMetrics.notchlessDarkShadowOffsetY
        let presentationTransitionKey = SurfacePresentationTransitionKey(content: content)
        let currentSnapshotVersion = model.activityModel.snapshotVersion
        let currentActivityIdentity = model.activityModel.current?.activity.identity
        let isIdentityHandoff = model.activityModel.handoff.map { handoff in
            handoff.snapshotVersion == currentSnapshotVersion
                && handoff.to == currentActivityIdentity
        } ?? false

        return ZStack(alignment: .top) {
            if model.isWindowPresented, model.renderedState != .dropTarget {
                surfaceBackground(
                    silhouette,
                    attachment: layout.attachment
                )
                    .accessibilityHidden(true)

                if layout.attachment == .notchIntegrated,
                   model.renderedState == .compact,
                   !content.showsFocusTimerLauncher {
                    transitioningContent(
                        key: presentationTransitionKey,
                        isIdentityHandoff: isIdentityHandoff
                    ) {
                        notchCompactContent(
                            content,
                            temporalSnapshot: temporalSnapshot,
                            surfaceWidth: layout.surfaceFrame.width,
                            surfaceHeight: layout.surfaceFrame.height,
                            occlusionWidth: model.displayGeometry.topEdgeOcclusion?.frame.width ?? 0
                        )
                    }
                    .opacity(
                        model.acceptsPointerInteraction
                            ? (model.isPointerInside ? 1 : 0.9)
                            : 1
                    )
                    .animation(
                        model.motionStyle.allowsHoverOpacityAnimation
                            ? .easeOut(duration: 0.12)
                            : nil,
                        value: model.isPointerInside
                    )
                } else {
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: layout.surfaceContentTopInset)
                            .accessibilityHidden(true)
                        transitioningContent(
                            key: presentationTransitionKey,
                            isIdentityHandoff: isIdentityHandoff
                        ) {
                            surfaceContent(content, temporalSnapshot: temporalSnapshot)
                        }
                            .frame(
                                width: layout.surfaceFrame.width,
                                height: contentHeight
                            )
                            .clipped()
                    }
                    .frame(
                        width: layout.surfaceFrame.width,
                        height: layout.surfaceFrame.height,
                        alignment: .top
                    )
                }
            }
        }
        .frame(
            width: layout.surfaceFrame.width,
            height: layout.surfaceFrame.height,
            alignment: .top
        )
        .clipShape(silhouette)
        .contentShape(silhouette)
        .onTapGesture {
            guard acceptsBackgroundTap else { return }
            model.send(.primaryAction)
        }
        .overlay {
            if model.renderedState != .dropTarget,
               layout.attachment == .notchlessPill {
                silhouette
                    .stroke(EryloPalette.cloud.opacity(0.1), lineWidth: 0.5)
                    .accessibilityHidden(true)
            }
        }
        .shadow(
            color: layout.attachment == .notchlessPill
                ? Color.black.opacity(notchlessShadowOpacity)
                : .clear,
            radius: notchlessShadowRadius,
            y: notchlessShadowOffsetY
        )
        .offset(y: layout.surfaceTopInset)
        .frame(
            width: model.metrics.maximumSize.width,
            height: model.metrics.maximumSize.height,
            alignment: .top
        )
        .animation(surfaceAnimation, value: model.geometryAnimationKey)
        .onChange(of: reduceMotion, initial: true) { _, newValue in
            model.updateReduceMotion(newValue)
        }
        .onChange(of: model.deliberateControlFocusRequest) { _, request in
            focusedControl = request?.control
        }
        .onDisappear {
            model.cancelPendingInteractions()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibility.label)
        .accessibilityValue(accessibility.value)
        .accessibilityHint(accessibility.hint)
        .accessibilityIdentifier("erylo.activity-surface")
        .accessibilityActions {
            if let surfaceAction = model.accessibilitySurfaceAction {
                Button(surfaceAction.label) {
                    model.performAccessibilitySurfaceAction()
                }
            }
        }
    }

    @ViewBuilder
    private func surfaceBackground(
        _ silhouette: TopEdgeSurfaceShape,
        attachment: PanelAttachment
    ) -> some View {
        switch attachment {
        case .notchIntegrated:
            silhouette.fill(Color.black)
        case .notchlessPill:
            if reduceTransparency {
                silhouette.fill(EryloPalette.ink)
            } else {
                silhouette
                    .fill(.ultraThinMaterial)
                    .overlay {
                        silhouette.fill(EryloPalette.ink.opacity(0.68))
                    }
            }
        }
    }

    private func notchCompactContent(
        _ content: ActivitySurfaceContent,
        temporalSnapshot: ActivitySurfaceTemporalSnapshot?,
        surfaceWidth: CGFloat,
        surfaceHeight: CGFloat,
        occlusionWidth: CGFloat
    ) -> some View {
        let resolvedOcclusionWidth = min(max(occlusionWidth, 0), surfaceWidth)
        let wingWidth = max((surfaceWidth - resolvedOcclusionWidth) / 2, 0)
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                notchCompactLeading(content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, PanelSurfaceVisualMetrics.notchWingOuterPadding)
                    .padding(.trailing, PanelSurfaceVisualMetrics.notchWingCameraClearance)
                    .frame(width: wingWidth)
                    .clipped()
                Color.clear
                    .frame(width: resolvedOcclusionWidth)
                    .accessibilityHidden(true)
                notchCompactTrailing(content, temporalSnapshot: temporalSnapshot)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.leading, PanelSurfaceVisualMetrics.notchWingCameraClearance)
                    .padding(.trailing, PanelSurfaceVisualMetrics.notchWingOuterPadding)
                    .frame(width: wingWidth)
                    .clipped()
            }
            .frame(height: 14)
            notchCompactSignalLine(content, temporalSnapshot: temporalSnapshot)
                .frame(height: 2)
        }
        .frame(width: surfaceWidth, height: surfaceHeight)
        .clipped()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func notchCompactLeading(_ content: ActivitySurfaceContent) -> some View {
        switch content.primary {
        case let .activity(item):
            activitySymbol(item, size: 11)
        case .degraded:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(EryloPalette.amber)
        case .empty:
            Text(SurfaceStrings.compactQuietTitle)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(EryloPalette.cloud)
        case .hidden, .dropTarget:
            EmptyView()
        }
    }

    @ViewBuilder
    private func notchCompactTrailing(
        _ content: ActivitySurfaceContent,
        temporalSnapshot: ActivitySurfaceTemporalSnapshot?
    ) -> some View {
        switch content.primary {
        case let .activity(item):
            if let notchCompactValue = item.notchCompactValue {
                principalValue(
                    notchCompactValue,
                    item: item,
                    size: 9,
                    weight: .medium,
                    numeric: usesNumericTransition(item)
                )
            } else if let temporalSnapshot {
                principalValue(
                    temporalSnapshot.remainingText,
                    item: item,
                    size: 9,
                    weight: .medium,
                    countsDown: true,
                    numeric: true
                )
            } else if item.composition == .standard {
                principalValue(
                    item.title,
                    item: item,
                    size: 10,
                    weight: .medium
                )
            } else {
                principalValue(
                    item.kind == .timer
                        ? item.detail ?? item.shortProgressValue ?? item.kindLabel
                        : item.shortProgressValue ?? item.kindLabel,
                    item: item,
                    size: 9,
                    weight: .medium,
                    countsDown: item.kind == .timer,
                    numeric: usesNumericTransition(item)
                )
            }
        case .degraded:
            Text(SurfaceStrings.compactPaused)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(EryloPalette.mist)
        case .empty:
            Text(SurfaceStrings.compactReady)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(EryloPalette.mist)
        case .hidden, .dropTarget:
            EmptyView()
        }
    }

    @ViewBuilder
    private func notchCompactSignalLine(
        _ content: ActivitySurfaceContent,
        temporalSnapshot: ActivitySurfaceTemporalSnapshot?
    ) -> some View {
        if case let .activity(item) = content.primary,
           item.hasSemanticProgress {
            activitySignalLine(
                item,
                temporalSnapshot: temporalSnapshot,
                height: 1.5
            )
                .padding(.horizontal, 8)
        } else {
            Color.clear.accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func surfaceContent(
        _ content: ActivitySurfaceContent,
        temporalSnapshot: ActivitySurfaceTemporalSnapshot?
    ) -> some View {
        Group {
            switch content.primary {
            case .hidden:
                EmptyView()
            case let .activity(item):
                switch content.state {
                case .compact:
                    compactActivity(
                        item,
                        content: content,
                        temporalSnapshot: temporalSnapshot
                    )
                case .peek:
                    peekActivity(
                        item,
                        content: content,
                        temporalSnapshot: temporalSnapshot
                    )
                case .expanded:
                    expandedActivity(
                        item,
                        content: content,
                        temporalSnapshot: temporalSnapshot
                    )
                case .hidden, .dropTarget:
                    EmptyView()
                }
            case let .empty(title, detail):
                if content.showsFocusTimerLauncher {
                    focusTimerLauncher()
                } else {
                    emptyContent(title: title, detail: detail, expanded: content.state == .expanded)
                }
            case let .degraded(title, detail):
                degradedContent(title: title, detail: detail)
            case .dropTarget:
                EmptyView()
            }
        }
    }

    private func focusTimerLauncher() -> some View {
        HStack(spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "timer")
                    .font(.system(size: 11, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(EryloPalette.amber)
                    .accessibilityHidden(true)
                Text(SurfaceStrings.focusTimerLauncherTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(EryloPalette.cloud)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            HStack(spacing: PanelSurfaceVisualMetrics.focusTimerPresetSpacing) {
                ForEach([15, 25, 50], id: \.self) { minutes in
                    Button("\(minutes)m") {
                        model.startFocusTimer(minutes: minutes)
                    }
                    .buttonStyle(
                        FocusTimerPresetButtonStyle(
                            reduceMotion: model.motionStyle == .reduced
                        )
                    )
                    .accessibilityLabel("Start \(minutes)-minute Focus Timer")
                    .accessibilityHint(SurfaceStrings.focusTimerLauncherHint)
                    .accessibilityIdentifier("erylo.focus-timer.launcher-\(minutes)")
                    .focused($focusedControl, equals: .focusTimerPreset(minutes))
                }
            }
            .opacity(model.isHitRegionSettled ? 1 : 0)
            .allowsHitTesting(model.isHitRegionSettled)
            .accessibilityHidden(!model.isHitRegionSettled)
            .animation(
                model.motionStyle == .reduced ? nil : .easeOut(duration: 0.10),
                value: model.isHitRegionSettled
            )
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SurfaceStrings.focusTimerLauncherTitle)
        .accessibilityHint(SurfaceStrings.focusTimerLauncherHint)
    }

    @ViewBuilder
    private func compactActivity(
        _ item: ActivitySurfaceItem,
        content: ActivitySurfaceContent,
        temporalSnapshot: ActivitySurfaceTemporalSnapshot?
    ) -> some View {
        switch item.composition {
        case .timerCountdown, .volumeLevel, .volumeMuted, .volumeUnmuted,
             .volumeOutput, .battery, .charging:
            compactSignalActivity(item, temporalSnapshot: temporalSnapshot)
        case .timerCompletion:
            completionActivity(item, content: content, expanded: false)
        case .standard:
            compactStandardActivity(item)
        }
    }

    private func compactSignalActivity(
        _ item: ActivitySurfaceItem,
        temporalSnapshot: ActivitySurfaceTemporalSnapshot?
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                activitySymbol(item, size: 13)
                Spacer(minLength: 10)
                projectedPrincipalValue(
                    item,
                    temporalSnapshot: temporalSnapshot,
                    size: 12,
                    weight: .semibold
                )
            }
            .padding(.horizontal, 15)
            .frame(maxHeight: .infinity)
            if item.hasSemanticProgress {
                activitySignalLine(
                    item,
                    temporalSnapshot: temporalSnapshot,
                    height: 1.5
                )
                    .padding(.horizontal, 12)
                    .frame(height: 2)
            }
        }
        .foregroundStyle(EryloPalette.cloud)
        .modifier(
            SignalActivityAccessibilityModifier(
                staticSummary: temporalSnapshot == nil ? item.accessibilitySummary : nil
            )
        )
        .accessibilitySortPriority(3)
    }

    private func compactStandardActivity(_ item: ActivitySurfaceItem) -> some View {
        HStack(spacing: 9) {
            activitySymbol(item, size: 13)
            Text(item.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let value = item.shortProgressValue {
                principalValue(
                    value,
                    item: item,
                    size: 11,
                    weight: .medium,
                    numeric: true
                )
            }
        }
        .foregroundStyle(EryloPalette.cloud)
        .padding(.horizontal, 15)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.accessibilitySummary)
        .accessibilitySortPriority(3)
    }

    @ViewBuilder
    private func peekActivity(
        _ item: ActivitySurfaceItem,
        content: ActivitySurfaceContent,
        temporalSnapshot: ActivitySurfaceTemporalSnapshot?
    ) -> some View {
        switch item.composition {
        case .timerCompletion:
            completionActivity(item, content: content, expanded: false)
        case .timerCountdown, .volumeLevel, .volumeMuted, .volumeUnmuted,
             .volumeOutput, .battery, .charging:
            compactSignalActivity(item, temporalSnapshot: temporalSnapshot)
        case .standard:
            peekStandardActivity(item, temporalSnapshot: temporalSnapshot)
        }
    }

    private func peekStandardActivity(
        _ item: ActivitySurfaceItem,
        temporalSnapshot: ActivitySurfaceTemporalSnapshot?
    ) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 9) {
                activitySymbol(item, size: 12)
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(EryloPalette.cloud)
                    .lineLimit(1)
                Spacer(minLength: 0)
                projectedDetail(
                    item,
                    temporalSnapshot: temporalSnapshot,
                    fontSize: 10
                )
            }
            projectedProgressTrack(
                item,
                temporalSnapshot: temporalSnapshot,
                height: 1.5
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.accessibilitySummary)
        .accessibilitySortPriority(3)
    }

    @ViewBuilder
    private func expandedActivity(
        _ item: ActivitySurfaceItem,
        content: ActivitySurfaceContent,
        temporalSnapshot: ActivitySurfaceTemporalSnapshot?
    ) -> some View {
        switch item.composition {
        case .timerCountdown:
            expandedTimer(
                item,
                content: content,
                temporalSnapshot: temporalSnapshot
            )
        case .timerCompletion:
            completionActivity(item, content: content, expanded: true)
        case .volumeLevel, .volumeMuted, .volumeUnmuted, .volumeOutput:
            expandedVolume(item)
        case .battery, .charging:
            expandedPower(item)
        case .standard:
            expandedStandardActivity(
                item,
                content: content,
                temporalSnapshot: temporalSnapshot
            )
        }
    }

    private func expandedTimer(
        _ item: ActivitySurfaceItem,
        content: ActivitySurfaceContent,
        temporalSnapshot: ActivitySurfaceTemporalSnapshot?
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(EryloPalette.mist)
                        .lineLimit(1)
                    projectedPrincipalValue(
                        item,
                        temporalSnapshot: temporalSnapshot,
                        size: 46,
                        weight: .medium,
                        color: EryloPalette.cloud
                    )
                }
                .accessibilityHidden(temporalSnapshot != nil)
                Spacer(minLength: 8)
                timerActionArea(content)
            }
            .padding(.horizontal, 22)
            .padding(.top, 7)

            Spacer(minLength: 6)

            activitySignalLine(
                item,
                temporalSnapshot: temporalSnapshot,
                height: 3
            )
                .padding(.horizontal, 22)
                .padding(.bottom, 11)
        }
        .accessibilityElement(children: .contain)
        .accessibilitySortPriority(4)
    }

    private func expandedVolume(_ item: ActivitySurfaceItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                activitySymbol(item, size: 25)
                VStack(alignment: .leading, spacing: 1) {
                    Text(volumeContextLabel(item))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(EryloPalette.mist)
                        .lineLimit(1)
                    projectedPrincipalValue(
                        item,
                        size: item.composition == .volumeOutput ? 21 : 34,
                        weight: item.composition == .volumeOutput ? .semibold : .medium,
                        color: EryloPalette.cloud
                    )
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 13)

            Spacer(minLength: 8)

            if item.hasSemanticProgress {
                activitySignalLine(item, height: 3)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.accessibilitySummary)
        .accessibilitySortPriority(4)
    }

    private func expandedPower(_ item: ActivitySurfaceItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                activitySymbol(item, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(EryloPalette.mist)
                        .lineLimit(1)
                    projectedPrincipalValue(
                        item,
                        size: 42,
                        weight: .medium,
                        color: EryloPalette.cloud
                    )
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)

            Spacer(minLength: 7)

            if item.hasSemanticProgress {
                activitySignalLine(item, height: 3)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.accessibilitySummary)
        .accessibilitySortPriority(4)
    }

    private func completionActivity(
        _ item: ActivitySurfaceItem,
        content: ActivitySurfaceContent,
        expanded: Bool
    ) -> some View {
        HStack(spacing: expanded ? 14 : 9) {
            activitySymbol(item, size: expanded ? 26 : 13)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: expanded ? 21 : 14, weight: .semibold))
                    .foregroundStyle(EryloPalette.cloud)
                    .lineLimit(1)
                if expanded {
                    Text(SurfaceStrings.focusTimerCompletionDetail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(EryloPalette.mist)
                }
            }
            Spacer(minLength: 0)
            if let action = content.action {
                Button(action.label) {
                    model.activityModel.dispatch(action)
                }
                .buttonStyle(
                    SurfaceActionButtonStyle(
                        tint: EryloPalette.mint,
                        reduceMotion: model.motionStyle == .reduced
                    )
                )
                .disabled(model.activityModel.actionDispatchState == .inProgress)
                .opacity(model.isHitRegionSettled ? 1 : 0)
                .allowsHitTesting(model.isHitRegionSettled)
                .accessibilityHidden(!model.isHitRegionSettled)
                .animation(
                    model.motionStyle == .reduced ? nil : .easeOut(duration: 0.10),
                    value: model.isHitRegionSettled
                )
                .accessibilityLabel(action.label)
                .accessibilityHint(SurfaceStrings.dismissCompletionHint)
                .accessibilityIdentifier("erylo.focus-timer.completion-done")
                .accessibilitySortPriority(1)
                .focused($focusedControl, equals: .completionDone)
            }
        }
        .padding(.horizontal, expanded ? 22 : 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.accessibilitySummary)
        .accessibilitySortPriority(4)
    }

    private func expandedStandardActivity(
        _ item: ActivitySurfaceItem,
        content: ActivitySurfaceContent,
        temporalSnapshot: ActivitySurfaceTemporalSnapshot?
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                activitySymbol(item, size: 19)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.kindLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(accentColor(item.accent))
                    Text(item.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(EryloPalette.cloud)
                        .lineLimit(1)
                    projectedDetail(
                        item,
                        temporalSnapshot: temporalSnapshot,
                        fontSize: 12
                    )
                    projectedProgressTrack(
                        item,
                        temporalSnapshot: temporalSnapshot,
                        height: 2.5
                    )
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 19)
            .padding(.top, 14)
            .padding(.bottom, content.queue.items.isEmpty ? 8 : 10)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(item.accessibilitySummary)
            .accessibilitySortPriority(4)

            if !content.queue.items.isEmpty {
                Rectangle()
                    .fill(EryloPalette.cloud.opacity(0.08))
                    .frame(height: 1)
                    .accessibilityHidden(true)
                queueView(content.queue)
            }

            Spacer(minLength: 4)
            actionArea(content)
                .frame(maxWidth: .infinity)
                .padding(.leading, PanelSurfaceVisualMetrics.expandedActionLeadingInset)
                .padding(
                    .trailing,
                    content.queue.items.isEmpty
                        ? PanelSurfaceVisualMetrics.expandedActionLeadingInset
                        : PanelSurfaceVisualMetrics.expandedActionTrailingInset
                )
                .padding(.bottom, 14)
        }
    }

    @ViewBuilder
    private func projectedPrincipalValue(
        _ item: ActivitySurfaceItem,
        temporalSnapshot: ActivitySurfaceTemporalSnapshot? = nil,
        size: CGFloat,
        weight: Font.Weight,
        color: Color = EryloPalette.mist
    ) -> some View {
        if let temporalSnapshot {
            principalValue(
                temporalSnapshot.remainingText,
                item: item,
                size: size,
                weight: weight,
                countsDown: true,
                numeric: true,
                color: color
            )
        } else if let value = item.signalPrincipalValue {
            principalValue(
                value,
                item: item,
                size: size,
                weight: weight,
                countsDown: item.composition == .timerCountdown,
                numeric: usesNumericTransition(item),
                color: color
            )
        }
    }

    @ViewBuilder
    private func principalValue(
        _ value: String,
        item: ActivitySurfaceItem,
        size: CGFloat,
        weight: Font.Weight,
        countsDown: Bool = false,
        numeric: Bool = false,
        color: Color = EryloPalette.mist
    ) -> some View {
        Group {
            if numeric, model.motionStyle == .standard {
                Text(value)
                    .contentTransition(.numericText(countsDown: countsDown))
                    .animation(.easeOut(duration: 0.16), value: value)
            } else {
                Text(value)
            }
        }
        .font(.system(size: size, weight: weight))
        .monospacedDigit()
        .foregroundStyle(color)
        .lineLimit(1)
        .minimumScaleFactor(0.9)
        .truncationMode(.tail)
        .accessibilityHidden(true)
        .matchedGeometryEffect(
            id: SignalContinuityID(identity: item.identity, element: .value),
            in: continuityNamespace
        )
    }

    private func usesNumericTransition(_ item: ActivitySurfaceItem) -> Bool {
        switch item.composition {
        case .timerCountdown, .volumeLevel, .volumeUnmuted, .battery, .charging:
            true
        case .timerCompletion, .volumeMuted, .volumeOutput, .standard:
            false
        }
    }

    private func volumeContextLabel(_ item: ActivitySurfaceItem) -> String {
        item.composition == .volumeOutput
            ? item.detail ?? SurfaceStrings.volumeOutputChanged
            : SurfaceStrings.volumeKind
    }

    @ViewBuilder
    private func activitySignalLine(
        _ item: ActivitySurfaceItem,
        temporalSnapshot: ActivitySurfaceTemporalSnapshot? = nil,
        height: CGFloat
    ) -> some View {
        if let temporalSnapshot {
            SurfaceSignalLine(
                progress: temporalSnapshot.fractionCompleted,
                tint: accentColor(item.accent),
                height: height
            )
        } else if let progress = item.progressFraction {
            SurfaceSignalLine(
                progress: progress,
                tint: accentColor(item.accent),
                height: height
            )
        }
    }

    @ViewBuilder
    private func timerActionArea(_ content: ActivitySurfaceContent) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            if let action = content.action {
                Button(role: .cancel) {
                    model.activityModel.dispatch(action)
                } label: {
                    Label(action.label, systemImage: "xmark")
                }
                .buttonStyle(
                    QuietSurfaceActionButtonStyle(
                        reduceMotion: model.motionStyle == .reduced
                    )
                )
                .disabled(model.activityModel.actionDispatchState == .inProgress)
                .opacity(model.isHitRegionSettled ? 1 : 0)
                .allowsHitTesting(model.isHitRegionSettled)
                .accessibilityHidden(!model.isHitRegionSettled)
                .animation(
                    model.motionStyle == .reduced ? nil : .easeOut(duration: 0.10),
                    value: model.isHitRegionSettled
                )
                .accessibilityLabel(action.label)
                .accessibilityHint(SurfaceStrings.actionHint(for: action.intent))
                .accessibilitySortPriority(1)
            }
            if let status = content.actionStatus {
                Text(status)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(EryloPalette.mist)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func projectedDetail(
        _ item: ActivitySurfaceItem,
        temporalSnapshot: ActivitySurfaceTemporalSnapshot? = nil,
        fontSize: CGFloat
    ) -> some View {
        if let temporalSnapshot {
            Text(SurfaceStrings.remainingTime(temporalSnapshot.remainingText))
                .font(.system(size: fontSize, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(EryloPalette.mist)
                .lineLimit(1)
                .accessibilityHidden(true)
        } else if let value = item.detail ?? item.shortProgressValue {
            Text(value)
                .font(.system(size: fontSize, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(EryloPalette.mist)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private func projectedProgressTrack(
        _ item: ActivitySurfaceItem,
        temporalSnapshot: ActivitySurfaceTemporalSnapshot? = nil,
        height: CGFloat
    ) -> some View {
        if let temporalSnapshot {
            SurfaceSignalLine(
                progress: temporalSnapshot.fractionCompleted,
                tint: accentColor(item.accent),
                height: height
            )
        } else if let progress = item.progressFraction {
            SurfaceSignalLine(
                progress: progress,
                tint: accentColor(item.accent),
                height: height
            )
        }
    }

    private func queueView(_ queue: ActivityQueueContext) -> some View {
        let visibleItems = Array(queue.items.prefix(1))
        let remainingCount = queue.remainingCount + max(queue.items.count - visibleItems.count, 0)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(SurfaceStrings.queueTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(EryloPalette.mist)
                Spacer()
                if remainingCount > 0 {
                    Text(SurfaceStrings.queueRemaining(remainingCount))
                        .font(.system(size: 9, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(EryloPalette.mist)
                }
            }

            ForEach(visibleItems, id: \.revision) { item in
                HStack(spacing: 7) {
                    Image(systemName: item.symbolName)
                        .font(.system(size: 9, weight: .semibold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(accentColor(item.semanticSymbolAccent))
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
                    actionStatusIcon
                    Text(status)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(EryloPalette.mist)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(action.label) {
                    model.activityModel.dispatch(action)
                }
                .buttonStyle(
                    SurfaceActionButtonStyle(
                        tint: actionColor(action),
                        reduceMotion: model.motionStyle == .reduced
                    )
                )
                .disabled(model.activityModel.actionDispatchState == .inProgress)
                .opacity(model.isHitRegionSettled ? 1 : 0)
                .allowsHitTesting(model.isHitRegionSettled)
                .accessibilityHidden(!model.isHitRegionSettled)
                .animation(
                    model.motionStyle == .reduced ? nil : .easeOut(duration: 0.10),
                    value: model.isHitRegionSettled
                )
                .accessibilityLabel(action.label)
                .accessibilityHint(SurfaceStrings.actionHint(for: action.intent))
                .accessibilitySortPriority(1)
            }
        } else if let status = content.actionStatus {
            HStack(spacing: 7) {
                actionStatusIcon
                Text(status)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(EryloPalette.mist)
                Spacer()
            }
        }
    }

    private func emptyContent(title: String, detail: String?, expanded: Bool) -> some View {
        HStack(spacing: expanded ? 16 : 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: expanded ? 14 : 12, weight: .semibold))
                    .foregroundStyle(EryloPalette.cloud)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(EryloPalette.mist)
                }
            }
            if expanded {
                Text(SurfaceStrings.primaryShortcutKey)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(EryloPalette.mist)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(EryloPalette.graphite, in: Capsule(style: .continuous))
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, expanded ? 16 : 14)
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

    private func activitySymbol(_ item: ActivitySurfaceItem, size: CGFloat) -> some View {
        Image(systemName: item.symbolName)
            .font(.system(size: size, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(accentColor(item.semanticSymbolAccent))
            .frame(width: size + 6, height: size + 6)
            .matchedGeometryEffect(
                id: SignalContinuityID(identity: item.identity, element: .symbol),
                in: continuityNamespace
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var actionStatusIcon: some View {
        if model.activityModel.actionDispatchState == .inProgress {
            ProgressView()
                .controlSize(.small)
                .tint(EryloPalette.mist)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(EryloPalette.coral)
                .accessibilityHidden(true)
        }
    }

    private func actionColor(_ action: SurfaceActivityAction) -> Color {
        switch action.intent {
        case .cancel, .dismiss:
            // Cancel and dismiss are routine, reversible session controls. Keep
            // them visually secondary; Coral remains reserved for a real
            // actionable failure or an activity's own reviewed accent.
            .secondary
        case .pause, .resume, .openSource, .togglePlayback:
            EryloPalette.sky
        }
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

    private var surfaceAnimation: Animation? {
        model.motionStyle == .reduced
            ? nil
            : .smooth(duration: 0.22, extraBounce: 0)
    }

    private var handoffAnimation: Animation? {
        reduceMotion || model.motionStyle == .reduced
            ? nil
            : .easeOut(duration: 0.16)
    }

    /// Keeps true activity handoffs inside one bounded transition host. Same-
    /// identity revisions retain one subtree so their matched-geometry sources
    /// remain unique and numeric/content transitions can update in place.
    private func transitioningContent<Content: View>(
        key: SurfacePresentationTransitionKey,
        isIdentityHandoff: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            content()
                .id(key)
                .transition(handoffTransition(isIdentityHandoff: isIdentityHandoff))
        }
        .animation(handoffAnimation, value: key)
    }

    private func handoffTransition(isIdentityHandoff: Bool) -> AnyTransition {
        guard !reduceMotion, model.motionStyle != .reduced else { return .identity }
        guard isIdentityHandoff else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.985, anchor: .center)),
            removal: .opacity
        )
    }

}

/// One continuous top-edge silhouette. On a notched display, small concave
/// outer curls make the bezel flow into the body; notchless screens use a
/// conventional rounded capsule/card.
private struct TopEdgeSurfaceShape: Shape {
    let attachment: PanelAttachment
    var topCornerRadius: CGFloat
    var lowerCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get {
            AnimatablePair(topCornerRadius, lowerCornerRadius)
        }
        set {
            topCornerRadius = newValue.first
            lowerCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        guard attachment == .notchIntegrated else {
            var rounded = Path()
            let radius = min(
                max(lowerCornerRadius, 0),
                min(rect.width, rect.height) / 2
            )
            rounded.addRoundedRect(
                in: rect,
                cornerSize: CGSize(width: radius, height: radius),
                style: .continuous
            )
            return rounded
        }

        let topRadius = min(
            max(topCornerRadius, 0),
            min(rect.width / 4, rect.height / 4)
        )
        let bottomRadius = min(
            max(lowerCornerRadius, 0),
            min((rect.width - topRadius * 2) / 2, rect.height - topRadius)
        )
        let leftWall = rect.minX + topRadius
        let rightWall = rect.maxX - topRadius

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: leftWall, y: rect.minY + topRadius),
            control: CGPoint(x: leftWall, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: leftWall, y: rect.maxY - bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: leftWall + bottomRadius, y: rect.maxY),
            control: CGPoint(x: leftWall, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rightWall - bottomRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rightWall, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rightWall, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rightWall, y: rect.minY + topRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rightWall, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

private struct SignalContinuityID: Hashable {
    enum Element: Hashable {
        case symbol
        case value
    }

    let identity: ActivityIdentity
    let element: Element
}

/// The view identity is deliberately presentation-based rather than geometry-
/// based. Expanding one activity preserves matched geometry, while broker
/// true activity handoffs receive one short content transition. Revisions keep
/// one identity so SwiftUI never hosts duplicate matched-geometry sources.
private enum SurfacePresentationTransitionKey: Hashable {
    case activity(ActivityIdentity)
    case focusTimerLauncher
    case empty
    case degraded
    case hidden

    init(content: ActivitySurfaceContent) {
        switch content.primary {
        case let .activity(item):
            self = .activity(item.identity)
        case .empty where content.showsFocusTimerLauncher:
            self = .focusTimerLauncher
        case .empty:
            self = .empty
        case .degraded:
            self = .degraded
        case .hidden, .dropTarget:
            self = .hidden
        }
    }
}

/// The root Timeline projection owns timestamp-backed timer status semantics.
/// Hiding its visual descendants prevents VoiceOver from announcing a stale
/// static title beside a second, independently ticking value.
private struct SignalActivityAccessibilityModifier: ViewModifier {
    let staticSummary: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let staticSummary {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(staticSummary)
        } else {
            content.accessibilityHidden(true)
        }
    }
}

/// Exists only inside a physically presented rendered activity branch. SwiftUI
/// tears its periodic schedule down when the NSPanel is ordered out, the logical
/// surface hides, or the timer activity is replaced.
private struct TemporalProjectionView<Content: View>: View {
    let projection: ActivitySurfaceTemporalProjection
    @ViewBuilder let content: (ActivitySurfaceTemporalSnapshot) -> Content

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(projection.snapshot(at: context.date))
        }
    }
}

private struct SurfaceSignalLine: View {
    let progress: Double
    let tint: Color
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(EryloPalette.cloud.opacity(0.12))
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private struct QuietSurfaceActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(
                !isEnabled
                    ? EryloPalette.mist.opacity(0.48)
                    : configuration.isPressed
                    ? EryloPalette.cloud
                    : EryloPalette.mist
            )
            .frame(minHeight: 28)
            .padding(.horizontal, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        EryloPalette.cloud.opacity(
                            !isEnabled ? 0.025 : configuration.isPressed ? 0.1 : 0.05
                        )
                    )
            )
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.98 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.08),
                value: configuration.isPressed
            )
    }
}

private struct SurfaceActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let tint: Color
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(EryloPalette.cloud.opacity(isEnabled ? 1 : 0.48))
            .frame(minHeight: 28)
            .padding(.horizontal, 14)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? tint.opacity(0.28)
                            : tint.opacity(isEnabled ? 0.16 : 0.06)
                    )
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(tint.opacity(isEnabled ? 0.34 : 0.12), lineWidth: 0.5)
                    }
            )
            .opacity(configuration.isPressed ? 0.86 : 1)
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.98 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.08),
                value: configuration.isPressed
            )
    }
}

private struct FocusTimerPresetButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: PanelSurfaceVisualMetrics.focusTimerPresetCornerRadius,
            style: .continuous
        )
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(configuration.isPressed ? EryloPalette.cloud : EryloPalette.mist)
            .frame(
                minWidth: PanelSurfaceVisualMetrics.focusTimerPresetMinimumWidth,
                minHeight: PanelSurfaceVisualMetrics.focusTimerPresetMinimumHeight
            )
            .background(
                shape
                    .fill(
                        configuration.isPressed
                            ? EryloPalette.amber.opacity(0.18)
                            : EryloPalette.cloud.opacity(0.045)
                    )
                    .overlay {
                        shape.stroke(
                            configuration.isPressed
                                ? EryloPalette.amber.opacity(0.34)
                                : EryloPalette.cloud.opacity(0.12),
                            lineWidth: 0.5
                        )
                    }
            )
            .contentShape(shape)
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.97 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.08),
                value: configuration.isPressed
            )
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
