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

    package var hasWork: Bool {
        isRunning || observerCount > 0 || monitorCount > 0
            || hotKeyResourceCount > 0 || handlerCount > 0 || callbackLeaseCount > 0
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

    private let resources = SystemPanelLifecycleResources()

    public init() {}

    public func start(handler: @escaping @MainActor @Sendable (PanelLifecycleEvent) -> Void) {
        resources.start(handler: handler)
    }

    public func stop() {
        resources.stop()
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

    fileprivate var hasHandler: Bool {
        handler != nil
    }

    fileprivate var hasActiveLease: Bool {
        activeLease != nil
    }

    func start(handler: @escaping @MainActor @Sendable (PanelLifecycleEvent) -> Void) {
        guard !isRunning else { return }
        let lease = UUID()
        isRunning = true
        activeLease = lease
        self.handler = handler
        installNotifications(lease: lease)
        installPointerMonitors(lease: lease)
        installPrimaryShortcut(lease: lease)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        activeLease = nil

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
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: pointerEvents) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.emit(.pointerMoved(NSEvent.mouseLocation), lease: lease)
            }
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: pointerEvents) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.emit(.pointerMoved(NSEvent.mouseLocation), lease: lease)
            }
            return event
        }
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
