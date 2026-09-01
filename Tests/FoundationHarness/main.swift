import AppKit
import CoreGraphics
import Darwin
import EryloActivity
import EryloCore
import EryloIntegrations
import EryloSurface
import EryloWindowing
import Foundation

@main
@MainActor
enum FoundationHarnessMain {
    static func main() async {
        var harness = FoundationHarness()
        harness.verifyPanelStateMachine()
        harness.verifyPanelGeometry()
        harness.verifyDisplayPolicy()
        harness.verifyExpandedInteractionPolicy()
        harness.verifyPassiveActivityAnnouncementPolicy()
        harness.verifyAutomaticWindowMorphStaging()
        harness.verifyHoverHysteresisAndMotionInterruption()
        await harness.verifyCoordinatorLifecycle()
        await harness.verifyPassiveAnnouncementDelivery()
        await harness.verifyDemandDrivenPanelLifecycle()
        await harness.verifyComposedDemandContraction()
        await harness.verifyDisabledProvider()
        harness.finish()
    }
}

@MainActor
private struct FoundationHarness {
    private var checkCount = 0
    private var failures: [String] = []

    mutating func verifyPanelStateMachine() {
        var machine = PanelStateMachine()
        check(machine.send(.show) == .compact, "show reveals compact state")
        check(machine.send(.hoverBegan) == .peek, "hover reveals peek state")
        check(machine.send(.primaryAction) == .expanded, "one action expands peek state")
        check(machine.send(.primaryAction) == .compact, "one action collapses expanded state")

        var hidden = PanelStateMachine()
        check(hidden.send(.hoverBegan) == .hidden, "hidden state ignores hover")
        check(hidden.send(.primaryAction) == .compact, "primary shortcut reveals a hidden surface")

        var hiddenDrop = PanelStateMachine()
        check(hiddenDrop.send(.dragEntered) == .dropTarget, "dormant drop reducer records a hidden drag entry")
        check(hiddenDrop.send(.dragExited) == .hidden, "dormant hidden drag exit restores invisible rest")

        var activityVisibility = PanelStateMachine()
        check(activityVisibility.updateActivityAvailability(true) == .compact, "first activity reveals compact state")
        check(activityVisibility.updateActivityAvailability(false) == .hidden, "empty compact state returns to hidden")
        var expandedActivity = PanelStateMachine(initialState: .expanded)
        check(expandedActivity.updateActivityAvailability(false) == .expanded, "empty snapshot does not collapse deliberate expansion")

        var dropTarget = PanelStateMachine(initialState: .expanded)
        check(dropTarget.send(.dragEntered) == .dropTarget, "drag enters drop-target state")
        check(dropTarget.send(.dragExited) == .expanded, "drag cancellation restores interrupted state")
        check(dropTarget.send(.dragEntered) == .dropTarget, "drop target can be re-entered")
        check(dropTarget.send(.dropCompleted) == .expanded, "drop completion has an explicit route")

        var interruptedPeek = PanelStateMachine(initialState: .peek)
        check(interruptedPeek.send(.dragEntered) == .dropTarget, "drag interrupts peek")
        check(interruptedPeek.send(.dragExited) == .peek, "cancelled drag restores peek")
        check(interruptedPeek.send(.dismiss) == .peek, "stale dismiss does not corrupt restored state")

        for state in PanelPresentationState.allCases {
            var candidate = PanelStateMachine(initialState: state)
            check(candidate.send(.hide) == .hidden, "hide wins from \(state.rawValue)")
        }
    }

    mutating func verifyPanelGeometry() {
        let display = DisplayGeometry(
            frame: CGRect(x: 100, y: 50, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 100, y: 50, width: 1_440, height: 875),
            backingScaleFactor: 2,
            topEdgeOcclusion: nil
        )
        let layouts = PanelPresentationState.allCases.map {
            PanelLayout(display: display, state: $0)
        }
        let fixedFrame = layouts[0].fixedFrame
        check(layouts.allSatisfy { $0.fixedFrame == fixedFrame }, "maximum frame is fixed across states")
        check(
            fixedFrame.maxY == display.visibleFrame.maxY,
            "notchless fixed frame starts below the usable menu-bar edge"
        )

        let hidden = PanelLayout(display: display, state: .hidden)
        check(!hidden.hitRegion.contains(hidden.surfaceFrame.center), "hidden state has no hit region")

        let compact = PanelLayout(display: display, state: .compact)
        check(compact.attachment == .notchlessPill, "notchless display uses pill attachment")
        check(compact.surfaceTopInset == 8, "notchless pill is inset from the display edge")
        check(compact.surfaceFrame.size == CGSize(width: 240, height: 32), "compact fallback keeps a quiet capsule footprint")
        check(
            compact.surfaceFrame.maxY == compact.fixedFrame.height - compact.surfaceTopInset,
            "notchless pill inset is represented in AppKit-local geometry"
        )
        check(
            compact.fixedFrame.minY + compact.surfaceFrame.maxY
                == display.visibleFrame.maxY - compact.surfaceTopInset,
            "notchless pill renders wholly below the visible-frame top edge"
        )
        check(
            compact.cornerRadius == compact.surfaceFrame.height / 2,
            "notchless compact surface remains a capsule"
        )
        check(compact.hitRegion.contains(compact.surfaceFrame.center), "compact center is interactive")
        check(
            !compact.hitRegion.contains(CGPoint(x: compact.surfaceFrame.minX, y: compact.surfaceFrame.minY)),
            "transparent rounded corner is not interactive"
        )
        check(
            compact.hitRegion.contains(CGPoint(x: compact.surfaceFrame.midX, y: compact.surfaceFrame.maxY)),
            "rounded-region boundary is interactive"
        )

        let notchlessLauncher = PanelLayout(
            display: display,
            state: .compact,
            showsFocusTimerLauncher: true
        )
        check(
            notchlessLauncher.surfaceFrame.size
                == PanelMetrics.feasibility.notchlessTimerLauncherSize,
            "notchless Focus Timer launcher uses its compact control-bearing footprint"
        )
        check(
            notchlessLauncher.surfaceFrame.size == CGSize(width: 300, height: 44)
                && notchlessLauncher.surfaceTopInset == 8,
            "notchless Focus Timer launcher stays one native control row below the menu bar"
        )
        check(
            notchlessLauncher.cornerRadius == 19
                && notchlessLauncher.hitRegion.contains(notchlessLauncher.surfaceFrame.center),
            "notchless Focus Timer launcher keeps a bounded continuous pill hit region"
        )

        let peek = PanelLayout(display: display, state: .peek)
        let expanded = PanelLayout(display: display, state: .expanded)
        let dropTarget = PanelLayout(display: display, state: .dropTarget)
        check(peek.surfaceFrame.size == CGSize(width: 292, height: 68), "peek adds one bounded line of context")
        check(expanded.surfaceFrame.size == CGSize(width: 376, height: 164), "expanded geometry stays compact while preserving content breathing room")
        check(dropTarget.surfaceFrame.size == CGSize(width: 404, height: 180), "drop target remains a bounded extension of expanded geometry")
        check(
            [peek, expanded].allSatisfy {
                $0.attachment == .notchlessPill
                    && $0.surfaceTopInset == 8
                    && $0.hitRegion.contains($0.surfaceFrame.center)
            },
            "every visible notchless state keeps the inset rounded fallback interactive"
        )
        check(
            dropTarget.hitRegion == .empty,
            "unmounted File Hold compatibility state cannot intercept input"
        )

        let notchedDisplay = DisplayGeometry(
            frame: display.frame,
            visibleFrame: display.visibleFrame,
            backingScaleFactor: display.backingScaleFactor,
            topEdgeOcclusion: TopEdgeOcclusion(
                frame: CGRect(x: 720, y: 876, width: 220, height: 74)
            )
        )
        let notched = PanelLayout(display: notchedDisplay, state: .compact)
        check(notched.attachment == .notchIntegrated, "top-edge occlusion selects notch integration")
        check(notched.surfaceTopInset == 0, "notch-integrated surface remains top-edge anchored")
        check(
            notched.fixedFrame.maxY == notchedDisplay.frame.maxY
                && notched.fixedFrame.size == compact.fixedFrame.size
                && notched.fixedFrame.midX == compact.fixedFrame.midX,
            "notch integration keeps the fixed envelope attached to the physical display edge"
        )
        check(notched.surfaceFrame.width == 280, "notch width and padding expand compact surface")
        check(notched.surfaceFrame.height == 74, "notch height expands compact surface")
        check(notched.topCornerRadius == 6, "compact notch shoulders use the smallest top curl")
        check(notched.surfaceContentTopInset == 0, "compact content remains in the notch wings")

        let notchedLauncherDisplay = DisplayGeometry(
            frame: display.frame,
            visibleFrame: display.visibleFrame,
            backingScaleFactor: display.backingScaleFactor,
            topEdgeOcclusion: TopEdgeOcclusion(
                frame: CGRect(x: 720, y: 906, width: 220, height: 44)
            )
        )
        let notchedLauncher = PanelLayout(
            display: notchedLauncherDisplay,
            state: .compact,
            showsFocusTimerLauncher: true
        )
        check(
            notchedLauncher.surfaceFrame.size == PanelMetrics.feasibility.timerLauncherSize,
            "notched Focus Timer launcher preserves its camera-safe 316 by 88 geometry"
        )
        check(
            notchedLauncher.surfaceContentTopInset == 44
                && notchedLauncher.surfaceFrame.height
                    - notchedLauncher.surfaceContentTopInset == 44,
            "notched Focus Timer launcher keeps one full control row below the physical occlusion"
        )

        let bodyReservedPeek = PanelLayout(
            display: notchedDisplay,
            state: .peek,
            minimumNotchBodyHeight: 36
        )
        check(
            bodyReservedPeek.surfaceFrame.height - bodyReservedPeek.surfaceContentTopInset == 36,
            "notched Peek reserves its requested body height below the occlusion"
        )

        let maximumBodyRequest = PanelLayout(
            display: notchedDisplay,
            state: .expanded,
            minimumNotchBodyHeight: 176
        )
        check(
            maximumBodyRequest.surfaceFrame.height <= PanelMetrics.feasibility.maximumSize.height
                && maximumBodyRequest.surfaceFrame.height
                    - maximumBodyRequest.surfaceContentTopInset == 166,
            "an oversized notched body request clamps to the maximum envelope without hiding the body calculation"
        )

        let realisticNotchedDisplay = DisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_512, height: 950),
            backingScaleFactor: 2,
            topEdgeOcclusion: TopEdgeOcclusion(
                frame: CGRect(x: 663, y: 950, width: 185, height: 32)
            )
        )
        let realisticPeek = PanelLayout(display: realisticNotchedDisplay, state: .peek)
        let realisticExpanded = PanelLayout(display: realisticNotchedDisplay, state: .expanded)
        check(realisticPeek.surfaceFrame.size == CGSize(width: 292, height: 68), "peek geometry clears a representative hardware notch")
        check(realisticPeek.surfaceContentTopInset == 32, "peek content begins below the physical occlusion")
        check(realisticPeek.topCornerRadius == 13, "peek uses a restrained intermediate top curl")
        check(realisticExpanded.surfaceFrame.size == CGSize(width: 376, height: 164), "expanded geometry preserves the designed visual hierarchy")
        check(realisticExpanded.surfaceContentTopInset == 32, "expanded content clears the physical occlusion")
        check(realisticExpanded.topCornerRadius == 19, "expanded shoulders flow gradually from the top bezel")
        check(
            realisticPeek.hitRegion.contains(realisticPeek.surfaceFrame.center)
                && realisticExpanded.hitRegion.contains(realisticExpanded.surfaceFrame.center),
            "notch-integrated peek and expanded bodies retain bounded click regions"
        )

        let constrainedMetrics = PanelMetrics(
            maximumSize: CGSize(width: 100, height: 80),
            compactSize: CGSize(width: 500, height: 400),
            peekSize: .zero,
            expandedSize: .zero,
            dropTargetSize: .zero,
            notchHorizontalPadding: 0
        )
        let constrained = PanelLayout(
            display: display,
            state: .compact,
            metrics: constrainedMetrics
        )
        check(constrained.surfaceFrame.size == constrainedMetrics.maximumSize, "surface is clamped to maximum frame")

        let conservativeRegion = compact.hitRegion.intersecting(expanded.hitRegion)
        check(
            conservativeRegion.contains(compact.surfaceFrame.center),
            "morph intersection keeps the shared visible region interactive"
        )
        check(
            !conservativeRegion.contains(expanded.surfaceFrame.center),
            "morph intersection rejects destination-only geometry"
        )
    }

    mutating func verifyDisplayPolicy() {
        let main = makeSnapshot(identity: 10, isMain: true)
        let external = makeSnapshot(identity: 20, originX: 1_440)
        let mirrored = makeSnapshot(identity: 30, originX: 3_360, isMirrored: true)

        let defaultResolution = DisplayPolicy.safeDefault.resolve([
            external,
            main,
            external,
            mirrored,
        ])
        check(
            defaultResolution.enabledDisplays.map(\.identity) == [main.identity],
            "safe display policy enables only the current main display"
        )
        check(
            defaultResolution.selectedDisplayIdentity == main.identity,
            "safe display policy selects the main display"
        )
        check(!DisplayPolicy.safeDefault.allowsFullscreenAuxiliary, "safe policy excludes fullscreen Spaces")
        check(
            DisplayPolicy(allowsFullscreenAuxiliary: true).allowsFullscreenAuxiliary,
            "fullscreen auxiliary participation requires an explicit policy"
        )
        check(
            !PanelCollectionBehaviorPolicy.make(allowsFullscreenAuxiliary: false)
                .contains(.fullScreenAuxiliary),
            "native default collection behavior excludes fullscreen Spaces"
        )
        check(
            PanelCollectionBehaviorPolicy.make(allowsFullscreenAuxiliary: true)
                .contains(.fullScreenAuxiliary),
            "native collection behavior adds fullscreen auxiliary only after opt-in"
        )

        let selectedExternal = DisplayPolicy(
            surfaceScope: .custom,
            enabledDisplayUUIDs: [external.uuid],
            preferredDisplayUUID: external.uuid
        ).resolve([main, external, mirrored])
        check(
            selectedExternal.enabledDisplays.map(\.identity) == [external.identity],
            "enabled-display allowlist selects a single external display"
        )
        check(
            selectedExternal.selectedDisplayIdentity == external.identity,
            "explicit selected display drives one-at-a-time interactions"
        )

        let explicitlyEmpty = DisplayPolicy(
            surfaceScope: .custom,
            enabledDisplayUUIDs: [],
            preferredDisplayUUID: external.uuid
        ).resolve([main, external])
        check(
            explicitlyEmpty.enabledDisplays.isEmpty,
            "explicitly empty display allowlist creates no panels"
        )
        check(
            explicitlyEmpty.selectedDisplayIdentity == nil,
            "explicitly empty display allowlist has no shortcut target"
        )

        let missingSelection = DisplayPolicy(
            surfaceScope: .allAvailable,
            preferredDisplayUUID: makeDisplayUUID(999)
        ).resolve([external, main])
        check(
            missingSelection.enabledDisplays.count == 2
                && missingSelection.selectedDisplayIdentity == nil,
            "missing preferred display never targets a different available display"
        )

        let fallbackLeft = makeSnapshot(identity: 40)
        let fallbackRight = makeSnapshot(identity: 20, originX: 1_440)
        let firstFallback = DisplayPolicy.safeDefault.resolve([fallbackLeft, fallbackRight])
        let reorderedFallback = DisplayPolicy.safeDefault.resolve([fallbackRight, fallbackLeft])
        check(
            firstFallback.selectedDisplayIdentity == fallbackRight.identity
                && reorderedFallback.selectedDisplayIdentity == fallbackRight.identity,
            "mainless fallback selection remains stable across provider reordering"
        )

        let staleAllowlist = DisplayPolicy(
            surfaceScope: .custom,
            enabledDisplayUUIDs: [makeDisplayUUID(999)],
            preferredDisplayUUID: makeDisplayUUID(999)
        ).resolve([external, main])
        check(
            staleAllowlist.enabledDisplays.isEmpty
                && staleAllowlist.selectedDisplayIdentity == nil,
            "stale custom display UUIDs remain unavailable instead of targeting main"
        )

        let staleMainlessAllowlist = DisplayPolicy(
            surfaceScope: .custom,
            enabledDisplayUUIDs: [makeDisplayUUID(999)]
        ).resolve([fallbackLeft, fallbackRight])
        check(
            staleMainlessAllowlist.enabledDisplays.isEmpty
                && staleMainlessAllowlist.selectedDisplayIdentity == nil,
            "stale mainless custom scope never substitutes a different display"
        )

        let rebootedExternal = makeSnapshot(
            identity: 220,
            uuid: external.uuid,
            originX: 1_440
        )
        let stablePreference = DisplayPolicy(
            surfaceScope: .custom,
            enabledDisplayUUIDs: [external.uuid],
            preferredDisplayUUID: external.uuid
        ).resolve([main, rebootedExternal])
        check(
            stablePreference.enabledDisplays.map(\.identity) == [rebootedExternal.identity]
                && stablePreference.selectedDisplayIdentity == rebootedExternal.identity,
            "stable UUID preference remaps to the display's new session identity"
        )

        let reusedSessionIdentity = makeSnapshot(
            identity: external.identity.rawValue,
            uuid: makeDisplayUUID(777),
            originX: 1_440
        )
        let reusedIdentityResolution = DisplayPolicy(
            surfaceScope: .custom,
            enabledDisplayUUIDs: [external.uuid],
            preferredDisplayUUID: external.uuid
        ).resolve([main, reusedSessionIdentity])
        check(
            reusedIdentityResolution.enabledDisplays.isEmpty
                && reusedIdentityResolution.selectedDisplayIdentity == nil,
            "reused Core Graphics ID with a different UUID never matches saved preference"
        )

        let disabled = DisplayPolicy(isEnabled: false).resolve([main, external])
        check(disabled.enabledDisplays.isEmpty, "disabled display policy creates no enabled surfaces")
        check(disabled.selectedDisplayIdentity == nil, "disabled display policy has no shortcut target")
    }

    mutating func verifyExpandedInteractionPolicy() {
        let hitRegion = HitRegion.roundedRectangle(
            CGRect(x: 20, y: 20, width: 200, height: 100),
            cornerRadius: 20
        )
        for state in PanelPresentationState.allCases where state != .expanded {
            let policy = ExpandedInteractionPolicy(
                state: state,
                isWindowPresented: true,
                hitRegion: hitRegion
            )
            check(!policy.allowsKeyInteraction, "\(state.rawValue) cannot become key")
            check(
                !policy.requiresMouseDownMonitoring,
                "\(state.rawValue) owns no outside-click monitors"
            )
            check(
                policy.escapeDecision(panelIsKey: true) == .ignore,
                "\(state.rawValue) ignores Escape dismissal"
            )
        }

        for state in [PanelPresentationState.compact, .peek] {
            let controlled = ExpandedInteractionPolicy(
                state: state,
                isWindowPresented: true,
                hitRegion: hitRegion,
                hasExplicitControls: true
            )
            check(
                controlled.allowsKeyInteraction,
                "control-bearing \(state.rawValue) is eligible for deliberate keyboard interaction"
            )
            check(
                !controlled.requiresMouseDownMonitoring
                    && controlled.escapeDecision(panelIsKey: true) == .retireKeyFocus,
                "control-bearing \(state.rawValue) retires key focus without invoking its action"
            )
        }

        let expanded = ExpandedInteractionPolicy(
            state: .expanded,
            isWindowPresented: true,
            hitRegion: hitRegion
        )
        check(expanded.allowsKeyInteraction, "presented Expanded state permits key interaction")
        check(
            expanded.requiresMouseDownMonitoring,
            "presented Expanded state demands paired outside-click monitors"
        )
        check(
            expanded.mouseDownDecision(at: CGPoint(x: 120, y: 70)) == .keepOpen,
            "clicks inside the current native hit region preserve Expanded actions"
        )
        check(
            expanded.mouseDownDecision(at: CGPoint(x: 20, y: 20)) == .dismiss,
            "transparent rounded corners dismiss as outside clicks"
        )
        check(
            expanded.mouseDownDecision(at: CGPoint(x: 240, y: 70)) == .dismiss,
            "clicks beyond the current native hit region dismiss Expanded"
        )
        check(
            expanded.escapeDecision(panelIsKey: true) == .dismissPresentation,
            "Escape dismisses when Expanded owns key interaction"
        )
        check(
            expanded.escapeDecision(panelIsKey: false) == .ignore,
            "Escape does not act when another window owns key interaction"
        )
        check(
            DeliberatePanelFocusPolicy.shouldRequestKey(
                from: .compact,
                to: .expanded,
                isWindowPresented: true
            ),
            "shortcut expansion deliberately transfers keyboard focus"
        )
        check(
            DeliberatePanelFocusPolicy.shouldRequestKey(
                from: .hidden,
                to: .compact,
                isWindowPresented: true,
                hasExplicitControls: true
            ),
            "shortcut reveal deliberately focuses a control-bearing compact launcher"
        )
        check(
            !DeliberatePanelFocusPolicy.shouldRequestKey(
                from: .compact,
                to: .expanded,
                isWindowPresented: false
            )
                && !DeliberatePanelFocusPolicy.shouldRequestKey(
                    from: .expanded,
                    to: .compact,
                    isWindowPresented: true
                ),
            "ordered-out or contracting surfaces never request key focus"
        )

        let orderedOut = ExpandedInteractionPolicy(
            state: .expanded,
            isWindowPresented: false,
            hitRegion: hitRegion
        )
        check(!orderedOut.allowsKeyInteraction, "ordered-out Expanded state cannot become key")
        check(
            !orderedOut.requiresMouseDownMonitoring,
            "ordered-out Expanded state owns no outside-click monitors"
        )

        var leasePolicy = ExpandedInteractionLeasePolicy()
        check(!leasePolicy.admits(0), "inactive dismissal lease rejects callbacks")
        let firstLease = leasePolicy.activate()
        check(leasePolicy.admits(firstLease), "active dismissal lease admits its callback")
        leasePolicy.retire()
        check(!leasePolicy.admits(firstLease), "retired dismissal lease rejects queued callbacks")
        let secondLease = leasePolicy.activate()
        check(
            secondLease != firstLease && leasePolicy.admits(secondLease),
            "reinstalled monitors own a fresh dismissal lease"
        )
        check(
            !leasePolicy.admits(firstLease),
            "stale monitor callbacks cannot dismiss a later Expanded session"
        )
    }

    mutating func verifyPassiveActivityAnnouncementPolicy() {
        do {
            var policy = PassiveActivityAnnouncementPolicy()
            let battery50 = try makeSurfaceItem(
                identifier: "battery-status",
                kind: .battery,
                progress: 0.50,
                revision: 1
            )
            let battery50Revision = try makeSurfaceItem(
                identifier: "battery-status",
                kind: .battery,
                progress: 0.50,
                revision: 2
            )
            let battery60 = try makeSurfaceItem(
                identifier: "battery-status",
                kind: .battery,
                progress: 0.60,
                revision: 3
            )
            check(
                policy.announcement(for: battery50) == "Battery, 50 percent",
                "first passive Battery value earns one semantic announcement"
            )
            check(
                policy.announcement(for: battery50) == nil
                    && policy.announcement(for: battery50Revision) == nil,
                "observer churn and an equivalent revision do not repeat an announcement"
            )
            check(
                policy.announcement(for: battery60) == "Battery, 60 percent"
                    && policy.announcement(for: battery50) == "Battery, 50 percent",
                "real passive value changes announce, including a return to a prior value"
            )

            let volume = try makeSurfaceItem(
                identifier: "volume-status",
                kind: .volume,
                progress: 0.35,
                revision: 1
            )
            let timer = try makeSurfaceItem(
                identifier: "timer-status",
                kind: .timer,
                progress: 0.35,
                revision: 1
            )
            check(
                policy.announcement(for: volume) == "Volume, 35 percent",
                "Volume earns a nonduplicative semantic announcement"
            )
            check(
                policy.announcement(for: timer) == nil && policy.announcement(for: nil) == nil,
                "interactive and absent activities never use the passive announcement route"
            )

            for index in 0..<PassiveActivityAnnouncementPolicy.maximumRememberedActivities {
                _ = policy.announcement(
                    for: try makeSurfaceItem(
                        identifier: "bounded-battery-\(index)",
                        kind: .battery,
                        progress: 0.25,
                        revision: 1
                    )
                )
            }
            check(
                policy.announcement(for: battery50) == "Battery, 50 percent",
                "bounded announcement memory evicts its oldest semantic identity"
            )
        } catch {
            check(false, "passive announcement fixtures validate")
        }
    }

    mutating func verifyPassiveAnnouncementDelivery() async {
        let main = makeSnapshot(identity: 61, isMain: true)
        let external = makeSnapshot(identity: 62, originX: 1_440)
        let displays = FakeDisplayProvider(displays: [main, external])
        let events = FakeLifecycleEventSource()
        let registry = DemandPanelRegistry()
        let broker = ActivityBroker()
        let activityModel = SurfaceActivityModel(broker: broker)
        let announcer = RecordingPanelAccessibilityAnnouncer()
        let coordinator = PanelCoordinator(
            displayProvider: displays,
            policy: DisplayPolicy(surfaceScope: .allAvailable),
            lifecycleEventSource: events,
            activityModel: activityModel,
            accessibilityAnnouncer: announcer,
            panelFactory: { snapshot, _ in registry.makePanel(snapshot: snapshot) }
        )

        await coordinator.startAndWait()
        do {
            _ = try await broker.submit(
                ActivityRequest(
                    identifier: "coordinator-battery",
                    source: ActivitySource.battery.rawValue,
                    kind: ActivityKind.battery.rawValue,
                    priority: 50,
                    title: "Battery",
                    progress: 0.50
                )
            )
            for _ in 0..<2_000 where registry.creationCount != 2 {
                await Task.yield()
            }
            check(
                announcer.announcements.isEmpty,
                "passive speech waits until a real demand-reporting panel is presented"
            )
            registry.panels.forEach { $0.setDemand(true) }
            check(
                registry.panels.allSatisfy { $0.showCount == 1 }
                    && announcer.announcements == ["Battery, 50 percent"],
                "late panel demand speaks one passive cue across multiple displays"
            )

            let equivalentSnapshot = try await broker.submit(
                ActivityRequest(
                    identifier: "coordinator-battery",
                    source: ActivitySource.battery.rawValue,
                    kind: ActivityKind.battery.rawValue,
                    priority: 50,
                    title: "Battery",
                    progress: 0.50
                )
            )
            for _ in 0..<2_000
                where activityModel.snapshotVersion < equivalentSnapshot.version {
                await Task.yield()
            }
            check(
                activityModel.snapshotVersion == equivalentSnapshot.version
                    && announcer.announcements.count == 1,
                "consumed equivalent broker revisions do not repeat passive speech"
            )
        } catch {
            check(false, "coordinator passive announcement fixture validates")
        }
        await coordinator.shutdown()
    }

    mutating func verifyHoverHysteresisAndMotionInterruption() {
        let display = makeSnapshot(identity: 10, isMain: true).geometry
        let scheduler = ManualOneShotScheduler()
        let model = PanelSurfaceModel(
            displayGeometry: display,
            initialState: .compact,
            scheduler: scheduler,
            activityModel: makeActiveActivityModel()
        )

        model.setPointerInside(true)
        check(
            scheduler.lastScheduledDelay == .milliseconds(120),
            "hover entry uses the controlled 120 millisecond dwell"
        )
        model.setPointerInside(false)
        check(
            scheduler.activeOperationCount == 0,
            "leaving before hover dwell cancels pending Peek work"
        )
        scheduler.runAll()
        check(model.state == .compact, "pointer transit keeps compact geometry stable")

        model.setPointerInside(true)
        scheduler.runNext()
        check(model.state == .peek, "sustained hover reveals Peek after its one-shot dwell")
        model.setPointerInside(false)
        check(
            scheduler.lastScheduledDelay == .milliseconds(300),
            "Peek exit uses the controlled 300 millisecond grace period"
        )
        model.setPointerInside(true)
        scheduler.runAll()
        check(model.state == .peek, "re-entry cancels the pending Peek exit")
        model.setPointerInside(false)
        scheduler.runAll()
        check(model.state == .compact, "completed hover exit returns Peek to compact")

        model.setPointerInside(true)
        check(model.state == .compact, "click can preempt the pending hover dwell")
        model.send(.primaryAction)
        scheduler.runAll()
        check(model.state == .expanded, "click deliberately expands the compact surface")

        let motionScheduler = ManualOneShotScheduler()
        let motionModel = PanelSurfaceModel(
            displayGeometry: display,
            initialState: .compact,
            scheduler: motionScheduler,
            activityModel: makeActiveActivityModel()
        )
        let expandedLayout = PanelLayout(display: display, state: .expanded)
        let destinationOnlyPoint = expandedLayout.surfaceFrame.center
        motionModel.send(.primaryAction)
        let expandingPointer = motionModel.pointerDisposition(at: destinationOnlyPoint)
        check(
            !expandingPointer.acceptsMouseEvents,
            "expansion exposes only the conservative shared hit region during morph"
        )
        check(
            expandingPointer.isInsideTargetSurface,
            "destination-visible geometry preserves hover without accepting premature clicks"
        )
        motionScheduler.runAll()
        check(
            motionModel.interactionHitRegion.contains(destinationOnlyPoint),
            "destination hit region activates after morph completion"
        )

        let interruptionScheduler = ManualOneShotScheduler()
        let interruptionModel = PanelSurfaceModel(
            displayGeometry: display,
            initialState: .compact,
            scheduler: interruptionScheduler,
            activityModel: makeActiveActivityModel()
        )
        interruptionModel.send(.primaryAction)
        interruptionModel.send(.primaryAction)
        interruptionScheduler.runAll()
        check(interruptionModel.state == .compact, "reversed morph settles at the latest state")
        check(
            interruptionModel.interactionHitRegion == interruptionModel.layout.hitRegion,
            "cancelled motion completion cannot restore a stale hit region"
        )

        let stressScheduler = ManualOneShotScheduler()
        let stressModel = PanelSurfaceModel(
            displayGeometry: display,
            initialState: .compact,
            scheduler: stressScheduler,
            activityModel: makeActiveActivityModel()
        )
        for _ in 0..<500 {
            stressModel.send(.primaryAction)
            stressModel.send(.primaryAction)
        }
        check(stressModel.state == .compact, "rapid repeated reversals retain deterministic state")
        check(
            stressModel.interactionHitRegion.componentCount == 2,
            "rapid reversals keep a bounded canonical hit-region intersection"
        )
        stressScheduler.runAll()
        check(
            stressModel.interactionHitRegion == stressModel.layout.hitRegion,
            "only the latest completion settles after reversal stress"
        )
        check(
            stressScheduler.activeOperationCount == 0,
            "reversal stress settles with zero pending interaction work"
        )

        let reduceMotionScheduler = ManualOneShotScheduler()
        let reduceMotionModel = PanelSurfaceModel(
            displayGeometry: display,
            initialState: .compact,
            scheduler: reduceMotionScheduler,
            activityModel: makeActiveActivityModel()
        )
        reduceMotionModel.updateReduceMotion(true)
        reduceMotionModel.send(.primaryAction)
        check(
            reduceMotionScheduler.activeOperationCount == 0
                && reduceMotionModel.isHitRegionSettled
                && reduceMotionModel.interactionHitRegion == reduceMotionModel.layout.hitRegion,
            "Reduce Motion snaps visual geometry and native hit testing without scheduled work"
        )

        let notchedDisplay = DisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_512, height: 950),
            backingScaleFactor: 2,
            topEdgeOcclusion: TopEdgeOcclusion(
                frame: CGRect(x: 663, y: 950, width: 185, height: 32)
            )
        )
        let topAnchorPoint = CGPoint(x: 280, y: 232)
        let notchedCompactLayout = PanelLayout(
            display: notchedDisplay,
            state: .compact
        )
        let notchedPeekLayout = PanelLayout(
            display: notchedDisplay,
            state: .peek
        )
        check(
            notchedCompactLayout.hitRegion.contains(topAnchorPoint),
            "compact notch anchor accepts the real top-edge pointer"
        )
        check(
            !notchedPeekLayout.hitRegion.contains(topAnchorPoint),
            "peek click shelf does not steal the hardware row"
        )
        check(
            notchedPeekLayout.hoverAnchorRegion.contains(topAnchorPoint),
            "peek retains the stable compact hover anchor"
        )

        let stableScheduler = ManualOneShotScheduler()
        let stableModel = PanelSurfaceModel(
            displayGeometry: notchedDisplay,
            initialState: .compact,
            scheduler: stableScheduler,
            activityModel: makeActiveActivityModel()
        )
        stableModel.setPointerInside(
            stableModel.pointerDisposition(at: topAnchorPoint).isInsideTargetSurface
        )
        check(stableModel.state == .compact, "notch hover preserves compact geometry")
        for _ in 0..<500 {
            stableModel.setPointerInside(
                stableModel.pointerDisposition(at: topAnchorPoint).isInsideTargetSurface
            )
        }
        stableScheduler.runAll()
        check(
            stableModel.state == .peek,
            "stationary notch hover settles in Peek without geometry oscillation"
        )
        check(
            stableScheduler.activeOperationCount == 0,
            "stationary notch hover settles without repeating work"
        )

        let closeScheduler = ManualOneShotScheduler()
        let closeModel = PanelSurfaceModel(
            displayGeometry: notchedDisplay,
            initialState: .expanded,
            scheduler: closeScheduler,
            activityModel: makeActiveActivityModel()
        )
        closeModel.setPointerInside(
            closeModel.pointerDisposition(at: topAnchorPoint).isInsideTargetSurface
        )
        closeModel.send(.primaryAction)
        for _ in 0..<500 {
            closeModel.setPointerInside(
                closeModel.pointerDisposition(at: topAnchorPoint).isInsideTargetSurface
            )
        }
        closeScheduler.runAll()
        check(
            closeModel.state == .compact,
            "explicit close stays compact under a stationary notch pointer"
        )
        check(
            closeScheduler.activeOperationCount == 0,
            "explicit close leaves no hover or motion work"
        )

        closeModel.setPointerInside(false)
        closeModel.send(.hoverBegan)
        closeScheduler.runAll()
        check(
            closeModel.state == .peek,
            "a genuine exit rearms the explicit compatibility hover event"
        )

        let hiddenModel = PanelSurfaceModel(
            displayGeometry: notchedDisplay,
            initialState: .hidden,
            scheduler: ManualOneShotScheduler(),
            activityModel: SurfaceActivityModel(inert: ())
        )
        check(
            !hiddenModel.pointerDisposition(at: topAnchorPoint).acceptsMouseEvents,
            "hidden notch anchor remains click-through"
        )

        let launcherScheduler = ManualOneShotScheduler()
        let launcherModel = PanelSurfaceModel(
            displayGeometry: display,
            initialState: .compact,
            scheduler: launcherScheduler,
            activityModel: SurfaceActivityModel(inert: ())
        )
        let launcherChanges = CallbackCounter()
        launcherModel.didChange = { [weak launcherChanges] in
            launcherChanges?.increment()
        }
        let compactHitRegion = launcherModel.interactionHitRegion
        launcherModel.setFocusTimerStartHandler { _ in true }
        check(launcherModel.state == .compact, "launcher availability is a same-state layout mutation")
        check(launcherChanges.count == 1, "same-state layout mutation notifies its AppKit owner")
        let launcherTarget = launcherModel.layout.hitRegion
        check(
            launcherModel.interactionHitRegion
                == compactHitRegion.intersecting(launcherTarget),
            "same-state growth keeps the native hit region inside visible geometry"
        )
        check(
            launcherScheduler.activeOperationCount == 1,
            "same-state growth owns one bounded hit-region settlement"
        )
        launcherScheduler.runAll()
        check(
            launcherModel.interactionHitRegion == launcherTarget
                && launcherChanges.count == 2,
            "same-state growth adopts the exact target after the morph settles"
        )
    }

    mutating func verifyAutomaticWindowMorphStaging() {
        let display = makeSnapshot(identity: 11, isMain: true).geometry
        let scheduler = ManualOneShotScheduler()
        let model = PanelSurfaceModel(
            displayGeometry: display,
            initialState: .compact,
            scheduler: scheduler,
            activityModel: makeActiveActivityModel()
        )
        model.setWindowPresented(false)

        check(
            model.stageForWindowOrderIn()
                && model.state == .compact
                && model.renderedState == .hidden
                && model.interactionHitRegion == .empty,
            "automatic order-in commits a real inert Hidden frame"
        )

        model.setWindowPresented(true)
        model.send(.hoverBegan)
        check(
            model.state == .peek && model.renderedState == .hidden,
            "a Compact-to-Peek handoff cannot bypass the staged entrance"
        )
        check(
            model.commitStagedWindowOrderIn()
                && model.renderedState == .peek,
            "the staged entrance reveals the newest valid logical destination"
        )
        scheduler.runAll()
        check(
            model.interactionHitRegion == model.layout.hitRegion,
            "the revealed destination earns its exact hit region only after motion settles"
        )

        let exitDelay = model.stageForWindowOrderOut()
        check(
            exitDelay == .milliseconds(220)
                && model.state == .peek
                && model.renderedState == .hidden
                && model.interactionHitRegion == .empty,
            "standard dismissal reaches click-through Hidden before physical order-out"
        )

        model.updateReduceMotion(true)
        check(
            model.stageForWindowOrderOut() == nil
                && model.renderedState == .hidden
                && model.interactionHitRegion == .empty,
            "Reduce Motion keeps physical dismissal synchronous"
        )

        let completionScheduler = ManualOneShotScheduler()
        guard let completionSnapshot = try? ActivitySurfacePreviewCatalog.timerCompletion.snapshot() else {
            check(false, "timer completion entrance fixture validates")
            return
        }
        let completionModel = PanelSurfaceModel(
            displayGeometry: display,
            initialState: .peek,
            scheduler: completionScheduler,
            activityModel: SurfaceActivityModel(previewSnapshot: completionSnapshot)
        )
        completionModel.setWindowPresented(false)
        check(
            completionModel.stageForWindowOrderIn()
                && completionModel.state == .peek
                && completionModel.renderedState == .hidden,
            "automatic timer completion Peek begins from committed Hidden geometry"
        )
        completionModel.setWindowPresented(true)
        check(
            completionModel.commitStagedWindowOrderIn()
                && completionModel.renderedState == .peek,
            "automatic timer completion reveals Peek through the staged morph"
        )

        let genericPeekModel = PanelSurfaceModel(
            displayGeometry: display,
            initialState: .peek,
            scheduler: ManualOneShotScheduler(),
            activityModel: makeActiveActivityModel()
        )
        check(
            !DeliberatePanelFocusLeasePolicy.admits(
                pending: genericPeekModel.deliberateFocusDestination,
                current: completionModel.deliberateFocusDestination
            ),
            "an automatic same-state activity handoff cannot inherit another activity's pending focus"
        )

        let launcherModel = PanelSurfaceModel(
            displayGeometry: display,
            initialState: .hidden,
            scheduler: ManualOneShotScheduler(),
            activityModel: SurfaceActivityModel(inert: ())
        )
        launcherModel.setFocusTimerStartHandler { _ in true }
        launcherModel.setWindowPresented(false)
        let launcherOrigin = launcherModel.state
        launcherModel.send(.primaryAction)
        check(
            launcherModel.stageForWindowOrderIn()
                && launcherModel.renderedState == .hidden
                && launcherModel.logicalContentHasExplicitControls,
            "staged launcher retains its logical control-bearing destination"
        )
        check(
            DeliberatePanelFocusPolicy.shouldRequestKey(
                from: launcherOrigin,
                to: launcherModel.state,
                isWindowPresented: true,
                hasExplicitControls: launcherModel.logicalContentHasExplicitControls
            ),
            "Hidden-to-Compact launcher shortcut retains deliberate focus admission after reentrancy"
        )
    }

    mutating func verifyCoordinatorLifecycle() async {
        let main = makeSnapshot(identity: 10, isMain: true)
        let external = makeSnapshot(identity: 20, originX: 1_440)
        let mirrored = makeSnapshot(identity: 30, originX: 3_360, isMirrored: true)
        let provider = FakeDisplayProvider(displays: [main, external, external, mirrored])
        let eventSource = FakeLifecycleEventSource()
        let registry = FakePanelRegistry()
        let broker = ActivityBroker()
        let activityModel = SurfaceActivityModel(broker: broker)
        let coordinator = PanelCoordinator(
            displayProvider: provider,
            policy: DisplayPolicy(
                surfaceScope: .allAvailable,
                preferredDisplayUUID: external.uuid
            ),
            lifecycleEventSource: eventSource,
            activityModel: activityModel,
            panelFactory: { snapshot, _ in registry.makePanel(snapshot: snapshot) }
        )

        await coordinator.startAndWait()
        await coordinator.startAndWait()
        check(eventSource.startCount == 1, "repeated coordinator start owns one event source")
        check(registry.creationCount == 0, "idle startup constructs zero hidden panel trees")
        check(!eventSource.isPointerMonitoringEnabled, "idle startup installs zero pointer monitors")
        check(
            coordinator.activeDisplayIdentities.isEmpty,
            "idle display discovery retains topology without native panels"
        )

        do {
            _ = try await broker.submit(
                ActivityRequest(
                    identifier: "lazy-first-reveal",
                    source: ActivitySource.timer.rawValue,
                    kind: ActivityKind.timer.rawValue,
                    priority: 50,
                    title: "First reveal"
                )
            )
        } catch {
            check(false, "first reveal activity validates")
        }
        for _ in 0..<2_000 where registry.creationCount != 2 { await Task.yield() }
        check(registry.creationCount == 2, "first activity constructs one bounded panel path per enabled display")
        check(eventSource.isPointerMonitoringEnabled, "first activity enables pointer monitors before presentation")
        check(
            coordinator.activeDisplayIdentities == [main.identity, external.identity],
            "first reveal excludes duplicate and mirrored displays"
        )

        eventSource.emit(.pointerMoved(CGPoint(x: -100, y: -100)))
        let mainPanel = registry.latestPanel(for: main.identity)
        let externalPanel = registry.latestPanel(for: external.identity)
        check(
            mainPanel?.fullscreenAuxiliaryUpdates == [false]
                && externalPanel?.fullscreenAuxiliaryUpdates == [false],
            "new panels start excluded from fullscreen Spaces"
        )
        var fullscreenPolicy = coordinator.policy
        fullscreenPolicy.allowsFullscreenAuxiliary = true
        coordinator.update(policy: fullscreenPolicy)
        check(
            mainPanel?.fullscreenAuxiliaryUpdates.last == true
                && externalPanel?.fullscreenAuxiliaryUpdates.last == true,
            "fullscreen opt-in updates every existing panel"
        )
        let contractionBaseline = (
            mainPanel?.cancellationCount ?? 0,
            externalPanel?.cancellationCount ?? 0
        )
        fullscreenPolicy.allowsFullscreenAuxiliary = false
        coordinator.update(policy: fullscreenPolicy)
        check(
            mainPanel?.fullscreenAuxiliaryUpdates.last == false
                && externalPanel?.fullscreenAuxiliaryUpdates.last == false
                && mainPanel?.cancellationCount == contractionBaseline.0 + 1
                && externalPanel?.cancellationCount == contractionBaseline.1 + 1,
            "fullscreen opt-out contracts transient state before updating existing panels"
        )
        let mainPointerBaseline = mainPanel?.pointerUpdateCount ?? 0
        let externalPointerBaseline = externalPanel?.pointerUpdateCount ?? 0

        let mainPosition = CGPoint(x: 100, y: 100)
        eventSource.emit(.pointerMoved(mainPosition))
        check(
            mainPanel?.pointerUpdateCount == mainPointerBaseline + 1
                && externalPanel?.pointerUpdateCount == externalPointerBaseline,
            "pointer movement routes only to its current display"
        )
        eventSource.emit(.pointerMoved(mainPosition))
        check(
            mainPanel?.pointerUpdateCount == mainPointerBaseline + 1
                && externalPanel?.pointerUpdateCount == externalPointerBaseline,
            "equivalent pointer positions do not repeat panel coordination"
        )

        let externalPosition = CGPoint(x: 1_500, y: 100)
        eventSource.emit(.pointerMoved(externalPosition))
        check(
            mainPanel?.pointerUpdateCount == mainPointerBaseline + 2
                && externalPanel?.pointerUpdateCount == externalPointerBaseline + 1,
            "cross-display movement updates the exited and entered displays exactly once"
        )
        check(
            mainPanel?.lastPointerPosition == externalPosition
                && externalPanel?.lastPointerPosition == externalPosition,
            "cross-display routing preserves the global pointer coordinate for both panels"
        )

        eventSource.emit(.pointerMoved(CGPoint(x: -200, y: -200)))
        let outsideMainCount = mainPanel?.pointerUpdateCount
        let outsideExternalCount = externalPanel?.pointerUpdateCount
        eventSource.emit(.pointerMoved(CGPoint(x: -300, y: -300)))
        check(
            mainPanel?.pointerUpdateCount == outsideMainCount
                && externalPanel?.pointerUpdateCount == outsideExternalCount,
            "pointer movement outside every display skips irrelevant panel work after exit"
        )

        eventSource.emit(.primaryShortcut)
        check(registry.latestPanel(for: external.identity)?.primaryActionCount == 1, "shortcut targets selected display")
        check(registry.latestPanel(for: main.identity)?.primaryActionCount == 0, "shortcut does not fan out")

        let replacement = makeSnapshot(identity: 40, uuid: external.uuid, originX: 1_440)
        provider.displays = [main, replacement]
        eventSource.emit(.displayConfigurationChanged)
        check(registry.creationCount == 3, "hot-plug adds only the new display panel")
        check(registry.latestPanel(for: external.identity)?.closeCount == 1, "hot-unplug closes stale panel once")
        check(
            coordinator.activeDisplayIdentities == [main.identity, replacement.identity],
            "hot-plug reconciliation retains one panel per current display"
        )

        eventSource.emit(.activeSpaceChanged)
        check(registry.creationCount == 3, "active-Space reconciliation reuses existing panels")

        eventSource.emit(.workspaceWillSleep)
        check(
            registry.latestPanel(for: main.identity)?.hideCount == 1
                && registry.latestPanel(for: main.identity)?.immediateEnvironmentalHideCount == 1,
            "sleep uses the immediate environmental hide route"
        )
        check(!eventSource.isPointerMonitoringEnabled, "sleep retires pointer monitoring while panels are hidden")
        let shortcutCountBeforeSleep = registry.totalPrimaryActionCount
        eventSource.emit(.primaryShortcut)
        check(
            registry.totalPrimaryActionCount == shortcutCountBeforeSleep,
            "shortcut is inert while workspace sleeps"
        )
        eventSource.emit(.workspaceDidWake)
        check(registry.latestPanel(for: main.identity)?.showCount == 2, "wake reconciles and reveals retained panel once")
        check(eventSource.isPointerMonitoringEnabled, "wake restores pointer monitoring before visible panels")

        if let identity = await broker.snapshot().current?.activity.identity {
            _ = await broker.cancel(identity)
        }
        for _ in 0..<2_000 where eventSource.isPointerMonitoringEnabled { await Task.yield() }
        check(!eventSource.isPointerMonitoringEnabled, "final activity hide tears down pointer monitors")
        check(registry.creationCount == 3, "final hide retains the bounded constructed panel set")
        let retainedSelectedPanel = registry.latestPanel(for: replacement.identity)
        let retainedShowCount = retainedSelectedPanel?.showCount
        eventSource.emit(.primaryShortcut)
        check(
            retainedSelectedPanel?.showCount == retainedShowCount.map { $0 + 1 },
            "one shortcut re-presents the retained selected presenter after final activity hide"
        )
        check(eventSource.isPointerMonitoringEnabled, "plain-presenter shortcut restores pointer monitoring")
        eventSource.emit(.primaryShortcut)
        check(!eventSource.isPointerMonitoringEnabled, "second empty shortcut hides the plain presenter once")

        await coordinator.updateAndWait(policy: DisplayPolicy(isEnabled: false))
        check(eventSource.stopCount == 1, "disabled policy removes observers, monitors, and shortcut")
        check(coordinator.activeDisplayIdentities.isEmpty, "disabled policy closes all panels")
        let requestsWhileDisabled = provider.requestCount
        eventSource.emit(.displayConfigurationChanged)
        check(
            provider.requestCount == requestsWhileDisabled,
            "disabled policy performs no display reconciliation work"
        )

        await coordinator.updateAndWait(policy: .safeDefault)
        check(eventSource.startCount == 2, "re-enabled policy installs one fresh event source")
        check(registry.creationCount == 3, "idle re-enable constructs no hidden panels")
        check(!eventSource.isPointerMonitoringEnabled, "idle re-enable retains zero pointer monitors")
        eventSource.emit(.primaryShortcut)
        check(registry.creationCount == 4, "idle global shortcut constructs only the selected display panel")
        check(registry.latestPanel(for: main.identity)?.primaryActionCount == 1, "idle shortcut reveals the resolved selected display")
        check(eventSource.isPointerMonitoringEnabled, "idle shortcut prepares pointer monitoring before reveal")

        await coordinator.stopAndWait()
        await coordinator.stopAndWait()
        check(eventSource.stopCount == 2, "repeated coordinator stop removes event source once")
        check(coordinator.activeDisplayIdentities.isEmpty, "stop releases all active panel ownership")

        await coordinator.startAndWait()
        check(eventSource.startCount == 3, "coordinator can restart after stop")
        check(registry.creationCount == 4, "idle restart constructs no panel trees")
        check(!eventSource.isPointerMonitoringEnabled, "idle restart owns zero pointer monitors")
        eventSource.emit(.primaryShortcut)
        check(registry.creationCount == 5, "post-restart shortcut owns one fresh selected-display construction")
        await coordinator.stopAndWait()
        check(eventSource.stopCount == 3, "restart lifecycle remains symmetrically removable")
    }

    mutating func verifyDisabledProvider() async {
        let provider = DisabledActivityProvider(identifier: "disabled-test")
        var events: [ActivityEvent] = []
        for await event in provider.events() {
            events.append(event)
        }
        check(events.isEmpty, "disabled provider finishes without events")
    }

    mutating func verifyDemandDrivenPanelLifecycle() async {
        let main = makeSnapshot(identity: 50, isMain: true)
        let selected = makeSnapshot(identity: 60, originX: 1_440)
        let events = FakeLifecycleEventSource()
        let registry = DemandPanelRegistry()
        let model = SurfaceActivityModel(broker: ActivityBroker())
        let coordinator = PanelCoordinator(
            displayProvider: FakeDisplayProvider(displays: [main, selected]),
            policy: DisplayPolicy(
                surfaceScope: .allAvailable,
                preferredDisplayUUID: selected.uuid
            ),
            lifecycleEventSource: events,
            activityModel: model,
            panelFactory: { snapshot, _ in registry.makePanel(snapshot: snapshot) }
        )

        await coordinator.startAndWait()
        check(registry.creationCount == 0, "demand lifecycle starts with zero panel constructions")
        check(!events.isPointerMonitoringEnabled, "demand lifecycle starts with zero pointer monitors")

        events.emit(.primaryShortcut)
        let firstPanel = registry.latestPanel
        check(registry.creationCount == 1, "first shortcut has one bounded construction path")
        check(firstPanel?.displayIdentity == selected.identity, "first shortcut constructs only the selected display")
        check(firstPanel?.showCount == 1, "pointer monitoring precedes the first demanded show")
        check(events.isPointerMonitoringEnabled, "first shortcut enables pointer monitoring")

        for _ in 0..<100 {
            events.emit(.primaryShortcut)
            events.emit(.primaryShortcut)
        }
        check(registry.creationCount == 1, "rapid hide/show reuses one panel without duplicates")
        check(firstPanel?.showCount == 101 && firstPanel?.hideCount == 100, "rapid hide/show applies every latest demand exactly once")
        check(events.isPointerMonitoringEnabled, "rapid hide/show settles visible with monitoring active")

        events.emit(.primaryShortcut)
        check(firstPanel?.hideCount == 101, "final hide orders the demanded panel out once")
        check(!events.isPointerMonitoringEnabled, "final hide removes pointer monitoring")

        await coordinator.stopAndWait()
        let stoppedMutations = firstPanel?.mutationCount
        firstPanel?.replayDemandRegistration(0, isDemanded: true)
        check(firstPanel?.mutationCount == stoppedMutations, "retired panel demand cannot mutate after stop")
        check(!events.isPointerMonitoringEnabled, "retired demand cannot reinstall pointer monitoring")

        await coordinator.startAndWait()
        check(registry.creationCount == 1, "idle restart creates no replacement panel")
        events.emit(.primaryShortcut)
        let replacementPanel = registry.latestPanel
        check(registry.creationCount == 2, "post-restart shortcut creates one replacement panel")
        let replacementMutations = replacementPanel?.mutationCount
        firstPanel?.replayDemandRegistration(0, isDemanded: false)
        check(replacementPanel?.mutationCount == replacementMutations, "stale panel lease cannot hide its replacement")
        check(events.isPointerMonitoringEnabled, "replacement remains monitored after stale demand")

        await coordinator.shutdown()
        replacementPanel?.replayDemandRegistration(0, isDemanded: true)
        check(!events.isRunning && !events.isPointerMonitoringEnabled, "shutdown rejects pending or replayed presentation demand")
    }

    mutating func verifyComposedDemandContraction() async {
        let broker = ActivityBroker()
        let activityModel = SurfaceActivityModel(broker: broker)
        let events = FakeLifecycleEventSource()
        let registry = ModelDemandPanelRegistry()
        let coordinator = PanelCoordinator(
            displayProvider: FakeDisplayProvider(
                displays: [makeSnapshot(identity: 70, isMain: true)]
            ),
            policy: .safeDefault,
            lifecycleEventSource: events,
            activityModel: activityModel,
            panelFactory: { snapshot, model in
                registry.makePanel(snapshot: snapshot, activityModel: model)
            }
        )
        let request: (String) -> ActivityRequest = { identifier in
            ActivityRequest(
                identifier: identifier,
                source: ActivitySource.external.rawValue,
                kind: ActivityKind.generic.rawValue,
                priority: 50,
                title: identifier,
                detail: "Inspect result"
            )
        }

        await coordinator.startAndWait()
        do {
            _ = try await broker.submit(request("expanded-expiry"))
        } catch {
            check(false, "expanded-expiry activity validates")
        }
        for _ in 0..<2_000 where registry.latestPanel?.state != .compact {
            await Task.yield()
        }
        guard let panel = registry.latestPanel else {
            check(false, "composed demand panel is constructed by first activity")
            await coordinator.shutdown()
            return
        }

        events.emit(.primaryShortcut)
        check(panel.state == .expanded, "activity surface deliberately expands through the coordinator")
        if let identity = await broker.snapshot().current?.activity.identity {
            _ = await broker.cancel(identity)
        }
        for _ in 0..<2_000 where activityModel.current != nil { await Task.yield() }
        check(panel.state == .hidden, "activity expiry removes a stale expanded composition")
        check(!panel.isPresented && panel.hideCount == 1, "coordinator orders out the expired empty surface")
        check(!events.isPointerMonitoringEnabled, "expired expanded content releases pointer monitoring")
        events.emit(.primaryShortcut)
        check(panel.state == .compact && panel.isPresented, "one shortcut reveals the retained compact surface")
        check(events.isPointerMonitoringEnabled, "revealed compact surface restores pointer monitoring")
        events.emit(.primaryShortcut)
        check(panel.state == .hidden && !panel.isPresented, "second shortcut hides the retained empty surface")
        check(!events.isPointerMonitoringEnabled, "empty surface contraction removes final pointer monitoring")

        await coordinator.shutdown()
        check(!events.isRunning && !events.isPointerMonitoringEnabled, "composed demand fixture shuts down with zero event work")
    }

    private mutating func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        checkCount += 1
        if !condition() {
            failures.append(name)
        }
    }

    func finish() -> Never {
        if failures.isEmpty {
            print("Foundation harness passed: \(checkCount) checks.")
            exit(EXIT_SUCCESS)
        }

        for failure in failures {
            fputs("FAIL: \(failure)\n", stderr)
        }
        fputs("Foundation harness failed: \(failures.count) of \(checkCount) checks.\n", stderr)
        exit(EXIT_FAILURE)
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

@MainActor
private func makeActiveActivityModel() -> SurfaceActivityModel {
    guard let snapshot = try? ActivitySurfacePreviewCatalog.generic.snapshot() else {
        preconditionFailure("bounded active surface fixture must validate")
    }
    return SurfaceActivityModel(previewSnapshot: snapshot)
}

private func makeSurfaceItem(
    identifier: String,
    kind: ActivityKind,
    progress: Double,
    revision: UInt64
) throws -> ActivitySurfaceItem {
    let source: ActivitySource = switch kind {
    case .battery, .charging:
        .battery
    case .timer:
        .timer
    case .meeting:
        .calendar
    case .volume:
        .volume
    case .media, .file, .generic:
        .external
    }
    let activity = try Activity(
        validating: ActivityRequest(
            identifier: identifier,
            source: source.rawValue,
            kind: kind.rawValue,
            priority: 50,
            title: kind.rawValue.capitalized,
            progress: progress
        )
    )
    return ActivitySurfaceItem(
        PresentedActivity(
            activity: activity,
            submissionSequence: 1,
            revision: revision
        )
    )
}

@MainActor
private final class RecordingPanelAccessibilityAnnouncer: PanelAccessibilityAnnouncing {
    private(set) var announcements: [String] = []

    func announce(_ text: String) {
        announcements.append(text)
    }
}

private func makeSnapshot(
    identity: UInt32,
    uuid: DisplayUUID? = nil,
    originX: CGFloat = 0,
    isMain: Bool = false,
    isMirrored: Bool = false
) -> DisplaySnapshot {
    let frame = CGRect(x: originX, y: 0, width: 1_440, height: 900)
    return DisplaySnapshot(
        identity: DisplayIdentity(rawValue: identity),
        uuid: uuid ?? makeDisplayUUID(identity),
        localizedName: isMain ? "Built-in Display" : "External Display",
        geometry: DisplayGeometry(
            frame: frame,
            visibleFrame: CGRect(x: originX, y: 0, width: 1_440, height: 875),
            backingScaleFactor: 2,
            topEdgeOcclusion: nil
        ),
        isMain: isMain,
        isMirrored: isMirrored
    )
}

private func makeDisplayUUID(_ value: UInt32) -> DisplayUUID {
    let uuid = String(format: "00000000-0000-0000-0000-%012llx", UInt64(value))
    return DisplayUUID(rawValue: uuid)!
}

@MainActor
private final class ManualScheduledOperation: ScheduledOperation {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}

@MainActor
private final class CallbackCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

@MainActor
private final class ManualOneShotScheduler: OneShotScheduling {
    private struct Entry {
        let delay: Duration
        let token: ManualScheduledOperation
        let operation: @MainActor @Sendable () -> Void
    }

    private var entries: [Entry] = []

    var lastScheduledDelay: Duration? {
        entries.last?.delay
    }

    var activeOperationCount: Int {
        entries.lazy.filter { !$0.token.isCancelled }.count
    }

    func schedule(
        after delay: Duration,
        operation: @escaping @MainActor @Sendable () -> Void
    ) -> any ScheduledOperation {
        let token = ManualScheduledOperation()
        entries.append(Entry(delay: delay, token: token, operation: operation))
        return token
    }

    func runNext() {
        guard !entries.isEmpty else { return }
        let entry = entries.removeFirst()
        if !entry.token.isCancelled {
            entry.operation()
        }
    }

    func runAll() {
        var remainingSafetyBudget = 10_000
        while !entries.isEmpty, remainingSafetyBudget > 0 {
            remainingSafetyBudget -= 1
            runNext()
        }
    }
}

@MainActor
private final class FakeDisplayProvider: EnabledDisplayProviding {
    var displays: [DisplaySnapshot]
    private(set) var requestCount = 0

    init(displays: [DisplaySnapshot]) {
        self.displays = displays
    }

    func enabledDisplays() -> [DisplaySnapshot] {
        requestCount += 1
        return displays
    }
}

@MainActor
private final class FakeLifecycleEventSource: PanelLifecycleEventSourcing {
    private(set) var isRunning = false
    private(set) var isPointerMonitoringEnabled = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var handler: (@MainActor @Sendable (PanelLifecycleEvent) -> Void)?

    func start(handler: @escaping @MainActor @Sendable (PanelLifecycleEvent) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        startCount += 1
        self.handler = handler
    }

    func setPointerMonitoringEnabled(_ isEnabled: Bool) {
        isPointerMonitoringEnabled = isRunning && isEnabled
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        isPointerMonitoringEnabled = false
        stopCount += 1
        handler = nil
    }

    func emit(_ event: PanelLifecycleEvent) {
        handler?(event)
    }
}

@MainActor
private final class FakePanelRegistry {
    private var panels: [DisplayIdentity: [FakePanel]] = [:]
    private(set) var creationCount = 0

    var totalPrimaryActionCount: Int {
        panels.values.flatMap { $0 }.reduce(0) { $0 + $1.primaryActionCount }
    }

    func makePanel(snapshot: DisplaySnapshot) -> any PanelPresenting {
        let panel = FakePanel(displayIdentity: snapshot.identity)
        panels[snapshot.identity, default: []].append(panel)
        creationCount += 1
        return panel
    }

    func latestPanel(for identity: DisplayIdentity) -> FakePanel? {
        panels[identity]?.last
    }
}

@MainActor
private final class FakePanel: PanelPresenting, PanelImmediateEnvironmentalHiding {
    let displayIdentity: DisplayIdentity
    private(set) var showCount = 0
    private(set) var hideCount = 0
    private(set) var closeCount = 0
    private(set) var updateCount = 0
    private(set) var pointerUpdateCount = 0
    private(set) var lastPointerPosition: CGPoint?
    private(set) var primaryActionCount = 0
    private(set) var cancellationCount = 0
    private(set) var immediateEnvironmentalHideCount = 0
    private(set) var fullscreenAuxiliaryUpdates: [Bool] = []

    init(displayIdentity: DisplayIdentity) {
        self.displayIdentity = displayIdentity
    }

    func show() {
        showCount += 1
    }

    func hide() {
        hideCount += 1
    }

    func hideImmediatelyForEnvironmentalTransition() {
        immediateEnvironmentalHideCount += 1
        hide()
    }

    func close() {
        closeCount += 1
    }

    func update(snapshot: DisplaySnapshot) {
        updateCount += 1
    }

    func updatePointer(screenPoint: CGPoint) {
        pointerUpdateCount += 1
        lastPointerPosition = screenPoint
    }

    func performPrimaryAction() {
        primaryActionCount += 1
    }

    func cancelPendingInteractions() {
        cancellationCount += 1
    }

    func setFullscreenAuxiliaryEnabled(_ enabled: Bool) {
        guard fullscreenAuxiliaryUpdates.last != enabled else { return }
        fullscreenAuxiliaryUpdates.append(enabled)
    }
}

@MainActor
private final class DemandPanelRegistry {
    private(set) var panels: [DemandPanel] = []

    var creationCount: Int {
        panels.count
    }

    var latestPanel: DemandPanel? {
        panels.last
    }

    func makePanel(snapshot: DisplaySnapshot) -> any PanelPresenting {
        let panel = DemandPanel(displayIdentity: snapshot.identity)
        panels.append(panel)
        return panel
    }
}

@MainActor
private final class DemandPanel: PanelPresenting, PanelPresentationDemandReporting {
    let displayIdentity: DisplayIdentity
    private(set) var showCount = 0
    private(set) var hideCount = 0
    private(set) var closeCount = 0
    private var isDemanded = false
    private var demandHandler: (@MainActor @Sendable (Bool) -> Void)?
    private var demandRegistrations: [@MainActor @Sendable (Bool) -> Void] = []

    var wantsSurfacePresentation: Bool {
        isDemanded
    }

    var mutationCount: Int {
        showCount + hideCount + closeCount
    }

    init(displayIdentity: DisplayIdentity) {
        self.displayIdentity = displayIdentity
    }

    func setPresentationDemandHandler(
        _ handler: (@MainActor @Sendable (Bool) -> Void)?
    ) {
        demandHandler = handler
        if let handler {
            demandRegistrations.append(handler)
            handler(isDemanded)
        }
    }

    func replayDemandRegistration(_ registration: Int, isDemanded: Bool) {
        guard demandRegistrations.indices.contains(registration) else { return }
        demandRegistrations[registration](isDemanded)
    }

    func setDemand(_ isDemanded: Bool) {
        self.isDemanded = isDemanded
        demandHandler?(isDemanded)
    }

    func show() {
        showCount += 1
    }

    func hide() {
        hideCount += 1
    }

    func close() {
        closeCount += 1
    }

    func update(snapshot: DisplaySnapshot) {
        _ = snapshot
    }

    func updatePointer(screenPoint: CGPoint) {
        _ = screenPoint
    }

    func performPrimaryAction() {
        isDemanded.toggle()
        demandHandler?(isDemanded)
    }

    func performVisibilityToggle() {
        performPrimaryAction()
    }

    func cancelPendingInteractions() {}
}

@MainActor
private final class ModelDemandPanelRegistry {
    private(set) var panels: [ModelDemandPanel] = []

    var latestPanel: ModelDemandPanel? {
        panels.last
    }

    func makePanel(
        snapshot: DisplaySnapshot,
        activityModel: SurfaceActivityModel
    ) -> any PanelPresenting {
        let panel = ModelDemandPanel(
            snapshot: snapshot,
            activityModel: activityModel
        )
        panels.append(panel)
        return panel
    }
}

@MainActor
private final class ModelDemandPanel: PanelPresenting, PanelPresentationDemandReporting {
    let displayIdentity: DisplayIdentity
    private let model: PanelSurfaceModel
    private var demandHandler: (@MainActor @Sendable (Bool) -> Void)?
    private(set) var isPresented = false
    private(set) var showCount = 0
    private(set) var hideCount = 0
    private(set) var closeCount = 0

    var wantsSurfacePresentation: Bool {
        model.state != .hidden
    }

    var state: PanelPresentationState {
        model.state
    }

    init(snapshot: DisplaySnapshot, activityModel: SurfaceActivityModel) {
        displayIdentity = snapshot.identity
        model = PanelSurfaceModel(
            displayGeometry: snapshot.geometry,
            activityModel: activityModel
        )
        model.didChange = { [weak self] in
            guard let self else { return }
            self.demandHandler?(self.wantsSurfacePresentation)
        }
    }

    func setPresentationDemandHandler(
        _ handler: (@MainActor @Sendable (Bool) -> Void)?
    ) {
        demandHandler = handler
        handler?(wantsSurfacePresentation)
    }

    func show() {
        isPresented = true
        showCount += 1
    }

    func hide() {
        isPresented = false
        hideCount += 1
        model.cancelPendingInteractions()
    }

    func close() {
        isPresented = false
        closeCount += 1
        model.cancelPendingInteractions()
    }

    func update(snapshot: DisplaySnapshot) {
        model.update(displayGeometry: snapshot.geometry)
    }

    func updatePointer(screenPoint: CGPoint) {
        _ = screenPoint
    }

    func performPrimaryAction() {
        model.send(.primaryAction)
    }

    func performVisibilityToggle() {
        model.send(model.state == .hidden ? .show : .hide)
    }

    func cancelPendingInteractions() {
        model.cancelPendingInteractions()
    }

    func send(_ event: PanelEvent) {
        model.send(event)
    }
}
