import CoreGraphics
import Darwin
import EryloActivity
import EryloCore
import EryloIntegrations
import EryloSurface
import EryloWindowing

@main
@MainActor
enum FoundationHarnessMain {
    static func main() async {
        var harness = FoundationHarness()
        harness.verifyPanelStateMachine()
        harness.verifyPanelGeometry()
        harness.verifyDisplayPolicy()
        harness.verifyHoverHysteresisAndMotionInterruption()
        await harness.verifyCoordinatorLifecycle()
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
        check(hiddenDrop.send(.dragEntered) == .dropTarget, "delivered hidden drag entry reveals the honest drop target")
        check(hiddenDrop.send(.dragExited) == .hidden, "hidden drag exit restores invisible rest")

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
        check(fixedFrame.maxY == display.frame.maxY, "fixed frame is top-edge anchored")

        let hidden = PanelLayout(display: display, state: .hidden)
        check(!hidden.hitRegion.contains(hidden.surfaceFrame.center), "hidden state has no hit region")

        let compact = PanelLayout(display: display, state: .compact)
        check(compact.attachment == .notchlessPill, "notchless display uses pill attachment")
        check(compact.surfaceTopInset == 8, "notchless pill is inset from the display edge")
        check(
            compact.surfaceFrame.maxY == compact.fixedFrame.height - compact.surfaceTopInset,
            "notchless pill inset is represented in AppKit-local geometry"
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
        check(notched.fixedFrame == compact.fixedFrame, "notch does not change the maximum frame")
        check(notched.surfaceFrame.width == 280, "notch width and padding expand compact surface")
        check(notched.surfaceFrame.height == 74, "notch height expands compact surface")

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

        let expanded = PanelLayout(display: display, state: .expanded)
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
            defaultResolution.enabledDisplays.map(\.identity) == [external.identity, main.identity],
            "safe display policy preserves order while removing mirrors and duplicates"
        )
        check(
            defaultResolution.selectedDisplayIdentity == main.identity,
            "safe display policy selects the main display"
        )

        let selectedExternal = DisplayPolicy(
            enabledDisplayIdentities: [external.identity],
            selectedDisplayIdentity: external.identity
        ).resolve([main, external, mirrored])
        check(
            selectedExternal.enabledDisplays.map(\.identity) == [external.identity],
            "enabled-display allowlist selects a single external display"
        )
        check(
            selectedExternal.selectedDisplayIdentity == external.identity,
            "explicit selected display drives one-at-a-time interactions"
        )

        let missingSelection = DisplayPolicy(
            selectedDisplayIdentity: DisplayIdentity(rawValue: 999)
        ).resolve([external, main])
        check(
            missingSelection.selectedDisplayIdentity == main.identity,
            "missing selected display safely falls back to main"
        )

        let disabled = DisplayPolicy(isEnabled: false).resolve([main, external])
        check(disabled.enabledDisplays.isEmpty, "disabled display policy creates no enabled surfaces")
        check(disabled.selectedDisplayIdentity == nil, "disabled display policy has no shortcut target")
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
        model.setPointerInside(false)
        scheduler.runAll()
        check(model.state == .compact, "pointer transit keeps compact geometry stable")

        model.setPointerInside(true)
        check(model.state == .compact, "hover highlights without changing panel geometry")
        model.send(.primaryAction)
        scheduler.runAll()
        check(model.state == .expanded, "click deliberately expands the stable compact surface")

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
            reduceMotionScheduler.lastScheduledDelay == .milliseconds(120),
            "Reduce Motion uses the crossfade/scale completion duration"
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
            stableModel.state == .compact,
            "stationary notch hover cannot oscillate surface geometry"
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
    }

    mutating func verifyCoordinatorLifecycle() async {
        let main = makeSnapshot(identity: 10, isMain: true)
        let external = makeSnapshot(identity: 20, originX: 1_440)
        let mirrored = makeSnapshot(identity: 30, originX: 3_360, isMirrored: true)
        let provider = FakeDisplayProvider(displays: [main, external, external, mirrored])
        let eventSource = FakeLifecycleEventSource()
        let registry = FakePanelRegistry()
        let activityModel = SurfaceActivityModel(broker: ActivityBroker())
        let coordinator = PanelCoordinator(
            displayProvider: provider,
            policy: DisplayPolicy(selectedDisplayIdentity: external.identity),
            lifecycleEventSource: eventSource,
            activityModel: activityModel,
            panelFactory: { snapshot, _ in registry.makePanel(snapshot: snapshot) }
        )

        await coordinator.startAndWait()
        await coordinator.startAndWait()
        check(eventSource.startCount == 1, "repeated coordinator start owns one event source")
        check(registry.creationCount == 2, "repeated start creates exactly one panel per display ID")
        check(
            coordinator.activeDisplayIdentities == [main.identity, external.identity],
            "coordinator excludes duplicate and mirrored displays"
        )

        eventSource.emit(.primaryShortcut)
        check(registry.latestPanel(for: external.identity)?.primaryActionCount == 1, "shortcut targets selected display")
        check(registry.latestPanel(for: main.identity)?.primaryActionCount == 0, "shortcut does not fan out")

        let replacement = makeSnapshot(identity: 40, originX: 1_440)
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
        check(registry.latestPanel(for: main.identity)?.hideCount == 1, "sleep hides existing panels")
        let shortcutCountBeforeSleep = registry.totalPrimaryActionCount
        eventSource.emit(.primaryShortcut)
        check(
            registry.totalPrimaryActionCount == shortcutCountBeforeSleep,
            "shortcut is inert while workspace sleeps"
        )
        eventSource.emit(.workspaceDidWake)
        check(registry.latestPanel(for: main.identity)?.showCount == 4, "wake reconciles and reveals retained panel")

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
        check(registry.creationCount == 5, "re-enabled policy recreates one panel per available display")

        await coordinator.stopAndWait()
        await coordinator.stopAndWait()
        check(eventSource.stopCount == 2, "repeated coordinator stop removes event source once")
        check(coordinator.activeDisplayIdentities.isEmpty, "stop releases all active panel ownership")

        await coordinator.startAndWait()
        check(eventSource.startCount == 3, "coordinator can restart after stop")
        check(registry.creationCount == 7, "restart recreates exactly one panel per display")
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

private func makeSnapshot(
    identity: UInt32,
    originX: CGFloat = 0,
    isMain: Bool = false,
    isMirrored: Bool = false
) -> DisplaySnapshot {
    let frame = CGRect(x: originX, y: 0, width: 1_440, height: 900)
    return DisplaySnapshot(
        identity: DisplayIdentity(rawValue: identity),
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

@MainActor
private final class ManualScheduledOperation: ScheduledOperation {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
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
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var handler: (@MainActor @Sendable (PanelLifecycleEvent) -> Void)?

    func start(handler: @escaping @MainActor @Sendable (PanelLifecycleEvent) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        startCount += 1
        self.handler = handler
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
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
private final class FakePanel: PanelPresenting {
    let displayIdentity: DisplayIdentity
    private(set) var showCount = 0
    private(set) var hideCount = 0
    private(set) var closeCount = 0
    private(set) var updateCount = 0
    private(set) var pointerUpdateCount = 0
    private(set) var primaryActionCount = 0
    private(set) var cancellationCount = 0

    init(displayIdentity: DisplayIdentity) {
        self.displayIdentity = displayIdentity
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
        updateCount += 1
    }

    func updatePointer(screenPoint: CGPoint) {
        pointerUpdateCount += 1
    }

    func performPrimaryAction() {
        primaryActionCount += 1
    }

    func cancelPendingInteractions() {
        cancellationCount += 1
    }
}
