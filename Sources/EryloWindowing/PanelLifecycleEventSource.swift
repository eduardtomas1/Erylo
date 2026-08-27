import AppKit
import Carbon.HIToolbox
import CoreGraphics

public enum PanelLifecycleEvent: Equatable, Sendable {
    case displayConfigurationChanged
    case workspaceWillSleep
    case workspaceDidWake
    case activeSpaceChanged
    case pointerMoved(CGPoint)
    case primaryShortcut
}

@MainActor
public protocol PanelLifecycleEventSourcing: AnyObject {
    var isRunning: Bool { get }

    func start(handler: @escaping @MainActor @Sendable (PanelLifecycleEvent) -> Void)
    func stop()
}

package typealias PanelLifecycleEventDeliveryScheduler = @Sendable (
    @escaping @MainActor @Sendable () async -> Void
) -> Void

package struct PanelPointerDeliveryWorkState: Equatable, Sendable {
    package let pendingDeliveryCount: Int
    package let hasBufferedPosition: Bool
    package let maximumPendingDeliveryCount: Int
}

/// Thread-safe newest-value handoff from AppKit's local and global monitor callbacks
/// to one bounded MainActor delivery loop.
private final class PanelPointerEventCoalescer: @unchecked Sendable {
    private struct PendingPosition {
        let point: CGPoint
        let lease: UUID
    }

    private struct State {
        var activeLease: UUID?
        var pendingPosition: PendingPosition?
        var lastDeliveredPosition: CGPoint?
        var isDeliveryScheduled = false
        var maximumPendingDeliveryCount = 0
    }

    private let lock = NSLock()
    private var state = State()
    private let schedule: PanelLifecycleEventDeliveryScheduler
    private let deliver: @MainActor @Sendable (CGPoint, UUID) -> Void

    init(
        schedule: @escaping PanelLifecycleEventDeliveryScheduler,
        deliver: @escaping @MainActor @Sendable (CGPoint, UUID) -> Void
    ) {
        self.schedule = schedule
        self.deliver = deliver
    }

    func activate(lease: UUID) {
        lock.withLock {
            state.activeLease = lease
            state.pendingPosition = nil
            state.lastDeliveredPosition = nil
        }
    }

    func deactivate() {
        lock.withLock {
            state.activeLease = nil
            state.pendingPosition = nil
            state.lastDeliveredPosition = nil
        }
    }

    func submit(_ point: CGPoint, lease: UUID) {
        let shouldSchedule = lock.withLock { () -> Bool in
            guard state.activeLease == lease else { return false }
            if state.pendingPosition?.point == point {
                return false
            }
            if state.pendingPosition == nil, state.lastDeliveredPosition == point {
                return false
            }

            state.pendingPosition = PendingPosition(point: point, lease: lease)
            guard !state.isDeliveryScheduled else { return false }
            state.isDeliveryScheduled = true
            state.maximumPendingDeliveryCount = max(
                state.maximumPendingDeliveryCount,
                1
            )
            return true
        }

        guard shouldSchedule else { return }
        schedule { [weak self] in
            await self?.drain()
        }
    }

    var workState: PanelPointerDeliveryWorkState {
        lock.withLock {
            PanelPointerDeliveryWorkState(
                pendingDeliveryCount: state.isDeliveryScheduled ? 1 : 0,
                hasBufferedPosition: state.pendingPosition != nil,
                maximumPendingDeliveryCount: state.maximumPendingDeliveryCount
            )
        }
    }

    @MainActor
    private func drain() async {
        while let pendingPosition = takeNextPosition() {
            deliver(pendingPosition.point, pendingPosition.lease)
            await Task.yield()
        }
    }

    private func takeNextPosition() -> PendingPosition? {
        lock.withLock {
            guard let pendingPosition = state.pendingPosition,
                  state.activeLease == pendingPosition.lease else {
                state.pendingPosition = nil
                state.isDeliveryScheduled = false
                return nil
            }
            state.pendingPosition = nil
            state.lastDeliveredPosition = pendingPosition.point
            return pendingPosition
        }
    }
}

@MainActor
package final class PanelLifecycleEventSourceWorkProbe {
    private let resources: SystemPanelLifecycleResources

    fileprivate init(resources: SystemPanelLifecycleResources) {
        self.resources = resources
    }

    package var isRunning: Bool {
        resources.isRunning
    }

    package var observerCount: Int {
        resources.applicationObservers.count + resources.workspaceObservers.count
    }

    package var monitorCount: Int {
        (resources.globalPointerMonitor == nil ? 0 : 1)
            + (resources.localPointerMonitor == nil ? 0 : 1)
    }

    package var hotKeyResourceCount: Int {
        (resources.hotKey == nil ? 0 : 1)
            + (resources.hotKeyEventHandler == nil ? 0 : 1)
            + (resources.hotKeyContextReference == nil ? 0 : 1)
    }

    package var handlerCount: Int {
        resources.hasHandler ? 1 : 0
    }

    package var callbackLeaseCount: Int {
        resources.hasActiveLease ? 1 : 0
    }

    package var pointerDeliveryWorkState: PanelPointerDeliveryWorkState {
        resources.pointerDeliveryWorkState
    }

    package var hasWork: Bool {
        isRunning || observerCount > 0 || monitorCount > 0
            || hotKeyResourceCount > 0 || handlerCount > 0 || callbackLeaseCount > 0
            || pointerDeliveryWorkState.pendingDeliveryCount > 0
    }
}

@MainActor
/// Owns platform registrations through a separate resource token so detached
/// last release can transfer cleanup to MainActor without capturing `self`.
public final class SystemPanelLifecycleEventSource: PanelLifecycleEventSourcing {
    public var isRunning: Bool {
        resources.isRunning
    }

    package var workProbe: PanelLifecycleEventSourceWorkProbe {
        PanelLifecycleEventSourceWorkProbe(resources: resources)
    }

    private let resources: SystemPanelLifecycleResources

    public init() {
        resources = SystemPanelLifecycleResources()
    }

    package init(pointerDeliveryScheduler: @escaping PanelLifecycleEventDeliveryScheduler) {
        resources = SystemPanelLifecycleResources(
            pointerDeliveryScheduler: pointerDeliveryScheduler
        )
    }

    public func start(handler: @escaping @MainActor @Sendable (PanelLifecycleEvent) -> Void) {
        resources.start(handler: handler)
    }

    public func stop() {
        resources.stop()
    }

    package func submitPointerPositionForTesting(_ point: CGPoint) {
        resources.submitCurrentPointerPosition(point)
    }

    deinit {
        let resources = resources
        Task { @MainActor in
            resources.stop()
        }
    }
}

@MainActor
private final class SystemPanelLifecycleResources {
    fileprivate var isRunning = false
    fileprivate var applicationObservers: [NSObjectProtocol] = []
    fileprivate var workspaceObservers: [NSObjectProtocol] = []
    fileprivate var globalPointerMonitor: Any?
    fileprivate var localPointerMonitor: Any?
    fileprivate var hotKey: EventHotKeyRef?
    fileprivate var hotKeyEventHandler: EventHandlerRef?
    fileprivate var hotKeyContextReference: Unmanaged<SystemPanelHotKeyContext>?
    private var handler: (@MainActor @Sendable (PanelLifecycleEvent) -> Void)?
    private var activeLease: UUID?
    private let pointerDeliveryScheduler: PanelLifecycleEventDeliveryScheduler
    private lazy var pointerDelivery = PanelPointerEventCoalescer(
        schedule: pointerDeliveryScheduler
    ) { [weak self] point, lease in
        self?.emit(.pointerMoved(point), lease: lease)
    }

    init(
        pointerDeliveryScheduler: @escaping PanelLifecycleEventDeliveryScheduler = { operation in
            Task { @MainActor in
                await operation()
            }
        }
    ) {
        self.pointerDeliveryScheduler = pointerDeliveryScheduler
    }

    fileprivate var hasHandler: Bool {
        handler != nil
    }

    fileprivate var hasActiveLease: Bool {
        activeLease != nil
    }

    fileprivate var pointerDeliveryWorkState: PanelPointerDeliveryWorkState {
        pointerDelivery.workState
    }

    func start(handler: @escaping @MainActor @Sendable (PanelLifecycleEvent) -> Void) {
        guard !isRunning else { return }
        let lease = UUID()
        isRunning = true
        activeLease = lease
        self.handler = handler
        pointerDelivery.activate(lease: lease)
        installNotifications(lease: lease)
        installPointerMonitors(lease: lease)
        installPrimaryShortcut(lease: lease)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        activeLease = nil
        pointerDelivery.deactivate()

        applicationObservers.forEach(NotificationCenter.default.removeObserver)
        applicationObservers.removeAll()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(workspaceCenter.removeObserver)
        workspaceObservers.removeAll()

        if let globalPointerMonitor {
            NSEvent.removeMonitor(globalPointerMonitor)
            self.globalPointerMonitor = nil
        }
        if let localPointerMonitor {
            NSEvent.removeMonitor(localPointerMonitor)
            self.localPointerMonitor = nil
        }
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let hotKeyEventHandler {
            RemoveEventHandler(hotKeyEventHandler)
            self.hotKeyEventHandler = nil
        }
        hotKeyContextReference?.release()
        hotKeyContextReference = nil

        handler = nil
    }

    private func installNotifications(lease: UUID) {
        applicationObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.emit(.displayConfigurationChanged, lease: lease)
                }
            }
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.emit(.workspaceWillSleep, lease: lease)
                }
            }
        )
        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.emit(.workspaceDidWake, lease: lease)
                }
            }
        )
        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.emit(.activeSpaceChanged, lease: lease)
                }
            }
        )
    }

    private func installPointerMonitors(lease: UUID) {
        let pointerEvents: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
        ]
        let pointerDelivery = pointerDelivery
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: pointerEvents) { _ in
            pointerDelivery.submit(NSEvent.mouseLocation, lease: lease)
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: pointerEvents) { event in
            pointerDelivery.submit(NSEvent.mouseLocation, lease: lease)
            return event
        }
    }

    fileprivate func submitCurrentPointerPosition(_ point: CGPoint) {
        guard let activeLease else { return }
        pointerDelivery.submit(point, lease: activeLease)
    }

    /// Carbon's public hot-key registration provides a global route without Accessibility
    /// permission or a global key-event monitor. The callback only changes panel state.
    private func installPrimaryShortcut(lease: UUID) {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = SystemPanelHotKeyContext(resources: self, lease: lease)
        let contextReference = Unmanaged.passRetained(context)
        hotKeyContextReference = contextReference
        let userData = contextReference.toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            eryloHotKeyEventHandler,
            1,
            &eventType,
            userData,
            &hotKeyEventHandler
        )
        guard installStatus == noErr else {
            hotKeyContextReference?.release()
            hotKeyContextReference = nil
            return
        }

        var registeredHotKey: EventHotKeyRef?
        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_E),
            UInt32(cmdKey | optionKey | controlKey),
            EventHotKeyID(signature: 0x4552_594C, id: 1),
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )
        guard registrationStatus == noErr else {
            if let hotKeyEventHandler {
                RemoveEventHandler(hotKeyEventHandler)
                self.hotKeyEventHandler = nil
            }
            hotKeyContextReference?.release()
            hotKeyContextReference = nil
            return
        }
        hotKey = registeredHotKey
    }

    fileprivate func emit(_ event: PanelLifecycleEvent, lease: UUID) {
        guard isRunning, activeLease == lease else { return }
        handler?(event)
    }
}

@MainActor
private final class SystemPanelHotKeyContext {
    private weak var resources: SystemPanelLifecycleResources?
    private let lease: UUID

    init(resources: SystemPanelLifecycleResources, lease: UUID) {
        self.resources = resources
        self.lease = lease
    }

    func receivePrimaryShortcut() {
        resources?.emit(.primaryShortcut, lease: lease)
    }
}

private func eryloHotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var receivedHotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &receivedHotKeyID
    )
    guard status == noErr, receivedHotKeyID.signature == 0x4552_594C,
          receivedHotKeyID.id == 1 else {
        return OSStatus(eventNotHandledErr)
    }

    let context = Unmanaged<SystemPanelHotKeyContext>
        .fromOpaque(userData)
        .takeUnretainedValue()
    Task { @MainActor in
        context.receivePrimaryShortcut()
    }
    return noErr
}
